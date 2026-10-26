# Worktrees

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Work on several branches at once: create
a Git worktree for a branch, and start an agent or a shell in it, from the palette. A side panel
lists your worktrees with their clean or dirty state and the agents in them. Remove a tree when
the work is done; the plugin refuses while the tree has changes or a pane uses it.

## Get it

LazyRex setup installs Worktrees with the other core plugins. To add it by hand, add an entry to
the `plugins` list of the hub config:

```json
{"source": "/path/to/Worktrees"}
```

The source is the plugin directory. The plugin uses the LazyRex Plugin SDK (`"sdk": "0"` in
`lazyrex.json`). It needs LazyRex hub v0.5.0-rc.1 or later (the base migration step of the SDK).

## Palette commands

- **LazyRex: Worktrees…** opens the panel, with the source repository first. A tree row opens a
  menu: **Open in new tab**, **Open in new session**, **Start agent…** and **Remove…**. A
  repository row also has **Forget repository…**.
- **LazyRex: New Worktree…** creates a worktree for a branch, and opens a shell in it.
- **LazyRex: Remove Worktree…** removes a managed worktree.

## Agent actions

| Action | What it does |
| --- | --- |
| `worktree.create` | Create a worktree for a branch, or return the linked tree of the branch that exists. |
| `worktree.list` | List worktrees, their dirty state, the workers in them, and the pending operations. |
| `worktree.remove` | Remove a managed linked worktree. |
| `worktree.open` | Start a profile (default: a shell) in a worktree, in a new tab or a new session. |
| `worktree.discard` | Discard a pending create or remove operation that stopped. |
| `worktree.forget` | Remove a recorded repository from the list. Nothing on disk changes. |

Each action that changes state takes a `key`. After an unknown outcome or a `running` result,
retry with the same key and the same arguments.

## Settings

Plugin args (hub config `plugins[].args`):

- `worktrees_root` (default `~/.lazyrex/worktrees`): the directory for new trees. It must be an
  absolute path. The plugin makes the directory if it does not exist.

## Tree paths

A new tree goes in `<root>/<name>-<id>/<branch>`. The root is `worktrees_root`. The name is the
directory name of the repository. The ID is 6 hex digits from the path of the repository's common Git
directory, so two repositories with the same name usually get different trees. Two common Git directory
paths can still get the same ID. If the target path already contains another repository or branch,
create fails with `conflict` instead of reusing that tree.

Before it makes a tree, create looks for a linked tree of the branch inside the root, at any path:
Git checks a branch out in at most one tree. If Git lists one, create returns it with `created = false`.
The main tree of a repository is never returned this way. If the listed tree's directory is missing,
create is refused: repair or prune the Git entry first. A tree of the branch outside the root is not
returned: `git worktree add` fails with `git_error`.

## Source repository

The panel shows first the repository of the source pane. The plugin keeps that repository per
pane directory, so a panel render runs no Git for a directory that it already knows. (A lookup
costs about 100 ms and 3 Git processes, measured on Rex build 0.0.1792158932-g88fd41.) A new directory
is looked up on its first render. The plugin keeps at most 64 directories. A known directory is
looked up again after the next refresh. These events start a refresh: Refresh, a focus of a
plugin view, a change of the worker set, a pane that enters or leaves the root, a pane exit, the
close of a managed pane, and a create, remove, forget or discard.
So when a repository appears or goes away in the same directory, the panel can show the old result
until then. A plain `worktree.list` call does not start a new lookup.

## Panel pages

The panel and its **More…** pages each encode to at most 48 KiB (the page budget of the plugin).
The panel shows the tree rows (the source repository first) and then each pending operation, as
many as fit. Discard ends an operation only when its Git process has stopped. If more remain, **More…** opens the next page; on that page, a row opens its menu, and
Discard works as on the panel. If the list changes between pages, a page can repeat or skip an
entry.

The panel cuts each text to 1024 bytes. An entry over 8 KiB first loses its label and detail. Only when its exact ID does not fit (a very long path, or an operation key of many KiB)
does it show as a placeholder without an action: discard such an operation with
`worktree.discard` and its full operation ID (`worktree.list` lists it), or with its operation key
as its caller.

The page budget is not a limit of the hub. The SDK sends a view over 45056 bytes (its inline
limit) to the hub in parts, and the hub joins them. A view over 786432 bytes (768 KiB, the reply
limit) fails with `too_large`. The hub gives both limits in the `hub.register` reply (hub v0.4.2 and
later). Other forms have no page budget; only the reply limit applies.

## Scans

The plugin checks each tree in the background: the tree exists, then `git --no-optional-locks status`.
A refresh only queues these checks. A timer runs them: at most 8 start in one tick (0.2 s), and at
most 8 run at one time. So the tree checks do not block the plugin's request queue, but the last
clean or dirty states of a large repository arrive later (101 trees: 13 ticks or more).
A refresh still lists the trees of each repository and matches the workers in the request queue
(measured on Rex build 0.0.1792158932-g88fd41: 101 trees and 16 workers, 0.14 to 0.16 s).

The tree states are Lua values, not SQL rows. So the hub's read tracking does not render the panel
again for them. When a scan job of a shown list ends, the plugin calls `app.refresh()` once.
`tests/refresh.lua` checks that the panel then shows the new state with no other render request.

## Git hooks

`git worktree add` runs the `post-checkout` hook when the checkout occurs
([githooks](https://git-scm.com/docs/githooks#_post_checkout)). If that hook fails, the plugin
returns `git_error`, and the created worktree remains. The error keeps the end of the Git output,
at most 4096 bytes of JSON.

## Remove

Remove (`worktree.remove`, or **Remove Worktree…**) runs plain `git worktree remove`, never
`--force`, and never deletes the branch. It is refused while a worker or a terminal pane uses the
tree, while a worker has an unknown working directory, and while the tree has changes or untracked files.

Ignored files (for example `log/`, `tmp/` or `.env`) also refuse removal by default: they can be the
only copy of a key or of local data. With `accept_ignored = true` (in the form: **Also delete
ignored files**), Git deletes the ignored files with the tree. Changes and untracked files still
refuse removal (observed with Git 2.54.0). `accept_ignored` is part of the request content of its
key, so a refusal without it needs a new key.

A remove records the identity of the tree's Git directory: its path, device, inode and birth time.
A retry compares it, so a different tree at the same path is a conflict, not a removal. macOS gives
the fields with `stat -f %d:%i:%B`, Linux with `stat -c %d:%i:%W`. On a Linux file system without a
birth time, the birth time is 0, so there the identity is the path, device and inode only.

## Forget repository

The menu of a repository row (its main tree, or the unavailable row of a repository that Git
cannot list) has **Forget repository…**. Agents use `worktree.forget`. Forget removes the
repository from the recorded repositories: `worktree.list` and the panel stop showing it. Nothing
on disk changes, and no process stops. A later create in that repository records it again. The
panel of a pane inside a forgotten repository still shows it as the source, marked "not recorded".

Forget is refused while:

- an unfinished operation uses the repository;
- a worker is inside the recorded repository path, or inside a tree that Git lists now;
- a worker has an unknown directory.

When Git cannot list the repository, its linked trees are unknown, so a worker in one of them does
not cause a refusal. Instead, each worker outside every listable recorded repository is "unattributed":
the form lists them, and an agent gets `needs_confirmation` until it calls again with
`accept_unattributed = true`. If the list changes before the submit, the form shows the new list.

## Storage

The plugin keeps its records in its SQL database (`hub.sql`). One request is at most 64 KiB, so a
large value (a long open request or key, as JSON inside a SQL parameter) goes first in pieces to a
staging table, and one transaction writes the record.

## Tests

The tests are Lua files in `tests/`. The LazyRex hub runs them:

```sh
lazyrex-hub test                 # every tests/*.lua
lazyrex-hub test -file list.lua  # one file
```

`lazyrex-hub test` starts its own isolated lab Rex server for each file. Never point tests at your own Rex server.
It needs a LazyRex checkout: `-lazyrex <dir>`, `LAZYREX_DIR`, or `../LazyRex` beside the plugin
directory. See LazyRex
[docs/testing.md](https://github.com/lazy-rex/LazyRex/blob/main/docs/testing.md#writing-tests)
for the test API. The `test` field of `lazyrex.json` configures the tests.
