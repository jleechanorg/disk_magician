# PR #138 conflict resolution

### File: `pyproject.toml`

**Conflict Type:** Textual package-version conflict

**Risk Level:** Low

**Original Conflict:**

```toml
# PR head
version = "0.2.186"
# Current base
version = "0.2.179"
```

**Resolution:** Kept `0.2.186` from the PR head.

**Reasoning:** PR #138 changes packaged observer code and therefore must retain
its version bump so uv does not reuse an older wheel. The current base version,
`0.2.179`, is lower; taking it would regress the version and violate the
repository's monotonic-version check. The observer implementation, packaged
mirror, and regression test merged without textual conflicts.
