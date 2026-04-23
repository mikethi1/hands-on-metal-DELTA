#!/usr/bin/env bash
# boot.sh
# ============================================================
# hands-on-metal — Phase 3-4: Boot Image Acquisition + Magisk Patch
#                  (root entrypoint)
#
# Runs the full boot-image-to-root-patch workflow in one step.
# Option 5 (boot_image) and option 9 (magisk_patch) are inlined
# as self-contained code blocks with all their settings and
# relied-upon variables explicitly declared.
#
# ┌─ Code Block A · Boot Image Acquisition (menu option 5) ────┐
# │  Script: core/boot_image.sh                                │
# │  Relies on: device profile from detect.sh / env_registry   │
# │  Strategy (first match wins):                               │
# │    1. root DD from live partition                           │
# │    2. Magisk stock backup (/data/adb/magisk/stock_boot.img) │
# │    3. TWRP / OrangeFox / Nandroid backup (.emmc.win)       │
# │    4. Pre-placed file in BOOT_WORK_DIR or /sdcard/Download  │
# │    5. Google factory image download (Pixel devices)         │
# │    5b. GKI generic boot image (Android 12+, any device)    │
# │    5c. OEM-specific guidance (Samsung/Xiaomi/OnePlus/etc.)  │
# │    6. Manual path prompt                                    │
# │  Variables written:                                         │
# │    HOM_BOOT_IMG_PATH    HOM_BOOT_IMG_SHA256                 │
# │    HOM_BOOT_PART_SRC    HOM_BOOT_IMG_METHOD → ENV_REGISTRY  │
# └────────────────────────────────────────────────────────────┘
#
# ┌─ Code Block B · Magisk Patch (menu option 9) ──────────────┐
# │  Script: core/magisk_patch.sh                              │
# │  Relies on: HOM_BOOT_IMG_PATH (Block A), HOM_DEV_BOOT_PART,│
# │             HOM_DEV_IS_AB, HOM_DEV_SAR, HOM_DEV_AVB_STATE, │
# │             HOM_ARB_REQUIRE_MAY2026_FLAGS                   │
# │  Settings: BUNDLED_MAGISK, BUNDLED_MAGISK32,               │
# │             BUNDLED_MAGISKINIT, BUNDLED_MAGISKBOOT,         │
# │             BUNDLED_BOOT_PATCH_SH, BUNDLED_STUB_APK,       │
# │             BUNDLED_INIT_LD, BOOT_WORK_DIR                  │
# │  Workflow:                                                  │
# │    1. Locate Magisk binary (PATH, /data/adb/magisk/, tools/)│
# │    2. Determine device-specific patch flags                 │
# │    3. Apply anti-rollback-aware patch options               │
# │    4. Run magisk --patch-boot (or boot_patch.sh)           │
# │    5. Validate patched image (magic + size sanity)          │
# │    6. Record patched image path and SHA-256                 │
# │  Variables written:                                         │
# │    HOM_PATCHED_IMG_PATH  HOM_PATCHED_IMG_SHA256            │
# │    HOM_MAGISK_BIN        HOM_MAGISK_VERSION → ENV_REGISTRY  │
# └────────────────────────────────────────────────────────────┘
#
# Usage:
#   bash boot.sh                    # acquire + patch (guided)
#   bash boot.sh -s SERIAL          # target device serial (ADB scope)
#   bash boot.sh --out DIR          # working directory (env registry root)
#   bash boot.sh --patch-only       # skip Block A, run Block B only
#                                   # (requires HOM_BOOT_IMG_PATH in registry)
#   bash boot.sh --no-patch         # run Block A only (skip Magisk patch)
#   bash boot.sh --help
# ============================================================

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── Device scope ──────────────────────────────────────────────
ADB_SERIAL=""
OUT="${OUT:-$HOME/hands-on-metal}"
_PATCH_ONLY=false
_NO_PATCH=false

usage() {
    awk 'NR==1 {next} /^[^#]/ {exit} {sub(/^#[ \t]*/, ""); print}' \
        "${BASH_SOURCE[0]}"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s)           ADB_SERIAL="$2"; shift 2 ;;
        -s*)          ADB_SERIAL="${1#-s}"; shift ;;
        --out)        OUT="$2"; shift 2 ;;
        --out=*)      OUT="${1#*=}"; shift ;;
        --patch-only) _PATCH_ONLY=true; shift ;;
        --no-patch)   _NO_PATCH=true; shift ;;
        -h|--help)    usage ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Run 'bash boot.sh --help' for usage." >&2
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

# ── Shared env registry ───────────────────────────────────────
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
export ENV_REGISTRY
mkdir -p "$OUT"

# Load registry — picks up HOM_DEV_* from detect.sh / env_registry
if [ -f "$ENV_REGISTRY" ]; then
    # shellcheck source=/dev/null
    source "$ENV_REGISTRY" 2>/dev/null || true
fi

# ── Shared framework (used by both code blocks) ───────────────
export SCRIPT_NAME="boot_image"
# shellcheck source=core/logging.sh
source "$REPO_ROOT/core/logging.sh"
# shellcheck source=core/ux.sh
source "$REPO_ROOT/core/ux.sh"
# shellcheck source=core/privacy.sh
source "$REPO_ROOT/core/privacy.sh" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════
# Code Block A · Boot Image Acquisition  (menu option 5)
#   Script   : core/boot_image.sh
#   Settings : SCRIPT_NAME="boot_image", OUT, ENV_REGISTRY,
#              BOOT_WORK_DIR, PARTITION_INDEX, REPO_ROOT
#   Relied-on device vars (from ENV_REGISTRY / detect.sh):
#              HOM_DEV_SDK_INT, HOM_DEV_BOOT_PART,
#              HOM_DEV_IS_AB, HOM_DEV_CODENAME, HOM_DEV_MODEL
#   Writes   : HOM_BOOT_IMG_PATH, HOM_BOOT_IMG_SHA256,
#              HOM_BOOT_PART_SRC, HOM_BOOT_IMG_METHOD
# ════════════════════════════════════════════════════════════════
if [ "$_PATCH_ONLY" = false ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Block A · Boot Image Acquisition"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Block A settings
    BOOT_WORK_DIR="${BOOT_WORK_DIR:-$OUT/boot_work}"
    PARTITION_INDEX="${PARTITION_INDEX:-$REPO_ROOT/build/partition_index.json}"
    export BOOT_WORK_DIR PARTITION_INDEX

    mkdir -p "$BOOT_WORK_DIR"

    # Source boot_image.sh (defines run_boot_image_acquire + helpers)
    # shellcheck source=core/boot_image.sh
    source "$REPO_ROOT/core/boot_image.sh"

    # Execute Block A
    run_boot_image_acquire

    # Reload registry — picks up HOM_BOOT_IMG_PATH just written
    if [ -f "$ENV_REGISTRY" ]; then
        # shellcheck source=/dev/null
        source "$ENV_REGISTRY" 2>/dev/null || true
    fi

    echo ""
    echo "  ✓ Block A complete."
    echo "    HOM_BOOT_IMG_PATH   = ${HOM_BOOT_IMG_PATH:-(not set)}"
    echo "    HOM_BOOT_IMG_METHOD = ${HOM_BOOT_IMG_METHOD:-(not set)}"
    echo "    HOM_BOOT_IMG_SHA256 = ${HOM_BOOT_IMG_SHA256:-(not set)}"
fi

if [ "$_NO_PATCH" = true ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " ✓ Acquisition complete (--no-patch: Magisk patch skipped)."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Next step — patch the boot image with Magisk:"
    echo "    bash boot.sh --patch-only"
    exit 0
fi

# Validate that Block A produced a usable image before proceeding
if [ -z "${HOM_BOOT_IMG_PATH:-}" ] || \
   [ ! -f "${HOM_BOOT_IMG_PATH:-/nonexistent}" ]; then
    echo "" >&2
    echo "ERROR: HOM_BOOT_IMG_PATH is not set or the file does not exist." >&2
    echo "  Run Block A first:  bash boot.sh --no-patch" >&2
    echo "  Or provide the image and re-run: bash boot.sh --patch-only" >&2
    exit 1
fi

# ════════════════════════════════════════════════════════════════
# Code Block B · Magisk Patch  (menu option 9)
#   Script   : core/magisk_patch.sh
#   Settings : SCRIPT_NAME="magisk_patch", OUT, ENV_REGISTRY,
#              BOOT_WORK_DIR,
#              BUNDLED_MAGISK, BUNDLED_MAGISK32,
#              BUNDLED_MAGISKINIT, BUNDLED_MAGISKBOOT,
#              BUNDLED_BOOT_PATCH_SH, BUNDLED_STUB_APK,
#              BUNDLED_INIT_LD
#   Relied-on vars (loaded from ENV_REGISTRY):
#              HOM_BOOT_IMG_PATH       (set by Block A)
#              HOM_DEV_BOOT_PART       (init_boot | boot)
#              HOM_DEV_IS_AB           (true | false)
#              HOM_DEV_SAR             (true | false)
#              HOM_DEV_AVB_STATE       (AVB state string)
#              HOM_ARB_REQUIRE_MAY2026_FLAGS  (true | false)
#   Writes   : HOM_PATCHED_IMG_PATH, HOM_PATCHED_IMG_SHA256,
#              HOM_MAGISK_BIN, HOM_MAGISK_VERSION
# ════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Block B · Magisk Patch"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Block B settings — switch SCRIPT_NAME for logging
export SCRIPT_NAME="magisk_patch"

# Bundled binary paths (placed by fetch.sh / build/fetch_all_deps.sh)
_HOM_TOOLS_DIR="$REPO_ROOT/tools"
BUNDLED_MAGISK="${BUNDLED_MAGISK:-$_HOM_TOOLS_DIR/magisk64}"
BUNDLED_MAGISK32="${BUNDLED_MAGISK32:-$_HOM_TOOLS_DIR/magisk32}"
BUNDLED_MAGISKINIT="${BUNDLED_MAGISKINIT:-$_HOM_TOOLS_DIR/magiskinit}"
BUNDLED_MAGISKBOOT="${BUNDLED_MAGISKBOOT:-$_HOM_TOOLS_DIR/magiskboot}"
BUNDLED_BOOT_PATCH_SH="${BUNDLED_BOOT_PATCH_SH:-$_HOM_TOOLS_DIR/boot_patch.sh}"
BUNDLED_STUB_APK="${BUNDLED_STUB_APK:-$_HOM_TOOLS_DIR/stub.apk}"
BUNDLED_INIT_LD="${BUNDLED_INIT_LD:-$_HOM_TOOLS_DIR/init-ld}"
BOOT_WORK_DIR="${BOOT_WORK_DIR:-$OUT/boot_work}"
export BUNDLED_MAGISK BUNDLED_MAGISK32 BUNDLED_MAGISKINIT \
       BUNDLED_MAGISKBOOT BUNDLED_BOOT_PATCH_SH \
       BUNDLED_STUB_APK BUNDLED_INIT_LD BOOT_WORK_DIR

# Show which device variables Block B will use
echo "  Relied-on device variables:"
echo "    HOM_BOOT_IMG_PATH            = ${HOM_BOOT_IMG_PATH}"
echo "    HOM_DEV_BOOT_PART            = ${HOM_DEV_BOOT_PART:-(not set)}"
echo "    HOM_DEV_IS_AB                = ${HOM_DEV_IS_AB:-(not set)}"
echo "    HOM_DEV_SAR                  = ${HOM_DEV_SAR:-(not set)}"
echo "    HOM_DEV_AVB_STATE            = ${HOM_DEV_AVB_STATE:-(not set)}"
echo "    HOM_ARB_REQUIRE_MAY2026_FLAGS= ${HOM_ARB_REQUIRE_MAY2026_FLAGS:-(not set)}"
echo ""
echo "  Magisk binary search path:"
echo "    BUNDLED_MAGISK    = $BUNDLED_MAGISK"
echo "    BUNDLED_MAGISK32  = $BUNDLED_MAGISK32"
echo "    BUNDLED_MAGISKBOOT= $BUNDLED_MAGISKBOOT"
echo ""

# Source magisk_patch.sh (defines run_magisk_patch + all helpers)
# shellcheck source=core/magisk_patch.sh
source "$REPO_ROOT/core/magisk_patch.sh"

# Execute Block B
run_magisk_patch

# Reload registry — picks up HOM_PATCHED_IMG_PATH just written
if [ -f "$ENV_REGISTRY" ]; then
    # shellcheck source=/dev/null
    source "$ENV_REGISTRY" 2>/dev/null || true
fi

echo ""
echo "  ✓ Block B complete."
echo "    HOM_PATCHED_IMG_PATH   = ${HOM_PATCHED_IMG_PATH:-(not set)}"
echo "    HOM_PATCHED_IMG_SHA256 = ${HOM_PATCHED_IMG_SHA256:-(not set)}"
echo "    HOM_MAGISK_VERSION     = ${HOM_MAGISK_VERSION:-(not set)}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✓ Boot + patch complete."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Patched image: ${HOM_PATCHED_IMG_PATH:-(see env registry)}"
echo ""
echo "Next steps:"
echo "  Check anti-rollback risk (recommended before flashing):"
echo "      bash terminal_menu.sh   # choose option: core/anti_rollback.sh"
echo ""
echo "  Flash the patched image directly:"
echo "      bash flash.sh"
