#!/system/bin/sh
# core/anti_rollback.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
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

# shellcheck disable=SC2034  # consumed by core/logging.sh when sourced
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
        head -1 < /proc/avb_rollback_index 2>/dev/null
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

    # ── 6. Tensor Pixel bootloader / radio ARB check ─────────
    # Background: starting with the May 2025 OTAs Google bumped the
    # bootloader anti-rollback (ARB) version on Tensor Pixels
    # (Pixel 6 / 6 Pro / 6a / 8 / 8 Pro / 8a).  Once the new
    # bootloader is installed and the device boots once, the ARB
    # counter is fused.  Flashing an older bootloader.img or
    # radio.img after that point is a PERMANENT BRICK — the device
    # will refuse to start and Google has no recovery path.
    #
    # See: https://xdaforums.com/t/4735780/  (May 2025 / and newer
    #     beware of permanent bricks if you don't handle the
    #     anti-rollback bootloader correctly on all Pixel 6/6 Pro/
    #     6a/8/8 Pro/8a)
    #
    # Strategy here:
    #   • If we know the device's current bootloader / baseband
    #     versions and a local factory ZIP is present, compare
    #     them against the factory's `require version-bootloader=`
    #     / `require version-baseband=` (already parsed by
    #     core/device_profile.sh into HOM_DEV_FACTORY_REQUIRED_…).
    #   • A *downgrade* on a Tensor device is unrecoverable; we
    #     refuse to proceed and add `bootloader`/`radio` to a
    #     `HOM_ARB_DO_NOT_FLASH` list that downstream flash
    #     tooling MUST honour.
    #   • An *upgrade* will fuse-bump the ARB; we warn loudly so
    #     the user understands they cannot revert.

    _arb_bl_compare() {
        # Compare two Pixel bootloader version strings of the form
        # "<codename>-<major>.<minor>-<build>" (e.g.
        # "husky-1.5-12345678").  Echoes:
        #   "older"    if $1 is older than $2
        #   "newer"    if $1 is newer than $2
        #   "equal"    if they are identical
        #   "unknown"  if either is empty / unparseable
        local a="$1" b="$2"
        [ -z "$a" ] || [ -z "$b" ] && { echo "unknown"; return; }
        [ "$a" = "$b" ] && { echo "equal"; return; }
        # Strip the leading "<codename>-" — same on both sides for a
        # given device.  Then compare lexicographically: Pixel
        # bootloader version strings sort correctly that way because
        # both the major.minor and the date-encoded build tail are
        # zero-padded by Google.
        local av bv
        av=$(printf '%s' "$a" | sed 's/^[^-]*-//')
        bv=$(printf '%s' "$b" | sed 's/^[^-]*-//')
        [ -z "$av" ] || [ -z "$bv" ] && { echo "unknown"; return; }
        if [ "$av" = "$bv" ]; then echo "equal"
        else
            # POSIX "smaller string sorts first" check
            local first
            first=$(printf '%s\n%s\n' "$av" "$bv" | sort | head -1)
            if [ "$first" = "$av" ]; then echo "older"; else echo "newer"; fi
        fi
    }

    local tensor_affected dev_bl dev_bb fact_bl fact_bb fact_zip
    tensor_affected=$(_reg_get HOM_DEV_TENSOR_ARB_AFFECTED)
    dev_bl=$(_reg_get HOM_DEV_BOOTLOADER)
    dev_bb=$(_reg_get HOM_DEV_BASEBAND)
    fact_bl=$(_reg_get HOM_DEV_FACTORY_REQUIRED_BOOTLOADER)
    fact_bb=$(_reg_get HOM_DEV_FACTORY_REQUIRED_BASEBAND)
    fact_zip=$(_reg_get HOM_DEV_FACTORY_ZIP)

    log_var "tensor_affected" "$tensor_affected" "device flagged as Tensor ARB-affected by device_profile"
    log_var "dev_bl"  "$dev_bl"  "device current bootloader version"
    log_var "dev_bb"  "$dev_bb"  "device current baseband version"
    log_var "fact_bl" "$fact_bl" "factory-required bootloader version (from android-info.txt)"
    log_var "fact_bb" "$fact_bb" "factory-required baseband version (from android-info.txt)"

    local bl_cmp="unknown" bb_cmp="unknown"
    local bootloader_downgrade="false"
    local bootloader_upgrade_will_fuse="false"
    local baseband_downgrade="false"
    local do_not_flash=""

    if [ -n "$fact_zip" ]; then
        bl_cmp=$(_arb_bl_compare "$fact_bl" "$dev_bl")
        bb_cmp=$(_arb_bl_compare "$fact_bb" "$dev_bb")
        ux_sep
        ux_print "  Bootloader / Radio ARB cross-check (vs $(basename "$fact_zip"))"
        ux_print "    device bootloader  : ${dev_bl:-unknown}"
        ux_print "    factory bootloader : ${fact_bl:-unknown}   →  $bl_cmp"
        ux_print "    device baseband    : ${dev_bb:-unknown}"
        ux_print "    factory baseband   : ${fact_bb:-unknown}   →  $bb_cmp"

        case "$bl_cmp" in
            older) bootloader_downgrade="true";   do_not_flash="$do_not_flash bootloader" ;;
            newer) bootloader_upgrade_will_fuse="true" ;;
        esac
        case "$bb_cmp" in
            older) baseband_downgrade="true";     do_not_flash="$do_not_flash radio" ;;
        esac
    else
        ux_print "  Bootloader/Radio ARB cross-check: skipped (no local factory ZIP found)"
    fi

    # Trim leading space.
    do_not_flash="${do_not_flash# }"

    _reg_set avb HOM_ARB_BL_COMPARE                  "$bl_cmp"
    _reg_set avb HOM_ARB_BB_COMPARE                  "$bb_cmp"
    _reg_set avb HOM_ARB_BOOTLOADER_DOWNGRADE        "$bootloader_downgrade"
    _reg_set avb HOM_ARB_BOOTLOADER_UPGRADE_WILL_FUSE "$bootloader_upgrade_will_fuse"
    _reg_set avb HOM_ARB_BASEBAND_DOWNGRADE          "$baseband_downgrade"
    _reg_set avb HOM_ARB_DO_NOT_FLASH                "$do_not_flash"

    log_var "HOM_ARB_BL_COMPARE"                   "$bl_cmp"                    "factory bootloader vs device (older|newer|equal|unknown)"
    log_var "HOM_ARB_BB_COMPARE"                   "$bb_cmp"                    "factory baseband vs device (older|newer|equal|unknown)"
    log_var "HOM_ARB_BOOTLOADER_DOWNGRADE"         "$bootloader_downgrade"      "true if factory ZIP would downgrade bootloader (BRICK RISK on Tensor)"
    log_var "HOM_ARB_BOOTLOADER_UPGRADE_WILL_FUSE" "$bootloader_upgrade_will_fuse" "true if factory ZIP would bump bootloader ARB fuses (irreversible)"
    log_var "HOM_ARB_BASEBAND_DOWNGRADE"           "$baseband_downgrade"        "true if factory ZIP would downgrade radio (BRICK RISK on Tensor)"
    log_var "HOM_ARB_DO_NOT_FLASH"                 "$do_not_flash"              "space-separated list of partitions downstream tooling MUST refuse to flash"

    # Loud warnings — only escalate to abort on Tensor (where the
    # XDA-documented brick is real); on other devices we still warn
    # but allow the user to proceed.
    if [ "$bootloader_downgrade" = "true" ] || [ "$baseband_downgrade" = "true" ]; then
        ux_print ""
        ux_print "  ╔════════════════════════════════════════════════════════════╗"
        ux_print "  ║  PERMANENT BRICK RISK — bootloader/radio DOWNGRADE         ║"
        ux_print "  ╠════════════════════════════════════════════════════════════╣"
        ux_print "  ║  The local factory ZIP would write OLDER bootloader/radio  ║"
        ux_print "  ║  than what is currently fused on this device:              ║"
        [ "$bootloader_downgrade" = "true" ] && \
            ux_print "  ║    bootloader: device='${dev_bl}' factory='${fact_bl}'"
        [ "$baseband_downgrade" = "true" ] && \
            ux_print "  ║    radio    : device='${dev_bb}' factory='${fact_bb}'"
        ux_print "  ║                                                            ║"
        ux_print "  ║  On Tensor Pixels (6/6 Pro/6a/8/8 Pro/8a) the May-2025+    ║"
        ux_print "  ║  ARB fuse bump makes this UNRECOVERABLE — the device       ║"
        ux_print "  ║  will refuse to boot and Google has no recovery path.      ║"
        ux_print "  ║  Reference: XDA thread 4735780                             ║"
        ux_print "  ║                                                            ║"
        ux_print "  ║  SAFE PARTITIONS to flash from this ZIP (skip the rest):   ║"
        ux_print "  ║    boot, init_boot, vendor_boot, dtbo, vbmeta,             ║"
        ux_print "  ║    system, system_ext, product, vendor, vendor_dlkm,       ║"
        ux_print "  ║    odm, odm_dlkm                                           ║"
        ux_print "  ║                                                            ║"
        ux_print "  ║  DO NOT FLASH:  ${do_not_flash}"
        ux_print "  ╚════════════════════════════════════════════════════════════╝"
        ux_print ""
        if [ "$tensor_affected" = "true" ]; then
            ux_step_result "Anti-Rollback Check" "FAIL" \
                "bootloader/radio downgrade would brick a Tensor Pixel (XDA 4735780)"
            manifest_step "anti_rollback_check" "FAIL" \
                "tensor_arb_brick_risk do_not_flash=$do_not_flash"
            ux_abort "Refusing to proceed: this would PERMANENTLY brick the device. Use a factory ZIP whose bootloader/radio versions match (or are newer than) the device, or flash only the safe partitions listed above."
        else
            ux_print "  (Device not flagged as Tensor — continuing, but you have been warned.)"
        fi
    elif [ "$bootloader_upgrade_will_fuse" = "true" ] && [ "$tensor_affected" = "true" ]; then
        ux_print ""
        ux_print "  ⚠  This factory ZIP will UPGRADE the bootloader on a Tensor"
        ux_print "     Pixel.  Once the new bootloader boots, the anti-rollback"
        ux_print "     fuses are bumped IRREVERSIBLY.  After that you must never"
        ux_print "     flash an older bootloader/radio (e.g. an older factory"
        ux_print "     image), or the device will be permanently bricked."
        ux_print ""
    fi

    # ── 7. Final verdict ─────────────────────────────────────

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
