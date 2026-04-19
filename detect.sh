#!/usr/bin/env bash
# detect.sh
# ============================================================
# hands-on-metal — Phase 2: Environment & Device Detection (root entrypoint)
#
# Runs the full two-stage device detection workflow in one step.
# Each stage is an inlined code block with its own settings and
# relied-upon variables so the script is self-contained.
#
# ┌─ Code Block A · Environment Detection (menu option 3) ─────┐
# │  Script: magisk-module/env_detect.sh                       │
# │  Probes the shell environment, available tools, Python      │
# │  builds, and Termux state.  Writes every discovered fact    │
# │  to ENV_REGISTRY so later blocks can source it.            │
# │  Variables written:                                         │
# │    HOM_ENV_SHELL  HOM_ENV_BUSYBOX  HOM_ENV_PYTHON          │
# │    HOM_ENV_TERMUX HOM_ENV_ROOT                              │
# └────────────────────────────────────────────────────────────┘
#
# ┌─ Code Block B · Device Profile (menu option 4) ────────────┐
# │  Script: core/device_profile.sh                            │
# │  Relies on: ENV_REGISTRY written by Block A                │
# │  Probes and records device model, manufacturer, codename,  │
# │  API level, security patch level, A/B slots, SAR,          │
# │  dynamic partitions, Treble, AVB, and boot partition type. │
# │  Variables written:                                         │
# │    HOM_DEV_MODEL         HOM_DEV_CODENAME                  │
# │    HOM_DEV_MANUFACTURER  HOM_DEV_API_LEVEL                 │
# │    HOM_DEV_SPL           HOM_DEV_BUILD_ID                  │
# │    HOM_DEV_IS_AB         HOM_DEV_SAR                       │
# │    HOM_DEV_DYNAMIC_PARTITIONS  HOM_DEV_TREBLE              │
# │    HOM_DEV_AVB_STATE     HOM_DEV_BOOT_PART                 │
# │    HOM_DEV_SERIAL        HOM_DEV_KERNEL_VERSION            │
# └────────────────────────────────────────────────────────────┘
#
# Usage:
#   bash detect.sh                  # run env detect + device profile
#   bash detect.sh -s SERIAL        # target device serial (ADB scope)
#   bash detect.sh --out DIR        # write env registry to DIR/env_registry.sh
#   bash detect.sh --help
# ============================================================

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── Device scope ──────────────────────────────────────────────
ADB_SERIAL=""
OUT="${OUT:-$HOME/hands-on-metal}"

usage() {
    awk 'NR==1 {next} /^[^#]/ {exit} {sub(/^#[ \t]*/, ""); print}' \
        "${BASH_SOURCE[0]}"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s)        ADB_SERIAL="$2"; shift 2 ;;
        -s*)       ADB_SERIAL="${1#-s}"; shift ;;
        --out)     OUT="$2"; shift 2 ;;
        --out=*)   OUT="${1#*=}"; shift ;;
        -h|--help) usage ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Run 'bash detect.sh --help' for usage." >&2
            exit 2
            ;;
    esac
done

export ADB_SERIAL OUT

# ── Dependency check ──────────────────────────────────────────
if [ "${HOM_DEPS_CHECKED:-}" != "1" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/check_deps.sh"
fi

# ── Shared env registry path ──────────────────────────────────
# Both code blocks read/write the same registry so variables
# discovered in Block A are immediately available to Block B.
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
export ENV_REGISTRY
mkdir -p "$OUT"

# ════════════════════════════════════════════════════════════════
# Code Block A · Environment Detection  (menu option 3)
#   Script   : magisk-module/env_detect.sh
#   Settings : OUT, ENV_REGISTRY, LOG (env_detect.log)
#   Writes   : HOM_ENV_SHELL, HOM_ENV_BUSYBOX, HOM_ENV_PYTHON,
#              HOM_ENV_TERMUX, HOM_ENV_ROOT → ENV_REGISTRY
# ════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Block A · Environment Detection"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# env_detect.sh honours the ENV_REGISTRY env var set above.
# It runs as a subprocess so its internal set -u cannot affect us.
bash "$REPO_ROOT/magisk-module/env_detect.sh"

# Reload registry — picks up all HOM_ENV_* vars just written.
if [ -f "$ENV_REGISTRY" ]; then
    # shellcheck source=/dev/null
    source "$ENV_REGISTRY" 2>/dev/null || true
fi

echo ""
echo "  ✓ Block A complete."
echo "    HOM_ENV_SHELL   = ${HOM_ENV_SHELL:-(not set)}"
echo "    HOM_ENV_PYTHON  = ${HOM_ENV_PYTHON:-(not set)}"
echo "    HOM_ENV_TERMUX  = ${HOM_ENV_TERMUX:-(not set)}"
echo "    HOM_ENV_ROOT    = ${HOM_ENV_ROOT:-(not set)}"

# ════════════════════════════════════════════════════════════════
# Code Block B · Device Profile  (menu option 4)
#   Script   : core/device_profile.sh
#   Relies on: ENV_REGISTRY (written by Block A), android_device
#   Settings : SCRIPT_NAME, OUT, ENV_REGISTRY, REPO_ROOT,
#              PARTITION_INDEX
#   Framework: core/logging.sh, core/ux.sh, core/privacy.sh
#   Writes   : HOM_DEV_MODEL, HOM_DEV_CODENAME,
#              HOM_DEV_MANUFACTURER, HOM_DEV_API_LEVEL,
#              HOM_DEV_SPL, HOM_DEV_BUILD_ID, HOM_DEV_IS_AB,
#              HOM_DEV_SAR, HOM_DEV_DYNAMIC_PARTITIONS,
#              HOM_DEV_TREBLE, HOM_DEV_AVB_STATE,
#              HOM_DEV_BOOT_PART, HOM_DEV_SERIAL,
#              HOM_DEV_KERNEL_VERSION → ENV_REGISTRY
# ════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Block B · Device Profile"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Block B settings
export SCRIPT_NAME="device_profile"
PARTITION_INDEX="${PARTITION_INDEX:-$REPO_ROOT/build/partition_index.json}"
export PARTITION_INDEX

# Source framework required by core/device_profile.sh
# shellcheck source=core/logging.sh
source "$REPO_ROOT/core/logging.sh"
# shellcheck source=core/ux.sh
source "$REPO_ROOT/core/ux.sh"
# shellcheck source=core/privacy.sh
source "$REPO_ROOT/core/privacy.sh" 2>/dev/null || true

# Source device_profile (defines run_device_profile and all helpers)
# shellcheck source=core/device_profile.sh
source "$REPO_ROOT/core/device_profile.sh"

# Execute Block B
run_device_profile

# Reload registry to surface all HOM_DEV_* written by Block B
if [ -f "$ENV_REGISTRY" ]; then
    # shellcheck source=/dev/null
    source "$ENV_REGISTRY" 2>/dev/null || true
fi

echo ""
echo "  ✓ Block B complete."
echo "    HOM_DEV_MODEL     = ${HOM_DEV_MODEL:-(not set)}"
echo "    HOM_DEV_CODENAME  = ${HOM_DEV_CODENAME:-(not set)}"
echo "    HOM_DEV_API_LEVEL = ${HOM_DEV_API_LEVEL:-(not set)}"
echo "    HOM_DEV_IS_AB     = ${HOM_DEV_IS_AB:-(not set)}"
echo "    HOM_DEV_BOOT_PART = ${HOM_DEV_BOOT_PART:-(not set)}"
echo "    HOM_DEV_AVB_STATE = ${HOM_DEV_AVB_STATE:-(not set)}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✓ Detection complete.  Registry: $ENV_REGISTRY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next step — acquire the boot image (includes Magisk patch):"
echo "    bash boot.sh"
