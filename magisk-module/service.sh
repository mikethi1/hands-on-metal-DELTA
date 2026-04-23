#!/system/bin/sh
# magisk-module/service.sh
# ============================================================
# Magisk module service script — runs on every boot with root.
#
# Execution order (guarded by sentinel so it only fully runs once):
#   1. env_detect.sh  — probe shell/Python/Termux, build env registry
#   2. setup_termux.sh — conditionally install + configure Termux
#   3. device_profile  — update device profile on each boot
#   4. collect.sh     — hardware data collection (read-only)
#
# On subsequent boots the sentinel prevents re-running steps 1-4
# unless manually deleted.  Delete the sentinel to force a re-run:
#   rm /data/adb/modules/hands-on-metal-collector/.collected
#
# OTA / version-change auto-detection (runs before the sentinel check):
#   If ro.build.version.sdk, ro.build.version.security_patch, or
#   ro.boot.slot_suffix differs from the cached values in env_registry.sh,
#   the sentinel and state file are deleted automatically so the full
#   workflow re-runs against the updated system image.  On an A/B slot
#   change the stale boot_work/ directory is also purged so a fresh image
#   is acquired from the now-active slot.
# ============================================================

MODULE_DIR=/data/adb/modules/hands-on-metal-collector
SENTINEL="$MODULE_DIR/.collected"
CORE="$MODULE_DIR/core"

OUT=/sdcard/hands-on-metal
ENV_REGISTRY="$OUT/env_registry.sh"
LOG_DIR="$OUT/logs"
STATE_FILE="$MODULE_DIR/.install_state"

export OUT ENV_REGISTRY LOG_DIR STATE_FILE MODULE_DIR

# Wait for the system to settle before touching sysfs / procfs
sleep 10

# ── OTA / version-change detector ────────────────────────────
# Runs unconditionally on every boot, before the sentinel check.
# Uses only POSIX sh builtins and getprop so logging.sh is not required.

_ota_log() {
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "UNKNOWN")
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '[%s][OTA_DETECT][service] %s\n' "$ts" "$*" \
        >> "$LOG_DIR/service_boot.log" 2>/dev/null || true
}

_ota_reg_get() {
    grep "^${1}=" "$ENV_REGISTRY" 2>/dev/null | \
        cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//'
}

if [ -f "$ENV_REGISTRY" ]; then
    _ota_sdk_cached=$(_ota_reg_get HOM_DEV_SDK_INT)
    _ota_spl_cached=$(_ota_reg_get HOM_DEV_SPL)
    _ota_slot_cached=$(_ota_reg_get HOM_DEV_SLOT_SUFFIX)

    _ota_sdk_live=$(getprop ro.build.version.sdk 2>/dev/null || true)
    _ota_spl_live=$(getprop ro.build.version.security_patch 2>/dev/null || true)
    _ota_slot_live=$(getprop ro.boot.slot_suffix 2>/dev/null || true)

    _ota_changed=0
    _ota_slot_changed=0
    _ota_reason=""

    if [ -n "$_ota_sdk_cached" ] && [ "$_ota_sdk_live" != "$_ota_sdk_cached" ]; then
        _ota_changed=1
        _ota_reason="SDK $_ota_sdk_cached→$_ota_sdk_live"
    fi

    if [ -n "$_ota_spl_cached" ] && [ "$_ota_spl_live" != "$_ota_spl_cached" ]; then
        _ota_changed=1
        _ota_reason="${_ota_reason:+$_ota_reason, }SPL $_ota_spl_cached→$_ota_spl_live"
    fi

    if [ -n "$_ota_slot_cached" ] && [ "$_ota_slot_live" != "$_ota_slot_cached" ]; then
        _ota_slot_changed=1
        _ota_changed=1
        _ota_reason="${_ota_reason:+$_ota_reason, }slot $_ota_slot_cached→$_ota_slot_live"
    fi

    if [ "$_ota_changed" -eq 1 ]; then
        _ota_log "[OTA_DETECTED] Change detected: $_ota_reason"
        _ota_log "Clearing sentinel and state file — full workflow will re-run"
        rm -f "$SENTINEL"
        rm -f "$STATE_FILE"
        if [ "$_ota_slot_changed" -eq 1 ]; then
            _ota_log "A/B slot change — purging stale boot image cache ($OUT/boot_work)"
            rm -rf "$OUT/boot_work"
        fi
    fi

    unset _ota_sdk_cached _ota_spl_cached _ota_slot_cached \
          _ota_sdk_live _ota_spl_live _ota_slot_live \
          _ota_changed _ota_slot_changed _ota_reason
fi

if [ ! -f "$SENTINEL" ]; then
    # Mark collected first so a crash mid-run does not loop forever.
    # Delete the sentinel manually if a fresh re-run is needed.
    touch "$SENTINEL"

    (
        SCRIPT_NAME="service"
        export SCRIPT_NAME

        # Bootstrap logging
        . "$CORE/logging.sh"
        . "$CORE/ux.sh"
        . "$CORE/state_machine.sh"

        log_banner "service.sh boot run (RUN_ID=$RUN_ID)"
        sm_print_status

        # Step 1: environment detection
        log_info "Step 1: env_detect.sh"
        SCRIPT_NAME="env_detect" sh "$MODULE_DIR/env_detect.sh"

        # Step 2: conditional Termux setup
        log_info "Step 2: setup_termux.sh"
        SCRIPT_NAME="setup_termux" sh "$MODULE_DIR/setup_termux.sh"

        # Step 3: hardware data collection
        log_info "Step 3: collect.sh"
        SCRIPT_NAME="collect" sh "$MODULE_DIR/collect.sh"

        log_banner "service.sh boot run complete"
    ) >> "$LOG_DIR/service_boot.log" 2>&1 &
fi
