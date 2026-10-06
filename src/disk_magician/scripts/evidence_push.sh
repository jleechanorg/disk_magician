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

command -v gcloud >/dev/null 2>&1 || die 1 "gcloud not found on PATH"

dest="${EVIDENCE_GCS_PREFIX%/}/$repo/$slug/"
gcloud storage rsync -r "$real_src" "$dest" || die 1 "gcloud storage rsync failed"

browse="${dest#gs://}"
echo "$dest"
echo "https://console.cloud.google.com/storage/browser/${browse%/}"
