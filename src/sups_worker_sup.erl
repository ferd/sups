-module(sups_worker_sup).
-export([start_link/0, init/1]).
-behaviour(supervisor).

start_link() -> supervisor:start_link(?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => worker1,
             start => {sups_worker, start_link, []},
             restart => permanent, modules => [sups_worker]}]
    }}.


