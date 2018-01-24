-module(sups_app).
-export([start/2, stop/1]).

start(_Type, _Args) -> sups_supersup:start_link().

stop(_) -> ok.

