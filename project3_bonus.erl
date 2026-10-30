-module(project3_bonus).
-export([main/1, run/4, run_benchmark/0]).

main(Args) ->
    case Args of
        [NumNodesStr, NumRequestsStr] ->
            %% Default failure mode: 10% node failures
            NumNodes = list_to_integer(NumNodesStr),
            NumRequests = list_to_integer(NumRequestsStr),
            NumFailures = max(1, NumNodes div 10),
            run(NumNodes, NumRequests, NumFailures, node);
        [NumNodesStr, NumRequestsStr, NumFailuresStr] ->
            NumNodes = list_to_integer(NumNodesStr),
            NumRequests = list_to_integer(NumRequestsStr),
            NumFailures = list_to_integer(NumFailuresStr),
            run(NumNodes, NumRequests, NumFailures, node);
        [NumNodesStr, NumRequestsStr, NumFailuresStr, FailureTypeStr] ->
            NumNodes = list_to_integer(NumNodesStr),
            NumRequests = list_to_integer(NumRequestsStr),
            NumFailures = list_to_integer(NumFailuresStr),
            FailureType = case FailureTypeStr of
                "connection" -> connection;
                "link" -> connection;
                "transient" -> transient;
                _ -> node
            end,
            run(NumNodes, NumRequests, NumFailures, FailureType);
        _ ->
            io:format("Usage: project3_bonus numNodes numRequests [numFailures] [node|connection|transient]~n"),
            io:format("   or: erl -noshell -pa . -s project3_bonus run_benchmark -s init stop~n"),
            halt(1)
    end.

run(NumNodes, NumRequests, NumFailures, FailureType) ->
    io:format("=============================================================~n"),
    io:format("  Pastry Failure & Fault Tolerance Simulation (Bonus)~n"),
    io:format("=============================================================~n"),
    io:format("Configuration:~n"),
    io:format("  Total Nodes:       ~p~n", [NumNodes]),
    io:format("  Requests / Node:   ~p~n", [NumRequests]),
    io:format("  Failure Type:      ~p~n", [FailureType]),
    io:format("  Failure Count:     ~p~n", [NumFailures]),
    io:format("-------------------------------------------------------------~n"),

    %% Step 1: Initialize Bootstrap & Join Nodes
    StartTime = erlang:monotonic_time(millisecond),
    BootstrapPid = pastry_node:start_bootstrap(self(), []),
    BootstrapNode = receive
        {bootstrap_ready, BPid, BId, BHex} ->
            {BId, BHex, BPid}
    after 5000 ->
        error(bootstrap_timeout)
    end,

    AllNodes = join_nodes(NumNodes - 1, BootstrapPid, [BootstrapNode]),
    BuildTime = erlang:monotonic_time(millisecond) - StartTime,
    io:format("[Network Built] ~p nodes joined successfully in ~p ms.~n", [NumNodes, BuildTime]),

    %% Step 2: Inject Failures
    {SurvivingNodes, FailedCount} = inject_failures(AllNodes, NumFailures, FailureType),
    io:format("[Failure Injected] Mode: ~p | Injected failures: ~p | Surviving nodes: ~p~n",
              [FailureType, FailedCount, length(SurvivingNodes)]),

    %% Step 3: Run Requests
    NumSurviving = length(SurvivingNodes),
    TotalExpectedRequests = NumSurviving * NumRequests,
    IntervalMs = case FailureType of
        transient -> 20;
        _ -> 50
    end,
    io:format("[Request Phase] ~p surviving nodes sending ~p requests each (~p total)...~n",
              [NumSurviving, NumRequests, TotalExpectedRequests]),

    lists:foreach(
        fun({_Id, _Hex, Pid}) ->
            Pid ! {start_requests, NumRequests, IntervalMs}
        end,
        SurvivingNodes
    ),

    %% Step 4: Collect Delivered Requests using fast O(log N) verification
    Checker = pastry_util:build_closest_checker(SurvivingNodes),
    {TotalHops, DeliveredCount, CorrectCount} = collect_requests(TotalExpectedRequests, Checker, 0, 0, 0),
    TotalTime = erlang:monotonic_time(millisecond) - StartTime,

    %% Step 5: Report Results
    DeliveryRate = (DeliveredCount / max(1, TotalExpectedRequests)) * 100.0,
    CorrectRate = (CorrectCount / max(1, TotalExpectedRequests)) * 100.0,
    AvgHops = case DeliveredCount of
        0 -> 0.0;
        _ -> TotalHops / DeliveredCount
    end,

    io:format("-------------------------------------------------------------~n"),
    io:format("Results:~n"),
    io:format("  Requests Delivered: ~p / ~p (~.1f%)~n", [DeliveredCount, TotalExpectedRequests, DeliveryRate]),
    io:format("  At Correct Node:    ~p / ~p (~.1f%)~n", [CorrectCount, TotalExpectedRequests, CorrectRate]),
    io:format("  Total Time Taken:   ~p ms~n", [TotalTime]),
    io:format("  Average number of hops = ~.2f~n", [AvgHops]),
    io:format("=============================================================~n"),
    lists:foreach(fun({_, _, Pid}) -> exit(Pid, kill) end, SurvivingNodes),
    {DeliveryRate, CorrectRate, AvgHops}.

join_nodes(0, _BootstrapPid, Acc) ->
    lists:reverse(Acc);
join_nodes(Remaining, BootstrapPid, Acc) ->
    pastry_node:start(self(), BootstrapPid, []),
    receive
        {join_complete, NewPid, NewId, NewHex} ->
            join_nodes(Remaining - 1, BootstrapPid, [{NewId, NewHex, NewPid} | Acc])
    after 10000 ->
        error(join_timeout)
    end.

inject_failures(AllNodes, NumFailures, node) ->
    %% Randomly select NumFailures nodes to kill
    Shuffled = [N || {_, N} <- lists:sort([{rand:uniform(), Node} || Node <- AllNodes])],
    ActualFailures = min(NumFailures, length(AllNodes) - 1),
    {ToKill, Surviving} = lists:split(ActualFailures, Shuffled),
    lists:foreach(
        fun({_Id, _Hex, Pid}) ->
            Pid ! kill_node
        end,
        ToKill
    ),
    {Surviving, ActualFailures};

inject_failures(AllNodes, NumFailures, connection) ->
    %% Permanently drop links between uniformly shuffled random pairs of nodes
    NodePids = [P || {_Id, _Hex, P} <- AllNodes],
    AllPairs = lists:usort([
        case P1 < P2 of
            true -> {P1, P2};
            false -> {P2, P1}
        end
        || P1 <- NodePids, P2 <- NodePids, P1 /= P2
    ]),
    ShuffledPairs = [P || {_, P} <- lists:sort([{rand:uniform(), Pair} || Pair <- AllPairs])],
    ActualDrops = min(NumFailures, length(ShuffledPairs)),
    PairsToDrop = lists:sublist(ShuffledPairs, ActualDrops),
    lists:foreach(
        fun({P1, P2}) ->
            P1 ! {drop_link, P2},
            P2 ! {drop_link, P1}
        end,
        PairsToDrop
    ),
    {AllNodes, ActualDrops};

inject_failures(AllNodes, NumFailures, transient) ->
    %% Drop links with temporary glitch and schedule restoration via restore_link during traffic
    NodePids = [P || {_Id, _Hex, P} <- AllNodes],
    AllPairs = lists:usort([
        case P1 < P2 of
            true -> {P1, P2};
            false -> {P2, P1}
        end
        || P1 <- NodePids, P2 <- NodePids, P1 /= P2
    ]),
    ShuffledPairs = [P || {_, P} <- lists:sort([{rand:uniform(), Pair} || Pair <- AllPairs])],
    ActualDrops = min(NumFailures, length(ShuffledPairs)),
    PairsToDrop = lists:sublist(ShuffledPairs, ActualDrops),
    lists:foreach(
        fun({P1, P2}) ->
            P1 ! {drop_link, P2},
            P2 ! {drop_link, P1},
            %% Auto-restore link after 40ms to simulate transient glitch recovery mid-traffic
            erlang:send_after(40, P1, {restore_link, P2}),
            erlang:send_after(40, P2, {restore_link, P1})
        end,
        PairsToDrop
    ),
    {AllNodes, ActualDrops}.

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

%%--------------------------------------------------------------------
%% Automated Benchmark Suite for Bonus Report
%%--------------------------------------------------------------------
run_benchmark() ->
    io:format("~nRunning Pastry Fault Tolerance & Resilience Benchmark Suite...~n~n"),
    N = 200,
    Reqs = 5,

    io:format("-----------------------------------------------------------------------------------------~n"),
    io:format(" EXPERIMENT 1: Node Failure Resilience (Total Nodes: ~p, Reqs/Node: ~p)~n", [N, Reqs]),
    io:format("-----------------------------------------------------------------------------------------~n"),
    io:format(" Failures (%) | Failed Nodes | Delivery Rate | Correct Node | Avg Hops Traversed ~n"),
    io:format("-----------------------------------------------------------------------------------------~n"),
    
    lists:foreach(
        fun(Pct) ->
            FailCount = round(N * Pct / 100),
            {DelivRate, CorrectRate, AvgHops} = run_silent(N, Reqs, FailCount, node),
            io:format("    ~3p%      |     ~3p      |    ~5.1f%     |    ~5.1f%    |      ~.2f         ~n",
                      [Pct, FailCount, DelivRate, CorrectRate, AvgHops])
        end,
        [0, 5, 10, 15, 20, 25, 30]
    ),
    io:format("-----------------------------------------------------------------------------------------~n~n"),

    io:format("-----------------------------------------------------------------------------------------~n"),
    io:format(" EXPERIMENT 2: Connection / Link Failure Resilience (Nodes: ~p, Shuffled)~n", [N]),
    io:format("-----------------------------------------------------------------------------------------~n"),
    io:format(" Dropped Links | Delivery Rate | Correct Node | Avg Hops Traversed ~n"),
    io:format("-----------------------------------------------------------------------------------------~n"),
    
    lists:foreach(
        fun(LinkDrops) ->
            {DelivRate, CorrectRate, AvgHops} = run_silent(N, Reqs, LinkDrops, connection),
            io:format("     ~4p      |    ~5.1f%     |    ~5.1f%    |      ~.2f         ~n",
                      [LinkDrops, DelivRate, CorrectRate, AvgHops])
        end,
        [0, 50, 100, 200, 400]
    ),
    io:format("-----------------------------------------------------------------------------------------~n~n"),

    io:format("-----------------------------------------------------------------------------------------~n"),
    io:format(" EXPERIMENT 3: Transient Link Glitch & Live Link Restoration (Nodes: ~p)~n", [N]),
    io:format("-----------------------------------------------------------------------------------------~n"),
    io:format(" Glitched Links | Delivery Rate | Correct Node | Avg Hops Traversed ~n"),
    io:format("-----------------------------------------------------------------------------------------~n"),
    
    lists:foreach(
        fun(LinkDrops) ->
            {DelivRate, CorrectRate, AvgHops} = run_silent(N, Reqs, LinkDrops, transient),
            io:format("     ~4p       |    ~5.1f%     |    ~5.1f%    |      ~.2f         ~n",
                      [LinkDrops, DelivRate, CorrectRate, AvgHops])
        end,
        [50, 100, 200]
    ),
    io:format("-----------------------------------------------------------------------------------------~n~n"),
    ok.

run_silent(NumNodes, NumRequests, NumFailures, FailureType) ->
    BootstrapPid = pastry_node:start_bootstrap(self(), []),
    BootstrapNode = receive
        {bootstrap_ready, BPid, BId, BHex} -> {BId, BHex, BPid}
    end,
    AllNodes = join_nodes(NumNodes - 1, BootstrapPid, [BootstrapNode]),
    {SurvivingNodes, _} = inject_failures(AllNodes, NumFailures, FailureType),
    TotalExpected = length(SurvivingNodes) * NumRequests,
    IntervalMs = case FailureType of
        transient -> 20; % Traffic window spans 100ms across 40ms auto-restoration
        _ -> 10
    end,
    lists:foreach(
        fun({_Id, _Hex, Pid}) -> Pid ! {start_requests, NumRequests, IntervalMs} end,
        SurvivingNodes
    ),
    Checker = pastry_util:build_closest_checker(SurvivingNodes),
    {TotalHops, DeliveredCount, CorrectCount} = collect_requests(TotalExpected, Checker, 0, 0, 0),
    DeliveryRate = (DeliveredCount / max(1, TotalExpected)) * 100.0,
    CorrectRate = (CorrectCount / max(1, TotalExpected)) * 100.0,
    AvgHops = case DeliveredCount of
        0 -> 0.0;
        _ -> TotalHops / DeliveredCount
    end,
    %% Clean up processes
    lists:foreach(fun({_, _, Pid}) -> exit(Pid, kill) end, SurvivingNodes),
    {DeliveryRate, CorrectRate, AvgHops}.
