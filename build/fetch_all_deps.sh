#!/usr/bin/env bash
# build/fetch_all_deps.sh
# ============================================================
# hands-on-metal — Full Dependency Fetcher + Offline Bundle Creator
#
# Uses git + curl to pull every dependency the project needs,
# then calls build_offline_zip.sh to produce the two flashable
# ZIPs, and finally creates a single offline bundle ZIP that
# contains:
#
#   • A complete snapshot of the repo at HEAD
#   • All optional binaries (busybox-arm64, magisk64, magisk32,
#     magiskinit64) in tools/
#   • Both flashable ZIPs (Magisk module + recovery)
#   • SHA-256 checksums
#
# Output: dist/hands-on-metal-full-bundle-<version>.zip
#
# Usage:
#   bash build/fetch_all_deps.sh
#   bash build/fetch_all_deps.sh --magisk-version v30.7
#   bash build/fetch_all_deps.sh --busybox-version 1.31.0
#   bash build/fetch_all_deps.sh --skip-binaries   (repo + ZIPs only)
#   bash build/fetch_all_deps.sh --version 2.1.0   (override module version)
#
# Requirements (host):
#   git  curl  unzip  zip  sha256sum (or shasum)  python3 (stdlib only)
# ============================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/tools"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$REPO_ROOT/build"

# ── defaults ──────────────────────────────────────────────────
MAGISK_VERSION="v30.7"
BUSYBOX_VERSION="1.31.0"
SKIP_BINARIES=false
MODULE_VERSION=""   # empty → read from module.prop

# ── argument parsing ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --magisk-version)  MAGISK_VERSION="$2";  shift 2 ;;
        --busybox-version) BUSYBOX_VERSION="$2"; shift 2 ;;
        --version)         MODULE_VERSION="$2";  shift 2 ;;
        --skip-binaries)   SKIP_BINARIES=true;   shift ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── resolve version ───────────────────────────────────────────
if [ -z "$MODULE_VERSION" ]; then
    MODULE_VERSION=$(grep '^version=' "$REPO_ROOT/magisk-module/module.prop" \
        2>/dev/null | cut -d= -f2 || echo "v2.0.0")
fi

# ── sha256sum portability ─────────────────────────────────────
if command -v sha256sum >/dev/null 2>&1; then
    SHA256="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA256="shasum -a 256"
else
    echo "ERROR: neither sha256sum nor shasum found — cannot verify downloads." >&2
    exit 1
fi

# ── portable temp directory (Termux sets $TMPDIR; fallback is $HOME/tmp) ─
_TMP="${TMPDIR:-${HOME:-.}/tmp}"
mkdir -p "$_TMP"

# ── helpers ───────────────────────────────────────────────────
step() { echo ""; echo "──────────────────────────────────────────"; echo " $*"; echo "──────────────────────────────────────────"; }
ok()   { echo "  ✓  $*"; }
warn() { echo "  ⚠  $*"; }
fail() { echo "  ✗  $*" >&2; }

require_cmd() {
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            fail "Required command not found: $cmd"
            echo "    Install it and re-run this script." >&2
            exit 1
        fi
    done
}

download() {
    local url="$1" dest="$2"
    local dest_dir
    dest_dir="$(dirname "$dest")"
    if [ ! -d "$dest_dir" ]; then
        mkdir -p "$dest_dir" || { fail "Cannot create directory: $dest_dir"; exit 1; }
    fi
    echo "  Downloading: $url"
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
            fail "Download failed: $url"
            fail "Check network connectivity and that the URL is reachable."
            exit 1
        fi
    else
        fail "curl is required for downloads."
        exit 1
    fi
    ok "Saved to: $dest"
}

# extract_magisk_binary <apk> <dest_file> <primary_path> [<fallback_path>...]
#
# Tries to extract a library from the Magisk APK using multiple
# candidate paths.  Magisk v26+ renamed libmagisk64.so / libmagisk32.so
# to libmagisk.so under each ABI directory, so we try the current name
# first and fall back to the old name.  On failure the APK contents are
# listed for diagnostic purposes.
extract_magisk_binary() {
    local apk="$1" dest="$2"
    shift 2
    local paths=("$@")

    local unzip_log="$_TMP/hom-unzip-$$.log"
    local extracted=false

    for candidate in "${paths[@]}"; do
        if unzip -jo "$apk" "$candidate" -d "$_TMP/" >"$unzip_log" 2>&1; then
            local basename
            basename="$(basename "$candidate")"
            cp "$_TMP/$basename" "$dest" && chmod +x "$dest"
            rm -f "$_TMP/$basename"
            extracted=true
            break
        fi
    done

    rm -f "$unzip_log"

    if [ "$extracted" = false ]; then
        fail "Extraction failed — APK does not contain any of the expected library paths:"
        for p in "${paths[@]}"; do
            echo "    • $p" >&2
        done
        echo "" >&2
        echo "  APK contents (lib/ entries):" >&2
        unzip -l "$apk" 2>/dev/null | grep 'lib/' | head -30 >&2 || true
        echo "" >&2
        fail "Check the Magisk release at: $MAGISK_APK_URL"
        exit 1
    fi
}

echo ""
echo "=============================================="
echo "  hands-on-metal Full Dependency Fetcher"
echo "  Module version : $MODULE_VERSION"
echo "  Magisk version : $MAGISK_VERSION"
echo "  BusyBox version: $BUSYBOX_VERSION"
echo "=============================================="

# ── pre-flight checks ─────────────────────────────────────────
step "Checking required host tools..."
if [ "${HOM_DEPS_CHECKED:-}" != "1" ]; then
    source "$REPO_ROOT/check_deps.sh" || exit 1
else
    ok "Dependencies already verified"
fi

# ── ensure directories exist ──────────────────────────────────
mkdir -p "$TOOLS_DIR" "$DIST_DIR"

# ── 1. Ensure the repo is complete (in case of shallow clone) ─
step "1/5  Ensuring complete git history..."
if git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
    echo "  Shallow clone detected — unshallowing..."
    git -C "$REPO_ROOT" fetch --unshallow origin
    ok "Unshallowed"
else
    ok "Full clone (or already complete)"
fi

# ── 2. Fetch optional binaries ────────────────────────────────
if [ "$SKIP_BINARIES" = true ]; then
    warn "Skipping binary downloads (--skip-binaries)"
else
    step "2/5  Fetching busybox-arm64 (static, ARM64)..."
    BUSYBOX_URL="https://busybox.net/downloads/binaries/${BUSYBOX_VERSION}-defconfig-multiarch-musl/busybox-armv8l"
    BUSYBOX_DEST="$TOOLS_DIR/busybox-arm64"
    if [ -f "$BUSYBOX_DEST" ]; then
        ok "Already present: $BUSYBOX_DEST (delete to re-download)"
    else
        download "$BUSYBOX_URL" "$BUSYBOX_DEST"
        chmod +x "$BUSYBOX_DEST"
        # Basic sanity: file must be an ELF
        if command -v file >/dev/null 2>&1; then
            file_out=$(file "$BUSYBOX_DEST" 2>/dev/null || true)
            if echo "$file_out" | grep -qi "ELF"; then
                ok "Verified: ELF binary"
            else
                warn "Binary may not be a valid ELF — check: $BUSYBOX_DEST"
            fi
        fi
    fi

    step "2/5  Fetching Magisk ${MAGISK_VERSION} binaries..."
    MAGISK_APK_URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VERSION}/Magisk-${MAGISK_VERSION}.apk"
    MAGISK_APK="$_TMP/hands-on-metal-magisk-${MAGISK_VERSION}.apk"

    all_magisk_present=true
    for t in magisk64 magisk32 magiskinit64 magiskboot boot_patch.sh; do
        [ -f "$TOOLS_DIR/$t" ] || { all_magisk_present=false; break; }
    done

    if [ "$all_magisk_present" = true ]; then
        ok "All Magisk binaries already present (delete to re-download)"
    else
        if [ ! -f "$MAGISK_APK" ]; then
            download "$MAGISK_APK_URL" "$MAGISK_APK"
        else
            ok "Magisk APK already cached at $MAGISK_APK"
        fi

        echo "  Extracting binaries from APK..."
        # Magisk v26+ renamed libmagisk64.so / libmagisk32.so to
        # libmagisk.so under each ABI directory.  We try the v26+
        # path first, then fall back to the pre-v26 name so that
        # both old and new APK layouts are supported.

        extract_magisk_binary "$MAGISK_APK" "$TOOLS_DIR/magisk64" \
            'lib/arm64-v8a/libmagisk.so' \
            'lib/arm64-v8a/libmagisk64.so'

        extract_magisk_binary "$MAGISK_APK" "$TOOLS_DIR/magisk32" \
            'lib/armeabi-v7a/libmagisk.so' \
            'lib/armeabi-v7a/libmagisk32.so'

        extract_magisk_binary "$MAGISK_APK" "$TOOLS_DIR/magiskinit64" \
            'lib/arm64-v8a/libmagiskinit.so'

        # magiskboot — low-level boot image tool; required by boot_patch.sh.
        # Magisk v26+ removed --boot-patch from the main binary; boot patching
        # is now done via boot_patch.sh + magiskboot (works without root).
        extract_magisk_binary "$MAGISK_APK" "$TOOLS_DIR/magiskboot" \
            'lib/arm64-v8a/libmagiskboot.so'

        # boot_patch.sh + util_functions.sh — the actual patching scripts.
        if unzip -jo "$MAGISK_APK" 'assets/boot_patch.sh' -d "$TOOLS_DIR/" >/dev/null 2>&1; then
            chmod +x "$TOOLS_DIR/boot_patch.sh"
        else
            warn "boot_patch.sh not found in APK assets — boot patching may fall back to magisk --boot-patch"
        fi
        unzip -jo "$MAGISK_APK" 'assets/util_functions.sh' -d "$TOOLS_DIR/" >/dev/null 2>&1 || true

        ok "magisk64, magisk32, magiskinit64, magiskboot, boot_patch.sh → $TOOLS_DIR/"

        # Print expected ARM64 hint (file may not be available on all hosts)
        if command -v file >/dev/null 2>&1; then
            if file "$TOOLS_DIR/magisk64" 2>/dev/null | grep -qi "ELF"; then
                ok "magisk64 verified: ELF binary"
            else
                warn "magisk64: could not verify ELF type (may be ARM64 on x86 host)"
            fi
        fi
    fi
fi

# ── 3. Build the two flashable ZIPs ──────────────────────────
step "3/5  Building flashable ZIPs..."
bash "$BUILD_DIR/build_offline_zip.sh" --version "$MODULE_VERSION"

MAGISK_ZIP="$DIST_DIR/hands-on-metal-magisk-module-${MODULE_VERSION}.zip"
RECOVERY_ZIP="$DIST_DIR/hands-on-metal-recovery-${MODULE_VERSION}.zip"

for z in "$MAGISK_ZIP" "$RECOVERY_ZIP"; do
    if [ -f "$z" ]; then
        ok "$(basename "$z")  ($(du -sh "$z" | cut -f1))"
    else
        fail "Expected ZIP not found: $z"
        exit 1
    fi
done

# ── 4. Create the full bundle ZIP ────────────────────────────
step "4/5  Creating full offline bundle ZIP..."

BUNDLE="$DIST_DIR/hands-on-metal-full-bundle-${MODULE_VERSION}.zip"
BUNDLE_STAGE="$(mktemp -d)"
trap 'rm -rf "$BUNDLE_STAGE"' EXIT

# a) Complete repo snapshot (exclude .git, dist, __pycache__)
echo "  Snapshotting repo..."
git -C "$REPO_ROOT" archive --format=tar HEAD | tar -x -C "$BUNDLE_STAGE"
ok "Repo snapshot added"

# b) Overwrite tools/ with the actually-fetched binaries
rm -rf "$BUNDLE_STAGE/tools"
mkdir -p "$BUNDLE_STAGE/tools"
for t in busybox-arm64 magisk64 magisk32 magiskinit64 magiskboot boot_patch.sh util_functions.sh; do
    if [ -f "$TOOLS_DIR/$t" ]; then
        cp "$TOOLS_DIR/$t" "$BUNDLE_STAGE/tools/$t"
        ok "Bundled tool: $t"
    else
        warn "Optional tool not present, skipped: $t"
    fi
done

# c) Both flashable ZIPs
mkdir -p "$BUNDLE_STAGE/dist"
cp "$MAGISK_ZIP"   "$BUNDLE_STAGE/dist/"
cp "$RECOVERY_ZIP" "$BUNDLE_STAGE/dist/"
ok "Flashable ZIPs added to dist/"

# d) Per-bundle checksums
CHECKSUM_FILE="$BUNDLE_STAGE/dist/checksums-${MODULE_VERSION}.sha256"
(
    cd "$DIST_DIR"
    $SHA256 \
        "hands-on-metal-magisk-module-${MODULE_VERSION}.zip" \
        "hands-on-metal-recovery-${MODULE_VERSION}.zip" \
) > "$CHECKSUM_FILE"

# Also checksum every tool binary included
(
    cd "$BUNDLE_STAGE/tools"
    for t in busybox-arm64 magisk64 magisk32 magiskinit64 magiskboot boot_patch.sh util_functions.sh; do
        [ -f "$t" ] && $SHA256 "$t"
    done
) >> "$CHECKSUM_FILE" 2>/dev/null || true

ok "Checksums written: $(basename "$CHECKSUM_FILE")"

# e) Pack the full bundle
echo "  Packing bundle ZIP..."
(cd "$BUNDLE_STAGE" && zip -r9 "$BUNDLE" . >/dev/null)
ok "Full bundle: $(basename "$BUNDLE")  ($(du -sh "$BUNDLE" | cut -f1))"

# ── 5. Final checksums file for dist/ ────────────────────────
step "5/5  Writing dist/ checksums..."
DIST_CHECKSUM="$DIST_DIR/checksums-${MODULE_VERSION}.sha256"
(
    cd "$DIST_DIR"
    files=()
    for f in \
        "hands-on-metal-magisk-module-${MODULE_VERSION}.zip" \
        "hands-on-metal-recovery-${MODULE_VERSION}.zip" \
        "hands-on-metal-full-bundle-${MODULE_VERSION}.zip"; do
        [ -f "$f" ] && files+=("$f")
    done
    $SHA256 "${files[@]}"
) > "$DIST_CHECKSUM"
ok "$(basename "$DIST_CHECKSUM")"

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  Done — all outputs in dist/"
echo "=============================================="
echo ""
echo "  Magisk module ZIP  : hands-on-metal-magisk-module-${MODULE_VERSION}.zip"
echo "    Flash via: Magisk app → Modules → Install from storage"
echo ""
echo "  Recovery ZIP       : hands-on-metal-recovery-${MODULE_VERSION}.zip"
echo "    Flash via: TWRP/OrangeFox → Install → select ZIP"
echo ""
echo "  Full offline bundle: hands-on-metal-full-bundle-${MODULE_VERSION}.zip"
echo "    Contains: complete repo snapshot, all tools, both ZIPs, checksums"
echo "    Copy this single file to any machine to work fully offline."
echo ""
echo "  Checksums          : checksums-${MODULE_VERSION}.sha256"
echo ""

if [ "$SKIP_BINARIES" = true ]; then
    warn "Binaries were NOT fetched (--skip-binaries). The ZIPs will rely on"
    warn "whatever Magisk/busybox is already installed on the target device."
    echo ""
fi
