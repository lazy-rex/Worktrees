# Handoff: Worktrees (2026-10-19)

## State

- origin/main is 88beb23. The live release clone runs 88beb23 too.
- Branch `harness` is the same as origin/main, plus this file. There are no other unpushed commits or branches. The local `main` is behind origin/main (33 commits); fast-forward it before you use it.
- The team goals are closed. The coordinator accepted them:
  1. The Node tests are ported to `tests/*.lua`. `lazyrex-hub test` runs them. The Node tests are removed (7b4e00b). The commit body of 7b4e00b is the approved coverage map.
  2. Agent parity.
- Last full run: 14 files, exit 0, on LazyRex main c9b3e0d (reviewer: 123 checks on 5417514). The coordinator also ran 88beb23 on LazyRex 3fa19d2: exit 0.

## How to test

```sh
lazyrex-hub test -lazyrex ../LazyRex             # every tests/*.lua
lazyrex-hub test -lazyrex ../LazyRex -file list.lua
```

Build `lazyrex-hub` from LazyRex `hub/cmd/hub`. The Go version is in `hub/go.mod`. Lab only: never point a test at the real Rex server.

## Decisions in effect

- An agent may remove any worktree, discard any operation by ID, and stop any worker (the user's decision, LazyRex docs/decisions.md, 7cf0851; LazyRex 9bc00c8).
- worktree.list reply budget: 44 KiB in total (45056 bytes). Pages: worktrees 16 KiB, operations 24 KiB, at most 50 entries a page. The other fields: 4 KiB. The limits: the test client takes 49152 bytes; one Rex control message is 65536 bytes.
- A list call with a cursor reads the latest cached scan. It starts a scan only when there is no scan. The list can change between pages.
- Notifications (hub.changed workers, view.seen focus, terminal events) do no Git work in the request queue. They set a flag, and one rex.after(0.2) tick refreshes (5417514). 'always' wins over 'workers' until the tick consumes it.

## Open items and known limits

- No known open bug. No reviewer condition is open.
- The burst fix was observed for 30 spawns and 30 stops. A larger burst is not tested. The plugin request queue holds 16 requests (a hub limit).
- `tests/list.lua` "a tree with too many workers is compact" still spaces its spawns and retries a busy reply. That was written before 5417514. You can remove the spacing and the retry, and then run the test several times.
- The commit message of 5417514 claims more than the code does. 19d7a03 corrects the comments. Do not amend.

## Rules for the next pair

- Push to this repository's main only after the reviewer approves. A push does not deploy: a release needs the user's approval through the coordinator. Never edit the release clones.
- Never amend a commit that the reviewer saw. Each defect gets its own fix commit, with a test that fails before the fix.
