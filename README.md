# Worktrees

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Git worktrees: list, create and remove worktrees, and start an agent or a shell in one, from palette commands and a side panel.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "worktrees", "path": "/path/to/Worktrees/worktrees.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

## Tests

The tests use `../LazyRex` (the client library in `lib/` and the lab harness in `lab/`).
Start an isolated lab server first, and never point tests at your own Rex server:

```sh
../LazyRex/lab/server.sh /tmp/rexlab
REX_SERVER=unix:///tmp/rexlab/rex.sock node tests/<name>.mjs
```

- worktrees.mjs, worktrees-hub.mjs (mock hub)
- worktrees-panel-lab.mjs, worktrees-contract-lab.sh (lab)
