sups
=====

Experimental code library to be used with PropEr or Quickcheck to validate that an OTP application is properly implemented to match the structure of its supervision tree.

Basically, in a scenario where the supervision structure encodes the expected failure semantics of a program, this library can be used to do fault-injection and failure simulation to see that the failures taking place within the program actually respect the model exposed by the supervision tree. If random process kills or simulated faults end up killing unexpected supervision subtrees, it is assumed that the caller processes have weaknesses in how they handle events.

This documentation is still a work in progress.

Calls
-----

The API needs rework to be a bit more transparent. This doc needs rework to be a bit more helpful.

- `sups_lib:init_state()` and `sups_lib:init_state([WhiteList])`: takes a snapshot of the supervision tree of currently running applications. Should be called before any other function of this library in a PropEr model to give it a baseline data set against which to run.
- `mark_as_dead(State, N, Filters, WhiteList)` where `N` should be an integer picked randomly by the test framework. See the _Filters_ section for filters. This function kills a random process in the supervision tree, and makes guesses (based on the tree structure) as to what processes should be expected to die along with it.
- `mock_success(State, MockFun, UnmockFun, WhiteList)` takes two functions: the first one of the form `fun() -> DoSomeMocking, IntegerValue end`, where you can set up any mocking you want, and `IntegerValue` tells the system how long to sleep (in milliseconds) before calling the unmocking function (`fun() -> Whatever end`), returning the system to normal.
- `validate_mark_as_dead(OldTree, NewTree, DeadList) -> Bool` (TODO: rework to use `State`) can be used as a postcondition to validate that the right processes are living or dead in the application.
- `validate_mock_success(OldTree, NewTree, DeadList) -> Bool` (TODO: rework to use `State`) can be used as a postcondition to validate that no unexpected processes died during fault injection.

Other functions are exported in `sups_lib` to let you implement custom validation.

Filters
-------

Zero of more filters can be used in a list:

- `{named, Atom}`: only kill processes with that given name (in the native registry)
- `{not_named, Atom}`: only kill processes aside from a known named one
- `{tagged, Term}`: only kill processes that have an entry of the form `put(sups_tags, [Term])` in their process dictionary
- `{not_tagged, Term}`: only kill processes that don't have an entry of the form `put(sups_tags, [Term])` in their process dictionary

How It Works
------------

By building a supervision tree data structure with all annotations, we can create an integer `N` through a regular PropEr or QuickCheck generator that is applied to the tree to denote a specific node. The count starts depth-first, from the right-most child to the leftmost child (meaning that by default shrinking rules, we start by killing newer processes than older and more critical ones).

This numeric value is adapted according to filters and whatnot, and since it relies on the shape of the tree rather than the processes it contains, it should allow proper Shrinking to work fine.

On a process kill, we analyze the structure of the tree and supervision structure, maintain a list of processes we know should have died, and use it to resolve what the actual tree should be doing as a model.

Example
-------
TODO

Actually the test code for this lib (`rebar3 proper`)

Caveats
-------

Currently, the system does not track nor model unexpected worker faults in remote subtrees (only local ones), and so those may end up impacting tolerance rates of other supervisors and lower the accuracy of the model. Not too sure if this becomes a problem in practice or not.

The system must be running under constant simulation load to be realistic.

The sleeping / waiting timer for propagation is a bit ad hoc and requires tweaking

Not seen enough testing with real world apps.

Roadmap
-------

- Fix arguments to functions
- Fix app/demo structure
- Rename mocking functions to be related to fault injection
- Write tests instead of just running them
- See if this holds up in real world projects