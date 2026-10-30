-module(benchmark_scale).
-export([run/0]).

run() ->
    Sizes = [100, 500, 1000, 2000, 5000, 10000],
    NumRequests = 2,
    io:format("=============================================================================~n"),
    io:format("  Pastry Network Scalability & Hop Analysis Benchmark~n"),
    io:format("=============================================================================~n"),
    io:format(" Nodes (N) | Log16(N) | Total Requests | Build Time | Req Time | Avg Hops ~n"),
    io:format("-----------------------------------------------------------------------------~n"),
    lists:foreach(
        fun(N) ->
            StartTime = erlang:monotonic_time(millisecond),
            BootstrapPid = pastry_node:start_bootstrap(self(), []),
            BootstrapNode = receive
                {bootstrap_ready, BPid, BId, BHex} -> {BId, BHex, BPid}
            end,
            Nodes = join_nodes(N - 1, BootstrapPid, [BootstrapNode]),
            BuildTime = erlang:monotonic_time(millisecond) - StartTime,
            
            ReqStart = erlang:monotonic_time(millisecond),
            TotalReqs = N * NumRequests,
            lists:foreach(
                fun({_Id, _Hex, Pid}) -> Pid ! {start_requests, NumRequests, 20} end,
                Nodes
            ),
            {TotalHops, Delivered} = collect_requests(TotalReqs, 0, 0),
            ReqTime = erlang:monotonic_time(millisecond) - ReqStart,
            
            AvgHops = TotalHops / max(1, Delivered),
            Log16 = math:log(N) / math:log(16),
            io:format("   ~5p   |  ~4.2f   |     ~5p      |  ~5p ms  | ~5p ms |   ~4.2f   ~n",
                      [N, Log16, TotalReqs, BuildTime, ReqTime, AvgHops]),
            
            %% Clean up processes
            lists:foreach(fun({_Id, _Hex, Pid}) -> exit(Pid, kill) end, Nodes)
        end,
        Sizes
    ),
    io:format("=============================================================================~n"),
    ok.

join_nodes(0, _BootstrapPid, Acc) ->
    lists:reverse(Acc);
join_nodes(Remaining, BootstrapPid, Acc) ->
    pastry_node:start(self(), BootstrapPid, []),
    receive
        {join_complete, NewPid, NewId, NewHex} ->
            join_nodes(Remaining - 1, BootstrapPid, [{NewId, NewHex, NewPid} | Acc])
    after 15000 ->
        error(join_timeout)
    end.

collect_requests(0, TotalHops, DeliveredCount) ->
    {TotalHops, DeliveredCount};
collect_requests(Remaining, TotalHops, DeliveredCount) ->
    receive
        {request_delivered, _NodePid, _KeyHex, Hops} ->
            collect_requests(Remaining - 1, TotalHops + Hops, DeliveredCount + 1)
    after 20000 ->
        {TotalHops, DeliveredCount}
    end.
