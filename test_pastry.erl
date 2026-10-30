-module(test_pastry).
-export([run/0]).

run() ->
    io:format("Running pastry unit tests...~n"),
    {Id1, Hex1} = pastry_util:random_id(),
    {Id2, Hex2} = pastry_util:random_id(),
    io:format("Generated Node 1: ~s (~p)~n", [Hex1, Id1]),
    io:format("Generated Node 2: ~s (~p)~n", [Hex2, Id2]),
    
    32 = length(Hex1),
    32 = length(Hex2),
    Id1 = pastry_util:hex_to_int(Hex1),
    Id2 = pastry_util:hex_to_int(Hex2),
    
    %% Test prefix length
    0 = pastry_util:shl("0123", "1123"),
    2 = pastry_util:shl("01ab", "01cd"),
    4 = pastry_util:shl("0123", "0123"),
    
    %% Test leaf set
    L0 = pastry_util:new_leaf_set(),
    true = pastry_util:is_in_leaf_range(Id2, L0, Id1),
    
    L1 = pastry_util:add_to_leaf_set(L0, {Id2, Hex2, self()}, Id1),
    true = pastry_util:is_in_leaf_range(Id2, L1, Id1),
    
    %% Test closest in leaf set
    {ClosestId, ClosestHex, _, _Dist} = pastry_util:closest_in_leaf_set(Id2, L1, Id1, Hex1),
    ClosestId = Id2,
    ClosestHex = Hex2,
    
    %% Test routing table
    R0 = pastry_util:new_routing_table(),
    R1 = pastry_util:add_to_routing_table(R0, {Id2, Hex2, self()}, Hex1),
    Shl = pastry_util:shl(Hex1, Hex2),
    Col = pastry_util:char_to_digit(lists:nth(Shl + 1, Hex2)),
    {Id2, Hex2, _} = pastry_util:get_routing_entry(R1, Shl, Col),
    
    io:format("All pastry_util tests passed successfully!~n"),
    
    %%--------------------------------------------------------------------
    %% Routing & Object Access Service Assertions (Item 2 & Item 7)
    %%--------------------------------------------------------------------
    io:format("Running routing & object access assertions on live overlay...~n"),
    NumNodes = 6,
    BPid = pastry_node:start_bootstrap(self(), []),
    BNode = receive
        {bootstrap_ready, PidB, IdB, HexB} -> {IdB, HexB, PidB}
    after 5000 ->
        error(bootstrap_timeout)
    end,
    
    JoinedNodes = join_test_nodes(NumNodes - 1, BPid, [BNode]),
    6 = length(JoinedNodes),
    
    %% Assertion 1: Object Access Service (PUT and GET across different nodes)
    {_TKeyId, TKeyHex} = pastry_util:random_id(),
    TestPayload = "Value-" ++ TKeyHex,
    
    [{_, _, Node1}, _, {_, _, Node3} | _] = JoinedNodes,
    
    %% PUT from Node 1
    {ok, PutDelivPid} = pastry_node:put(Node1, TKeyHex, TestPayload),
    true = is_pid(PutDelivPid),
    
    %% GET from Node 3 (different node in overlay)
    {ok, RetrievedVal, GetDelivPid} = pastry_node:get(Node3, TKeyHex),
    TestPayload = RetrievedVal,
    PutDelivPid = GetDelivPid,
    io:format("Object Access Service PUT/GET verified: ~s retrieved successfully across nodes!~n", [RetrievedVal]),
    
    %% Assertion 2: Verify delivery landed on the true closest node in overlay
    Checker = pastry_util:build_closest_checker(JoinedNodes),
    true = pastry_util:is_closest_node(TKeyHex, GetDelivPid, Checker),
    io:format("Routing Assertion 1 passed: message landed on true numerically closest node!~n"),
    
    %% Assertion 3: Verify multiple random keys route to their exact closest node
    lists:foreach(
        fun(Idx) ->
            {_, RHex} = pastry_util:random_id(),
            ValStr = "AssertVal-" ++ integer_to_list(Idx),
            {ok, DPid} = pastry_node:put(Node1, RHex, ValStr),
            true = pastry_util:is_closest_node(RHex, DPid, Checker),
            {ok, ValStr, DPid} = pastry_node:get(Node3, RHex)
        end,
        lists:seq(1, 10)
    ),
    io:format("Routing Assertion 2 passed: 10/10 random keys routed to true closest nodes!~n"),
    
    %% Assertion 4: Verify fallback routing with dropped link and state healing on restore
    {_, _, N1Pid} = lists:nth(1, JoinedNodes),
    {_, _, N2Pid} = lists:nth(2, JoinedNodes),
    N1Pid ! {drop_link, N2Pid},
    N2Pid ! {drop_link, N1Pid},
    {_, FHex} = pastry_util:random_id(),
    {ok, _} = pastry_node:put(N1Pid, FHex, "fallback_test_val"),
    {ok, "fallback_test_val", _} = pastry_node:get(N2Pid, FHex),
    io:format("Routing Assertion 3 passed: routed successfully around dropped link!~n"),

    %% Assertion 5: Verify link restoration and bidirectional state re-learning
    N1Pid ! {restore_link, N2Pid},
    timer:sleep(50),
    N1Pid ! {get_info, self()},
    receive
        {node_info, _, _, _, LS1, _} ->
            true = lists:keymember(N2Pid, 3, LS1)
    after 2000 ->
        error(restore_probe_timeout)
    end,
    io:format("Routing Assertion 4 passed: state healed and link restored successfully!~n"),
    
    %% Clean up test processes
    lists:foreach(fun({_Id, _Hex, Pid}) -> exit(Pid, kill) end, JoinedNodes),
    io:format("All routing and pastry unit tests passed successfully!~n"),
    ok.

join_test_nodes(0, _BPid, Acc) ->
    lists:reverse(Acc);
join_test_nodes(Remaining, BPid, Acc) ->
    pastry_node:start(self(), BPid, []),
    receive
        {join_complete, NewPid, NewId, NewHex} ->
            join_test_nodes(Remaining - 1, BPid, [{NewId, NewHex, NewPid} | Acc])
    after 10000 ->
        error(join_timeout)
    end.
