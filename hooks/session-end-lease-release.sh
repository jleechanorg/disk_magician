#!/usr/bin/env bash
# SessionEnd hook template (spec C8; installing it needs decision D6).
# Marks the ending session's worktree leases released. Deletes nothing,
# prints nothing and always exits 0, so it can never block a session exit.
sid="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id") or "")' 2>/dev/null)"
if [[ "$sid" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
    "${DISKM_BIN:-diskm}" lease-release --owner-session "$sid" >/dev/null 2>&1
fi
exit 0
