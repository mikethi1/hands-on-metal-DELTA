#!/usr/bin/env bash
# check_deps.sh
# ============================================================
# hands-on-metal — Host-Side Dependency Checker
#
# Verifies that all required (and optional) host-side tools are
# installed before running build scripts or the pipeline.
#
# Usage:
#   bash check_deps.sh            # run standalone
#   source check_deps.sh          # source from another script
#
# When sourced, sets HOM_DEPS_CHECKED=1 on success so that
# downstream scripts can skip redundant checks.
#
# Exit / return codes:
#   0 — all required dependencies found
#   1 — one or more required dependencies missing
# ============================================================

# Skip if already checked in this session (e.g. menu already ran it)
if [ "${HOM_DEPS_CHECKED:-}" = "1" ]; then
    # shellcheck disable=SC2317  # exit is reachable when this script is executed (not sourced)
    return 0 2>/dev/null || exit 0
fi

_hom_dep_ok=true

_hom_require() {
    local cmd="$1" desc="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  ✗  MISSING (required): $cmd — $desc" >&2
        _hom_dep_ok=false
    fi
}

_hom_optional() {
    local cmd="$1" desc="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  ⚠  missing (optional): $cmd — $desc"
    fi
}

echo ""
echo "Checking host-side dependencies..."
echo ""

# ── Detect execution environment ──────────────────────────────
_hom_env_type="unknown"
if [ -d "/data/data/com.termux/files/usr" ] || [ -n "${TERMUX_VERSION:-}" ]; then
    _hom_env_type="termux"
elif [ -n "$(getprop ro.build.display.id 2>/dev/null)" ]; then
    _hom_env_type="android"
else
    _hom_env_type="host"
fi

if [ "$_hom_env_type" != "unknown" ]; then
    echo "  ℹ  Environment: $_hom_env_type"
    echo ""
fi

# ── Required tools ────────────────────────────────────────────
_hom_require zip       "Building flashable ZIPs (build_offline_zip.sh, fetch_all_deps.sh)"
_hom_require unzip     "Extracting Magisk APK (fetch_all_deps.sh)"
_hom_require curl      "Downloading Magisk APK and busybox binary (fetch_all_deps.sh)"
_hom_require python3   "Pipeline scripts and Termux bootstrap"
_hom_require tar       "Bundle creation via git archive (fetch_all_deps.sh)"

# sha256sum OR shasum — at least one is required.
# On macOS shasum is used with the -a 256 flag (shasum -a 256).
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "  ✗  MISSING (required): sha256sum or shasum -a 256 — Checksum verification" >&2
    _hom_dep_ok=false
fi

# ── Optional tools ────────────────────────────────────────────
# Host-side tools (PC / Termux)
_hom_optional git      "Cloning the repo and bundle creation via git archive (fetch_all_deps.sh)"
_hom_optional adb      "Pushing ZIPs to device / pulling logs / Mode C host-assisted flash (Android Platform Tools)"
_hom_optional fastboot "Mode C host-assisted flash: fastboot boot / fastboot flash (Android Platform Tools)"
_hom_optional file     "Verifying ELF binary types after download"
_hom_optional nm       "Analysing vendor library symbols (parse_symbols.py)"
_hom_optional readelf  "Analysing ELF dynamic sections (parse_symbols.py)"
_hom_optional c++filt  "Demangling C++ symbol names (parse_symbols.py)"
_hom_optional openssl  "Fallback SHA-256 hashing on device (core scripts)"
_hom_optional lz4     "Decompressing LZ4-compressed TWRP Nandroid backups (core/boot_image.sh)"
_hom_optional gzip    "Decompressing gzip-compressed TWRP Nandroid backups (core/boot_image.sh)"

echo ""

# ── Auto-fetch Magisk from topjohnwu/Magisk GitHub releases ───
# Skipped on-device (Termux/Android — Magisk is installed there)
# and when the user opts out via HOM_SKIP_MAGISK_DOWNLOAD=1.
# Requires curl + unzip (already required above); fails soft so a
# missing network does not block the rest of the dep check.
_hom_fetch_magisk() {
    [ "${HOM_SKIP_MAGISK_DOWNLOAD:-}" = "1" ] && return 0
    [ "$_hom_env_type" = "termux" ] || [ "$_hom_env_type" = "android" ] && return 0
    command -v curl  >/dev/null 2>&1 || return 0
    command -v unzip >/dev/null 2>&1 || return 0

    local repo_root tools_dir
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    tools_dir="$repo_root/tools"

    # Already fetched? Nothing to do.
    if [ -f "$tools_dir/magisk64" ] && [ -f "$tools_dir/magisk32" ] \
            && [ -f "$tools_dir/magiskinit64" ] \
            && [ -f "$tools_dir/magiskboot" ] && [ -f "$tools_dir/boot_patch.sh" ]; then
        echo "  ✓  Magisk binaries already present in tools/"
        return 0
    fi

    local version="${HOM_MAGISK_VERSION:-v30.7}"
    local url="https://github.com/topjohnwu/Magisk/releases/download/${version}/Magisk-${version}.apk"
    local tmp="${TMPDIR:-${HOME:-.}/tmp}"
    local apk="$tmp/hands-on-metal-magisk-${version}.apk"

    mkdir -p "$tools_dir" "$tmp"

    if [ ! -f "$apk" ]; then
        echo "  ↓  Downloading Magisk ${version} from topjohnwu/Magisk..."
        if ! curl -fsSL --retry 3 --retry-delay 2 -o "$apk" "$url"; then
            echo "  ⚠  Could not download Magisk (offline / blocked / bad version)." >&2
            echo "     URL: $url" >&2
            echo "     Re-run with HOM_SKIP_MAGISK_DOWNLOAD=1 to silence." >&2
            rm -f "$apk"
            return 0
        fi
    else
        echo "  ✓  Magisk APK cached at $apk"
    fi

    # Extract magisk64 / magisk32 / magiskinit64 / magiskboot from the APK.
    # Magisk v26+ renamed libmagisk{64,32}.so → libmagisk.so under each ABI;
    # try the new path first, then fall back to the old one.
    # Magisk v26+ removed --boot-patch from the main binary; boot patching
    # requires magiskboot + boot_patch.sh (works without root).
    _hom_extract_magisk() {
        local dest="$1"; shift
        local p
        for p in "$@"; do
            if unzip -jo "$apk" "$p" -d "$tmp/" >/dev/null 2>&1; then
                local base
                base="$(basename "$p")"
                cp "$tmp/$base" "$dest" && chmod +x "$dest"
                rm -f "$tmp/$base"
                return 0
            fi
        done
        return 1
    }

    local extract_ok=true
    _hom_extract_magisk "$tools_dir/magisk64" \
        'lib/arm64-v8a/libmagisk.so' \
        'lib/arm64-v8a/libmagisk64.so' || extract_ok=false
    _hom_extract_magisk "$tools_dir/magisk32" \
        'lib/armeabi-v7a/libmagisk.so' \
        'lib/armeabi-v7a/libmagisk32.so' || extract_ok=false
    _hom_extract_magisk "$tools_dir/magiskinit64" \
        'lib/arm64-v8a/libmagiskinit.so' || extract_ok=false
    _hom_extract_magisk "$tools_dir/magiskboot" \
        'lib/arm64-v8a/libmagiskboot.so' || extract_ok=false

    # boot_patch.sh + util_functions.sh — the actual patching scripts
    if unzip -jo "$apk" 'assets/boot_patch.sh' -d "$tools_dir/" >/dev/null 2>&1; then
        chmod +x "$tools_dir/boot_patch.sh"
    else
        echo "  ⚠  boot_patch.sh not found in APK assets." >&2
        extract_ok=false
    fi
    unzip -jo "$apk" 'assets/util_functions.sh' -d "$tools_dir/" >/dev/null 2>&1 || true

    unset -f _hom_extract_magisk

    if [ "$extract_ok" = true ]; then
        echo "  ✓  Magisk binaries extracted to tools/ (magisk64, magisk32, magiskinit64, magiskboot, boot_patch.sh)"
    else
        echo "  ⚠  Magisk APK downloaded but extraction failed (unexpected APK layout)." >&2
    fi
}

_hom_fetch_magisk
unset -f _hom_fetch_magisk

echo ""

# ── On-TARGET apps (detected at runtime, guidance only) ──────
echo "  On-TARGET optional apps (install on the Android device being flashed):"
echo ""
echo "    Shizuku — Elevated ADB shell-level access without root (Android 11+)"
echo "              https://shizuku.rikka.app/"
echo "              Enables: better /proc, /sys reads, full logcat, pm/am commands"
echo "              Install: Google Play (moe.shizuku.privileged.api) or GitHub releases"
echo ""
echo "    LADB    — On-device ADB shell terminal with elevated privileges"
echo "              https://github.com/tytydraco/LADB"
echo "              Enables: local ADB shell without PC connection"
echo "              Install: Google Play (com.draco.ladb) or GitHub releases"
echo ""
echo "    Termux  — Linux terminal emulator for Android (for device-to-device flashing)"
echo "              https://f-droid.org/packages/com.termux/"
echo "              Provides: adb, fastboot, python3, and other build tools on-device"
echo "              Install: F-Droid (recommended) or GitHub releases"
echo "              Deps in Termux: pkg install android-tools python"
echo ""

if [ "$_hom_dep_ok" = false ]; then
    echo "ERROR: One or more required tools are missing. Install them and try again." >&2
    echo ""
    unset _hom_dep_ok _hom_require _hom_optional _hom_env_type
    # shellcheck disable=SC2317  # exit is reachable when this script is executed (not sourced)
    return 1 2>/dev/null || exit 1
fi

echo "  ✓  All required dependencies found"
echo ""

# ── native Android terminal guidance ─────────────────────────
if [ "$_hom_env_type" = "android" ]; then
    echo "  ℹ  Running in native Android shell (not Termux)."
    echo "     If build tools are missing, install Termux from F-Droid"
    echo "     or use adb shell from a host machine with all tools."
    echo ""
fi

export HOM_DEPS_CHECKED=1

unset _hom_dep_ok _hom_require _hom_optional _hom_env_type
