#!/bin/sh
# Run against a server started with spikes/lab/server.sh. Never select the real server.
set -eu
case "${WORKTREE_LAB_SOCKET:-}" in
  /tmp/rexlab-worktrees-*/rex.sock) ;;
  *) echo 'Set WORKTREE_LAB_SOCKET to /tmp/rexlab-worktrees-<name>/rex.sock' >&2; exit 2 ;;
esac
cd "$(dirname "$0")/../hub"
"${GO_BIN:-go}" test ./cmd/hub -run 'TestWorktree.*Lab|TestCwdLock$' -count=1 -v
