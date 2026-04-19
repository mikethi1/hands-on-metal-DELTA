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
#   $ENV_REGISTRY  (~/hands-on-metal/env_registry.sh)
#
# Requires: logging.sh, ux.sh sourced first.
# ============================================================

# shellcheck disable=SC2034  # consumed by core/logging.sh when sourced
SCRIPT_NAME="device_profile"

OUT="${OUT:-$HOME/hands-on-metal}"
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
    local slot="${HOM_DEV_SLOT_SUFFIX:-$(_prop ro.boot.slot_suffix)}"
    # Try names in priority order: with slot suffix first (A/B devices
    # only have <name>_a/<name>_b symlinks, no plain <name>), then the
    # bare name (A-only devices).
    local n
    for n in "${name}${slot}" "$name"; do
        [ -n "$n" ] || continue
        for try in \
            "/dev/block/bootdevice/by-name/$n" \
            "/dev/block/by-name/$n"; do
            [ -b "$try" ] && { echo "$try"; return 0; }
        done
        for g in /dev/block/platform/*/by-name/"$n" \
                 /dev/block/platform/*/*/by-name/"$n"; do
            [ -b "$g" ] && { echo "$g"; return 0; }
        done
    done
    return 1
}

# ── factory-image helpers ─────────────────────────────────────
#
# Optional cross-check: if the user already downloaded the Google
# factory ZIP for this build (e.g. via "boot_image.sh" or by hand)
# and dropped it in ~/Downloads, peek inside it to *confirm* the
# partition layout and pick up extra metadata (board, required
# bootloader / baseband versions).  Filename convention is the same
# one used by core/boot_image.sh:
#   ${codename}-${build_id_lower}-factory*.zip   (e.g.
#   husky-cp1a.260305.018-factory-abcd1234.zip)
#
# These helpers degrade silently when no zip is found or `unzip` is
# not installed — the rest of the profile is still produced.

_dp_default_downloads_dir() {
    if [ -n "${HOME:-}" ] && [ -d "$HOME/storage/downloads" ]; then
        echo "$HOME/storage/downloads"
    elif [ -d "/sdcard/Download" ]; then
        echo "/sdcard/Download"
    elif [ -n "${HOME:-}" ] && [ -d "$HOME/Downloads" ]; then
        echo "$HOME/Downloads"
    else
        echo "/sdcard/Download"
    fi
}

_dp_find_factory_zip() {
    # $1 = codename (e.g. husky), $2 = build_id_lower (e.g. cp1a.260305.018)
    local cn="$1" bid="$2" dir cand
    dir=$(_dp_default_downloads_dir)
    [ -d "$dir" ] || return 1

    # 1. Exact match for this device + build.
    if [ -n "$cn" ] && [ -n "$bid" ]; then
        for cand in "$dir/${cn}-${bid}-factory"*.zip; do
            [ -f "$cand" ] && [ -s "$cand" ] && { echo "$cand"; return 0; }
        done
    fi
    # 2. Any factory ZIP for this codename (different build still useful).
    if [ -n "$cn" ]; then
        for cand in "$dir/${cn}-"*-factory*.zip; do
            [ -f "$cand" ] && [ -s "$cand" ] && { echo "$cand"; return 0; }
        done
    fi
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
    #
    # Without root (e.g. when the script runs from Termux on a locked
    # userdebug/user build) the /dev/block/by-name symlinks are not
    # readable, so _find_block returns nothing even when the partition
    # exists.  In that case we fall back to inference from
    # ro.product.first_api_level so the user isn't told "not found"
    # for partitions that the device demonstrably has.

    local boot_part="boot"
    local boot_part_source="default"
    local init_boot_dev vendor_boot_dev boot_dev
    local init_boot_source="block_device"
    local vendor_boot_source="block_device"
    local boot_dev_source="block_device"

    init_boot_dev=$(_find_block init_boot 2>/dev/null || true)
    vendor_boot_dev=$(_find_block vendor_boot 2>/dev/null || true)
    boot_dev=$(_find_block boot 2>/dev/null || true)

    # Helper: is first_api_level numeric and >= N ?
    _api_ge() {
        case "$api_level" in
            ''|*[!0-9]*) return 1 ;;
            *) [ "$api_level" -ge "$1" ] ;;
        esac
    }

    if [ -b "$init_boot_dev" ]; then
        boot_part="init_boot"
        boot_part_source="block_device"
    else
        # Devices that *launched* on Android 13 (API 33) or later
        # always ship with an init_boot partition and Magisk patches
        # init_boot on those devices.
        # See https://source.android.com/docs/core/architecture/partitions/generic-boot
        if _api_ge 33; then
            boot_part="init_boot"
            boot_part_source="first_api_level=$api_level"
            init_boot_source="inferred:first_api_level=$api_level"
            log_info "init_boot block device not visible (likely no root); inferring init_boot from first_api_level=$api_level"
        else
            init_boot_source="not_found"
        fi
    fi

    if [ ! -b "$vendor_boot_dev" ]; then
        # GKI devices launched on Android 12 (API 31) or later ship a
        # separate vendor_boot partition.  When we can't see the block
        # path we infer presence from first_api_level.
        if _api_ge 31; then
            vendor_boot_source="inferred:first_api_level=$api_level"
        else
            vendor_boot_source="not_found"
        fi
    fi

    [ -b "$boot_dev" ] || boot_dev_source="not_visible"

    # ── 8b. Cross-check against local factory ZIP if present ──
    # If the user already has the matching Google factory image in
    # ~/Downloads (same filename convention used by core/boot_image.sh:
    # "${codename}-${build_id_lower}-factory*.zip"), peek inside it to
    # turn the API-level *inference* of init_boot/vendor_boot into a
    # hard fact, and harvest extra metadata (board, required bootloader
    # / baseband versions) that getprop doesn't expose without root.

    local factory_zip="" factory_zip_match="none"
    local factory_board="" factory_req_bl="" factory_req_bb=""
    local build_id_lower=""
    if [ -n "$build_id" ]; then
        # POSIX-portable lowercase via tr (mksh/ash both have it).
        build_id_lower=$(printf '%s' "$build_id" | tr '[:upper:]' '[:lower:]')
    fi

    factory_zip=$(_dp_find_factory_zip "$device" "$build_id_lower" 2>/dev/null || true)
    if [ -n "$factory_zip" ] && [ -f "$factory_zip" ]; then
        case "$factory_zip" in
            *"/${device}-${build_id_lower}-factory"*) factory_zip_match="exact_build" ;;
            *)                                        factory_zip_match="codename_only" ;;
        esac
        log_info "Local factory ZIP detected: $factory_zip ($factory_zip_match)"

        if command -v unzip >/dev/null 2>&1; then
            local _dp_tmp
            _dp_tmp=$(mktemp -d 2>/dev/null || echo "$OUT/_dp_factory_$$")
            mkdir -p "$_dp_tmp" 2>/dev/null || true

            # List the outer ZIP once.  Google factory ZIPs nest as:
            #   <codename>-<build>/image-<codename>-<build>.zip
            #   <codename>-<build>/bootloader-<codename>-*.img
            #   <codename>-<build>/radio-<codename>-*.img
            local _outer_list="$_dp_tmp/outer.list"
            unzip -l "$factory_zip" > "$_outer_list" 2>/dev/null || : > "$_outer_list"

            local inner_rel
            inner_rel=$(grep -o "[^ ]*image-${device}-[^ ]*\\.zip" "$_outer_list" | head -1)
            [ -z "$inner_rel" ] && inner_rel=$(grep -o '[^ ]*image-[^ ]*\.zip' "$_outer_list" | head -1)

            local _inner_list=""
            if [ -n "$inner_rel" ]; then
                # Extract just the inner ZIP into temp; needed because
                # `unzip -l` requires a seekable file.
                if unzip -p "$factory_zip" "$inner_rel" > "$_dp_tmp/inner.zip" 2>/dev/null \
                   && [ -s "$_dp_tmp/inner.zip" ]; then
                    _inner_list="$_dp_tmp/inner.list"
                    unzip -l "$_dp_tmp/inner.zip" > "$_inner_list" 2>/dev/null || _inner_list=""
                fi
            fi

            # Confirm partition presence from the inner image-*.zip listing.
            # `unzip -l` indents filenames with spaces, so the prefix we
            # accept before the filename is "start-of-line | space | /".
            if [ -n "$_inner_list" ] && [ -s "$_inner_list" ]; then
                local _ftag
                _ftag="factory_zip:$(basename "$factory_zip")"
                local _has_boot=0 _has_init_boot=0 _has_vendor_boot=0
                grep -qE '(^| |/)boot\.img$'        "$_inner_list" && _has_boot=1
                grep -qE '(^| |/)init_boot\.img$'   "$_inner_list" && _has_init_boot=1
                grep -qE '(^| |/)vendor_boot\.img$' "$_inner_list" && _has_vendor_boot=1

                if [ "$_has_boot" -eq 1 ]; then
                    [ -b "$boot_dev" ] || boot_dev_source="$_ftag"
                fi
                if [ "$_has_init_boot" -eq 1 ]; then
                    [ -b "$init_boot_dev" ] || init_boot_source="$_ftag"
                    # Promote boot_part decision from API-level inference to fact.
                    case "$boot_part_source" in
                        first_api_level=*|default)
                            boot_part="init_boot"
                            boot_part_source="$_ftag"
                            ;;
                    esac
                else
                    # init_boot.img not in the factory ZIP.  On GKI devices
                    # that launched before API 33 (Pixel 6 / Android 12)
                    # there is no separate init_boot partition — the init
                    # ramdisk is bundled inside vendor_boot.img as a
                    # ramdisk fragment, and Magisk patches boot.img on
                    # those devices.  Reflect that in the source tag and
                    # in the boot_part decision.
                    if [ "$_has_vendor_boot" -eq 1 ]; then
                        case "$init_boot_source" in
                            inferred:*|not_found|block_device)
                                init_boot_source="in_vendor_boot:$(basename "$factory_zip")"
                                ;;
                        esac
                        # If we previously *inferred* init_boot from
                        # first_api_level but the factory ZIP proves the
                        # device has no init_boot partition, fall back to
                        # patching boot.img.
                        case "$boot_part_source" in
                            first_api_level=*)
                                boot_part="boot"
                                boot_part_source="$_ftag(no init_boot)"
                                log_info "Factory ZIP has no init_boot image; init ramdisk is inside vendor_boot — patching boot instead"
                                ;;
                        esac
                    else
                        case "$init_boot_source" in
                            inferred:*|not_found) init_boot_source="absent_in_factory_zip" ;;
                        esac
                    fi
                fi
                if [ "$_has_vendor_boot" -eq 1 ]; then
                    [ -b "$vendor_boot_dev" ] || vendor_boot_source="$_ftag"
                else
                    case "$vendor_boot_source" in
                        inferred:*|not_found) vendor_boot_source="absent_in_factory_zip" ;;
                    esac
                fi

                # android-info.txt sits in the inner ZIP and carries
                # board + required-bootloader/baseband info.  Real
                # Google factory inner ZIPs keep it at the top level,
                # but we look it up via the listing so we tolerate any
                # internal prefix.
                local _ainfo_rel
                _ainfo_rel=$(grep -oE '[^ ]*android-info\.txt' "$_inner_list" | head -1)
                if [ -n "$_ainfo_rel" ] \
                   && unzip -p "$_dp_tmp/inner.zip" "$_ainfo_rel" \
                        > "$_dp_tmp/android-info.txt" 2>/dev/null \
                   && [ -s "$_dp_tmp/android-info.txt" ]; then
                    factory_board=$(awk -F= '/^board=/        {print $2; exit}' "$_dp_tmp/android-info.txt" | tr -d '\r')
                    factory_req_bl=$(awk -F= '/^require version-bootloader=/ {print $2; exit}' "$_dp_tmp/android-info.txt" | tr -d '\r')
                    factory_req_bb=$(awk -F= '/^require version-baseband=/   {print $2; exit}' "$_dp_tmp/android-info.txt" | tr -d '\r')
                fi
            fi

            rm -rf "$_dp_tmp" 2>/dev/null || true
        else
            log_info "Factory ZIP found but 'unzip' not installed; skipping cross-check"
        fi
    fi

    _reg_set device HOM_DEV_FACTORY_ZIP                  "${factory_zip:-}"
    _reg_set device HOM_DEV_FACTORY_ZIP_MATCH            "$factory_zip_match"
    _reg_set device HOM_DEV_FACTORY_BOARD                "$factory_board"
    _reg_set device HOM_DEV_FACTORY_REQUIRED_BOOTLOADER  "$factory_req_bl"
    _reg_set device HOM_DEV_FACTORY_REQUIRED_BASEBAND    "$factory_req_bb"
    log_var  "HOM_DEV_FACTORY_ZIP"                  "${factory_zip:-}"     "local Google factory ZIP path (if present in ~/Downloads)"
    log_var  "HOM_DEV_FACTORY_ZIP_MATCH"            "$factory_zip_match"   "exact_build | codename_only | none"
    log_var  "HOM_DEV_FACTORY_BOARD"                "$factory_board"       "board= from factory android-info.txt"
    log_var  "HOM_DEV_FACTORY_REQUIRED_BOOTLOADER"  "$factory_req_bl"      "required bootloader version from factory image"
    log_var  "HOM_DEV_FACTORY_REQUIRED_BASEBAND"    "$factory_req_bb"      "required baseband (radio) version from factory image"

    _reg_set device HOM_DEV_BOOT_PART              "$boot_part"
    _reg_set device HOM_DEV_BOOT_PART_SOURCE       "$boot_part_source"
    _reg_set device HOM_DEV_BOOT_DEV               "${boot_dev:-MISSING}"
    _reg_set device HOM_DEV_BOOT_DEV_SOURCE        "$boot_dev_source"
    _reg_set device HOM_DEV_INIT_BOOT_DEV          "${init_boot_dev:-MISSING}"
    _reg_set device HOM_DEV_INIT_BOOT_DEV_SOURCE   "$init_boot_source"
    _reg_set device HOM_DEV_VENDOR_BOOT_DEV        "${vendor_boot_dev:-MISSING}"
    _reg_set device HOM_DEV_VENDOR_BOOT_DEV_SOURCE "$vendor_boot_source"

    log_var "HOM_DEV_BOOT_PART"              "$boot_part"          "partition to patch with Magisk (boot or init_boot)"
    log_var "HOM_DEV_BOOT_PART_SOURCE"       "$boot_part_source"   "how HOM_DEV_BOOT_PART was determined (block_device | first_api_level=N | default)"
    log_var "HOM_DEV_BOOT_DEV"               "${boot_dev:-MISSING}" "block device path for boot partition"
    log_var "HOM_DEV_BOOT_DEV_SOURCE"        "$boot_dev_source"    "block_device | not_visible (no root)"
    log_var "HOM_DEV_INIT_BOOT_DEV"          "${init_boot_dev:-MISSING}" "block device path for init_boot partition"
    log_var "HOM_DEV_INIT_BOOT_DEV_SOURCE"   "$init_boot_source"   "block_device | inferred:first_api_level=N | not_found"
    log_var "HOM_DEV_VENDOR_BOOT_DEV"        "${vendor_boot_dev:-MISSING}" "block device path for vendor_boot partition"
    log_var "HOM_DEV_VENDOR_BOOT_DEV_SOURCE" "$vendor_boot_source" "block_device | inferred:first_api_level=N | not_found"

    # User-visible lines — distinguish "absent" from "present but
    # block path not readable", and surface factory-ZIP confirmation.
    _fmt_dev() {
        # $1 = device path (may be empty), $2 = source tag
        local dev="$1" src="$2"
        if [ -n "$dev" ]; then
            printf '%s' "$dev"
        else
            case "$src" in
                factory_zip:*)         printf 'present (confirmed by %s)' "${src#factory_zip:}" ;;
                in_vendor_boot:*)      printf 'inside vendor_boot — no separate init_boot partition (per %s)' "${src#in_vendor_boot:}" ;;
                inferred:*)            printf 'present (%s)' "$src" ;;
                absent_in_factory_zip) printf 'absent (per local factory ZIP)' ;;
                not_visible)           printf 'no root — block path not readable' ;;
                *)                     printf 'not found' ;;
            esac
        fi
    }

    ux_print "  Boot part  : $boot_part  (device: $(_fmt_dev "$boot_dev" "$boot_dev_source"))"
    ux_print "  init_boot  : $(_fmt_dev "$init_boot_dev" "$init_boot_source")"
    ux_print "  vendor_boot: $(_fmt_dev "$vendor_boot_dev" "$vendor_boot_source")"
    if [ -n "$factory_zip" ]; then
        ux_print "  Factory ZIP: $(basename "$factory_zip") ($factory_zip_match)"
        [ -n "$factory_board"  ] && ux_print "    board               : $factory_board"
        [ -n "$factory_req_bl" ] && ux_print "    required bootloader : $factory_req_bl"
        [ -n "$factory_req_bb" ] && ux_print "    required baseband   : $factory_req_bb"
    fi

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

    # ── 9b. Bootloader / radio versions + Tensor ARB flag ─────
    # Captured here so anti_rollback.sh can compare against any
    # local factory ZIP and warn about the May-2025 Tensor
    # bootloader/radio anti-rollback brick risk on Pixel 6/8 series.
    # See https://xdaforums.com/t/may-2025-and-newer-beware-of-permanent-bricks-…-pixel-6-6-pro-6a-8-8-pro-8a.4735780/

    local bootloader_ver baseband_ver
    bootloader_ver=$(_prop ro.bootloader)
    [ -z "$bootloader_ver" ] && bootloader_ver=$(_prop ro.boot.bootloader)
    baseband_ver=$(_prop ro.build.expect.baseband)
    [ -z "$baseband_ver" ] && baseband_ver=$(_prop gsm.version.baseband)

    local tensor_arb_affected="false"
    case "$device" in
        # Pixel 6 / 6 Pro / 6a — Tensor G1
        oriole|raven|bluejay) tensor_arb_affected="true" ;;
        # Pixel 8 / 8 Pro / 8a — Tensor G3
        # (Pixel 7 series / Tensor G2 were NOT covered by the
        # May-2025 ARB bump described in XDA thread 4735780.)
        shiba|husky|akita)    tensor_arb_affected="true" ;;
    esac

    _reg_set device HOM_DEV_BOOTLOADER          "$bootloader_ver"
    _reg_set device HOM_DEV_BASEBAND            "$baseband_ver"
    _reg_set device HOM_DEV_TENSOR_ARB_AFFECTED "$tensor_arb_affected"

    log_var "HOM_DEV_BOOTLOADER"          "$bootloader_ver"      "ro.bootloader (current bootloader version string)"
    log_var "HOM_DEV_BASEBAND"            "$baseband_ver"        "current baseband / radio version string"
    log_var "HOM_DEV_TENSOR_ARB_AFFECTED" "$tensor_arb_affected" "true on Tensor Pixels subject to bootloader/radio ARB fuse-bumps"

    ux_print "  Bootloader : ${bootloader_ver:-unknown}"
    ux_print "  Baseband   : ${baseband_ver:-unknown}"
    if [ "$tensor_arb_affected" = "true" ]; then
        ux_print "  ⚠  Tensor Pixel — bootloader/radio downgrades can permanently brick this device"
        ux_print "     (anti_rollback.sh will cross-check any local factory ZIP)"
    fi

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
        echo "Bootloader     : ${bootloader_ver:-unknown}"
        echo "Baseband       : ${baseband_ver:-unknown}"
        echo "Tensor ARB     : $tensor_arb_affected"
        echo "Boot partition : $boot_part  (source: $boot_part_source)"
        echo "  boot dev     : $(_fmt_dev "$boot_dev" "$boot_dev_source")"
        echo "  init_boot    : $(_fmt_dev "$init_boot_dev" "$init_boot_source")"
        echo "  vendor_boot  : $(_fmt_dev "$vendor_boot_dev" "$vendor_boot_source")"
        if [ -n "$factory_zip" ]; then
            echo "Factory ZIP    : $factory_zip"
            echo "  match        : $factory_zip_match"
            echo "  board        : ${factory_board:-(not parsed)}"
            echo "  req bootldr  : ${factory_req_bl:-(not parsed)}"
            echo "  req baseband : ${factory_req_bb:-(not parsed)}"
        else
            echo "Factory ZIP    : (none in $(_dp_default_downloads_dir))"
        fi
        echo "SoC            : $soc_mfr $soc_model ($platform / $hardware)"
    } > "$PROFILE_REPORT"

    ux_print ""
    ux_print "Profile saved to: $PROFILE_REPORT"
    ux_step_result "Device Profile" "OK" "partition to patch: $boot_part"
    manifest_step "device_profile" "OK" "boot_part=$boot_part spl=$spl ab=$is_ab"
}
