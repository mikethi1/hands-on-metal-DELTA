#!/system/bin/sh
# magisk-module/env_detect.sh
# ============================================================
# Hands-on-metal — Environment Detection
# Runs early in service.sh before collect.sh.
# Probes the shell environment, available tools, Python builds,
# and Termux state, then writes every discovered fact into the
# flat env registry at $ENV_REGISTRY so the rest of the
# pipeline can source it without a database dependency.
#
# All writes go to /sdcard/hands-on-metal/env_registry.sh —
# a sourceable key=value file.  The pipeline ingests this into
# the env_var SQLite table later.
#
# Safety guarantees (same as collect.sh):
#   • Never writes outside /sdcard/hands-on-metal/
#   • Never modifies any system partition
# ============================================================

set -u

OUT=/sdcard/hands-on-metal
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
    printf '%s=%s  # cat:%s\n' "$key" "$val" "$cat" >> "$tmp"
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
            nmreadelf nm lshal getprop setprop \
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
for py_cmd in python3 python python3.12 python3.11 python3.10 python3.9 python3.8; do
    p=$(command -v "$py_cmd" 2>/dev/null || true)
    [ -z "$p" ] && continue
    rp=$(real_abs "$p")
    ver=$("$p" --version 2>&1 | awk '{print $2}')
    key="HOM_PYTHON_$(echo "$py_cmd" | tr '.' '_' | tr 'a-z' 'A-Z')"
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
CANONICAL=$(grep "^HOM_PYTHON_CANONICAL=" "$ENV_REGISTRY" | cut -d= -f2- | cut -d' ' -f1 || true)
if [ -n "$CANONICAL" ] && [ -x "$CANONICAL" ]; then
    SITE=$("$CANONICAL" -c "import site; print(' '.join(site.getsitepackages()))" 2>/dev/null || true)
    reg_set python HOM_PYTHON_SITE_PACKAGES "$SITE"
fi

# ── 4. pip / package managers ─────────────────────────────────

log "Detecting pip and package managers..."

for pm in pip3 pip pip3.12 pip3.11; do
    p=$(command -v "$pm" 2>/dev/null || true)
    [ -z "$p" ] && continue
    rp=$(real_abs "$p")
    key="HOM_PIP_$(echo "$pm" | tr '.' '_' | tr 'a-z' 'A-Z')"
    reg_set_path python "$key" "$rp"
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

# Decide whether Termux SHOULD be installed by setup_termux.sh.
# Criteria: no system Python found AND no Termux prefix AND we have
# network access (checked later in setup_termux.sh).
if [ "$PY_FOUND" -eq 0 ] && [ -z "$TERMUX_PREFIX" ]; then
    reg_set termux HOM_TERMUX_SHOULD_INSTALL "true"
else
    reg_set termux HOM_TERMUX_SHOULD_INSTALL "false"
fi

# ── 6. Permissions / SELinux context ─────────────────────────

log "Detecting permissions and SELinux context..."

reg_set shell HOM_WHOAMI "$(id 2>/dev/null || echo unknown)"
reg_set shell HOM_SELINUX_CONTEXT "$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0' || echo unknown)"
reg_set shell HOM_SELINUX_ENFORCE "$(cat /sys/fs/selinux/enforce 2>/dev/null || echo unknown)"

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

# ── 9. Encryption state ───────────────────────────────────────

log "Recording encryption state..."

reg_set crypto HOM_CRYPTO_STATE "$(getprop ro.crypto.state 2>/dev/null || echo unknown)"
reg_set crypto HOM_CRYPTO_TYPE "$(getprop ro.crypto.type 2>/dev/null || echo unknown)"
reg_set crypto HOM_CRYPTO_FILENAMES_MODE "$(getprop ro.crypto.volume.filenames_mode 2>/dev/null || echo unknown)"
reg_set crypto HOM_VOLD_DECRYPT "$(getprop vold.decrypt 2>/dev/null || echo unknown)"

# ── 10. Module output directory ───────────────────────────────

log "Recording output paths..."

reg_set_path path HOM_OUT_DIR "$(real_abs "$OUT")"
reg_set_path path HOM_ENV_REGISTRY "$(real_abs "$ENV_REGISTRY")"
reg_set_path path HOM_LIVE_DUMP "$(real_abs "$OUT/live_dump")"

# ── done ─────────────────────────────────────────────────────

VAR_COUNT=$(grep -c '=' "$ENV_REGISTRY" 2>/dev/null || echo 0)
log "=== env_detect.sh complete: $VAR_COUNT variables written to $ENV_REGISTRY ==="
