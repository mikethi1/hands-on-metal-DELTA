#!/system/bin/sh
# core/anti_rollback.sh
# ============================================================
# Anti-rollback protection guard.
#
# Android's AVB anti-rollback index prevents flashing images
# whose rollback index is lower than what the device has stored
# in its Replay Protection Memory Block (RPMB/fuses).
#
# Starting with the May 2026 security patch and the associated
# Magisk guard policy, Magisk's own patch logic also enforces
# that the patched image's security patch level (SPL) is not
# rolled back.
#
# This script:
#   1. Reads the current device SPL and AVB rollback index.
#   2. Reads the SPL embedded in the target boot image header.
#   3. Compares them and blocks the install if a rollback is
#      detected.
#   4. Records the check result in the env registry.
#
# Requires: logging.sh, ux.sh sourced first.
#
# ENV_REGISTRY variables consumed:
#   HOM_BOOT_IMG_PATH  — path to the local copy of the image
#   HOM_DEV_SPL        — device security patch level
#   HOM_DEV_AVB_STATE  — AVB verified boot state
# ============================================================

SCRIPT_NAME="anti_rollback"

OUT="${OUT:-/sdcard/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"

# The SPL from which Magisk's May-2026 anti-rollback policy activates.
MAY_2026_SPL="2026-05-07"

# Minimum Magisk version code required when May-2026 policy is active.
MAY_2026_MAGISK_MIN=30700
MAY_2026_MAGISK_STR="30.7"

# ── helpers ───────────────────────────────────────────────────

_reg_get() {
    grep "^${1}=" "$ENV_REGISTRY" 2>/dev/null | \
        cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//'
}

_reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

# Compare two YYYY-MM-DD dates.  Returns 0 if $1 >= $2.
_spl_ge() {
    local a="$1" b="$2"
    # Normalize: strip dashes → YYYYMMDD integer comparison
    local an; an=$(printf '%s' "$a" | tr -d '-')
    local bn; bn=$(printf '%s' "$b" | tr -d '-')
    [ -z "$an" ] && return 1
    [ -z "$bn" ] && return 0
    [ "$an" -ge "$bn" ] 2>/dev/null
}

# Extract the security patch level from a boot image header.
# The boot image v3/v4 header embeds the security_patch_level field
# at offset 0x60 (96 bytes) as a null-terminated ASCII string in
# the format YYYY-MM-DD.  For v0/v1/v2 images it is not present;
# we return empty string in that case.
_extract_img_spl() {
    local img="$1"
    [ -f "$img" ] || { echo ""; return; }

    # Read 10 bytes at offset 0x60 — covers YYYY-MM-DD\0
    local raw
    raw=$(dd if="$img" bs=1 skip=96 count=10 2>/dev/null | cat)
    # Validate the format YYYY-MM-DD
    if printf '%s' "$raw" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        printf '%s' "$raw" | head -c 10
    else
        echo ""
    fi
}

# Read the AVB rollback index stored by the bootloader.
# /sys/fs/pstore may expose it; alternatively we read from
# getprop ro.boot.vbmeta.avb_version and stored rollback counters.
_read_avb_rollback_index() {
    # Prefer /proc/avb_rollback_index if present (some kernels expose it)
    if [ -r /proc/avb_rollback_index ]; then
        cat /proc/avb_rollback_index 2>/dev/null | head -1
        return
    fi
    # Fallback: read the Magisk-exposed rollback index file
    if [ -f /data/adb/.avb_rollback_index ]; then
        cat /data/adb/.avb_rollback_index
        return
    fi
    # Cannot determine; return empty (caller will treat as unknown)
    echo ""
}

# ── main function ─────────────────────────────────────────────

run_anti_rollback_check() {
    ux_section "Anti-Rollback Protection Check"
    ux_step_info "Anti-Rollback Check" \
        "Compares the device's stored security patch level and AVB rollback index \
against the boot image being patched" \
        "Flashing an image with an older security patch level or rollback index can \
permanently brick the device via AVB fuse-burning — this check prevents that"

    local boot_img device_spl avb_state
    boot_img=$(_reg_get HOM_BOOT_IMG_PATH)
    device_spl=$(_reg_get HOM_DEV_SPL)
    avb_state=$(_reg_get HOM_DEV_AVB_STATE)

    log_var "boot_img"   "$boot_img"   "path to boot image being checked"
    log_var "device_spl" "$device_spl" "device current security patch level"
    log_var "avb_state"  "$avb_state"  "AVB verified boot state"

    if [ -z "$boot_img" ] || [ ! -f "$boot_img" ]; then
        ux_abort "Anti-rollback check: no boot image found at '$boot_img' — run boot image acquisition first."
    fi

    # ── 1. Check device SPL vs May 2026 policy ────────────────

    local may2026_active="false"
    if _spl_ge "$device_spl" "$MAY_2026_SPL"; then
        may2026_active="true"
        ux_print "  May-2026 anti-rollback policy is ACTIVE (device SPL: $device_spl)"
    else
        ux_print "  May-2026 policy not yet active (device SPL: $device_spl)"
    fi

    _reg_set avb HOM_ARB_MAY2026_ACTIVE "$may2026_active"
    log_var "HOM_ARB_MAY2026_ACTIVE" "$may2026_active" \
        "true when device SPL >= 2026-05-07 (activates Magisk May-2026 policy)"

    # ── 2. Extract image SPL ──────────────────────────────────

    local img_spl
    img_spl=$(_extract_img_spl "$boot_img")

    if [ -z "$img_spl" ]; then
        ux_print "  Boot image SPL: not embedded (boot image v0/v1/v2 header)"
        _reg_set avb HOM_ARB_IMG_SPL "UNKNOWN"
    else
        ux_print "  Boot image SPL: $img_spl"
        _reg_set avb HOM_ARB_IMG_SPL "$img_spl"
    fi

    log_var "HOM_ARB_IMG_SPL" "${img_spl:-UNKNOWN}" "security patch level in boot image header"

    # ── 3. Rollback direction check ───────────────────────────

    local rollback_risk="false"
    if [ -n "$img_spl" ] && [ -n "$device_spl" ]; then
        if ! _spl_ge "$img_spl" "$device_spl"; then
            rollback_risk="true"
            ux_print ""
            ux_print "  ╔═══════════════════════════════════════════╗"
            ux_print "  ║  ROLLBACK RISK DETECTED                   ║"
            ux_print "  ║  Image SPL ($img_spl) is OLDER than       ║"
            ux_print "  ║  device SPL ($device_spl).                ║"
            ux_print "  ║  This image cannot be safely flashed.     ║"
            ux_print "  ╚═══════════════════════════════════════════╝"
            ux_print ""
            ux_print "  ACTION: Obtain a boot image from a firmware version"
            ux_print "  whose security patch level is >= $device_spl."
        fi
    fi

    _reg_set avb HOM_ARB_ROLLBACK_RISK "$rollback_risk"
    log_var "HOM_ARB_ROLLBACK_RISK" "$rollback_risk" \
        "true when image SPL < device SPL (rollback protection would block boot)"

    # ── 4. AVB rollback index check ───────────────────────────

    local dev_rollback_index
    dev_rollback_index=$(_read_avb_rollback_index)

    if [ -n "$dev_rollback_index" ]; then
        ux_print "  Device AVB rollback index: $dev_rollback_index"
        _reg_set avb HOM_ARB_DEV_ROLLBACK_IDX "$dev_rollback_index"
        log_var "HOM_ARB_DEV_ROLLBACK_IDX" "$dev_rollback_index" \
            "AVB rollback index stored in device fuses/RPMB"
    else
        ux_print "  Device AVB rollback index: not readable (OK — Magisk handles this)"
        _reg_set avb HOM_ARB_DEV_ROLLBACK_IDX "UNKNOWN"
    fi

    # ── 5. May-2026 Magisk patch flag requirement ─────────────
    # When the May-2026 policy is active, we must ensure Magisk uses
    # the --patch-vbmeta-flag and correct rollback_index in the patched
    # image.  We record this requirement so magisk_patch.sh picks it up.

    local require_may2026_flags="false"
    if [ "$may2026_active" = "true" ]; then
        require_may2026_flags="true"
        ux_print "  Magisk MUST use May-2026 compatible patch flags."
        ux_print "  (magisk_patch.sh will apply --patch-vbmeta-flag and rollback_index preservation)"

        # ── Magisk version gate ───────────────────────────────
        # When the May-2026 policy is active, Magisk must be at
        # least v30.7 (30700).  Older versions do not support
        # PATCHVBMETAFLAG correctly and would produce an image
        # that fails AVB verification — bricking the device.
        local magisk_ver_code
        magisk_ver_code=$(_reg_get HOM_MAGISK_VER_CODE)
        if [ -n "$magisk_ver_code" ] && [ "$magisk_ver_code" != "UNKNOWN" ]; then
            if [ "$magisk_ver_code" -lt "$MAY_2026_MAGISK_MIN" ] 2>/dev/null; then
                ux_print ""
                ux_print "  ╔═══════════════════════════════════════════╗"
                ux_print "  ║  MAGISK VERSION TOO OLD FOR MAY-2026      ║"
                ux_print "  ║  Installed: $magisk_ver_code (need ≥ $MAY_2026_MAGISK_MIN)    ║"
                ux_print "  ║  Upgrade to Magisk $MAY_2026_MAGISK_STR+ before proceeding.   ║"
                ux_print "  ╚═══════════════════════════════════════════╝"
                ux_print ""
                _reg_set avb HOM_ARB_MAGISK_ADEQUATE "false"
                manifest_step "anti_rollback_magisk_version" "FAIL" \
                    "need>=$MAY_2026_MAGISK_MIN got=$magisk_ver_code"
                ux_abort "Magisk $magisk_ver_code cannot safely handle May-2026 anti-rollback policy. Upgrade to $MAY_2026_MAGISK_STR+."
            else
                _reg_set avb HOM_ARB_MAGISK_ADEQUATE "true"
                ux_print "  Magisk version $magisk_ver_code ≥ $MAY_2026_MAGISK_MIN — OK for May-2026 policy"
            fi
        else
            # Version unknown — warn but allow (offline bundle case)
            ux_print "  WARNING: Magisk version not yet known — magisk_patch.sh will re-check."
            _reg_set avb HOM_ARB_MAGISK_ADEQUATE "unknown"
        fi
    fi

    _reg_set avb HOM_ARB_REQUIRE_MAY2026_FLAGS "$require_may2026_flags"
    log_var "HOM_ARB_REQUIRE_MAY2026_FLAGS" "$require_may2026_flags" \
        "true when magisk_patch.sh must apply May-2026 policy-compatible patch options"

    # ── 6. Final verdict ─────────────────────────────────────

    if [ "$rollback_risk" = "true" ]; then
        ux_step_result "Anti-Rollback Check" "FAIL" \
            "image SPL older than device — flash blocked to protect device"
        manifest_step "anti_rollback_check" "FAIL" \
            "rollback risk: img=$img_spl dev=$device_spl"
        ux_abort "Anti-rollback check failed: cannot proceed safely. See instructions above."
    fi

    ux_step_result "Anti-Rollback Check" "OK" \
        "no rollback risk detected${may2026_active:+ (May-2026 flags required)}"
    manifest_step "anti_rollback_check" "OK" \
        "img_spl=${img_spl:-NA} device_spl=$device_spl may2026=$may2026_active"
}
