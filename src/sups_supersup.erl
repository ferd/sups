-module(sups_supersup).
-export([start_link/0, init/1]).
-behaviour(supervisor).

start_link() -> supervisor:start_link(?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 1},
    ChildSpecs = [
        #{id => db_sup,
          start => {sups_db_sup, start_link, []},
          restart => permanent,
          type => supervisor,
          modules => [sups_db_sup]},
        #{id => workers_sup,
          start => {sups_worker_sup, start_link, []},
          type => supervisor,
          modules => [sups_worker_sup]}
    ],
    {ok, {SupFlags, ChildSpecs}}.
