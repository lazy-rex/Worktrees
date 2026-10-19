# Worktrees

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Git worktrees: list, create and remove worktrees, and start an agent or a shell in one, from palette commands and a side panel.

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
