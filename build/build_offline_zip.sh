#!/bin/bash
# build/build_offline_zip.sh
# ============================================================
# Builds the fully offline, self-contained flashable ZIPs:
#
#   hands-on-metal-magisk-module.zip   — flash via Magisk app
#   hands-on-metal-recovery.zip        — flash via TWRP/OrangeFox
#
# The recovery ZIP includes everything needed to bootstrap root
# from a device that does NOT yet have Magisk installed.
#
# Prerequisites (all optional but unlock more offline capability):
#   • tools/busybox-arm64   — static busybox for recovery
#   • tools/magisk64        — Magisk binary for offline patch
#   • tools/magisk32        — 32-bit Magisk binary (older devices)
#   • tools/magiskinit64    — Magisk init binary
#
# Usage:
#   bash build/build_offline_zip.sh
#   bash build/build_offline_zip.sh --no-tools   (skip tool validation)
#   bash build/build_offline_zip.sh --version 2.0.0
#
# Output: dist/
# ============================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
TOOLS_DIR="$REPO_ROOT/tools"
BUILD_DIR="$REPO_ROOT/build"

# Default version from module.prop
DEFAULT_VERSION=$(grep '^version=' "$REPO_ROOT/magisk-module/module.prop" \
    2>/dev/null | cut -d= -f2 || echo "v1.0.0")

# ── argument parsing ──────────────────────────────────────────
VERSION="$DEFAULT_VERSION"
SKIP_TOOLS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --no-tools) SKIP_TOOLS=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

echo "============================================"
echo " hands-on-metal Offline ZIP Builder"
echo " Version: $VERSION"
echo "============================================"
echo ""

# ── output directory ──────────────────────────────────────────
mkdir -p "$DIST_DIR"

# ── tool validation ───────────────────────────────────────────
missing_tools=()

if [ "$SKIP_TOOLS" = false ]; then
    for tool in busybox-arm64 magisk64; do
        if [ ! -f "$TOOLS_DIR/$tool" ]; then
            missing_tools+=("$tool")
        fi
    done
fi

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "WARNING: The following optional tools are missing from $TOOLS_DIR/:"
    for t in "${missing_tools[@]}"; do
        echo "  - $t"
    done
    echo ""
    echo "ZIPs will be built without bundled binaries."
    echo "See docs/MAINTAINER.md for how to obtain them."
    echo ""
fi

# ── build temp staging area ───────────────────────────────────
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "[1/4] Staging common files..."

# Core scripts
mkdir -p "$STAGE/core"
cp "$REPO_ROOT/core/"*.sh "$STAGE/core/"
chmod 0755 "$STAGE/core/"*.sh

# Partition index
mkdir -p "$STAGE/build"
cp "$BUILD_DIR/partition_index.json" "$STAGE/build/"

# Tools (busybox, Magisk binaries — best-effort)
mkdir -p "$STAGE/tools"
for tool in busybox-arm64 magisk64 magisk32 magiskinit64; do
    if [ -f "$TOOLS_DIR/$tool" ]; then
        cp "$TOOLS_DIR/$tool" "$STAGE/tools/"
        echo "  Bundled: $tool"
    fi
done

# Recovery collect script
mkdir -p "$STAGE/recovery-zip"
cp "$REPO_ROOT/recovery-zip/collect_recovery.sh" "$STAGE/recovery-zip/"
chmod 0755 "$STAGE/recovery-zip/collect_recovery.sh"

# ── build Magisk module ZIP ───────────────────────────────────
echo "[2/4] Building Magisk module ZIP..."

MODULE_STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$MODULE_STAGE"' EXIT

# Module files
cp -r "$STAGE/core"   "$MODULE_STAGE/"
cp -r "$STAGE/build"  "$MODULE_STAGE/"
cp -r "$STAGE/tools"  "$MODULE_STAGE/"

# Magisk module files
for f in module.prop service.sh collect.sh env_detect.sh setup_termux.sh customize.sh; do
    if [ -f "$REPO_ROOT/magisk-module/$f" ]; then
        cp "$REPO_ROOT/magisk-module/$f" "$MODULE_STAGE/"
        chmod 0755 "$MODULE_STAGE/$f" 2>/dev/null || true
    fi
done

# META-INF
mkdir -p "$MODULE_STAGE/META-INF/com/google/android"
cp "$REPO_ROOT/magisk-module/META-INF/com/google/android/update-binary" \
    "$MODULE_STAGE/META-INF/com/google/android/"
cp "$REPO_ROOT/magisk-module/META-INF/com/google/android/updater-script" \
    "$MODULE_STAGE/META-INF/com/google/android/"
chmod 0755 "$MODULE_STAGE/META-INF/com/google/android/update-binary"

# Update module.prop version
sed -i "s/^version=.*/version=$VERSION/" "$MODULE_STAGE/module.prop" 2>/dev/null || true

MAGISK_ZIP="$DIST_DIR/hands-on-metal-magisk-module-${VERSION}.zip"
(cd "$MODULE_STAGE" && zip -r9 "$MAGISK_ZIP" . >/dev/null)
echo "  → $MAGISK_ZIP  ($(du -sh "$MAGISK_ZIP" | cut -f1))"

# ── build Recovery ZIP ────────────────────────────────────────
echo "[3/4] Building Recovery ZIP..."

RECOVERY_STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$MODULE_STAGE" "$RECOVERY_STAGE"' EXIT

# Core + tools + recovery-zip + magisk-module scripts (all needed by update-binary)
cp -r "$STAGE/core"          "$RECOVERY_STAGE/"
cp -r "$STAGE/build"         "$RECOVERY_STAGE/"
cp -r "$STAGE/tools"         "$RECOVERY_STAGE/"
cp -r "$STAGE/recovery-zip"  "$RECOVERY_STAGE/"

# Magisk module scripts (used during recovery install for module setup)
mkdir -p "$RECOVERY_STAGE/magisk-module"
for f in service.sh collect.sh env_detect.sh setup_termux.sh customize.sh module.prop; do
    if [ -f "$REPO_ROOT/magisk-module/$f" ]; then
        cp "$REPO_ROOT/magisk-module/$f" "$RECOVERY_STAGE/magisk-module/"
    fi
done

# META-INF
mkdir -p "$RECOVERY_STAGE/META-INF/com/google/android"
cp "$REPO_ROOT/recovery-zip/META-INF/com/google/android/update-binary" \
    "$RECOVERY_STAGE/META-INF/com/google/android/"
cp "$REPO_ROOT/recovery-zip/META-INF/com/google/android/updater-script" \
    "$RECOVERY_STAGE/META-INF/com/google/android/"
chmod 0755 "$RECOVERY_STAGE/META-INF/com/google/android/update-binary"

RECOVERY_ZIP="$DIST_DIR/hands-on-metal-recovery-${VERSION}.zip"
(cd "$RECOVERY_STAGE" && zip -r9 "$RECOVERY_ZIP" . >/dev/null)
echo "  → $RECOVERY_ZIP  ($(du -sh "$RECOVERY_ZIP" | cut -f1))"

# ── generate SHA-256 checksums ────────────────────────────────
echo "[4/4] Generating checksums..."

CHECKSUM_FILE="$DIST_DIR/checksums-${VERSION}.sha256"
(
    cd "$DIST_DIR"
    sha256sum \
        "hands-on-metal-magisk-module-${VERSION}.zip" \
        "hands-on-metal-recovery-${VERSION}.zip" \
    > "$CHECKSUM_FILE"
)
echo "  → $CHECKSUM_FILE"

# ── summary ───────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Build complete — $DIST_DIR/"
echo "============================================"
echo ""
echo "  Magisk module ZIP : hands-on-metal-magisk-module-${VERSION}.zip"
echo "    Flash via: Magisk app → Modules → Install from storage"
echo ""
echo "  Recovery ZIP      : hands-on-metal-recovery-${VERSION}.zip"
echo "    Flash via: TWRP/OrangeFox → Install → select ZIP"
echo ""
echo "  Checksums         : checksums-${VERSION}.sha256"
echo ""

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "NOTE: ZIPs were built without some bundled tools:"
    for t in "${missing_tools[@]}"; do
        echo "  - tools/$t  (see docs/MAINTAINER.md)"
    done
    echo ""
fi
