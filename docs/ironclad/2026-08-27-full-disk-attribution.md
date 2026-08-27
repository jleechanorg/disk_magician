# Ironclad contract — full disk attribution

## Objective

Produce a current, machine-local disk attribution whose full-coverage claim is
both fail-closed in code and supported by a freshly completed scanner run.

## Authoritative acceptance criteria

1. `history diff --days 7` and `--days 30` reject legacy or partial ledgers
   for full-attribution output; the active configured state repository is used.
2. A scanner child enumeration failure is an explicit unfinished path; no
   omitted path can contribute to a `complete` coverage envelope.
3. The frontier report sets `coverage_envelope.complete` only when all of the
   following hold: scanner mode is complete, its FDA preflight is granted,
   every reachable top-level root is measured, and none is unfinished.
4. The mega-table publisher independently validates that envelope, an empty
   `frontier_unfinished`, and a balanced accounting equation before replacing
   the published table. Any violation preserves the old table and records a
   partial status sidecar.
5. Root scripts and `src/disk_magician` mirrors match; the uv-installed CLI is
   rebuilt at a bumped version and its default state resolution is verified.
6. Focused regression suites pass, including each fail-closed condition.
7. One production frontier run after deployment completes with a current
   `coverage_envelope.complete: true`; its resulting ledger is published and
   validates. If it cannot complete inside the configured cap, report that as
   an evidence blocker, never as full attribution.

## Required evidence

- Test output for scanner, renderer/publisher, snapshot commit, and history.
- `sync_package_tree.sh --check`, installed version, and default-state proof.
- Frontier JSON capture time, mode, FDA result, root counts, unfinished count,
  and coverage envelope; published ledger status from the state repository.
- Independent review after the final code and live run.

## Non-goals and safety

No cleanup or deletion is authorized by this contract. Do not overwrite an
existing mega-table with partial data, and preserve unrelated Beads changes.
