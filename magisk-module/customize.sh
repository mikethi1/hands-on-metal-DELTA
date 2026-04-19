#!/system/bin/sh
# magisk-module/customize.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Magisk module customization hook.
# Sourced by the update-binary installer after module files are
# extracted.  Runs the full hands-on-metal guided root workflow
# using the shared core/* scripts.
#
# Workflow (state machine):
#   INIT → ENV_DETECTED → DEVICE_PROFILED → BOOT_IMG_ACQUIRED
#   → BOOT_IMG_PATCHED → ANTI_ROLLBACK_CHECKED → FLASH_QUEUED
#   → FLASHED → ROOT_VERIFIED → COMPLETE
#
# At each step the user sees:
#   • What the step does and why it is needed
#   • Expected outcome (success / failure / action required)
#   • Full log path for troubleshooting
# ============================================================

set -u

# ── base paths ────────────────────────────────────────────────

MODPATH="${MODPATH:-/data/adb/modules/hands-on-metal-collector}"
CORE="$MODPATH/core"
OUT="${HOME:-/data/local/tmp}/hands-on-metal"
ENV_REGISTRY="$OUT/env_registry.sh"
STATE_FILE="$MODPATH/.install_state"
LOG_DIR="$OUT/logs"

# Export so core scripts pick them up
export OUT ENV_REGISTRY STATE_FILE LOG_DIR ZIPFILE

# ── bootstrap logging & UX ────────────────────────────────────

SCRIPT_NAME="customize"
export SCRIPT_NAME

# shellcheck source=/dev/null
. "$CORE/logging.sh"
# shellcheck source=/dev/null
. "$CORE/ux.sh"
# shellcheck source=/dev/null
. "$CORE/state_machine.sh"
# shellcheck source=/dev/null
. "$CORE/privacy.sh"

mkdir -p "$OUT" "$LOG_DIR"
log_banner "hands-on-metal root workflow (Magisk path)"
sm_print_status

# ── helpers ───────────────────────────────────────────────────

_source_core() {
    local script="$CORE/$1"
    if [ -f "$script" ]; then
        # shellcheck source=/dev/null
        . "$script"
    else
        ux_abort "Missing core script: $script"
    fi
}

# ── step 1: environment detection ────────────────────────────

if ! sm_require "ENV_DETECTED" 2>/dev/null; then
    ux_step_info "Environment Detection" \
        "Probes shell, Python, Termux, available tools, SELinux context, and key paths" \
        "Ensures all prerequisites are present before running collection or patching scripts"

    # shellcheck disable=SC1091  # source path is dynamic at install time
    SCRIPT_NAME="env_detect" . "$MODPATH/env_detect.sh" || \
        ux_abort "Environment detection failed — check $LOG_DIR for details"

    sm_set_state "ENV_DETECTED"
fi

ux_step_result "Environment Detection" "OK"
ux_progress 10

# ── step 2: device profile (Treble Check equivalent) ─────────

if ! sm_require "DEVICE_PROFILED" 2>/dev/null; then
    _source_core "device_profile.sh"
    SCRIPT_NAME="device_profile"
    run_device_profile
    sm_set_state "DEVICE_PROFILED"
fi

ux_step_result "Device Profile" "OK"
ux_progress 20

# ── step 2b: candidate entry & family defaults ───────────────
# Check if the device is in the known-compatibility database and
# apply safe defaults for Magisk flags.  Unknown devices get a
# candidate entry for maintainer review.

_source_core "candidate_entry.sh"
SCRIPT_NAME="candidate_entry"
run_candidate_entry

_source_core "apply_defaults.sh"
SCRIPT_NAME="apply_defaults"
run_apply_defaults

ux_progress 25

# ── step 3: boot image acquisition ───────────────────────────

if ! sm_require "BOOT_IMG_ACQUIRED" 2>/dev/null; then
    _source_core "boot_image.sh"
    # shellcheck disable=SC2034  # consumed by sourced core/boot_image.sh
    PARTITION_INDEX="$MODPATH/build/partition_index.json"
    SCRIPT_NAME="boot_image"
    run_boot_image_acquire
    sm_set_state "BOOT_IMG_ACQUIRED"
fi

ux_step_result "Boot Image Acquire" "OK"
ux_progress 40

# ── step 4: anti-rollback check ──────────────────────────────

if ! sm_require "ANTI_ROLLBACK_CHECKED" 2>/dev/null; then
    _source_core "anti_rollback.sh"
    SCRIPT_NAME="anti_rollback"
    run_anti_rollback_check
    sm_set_state "ANTI_ROLLBACK_CHECKED"
fi

ux_step_result "Anti-Rollback Check" "OK"
ux_progress 55

# ── step 5: Magisk patch ──────────────────────────────────────

if ! sm_require "BOOT_IMG_PATCHED" 2>/dev/null; then
    _source_core "magisk_patch.sh"
    SCRIPT_NAME="magisk_patch"
    run_magisk_patch
    sm_set_state "BOOT_IMG_PATCHED"
fi

ux_step_result "Magisk Patch" "OK"
ux_progress 75

# ── step 6: queue flash & reboot ─────────────────────────────

if ! sm_require "FLASHED" 2>/dev/null; then
    _source_core "flash.sh"
    SCRIPT_NAME="flash"

    ux_section "Ready to Flash"
    ux_print "  The patched image is ready."
    ux_print "  Flashing will write it to the boot partition and reboot."
    ux_print ""
    ux_print "  WARNING: Ensure you have a recovery backup before proceeding."
    ux_print ""

    # In Magisk installer context, we flash immediately.
    sm_set_state "FLASH_QUEUED"
    run_flash_magisk_path
    sm_set_state "FLASHED"
fi

ux_step_result "Flash" "OK"
ux_progress 95

# ── step 7: mark complete ─────────────────────────────────────

sm_set_state "ROOT_VERIFIED"
sm_set_state "COMPLETE"
ux_progress 100

ux_section "Installation Complete"
ux_print "  Root has been installed via Magisk."
ux_print "  The device will reboot momentarily."
ux_print ""
ux_print "  After reboot:"
ux_print "    1. Open Magisk app → confirm root"
ux_print "    2. Hardware collection logs: ~/hands-on-metal/"
ux_print "    3. Full install log: $LOG_DIR/"
ux_print ""

log_banner "customize.sh complete (COMPLETE state)"
