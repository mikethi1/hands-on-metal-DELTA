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
_hom_require git       "Cloning the repo and running fetch_all_deps.sh"
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
_hom_optional adb      "Pushing ZIPs to device / pulling logs (Android Platform Tools)"
_hom_optional file     "Verifying ELF binary types after download"
_hom_optional nm       "Analysing vendor library symbols (parse_symbols.py)"
_hom_optional readelf  "Analysing ELF dynamic sections (parse_symbols.py)"
_hom_optional c++filt  "Demangling C++ symbol names (parse_symbols.py)"
_hom_optional openssl  "Fallback SHA-256 hashing on device (core scripts)"

echo ""

if [ "$_hom_dep_ok" = false ]; then
    echo "ERROR: One or more required tools are missing. Install them and try again." >&2
    echo ""
    unset _hom_dep_ok _hom_require _hom_optional _hom_env_type
    return 1 2>/dev/null || exit 1
fi

echo "  ✓  All required dependencies found"
echo ""

# ── native Android terminal guidance ─────────────────────────
if [ "$_hom_env_type" = "android" ]; then
    echo "  ℹ  Running in native Android shell."
    echo "     Some build tools (git, python3, curl, zip, unzip, tar)"
    echo "     may not be available. Install Termux or use the"
    echo "     Android 15+ built-in Terminal for full functionality."
    echo ""
fi

export HOM_DEPS_CHECKED=1

unset _hom_dep_ok _hom_require _hom_optional _hom_env_type
