# Port to the Plugin SDK (plan)

Status: **proposed**, 2026-10-22. The SDK is hub draft 3 (`origin/hub/sql-contract`: docs/plugin-sdk.md
and docs/sql.md). Nothing in it is implemented yet. No date gates the port (coordinator, 2026-10-22): the port starts when
the first SDK Lua commit runs against the fake hub.sql, and moves to the real hub branch when it
lands. What the SDK does not cover yet uses the raw escape (`app.hub`, raw dispatch), and shrinks later.

Base: Worktrees main 0008d43 plus the panel pages (E1, in review). `worktrees.lua` has 1716 lines
(990aec9: about 1800). Tests: 26 files, about 3900 lines.

## 1. What the SDK replaces

| Today | Lines (about) | With the SDK |
|---|---|---|
| `hub()` wrapper, the error-text parser, `rex_ok` for hub calls | 20 | SDK hub calls |
| `client.keymap` action list, `hub.register`, `hub.ui.tabs`, `client.set_label` | 70 | `app.action`, `app.panel` (and forms: gap G1) |
| The `client_perform_requested` dispatcher, `hub.forward` checks, `hub.identify`, `agent_caller` | 60 | the SDK dispatch, `ctx.agent` (aliases: gap G5) |
| `client.reply` error shaping | 5 | handler errors (codes: gap G3) |
| `catalog()`, `save()`, the `if_rev` retry loops in forget, admit, mutation, finish, cleanup | 120 | SQL in the handler transaction |
| The `discard/` and `open/` reservation records (`if_rev = '0'`) | 60 | SQL rows with a primary key |
| `hub.store.op` replay of create, remove, discard, forget | 40 | own `ops` table (section 3; the SDK store is not enough: gap G4) |
| `startup` (catalog read, cleanup, first refresh) | 20 | a start hook (gap G6) |
| `hub.ui.invalidate` calls | 10 | automatic for SQL reads; non-SQL state: gap G2 |

Estimate: 350 to 450 lines go, before the cleanup of section 4.

## 2. What stays (the domain)

- Git: `trees`, `repo_info`, `same_tree`, `identity`, the tree path and its repository ID.
- The operation phases of create and remove: prepared, sending (a Rex block runs Git), cleanup. A Git
  mutation and a Rex block are external effects; they cannot be in an SQL transaction. Rules: each
  phase commits before its external effect starts; the result and the cleanup phase commit together.
  `{tx = false}` alone gives no atomicity across statements, so each such commit uses a supported SDK
  transaction (G11) or one reviewed single statement.
- The scan queue and its timer, the snapshots, the source cache, removal advice: memory state.
- `hub.cwd.lock`, `hub.cwd.unlock`, `hub.cwd.check`, `hub.workers`, `hub.profiles`, `hub.spawn`,
  `hub.session.ensure`: hub services (gap G7).
- Rex calls: `session.new_block`, `com.superlogical.terminal.process`, `.format`, `.pwd`,
  `block.close`, `session.list_blocks`, `session.attach`.
- The views: the panel and 7 form routes, with paths in the route query.

## 3. Data: hub.store to SQL

Schema (migration 1):

```sql
CREATE TABLE repos (common TEXT PRIMARY KEY, repo TEXT NOT NULL);
CREATE TABLE pending (id TEXT PRIMARY KEY, kind TEXT NOT NULL, fingerprint TEXT, phase TEXT NOT NULL,
  actor TEXT, op TEXT NOT NULL);           -- op: the operation record as JSON (path, branch, block, ...)
CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL, at INTEGER NOT NULL);
CREATE TABLE reservations (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, record TEXT NOT NULL);
                                           -- the discard/ and open/ records, each whole as JSON (an open intent
                                           -- keeps its request, keys and state, not only a path)
CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL);   -- kv_import_progress, kv_import
```

Import (once, in the start hook), in pages. The sources, in this order, each with its own key space:
(1) the KV record `catalog` (repos and pending, one page), (2) `hub.store.scan` with the prefix
`open/`, (3) `hub.store.scan` with the prefix `discard/`, (4) `hub.store.ops_scan` for every saved
operation result (hub lead, to be added on hub/sql). Each `hub.sql.batch` copies one page and writes
the progress row `meta(name = 'kv_import_progress')` with the source and the cursor together (for
example `ops:<last key>`); the move to the next source writes the new source with an empty cursor. A
restart resumes from that row. The last batch writes `meta(name = 'kv_import', value = 'done')` with
the last page. Only the done row says that the import is complete: empty `repos` and `pending` are
valid after Forget, so they never start an import. Every saved result moves, also a completed
operation that no pending entry or reservation names; else its key could run again.

Until the done row commits, the plugin is inactive: every action and view answers `unavailable`
("import in progress"), and no cleanup, refresh or scan reads the partial SQL state. The importing
instance is the only writer of its namespace (the retirement fence), and it writes no KV key, so the
source stays stable during the import.

Rollback: before the done row, no SQL-era write exists (the plugin is inactive), so a rollback to
the KV plugin is safe only after a reset: with the hub stopped, delete the plugin's SQL file
(`<state>/sql/worktrees.db`). Without that reset, the KV plugin can change the source, and a later SQL
start would resume stale progress; so a rollback without the reset is not supported. After the done
row, the SQL tables are the only current state: the KV records stay as a copy of the old state, and
a rollback to the KV plugin would lose every later SQL write. The plan has no dual writes and no
reverse export, so a rollback after the done row is not supported.

Tests (import): a restart after each source transition; a restart after a page commit whose reply
was lost (the batch committed; the retry finds the progress row and does not copy the page twice);
a restart after Forget leaves empty tables empty (no second import); a replay of an imported
completed operation that nothing names; actions before the done row answer `unavailable`.

## 4. What I delete

- Everything in section 1 that the SDK covers.
- The legacy `owners` field and its comment (no rule uses it).
- `user_caller` versus `agent_caller` duplication, once `ctx.agent` (nil for the user) and the aliases arrive.
- The test support that stubs the hub protocol (`tests/support/sandbox.lua` stubs `client.perform`
  and `client.reply`): it moves to the SDK's test harness when that has a sandbox (gap G9).

## 5. Tests that stay green

All 26 files keep their behavior assertions. Changes: tests that read or write the `catalog` KV record
(discard, forget, list, parity fixture, remove, restart) read and write the SQL tables. The parity
sweep and the routes in `lazyrex.json` stay. Line counts before and after go in the port commit.

## 6. SDK gaps (sent to the hub lead and the Tunnels pair)

- G1. Forms and widgets: form routes (`/forms/...` with a query), `form`, `widget` and `error` nodes,
  submit and `$cancel`, the results `{form = route}` and `{close_form = true}`, the form status, and
  palette commands (`hub.register` commands: `surface = 'panel'`, `landing`, `user_only = 'navigation'`,
  routes). The panel has no tab (maintainer, 2026-10-17).
- G2. Refresh from non-SQL state: a scan end, a worker change (`hub.changed`), a focus (`view.seen`)
  change what a panel shows without a SQL write. The SDK needs `app.refresh()` or a dependency on
  a memory value, and handlers for `hub.changed` and `view.seen`.
- G3. Error codes: agents depend on `refused`, `conflict`, `git_error`, `needs_confirmation`,
  `not_found`, `operation_conflict`, `unresolved`, `too_large`. `error('text')` gives text only.
- G4. Saved replies: 7 days and 10 000 keys are not enough for an operation whose result a retry
  must find after a long stop; a running reply (`{status = 'running'}`) must not be saved. So
  Worktrees keeps its own `ops` table and opts out (`{store = false}`). The SDK must not replay a
  saved `running` reply.
- G5. Caller identity: `hub.identify` gives `legacy` IDs after an identity migration; a key of a legacy
  ID must still find its operation. `ctx` needs the aliases, the caller session, and the forwarded
  requester identity (PID) that `hub.spawn` needs for `on_behalf`.
- G6. A start hook and timers: work after start (import, cleanup of phase cleanup), and `rex.after`
  timers (the scan timer, the notification tick) that call SQL outside a handler.
- G7. Hub calls under the SDK: `hub.cwd.*`, `hub.workers`, `hub.profiles`, `hub.spawn` with
  `on_behalf` (the requester PID of a forwarded call), `hub.session.ensure`. And Rex calls.
- G8. KV import: a way to list KV keys by prefix (`open/`, `discard/`) and saved ops, for a one-time import.
- G9. Tests: a sandbox (a plugin with stubbed Git and hub services, controlled timers) like
  `tests/support/sandbox.lua`, and the view size limit (48 KiB) in the SDK's renderer path.
- G10. Long handlers: a create holds no transaction while Git runs, but its phase commits must
  happen in order across a same-key retry. `{tx = false}` per action is the proposal; confirm that
  a same-key retry of a `{tx = false}` action reaches the handler (not a saved reply).
- G11. Phase commits (reviewer): a `{tx = false}` action that persists an intent before external work
  needs an atomic commit of several statements (for example `app.db.tx(fn)`), or a supported
  alternative. The import needs the same, and a restart-safe mark that it is complete.

## 7. Answers (hub lead, hub.sql handoff, 2026-10-22; proposed, not yet implemented)

- G11: `hub.sql.batch {statements}` without `tx` is one all-or-nothing transaction; it works from any
  code. Each phase commit (before an external effect; the result with the cleanup phase) is one batch.
- G3: a hub.sql error message starts with its code (`"<code>: <text>"`); the SDK keeps the code.
- G2: non-SQL state uses `hub.ui.invalidate` and explicit render deps (hub branch hub/render-deps-r1).
- G6: `begin`, `commit` and `batch` work from timers, events and start code.
- G4: the hub saves a reply only for a commit with `key`; Worktrees uses `store = false`.
- G7: raw hub calls (`app.hub`), also `hub.store.*` during the port.
- G8: `hub.store.scan {prefix, after?, limit?}` exists; `hub.store.ops_scan {after?, limit?}` is new (hub lead,
  hub/sql). The import pages through both (section 3).
- G1, G5, G9 and G10 are SDK surfaces (claude-22).
