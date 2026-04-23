#!/system/bin/sh
# magisk-module/service.sh
# ============================================================
# Magisk module service script — runs on every boot.
# Executes collect.sh only once (on the first boot after
# module installation).  The sentinel file is stored on /data
# so it survives reboots.
# ============================================================

SENTINEL=/data/adb/modules/hands-on-metal-collector/.collected
MODULE_DIR=/data/adb/modules/hands-on-metal-collector

# Wait for the system to settle before touching sysfs / procfs
sleep 10

if [ ! -f "$SENTINEL" ]; then
    # Run collector in the background so boot is not blocked
    sh "$MODULE_DIR/collect.sh" &
    touch "$SENTINEL"
fi
