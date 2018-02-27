-module(sups_statem).
-include_lib("proper/include/proper.hrl").
-compile(export_all).
-define(APPS, [sups]).

initial_state() -> undefined.

command(undefined) ->
    {call, sups_lib, find_supervisors, [?APPS]};
command(State) ->
    oneof([
        {call, sups_lib, mock_success, [State, fun mock_db_call/0, fun unmock_db_call/0, ?APPS]},
        {call, sups_lib, mark_as_dead, [State, non_neg_integer(), ?APPS]}
    ]).

precondition(undefined, {call, _, find_supervisors, _}) ->
    true;
precondition(State, {call, _, mock_success, _}) when State =/= undefined ->
    true;
precondition(State, {call, _, mark_as_dead, _}) when State =/= undefined ->
    true;
precondition(_, _) ->
    false.

postcondition(_, {call, _, find_supervisors, _}, _Apptree) ->
    true;
    %Apptree =/= [];
postcondition({OldTree, _Deaths}, {call, _, mark_as_dead, _}, {NewTree,NewDeaths}) ->
    MustBeMissing = sups_lib:extract_dead(NewDeaths),
    Res = sups_lib:unexpected_not_in_tree(NewTree, MustBeMissing)
    andalso sups_lib:sups_still_living(OldTree, NewTree, MustBeMissing),
    case Res of
        true -> true;
        false ->
            io:format("res: ~p andalso ~p~n", [sups_lib:unexpected_not_in_tree(NewTree, MustBeMissing),
                                               sups_lib:sups_still_living(OldTree, NewTree, MustBeMissing)]),
            io:format("Old: ~p~n"
                      "New: ~p~n"
                      "Dead: ~p~n",
                      [OldTree, NewTree, sets:to_list(MustBeMissing)]),
            false
    end;
postcondition({OldTree, _Deaths}, {call, _, mock_success, _}, {NewTree,NewDeaths}) ->
    %% Should not see any deaths on a successful call.
    MustBeMissing = sups_lib:extract_dead(NewDeaths),
    sups_lib:sups_still_living(OldTree, NewTree, MustBeMissing).

next_state(undefined, AppTree, {call, _, find_supervisors, _}) ->
    {AppTree, []};
next_state(_State, NewState, {call, _, mock_success, _}) ->
    NewState;
next_state(_State, NewState, {call, _, mark_as_dead, _}) ->
    NewState.


mock_db_call() ->
    meck:expect(sups_db_worker, req, fun(_,_) -> {error, disconnected} end),
    ok.

unmock_db_call() ->
    meck:delete(sups_db_worker, req, 2, false),
    ok.
