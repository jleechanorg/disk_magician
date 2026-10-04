---
title: FDA results are execution-route-specific for root frontier collection
hostname: jeffreys-macbook-pro.local
date: 2026-10-04
status: active
paths:
  - /tmp/disk-collector-activation-20261004/first-root-probe-summary.json
  - /tmp/disk-frontier-home-20261004/deployed-root-preflight.json
safety_rule: none
---

## What

The scanner's FDA result differs by execution route. The immutable admin
authtrampoline run recorded in
`/tmp/disk-collector-activation-20261004/first-root-probe-summary.json`
used root privileges but was denied on five of six probes (`mobile_sync`,
`mail`, `messages`, `spotlight`, and `document_revisions`), could read only
`fseventsd`, and reached its 900.1-second bound with a partial coverage
envelope. A later normal existing-sudo invocation of the installed CLI, using
the validated `--scan-user-home /Users/jleechan` identity, recorded in
`/tmp/disk-frontier-home-20261004/deployed-root-preflight.json`, read all six
user and system probes in 2.4 seconds. This is evidence about these two
process routes and runs, not a claim of global unreadability or global FDA
grant.

## Why it matters

An authtrampoline denial must not be promoted into a machine-wide TCC or FDA
diagnosis, and the successful six-probe preflight must not be promoted into a
full-volume or scheduled-daemon proof. The successful run deliberately used a
two-second wall-clock cap and `--max-depth 0`; its `coverage_envelope.complete`
was false with seven unfinished top-level roots. The remaining question is
whether the intended root runner and its scheduled launchd route can collect
and publish a complete result. At 09:06 UTC, the already-authorized root-runner update was awaiting
macOS administrator authentication.

## Guards / governance

No `safety.local.json` rule is justified: this finding concerns access-route
provenance and does not authorize deletion or change cleanup enforcement.
Keep both raw JSON artifacts with their route-specific provenance. A full-volume claim requires a fresh complete collection, and a scheduled
operation claim requires evidence from the intended launchd execution route.
Do not change FDA settings or sudoers based on either route alone. Related implementation and evidence are
tracked in [PR #98](https://github.com/jleechanorg/disk_magician/pull/98)
(prod +47/-11, non-prod +67/-0; evidence gist
[published evidence](https://gist.github.com/jleechan2015/fc23374cee16a64d53ead3b97a4f9f6c)).

## History

- 2026-10-04 — immutable admin authtrampoline root probe denied 5/6 FDA
  targets and timed out at the 900-second bound; diagnostic summary preserved in
  `first-root-probe-summary.json`.
- 2026-10-04 — normal existing-sudo installed CLI with explicit validated
  `/Users/jleechan` identity read all 6 FDA probes in 2.4 seconds; the
  intentionally bounded run remained partial; raw result preserved in
  `deployed-root-preflight.json`.
- 2026-10-04 — classified the discrepancy as execution-route-specific;
  full-volume and scheduled-daemon behavior remain unproven pending the
  root-runner update and actual collection.
