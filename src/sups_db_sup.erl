-module(sups_db_sup).
-export([start_link/0, init/1]).
-behaviour(supervisor).

start_link() -> supervisor:start_link(?MODULE, []).

init([]) ->
    put(sups_tags, [db]),
    {ok, {#{strategy => one_for_one, intensity => 10, period => 1},
          [#{id => worker1,
             start => {sups_db_worker, start_link, []},
             restart => permanent,
             type => worker,
             modules => [sups_db_worker]}]
    }}.

