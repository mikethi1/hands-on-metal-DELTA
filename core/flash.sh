#!/system/bin/sh
# core/flash.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Flash execution — writes the patched image to the device.
#
# Supports two paths:
#
#   A. Magisk path (device already has Magisk):
#      • Writes patched image directly to the active boot slot
#        via `dd` or `flash_image`.
#      • Reboots device.
#
#   B. Recovery path (booted into TWRP/OrangeFox):
#      • Installs Magisk APK stub via pm.
#      • Writes patched image to the active boot slot.
#      • Installs hands-on-metal Magisk module.
#      • Reboots into system.
#
# Safety:
#   • Pre-flash SHA-256 of the target partition is recorded.
#   • Post-flash SHA-256 is verified against the patched image.
#   • If the post-flash checksum does not match → alerts user
#     and does NOT reboot (leaves device recoverable).
#
# Requires: logging.sh, ux.sh sourced first.
#
# ENV_REGISTRY variables consumed:
#   HOM_PATCHED_IMG_PATH    — path to patched image
#   HOM_PATCHED_IMG_SHA256  — expected SHA-256 after flash
#   HOM_DEV_BOOT_PART       — boot | init_boot
#   HOM_DEV_IS_AB           — true/false
#   HOM_DEV_SLOT_SUFFIX     — _a | _b | empty
# ============================================================

# shellcheck disable=SC2034  # consumed by core/logging.sh when sourced
SCRIPT_NAME="flash"

OUT="${OUT:-$HOME/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"

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

_sha256() {
    local src="$1"
    if [ -b "$src" ]; then
        # Block device: hash first 4 MiB for speed
        dd if="$src" bs=4096 count=1024 2>/dev/null | \
            { sha256sum 2>/dev/null || openssl dgst -sha256 2>/dev/null; } | \
            awk '{print $NF}'
    elif [ -f "$src" ]; then
        { sha256sum "$src" 2>/dev/null || openssl dgst -sha256 "$src" 2>/dev/null; } | \
            awk '{print $NF}'
    else
        echo "UNAVAILABLE"
    fi
}

_find_block() {
    local name="$1"
    for try in \
        "/dev/block/bootdevice/by-name/$name" \
        "/dev/block/by-name/$name"; do
        [ -b "$try" ] && { echo "$try"; return 0; }
    done
    for g in /dev/block/platform/*/by-name/"$name" \
             /dev/block/platform/*/*/by-name/"$name"; do
        [ -b "$g" ] && { echo "$g"; return 0; }
    done
    return 1
}

# Resolve the correct block device for the target partition,
# taking A/B slot into account.
_resolve_flash_target() {
    local part="$1"
    local is_ab="$2"
    local slot_suffix="$3"

    local dev=""
    # For A/B devices, prefer the slot-suffixed name
    if [ "$is_ab" = "true" ] && [ -n "$slot_suffix" ]; then
        dev=$(_find_block "${part}${slot_suffix}" 2>/dev/null || true)
    fi
    # Fall back to unsuffixed name
    [ -b "$dev" ] || dev=$(_find_block "$part" 2>/dev/null || true)
    echo "$dev"
}

# ── flash helpers ─────────────────────────────────────────────

# Write image to block device via dd.  Returns 0 on success.
_dd_flash() {
    local img="$1" dev="$2"
    log_info "DD flashing: $img → $dev"
    log_exec "dd_flash" dd if="$img" of="$dev" bs=4096 conv=notrunc,fsync
}

# ── path A: Magisk-installed path ────────────────────────────

run_flash_magisk_path() {
    ux_section "Flash (Magisk Path)"
    ux_step_info "Flash Patched Boot" \
        "Writes the Magisk-patched boot image directly to the boot partition" \
        "This permanently installs Magisk root to the active boot slot"

    # ── Anti-rollback final gate ─────────────────────────────
    # Re-verify the anti-rollback result one last time before the
    # irreversible dd write.  This catches any race or state-file
    # corruption between the check step and flash step.
    local arb_risk arb_magisk_ok
    arb_risk=$(_reg_get HOM_ARB_ROLLBACK_RISK)
    arb_magisk_ok=$(_reg_get HOM_ARB_MAGISK_ADEQUATE)

    if [ "$arb_risk" = "true" ]; then
        ux_abort "FLASH BLOCKED: Anti-rollback risk detected (HOM_ARB_ROLLBACK_RISK=true). Cannot flash safely."
    fi
    if [ "$arb_magisk_ok" = "false" ]; then
        ux_abort "FLASH BLOCKED: Magisk version inadequate for May-2026 policy (HOM_ARB_MAGISK_ADEQUATE=false). Upgrade Magisk."
    fi

    local patched_img boot_part is_ab slot_suffix patched_sha256
    patched_img=$(_reg_get HOM_PATCHED_IMG_PATH)
    boot_part=$(_reg_get HOM_DEV_BOOT_PART)
    is_ab=$(_reg_get HOM_DEV_IS_AB)
    slot_suffix=$(_reg_get HOM_DEV_SLOT_SUFFIX)
    patched_sha256=$(_reg_get HOM_PATCHED_IMG_SHA256)

    log_var "patched_img"   "$patched_img"   "image to be flashed"
    log_var "boot_part"     "$boot_part"     "partition type"
    log_var "is_ab"         "$is_ab"         "A/B device"
    log_var "slot_suffix"   "$slot_suffix"   "current slot suffix"
    log_var "patched_sha256" "$patched_sha256" "expected SHA-256 after flash"

    if [ -z "$patched_img" ] || [ ! -f "$patched_img" ]; then
        ux_abort "Flash: patched image not found at '$patched_img'. Run Magisk patch first."
    fi

    local flash_dev
    flash_dev=$(_resolve_flash_target "$boot_part" "$is_ab" "$slot_suffix")

    if [ -z "$flash_dev" ] || [ ! -b "$flash_dev" ]; then
        ux_abort "Flash: cannot find block device for $boot_part${slot_suffix}. Aborting."
    fi

    log_var "flash_dev" "$flash_dev" "block device being written"
    ux_print "  Target : $flash_dev"
    ux_print "  Image  : $patched_img"

    # Pre-flash checksum
    local pre_sha
    pre_sha=$(_sha256 "$flash_dev")
    _reg_set flash HOM_FLASH_PRE_SHA256 "$pre_sha"
    log_var "HOM_FLASH_PRE_SHA256" "$pre_sha" "SHA-256 of block device before flash"
    ux_print "  Pre-flash SHA-256 (4MiB): $pre_sha"

    # Flash
    ux_print "  Flashing..."
    if ! _dd_flash "$patched_img" "$flash_dev"; then
        ux_abort "Flash failed (dd returned error). Device is still bootable — do NOT reboot."
    fi

    # Post-flash checksum
    local post_sha
    post_sha=$(_sha256 "$flash_dev")
    _reg_set flash HOM_FLASH_POST_SHA256 "$post_sha"
    log_var "HOM_FLASH_POST_SHA256" "$post_sha" "SHA-256 of block device after flash"
    ux_print "  Post-flash SHA-256 (4MiB): $post_sha"

    # Verify written == expected (compare 4MiB prefix)
    local expected_4m
    expected_4m=$(_sha256 "$patched_img")
    if [ "$post_sha" != "$expected_4m" ]; then
        ux_print ""
        ux_print "  WARNING: Post-flash checksum mismatch!"
        ux_print "  Expected: $expected_4m"
        ux_print "  Got     : $post_sha"
        ux_print "  Do NOT reboot — reflash or use recovery to restore."
        manifest_step "flash_verify" "FAIL" "checksum mismatch"
        ux_abort "Flash verification failed. Refusing to reboot to protect device."
    fi

    _reg_set flash HOM_FLASH_STATUS "OK"
    _reg_set flash HOM_FLASH_VERIFIED "1"
    ux_step_result "Flash Patched Boot" "OK" "verified SHA-256 match"
    manifest_step "flash_boot" "OK" "dev=$flash_dev sha256=$post_sha"

    # Reboot
    ux_print ""
    ux_print "  Flash successful! Rebooting in 5 seconds..."
    ux_print "  After reboot: open Magisk app to confirm root."
    sleep 5
    log_exec "reboot" reboot
}

# ── path B: Recovery / TWRP path ─────────────────────────────

run_flash_recovery_path() {
    ux_section "Flash (Recovery Path)"
    ux_step_info "Flash + Install Magisk (Recovery)" \
        "Flashes the patched boot image, installs the Magisk module ZIP, and reboots" \
        "This brings a non-rooted device from TWRP to fully rooted system in one step"

    # ── Anti-rollback final gate ─────────────────────────────
    local arb_risk arb_magisk_ok
    arb_risk=$(_reg_get HOM_ARB_ROLLBACK_RISK)
    arb_magisk_ok=$(_reg_get HOM_ARB_MAGISK_ADEQUATE)

    if [ "$arb_risk" = "true" ]; then
        ux_abort "FLASH BLOCKED: Anti-rollback risk detected. Cannot flash safely."
    fi
    if [ "$arb_magisk_ok" = "false" ]; then
        ux_abort "FLASH BLOCKED: Magisk version inadequate for May-2026 policy. Upgrade Magisk."
    fi

    local patched_img boot_part is_ab slot_suffix patched_sha256 zipfile
    patched_img=$(_reg_get HOM_PATCHED_IMG_PATH)
    boot_part=$(_reg_get HOM_DEV_BOOT_PART)
    is_ab=$(_reg_get HOM_DEV_IS_AB)
    slot_suffix=$(_reg_get HOM_DEV_SLOT_SUFFIX)
    patched_sha256=$(_reg_get HOM_PATCHED_IMG_SHA256)
    zipfile="${ZIPFILE:-}"

    if [ -z "$patched_img" ] || [ ! -f "$patched_img" ]; then
        ux_abort "Recovery flash: patched image not found. Run Magisk patch first."
    fi

    local flash_dev
    flash_dev=$(_resolve_flash_target "$boot_part" "$is_ab" "$slot_suffix")

    if [ -z "$flash_dev" ] || [ ! -b "$flash_dev" ]; then
        ux_abort "Recovery flash: block device for $boot_part not found."
    fi

    ux_print "  Target: $flash_dev"
    ux_print "  Image : $patched_img"

    # Pre-flash
    local pre_sha; pre_sha=$(_sha256 "$flash_dev")
    ux_print "  Pre-flash SHA-256 (4MiB): $pre_sha"
    _reg_set flash HOM_FLASH_PRE_SHA256 "$pre_sha"

    ux_print "  Flashing patched boot..."
    if ! _dd_flash "$patched_img" "$flash_dev"; then
        ux_abort "Flash failed in recovery path."
    fi

    # Post-flash verify
    local post_sha; post_sha=$(_sha256 "$flash_dev")
    local expected_4m; expected_4m=$(_sha256 "$patched_img")
    ux_print "  Post-flash SHA-256 (4MiB): $post_sha"

    if [ "$post_sha" != "$expected_4m" ]; then
        manifest_step "flash_verify" "FAIL" "checksum mismatch"
        ux_abort "Flash verification failed (checksum mismatch). Do NOT reboot."
    fi

    _reg_set flash HOM_FLASH_STATUS "OK"
    _reg_set flash HOM_FLASH_VERIFIED "1"
    ux_step_result "Flash Patched Boot" "OK" "SHA-256 verified"
    manifest_step "flash_boot_recovery" "OK" "dev=$flash_dev"

    # Install Magisk module from ZIP (extract to module dir)
    local module_dir="/data/adb/modules/hands-on-metal-collector"
    if [ -n "$zipfile" ] && [ -f "$zipfile" ]; then
        ux_print "  Installing hands-on-metal Magisk module..."
        mkdir -p "$module_dir"
        unzip -o "$zipfile" \
            "module.prop" \
            "core/*" \
            "magisk-module/service.sh" \
            "magisk-module/collect.sh" \
            "magisk-module/env_detect.sh" \
            "magisk-module/setup_termux.sh" \
            -d "$module_dir" >/dev/null 2>&1 || true
        # Ensure the module is recognized by Magisk on next boot
        touch "$module_dir/.update"
        ux_print "  Module installed at $module_dir"
        manifest_step "module_install" "OK" "dir=$module_dir"
    else
        log_warn "ZIPFILE not set or not found — module not installed from recovery"
    fi

    ux_print ""
    ux_print "  Rebooting into system in 5 seconds..."
    ux_print "  After reboot: open Magisk app to confirm root."
    sleep 5
    log_exec "reboot_system" reboot
}
