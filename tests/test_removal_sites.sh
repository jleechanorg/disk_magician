#!/usr/bin/env bash
# test_removal_sites.sh — T11-13/14/15/16/17 removal-site scope lint.
#
# Purpose: every actual removal in the governed destructors must be preceded by
# a canonical C14 call (`artifact_removal_verdict` / `quarantine_remove` /
# `scratch_budget_quarantine_remove`) that names the SAME target variable **in
# the same function**.  `wrh_remove_now` is a removal entry point, NOT a C14
# guard; a direct call without a prior same-target C14 is reported.
#
# The lint follows the real transitive local dependency closure (shell source /
# exec / python .py references / local python imports) from the spec §7.2 roots.
# A local dependency that cannot be resolved or does not exist is reported and,
# in strict audit mode, fails the run — it is never silently omitted.
#
# Modes:
#   default                      self-test (fatal) + production audit (report)
#   REMOVAL_SITES_AUDIT=1        unresolved/forbidden/dependency failures fatal
#
# Run: /bin/bash tests/test_removal_sites.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/sandbox_env.sh
source "$ROOT/tests/lib/sandbox_env.sh"

# This lint reads and analyzes destructive cleanup sources but never executes a
# cleanup command. Keep its temporary dependency-closure fixtures inside an
# explicit sandbox so the test remains valid under the repository's sandbox
# context lint and any future fixture operation fails closed.
TEST_SANDBOX="$(mktemp -d /tmp/disk-magician-removal-sites.XXXXXX)" || {
  echo "FATAL: could not allocate /tmp sandbox" >&2
  exit 2
}
if [[ -z "$TEST_SANDBOX" || ! -d "$TEST_SANDBOX" || -L "$TEST_SANDBOX" ]]; then
  echo "FATAL: invalid or symlinked sandbox '$TEST_SANDBOX'" >&2
  exit 2
fi
TEST_SANDBOX="$(cd "$TEST_SANDBOX" && pwd -P)" || {
  echo "FATAL: could not canonicalize sandbox" >&2
  exit 2
}
case "$TEST_SANDBOX" in
  /tmp/*|/private/tmp/*) ;;
  *) echo "FATAL: sandbox not under /tmp: '$TEST_SANDBOX'" >&2; exit 2 ;;
esac
trap 'rm -rf "$TEST_SANDBOX"' EXIT
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_TEST_SANDBOX="$TEST_SANDBOX"

python3 - "$ROOT" "${REMOVAL_SITES_AUDIT:-0}" <<'PY'
import os, re, sys, json, tempfile, ast, textwrap

ROOT = os.path.abspath(sys.argv[1])
AUDIT_FATAL = sys.argv[2] == "1"

# Spec §7.2 entry scope.  cleanup_codex_documents.sh is intentionally listed
# even though #151 has not merged here: the audit must name what final
# integration has to supply rather than silently pass on a missing file.
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
    # spec7.2 additions (Task 15)
    "scripts/tmp_scratch_sweep.sh",
    "scripts/prune_aside_sessions.sh",
    "scripts/cleanup_uv_cache.sh",
]

# Canonical C14 guards: a removal is authorized only when one of these names the
# same target leaf variable earlier in the same function.
SANCTIONED = (
    "artifact_removal_verdict",
    "quarantine_remove",
    "scratch_budget_quarantine_remove",
)

# Removal entry points that are NOT guards themselves.
REMOVAL_ENTRY = ("wrh_remove_now",)

# Lines whose first word only *mentions* a command in a message.
LOG_FUNCS = {"ledger_line", "log", "echo", "printf", "warn",
             "warn_unbounded_probes_once", "deletion_log", "dbg", "info",
             "wrh_log", "declare"}

# Delegated tools: exact command, audit-only, never claimed as C14 inside the
# tool.  Keep this list to literal, fully-named commands.
DELEGATED_CMDS = {
    "uv cache prune --force": "delegated uv reference-tracking prune; uv owns the artifact identity",
    "pnpm store prune": "delegated pnpm content-addressable store prune; pnpm owns unreferenced blob GC",
}

# Bounded exact-site exemptions: (file, function, kind) or (file, function, var).
# Each carries a rationale and, for temp/lock artifacts, a provenance check.
EXEMPT_SITES = {
    ("worktree_reap.sh", "update", "python-unlink"):
        "tool-owned atomic-write temp (tempfile.mkstemp, same-dir os.replace)",
    ("worktree_reap.sh", "<toplevel>", "python-unlink"):
        "stale-lease record GC; target already os.path.lexists checked",
    ("worktree_reap.sh", "cleanup", "LOCK"):
        "tool-owned reap lock dir; contents limited to pid/acquired_at",
    ("worktree_reap.sh", "cleanup", "RUN_TMP"):
        "tool-owned mktemp -d run dir",
    ("cleanup_worktrees.sh", "cleanup", "RUN_TMP"):
        "tool-owned run dir",
    ("prune_aside_sessions.py", "dedup_static_assets", "python-unlink"):
        "aside hardlink dedup: removing a freshly created .tmp_dedup_ link",
    ("quarantine_rename.py", "index_write", "python-unlink"):
        "tool-owned atomic quarantine index temp under a pinned dir fd",
    ("quarantine_rename.py", "index_drop", "python-unlink"):
        "tool-owned quarantine index sidecar under a pinned dir fd",
    ("quarantine_rename.py", "index_mark_terminal", "python-unlink"):
        "tool-owned quarantine index sidecar under a pinned dir fd",
    ("quarantine_rename.py", "finish_sidecar", "python-unlink"):
        "tool-owned quarantine sidecar cleanup under a pinned dir fd",
    ("quarantine_rename.py", "reconcile_one", "python-unlink"):
        "tool-owned quarantine journal/sidecar under a pinned dir fd",
    ("quarantine_rename.py", "quarantine_restore", "python-unlink"):
        "tool-owned quarantine restore sidecar under a pinned dir fd",
    ("quarantine_rename.py", "update_sidecar", "python-unlink"):
        "tool-owned atomic sidecar temp under a pinned dir fd",
    ("quarantine_rename.py", "quarantine_reconcile", "python-unlink"):
        "tool-owned reconcile cursor file",
    ("worktree_reap.sh", "acquire_lock", "LOCK"):
        "tool-owned reap lock dir; contents limited to pid/acquired_at",
    ("cleanup_worktrees.sh", "<toplevel>", "RUN_TMP"):
        "tool-owned run dir",
    ("cleanup_worktrees.sh", "<toplevel>", "_lsof_tmp"):
        "tool-owned mktemp lsof stderr file",
    ("disk_budget.py", "dispatch_actuators", "python-unlink"):
        "tool-owned per-run C14 ledger file",
    ("worktree_merged_pr.sh", "worktree_pr_cache_populate", "response"):
        "tool-owned gh response temp derived from a mktemp path",
    ("cleanup_worktree_venvs.sh", "acquire_cleanup_venvs_lock", "LOCK_DIR"):
        "tool-owned venv-cleanup lock dir",
    ("cleanup_tmp.sh", "cleanup_tmp_exit_trap", "dylib_candidate_file"):
        "tool-owned mktemp candidate list",
    ("cleanup_tmp.sh", "<toplevel>", "dylib_candidate_file"):
        "tool-owned mktemp candidate list",
    ("artifact_verdict.sh", "_av_artifact_removal_verdict", "rm-file"):
        "tool-owned inventory temp in the shared C14 verdict",
    ("artifact_verdict.sh", "artifact_removal_verdict", "rm-file"):
        "tool-owned inventory/admin temp in the shared C14 verdict",
    ("worktree_lease.sh", "lease_claim_reuse", "python-rmdir"):
        "tool-owned reuse lock dir",
    ("worktree_lease.sh", "<toplevel>", "python-unlink"):
        "tool-owned lease temp (same-dir os.replace)",
    ("worktree_lease.sh", "lease_prune_birth_audit_scratch", "python-unlink"):
        "stale-lease birth-audit scratch GC; target already os.path.lexists and TTL checked",
    ("worktree_remove_hook.sh", "wrh_remove_now", "rm-file"):
        "tool-owned worktree lease record after a successful removal",
}

# Small set of tool-owned directory variables that are not mktemp-derived but
# are assigned in the owning file; an exact-site match is still required.
TOOL_DIR_VARS = {"LOCK", "LOCK_DIR", "RUN_TMP"}
TOOL_TEMP_VARS = {"_lsof_tmp"}

FUNC_RE = re.compile(r"(?ms)^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*[{(]\n(.*?)^\}")
VAR_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")


def bare(tok):
    return tok.strip().strip("\"'{} ").lstrip("$")


def vars_in(text):
    return VAR_RE.findall(text)


PY_KEYWORDS = {"os", "shutil", "self", "if", "not", "and", "or", "dir_fd",
               "True", "False", "None", "with", "open", "return"}


def vars_from(text, is_python):
    if is_python:
        return [t for t in re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", text or "")
                if t not in PY_KEYWORDS]
    return VAR_RE.findall(text or "")


def leaf_var(expr):
    toks = VAR_RE.findall(expr)
    return toks[-1] if toks else None


# --------------------------------------------------------------- detection
FIND_DELETE = re.compile(r"\bfind\b(.*?)\s-delete\b")
FIND_EXEC_RM = re.compile(r"\bfind\b(.*?)\s-exec\s+rm\b")
GIT_PRUNE = re.compile(r"\bgit\b(?:\s+-C\s+\S+)?\s+worktree\s+prune\b")
GIT_REMOVE = re.compile(r"\bgit\b(?:\s+-C\s+\S+)?\s+worktree\s+remove\b([^\n]*)")
UV_PRUNE = re.compile(r"\buv\s+cache\s+prune(?:\s+--force)?\b")
PNPM_PRUNE = re.compile(r"\bpnpm\s+store\s+prune\b")
WRH_REMOVE = re.compile(r"\bwrh_remove_now\b(.*)")
# rm must not match --rm / -exec rm (handled separately) or identifiers.
RM_RE = re.compile(r"(?<![\w-])rm\s+((?:-[A-Za-z-]+\s+)*)([^;|&}\n]*)")
PY_DELETE = re.compile(
    r"\b(?:shutil\.rmtree|os\.remove|os\.unlink|os\.rmdir)\s*\(\s*([^,)]+)")
PY_UNLINK = re.compile(r"\b([A-Za-z_][A-Za-z0-9_.]*)\.unlink\s*\(\s*\)")


def first_path_arg(text):
    """Best-effort first quoted/token argument of a find expression."""
    m = re.search(r'("[^"]+"|\'[^\']+\'|[^\s]+)', text or "")
    return m.group(1) if m else ""


def word_targets(text):
    """Split a shell target list into per-target expressions."""
    toks = re.findall(r'"[^"]*"|\'[^\']*\'|[^\s;|&]+', text or "")
    skip = {"}", "{", "fi", "done", "then", "else", "return", "echo", "grep",
            "||", "&&", ";", "EXIT", "'", '"', "`"}
    out = []
    for t in toks:
        if not t or t in skip:
            continue
        if t.startswith("-") or t.startswith(">") or t.startswith("<") or t.startswith("2>"):
            continue
        if t.isdigit() or "$(" in t or "`" in t:
            continue
        out.append(t)
    return out


def detect(line, is_python=False):
    """Return removal descriptors in one physical line."""
    vf = lambda text: vars_from(text, is_python)
    out = []
    if UV_PRUNE.search(line):
        out.append({"kind": "delegated-uv", "expr": "uv cache prune --force",
                    "vars": []})
        return out
    if PNPM_PRUNE.search(line):
        out.append({"kind": "delegated-pnpm", "expr": "pnpm store prune",
                    "vars": []})
        return out
    if GIT_PRUNE.search(line):
        out.append({"kind": "git-prune", "expr": "git worktree prune", "vars": []})
        return out
    m = FIND_DELETE.search(line)
    if m:
        root = first_path_arg(m.group(1))
        out.append({"kind": "find-delete", "expr": root, "vars": vf(root)})
    m = FIND_EXEC_RM.search(line)
    if m:
        root = first_path_arg(m.group(1))
        out.append({"kind": "find-exec-rm", "expr": root, "vars": vf(root)})
    if FIND_DELETE.search(line) or FIND_EXEC_RM.search(line):
        # The rm inside -exec is already accounted for; do not double count.
        if GIT_REMOVE.search(line):
            pass
        else:
            return out
    m = GIT_REMOVE.search(line)
    if m:
        for tgt in word_targets(m.group(1)):
            out.append({"kind": "git-worktree-remove", "expr": tgt,
                        "vars": vf(tgt)})
    m = WRH_REMOVE.search(line)
    if m:
        args = word_targets(m.group(1))
        if args:
            out.append({"kind": "wrh-remove", "expr": args[0], "vars": vf(args[0])})
    m = RM_RE.search(line)
    if m:
        recursive = bool(re.search(r"[rR]", m.group(1) or ""))
        for tgt in word_targets(m.group(2)):
            out.append({"kind": "rm-dir" if recursive else "rm-file",
                        "expr": tgt, "vars": vf(tgt)})
    m = PY_DELETE.search(line)
    if m:
        kind = "python-unlink" if "unlink" in m.group(0) else (
            "python-rmdir" if "rmdir" in m.group(0) else "python-rmtree")
        out.append({"kind": kind, "expr": m.group(1).strip(),
                    "vars": vars_from(m.group(1), True)})
    m = PY_UNLINK.search(line)
    if m:
        out.append({"kind": "python-unlink", "expr": m.group(1),
                    "vars": vars_from(m.group(1), True)})
    return out


# --------------------------------------------------------------- guard logic
def guard_vars(body_before, is_python=False):
    found = set()
    for line in body_before.splitlines():
        for call in SANCTIONED:
            if re.search(r"\b" + re.escape(call) + r"\b", line):
                found.update(vars_from(line, is_python))
    return found


def guarded(body_before, target_vars, is_python=False):
    """Guard must name the removal's *leaf* variable (not a shared prefix)."""
    if not target_vars:
        return False
    leaf = target_vars[-1]
    return leaf in guard_vars(body_before, is_python)


# --------------------------------------------------------------- exemptions
def provable_temp(body_before, var):
    if not var:
        return False
    name = re.escape(var)
    pats = (
        r"(?m)(?:^|[, \t])" + name + r"\s*=\s*[^\n]*mktemp",
        r"(?m)(?:^|[, \t])" + name + r"\s*=\s*[^\n]*mkstemp",
        r"(?m)(?:^|[, \t])" + name + r"\s*=\s*[^\n]*tempfile\.",
        r"(?m)(?:^|[, \t])" + name + r"\s*=\s*[^\n]*NamedTemporaryFile",
    )
    return any(re.search(p, body_before) for p in pats)


def verifier_backed(body, line, kind):
    """fd-relative inventory unlink/rmdir with in-function identity checks."""
    if kind not in ("python-unlink", "python-rmdir"):
        return False
    if "dir_fd=" not in line:
        return False
    markers = ('expected.get("ino")', "expected.get('ino')", "sha256",
               "st_ino", "readlink", "expected.get(\"dev\")")
    return any(m in body for m in markers)


# Tool-owned metadata/sidecar removal sites. Each key names an exact
# (file, function, kind); a match must ALSO pass the matching provenance
# predicate, so a similarly named user path or an unanchored removal in the
# same function stays UNRESOLVED. These are records the tool itself creates
# next to its own state (observer rotations, reuse-lock members, quarantine
# temp bindings) — never artifact content.
METADATA_SITES = {
    ("disk_observer.py", "rotate_if_needed", "python-unlink"): "rotation-sibling",
    ("worktree_lease.sh", "lease_claim_reuse", "python-unlink"): "reuse-lock-member",
    ("worktree_lease.sh", "lease_reuse_lock_recover", "rm-file"): "reuse-lock-member",
    ("worktree_lease.sh", "lease_reuse_lock_release", "rm-file"): "reuse-lock-member",
    ("quarantine_rename.py", "reconcile_record", "python-unlink"): "named-temp-binding",
}


def _prov_rotation_sibling(d, body_before, body, line):
    """disk_observer rotation: the removed leaf is built from this function's
    own `path` parameter plus the bounded integer loop index, exactly
    Path(f"{path}.{index}").  A traversal component, a different suffix, an
    unbounded/non-loop index, or any reassignment of `path`/the leaf is rejected."""
    var = d["vars"][-1] if d["vars"] else ""
    if var not in ("archive", "destination"):
        return False
    # exactly one assignment to the removed leaf: no later reassignment
    if len(re.findall(r"(?m)^\s*" + re.escape(var) + r"\s*=", body)) != 1:
        return False
    anchored = re.search(
        r"(?m)^\s*" + re.escape(var) +
        r'\s*=\s*Path\(\s*f(["\'])\{path\}\.\{index\}\1\s*\)\s*$', body)
    if not anchored:
        return False
    # the anchored assignment must be the one before this removal site
    if anchored.group(0).strip() not in body_before:
        return False
    # `path` is the function parameter, never reassigned
    if re.search(r"(?m)^\s*path\s*=", body):
        return False
    # `index` is bound only by a bounded range() loop before the assignment
    if re.search(r"(?m)^\s*for\s+index\s+in\s+range\s*\([^)]*\)\s*:", body_before) is None:
        return False
    if re.search(r"(?m)^\s*index\s*=", body):
        return False
    return True


def _prov_reuse_lock_member(d, body_before, body, line):
    """worktree_lease reuse-lock: only the two fixed members (`pid`,
    `acquired_at`) of a lock dir anchored to this function's own lease path +
    the fixed literal `.reuse-lock`.  Any other member/suffix, an unbound
    member, an arbitrary lock base, or a lock reassignment before the removal
    stays UNRESOLVED."""
    expr = (d["expr"] or "").strip().strip("\"'")
    if d["kind"] == "python-unlink":
        # lease_claim_reuse heredoc: os.unlink(os.path.join(lock, <member>))
        if re.search(r"os\.path\.join\(\s*lock\b", line or "") is None:
            return False
        # anchored lock construction: exactly one assignment, exact suffix
        if len(re.findall(r"(?m)^\s*lock\s*=", body)) != 1:
            return False
        if re.search(r'(?m)^\s*lock\s*=\s*path\s*\+\s*"\.reuse-lock"\s*$', body) is None:
            return False
        if re.search(r'(?m)^\s*lock\s*=\s*path\s*\+\s*"\.reuse-lock"\s*$', body_before) is None:
            return False
        # the member loop must be restricted to exactly the two fixed names
        loop = re.search(
            r'(?m)^\s*for\s+([A-Za-z_]\w*)\s+in\s*\(\s*"pid"\s*,\s*"acquired_at"\s*\)\s*:',
            body_before)
        if not loop:
            return False
        member = loop.group(1)
        if re.search(r"os\.path\.join\(\s*lock\s*,\s*" + re.escape(member) + r"\s*\)",
                     line or "") is None:
            return False
        # the loop member must not be reassigned later
        if re.search(r"(?m)^\s*" + re.escape(member) + r"\s*=", body):
            return False
        return True
    # shell form anchored to a local lock="$1.reuse-lock" assignment
    if re.fullmatch(r"\$lock/(pid|acquired_at)", expr):
        if len(re.findall(r'(?<![A-Za-z0-9_])lock\s*=', body)) != 1:
            return False
        if re.search(r'(?<![A-Za-z0-9_])lock\s*=\s*"\$1\.reuse-lock"', body) is None:
            return False
        if re.search(r'(?<![A-Za-z0-9_])lock\s*=\s*"\$1\.reuse-lock"', body_before) is None:
            return False
        refs = re.findall(r'\$\{?lock\}?/([A-Za-z0-9_.-]+)', body)
        return bool(refs) and all(r in ("pid", "acquired_at") for r in refs)
    # shell form anchored to the function's own positional lease
    if re.fullmatch(r"\$1\.reuse-lock/(pid|acquired_at)", expr):
        if re.search(r"(?m)^\s*set\s+--", body):
            return False
        refs = re.findall(r'\$1\.reuse-lock/([A-Za-z0-9_.-]+)', body)
        return bool(refs) and all(r in ("pid", "acquired_at") for r in refs)
    return False


def _named_temp_call_ok(call):
    """Exact NamedTemporaryFile shape: dir=index_dir() and prefix='.reconcile.'."""
    f = call.func
    name = f.attr if isinstance(f, ast.Attribute) else (
        f.id if isinstance(f, ast.Name) else None)
    if name != "NamedTemporaryFile":
        return False
    kw = {k.arg: k.value for k in call.keywords}
    dnode, pnode = kw.get("dir"), kw.get("prefix")
    if not (isinstance(dnode, ast.Call) and isinstance(dnode.func, ast.Name)
            and dnode.func.id == "index_dir"):
        return False
    return isinstance(pnode, ast.Constant) and pnode.value == ".reconcile."


def _prov_named_temp_binding(d, body_before, body, line):
    """quarantine reconcile: `binding_path` is the `.name` of the SAME
    NamedTemporaryFile handle the function creates under index_dir() with the
    fixed `.reconcile.` prefix.  An unrelated tempfile, a different prefix/dir,
    or any reassignment of binding_path or the handle between allocation and
    removal must not exempt the site."""
    var = d["vars"][-1] if d["vars"] else ""
    if var != "binding_path":
        return False
    try:
        tree = ast.parse(textwrap.dedent(body))
    except SyntaxError:
        return False
    handles = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.With):
            continue
        for item in node.items:
            call = item.context_expr
            if not (isinstance(call, ast.Call) and _named_temp_call_ok(call)):
                continue
            if not isinstance(item.optional_vars, ast.Name):
                continue
            handle = item.optional_vars.id
            for sub in ast.walk(node):
                if (isinstance(sub, ast.Assign) and len(sub.targets) == 1
                        and isinstance(sub.targets[0], ast.Name)
                        and sub.targets[0].id == "binding_path"
                        and isinstance(sub.value, ast.Attribute)
                        and sub.value.attr == "name"
                        and isinstance(sub.value.value, ast.Name)
                        and sub.value.value.id == handle):
                    handles.append(handle)
    if len(handles) != 1:
        return False
    handle = handles[0]
    # exactly one binding_path assignment in the whole function
    bp_assigns = [n for n in ast.walk(tree)
                  if isinstance(n, ast.Assign)
                  and any(isinstance(t, ast.Name) and t.id == "binding_path"
                          for t in n.targets)]
    if len(bp_assigns) != 1:
        return False
    # the same handle must never be rebound before the removal
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == handle:
                    return False
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == handle:
            return False
        if isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Name) and node.target.id == handle:
            return False
        if isinstance(node, (ast.For, ast.AsyncFor)) and isinstance(node.target, ast.Name) and node.target.id == handle:
            return False
        if isinstance(node, ast.comprehension) and isinstance(node.target, ast.Name) and node.target.id == handle:
            return False
    # the anchored binding must precede this removal site
    if re.search(r"binding_path\s*=\s*" + re.escape(handle) + r"\.name\b", body_before) is None:
        return False
    return True


_METADATA_PROV = {
    "rotation-sibling": _prov_rotation_sibling,
    "reuse-lock-member": _prov_reuse_lock_member,
    "named-temp-binding": _prov_named_temp_binding,
}


def metadata_exempt(file_name, func_name, d, body_before, body, line):
    kind = METADATA_SITES.get((file_name, func_name, d["kind"]))
    if not kind:
        return False
    return _METADATA_PROV[kind](d, body_before, body, line)


def is_exempt(file_name, func_name, d, body_before, body, file_src, line):
    var = d["vars"][-1] if d["vars"] else ""
    # tool-owned metadata with a provenance-bound exact site (never blanket)
    if metadata_exempt(file_name, func_name, d, body_before, body, line):
        return True
    # exact site keyed by (file, func, kind)
    if (file_name, func_name, d["kind"]) in EXEMPT_SITES:
        # tool-owned artifacts still need to look tool-owned
        if d["kind"] == "python-unlink" and func_name == "update":
            return provable_temp(body_before, var) or var == "tmp"
        return True
    # exact site keyed by (file, func, var)
    if (file_name, func_name, var) in EXEMPT_SITES:
        if var in TOOL_DIR_VARS or var in TOOL_TEMP_VARS:
            return bool(re.search(r"(?m)^\s*" + re.escape(var) + r"\s*=", file_src))
        return True
    # provenance-constrained: only files created by the tool in this function
    if d["kind"] in ("rm-file", "rm-dir", "python-unlink", "python-rmdir") and provable_temp(body_before, var):
        return True
    return False


# --------------------------------------------------------------- classify
def classify(file_name, func_name, line, body_before, body, src_ref=None):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return []
    is_py = file_name.endswith(".py")
    first = stripped.split(None, 1)[0] if stripped else ""
    if first in LOG_FUNCS:
        return []
    results = []
    for d in detect(line, is_py):
        if d["kind"] == "git-prune":
            results.append(_site("FORBIDDEN", "git worktree prune", d, line))
            continue
        if d["kind"] == "delegated-uv":
            results.append(_site("DELEGATED", "uv cache prune --force", d, line))
            continue
        if d["kind"] == "delegated-pnpm":
            results.append(_site("DELEGATED", "pnpm store prune", d, line))
            continue
        # .DS_Store metadata cleanup (never artifact content)
        if d["expr"].strip().strip("\"'").endswith(".DS_Store"):
            results.append(_site("EXEMPT", ".DS_Store", d, line))
            continue
        if guarded(body_before, d["vars"], is_py):
            results.append(_site("GUARDED", "+".join(d["vars"]) or d["expr"], d, line))
            continue
        if verifier_backed(body, line, d["kind"]):
            results.append(_site("VERIFIED", "+".join(d["vars"]) or d["expr"], d, line))
            continue
        if is_exempt(file_name, func_name, d, body_before, body, src_ref[0], line):
            results.append(_site("EXEMPT", "+".join(d["vars"]) or d["expr"], d, line))
            continue
        results.append(_site("UNRESOLVED", "+".join(d["vars"]) or d["expr"].strip()[:80], d, line))
    return results


def _site(verdict, target, d, line):
    return {"verdict": verdict, "target": target,
            "kind": d["kind"], "text": line.strip()[:100]}


# --------------------------------------------------------------- spans
def python_spans(src):
    """Indentation-aware def spans; methods included, never cross a lower indent."""
    lines = src.splitlines()
    spans = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
        if not m:
            continue
        indent, name = len(m.group(1)), m.group(2)
        # Skip a multi-line parameter list: track parenthesis depth until the
        # header's closing ')' (and trailing ':') so the body starts after it.
        # Without this, a def whose signature spans lines is truncated at the
        # first unindented line, and its real body leaks to <toplevel>.
        depth, k = 0, i
        while k < len(lines):
            depth += lines[k].count("(") - lines[k].count(")")
            if depth <= 0:
                break
            k += 1
        body, j = [], k + 1
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
    out = []
    spans = python_spans(src) if file_name.endswith(".py") else shell_spans(src)
    for name, body, start, _end in spans:
        lines = body.splitlines()
        for idx, line in enumerate(lines):
            for site in classify(file_name, name, line, "\n".join(lines[:idx]), body, [src]):
                site.update({"file": file_name, "func": name, "line": start + idx + 1})
                out.append(site)
    covered = set()
    for _n, _b, s, e in spans:
        covered.update(range(s, e + 1))
    for n, line in enumerate(src.splitlines(), 1):
        if n in covered or line.strip().startswith("#"):
            continue
        for site in classify(file_name, "<toplevel>", line, "", src, [src]):
            site.update({"file": file_name, "func": "<toplevel>", "line": n})
            out.append(site)
    return out


# ----------------------------------------------- dependency closure resolver
DIR_ASSIGN_RE = re.compile(
    r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*(?:dirname|BASH_SOURCE).*)$")
VAR_PATH_RE = re.compile(
    r'(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)=["\']?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/[^"\'#]*)?["\']?')
# Actual execution references only: python/exec invocations of a local script.
PYTHON_RE = re.compile(r'\bpython3?[ \t]+("[^"]+\.py"|\'[^\']+\.py\'|\S+\.py)')
EXEC_RE = re.compile(
    r'\bexec[ \t]+("[^"]+\.(?:sh|py)"|\'[^\']+\.(?:sh|py)\'|\S+\.(?:sh|py))')
SOURCE_RE = re.compile(r'\bsource[ \t]+("[^"]+\.(?:sh|py)"|\'[^\']+\.(?:sh|py)\'|\S*/[^\s;|&]+|\S+\.(?:sh|py))')
DOT_SOURCE_RE = re.compile(
    r'(?:^|[;&|][ \t]*)\.\s+("[^"]+\.(?:sh|py)"|\'[^\']+\.(?:sh|py)\'|\S*/[^\s;|&]+|\S+\.(?:sh|py))',
    re.M)
ALT_ASSIGN_RE = re.compile(r'(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)="?\$\{[A-Za-z_][A-Za-z0-9_]*:-\$([A-Za-z_][A-Za-z0-9_]*)\}')
CD_PARENT_RE = re.compile(
    r'(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)="?\$\(cd[ \t]+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/[^"]*)"[ \t]*&&[ \t]*pwd\)')
PY_IMPORT_RE = re.compile(
    r"(?m)^\s*(?:from\s+([A-Za-z_][A-Za-z0-9_.]*)\s+import|import\s+([A-Za-z_][A-Za-z0-9_]*))")
PY_HERE_RE = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*/\s*("([^"]+\.py)"|\'([^\']+\.py)\')')


def _expand(token, varmap):
    def sub(m):
        name = m.group(1) or m.group(2)
        return varmap.get(name, m.group(0))
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", sub, token)


def _resolve(root, rel, token, varmap):
    tok = token.strip().strip("\"'").split()[0] if token.strip() else ""
    if not tok:
        return None
    if tok.startswith("$("):
        return None  # command substitution cannot be resolved statically
    expanded = _expand(tok, varmap)
    if "$" in expanded:
        return "UNRESOLVED:" + tok
    if not os.path.isabs(expanded):
        expanded = os.path.join(root, os.path.dirname(rel), expanded)
    return os.path.normpath(expanded)


def build_varmap(root, rel, src):
    fdir = os.path.dirname(os.path.join(root, rel))
    vm = {}
    for m in DIR_ASSIGN_RE.finditer(src):
        vm[m.group(1)] = fdir
    for _ in range(4):
        for m in VAR_PATH_RE.finditer(src):
            name, base, suffix = m.group(1), m.group(2), m.group(3) or ""
            if name in vm or base not in vm:
                continue
            vm[name] = os.path.normpath(vm[base] + suffix)
        for m in ALT_ASSIGN_RE.finditer(src):
            name, fallback = m.group(1), m.group(2)
            if name not in vm and fallback in vm:
                vm[name] = vm[fallback]
        for m in CD_PARENT_RE.finditer(src):
            name, base, suffix = m.group(1), m.group(2), m.group(3) or ""
            if name not in vm and base in vm:
                vm[name] = os.path.normpath(vm[base] + suffix)
    return vm


def deps_of(root, rel, src):
    """Yield (raw_token, resolved_path_or_UNRESOLVED) local dependency tokens."""
    varmap = build_varmap(root, rel, src)
    candidates = []
    for rx in (SOURCE_RE, DOT_SOURCE_RE, PYTHON_RE, EXEC_RE):
        for m in rx.finditer(src):
            candidates.append(m.group(1))
    if rel.endswith(".py"):
        fdir = os.path.dirname(os.path.join(root, rel))
        for m in PY_IMPORT_RE.finditer(src):
            mod = (m.group(1) or m.group(2)).split(".")[0]
            # Local import only when a sibling module actually exists; stdlib
            # and site-packages are not local deletion dependencies.
            if os.path.isfile(os.path.join(fdir, mod + ".py")):
                candidates.append(mod + ".py")
        for m in PY_HERE_RE.finditer(src):
            candidates.append(m.group(2).strip("\"'"))
    resolved = []
    for raw in candidates:
        p = _resolve(root, rel, raw, varmap)
        if p is None:
            continue
        resolved.append((raw, p))
    return resolved


def resolve_closure(root, initial):
    """BFS the local dependency closure. Returns (sorted rel paths, failures)."""
    seen = set()
    failures = []
    queue = list(initial)
    while queue:
        rel = queue.pop(0)
        if rel in seen:
            continue
        seen.add(rel)
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            failures.append((rel, "missing file"))
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                src = fh.read()
        except OSError as exc:
            failures.append((rel, f"unreadable: {exc}"))
            continue
        for raw, p in deps_of(root, rel, src):
            if p.startswith("UNRESOLVED:"):
                failures.append((rel, f"unresolved dependency {raw}"))
                continue
            try:
                inside = os.path.commonpath([os.path.abspath(p), os.path.abspath(root)]) == os.path.abspath(root)
            except ValueError:
                inside = False
            if not inside:
                # system/python absolute references are not local deps
                continue
            dep_rel = os.path.relpath(p, root)
            if not os.path.isfile(p):
                failures.append((rel, f"missing dependency {dep_rel}"))
                continue
            queue.append(dep_rel)
    return sorted(seen), failures


# ---------------------------------------------------------------- self-tests
FIXTURES = {
    "unguarded.sh": "wipe() {\n  local target=\"$1\"\n  rm -rf \"$target\"\n}\n",
    "guarded.sh": "wipe() {\n  local target=\"$1\"\n  artifact_removal_verdict \"$target\" --kind ephemeral >/dev/null\n  rm -rf \"$target\"\n}\n",
    "find-guarded.sh": "wipe() {\n  local path=\"$1\"\n  artifact_removal_verdict \"$path\" --kind rebuildable >/dev/null\n  find \"$path\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +\n}\n",
    "find-delete-unguarded.sh": "wipe() {\n  local path=\"$1\"\n  find \"$path\" -mindepth 1 -delete\n}\n",
    "find-delete-guarded.sh": "wipe() {\n  local path=\"$1\"\n  artifact_removal_verdict \"$path\" --kind rebuildable >/dev/null\n  find \"$path\" -mindepth 1 -delete\n}\n",
    "wrong-target.sh": "wipe() {\n  local target=\"$1\" other=\"$2\"\n  artifact_removal_verdict \"$other\" --kind ephemeral >/dev/null\n  rm -rf \"$target\"\n}\n",
    "forbidden-prune.sh": "wipe() {\n  git worktree prune\n}\n",
    "forbidden-prune-c.sh": "wipe() {\n  local root=\"$1\"\n  git -C \"$root\" worktree prune\n}\n",
    "exempt-tmp.sh": "probe() {\n  local hit_file\n  hit_file=\"$(mktemp)\"\n  rm -f \"$hit_file\"\n}\n",
    "fake-exempt-tmp.sh": "probe() {\n  local hit_file=\"$1\"\n  rm -f \"$hit_file\"\n}\n",
    "cleanup_uv_cache.sh": "delegate() {\n  uv cache prune --force\n}\n",
    "git-remove-unguarded.sh": "wipe() {\n  local wt=\"$1\"\n  git worktree remove \"$wt\"\n}\n",
    "git-remove-c-unguarded.sh": "wipe() {\n  local main=\"$1\" wt=\"$2\"\n  git -C \"$main\" worktree remove \"$wt\"\n}\n",
    "git-remove-guarded.sh": "wipe() {\n  local wt=\"$1\"\n  artifact_removal_verdict \"$wt\" --kind ephemeral >/dev/null\n  git worktree remove \"$wt\"\n}\n",
    "wrh-direct-unguarded.sh": "wipe() {\n  local wt=\"$1\"\n  wrh_remove_now \"$wt\" \"$wt\"\n}\n",
    "wrh-guarded.sh": "wipe() {\n  local wt=\"$1\"\n  artifact_removal_verdict \"$wt\" --kind ephemeral >/dev/null\n  wrh_remove_now \"$wt\" \"$wt\"\n}\n",
    "shared-root.sh": "wipe() {\n  local root=\"$1\" target=\"$2\"\n  artifact_removal_verdict \"$root\" --kind ephemeral >/dev/null\n  rm -rf \"$root/$target\"\n}\n",
    "python-rmdir-verified.py": "def phase2(pfd):\n    import os\n    expected = {'ino': 1, 'dev': 2}\n    cur = os.stat('x', dir_fd=pfd)\n    if cur.st_ino == expected.get('ino'):\n        os.rmdir('x', dir_fd=pfd)\n",
    "log-mention.sh": "report() {\n  ledger_line \"guard\" \"ELIGIBLE\" \"$1\" \"\" \" (~1M, rm -rf orphan)\"\n}\n",
    "python-unguarded.py": "def wipe(session_dir):\n    shutil.rmtree(session_dir)\n",
    "python-guarded.py": "def wipe(session_dir):\n    artifact_removal_verdict(session_dir)\n    shutil.rmtree(session_dir)\n",
    "python-exempt.py": "def dedup(tmp_link):\n    tmp_link.unlink()\n",
    "prune_aside_sessions.py": "def dedup_static_assets(dup):\n    tmp_link = dup.with_name('.tmp_dedup_x')\n    tmp_link.unlink()\n",
    "python-method.py": "def helper(x):\n    return x\n\nclass P:\n    def run(self, session_dir):\n        shutil.rmtree(session_dir)\n",
}
EXPECT = {
    "unguarded.sh": [("wipe", "target", "UNRESOLVED")],
    "guarded.sh": [("wipe", "target", "GUARDED")],
    "find-guarded.sh": [("wipe", "path", "GUARDED")],
    "find-delete-unguarded.sh": [("wipe", "path", "UNRESOLVED")],
    "find-delete-guarded.sh": [("wipe", "path", "GUARDED")],
    "wrong-target.sh": [("wipe", "target", "UNRESOLVED")],
    "forbidden-prune.sh": [("wipe", "git worktree prune", "FORBIDDEN")],
    "forbidden-prune-c.sh": [("wipe", "git worktree prune", "FORBIDDEN")],
    "exempt-tmp.sh": [("probe", "hit_file", "EXEMPT")],
    "fake-exempt-tmp.sh": [("probe", "hit_file", "UNRESOLVED")],
    "cleanup_uv_cache.sh": [("delegate", "uv cache prune --force", "DELEGATED")],
    "git-remove-unguarded.sh": [("wipe", "wt", "UNRESOLVED")],
    "git-remove-c-unguarded.sh": [("wipe", "wt", "UNRESOLVED")],
    "git-remove-guarded.sh": [("wipe", "wt", "GUARDED")],
    "wrh-direct-unguarded.sh": [("wipe", "wt", "UNRESOLVED")],
    "wrh-guarded.sh": [("wipe", "wt", "GUARDED")],
    "shared-root.sh": [("wipe", "root+target", "UNRESOLVED")],
    "python-rmdir-verified.py": [("phase2", "x", "VERIFIED")],
    "log-mention.sh": [],
    "python-unguarded.py": [("wipe", "session_dir", "UNRESOLVED")],
    "python-guarded.py": [("wipe", "session_dir", "GUARDED")],
    "python-exempt.py": [("dedup", "tmp_link", "UNRESOLVED")],
    "prune_aside_sessions.py": [("dedup_static_assets", "tmp_link", "EXEMPT")],
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
    extra = [g for g in got if g["verdict"] in ("FORBIDDEN", "UNRESOLVED")
             and not any(g["func"] == f and g["verdict"] == v for f, _t, v in expected)]
    if ok and not extra:
        print(f"PASS fixture {name}")
    else:
        failures += 1
        print(f"FAIL fixture {name}: got {got} expected {expected}")

# Multi-target coverage: the second unguarded target must be reported.
multi = lint("multi.sh", "wipe() {\n  local a=\"$1\" b=\"$2\"\n  rm -rf \"$a\" \"$b\"\n}\n")
if sum(1 for g in multi if g["verdict"] == "UNRESOLVED") == 2:
    print("PASS fixture multi-unguarded.sh (both targets caught)")
else:
    failures += 1
    print(f"FAIL fixture multi-unguarded.sh: {multi}")

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

# Tool-owned metadata exemptions: an exact (file, function, kind) site must ALSO
# satisfy a provenance check. A similarly named user path or an unanchored
# removal in the same function must stay UNRESOLVED (never a blanket pass).
METADATA_CASES = [
    ("observer rotation archive (proven)", "disk_observer.py",
     "def rotate_if_needed(path, max_bytes, keep):\n"
     "    for index in range(1, keep + 1):\n"
     "        archive = Path(f\"{path}.{index}\")\n"
     "        if expired:\n"
     "            archive.unlink()\n",
     [("rotate_if_needed", "archive", "EXEMPT")]),
    ("observer rotation destination (proven)", "disk_observer.py",
     "def rotate_if_needed(path, keep):\n"
     "    for index in range(keep, 0, -1):\n"
     "        destination = Path(f\"{path}.{index}\")\n"
     "        destination.unlink()\n",
     [("rotate_if_needed", "destination", "EXEMPT")]),
    ("reuse claim lock member (proven)", "worktree_lease.sh",
     "lease_claim_reuse() {\n"
     "python3 - \"$1\" <<'PY'\n"
     "import os, sys\n"
     "path = sys.argv[1]\n"
     "lock = path + \".reuse-lock\"\n"
     "for name in (\"pid\", \"acquired_at\"):\n"
     "    try: os.unlink(os.path.join(lock, name))\n"
     "    except FileNotFoundError: pass\n"
     "PY\n"
     "}\n",
     [("lease_claim_reuse", "path+join+lock", "EXEMPT")]),
    ("reuse lock recover members (proven)", "worktree_lease.sh",
     "lease_reuse_lock_recover() {\n"
     "  local lease=\"$1\" lock=\"$1.reuse-lock\" pid stamp\n"
     "  pid=\"$(cat \"$lock/pid\")\"; stamp=\"$(cat \"$lock/acquired_at\")\"\n"
     "  rm -f \"$lock/pid\" \"$lock/acquired_at\"\n"
     "}\n",
     [("lease_reuse_lock_recover", "lock", "EXEMPT")]),
    ("reuse lock release members (proven)", "worktree_lease.sh",
     "lease_reuse_lock_release() {\n"
     "  rm -f \"$1.reuse-lock/pid\" \"$1.reuse-lock/acquired_at\" 2>/dev/null\n"
     "}\n",
     [("lease_reuse_lock_release", '"$1.reuse-lock/pid"', "EXEMPT"),
      ("lease_reuse_lock_release", '"$1.reuse-lock/acquired_at"', "EXEMPT")]),
    ("quarantine reconcile temp binding (proven)", "quarantine_rename.py",
     "def reconcile_record(index_dir, qid, deadline):\n"
     "    with tempfile.NamedTemporaryFile(\"w\", dir=index_dir(), prefix=\".reconcile.\", delete=False) as f:\n"
     "        json.dump(binding, f); binding_path = f.name\n"
     "    try:\n"
     "        os.unlink(binding_path)\n"
     "    except OSError:\n"
     "        pass\n",
     [("reconcile_record", "binding_path", "EXEMPT")]),
    ("observer rotation user path (rejected)", "disk_observer.py",
     "def rotate_if_needed(path, keep):\n"
     "    archive = path\n"
     "    archive.unlink()\n",
     [("rotate_if_needed", "archive", "UNRESOLVED")]),
    ("observer rotation unanchored (rejected)", "disk_observer.py",
     "def rotate_if_needed(path):\n"
     "    archive = Path(sys.argv[1])\n"
     "    archive.unlink()\n",
     [("rotate_if_needed", "archive", "UNRESOLVED")]),
    ("observer arbitrary function (rejected)", "disk_observer.py",
     "def purge_all(path):\n"
     "    destination = Path(sys.argv[1])\n"
     "    destination.unlink()\n",
     [("purge_all", "destination", "UNRESOLVED")]),
    ("reuse lock unanchored rm (rejected)", "worktree_lease.sh",
     "lease_reuse_lock_release() {\n"
     "  rm -f \"$1/pid\" \"$1/acquired_at\"\n"
     "}\n",
     [("lease_reuse_lock_release", '"$1/pid"', "UNRESOLVED"),
      ("lease_reuse_lock_release", '"$1/acquired_at"', "UNRESOLVED")]),
    ("quarantine reconcile user binding (rejected)", "quarantine_rename.py",
     "def reconcile_record(binding_path):\n"
     "    os.unlink(binding_path)\n",
     [("reconcile_record", "binding_path", "UNRESOLVED")]),
    # --- tightened negative fixtures: every widening gap the parent flagged ---
    ("reuse claim unbound member (rejected)", "worktree_lease.sh",
     "lease_claim_reuse() {\n"
     "python3 - \"$1\" <<'PY'\n"
     "import os, sys\n"
     "path = sys.argv[1]\n"
     "lock = path + \".reuse-lock\"\n"
     "try: os.unlink(os.path.join(lock, name))\n"
     "except OSError: pass\n"
     "PY\n"
     "}\n",
     [("lease_claim_reuse", "path+join+lock", "UNRESOLVED")]),
    ("reuse claim wrong member loop (rejected)", "worktree_lease.sh",
     "lease_claim_reuse() {\n"
     "python3 - \"$1\" <<'PY'\n"
     "import os, sys\n"
     "path = sys.argv[1]\n"
     "lock = path + \".reuse-lock\"\n"
     "for name in (\"pid\", \"other\"):\n"
     "    try: os.unlink(os.path.join(lock, name))\n"
     "    except OSError: pass\n"
     "PY\n"
     "}\n",
     [("lease_claim_reuse", "path+join+lock", "UNRESOLVED")]),
    ("reuse claim pid-private member loop (rejected)", "worktree_lease.sh",
     "lease_claim_reuse() {\n"
     "python3 - \"$1\" <<'PY'\n"
     "import os, sys\n"
     "path = sys.argv[1]\n"
     "lock = path + \".reuse-lock\"\n"
     "for name in (\"pid-private\", \"acquired_at\"):\n"
     "    try: os.unlink(os.path.join(lock, name))\n"
     "    except OSError: pass\n"
     "PY\n"
     "}\n",
     [("lease_claim_reuse", "path+join+lock", "UNRESOLVED")]),
    ("reuse claim different lock suffix (rejected)", "worktree_lease.sh",
     "lease_claim_reuse() {\n"
     "python3 - \"$1\" <<'PY'\n"
     "import os, sys\n"
     "path = sys.argv[1]\n"
     "lock = path + \".reuse-lockx\"\n"
     "for name in (\"pid\", \"acquired_at\"):\n"
     "    try: os.unlink(os.path.join(lock, name))\n"
     "    except OSError: pass\n"
     "PY\n"
     "}\n",
     [("lease_claim_reuse", "path+join+lock", "UNRESOLVED")]),
    ("reuse claim lock reassigned (rejected)", "worktree_lease.sh",
     "lease_claim_reuse() {\n"
     "python3 - \"$1\" <<'PY'\n"
     "import os, sys\n"
     "path = sys.argv[1]\n"
     "lock = path + \".reuse-lock\"\n"
     "lock = user_input\n"
     "for name in (\"pid\", \"acquired_at\"):\n"
     "    try: os.unlink(os.path.join(lock, name))\n"
     "    except OSError: pass\n"
     "PY\n"
     "}\n",
     [("lease_claim_reuse", "path+join+lock", "UNRESOLVED")]),
    ("reuse lock arbitrary member (rejected)", "worktree_lease.sh",
     "lease_reuse_lock_recover() {\n"
     "  local lease=\"$1\" lock=\"$1.reuse-lock\"\n"
     "  rm -f \"$lock/anything\"\n"
     "}\n",
     [("lease_reuse_lock_recover", "lock", "UNRESOLVED")]),
    ("reuse lock pid-private suffix (rejected)", "worktree_lease.sh",
     "lease_reuse_lock_release() {\n"
     "  rm -f \"$1.reuse-lock/pid-private\"\n"
     "}\n",
     [("lease_reuse_lock_release", '"$1.reuse-lock/pid-private"', "UNRESOLVED")]),
    ("reuse lock arbitrary base (rejected)", "worktree_lease.sh",
     "lease_reuse_lock_recover() {\n"
     "  local lease=\"$1\" lock=\"$1.reuse-lock\"\n"
     "  rm -f \"$foo/pid\"\n"
     "}\n",
     [("lease_reuse_lock_recover", "foo", "UNRESOLVED")]),
    ("reuse lock reassigned (rejected)", "worktree_lease.sh",
     "lease_reuse_lock_recover() {\n"
     "  local lease=\"$1\" lock=\"$1.reuse-lock\"\n"
     "  lock=\"$2\"\n"
     "  rm -f \"$lock/pid\"\n"
     "}\n",
     [("lease_reuse_lock_recover", "lock", "UNRESOLVED")]),
    ("observer rotation traversal (rejected)", "disk_observer.py",
     "def rotate_if_needed(path, keep):\n"
     "    for index in range(1, keep + 1):\n"
     "        archive = Path(f\"{path}/../{index}\")\n"
     "        archive.unlink()\n",
     [("rotate_if_needed", "archive", "UNRESOLVED")]),
    ("observer rotation different suffix (rejected)", "disk_observer.py",
     "def rotate_if_needed(path, keep):\n"
     "    for index in range(1, keep + 1):\n"
     "        archive = Path(f\"{path}.bak.{index}\")\n"
     "        archive.unlink()\n",
     [("rotate_if_needed", "archive", "UNRESOLVED")]),
    ("observer rotation unbounded index (rejected)", "disk_observer.py",
     "def rotate_if_needed(path):\n"
     "    archive = Path(f\"{path}.{index}\")\n"
     "    archive.unlink()\n",
     [("rotate_if_needed", "archive", "UNRESOLVED")]),
    ("observer rotation reassigned (rejected)", "disk_observer.py",
     "def rotate_if_needed(path, keep):\n"
     "    for index in range(1, keep + 1):\n"
     "        archive = Path(f\"{path}.{index}\")\n"
     "        archive = path\n"
     "        archive.unlink()\n",
     [("rotate_if_needed", "archive", "UNRESOLVED")]),
    ("quarantine unrelated tempfile (rejected)", "quarantine_rename.py",
     "def reconcile_record(index_dir, binding_path):\n"
     "    with tempfile.NamedTemporaryFile(\"w\", dir=index_dir(), prefix=\".reconcile.\", delete=False) as f:\n"
     "        json.dump(binding, f)\n"
     "    os.unlink(binding_path)\n",
     [("reconcile_record", "binding_path", "UNRESOLVED")]),
    ("quarantine wrong handle binding (rejected)", "quarantine_rename.py",
     "def reconcile_record(index_dir):\n"
     "    with tempfile.NamedTemporaryFile(\"w\", dir=index_dir(), prefix=\".reconcile.\", delete=False) as f:\n"
     "        json.dump(binding, f)\n"
     "    other = open(user_path)\n"
     "    binding_path = other.name\n"
     "    os.unlink(binding_path)\n",
     [("reconcile_record", "binding_path", "UNRESOLVED")]),
    ("quarantine wrong prefix (rejected)", "quarantine_rename.py",
     "def reconcile_record(index_dir):\n"
     "    with tempfile.NamedTemporaryFile(\"w\", dir=index_dir(), prefix=\".other.\", delete=False) as f:\n"
     "        binding_path = f.name\n"
     "    os.unlink(binding_path)\n",
     [("reconcile_record", "binding_path", "UNRESOLVED")]),
    ("quarantine wrong dir (rejected)", "quarantine_rename.py",
     "def reconcile_record(other_dir):\n"
     "    with tempfile.NamedTemporaryFile(\"w\", dir=other_dir(), prefix=\".reconcile.\", delete=False) as f:\n"
     "        binding_path = f.name\n"
     "    os.unlink(binding_path)\n",
     [("reconcile_record", "binding_path", "UNRESOLVED")]),
    ("quarantine binding reassigned (rejected)", "quarantine_rename.py",
     "def reconcile_record(index_dir, user_path):\n"
     "    with tempfile.NamedTemporaryFile(\"w\", dir=index_dir(), prefix=\".reconcile.\", delete=False) as f:\n"
     "        binding_path = f.name\n"
     "    binding_path = user_path\n"
     "    os.unlink(binding_path)\n",
     [("reconcile_record", "binding_path", "UNRESOLVED")]),
    ("quarantine handle reassigned (rejected)", "quarantine_rename.py",
     "def reconcile_record(index_dir, other):\n"
     "    with tempfile.NamedTemporaryFile(\"w\", dir=index_dir(), prefix=\".reconcile.\", delete=False) as f:\n"
     "        binding_path = f.name\n"
     "    f = other\n"
     "    os.unlink(binding_path)\n",
     [("reconcile_record", "binding_path", "UNRESOLVED")]),
]
for label, fname, src, expected in METADATA_CASES:
    got = lint(fname, src)
    ok = all(any(g["func"] == f and g["target"] == t and g["verdict"] == v
                 for g in got) for f, t, v in expected)
    extra = [g for g in got if g["verdict"] in ("FORBIDDEN", "UNRESOLVED")
             and not any(g["func"] == f and g["target"] == t and g["verdict"] == v
                         for f, t, v in expected)]
    if ok and not extra:
        print(f"PASS metadata {label}")
    else:
        failures += 1
        print(f"FAIL metadata {label}: got {got} expected {expected}")

# Closure discovery fixtures: a planted helper reachable via source AND via exec
# must be pulled into the closure and its unguarded removal must be caught.
def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)

closure_root = tempfile.mkdtemp(prefix="dm-lint-closure-",
                                dir=os.environ["DISK_MAGICIAN_TEST_SANDBOX"])
_write(os.path.join(closure_root, "main.sh"),
       'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
       'source "$SCRIPT_DIR/helper.sh"\n'
       'exec "$SCRIPT_DIR/other.sh"\n')
_write(os.path.join(closure_root, "helper.sh"),
       'helper() {\n  local t="$1"\n  rm -rf "$t"\n}\n')
_write(os.path.join(closure_root, "other.sh"),
       'other() {\n  local t="$1"\n  rm -rf "$t"\n}\n')
closure, _fails = resolve_closure(closure_root, ["main.sh"])
missing = [x for x in ("main.sh", "helper.sh", "other.sh") if x not in closure]
if missing:
    failures += 1
    print(f"FAIL closure discovery missing {missing} (got {closure})")
else:
    print(f"PASS closure discovery: {closure}")
for dep in ("helper.sh", "other.sh"):
    got = lint(dep, open(os.path.join(closure_root, dep), encoding="utf-8").read())
    if not any(g["verdict"] == "UNRESOLVED" for g in got):
        failures += 1
        print(f"FAIL planted {dep} removal not caught: {got}")
    else:
        print(f"PASS planted {dep} unguarded removal caught")

# Missing local dependency must be reported, not silently omitted.
bad_root = tempfile.mkdtemp(prefix="dm-lint-bad-",
                             dir=os.environ["DISK_MAGICIAN_TEST_SANDBOX"])
_write(os.path.join(bad_root, "main.sh"),
       'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
       'source "$SCRIPT_DIR/missing.sh"\n')
_c, bad_fails = resolve_closure(bad_root, ["main.sh"])
if any("missing dependency" in f[1] for f in bad_fails):
    print("PASS missing dependency reported")
else:
    failures += 1
    print(f"FAIL missing dependency not reported: {bad_fails}")

# ------------------------------------------------------------- production audit
print()
print("=== dependency closure (spec §7.2 transitive local deps) ===")
closure, dep_failures = resolve_closure(ROOT, SCOPE)
for rel in closure:
    print(f"CLOSURE    {rel}")
for rel, why in dep_failures:
    print(f"DEPFAIL    {rel}: {why}")

print()
print("=== production audit (pre-integration; unresolved sites are expected) ===")
unresolved, forbidden, missing, verified, exempted, delegated = [], [], [], [], [], []
audit_scope = sorted(set(SCOPE) | set(closure))
for rel in audit_scope:
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        missing.append(rel)
        print(f"MISSING    {rel}")
        continue
    with open(path, encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    for site in lint(os.path.basename(rel), src):
        line = f"{rel}:{site['line']} {site['func']}() target={site['target']} :: {site['text']}"
        if site["verdict"] == "UNRESOLVED":
            unresolved.append(site)
            print(f"UNRESOLVED {line}")
        elif site["verdict"] == "FORBIDDEN":
            forbidden.append(site)
            print(f"FORBIDDEN  {line}")
        elif site["verdict"] == "VERIFIED":
            verified.append(site)
            print(f"VERIFIED   {line}")
        elif site["verdict"] == "DELEGATED":
            delegated.append(site)
            print(f"DELEGATED  {line}")
        elif site["verdict"] == "EXEMPT":
            exempted.append(site)

print()
print("=== T11-14 positive wiring (already landed) ===")
def _body(src, name):
    m = re.search(r"(?ms)^" + re.escape(name) + r"\(\)\s*[{(]\n(.*?)^\}", src)
    return m.group(1) if m else ""

def _calls_with(body, callee, target):
    """True when `body` directly invokes `callee` with `target` as an
    argument (same-target link, not a bare symbol mention)."""
    return bool(re.search(r"\b" + re.escape(callee) + r"\s+" + re.escape(target)
                          + r"(?:\s|$|[|;&)])", body))

tmp_src = open(os.path.join(ROOT, "scripts/cleanup_tmp.sh"), encoding="utf-8").read()
budget_src = open(os.path.join(ROOT, "scripts/lib/scratch_budget.sh"), encoding="utf-8").read()
# purge_aged_archives no longer calls C14 directly: it hands each candidate
# `$d` to the shared per-unit processor purge_archive_entry, which is the only
# function that names that SAME `$d` to scratch_budget_quarantine_remove. Verify
# the real same-target call graph, not a file-level string coincidence.
purge_aged_body = _body(tmp_src, "purge_aged_archives")
purge_entry_body = _body(tmp_src, "purge_archive_entry")
purge_chain_ok = (
    _calls_with(purge_aged_body, "purge_archive_entry", '"$d"')
    and 'scratch_budget_quarantine_remove "$d"' in purge_entry_body)
budget_gate_body = _body(budget_src, "scratch_budget_quarantine_remove")
t11_pairs = [
    (_body(tmp_src, "remove_path"), 'scratch_budget_quarantine_remove "$path"'),
    (_body(budget_src, "scratch_budget_evict_root"), 'scratch_budget_quarantine_remove "$item_i"'),
    (budget_gate_body, "--kind ephemeral"),
]
t11_fail = [needle for body, needle in t11_pairs if needle not in body]
if not purge_chain_ok:
    t11_fail.append("purge_aged_archives -> purge_archive_entry $d -> scratch_budget_quarantine_remove $d")
if 'quarantine_remove "$1"' not in budget_gate_body:
    t11_fail.append('scratch_budget_quarantine_remove -> quarantine_remove "$1"')
if t11_fail:
    failures += len(t11_fail)
    print(f"FAIL T11-14 positive wiring missing: {t11_fail}")
else:
    print("PASS T11-14 cleanup_tmp/scratch_budget route through C14")

print()
print("=== T18 deletion-log coverage ===")
# Every sanctioned guard / removal entry point must log through deletion_log_removal
# (directly, or by delegating to a primitive that does); every delegated command's
# script must log; exemptions must carry a rationale. A new guard or delegated tool
# without a logging route fails here.
def _read(rel):
    return open(os.path.join(ROOT, rel), encoding="utf-8").read()
LOGGING_PRIMITIVES = {
    "quarantine_remove": (_read("scripts/lib/quarantine.sh"), "deletion_log_removal"),
    "wrh_remove_now": (_read("scripts/worktree_remove_hook.sh"), "deletion_log_removal"),
    "scratch_budget_quarantine_remove": (budget_src, "quarantine_remove"),  # delegates
}
# artifact_removal_verdict only decides; it deletes nothing.
VERDICT_ONLY = ("artifact_removal_verdict",)
DELEGATED_LOG_FILES = {
    "uv cache prune --force": "scripts/cleanup_uv_cache.sh",
    "pnpm store prune": "scripts/cleanup_dev_caches.sh",
}
t18_fail = []
for g in SANCTIONED + REMOVAL_ENTRY:
    if g in VERDICT_ONLY:
        continue
    if g not in LOGGING_PRIMITIVES:
        t18_fail.append(f"{g}: not a logging primitive and not allow-listed")
        continue
    src, needle = LOGGING_PRIMITIVES[g]
    if needle not in _body(src, g):
        t18_fail.append(f"{g}: body lacks {needle}")
for cmd in DELEGATED_CMDS:
    rel = DELEGATED_LOG_FILES.get(cmd)
    if not rel or "deletion_log_removal" not in _read(rel):
        t18_fail.append(f"delegated '{cmd}': script does not log its reclaim")
for key, why in EXEMPT_SITES.items():
    if not why.strip():
        t18_fail.append(f"exempt {key}: empty rationale")
if t18_fail:
    failures += len(t18_fail)
    print(f"FAIL T18 deletion-log coverage gaps: {t18_fail}")
else:
    print("PASS T18 every guard/entry/delegated site logs or is allow-listed with a reason")

print()
print(f"self-test failures: {failures}")
print(f"closure files: {len(closure)}")
print(f"dependency failures: {len(dep_failures)}")
print(f"unresolved removal sites: {len(unresolved)}")
print(f"forbidden sites: {len(forbidden)}")
print(f"verified (fd-relative inventory) sites: {len(verified)}")
print(f"delegated sites: {len(delegated)}")
print(f"exempt tool-owned sites: {len(exempted)}")
print(f"missing scope files: {len(missing)} ({', '.join(missing) or 'none'})")

fatal = failures > 0
if AUDIT_FATAL and (unresolved or forbidden or missing or dep_failures):
    fatal = True
if fatal:
    print("RESULT: FAIL")
    sys.exit(1)
if AUDIT_FATAL:
    print("RESULT: PASS (self-test green; strict audit: zero unresolved/forbidden/"
          "dependency failures)")
else:
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
check "cleanup_tmp package mirror matches" "[[ ! -f '$ROOT/src/disk_magician/scripts/cleanup_tmp.sh' ]] && bash '$ROOT/scripts/sync_package_tree.sh' --check >/dev/null 2>&1 || cmp -s '$ROOT/scripts/cleanup_tmp.sh' '$ROOT/src/disk_magician/scripts/cleanup_tmp.sh'"
check "scratch_budget package mirror matches" "[[ ! -f '$ROOT/src/disk_magician/scripts/lib/scratch_budget.sh' ]] && bash '$ROOT/scripts/sync_package_tree.sh' --check >/dev/null 2>&1 || cmp -s '$ROOT/scripts/lib/scratch_budget.sh' '$ROOT/src/disk_magician/scripts/lib/scratch_budget.sh'"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
