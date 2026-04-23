#!/usr/bin/env bash
# fetch.sh
# ============================================================
# hands-on-metal — Phase 1: Fetch Dependencies (root entrypoint)
#
# Downloads every dependency the project needs and produces the
# flashable offline ZIPs in one step:
#
#   1. Downloads the Magisk APK and extracts the binaries:
#        magisk64, magisk32, magiskinit, magiskboot, boot_patch.sh
#        stub.apk, init-ld  → placed in tools/
#   2. Downloads busybox-arm64 → placed in tools/
#   3. Calls build/build_offline_zip.sh to produce:
#        dist/hands-on-metal-magisk-module-<version>.zip
#        dist/hands-on-metal-recovery-<version>.zip
#   4. Bundles everything into a single offline archive:
#        dist/hands-on-metal-full-bundle-<version>.zip
#
# Variables populated after a successful run
# (written to env_registry by build scripts):
#   HOM_MODULE_VERSION     — module version string
#   HOM_MAGISK_VERSION     — Magisk version downloaded
#   HOM_BUSYBOX_VERSION    — busybox version downloaded
#
# Usage:
#   bash fetch.sh                            # fetch latest + build ZIPs
#   bash fetch.sh --magisk-version v30.7     # pin Magisk version
#   bash fetch.sh --busybox-version 1.31.0   # pin busybox version
#   bash fetch.sh --skip-binaries            # repo + ZIPs only
#   bash fetch.sh --version 2.1.0            # override module version
#   bash fetch.sh -s SERIAL                  # target device serial (ADB scope)
#   bash fetch.sh --help
# ============================================================

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── Device scope ──────────────────────────────────────────────
ADB_SERIAL=""

# ── Argument parsing ──────────────────────────────────────────
_extra_args=()

usage() {
    awk 'NR==1 {next} /^[^#]/ {exit} {sub(/^#[ \t]*/, ""); print}' \
        "${BASH_SOURCE[0]}"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s)        ADB_SERIAL="$2"; shift 2 ;;
        -s*)       ADB_SERIAL="${1#-s}"; shift ;;
        -h|--help) usage ;;
        *)         _extra_args+=("$1"); shift ;;
    esac
done

export ADB_SERIAL

# ── Dependency check ──────────────────────────────────────────
if [ "${HOM_DEPS_CHECKED:-}" != "1" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/check_deps.sh"
fi

# ── Load existing env registry ────────────────────────────────
# Picks up any previously detected HOM_* device variables so
# downstream steps can use them without re-running detection.
ENV_REGISTRY="${ENV_REGISTRY:-$HOME/hands-on-metal/env_registry.sh}"
export ENV_REGISTRY
if [ -f "$ENV_REGISTRY" ]; then
    # shellcheck source=/dev/null
    source "$ENV_REGISTRY" 2>/dev/null || true
fi

# ── Run ───────────────────────────────────────────────────────
if [ "${#_extra_args[@]}" -gt 0 ]; then
    bash "$REPO_ROOT/build/fetch_all_deps.sh" "${_extra_args[@]}"
else
    bash "$REPO_ROOT/build/fetch_all_deps.sh"
fi

echo ""
echo "✓ Fetch complete.  Binaries in: $REPO_ROOT/tools/"
echo "                   ZIPs in:     $REPO_ROOT/dist/"
echo ""
echo "Next step — detect the connected device:"
echo "    bash detect.sh"
