#!/system/bin/sh
# core/device_profile.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Device profiling — equivalent of Treble Check + environment
# detection in one unified pass.
#
# Probes and records:
#   • Model, manufacturer, device codename
#   • Android API level and security patch level
#   • A/B (seamless) update slots
#   • System-as-Root (SAR)
#   • Dynamic partitions (super)
#   • Treble compliance (ro.treble.enabled)
#   • Partition naming: boot vs init_boot vs vendor_boot
#   • AVB (Android Verified Boot) version and state
#   • Available boot partition block devices
#
# All results are written to:
#   $ENV_REGISTRY  (/sdcard/hands-on-metal/env_registry.sh)
#
# Requires: logging.sh, ux.sh sourced first.
# ============================================================

# shellcheck disable=SC2034  # consumed by core/logging.sh when sourced
SCRIPT_NAME="device_profile"

OUT="${OUT:-/sdcard/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
PROFILE_REPORT="$OUT/device_profile.txt"

# ── helpers ───────────────────────────────────────────────────

_prop() {
    getprop "$1" 2>/dev/null || true
}

_reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s profile:device\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
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

# ── main function ─────────────────────────────────────────────

run_device_profile() {
    ux_section "Device Profile"
    ux_step_info "Device Profile" \
        "Reads device properties, partition layout, AVB state, and Treble status" \
        "The rest of the workflow depends on knowing the exact device model, API level, \
partition naming, and boot security configuration"

    mkdir -p "$OUT"
    [ -f "$ENV_REGISTRY" ] || : > "$ENV_REGISTRY"
    : > "$PROFILE_REPORT"

    # ── 1. Identity ───────────────────────────────────────────

    local model brand device codename fingerprint
    model=$(_prop ro.product.model)
    brand=$(_prop ro.product.brand)
    device=$(_prop ro.product.device)
    codename=$(_prop ro.product.name)
    fingerprint=$(_prop ro.build.fingerprint)

    _reg_set device HOM_DEV_MODEL          "$model"
    _reg_set device HOM_DEV_BRAND          "$brand"
    _reg_set device HOM_DEV_DEVICE         "$device"
    _reg_set device HOM_DEV_CODENAME       "$codename"
    _reg_set device HOM_DEV_FINGERPRINT    "$fingerprint"

    log_var "HOM_DEV_MODEL"       "$model"       "device marketing name"
    log_var "HOM_DEV_BRAND"       "$brand"       "manufacturer brand"
    log_var "HOM_DEV_DEVICE"      "$device"      "device codename (board)"
    log_var "HOM_DEV_CODENAME"    "$codename"    "product name"
    log_var "HOM_DEV_FINGERPRINT" "$fingerprint" "build fingerprint"

    ux_print "  Model      : $brand $model ($device)"
    ux_print "  Fingerprint: $fingerprint"

    # ── 2. Android version + security patch ──────────────────

    local api_level spl release sdk_int build_id
    api_level=$(_prop ro.product.first_api_level)
    sdk_int=$(_prop ro.build.version.sdk)
    release=$(_prop ro.build.version.release)
    spl=$(_prop ro.build.version.security_patch)
    build_id=$(_prop ro.build.id)

    _reg_set device HOM_DEV_FIRST_API_LEVEL "$api_level"
    _reg_set device HOM_DEV_SDK_INT         "$sdk_int"
    _reg_set device HOM_DEV_ANDROID_VER     "$release"
    _reg_set device HOM_DEV_SPL             "$spl"
    _reg_set device HOM_DEV_BUILD_ID        "$build_id"

    log_var "HOM_DEV_FIRST_API_LEVEL" "$api_level" "API level device shipped with (first_api_level)"
    log_var "HOM_DEV_SDK_INT"         "$sdk_int"   "current SDK integer"
    log_var "HOM_DEV_ANDROID_VER"     "$release"   "Android version string"
    log_var "HOM_DEV_SPL"             "$spl"       "security patch level (YYYY-MM-DD)"
    log_var "HOM_DEV_BUILD_ID"        "$build_id"  "build ID (e.g. AP4A.250405.002)"

    ux_print "  Android    : $release  (API $sdk_int, first: $api_level)"
    ux_print "  Build ID   : $build_id"
    ux_print "  Patch level: $spl"

    # ── 3. A/B slots ─────────────────────────────────────────

    local ab_update slot_suffix current_slot
    ab_update=$(_prop ro.build.ab_update)
    slot_suffix=$(_prop ro.boot.slot_suffix)
    current_slot="${slot_suffix:-none}"

    local is_ab="false"
    [ "$ab_update" = "true" ] && is_ab="true"

    _reg_set device HOM_DEV_IS_AB        "$is_ab"
    _reg_set device HOM_DEV_SLOT_SUFFIX  "$slot_suffix"
    _reg_set device HOM_DEV_CURRENT_SLOT "$current_slot"

    log_var "HOM_DEV_IS_AB"        "$is_ab"        "true if device uses A/B (seamless) updates"
    log_var "HOM_DEV_SLOT_SUFFIX"  "$slot_suffix"  "current slot suffix (_a or _b)"
    log_var "HOM_DEV_CURRENT_SLOT" "$current_slot" "human-readable current slot"

    ux_print "  A/B updates: $is_ab  (current slot: $current_slot)"

    # ── 4. System-as-Root (SAR) ───────────────────────────────

    local sar="false"
    if [ "$(_prop ro.build.system_root_image)" = "true" ]; then
        sar="true"
    elif getprop ro.apex.updatable 2>/dev/null | grep -q "true"; then
        # API 29+ with APEX implies SAR
        sar="likely"
    fi
    _reg_set device HOM_DEV_SAR "$sar"
    log_var "HOM_DEV_SAR" "$sar" "System-as-Root enabled"
    ux_print "  SAR        : $sar"

    # ── 5. Dynamic partitions ─────────────────────────────────

    local dyn_parts="false"
    if _find_block super >/dev/null 2>&1; then
        dyn_parts="true"
    fi
    local dyn_prop
    dyn_prop=$(_prop ro.boot.dynamic_partitions)
    [ "$dyn_prop" = "true" ] && dyn_parts="true"

    _reg_set device HOM_DEV_DYNAMIC_PARTITIONS "$dyn_parts"
    log_var "HOM_DEV_DYNAMIC_PARTITIONS" "$dyn_parts" "device uses dynamic/super partitions"
    ux_print "  Dynamic ptns: $dyn_parts"

    # ── 6. Treble compliance ──────────────────────────────────

    local treble_enabled treble_vintf_version
    treble_enabled=$(_prop ro.treble.enabled)
    treble_vintf_version=$(_prop ro.vndk.version)

    _reg_set device HOM_DEV_TREBLE_ENABLED     "$treble_enabled"
    _reg_set device HOM_DEV_TREBLE_VINTF_VER   "$treble_vintf_version"

    log_var "HOM_DEV_TREBLE_ENABLED"   "$treble_enabled"   "Project Treble compliance flag"
    log_var "HOM_DEV_TREBLE_VINTF_VER" "$treble_vintf_version" "VNDK/VINTF version"

    ux_print "  Treble     : $treble_enabled  (VNDK: $treble_vintf_version)"

    # ── 7. AVB (Android Verified Boot) ───────────────────────

    local avb_version avb_state avb_algo
    avb_version=$(_prop ro.boot.avb_version)
    avb_state=$(_prop ro.boot.verifiedbootstate)
    avb_algo=$(_prop ro.boot.vbmeta.avb_version)

    _reg_set device HOM_DEV_AVB_VERSION "$avb_version"
    _reg_set device HOM_DEV_AVB_STATE   "$avb_state"
    _reg_set device HOM_DEV_AVB_ALGO    "$avb_algo"

    log_var "HOM_DEV_AVB_VERSION" "$avb_version" "AVB version reported by bootloader"
    log_var "HOM_DEV_AVB_STATE"   "$avb_state"   "verified boot state (green/yellow/orange/red)"
    log_var "HOM_DEV_AVB_ALGO"    "$avb_algo"    "AVB algorithm from vbmeta"

    ux_print "  AVB        : v$avb_version  state=$avb_state"

    # ── 8. Partition naming — which boot image to patch ───────
    # Priority: init_boot (API 33+) > boot
    # vendor_boot is always separate; we note it but don't patch it.

    local boot_part="boot"
    local boot_part_source="default"
    local init_boot_dev vendor_boot_dev boot_dev

    init_boot_dev=$(_find_block init_boot 2>/dev/null || true)
    vendor_boot_dev=$(_find_block vendor_boot 2>/dev/null || true)
    boot_dev=$(_find_block boot 2>/dev/null || true)

    if [ -b "$init_boot_dev" ]; then
        boot_part="init_boot"
        boot_part_source="block_device"
    else
        # Fallback: without root the by-name block paths are not
        # readable (e.g. Termux), so _find_block can't see init_boot
        # even when the device has it.  Devices that *launched* on
        # Android 13 (API 33) or later always ship with an init_boot
        # partition and Magisk patches init_boot on those devices.
        # See https://source.android.com/docs/core/architecture/partitions/generic-boot
        case "$api_level" in
            ''|*[!0-9]*) : ;;  # unknown / non-numeric → keep default
            *)
                if [ "$api_level" -ge 33 ]; then
                    boot_part="init_boot"
                    boot_part_source="first_api_level=$api_level"
                    log_info "init_boot block device not visible (likely no root); inferring init_boot from first_api_level=$api_level"
                fi
                ;;
        esac
    fi

    _reg_set device HOM_DEV_BOOT_PART        "$boot_part"
    _reg_set device HOM_DEV_BOOT_PART_SOURCE "$boot_part_source"
    _reg_set device HOM_DEV_BOOT_DEV         "${boot_dev:-MISSING}"
    _reg_set device HOM_DEV_INIT_BOOT_DEV    "${init_boot_dev:-MISSING}"
    _reg_set device HOM_DEV_VENDOR_BOOT_DEV  "${vendor_boot_dev:-MISSING}"

    log_var "HOM_DEV_BOOT_PART"        "$boot_part"          "partition to patch with Magisk (boot or init_boot)"
    log_var "HOM_DEV_BOOT_PART_SOURCE" "$boot_part_source"   "how HOM_DEV_BOOT_PART was determined (block_device | first_api_level=N | default)"
    log_var "HOM_DEV_BOOT_DEV"         "${boot_dev:-MISSING}" "block device path for boot partition"
    log_var "HOM_DEV_INIT_BOOT_DEV"    "${init_boot_dev:-MISSING}" "block device path for init_boot partition"
    log_var "HOM_DEV_VENDOR_BOOT_DEV"  "${vendor_boot_dev:-MISSING}" "block device path for vendor_boot partition"

    ux_print "  Boot part  : $boot_part  (device: ${boot_dev:-not found})"
    ux_print "  init_boot  : ${init_boot_dev:-not found}"
    ux_print "  vendor_boot: ${vendor_boot_dev:-not found}"

    # ── 9. SoC / chipset identity ─────────────────────────────

    local soc_mfr soc_model platform hardware
    soc_mfr=$(_prop ro.soc.manufacturer)
    soc_model=$(_prop ro.soc.model)
    platform=$(_prop ro.board.platform)
    hardware=$(_prop ro.hardware)

    _reg_set device HOM_DEV_SOC_MFR   "$soc_mfr"
    _reg_set device HOM_DEV_SOC_MODEL "$soc_model"
    _reg_set device HOM_DEV_PLATFORM  "$platform"
    _reg_set device HOM_DEV_HARDWARE  "$hardware"

    log_var "HOM_DEV_SOC_MFR"   "$soc_mfr"   "SoC manufacturer (Qualcomm/MediaTek/Google/Samsung)"
    log_var "HOM_DEV_SOC_MODEL" "$soc_model" "SoC model number"
    log_var "HOM_DEV_PLATFORM"  "$platform"  "ro.board.platform (e.g. msm8998)"
    log_var "HOM_DEV_HARDWARE"  "$hardware"  "ro.hardware"

    ux_print "  SoC        : $soc_mfr $soc_model ($platform)"

    # ── 10. Write human-readable profile report ───────────────

    {
        echo "=== Device Profile Report ==="
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "Model          : $brand $model ($device)"
        echo "Fingerprint    : $fingerprint"
        echo "Android        : $release (API $sdk_int, first=$api_level)"
        echo "Build ID       : $build_id"
        echo "Security Patch : $spl"
        echo "A/B slots      : $is_ab (slot: $current_slot)"
        echo "SAR            : $sar"
        echo "Dynamic parts  : $dyn_parts"
        echo "Treble         : $treble_enabled (VNDK $treble_vintf_version)"
        echo "AVB            : v$avb_version state=$avb_state"
        echo "Boot partition : $boot_part"
        echo "  boot dev     : ${boot_dev:-NOT FOUND}"
        echo "  init_boot    : ${init_boot_dev:-NOT FOUND}"
        echo "  vendor_boot  : ${vendor_boot_dev:-NOT FOUND}"
        echo "SoC            : $soc_mfr $soc_model ($platform / $hardware)"
    } > "$PROFILE_REPORT"

    ux_print ""
    ux_print "Profile saved to: $PROFILE_REPORT"
    ux_step_result "Device Profile" "OK" "partition to patch: $boot_part"
    manifest_step "device_profile" "OK" "boot_part=$boot_part spl=$spl ab=$is_ab"
}
