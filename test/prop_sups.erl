-module(prop_sups).
-include_lib("proper/include/proper.hrl").

prop_check_tree() ->
    ?FORALL(Cmds, commands(sups_statem),
        begin
            %% Pre
            application:load(sasl),
            application:set_env(sasl, sasl_error_logger, false),
            {ok, Apps} = application:ensure_all_started(sups),
            %% Tests
            {History, State, Result} = run_commands(sups_statem, Cmds),
            %% Post
            [application:stop(App) || App <- Apps],
            %% Reporting
            ?WHENFAIL(io:format("History: ~p\nState: ~p\nResult: ~p\n",
                                [History,State,Result]),
                      collect(length(Cmds), Result =:= ok))
        end).
