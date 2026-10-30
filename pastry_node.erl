-module(pastry_node).
-export([
    start/3,
    start_link/3,
    start_bootstrap/2,
    start_link_bootstrap/2,
    loop/1,
    put/3,
    put/4,
    get/2,
    get/3
]).

-define(MAINTENANCE_INTERVAL_MS, 3000).

-record(state, {
    id :: integer(),
    hex :: string(),
    leaf_set :: tuple(),
    routing_table :: map(),
    neighborhood_set :: list(),
    app_store :: map(),
    coordinator_pid :: pid(),
    alive = true :: boolean(),
    dropped_links = #{} :: map(),
    status = ready :: ready | joining,
    join_collected_nodes = [] :: list(),
    join_target_caller :: pid() | undefined,
    requests_remaining = 0 :: integer(),
    request_interval_ms = 1000 :: integer()
}).

%% Start a regular node that joins via a bootstrap node
start(CoordinatorPid, BootstrapPid, Opts) ->
    spawn(fun() -> init(CoordinatorPid, BootstrapPid, Opts) end).

start_link(CoordinatorPid, BootstrapPid, Opts) ->
    spawn_link(fun() -> init(CoordinatorPid, BootstrapPid, Opts) end).

%% Start the very first node (bootstrap node)
start_bootstrap(CoordinatorPid, Opts) ->
    spawn(fun() -> init_bootstrap(CoordinatorPid, Opts) end).

start_link_bootstrap(CoordinatorPid, Opts) ->
    spawn_link(fun() -> init_bootstrap(CoordinatorPid, Opts) end).

%% Client API for Object Access Service
put(NodePid, KeyHex, ValueStr) ->
    put(NodePid, KeyHex, ValueStr, 5000).

put(NodePid, KeyHex, ValueStr, Timeout) ->
    NodePid ! {app_put, KeyHex, ValueStr, self()},
    receive
        {put_reply, KeyHex, ok, DeliveringPid} ->
            {ok, DeliveringPid}
    after Timeout ->
        {error, timeout}
    end.

get(NodePid, KeyHex) ->
    get(NodePid, KeyHex, 5000).

get(NodePid, KeyHex, Timeout) ->
    NodePid ! {app_get, KeyHex, self()},
    receive
        {get_reply, KeyHex, Val, DeliveringPid} ->
            {ok, Val, DeliveringPid}
    after Timeout ->
        {error, timeout}
    end.

init_bootstrap(CoordinatorPid, _Opts) ->
    {Id, Hex} = pastry_util:random_id(),
    State = #state{
        id = Id,
        hex = Hex,
        leaf_set = pastry_util:new_leaf_set(),
        routing_table = pastry_util:new_routing_table(),
        neighborhood_set = [],
        app_store = #{},
        coordinator_pid = CoordinatorPid,
        alive = true,
        status = ready
    },
    CoordinatorPid ! {bootstrap_ready, self(), Id, Hex},
    erlang:send_after(?MAINTENANCE_INTERVAL_MS, self(), periodic_maintenance),
    loop(State).

init(CoordinatorPid, BootstrapPid, _Opts) ->
    {Id, Hex} = pastry_util:random_id(),
    State = #state{
        id = Id,
        hex = Hex,
        leaf_set = pastry_util:new_leaf_set(),
        routing_table = pastry_util:new_routing_table(),
        neighborhood_set = [],
        app_store = #{},
        coordinator_pid = CoordinatorPid,
        alive = true,
        status = joining,
        join_collected_nodes = [],
        join_target_caller = CoordinatorPid
    },
    %% Send join request to bootstrap node
    BootstrapPid ! {join_request, Id, Hex, self(), 0, []},
    erlang:send_after(?MAINTENANCE_INTERVAL_MS, self(), periodic_maintenance),
    loop(State).

loop(State) ->
    receive
        %%--------------------------------------------------------------------
        %% Node Join Protocol (Section 2.4)
        %%--------------------------------------------------------------------
        {join_request, XId, XHex, XPid, Hop, Visited} ->
            handle_join_request(XId, XHex, XPid, Hop, Visited, State),
            loop(State);

        {join_bootstrap_info, RowEntries, NeighborEntries, FromNode} ->
            NewCollected = [FromNode | RowEntries] ++ NeighborEntries ++ State#state.join_collected_nodes,
            loop(State#state{
                join_collected_nodes = NewCollected,
                neighborhood_set = [FromNode | NeighborEntries]
            });

        {join_hop_row, _RowIndex, RowEntries, FromNode} ->
            NewCollected = [FromNode | RowEntries] ++ State#state.join_collected_nodes,
            loop(State#state{join_collected_nodes = NewCollected});

        {join_final, LeafList, ZNode} ->
            NewState = finalize_join(LeafList, ZNode, State),
            loop(NewState);

        {node_joined, {CandId, CandHex, CandPid}} ->
            NewState = handle_node_joined(CandId, CandHex, CandPid, State),
            loop(NewState);

        %%--------------------------------------------------------------------
        %% Routing & Application API (Section 2.2 & 2.3)
        %%--------------------------------------------------------------------
        {route, Msg, KeyHex, KeyInt, Hops, Visited} ->
            NewState = handle_route(Msg, KeyHex, KeyInt, Hops, Visited, State),
            loop(NewState);

        %% Pastry API: route(msg, key) initiated by local node
        {api_route, Msg, KeyHex} ->
            KeyInt = pastry_util:hex_to_int(KeyHex),
            self() ! {route, Msg, KeyHex, KeyInt, 0, []},
            loop(State);

        %% Application Key-Value API (Object access service)
        {app_put, KeyHex, ValueStr} ->
            KeyInt = pastry_util:hex_to_int(KeyHex),
            Msg = {put, KeyHex, ValueStr, self()},
            self() ! {route, Msg, KeyHex, KeyInt, 0, []},
            loop(State);

        {app_put, KeyHex, ValueStr, RequesterPid} ->
            KeyInt = pastry_util:hex_to_int(KeyHex),
            Msg = {put, KeyHex, ValueStr, RequesterPid},
            self() ! {route, Msg, KeyHex, KeyInt, 0, []},
            loop(State);

        {app_get, KeyHex} ->
            KeyInt = pastry_util:hex_to_int(KeyHex),
            Msg = {get, KeyHex, self()},
            self() ! {route, Msg, KeyHex, KeyInt, 0, []},
            loop(State);

        {app_get, KeyHex, RequesterPid} ->
            KeyInt = pastry_util:hex_to_int(KeyHex),
            Msg = {get, KeyHex, RequesterPid},
            self() ! {route, Msg, KeyHex, KeyInt, 0, []},
            loop(State);

        {get_reply, _KeyHex, _Val, _DeliveringPid} ->
            loop(State);

        {put_reply, _KeyHex, _Status, _DeliveringPid} ->
            loop(State);

        %% Request Simulation Driver
        {start_requests, NumRequests, IntervalMs} ->
            NewState = State#state{
                requests_remaining = NumRequests,
                request_interval_ms = IntervalMs
            },
            %% Immediately send first request
            self() ! send_next_request,
            loop(NewState);

        send_next_request ->
            case State#state.requests_remaining > 0 of
                true ->
                    %% Generate a random 128-bit key for object access request
                    {_TargetId, TargetHex} = pastry_util:random_id(),
                    DataString = "Val-" ++ State#state.hex,
                    Msg = {put, TargetHex, DataString, self()},
                    TargetInt = pastry_util:hex_to_int(TargetHex),
                    self() ! {route, Msg, TargetHex, TargetInt, 0, []},
                    
                    %% Schedule next request after interval
                    Remaining = State#state.requests_remaining - 1,
                    case Remaining > 0 of
                        true ->
                            erlang:send_after(State#state.request_interval_ms, self(), send_next_request);
                        false ->
                            ok
                    end,
                    loop(State#state{requests_remaining = Remaining});
                false ->
                    loop(State)
            end;

        %%--------------------------------------------------------------------
        %% Failure Model & Fault Tolerance (Bonus: Node & Connection Failure)
        %%--------------------------------------------------------------------
        kill_node ->
            %% Node crash: actor terminates immediately
            exit(normal);

        {drop_link, TargetPid} ->
            NewDropped = maps:put(TargetPid, true, State#state.dropped_links),
            loop(State#state{dropped_links = NewDropped});

        {restore_link, TargetPid} ->
            NewDropped = maps:remove(TargetPid, State#state.dropped_links),
            case is_process_alive(TargetPid) of
                true ->
                    TargetPid ! {probe_restore, {State#state.id, State#state.hex, self()},
                                 pastry_util:leaf_set_to_list(State#state.leaf_set)};
                false ->
                    ok
            end,
            loop(State#state{dropped_links = NewDropped});

        {probe_restore, RemoteNode, RemoteLeafList} ->
            {_RId, _RHex, RPid} = RemoteNode,
            NewDropped = maps:remove(RPid, State#state.dropped_links),
            NewLS1 = pastry_util:add_to_leaf_set(State#state.leaf_set, RemoteNode, State#state.id),
            NewLS2 = pastry_util:add_all_to_leaf_set(NewLS1, RemoteLeafList, State#state.id),
            NewRT1 = pastry_util:add_to_routing_table(State#state.routing_table, RemoteNode, State#state.hex),
            NewRT2 = pastry_util:add_all_to_routing_table(NewRT1, RemoteLeafList, State#state.hex),
            RPid ! {probe_restore_reply, {State#state.id, State#state.hex, self()},
                    pastry_util:leaf_set_to_list(NewLS2)},
            loop(State#state{
                dropped_links = NewDropped,
                leaf_set = NewLS2,
                routing_table = NewRT2
            });

        {probe_restore_reply, RemoteNode, RemoteLeafList} ->
            {_RId, _RHex, RPid} = RemoteNode,
            NewDropped = maps:remove(RPid, State#state.dropped_links),
            NewLS1 = pastry_util:add_to_leaf_set(State#state.leaf_set, RemoteNode, State#state.id),
            NewLS2 = pastry_util:add_all_to_leaf_set(NewLS1, RemoteLeafList, State#state.id),
            NewRT1 = pastry_util:add_to_routing_table(State#state.routing_table, RemoteNode, State#state.hex),
            NewRT2 = pastry_util:add_all_to_routing_table(NewRT1, RemoteLeafList, State#state.hex),
            loop(State#state{
                dropped_links = NewDropped,
                leaf_set = NewLS2,
                routing_table = NewRT2
            });

        {request_leaf_set, RequesterPid} ->
            RequesterPid ! {leaf_set_response, pastry_util:leaf_set_to_list(State#state.leaf_set)},
            loop(State);

        {leaf_set_response, CandidateList} ->
            %% Leaf set repair response (Section 2.4)
            NewState = repair_integrate_leafs(CandidateList, State),
            loop(NewState);

        {request_routing_entry, Row, Col, RequesterPid} ->
            Entry = pastry_util:get_routing_entry(State#state.routing_table, Row, Col),
            RequesterPid ! {routing_entry_response, Row, Col, Entry},
            loop(State);

        {routing_entry_response, _Row, _Col, Entry} ->
            NewState = case Entry of
                {_CId, _CHex, CPid} ->
                    case is_alive_and_connected(CPid, State#state.dropped_links) of
                        true ->
                            NewRT = pastry_util:add_to_routing_table(State#state.routing_table, Entry, State#state.hex),
                            State#state{routing_table = NewRT};
                        false ->
                            State
                    end;
                _ ->
                    State
            end,
            loop(NewState);

        {ping, SenderPid} ->
            SenderPid ! {pong, self()},
            loop(State);

        {get_info, Caller} ->
            Caller ! {node_info, State#state.id, State#state.hex, true,
                      pastry_util:leaf_set_to_list(State#state.leaf_set),
                      pastry_util:routing_table_to_list(State#state.routing_table)},
            loop(State);

        periodic_maintenance ->
            CleanLeafSet = pastry_util:clean_leaf_set(State#state.leaf_set, State#state.dropped_links),
            CleanRT = pastry_util:clean_routing_table(State#state.routing_table, State#state.dropped_links),
            {LList, RList} = CleanLeafSet,
            %% Proactively trigger leaf repair if depleted or changed
            case length(LList) < 8 orelse length(RList) < 8 orelse CleanLeafSet /= State#state.leaf_set of
                true -> trigger_leaf_repair(CleanLeafSet, State#state.id);
                false -> ok
            end,
            erlang:send_after(?MAINTENANCE_INTERVAL_MS, self(), periodic_maintenance),
            loop(State#state{leaf_set = CleanLeafSet, routing_table = CleanRT});

        _Other ->
            loop(State)
    end.

%%--------------------------------------------------------------------
%% Internal Join Request Handling
%%--------------------------------------------------------------------
handle_join_request(XId, XHex, XPid, Hop, Visited, State) ->
    #state{
        id = SelfId,
        hex = SelfHex,
        leaf_set = LeafSet,
        routing_table = RoutingTable,
        neighborhood_set = NeighborhoodSet,
        dropped_links = DroppedLinks
    } = State,

    PrefixLen = pastry_util:shl(SelfHex, XHex),
    RowEntries = pastry_util:get_routing_row(RoutingTable, PrefixLen),
    SelfEntry = {SelfId, SelfHex, self()},

    if
        Hop == 0 ->
            XPid ! {join_bootstrap_info, RowEntries, NeighborhoodSet, SelfEntry};
        true ->
            XPid ! {join_hop_row, PrefixLen, RowEntries, SelfEntry}
    end,

    %% Determine if X is in range of our leaf set
    case pastry_util:is_in_leaf_range(XId, LeafSet, SelfId) of
        true ->
            {ClosestId, _ClosestHex, ClosestPid, _Dist} =
                pastry_util:closest_in_leaf_set(XId, LeafSet, SelfId, SelfHex, DroppedLinks),
            if
                ClosestId == SelfId ->
                    %% Destination reached: Self is numerically closest to X
                    XPid ! {join_final, pastry_util:leaf_set_to_list(LeafSet), SelfEntry};
                true ->
                    %% Forward to closer leaf node
                    ClosestPid ! {join_request, XId, XHex, XPid, Hop + 1, [SelfHex | Visited]}
            end;
        false ->
            %% Outside leaf set range: use routing table
            Col = pastry_util:char_to_digit(lists:nth(PrefixLen + 1, XHex)),
            case pastry_util:get_routing_entry(RoutingTable, PrefixLen, Col) of
                {TargetId, _TargetHex, TargetPid} when TargetId /= SelfId ->
                    case is_alive_and_connected(TargetPid, DroppedLinks) of
                        true ->
                            TargetPid ! {join_request, XId, XHex, XPid, Hop + 1, [SelfHex | Visited]};
                        false ->
                            fallback_join(XId, XHex, XPid, Hop, Visited, State, SelfEntry)
                    end;
                _ ->
                    fallback_join(XId, XHex, XPid, Hop, Visited, State, SelfEntry)
            end
    end.

fallback_join(XId, XHex, XPid, Hop, Visited, State, SelfEntry) ->
    #state{routing_table = RT, leaf_set = LS, neighborhood_set = NS, hex = SelfHex, id = SelfId, dropped_links = DL} = State,
    case pastry_util:find_fallback_node(RT, LS, NS, XHex, XId, SelfHex, SelfId, DL) of
        {FbId, _FbHex, FbPid} when FbId /= SelfId ->
            FbPid ! {join_request, XId, XHex, XPid, Hop + 1, [SelfHex | Visited]};
        _ ->
            XPid ! {join_final, pastry_util:leaf_set_to_list(LS), SelfEntry}
    end.

%%--------------------------------------------------------------------
%% Finalizing Join
%%--------------------------------------------------------------------
finalize_join(LeafList, ZNode, State) ->
    #state{
        id = SelfId,
        hex = SelfHex,
        join_collected_nodes = Collected,
        join_target_caller = CoordinatorPid
    } = State,

    AllKnownNodes = [ZNode | LeafList] ++ Collected,

    %% Build initial leaf set and routing table
    InitialLeafSet = pastry_util:add_all_to_leaf_set(pastry_util:new_leaf_set(), [ZNode | LeafList], SelfId),
    InitialRoutingTable = pastry_util:add_all_to_routing_table(pastry_util:new_routing_table(), AllKnownNodes, SelfHex),
    
    %% Populate neighborhood set with proximate peers discovered along join path (Section 2.4)
    NeighborhoodCandidates = lists:usort(State#state.neighborhood_set ++ [ZNode | Collected]),
    InitialNeighborhood = lists:sublist([N || N = {NId, _, NPid} <- NeighborhoodCandidates, NId /= SelfId, is_process_alive(NPid)], 16),

    %% Notify all nodes in leaf set, routing table, and neighborhood set
    NodesToNotify = lists:usort(
        pastry_util:leaf_set_to_list(InitialLeafSet) ++
        pastry_util:routing_table_to_list(InitialRoutingTable) ++
        InitialNeighborhood
    ),

    SelfInfo = {SelfId, SelfHex, self()},
    lists:foreach(
        fun({_NId, _NHex, NPid}) ->
            case is_process_alive(NPid) of
                true -> NPid ! {node_joined, SelfInfo};
                false -> ok
            end
        end,
        NodesToNotify
    ),

    app_new_leafs(InitialLeafSet),

    case CoordinatorPid of
        undefined -> ok;
        Pid -> Pid ! {join_complete, self(), SelfId, SelfHex}
    end,

    State#state{
        leaf_set = InitialLeafSet,
        routing_table = InitialRoutingTable,
        neighborhood_set = InitialNeighborhood,
        status = ready,
        join_collected_nodes = []
    }.

handle_node_joined(CandId, CandHex, CandPid, State) ->
    #state{
        id = SelfId,
        hex = SelfHex,
        leaf_set = LeafSet,
        routing_table = RoutingTable
    } = State,

    Candidate = {CandId, CandHex, CandPid},
    NewLeafSet = pastry_util:add_to_leaf_set(LeafSet, Candidate, SelfId),
    case NewLeafSet /= LeafSet of
        true -> app_new_leafs(NewLeafSet);
        false -> ok
    end,

    NewRoutingTable = pastry_util:add_to_routing_table(RoutingTable, Candidate, SelfHex),
    State#state{
        leaf_set = NewLeafSet,
        routing_table = NewRoutingTable
    }.

%%--------------------------------------------------------------------
%% Routing Logic (Section 2.2 with Fault Tolerance & State Repair)
%%--------------------------------------------------------------------
handle_route(Msg, KeyHex, KeyInt, Hops, Visited, State) ->
    #state{
        id = SelfId,
        hex = SelfHex,
        leaf_set = LeafSet,
        routing_table = RoutingTable,
        dropped_links = DroppedLinks
    } = State,

    %% Clean dead/disconnected nodes from leaf set and routing table
    CleanLeafSet = pastry_util:clean_leaf_set(LeafSet, DroppedLinks),
    CleanRT = pastry_util:clean_routing_table(RoutingTable, DroppedLinks),
    
    %% Trigger background leaf repair if any leaf nodes died
    case CleanLeafSet /= LeafSet of
        true -> trigger_leaf_repair(CleanLeafSet, SelfId);
        false -> ok
    end,

    UpdatedState = State#state{leaf_set = CleanLeafSet, routing_table = CleanRT},

    case lists:member(SelfHex, Visited) of
        true ->
            %% Loop protection: deliver directly
            deliver(Msg, KeyHex, KeyInt, Hops, UpdatedState);
        false ->
            case pastry_util:is_in_leaf_range(KeyInt, CleanLeafSet, SelfId) of
                true ->
                    {ClosestId, ClosestHex, ClosestPid, _Dist} =
                        pastry_util:closest_in_leaf_set(KeyInt, CleanLeafSet, SelfId, SelfHex, DroppedLinks),
                    if
                        ClosestId == SelfId ->
                            deliver(Msg, KeyHex, KeyInt, Hops, UpdatedState);
                        true ->
                            case is_alive_and_connected(ClosestPid, DroppedLinks) of
                                true ->
                                    app_forward(Msg, KeyHex, ClosestHex),
                                    ClosestPid ! {route, Msg, KeyHex, KeyInt, Hops + 1, [SelfHex | Visited]},
                                    UpdatedState;
                                false ->
                                    reroute_fallback(Msg, KeyHex, KeyInt, Hops, Visited, UpdatedState)
                            end
                    end;
                false ->
                    %% Routing table lookup
                    PrefixLen = pastry_util:shl(SelfHex, KeyHex),
                    Col = pastry_util:char_to_digit(lists:nth(PrefixLen + 1, KeyHex)),
                    Entry = pastry_util:get_routing_entry(CleanRT, PrefixLen, Col),
                    case Entry of
                        {TargetId, TargetHex, TargetPid} when TargetId /= SelfId ->
                            case is_alive_and_connected(TargetPid, DroppedLinks) of
                                true ->
                                    app_forward(Msg, KeyHex, TargetHex),
                                    TargetPid ! {route, Msg, KeyHex, KeyInt, Hops + 1, [SelfHex | Visited]},
                                    UpdatedState;
                                false ->
                                    trigger_routing_repair(CleanRT, PrefixLen, Col, DroppedLinks),
                                    reroute_fallback(Msg, KeyHex, KeyInt, Hops, Visited, UpdatedState)
                            end;
                        _ ->
                            trigger_routing_repair(CleanRT, PrefixLen, Col, DroppedLinks),
                            reroute_fallback(Msg, KeyHex, KeyInt, Hops, Visited, UpdatedState)
                    end
            end
    end.

reroute_fallback(Msg, KeyHex, KeyInt, Hops, Visited, State) ->
    #state{
        id = SelfId,
        hex = SelfHex,
        leaf_set = LeafSet,
        routing_table = RoutingTable,
        neighborhood_set = NeighborhoodSet,
        dropped_links = DroppedLinks
    } = State,
    case pastry_util:find_fallback_node(RoutingTable, LeafSet, NeighborhoodSet, KeyHex, KeyInt, SelfHex, SelfId, DroppedLinks) of
        {FbId, FbHex, FbPid} when FbId /= SelfId ->
            case is_alive_and_connected(FbPid, DroppedLinks) of
                true ->
                    app_forward(Msg, KeyHex, FbHex),
                    FbPid ! {route, Msg, KeyHex, KeyInt, Hops + 1, [SelfHex | Visited]},
                    State;
                false ->
                    deliver(Msg, KeyHex, KeyInt, Hops, State)
            end;
        _ ->
            deliver(Msg, KeyHex, KeyInt, Hops, State)
    end.

is_alive_and_connected(Pid, DroppedLinks) ->
    is_pid(Pid) andalso is_process_alive(Pid) andalso not maps:is_key(Pid, DroppedLinks).

%%--------------------------------------------------------------------
%% Failure Recovery Mechanisms (Section 2.4 - Leaf Set & Routing Repair)
%%--------------------------------------------------------------------
trigger_leaf_repair({LeftLeafs, RightLeafs}, _SelfId) ->
    %% Contact furthest live leaf nodes to request leaf sets
    case RightLeafs of
        [] -> ok;
        _ ->
            {_, _, RPid} = lists:last(RightLeafs),
            case is_process_alive(RPid) of
                true -> RPid ! {request_leaf_set, self()};
                false -> ok
            end
    end,
    case LeftLeafs of
        [] -> ok;
        _ ->
            {_, _, LPid} = lists:last(LeftLeafs),
            case is_process_alive(LPid) of
                true -> LPid ! {request_leaf_set, self()};
                false -> ok
            end
    end,
    ok.

trigger_routing_repair(RoutingTable, PrefixLen, MissingCol, DroppedLinks) ->
    %% Find alternative live peers in the same row (Section 2.4)
    RowEntries = [E || E = {_, _, Pid} <- pastry_util:get_routing_row(RoutingTable, PrefixLen),
                       is_alive_and_connected(Pid, DroppedLinks)],
    case RowEntries of
        [] -> ok;
        [First | _] ->
            {_, _, PeerPid} = First,
            PeerPid ! {request_routing_entry, PrefixLen, MissingCol, self()}
    end.

repair_integrate_leafs(CandidateList, State) ->
    #state{id = SelfId, leaf_set = LeafSet, dropped_links = Dropped} = State,
    LiveCandidates = [C || {_, _, CPid} = C <- CandidateList, is_alive_and_connected(CPid, Dropped)],
    NewLeafSet = pastry_util:add_all_to_leaf_set(LeafSet, LiveCandidates, SelfId),
    State#state{leaf_set = NewLeafSet}.

%%--------------------------------------------------------------------
%% Application API Callbacks (Section 2.3)
%%--------------------------------------------------------------------
deliver(Msg, KeyHex, _KeyInt, Hops, State) ->
    #state{
        app_store = AppStore,
        coordinator_pid = CoordinatorPid
    } = State,
    case Msg of
        {put, KeyHex, ValueStr, RequesterPid} ->
            NewAppStore = maps:put(KeyHex, ValueStr, AppStore),
            case is_pid(RequesterPid) of
                true -> RequesterPid ! {put_reply, KeyHex, ok, self()};
                false -> ok
            end,
            case CoordinatorPid of
                undefined -> ok;
                CPid when CPid /= RequesterPid -> CPid ! {request_delivered, self(), KeyHex, Hops};
                _ -> ok
            end,
            State#state{app_store = NewAppStore};
        {get, KeyHex, RequesterPid} ->
            Val = maps:get(KeyHex, AppStore, undefined),
            case is_pid(RequesterPid) of
                true -> RequesterPid ! {get_reply, KeyHex, Val, self()};
                false -> ok
            end,
            case CoordinatorPid of
                undefined -> ok;
                CPid when CPid /= RequesterPid -> CPid ! {request_delivered, self(), KeyHex, Hops};
                _ -> ok
            end,
            State;
        _Other ->
            case CoordinatorPid of
                undefined -> ok;
                CPid -> CPid ! {request_delivered, self(), KeyHex, Hops}
            end,
            State
    end.

%% Pastry Application API Upcall: forward(Msg, Key, NextHopId) (Section 2.3)
%% Invoked before a message is forwarded to the next hop.
app_forward(_Msg, _KeyHex, _NextHopHex) ->
    ok.

%% Pastry Application API Upcall: newLeafs(LeafSet) (Section 2.3)
%% Invoked when the node's leaf set changes.
app_new_leafs(_LeafSet) ->
    ok.
