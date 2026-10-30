-module(project3).
-export([main/1, main/0, start/0, run/2, run/3]).

%% Entry point when called with no args (e.g. erl -noshell -s project3 start ...)
start() ->
    Args = init:get_plain_arguments(),
    main(Args).

main() ->
    Args = init:get_plain_arguments(),
    main(Args).

%% Main entry point (escript or erl -s project3 main Arg1 Arg2)
main(Args) ->
    case Args of
        [NumNodesArg, NumRequestsArg] ->
            NumNodes = parse_arg(NumNodesArg),
            NumRequests = parse_arg(NumRequestsArg),
            run(NumNodes, NumRequests, 1000);
        [NumNodesArg, NumRequestsArg, IntervalArg] ->
            NumNodes = parse_arg(NumNodesArg),
            NumRequests = parse_arg(NumRequestsArg),
            IntervalMs = parse_arg(IntervalArg),
            run(NumNodes, NumRequests, IntervalMs);
        _ ->
            io:format("Usage: project3 numNodes numRequests [intervalMs]~n"),
            io:format("Example: project3 100 10~n"),
            halt(1)
    end.

parse_arg(Arg) when is_integer(Arg) -> Arg;
parse_arg(Arg) when is_atom(Arg) -> list_to_integer(atom_to_list(Arg));
parse_arg(Arg) when is_list(Arg) -> list_to_integer(Arg).

run(NumNodes, NumRequests) ->
    run(NumNodes, NumRequests, 1000).

run(NumNodes, NumRequests, IntervalMs) ->
    io:format("=============================================================~n"),
    io:format("  Pastry P2P Network Simulation (Project 3)~n"),
    io:format("=============================================================~n"),
    io:format("Team Member: Suhrudh Reddy Pyata (UFID: 32561781)~n"),
    io:format("Peers (Nodes):        ~p~n", [NumNodes]),
    io:format("Requests per peer:    ~p~n", [NumRequests]),
    io:format("Request interval:     ~p ms (~.1f req/sec per peer)~n", [IntervalMs, 1000.0 / IntervalMs]),
    io:format("-------------------------------------------------------------~n"),

    StartTime = erlang:monotonic_time(millisecond),

    %% Step 1: Start bootstrap node (first peer actor)
    BootstrapPid = pastry_node:start_bootstrap(self(), []),
    BootstrapNode = receive
        {bootstrap_ready, BPid, BId, BHex} ->
            {BId, BHex, BPid}
    after 10000 ->
        error(bootstrap_timeout)
    end,

    %% Step 2: Join remaining peers one by one via Pastry join protocol
    io:format("[Network Join Phase] Initializing and joining ~p peer actors...~n", [NumNodes]),
    AllNodes = join_peers(NumNodes - 1, BootstrapPid, [BootstrapNode], 1, NumNodes),
    BuildTime = erlang:monotonic_time(millisecond) - StartTime,
    io:format("[Network Ready] All ~p peers joined successfully in ~p ms.~n", [NumNodes, BuildTime]),

    %% Step 3: Start request phase (each peer sends requests at the specified interval)
    TotalExpectedRequests = NumNodes * NumRequests,
    io:format("[Request Phase] Starting ~p requests (~p requests/sec per peer)...~n",
              [TotalExpectedRequests, 1000.0 / IntervalMs]),

    lists:foreach(
        fun({_Id, _Hex, Pid}) ->
            Pid ! {start_requests, NumRequests, IntervalMs}
        end,
        AllNodes
    ),

    %% Precompute O(log N) circular binary-search checker
    Checker = pastry_util:build_closest_checker(AllNodes),

    %% Step 4: Collect all delivered requests and compute average hops
    {TotalHops, DeliveredCount, CorrectCount} = collect_requests(TotalExpectedRequests, Checker, 0, 0, 0),
    TotalTime = erlang:monotonic_time(millisecond) - StartTime,

    %% Step 5: Output average number of hops
    AvgHops = case DeliveredCount of
        0 -> 0.0;
        _ -> TotalHops / DeliveredCount
    end,

    io:format("-------------------------------------------------------------~n"),
    io:format("Simulation Summary:~n"),
    io:format("  Requests Delivered: ~p / ~p (~.1f%)~n",
              [DeliveredCount, TotalExpectedRequests, (DeliveredCount / max(1, TotalExpectedRequests)) * 100.0]),
    io:format("  Routing Accuracy:   ~p / ~p (~.1f% at closest node)~n",
              [CorrectCount, TotalExpectedRequests, (CorrectCount / max(1, TotalExpectedRequests)) * 100.0]),
    io:format("  Total Simulation Time: ~p ms (~.2f s)~n", [TotalTime, TotalTime / 1000.0]),
    io:format("Average number of hops = ~.2f~n", [AvgHops]),
    io:format("=============================================================~n"),
    lists:foreach(fun({_Id, _Hex, Pid}) -> exit(Pid, kill) end, AllNodes),
    AvgHops.

join_peers(0, _BootstrapPid, Acc, _Current, _Total) ->
    lists:reverse(Acc);
join_peers(Remaining, BootstrapPid, Acc, Current, Total) ->
    pastry_node:start(self(), BootstrapPid, []),
    receive
        {join_complete, NewPid, NewId, NewHex} ->
            NextCurrent = Current + 1,
            case NextCurrent rem 1000 == 0 of
                true ->
                    io:format("  Joined ~p / ~p peers...~n", [NextCurrent, Total]);
                false ->
                    ok
            end,
            join_peers(Remaining - 1, BootstrapPid, [{NewId, NewHex, NewPid} | Acc], NextCurrent, Total)
    after 15000 ->
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
    after 30000 ->
        io:format("Warning: Request collection timed out with ~p requests remaining!~n", [Remaining]),
        {TotalHops, DeliveredCount, CorrectCount}
    end.
