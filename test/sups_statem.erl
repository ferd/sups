-module(sups_statem).
-include_lib("proper/include/proper.hrl").
-compile(export_all).
-define(APPS, [sups]).

initial_state() -> undefined.

command(undefined) ->
    {call, sups_lib, init_state, [?APPS]};
command(State) ->
    oneof([
        {call, sups_lib, mock_success,
         [State, fun mock_db_call/0, fun unmock_db_call/0, ?APPS]},
        {call, sups_lib, mark_as_dead,
         [State, non_neg_integer(), [{not_tagged, db}], ?APPS]}
    ]).

precondition(undefined, {call, _, init_state, _}) ->
    true;
precondition(State, {call, _, mock_success, _}) when State =/= undefined ->
    true;
precondition(State, {call, _, mark_as_dead, _}) when State =/= undefined ->
    true;
precondition(_, _) ->
    false.

postcondition(_, {call, _, init_state, _}, _Apptree) ->
    true;
postcondition({OldTree, _Deaths}, {call, _, mark_as_dead, _}, {NewTree,NewDeaths}) ->
    sups_lib:validate_mark_as_dead(OldTree, NewTree, NewDeaths);
postcondition({OldTree, _Deaths}, {call, _, mock_success, _}, {NewTree,NewDeaths}) ->
    sups_lib:validate_mock_success(OldTree, NewTree, NewDeaths).

next_state(undefined, NewState, {call, _, init_state, _}) ->
    NewState;
next_state(_State, NewState, {call, _, mock_success, _}) ->
    NewState;
next_state(_State, NewState, {call, _, mark_as_dead, _}) ->
    NewState.


%% This is actually using a stub because the demo didn't quite like me flipping
%% the switch super hard on a central process through meck and lotsa code loading.
mock_db_call() ->
    gen_server:call(sups_db_worker, disconnect, infinity),
    100.

unmock_db_call() ->
    gen_server:call(sups_db_worker, connect, infinity),
    ok.
