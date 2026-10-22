3 matches in 2 files:

37:0:refs/heads/gone"   # advertised, then deleted below
tests/test_cleanup_worktrees_detached_origin.sh:38:git -C "$REPO" fetch -q origin
tests/test_cleanup_worktrees_detached_origin.sh:44:git -C "$TMP_ROOT/origin.git" update-ref -d refs/heads/gone
