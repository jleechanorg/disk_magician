---
title: Root FDA preflight outcomes differ across observed invocation contexts
hostname: jeffreys-macbook-pro.local
date: 2026-10-04
status: active
paths:
  - /tmp/disk-collector-activation-20261004/first-root-probe-summary.json
  - /tmp/disk-frontier-home-20261004/deployed-root-preflight.json
  - /tmp/disk-root-tcc-20261004.log
  - /tmp/disk-root-runner-auth-20261004.log
safety_rule: none
---

## What

Two root scanner runs returned different FDA results. The immutable admin
authtrampoline run recorded in
`/tmp/disk-collector-activation-20261004/first-root-probe-summary.json`
used root privileges but was denied on five of six probes (`mobile_sync`,
`mail`, `messages`, `spotlight`, and `document_revisions`), could read only
`fseventsd`, and reached its 900.1-second bound with a partial coverage
envelope. A later normal existing-sudo invocation of the installed CLI, using
the validated `--scan-user-home /Users/jleechan` identity, recorded in
`/tmp/disk-frontier-home-20261004/deployed-root-preflight.json`, read all six
user and system probes in 2.4 seconds. This is evidence about these two
invocation contexts and runs, not a claim of global unreadability or global FDA
grant. The runs were not a controlled comparison: time, interpreter, scanner
version, and arguments also differed. Route-dependent TCC is a plausible
explanation, not an isolated causal conclusion. The later JSON records root
execution and arguments but does not attest its executable or parent process.

## Why it matters

An authtrampoline denial must not be promoted into a machine-wide TCC or FDA
diagnosis, and the successful six-probe preflight must not be promoted into a
full-volume or scheduled-daemon proof. The successful run deliberately used a
two-second wall-clock cap and `--max-depth 0`; its `coverage_envelope.complete`
was false with seven unfinished top-level roots. The remaining question is
whether the intended root runner and its scheduled launchd route can collect
and publish a complete result. At 09:12 UTC, the update request remained pending with no installer process.
The authd log ties its osascript PID 68361 to engine 683, which rejected an
expired cached credential and entered `builtin:authenticate` at 09:02:34 UTC.
Waiting for administrator authentication is an inference from these records;
no visible authentication prompt was captured.

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
- 2026-10-04 — recorded an invocation-context discrepancy;
  full-volume and scheduled-daemon behavior remain unproven pending the
  root-runner update and actual collection.
