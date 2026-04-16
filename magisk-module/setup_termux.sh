#!/system/bin/sh
# magisk-module/setup_termux.sh
# ============================================================
# Hands-on-metal — Conditional Termux Bootstrap
# Called by service.sh after env_detect.sh.
# Only runs if env_detect.sh decided Termux should be installed
# (HOM_TERMUX_SHOULD_INSTALL=true in the env registry).
#
# What it does:
#   1. Verifies network is reachable before touching anything
#   2. Locates or validates an existing Termux bootstrap APK
#   3. Installs Termux via pm if not present
#   4. Runs `pkg update` and installs the required package list
#   5. Updates the env registry with new Termux paths
#
# Required packages configured in: REQUIRED_PACKAGES below.
# All writes go to /sdcard/hands-on-metal/.
# Never modifies /system or any read-only partition.
# ============================================================

set -u

OUT=/sdcard/hands-on-metal
ENV_REGISTRY="$OUT/env_registry.sh"
LOG="$OUT/setup_termux.log"

# ── packages to install inside Termux ────────────────────────
# Adjust this list as the project's needs evolve.
REQUIRED_PACKAGES="python git curl wget openssh sqlite"

# ── helpers ──────────────────────────────────────────────────

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

reg_get() {
    grep "^${1}=" "$ENV_REGISTRY" 2>/dev/null | cut -d= -f2- | cut -d' ' -f1
}

real_abs() {
    local p="$1"
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$p" 2>/dev/null || echo "$p"
    else
        echo "$p"
    fi
}

reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s=%s  # cat:%s\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

reg_set_path() {
    local cat="$1" key="$2" val="$3"
    reg_set "$cat" "$key" "$val"
    local rp
    rp=$(real_abs "$val")
    [ "$rp" != "$val" ] && reg_set "$cat" "${key}_REALPATH" "$rp"
}

# ── network check ─────────────────────────────────────────────

wait_for_network() {
    local max_wait=120
    local elapsed=0
    log "Waiting for network connectivity (max ${max_wait}s)..."
    while [ "$elapsed" -lt "$max_wait" ]; do
        # Try a simple TCP connection to a Google DNS server
        if (echo "" | nc -w 2 8.8.8.8 53) >/dev/null 2>&1 ||
           ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log "Network is up (after ${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log "Network did not become available after ${max_wait}s — aborting Termux setup"
    return 1
}

# ── main ─────────────────────────────────────────────────────

mkdir -p "$OUT"
log "=== setup_termux.sh start ==="

# Read the decision from env_detect.sh
SHOULD_INSTALL=$(reg_get HOM_TERMUX_SHOULD_INSTALL)
if [ "$SHOULD_INSTALL" != "true" ]; then
    log "HOM_TERMUX_SHOULD_INSTALL=$SHOULD_INSTALL — nothing to do"
    # Re-read Termux paths in case Termux was already present; refresh registry.
    TERMUX_PREFIX=$(reg_get HOM_TERMUX_PREFIX)
    if [ -n "$TERMUX_PREFIX" ] && [ -d "$TERMUX_PREFIX" ]; then
        log "Existing Termux prefix: $TERMUX_PREFIX"
        _refresh_termux_paths "$TERMUX_PREFIX"
    fi
    exit 0
fi

# Network must be up before we attempt any download / pm install
wait_for_network || exit 1

# ── Check if Termux APK is already installed by the package manager ──

TERMUX_PKG_NAME="com.termux"
TERMUX_DATA_DIR=""
for cand in /data/data/com.termux /data/user/0/com.termux; do
    [ -d "$cand" ] && { TERMUX_DATA_DIR="$cand"; break; }
done

if [ -z "$TERMUX_DATA_DIR" ]; then
    log "Termux not found as installed APK — attempting install via pm..."

    # Look for a Termux APK in the sdcard drop zone
    TERMUX_APK=""
    for f in "$OUT/termux.apk" /sdcard/termux.apk /sdcard/Download/termux*.apk; do
        [ -f "$f" ] && { TERMUX_APK="$f"; break; }
    done

    if [ -n "$TERMUX_APK" ]; then
        log "Installing Termux from $TERMUX_APK ..."
        pm install -r "$TERMUX_APK" >> "$LOG" 2>&1 && \
            log "pm install succeeded" || \
            log "pm install failed — Termux setup will be incomplete"
    else
        log "No Termux APK found at $OUT/termux.apk or /sdcard/Download/termux*.apk"
        log "Drop a Termux APK (F-Droid build) to $OUT/termux.apk and rerun"
        reg_set termux HOM_TERMUX_INSTALLED "false"
        reg_set termux HOM_TERMUX_INSTALL_ERROR "no_apk_found"
        exit 1
    fi

    # Re-check after install
    for cand in /data/data/com.termux /data/user/0/com.termux; do
        [ -d "$cand" ] && { TERMUX_DATA_DIR="$cand"; break; }
    done

    if [ -z "$TERMUX_DATA_DIR" ]; then
        log "Termux data directory still not found after install attempt — giving up"
        reg_set termux HOM_TERMUX_INSTALLED "false"
        reg_set termux HOM_TERMUX_INSTALL_ERROR "data_dir_missing_after_install"
        exit 1
    fi
fi

TERMUX_PREFIX="$TERMUX_DATA_DIR/files/usr"
TERMUX_HOME="$TERMUX_DATA_DIR/files/home"

log "Termux prefix: $TERMUX_PREFIX"
log "Termux home:   $TERMUX_HOME"

_refresh_termux_paths() {
    local pfx="$1"
    reg_set_path termux HOM_TERMUX_PREFIX "$pfx"
    reg_set termux HOM_TERMUX_INSTALLED "true"
    local hm
    hm=$(dirname "$(dirname "$pfx")")/home
    [ -d "$hm" ] && reg_set_path termux HOM_TERMUX_HOME "$hm"
    for sh in "$pfx/bin/bash" "$pfx/bin/sh"; do
        [ -x "$sh" ] && { reg_set_path termux HOM_TERMUX_SHELL "$sh"; break; }
    done
    for tpy in "$pfx/bin/python3" "$pfx/bin/python"; do
        if [ -x "$tpy" ]; then
            tver=$("$tpy" --version 2>&1 | awk '{print $2}')
            reg_set_path termux HOM_TERMUX_PYTHON "$tpy"
            reg_set termux HOM_TERMUX_PYTHON_VERSION "$tver"
            break
        fi
    done
    local pkg_cmd="$pfx/bin/pkg"
    [ -x "$pkg_cmd" ] && reg_set_path termux HOM_TERMUX_PKG "$pkg_cmd"
}

# ── Wait for Termux bootstrap to finish (first-run unpacking) ─

TERMUX_BIN="$TERMUX_PREFIX/bin"
MAX_WAIT=120
elapsed=0
log "Waiting for Termux bootstrap (pkg/apt) to appear..."
while [ ! -x "$TERMUX_BIN/pkg" ] && [ ! -x "$TERMUX_BIN/apt" ]; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        log "Termux bootstrap did not complete in ${MAX_WAIT}s — skipping package install"
        _refresh_termux_paths "$TERMUX_PREFIX"
        exit 1
    fi
done
log "Termux bootstrap ready after ${elapsed}s"

# ── Run pkg update ─────────────────────────────────────────────

log "Running: pkg update -y ..."
# Run as the Termux UID using run-as; fall back to direct call if unavailable.
if command -v run-as >/dev/null 2>&1; then
    run-as com.termux "$TERMUX_PREFIX/bin/pkg" update -y >> "$LOG" 2>&1 || \
        log "pkg update returned non-zero (may be ok)"
else
    "$TERMUX_PREFIX/bin/pkg" update -y >> "$LOG" 2>&1 || \
        log "pkg update returned non-zero (may be ok)"
fi

# ── Install required packages ──────────────────────────────────

log "Installing packages: $REQUIRED_PACKAGES ..."
# shellcheck disable=SC2086  # word-split intentional for package list
if command -v run-as >/dev/null 2>&1; then
    run-as com.termux "$TERMUX_PREFIX/bin/pkg" install -y $REQUIRED_PACKAGES >> "$LOG" 2>&1 || \
        log "pkg install returned non-zero (check $LOG)"
else
    "$TERMUX_PREFIX/bin/pkg" install -y $REQUIRED_PACKAGES >> "$LOG" 2>&1 || \
        log "pkg install returned non-zero (check $LOG)"
fi

# ── Refresh env registry with confirmed Termux paths ──────────

_refresh_termux_paths "$TERMUX_PREFIX"

# Record installed package paths
for pkg_bin in python3 git curl wget sqlite3; do
    p="$TERMUX_PREFIX/bin/$pkg_bin"
    [ -x "$p" ] && \
        reg_set_path package \
            "HOM_TERMUX_BIN_$(echo "$pkg_bin" | tr 'a-z-' 'A-Z_')" \
            "$(real_abs "$p")"
done

# Update the install decision so subsequent runs skip this block
reg_set termux HOM_TERMUX_SHOULD_INSTALL "false"
reg_set termux HOM_TERMUX_INSTALLED "true"

log "=== setup_termux.sh complete ==="
