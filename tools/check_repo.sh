#!/usr/bin/env bash
# tools/check_repo.sh
# ============================================================
# Local one-shot of the CI checks. Runs shellcheck on every *.sh
# and the Python unittest suite. Exits non-zero on the first
# failure so the output is easy to scan.
#
# Usage:
#   tools/check_repo.sh
# ============================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Running shellcheck on every *.sh"
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  shellcheck not installed — skipping (install: sudo apt-get install shellcheck)" >&2
else
    mapfile -t scripts < <(find . -type f -name '*.sh' -not -path './.git/*' | sort)
    if [ "${#scripts[@]}" -eq 0 ]; then
        echo "  no shell scripts found" >&2
        exit 1
    fi
    shellcheck "${scripts[@]}"
    echo "  ✓ shellcheck clean (${#scripts[@]} files)"
fi
echo

echo "==> Running Python unittest suite"
python3 -m unittest discover -v tests
echo

echo "All checks passed."
