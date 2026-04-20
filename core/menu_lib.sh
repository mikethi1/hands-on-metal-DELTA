#!/usr/bin/env bash
# core/menu_lib.sh
# ============================================================
# hands-on-metal — Shared Menu Library
#
# Sourced by terminal_menu.sh (Phase 1-4) and pipeline_menu.sh
# (Phase 5-8).  Each menu script defines:
#
#   HOM_MENU_TITLE      — title shown in the header box
#   HOM_OTHER_MENU      — path to the companion menu script
#   build_script_index  — function populating SCRIPT_LABELS /
#                         SCRIPT_PATHS / SCRIPT_TYPES for its
#                         own phase range
#
# Everything else — prerequisite checking, fancy display,
# run logic, completion messages — lives here.
# ============================================================

# ── ANSI color / style codes ─────────────────────────────────
CLR_LIGHT_GREEN=$'\033[92m'
CLR_DARK_GREEN=$'\033[32m'
CLR_YELLOW=$'\033[33m'
CLR_CYAN=$'\033[96m'
CLR_BOLD=$'\033[1m'
CLR_DIM=$'\033[2m'
CLR_RESET=$'\033[0m'

if [ ! -t 1 ]; then
    CLR_LIGHT_GREEN="" CLR_DARK_GREEN="" CLR_YELLOW=""
    CLR_CYAN="" CLR_BOLD="" CLR_DIM="" CLR_RESET=""
fi

# ── Repeat a character N times ────────────────────────────────
_repeat_char() {
    local char="$1" count="$2" out="" i=0
    while [ "$i" -lt "$count" ]; do
        out="${out}${char}"
        i=$(( i + 1 ))
    done
    printf '%s' "$out"
}

# ── Load env registry ─────────────────────────────────────────
_HOM_ENV_REGISTRY="${ENV_REGISTRY:-$HOME/hands-on-metal/env_registry.sh}"
load_env_registry() {
    local _reg="${ENV_REGISTRY:-${OUT:-$HOME/hands-on-metal}/env_registry.sh}"
    if [ -f "$_reg" ]; then
        # shellcheck disable=SC1090
        source "$_reg" 2>/dev/null || true
    fi
}
load_env_registry

# ── Phase mapping ─────────────────────────────────────────────
get_script_phase() {
    local rel="$1"
    case "$rel" in
        build/fetch_all_deps.sh|build/build_offline_zip.sh)
            echo "1" ;;
        magisk-module/env_detect.sh|core/device_profile.sh)
            echo "2" ;;
        core/boot_image.sh|core/anti_rollback.sh|\
        core/candidate_entry.sh|core/apply_defaults.sh)
            echo "3" ;;
        core/magisk_patch.sh|core/flash.sh)
            echo "4" ;;
        magisk-module/customize.sh|magisk-module/service.sh|\
        magisk-module/collect.sh|recovery-zip/collect_recovery.sh|\
        recovery-zip/collect_factory.sh|magisk-module/setup_termux.sh)
            echo "5" ;;
        pipeline/parse_logs.py|pipeline/parse_manifests.py|\
        pipeline/parse_pinctrl.py|pipeline/parse_symbols.py|\
        pipeline/unpack_images.py|pipeline/build_table.py)
            echo "6" ;;
        pipeline/report.py|pipeline/failure_analysis.py|\
        core/share.sh|pipeline/upload.py|\
        pipeline/github_notify.py|build/host_flash.sh)
            echo "7" ;;
        core/logging.sh|core/ux.sh|core/privacy.sh|core/state_machine.sh)
            echo "8" ;;
        *) echo "0" ;;
    esac
}

phase_label() {
    case "$1" in
        1) echo "Setup & Build" ;;
        2) echo "Environment & Device Detection" ;;
        3) echo "Boot Image & Pre-patch Analysis" ;;
        4) echo "Patch & Flash" ;;
        5) echo "Module Installation & Data Collection" ;;
        6) echo "Analysis Pipeline" ;;
        7) echo "Reporting & Sharing" ;;
        8) echo "Utility / Framework" ;;
        *) echo "Other" ;;
    esac
}

# ── Boot-image obtainability check ────────────────────────────
_boot_image_obtainable() {
    [ -n "${HOM_BOOT_IMG_PATH:-}" ] \
        && [ -f "${HOM_BOOT_IMG_PATH:-/nonexistent}" ] && return 0
    [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] 2>/dev/null && return 0
    for _bpi in /data/adb/magisk/stock_boot.img \
                /data/adb/magisk/stock_boot_*.img; do
        [ -f "$_bpi" ] 2>/dev/null && return 0
    done
    local _bpd
    for _bpd in "$HOME/hands-on-metal/boot_work" \
                /sdcard/Download /sdcard /data/local/tmp; do
        for _bpn in boot.img init_boot.img \
                    boot_original.img init_boot_original.img; do
            [ -f "$_bpd/$_bpn" ] 2>/dev/null && return 0
        done
    done
    local _bpb
    for _bpb in /sdcard/TWRP/BACKUPS /sdcard/Fox/BACKUPS \
                /sdcard/OrangeFox/BACKUPS /sdcard/PBRP/BACKUPS \
                /sdcard/SHRP/BACKUPS /sdcard/RedWolf/BACKUPS \
                /sdcard/clockworkmod/backup /sdcard/nandroid; do
        [ -d "$_bpb" ] 2>/dev/null || continue
        for _bpg in \
            "$_bpb"/*/*/boot.emmc.win   "$_bpb"/*/*/init_boot.emmc.win \
            "$_bpb"/*/*/boot.emmc.win.gz "$_bpb"/*/*/init_boot.emmc.win.gz \
            "$_bpb"/*/*/boot.emmc.win.lz4 "$_bpb"/*/*/init_boot.emmc.win.lz4 \
            "$_bpb"/*/*/boot.img "$_bpb"/*/*/init_boot.img \
            "$_bpb"/*/boot.img  "$_bpb"/*/init_boot.img; do
            [ -f "$_bpg" ] 2>/dev/null && return 0
        done
    done
    local _api_level
    _api_level=$(getprop ro.build.version.sdk 2>/dev/null || echo 0)
    [ "$_api_level" -ge 31 ] 2>/dev/null && return 0
    return 1
}

_module_script_readable() {
    local script="$1"
    [ -f "$script" ] 2>/dev/null && [ -r "$script" ] 2>/dev/null
}

# ── Prerequisite checking ─────────────────────────────────────
check_prereq() {
    local prereq="$1"
    case "$prereq" in
        root)
            [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] 2>/dev/null ;;
        network)
            curl -s --connect-timeout 2 -o /dev/null https://github.com 2>/dev/null \
                || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 ;;
        boot_image)
            _boot_image_obtainable ;;
        magisk_binary)
            command -v magisk >/dev/null 2>&1 \
                || [ -x "/data/adb/magisk/magisk" ]   2>/dev/null \
                || [ -x "/data/adb/magisk/magisk64" ] 2>/dev/null \
                || [ -x "/data/adb/magisk/magisk32" ] 2>/dev/null \
                || [ -x "${REPO_ROOT:-__none__}/tools/magisk64" ] 2>/dev/null \
                || [ -x "${REPO_ROOT:-__none__}/tools/magisk32" ] 2>/dev/null \
                || [ -x "${OUT:-$HOME/hands-on-metal}/tools/magisk64" ] 2>/dev/null \
                || [ -x "${OUT:-$HOME/hands-on-metal}/tools/magisk32" ] 2>/dev/null ;;
        device_profile)
            [ -n "${HOM_DEV_MODEL:-}" ] ;;
        env_registry)
            [ -f "${ENV_REGISTRY:-$HOME/hands-on-metal/env_registry.sh}" ] 2>/dev/null ;;
        android_device)
            [ -n "$(getprop ro.build.display.id 2>/dev/null || true)" ] \
                || [ -d "/data/data/com.termux" ] 2>/dev/null ;;
        partition_index)
            [ -f "${REPO_ROOT:-__none__}/build/partition_index.json" ] ;;
        schema)
            [ -f "${REPO_ROOT:-__none__}/schema/hardware_map.sql" ] ;;
        env_github_token)
            [ -n "${GITHUB_TOKEN:-}" ] ;;
        target_device)
            command -v adb >/dev/null 2>&1 \
                && adb devices 2>/dev/null \
                    | grep -qE '\t(device|recovery|sideload)' ;;
        target_shizuku)
            command -v adb >/dev/null 2>&1 \
                && adb shell \
                    "dumpsys activity services moe.shizuku.privileged.api \
                     2>/dev/null" 2>/dev/null \
                    | grep -q "ServiceRecord" 2>/dev/null ;;
        target_ladb)
            command -v adb >/dev/null 2>&1 \
                && adb shell "pm list packages 2>/dev/null" 2>/dev/null \
                    | grep -q "com.draco.ladb" 2>/dev/null ;;
        module_core_stack)
            local _mod="${HOM_MODULE_DIR:-/data/adb/modules/hands-on-metal-collector}"
            _module_script_readable "$_mod/core/logging.sh" \
                && _module_script_readable "$_mod/core/ux.sh" \
                && _module_script_readable "$_mod/core/state_machine.sh" \
                && _module_script_readable "$_mod/core/privacy.sh" \
                && _module_script_readable "$_mod/env_detect.sh" ;;
        cmd:*)
            command -v "${prereq#cmd:}" >/dev/null 2>&1 ;;
        *)
            return 1 ;;
    esac
}

prereq_label() {
    local prereq="$1"
    case "$prereq" in
        root)             echo "root (superuser) access" ;;
        network)          echo "network / internet access" ;;
        boot_image)       echo "boot image (root DD / backup / GKI / factory / manual)" ;;
        magisk_binary)    echo "Magisk binary" ;;
        device_profile)   echo "device profile (core/device_profile.sh)" ;;
        env_registry)     echo "environment registry ($HOME/hands-on-metal/env_registry.sh)" ;;
        android_device)   echo "Android device environment" ;;
        partition_index)  echo "partition index (build/partition_index.json)" ;;
        schema)           echo "database schema (schema/hardware_map.sql)" ;;
        env_github_token) echo "GITHUB_TOKEN environment variable" ;;
        target_device)    echo "TARGET device connected via USB, OTG, or wireless ADB" ;;
        target_shizuku)   echo "Shizuku running on TARGET (elevated ADB shell access)" ;;
        target_ladb)      echo "LADB installed on TARGET (on-device ADB shell)" ;;
        module_core_stack) echo "module core scripts present + readable (/data/adb/modules/...)" ;;
        cmd:*)            echo "command: ${prereq#cmd:}" ;;
        *)                echo "$prereq" ;;
    esac
}

prereq_provider() {
    local prereq="$1"
    case "$prereq" in
        boot_image)      echo "core/boot_image.sh" ;;
        device_profile)  echo "core/device_profile.sh" ;;
        env_registry)    echo "magisk-module/env_detect.sh" ;;
        partition_index) echo "build/fetch_all_deps.sh" ;;
        schema)          echo "build/fetch_all_deps.sh" ;;
        target_device)   echo "build/host_flash.sh:wifi-setup" ;;
        target_shizuku)  echo "build/host_flash.sh:elevated-setup" ;;
        target_ladb)     echo "build/host_flash.sh:elevated-setup" ;;
        module_core_stack) echo "magisk-module installer (module payload extract)" ;;
        *)               echo "" ;;
    esac
}

get_prereqs_for_script() {
    local rel="$1"
    case "$rel" in
        build/build_offline_zip.sh)           echo "cmd:zip partition_index" ;;
        build/fetch_all_deps.sh)              echo "cmd:git cmd:curl cmd:unzip network" ;;
        build/host_flash.sh)                  echo "cmd:adb" ;;
        build/host_flash.sh:c1)               echo "cmd:adb cmd:fastboot" ;;
        build/host_flash.sh:c2)               echo "cmd:adb cmd:fastboot" ;;
        build/host_flash.sh:c3)               echo "cmd:adb" ;;
        build/host_flash.sh:wifi-setup)       echo "cmd:adb" ;;
        build/host_flash.sh:dump)             echo "cmd:adb" ;;
        build/host_flash.sh:elevated-setup)   echo "cmd:adb" ;;
        core/anti_rollback.sh)                echo "boot_image" ;;
        core/apply_defaults.sh)               echo "device_profile partition_index" ;;
        core/boot_image.sh)                   echo "android_device" ;;
        core/candidate_entry.sh)              echo "device_profile partition_index" ;;
        core/device_profile.sh)               echo "android_device" ;;
        core/flash.sh)                        echo "root boot_image" ;;
        core/logging.sh)                      echo "" ;;
        core/magisk_patch.sh)                 echo "boot_image magisk_binary" ;;
        core/privacy.sh)                      echo "" ;;
        core/share.sh)                        echo "env_registry" ;;
        core/state_machine.sh)                echo "" ;;
        core/ux.sh)                           echo "" ;;
        magisk-module/collect.sh)             echo "android_device env_registry" ;;
        magisk-module/customize.sh)           echo "root android_device module_core_stack" ;;
        magisk-module/env_detect.sh)          echo "android_device" ;;
        magisk-module/service.sh)             echo "root android_device module_core_stack" ;;
        magisk-module/setup_termux.sh)        echo "android_device network" ;;
        recovery-zip/collect_recovery.sh)     echo "root android_device" ;;
        recovery-zip/collect_factory.sh)      echo "cmd:unzip" ;;
        pipeline/build_table.py)              echo "cmd:python3 schema" ;;
        pipeline/failure_analysis.py)         echo "cmd:python3" ;;
        pipeline/github_notify.py)            echo "cmd:python3" ;;
        pipeline/parse_logs.py)               echo "cmd:python3" ;;
        pipeline/parse_manifests.py)          echo "cmd:python3 schema" ;;
        pipeline/parse_pinctrl.py)            echo "cmd:python3 schema" ;;
        pipeline/parse_symbols.py)            echo "cmd:python3" ;;
        pipeline/report.py)                   echo "cmd:python3" ;;
        pipeline/unpack_images.py)            echo "cmd:python3" ;;
        pipeline/upload.py)                   echo "cmd:python3" ;;
        *)                                    echo "" ;;
    esac
}

script_description() {
    local rel="$1"
    case "$rel" in
        build/build_offline_zip.sh)        echo "Build flashable offline ZIPs (Magisk module + recovery)" ;;
        build/fetch_all_deps.sh)           echo "Download Magisk APK, busybox, and create offline bundle" ;;
        build/host_flash.sh)               echo "Host-assisted flash: fastboot boot / flash / ADB sideload (Mode C)" ;;
        build/host_flash.sh:c1)            echo "C1: Temporarily boot TWRP on TARGET via fastboot boot" ;;
        build/host_flash.sh:c2)            echo "C2: Flash pre-patched boot image to TARGET via fastboot" ;;
        build/host_flash.sh:c3)            echo "C3: ADB sideload recovery ZIP to TARGET in custom recovery" ;;
        build/host_flash.sh:wifi-setup)    echo "Pair and connect to TARGET over wireless ADB (no root needed)" ;;
        build/host_flash.sh:dump)          echo "Collect diagnostic/partition data from TARGET (root-adaptive)" ;;
        build/host_flash.sh:elevated-setup) echo "Set up Shizuku/LADB on TARGET for elevated ADB access" ;;
        core/anti_rollback.sh)             echo "Check SPL / AVB rollback risk before flashing" ;;
        core/apply_defaults.sh)            echo "Apply device-family defaults from partition index" ;;
        core/boot_image.sh)                echo "Acquire boot/init_boot image (root DD, backups, GKI, factory, or manual)" ;;
        core/candidate_entry.sh)           echo "Create a candidate entry for an unknown device" ;;
        core/device_profile.sh)            echo "Detect device model, partitions, AVB, and Treble support" ;;
        core/flash.sh)                     echo "Flash patched boot image to device and verify" ;;
        core/logging.sh)                   echo "Shared logging framework (sourced by other scripts)" ;;
        core/magisk_patch.sh)              echo "Patch boot image with Magisk for root access" ;;
        core/privacy.sh)                   echo "Privacy-by-default PII redaction helpers" ;;
        core/share.sh)                     echo "Create a shareable diagnostic bundle (PII redacted)" ;;
        core/state_machine.sh)             echo "Persistent reboot-safe workflow state tracker" ;;
        core/ux.sh)                        echo "User-experience output helpers (TWRP / shell / service)" ;;
        magisk-module/collect.sh)          echo "Hardware data collection (root-adaptive: full with root, partial without)" ;;
        magisk-module/customize.sh)        echo "Main Magisk module installation hook (full workflow)" ;;
        magisk-module/env_detect.sh)       echo "Detect shell, tools, Python, Termux on device" ;;
        magisk-module/service.sh)          echo "Boot service: env detect, Termux setup, collection" ;;
        magisk-module/setup_termux.sh)     echo "Install and bootstrap Termux with required packages" ;;
        recovery-zip/collect_recovery.sh)  echo "Recovery-mode collection with read-only mounts" ;;
        recovery-zip/collect_factory.sh)   echo "Factory image collection without root — parse factory ZIP, extract boot/dtbo/vbmeta images" ;;
        pipeline/build_table.py)           echo "Build hardware-map SQLite database from collected data" ;;
        pipeline/failure_analysis.py)      echo "Analyse install logs for failure patterns" ;;
        pipeline/github_notify.py)         echo "Post analysis results as a GitHub issue comment (or dry-run preview)" ;;
        pipeline/parse_logs.py)            echo "Parse master log and run-manifest files" ;;
        pipeline/parse_manifests.py)       echo "Parse VINTF / sysconfig / permissions XML manifests" ;;
        pipeline/parse_pinctrl.py)         echo "Parse pinctrl debug files into database" ;;
        pipeline/parse_symbols.py)         echo "Parse vendor library symbols and ELF sections" ;;
        pipeline/report.py)                echo "Generate HTML hardware report from database" ;;
        pipeline/unpack_images.py)         echo "Unpack boot / vendor-boot images and extract ramdisk" ;;
        pipeline/upload.py)                echo "Upload diagnostic bundle to GitHub Gist (or local summary)" ;;
        *)                                 echo "" ;;
    esac
}

is_already_done() {
    local rel="$1"
    case "$rel" in
        build/fetch_all_deps.sh)
            [ -f "${REPO_ROOT:-__none__}/tools/magisk64" ] 2>/dev/null \
                && [ -f "${REPO_ROOT:-__none__}/tools/busybox-arm64" ] 2>/dev/null ;;
        build/build_offline_zip.sh)
            compgen -G "${REPO_ROOT:-__none__}/dist/hands-on-metal-*.zip" \
                >/dev/null 2>&1 ;;
        core/device_profile.sh)
            [ -n "${HOM_DEV_MODEL:-}" ] ;;
        core/apply_defaults.sh)
            [ -n "${HOM_DEFAULT_PATCH_TARGET:-}" ] ;;
        core/boot_image.sh)
            [ -n "${HOM_BOOT_IMG_PATH:-}" ] \
                && [ -f "${HOM_BOOT_IMG_PATH:-/nonexistent}" ] ;;
        core/anti_rollback.sh)
            [ -n "${HOM_ARB_ROLLBACK_RISK:-}" ] ;;
        core/candidate_entry.sh)
            [ -n "${HOM_CANDIDATE_FAMILY_MATCHED:-}" ] ;;
        core/magisk_patch.sh)
            [ -n "${HOM_PATCHED_IMG_PATH:-}" ] \
                && [ -f "${HOM_PATCHED_IMG_PATH:-/nonexistent}" ] 2>/dev/null ;;
        core/flash.sh)
            [ "${HOM_FLASH_STATUS:-}" = "OK" ] 2>/dev/null ;;
        magisk-module/env_detect.sh)
            [ -f "${ENV_REGISTRY:-$HOME/hands-on-metal/env_registry.sh}" ] 2>/dev/null ;;
        magisk-module/collect.sh)
            [ -n "${HOM_LIVE_DUMP_DIR:-}" ] \
                && [ -f "${HOM_LIVE_DUMP_DIR:-/nonexistent}/manifest.txt" ] 2>/dev/null ;;
        recovery-zip/collect_recovery.sh)
            [ -n "${HOM_RECOVERY_DUMP_DIR:-}" ] \
                && [ -f "${HOM_RECOVERY_DUMP_DIR:-/nonexistent}/recovery_manifest.txt" ] 2>/dev/null ;;
        recovery-zip/collect_factory.sh)
            [ -n "${HOM_FACTORY_DUMP_DIR:-}" ] \
                && [ -d "${HOM_FACTORY_DUMP_DIR:-/nonexistent}/boot_images" ] 2>/dev/null ;;
        pipeline/parse_logs.py)
            [ -f "${HOM_PARSED_LOG_PATH:-${OUT:-$HOME/hands-on-metal}/parsed.json}" ] 2>/dev/null ;;
        pipeline/unpack_images.py)
            [ -d "${HOM_LIVE_DUMP_DIR:-${OUT:-$HOME/hands-on-metal}/live_dump}/ramdisk" ] 2>/dev/null \
                || [ -d "${HOM_FACTORY_DUMP_DIR:-/nonexistent}/ramdisk" ] 2>/dev/null ;;
        pipeline/build_table.py)
            [ -f "${HOM_DB_PATH:-${OUT:-$HOME/hands-on-metal}/hardware_map.sqlite}" ] 2>/dev/null ;;
        pipeline/report.py)
            [ -f "${OUT:-$HOME/hands-on-metal}/report.html" ] 2>/dev/null ;;
        *)
            return 1 ;;
    esac
}

# ── Script index arrays ───────────────────────────────────────
declare -a SCRIPT_LABELS=()
declare -a SCRIPT_PATHS=()
declare -a SCRIPT_TYPES=()
declare -a ITEM_STATUS=()
declare -a MISSING_INFO=()

# build_script_index is defined by each menu script (phase-specific).

refresh_status() {
    load_env_registry
    ITEM_STATUS=()
    MISSING_INFO=()
    local _reg="${ENV_REGISTRY:-${OUT:-$HOME/hands-on-metal}/env_registry.sh}"
    if [ -f "$_reg" ]; then
        # shellcheck source=/dev/null
        . "$_reg" 2>/dev/null || true
    fi
    local i rel prereqs prereq
    for i in "${!SCRIPT_LABELS[@]}"; do
        rel="${SCRIPT_LABELS[$i]}"
        if is_already_done "$rel" 2>/dev/null; then
            ITEM_STATUS+=("done")
            MISSING_INFO+=("")
            continue
        fi
        prereqs="$(get_prereqs_for_script "$rel")"
        local missing=""
        if [ -n "$prereqs" ]; then
            for prereq in $prereqs; do
                if ! check_prereq "$prereq" 2>/dev/null; then
                    local lbl provider provider_idx
                    lbl="$(prereq_label "$prereq")"
                    provider="$(prereq_provider "$prereq")"
                    provider_idx=""
                    if [ -n "$provider" ]; then
                        local j
                        for j in "${!SCRIPT_LABELS[@]}"; do
                            if [ "${SCRIPT_LABELS[$j]}" = "$provider" ]; then
                                provider_idx="$((j + 1))"
                                break
                            fi
                        done
                    fi
                    if [ -n "$provider_idx" ]; then
                        missing="${missing:+$missing; }$lbl -> run option $provider_idx ($provider)"
                    elif [ -n "$provider" ]; then
                        missing="${missing:+$missing; }$lbl -> $provider"
                    else
                        missing="${missing:+$missing; }$lbl"
                    fi
                fi
            done
        fi
        if [ -n "$missing" ]; then
            ITEM_STATUS+=("missing")
            MISSING_INFO+=("$missing")
        else
            ITEM_STATUS+=("ready")
            MISSING_INFO+=("")
        fi
    done
}

missing_prereqs_for_script() {
    local rel="$1"
    local prereqs prereq missing=""
    prereqs="$(get_prereqs_for_script "$rel")"
    [ -n "$prereqs" ] || { echo ""; return 0; }
    for prereq in $prereqs; do
        if ! check_prereq "$prereq" 2>/dev/null; then
            local lbl provider provider_idx
            lbl="$(prereq_label "$prereq")"
            provider="$(prereq_provider "$prereq")"
            provider_idx=""
            if [ -n "$provider" ]; then
                local j
                for j in "${!SCRIPT_LABELS[@]}"; do
                    if [ "${SCRIPT_LABELS[$j]}" = "$provider" ]; then
                        provider_idx="$((j + 1))"
                        break
                    fi
                done
            fi
            if [ -n "$provider_idx" ]; then
                missing="${missing:+$missing; }$lbl -> run option $provider_idx ($provider)"
            elif [ -n "$provider" ]; then
                missing="${missing:+$missing; }$lbl -> $provider"
            else
                missing="${missing:+$missing; }$lbl"
            fi
        fi
    done
    echo "$missing"
}

# ── Suggested next step ───────────────────────────────────────
SUGGESTION_IDX=-1
SUGGESTION_DESC=""

compute_suggestion() {
    SUGGESTION_IDX=-1
    SUGGESTION_DESC=""
    local -A provider_demand=()
    local i rel prereqs prereq provider
    for i in "${!SCRIPT_LABELS[@]}"; do
        if [ "${ITEM_STATUS[$i]}" = "missing" ]; then
            rel="${SCRIPT_LABELS[$i]}"
            prereqs="$(get_prereqs_for_script "$rel")"
            for prereq in $prereqs; do
                if ! check_prereq "$prereq" 2>/dev/null; then
                    provider="$(prereq_provider "$prereq")"
                    if [ -n "$provider" ]; then
                        provider_demand["$provider"]=$(( ${provider_demand["$provider"]:-0} + 1 ))
                    fi
                fi
            done
        fi
    done
    local best_idx=-1 best_score=0 best_desc=""
    for i in "${!SCRIPT_LABELS[@]}"; do
        if [ "${ITEM_STATUS[$i]}" = "ready" ]; then
            rel="${SCRIPT_LABELS[$i]}"
            local score="${provider_demand["$rel"]:-0}"
            if [ "$score" -gt "$best_score" ]; then
                best_score="$score"
                best_idx="$i"
                best_desc="$(script_description "$rel")"
                if [ "$score" -eq 1 ]; then
                    best_desc="$best_desc — unblocks $score other option"
                else
                    best_desc="$best_desc — unblocks $score other options"
                fi
            fi
        fi
    done
    if [ "$best_idx" -eq -1 ]; then
        for i in "${!SCRIPT_LABELS[@]}"; do
            if [ "${ITEM_STATUS[$i]}" = "ready" ]; then
                best_idx="$i"
                best_desc="$(script_description "${SCRIPT_LABELS[$i]}")"
                break
            fi
        done
    fi
    SUGGESTION_IDX="$best_idx"
    SUGGESTION_DESC="$best_desc"
}

print_suggestion_line() {
    compute_suggestion
    echo
    if [ "$SUGGESTION_IDX" -ge 0 ]; then
        local num="$(( SUGGESTION_IDX + 1 ))"
        local rel="${SCRIPT_LABELS[$SUGGESTION_IDX]}"
        printf "  %s▶  s  →  option %d (%s)%s\n" \
            "$CLR_LIGHT_GREEN" "$num" "$rel" "$CLR_RESET"
        printf "     %s%s%s\n" "$CLR_DIM" "$SUGGESTION_DESC" "$CLR_RESET"
    else
        local all_done=true
        for i in "${!ITEM_STATUS[@]}"; do
            if [ "${ITEM_STATUS[$i]}" != "done" ]; then
                all_done=false; break
            fi
        done
        if [ "$all_done" = true ]; then
            printf "  %s●  s  →  all steps complete%s\n" \
                "$CLR_DARK_GREEN" "$CLR_RESET"
        else
            printf "  %s⚠  s  →  no runnable suggestion — resolve external prerequisites first%s\n" \
                "$CLR_YELLOW" "$CLR_RESET"
        fi
    fi
}

# ── Fancy header box ──────────────────────────────────────────
print_device_header() {
    local inner=66
    local content_w=$(( inner - 2 ))
    local title="${HOM_MENU_TITLE:-hands-on-metal}"
    local date_str
    date_str="$(date -u +%Y-%m-%d 2>/dev/null || true)"

    printf "  ╔%s╗\n" "$(_repeat_char '═' "$inner")"

    local gap=$(( content_w - ${#title} - ${#date_str} ))
    [ "$gap" -lt 0 ] && gap=0
    printf "  ║ %s%s%s%*s%s ║\n" \
        "$CLR_BOLD" "$title" "$CLR_RESET" "$gap" "" "$date_str"

    if [ -n "${HOM_DEV_MODEL:-}" ]; then
        printf "  ╠%s╣\n" "$(_repeat_char '═' "$inner")"
        local dev_str="Device │ ${HOM_DEV_MODEL}"
        [ -n "${HOM_DEV_CODENAME:-}" ] \
            && dev_str="${dev_str} (${HOM_DEV_CODENAME})"
        [ -n "${HOM_DEV_API_LEVEL:-}" ] \
            && dev_str="${dev_str}  ·  API ${HOM_DEV_API_LEVEL}"
        if [ "${HOM_DEV_IS_AB:-}" = "true" ]; then
            dev_str="${dev_str}  ·  A/B"
        elif [ "${HOM_DEV_IS_AB:-}" = "false" ]; then
            dev_str="${dev_str}  ·  A-only"
        fi
        [ -n "${HOM_DEV_BOOT_PART:-}" ] \
            && dev_str="${dev_str}  ·  ${HOM_DEV_BOOT_PART}"
        printf "  ║ %-*s ║\n" "$content_w" "$dev_str"
    fi

    printf "  ╚%s╝\n" "$(_repeat_char '═' "$inner")"
    echo
}

# ── Progress bar ──────────────────────────────────────────────
print_progress_bar() {
    local done_n=0 ready_n=0 wait_n=0 total="${#SCRIPT_LABELS[@]}"
    local i
    for i in "${!ITEM_STATUS[@]}"; do
        case "${ITEM_STATUS[$i]}" in
            done)    done_n=$(( done_n + 1 )) ;;
            ready)   ready_n=$(( ready_n + 1 )) ;;
            missing) wait_n=$(( wait_n + 1 )) ;;
        esac
    done
    local bar_w=30 filled=0
    [ "$total" -gt 0 ] && filled=$(( done_n * bar_w / total ))
    local bar="" j=0
    while [ "$j" -lt "$bar_w" ]; do
        [ "$j" -lt "$filled" ] && bar="${bar}█" || bar="${bar}░"
        j=$(( j + 1 ))
    done
    printf "  Progress  %s%s%s" "$CLR_DARK_GREEN" "$bar" "$CLR_RESET"
    printf "  %s● %d done%s" "$CLR_DARK_GREEN" "$done_n" "$CLR_RESET"
    printf "  %s▶ %d ready%s" "$CLR_LIGHT_GREEN" "$ready_n" "$CLR_RESET"
    printf "  %s⚠ %d waiting%s\n" "$CLR_YELLOW" "$wait_n" "$CLR_RESET"
}

# ── Main menu display ─────────────────────────────────────────
print_menu() {
    refresh_status
    print_device_header

    printf "  Legend:  %s▶ READY%s  %s● DONE %s  %s⚠ WAIT %s\n" \
        "$CLR_LIGHT_GREEN" "$CLR_RESET" \
        "$CLR_DARK_GREEN"  "$CLR_RESET" \
        "$CLR_YELLOW"      "$CLR_RESET"

    local i color status_badge desc
    local cur_phase="" prev_phase=""
    for i in "${!SCRIPT_LABELS[@]}"; do
        local rel="${SCRIPT_LABELS[$i]}"
        cur_phase="$(get_script_phase "$rel")"

        if [ "$cur_phase" != "$prev_phase" ]; then
            local plabel
            plabel="$(phase_label "$cur_phase")"
            local phdr="── Phase ${cur_phase} · ${plabel} "
            local pad=$(( 66 - ${#phdr} ))
            [ "$pad" -lt 0 ] && pad=0
            printf "\n  %s%s%s%s\n" \
                "$CLR_CYAN" "$phdr" \
                "$(_repeat_char '─' "$pad")" "$CLR_RESET"
            prev_phase="$cur_phase"
        fi

        case "${ITEM_STATUS[$i]}" in
            ready)
                color="$CLR_LIGHT_GREEN"
                status_badge="${CLR_LIGHT_GREEN}▶ READY${CLR_RESET}"
                ;;
            done)
                color="$CLR_DARK_GREEN"
                status_badge="${CLR_DARK_GREEN}● DONE ${CLR_RESET}"
                ;;
            missing)
                color="$CLR_YELLOW"
                status_badge="${CLR_YELLOW}⚠ WAIT ${CLR_RESET}"
                ;;
        esac

        printf "  %s%2d)%s  %-44s %s\n" \
            "$color" "$(( i + 1 ))" "$CLR_RESET" \
            "${SCRIPT_LABELS[$i]}" "$status_badge"

        desc="$(script_description "${SCRIPT_LABELS[$i]}")"
        [ -n "$desc" ] \
            && printf "       %s%s%s\n" "$CLR_DIM" "$desc" "$CLR_RESET"

        [ "${ITEM_STATUS[$i]}" = "missing" ] \
            && printf "       %sneeds: %s%s\n" \
                "$CLR_YELLOW" "${MISSING_INFO[$i]}" "$CLR_RESET"
    done

    echo
    print_progress_bar
    echo
    local sep
    sep="$(_repeat_char '─' 68)"
    printf "  %s\n" "$sep"
    print_suggestion_line
    printf "  %s\n" "$sep"
    local other_lbl="${HOM_OTHER_MENU_LABEL:-other menu}"
    printf "  %sp%s prerequisites  %sr%s refresh  %sm%s %-18s  %sq%s quit\n" \
        "$CLR_CYAN" "$CLR_RESET" \
        "$CLR_CYAN" "$CLR_RESET" \
        "$CLR_CYAN" "$CLR_RESET" "$other_lbl" \
        "$CLR_CYAN" "$CLR_RESET"
}

# ── Prerequisites sub-menu ────────────────────────────────────
print_prereq_submenu() {
    refresh_status
    echo
    printf "  ╔%s╗\n" "$(_repeat_char '═' 66)"
    printf "  ║ %-66s║\n" " Prerequisites Check"
    printf "  ╚%s╝\n" "$(_repeat_char '═' 66)"
    echo

    local i rel prereqs prereq
    for i in "${!SCRIPT_LABELS[@]}"; do
        rel="${SCRIPT_LABELS[$i]}"
        prereqs="$(get_prereqs_for_script "$rel")"

        local hdr_color
        case "${ITEM_STATUS[$i]}" in
            ready)   hdr_color="$CLR_LIGHT_GREEN" ;;
            done)    hdr_color="$CLR_DARK_GREEN" ;;
            missing) hdr_color="$CLR_YELLOW" ;;
        esac

        printf "%s%2d) %s%s" "$hdr_color" "$(( i + 1 ))" "$rel" "$CLR_RESET"

        case "${ITEM_STATUS[$i]}" in
            ready)   echo "  ${CLR_LIGHT_GREEN}[READY]${CLR_RESET}" ;;
            done)    echo "  ${CLR_DARK_GREEN}[DONE — not needed]${CLR_RESET}" ;;
            missing) echo "  ${CLR_YELLOW}[BLOCKED]${CLR_RESET}" ;;
        esac

        if [ -z "$prereqs" ]; then
            echo "      No prerequisites (always runnable)"
        else
            for prereq in $prereqs; do
                local lbl provider provider_idx met_str
                lbl="$(prereq_label "$prereq")"
                provider="$(prereq_provider "$prereq")"
                provider_idx=""
                if [ -n "$provider" ]; then
                    local j
                    for j in "${!SCRIPT_LABELS[@]}"; do
                        if [ "${SCRIPT_LABELS[$j]}" = "$provider" ]; then
                            provider_idx="$(( j + 1 ))"
                            break
                        fi
                    done
                fi
                if check_prereq "$prereq" 2>/dev/null; then
                    met_str="${CLR_LIGHT_GREEN}✓ met${CLR_RESET}"
                else
                    if [ -n "$provider_idx" ]; then
                        met_str="${CLR_YELLOW}✗ MISSING — run option $provider_idx ($provider)${CLR_RESET}"
                    elif [ -n "$provider" ]; then
                        met_str="${CLR_YELLOW}✗ MISSING — provided by: $provider${CLR_RESET}"
                    else
                        met_str="${CLR_YELLOW}✗ MISSING — resolve externally${CLR_RESET}"
                    fi
                fi
                echo "      • $lbl  $met_str"
            done
        fi
        echo
    done

    printf "  %s\n" "$(_repeat_char '═' 68)"
    print_suggestion_line
    echo
    echo " Enter) return to main menu"
    echo
    read -r -p "Choose (s or Enter): " sub_choice
    sub_choice="${sub_choice//[!a-zA-Z0-9]/}"
    case "$sub_choice" in
        s|S)
            if [ "$SUGGESTION_IDX" -ge 0 ]; then
                run_selected "$SUGGESTION_IDX"
            else
                echo "No suggestion available."
            fi
            ;;
        *) ;;
    esac
}

# ── Startup scan with full variable table ─────────────────────
startup_scan() {
    echo
    printf "  ╔%s╗\n" "$(_repeat_char '═' 66)"
    printf "  ║ %-66s║\n" " System & Environment Scan"
    printf "  ╚%s╝\n" "$(_repeat_char '═' 66)"

    # ── 1. Deeper prerequisite check ─────────────────────────
    echo
    printf "  %s── Prerequisites %s%s\n" \
        "$CLR_CYAN" "$(_repeat_char '─' 50)" "$CLR_RESET"
    echo

    local all_prereqs="" i rel prereqs prereq
    for i in "${!SCRIPT_LABELS[@]}"; do
        rel="${SCRIPT_LABELS[$i]}"
        prereqs="$(get_prereqs_for_script "$rel")"
        for prereq in $prereqs; do
            case " $all_prereqs " in
                *" $prereq "*) ;;
                *)
                    all_prereqs="$all_prereqs $prereq"
                    local lbl
                    lbl="$(prereq_label "$prereq")"
                    if check_prereq "$prereq" 2>/dev/null; then
                        printf "  %s✓%s  %s\n" "$CLR_LIGHT_GREEN" "$CLR_RESET" "$lbl"
                    else
                        local provider
                        provider="$(prereq_provider "$prereq")"
                        if [ -n "$provider" ]; then
                            printf "  %s✗%s  %s  → provided by: %s\n" \
                                "$CLR_YELLOW" "$CLR_RESET" "$lbl" "$provider"
                        else
                            printf "  %s✗%s  %s  → resolve externally\n" \
                                "$CLR_YELLOW" "$CLR_RESET" "$lbl"
                        fi
                    fi
                    ;;
            esac
        done
    done

    # ── 2. Full HOM_* variable table (all known vars, sensitive masked) ──
    echo
    printf "  %s── HOM_* Variable Registry %s%s\n" \
        "$CLR_CYAN" "$(_repeat_char '─' 40)" "$CLR_RESET"
    printf "  %-38s  %s\n" "Variable" "Value"
    printf "  %s\n" "$(_repeat_char '─' 68)"

    local _known_hom_vars=(
        # ── device_profile.sh ──────────────────────────────────────────
        HOM_DEV_MODEL           HOM_DEV_BRAND            HOM_DEV_DEVICE
        HOM_DEV_CODENAME        HOM_DEV_FINGERPRINT      HOM_DEV_FIRST_API_LEVEL
        HOM_DEV_SDK_INT         HOM_DEV_ANDROID_VER      HOM_DEV_SPL
        HOM_DEV_BUILD_ID        HOM_DEV_IS_AB            HOM_DEV_SLOT_SUFFIX
        HOM_DEV_CURRENT_SLOT    HOM_DEV_SAR              HOM_DEV_DYNAMIC_PARTITIONS
        HOM_DEV_TREBLE_ENABLED  HOM_DEV_TREBLE_VINTF_VER HOM_DEV_AVB_VERSION
        HOM_DEV_AVB_STATE       HOM_DEV_AVB_ALGO         HOM_DEV_BOOT_PART
        HOM_DEV_BOOT_PART_SOURCE HOM_DEV_BOOT_DEV        HOM_DEV_INIT_BOOT_DEV
        HOM_DEV_VENDOR_BOOT_DEV HOM_DEV_SOC_MFR          HOM_DEV_SOC_MODEL
        HOM_DEV_PLATFORM        HOM_DEV_HARDWARE         HOM_DEV_BOOTLOADER
        HOM_DEV_BASEBAND        HOM_DEV_TENSOR_ARB_AFFECTED
        HOM_DEV_FACTORY_ZIP     HOM_DEV_FACTORY_ZIP_MATCH HOM_DEV_FACTORY_BOARD
        HOM_DEV_FACTORY_REQUIRED_BOOTLOADER HOM_DEV_FACTORY_REQUIRED_BASEBAND
        # ── boot_image.sh / collect_factory.sh ────────────────────────
        HOM_BOOT_IMG_PATH       HOM_BOOT_IMG_SHA256      HOM_BOOT_PART_SRC
        HOM_BOOT_IMG_METHOD
        # ── magisk_patch.sh ───────────────────────────────────────────
        HOM_PATCHED_IMG_PATH    HOM_PATCHED_IMG_SHA256
        HOM_MAGISK_BIN          HOM_MAGISK_VERSION
        # ── flash.sh ─────────────────────────────────────────────────
        HOM_FLASH_STATUS        HOM_FLASH_PRE_SHA256     HOM_FLASH_POST_SHA256
        # ── anti_rollback.sh ─────────────────────────────────────────
        HOM_ARB_ROLLBACK_RISK   HOM_ARB_IMG_SPL          HOM_ARB_REQUIRE_MAY2026_FLAGS
        HOM_ARB_MAY2026_ACTIVE  HOM_ARB_DEV_ROLLBACK_IDX HOM_ARB_MAGISK_ADEQUATE
        # ── apply_defaults.sh / candidate_entry.sh ───────────────────
        HOM_DEFAULT_PATCH_TARGET HOM_CANDIDATE_FAMILY_MATCHED
        # ── env_detect.sh ─────────────────────────────────────────────
        # (HOM_ENV_TYPE: termux | android_terminal | adb_shell | android_native | linux_host)
        HOM_ENV_TYPE            HOM_EXEC_NODE            HOM_EXEC_UID
        HOM_MAGISK_BIN
        # ── collect.sh ───────────────────────────────────────────────
        HOM_LIVE_DUMP_DIR       HOM_MANIFEST             HOM_COLLECT_LOG
        HOM_COLLECT_ROOT        HOM_COLLECT_DATA_SOURCE  HOM_HW_ENV
        HOM_CRYPTO_CLASS        HOM_CRYPTO_STATE         HOM_CRYPTO_TYPE
        # ── collect_recovery.sh ──────────────────────────────────────
        HOM_RECOVERY_DUMP_DIR   HOM_RECOVERY_MANIFEST
        # ── collect_factory.sh ───────────────────────────────────────
        HOM_FACTORY_DUMP_DIR    HOM_FACTORY_MANIFEST
        HOM_FACTORY_ZIP_PATH    HOM_FACTORY_BUILD_ID     HOM_FACTORY_CODENAME
        HOM_RECOVERY_MODE
        # ── upload / fileserver ───────────────────────────────────────
        HOM_FILESERVER_URL      HOM_FILESERVER_TOKEN
    )
    for _var in "${_known_hom_vars[@]}"; do
        local _val="${!_var:-}"
        local _display_val
        case "$_var" in
            *TOKEN*|*SECRET*|*KEY*|*PASSWORD*|*PASS*)
                [ -n "$_val" ] && _display_val="####" || _display_val="(not set)"
                ;;
            *)
                _display_val="${_val:-(not set)}"
                ;;
        esac
        if [ -n "$_val" ]; then
            printf "  %s%-38s%s  %s\n" \
                "$CLR_DARK_GREEN" "$_var" "$CLR_RESET" "$_display_val"
        else
            printf "  %-38s  %s\n" "$_var" "$_display_val"
        fi
    done

    # Any unlisted HOM_* vars found in environment
    local _extra_found=false
    while IFS='=' read -r _var _val; do
        case "$_var" in HOM_*) ;; *) continue ;; esac
        local _known=false
        for _k in "${_known_hom_vars[@]}"; do
            [ "$_k" = "$_var" ] && _known=true && break
        done
        if [ "$_known" = false ]; then
            _extra_found=true
            printf "  %s%-38s%s  %s\n" \
                "$CLR_DARK_GREEN" "$_var" "$CLR_RESET" "$_val"
        fi
    done < <(env | sort)
    printf "  %s\n" "$(_repeat_char '─' 68)"

    # ── 2b. Required variable health check ────────────────────
    echo
    printf "  %s── Required Variable Health %s%s\n" \
        "$CLR_CYAN" "$(_repeat_char '─' 39)" "$CLR_RESET"
    local _required_hom_vars=(
        HOM_DEV_MODEL HOM_DEV_CODENAME HOM_DEV_SDK_INT
        HOM_DEV_SPL HOM_DEV_BUILD_ID HOM_DEV_BOOT_PART
    )
    local _missing_required=0 _req _req_val
    for _req in "${_required_hom_vars[@]}"; do
        _req_val="${!_req:-}"
        if [ -n "$_req_val" ] && [ "$_req_val" != "MISSING" ]; then
            printf "  %s✓%s  %-24s = %s\n" \
                "$CLR_LIGHT_GREEN" "$CLR_RESET" "$_req" "$_req_val"
        else
            _missing_required=$(( _missing_required + 1 ))
            printf "  %s✗%s  %-24s = (missing)  → run core/device_profile.sh\n" \
                "$CLR_YELLOW" "$CLR_RESET" "$_req"
        fi
    done
    # HOM_DEV_TENSOR_ARB_AFFECTED is written by device_profile — show it when set
    _req_val="${HOM_DEV_TENSOR_ARB_AFFECTED:-}"
    if [ "$_req_val" = "true" ]; then
        printf "  %s⚠%s  %-24s = %s  → Tensor Pixel — bootloader/radio ARB risk\n" \
            "$CLR_YELLOW" "$CLR_RESET" "HOM_DEV_TENSOR_ARB_AFFECTED" "$_req_val"
    fi
    if [ "$_missing_required" -gt 0 ]; then
        printf "  %s→ %d required variable(s) missing; parsing/reporting may be incomplete.%s\n" \
            "$CLR_YELLOW" "$_missing_required" "$CLR_RESET"
    fi

    # ── 3. Project-relevant variable table ────────────────────
    echo
    printf "  %s── Project Variables %s%s\n" \
        "$CLR_CYAN" "$(_repeat_char '─' 47)" "$CLR_RESET"
    printf "  %-38s  %s\n" "Variable" "Value"
    printf "  %s\n" "$(_repeat_char '─' 68)"

    local _project_vars=(
        GITHUB_TOKEN ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_ROOT
        TERMUX_VERSION ADB_SERIAL ENV_REGISTRY OUT RUN_ID
    )
    for _var in "${_project_vars[@]}"; do
        local _val="${!_var:-}"
        local _display_val
        case "$_var" in
            *TOKEN*|*SECRET*|*KEY*|*PASSWORD*)
                [ -n "$_val" ] && _display_val="####" || _display_val="(not set)"
                ;;
            *)
                _display_val="${_val:-(not set)}"
                ;;
        esac
        if [ -n "$_val" ]; then
            printf "  %s%-38s%s  %s\n" \
                "$CLR_DARK_GREEN" "$_var" "$CLR_RESET" "$_display_val"
        else
            printf "  %-38s  %s\n" "$_var" "$_display_val"
        fi
    done
    printf "  %s\n" "$(_repeat_char '─' 68)"
    echo
    printf "  %s\n" "$(_repeat_char '═' 68)"
    echo
}

# ── Completion summary ────────────────────────────────────────
script_completion_success() {
    local rel="$1"
    case "$rel" in
        build/build_offline_zip.sh)
            echo "Built flashable ZIPs (Magisk module + recovery) in build/dist/."
            echo "  • Magisk module ZIP: flash via Magisk app → Modules → Install from storage"
            echo "  • Recovery ZIP: flash via TWRP/OrangeFox → Install → select ZIP"
            ;;
        build/fetch_all_deps.sh)
            echo "Downloaded all dependencies (Magisk APK, busybox, offline bundle) into build/."
            ;;
        build/host_flash.sh)
            echo "Host-assisted flash completed (Mode C)."
            echo "  • Device was flashed via ADB/fastboot from this PC."
            echo "  • See docs/ADB_FASTBOOT_INSTALL.md for the full Mode C guide."
            ;;
        core/anti_rollback.sh)
            echo "Checked the Security Patch Level (SPL) and AVB rollback index."
            echo "  • Anti-rollback risk assessment stored in HOM_ARB_ROLLBACK_RISK."
            ;;
        core/apply_defaults.sh)
            echo "Applied device-family defaults from the partition index to the current profile."
            echo "  • Default patch target set (HOM_DEFAULT_PATCH_TARGET)."
            ;;
        core/boot_image.sh)
            echo "Acquired the boot (or init_boot) image."
            echo "  • Image path stored in HOM_BOOT_IMG_PATH."
            echo "  • Sources checked: root DD, Magisk stock backup, TWRP/recovery backups,"
            echo "    GKI generic image (Android 12+), Google factory, OEM firmware, manual."
            ;;
        core/candidate_entry.sh)
            echo "Created a new candidate entry for this device in the partition index."
            ;;
        core/device_profile.sh)
            echo "Detected device model, partitions, A/B slot layout, AVB, and Treble support."
            echo "  • Device model stored in HOM_DEV_MODEL."
            ;;
        core/flash.sh)
            echo "Flashed the patched boot image to the device and verified integrity."
            echo "  • Flash status stored in HOM_FLASH_STATUS=OK."
            echo "  • Pre/post SHA-256 recorded in HOM_FLASH_PRE_SHA256 / HOM_FLASH_POST_SHA256."
            ;;
        core/logging.sh)
            echo "Logging framework loaded successfully (sourced by other scripts)."
            ;;
        core/magisk_patch.sh)
            echo "Patched the boot image with Magisk for root access."
            echo "  • Patched image path stored in HOM_PATCHED_IMG_PATH."
            ;;
        core/privacy.sh)
            echo "Privacy-by-default PII redaction helpers loaded."
            ;;
        core/share.sh)
            echo "Created a shareable PII-redacted diagnostic bundle."
            ;;
        core/state_machine.sh)
            echo "State machine framework loaded (reboot-safe workflow tracker)."
            ;;
        core/ux.sh)
            echo "UX output helpers loaded (TWRP / shell / service display modes)."
            ;;
        magisk-module/collect.sh)
            echo "Collected hardware data from the device."
            echo "  With root: full collection (dmesg, pinctrl, vendor libs, boot DD)."
            echo "  Without root: partial collection (getprop, /proc, sysfs classes, VINTF)."
            ;;
        magisk-module/customize.sh)
            echo "Ran the full Magisk module installation workflow on the device."
            ;;
        magisk-module/env_detect.sh)
            echo "Detected the device environment (shell, tools, Python, Termux)."
            echo "  • Results saved to $HOME/hands-on-metal/env_registry.sh."
            ;;
        magisk-module/service.sh)
            echo "Boot service executed: environment detection, Termux setup, and data collection."
            ;;
        magisk-module/setup_termux.sh)
            echo "Installed and bootstrapped Termux with the required packages."
            ;;
        recovery-zip/collect_recovery.sh)
            echo "Collected hardware data in recovery mode using read-only mounts."
            ;;
        recovery-zip/collect_factory.sh)
            echo "Parsed factory ZIP and extracted boot-chain images without root."
            echo "  • Partition images (boot/init_boot/vendor_boot/dtbo/vbmeta) → \${OUT}/boot_work/partitions/"
            echo "  • Copies also in: \${HOM_FACTORY_DUMP_DIR}/boot_images/"
            echo "  • HOM_BOOT_IMG_PATH now points to the correct image for Magisk patching."
            echo "  • Key build properties (board, required bootloader/baseband) written to env registry."
            ;;
        pipeline/build_table.py)
            echo "Built the hardware-map SQLite database from collected data."
            ;;
        pipeline/failure_analysis.py)
            echo "Analyzed install logs and identified failure patterns."
            ;;
        pipeline/github_notify.py)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                echo "Posted analysis results as a GitHub issue comment."
            else
                echo "Printed analysis results locally (dry-run — no GITHUB_TOKEN set)."
                echo "  Set GITHUB_TOKEN to post results as a GitHub issue comment."
            fi
            ;;
        pipeline/parse_logs.py)
            echo "Parsed master log and run-manifest files."
            ;;
        pipeline/parse_manifests.py)
            echo "Parsed VINTF / sysconfig / permissions XML manifests into the database."
            ;;
        pipeline/parse_pinctrl.py)
            echo "Parsed pinctrl debug files into the database."
            ;;
        pipeline/parse_symbols.py)
            echo "Parsed vendor library symbols and ELF sections."
            ;;
        pipeline/report.py)
            echo "Generated HTML hardware report from the database."
            ;;
        pipeline/unpack_images.py)
            echo "Unpacked boot / vendor-boot images and extracted the ramdisk."
            ;;
        pipeline/upload.py)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                echo "Uploaded the diagnostic bundle to GitHub Gist."
            else
                echo "Displayed local bundle summary (no GITHUB_TOKEN set)."
                echo "  Set GITHUB_TOKEN or re-run with --token to upload to GitHub Gist."
            fi
            ;;
        *)
            echo "Script completed successfully."
            ;;
    esac
}

script_completion_failure() {
    local rel="$1" rc="$2"
    case "$rel" in
        build/build_offline_zip.sh)
            echo "ZIP build failed. Check that 'zip' is installed and the partition index exists." ;;
        build/fetch_all_deps.sh)
            echo "Dependency download failed. Verify network access and that git/curl/unzip are installed." ;;
        build/host_flash.sh)
            echo "Host-assisted flash failed. Check device connection, bootloader unlock status, and USB cable."
            echo "  See docs/ADB_FASTBOOT_INSTALL.md for troubleshooting." ;;
        core/anti_rollback.sh)
            echo "Rollback check failed. Ensure the boot image file (HOM_BOOT_IMG_PATH) is valid." ;;
        core/apply_defaults.sh)
            echo "Could not apply defaults. Ensure device profile and partition index are available." ;;
        core/boot_image.sh)
            echo "Could not acquire the boot image."
            echo "  Options: place boot.img in /sdcard/Download, check TWRP/recovery backups,"
            echo "  download GKI image from ci.android.com (Android 12+), or get root access." ;;
        core/candidate_entry.sh)
            echo "Candidate entry creation failed. Verify device profile and partition index." ;;
        core/device_profile.sh)
            echo "Device detection failed. Ensure you are running on an Android device or in Termux." ;;
        core/flash.sh)
            echo "Flash failed. Ensure root access and a valid patched boot image." ;;
        core/logging.sh)
            echo "Logging framework failed to load. Check file permissions and available disk space." ;;
        core/magisk_patch.sh)
            echo "Magisk patching failed. Ensure the boot image and Magisk binary are available." ;;
        core/privacy.sh)
            echo "Privacy helpers failed to load. Check file permissions." ;;
        core/share.sh)
            echo "Share bundle creation failed. Ensure env_registry.sh exists and is readable." ;;
        core/state_machine.sh)
            echo "State machine framework failed to load. Check file permissions." ;;
        core/ux.sh)
            echo "UX helpers failed to load. Ensure core/logging.sh was sourced first." ;;
        magisk-module/collect.sh)
            echo "Data collection failed. Ensure you are on an Android device."
            echo "  Without root: some data sources are skipped (dmesg, pinctrl, vendor libs)."
            echo "  With root: all sources are available." ;;
        magisk-module/customize.sh)
            echo "Module installation failed. Ensure root access and an Android environment." ;;
        magisk-module/env_detect.sh)
            echo "Environment detection failed. Ensure you are on an Android device." ;;
        magisk-module/service.sh)
            echo "Boot service failed. Ensure root access and an Android environment." ;;
        magisk-module/setup_termux.sh)
            echo "Termux setup failed. Ensure network access and an Android device." ;;
        recovery-zip/collect_recovery.sh)
            echo "Recovery-mode collection failed. Ensure root access and an Android device." ;;
        recovery-zip/collect_factory.sh)
            echo "Factory ZIP collection failed."
            echo "  • Ensure the factory ZIP is accessible (set HOM_FACTORY_ZIP=/path/to/factory.zip)."
            echo "  • Verify unzip is installed: command -v unzip"
            echo "  • The ZIP must be a valid Google factory image containing an inner image-*.zip." ;;
        pipeline/build_table.py)
            echo "Database build failed. Verify Python 3 and the schema file are present." ;;
        pipeline/failure_analysis.py)
            echo "Failure analysis failed."
            echo "  Verify parsed input exists (default: \$OUT/parsed.json) or pass --parsed manually." ;;
        pipeline/github_notify.py)
            echo "GitHub notification failed. Verify Python 3 is installed."
            [ -n "${GITHUB_TOKEN:-}" ] \
                && echo "  GITHUB_TOKEN is set — check token permissions (issues:write scope)." ;;
        pipeline/parse_logs.py)
            echo "Log parsing failed. Verify Python 3 is installed." ;;
        pipeline/parse_manifests.py)
            echo "Manifest parsing failed."
            echo "  Verify --db/--dump/--run-id and that dump contains getprop.txt plus vendor/system XML trees." ;;
        pipeline/parse_pinctrl.py)
            echo "Pinctrl parsing failed."
            echo "  pinctrl data is only collected when root is available during hardware collection."
            echo "  If the dump lacks sys/kernel/debug/pinctrl/, re-run with root or skip this step." ;;
        pipeline/parse_symbols.py)
            echo "Symbol parsing failed."
            echo "  Verify --db/--dump/--run-id and that dump has vendor_symbols/*.nm.txt." ;;
        pipeline/report.py)
            echo "Report generation failed. Verify Python 3 is installed." ;;
        pipeline/unpack_images.py)
            echo "Image unpacking failed. Verify Python 3 is installed."
            echo "  Preferred: run option 5 (core/boot_image.sh) first." ;;
        pipeline/upload.py)
            echo "Upload failed. Verify Python 3 is installed."
            [ -n "${GITHUB_TOKEN:-}" ] \
                && echo "  GITHUB_TOKEN is set — check token permissions (gist scope)." ;;
        *)
            echo "Script failed (exit code $rc). Review the output above for details." ;;
    esac
}

script_next_steps() {
    local rel="$1" rc="$2"
    if [ "$rc" -ne 0 ]; then
        echo "  → Fix the issue above and re-run this option, or press 'p' to check prerequisites."
        return
    fi
    case "$rel" in
        build/build_offline_zip.sh)
            echo "  → Transfer the ZIPs from build/dist/ to your device."
            echo "  → Flash the Magisk module ZIP via: Magisk app → Modules → Install from storage."
            echo "  → Or flash the recovery ZIP via: TWRP/OrangeFox → Install → select ZIP." ;;
        build/fetch_all_deps.sh)
            echo "  → Dependencies are ready. Run 'build/build_offline_zip.sh' to build ZIPs." ;;
        build/host_flash.sh)
            echo "  → After device reboots: open Magisk app to confirm root."
            echo "  → If using C2 (direct flash): install the Magisk module ZIP via Magisk app."
            echo "  → Pull logs: adb pull ~/hands-on-metal/logs/ ./hom-logs/" ;;
        core/anti_rollback.sh)
            echo "  → If no rollback risk was found, proceed to flash (core/flash.sh)."
            echo "  → If a risk was detected, review the SPL/AVB details before flashing." ;;
        core/apply_defaults.sh)
            echo "  → Defaults applied. Proceed to acquire the boot image (core/boot_image.sh)." ;;
        core/boot_image.sh)
            echo "  → Boot image acquired. Next, patch it with Magisk (core/magisk_patch.sh)."
            echo "  → Or check rollback risk first (core/anti_rollback.sh)." ;;
        core/candidate_entry.sh)
            echo "  → Candidate entry created. Run 'build/fetch_all_deps.sh' to refresh." ;;
        core/device_profile.sh)
            echo "  → Device detected. Apply defaults (core/apply_defaults.sh)"
            echo "    or acquire the boot image (core/boot_image.sh)." ;;
        core/flash.sh)
            echo "  → Device flashed and verified. Reboot your device to activate Magisk root."
            echo "  → After reboot, verify root by running: su -c 'id'" ;;
        core/logging.sh)
            echo "  → Logging framework is ready (used automatically by other scripts)." ;;
        core/magisk_patch.sh)
            echo "  → Boot image patched. Check rollback risk (core/anti_rollback.sh)"
            echo "    then flash the patched image (core/flash.sh)." ;;
        core/privacy.sh)
            echo "  → Privacy helpers are loaded (used automatically during data collection)." ;;
        core/share.sh)
            echo "  → Diagnostic bundle created. Share it or upload via 'pipeline/upload.py'." ;;
        core/state_machine.sh)
            echo "  → State machine is ready (used automatically by the workflow scripts)." ;;
        core/ux.sh)
            echo "  → UX helpers are loaded (used automatically by other scripts)." ;;
        magisk-module/collect.sh)
            echo "  → Hardware data collected. Run the pipeline scripts to parse and analyze."
            echo "  → Start with 'pipeline/parse_logs.py' or 'pipeline/build_table.py'."
            echo "  → Without root, some sources were skipped. Re-run with root for full data." ;;
        magisk-module/customize.sh)
            echo "  → Module installed. Reboot your device for changes to take effect." ;;
        magisk-module/env_detect.sh)
            echo "  → Environment registry saved. Other scripts can now use the detected config." ;;
        magisk-module/service.sh)
            echo "  → Boot service completed. Data collected automatically on each boot." ;;
        magisk-module/setup_termux.sh)
            echo "  → Termux is set up. Run the full collection (magisk-module/collect.sh)." ;;
        recovery-zip/collect_recovery.sh)
            echo "  → Recovery data collected. Run the pipeline scripts to parse and analyze." ;;
        recovery-zip/collect_factory.sh)
            echo "  → Factory boot images extracted to \${OUT}/boot_work/partitions/."
            echo "  → HOM_BOOT_IMG_PATH is now set — proceed to patch with Magisk (core/magisk_patch.sh)."
            echo "  → Or check rollback risk first (core/anti_rollback.sh)." ;;
        pipeline/build_table.py)
            echo "  → Database built. Generate a report with 'pipeline/report.py'." ;;
        pipeline/failure_analysis.py)
            echo "  → Analysis complete. Post results via 'pipeline/github_notify.py'." ;;
        pipeline/github_notify.py)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                echo "  → GitHub issue comment posted."
            else
                echo "  → Dry-run output printed. Set GITHUB_TOKEN to post to GitHub."
            fi ;;
        pipeline/parse_logs.py)
            echo "  → Logs parsed. Continue with 'pipeline/build_table.py'." ;;
        pipeline/parse_manifests.py)
            echo "  → Manifests parsed. Continue with 'pipeline/build_table.py'." ;;
        pipeline/parse_pinctrl.py)
            echo "  → Pinctrl parsed. Continue with 'pipeline/build_table.py'." ;;
        pipeline/parse_symbols.py)
            echo "  → Symbols parsed. Continue with 'pipeline/build_table.py'." ;;
        pipeline/report.py)
            echo "  → HTML report generated. Open it in a browser to view results." ;;
        pipeline/unpack_images.py)
            echo "  → Images unpacked. Proceed with parsing or analysis of the extracted contents." ;;
        pipeline/upload.py)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                echo "  → Bundle uploaded to GitHub Gist. Share the Gist URL with collaborators."
            else
                echo "  → Local summary displayed. Set GITHUB_TOKEN and re-run to upload."
            fi ;;
        *)
            echo "  → Return to the menu to continue with the next step." ;;
    esac
}

# ── Run a selected script ─────────────────────────────────────
run_selected() {
    local idx="$1"
    local script="${SCRIPT_PATHS[$idx]}"
    local kind="${SCRIPT_TYPES[$idx]}"
    local rel="${SCRIPT_LABELS[$idx]}"
    local args_array=()
    local missing
    local _out _dump _db _run_id _mode _parsed _analysis _logs

    echo
    printf "  Selected: %s%s%s\n" "$CLR_BOLD" "$rel" "$CLR_RESET"
    printf "  %s%s%s\n" "$CLR_DIM" "$(script_description "$rel")" "$CLR_RESET"
    echo
    missing="$(missing_prereqs_for_script "$rel")"
    if [ -n "$missing" ] && [ "${HOM_ALLOW_MISSING_PREREQS:-0}" != "1" ]; then
        printf "  %s✗ BLOCKED%s — unresolved prerequisites:\n" \
            "$CLR_YELLOW" "$CLR_RESET"
        printf "     %s\n" "$missing"
        echo "  Use 'p' to inspect prerequisites."
        echo "  Override (advanced): set HOM_ALLOW_MISSING_PREREQS=1"
        return 2
    fi
    echo "  Note: enter space-separated arguments (embedded quoting not supported)."
    read -r -a args_array -p "  Arguments (optional): "

    if [ "${#args_array[@]}" -eq 0 ] && [ "$kind" = "python" ]; then
        _out="${OUT:-$HOME/hands-on-metal}"
        _dump="${HOM_LIVE_DUMP_DIR:-${HOM_LIVE_DUMP:-$_out/live_dump}}"
        _db="${HOM_DB_PATH:-$_out/hardware_map.sqlite}"
        _logs="${LOG_DIR:-$_out/logs}"
        _parsed="${HOM_PARSED_LOG_PATH:-$_out/parsed.json}"
        _analysis="${HOM_FAILURE_ANALYSIS_PATH:-$_out/failure_analysis.json}"
        _run_id="${RUN_ID:-1}"
        _mode="${HOM_BUILD_MODE:-A}"
        # Parsers expect integer run IDs; fallback to 1 when RUN_ID is timestamp-like.
        case "$_run_id" in ''|*[!0-9]*) _run_id=1 ;; esac
        case "$rel" in
            pipeline/parse_logs.py)
                args_array=(--log "$_logs" --out "$_parsed")
                ;;
            pipeline/parse_manifests.py|pipeline/parse_pinctrl.py|pipeline/parse_symbols.py)
                args_array=(--db "$_db" --dump "$_dump" --run-id "$_run_id")
                ;;
            pipeline/build_table.py)
                args_array=(--db "$_db" --dump "$_dump" --mode "$_mode")
                ;;
            pipeline/report.py)
                args_array=(--db "$_db" --out "$_out")
                ;;
            pipeline/failure_analysis.py)
                args_array=(--parsed "$_parsed" --index "$REPO_ROOT/build/partition_index.json" --out "$_analysis")
                ;;
        esac
        if [ "${#args_array[@]}" -gt 0 ]; then
            echo "  Auto-args: ${args_array[*]}"
        fi
    fi

    echo
    echo "  Running…"
    local rc=0
    (
        cd "$REPO_ROOT" || exit 1
        export HOM_DEPS_CHECKED
        if [ "$kind" = "python" ]; then
            if [ "${#args_array[@]}" -gt 0 ]; then
                python3 "$script" "${args_array[@]}"
            else
                python3 "$script"
            fi
        else
            case "$rel" in
                core/anti_rollback.sh|core/apply_defaults.sh|\
                core/boot_image.sh|core/candidate_entry.sh|\
                core/device_profile.sh|core/flash.sh|\
                core/magisk_patch.sh|core/share.sh)
                    # shellcheck disable=SC2030
                    SCRIPT_NAME="${rel##*/}"
                    SCRIPT_NAME="${SCRIPT_NAME%.sh}"
                    export SCRIPT_NAME
                    # shellcheck source=/dev/null
                    source "$REPO_ROOT/core/logging.sh"
                    # shellcheck source=/dev/null
                    source "$REPO_ROOT/core/ux.sh"
                    # shellcheck source=/dev/null
                    source "$REPO_ROOT/core/privacy.sh" 2>/dev/null || true
                    # shellcheck source=/dev/null
                    source "$script"
                    case "$rel" in
                        core/anti_rollback.sh)   run_anti_rollback_check "${args_array[@]}" ;;
                        core/apply_defaults.sh)  run_apply_defaults "${args_array[@]}" ;;
                        core/boot_image.sh)      run_boot_image_acquire "${args_array[@]}" ;;
                        core/candidate_entry.sh) run_candidate_entry "${args_array[@]}" ;;
                        core/device_profile.sh)  run_device_profile "${args_array[@]}" ;;
                        core/flash.sh)           run_flash_magisk_path "${args_array[@]}" ;;
                        core/magisk_patch.sh)    run_magisk_patch "${args_array[@]}" ;;
                        core/share.sh)           run_share "${args_array[@]}" ;;
                    esac
                    ;;
                *)
                    if [ "${#args_array[@]}" -gt 0 ]; then
                        bash "$script" "${args_array[@]}"
                    else
                        bash "$script"
                    fi
                    ;;
            esac
        fi
    ) || rc=$?

    echo
    printf "  %s\n" "$(_repeat_char '═' 68)"
    if [ "$rc" -eq 0 ]; then
        printf "  %s✓ SUCCESS%s — %s\n" "$CLR_LIGHT_GREEN" "$CLR_RESET" "$rel"
        printf "  %s\n" "$(_repeat_char '═' 68)"
        echo
        script_completion_success "$rel"
    else
        printf "  %s✗ FAILED (exit code %d)%s — %s\n" \
            "$CLR_YELLOW" "$rc" "$CLR_RESET" "$rel"
        printf "  %s\n" "$(_repeat_char '═' 68)"
        echo
        script_completion_failure "$rel" "$rc"
    fi
    echo
    echo "  Next steps:"
    script_next_steps "$rel" "$rc"
    echo

    # After boot_image succeeds, auto-offer to patch
    if [ "$rc" -eq 0 ] && [ "$rel" = "core/boot_image.sh" ]; then
        local _patch_idx=-1 _j
        for _j in "${!SCRIPT_LABELS[@]}"; do
            if [ "${SCRIPT_LABELS[$_j]}" = "core/magisk_patch.sh" ]; then
                _patch_idx="$_j"
                break
            fi
        done
        if [ "$_patch_idx" -ge 0 ]; then
            printf "  Patch boot image with Magisk now (option %d)? [y/n]: " \
                "$(( _patch_idx + 1 ))"
            local _yn
            read -r _yn
            _yn="${_yn//[!a-zA-Z]/}"
            case "$_yn" in
                y|Y) run_selected "$_patch_idx" ;;
            esac
        fi
    fi
}

# ── Upload-on-exit hook ───────────────────────────────────────
HOM_EXIT_UPLOAD_DONE=0
run_exit_log_upload() {
    [ "${HOM_EXIT_UPLOAD_DONE:-0}" = "1" ] && return 0
    HOM_EXIT_UPLOAD_DONE=1
    set +eu
    local out_dir="${OUT:-$HOME/hands-on-metal}"
    local reg="${ENV_REGISTRY:-$out_dir/env_registry.sh}"
    local upload_py="${REPO_ROOT:-__none__}/pipeline/upload.py"
    if [ ! -f "$reg" ] || [ ! -f "$upload_py" ]; then
        return 0
    fi
    echo
    printf "  %s\n" "$(_repeat_char '═' 68)"
    echo "  Uploading session logs before exit…"
    printf "  %s\n" "$(_repeat_char '═' 68)"
    (
        cd "${REPO_ROOT:-.}" || exit 0
        # shellcheck disable=SC2031
        export SCRIPT_NAME="${HOM_MENU_SCRIPT_NAME:-terminal_menu}"
        # shellcheck source=/dev/null
        . "${REPO_ROOT:-__none__}/core/logging.sh"  2>/dev/null || exit 0
        # shellcheck source=/dev/null
        . "${REPO_ROOT:-__none__}/core/ux.sh"       2>/dev/null || true
        # shellcheck source=/dev/null
        . "${REPO_ROOT:-__none__}/core/privacy.sh"  2>/dev/null || true
        # shellcheck source=/dev/null
        . "${REPO_ROOT:-__none__}/core/share.sh"    2>/dev/null || exit 0
        run_share >/dev/null 2>&1 || true
    ) || true
    local share_root="$out_dir/share"
    local bundle="" candidate newest=""
    if [ -d "$share_root" ]; then
        for candidate in "$share_root"/*/; do
            [ -d "$candidate" ] || continue
            if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
                newest="$candidate"
            fi
        done
        bundle="${newest%/}"
    fi
    if [ -z "$bundle" ] || [ ! -d "$bundle" ]; then
        echo "  (no share bundle to upload — skipping)"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            python3 "$upload_py" --bundle "$bundle" --token "$GITHUB_TOKEN" \
                || echo "  (upload failed — bundle preserved at: $bundle)"
        else
            python3 "$upload_py" --bundle "$bundle" \
                || echo "  (summary failed — bundle preserved at: $bundle)"
            echo "  (no GITHUB_TOKEN set — local summary only)"
        fi
    else
        echo "  (python3 not found — bundle preserved at: $bundle)"
    fi
    if [ -n "${HOM_FILESERVER_URL:-}" ]; then
        local bundle_json="$bundle/share_bundle.json"
        if [ -f "$bundle_json" ] && command -v curl >/dev/null 2>&1; then
            local fs_url="${HOM_FILESERVER_URL%/}/upload" fs_ok=0
            if [ -n "${HOM_FILESERVER_TOKEN:-}" ]; then
                curl --silent --show-error --connect-timeout 5 --max-time 30 \
                    -H "Authorization: Bearer ${HOM_FILESERVER_TOKEN}" \
                    -F "file=@${bundle_json}" \
                    "$fs_url" >/dev/null 2>&1 && fs_ok=1
            else
                curl --silent --show-error --connect-timeout 5 --max-time 30 \
                    -F "file=@${bundle_json}" \
                    "$fs_url" >/dev/null 2>&1 && fs_ok=1
            fi
            if [ "$fs_ok" -eq 1 ]; then
                echo "  (bundle pushed to file server)"
            else
                echo "  (file server push failed — bundle preserved at: $bundle)"
            fi
        fi
    fi
}

# ── Main interactive loop ─────────────────────────────────────
main() {
    if [ ! -d "${REPO_ROOT:-__none__}/pipeline" ]; then
        echo "Error: pipeline directory not found in repository." >&2
        exit 1
    fi

    trap 'run_exit_log_upload' EXIT

    build_script_index

    if [ "${#SCRIPT_LABELS[@]}" -eq 0 ]; then
        echo "No scripts found." >&2
        exit 1
    fi

    startup_scan

    while true; do
        print_menu
        read -r -p "  Choose: " choice
        choice="${choice//[!a-zA-Z0-9]/}"

        case "$choice" in
            q|Q)
                echo "  Bye."
                exit 0
                ;;
            r|R)
                build_script_index
                continue
                ;;
            p|P)
                print_prereq_submenu
                continue
                ;;
            s|S)
                if [ "$SUGGESTION_IDX" -ge 0 ]; then
                    run_selected "$SUGGESTION_IDX"
                else
                    echo "  No suggestion available."
                fi
                continue
                ;;
            m|M)
                local _other="${HOM_OTHER_MENU:-}"
                if [ -n "$_other" ] && [ -f "$_other" ]; then
                    exec bash "$_other"
                else
                    echo "  No companion menu configured."
                fi
                continue
                ;;
            ''|*[!0-9]*)
                echo "  Invalid choice."
                ;;
            *)
                if [ "$choice" -lt 1 ] || \
                   [ "$choice" -gt "${#SCRIPT_LABELS[@]}" ]; then
                    echo "  Invalid choice."
                else
                    run_selected "$(( choice - 1 ))"
                fi
                ;;
        esac
    done
}
