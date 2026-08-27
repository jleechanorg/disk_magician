# FDA Full Attribution Design

## Goal

Produce an exact, current 5-GiB leaf ledger for every path reachable by the
FDA-enabled scanner, and name any remaining inaccessible/APFS allocation as
opaque rather than calling it measured or reclaimable.

## Assumptions and Recommended Defaults

- FDA is available to this session; the scanner must verify its own process
  can read MobileSync, Mail, and Messages before claiming FDA coverage.
- The active state repo is resolved only by `resolve_state_repo_path.py`.
- One frontier run is one measurement pass. No multi-night rows are merged
  into a current ledger.
- The existing 2,700-second cap remains; a cap exhaustion is a partial result,
  not a full attribution result.

## Options Considered

1. Raise or remove the cap. Rejected: it can wedge a loaded host and still
   does not explain inaccessible APFS allocation.
2. Merge frontier work across nights. Rejected: mixed-age rows would falsely
   imply a coherent disk equation.
3. FDA preflight plus an atomic, coverage-gated frontier report. Selected:
   bounded, honest, and compatible with the existing 5-GiB contract.

## Design

The scanner adds an FDA preflight that records the three protected Library
roots as readable, denied, or missing. Its output records a coverage envelope:
all top-level roots must be measured or have a named intrinsic gate. The
renderer writes the mega-table only for a fresh report meeting that envelope;
otherwise it preserves the prior table and writes an explicit partial status.

`history diff` calls the canonical resolver so default 7/30-day floors use the
same state repository as snapshots. Its floor output retains the source ref,
capture time, and residual delta.

## Error Handling and Evidence

Permission and time limits are separate result classes. The output names the
blocked root and gate; it never converts either into a bucket. Tests cover the
configured state repo, FDA-preflight status, an accepted all-root report, and
a rejected partial report. Final evidence is a deployed scanner run, its raw
JSON, ledger validation, and the deployed 7/30-day commands.
