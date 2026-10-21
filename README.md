# Worktrees

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Git worktrees: list, create and remove worktrees, and start an agent or a shell in one, from palette commands and a side panel.

## Tree paths

A new tree goes in `<root>/<name>-<id>/<branch>`. The root is `~/.lazyrex/worktrees`. The name is the
directory name of the repository. The ID is 6 hex digits from the path of the repository's common Git
directory, so two repositories with the same name usually get different trees. Two paths can still
get the same ID. Then create does not reuse the other repository's tree: it fails with `conflict`.

Before it makes a tree, create looks for a linked tree of the branch inside the root, also at an
older path (`<root>/<name>/<branch>`). If Git lists one, create returns it with `created = false`.
The main tree of a repository is never returned this way. If the listed tree's directory is missing,
create is refused: repair or prune the Git entry first. A tree of the branch outside the root is not
returned: `git worktree add` fails with `git_error`.

## Scans

The plugin checks each tree in the background: the tree exists, then `git --no-optional-locks status`.
A refresh only queues these checks. A timer runs them: at most 8 start in one tick (0.2 s), and at
most 8 run at one time. So the tree checks do not block the plugin's request queue, but the last
clean or dirty states of a large repository arrive later (101 trees: 13 ticks or more).
A refresh still lists the trees of each repository and matches the workers in the request queue
(observed on Rex 0.0.1792158932-g88fd41: 101 trees and 16 workers, 0.14 to 0.16 s).

## Git hooks

`git worktree add` runs the `post-checkout` hook when the checkout occurs
([githooks](https://git-scm.com/docs/githooks#_post_checkout)). If that hook fails, the plugin
returns `git_error`, and the created worktree remains. The error keeps the end of the Git output,
at most 4096 bytes of JSON.

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
