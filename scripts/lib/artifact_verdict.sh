#!/usr/bin/env bash
# artifact_verdict.sh — C14 artifact_removal_verdict (spec §7.2), sourced.
# Discovery plus per-repository content, ownership, lease, live-cwd and
# fd-relative inventory checks. Prints `remove` only when every check passes;
# any unknown prints `kept:<why>` or `deferred:<why>` (fail closed).
# `--self-test` drives a real self-owned /tmp remove/kept/corrupt-evidence
# triple through this verdict and prints `ok` only on a full pass, else
# `incomplete`.

_AV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$_AV_DIR/worktree_ignored.sh"
# shellcheck source=scripts/worktree_remove_hook.sh
source "$_AV_DIR/../worktree_remove_hook.sh" # has_hidden_state
# shellcheck source=scripts/lib/scratch_roots.sh
source "$_AV_DIR/scratch_roots.sh"

# c14_discover_repos <root>: print every repository under <root> (itself
# included), NUL-terminated and absolute: a dir holding a `.git` dir or file,
# or a bare repo (HEAD + objects/ + refs/). No -prune, so ignored dirs are
# walked too. rc 1 when the walk is incomplete or a path escapes <root>; the
# OK sentinel can never be a find path, which starts with "/".
c14_discover_repos() {
    local root p d target done=
    root="$(cd "$1" 2>/dev/null && pwd -P)" && [[ "$root" == /* ]] || return 1
    while IFS= read -r -d '' p; do
        [[ "$p" == OK ]] && { done=1; continue; }
        [[ "$p" == "$root"/* ]] || return 1
        d="${p%/*}"
        if [[ "${p##*/}" == .git ]]; then
            if [[ -L "$p" ]]; then
                target="$(cd "$p" 2>/dev/null && pwd -P)" || { printf 'kept:gitdir-invalid\0'; return 1; }
                [[ "$target" == "$root"/* ]] || { printf 'kept:gitdir-invalid\0'; return 1; }
            fi
            printf '%s\0' "$d"
        # A bare repo; git internals (.git/modules, .git/worktrees) go with their
        # owner. HEAD/objects/refs may be internal symlinks, but a repo-looking
        # shape we cannot validate fails closed rather than falling through to
        # ordinary ephemeral content.
        elif [[ "${p##*/}" == HEAD && "/$d/" != */.git/* ]]; then
            if [[ -f "$p" && -d "$d/objects" && -d "$d/refs" ]]; then
                printf '%s\0' "$d"
            elif [[ -L "$p" || -L "$d/objects" || -L "$d/refs" || -e "$d/objects" || -e "$d/refs" ]]; then
                printf 'kept:gitdir-invalid\0'; return 1
            fi
        fi
    done < <(find "$root" \( -name .git -o -name HEAD \) -print0 2>/dev/null && printf 'OK\0')
    [[ -n "$done" ]]
}

# c14_repo_content_ok <repo> [--overlay-manifest <receipt>]: print `ok` (rc 0) or `kept:<reason>` (rc 1).
# Git env dropped; git must resolve <repo> itself, not an ancestor (broken .git).
c14_repo_content_ok() (
    local r=$1 mode=${2:-} receipt=${3:-} st flags cert && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
    r="$(cd "$r" 2>/dev/null && pwd -P)" || { echo kept:check-failed; return 1; }
    if [[ "$mode" == --overlay-manifest ]]; then
        [[ -n "$receipt" ]] || { echo kept:check-failed; return 1; }
        cert="$(python3 "$_AV_DIR/../c14_probe.py" outer-certificate "$r" "$receipt")" || { echo "${cert:-kept:check-failed}"; return 1; }
        [[ "$cert" == ok ]] || { echo "$cert"; return 1; }
    elif [[ -n "$mode" || -n "$receipt" ]]; then
        echo kept:check-failed; return 1
    fi
    case "$(git -C "$r" rev-parse --is-bare-repository 2>/dev/null)" in
        true) [[ "$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null)" == "$r" ]] && { echo ok; return 0; } ;;
        false) [[ "$(git -C "$r" rev-parse --show-toplevel 2>/dev/null)" == "$r" ]] ;;
        *) false ;;
    esac || { echo kept:check-failed; return 1; }
    if ! st="$(git -C "$r" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null)" ||
        ! flags="$(git -C "$r" ls-files -v 2>/dev/null)"; then
        echo kept:check-failed; return 1
    fi
    if [[ -n "$st" ]]; then
        st="$(grep -vE '^\?\? \.husky/_(/.*)?$' <<<"$st" || true)"
    fi
    # Tracked or submodule changes, untracked files, or hidden index flags.
    if [[ -n "$st" && "$mode" != --overlay-manifest ]] || grep -q '^[a-zS]' <<<"$flags"; then
        echo kept:dirty; return 1
    fi
    has_hidden_state "$r" && { echo kept:secret-like; return 1; }
    has_ignored_user_data "$r" && { echo kept:ignored-data; return 1; }
    echo ok
)

# c14_repo_pushed_ok <repo> [<root>]: all commits in the live ls-remote set of remotes
# outside <root> (default <repo>). Independent repo: every ref and reflog, no unreachable
# object, .git = lease git_meta. Registered linked worktree: only its branch, the branch
# reflog and the ids under its admin dir (allowlisted names), then wrh_removal_verdict.
c14_repo_pushed_ok() (
    local r=$1 root=${2:-$1} deadline=${3:-} gd cd kv out adv='' have tips='' unp v linked= scope=(--all --reflog)
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
    gd="$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null)" &&
        cd="$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
        { echo kept:check-failed; return 1; }
    # Fail closed when the candidate contains the common admin storage but a
    # registered linked worktree lives outside it: removing the candidate would
    # orphan that worktree's admin even if its visible branch is pushed. A
    # linked-worktree candidate keeps its host's admin outside itself, so its
    # siblings do not veto it.
    out="$(python3 "$_AV_DIR/../c14_probe.py" worktrees "$cd" "$root" ${deadline:+"$deadline"})" || {
        echo "${out:-kept:check-failed}"; return 1;
    }
    [[ "$out" == ok ]] || { echo "${out:-kept:check-failed}"; return 1; }
    if [[ "$cd" != "$gd" ]]; then
        [[ "$(git -C "$r" config --get extensions.refStorage || echo files)" == files ]] &&
            tips="$(python3 "$_AV_DIR/../c14_probe.py" admin "$gd" "$(lease_path_for "$r" 2>/dev/null)")" ||
            { echo kept:check-failed; return 1; }
        [[ "$tips" == kept:* ]] && { echo "$tips"; return 1; }
        tips+=$'\n'"$(git -C "$r" rev-parse --verify -q HEAD)" || { echo kept:check-failed; return 1; }
        scope=() linked=1
    fi
    while IFS= read -r -d '' kv; do
        out="$(python3 "$_AV_DIR/../c14_probe.py" lsremote "${kv#*$'\n'}" "$root" ${deadline:+"$deadline"})" || {
            [[ "$out" == deferred:* ]] && { echo "$out"; return 1; }
            echo kept:remote-unverified; return 1;
        }
        adv+="$out"$'\n'
    done < <(git -C "$r" config -z --get-regexp '^remote\..*\.url$' 2>/dev/null)
    # Advertised SHAs present locally become negative tips.
    have="$(cut -f1 <<<"$adv" | GIT_NO_LAZY_FETCH=1 git -C "$r" cat-file --batch-check='%(objectname)' 2>/dev/null | grep -v ' missing$' | sed 's/^/^/')"
    unp="$(git -C "$r" rev-list ${scope[@]+"${scope[@]}"} --stdin -n1 < <(printf '%s\n' $tips $have) 2>/dev/null)" || { echo kept:check-failed; return 1; }
    [[ -z "$unp" ]] || { echo kept:not-pushed; return 1; }
    if [[ -n "$linked" ]]; then  # linked: unreachable objects stay in the common store
        v="$(wrh_removal_verdict "$r" minutes:30 origin-or-merged-pr)"
        [[ "$v" == remove ]] && { echo ok; return 0; }
        echo "$v"; return 1
    fi
    out="$(git -C "$r" fsck --connectivity-only --unreachable --no-reflogs --no-progress 2>/dev/null)" ||
        { echo kept:check-failed; return 1; }
    grep -q '^unreachable ' <<<"$out" && { echo kept:unreachable-object; return 1; }
    v="$(python3 "$_AV_DIR/../c14_probe.py" gitmeta "$gd" "$(lease_path_for "$r" 2>/dev/null)")"
    echo "${v:-kept:check-failed}"
    [[ "$v" == ok ]]
)

# c14_repos_ok <root> [--outer-certificate <receipt>]: validate the outer copy
# certificate, then run ordinary content and remote checks on every nested repository.
c14_check_repo_list() {
    local root=$1 deadline=${2:-} outer_receipt=${3:-} r v done= canon
    canon="$(cd "$root" 2>/dev/null && pwd -P)" || { echo kept:check-failed; return 1; }
    if [[ -n "$outer_receipt" ]]; then
        v="$(python3 "$_AV_DIR/../c14_probe.py" outer-certificate "$canon" "$outer_receipt")" || { echo "${v:-kept:check-failed}"; return 1; }
        [[ "$v" == ok ]] || { echo "$v"; return 1; }
    fi
    while IFS= read -r -d '' r; do
        [[ "$r" == OK ]] && { done=1; continue; }
        [[ "$r" == kept:* ]] && { echo "$r"; return 1; }
        if [[ -n "$outer_receipt" && "$r" == "$canon" ]]; then continue; fi
        v="$(c14_repo_content_ok "$r")" || { echo "$v"; return 1; }
        v="$(c14_repo_pushed_ok "$r" "$root" "$deadline")" || { echo "$v"; return 1; }
    done
    [[ -n "$done" ]] || { echo kept:check-failed; return 1; }
    echo ok
}

c14_repos_ok() {
    local root=$1 inv=${2:-} deadline=${3:-} receipt=
    if [[ "$inv" == --outer-certificate ]]; then
        receipt=${3:-}
        [[ -n "$receipt" && -z "${4:-}" ]] || { echo kept:check-failed; return 1; }
        c14_check_repo_list "$root" "" "$receipt" < <(c14_discover_repos "$root" && printf 'OK\0')
        return
    fi
    if [[ -n "$inv" ]]; then
        c14_check_repo_list "$root" "$deadline" < <(C14_ROOT="$root" python3 "$_AV_DIR/../c14_probe.py" repos "$inv" && printf 'OK\0')
    else
        c14_check_repo_list "$root" "$deadline" < <(c14_discover_repos "$root" && printf 'OK\0')
    fi
}

# c14_ephemeral_retention <canonical path> [<archived content path>] [--archive-origin]: minutes of
# the declared-ephemeral row E2-E7 it matches (§7.2; longest wins), rc 1 for
# none. --archive-origin restricts classification to the E2/E3 scratch-root
# rows. When validating a receipt, path selects the row and archived content
# supplies the source-shape check without probing a recreated original path.
c14_ephemeral_retention() {
    local p=$1 content=${2:-$1} archive_origin=${3:-} r rel
    while IFS= read -r r; do
        r="$(cd "$r" 2>/dev/null && pwd -P)" && rel=${p#"$r"/} && [[ "$rel" != "$p" && ! "$rel" =~ ^(_disk_magician_archive|system-|com\.apple\.|PowerlogHelperd) ]] || continue
        if [[ "$rel" =~ ^(pr[0-9]|pr-|pr_|claude-|claude_)[^/]*$ ]]; then echo 2880
        elif [[ ( "$rel" =~ ^agent_prompt_[^/]*\.txt$ && -f "$content" ) || ( "$rel" =~ ^[^/]+(/[^/]+)?$ && -d "$content/.git" ) ]]; then echo 240
        elif [[ ( "$rel" =~ ^cli_validation_gemini_[^/]*$ && -d "$content" ) || ( "$rel" != */* && -f "$content/.git" ) ]]; then echo 60
        else continue; fi
        return 0
    done < <(scratch_roots_get_unique)
    [[ "$archive_origin" != --archive-origin ]] || return 1
    rel=${p#"$HOME"/}
    if [[ "$rel" =~ ^\.gemini/antigravity/(brain|implicit)\.backup$ ]]; then echo 43200
    elif [[ "$rel" =~ ^\.gemini/antigravity(-cli)?/brain/[^/]+$ ]]; then echo 30240
    elif [[ "$rel" =~ ^\.aside/u/[^/]+/sessions/[^/]+$ || "$rel" =~ ^\.claude/supervisor/cmux-codex-launchd\.[0-9]{8}T[0-9]{6}\.log$ || "$rel" =~ ^Documents/Codex/[0-9]{4}-[0-9]{2}-[0-9]{2}(/[^/]+)?$ ]]; then echo 10080
    elif [[ "$rel" =~ ^\.llm-inspector/captures/(capture-[^/]*\.json|[^/]*\.summary\.json)$ ]]; then echo 4320
    else return 1; fi
}
# c14_archive_origin <candidate> <inventory>: E1 uses only a matching durable
# origin receipt. `none` falls through to ordinary provenance; invalid identity
# or a receipt whose E2/E3 retention has not elapsed stays kept.
c14_archive_origin() (
    local p=$1 inv=$2 archive_root receipt info original archived_at retention expected_retention now minimum
    archive_root="${DISK_MAGICIAN_ARCHIVE_ROOT:-${DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE:-/private/tmp}/_disk_magician_archive}"
    [[ -d "$archive_root" ]] || { echo none; return 0; }
    archive_root="$(cd "$archive_root" 2>/dev/null && pwd -P)" || { echo kept:archive-identity; return 0; }
    [[ "$p" == "$archive_root/"* ]] || { echo none; return 0; }
    receipt="$p.c14-origin.json"
    [[ -e "$receipt" || -L "$receipt" ]] || { echo none; return 0; }
    info="$(python3 "$_AV_DIR/../c14_probe.py" archive-info "$p" "$receipt" "$inv")"
    [[ "$info" != kept:* ]] || { echo kept:archive-identity; return 0; }
    IFS= read -r -d '' original < <(python3 -c 'import json,sys; sys.stdout.write(json.loads(sys.argv[1])["original_path"]); sys.stdout.write("\0")' "$info" 2>/dev/null) || { echo kept:archive-identity; return 0; }
    archived_at="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["archived_at"])' "$info" 2>/dev/null)" || { echo kept:archive-identity; return 0; }
    retention="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["retention_minutes"])' "$info" 2>/dev/null)" || { echo kept:archive-identity; return 0; }
    case "$retention" in 60|240|2880|4320|10080|30240|43200) ;; *) echo kept:archive-identity; return 0 ;; esac
    expected_retention="$(c14_ephemeral_retention "$original" "$p" --archive-origin)" || { echo kept:archive-identity; return 0; }
    [[ "$retention" == "$expected_retention" ]] || { echo kept:archive-identity; return 0; }
    minimum=1440
    (( retention > minimum )) && minimum=$retention
    now="$(date +%s)"
    (( now >= archived_at && now - archived_at >= minimum * 60 )) || { echo kept:recent-activity; return 0; }
    echo ok
)
# _av_rebuildable <path> [<deadline>]: rc 0 under the cache-root table (§7.2 (b)) or,
# as cleanup_worktree_venvs does, an untracked venv dir atop a linked worktree that
# passes the content and push checks and is past the strict 7-day floor. Prints
# `recent-activity` (and returns 1) when that floor protects the venv, or when
# worktree recency cannot be measured; a kept/deferred verdict from the push check
# is printed verbatim. The caller maps a bare reason back to kept.
_av_rebuildable() (
    local h w g t re='^((\.cache/(uv|pre-commit|worldai|ms-playwright|camoufox|claude-cli-nodejs|go-build|pip|puppeteer|huggingface|torch|triton|node-gyp|yarn|pnpm)|\.npm/(_cacache|_npx)|\.gradle/(caches|daemon|wrapper/dists)|\.cargo/registry/(cache|src)|\.rustup/toolchains/[^/]+|\.local/share/opencode/(repos|log|tool-output|snapshot)|\.local/state/fsevents-projects\.state\.json|\.peekaboo/snapshots|Snapchat/Dev/\.cache/bazel|Library/Caches/(ms-playwright|CocoaPods|@granolaelectron-updater|claude-cli-nodejs|go-build|org\.swift\.swiftpm|Google|Homebrew|pip|com\.apple\.dt\.Xcode|SentryCrash|SiriTTS)|Library/Application Support/(Cursor|Code|Google/Chrome|BraveSoftware/Brave-Browser|discord)/(Cache|CachedData|CachedExtensionVSIXs|Code Cache|GPUCache|DawnGraphiteCache|DawnWebGPUCache|Default/Cache|Default/Code Cache|Default/Service Worker/CacheStorage|Profile [0-9]+/Cache|Profile [0-9]+/Code Cache|Profile [0-9]+/Service Worker/CacheStorage)|Library/Developer/(Xcode/DerivedData|CoreSimulator/(Caches|Temp)))($|/[^/]))' deadline=${2:-} pushed
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
    if [[ "${1##*/}" =~ ^(venv|\.venv|venv\.bak(\..+)?)$ ]]; then
        if [[ "${DISK_MAGICIAN_INCLUDE_REPOS:-0}" == "1" ]]; then
            w="${1%/*}"
            [[ -e "$w/.git" && ( -f "$1/pyvenv.cfg" || -f "$1/bin/activate" || -x "$1/bin/python" ) ]] || return 1
            if git -C "$w" rev-parse --show-toplevel >/dev/null 2>&1; then
                t="$(git --literal-pathspecs -C "$w" ls-files -- "${1##*/}" 2>/dev/null)" || return 1
                [[ -z "$t" ]] || return 1
            fi
            worktree_is_recently_active "$w" 7 && { printf 'recent-activity\n'; return 1; }
            return 0
        fi
        w="$(git -C "${1%/*}" rev-parse --show-toplevel 2>/dev/null)" && [[ "$w" == "${1%/*}" ]] &&
            g="$(git -C "$w" rev-parse --absolute-git-dir 2>/dev/null)" &&
            [[ "$g" != "$(git -C "$w" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]] &&
            t="$(git --literal-pathspecs -C "$w" ls-files -- "${1##*/}" 2>/dev/null)" && [[ -z "$t" ]] &&
            c14_repo_content_ok "$w" >/dev/null || return 1
        # The caller's deadline reaches the bounded shared remote/topology probes;
        # their kept/deferred verdict is propagated verbatim (never kept:-prefixed).
        pushed="$(c14_repo_pushed_ok "$w" "$w" "$deadline")" || { printf '%s\n' "${pushed:-kept:check-failed}"; return 1; }
        # Canonical strict floor: no venv is stripped from a worktree touched
        # within 7 days, and unmeasurable recency fails closed as active.
        worktree_is_recently_active "$w" 7 && { printf 'recent-activity\n'; return 1; }
        return 0
    fi
    if [[ ! -d "$1/.git" && ( -e "$1/Build/Products" || -e "$1/ModuleCache.noindex" || -e "$1/Index.noindex" || -e "$1/CompilationCache.noindex" ) ]]; then
        return 0
    fi
    if [[ "$1" =~ ^/(private/)?tmp/idb(_[^/]*)?(/.*)?$ || "$1" =~ ^/(private/)?var/folders/[^/]+/[^/]+/C/clang/ModuleCache.*$ || "$1" =~ /\.beads/\.br_recovery/ || "$1" =~ ^/opt/homebrew/share/android-commandlinetools/(system-images|emulator|ndk)(/.*)?$ ]]; then
        return 0
    fi
    h="$(cd "$HOME" 2>/dev/null && pwd -P)" && [[ -n "$h" && "${1#"$h"/}" =~ $re ]]
)
# _av_newest_mtime <path>: newest mtime of <path> and everything under it; rc 1 if unmeasurable.
_av_newest_mtime() { python3 "$_AV_DIR/../c14_probe.py" newest-mtime "$1"; }
# _av_open_file <path>: rc 0 when lsof prints anything (an open non-cwd fd or an error).
_av_open_file() { python3 "$_AV_DIR/../c14_probe.py" open-file "$1" "${2:-}"; }
# _av_secret_like <path>: rc 0 when a secret-like name (wrh patterns) is under <path> or find fails.
_av_secret_like() {
    local out
    out="$(find "$1" \( -iname '.env*' -o -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' \
        -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'id_ecdsa*' -o -iname 'id_dsa*' -o -iname .npmrc \
        -o -iname .netrc -o -iname '*credentials*' -o -iname 'secrets*' \) ! -name '*.pyc' ! -path '*/__pycache__/*' \
        -print 2>/dev/null)" || return 0
    [[ -n "$out" ]]
}
# _av_lease_record_paths <path>: NUL-list the recorded path of every lease whose
# canonical path is <path> or under it, for any filesystem kind (plain dir, plain
# file, repo). Reads the lease store, not Git discovery, so a lease on a plain dir
# inside <path> still keeps it. rc 1 when the store cannot be scanned, a record is
# malformed, or a record's source filename is not the canonical lease name for its
# recorded path (fail closed: a lease we cannot rule out must keep the path).
_av_lease_record_paths() {
    local ld
    ld="$(lease_dir)" && [[ -d "$ld" ]] || return 0
    python3 - "$ld" "$1" <<'PY'
import hashlib, json, os, sys
ld, cand = sys.argv[1], os.path.realpath(sys.argv[2])
try:
    names = sorted(os.listdir(ld))
except OSError:
    sys.exit(1)
out = []
for n in names:
    if not n.endswith(".json") or n.startswith("."):
        continue
    p = os.path.join(ld, n)
    try:
        with open(p) as f:
            d = json.load(f)
    except FileNotFoundError:
        if os.path.islink(p):
            sys.exit(1)
        continue
    except (OSError, ValueError):
        sys.exit(1)
    rec = d.get("path") if isinstance(d, dict) else None
    if not isinstance(rec, str) or not rec:
        sys.exit(1)
    real = os.path.realpath(rec)
    # Bind the record to the file it came from. lease_path_for keys a lease as
    # sha256(realpath(path))[:16].json; a file stored under any other name has
    # an unknown identity and must fail closed rather than be silently dropped.
    if n != hashlib.sha256(os.fsencode(real)).hexdigest()[:16] + ".json":
        sys.exit(1)
    if real == cand or real.startswith(cand.rstrip("/") + "/"):
        out.append(real)
sys.stdout.buffer.write(b"".join(os.fsencode(p) + b"\0" for p in out))
PY
}

# _av_lease_scope <path>: NUL-list <path>, its ancestors below its scratch root (else
# $HOME, else /), every repository under it, and every lease record whose path is
# <path> or under it; rc 1 when discovery is incomplete. The lease-record scan runs
# last so the candidate's own lease is checked first; a failed scan still blocks.
_av_lease_scope() {
    local a=${1%/*} r stops=$'\n'
    while IFS= read -r r; do r="$(cd "$r" 2>/dev/null && pwd -P)" && stops+="$r"$'\n'; done < <(scratch_roots_get_unique)
    stops+="$(cd "$HOME" 2>/dev/null && pwd -P)"$'\n'
    printf '%s\0' "$1"
    while [[ -n "$a" && "$stops" != *$'\n'"$a"$'\n'* ]]; do printf '%s\0' "$a"; a=${a%/*}; done
    if [[ -d "$1" ]]; then
        if [[ -n "${2:-}" ]]; then C14_ROOT="$1" python3 "$_AV_DIR/../c14_probe.py" repos "$2" || return 1
        else c14_discover_repos "$1" || return 1; fi
    fi
    _av_lease_record_paths "$1"
}

# _av_path_identity <path>: filesystem identity in the format used by
# cleanup_code_sign_clones.sh. Both macOS and GNU stat forms are accepted.
_av_path_identity() {
    local id
    id="$(stat -f '%d:%i:%u' "$1" 2>/dev/null)" || id=''
    [[ "$id" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || id="$(stat -c '%d:%i:%u' "$1" 2>/dev/null)" || return 1
    [[ "$id" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    printf '%s\n' "$id"
}

# _av_os_clone_proof <path> <candidate-id> <parent-id> <X-root-id>: the
# caller freezes all three identities during enumeration and passes them back
# at the final verdict. The path must still be a recognized code-sign clone
# under the canonical X scan root and each identity must still match.
_av_os_clone_proof() {
    local p=$1 candidate_id=$2 parent_id=$3 root_id=$4 user_tmp x_dir parent base uid
    [[ "$candidate_id" =~ ^[0-9]+:[0-9]+:[0-9]+$ && "$parent_id" =~ ^[0-9]+:[0-9]+:[0-9]+$ &&
        "$root_id" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    if [[ -n "${DISK_MAGICIAN_CODE_SIGN_X_DIR:-}" ]]; then
        x_dir="$(cd "$DISK_MAGICIAN_CODE_SIGN_X_DIR" 2>/dev/null && pwd -P)" || return 1
    else
        user_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" || return 1
        user_tmp="$(cd "$user_tmp" 2>/dev/null && pwd -P)" || return 1
        x_dir="$(cd "$(dirname "$user_tmp")/X" 2>/dev/null && pwd -P)" || return 1
    fi
    [[ -n "$x_dir" && -d "$x_dir" && ! -L "$x_dir" && "$p" == "$x_dir/"* ]] || return 1
    parent=${p%/*}; base=${p##*/}
    if [[ "$parent" == "$x_dir" ]]; then
        [[ "$base" == *.code_sign_clone ]] || return 1
    else
        [[ "${parent%/*}" == "$x_dir" && "${parent##*/}" == *.code_sign_clone && "$base" == code_sign_clone.* ]] || return 1
    fi
    [[ -d "$p" && ! -L "$p" && ! -L "$parent" ]] || return 1
    uid="$(id -u)" || return 1
    [[ "$(_av_path_identity "$p")" == "$candidate_id" && "${candidate_id##*:}" == "$uid" &&
        "$(_av_path_identity "$parent")" == "$parent_id" && "$(_av_path_identity "$x_dir")" == "$root_id" &&
        "${parent_id##*:}" == "$uid" && "${root_id##*:}" == "$uid" ]]
}

# artifact_removal_verdict <path> [...] | --self-test
# Subshell so the cwd change inside wrh_live_cwd_reason never leaks to callers.
_av_artifact_removal_verdict() (
    [[ "${1:-}" == --self-test ]] && { echo incomplete; return 0; }
    local p=${1:-} kind='' deadline='' inventory_out='' own_claim='' t3_owner_null=0 q done='' st newest ret frozen_id='' frozen_parent_id='' frozen_root_id='' inv admin_source='' admin_filter='' candidate_lease=''
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --t3-owner-null) t3_owner_null=1; shift ;;
            --kind|--frozen-identity|--frozen-parent-identity|--frozen-root-identity|--deadline-at|--inventory-out|--own-reuse-claim)
                [[ $# -ge 2 ]] || { echo kept:check-failed; return 0; }
                case "$1" in
                    --kind) kind=$2 ;;
                    --frozen-identity) frozen_id=$2 ;;
                    --frozen-parent-identity) frozen_parent_id=$2 ;;
                    --frozen-root-identity) frozen_root_id=$2 ;;
                    --deadline-at) deadline=$2 ;;
                    --inventory-out) inventory_out=$2 ;;
                    --own-reuse-claim) own_claim=$2 ;;
                esac
                shift 2 ;;
            *) echo kept:check-failed; return 0 ;;
        esac
    done
    # A named reuse claim must be an absolute, existing lease file; never a
    # bare name that could resolve against the caller's cwd.
    if [[ -n "$own_claim" ]]; then
        [[ "$own_claim" == /* && -f "$own_claim" && ! -L "$own_claim" ]] || { echo kept:check-failed; return 0; }
        own_claim="$(cd "$(dirname "$own_claim")" 2>/dev/null && pwd -P)/${own_claim##*/}"
    fi
    p=${p%/} && [[ ! "${p##*/}" =~ ^\.{0,2}$ ]] && p="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/${p##*/}" && [[ -e "$p" && ! -L "$p" ]] || { echo kept:check-failed; return 0; }
    if [[ -n "$deadline" && ! "$deadline" =~ ^[0-9]+([.][0-9]+)?$ ]]; then echo kept:check-failed; return 0; fi
    "$_AV_DIR/../safety_check.sh" "$p" >/dev/null 2>&1 || { echo kept:protected; return 0; }
    q="$_AV_DIR/../../config.json" && [[ -f "$q" ]] || q+=.template  # never-touch tmp roots, as cleanup_tmp.sh
    # Anchored protection: only a configured protected basename directly under a
    # real scratch root (and its descendants) is protected. A same-named
    # component elsewhere (e.g. ~/.worktrees/worldarchitect.ai/foo or an
    # archive copy) must fall through to the ordinary C14 checks.
    scratch_roots_is_protected_path "$p" "$q" && { echo kept:protected; return 0; }
    if [[ -n "${DISK_MAGICIAN_TEST_AFTER_NOMINATE:-}" ]]; then
        [[ "${DISK_MAGICIAN_TEST_CONTEXT:-}" == 1 ]] || { echo kept:check-failed; return 0; }
        printf 'race fixture\n' >"$DISK_MAGICIAN_TEST_AFTER_NOMINATE" || { echo kept:check-failed; return 0; }
    fi
    inv=${C14_INVENTORY_FILE:-}
    [[ -n "$inv" ]] || { echo kept:check-failed; return 0; }
    st="$(python3 "$_AV_DIR/../c14_probe.py" inventory "$p" "$inv" ${deadline:+"$deadline"})"
    if [[ "$st" != ok ]]; then echo "${st:-kept:check-failed}"; return 0; fi
    # The one lease file whose owner-null state T3 may free. Never an ancestor
    # or descendant: only this exact path's own lease can match $q below.
    candidate_lease="$(lease_path_for "$p")" || { echo kept:check-failed; return 0; }
    while IFS= read -r -d '' q; do  # a lease not dead or released keeps; absent only on ENOENT
        [[ "$q" == OK ]] && { done=1; continue; }
        q="$(lease_path_for "$q")" || { echo kept:check-failed; return 0; }
        case "$(python3 -c 'import os,sys;d=os.path.dirname(sys.argv[1])
try:os.stat(d);os.stat(sys.argv[1]);print("lease" if os.access(d,os.R_OK|os.X_OK) else "")
except FileNotFoundError:print("none")' "$q" 2>/dev/null)" in none) continue ;; lease) ;; *) echo kept:owner-unknown; return 0 ;; esac
        # A dead/released lease frees the path. A pending reuse claim is
        # honored ONLY when the caller names the exact claim file it holds
        # (--own-reuse-claim) AND that file is this candidate's own lease (never
        # an ancestor's) AND the pending owner exactly matches this runtime.
        # Any other pending/live owner keeps, so a shared runtime ancestor or a
        # competing caller can never bypass the claim.
        if [[ -n "$own_claim" && "$q" == "$own_claim" && "$q" == "$(lease_path_for "$p")" ]] &&
            declare -F lease_owner_state_for >/dev/null 2>&1; then
            _av_own_owner="$(lease_resolve_owner 2>/dev/null)"
            _av_owner_state="$(lease_owner_state_for "$q" "$_av_own_owner" "$p")"
        else
            _av_owner_state="$(lease_owner_state "$q")"
        fi
        # Owner-null leases are never globally disposable. The T3 context
        # (--t3-owner-null, set only by cleanup_worktrees.sh's sanctioned
        # 3-day path) may free EXACTLY the candidate worktree's own null lease
        # after every other check; an ancestor/descendant null lease, T1, and
        # live/unknown/malformed owners all still keep.
        case "$_av_owner_state" in
            dead|released|own-live) ;;
            none)
                # birth-audit's ownerless scratch adoption record is ledger, not a claim.
                [[ "$(python3 -c 'import json,sys
try:d=json.load(open(sys.argv[1]));print("y" if "owner" in d and d["owner"] is None and d.get("pending") is False and d.get("kind")=="scratch" and d.get("creator")=="birth-audit" else "n")
except Exception:print("n")' "$q" 2>/dev/null)" == y ]] && continue
                if [[ "$t3_owner_null" != 1 || -z "$candidate_lease" || "$q" != "$candidate_lease" ]]; then
                    echo kept:owner-unknown; return 0
                fi ;;
            alive*) echo kept:live-owner; return 0 ;;
            *) echo kept:owner-unknown; return 0 ;;
        esac
    done < <(_av_lease_scope "$p" "$inv" && printf 'OK\0')
    [[ -n "$done" ]] || { echo kept:check-failed; return 0; }
    wrh_live_cwd_reason "$p"
    [[ -z "$WRH_LIVE_CWD_REASON" ]] || { echo "kept:$WRH_LIVE_CWD_REASON"; return 0; }
    st="$(_av_open_file "$p" "$deadline")"
    [[ "$st" == deferred:* ]] && { echo "$st"; return 0; }
    [[ "$st" == yes ]] && { echo kept:open-file; return 0; }
    [[ "$st" == no ]] || { [[ "$st" == kept:* ]] && echo "$st" || echo kept:check-failed; return 0; }
    newest="$(_av_newest_mtime "$inv")" || { echo kept:mtime-unmeasurable; return 0; }
    (( $(date +%s) - newest >= 3600 )) || { echo kept:recent-activity; return 0; }
    st="$(python3 "$_AV_DIR/../c14_probe.py" secrets "$inv")"
    if [[ "$st" != no ]]; then [[ "$st" == yes ]] && st=kept:secret-like; echo "${st:-kept:check-failed}"; return 0; fi
    if [[ -d "$p" ]]; then st="$(c14_repos_ok "$p" "$inv" "$deadline")" || { echo "$st"; return 0; }; fi
    case "$kind" in
        ephemeral) ret="$(c14_archive_origin "$p" "$inv")"
            if [[ "$ret" == none ]]; then
                ret="$(c14_ephemeral_retention "$p")" || { echo kept:unproven-content; return 0; }
                (( $(date +%s) - newest > ret * 60 )) || { echo kept:recent-activity; return 0; }
            else
                [[ "$ret" == ok ]] || { echo "$ret"; return 0; }
            fi ;;
        rebuildable) ret="$(_av_rebuildable "$p" "$deadline")" || {
            case "$ret" in
                deferred:*|kept:*) echo "$ret" ;;
                '') echo kept:unproven-content ;;
                *) echo "kept:$ret" ;;
            esac
            return 0; } ;;
        os_clone) _av_os_clone_proof "$p" "$frozen_id" "$frozen_parent_id" "$frozen_root_id" || { echo kept:check-failed; return 0; } ;;
        '') st="$({ C14_ROOT="$p" python3 "$_AV_DIR/../c14_probe.py" repos "$inv" && printf 'OK\0'; } |
                    python3 "$_AV_DIR/../c14_probe.py" provenance "$p" "$(lease_path_for "$p")" "$deadline")"
            [[ "$st" == ok ]] || { [[ "$st" == kept:* ]] && echo "$st" || echo kept:check-failed; return 0; } ;;
        *) echo kept:unproven-content; return 0 ;;
    esac
    if [[ -n "$inventory_out" ]]; then
        mkdir -p "$(dirname "$inventory_out")" || { echo kept:check-failed; return 0; }
        # Linked-worktree admin state belongs only to a candidate that is the
        # worktree root. A venv or other child directory has its own inventory;
        # appending the parent's admin rows makes later payload verification fail.
        if [[ -d "$p" ]]; then
            local top gd cd
            top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY -u GIT_CEILING_DIRECTORIES git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || top=''
            if [[ "$top" == "$p" ]]; then
                gd="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY -u GIT_CEILING_DIRECTORIES git -C "$p" rev-parse --absolute-git-dir 2>/dev/null)" || gd=''
                cd="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY -u GIT_CEILING_DIRECTORIES git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || cd=''
                [[ -n "$gd" && -n "$cd" && "$gd" != "$cd" ]] && { admin_source=${C14_ADMIN_INVENTORY:-}; admin_filter=$gd; }
            fi
        fi
        st="$(python3 "$_AV_DIR/../c14_probe.py" merge-inventory "$inv" "$admin_source" "$inventory_out.tmp.$$" "$admin_filter")"
        [[ "$st" == ok ]] && mv -f "$inventory_out.tmp.$$" "$inventory_out" || { rm -f "$inventory_out.tmp.$$"; echo kept:check-failed; return 0; }
    fi
    echo remove
)

# _av_self_test_run <root> — genuine kept/remove pair plus a corrupted-evidence
# negative through the production artifact_removal_verdict on self-owned /tmp
# fixtures. Prints `ok` only when every proof holds; prints nothing otherwise.
# Isolated: its own DISK_MAGICIAN_STATE_DIR under <root>, no ledger, no host
# policy decisions, no process stubs.
_av_self_test_run() {
    local root="$1" base seed good bad corrupt probe gd lm f out
    export HOME="$root/home"
    mkdir -p "$HOME" || return 0
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR GIT_EXEC_PATH
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=c14-selftest GIT_AUTHOR_EMAIL=c14-selftest@invalid
    export GIT_COMMITTER_NAME=c14-selftest GIT_COMMITTER_EMAIL=c14-selftest@invalid
    export DISK_MAGICIAN_STATE_DIR="$root/state"
    # Drop ambient test-injection overrides so the self-test's own /tmp fixture
    # is classified and probed with the real tools, never an inherited stub.
    unset DISK_MAGICIAN_C14_LEDGER C14_INVENTORY_OUT C14_INVENTORY_FILE DISK_MAGICIAN_LIFECYCLE_PARENT_PID \
        DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE DISK_MAGICIAN_TMP_ROOT_OVERRIDE DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE \
        DISK_MAGICIAN_ARCHIVE_ROOT DISK_MAGICIAN_STAT_BIN DISK_MAGICIAN_PS_BIN DISK_MAGICIAN_LSOF_BIN DISK_MAGICIAN_GIT_BIN
    probe="$_AV_DIR/../c14_probe.py"
    [[ -f "$probe" ]] || { echo incomplete; return 0; }
    declare -F c14_repo_content_ok >/dev/null 2>&1 || { echo incomplete; return 0; }
    # A corrupt/unreadable helper library must never authorize removal.
    python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$probe" 2>/dev/null || { echo incomplete; return 0; }
    base="$root/origin.git"
    seed="$root/seed"
    git init -q --bare -b main "$base" 2>/dev/null || return 0
    git init -q -b main "$seed" 2>/dev/null || return 0
    printf 'selftest\n' >"$seed/keep.txt" || return 0
    git -C "$seed" add -A >/dev/null 2>&1 && git -C "$seed" commit -qm selftest >/dev/null 2>&1 || return 0
    git -C "$seed" push -q "$base" main >/dev/null 2>&1 || return 0

    # remove fixture: clean, pushed clone with a released baseline lease.
    good="$root/remove-candidate"
    git clone -q "$base" "$good" 2>/dev/null || return 0
    gd="$(git -C "$good" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
    lm="$(python3 "$probe" gitmeta "$gd" 2>/dev/null)" || return 0
    f="$(lease_path_for "$good")" || return 0
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    printf '{"path":"%s","owner":{"pid":1},"released_at":1,"git_meta":%s}\n' "$good" "$lm" >"$f" || return 0
    find "$good" -exec touch -h -t 202001010000 {} + 2>/dev/null
    out="$(artifact_removal_verdict "$good" --kind ephemeral 2>/dev/null)"
    [[ "$out" == remove ]] || return 0

    # kept fixture: a dirty tracked edit must never be removed.
    bad="$root/keep-candidate"
    git clone -q "$base" "$bad" 2>/dev/null || return 0
    printf 'dirty\n' >>"$bad/keep.txt" || return 0
    gd="$(git -C "$bad" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
    lm="$(python3 "$probe" gitmeta "$gd" 2>/dev/null)" || return 0
    f="$(lease_path_for "$bad")" || return 0
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    printf '{"path":"%s","owner":{"pid":1},"released_at":1,"git_meta":%s}\n' "$bad" "$lm" >"$f" || return 0
    find "$bad" -exec touch -h -t 202001010000 {} + 2>/dev/null
    out="$(artifact_removal_verdict "$bad" --kind ephemeral 2>/dev/null)"
    [[ "$out" == kept:* ]] || return 0

    # corrupted helper-evidence negative: the same removable shape with a
    # damaged git_meta must fail closed (never remove).
    corrupt="$root/corrupt-candidate"
    git clone -q "$base" "$corrupt" 2>/dev/null || return 0
    f="$(lease_path_for "$corrupt")" || return 0
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    printf '{"path":"%s","owner":{"pid":1},"released_at":1,"git_meta":{}}\n' "$corrupt" >"$f" || return 0
    find "$corrupt" -exec touch -h -t 202001010000 {} + 2>/dev/null
    out="$(artifact_removal_verdict "$corrupt" --kind ephemeral 2>/dev/null)"
    [[ "$out" != remove ]] || return 0

    echo ok
}

# _av_self_test — allocate a self-owned /tmp root, run the real pair, and clean
# up only that root. Prints `ok` on a full pass, `incomplete` otherwise. A
# failed allocation or a missing/corrupt helper library never reports ok.
_av_self_test() {
    local root out
    root="$(mktemp -d /tmp/c14-selftest.XXXXXX)" || { echo incomplete; return 0; }
    if [[ -z "$root" || ( "$root" != /tmp/c14-selftest.* && "$root" != /private/tmp/c14-selftest.* ) || ! -d "$root" || -L "$root" ]]; then
        echo incomplete
        return 0
    fi
    out="$(_av_self_test_run "$root" 2>/dev/null)" || out=incomplete
    rm -rf -- "$root" 2>/dev/null
    [[ "$out" == ok ]] || out=incomplete
    printf '%s\n' "$out"
}

artifact_removal_verdict() {
    [[ "${1:-}" == --self-test ]] && { _av_self_test; return 0; }
    local tmpdir inv result reason admin_inv
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/c14-verdict.XXXXXX")" || { echo kept:check-failed; return 0; }
    inv="$tmpdir/inventory.json"
    # The admin row channel is per-call and owned by this verdict. A caller's
    # C14_INVENTORY_OUT is never inherited, and only --inventory-out names the
    # external receipt destination.
    admin_inv="$tmpdir/admin.jsonl"
    result="$(GIT_OPTIONAL_LOCKS=0 C14_INVENTORY_FILE="$inv" C14_ADMIN_INVENTORY="$admin_inv" C14_INVENTORY_OUT="$admin_inv" _av_artifact_removal_verdict "$@")"
    if [[ ( "$result" == kept:* || "$result" == deferred:* ) && -f "$inv" && -n "${DISK_MAGICIAN_C14_LEDGER:-}" ]]; then
        reason=${result#*:}
        python3 "$_AV_DIR/../c14_probe.py" account "$inv" "$DISK_MAGICIAN_C14_LEDGER" "$reason" >/dev/null 2>&1 || true
    fi
    rm -f "$inv" "$admin_inv"
    rmdir "$tmpdir" 2>/dev/null || true
    echo "${result:-kept:check-failed}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then artifact_removal_verdict "$@"; fi
