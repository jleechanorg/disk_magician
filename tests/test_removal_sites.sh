#!/usr/bin/env bash
# test_removal_sites.sh — T11-13/14/15/16/17 removal-site scope lint.
#
# Purpose: every actual removal in the governed destructors must be preceded by
# a canonical C14 call (`artifact_removal_verdict` / `quarantine_remove` /
# `scratch_budget_quarantine_remove` / `wrh_remove_now`) that names the SAME
# target variable **in the same function**. A file-wide grep is not enough.
#
# This is a PREPARATION unit: the branch under test is not yet integrated with
# the final WRH/scheduler/tier dependencies, so the production audit over the
# pinned file list is expected to report unresolved sites. The self-test
# fixtures prove the lint detects unguarded, wrong-target and forbidden
# removals; the audit prints the exact remaining list for the parent to wire.
#
# Modes:
#   default                      self-test (fatal) + production audit (report)
#   REMOVAL_SITES_AUDIT=1        production unresolved/forbidden sites are fatal
#
# Run: /bin/bash tests/test_removal_sites.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" "${REMOVAL_SITES_AUDIT:-0}" <<'PY'
import os, re, sys

ROOT = sys.argv[1]
AUDIT_FATAL = sys.argv[2] == "1"

# The pinned scope. cleanup_codex_documents.sh is intentionally listed even
# though #151 has not merged here: the audit must name what final integration
# has to supply rather than silently pass on a missing file.
SCOPE = [
    "scripts/worktree_reap.sh",
    "scripts/cleanup_worktrees.sh",
    "scripts/cleanup_tmp.sh",
    "scripts/lib/scratch_budget.sh",
    "scripts/cleanup_code_sign_clones.sh",
    "scripts/cleanup_dev_caches.sh",
    "scripts/cleanup_xcode.sh",
    "scripts/cleanup_worktree_venvs.sh",
    "scripts/cleanup_pr_scratch.sh",
    "scripts/cleanup_llm_inspector.sh",
    "scripts/prune_aside_sessions.py",
    "scripts/cleanup_antigravity_brain.sh",
    "scripts/cleanup_supervisor_logs.sh",
    "scripts/cleanup_codex_documents.sh",
]

SANCTIONED = (
    "artifact_removal_verdict",
    "quarantine_remove",
    "scratch_budget_quarantine_remove",
    "wrh_remove_now",
)

# Lines whose first word is one of these only *mention* a command in a message;
# they never execute a removal.
LOG_FUNCS = {"ledger_line", "log", "echo", "printf", "warn",
             "warn_unbounded_probes_once", "deletion_log", "dbg", "info"}

# Bounded explicit exemptions. Each is an exact tool-owned artifact name; these
# are never "exempt the whole file".
EXEMPT_TARGETS = {
    # tool-owned temp/lock files and script run dirs
    "err", "hit_file", "err_file", "dylib_candidate_file", "snapshot_file",
    "candidates_file", "RUN_TMP", "LOCK", "LOCK_DIR", "_lsof_tmp",
    # immutable hardlink dedup: removing a freshly-made link changes no content
    "tmp_link",
}
# Exact-site exemptions: (file, function, target_var) -> reason.
EXEMPT_SITES = {
    ("worktree_reap.sh", "update", "tmp"):
        "tool-owned atomic-write temp (tempfile.mkstemp)",
    ("worktree_reap.sh", "<toplevel>", "p"):
        "tool-owned stale-lease record GC, not user content",
}
# Delegated uv cache fixture demonstrates the exact-site exemption mechanism.
EXEMPT_SITES[("uv-delegated.sh", "delegate", "uv_cache_dir")] = \
    "delegated uv cache prune (cleanup_uv_cache.sh owns the artifact)"

FUNC_RE = re.compile(r"(?ms)^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*[{(]\n(.*?)^\}")
VAR_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
RM_RE = re.compile(r"\brm\s+(?:-[A-Za-z]+\s+)+([^\n;|&]*)")
FIND_RM_RE = re.compile(r"\bfind\s+(\"[^\"]+\"|\S+)[^\n]*?-exec\s+rm\b")
GIT_REMOVE_RE = re.compile(r"\bgit\s+worktree\s+remove\b([^\n;|&]*)")
GIT_PRUNE_RE = re.compile(r"\bgit\s+worktree\s+prune\b")
PY_RMTREE_RE = re.compile(r"\b(?:shutil\.rmtree|os\.remove|os\.unlink)\s*\(\s*([^),]+)")
PY_UNLINK_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_.]*)\.unlink\s*\(\s*\)")


def bare(tok):
    return tok.strip().strip("\"'{} ").lstrip("$")


def targets_of(text):
    toks = set(VAR_RE.findall(text))
    if not toks:
        toks = {m.group(1) for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", text)}
    return {bare(t) for t in toks if bare(t)}


def guarded_in(body_before, tgt):
    for line in body_before.splitlines():
        for call in SANCTIONED:
            if re.search(r"\b" + re.escape(call) + r"\b", line):
                for var in tgt:
                    if re.search(r"\b" + re.escape(var) + r"\b", line):
                        return True
    return False


def classify(file_name, func_name, line, body_before):
    stripped = line.strip()
    if GIT_PRUNE_RE.search(line):
        return "FORBIDDEN", "git worktree prune"
    first = stripped.split(None, 1)[0] if stripped else ""
    if first in LOG_FUNCS:
        return None, None  # a message that merely mentions a removal
    raw = None
    m = FIND_RM_RE.search(line)          # find ... -exec rm: the root is the target
    if m:
        raw = m.group(1).strip('"')
    if raw is None:
        m = RM_RE.search(line)
        if m:
            raw = m.group(1)
    if raw is None:
        m = GIT_REMOVE_RE.search(line)
        if m:
            raw = m.group(1)
    if raw is None:
        m = PY_RMTREE_RE.search(line)
        if m:
            raw = m.group(1)
    if raw is None:
        m = PY_UNLINK_RE.search(line)
        if m:
            raw = m.group(1)
    if raw is None:
        return None, None

    tgt = targets_of(raw)
    if not tgt:
        return "UNRESOLVED", raw.strip()[:80]
    if guarded_in(body_before, tgt):
        return "GUARDED", "+".join(sorted(tgt))
    if tgt <= EXEMPT_TARGETS:
        return "EXEMPT", "+".join(sorted(tgt))
    for var in tgt:
        if (file_name, func_name, var) in EXEMPT_SITES:
            return "EXEMPT", var
    return "UNRESOLVED", "+".join(sorted(tgt))


def python_spans(src):
    """Indentation-aware def spans; methods included, never cross a lower indent."""
    lines = src.splitlines()
    spans = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
        if not m:
            continue
        indent, name = len(m.group(1)), m.group(2)
        body, j = [], i + 1
        while j < len(lines):
            cur_line = lines[j]
            if cur_line.strip() == "":
                body.append(cur_line); j += 1; continue
            cur = len(cur_line) - len(cur_line.lstrip())
            if cur <= indent:
                break
            body.append(cur_line); j += 1
        spans.append((name, "\n".join(body), i + 1, j))
    return spans


def shell_spans(src):
    spans = []
    for m in FUNC_RE.finditer(src):
        start = src[:m.start()].count("\n") + 1
        end = src[:m.end()].count("\n") + 1
        spans.append((m.group(1), m.group(2), start, end))
    return spans


def lint(file_name, src):
    """Classify every removal site; function-scoped, no file-wide loophole."""
    out = []
    spans = python_spans(src) if file_name.endswith(".py") else shell_spans(src)
    for name, body, start, _end in spans:
        lines = body.splitlines()
        for idx, line in enumerate(lines):
            if line.strip().startswith("#"):
                continue
            verdict, target = classify(file_name, name, line, "\n".join(lines[:idx]))
            if verdict:
                out.append({"file": file_name, "func": name, "line": start + idx + 1,
                            "verdict": verdict, "target": target,
                            "text": line.strip()[:100]})
    covered = set()
    for _n, _b, s, e in spans:
        covered.update(range(s, e + 1))
    for n, line in enumerate(src.splitlines(), 1):
        if n in covered or line.strip().startswith("#"):
            continue
        verdict, target = classify(file_name, "<toplevel>", line, "")
        if verdict:
            out.append({"file": file_name, "func": "<toplevel>", "line": n,
                        "verdict": verdict, "target": target,
                        "text": line.strip()[:100]})
    return out


# ---------------------------------------------------------------- self-tests
FIXTURES = {
    "unguarded.sh": "wipe() {\n  local target=\"$1\"\n  rm -rf \"$target\"\n}\n",
    "guarded.sh": "wipe() {\n  local target=\"$1\"\n  artifact_removal_verdict \"$target\" --kind ephemeral >/dev/null\n  rm -rf \"$target\"\n}\n",
    "find-guarded.sh": "wipe() {\n  local path=\"$1\"\n  artifact_removal_verdict \"$path\" --kind rebuildable >/dev/null\n  find \"$path\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +\n}\n",
    "wrong-target.sh": "wipe() {\n  local target=\"$1\" other=\"$2\"\n  artifact_removal_verdict \"$other\" --kind ephemeral >/dev/null\n  rm -rf \"$target\"\n}\n",
    "forbidden-prune.sh": "wipe() {\n  git worktree prune\n}\n",
    "exempt-tmp.sh": "probe() {\n  local hit_file\n  hit_file=\"$(mktemp)\"\n  rm -f \"$hit_file\"\n}\n",
    "uv-delegated.sh": "delegate() {\n  local uv_cache_dir=\"$1\"\n  cleanup_uv_cache \"$uv_cache_dir\"\n  rm -rf \"$uv_cache_dir\"\n}\n",
    "git-remove-unguarded.sh": "wipe() {\n  local wt=\"$1\"\n  git worktree remove \"$wt\"\n}\n",
    "git-remove-guarded.sh": "wipe() {\n  local wt=\"$1\"\n  wrh_remove_now \"$wt\" \"$wt\"\n  git worktree remove \"$wt\"\n}\n",
    "log-mention.sh": "report() {\n  ledger_line \"guard\" \"ELIGIBLE\" \"$1\" \"\" \" (~1M, rm -rf orphan)\"\n}\n",
    "python-unguarded.py": "def wipe(session_dir):\n    shutil.rmtree(session_dir)\n",
    "python-guarded.py": "def wipe(session_dir):\n    artifact_removal_verdict(session_dir)\n    shutil.rmtree(session_dir)\n",
    "python-exempt.py": "def dedup(tmp_link):\n    tmp_link.unlink()\n",
    "python-method.py": "def helper(x):\n    return x\n\nclass P:\n    def run(self, session_dir):\n        shutil.rmtree(session_dir)\n",
}
EXPECT = {
    "unguarded.sh": [("wipe", "target", "UNRESOLVED")],
    "guarded.sh": [("wipe", "target", "GUARDED")],
    "find-guarded.sh": [("wipe", "path", "GUARDED")],
    "wrong-target.sh": [("wipe", "target", "UNRESOLVED")],
    "forbidden-prune.sh": [("wipe", "git worktree prune", "FORBIDDEN")],
    "exempt-tmp.sh": [("probe", "hit_file", "EXEMPT")],
    "uv-delegated.sh": [("delegate", "uv_cache_dir", "EXEMPT")],
    "git-remove-unguarded.sh": [("wipe", "wt", "UNRESOLVED")],
    "git-remove-guarded.sh": [("wipe", "wt", "GUARDED")],
    "log-mention.sh": [],
    "python-unguarded.py": [("wipe", "session_dir", "UNRESOLVED")],
    "python-guarded.py": [("wipe", "session_dir", "GUARDED")],
    "python-exempt.py": [("dedup", "tmp_link", "EXEMPT")],
    "python-method.py": [("run", "session_dir", "UNRESOLVED")],
}

failures = 0
print("=== removal-site lint self-test ===")
for name, src in FIXTURES.items():
    got = lint(name, src)
    expected = EXPECT[name]
    ok = all(
        any(g["func"] == f and g["target"] == t and g["verdict"] == v for g in got)
        for f, t, v in expected)
    # No unexpected FORBIDDEN/UNRESOLVED that the fixture did not ask for.
    extra = [g for g in got if g["verdict"] in ("FORBIDDEN", "UNRESOLVED")
             and not any(g["func"] == f and g["verdict"] == v for f, _t, v in expected)]
    if ok and not extra:
        print(f"PASS fixture {name}")
    else:
        failures += 1
        print(f"FAIL fixture {name}: got {got} expected {expected}")

for fname, src in [
    ("late-guard.sh",
     "wipe() {\n  local target=\"$1\"\n  rm -rf \"$target\"\n  artifact_removal_verdict \"$target\" --kind ephemeral >/dev/null\n}\n"),
    ("wrong-target-python.py",
     "def wipe(session_dir, other):\n    artifact_removal_verdict(other)\n    shutil.rmtree(session_dir)\n"),
]:
    got = lint(fname, src)
    if got and got[-1]["verdict"] == "UNRESOLVED":
        print(f"PASS fixture {fname}")
    else:
        failures += 1
        print(f"FAIL fixture {fname}: {got}")

# ------------------------------------------------------------- production audit
print()
print("=== production audit (pre-integration; unresolved sites are expected) ===")
unresolved, forbidden, missing = [], [], []
for rel in SCOPE:
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        missing.append(rel)
        print(f"MISSING    {rel}")
        continue
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    for site in lint(os.path.basename(rel), src):
        if site["verdict"] == "UNRESOLVED":
            unresolved.append(site)
            print(f"UNRESOLVED {rel}:{site['line']} {site['func']}() "
                  f"target={site['target']} :: {site['text']}")
        elif site["verdict"] == "FORBIDDEN":
            forbidden.append(site)
            print(f"FORBIDDEN  {rel}:{site['line']} {site['text']}")

print()
print("=== T11-14 positive wiring (already landed) ===")
def _body(src, name):
    m = re.search(r"(?ms)^" + re.escape(name) + r"\(\)\s*[{(]\n(.*?)^\}", src)
    return m.group(1) if m else ""
tmp_src = open(os.path.join(ROOT, "scripts/cleanup_tmp.sh"), encoding="utf-8").read()
budget_src = open(os.path.join(ROOT, "scripts/lib/scratch_budget.sh"), encoding="utf-8").read()
t11_pairs = [
    (_body(tmp_src, "remove_path"), 'scratch_budget_quarantine_remove "$path"'),
    (_body(tmp_src, "purge_aged_archives"), 'scratch_budget_quarantine_remove "$d"'),
    (_body(budget_src, "scratch_budget_evict_root"), 'scratch_budget_quarantine_remove "$item_i"'),
    (_body(budget_src, "scratch_budget_quarantine_remove"), "--kind ephemeral"),
]
t11_fail = [needle for body, needle in t11_pairs if needle not in body]
if t11_fail:
    failures += len(t11_fail)
    print(f"FAIL T11-14 positive wiring missing: {t11_fail}")
else:
    print("PASS T11-14 cleanup_tmp/scratch_budget route through C14")

print()
print(f"self-test failures: {failures}")
print(f"unresolved removal sites: {len(unresolved)}")
print(f"forbidden sites: {len(forbidden)}")
print(f"missing scope files: {len(missing)} ({', '.join(missing) or 'none'})")

fatal = failures > 0
if AUDIT_FATAL and (unresolved or forbidden or missing):
    fatal = True
if fatal:
    print("RESULT: FAIL")
    sys.exit(1)
print("RESULT: PASS (self-test green; production audit report-only)")
PY

PASS=0
FAIL=0
check() {
  local name="$1" condition="$2"
  if eval "$condition"; then
    echo "PASS $name"
    PASS=$(( PASS + 1 ))
  else
    echo "FAIL $name"
    FAIL=$(( FAIL + 1 ))
  fi
}
echo "=== mirror parity ==="
check "cleanup_tmp package mirror matches" "cmp -s '$ROOT/scripts/cleanup_tmp.sh' '$ROOT/src/disk_magician/scripts/cleanup_tmp.sh'"
check "scratch_budget package mirror matches" "cmp -s '$ROOT/scripts/lib/scratch_budget.sh' '$ROOT/src/disk_magician/scripts/lib/scratch_budget.sh'"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
