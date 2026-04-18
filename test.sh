#!/usr/bin/env bash
# test.sh
# ============================================================
# hands-on-metal — Complete Test Workflow (root entrypoint)
#
# Runs the full unit-test suite using the Python standard
# library only — matches the GitHub Actions CI invocation
# (.github/workflows/ci.yml), so a green local run means a
# green CI run.
#
# Usage:
#   bash test.sh            # run all tests
#   bash test.sh -v         # extra-verbose output (unittest -vv equivalent)
#   bash test.sh --help
#
# Any extra arguments are forwarded to `unittest discover`.
# ============================================================

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

case "${1:-}" in
    -h|--help)
        awk 'NR==1 {next} /^[^#]/ {exit} {sub(/^#[ \t]*/, ""); print}' "${BASH_SOURCE[0]}"
        exit 0
        ;;
esac

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    PYTHON=python
fi
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "ERROR: python3 (or python) not found in PATH." >&2
    exit 1
fi

exec "$PYTHON" -m unittest discover -v "$@" tests
