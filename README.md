# Worktrees

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Git worktrees: list, create and remove worktrees, and start an agent or a shell in one, from palette commands and a side panel.

## Scans

The plugin checks each tree in the background: the tree exists, then `git --no-optional-locks status`.
A refresh only queues these checks. A timer runs them: at most 8 start in one tick (0.2 s), and at
most 8 run at one time. So a refresh of many trees does not block the plugin's request queue, but
the last clean or dirty states of a large repository arrive later (101 trees: 13 ticks or more).
A refresh still lists the trees of each repository and matches the workers in the request queue
(observed on Rex 0.0.1792158932-g88fd41: 101 trees and 16 workers, 0.14 to 0.16 s).

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "worktrees", "path": "/path/to/Worktrees/worktrees.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

## Tests

The tests are Lua files in `tests/`. The LazyRex hub runs them:

```sh
lazyrex-hub test                 # every tests/*.lua
lazyrex-hub test -file list.lua  # one file
```

`lazyrex-hub test` starts its own isolated lab Rex server for each file. Never point tests at your own Rex server.
It uses `../LazyRex` (set `-lazyrex` for another checkout). See LazyRex `docs/testing.md` for the test API.
