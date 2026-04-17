#!/system/bin/sh
# magisk-module/service.sh
# ============================================================
# Magisk module service script — runs on every boot.
# Execution order:
#   1. env_detect.sh  — probe shell/Python/Termux, build env registry
#   2. setup_termux.sh — conditionally install + configure Termux
#   3. collect.sh     — hardware data collection (read-only)
#
# Steps 1-3 run only once (on the first boot after module
# installation), guarded by a sentinel file on /data.
# ============================================================

SENTINEL=/data/adb/modules/hands-on-metal-collector/.collected
MODULE_DIR=/data/adb/modules/hands-on-metal-collector

# Wait for the system to settle before touching sysfs / procfs
sleep 10

if [ ! -f "$SENTINEL" ]; then
    # Mark collected first so a crash mid-run doesn't loop forever.
    # Delete the sentinel manually if you want a fresh re-run.
    touch "$SENTINEL"

    (
        # Step 1: detect shell environment and write env registry
        sh "$MODULE_DIR/env_detect.sh"

        # Step 2: conditionally install / configure Termux
        sh "$MODULE_DIR/setup_termux.sh"

        # Step 3: hardware data collection
        sh "$MODULE_DIR/collect.sh"
    ) &
fi
