#!/system/bin/sh
# magisk-module/env_detect.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Hands-on-metal — Environment Detection
# Runs early in service.sh before collect.sh.
# Probes the shell environment, available tools, Python builds,
# and Termux state, then writes every discovered fact into the
# flat env registry at $ENV_REGISTRY so the rest of the
# pipeline can source it without a database dependency.
#
# All writes go to $OUT/env_registry.sh (~/hands-on-metal/env_registry.sh) —
# a sourceable key=value file.  The pipeline ingests this into
# the env_var SQLite table later.
#
# Safety guarantees (same as collect.sh):
#   • Never writes outside $OUT/
#   • Never modifies any system partition
# ============================================================

set -u

OUT="${HOME:-/data/local/tmp}/hands-on-metal"
ENV_REGISTRY="$OUT/env_registry.sh"
LOG="$OUT/env_detect.log"

# ── helpers ──────────────────────────────────────────────────

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

# Write (or update) one variable in the registry.
# Usage: reg_set CATEGORY KEY VALUE
reg_set() {
    local cat="$1" key="$2" val="$3"
    # Remove any existing definition for this key, then append.
    # sed -i is not guaranteed portable on all Android /system/bin/sh
    # implementations, so we rebuild the file via a tmp copy.
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

# Resolve a path to its real absolute path (no symlinks).
real_abs() {
    local p="$1"
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$p" 2>/dev/null || echo "$p"
    else
        echo "$p"
    fi
}

# Record both the nominal value and its real absolute path.
reg_set_path() {
    local cat="$1" key="$2" val="$3"
    reg_set "$cat" "$key" "$val"
    local rp
    rp=$(real_abs "$val")
    [ "$rp" != "$val" ] && reg_set "$cat" "${key}_REALPATH" "$rp"
}

# ── init ─────────────────────────────────────────────────────

mkdir -p "$OUT"
: > "$ENV_REGISTRY"    # truncate; we rebuild from scratch each detect run
log "=== env_detect.sh start ==="

# ── 1. Shell identity ────────────────────────────────────────

log "Detecting shell environment..."

SHELL_PATH=$(real_abs "$(command -v sh 2>/dev/null || echo /system/bin/sh)")
reg_set_path shell HOM_SHELL_PATH "$SHELL_PATH"

# Detect if this is bash or mksh or ash/busybox sh
SHELL_BANNER=$(sh --version 2>&1 | head -1 || true)
reg_set shell HOM_SHELL_BANNER "$SHELL_BANNER"

# Magisk's own shell path
MAGISK_SHELL=$(real_abs "$(command -v magisk 2>/dev/null || true)")
reg_set_path shell HOM_MAGISK_BIN "$MAGISK_SHELL"

# busybox availability
BB=""
for try in /system/bin/busybox /sbin/busybox /data/adb/magisk/busybox; do
    [ -x "$try" ] && { BB=$(real_abs "$try"); break; }
done
reg_set_path shell HOM_BUSYBOX "$BB"

# ── 2. Core tool availability ─────────────────────────────────

log "Probing core tools..."

for tool in awk sed grep find sort uniq head tail cut tr wc \
            dd cp mv rm mkdir chmod chown ln readlink \
            readelf nm lshal getprop setprop \
            dmsetup blkid mount umount; do
    p=$(command -v "$tool" 2>/dev/null || true)
    if [ -n "$p" ]; then
        reg_set_path shell "HOM_TOOL_$(echo "$tool" | tr 'a-z-' 'A-Z_')" "$p"
    else
        reg_set shell "HOM_TOOL_$(echo "$tool" | tr 'a-z-' 'A-Z_')" "MISSING"
    fi
done

# ── 3. Python detection ───────────────────────────────────────

log "Detecting Python installations..."

PY_FOUND=0
for py_cmd in python3 python python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
    p=$(command -v "$py_cmd" 2>/dev/null || true)
    [ -z "$p" ] && continue
    rp=$(real_abs "$p")
    ver=$("$p" --version 2>&1 | awk '{print $2}')
    key="HOM_PYTHON_$(echo "$py_cmd" | tr '.' '_' | tr '[:lower:]' '[:upper:]')"
    reg_set_path python "$key" "$rp"
    reg_set python "${key}_VERSION" "$ver"
    PY_FOUND=$((PY_FOUND + 1))
    # Record the first/best Python as the canonical one
    if [ "$PY_FOUND" -eq 1 ]; then
        reg_set_path python HOM_PYTHON_CANONICAL "$rp"
        reg_set python HOM_PYTHON_VERSION "$ver"
    fi
done
reg_set python HOM_PYTHON_COUNT "$PY_FOUND"

# Site-packages locations for found Pythons
CANONICAL=$(grep "^HOM_PYTHON_CANONICAL=" "$ENV_REGISTRY" | \
            cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//' || true)
if [ -n "$CANONICAL" ] && [ -x "$CANONICAL" ]; then
    SITE=$("$CANONICAL" -c "import site; print(' '.join(site.getsitepackages()))" 2>/dev/null || true)
    reg_set python HOM_PYTHON_SITE_PACKAGES "$SITE"
fi

# ── 3b. Python version adequacy ──────────────────────────────
# Pipeline scripts require Python 3.7+ (from __future__ import
# annotations), and the project documents Python 3.8+ as the
# minimum.  Record whether the canonical Python meets the bar.

if [ -n "$CANONICAL" ] && [ -x "$CANONICAL" ]; then
    PY_MAJOR=$("$CANONICAL" -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo 0)
    PY_MINOR=$("$CANONICAL" -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo 0)
    reg_set python HOM_PYTHON_MAJOR "$PY_MAJOR"
    reg_set python HOM_PYTHON_MINOR "$PY_MINOR"
    if [ "$PY_MAJOR" -gt 3 ] 2>/dev/null || \
       { [ "$PY_MAJOR" -eq 3 ] 2>/dev/null && [ "$PY_MINOR" -ge 8 ] 2>/dev/null; }; then
        reg_set python HOM_PYTHON_ADEQUATE "true"
    else
        reg_set python HOM_PYTHON_ADEQUATE "false"
        log "WARNING: Python $PY_MAJOR.$PY_MINOR found but 3.8+ is required for pipeline scripts"
    fi
else
    reg_set python HOM_PYTHON_ADEQUATE "false"
fi

# ── 3c. Python stdlib module validation ──────────────────────
# Verify that all stdlib modules required by the pipeline
# scripts are importable.  This catches stripped/minimal Python
# installs (common in Termux or embedded builds).

log "Validating Python stdlib modules..."

PY_STDLIB_OK=true
if [ -n "$CANONICAL" ] && [ -x "$CANONICAL" ]; then
    for mod in sqlite3 gzip lzma bz2 json argparse re pathlib struct io \
               hashlib math glob tempfile unittest subprocess; do
        if "$CANONICAL" -c "import $mod" 2>/dev/null; then
            reg_set python "HOM_PYMOD_$(echo "$mod" | tr '[:lower:]' '[:upper:]')" "ok"
        else
            reg_set python "HOM_PYMOD_$(echo "$mod" | tr '[:lower:]' '[:upper:]')" "MISSING"
            PY_STDLIB_OK=false
            log "WARNING: Python stdlib module '$mod' cannot be imported"
        fi
    done
    # xml.etree.ElementTree (used by parse_manifests.py)
    if "$CANONICAL" -c "from xml.etree import ElementTree" 2>/dev/null; then
        reg_set python HOM_PYMOD_XML_ETREE "ok"
    else
        reg_set python HOM_PYMOD_XML_ETREE "MISSING"
        PY_STDLIB_OK=false
        log "WARNING: Python stdlib module 'xml.etree.ElementTree' cannot be imported"
    fi
fi
reg_set python HOM_PYTHON_STDLIB_OK "$PY_STDLIB_OK"

# ── 3d. Python optional dependency detection ──────────────────
# unpack_images.py can use lz4 and zstandard for additional
# compression formats.  These are NOT required but improve
# coverage for boot images that use non-standard compressors.

log "Detecting optional Python packages..."

if [ -n "$CANONICAL" ] && [ -x "$CANONICAL" ]; then
    for opt in lz4 zstandard; do
        if "$CANONICAL" -c "import $opt" 2>/dev/null; then
            optver=$("$CANONICAL" -c "import $opt; print(getattr($opt, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
            reg_set python "HOM_PYOPT_$(echo "$opt" | tr '[:lower:]' '[:upper:]')" "$optver"
        else
            reg_set python "HOM_PYOPT_$(echo "$opt" | tr '[:lower:]' '[:upper:]')" "not_installed"
        fi
    done
fi

# ── 4. pip / package managers ─────────────────────────────────

log "Detecting pip and package managers..."

for pm in pip3 pip pip3.12 pip3.11; do
    p=$(command -v "$pm" 2>/dev/null || true)
    [ -z "$p" ] && continue
    rp=$(real_abs "$p")
    key="HOM_PIP_$(echo "$pm" | tr '.' '_' | tr '[:lower:]' '[:upper:]')"
    reg_set_path python "$key" "$rp"
done

# ── 4b. Pipeline external tool detection ──────────────────────
# parse_symbols.py calls c++filt via subprocess for C++ symbol
# demangling.  Record its availability.

log "Detecting pipeline external tools..."

for ptool in c++filt nm readelf file; do
    p=$(command -v "$ptool" 2>/dev/null || true)
    key="HOM_PIPELINE_$(echo "$ptool" | tr 'a-z+' 'A-Z_' | tr '-' '_')"
    if [ -n "$p" ]; then
        reg_set_path pipeline "$key" "$p"
    else
        reg_set pipeline "$key" "not_found"
    fi
done

# ── 5. Termux detection ───────────────────────────────────────

log "Detecting Termux..."

TERMUX_PREFIX_CANDIDATES="/data/data/com.termux/files/usr /data/user/0/com.termux/files/usr"
TERMUX_PREFIX=""
for cand in $TERMUX_PREFIX_CANDIDATES; do
    [ -d "$cand" ] && { TERMUX_PREFIX=$(real_abs "$cand"); break; }
done

if [ -n "$TERMUX_PREFIX" ]; then
    reg_set_path termux HOM_TERMUX_PREFIX "$TERMUX_PREFIX"
    reg_set termux HOM_TERMUX_INSTALLED "true"

    # Termux HOME
    TERMUX_HOME=$(dirname "$(dirname "$TERMUX_PREFIX")")/home
    [ -d "$TERMUX_HOME" ] && reg_set_path termux HOM_TERMUX_HOME "$TERMUX_HOME"

    # Termux shell
    TERMUX_SHELL="$TERMUX_PREFIX/bin/bash"
    [ -x "$TERMUX_SHELL" ] || TERMUX_SHELL="$TERMUX_PREFIX/bin/sh"
    [ -x "$TERMUX_SHELL" ] && reg_set_path termux HOM_TERMUX_SHELL "$TERMUX_SHELL"

    # Termux Python
    for tpy in "$TERMUX_PREFIX/bin/python3" "$TERMUX_PREFIX/bin/python"; do
        if [ -x "$tpy" ]; then
            tver=$("$tpy" --version 2>&1 | awk '{print $2}')
            reg_set_path termux HOM_TERMUX_PYTHON "$tpy"
            reg_set termux HOM_TERMUX_PYTHON_VERSION "$tver"
            break
        fi
    done

    # pkg command
    PKG_CMD="$TERMUX_PREFIX/bin/pkg"
    [ -x "$PKG_CMD" ] && reg_set_path termux HOM_TERMUX_PKG "$PKG_CMD"

    # apt command
    APT_CMD="$TERMUX_PREFIX/bin/apt"
    [ -x "$APT_CMD" ] && reg_set_path termux HOM_TERMUX_APT "$APT_CMD"
else
    reg_set termux HOM_TERMUX_INSTALLED "false"
fi

# ── 5b. Native Android terminal detection ─────────────────────
# Android 15+ includes a built-in Terminal app that runs a
# lightweight Debian VM.  Detect this and other non-Termux
# Android shell environments (adb shell, AOSP terminal).
#
# Environment types:
#   termux             — Termux app (detected above)
#   android_terminal   — Android 15+ built-in Terminal (AVF VM)
#   adb_shell          — adb shell / local shell over adbd
#   android_native     — other native Android shell (mksh)
#   linux_host         — Linux/macOS/CI host (not Android)
#   unknown            — could not determine

log "Detecting shell environment type..."

HOM_ENV_TYPE="unknown"

if [ -n "$TERMUX_PREFIX" ]; then
    HOM_ENV_TYPE="termux"
elif [ -n "$(getprop ro.build.display.id 2>/dev/null)" ]; then
    # We are on Android (getprop is present and returns build info)
    # Distinguish between Android 15 Terminal VM and native shell
    if [ -d /apex/com.android.virt ] || \
       grep -q "com.android.virtualization" /proc/cmdline 2>/dev/null || \
       [ -n "${ANDROID_TERMINAL_APP:-}" ]; then
        HOM_ENV_TYPE="android_terminal"
    elif [ -n "${ADB_VENDOR_KEYS:-}" ] || \
         grep -qz "adbd" /proc/$PPID/cmdline 2>/dev/null; then
        HOM_ENV_TYPE="adb_shell"
    else
        HOM_ENV_TYPE="android_native"
    fi
else
    HOM_ENV_TYPE="linux_host"
fi

reg_set shell HOM_ENV_TYPE "$HOM_ENV_TYPE"

# Record whether key host-side build tools are available
# (these are needed by fetch_all_deps.sh / build_offline_zip.sh
# but are NOT expected in recovery or Magisk service context)
for build_tool in zip unzip curl git tar python3 bash; do
    p=$(command -v "$build_tool" 2>/dev/null || true)
    key="HOM_BUILD_TOOL_$(echo "$build_tool" | tr '[:lower:]' '[:upper:]')"
    if [ -n "$p" ]; then
        reg_set shell "$key" "$p"
    else
        reg_set shell "$key" "MISSING"
    fi
done

# Decide whether Termux SHOULD be installed by setup_termux.sh.
# Criteria: no system Python found AND no Termux prefix AND we have
# network access (checked later in setup_termux.sh).
if [ "$PY_FOUND" -eq 0 ] && [ -z "$TERMUX_PREFIX" ]; then
    reg_set termux HOM_TERMUX_SHOULD_INSTALL "true"
else
    reg_set termux HOM_TERMUX_SHOULD_INSTALL "false"
fi

# ── 6. Permissions / SELinux / execution context ─────────────

log "Detecting permissions, SELinux, and execution context..."

reg_set shell HOM_WHOAMI "$(id 2>/dev/null || echo unknown)"
reg_set shell HOM_SELINUX_CONTEXT "$(tr -d '\0' < /proc/self/attr/current 2>/dev/null || echo unknown)"
reg_set shell HOM_SELINUX_ENFORCE "$(cat /sys/fs/selinux/enforce 2>/dev/null || echo unknown)"

# ── 6b. Execution node detection ─────────────────────────────
# Determine what privilege level / context we are running in:
#   root_magisk    — uid 0 via Magisk su or service.sh
#   root_recovery  — uid 0 in TWRP/OrangeFox recovery
#   root_other     — uid 0 from unknown source
#   unprivileged   — not root

log "Detecting execution node..."

EXEC_UID=$(id -u 2>/dev/null || echo 9999)
EXEC_NODE="unprivileged"

if [ "$EXEC_UID" = "0" ]; then
    if [ -d /data/adb/magisk ]; then
        EXEC_NODE="root_magisk"
    elif [ -d /tmp/recovery ] || [ -n "${TWRP:-}" ] || [ -f /sbin/recovery ]; then
        EXEC_NODE="root_recovery"
    else
        EXEC_NODE="root_other"
    fi
fi

reg_set shell HOM_EXEC_UID  "$EXEC_UID"
reg_set shell HOM_EXEC_NODE "$EXEC_NODE"

# Magisk version (if available)
if command -v magisk >/dev/null 2>&1; then
    _mg_ver=$(magisk -v 2>/dev/null | head -1 || echo "unknown")
    _mg_code=$(magisk -V 2>/dev/null | head -1 || echo "0")
    reg_set shell HOM_MAGISK_VERSION "$_mg_ver"
    reg_set shell HOM_MAGISK_VER_CODE "$_mg_code"
fi

# ── 6c. Folder permissions audit ─────────────────────────────
# Verify write access to the directories the workflow uses.
# Record per-directory status so downstream scripts can adapt.

log "Auditing folder permissions..."

for dir_path in "$OUT" /data/adb /data/local/tmp; do
    dir_key="HOM_PERM_$(echo "$dir_path" | sed 's|/|_|g' | sed 's|^_||' | tr 'a-z-' 'A-Z_')"
    if [ -d "$dir_path" ]; then
        # Check read access
        if [ -r "$dir_path" ]; then
            dir_read="true"
        else
            dir_read="false"
        fi
        # Check write access with a temporary file probe
        _test_file="$dir_path/.hom_perm_test_$$"
        if touch "$_test_file" 2>/dev/null; then
            rm -f "$_test_file"
            dir_write="true"
        else
            dir_write="false"
        fi
        reg_set perm "${dir_key}_EXISTS"   "true"
        reg_set perm "${dir_key}_READABLE" "$dir_read"
        reg_set perm "${dir_key}_WRITABLE" "$dir_write"
    else
        # Try to create the directory (needed for first run)
        if mkdir -p "$dir_path" 2>/dev/null; then
            reg_set perm "${dir_key}_EXISTS"   "true"
            reg_set perm "${dir_key}_READABLE" "true"
            reg_set perm "${dir_key}_WRITABLE" "true"
        else
            reg_set perm "${dir_key}_EXISTS"   "false"
            reg_set perm "${dir_key}_READABLE" "false"
            reg_set perm "${dir_key}_WRITABLE" "false"
        fi
    fi
done

# Output directory must be writable — warn loudly if not
_out_test="$OUT/.hom_perm_check_$$"
if ! (mkdir -p "$OUT" && touch "$_out_test") 2>/dev/null; then
    log "ERROR: $OUT is NOT writable — workflow cannot proceed"
else
    rm -f "$_out_test"
fi
unset _out_test

# ── 7. Key filesystem paths ───────────────────────────────────

log "Resolving key filesystem paths..."

for dir in /system /vendor /odm /product /data /sdcard \
           /dev/block /dev/block/bootdevice \
           /data/adb/magisk /data/adb/modules; do
    [ -e "$dir" ] || continue
    key="HOM_PATH_$(echo "$dir" | sed 's|/|_|g' | sed 's|^_||' | tr 'a-z-' 'A-Z_')"
    reg_set_path path "$key" "$(real_abs "$dir")"
done

# ── 8. Block device by-name symlink directory ─────────────────

log "Detecting block device layout..."

for try in /dev/block/bootdevice/by-name \
           /dev/block/by-name; do
    [ -d "$try" ] && {
        reg_set_path path HOM_BLOCK_BY_NAME "$(real_abs "$try")"
        break
    }
done

# Platform-specific by-name (e.g. /dev/block/platform/soc/*/by-name)
for g in /dev/block/platform/*/by-name \
         /dev/block/platform/*/*/by-name; do
    [ -d "$g" ] && {
        reg_set_path path HOM_BLOCK_PLATFORM_BY_NAME "$(real_abs "$g")"
        break
    }
done

# ── 9. Encryption / decryption readiness ──────────────────────
# Record the full encryption state so that downstream scripts
# (collect.sh, unpack_images.py, failure_analysis.py) know what
# to expect when accessing /data or analysing boot images.

log "Recording encryption state and decryption readiness..."

CRYPTO_STATE=$(getprop ro.crypto.state 2>/dev/null || echo unknown)
CRYPTO_TYPE=$(getprop ro.crypto.type 2>/dev/null || echo unknown)
CRYPTO_FN_MODE=$(getprop ro.crypto.volume.filenames_mode 2>/dev/null || echo unknown)
VOLD_DECRYPT=$(getprop vold.decrypt 2>/dev/null || echo unknown)

reg_set crypto HOM_CRYPTO_STATE "$CRYPTO_STATE"
reg_set crypto HOM_CRYPTO_TYPE "$CRYPTO_TYPE"
reg_set crypto HOM_CRYPTO_FILENAMES_MODE "$CRYPTO_FN_MODE"
reg_set crypto HOM_VOLD_DECRYPT "$VOLD_DECRYPT"

# FDE vs FBE classification (used by unpack_images.py / failure_analysis.py)
# FDE (Full Disk Encryption) — pre-API 24, ro.crypto.state=encrypted, ro.crypto.type=block
# FBE (File-Based Encryption) — API 24+, ro.crypto.state=encrypted, ro.crypto.type=file
CRYPTO_CLASS="none"
case "$CRYPTO_STATE" in
    encrypted)
        case "$CRYPTO_TYPE" in
            block) CRYPTO_CLASS="FDE" ;;
            file)  CRYPTO_CLASS="FBE" ;;
            *)     CRYPTO_CLASS="unknown_encrypted" ;;
        esac
        ;;
    unencrypted) CRYPTO_CLASS="none" ;;
esac
reg_set crypto HOM_CRYPTO_CLASS "$CRYPTO_CLASS"

# Is /data currently decrypted (userdata readable)?
if [ -r /data/data/. ] && [ -d /data/data ]; then
    reg_set crypto HOM_USERDATA_DECRYPTED "true"
else
    reg_set crypto HOM_USERDATA_DECRYPTED "false"
fi

# dm-crypt / dm-verity kernel module availability
for kmod in dm_crypt dm_verity; do
    if [ -d "/sys/module/$kmod" ]; then
        reg_set crypto "HOM_KMOD_$(echo "$kmod" | tr '[:lower:]' '[:upper:]')" "loaded"
    else
        reg_set crypto "HOM_KMOD_$(echo "$kmod" | tr '[:lower:]' '[:upper:]')" "not_loaded"
    fi
done

# dmsetup availability (used by collect.sh for dm table inspection)
if command -v dmsetup >/dev/null 2>&1; then
    reg_set crypto HOM_DMSETUP_AVAILABLE "true"
else
    reg_set crypto HOM_DMSETUP_AVAILABLE "false"
fi

# ── 10. Module output directory ───────────────────────────────

log "Recording output paths..."

reg_set_path path HOM_OUT_DIR "$(real_abs "$OUT")"
reg_set_path path HOM_ENV_REGISTRY "$(real_abs "$ENV_REGISTRY")"
reg_set_path path HOM_LIVE_DUMP "$(real_abs "$OUT/live_dump")"

# ── 11. Android API-level feature flags ───────────────────────
# Record which Android features are expected at the detected API
# level.  These flags let every downstream script adapt its
# behaviour without hard-coding API thresholds themselves.
#
# The thresholds are derived from AOSP source and the scripts
# that depend on them:
#   API 21 (5.0)  — minimum supported
#   API 24 (7.0)  — File-Based Encryption (FBE) introduced
#   API 26 (8.0)  — Treble / VNDK enforced
#   API 28 (9.0)  — System-as-Root (SAR) default
#   API 29 (10)   — Dynamic partitions / APEX
#   API 30 (11)   — Virtual A/B
#   API 33 (13)   — init_boot partition (generic kernel image)
#   API 35 (15)   — current upper test boundary

log "Computing Android API-level feature flags..."

SDK_INT=$(getprop ro.build.version.sdk 2>/dev/null || echo 0)
# Ensure we have a numeric value
case "$SDK_INT" in
    ''|*[!0-9]*) SDK_INT=0 ;;
esac
reg_set api HOM_API_SDK_INT "$SDK_INT"

# File-Based Encryption support (API 24+)
if [ "$SDK_INT" -ge 24 ] 2>/dev/null; then
    reg_set api HOM_API_FBE_SUPPORTED "true"
else
    reg_set api HOM_API_FBE_SUPPORTED "false"
fi

# Treble / VNDK enforced (API 26+)
if [ "$SDK_INT" -ge 26 ] 2>/dev/null; then
    reg_set api HOM_API_TREBLE_ENFORCED "true"
else
    reg_set api HOM_API_TREBLE_ENFORCED "false"
fi

# System-as-Root default (API 28+)
if [ "$SDK_INT" -ge 28 ] 2>/dev/null; then
    reg_set api HOM_API_SAR_DEFAULT "true"
else
    reg_set api HOM_API_SAR_DEFAULT "false"
fi

# Dynamic partitions / APEX (API 29+)
if [ "$SDK_INT" -ge 29 ] 2>/dev/null; then
    reg_set api HOM_API_DYNAMIC_PARTITIONS "true"
    reg_set api HOM_API_APEX_SUPPORTED "true"
else
    reg_set api HOM_API_DYNAMIC_PARTITIONS "false"
    reg_set api HOM_API_APEX_SUPPORTED "false"
fi

# Virtual A/B (API 30+)
if [ "$SDK_INT" -ge 30 ] 2>/dev/null; then
    reg_set api HOM_API_VIRTUAL_AB "true"
else
    reg_set api HOM_API_VIRTUAL_AB "false"
fi

# init_boot partition / Generic Kernel Image (API 33+)
if [ "$SDK_INT" -ge 33 ] 2>/dev/null; then
    reg_set api HOM_API_INIT_BOOT "true"
else
    reg_set api HOM_API_INIT_BOOT "false"
fi

# ── done ─────────────────────────────────────────────────────

VAR_COUNT=$(grep -c '=' "$ENV_REGISTRY" 2>/dev/null || echo 0)
log "=== env_detect.sh complete: $VAR_COUNT variables written to $ENV_REGISTRY ==="
