#!/usr/bin/env bash
# collect.sh
# ============================================================
# hands-on-metal — Phase 5: Hardware Data Collection (root entrypoint)
#
# Collects all hardware-relevant data READ-ONLY from the device
# into the output directory, then writes a manifest so the
# host-side pipeline knows what is available.
#
# ┌─ Code Block A · Data Collection ───────────────────────────┐
# │  Script: magisk-module/collect.sh                          │
# │  Root-adaptive — behaviour depends on privilege level:     │
# │    With root   : full collection — dmesg, pinctrl,        │
# │                  vendor library symbols, readelf, boot     │
# │                  partition DD, dmsetup                     │
# │    Without root: partial collection — getprop, /proc       │
# │                  files, readable sysfs classes, VINTF      │
# │                  manifests, sysconfig, board summary,      │
# │                  encryption state props                    │
# │  Safety guarantees:                                        │
# │    • Never mounts any partition read-write                 │
# │    • Never writes outside $OUT/                            │
# │    • Skips unreadable paths gracefully                     │
# │  Relies on (from env_registry / detect.sh):                │
# │    HOM_ENV_ROOT     — whether root is available            │
# │    HOM_DEV_MODEL    — device model for manifest labelling  │
# │    HOM_DEV_IS_AB    — slot layout awareness                │
# │  Variables written:                                        │
# │    HOM_COLLECT_STATUS  HOM_COLLECT_FILE_COUNT             │
# │    HOM_COLLECT_ROOT_MODE → ENV_REGISTRY (via manifest)    │
# └────────────────────────────────────────────────────────────┘
#
# Device scope:
#   -s SERIAL targets a specific ADB device when the collection
#   is triggered from a host PC via `adb shell`.  When running
#   directly in Termux on the device, -s is ignored.
#
# Usage:
#   bash collect.sh                  # collect on current device
#   bash collect.sh -s SERIAL        # target device serial (ADB scope)
#   bash collect.sh --out DIR        # write live_dump to DIR/live_dump/
#   bash collect.sh --help
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
            echo "Run 'bash collect.sh --help' for usage." >&2
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

# ── Load env registry ─────────────────────────────────────────
# Picks up HOM_DEV_* and HOM_ENV_* set by detect.sh.
ENV_REGISTRY="${ENV_REGISTRY:-$HOME/hands-on-metal/env_registry.sh}"
export ENV_REGISTRY
if [ -f "$ENV_REGISTRY" ]; then
    # shellcheck source=/dev/null
    source "$ENV_REGISTRY" 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════════
# Code Block A · Data Collection  (Phase 5 / pipeline menu option)
#   Script   : magisk-module/collect.sh
#   Settings : OUT  (→ live_dump lives at $OUT/live_dump/),
#              ENV_REGISTRY (read for HOM_DEV_* context;
#                            collect.sh also writes manifest vars)
#   Relied-on vars (from ENV_REGISTRY / detect.sh):
#              HOM_ENV_ROOT    — root presence → full vs partial
#              HOM_DEV_MODEL   — device model for labelling
#              HOM_DEV_IS_AB   — slot layout (A/B aware)
#              HOM_DEV_BOOT_PART — partition to DD if root
#   Writes   : $OUT/live_dump/ (collection tree)
#              $OUT/live_dump/manifest.txt
#              $OUT/live_dump/collect.log
# ════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Block A · Hardware Data Collection"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Device scope:"
echo "    ADB_SERIAL  = ${ADB_SERIAL:-(any connected device)}"
echo "    OUT         = $OUT"
echo "  Device context (from registry):"
echo "    HOM_DEV_MODEL    = ${HOM_DEV_MODEL:-(not detected — run detect.sh first)}"
echo "    HOM_ENV_ROOT     = ${HOM_ENV_ROOT:-(unknown)}"
echo ""

# collect.sh uses its own OUT internally:
#   OUT="${HOME:-/data/local/tmp}/hands-on-metal/live_dump"
# We override via the environment variable so our OUT/live_dump is used.
export OUT="$OUT/live_dump"

bash "$REPO_ROOT/magisk-module/collect.sh"

# Restore OUT to the parent level so the registry path is correct
export OUT="${OUT%/live_dump}"

# Reload registry to pick up any vars written by collect
if [ -f "$ENV_REGISTRY" ]; then
    # shellcheck source=/dev/null
    source "$ENV_REGISTRY" 2>/dev/null || true
fi

_DUMP_DIR="$OUT/live_dump"
_FILE_COUNT=0
if [ -d "$_DUMP_DIR" ]; then
    _FILE_COUNT=$(find "$_DUMP_DIR" -type f 2>/dev/null | wc -l || echo 0)
fi

echo ""
echo "  ✓ Block A complete."
echo "    Live dump : $_DUMP_DIR"
echo "    File count: $_FILE_COUNT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✓ Collection complete."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next step — run the analysis pipeline (pull logs + parse):"
echo "    bash pipeline.sh --mode A"
echo ""
echo "Or pull the live dump from the device and parse directly:"
echo "    adb${ADB_SERIAL:+ -s $ADB_SERIAL} pull ~/hands-on-metal/live_dump/ ./live_dump/"
echo "    python3 pipeline/parse_logs.py --log ./logs --out ./parsed.json"
