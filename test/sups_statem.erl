-module(sups_statem).
-include_lib("proper/include/proper.hrl").
-export([find_supervisors/0, find_supervisors/1, mark_as_dead/3]).
-compile(export_all).
-define(APPS, [sups]).

% {modprote, [{permanent,
%     {one_for_one,<0.170.0>,
%         {5,60},
%         [{permanent,{worker,<0.207.0>}},
%          {permanent,{worker,<0.206.0>}},
%          {temporary,
%              {one_for_one,<0.199.0>,
%                  {5,60},
%                  [{permanent,{worker,<0.205.0>}},
%                   {permanent,{worker,<0.200.0>}}]}},
%          {permanent,{simple_one_for_one,<0.182.0>,{5,60},[]}},
%          {permanent,
%              {one_for_all,<0.171.0>,
%                  {5,60},
%                  [{permanent,
%                       {one_for_one,<0.173.0>,
%                           {10,30},
%                           [{permanent,{worker,<0.180.0>}},
%                            {permanent,{worker,<0.179.0>}},
%                            {permanent,{worker,<0.178.0>}},
%                            {permanent,{worker,<0.176.0>}},
%                            {permanent,{worker,<0.175.0>}},
%                            {permanent,{worker,<0.174.0>}}]}},
%                   {permanent,{worker,<0.172.0>}}]}}]}},

-type strategy() :: one_for_one | simple_one_for_one | rest_for_one | one_for_all.
-type intensity() :: non_neg_integer().
-type period() :: pos_integer().
-type restart() :: permanent | transient | temporary. 
-type worker() :: {worker | non_otp_sup, pid()}.
-type sup() :: {strategy(), pid(), {intensity(), period()}, [suptree()]}.
-type suptree() :: [{restart(), worker() | sup()}].
-type app() :: atom().
-type apptree() :: [{app(), [suptree()]}].

%-type model() :: {apptree(), [{dead | child_dead, supervisor_pid(), stamp()}]}.
-export_type([apptree/0]).

initial_state() -> undefined.

command(undefined) ->
    {call, ?MODULE, find_supervisors, [?APPS]};
command(State) ->
    oneof([
       %{call, ?MODULE, mock_failure, [type_of_generation()]},
        {call, ?MODULE, mark_as_dead, [State, non_neg_integer(), ?APPS]}
    ]).

precondition(undefined, {call, _, find_supervisors, _}) ->
    true;
precondition(State, {call, _, mark_as_dead, _}) when State =/= undefined ->
    true;
precondition(_, _) ->
    false.

postcondition(_, {call, _, find_supervisors, _}, _Apptree) ->
    true;
    %Apptree =/= [];
postcondition({OldTree, _Deaths}, {call, _, mark_as_dead, _}, {NewTree,NewDeaths}) ->
    MustBeMissing = extract_dead(NewDeaths),
    Res = unexpected_not_in_tree(NewTree, MustBeMissing)
    andalso sups_still_living(OldTree, NewTree, MustBeMissing),
    case Res of
        true -> true;
        false ->
            io:format("res: ~p andalso ~p~n", [unexpected_not_in_tree(NewTree, MustBeMissing),
                                               sups_still_living(OldTree, NewTree, MustBeMissing)]),
            io:format("Old: ~p~n"
                      "New: ~p~n"
                      "Dead: ~p~n",
                      [OldTree, NewTree, sets:to_list(MustBeMissing)]),
            false
    end;
postcondition({OldTree, _Deaths}, {call, _, simulate_failure, _}, NewTree) ->
    sups_still_living(OldTree, NewTree, sets:new()).

next_state(undefined, AppTree, {call, _, find_supervisors, _}) ->
    {AppTree, []};
next_state(_State, NewState, {call, _, mark_as_dead, _}) ->
    NewState.

extract_dead(List) -> sets:from_list([Pid || {dead, Pid, _} <- List]).

unexpected_not_in_tree([], _) -> true;
unexpected_not_in_tree([{_Restart, noproc} | T], Set) ->
    unexpected_not_in_tree(T, Set);
unexpected_not_in_tree([{_Restart, {_Type, Pid}} | T], Set) ->
    (not sets:is_element(Pid, Set)) andalso unexpected_not_in_tree(T, Set);
unexpected_not_in_tree([{_Restart, {_, Pid, _, Children}} | T], Set) ->
    (not sets:is_element(Pid, Set))
    andalso unexpected_not_in_tree(Children, Set)
    andalso unexpected_not_in_tree(T, Set);
unexpected_not_in_tree([{_App, Sup}|T], Set) when is_list(Sup) ->
    unexpected_not_in_tree(Sup, Set) andalso unexpected_not_in_tree(T, Set).

sups_still_living(Old, New, ShouldBeDead) ->
    OldSupPids = supervisor_pids(Old),
    NewSupPids = supervisor_pids(New),
    MustLive = OldSupPids -- sets:to_list(ShouldBeDead),
    lists:all(fun(Pid) -> lists:member(Pid, NewSupPids) end, MustLive).

mark_as_dead({Tree, Deaths}, N, Whitelist) when is_list(Tree) ->
    %% 1. find how many procs are in the tree,
    M = count_procs(Tree),
    mark_as_dead({Tree, Deaths}, N, M, Whitelist).

mark_as_dead(State, _, 0, _) ->
    io:format("Null case, supervisor tree is gone or only root left~n", []),
    State;
mark_as_dead({Tree, Deaths}, N, Count, Whitelist) ->
    M = Count-1,
    %% 2. mark them with numbers 0..M based on position (implicit)
    %% 3. mark the pid or supervisor at M-N rem M as dead (prioritize workers at first)
    ChosenN = M - (N rem M),
    %% 4. propagate expected status to other supervisors based on tolerance
    {Pid, NewDeaths} = propagate_death(Tree, Deaths, ChosenN),
    %% 5. kill the actual process
    kill_and_wait(Pid), % should this be conditional in case a proc choice failed?
    %% 6. wait N milliseconds for propagation
    DeadSleep = lists:sum([case Dead of  % TODO: tweak
                            dead -> 250;
                            child_dead -> 100
                           end || {Dead, _, _} <- NewDeaths]),
    timer:sleep(DeadSleep), % very tolerant sups may be killed at random anyway
    %% 7. take a snapshot of the program tree and compare them
    NewTree = find_supervisors(Whitelist),
    {NewTree, NewDeaths ++ Deaths}.

count_procs([]) -> 0;
count_procs([{_Restart, noproc} | T]) ->
    %% This happens somehow
    count_procs(T);
count_procs([{_Restart, {_, _Pid, _, Children}}|T]) ->
    1 + count_procs(Children) + count_procs(T);
count_procs([{_Restart, {_Type, _Pid}} | T]) ->
    1 + count_procs(T);
count_procs([{App, [{_, {_, _, _, Children}}]}|T]) when is_atom(App) ->
    count_procs(Children) + count_procs(T).

kill_and_wait(Pid) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        error({timeout, {kill, Pid}})
    end.

%% kill shots
propagate_death([{_Restart, {_Type, Pid}}|_], _Deaths, 0) ->
    {Pid, [{dead, Pid, stamp()}]};
propagate_death([{_Restart, {_Strategy, Pid, _, Children}}|_], _Deaths, 0) ->
    {Pid, [{dead, Pid, stamp()} | recursive_all_dead(Children)]};
%% propagation
propagate_death([], _Deaths, N) ->
    {not_in_tree, N};
propagate_death([{_Restart, noproc} | T], Deaths, N) ->
    propagate_death(T, Deaths, N);
propagate_death([{_Restart, {Strategy, Pid, Tolerance, Children}}|T], Deaths, N) ->
    case propagate_death(Children, Deaths, N-1) of
        {not_in_tree, NewN} ->
            propagate_death(T, Deaths, NewN);
        {KillPid, NewDeaths} when is_pid(KillPid) ->
            handle_child_death(Pid, KillPid, Strategy, Tolerance, NewDeaths, Deaths, Children)
    end;
propagate_death([{_Restart, {_Atom, _Pid}}|T], Deaths, N) ->
    propagate_death(T, Deaths, N-1);
propagate_death([{App, [{_,{Strategy,Pid,Tolerance,Children}}]}|T], Deaths, N) when is_atom(App) ->
    case propagate_death(Children, Deaths, N) of
        {not_in_tree, NewN} ->
            propagate_death(T, Deaths, NewN);
        {KillPid, NewDeaths} when is_pid(KillPid) ->
            handle_child_death(Pid, KillPid, Strategy, Tolerance, NewDeaths, Deaths, Children)
    end.

handle_child_death(Pid, KillPid, Strategy, {Intensity, Period}, NewDeaths, Deaths, Children) ->
    %% =====
    %% Dependencies:
    %% - if a one_for_one/sofo supervisor sibling dies, none of the other siblings should die
    %% - if a rest_for_one supervisor sibling (ancestor) dies, the newer ones should die
    %% - if a one_for_all supervisor sibling dies, they all die.
    %% - if a worker dies, add the count to the parent ({child_dead, SupPid, Stamp})
    Now = stamp(),
    Deadline = Now-Period,
    ChildPids = get_child_pids(Children),
    DeadPids = [{child_dead, Pid, S} || {dead, P, S} <- NewDeaths,
                                        lists:member(P, ChildPids)],
    ShouldDie = Intensity < length(qualifying_deaths(Pid, Deadline, DeadPids++Deaths)),
    CurrentDeaths = if ShouldDie ->
                        [{dead, Pid, Now} | all_dead(Children)]
                    ;  not ShouldDie ->
                        ShutdownPids = propagate(Strategy, DeadPids, Children),
                        dedupe_append([ShutdownPids, DeadPids, NewDeaths])
                    end,
    {KillPid, CurrentDeaths}.

propagate(_, [], _) ->
    % no dead children
    [];
propagate(one_for_all, _, Children) ->
    all_dead(Children);
propagate(rest_for_one, [DeadPid], Children) ->
    %% The children are in reverse order, so we dropwhile to the child
    lists:dropwhile(fun({_, Pid, _}) -> Pid =/= DeadPid end, all_dead(Children));
propagate(T, Dead, _) when T =:= one_for_one; T =:= simple_one_for_one ->
    %% one_for_one and simple_one_for_one remain as-is
    Dead.

dedupe_append([]) -> [];
dedupe_append([[]|T]) -> dedupe_append(T);
dedupe_append([[H={Tag,Pid,_}|T] | Rest]) ->
    try
        [throw(dupe) || List <- [T | Rest],
                        {Type,P,_} <- List,
                        {Type,P} == {Tag,Pid}],
        [H | dedupe_append([T | Rest])]
    catch
        dupe -> dedupe_append([T|Rest])
    end.

stamp() ->
    erlang:monotonic_time(second). % same resolution as supervisor intervals

recursive_all_dead(Children) ->
    Now = stamp(),
    [{dead, Pid, Now} || Pid <- get_subtree_pids(Children)].

all_dead(Children) ->
    Now = stamp(),
    [{dead, Pid, Now} || Pid <- get_child_pids(Children)].

get_child_pids([]) -> [];
get_child_pids([{_, noproc} | T]) -> get_child_pids(T);
get_child_pids([{_, {_, Pid, _, _}} | T]) -> [Pid | get_child_pids(T)];
get_child_pids([{_, {_, Pid}}|T]) -> [Pid | get_child_pids(T)].

supervisor_pids([]) -> [];
supervisor_pids([{_, noproc} | T]) -> supervisor_pids(T);
supervisor_pids([{_, {_,_}} | T]) -> supervisor_pids(T);
supervisor_pids([{_, {_, Pid, _, Children}} | T]) ->
    [Pid | supervisor_pids(Children)] ++ supervisor_pids(T);
supervisor_pids([{_, Sup} | T]) when is_list(Sup) ->
    supervisor_pids(Sup) ++ supervisor_pids(T).

get_subtree_pids([]) -> [];
get_subtree_pids([{_, noproc} | T]) -> get_subtree_pids(T);
get_subtree_pids([{_, {_, Pid}}|T]) -> [Pid | get_subtree_pids(T)];
get_subtree_pids([{_, {_, Pid, _, Children}} | T]) ->
    [Pid | get_subtree_pids(Children)] ++ get_subtree_pids(T).

qualifying_deaths(Pid, Deadline, Deaths) ->
    [D || D = {child_dead,P,S} <- Deaths,
          P =:= Pid, S >= Deadline].


-spec find_supervisors() -> apptree().
find_supervisors() -> find_supervisors([]).

find_supervisors(Whitelist) ->
    [{App, [{permanent, dig_sup(P)}]}
     || {App,P} <- root_sups(),
        Whitelist =:= [] orelse lists:member(App, Whitelist)].


%%% DIG WITHIN A SUPERVISOR
dig_sup(Pid) ->
    try sys:get_state(Pid) of
        {state, _Name, Strategy, Children, _Dynamics,
         Intensity, Period, _Restarts, _DynamicRestarts,
         _Mod, _Args} ->
            {Strategy, Pid, {Intensity, Period}, dig_children(Children, Pid)};
        _Other ->
            {non_otp_supervisor, Pid}
    catch
        exit:{noproc,_} -> noproc
    end.

dig_children([{child, undefined, _Name, _MFA, Restart, _Kill, worker, _Type}], Parent) ->
    %% Simple one for one worker
    Children = supervisor:which_children(Parent),
    [{Restart, {worker, Pid}} || {_,Pid,_,_} <- Children];
dig_children([{child, undefined, _Name, _MFA, Restart, _Kill, supervisor, _Type}], Parent) ->
    Children = supervisor:which_children(Parent),
    [{Restart, handle_dig_result(dig_sup(Pid))} || {_,Pid,_,_} <- Children];
dig_children(Children, _Parent) ->
    dig_children_(Children).

dig_children_([]) -> [];
dig_children_([{child, Pid, _Name, _MFA, Restart, _Kill, worker, _Type} | T]) ->
    [{Restart, {worker, Pid}} | dig_children_(T)];
dig_children_([{child, Pid, _Name, _MFA, Restart, _Kill, supervisor, _} | T]) ->
    [{Restart, handle_dig_result(dig_sup(Pid))} | dig_children_(T)].

handle_dig_result({non_otp_supervisor, Pid}) -> {non_otp_sup, Pid};
handle_dig_result(noproc) -> noproc;
handle_dig_result(Res) -> Res.

root_sups() ->
    RunningApps = proplists:get_value(running, application:info()),
    Apps = [{App, Pid} || {App, Pid} <- RunningApps, is_pid(Pid)],
    [{App, P} ||
          {App, MasterOuter} <- Apps,
          {links, MasterInners} <- [process_info(MasterOuter, links)],
          M <- MasterInners,
          {_,{application_master,start_it,4}} <- [process_info(M, initial_call)],
          {links, Links} <- [process_info(M, links)],
          P <- Links,
          {supervisor,_,_} <- [proc_lib:translate_initial_call(P)]].
