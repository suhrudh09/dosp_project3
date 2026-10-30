-module(test_network).
-export([run/0, run/2]).

run() ->
    run(10, 5).

run(NumNodes, NumRequests) ->
    io:format("Starting network test with ~p nodes, ~p requests each...~n", [NumNodes, NumRequests]),
    StartTime = erlang:monotonic_time(millisecond),
    
    %% Start bootstrap node
    BootstrapPid = pastry_node:start_bootstrap(self(), []),
    BootstrapNode = receive
        {bootstrap_ready, BPid, BId, BHex} ->
            io:format("Bootstrap node ready: ~s~n", [BHex]),
            {BId, BHex, BPid}
    after 5000 ->
        error(bootstrap_timeout)
    end,
    
    %% Join remaining nodes
    Nodes = join_remaining_nodes(NumNodes - 1, BootstrapPid, [BootstrapNode]),
    BuildTime = erlang:monotonic_time(millisecond) - StartTime,
    io:format("Successfully joined ~p nodes in ~p ms!~n", [NumNodes, BuildTime]),
    
    %% Start request phase
    TotalExpectedRequests = NumNodes * NumRequests,
    io:format("Sending start_requests to all ~p nodes (~p total requests)...~n", [NumNodes, TotalExpectedRequests]),
    %% For testing, use 50ms interval to speed up the test
    lists:foreach(
        fun({_Id, _Hex, Pid}) ->
            Pid ! {start_requests, NumRequests, 50}
        end,
        Nodes
    ),
    
    %% Collect request completions using fast O(log N) verification
    Checker = pastry_util:build_closest_checker(Nodes),
    {TotalHops, DeliveredCount, CorrectCount} = collect_requests(TotalExpectedRequests, Checker, 0, 0, 0),
    TotalTime = erlang:monotonic_time(millisecond) - StartTime,
    
    AvgHops = TotalHops / max(1, DeliveredCount),
    Accuracy = (CorrectCount / max(1, TotalExpectedRequests)) * 100.0,
    io:format("Completed ~p/~p requests in ~p ms (Routing Accuracy: ~.1f%).~n",
              [DeliveredCount, TotalExpectedRequests, TotalTime, Accuracy]),
    io:format("Average number of hops = ~.2f~n", [AvgHops]),
    
    %% Clean up processes
    lists:foreach(fun({_Id, _Hex, Pid}) -> exit(Pid, kill) end, Nodes),
    ok.

join_remaining_nodes(0, _BootstrapPid, Acc) ->
    lists:reverse(Acc);
join_remaining_nodes(Remaining, BootstrapPid, Acc) ->
    pastry_node:start_link(self(), BootstrapPid, []),
    receive
        {join_complete, NewPid, NewId, NewHex} ->
            join_remaining_nodes(Remaining - 1, BootstrapPid, [{NewId, NewHex, NewPid} | Acc])
    after 10000 ->
        error(join_timeout)
    end.

collect_requests(0, _Checker, TotalHops, DeliveredCount, CorrectCount) ->
    {TotalHops, DeliveredCount, CorrectCount};
collect_requests(Remaining, Checker, TotalHops, DeliveredCount, CorrectCount) ->
    receive
        {request_delivered, NodePid, KeyHex, Hops} ->
            IsCorrect = pastry_util:is_closest_node(KeyHex, NodePid, Checker),
            NewCorrect = case IsCorrect of true -> CorrectCount + 1; false -> CorrectCount end,
            collect_requests(Remaining - 1, Checker, TotalHops + Hops, DeliveredCount + 1, NewCorrect)
    after 10000 ->
        io:format("Warning: Request collection timed out with ~p requests remaining!~n", [Remaining]),
        {TotalHops, DeliveredCount, CorrectCount}
    end.
