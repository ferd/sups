-module(sups_lib).
-export([find_supervisors/0, find_supervisors/1, extract_dead/1,
         mark_as_dead/3, mock_success/4,
         unexpected_not_in_tree/2, sups_still_living/3]).

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
-type death_event() :: {dead|child_dead, pid(), stamp()}.
-type stamp() :: integer().
-type mockfun() :: fun(() -> ok).
-type unmockfun() :: fun(() -> ok). 

%-type model() :: {apptree(), [{dead | child_dead, supervisor_pid(), stamp()}]}.
-export_type([apptree/0]).

%%%%%%%%%%%%%%
%%% PUBLIC %%%
%%%%%%%%%%%%%%

%% @doc find all the supervisors in a running system
-spec find_supervisors() -> apptree().
find_supervisors() -> find_supervisors([]).

%% @doc find all the supervisors in a running system within a
%% list of whitelisted applications. An empty list means all
%% apps are scanned.
-spec find_supervisors([atom()]) -> apptree().
find_supervisors(Whitelist) ->
    [{App, [{permanent, dig_sup(P)}]}
     || {App,P} <- root_sups(),
        Whitelist =:= [] orelse lists:member(App, Whitelist)].

%% @doc from a list of death events, extract the pids that are definitely dead
%% under the form of a set for quick matching
-spec extract_dead([death_event()]) -> sets:set(pid()).
extract_dead(List) -> sets:from_list([Pid || {dead, Pid, _} <- List]).

%% @doc Takes in an app tree with all the related deaths seen so far,
%% along with a random number `N' that identifies what should die,
%% and a whitelist of applications to look into to kill stuff in.
%% Then, the call will go inside the tree and:
%%
%% 1. find how many processes are in the tree
%% 2. mark them with numbers 0..M based on position (implicit)
%% 3. mark the pid or supervisor at M-N rem M as dead (prioritize workers at first)
%% 4. propagate expected status to other supervisors based on tolerance
%% 5. kill the actual process
%% 6. wait a few milliseconds for propagation (arbitrary)
%% 7. take a snapshot of the program tree and compare with the old one.
%% @end
%% @TODO make the millisecond wait for propagation more solid
-spec mark_as_dead({apptree(), [death_event()]}, non_neg_integer(), [atom()]) ->
        {apptree(), [death_event()]}.
mark_as_dead({Tree, Deaths}, N, Whitelist) when is_list(Tree) ->
    %% 1. find how many procs are in the tree,
    M = count_procs(Tree),
    mark_as_dead({Tree, Deaths}, N, M, Whitelist).

%% @doc runs a mocked bit of code that can simulate some sort of
%% failure or return value for an arbitrary period of time
%% and then reverts it.
%% A healthy supervision tree should be coming back, with no supervisor
%% failures in it.
-spec mock_success({apptree(), [death_event()]}, mockfun(), unmockfun(), [atom()]) ->
        {apptree(), [death_event()]}.
mock_success({Tree, Deaths}, Mock, Unmock, Whitelist) when is_list(Tree) ->
    Mock(),
    timer:sleep(100),
    Unmock(),
    NewTree = find_supervisors(Whitelist),
    {NewTree, Deaths}.


%% @doc Takes a supervision tree model and ensures that none of the
%% processes in `Set' are to be found in it.
-spec unexpected_not_in_tree(apptree(), sets:set(pid())) -> boolean().
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

%% @doc compares two supervision trees (an old one and a newer one) and a set of
%% pids that are expected to be dead, and makes sure that the new supervision tree
%% does contain all of the supervisors that were in the old tree and should
%% not have died according to the model.
-spec sups_still_living(apptree(), apptree(), sets:set(pid())) -> boolean().
sups_still_living(Old, New, ShouldBeDead) ->
    OldSupPids = supervisor_pids(Old),
    NewSupPids = supervisor_pids(New),
    MustLive = OldSupPids -- sets:to_list(ShouldBeDead),
    lists:all(fun(Pid) -> lists:member(Pid, NewSupPids) end, MustLive).

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

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


%%% MARK AS DEAD COMPLEX STUFF %%%

%% @private mark_as_dead continuation.
%% @TODO: fix the logging for the last process left maybe
-spec mark_as_dead({apptree(), [death_event()]}, non_neg_integer(), non_neg_integer(), [atom()]) ->
        {apptree(), [death_event()]}.
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
    %% 6. wait a few milliseconds for propagation
    DeadSleep = lists:sum([case Dead of  % TODO: tweak
                            dead -> 250;
                            child_dead -> 100
                           end || {Dead, _, _} <- NewDeaths]),
    timer:sleep(DeadSleep), % very tolerant sups may be killed at random anyway
    %% 7. take a snapshot of the program tree and compare them
    NewTree = find_supervisors(Whitelist),
    {NewTree, NewDeaths ++ Deaths}.

%% @private returns how many processes are in a supervision tree
-spec count_procs(apptree()) -> non_neg_integer().
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

%% @private send an exit signal and return once the process has died.
kill_and_wait(Pid) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        error({timeout, {kill, Pid}})
    end.

%% @private
%% Take the app tree, the deaths seen so far, and then kill the process
%% that has been targeted by its integer position. Once it is killed, update
%% the death events and propagate all deaths up the supervision tree
%% according to the model.
%% @end
-spec propagate_death(apptree(), [death_event()], non_neg_integer()) ->
    {pid(), [death_event()]}.
%% kill shots
propagate_death([{_Restart, {_Type, Pid}}|_], _Deaths, 0) ->
    {Pid, [{dead, Pid, stamp()}]};
propagate_death([{_Restart, {_Strategy, Pid, _, Children}}|_], _Deaths, 0) ->
    {Pid, [{dead, Pid, stamp()} | recursive_all_dead(Children)]};
%% propagation steps
propagate_death([], _Deaths, N) ->
    %% proc not found
    {not_in_tree, N};
propagate_death([{_Restart, noproc} | T], Deaths, N) ->
    %% skip process as non-existing
    propagate_death(T, Deaths, N);
propagate_death([{_Restart, {Strategy, Pid, Tolerance, Children}}|T], Deaths, N) ->
    %% supervisor (not the target). Propagate the kill signal, and if it comes
    %% back up to us and a child (direct or not) was the target, propagate
    %% the death to other siblings or even ourselves
    case propagate_death(Children, Deaths, N-1) of
        {not_in_tree, NewN} ->
            propagate_death(T, Deaths, NewN);
        {KillPid, NewDeaths} when is_pid(KillPid) ->
            handle_child_death(Pid, KillPid, Strategy, Tolerance, NewDeaths, Deaths, Children)
    end;
propagate_death([{_Restart, {_Atom, _Pid}}|T], Deaths, N) ->
    %% non-target worker
    propagate_death(T, Deaths, N-1);
propagate_death([{App, [{_,{Strategy,Pid,Tolerance,Children}}]}|T], Deaths, N) when is_atom(App) ->
    %% Skip to the next app. Since we represent the root process of the app, we may
    %% need to do propagation of our own.
    case propagate_death(Children, Deaths, N) of
        {not_in_tree, NewN} ->
            propagate_death(T, Deaths, NewN);
        {KillPid, NewDeaths} when is_pid(KillPid) ->
            handle_child_death(Pid, KillPid, Strategy, Tolerance, NewDeaths, Deaths, Children)
    end.

%% @private Act as a supervisor and apply a modeled version of the various
%% restart strategies to children:
%% - if a one_for_one/sofo supervisor sibling dies, none of the other siblings should die
%% - if a rest_for_one supervisor sibling (ancestor) dies, the newer ones should die
%% - if a one_for_all supervisor sibling dies, they all die.
%% - if a worker dies, add the count to the parent ({child_dead, SupPid, Stamp})
-spec handle_child_death(pid(), pid(), strategy(), {intensity(), period()},
                         [death_event()], [death_event()], apptree()) -> {pid(), [death_event()]}.
handle_child_death(Pid, KillPid, Strategy, {Intensity, Period}, NewDeaths, Deaths, Children) ->
    Now = stamp(),
    Deadline = Now-Period,
    ChildPids = get_child_pids(Children),
    DeadPids = [{child_dead, Pid, S} || {dead, P, S} <- NewDeaths,
                                        lists:member(P, ChildPids)],
    %% Should the supervisor die, or just some of its children?
    ShouldDie = Intensity < length(qualifying_deaths(Pid, Deadline, DeadPids++Deaths)),
    CurrentDeaths = if ShouldDie ->
                        [{dead, Pid, Now} | all_dead(Children)]
                    ;  not ShouldDie ->
                        ShutdownPids = propagate(Strategy, DeadPids, Children),
                        dedupe_append([ShutdownPids, DeadPids, NewDeaths])
                    end,
    {KillPid, CurrentDeaths}.

%% @private implement the propagation strategy on a list of children
-spec propagate(strategy(), [pid()], [worker()|sup()]) -> [pid()].
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

%% @private Add events to the end of a list, but skip duplicate entries since
%% those can interfere with the frequency counts. Keep the latest instances
%% only.
-spec dedupe_append([[death_event()]]) -> [death_event()].
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

%% @private mark all direct children as dead
-spec all_dead([worker()|sup()]) -> [death_event()].
all_dead(Children) ->
    Now = stamp(),
    [{dead, Pid, Now} || Pid <- get_child_pids(Children)].

%% @private mark all direct and indirect children as dead
-spec recursive_all_dead([worker()|sup()]) -> [death_event()].
recursive_all_dead(Children) ->
    Now = stamp(),
    [{dead, Pid, Now} || Pid <- get_subtree_pids(Children)].

%% @private all deaths that have happened on or after a deadline
-spec qualifying_deaths(pid(), stamp(), [death_event()]) -> [death_event()].
qualifying_deaths(Pid, Deadline, Deaths) ->
    [D || D = {child_dead,P,S} <- Deaths,
          P =:= Pid, S >= Deadline].

%% @private monotonic timestamp. Must have the same granularity as
%% what supervisors use on their own to get filtering to work (seconds).
-spec stamp() -> stamp().
stamp() -> erlang:monotonic_time(second).

%% @private get the pids of all direct children of a process'
%% child list
-spec get_child_pids([worker()|sup()]) -> [pid()].
get_child_pids([]) -> [];
get_child_pids([{_, noproc} | T]) -> get_child_pids(T);
get_child_pids([{_, {_, Pid, _, _}} | T]) -> [Pid | get_child_pids(T)];
get_child_pids([{_, {_, Pid}}|T]) -> [Pid | get_child_pids(T)].

%% @private get the pids of all direct or indirect children of a process'
%% child list
-spec get_subtree_pids([worker()|sup()]) -> [pid()].
get_subtree_pids([]) -> [];
get_subtree_pids([{_, noproc} | T]) -> get_subtree_pids(T);
get_subtree_pids([{_, {_, Pid}}|T]) -> [Pid | get_subtree_pids(T)];
get_subtree_pids([{_, {_, Pid, _, Children}} | T]) ->
    [Pid | get_subtree_pids(Children)] ++ get_subtree_pids(T).

%% @private get the pids of all supervisors that are direct or indirect
%% children of a process' child list
-spec supervisor_pids([worker()|sup()]) -> [pid()].
supervisor_pids([]) -> [];
supervisor_pids([{_, noproc} | T]) -> supervisor_pids(T);
supervisor_pids([{_, {_,_}} | T]) -> supervisor_pids(T);
supervisor_pids([{_, {_, Pid, _, Children}} | T]) ->
    [Pid | supervisor_pids(Children)] ++ supervisor_pids(T);
supervisor_pids([{_, Sup} | T]) when is_list(Sup) ->
    supervisor_pids(Sup) ++ supervisor_pids(T).
