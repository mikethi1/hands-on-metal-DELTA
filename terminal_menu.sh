#!/usr/bin/env bash
# terminal_menu.sh
# Interactive terminal launcher for all project scripts.
#
# Features:
#   - Color-coded menu items based on prerequisite status
#   - Prerequisites sub-menu showing detailed dependency info
#   - Automatic detection of what can run, what is already done,
#     and what still needs prerequisites fulfilled
#
# Color scheme:
#   Light green — script is ready to run (all prerequisites met)
#   Dark green  — script does not need to be run (already done)
#   Yellow      — script has unmet prerequisites (details shown)

set -eu

# When launched from "curl … | bash" (e.g. via setup.sh), stdin is the
# exhausted pipe — not the terminal.  Reopen it from /dev/tty so that
# interactive `read` calls work.
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec < /dev/tty
elif [ ! -t 0 ]; then
    echo "Error: no interactive terminal available (stdin is not a tty)." >&2
    echo "Run 'bash terminal_menu.sh' from an interactive terminal session." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── dependency check (runs once per session) ──────────────────
source "$REPO_ROOT/check_deps.sh" || exit 1

# ── load device environment registry (if available) ──────────
# device_profile.sh writes HOM_DEV_* variables (build ID, boot
# partition type, codename, etc.) to this file.  Sourcing it
# makes that context available for display in the menu.
_HOM_ENV_REGISTRY="$HOME/hands-on-metal/env_registry.sh"
load_env_registry() {
    if [ -f "$_HOM_ENV_REGISTRY" ]; then
        # shellcheck disable=SC1090
        source "$_HOM_ENV_REGISTRY" 2>/dev/null || true
    fi
}
load_env_registry

# ── ANSI color codes ─────────────────────────────────────────
CLR_LIGHT_GREEN=$'\033[92m'   # ready to run
CLR_DARK_GREEN=$'\033[32m'    # already done / not needed
CLR_YELLOW=$'\033[33m'        # unmet prerequisites
CLR_RESET=$'\033[0m'

# If output is not a terminal, disable colors
if [ ! -t 1 ]; then
    CLR_LIGHT_GREEN=""
    CLR_DARK_GREEN=""
    CLR_YELLOW=""
    CLR_RESET=""
fi

# ── Prerequisite definitions ─────────────────────────────────
# Each prerequisite has:
#   - An ID (used as a key)
#   - A human-readable description
#   - A check (performed by check_prereq)
#   - An optional provider (another script that can fulfil it)

# Returns space-separated prerequisite IDs for a given script.
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
        magisk-module/customize.sh)           echo "root android_device" ;;
        magisk-module/env_detect.sh)          echo "android_device" ;;
        magisk-module/service.sh)             echo "root android_device" ;;
        magisk-module/setup_termux.sh)        echo "android_device network" ;;
        recovery-zip/collect_recovery.sh)     echo "root android_device" ;;
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

# Human-readable label for a prerequisite ID.
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
        cmd:*)            echo "command: ${prereq#cmd:}" ;;
        *)                echo "$prereq" ;;
    esac
}

# Check if a boot image file is available or can be obtained.
# Returns 0 (prereq met / obtainable) when ANY of:
#   1. HOM_BOOT_IMG_PATH is set and file exists (already acquired)
#   2. Root access available (can dd dump from live block device)
#   3. Magisk stock boot backup exists (/data/adb/magisk/stock_boot*.img)
#      NOTE: The Magisk GitHub repo (topjohnwu/Magisk) does NOT host
#      factory boot images.  Magisk is a rooting tool only.  However,
#      when Magisk patches a boot image it saves the original here.
#   4. Image found in TWRP / OrangeFox / PBRP / SHRP / RedWolf /
#      CWM / Nandroid backup folders
#   5. Image pre-placed in Download / boot_work / tmp directories
_boot_image_obtainable() {
    # 1. Already acquired
    [ -n "${HOM_BOOT_IMG_PATH:-}" ] \
        && [ -f "${HOM_BOOT_IMG_PATH:-/nonexistent}" ] && return 0

    # 2. Root available → can dd the live partition
    [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] 2>/dev/null && return 0

    # 3. Magisk stock boot backup (saved when Magisk patches)
    for _bpi in /data/adb/magisk/stock_boot.img /data/adb/magisk/stock_boot_*.img; do
        [ -f "$_bpi" ] 2>/dev/null && return 0
    done

    # 4. Pre-placed images in standard locations
    local _bpd
    for _bpd in \
        $HOME/hands-on-metal/boot_work \
        /sdcard/Download \
        /sdcard \
        /data/local/tmp; do
        for _bpn in boot.img init_boot.img boot_original.img init_boot_original.img; do
            [ -f "$_bpd/$_bpn" ] 2>/dev/null && return 0
        done
    done

    # 5. TWRP / custom recovery Nandroid backup folders
    #    TWRP naming: BACKUPS/<serial>/<date>/<part>.emmc.win
    #    .win files are raw dd dumps of the partition (same as .img).
    #    May also be gzip (.win.gz) or lz4 (.win.lz4) compressed.
    local _bpb
    for _bpb in \
        /sdcard/TWRP/BACKUPS \
        /sdcard/Fox/BACKUPS \
        /sdcard/OrangeFox/BACKUPS \
        /sdcard/PBRP/BACKUPS \
        /sdcard/SHRP/BACKUPS \
        /sdcard/RedWolf/BACKUPS \
        /sdcard/clockworkmod/backup \
        /sdcard/nandroid; do
        [ -d "$_bpb" ] 2>/dev/null || continue
        # TWRP-style: BACKUPS/<serial>/<date>/<part>.emmc.win[.gz|.lz4]
        for _bpg in "$_bpb"/*/*/boot.emmc.win   "$_bpb"/*/*/init_boot.emmc.win \
                     "$_bpb"/*/*/boot.emmc.win.gz "$_bpb"/*/*/init_boot.emmc.win.gz \
                     "$_bpb"/*/*/boot.emmc.win.lz4 "$_bpb"/*/*/init_boot.emmc.win.lz4 \
                     "$_bpb"/*/*/boot.img "$_bpb"/*/*/init_boot.img \
                     "$_bpb"/*/boot.img "$_bpb"/*/init_boot.img; do
            [ -f "$_bpg" ] 2>/dev/null && return 0
        done
    done

    # 6. GKI device (Android 12+ / API 31+) — generic boot image
    #    obtainable from ci.android.com for the matching kernel version.
    #    Reference: https://source.android.com/docs/core/architecture/partitions/generic-boot
    local _api_level
    _api_level=$(getprop ro.build.version.sdk 2>/dev/null || echo 0)
    [ "$_api_level" -ge 31 ] 2>/dev/null && return 0

    return 1
}

# Check whether a prerequisite is satisfied.  Returns 0 if met.
check_prereq() {
    local prereq="$1"
    case "$prereq" in
        root)
            [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] 2>/dev/null ;;
        network)
            # Quick connectivity probe (non-blocking)
            curl -s --connect-timeout 2 -o /dev/null https://github.com 2>/dev/null \
                || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 ;;
        boot_image)
            _boot_image_obtainable ;;
        magisk_binary)
            command -v magisk >/dev/null 2>&1 \
                || [ -x "/data/adb/magisk/magisk" ] 2>/dev/null \
                || [ -x "/data/adb/magisk/magisk64" ] 2>/dev/null \
                || [ -x "/data/adb/magisk/magisk32" ] 2>/dev/null \
                || [ -x "$REPO_ROOT/tools/magisk64" ] 2>/dev/null \
                || [ -x "$REPO_ROOT/tools/magisk32" ] 2>/dev/null \
                || [ -x "${OUT:-$HOME/hands-on-metal}/tools/magisk64" ] 2>/dev/null \
                || [ -x "${OUT:-$HOME/hands-on-metal}/tools/magisk32" ] 2>/dev/null ;;
        device_profile)
            [ -n "${HOM_DEV_MODEL:-}" ] ;;
        env_registry)
            [ -f "$HOME/hands-on-metal/env_registry.sh" ] 2>/dev/null ;;
        android_device)
            [ -n "$(getprop ro.build.display.id 2>/dev/null || true)" ] \
                || [ -d "/data/data/com.termux" ] 2>/dev/null ;;
        partition_index)
            [ -f "$REPO_ROOT/build/partition_index.json" ] ;;
        schema)
            [ -f "$REPO_ROOT/schema/hardware_map.sql" ] ;;
        env_github_token)
            [ -n "${GITHUB_TOKEN:-}" ] ;;
        target_device)
            # Check for any device connected via ADB
            command -v adb >/dev/null 2>&1 \
                && adb devices 2>/dev/null | grep -qE '\t(device|recovery|sideload)' ;;
        target_shizuku)
            # Shizuku service running on connected device
            command -v adb >/dev/null 2>&1 \
                && adb shell "dumpsys activity services moe.shizuku.privileged.api 2>/dev/null" 2>/dev/null \
                    | grep -q "ServiceRecord" 2>/dev/null ;;
        target_ladb)
            # LADB installed on connected device
            command -v adb >/dev/null 2>&1 \
                && adb shell "pm list packages 2>/dev/null" 2>/dev/null \
                    | grep -q "com.draco.ladb" 2>/dev/null ;;
        cmd:*)
            command -v "${prereq#cmd:}" >/dev/null 2>&1 ;;
        *)
            return 1 ;;
    esac
}

# Return the relative path of a script that can provide a prerequisite,
# or empty string if it must be resolved externally.
prereq_provider() {
    local prereq="$1"
    case "$prereq" in
        boot_image)       echo "core/boot_image.sh" ;;
        device_profile)   echo "core/device_profile.sh" ;;
        env_registry)     echo "magisk-module/env_detect.sh" ;;
        partition_index)  echo "build/fetch_all_deps.sh" ;;
        schema)           echo "build/fetch_all_deps.sh" ;;
        target_device)    echo "build/host_flash.sh:wifi-setup" ;;
        target_shizuku)   echo "build/host_flash.sh:elevated-setup" ;;
        target_ladb)      echo "build/host_flash.sh:elevated-setup" ;;
        *)                echo "" ;;
    esac
}

# Human-readable description of what a script does.
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

# Check whether a script's work is already done (not needed).
is_already_done() {
    local rel="$1"
    case "$rel" in
        build/fetch_all_deps.sh)
            # Deps fetched if Magisk APK or busybox binary already present
            [ -d "$REPO_ROOT/build/magisk" ] 2>/dev/null \
                && [ -f "$REPO_ROOT/build/busybox" ] 2>/dev/null ;;
        build/build_offline_zip.sh)
            # ZIPs already built
            compgen -G "$REPO_ROOT/build/hands-on-metal-*.zip" >/dev/null 2>&1 ;;
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
            [ -f "$HOME/hands-on-metal/env_registry.sh" ] 2>/dev/null ;;
        *)
            return 1 ;;
    esac
}

# ── Script index ─────────────────────────────────────────────
build_script_index() {
    SCRIPT_LABELS=()
    SCRIPT_PATHS=()
    SCRIPT_TYPES=()

    # Workflow-ordered list: first-to-run at the top, last at the bottom.
    # Phase 1: Setup & Build
    # Phase 2: Environment & Device Detection
    # Phase 3: Boot Image & Pre-patch Analysis
    # Phase 4: Patch & Flash
    # Phase 5: Module Installation & Data Collection
    # Phase 6: Analysis Pipeline
    # Phase 7: Reporting & Sharing
    # Phase 8: Utility / Framework (always runnable)
    local _ordered_scripts=(
        # ── Phase 1: Setup & Build ────────────────────────────
        "shell:build/fetch_all_deps.sh"
        "shell:build/build_offline_zip.sh"
        # ── Phase 2: Environment & Device Detection ───────────
        "shell:magisk-module/env_detect.sh"
        "shell:core/device_profile.sh"
        # ── Phase 3: Boot Image & Pre-patch Analysis ──────────
        "shell:core/boot_image.sh"
        "shell:core/anti_rollback.sh"
        "shell:core/candidate_entry.sh"
        "shell:core/apply_defaults.sh"
        # ── Phase 4: Patch & Flash ────────────────────────────
        "shell:core/magisk_patch.sh"
        "shell:core/flash.sh"
        # ── Phase 5: Module Installation & Data Collection ────
        "shell:magisk-module/customize.sh"
        "shell:magisk-module/service.sh"
        "shell:magisk-module/collect.sh"
        "shell:recovery-zip/collect_recovery.sh"
        "shell:magisk-module/setup_termux.sh"
        # ── Phase 6: Analysis Pipeline ────────────────────────
        "python:pipeline/parse_logs.py"
        "python:pipeline/parse_manifests.py"
        "python:pipeline/parse_pinctrl.py"
        "python:pipeline/parse_symbols.py"
        "python:pipeline/unpack_images.py"
        "python:pipeline/build_table.py"
        # ── Phase 7: Reporting & Sharing ──────────────────────
        "python:pipeline/report.py"
        "python:pipeline/failure_analysis.py"
        "shell:core/share.sh"
        "python:pipeline/upload.py"
        "python:pipeline/github_notify.py"
        "shell:build/host_flash.sh"
        # ── Phase 8: Utility / Framework ──────────────────────
        "shell:core/logging.sh"
        "shell:core/ux.sh"
        "shell:core/privacy.sh"
        "shell:core/state_machine.sh"
    )

    local entry kind rel
    for entry in "${_ordered_scripts[@]}"; do
        kind="${entry%%:*}"
        rel="${entry#*:}"
        if [ -f "$REPO_ROOT/$rel" ]; then
            SCRIPT_LABELS+=("$rel")
            SCRIPT_PATHS+=("$REPO_ROOT/$rel")
            SCRIPT_TYPES+=("$kind")
        fi
    done
}

# ── Prerequisite status cache (rebuilt per print) ─────────────
# STATUS[i] = "ready" | "done" | "missing"
# MISSING_INFO[i] = human-readable string of what is missing
declare -a ITEM_STATUS=()
declare -a MISSING_INFO=()

refresh_status() {
    # Re-source the env registry in case device_profile.sh ran mid-session
    load_env_registry

    ITEM_STATUS=()
    MISSING_INFO=()

    # Re-source the persisted env registry written by core/* scripts via
    # _reg_set (lines like  HOM_DEV_MODEL="Pixel 8"  # cat:device …).
    # Scripts run in a subshell so their exports do not survive back into
    # the menu — but they do persist these vars to env_registry.sh.
    # Sourcing it here lets is_already_done / check_prereq see the state
    # set by previously-run scripts (e.g. HOM_DEV_MODEL after option 4).
    local _reg="${ENV_REGISTRY:-${OUT:-$HOME/hands-on-metal}/env_registry.sh}"
    if [ -f "$_reg" ]; then
        # shellcheck source=/dev/null
        . "$_reg" 2>/dev/null || true
    fi

    local i rel prereqs prereq
    for i in "${!SCRIPT_LABELS[@]}"; do
        rel="${SCRIPT_LABELS[$i]}"

        # 1) Already done?
        if is_already_done "$rel" 2>/dev/null; then
            ITEM_STATUS+=("done")
            MISSING_INFO+=("")
            continue
        fi

        # 2) Check prerequisites
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
                        # Find the menu number for the provider script
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

# ── Suggested next step ──────────────────────────────────────
# Picks the best "ready" script that would unblock the most
# "missing" (blocked) scripts.  Falls back to the first ready
# script in list order when nothing is blocked.
#
# Sets globals:
#   SUGGESTION_IDX  — 0-based index into SCRIPT_LABELS (-1 = none)
#   SUGGESTION_DESC — human-readable reason for the suggestion
compute_suggestion() {
    SUGGESTION_IDX=-1
    SUGGESTION_DESC=""

    # Collect which providers are needed by blocked scripts
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

    # Among ready (not done) scripts, find the one that is a provider
    # for the most blocked items
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

    # If no provider-based match, pick the first ready script
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

# Print the suggestion line (reused by both menus).
print_suggestion_line() {
    compute_suggestion
    echo
    if [ "$SUGGESTION_IDX" -ge 0 ]; then
        local num="$(( SUGGESTION_IDX + 1 ))"
        local rel="${SCRIPT_LABELS[$SUGGESTION_IDX]}"
        printf " %ss) suggested next: option %d (%s)%s\n" \
            "$CLR_LIGHT_GREEN" "$num" "$rel" "$CLR_RESET"
        printf "    %s%s%s\n" "$CLR_LIGHT_GREEN" "$SUGGESTION_DESC" "$CLR_RESET"
    else
        local all_done=true
        for i in "${!ITEM_STATUS[@]}"; do
            if [ "${ITEM_STATUS[$i]}" != "done" ]; then
                all_done=false
                break
            fi
        done
        if [ "$all_done" = true ]; then
            printf " %ss) all steps complete — nothing to suggest%s\n" \
                "$CLR_DARK_GREEN" "$CLR_RESET"
        else
            printf " %ss) no runnable suggestion — resolve external prerequisites first%s\n" \
                "$CLR_YELLOW" "$CLR_RESET"
        fi
    fi
}
print_menu() {
    refresh_status

    echo
    echo "hands-on-metal terminal menu"
    echo "Repository: $REPO_ROOT"
    echo
    echo "  Legend: ${CLR_LIGHT_GREEN}■${CLR_RESET} ready  ${CLR_DARK_GREEN}■${CLR_RESET} done  ${CLR_YELLOW}■${CLR_RESET} needs prerequisites"
    echo

    local i color status_char
    for i in "${!SCRIPT_LABELS[@]}"; do
        case "${ITEM_STATUS[$i]}" in
            ready)
                color="$CLR_LIGHT_GREEN"
                status_char="✓"
                ;;
            done)
                color="$CLR_DARK_GREEN"
                status_char="●"
                ;;
            missing)
                color="$CLR_YELLOW"
                status_char="✗"
                ;;
        esac

        printf "%s%2d) [%s] %s %s%s\n" \
            "$color" "$((i + 1))" "${SCRIPT_TYPES[$i]}" "${SCRIPT_LABELS[$i]}" "$status_char" "$CLR_RESET"

        # Always show the description so every option is self-documenting
        local desc
        desc="$(script_description "${SCRIPT_LABELS[$i]}")"
        if [ -n "$desc" ]; then
            printf "      %s\n" "$desc"
        fi

        if [ "${ITEM_STATUS[$i]}" = "missing" ]; then
            printf "      needs: %s\n" "${MISSING_INFO[$i]}"
        fi
    done

    echo
    print_suggestion_line
    echo
    echo " p) check prerequisites (detailed)"
    echo " r) refresh script list"
    echo " q) quit"
}

# ── Prerequisites sub-menu ───────────────────────────────────
print_prereq_submenu() {
    refresh_status

    echo
    echo "═══════════════════════════════════════════════════════"
    echo " Prerequisites Check"
    echo "═══════════════════════════════════════════════════════"
    echo

    local i rel prereqs prereq
    for i in "${!SCRIPT_LABELS[@]}"; do
        rel="${SCRIPT_LABELS[$i]}"
        prereqs="$(get_prereqs_for_script "$rel")"

        # Header color based on status
        local hdr_color
        case "${ITEM_STATUS[$i]}" in
            ready)   hdr_color="$CLR_LIGHT_GREEN" ;;
            done)    hdr_color="$CLR_DARK_GREEN" ;;
            missing) hdr_color="$CLR_YELLOW" ;;
        esac

        printf "%s%2d) %s%s" "$hdr_color" "$((i + 1))" "$rel" "$CLR_RESET"

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
                            provider_idx="$((j + 1))"
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

    echo "═══════════════════════════════════════════════════════"
    print_suggestion_line
    echo
    echo " Enter) return to main menu"
    echo
    read -r -p "Choose (s or Enter): " sub_choice
    echo "  You entered: $sub_choice"
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

# ── Completion summary (what just happened) ──────────────────
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
            echo "  • Anti-rollback risk assessment stored in HOM_ARB_RISK."
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
            echo "  • Flash verification flag set (HOM_FLASH_VERIFIED=1)."
            ;;
        core/logging.sh)
            echo "Logging framework loaded successfully (sourced by other scripts)."
            ;;
        core/magisk_patch.sh)
            echo "Patched the boot image with Magisk for root access."
            echo "  • Patched image path stored in HOM_PATCHED_IMG."
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
            echo "ZIP build failed. Check that 'zip' is installed and the partition index exists."
            ;;
        build/fetch_all_deps.sh)
            echo "Dependency download failed. Verify network access and that git/curl/unzip are installed."
            ;;
        build/host_flash.sh)
            echo "Host-assisted flash failed. Check device connection, bootloader unlock status, and USB cable."
            echo "  See docs/ADB_FASTBOOT_INSTALL.md for troubleshooting."
            ;;
        core/anti_rollback.sh)
            echo "Rollback check failed. Ensure the boot image file (HOM_BOOT_IMG_PATH) is valid."
            ;;
        core/apply_defaults.sh)
            echo "Could not apply defaults. Ensure device profile and partition index are available."
            ;;
        core/boot_image.sh)
            echo "Could not acquire the boot image."
            echo "  Options: place boot.img in /sdcard/Download, check TWRP/recovery backups,"
            echo "  download GKI image from ci.android.com (Android 12+), or get root access."
            ;;
        core/candidate_entry.sh)
            echo "Candidate entry creation failed. Verify device profile and partition index."
            ;;
        core/device_profile.sh)
            echo "Device detection failed. Ensure you are running on an Android device or in Termux."
            ;;
        core/flash.sh)
            echo "Flash failed. Ensure root access and a valid patched boot image."
            ;;
        core/logging.sh)
            echo "Logging framework failed to load. Check file permissions and available disk space."
            ;;
        core/magisk_patch.sh)
            echo "Magisk patching failed. Ensure the boot image and Magisk binary are available."
            ;;
        core/privacy.sh)
            echo "Privacy helpers failed to load. Check file permissions."
            ;;
        core/share.sh)
            echo "Share bundle creation failed. Ensure env_registry.sh exists and is readable."
            ;;
        core/state_machine.sh)
            echo "State machine framework failed to load. Check file permissions."
            ;;
        core/ux.sh)
            echo "UX helpers failed to load. Ensure core/logging.sh was sourced first."
            ;;
        magisk-module/collect.sh)
            echo "Data collection failed. Ensure you are on an Android device."
            echo "  Without root: some data sources are skipped (dmesg, pinctrl, vendor libs)."
            echo "  With root: all sources are available."
            ;;
        magisk-module/customize.sh)
            echo "Module installation failed. Ensure root access and an Android environment."
            ;;
        magisk-module/env_detect.sh)
            echo "Environment detection failed. Ensure you are on an Android device."
            ;;
        magisk-module/service.sh)
            echo "Boot service failed. Ensure root access and an Android environment."
            ;;
        magisk-module/setup_termux.sh)
            echo "Termux setup failed. Ensure network access and an Android device."
            ;;
        recovery-zip/collect_recovery.sh)
            echo "Recovery-mode collection failed. Ensure root access and an Android device."
            ;;
        pipeline/build_table.py)
            echo "Database build failed. Verify Python 3 and the schema file are present."
            ;;
        pipeline/failure_analysis.py)
            echo "Failure analysis failed. Verify Python 3 is installed."
            ;;
        pipeline/github_notify.py)
            echo "GitHub notification failed. Verify Python 3 is installed."
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                echo "  GITHUB_TOKEN is set — check token permissions (issues:write scope)."
            fi
            ;;
        pipeline/parse_logs.py)
            echo "Log parsing failed. Verify Python 3 is installed."
            ;;
        pipeline/parse_manifests.py)
            echo "Manifest parsing failed. Verify Python 3 and the schema file."
            ;;
        pipeline/parse_pinctrl.py)
            echo "Pinctrl parsing failed. Verify Python 3 and the schema file."
            ;;
        pipeline/parse_symbols.py)
            echo "Symbol parsing failed. Verify Python 3 is installed."
            ;;
        pipeline/report.py)
            echo "Report generation failed. Verify Python 3 is installed."
            ;;
        pipeline/unpack_images.py)
            echo "Image unpacking failed. Verify Python 3 is installed."
            ;;
        pipeline/upload.py)
            echo "Upload failed. Verify Python 3 is installed."
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                echo "  GITHUB_TOKEN is set — check token permissions (gist scope)."
            fi
            ;;
        *)
            echo "Script failed (exit code $rc). Review the output above for details."
            ;;
    esac
}

# ── Next-step instructions ───────────────────────────────────
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
            echo "  → Or flash the recovery ZIP via: TWRP/OrangeFox → Install → select ZIP."
            ;;
        build/fetch_all_deps.sh)
            echo "  → Dependencies are ready. You can now run 'build/build_offline_zip.sh' to build ZIPs."
            ;;
        build/host_flash.sh)
            echo "  → After device reboots: open Magisk app to confirm root."
            echo "  → If using C2 (direct flash): install the Magisk module ZIP via Magisk app."
            echo "  → Pull logs: adb pull ~/hands-on-metal/logs/ ./hom-logs/"
            ;;
        core/anti_rollback.sh)
            echo "  → If no rollback risk was found, proceed to flash (core/flash.sh)."
            echo "  → If a risk was detected, review the SPL/AVB details before flashing."
            ;;
        core/apply_defaults.sh)
            echo "  → Defaults applied. You can now proceed to acquire the boot image (core/boot_image.sh)."
            ;;
        core/boot_image.sh)
            echo "  → Boot image acquired. Next, patch it with Magisk (core/magisk_patch.sh)."
            echo "  → Or check rollback risk first (core/anti_rollback.sh)."
            ;;
        core/candidate_entry.sh)
            echo "  → Candidate entry created. Run 'build/fetch_all_deps.sh' to refresh the partition index."
            ;;
        core/device_profile.sh)
            echo "  → Device detected. Next, apply defaults (core/apply_defaults.sh)"
            echo "    or acquire the boot image (core/boot_image.sh)."
            ;;
        core/flash.sh)
            echo "  → Device flashed and verified. Reboot your device to activate Magisk root."
            echo "  → After reboot, verify root by running: su -c 'id'"
            ;;
        core/logging.sh)
            echo "  → Logging framework is ready. It will be used automatically by other scripts."
            ;;
        core/magisk_patch.sh)
            echo "  → Boot image patched. Next, check rollback risk (core/anti_rollback.sh)"
            echo "    then flash the patched image (core/flash.sh)."
            ;;
        core/privacy.sh)
            echo "  → Privacy helpers are loaded. They will be used automatically during data collection."
            ;;
        core/share.sh)
            echo "  → Diagnostic bundle created. Share it with the project maintainers for analysis."
            echo "  → Or upload it via 'pipeline/upload.py'."
            ;;
        core/state_machine.sh)
            echo "  → State machine is ready. It will be used automatically by the workflow scripts."
            ;;
        core/ux.sh)
            echo "  → UX helpers are loaded. They will be used automatically by other scripts."
            ;;
        magisk-module/collect.sh)
            echo "  → Hardware data collected. Run the pipeline scripts to parse and analyze the data."
            echo "  → Start with 'pipeline/parse_logs.py' or 'pipeline/build_table.py'."
            echo "  → Without root, some sources were skipped. Re-run with root for full data."
            ;;
        magisk-module/customize.sh)
            echo "  → Module installed. Reboot your device for changes to take effect."
            ;;
        magisk-module/env_detect.sh)
            echo "  → Environment registry saved. Other scripts can now use the detected configuration."
            ;;
        magisk-module/service.sh)
            echo "  → Boot service completed. Data should now be collected automatically on each boot."
            ;;
        magisk-module/setup_termux.sh)
            echo "  → Termux is set up. You can now run the full collection (magisk-module/collect.sh)."
            ;;
        recovery-zip/collect_recovery.sh)
            echo "  → Recovery data collected. Run the pipeline scripts to parse and analyze it."
            ;;
        pipeline/build_table.py)
            echo "  → Database built. Generate a report with 'pipeline/report.py'."
            ;;
        pipeline/failure_analysis.py)
            echo "  → Analysis complete. Review the output or post results via 'pipeline/github_notify.py'."
            ;;
        pipeline/github_notify.py)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                echo "  → GitHub issue comment posted. Check the issue for the analysis results."
            else
                echo "  → Dry-run output printed. Set GITHUB_TOKEN to post to GitHub."
            fi
            ;;
        pipeline/parse_logs.py)
            echo "  → Logs parsed. Continue with 'pipeline/build_table.py' to build the database."
            ;;
        pipeline/parse_manifests.py)
            echo "  → Manifests parsed. Continue with 'pipeline/build_table.py' to build the database."
            ;;
        pipeline/parse_pinctrl.py)
            echo "  → Pinctrl parsed. Continue with 'pipeline/build_table.py' to build the database."
            ;;
        pipeline/parse_symbols.py)
            echo "  → Symbols parsed. Continue with 'pipeline/build_table.py' to build the database."
            ;;
        pipeline/report.py)
            echo "  → HTML report generated. Open the report file in a browser to view results."
            ;;
        pipeline/unpack_images.py)
            echo "  → Images unpacked. Proceed with parsing or analysis of the extracted contents."
            ;;
        pipeline/upload.py)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                echo "  → Bundle uploaded to GitHub Gist. Share the Gist URL with collaborators."
            else
                echo "  → Local summary displayed. Set GITHUB_TOKEN and re-run to upload."
            fi
            ;;
        *)
            echo "  → Return to the menu to continue with the next step."
            ;;
    esac
}

# ── Run a selected script ────────────────────────────────────
run_selected() {
    local idx="$1"
    local script="${SCRIPT_PATHS[$idx]}"
    local kind="${SCRIPT_TYPES[$idx]}"
    local rel="${SCRIPT_LABELS[$idx]}"
    local args_array=()

    echo
    echo "Selected: $rel"
    echo "  $(script_description "$rel")"
    echo
    echo "Note: enter space-separated arguments (embedded space quoting is not supported)."
    read -r -a args_array -p "Arguments (optional): "
    if [ "${#args_array[@]}" -gt 0 ]; then
        echo "  You entered: ${args_array[*]}"
    fi

    echo
    echo "Running..."
    # Capture the subshell's exit code via "|| rc=$?" so that the
    # outer "set -e" in this menu does NOT abort before we get a
    # chance to print the SUCCESS/FAILED banner when a script fails.
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
            # Core scripts define functions (run_*) that require
            # logging.sh and ux.sh to be sourced first.  When run
            # from the menu we source the framework, then source
            # the target script, and call its main function.
            case "$rel" in
                core/anti_rollback.sh|core/apply_defaults.sh|\
                core/boot_image.sh|core/candidate_entry.sh|\
                core/device_profile.sh|core/flash.sh|\
                core/magisk_patch.sh|core/share.sh)
                    # Source framework scripts
                    # Intentional: SCRIPT_NAME is only consumed inside this subshell.
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
                    # Source the target script (defines its functions)
                    # shellcheck source=/dev/null
                    source "$script"
                    # Call the appropriate main function
                    case "$rel" in
                        core/anti_rollback.sh)  run_anti_rollback_check "${args_array[@]}" ;;
                        core/apply_defaults.sh) run_apply_defaults "${args_array[@]}" ;;
                        core/boot_image.sh)     run_boot_image_acquire "${args_array[@]}" ;;
                        core/candidate_entry.sh) run_candidate_entry "${args_array[@]}" ;;
                        core/device_profile.sh) run_device_profile "${args_array[@]}" ;;
                        core/flash.sh)          run_flash_magisk_path "${args_array[@]}" ;;
                        core/magisk_patch.sh)   run_magisk_patch "${args_array[@]}" ;;
                        core/share.sh)          run_share "${args_array[@]}" ;;
                    esac
                    ;;
                *)
                    # All other shell scripts run inline (build/*, magisk-module/*, etc.)
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
    echo "═══════════════════════════════════════════════════════"
    if [ "$rc" -eq 0 ]; then
        printf " %s✓ SUCCESS%s — %s\n" "$CLR_LIGHT_GREEN" "$CLR_RESET" "$rel"
        echo "═══════════════════════════════════════════════════════"
        echo
        script_completion_success "$rel"
    else
        printf " %s✗ FAILED (exit code %d)%s — %s\n" "$CLR_YELLOW" "$rc" "$CLR_RESET" "$rel"
        echo "═══════════════════════════════════════════════════════"
        echo
        script_completion_failure "$rel" "$rc"
    fi
    echo
    echo "Next steps:"
    script_next_steps "$rel" "$rc"
    echo
}

# ── Upload-on-exit hook ──────────────────────────────────────
# Build a redacted share bundle (core/share.sh::run_share) for the
# current RUN_ID and feed it to pipeline/upload.py so that, regardless
# of how the menu exits (q, Ctrl-C, error, scripted EOF), the user
# always ends up with an uploaded / summarised diagnostic bundle.
#
# Best-effort: never aborts the exit, never re-traps itself.
# Honours $GITHUB_TOKEN when present (real Gist upload), otherwise
# the upload script prints a local summary (its documented dry-run
# behaviour) — see pipeline/upload.py header.
HOM_EXIT_UPLOAD_DONE=0
run_exit_log_upload() {
    [ "${HOM_EXIT_UPLOAD_DONE:-0}" = "1" ] && return 0
    HOM_EXIT_UPLOAD_DONE=1

    # Disable strict mode for the trap; we never want exit-time
    # housekeeping to abort the script half-way through.
    set +eu

    local out_dir="${OUT:-$HOME/hands-on-metal}"
    local reg="${ENV_REGISTRY:-$out_dir/env_registry.sh}"
    local upload_py="$REPO_ROOT/pipeline/upload.py"

    # Nothing has been collected yet (e.g. fresh checkout on a
    # non-Android host) — silently skip rather than emit noise.
    if [ ! -f "$reg" ] || [ ! -f "$upload_py" ]; then
        return 0
    fi

    echo
    echo "═══════════════════════════════════════════════════════"
    echo " Uploading session logs before exit…"
    echo "═══════════════════════════════════════════════════════"

    # 1) Build (or refresh) the share bundle for this RUN_ID.
    (
        cd "$REPO_ROOT" || exit 0
        # Intentional: this assignment is scoped to this subshell.
        # shellcheck disable=SC2031
        export SCRIPT_NAME="terminal_menu"
        # shellcheck source=/dev/null
        . "$REPO_ROOT/core/logging.sh"   2>/dev/null || exit 0
        # shellcheck source=/dev/null
        . "$REPO_ROOT/core/ux.sh"        2>/dev/null || true
        # shellcheck source=/dev/null
        . "$REPO_ROOT/core/privacy.sh"   2>/dev/null || true
        # shellcheck source=/dev/null
        . "$REPO_ROOT/core/share.sh"     2>/dev/null || exit 0
        run_share >/dev/null 2>&1 || true
    ) || true

    # 2) Locate the most recent share bundle and upload it.
    local share_root="$out_dir/share"
    local bundle=""
    if [ -d "$share_root" ]; then
        # Find the newest subdirectory of share/ without parsing `ls`.
        local candidate newest=""
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
            echo "  (no GITHUB_TOKEN set — printed local summary only;"
            echo "   export GITHUB_TOKEN before launching terminal_menu.sh"
            echo "   to upload the bundle to a Gist on next exit)"
        fi
    else
        echo "  (python3 not found — bundle preserved at: $bundle)"
    fi
}

# ── Main loop ────────────────────────────────────────────────
main() {
    if [ ! -d "$REPO_ROOT/pipeline" ]; then
        echo "Error: pipeline directory not found in repository." >&2
        exit 1
    fi

    # Always upload session logs on exit, however we got there.
    trap 'run_exit_log_upload' EXIT

    build_script_index

    if [ "${#SCRIPT_LABELS[@]}" -eq 0 ]; then
        echo "No scripts found." >&2
        exit 1
    fi

    # Run the startup scan once to gather all available information
    startup_scan

    while true; do
        print_menu
        read -r -p "Choose an option: " choice
        echo "  You entered: $choice"
        # Strip non-alphanumeric bytes: invisible control characters, Unicode
        # zero-width / formatting chars, trailing CR, ANSI remnants, etc. that
        # some terminal emulators and input methods inject on Android / Termux.
        choice="${choice//[!a-zA-Z0-9]/}"

        case "$choice" in
            q|Q)
                echo "Bye."
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
                    echo "No suggestion available."
                fi
                continue
                ;;
            ''|*[!0-9]*)
                echo "Invalid choice."
                ;;
            *)
                if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#SCRIPT_LABELS[@]}" ]; then
                    echo "Invalid choice."
                else
                    run_selected "$((choice - 1))"
                fi
                ;;
        esac
    done
}

main "$@"
