---
title: Root privileges alone do not establish FDA evidence
hostname: jeffreys-macbook-pro.local
date: 2026-10-04
status: active
paths:
  - /tmp/disk-collector-activation-20261004/first-root-probe-summary.json
  - /tmp/disk-frontier-home-20261004/deployed-root-preflight.json
safety_rule: none
---

## What

Two scanner reports recorded root execution (`sudo_used: true`) but different
FDA preflight outcomes. The first report records five denied probes and one
readable probe (`fseventsd`), 900.1 seconds elapsed, and incomplete coverage.
The later report records all six probes readable, 2.4 seconds elapsed, and
incomplete coverage with seven unfinished top-level roots. Its arguments
include `--scan-user-home /Users/jleechan`, `--wall-clock-cap 2`, and
`--max-depth 0`.

These JSON artifacts establish the measured outcomes, not their cause. They
do not share process identifiers or attest the executable and parent process.
The runs were not a controlled comparison; time, implementation and arguments
could differ. No execution route is established as the sole cause here.

## Why it matters

Root execution does not by itself establish FDA access. Use the particular
run's probe results. A denied run does not establish a permanent machine-wide
permission wall, and six readable probes do not establish full-volume or
scheduled-daemon coverage. A full-volume claim needs a fresh complete result;
a scheduled-operation claim needs evidence from that execution context.

## Guards / governance

No `safety.local.json` rule is justified: this finding changes neither deletion
permissions nor cleanup enforcement. The observed discrepancy is not authority
to change FDA settings or sudoers. Related CLI input work is recorded in
[PR #98](https://github.com/jleechanorg/disk_magician/pull/98)
(prod +47/-11, non-prod +67/-0), with
[published evidence](https://gist.github.com/jleechan2015/fc23374cee16a64d53ead3b97a4f9f6c).

## History

- 2026-10-04 — preserved the first diagnostic summary and later preflight JSON;
  documented their differing root/FDA outcomes without a causal attribution.
