#!/usr/bin/env bash
# findings_lint.sh — validate findings_wiki/ documents.
#
# Usage:
#   findings_lint.sh              Validate finding docs' frontmatter (forks).
#   findings_lint.sh --upstream   Assert PURITY: no finding docs may exist
#                                 (upstream repo must stay machine-agnostic).
#
# Exit codes: 0 ok, 1 violations found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIR="$REPO_ROOT/findings_wiki"

[[ -d "$DIR" ]] || { echo "findings_wiki/ missing"; exit 1; }

docs=()
for f in "$DIR"/*.md; do
  [[ -e "$f" ]] || break
  case "$(basename "$f")" in README.md|TEMPLATE.md) continue ;; esac
  docs+=("$f")
done

if [[ "${1:-}" == "--upstream" ]]; then
  if [[ "${#docs[@]}" -gt 0 ]]; then
    echo "PURITY VIOLATION: upstream must not contain finding docs:"
    printf '  %s\n' "${docs[@]}"
    exit 1
  fi
  echo "upstream purity OK (README.md + TEMPLATE.md only)"
  exit 0
fi

fail=0
for f in "${docs[@]}"; do
  for key in title hostname date status paths; do
    if ! grep -qE "^${key}:" "$f"; then
      echo "MISSING ${key}: $(basename "$f")"
      fail=1
    fi
  done
  if ! grep -qE "^status: *(active|mitigated|resolved)" "$f"; then
    echo "BAD status (want active|mitigated|resolved): $(basename "$f")"
    fail=1
  fi
done
echo "validated ${#docs[@]} finding doc(s)"
exit "$fail"
