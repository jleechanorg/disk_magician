#!/usr/bin/env bash
# evidence_push.sh — publish a /tmp evidence dir to the durable GCS store
# (spec D8): gcloud storage rsync -r <dir> $EVIDENCE_GCS_PREFIX/<repo>/<slug>/
#
# Usage: evidence_push.sh <dir> --repo <repo> --slug <slug>
# Exit: 0 uploaded, 1 usage/gcloud error, 2 source outside the evidence tmp
#       root, 3 secret-shaped file present (nothing uploaded).
set -euo pipefail

# shellcheck source=scripts/lib/layout_standard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/layout_standard.sh"

die() { echo "evidence-push: $2" >&2; exit "$1"; }

src="" repo="" slug=""
while (( $# )); do
    case "$1" in
        --repo) (( $# >= 2 )) || die 1 "--repo needs a value"; repo="$2"; shift 2 ;;
        --slug) (( $# >= 2 )) || die 1 "--slug needs a value"; slug="$2"; shift 2 ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        -*) die 1 "unknown option: $1" ;;
        *) [[ -z "$src" ]] || die 1 "only one source dir allowed"; src="$1"; shift ;;
    esac
done

[[ -n "$src" ]] || die 1 "source dir required"
_layout_valid_component "$repo" || die 1 "--repo must be a single path component"
_layout_valid_component "$slug" || die 1 "--slug must be a single path component"
[[ -d "$src" ]] || die 1 "not a directory: $src"

real_src="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$src")"
root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$EVIDENCE_TMP_ROOT")"
[[ "$real_src" == "${root%/}/"* ]] || die 2 "source $real_src is not under $root"

secrets="$(find "$real_src" \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \
    -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '*credentials*.json' \) -print)"
[[ -z "$secrets" ]] || die 3 "refusing upload; secret-shaped files present:
$secrets"

# Content scan (D8): gitleaks when installed, else a stdlib regex scan. Any
# finding or scanner error refuses the upload; only file paths are printed.
if command -v gitleaks >/dev/null 2>&1; then
    gitleaks detect --no-git --source "$real_src" --no-banner --redact >&2 \
        || die 3 "refusing upload; gitleaks reported leaks or failed (rc=$?)"
else
    hits="$(python3 - "$real_src" <<'PY'
import os, re, sys
pat = re.compile(rb'-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}'
                 rb'|github_pat_[A-Za-z0-9_]{50,}|xox[baprs]-[A-Za-z0-9-]{10,}'
                 rb'|sk-[A-Za-z0-9_-]{20,}|"private_key"\s*:')
for d, _, files in os.walk(sys.argv[1]):
    for n in files:
        p = os.path.join(d, n)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        if os.path.getsize(p) > 20 * 1024 * 1024:
            print("evidence-push: skipping content scan of >20MB file: " + p, file=sys.stderr)
            continue
        with open(p, "rb") as f:
            if pat.search(f.read()):
                print(p)
PY
)" || die 3 "refusing upload; content scan failed"
    [[ -z "$hits" ]] || die 3 "refusing upload; secret-shaped content in:
$hits"
fi

command -v gcloud >/dev/null 2>&1 || die 1 "gcloud not found on PATH"

dest="${EVIDENCE_GCS_PREFIX%/}/$repo/$slug/"
gcloud storage rsync -r "$real_src" "$dest" || die 1 "gcloud storage rsync failed"

browse="${dest#gs://}"
echo "$dest"
echo "https://console.cloud.google.com/storage/browser/${browse%/}"
