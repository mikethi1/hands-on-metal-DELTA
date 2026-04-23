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
