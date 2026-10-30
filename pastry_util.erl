-module(pastry_util).
-export([
    random_id/0,
    int_to_hex/1,
    hex_to_int/1,
    dist/2,
    cw_dist/2,
    ccw_dist/2,
    is_clockwise/2,
    shl/2,
    char_to_digit/1,
    digit_to_char/1,
    
    %% Leaf set functions
    new_leaf_set/0,
    add_to_leaf_set/3,
    add_all_to_leaf_set/3,
    clean_leaf_set/2,
    is_in_leaf_range/3,
    closest_in_leaf_set/4,
    closest_in_leaf_set/5,
    leaf_set_to_list/1,
    
    %% Routing table functions
    new_routing_table/0,
    add_to_routing_table/3,
    add_all_to_routing_table/3,
    clean_routing_table/2,
    get_routing_entry/3,
    get_routing_row/2,
    routing_table_to_list/1,
    find_fallback_node/6,
    find_fallback_node/7,
    find_fallback_node/8,
    max_space/0,
    build_closest_checker/1,
    is_closest_node/3
]).

%% 128-bit space constants
-define(BITS, 128).
-define(DIGITS, 32).
-define(BASE_B, 4). %% 2^4 = 16 (hex)
-define(MAX_SPACE, 340282366920938463463374607431768211456). %% 2^128
-define(HALF_SPACE, 170141183460469231731687303715884105728). %% 2^127
-define(LEAF_SET_L, 16).
-define(LEAF_SET_HALF, 8).

%%--------------------------------------------------------------------
%% ID generation and conversion
%%--------------------------------------------------------------------
random_id() ->
    <<Int:?BITS>> = crypto:strong_rand_bytes(16),
    Hex = int_to_hex(Int),
    {Int, Hex}.

int_to_hex(Int) when is_integer(Int) ->
    lists:flatten(io_lib:format("~32.16.0b", [Int])).

hex_to_int(Hex) when is_list(Hex) ->
    list_to_integer(Hex, 16).

%%--------------------------------------------------------------------
%% Distance calculations in 128-bit circular space
%%--------------------------------------------------------------------
dist(Id1, Id2) ->
    Diff = abs(Id1 - Id2),
    case Diff > ?HALF_SPACE of
        true -> ?MAX_SPACE - Diff;
        false -> Diff
    end.

cw_dist(FromId, ToId) ->
    (ToId - FromId + ?MAX_SPACE) rem ?MAX_SPACE.

ccw_dist(FromId, ToId) ->
    (FromId - ToId + ?MAX_SPACE) rem ?MAX_SPACE.

is_clockwise(CandId, SelfId) ->
    cw_dist(SelfId, CandId) < ccw_dist(SelfId, CandId).

%%--------------------------------------------------------------------
%% Prefix length (shl) and digit conversions
%%--------------------------------------------------------------------
shl([], _) -> 0;
shl(_, []) -> 0;
shl([C | R1], [C | R2]) -> 1 + shl(R1, R2);
shl(_, _) -> 0.

char_to_digit(C) when C >= $0 andalso C =< $9 -> C - $0;
char_to_digit(C) when C >= $a andalso C =< $f -> C - $a + 10;
char_to_digit(C) when C >= $A andalso C =< $F -> C - $A + 10.

digit_to_char(D) when D >= 0 andalso D =< 9 -> D + $0;
digit_to_char(D) when D >= 10 andalso D =< 15 -> D - 10 + $a.

%%--------------------------------------------------------------------
%% Leaf Set: {LeftLeafs, RightLeafs}
%% LeftLeafs: CCW nodes sorted by ccw_dist ascending (closest first)
%% RightLeafs: CW nodes sorted by cw_dist ascending (closest first)
%%--------------------------------------------------------------------
new_leaf_set() ->
    {[], []}.

leaf_set_to_list({LeftLeafs, RightLeafs}) ->
    LeftLeafs ++ RightLeafs.

clean_leaf_set({LeftLeafs, RightLeafs}, DroppedLinks) ->
    Filter = fun({_Id, _Hex, Pid}) ->
        is_pid(Pid) andalso is_process_alive(Pid) andalso not maps:is_key(Pid, DroppedLinks)
    end,
    {lists:filter(Filter, LeftLeafs), lists:filter(Filter, RightLeafs)}.

add_to_leaf_set({LeftLeafs, RightLeafs}, {CandId, CandHex, CandPid}, SelfId) ->
    if
        CandId == SelfId ->
            {LeftLeafs, RightLeafs};
        true ->
            case is_clockwise(CandId, SelfId) of
                true ->
                    %% Belongs in RightLeafs (clockwise)
                    L1 = lists:keydelete(CandId, 1, LeftLeafs),
                    R1 = lists:keydelete(CandId, 1, RightLeafs),
                    NewR = lists:sort(
                        fun({IdA, _, _}, {IdB, _, _}) ->
                            cw_dist(SelfId, IdA) =< cw_dist(SelfId, IdB)
                        end,
                        [{CandId, CandHex, CandPid} | R1]
                    ),
                    TrimmedR = lists:sublist(NewR, ?LEAF_SET_HALF),
                    {L1, TrimmedR};
                false ->
                    %% Belongs in LeftLeafs (counter-clockwise)
                    L1 = lists:keydelete(CandId, 1, LeftLeafs),
                    R1 = lists:keydelete(CandId, 1, RightLeafs),
                    NewL = lists:sort(
                        fun({IdA, _, _}, {IdB, _, _}) ->
                            ccw_dist(SelfId, IdA) =< ccw_dist(SelfId, IdB)
                        end,
                        [{CandId, CandHex, CandPid} | L1]
                    ),
                    TrimmedL = lists:sublist(NewL, ?LEAF_SET_HALF),
                    {TrimmedL, R1}
            end
    end.

add_all_to_leaf_set(LeafSet, [], _SelfId) ->
    LeafSet;
add_all_to_leaf_set(LeafSet, [Node | Rest], SelfId) ->
    NewLeafSet = add_to_leaf_set(LeafSet, Node, SelfId),
    add_all_to_leaf_set(NewLeafSet, Rest, SelfId).

%% Check if key is covered by the leaf set
is_in_leaf_range(_KeyInt, {[], []}, _SelfId) ->
    true;
is_in_leaf_range(_KeyInt, {LeftLeafs, RightLeafs}, _SelfId)
  when length(LeftLeafs) < ?LEAF_SET_HALF andalso length(RightLeafs) < ?LEAF_SET_HALF ->
    %% Small network or early in initialization: leaf set contains all nodes
    true;
is_in_leaf_range(KeyInt, {LeftLeafs, RightLeafs}, SelfId) ->
    MinCCW = case LeftLeafs of
        [] -> SelfId;
        _ ->
            {LastLId, _, _} = lists:last(LeftLeafs),
            LastLId
    end,
    MaxCW = case RightLeafs of
        [] -> SelfId;
        _ ->
            {LastRId, _, _} = lists:last(RightLeafs),
            LastRId
    end,
    ArcLen = cw_dist(MinCCW, MaxCW),
    KeyLen = cw_dist(MinCCW, KeyInt),
    KeyLen =< ArcLen.

closest_in_leaf_set(KeyInt, LeafSet, SelfId, SelfHex) ->
    closest_in_leaf_set(KeyInt, LeafSet, SelfId, SelfHex, #{}).

closest_in_leaf_set(KeyInt, {LeftLeafs, RightLeafs}, SelfId, SelfHex, DroppedLinks) ->
    AllNodes = [{SelfId, SelfHex, self()} | LeftLeafs ++ RightLeafs],
    LiveNodes = lists:filter(
        fun({_NId, _NHex, NPid}) ->
            is_pid(NPid) andalso is_process_alive(NPid) andalso not maps:is_key(NPid, DroppedLinks)
        end,
        AllNodes
    ),
    lists:foldl(
        fun({NId, NHex, NPid}, {BestId, BestHex, BestPid, BestDist}) ->
            D = dist(KeyInt, NId),
            if
                D < BestDist -> {NId, NHex, NPid, D};
                true -> {BestId, BestHex, BestPid, BestDist}
            end
        end,
        {SelfId, SelfHex, self(), dist(KeyInt, SelfId)},
        LiveNodes
    ).

%%--------------------------------------------------------------------
%% Routing Table: Map #{ {Row, Col} => {Id, Hex, Pid} }
%%--------------------------------------------------------------------
new_routing_table() ->
    #{}.

clean_routing_table(Table, DroppedLinks) ->
    maps:filter(
        fun(_Key, {_Id, _Hex, Pid}) ->
            is_pid(Pid) andalso is_process_alive(Pid) andalso not maps:is_key(Pid, DroppedLinks)
        end,
        Table
    ).

add_to_routing_table(Table, {CandId, CandHex, CandPid}, SelfHex) ->
    case CandHex == SelfHex of
        true ->
            Table;
        false ->
            Row = shl(SelfHex, CandHex),
            if
                Row >= ?DIGITS ->
                    Table;
                true ->
                    Col = char_to_digit(lists:nth(Row + 1, CandHex)),
                    maps:put({Row, Col}, {CandId, CandHex, CandPid}, Table)
            end
    end.

add_all_to_routing_table(Table, [], _SelfHex) ->
    Table;
add_all_to_routing_table(Table, [Node | Rest], SelfHex) ->
    NewTable = add_to_routing_table(Table, Node, SelfHex),
    add_all_to_routing_table(NewTable, Rest, SelfHex).

get_routing_entry(Table, Row, Col) ->
    maps:get({Row, Col}, Table, undefined).

get_routing_row(Table, Row) ->
    [Entry || {{R, _Col}, Entry} <- maps:to_list(Table), R == Row].

routing_table_to_list(Table) ->
    maps:values(Table).

%%--------------------------------------------------------------------
%% Fallback routing rule (Section 2.2):
%% Search across L U R U M for any node T such that:
%% shl(T, Key) >= PrefixLen AND dist(T, Key) < dist(Self, Key)
%%--------------------------------------------------------------------
find_fallback_node(RoutingTable, LeafSet, KeyHex, KeyInt, SelfHex, SelfInt) ->
    find_fallback_node(RoutingTable, LeafSet, [], KeyHex, KeyInt, SelfHex, SelfInt, #{}).

find_fallback_node(RoutingTable, LeafSet, KeyHex, KeyInt, SelfHex, SelfInt, DroppedLinks) ->
    find_fallback_node(RoutingTable, LeafSet, [], KeyHex, KeyInt, SelfHex, SelfInt, DroppedLinks).

find_fallback_node(RoutingTable, LeafSet, NeighborhoodSet, KeyHex, KeyInt, SelfHex, SelfInt, DroppedLinks) ->
    LNodes = leaf_set_to_list(LeafSet),
    RNodes = routing_table_to_list(RoutingTable),
    AllCandidates = lists:usort(LNodes ++ RNodes ++ NeighborhoodSet),
    CurrentPrefixLen = shl(SelfHex, KeyHex),
    CurrentDist = dist(SelfInt, KeyInt),
    
    FilterFun = fun({TId, THex, TPid}) ->
        (shl(THex, KeyHex) >= CurrentPrefixLen) andalso
        (dist(TId, KeyInt) < CurrentDist) andalso
        is_pid(TPid) andalso is_process_alive(TPid) andalso not maps:is_key(TPid, DroppedLinks)
    end,
    ValidCandidates = lists:filter(FilterFun, AllCandidates),
    case ValidCandidates of
        [] ->
            undefined;
        _ ->
            Best = lists:foldl(
                fun({TId, THex, TPid}, {BId, BHex, BPid, BDist}) ->
                    D = dist(TId, KeyInt),
                    if
                        D < BDist -> {TId, THex, TPid, D};
                        true -> {BId, BHex, BPid, BDist}
                    end
                end,
                {0, "", undefined, ?MAX_SPACE},
                ValidCandidates
            ),
            {BestId, BestHex, BestPid, _} = Best,
            {BestId, BestHex, BestPid}
    end.

max_space() ->
    ?MAX_SPACE.

%%--------------------------------------------------------------------
%% Fast O(log N) Closest Node Verification (Item 4)
%% Precomputes sorted IDs for circular binary search.
%%--------------------------------------------------------------------
build_closest_checker(Nodes) ->
    PidToId = maps:from_list([{Pid, Id} || {Id, _, Pid} <- Nodes]),
    SortedIds = lists:sort([Id || {Id, _, _} <- Nodes]),
    Tuple = list_to_tuple(SortedIds),
    Size = tuple_size(Tuple),
    {PidToId, Tuple, Size}.

is_closest_node(KeyHex, DeliveringPid, {PidToId, Tuple, Size}) ->
    KeyInt = hex_to_int(KeyHex),
    TrueClosestId = find_closest_id(KeyInt, Tuple, Size),
    TrueMinDist = dist(KeyInt, TrueClosestId),
    case maps:find(DeliveringPid, PidToId) of
        {ok, DelivId} ->
            dist(KeyInt, DelivId) == TrueMinDist;
        error ->
            false
    end.

find_closest_id(KeyInt, SortedTuple, Size) ->
    case Size of
        1 ->
            element(1, SortedTuple);
        _ ->
            First = element(1, SortedTuple),
            Last = element(Size, SortedTuple),
            if
                KeyInt =< First orelse KeyInt >= Last ->
                    choose_closer(KeyInt, First, Last);
                true ->
                    {Pred, Succ} = bsearch_neighbors(KeyInt, SortedTuple, 1, Size),
                    choose_closer(KeyInt, Pred, Succ)
            end
    end.

choose_closer(KeyInt, Id1, Id2) ->
    D1 = dist(KeyInt, Id1),
    D2 = dist(KeyInt, Id2),
    if
        D1 =< D2 -> Id1;
        true -> Id2
    end.

bsearch_neighbors(_KeyInt, Tuple, Low, High) when Low + 1 == High ->
    {element(Low, Tuple), element(High, Tuple)};
bsearch_neighbors(KeyInt, Tuple, Low, High) ->
    Mid = (Low + High) div 2,
    MidVal = element(Mid, Tuple),
    if
        MidVal =< KeyInt ->
            bsearch_neighbors(KeyInt, Tuple, Mid, High);
        true ->
            bsearch_neighbors(KeyInt, Tuple, Low, Mid)
    end.
