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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── dependency check (runs once per session) ──────────────────
source "$REPO_ROOT/check_deps.sh" || exit 1

# ── load device environment registry (if available) ──────────
# device_profile.sh writes HOM_DEV_* variables (build ID, boot
# partition type, codename, etc.) to this file.  Sourcing it
# makes that context available for display in the menu.
_HOM_ENV_REGISTRY="/sdcard/hands-on-metal/env_registry.sh"
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
        magisk-module/collect.sh)             echo "root android_device env_registry" ;;
        magisk-module/customize.sh)           echo "root android_device" ;;
        magisk-module/env_detect.sh)          echo "android_device" ;;
        magisk-module/service.sh)             echo "root android_device" ;;
        magisk-module/setup_termux.sh)        echo "android_device network" ;;
        recovery-zip/collect_recovery.sh)     echo "root android_device" ;;
        pipeline/build_table.py)              echo "cmd:python3 schema" ;;
        pipeline/failure_analysis.py)         echo "cmd:python3" ;;
        pipeline/github_notify.py)            echo "cmd:python3 env_github_token" ;;
        pipeline/parse_logs.py)               echo "cmd:python3" ;;
        pipeline/parse_manifests.py)          echo "cmd:python3 schema" ;;
        pipeline/parse_pinctrl.py)            echo "cmd:python3 schema" ;;
        pipeline/parse_symbols.py)            echo "cmd:python3" ;;
        pipeline/report.py)                   echo "cmd:python3" ;;
        pipeline/unpack_images.py)            echo "cmd:python3" ;;
        pipeline/upload.py)                   echo "cmd:python3 env_github_token" ;;
        *)                                    echo "" ;;
    esac
}

# Human-readable label for a prerequisite ID.
prereq_label() {
    local prereq="$1"
    case "$prereq" in
        root)             echo "root (superuser) access" ;;
        network)          echo "network / internet access" ;;
        boot_image)       echo "boot image file (HOM_BOOT_IMG_PATH)" ;;
        magisk_binary)    echo "Magisk binary" ;;
        device_profile)   echo "device profile (core/device_profile.sh)" ;;
        env_registry)     echo "environment registry (/sdcard/hands-on-metal/env_registry.sh)" ;;
        android_device)   echo "Android device environment" ;;
        partition_index)  echo "partition index (build/partition_index.json)" ;;
        schema)           echo "database schema (schema/hardware_map.sql)" ;;
        env_github_token) echo "GITHUB_TOKEN environment variable" ;;
        cmd:*)            echo "command: ${prereq#cmd:}" ;;
        *)                echo "$prereq" ;;
    esac
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
            [ -n "${HOM_BOOT_IMG_PATH:-}" ] \
                && [ -f "${HOM_BOOT_IMG_PATH:-/nonexistent}" ] ;;
        magisk_binary)
            command -v magisk >/dev/null 2>&1 \
                || [ -f "/data/adb/magisk/magisk" ] 2>/dev/null ;;
        device_profile)
            [ -n "${HOM_DEV_MODEL:-}" ] ;;
        env_registry)
            [ -f "/sdcard/hands-on-metal/env_registry.sh" ] 2>/dev/null ;;
        android_device)
            [ -n "$(getprop ro.build.display.id 2>/dev/null || true)" ] \
                || [ -d "/data/data/com.termux" ] 2>/dev/null ;;
        partition_index)
            [ -f "$REPO_ROOT/build/partition_index.json" ] ;;
        schema)
            [ -f "$REPO_ROOT/schema/hardware_map.sql" ] ;;
        env_github_token)
            [ -n "${GITHUB_TOKEN:-}" ] ;;
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
        *)                echo "" ;;
    esac
}

# Human-readable description of what a script does.
script_description() {
    local rel="$1"
    case "$rel" in
        build/build_offline_zip.sh)        echo "Build flashable offline ZIPs (Magisk module + recovery)" ;;
        build/fetch_all_deps.sh)           echo "Download Magisk APK, busybox, and create offline bundle" ;;
        core/anti_rollback.sh)             echo "Check SPL / AVB rollback risk before flashing" ;;
        core/apply_defaults.sh)            echo "Apply device-family defaults from partition index" ;;
        core/boot_image.sh)                echo "Acquire the boot or init_boot image from the device" ;;
        core/candidate_entry.sh)           echo "Create a candidate entry for an unknown device" ;;
        core/device_profile.sh)            echo "Detect device model, partitions, AVB, and Treble support" ;;
        core/flash.sh)                     echo "Flash patched boot image to device and verify" ;;
        core/logging.sh)                   echo "Shared logging framework (sourced by other scripts)" ;;
        core/magisk_patch.sh)              echo "Patch boot image with Magisk for root access" ;;
        core/privacy.sh)                   echo "Privacy-by-default PII redaction helpers" ;;
        core/share.sh)                     echo "Create a shareable diagnostic bundle (PII redacted)" ;;
        core/state_machine.sh)             echo "Persistent reboot-safe workflow state tracker" ;;
        core/ux.sh)                        echo "User-experience output helpers (TWRP / shell / service)" ;;
        magisk-module/collect.sh)          echo "Read-only hardware data collection on rooted device" ;;
        magisk-module/customize.sh)        echo "Main Magisk module installation hook (full workflow)" ;;
        magisk-module/env_detect.sh)       echo "Detect shell, tools, Python, Termux on device" ;;
        magisk-module/service.sh)          echo "Boot service: env detect, Termux setup, collection" ;;
        magisk-module/setup_termux.sh)     echo "Install and bootstrap Termux with required packages" ;;
        recovery-zip/collect_recovery.sh)  echo "Recovery-mode collection with read-only mounts" ;;
        pipeline/build_table.py)           echo "Build hardware-map SQLite database from collected data" ;;
        pipeline/failure_analysis.py)      echo "Analyse install logs for failure patterns" ;;
        pipeline/github_notify.py)         echo "Post analysis results as a GitHub issue comment" ;;
        pipeline/parse_logs.py)            echo "Parse master log and run-manifest files" ;;
        pipeline/parse_manifests.py)       echo "Parse VINTF / sysconfig / permissions XML manifests" ;;
        pipeline/parse_pinctrl.py)         echo "Parse pinctrl debug files into database" ;;
        pipeline/parse_symbols.py)         echo "Parse vendor library symbols and ELF sections" ;;
        pipeline/report.py)                echo "Generate HTML hardware report from database" ;;
        pipeline/unpack_images.py)         echo "Unpack boot / vendor-boot images and extract ramdisk" ;;
        pipeline/upload.py)                echo "Upload diagnostic bundle to GitHub Gist" ;;
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
            [ -n "${HOM_ARB_RISK:-}" ] ;;
        core/magisk_patch.sh)
            [ -n "${HOM_PATCHED_IMG:-}" ] \
                && [ -f "${HOM_PATCHED_IMG:-/nonexistent}" ] 2>/dev/null ;;
        core/flash.sh)
            [ "${HOM_FLASH_VERIFIED:-}" = "1" ] 2>/dev/null ;;
        magisk-module/env_detect.sh)
            [ -f "/sdcard/hands-on-metal/env_registry.sh" ] 2>/dev/null ;;
        *)
            return 1 ;;
    esac
}

# ── Script index ─────────────────────────────────────────────
build_script_index() {
    SCRIPT_LABELS=()
    SCRIPT_PATHS=()
    SCRIPT_TYPES=()

    local path rel
    while IFS= read -r path; do
        rel="${path#"$REPO_ROOT"/}"
        SCRIPT_LABELS+=("$rel")
        SCRIPT_PATHS+=("$path")
        SCRIPT_TYPES+=("shell")
    done < <(find \
        "$REPO_ROOT/build" \
        "$REPO_ROOT/core" \
        "$REPO_ROOT/magisk-module" \
        "$REPO_ROOT/recovery-zip" \
        -type f -name "*.sh" | sort)

    while IFS= read -r path; do
        rel="${path#"$REPO_ROOT"/}"
        SCRIPT_LABELS+=("$rel")
        SCRIPT_PATHS+=("$path")
        SCRIPT_TYPES+=("python")
    done < <(find "$REPO_ROOT/pipeline" -maxdepth 1 -type f -name "*.py" | sort)
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

        printf "%s%2d) [%s] %s %s%s" \
            "$color" "$((i + 1))" "${SCRIPT_TYPES[$i]}" "${SCRIPT_LABELS[$i]}" "$status_char" "$CLR_RESET"

        if [ "${ITEM_STATUS[$i]}" = "missing" ]; then
            printf "\n      needs: %s" "${MISSING_INFO[$i]}"
        fi
        printf "\n"
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

# ── Script-specific argument help ─────────────────────────────
# Returns a description of accepted CLI arguments for a given
# script, or empty if the script takes no arguments.
# Also returns whether the script accepts arguments at all.
script_arguments_help() {
    local rel="$1"
    case "$rel" in
        build/build_offline_zip.sh)
            echo "Accepted arguments:"
            echo "  --version <version>   Override module version (default: from module.prop)"
            echo "  --no-tools            Skip tool validation"
            echo ""
            echo "Example:  --version 2.1.0"
            ;;
        build/fetch_all_deps.sh)
            echo "Accepted arguments:"
            echo "  --magisk-version <ver>   Magisk release to fetch  (default: v30.7)"
            echo "  --busybox-version <ver>  BusyBox release to fetch (default: 1.31.0)"
            echo "  --version <ver>          Override module version"
            echo "  --skip-binaries          Skip binary downloads (repo + ZIPs only)"
            echo ""
            echo "Example:  --magisk-version v30.8 --version 2.1.0"
            ;;
        *)
            ;;
    esac
}

# Returns "true" if the script accepts CLI arguments, "false" otherwise.
script_accepts_args() {
    local rel="$1"
    case "$rel" in
        build/build_offline_zip.sh|build/fetch_all_deps.sh) echo "true" ;;
        *) echo "false" ;;
    esac
}

# ── Boot image context display ────────────────────────────────
# For scripts that deal with boot images, display current device
# context so the user knows what the script will look for.
show_boot_image_context() {
    local rel="$1"

    # Only relevant for boot-image-related scripts
    case "$rel" in
        core/boot_image.sh|core/magisk_patch.sh|core/flash.sh|core/anti_rollback.sh)
            ;;
        *)
            return
            ;;
    esac

    # Reload env registry for freshest device info
    load_env_registry

    local boot_part="${HOM_DEV_BOOT_PART:-}"
    local build_id="${HOM_DEV_BUILD_ID:-}"
    local codename="${HOM_DEV_DEVICE:-}"
    local model="${HOM_DEV_MODEL:-}"
    local android_ver="${HOM_DEV_ANDROID_VER:-}"
    local sdk_int="${HOM_DEV_SDK_INT:-}"

    # Only show context if device profile info is available
    if [ -z "$boot_part" ] && [ -z "$codename" ]; then
        return
    fi

    echo ""
    echo "  ─── Device context ───────────────────────────────"

    if [ -n "$model" ]; then
        echo "  Device        : ${HOM_DEV_BRAND:-} $model ($codename)"
    elif [ -n "$codename" ]; then
        echo "  Device        : $codename"
    fi

    if [ -n "$android_ver" ] && [ -n "$sdk_int" ]; then
        echo "  Android       : $android_ver (API $sdk_int)"
    fi

    if [ -n "$build_id" ]; then
        echo "  Build ID      : $build_id"
    fi

    if [ -n "$boot_part" ]; then
        if [ "$boot_part" = "init_boot" ]; then
            echo "  Patch target  : ${CLR_LIGHT_GREEN}init_boot${CLR_RESET} (Android 13+ / API 33+)"
            echo "  Expected file : init_boot.img"
        else
            echo "  Patch target  : ${CLR_LIGHT_GREEN}boot${CLR_RESET} (standard boot partition)"
            echo "  Expected file : boot.img"
        fi
    fi

    # Show factory image source info for boot_image.sh
    if [ "$rel" = "core/boot_image.sh" ]; then
        echo ""
        echo "  ─── Image acquisition strategy ─────────────────"
        echo "  The script will try these sources in order:"
        echo "    1) Root DD copy from live partition (requires root)"
        echo "    2) Pre-placed file scan: /sdcard/Download/${boot_part:-boot}.img"
        if [ -n "$codename" ] && [ -f "$REPO_ROOT/build/partition_index.json" ] \
            && grep -q "\"${codename}\"" "$REPO_ROOT/build/partition_index.json" 2>/dev/null; then
            local bid_lower=""
            [ -n "$build_id" ] && bid_lower=$(echo "$build_id" | tr 'A-Z' 'a-z')
            echo "    3) Google factory image download (Pixel detected)"
            if [ -n "$bid_lower" ]; then
                echo "       wget URL: https://dl.google.com/dl/android/aosp/${codename}-${bid_lower}-factory.zip"
            else
                echo "       wget URL: https://dl.google.com/dl/android/aosp/${codename}-{build_id}-factory.zip"
                echo "       (build ID not yet detected — run device_profile.sh first)"
            fi
        fi
        echo "    4) Manual path prompt (final fallback)"
        echo ""
        echo "  NOTE: Common filenames like boot.img, init_boot.img, magisk_patched.img,"
        echo "  magisk.zip, or other names will be recognized if placed in /sdcard/Download/."
        echo "  The file must contain a valid Android boot image (ANDROID! magic header)."
    fi

    echo "  ─────────────────────────────────────────────────"
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

    # Show script-specific argument help or boot image context
    local help_text
    help_text="$(script_arguments_help "$rel")"
    local accepts_args
    accepts_args="$(script_accepts_args "$rel")"

    if [ "$accepts_args" = "true" ]; then
        echo ""
        echo "$help_text"
        echo "Note: enter space-separated arguments (embedded space quoting is not supported)."
        read -r -a args_array -p "Arguments (optional): "
    else
        show_boot_image_context "$rel"
    fi

    echo
    echo "Running..."
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
            if [ "${#args_array[@]}" -gt 0 ]; then
                bash "$script" "${args_array[@]}"
            else
                bash "$script"
            fi
        fi
    )
    local rc=$?
    echo
    echo "Exit code: $rc"
    echo
}

# ── Main loop ────────────────────────────────────────────────
main() {
    if [ ! -d "$REPO_ROOT/pipeline" ]; then
        echo "Error: pipeline directory not found in repository." >&2
        exit 1
    fi

    build_script_index

    if [ "${#SCRIPT_LABELS[@]}" -eq 0 ]; then
        echo "No scripts found." >&2
        exit 1
    fi

    while true; do
        print_menu
        read -r -p "Choose an option: " choice

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
