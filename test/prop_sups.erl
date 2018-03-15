-module(prop_sups).
-include_lib("proper/include/proper.hrl").

prop_check_tree() ->
    ?FORALL(Cmds, commands(sups_statem),
        begin
            %% Pre
            silence_logs(),
            {ok, Apps} = application:ensure_all_started(sups),
            %% Tests
            {History, State, Result} = run_commands(sups_statem, Cmds),
            %% Post
            [application:stop(App) || App <- Apps],
            %% Reporting
            ?WHENFAIL(io:format("History: ~p~nState: ~p~nResult: ~p~n",
                                [History,State,Result]),
                      collect(bucket(length(Cmds), 10),
                              Result =:= ok))
        end).

bucket(N, M) ->
    Base = N div M,
    {Base*M, (Base+1)*M}.

silence_logs() ->
    application:load(lager),
    application:set_env(lager, handlers, []),
    application:ensure_all_started(lager).