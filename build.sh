#!/usr/bin/env bash
# build.sh
# ============================================================
# hands-on-metal — Complete Build Workflow (root entrypoint)
#
# A single-command wrapper around build/build_offline_zip.sh.
# Run from the repository root or anywhere — this script always
# resolves the repo root from its own location, so it is safe to
# paste into a terminal or invoke from a parent directory.
#
# Usage:
#   bash build.sh                  # build both flashable ZIPs (Magisk module + recovery)
#   bash build.sh --no-tools       # build without bundled binaries
#   bash build.sh --version 2.0.0  # override version
#   bash build.sh --help           # show build_offline_zip.sh help
#
# All extra arguments are forwarded verbatim to build_offline_zip.sh.
#
# After a successful build, prints the suggested next step
# (flashing — see ./flash.sh).
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

bash build/build_offline_zip.sh "$@"

echo ""
echo "✓ Build complete.  Output: $REPO_ROOT/dist/"
echo ""
echo "Next step — flash the resulting ZIP to a connected device:"
echo "    bash flash.sh"
