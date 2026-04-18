#!/usr/bin/env bash
# build/host_flash.sh
# ============================================================
# hands-on-metal — Host-Assisted Flash (Mode C)
#
# Flashes a TARGET device from the system running this script
# (the HOST). The host can be a PC (Linux/macOS/Windows) or
# another Android device (Termux via USB OTG or wireless ADB).
#
# Terminology:
#   HOST   = the machine running this script
#   TARGET = the device being flashed (connected via USB/OTG/wireless)
#
# Supports three sub-paths:
#   C1 — Temporary TWRP boot:  fastboot boot twrp.img
#   C2 — Direct fastboot flash of a pre-patched boot image
#   C3 — ADB sideload (requires recovery on target device)
#
# Prerequisites (checked automatically):
#   - adb and fastboot commands available on HOST
#   - TARGET device connected and detected via ADB or fastboot
#   - Unlocked bootloader on TARGET (for C1 and C2)
#
# Usage:
#   bash build/host_flash.sh                          # interactive menu
#   bash build/host_flash.sh --c1 TWRP                # boot TWRP image
#   bash build/host_flash.sh --c2 IMG                 # flash pre-patched image
#   bash build/host_flash.sh --c3 ZIP                 # sideload recovery ZIP
#   bash build/host_flash.sh -s SERIAL --c2 IMG       # target specific device
#
# Options:
#   -s SERIAL    Target a specific device by serial number.
#                Required when multiple devices are connected.
#                Use 'adb devices' or 'fastboot devices' to list serials.
#
# This script follows the same conventions as the terminal menu:
#   - Prerequisite checking via check_deps.sh IDs
#   - Color-coded output (host ℹ green, target ▸ cyan)
#   - Completion and next-step messages
#   - Non-destructive by default (confirms before flashing)
# ============================================================

set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/build/dist"

# ── Host OS detection ─────────────────────────────────────────
# Detect the host platform so commands, paths, and instructions
# are tailored to the system this script is running on.

_detect_host_os() {
    local os_name
    os_name="$(uname -s 2>/dev/null || echo unknown)"
    case "$os_name" in
        Linux*)
            if [ -d "/data/data/com.termux/files/usr" ] || [ -n "${TERMUX_VERSION:-}" ]; then
                HOM_HOST_OS="termux"
            elif [ -n "$(getprop ro.build.display.id 2>/dev/null || true)" ]; then
                HOM_HOST_OS="android"
            else
                HOM_HOST_OS="linux"
            fi
            ;;
        Darwin*)  HOM_HOST_OS="macos" ;;
        MINGW*|MSYS*|CYGWIN*)  HOM_HOST_OS="windows" ;;
        *)        HOM_HOST_OS="unknown" ;;
    esac
}

_detect_host_os

# ── Colors ────────────────────────────────────────────────────
CLR_GREEN=$'\033[92m'
CLR_YELLOW=$'\033[33m'
CLR_RED=$'\033[91m'
CLR_CYAN=$'\033[96m'
CLR_RESET=$'\033[0m'

if [ ! -t 1 ]; then
    CLR_GREEN="" CLR_YELLOW="" CLR_RED="" CLR_CYAN="" CLR_RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────

info()  { printf "%s  ℹ  %s%s\n" "$CLR_GREEN"  "$1" "$CLR_RESET"; }
warn()  { printf "%s  ⚠  %s%s\n" "$CLR_YELLOW" "$1" "$CLR_RESET"; }
fail()  { printf "%s  ✗  %s%s\n" "$CLR_RED"    "$1" "$CLR_RESET" >&2; exit 1; }
ok()    { printf "%s  ✓  %s%s\n" "$CLR_GREEN"  "$1" "$CLR_RESET"; }
# Target-prefixed messages (cyan ▸) to distinguish from host (green ℹ)
tgt()   { printf "%s  ▸  [TARGET] %s%s\n" "$CLR_CYAN" "$1" "$CLR_RESET"; }

# ── Debugging enable instructions ────────────────────────────
# Shows step-by-step instructions for enabling Developer Options
# and USB/wireless debugging on the TARGET device.

_show_debug_enable_instructions() {
    local mode="${1:-usb}"  # "usb" or "wireless" or "both"
    echo ""
    echo "  ${CLR_YELLOW}┌──────────────────────────────────────────────────────────────┐${CLR_RESET}"
    echo "  ${CLR_YELLOW}│  How to enable ADB debugging on TARGET device               │${CLR_RESET}"
    echo "  ${CLR_YELLOW}└──────────────────────────────────────────────────────────────┘${CLR_RESET}"
    echo ""
    echo "  Step 1: Enable Developer Options (if not already visible)"
    echo "    On TARGET: Settings → About phone → tap 'Build number' 7 times"
    echo "    You will see: 'You are now a developer!'"
    echo ""
    if [ "$mode" = "usb" ] || [ "$mode" = "both" ]; then
        echo "  Step 2: Enable USB debugging"
        echo "    On TARGET: Settings → Developer options (or System → Developer options)"
        echo "      → Toggle ON: 'USB debugging'"
        echo "    When you connect the USB cable, TARGET will prompt:"
        echo "      'Allow USB debugging?' → tap 'Allow' (check 'Always allow' for this HOST)"
        echo ""
    fi
    if [ "$mode" = "wireless" ] || [ "$mode" = "both" ]; then
        echo "  Step 2: Enable Wireless debugging (Android 11+)"
        echo "    On TARGET: Settings → Developer options"
        echo "      → Toggle ON: 'Wireless debugging'"
        echo "      → Tap 'Pair device with pairing code' to get the code"
        echo ""
    fi
    echo "  ${CLR_CYAN}Note: Developer options may be under Settings → System → Developer options${CLR_RESET}"
    echo "  ${CLR_CYAN}      on some devices, or Settings → Additional settings → Developer options.${CLR_RESET}"
    echo ""
}

# ── Elevated ADB tools (Shizuku / LADB) ─────────────────────
# Shizuku and LADB provide ADB shell-level (UID 2000) permissions
# on-device WITHOUT root. This is higher than normal app permissions
# but lower than root (UID 0).
#
# Shizuku: runs an ADB-privilege process that grants shell-level
#   access to other apps via its API. Requires wireless debugging
#   (Android 11+) or USB ADB to start.
#   https://shizuku.rikka.app/
#
# LADB: on-device ADB shell app — gives a terminal with shell-user
#   privileges. Uses wireless debugging internally.
#   https://github.com/tytydraco/LADB
#
# What elevated (shell-level, UID 2000) access enables:
#   ✓ Read more /proc and /sys files (iomem, interrupts, etc.)
#   ✓ Run pm (package manager), am (activity manager) commands
#   ✓ Access Settings.Secure, Settings.Global databases
#   ✓ Read logcat without filtering
#   ✓ Better access to /vendor and /system files
#   ✓ List /dev/block/by-name/ symlinks (partition NAME → device NODE mapping)
#   ✗ CANNOT read block device DATA (dd /dev/block/* — SELinux blocks UID 2000)
#   ✗ CANNOT write to /dev/block/ (needs root)
#   ✗ CANNOT flash boot images (needs root or fastboot)
#
# IMPORTANT: /dev/block/ access without root gives SYMLINKS ONLY.
# You can see which partition names exist and what block device nodes
# they map to (e.g., boot → sda18), but you CANNOT read the actual
# partition data. SELinux policy (u:object_r:block_device:s0) blocks
# reads from the shell user. Only root (UID 0) can dd block devices.
#
# For hands-on-metal, elevated access improves data collection
# quality significantly even without root, but partition IMAGE
# dumps still require root.

# Detect if Shizuku is running on TARGET
_check_shizuku() {
    if _adb shell "pm list packages 2>/dev/null" | grep -q "moe.shizuku.privileged.api"; then
        if _adb shell "dumpsys activity services moe.shizuku.privileged.api 2>/dev/null" | grep -q "ServiceRecord"; then
            echo "running"
            return 0
        fi
        echo "installed"
        return 0
    fi
    echo "not_installed"
    return 1
}

# Detect if LADB is installed on TARGET
_check_ladb() {
    if _adb shell "pm list packages 2>/dev/null" | grep -q "com.draco.ladb"; then
        echo "installed"
        return 0
    fi
    echo "not_installed"
    return 1
}

# Show instructions for setting up Shizuku or LADB
_show_elevated_setup_instructions() {
    echo ""
    echo "  ${CLR_YELLOW}┌──────────────────────────────────────────────────────────────┐${CLR_RESET}"
    echo "  ${CLR_YELLOW}│  Elevated ADB tools — shell-level access without root       │${CLR_RESET}"
    echo "  ${CLR_YELLOW}└──────────────────────────────────────────────────────────────┘${CLR_RESET}"
    echo ""
    echo "  These tools provide ADB shell-level (UID 2000) permissions on TARGET"
    echo "  WITHOUT root. They improve data collection quality significantly."
    echo ""
    echo "  ${CLR_CYAN}Option 1: Shizuku (recommended — grants elevated access to apps)${CLR_RESET}"
    echo "    1. Install Shizuku from Google Play or GitHub:"
    echo "       https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api"
    echo "       https://github.com/RikkaApps/Shizuku/releases"
    echo "    2. Enable Wireless debugging on TARGET:"
    echo "       Settings → Developer options → Wireless debugging → ON"
    echo "    3. Open Shizuku app → tap 'Start via Wireless debugging'"
    echo "       → Follow the pairing steps in the app"
    echo "    4. Shizuku now provides elevated access to compatible apps"
    echo ""
    echo "  ${CLR_CYAN}Option 2: LADB (on-device ADB shell terminal)${CLR_RESET}"
    echo "    1. Install LADB from Google Play or GitHub:"
    echo "       https://play.google.com/store/apps/details?id=com.draco.ladb"
    echo "       https://github.com/tytydraco/LADB/releases"
    echo "    2. Enable Wireless debugging on TARGET"
    echo "    3. Open LADB → pair when prompted"
    echo "    4. You now have an ADB shell with elevated (shell user) privileges"
    echo ""
    echo "  ${CLR_GREEN}What elevated access enables for hands-on-metal:${CLR_RESET}"
    echo "    ✓ Better /proc and /sys reads (iomem, interrupts without restriction)"
    echo "    ✓ Full logcat access (no PID filtering)"
    echo "    ✓ Package manager and activity manager commands"
    echo "    ✓ Access to more vendor/system files for VINTF manifest collection"
    echo "    ✓ Settings database reads (Settings.Secure, Settings.Global)"
    echo ""
    echo "  ${CLR_YELLOW}What elevated access still CANNOT do:${CLR_RESET}"
    echo "    ✗ Read/write partition block devices (dd /dev/block/*) — needs root"
    echo "    ✗ Flash boot images — needs root (Mode A/B) or fastboot (Mode C)"
    echo "    ✗ Modify system partition — needs root"
    echo ""
}

# Run elevated-aware dump — uses shell-level access if available
run_elevated_setup() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Elevated ADB Setup — Shizuku / LADB"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "HOST: $HOM_HOST_OS"

    # Check TARGET connection
    if check_device_adb; then
        if [ -z "$HOM_TARGET_SERIAL" ]; then
            _resolve_target_serial adb
        fi
        _identify_target_adb
        _print_target_banner
    else
        warn "No TARGET connected. Connect first via USB or WiFi ADB."
        _show_debug_enable_instructions "both"
        return 1
    fi

    # Detect current state
    local shizuku_state ladb_state
    shizuku_state=$(_check_shizuku 2>/dev/null || echo "not_installed")
    ladb_state=$(_check_ladb 2>/dev/null || echo "not_installed")

    echo "  Current state on TARGET:"
    case "$shizuku_state" in
        running)       echo "    Shizuku: ${CLR_GREEN}✓ running${CLR_RESET}" ;;
        installed)     echo "    Shizuku: ${CLR_YELLOW}● installed (not started)${CLR_RESET}" ;;
        not_installed) echo "    Shizuku: ${CLR_RED}✗ not installed${CLR_RESET}" ;;
    esac
    case "$ladb_state" in
        installed)     echo "    LADB:    ${CLR_GREEN}✓ installed${CLR_RESET}" ;;
        not_installed) echo "    LADB:    ${CLR_RED}✗ not installed${CLR_RESET}" ;;
    esac
    echo ""

    if [ "$shizuku_state" = "running" ]; then
        ok "Shizuku is already running on TARGET."
        echo "  Elevated data collection is available. Run:"
        echo "    bash build/host_flash.sh --dump"
        echo ""
        echo "  The dump command will automatically use elevated access"
        echo "  for improved /proc, /sys, and vendor file collection."
    elif [ "$shizuku_state" = "installed" ]; then
        info "Shizuku is installed but not started."
        echo ""
        echo "  On TARGET: open Shizuku app → tap 'Start'"
        echo "  If wireless debugging method:"
        echo "    Shizuku → 'Start via Wireless debugging' → follow pairing steps"
        echo "  If connected via USB ADB:"
        echo "    Shizuku → 'Start via connected ADB' (auto-detected)"
        echo ""
        read -r -p "  Press Enter when Shizuku is started on TARGET..."
        local new_state
        new_state=$(_check_shizuku 2>/dev/null || echo "not_installed")
        if [ "$new_state" = "running" ]; then
            ok "Shizuku is now running. Elevated access available."
        else
            warn "Shizuku still not detected as running. You can try again later."
        fi
    else
        _show_elevated_setup_instructions

        echo "  Would you like to:"
        echo "    1) Continue without elevated access (standard ADB)"
        echo "    2) I've installed Shizuku/LADB — check again"
        echo ""
        read -r -p "  Choose [1/2]: " elevated_choice
        if [ "$elevated_choice" = "2" ]; then
            shizuku_state=$(_check_shizuku 2>/dev/null || echo "not_installed")
            if [ "$shizuku_state" = "running" ]; then
                ok "Shizuku detected and running!"
            elif [ "$shizuku_state" = "installed" ]; then
                info "Shizuku installed. Start it from the app, then run --dump."
            else
                info "No elevated tools detected. Continuing with standard ADB access."
            fi
        fi
    fi

    echo ""
    echo "  Next steps:"
    echo "    • Run 'bash build/host_flash.sh --dump' for data collection"
    echo "    • Run 'bash build/host_flash.sh --wifi-setup' if not connected yet"
    echo ""
}

# ── Target device serial ─────────────────────────────────────
# If set, all adb/fastboot commands are routed to this device.
# Set via -s <serial> option.
HOM_TARGET_SERIAL="${HOM_TARGET_SERIAL:-}"

# Wrappers that inject -s <serial> when a target is specified.
# All device commands MUST go through these wrappers.
_adb() {
    if [ -n "$HOM_TARGET_SERIAL" ]; then
        adb -s "$HOM_TARGET_SERIAL" "$@"
    else
        adb "$@"
    fi
}

_fastboot() {
    if [ -n "$HOM_TARGET_SERIAL" ]; then
        fastboot -s "$HOM_TARGET_SERIAL" "$@"
    else
        fastboot "$@"
    fi
}

# ── Target device identification ─────────────────────────────
# Reads model, build, serial from the target to display in headers
# and confirmation prompts. Called once after connection is established.

HOM_TARGET_MODEL=""
HOM_TARGET_BUILD=""
HOM_TARGET_SERIAL_DISPLAY=""
HOM_TARGET_ANDROID_VER=""

_identify_target_adb() {
    HOM_TARGET_MODEL=$(_adb shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "unknown")
    HOM_TARGET_BUILD=$(_adb shell getprop ro.build.display.id 2>/dev/null | tr -d '\r' || echo "unknown")
    HOM_TARGET_ANDROID_VER=$(_adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || echo "unknown")
    HOM_TARGET_SERIAL_DISPLAY=$(_adb get-serialno 2>/dev/null | tr -d '\r' || echo "${HOM_TARGET_SERIAL:-unknown}")
}

_identify_target_fastboot() {
    HOM_TARGET_SERIAL_DISPLAY=$(_fastboot getvar serialno 2>&1 | grep 'serialno:' | awk '{print $2}' || echo "${HOM_TARGET_SERIAL:-unknown}")
    HOM_TARGET_MODEL=$(_fastboot getvar product 2>&1 | grep 'product:' | awk '{print $2}' || echo "unknown")
    HOM_TARGET_BUILD=""
    HOM_TARGET_ANDROID_VER=""
}

_print_target_banner() {
    echo ""
    echo "  ┌──────────────────────────────────────────────────┐"
    printf "  │  HOST   : %-40s│\n" "$HOM_HOST_OS ($(uname -m 2>/dev/null || echo unknown))"
    printf "  │  TARGET : %-40s│\n" "${HOM_TARGET_MODEL:-not yet detected}"
    if [ -n "$HOM_TARGET_BUILD" ]; then
        printf "  │  Build  : %-40s│\n" "$HOM_TARGET_BUILD"
    fi
    if [ -n "$HOM_TARGET_ANDROID_VER" ]; then
        printf "  │  Android: %-40s│\n" "$HOM_TARGET_ANDROID_VER"
    fi
    printf "  │  Serial : %-40s│\n" "${HOM_TARGET_SERIAL_DISPLAY:-auto-detect}"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""

    # Device-to-device warning
    if [ "$HOM_HOST_OS" = "termux" ] || [ "$HOM_HOST_OS" = "android" ]; then
        local host_model
        host_model=$(getprop ro.product.model 2>/dev/null || echo "this device")
        if [ "$HOM_TARGET_MODEL" = "$host_model" ] && [ "$HOM_TARGET_MODEL" != "unknown" ]; then
            warn "HOST and TARGET appear to be the same device ($host_model)."
            echo "    You cannot flash the device you're running on via ADB/fastboot."
            echo "    To flash THIS device, use Mode A (Magisk) or Mode B (Recovery) instead."
            echo ""
            read -r -p "  Continue anyway? [y/N]: " cont
            [ "$cont" = "y" ] || [ "$cont" = "Y" ] || exit 0
        else
            info "Device-to-device mode: $host_model (HOST) → ${HOM_TARGET_MODEL} (TARGET)"
        fi
    fi
}

# Resolve which target device to use when multiple are connected.
_resolve_target_serial() {
    local mode="$1"  # "adb" or "fastboot"
    local devices=""
    local count=0

    if [ -n "$HOM_TARGET_SERIAL" ]; then
        return 0  # already set via -s option
    fi

    if [ "$mode" = "adb" ]; then
        devices=$(adb devices 2>/dev/null | grep -E '\t(device|recovery|sideload)' | awk '{print $1}')
    else
        devices=$(fastboot devices 2>/dev/null | awk '{print $1}')
    fi

    count=$(echo "$devices" | grep -c . 2>/dev/null || echo 0)

    if [ "$count" -eq 0 ]; then
        return 1  # no devices
    elif [ "$count" -eq 1 ]; then
        HOM_TARGET_SERIAL="$devices"
        return 0
    else
        # Multiple devices — user must pick
        echo ""
        warn "Multiple devices detected. Select the TARGET device to flash:"
        echo ""
        local i=1
        local serials=()
        while IFS= read -r serial; do
            serials+=("$serial")
            local label=""
            if [ "$mode" = "adb" ]; then
                label=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "")
            else
                label=$(fastboot -s "$serial" getvar product 2>&1 | grep 'product:' | awk '{print $2}' || echo "")
            fi
            printf "    %d) %s  %s\n" "$i" "$serial" "${label:+($label)}"
            i=$((i + 1))
        done <<< "$devices"

        echo ""
        read -r -p "  Select target [1-$count]: " pick
        if [ -z "$pick" ] || [ "$pick" -lt 1 ] 2>/dev/null || [ "$pick" -gt "$count" ] 2>/dev/null; then
            fail "Invalid selection. Use -s <serial> to specify the target device."
        fi
        HOM_TARGET_SERIAL="${serials[$((pick - 1))]}"
        ok "Selected target: $HOM_TARGET_SERIAL"
        return 0
    fi
}

# ── Prerequisite checks (OS-tailored) ─────────────────────────

# Print the correct install instructions for this host OS.
_install_instructions() {
    case "$HOM_HOST_OS" in
        linux)
            echo "  Install Android Platform Tools:"
            if command -v apt-get >/dev/null 2>&1; then
                echo "    sudo apt-get install android-tools-adb android-tools-fastboot"
            elif command -v dnf >/dev/null 2>&1; then
                echo "    sudo dnf install android-tools"
            elif command -v pacman >/dev/null 2>&1; then
                echo "    sudo pacman -S android-tools"
            else
                echo "    Download from https://developer.android.com/tools/releases/platform-tools"
                echo "    Extract and add the directory to your PATH."
            fi
            echo ""
            echo "  USB permissions (if 'no permissions' error):"
            echo "    sudo usermod -aG plugdev \$USER"
            echo "    # Then add a udev rule or install android-udev-rules:"
            echo "    sudo apt-get install android-sdk-platform-tools-common  # includes udev rules"
            echo "    # Log out and back in for group changes to take effect."
            ;;
        macos)
            echo "  Install Android Platform Tools:"
            if command -v brew >/dev/null 2>&1; then
                echo "    brew install android-platform-tools"
            else
                echo "    Install Homebrew first: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                echo "    Then: brew install android-platform-tools"
            fi
            echo ""
            echo "  Note: macOS may prompt 'Allow accessory to connect' — click Allow."
            echo "  If adb/fastboot is not found after install, restart your terminal."
            ;;
        windows)
            echo "  Install Android Platform Tools:"
            echo "    1. Download from https://developer.android.com/tools/releases/platform-tools"
            echo "    2. Extract the ZIP (e.g. to C:\\platform-tools)"
            echo "    3. Add the folder to your system PATH:"
            echo "       Settings → System → About → Advanced → Environment Variables → Path → Edit → New"
            echo "    4. Install your device's USB driver (Google USB Driver or OEM driver)"
            echo "       https://developer.android.com/studio/run/oem-usb"
            echo ""
            echo "  If using Git Bash/MSYS2, run this script from there."
            printf '  If using PowerShell/CMD, use .\\adb.exe and .\\fastboot.exe instead.\n'
            ;;
        termux)
            echo "  Install Android Platform Tools in Termux:"
            echo "    pkg install android-tools"
            echo ""
            echo "  Note: ADB in Termux requires either:"
            echo "    a) Wireless debugging (Android 11+): Settings → Developer options → Wireless debugging"
            echo "       adb pair <ip>:<pair_port>    # enter the pairing code"
            echo "       adb connect <ip>:<port>"
            echo "    b) USB OTG cable connecting another device"
            echo ""
            echo "  Fastboot from Termux requires USB OTG — wireless does not support fastboot."
            ;;
        android)
            echo "  ADB is not typically available in native Android shell."
            echo "  Install Termux from F-Droid and use Termux instead,"
            echo "  or run this script from a PC connected to the device."
            ;;
        *)
            echo "  Install Android Platform Tools from:"
            echo "    https://developer.android.com/tools/releases/platform-tools"
            ;;
    esac
}

check_host_prereqs() {
    local missing=""

    info "Host OS detected: $HOM_HOST_OS"

    # Termux/Android: warn about limitations
    if [ "$HOM_HOST_OS" = "termux" ]; then
        warn "Running from Termux — fastboot requires USB OTG; ADB requires wireless debugging or OTG."
    elif [ "$HOM_HOST_OS" = "android" ]; then
        warn "Running from native Android shell — limited ADB/fastboot support."
        echo "  Consider using a PC or Termux instead."
    fi

    if ! command -v adb >/dev/null 2>&1; then
        missing="${missing}adb "
    fi
    if ! command -v fastboot >/dev/null 2>&1; then
        missing="${missing}fastboot "
    fi

    if [ -n "$missing" ]; then
        echo ""
        echo "  ${CLR_RED}✗  Missing required tools: ${missing}${CLR_RESET}" >&2
        echo ""
        _install_instructions
        exit 1
    fi

    ok "Host tools found: adb $(adb version 2>/dev/null | head -1 | awk '{print $NF}'), fastboot $(fastboot --version 2>/dev/null | head -1 | awk '{print $NF}')"

    # Check if any TARGET device is connected
    if ! check_device_adb && ! check_device_fastboot; then
        echo ""
        warn "No TARGET device detected."
        echo ""
        echo "  ${CLR_YELLOW}Before connecting, make sure debugging is enabled on TARGET:${CLR_RESET}"
        _show_debug_enable_instructions "usb"
        echo "  Connection priority (try in this order):"
        echo "    1. ${CLR_GREEN}USB cable${CLR_RESET} — fastest, supports ADB + fastboot (all modes)"
        echo "    2. ${CLR_GREEN}USB OTG${CLR_RESET}  — for device-to-device via Termux (ADB + fastboot)"
        echo "    3. ${CLR_YELLOW}WiFi ADB${CLR_RESET} — last resort, ADB only, no fastboot (--wifi-setup)"
        echo ""
    fi

    # Platform-specific USB permission check
    if [ "$HOM_HOST_OS" = "linux" ]; then
        # Check if user can access USB devices (common Linux issue)
        if ! adb devices >/dev/null 2>&1; then
            warn "ADB could not list devices. You may need USB permissions:"
            echo "    sudo usermod -aG plugdev \$USER  # then log out and back in"
        fi
    elif [ "$HOM_HOST_OS" = "windows" ]; then
        info "Windows: ensure your device's USB driver is installed."
        echo "    https://developer.android.com/studio/run/oem-usb"
    fi
}

# Check if a device is connected in the given mode.
# Returns 0 if found, 1 if not.
check_device_adb() {
    if [ -n "$HOM_TARGET_SERIAL" ]; then
        # Check specific serial
        adb devices 2>/dev/null | grep -qE "^${HOM_TARGET_SERIAL}\s+(device|recovery|sideload)"
    else
        local count
        count=$(adb devices 2>/dev/null | grep -cE '\t(device|recovery|sideload)' || true)
        [ "$count" -gt 0 ]
    fi
}

check_device_fastboot() {
    if [ -n "$HOM_TARGET_SERIAL" ]; then
        fastboot devices 2>/dev/null | grep -qE "^${HOM_TARGET_SERIAL}\s"
    else
        local count
        count=$(fastboot devices 2>/dev/null | grep -cE 'fastboot' || true)
        [ "$count" -gt 0 ]
    fi
}

wait_for_device() {
    local mode="$1" timeout="${2:-30}"
    local elapsed=0
    local serial_hint=""
    [ -n "$HOM_TARGET_SERIAL" ] && serial_hint=" (serial: $HOM_TARGET_SERIAL)"

    info "Waiting for TARGET device in $mode mode${serial_hint} (${timeout}s timeout)..."

    # Platform-specific hints while waiting
    if [ "$mode" = "fastboot" ] && [ "$HOM_HOST_OS" = "termux" ]; then
        warn "Fastboot in Termux requires USB OTG cable — wireless ADB does not support fastboot."
    elif [ "$mode" = "fastboot" ] && [ "$HOM_HOST_OS" = "windows" ]; then
        info "Windows: if TARGET is not detected, check USB driver installation."
    elif [ "$mode" = "adb" ] && [ "$HOM_HOST_OS" = "termux" ]; then
        info "Termux ADB: ensure wireless debugging is connected (adb connect <ip>:<port>)."
    fi

    while [ "$elapsed" -lt "$timeout" ]; do
        case "$mode" in
            adb)      check_device_adb && { ok "TARGET device found (ADB)${serial_hint}"; return 0; } ;;
            fastboot) check_device_fastboot && { ok "TARGET device found (fastboot)${serial_hint}"; return 0; } ;;
        esac
        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Helpful failure message per platform
    echo ""
    case "$HOM_HOST_OS" in
        linux)
            warn "TARGET device not found. Try these in order:"
            echo "    1. ${CLR_GREEN}USB cable${CLR_RESET} — check it's data-capable (not charge-only)"
            echo "    2. USB debugging enabled on TARGET?"
            echo "    3. Run: sudo adb devices  (if permission denied)"
            echo "    4. Check udev rules: lsusb | grep -i android"
            echo "    5. ${CLR_YELLOW}Last resort: WiFi ADB${CLR_RESET} — bash build/host_flash.sh --wifi-setup"
            ;;
        macos)
            warn "TARGET device not found. Try these in order:"
            echo "    1. ${CLR_GREEN}USB cable${CLR_RESET} — check it's data-capable"
            echo "    2. USB debugging enabled on TARGET?"
            echo "    3. Click 'Allow' on any macOS accessory prompts"
            echo "    4. Try: adb kill-server && adb start-server"
            echo "    5. ${CLR_YELLOW}Last resort: WiFi ADB${CLR_RESET} — bash build/host_flash.sh --wifi-setup"
            ;;
        windows)
            warn "TARGET device not found. Try these in order:"
            echo "    1. ${CLR_GREEN}USB cable${CLR_RESET} — check it's data-capable"
            echo "    2. USB debugging enabled on TARGET?"
            echo "    3. USB driver installed? (Device Manager → show device)"
            echo "       Download: https://developer.android.com/studio/run/oem-usb"
            echo "    4. Try: adb kill-server && adb start-server"
            echo "    5. ${CLR_YELLOW}Last resort: WiFi ADB${CLR_RESET} — bash build/host_flash.sh --wifi-setup"
            ;;
        termux)
            warn "TARGET device not found. Try these in order:"
            echo "    1. ${CLR_GREEN}USB OTG cable${CLR_RESET} — connect OTG cable to TARGET (supports ADB + fastboot)"
            echo "    2. USB debugging enabled on TARGET?"
            echo "    3. ${CLR_YELLOW}Last resort: WiFi ADB${CLR_RESET} — ADB only, no fastboot"
            echo "       Run: bash build/host_flash.sh --wifi-setup"
            ;;
        android)
            warn "TARGET device not found."
            echo "    1. ${CLR_GREEN}Use a PC with USB cable${CLR_RESET} (recommended)"
            echo "    2. Use Termux with USB OTG cable"
            echo "    3. ${CLR_YELLOW}Last resort: WiFi ADB via Termux${CLR_RESET}"
            ;;
        *)
            warn "TARGET device not found."
            echo "    1. ${CLR_GREEN}USB cable${CLR_RESET} — check connection and debugging settings"
            echo "    2. ${CLR_YELLOW}Last resort: WiFi ADB${CLR_RESET} — bash build/host_flash.sh --wifi-setup"
            ;;
    esac
    # Always show debugging enable instructions on failure
    _show_debug_enable_instructions "$mode"

    # Offer WiFi ADB setup as an interactive fallback option
    if [ -t 0 ] && [ "$mode" = "adb" ]; then
        echo ""
        echo "  ${CLR_YELLOW}Would you like to try WiFi ADB as a last resort?${CLR_RESET}"
        read -r -p "  Try WiFi ADB setup? [y/N]: " try_wifi
        if [ "$try_wifi" = "y" ] || [ "$try_wifi" = "Y" ]; then
            run_wifi_setup
            # Re-check after WiFi setup
            if check_device_adb; then
                _resolve_target_serial adb
                _identify_target_adb
                ok "TARGET connected via WiFi ADB"
                _print_target_banner
                return 0
            fi
        fi
    fi
    return 1
}

# ── WiFi ADB setup helper ────────────────────────────────────
# Guides the user through wireless ADB pairing and connection.
# Works for:
#   - PC HOST → non-rooted TARGET over WiFi
#   - Termux HOST → non-rooted TARGET over WiFi
#   - Termux self-loopback → same device connects to its own wireless debugging
#
# No root is required on TARGET — Android 11+ wireless debugging
# is a user-accessible feature in Developer options.

run_wifi_setup() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  WiFi ADB Setup — Last Resort Connection"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  ${CLR_YELLOW}WiFi ADB is a last resort. Prefer USB or OTG when possible:${CLR_RESET}"
    echo "    1. USB cable (PC → TARGET) — fastest, supports ADB + fastboot"
    echo "    2. USB OTG (Termux → TARGET) — supports ADB + fastboot"
    echo "    3. WiFi ADB — ADB only, no fastboot, slower, requires Android 11+"
    echo ""
    info "HOST: $HOM_HOST_OS"
    info "No root is required on TARGET for WiFi ADB (Android 11+)."
    echo ""

    # Detect self-loopback scenario
    local is_self_loopback=false
    if [ "$HOM_HOST_OS" = "termux" ] || [ "$HOM_HOST_OS" = "android" ]; then
        echo "  Are you connecting to:"
        echo ""
        echo "    1) THIS device (self-loopback — Termux connecting to its own wireless debugging)"
        echo "    2) ANOTHER device (device-to-device over WiFi)"
        echo ""
        read -r -p "  Choose [1/2]: " loopback_choice
        case "$loopback_choice" in
            1) is_self_loopback=true ;;
            2) is_self_loopback=false ;;
            *) warn "Defaulting to another device."; is_self_loopback=false ;;
        esac
        echo ""
    fi

    if [ "$is_self_loopback" = true ]; then
        _wifi_setup_self_loopback
    else
        _wifi_setup_remote
    fi
}

# Self-loopback: Termux on the same non-rooted device
_wifi_setup_self_loopback() {
    echo ""
    echo "  ┌──────────────────────────────────────────────────┐"
    echo "  │  Self-loopback: Termux → same device (no root)  │"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""
    echo "  This connects Termux ADB to this device's own wireless"
    echo "  debugging port. No root is needed — wireless debugging"
    echo "  is a standard Android 11+ feature."
    echo ""
    echo "  ${CLR_YELLOW}Limitations of self-loopback (no root):${CLR_RESET}"
    echo "    • You can push files, read properties, and run non-root shell commands"
    echo "    • You CANNOT flash boot partitions (need root DD or fastboot from another device)"
    echo "    • You CANNOT use fastboot (device can't reboot itself to fastboot and keep the connection)"
    echo "    • Useful for: pre-placing boot images, diagnostics, file transfer, reboot commands"
    echo ""

    echo "  Step 1: Enable wireless debugging on this device"
    echo "    Settings → Developer options → Wireless debugging → ON"
    echo "    (You must already have Developer options enabled)"
    echo ""
    read -r -p "  Press Enter when wireless debugging is enabled..."
    echo ""

    echo "  Step 2: Get the pairing code"
    echo "    Settings → Developer options → Wireless debugging"
    echo "    → 'Pair device with pairing code'"
    echo "    Note the IP:PORT and the 6-digit pairing code shown."
    echo ""
    read -r -p "  Enter pairing IP:PORT (e.g. 127.0.0.1:37123): " pair_addr

    if [ -z "$pair_addr" ]; then
        fail "No pairing address entered."
    fi

    info "Pairing with $pair_addr..."
    echo "  Enter the 6-digit pairing code when prompted:"
    adb pair "$pair_addr"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "Pairing failed (exit code $rc). Check the IP:PORT and code."
    fi
    ok "Paired successfully"
    echo ""

    echo "  Step 3: Connect to this device's debugging port"
    echo "    In Settings → Wireless debugging, note the IP:PORT under"
    echo "    'IP address & Port' (this is different from the pairing port)."
    echo ""
    read -r -p "  Enter connection IP:PORT (e.g. 127.0.0.1:42456): " connect_addr

    if [ -z "$connect_addr" ]; then
        fail "No connection address entered."
    fi

    info "Connecting to $connect_addr..."
    adb connect "$connect_addr"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "adb connect returned exit code $rc — checking if device is connected anyway..."
    fi

    # Verify connection
    if adb devices 2>/dev/null | grep -q "$connect_addr"; then
        ok "Connected to self via wireless ADB: $connect_addr"
        HOM_TARGET_SERIAL="$connect_addr"
    else
        fail "Connection failed. Ensure wireless debugging is still active."
    fi

    echo ""
    echo "  ✓ Self-loopback established. What you can do now:"
    echo ""
    echo "    # Push a boot image for later use by the installer"
    echo "    adb -s $connect_addr push boot.img /sdcard/Download/"
    echo ""
    echo "    # Check device properties"
    echo "    adb -s $connect_addr shell getprop ro.product.model"
    echo ""
    echo "    # Reboot to recovery or bootloader (for use with a PC)"
    echo "    adb -s $connect_addr reboot recovery"
    echo "    adb -s $connect_addr reboot bootloader"
    echo ""
    echo "  ${CLR_YELLOW}To flash this device, you still need either:${CLR_RESET}"
    echo "    • A PC with fastboot (C1/C2) — connect via USB after rebooting to bootloader"
    echo "    • Magisk already installed (Mode A) — flash module ZIP via Magisk app"
    echo "    • Custom recovery (Mode B) — flash ZIP via TWRP"
    echo ""
}

# Remote: HOST connects to a separate TARGET device over WiFi
_wifi_setup_remote() {
    echo ""
    echo "  ┌──────────────────────────────────────────────────┐"
    echo "  │  WiFi ADB: HOST → remote TARGET (LAST RESORT)   │"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""
    echo "  ${CLR_YELLOW}Only use WiFi ADB when USB and OTG are not available.${CLR_RESET}"
    echo "  Limitations: no fastboot, slower transfers, requires Android 11+."
    echo ""

    case "$HOM_HOST_OS" in
        termux)
            echo "  ${CLR_YELLOW}HOST is Termux — prefer USB OTG cable over WiFi.${CLR_RESET}"
            echo "  WiFi: both devices must be on the same network."
            echo "  Fastboot is NOT available over WiFi — only ADB (C3 sideload)."
            ;;
        linux|macos|windows)
            echo "  ${CLR_YELLOW}Prefer a USB cable. WiFi ADB has limited functionality.${CLR_RESET}"
            echo "  HOST ($HOM_HOST_OS) and TARGET must be on the same network."
            echo "  For C1/C2 (fastboot), connect TARGET via USB cable instead."
            ;;
    esac
    echo ""

    echo "  Step 1: On TARGET device — enable wireless debugging"
    echo "    Settings → Developer options → Wireless debugging → ON"
    echo ""
    read -r -p "  Press Enter when wireless debugging is enabled on TARGET..."
    echo ""

    echo "  Step 2: On TARGET device — get the pairing code"
    echo "    Settings → Developer options → Wireless debugging"
    echo "    → 'Pair device with pairing code'"
    echo "    Note the IP:PORT and the 6-digit pairing code."
    echo ""
    read -r -p "  Enter TARGET pairing IP:PORT (e.g. 192.168.1.100:37123): " pair_addr

    if [ -z "$pair_addr" ]; then
        fail "No pairing address entered."
    fi

    info "Pairing with TARGET at $pair_addr..."
    echo "  Enter the 6-digit pairing code from TARGET when prompted:"
    adb pair "$pair_addr"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "Pairing with TARGET failed (exit code $rc). Check IP:PORT and code."
    fi
    ok "Paired with TARGET"
    echo ""

    echo "  Step 3: Connect to TARGET's debugging port"
    echo "    On TARGET: Wireless debugging screen shows IP:PORT under"
    echo "    'IP address & Port' (different from the pairing port)."
    echo ""
    read -r -p "  Enter TARGET connection IP:PORT (e.g. 192.168.1.100:42456): " connect_addr

    if [ -z "$connect_addr" ]; then
        fail "No connection address entered."
    fi

    info "Connecting to TARGET at $connect_addr..."
    adb connect "$connect_addr"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "adb connect returned exit code $rc — checking device list..."
    fi

    # Verify and set as target
    if adb devices 2>/dev/null | grep -q "$connect_addr"; then
        ok "Connected to TARGET via WiFi: $connect_addr"
        HOM_TARGET_SERIAL="$connect_addr"
        _identify_target_adb
        _print_target_banner
    else
        fail "Connection to TARGET failed. Check WiFi and wireless debugging on TARGET."
    fi

    echo ""
    echo "  ✓ WiFi ADB connection established."
    echo ""
    echo "  Available Mode C options over WiFi (no root needed on TARGET):"
    echo "    ${CLR_GREEN}✓ C3 — ADB sideload${CLR_RESET} (push ZIP or sideload to TARGET in recovery)"
    echo "    ${CLR_YELLOW}✗ C1 — Temporary TWRP boot${CLR_RESET} (needs fastboot — USB only)"
    echo "    ${CLR_YELLOW}✗ C2 — Direct fastboot flash${CLR_RESET} (needs fastboot — USB only)"
    echo ""
    echo "  What you can do now:"
    echo "    # Push files to TARGET"
    echo "    adb -s $connect_addr push recovery.zip /sdcard/"
    echo ""
    echo "    # Reboot TARGET to recovery for sideload"
    echo "    adb -s $connect_addr reboot recovery"
    echo ""
    echo "    # Run the C3 sideload"
    echo "    bash build/host_flash.sh -s $connect_addr --c3 recovery.zip"
    echo ""
    echo "    # Reboot TARGET to bootloader (then connect USB for fastboot)"
    echo "    adb -s $connect_addr reboot bootloader"
    echo ""

    # Offer to continue to C3 or dump
    echo "  What would you like to do next?"
    echo "    1) C3 — ADB sideload"
    echo "    2) Dump — Collect diagnostic data from TARGET"
    echo "    3) Nothing — exit"
    echo ""
    read -r -p "  Choose [1/2/3]: " next_action
    case "$next_action" in
        1) run_c3 ;;
        2) run_dump ;;
        *) return 0 ;;
    esac
}

# ── Partition / diagnostic dump ──────────────────────────────
# Collects accessible data from TARGET over ADB. Works with and
# without root — the script adapts to what's available.
#
# With root:  full partition dumps (boot, dtbo, vbmeta), live
#             hardware data, /proc, /sys, block device reads.
# Without root: properties, accessible /proc and /sys entries,
#             partition layout, VINTF manifests, dumpsys output.
#
# The collected data can be used with the host-side pipeline:
#   python pipeline/build_table.py --dump ./hom-dump/ --mode C
#
# Uses:
#   1. Pre-flash analysis — understand TARGET before committing to flash
#   2. Boot image extraction — root DD for later patching (with root)
#   3. Hardware catalog — feed into the pipeline's SQLite hardware map
#   4. Offline diagnosis — analyse a device you can't physically access
#   5. Partition layout reference — compare across devices/OTAs

run_dump() {
    local dump_dir="${1:-./hom-dump-$(date +%Y%m%d-%H%M%S)}"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Diagnostic Dump — Collect data from TARGET"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "HOST ($HOM_HOST_OS) will collect diagnostic data from TARGET."
    info "Dump directory (on HOST): $dump_dir"
    echo ""

    # Ensure we have a target
    if ! check_device_adb; then
        fail "No TARGET device found via ADB. Connect first (--wifi-setup or USB)."
    fi

    if [ -z "$HOM_TARGET_SERIAL" ]; then
        _resolve_target_serial adb
    fi
    _identify_target_adb
    _print_target_banner

    mkdir -p "$dump_dir"

    # Detect root and elevated (Shizuku/shell-level) access on TARGET
    local has_root=false
    local has_elevated=false
    if _adb shell "su -c 'id'" 2>/dev/null | grep -q 'uid=0'; then
        has_root=true
        has_elevated=true
        ok "TARGET has root access (UID 0) — full partition dumps available"
    elif _adb shell "id" 2>/dev/null | grep -q 'uid=2000\|shell'; then
        has_elevated=true
        ok "TARGET has elevated ADB shell access (UID 2000)"
        echo "    Enhanced /proc, /sys, logcat collection available."
        echo "    Partition image dumps still require root."
        # Check for Shizuku
        local shizuku_state
        shizuku_state=$(_check_shizuku 2>/dev/null || echo "not_installed")
        if [ "$shizuku_state" = "running" ]; then
            ok "Shizuku is running — elevated app-level access available"
        fi
    else
        warn "TARGET has NO root and NO elevated access"
        echo "    Partition image dumps (dd) require root."
        echo "    Properties, VINTF manifests, and dumpsys are still available."
        echo ""
        echo "    ${CLR_CYAN}Tip: Install Shizuku or LADB on TARGET for better data collection${CLR_RESET}"
        echo "    ${CLR_CYAN}     without root. Run: bash build/host_flash.sh --elevated-setup${CLR_RESET}"
    fi

    echo ""
    info "Collecting data from TARGET..."
    echo ""

    # ── 1. Device properties (no root needed) ────────────────
    tgt "Collecting device properties..."
    if _adb shell getprop > "$dump_dir/getprop.txt" 2>/dev/null; then
        ok "  getprop.txt"
    else
        warn "  getprop failed"
    fi

    # ── 2. Partition layout (symlinks only without root) ────
    # Without root: ls shows symlinks (partition names → block device nodes)
    # but the actual block device data is NOT readable (SELinux blocks it).
    # With root: we can also read /proc/partitions sizes and stat devices.
    tgt "Collecting partition layout (symlinks — names only, not data)..."
    mkdir -p "$dump_dir/partitions"
    {
        echo "# NOTE: These are symlinks only. Partition names and their block"
        echo "# device mappings are visible, but the actual partition DATA"
        echo "# cannot be read without root (SELinux blocks /dev/block/* reads)."
        echo ""
        echo "=== /dev/block/bootdevice/by-name/ (symlinks) ==="
        _adb shell "ls -la /dev/block/bootdevice/by-name/ 2>/dev/null" || true
        echo ""
        echo "=== /dev/block/by-name/ (symlinks) ==="
        _adb shell "ls -la /dev/block/by-name/ 2>/dev/null" || true
        echo ""
        echo "=== /dev/block/platform/*/by-name/ (symlinks) ==="
        _adb shell "ls -la /dev/block/platform/*/by-name/ 2>/dev/null" || true
        echo ""
        echo "=== /proc/partitions (block device sizes) ==="
        _adb shell "cat /proc/partitions 2>/dev/null" || true
        echo ""
        echo "=== /proc/mounts (mounted partitions) ==="
        _adb shell "cat /proc/mounts 2>/dev/null" || true
    } > "$dump_dir/partitions/layout.txt" 2>/dev/null
    ok "  partitions/layout.txt (symlinks + /proc/partitions + /proc/mounts)"

    # ── 3. /proc files (mostly accessible without root) ──────
    tgt "Collecting /proc data..."
    mkdir -p "$dump_dir/proc"
    for f in cpuinfo meminfo cmdline version mounts filesystems; do
        if _adb shell "cat /proc/$f 2>/dev/null" > "$dump_dir/proc/$f" 2>/dev/null; then
            ok "  proc/$f"
        fi
    done

    # iomem and interrupts — restricted without root/elevated access
    # With elevated (UID 2000) or root: full content available
    # Without: may be empty or show only partial data
    if [ "$has_root" = true ]; then
        _adb shell "su -c 'cat /proc/iomem'" > "$dump_dir/proc/iomem" 2>/dev/null || true
        _adb shell "su -c 'cat /proc/interrupts'" > "$dump_dir/proc/interrupts" 2>/dev/null || true
    else
        _adb shell "cat /proc/iomem 2>/dev/null" > "$dump_dir/proc/iomem" 2>/dev/null || true
        _adb shell "cat /proc/interrupts 2>/dev/null" > "$dump_dir/proc/interrupts" 2>/dev/null || true
    fi
    if [ -s "$dump_dir/proc/iomem" ]; then
        ok "  proc/iomem"
    else
        if [ "$has_elevated" = true ]; then
            warn "  proc/iomem (restricted — elevated access insufficient on this device)"
        else
            warn "  proc/iomem (restricted — use Shizuku/LADB or root for full data)"
        fi
    fi
    if [ -s "$dump_dir/proc/interrupts" ]; then
        ok "  proc/interrupts"
    else
        if [ "$has_elevated" = true ]; then
            warn "  proc/interrupts (restricted — elevated access insufficient)"
        else
            warn "  proc/interrupts (restricted — use Shizuku/LADB or root for full data)"
        fi
    fi

    # logcat — better with elevated/shell access (no PID filter)
    if [ "$has_elevated" = true ] || [ "$has_root" = true ]; then
        tgt "Collecting logcat (elevated access — no PID filter)..."
        _adb logcat -d -v threadtime > "$dump_dir/logcat.txt" 2>/dev/null || true
        if [ -s "$dump_dir/logcat.txt" ]; then
            ok "  logcat.txt (full)"
        else
            warn "  logcat failed"
        fi
    fi

    # ── 4. Device tree (readable on many devices without root)
    tgt "Collecting device tree..."
    mkdir -p "$dump_dir/proc/device-tree"
    local dt_path=""
    for try in /proc/device-tree /sys/firmware/devicetree/base; do
        if _adb shell "test -d $try" 2>/dev/null; then
            dt_path="$try"
            break
        fi
    done
    if [ -n "$dt_path" ]; then
        # Pull model and compatible strings
        _adb shell "cat $dt_path/model 2>/dev/null" > "$dump_dir/proc/device-tree/model" 2>/dev/null || true
        _adb shell "cat $dt_path/compatible 2>/dev/null | tr '\0' '\n'" > "$dump_dir/proc/device-tree/compatible" 2>/dev/null || true
        # List SoC nodes
        _adb shell "ls $dt_path/soc/ 2>/dev/null" > "$dump_dir/proc/device-tree/soc_nodes.txt" 2>/dev/null || true
        ok "  device-tree (from $dt_path)"
    else
        warn "  device-tree not accessible"
    fi

    # ── 5. Loaded kernel modules ─────────────────────────────
    tgt "Collecting kernel modules..."
    _adb shell "cat /proc/modules 2>/dev/null" > "$dump_dir/lsmod.txt" 2>/dev/null || true
    if [ -s "$dump_dir/lsmod.txt" ]; then
        ok "  lsmod.txt"
    else
        warn "  lsmod.txt (restricted)"
    fi

    # ── 6. VINTF manifests (vendor/system, no root needed) ───
    tgt "Collecting VINTF manifests..."
    for vintf_path in \
        /vendor/etc/manifest.xml \
        /vendor/etc/vintf/manifest.xml \
        /system/etc/vintf/manifest.xml \
        /odm/etc/vintf/manifest.xml \
        /vendor/etc/vintf/compatibility_matrix.xml; do
        local base_dir
        base_dir=$(dirname "$vintf_path" | sed 's|^/||')
        local base_name
        base_name=$(basename "$vintf_path")
        mkdir -p "$dump_dir/$base_dir"
        _adb shell "cat $vintf_path 2>/dev/null" > "$dump_dir/$base_dir/$base_name" 2>/dev/null || true
        if [ -s "$dump_dir/$base_dir/$base_name" ]; then
            ok "  $base_dir/$base_name"
        fi
    done

    # ── 7. dumpsys data (no root needed for many services) ───
    tgt "Collecting dumpsys data..."
    mkdir -p "$dump_dir/dumpsys"
    for svc in display SurfaceFlinger audio media.camera battery; do
        _adb shell "dumpsys $svc 2>/dev/null" > "$dump_dir/dumpsys/$svc.txt" 2>/dev/null || true
        if [ -s "$dump_dir/dumpsys/$svc.txt" ]; then
            ok "  dumpsys/$svc"
        fi
    done

    # ── 8. Build and security info ───────────────────────────
    tgt "Collecting build info..."
    mkdir -p "$dump_dir/build"
    {
        echo "model=$(             _adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
        echo "device=$(            _adb shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
        echo "board=$(             _adb shell getprop ro.product.board 2>/dev/null | tr -d '\r')"
        echo "platform=$(          _adb shell getprop ro.board.platform 2>/dev/null | tr -d '\r')"
        echo "android_version=$(   _adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
        echo "api_level=$(         _adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
        echo "security_patch=$(    _adb shell getprop ro.build.version.security_patch 2>/dev/null | tr -d '\r')"
        echo "build_id=$(          _adb shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')"
        echo "verified_boot=$(     _adb shell getprop ro.boot.verifiedbootstate 2>/dev/null | tr -d '\r')"
        echo "boot_slot=$(         _adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')"
        echo "soc_manufacturer=$(  _adb shell getprop ro.soc.manufacturer 2>/dev/null | tr -d '\r')"
        echo "soc_model=$(         _adb shell getprop ro.soc.model 2>/dev/null | tr -d '\r')"
        echo "hardware=$(          _adb shell getprop ro.hardware 2>/dev/null | tr -d '\r')"
        echo "bootloader=$(        _adb shell getprop ro.bootloader 2>/dev/null | tr -d '\r')"
        echo "flash_locked=$(      _adb shell getprop ro.boot.flash.locked 2>/dev/null | tr -d '\r')"
    } > "$dump_dir/build/summary.txt"
    ok "  build/summary.txt"

    # ── 9. Partition image dumps (ROOT ONLY) ─────────────────
    if [ "$has_root" = true ]; then
        tgt "Dumping partition images (root access available)..."
        mkdir -p "$dump_dir/boot_images"

        for part in boot init_boot dtbo vbmeta vbmeta_system; do
            local dev=""
            for try_dev in \
                "/dev/block/bootdevice/by-name/$part" \
                "/dev/block/by-name/$part"; do
                if _adb shell "test -e $try_dev" 2>/dev/null; then
                    dev="$try_dev"
                    break
                fi
            done

            if [ -n "$dev" ]; then
                tgt "  Dumping $part from $dev..."
                _adb shell "su -c 'dd if=$dev bs=4096 2>/dev/null'" > "$dump_dir/boot_images/$part.img" 2>/dev/null
                local size
                size=$(wc -c < "$dump_dir/boot_images/$part.img" 2>/dev/null || echo 0)
                if [ "$size" -gt 0 ]; then
                    ok "  boot_images/$part.img ($(( size / 1024 )) KB)"
                else
                    rm -f "$dump_dir/boot_images/$part.img"
                    warn "  $part — dump failed or empty"
                fi
            fi
        done

        # If we dumped a boot image, it can be used for patching
        if [ -f "$dump_dir/boot_images/boot.img" ] || [ -f "$dump_dir/boot_images/init_boot.img" ]; then
            echo ""
            ok "Boot image dumped — this can be used for Mode C2 (fastboot flash):"
            if [ -f "$dump_dir/boot_images/init_boot.img" ]; then
                echo "    1. Patch: transfer init_boot.img to Magisk app → Patch a File"
                echo "    2. Flash: fastboot flash init_boot magisk_patched-*.img"
            else
                echo "    1. Patch: transfer boot.img to Magisk app → Patch a File"
                echo "    2. Flash: fastboot flash boot magisk_patched-*.img"
            fi
        fi

        # ── 10. /proc/iomem full dump (root only) ────────────
        _adb shell "su -c 'cat /proc/iomem'" > "$dump_dir/proc/iomem_full" 2>/dev/null || true
        [ -s "$dump_dir/proc/iomem_full" ] && ok "  proc/iomem_full (root — full detail)"

        # ── 11. SELinux policy ────────────────────────────────
        tgt "Collecting SELinux policy..."
        mkdir -p "$dump_dir/selinux"
        _adb shell "su -c 'cat /sys/fs/selinux/policy'" > "$dump_dir/selinux/policy.bin" 2>/dev/null || true
        [ -s "$dump_dir/selinux/policy.bin" ] && ok "  selinux/policy.bin"

    else
        echo ""
        info "Skipping partition image dumps (no root on TARGET)."
        echo "    To get partition dumps, either:"
        echo "      • Root TARGET first (Mode A or C1+sideload)"
        echo "      • Use 'fastboot boot twrp.img' to get temporary root"
        echo "      • Extract boot.img from TARGET's factory image on HOST"
    fi

    # ── Write manifest ────────────────────────────────────────
    find "$dump_dir" -type f | sed "s|^$dump_dir/||" | sort > "$dump_dir/manifest.txt"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    ok "Dump complete: $dump_dir"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Files collected: $(wc -l < "$dump_dir/manifest.txt")"
    echo "  Total size: $(du -sh "$dump_dir" 2>/dev/null | awk '{print $1}')"
    echo ""
    echo "  ${CLR_GREEN}What you can do with this dump:${CLR_RESET}"
    echo ""
    echo "  1. ${CLR_CYAN}Build a hardware map (pipeline):${CLR_RESET}"
    echo "     python pipeline/build_table.py --dump $dump_dir --mode C"
    echo ""
    echo "  2. ${CLR_CYAN}Unpack boot images (if dumped):${CLR_RESET}"
    echo "     python pipeline/unpack_images.py --dump $dump_dir --run-id 1"
    echo "     → Extracts kernel, ramdisk, fstab, init.rc, default.prop"
    echo ""
    echo "  3. ${CLR_CYAN}Parse VINTF manifests:${CLR_RESET}"
    echo "     python pipeline/parse_manifests.py --dump $dump_dir --run-id 1"
    echo "     → HAL interfaces, board capabilities, hardware features"
    echo ""
    echo "  4. ${CLR_CYAN}Analyse device tree:${CLR_RESET}"
    echo "     python pipeline/build_table.py --dump $dump_dir --mode C"
    echo "     → SoC peripherals, regulators, display controllers"
    echo ""
    echo "  5. ${CLR_CYAN}Run failure analysis (pre-flash check):${CLR_RESET}"
    echo "     python pipeline/failure_analysis.py --dump $dump_dir"
    echo "     → Anti-rollback check, partition compatibility, known issues"
    echo ""
    if [ "$has_root" = true ]; then
        echo "  6. ${CLR_CYAN}Use dumped boot image for patching:${CLR_RESET}"
        echo "     Transfer boot.img to Magisk → Patch a File → pull back → fastboot flash"
        echo "     See Mode C2 in docs/ADB_FASTBOOT_INSTALL.md"
        echo ""
    fi
    echo "  Full pipeline docs: docs/PIPELINE.md (if available)"
    echo ""
}

# Find the latest recovery ZIP in dist/.
find_recovery_zip() {
    local latest=""
    if [ -d "$DIST_DIR" ]; then
        # shellcheck disable=SC2012  # ls -t for newest is simpler than find here
        latest=$(ls -t "$DIST_DIR"/hands-on-metal-recovery-*.zip 2>/dev/null | head -1 || true)
    fi
    echo "$latest"
}

# ── C1: Temporary TWRP boot ──────────────────────────────────

# Boot-image safety, integrity, and ARP probe helpers
# ----------------------------------------------------
# Used by run_c1, run_c2, run_c3 to verify host-side artefacts
# and probe TARGET safety state before any destructive operation.
# Designed to cover the full Android 10–16 boot-type matrix:
#   • boot          (legacy / pre-GKI)
#   • init_boot     (GKI 2.0, Android 13+)
#   • vendor_boot   (GKI, Android 12+)
#   • recovery      (A-only devices)
# All checks are non-fatal (warn + prompt) unless the bootloader
# is locked, in which case run_c2 refuses to flash without
# --force-locked.

# Global safety options (overridable by --partition / --no-verify
# / --sha256 / --force-locked CLI flags)
HOM_FORCE_PART="${HOM_FORCE_PART:-}"
HOM_NO_VERIFY="${HOM_NO_VERIFY:-false}"
HOM_EXPECTED_SHA256="${HOM_EXPECTED_SHA256:-}"
HOM_FORCE_FLASH="${HOM_FORCE_FLASH:-false}"

# Cross-platform SHA-256 of a file (Linux/macOS/Termux).
# Echoes the lowercase hex digest, or empty string on failure.
_host_sha256() {
    local file="$1"
    [ -f "$file" ] || { echo ""; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        echo ""
        return 1
    fi
}

# Verify integrity of a host-side artefact before sending it to TARGET.
# Args: <file> <kind>   (kind is human-readable, e.g. "TWRP image")
# Honours: $HOM_NO_VERIFY, $HOM_EXPECTED_SHA256, and an optional
# sidecar file `<file>.sha256` containing the expected hex digest.
# Exits via fail() on a definite mismatch.  Warns on missing checksum.
_verify_image_integrity() {
    local file="$1" kind="${2:-image}"

    if [ "$HOM_NO_VERIFY" = "true" ]; then
        warn "Integrity check skipped for $kind ($file) — --no-verify in effect."
        return 0
    fi

    local actual expected expected_src=""
    actual=$(_host_sha256 "$file")
    if [ -z "$actual" ]; then
        warn "No SHA-256 tool found on HOST (sha256sum / shasum / openssl) — cannot verify $kind."
        warn "Pass --no-verify to silence this warning."
        return 0
    fi

    info "$kind SHA-256: $actual"

    # Resolve expected digest in priority order:
    #   1. --sha256 CLI flag
    #   2. <file>.sha256 sidecar
    #   3. (none — informational only)
    if [ -n "$HOM_EXPECTED_SHA256" ]; then
        expected="$HOM_EXPECTED_SHA256"
        expected_src="--sha256 flag"
    elif [ -f "${file}.sha256" ]; then
        expected=$(awk '{print $1; exit}' "${file}.sha256" 2>/dev/null || echo "")
        expected_src="${file}.sha256"
    fi

    if [ -n "${expected:-}" ]; then
        # Normalise: strip whitespace, lowercase
        expected=$(printf "%s" "$expected" | tr 'A-Z ' 'a-z\n' | head -1)
        if [ "$actual" = "$expected" ]; then
            ok "Integrity verified ($kind matches $expected_src)"
        else
            fail "Integrity check FAILED for $kind:
  expected: $expected   (from $expected_src)
  actual:   $actual
  Refusing to send a tampered or wrong image to TARGET.
  Pass --no-verify to override (NOT RECOMMENDED)."
        fi
    else
        info "No expected SHA-256 supplied (no --sha256 flag, no ${file}.sha256 sidecar) — recorded for audit only."
    fi
}

# Detect the TARGET partition name from a filename.
# Order matters: the longest/most-specific match wins.
# Echoes one of: init_boot | vendor_boot | recovery | boot | ""
_detect_partition() {
    local file="$1"
    local base
    base=$(basename "$file" 2>/dev/null | tr 'A-Z' 'a-z')
    case "$base" in
        *init_boot*)   echo "init_boot"   ;;
        *vendor_boot*) echo "vendor_boot" ;;
        *recovery*)    echo "recovery"    ;;
        *boot*)        echo "boot"        ;;
        *)             echo ""            ;;
    esac
}

# Probe the TARGET's safety/lock/ARP state via `fastboot getvar`.
# Sets globals: HOM_TARGET_UNLOCKED, HOM_TARGET_SECURE,
# HOM_TARGET_CURRENT_SLOT, HOM_TARGET_BOOTLOADER_VER,
# HOM_TARGET_BASEBAND_VER, HOM_TARGET_ARB_VERSION.
# Pre-condition: TARGET is in fastboot mode.
# All values default to "unknown" if the bootloader does not expose them.
HOM_TARGET_UNLOCKED=""
HOM_TARGET_SECURE=""
HOM_TARGET_CURRENT_SLOT=""
HOM_TARGET_BOOTLOADER_VER=""
HOM_TARGET_BASEBAND_VER=""
HOM_TARGET_ARB_VERSION=""

_getvar() {
    # Echoes the value of `fastboot getvar <key>` (after the "key:")
    # or empty string on failure.  fastboot writes getvar output to stderr.
    local key="$1" out
    out=$(_fastboot getvar "$key" 2>&1 | grep -E "^${key}:" | head -1 | awk -F': *' '{print $2}' | tr -d '\r')
    printf "%s" "$out"
}

_probe_target_safety() {
    info "Probing TARGET safety state via fastboot getvar..."
    HOM_TARGET_UNLOCKED=$(_getvar unlocked)
    HOM_TARGET_SECURE=$(_getvar secure)
    HOM_TARGET_CURRENT_SLOT=$(_getvar current-slot)
    HOM_TARGET_BOOTLOADER_VER=$(_getvar version-bootloader)
    HOM_TARGET_BASEBAND_VER=$(_getvar version-baseband)
    HOM_TARGET_ARB_VERSION=$(_getvar anti-rollback-version)

    echo ""
    echo "  ${CLR_CYAN}TARGET safety profile:${CLR_RESET}"
    echo "    unlocked            : ${HOM_TARGET_UNLOCKED:-unknown}"
    echo "    secure              : ${HOM_TARGET_SECURE:-unknown}"
    echo "    current-slot        : ${HOM_TARGET_CURRENT_SLOT:-unknown (A-only or not exposed)}"
    echo "    version-bootloader  : ${HOM_TARGET_BOOTLOADER_VER:-unknown}"
    echo "    version-baseband    : ${HOM_TARGET_BASEBAND_VER:-unknown}"
    echo "    anti-rollback-ver   : ${HOM_TARGET_ARB_VERSION:-unknown (not exposed)}"
    echo ""

    if [ "$HOM_TARGET_UNLOCKED" = "no" ]; then
        warn "TARGET bootloader is LOCKED. Flashing will fail and may trigger anti-rollback."
        if [ "$HOM_FORCE_FLASH" != "true" ]; then
            fail "Refusing to flash a locked bootloader. Unlock first with:
  fastboot${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} flashing unlock
Or pass --force-locked to override (your fastboot flash will almost certainly fail)."
        else
            warn "--force-locked supplied; proceeding despite locked bootloader."
        fi
    elif [ "$HOM_TARGET_UNLOCKED" = "yes" ]; then
        ok "TARGET bootloader is unlocked."
    fi

    if [ -n "$HOM_TARGET_ARB_VERSION" ]; then
        info "TARGET anti-rollback version reported: $HOM_TARGET_ARB_VERSION"
        info "Ensure the image you are flashing is not from an OLDER anti-rollback index."
        info "(See docs/TROUBLESHOOTING.md for ARB recovery if this is a downgrade.)"
    fi
}

# Confirm the TARGET actually has a partition with the given name.
# Best-effort: some bootloaders expose `partition-size:<name>`.
# Non-fatal: warns on missing/unknown.
_check_partition_exists() {
    local part="$1" size
    size=$(_getvar "partition-size:$part")
    if [ -n "$size" ]; then
        ok "TARGET has partition '$part' (size: $size)"
    else
        warn "TARGET did not report a partition called '$part' via getvar partition-size:$part."
        warn "Either the bootloader doesn't expose it, or the partition name is wrong for this device."
        warn "If unsure, abort and consult docs/INSTALL_HUB.md for your device's partition layout."
    fi
}

run_c1() {
    local twrp_img="${1:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Mode C1 — Temporary TWRP Boot via fastboot"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "HOST ($HOM_HOST_OS) will boot TWRP on TARGET via fastboot."
    info "TWRP runs in RAM only — TARGET's stock recovery is unchanged."
    echo ""

    # Validate TWRP image
    if [ -z "$twrp_img" ]; then
        echo "  Enter the path to your TWRP .img file (on this $HOM_HOST_OS machine):"
        echo "  (Download from https://twrp.me/Devices/ for your TARGET device)"
        echo ""
        read -r -p "  TWRP image path: " twrp_img
    fi

    if [ ! -f "$twrp_img" ]; then
        fail "TWRP image not found at: $twrp_img (on HOST)"
    fi

    ok "TWRP image (on HOST): $twrp_img"

    # Integrity check (non-fatal unless mismatch confirmed)
    _verify_image_integrity "$twrp_img" "TWRP image"

    # Get TARGET device into fastboot
    if check_device_fastboot; then
        _resolve_target_serial fastboot
        _identify_target_fastboot
        ok "TARGET already in fastboot mode"
    elif check_device_adb; then
        _resolve_target_serial adb
        _identify_target_adb
        tgt "Rebooting TARGET to bootloader..."
        _adb reboot bootloader
        wait_for_device fastboot 30 || fail "TARGET did not enter fastboot mode"
    else
        echo ""
        warn "No TARGET device detected."
        case "$HOM_HOST_OS" in
            linux|macos)
                echo "    Connect TARGET device via USB, then either:"
                echo "      • Enable USB debugging on TARGET and run: adb reboot bootloader"
                echo "      • Or power off TARGET, hold Power + Volume Down to enter fastboot"
                ;;
            windows)
                echo "    1. Ensure USB driver for TARGET is installed (Device Manager)"
                echo "    2. Connect TARGET via USB, then either:"
                echo "       • Run: adb reboot bootloader"
                echo "       • Or power off TARGET, hold Power + Volume Down"
                ;;
            termux)
                echo "    Fastboot requires USB OTG cable from this device to TARGET."
                echo "    Wireless ADB cannot enter fastboot."
                echo "    Connect TARGET via OTG, then:"
                echo "      Power off TARGET → hold Power + Volume Down"
                ;;
            *)
                echo "    Connect TARGET and enter fastboot mode (Power + Volume Down)"
                ;;
        esac
        echo ""
        wait_for_device fastboot 60 || fail "No TARGET device found in fastboot mode"
        _resolve_target_serial fastboot
        _identify_target_fastboot
    fi

    _print_target_banner

    # Probe TARGET safety state (lock status, ARP, slot, bootloader version)
    _probe_target_safety

    # Boot TWRP on TARGET
    tgt "Booting TWRP image on TARGET (temporary, RAM only)..."
    if ! _fastboot boot "$twrp_img"; then
        fail "fastboot boot failed on TARGET. The device may not support booting unsigned images.
  Try instead:
    fastboot${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} flash recovery $twrp_img
    fastboot${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} reboot recovery"
    fi

    ok "TWRP booted on TARGET"
    echo ""

    # Offer to sideload the recovery ZIP
    local zip
    zip=$(find_recovery_zip)
    if [ -n "$zip" ]; then
        echo "  Found recovery ZIP (on HOST): $zip"
        _verify_image_integrity "$zip" "recovery ZIP"
        echo ""
        read -r -p "  Sideload this ZIP to TARGET now? [y/N]: " do_sideload
        if [ "$do_sideload" = "y" ] || [ "$do_sideload" = "Y" ]; then
            echo ""
            info "Waiting for TWRP ADB on TARGET..."
            echo "  On TARGET device: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            wait_for_device adb 120 || fail "TARGET not detected in ADB mode. Start ADB sideload in TWRP on TARGET first."

            tgt "Sideloading to TARGET: $zip"
            _adb sideload "$zip"
            local rc=$?
            if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
                # adb sideload returns 1 on some TWRP versions even on success
                ok "Sideload to TARGET complete (exit code $rc)"
            else
                fail "Sideload to TARGET failed (exit code $rc)"
            fi
        fi
    else
        echo "  No recovery ZIP found in $DIST_DIR/ (on HOST)"
        echo "  Run 'build/build_offline_zip.sh' on HOST first, or push manually:"
        echo "    adb${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} push <recovery-zip> /sdcard/"
        echo "    Then flash from TWRP on TARGET: Install → select ZIP"
    fi

    echo ""
    echo "  Next steps:"
    echo "    1. If not sideloaded: flash the ZIP from TWRP on TARGET → Install"
    echo "    2. After flash: TARGET reboots automatically"
    echo "    3. On TARGET: open Magisk app → confirm root"
    echo ""
}

# ── C2: Direct fastboot flash ────────────────────────────────

run_c2() {
    local patched_img="${1:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Mode C2 — Direct Fastboot Flash"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "HOST ($HOM_HOST_OS) will flash a pre-patched boot image to TARGET via fastboot."
    info "No recovery needed on TARGET. Boot image must be patched on HOST first."
    echo ""

    # Validate patched image (must exist on HOST)
    if [ -z "$patched_img" ]; then
        echo "  Enter the path to your Magisk-patched boot image (on this $HOM_HOST_OS machine):"
        echo "  (Patch via Magisk app on another device, or extract from factory image)"
        echo ""
        read -r -p "  Patched boot image path (on HOST): " patched_img
    fi

    if [ ! -f "$patched_img" ]; then
        fail "Patched boot image not found at: $patched_img (on HOST)"
    fi

    ok "Patched image (on HOST): $patched_img"

    # Integrity check (sha256, fails on mismatch with --sha256 / sidecar)
    _verify_image_integrity "$patched_img" "patched boot image"

    # Detect target partition (extended: init_boot / vendor_boot / recovery / boot).
    # --partition CLI flag overrides auto-detection.
    local part_name
    if [ -n "$HOM_FORCE_PART" ]; then
        part_name="$HOM_FORCE_PART"
        info "Target partition on TARGET: $part_name (forced via --partition)"
    else
        part_name=$(_detect_partition "$patched_img")
        if [ -z "$part_name" ]; then
            warn "Could not auto-detect target partition from filename: $(basename "$patched_img")"
            echo "  Common names: boot, init_boot (Android 13+ GKI 2.0), vendor_boot (Android 12+ GKI), recovery (A-only)."
            read -r -p "  Enter target partition name [boot]: " part_name
            part_name="${part_name:-boot}"
        else
            info "Target partition on TARGET: $part_name (detected from filename)"
        fi
    fi

    # Get TARGET into fastboot
    if check_device_fastboot; then
        _resolve_target_serial fastboot
        _identify_target_fastboot
        ok "TARGET already in fastboot mode"
    elif check_device_adb; then
        _resolve_target_serial adb
        _identify_target_adb
        tgt "Rebooting TARGET to bootloader..."
        _adb reboot bootloader
        wait_for_device fastboot 30 || fail "TARGET did not enter fastboot mode"
    else
        echo ""
        warn "No TARGET device detected."
        case "$HOM_HOST_OS" in
            termux)
                echo "    Connect TARGET device via USB OTG cable, then:"
                echo "      Power off TARGET → hold Power + Volume Down"
                ;;
            *)
                echo "    Connect TARGET and enter fastboot mode:"
                echo "      Power off TARGET → hold Power + Volume Down"
                ;;
        esac
        echo ""
        wait_for_device fastboot 60 || fail "No TARGET device found in fastboot mode"
        _resolve_target_serial fastboot
        _identify_target_fastboot
    fi

    _print_target_banner

    # Probe TARGET safety state (lock status, ARP, slot, bootloader version).
    # Refuses to flash a locked bootloader unless --force-locked is set.
    _probe_target_safety

    # Verify the partition actually exists on TARGET (best-effort).
    _check_partition_exists "$part_name"

    # Confirm before flashing TARGET
    echo ""
    echo "  ${CLR_YELLOW}WARNING: This will overwrite the $part_name partition on TARGET.${CLR_RESET}"
    echo "  HOST     : $HOM_HOST_OS"
    echo "  TARGET   : ${HOM_TARGET_MODEL:-unknown} (serial: ${HOM_TARGET_SERIAL_DISPLAY:-auto})"
    echo "  Partition: $part_name"
    echo "  Image    : $patched_img (on HOST)"
    echo ""
    read -r -p "  Proceed with flash to TARGET? [y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Flash cancelled."
        return 0
    fi

    # Flash TARGET
    tgt "Flashing $part_name on TARGET..."
    if ! _fastboot flash "$part_name" "$patched_img"; then
        fail "fastboot flash failed on TARGET. Check:
  • Is TARGET's bootloader unlocked?
  • Is the image the correct format for TARGET?
  • Try: fastboot${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} flashing unlock"
    fi

    ok "Flash to TARGET successful"

    # Reboot TARGET
    read -r -p "  Reboot TARGET now? [Y/n]: " do_reboot
    if [ "$do_reboot" != "n" ] && [ "$do_reboot" != "N" ]; then
        _fastboot reboot
        ok "TARGET rebooting"
    fi

    echo ""
    echo "  Next steps (on TARGET device):"
    echo "    1. Install Magisk app (APK) if not already installed"
    echo "    2. Open Magisk → confirm root"
    echo "    3. Flash the hands-on-metal Magisk module ZIP via Magisk app"
    echo ""
}

# ── C3: ADB sideload ─────────────────────────────────────────

run_c3() {
    local zip="${1:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Mode C3 — ADB Sideload"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "HOST ($HOM_HOST_OS) will sideload the recovery ZIP to TARGET."
    warn "Stock recovery on TARGET does NOT accept unsigned ZIPs — custom recovery required."
    echo ""

    # Find ZIP (on HOST)
    if [ -z "$zip" ]; then
        zip=$(find_recovery_zip)
        if [ -n "$zip" ]; then
            info "Found recovery ZIP (on HOST): $zip"
            read -r -p "  Use this ZIP? [Y/n]: " use_found
            if [ "$use_found" = "n" ] || [ "$use_found" = "N" ]; then
                read -r -p "  Enter ZIP path (on HOST): " zip
            fi
        else
            echo "  No recovery ZIP found in $DIST_DIR/ (on HOST)"
            echo "  Run 'build/build_offline_zip.sh' on HOST first, or enter a path:"
            echo ""
            read -r -p "  Recovery ZIP path (on HOST): " zip
        fi
    fi

    if [ ! -f "$zip" ]; then
        fail "Recovery ZIP not found at: $zip (on HOST)"
    fi

    ok "Recovery ZIP (on HOST): $zip"

    # Integrity check
    _verify_image_integrity "$zip" "recovery ZIP"

    # Check TARGET device state
    if check_device_adb; then
        _resolve_target_serial adb
        _identify_target_adb

        # Check if already in recovery/sideload
        local state
        state=$(adb devices 2>/dev/null | grep -E "^${HOM_TARGET_SERIAL:-[^\t]+}\s" | grep -oE '(recovery|sideload)' | head -1 || true)
        if [ "$state" = "sideload" ]; then
            ok "TARGET already in sideload mode"
        elif [ "$state" = "recovery" ]; then
            tgt "TARGET is in recovery mode."
            echo "  On TARGET: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            read -r -p "  Press Enter when sideload mode is active on TARGET..."
        else
            tgt "TARGET detected in normal ADB mode. Rebooting TARGET to recovery..."
            _adb reboot recovery
            echo ""
            echo "  Waiting for TWRP to boot on TARGET..."
            echo "  When TWRP loads on TARGET: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            read -r -p "  Press Enter when sideload mode is active on TARGET..."
        fi
    else
        echo ""
        warn "No TARGET device detected via ADB."
        case "$HOM_HOST_OS" in
            termux)
                echo "    For wireless ADB:"
                echo "      1. On TARGET: Settings → Developer options → Wireless debugging"
                echo "      2. On this device: adb pair <ip>:<pair_port>"
                echo "      3. On this device: adb connect <ip>:<port>"
                echo "    For USB OTG:"
                echo "      Connect TARGET via OTG cable"
                ;;
            *)
                echo "    1. Connect TARGET via USB"
                echo "    2. Boot TARGET into recovery (Power + Volume Down, or 'adb reboot recovery')"
                echo "    3. In TWRP on TARGET: Advanced → ADB Sideload → Swipe to start"
                ;;
        esac
        echo ""
        read -r -p "  Press Enter when TARGET is in sideload mode..."
        _resolve_target_serial adb
        _identify_target_adb
    fi

    _print_target_banner

    # Sideload to TARGET
    tgt "Sideloading to TARGET: $zip"
    _adb sideload "$zip"
    local rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
        ok "Sideload to TARGET complete (exit code $rc — normal for TWRP)"
    else
        fail "Sideload to TARGET failed (exit code $rc).
  Check that TARGET is in TWRP sideload mode.
  Stock recovery rejects unsigned ZIPs."
    fi

    echo ""
    echo "  Next steps (on TARGET device):"
    echo "    1. TARGET reboots automatically after the installer finishes"
    echo "    2. On TARGET: open Magisk app → confirm root"
    echo "    3. On TARGET: check /sdcard/hands-on-metal/ for hardware data"
    echo ""
}

# ── Interactive menu ──────────────────────────────────────────

show_menu() {
    check_host_prereqs

    local zip
    zip=$(find_recovery_zip)

    # Try to detect and identify target
    local target_status="not detected"
    if check_device_adb; then
        _resolve_target_serial adb
        _identify_target_adb
        target_status="${HOM_TARGET_MODEL} (Android ${HOM_TARGET_ANDROID_VER}, serial: ${HOM_TARGET_SERIAL_DISPLAY})"
    elif check_device_fastboot; then
        _resolve_target_serial fastboot
        _identify_target_fastboot
        target_status="${HOM_TARGET_MODEL} (fastboot, serial: ${HOM_TARGET_SERIAL_DISPLAY})"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  hands-on-metal — Host-Assisted Flash (Mode C)"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    printf "  HOST   : %s (%s)\n" "$HOM_HOST_OS" "$(uname -m 2>/dev/null || echo unknown)"
    printf "  TARGET : %s\n" "$target_status"
    echo ""
    echo "  Choose an action:"
    echo ""
    echo "    ${CLR_GREEN}Flash / Install (USB or OTG recommended):${CLR_RESET}"
    echo "    1) C1 — Temporary TWRP boot (fastboot boot twrp.img)"
    echo "           Boots TWRP in RAM on TARGET, then sideload. ${CLR_CYAN}[USB/OTG]${CLR_RESET}"
    echo ""
    echo "    2) C2 — Direct fastboot flash (pre-patched boot image)"
    echo "           Flashes boot image from HOST to TARGET. ${CLR_CYAN}[USB/OTG]${CLR_RESET}"
    echo ""
    echo "    3) C3 — ADB sideload (requires TWRP/OrangeFox on TARGET)"
    echo "           Sends recovery ZIP from HOST to TARGET. ${CLR_CYAN}[USB/OTG/WiFi]${CLR_RESET}"
    echo ""
    echo "    ${CLR_CYAN}Diagnostics:${CLR_RESET}"
    echo "    4) Dump — Collect diagnostic data from TARGET"
    echo "           Works with or without root. Feeds into the pipeline."
    echo ""
    echo "    5) Elevated setup — Install Shizuku/LADB for enhanced access"
    echo "           ADB shell-level (UID 2000) without root. Better data collection."
    echo ""
    echo "    ${CLR_YELLOW}Last resort (only if USB/OTG unavailable):${CLR_RESET}"
    echo "    6) WiFi setup — Pair and connect to TARGET over wireless ADB"
    echo "           No fastboot. ADB only. Android 11+ required on TARGET."
    echo ""

    if [ -n "$zip" ]; then
        echo "  ${CLR_GREEN}Recovery ZIP found (on HOST): $(basename "$zip")${CLR_RESET}"
    else
        echo "  ${CLR_YELLOW}No recovery ZIP found on HOST — run 'build/build_offline_zip.sh' first${CLR_RESET}"
    fi

    echo ""
    echo "    q) Back to main menu"
    echo ""

    read -r -p "  Choose [1/2/3/4/5/6/q]: " choice
    case "$choice" in
        1) run_c1 ;;
        2) run_c2 ;;
        3) run_c3 ;;
        4) run_dump ;;
        5) run_elevated_setup ;;
        6) run_wifi_setup ;;
        q|Q) return 0 ;;
        *) warn "Invalid choice"; show_menu ;;
    esac
}

# ── CLI entry point ───────────────────────────────────────────

main() {
    # Parse global options first (-s serial, --partition, --no-verify, --sha256, --force-locked)
    while [ $# -gt 0 ]; do
        case "$1" in
            -s)
                shift
                if [ $# -eq 0 ]; then
                    fail "Option -s requires a serial number argument."
                fi
                HOM_TARGET_SERIAL="$1"
                info "Target serial set: $HOM_TARGET_SERIAL"
                shift
                ;;
            --partition)
                shift
                if [ $# -eq 0 ]; then
                    fail "Option --partition requires a partition name (e.g. boot, init_boot, vendor_boot, recovery)."
                fi
                HOM_FORCE_PART="$1"
                info "Target partition forced: $HOM_FORCE_PART"
                shift
                ;;
            --partition=*)
                HOM_FORCE_PART="${1#*=}"
                info "Target partition forced: $HOM_FORCE_PART"
                shift
                ;;
            --sha256)
                shift
                if [ $# -eq 0 ]; then
                    fail "Option --sha256 requires a hex digest argument."
                fi
                HOM_EXPECTED_SHA256="$1"
                shift
                ;;
            --sha256=*)
                HOM_EXPECTED_SHA256="${1#*=}"
                shift
                ;;
            --no-verify)
                HOM_NO_VERIFY="true"
                shift
                ;;
            --force-locked)
                HOM_FORCE_FLASH="true"
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    case "${1:-}" in
        --c1) shift; check_host_prereqs; run_c1 "$@" ;;
        --c2) shift; check_host_prereqs; run_c2 "$@" ;;
        --c3) shift; check_host_prereqs; run_c3 "$@" ;;
        --wifi-setup) shift; check_host_prereqs; run_wifi_setup "$@" ;;
        --dump) shift; check_host_prereqs; run_dump "$@" ;;
        --elevated-setup) shift; check_host_prereqs; run_elevated_setup "$@" ;;
        --help|-h)
            echo "Usage: bash build/host_flash.sh [-s SERIAL] [COMMAND]"
            echo ""
            echo "  Flashes, diagnoses, or dumps a TARGET device from this HOST."
            echo ""
            echo "  Commands:"
            echo "  --c1 TWRP_IMG      Temporarily boot TWRP on TARGET, then sideload"
            echo "  --c2 PATCHED_IMG   Flash pre-patched boot image to TARGET via fastboot"
            echo "  --c3 ZIP           ADB sideload recovery ZIP to TARGET in TWRP"
            echo "  --wifi-setup       Pair and connect to TARGET over wireless ADB (no root needed)"
            echo "  --dump [DIR]       Collect diagnostic/partition data from TARGET"
            echo "  --elevated-setup   Set up Shizuku/LADB for enhanced non-root access on TARGET"
            echo ""
            echo "  Options:"
            echo "  -s SERIAL          Target a specific device by serial number"
            echo "                     (required when multiple devices are connected)"
            echo "  --partition NAME   Override partition auto-detection for --c2"
            echo "                     (boot | init_boot | vendor_boot | recovery)"
            echo "  --sha256 HEX       Expected SHA-256 of the image/ZIP being sent to TARGET."
            echo "                     A matching '<image>.sha256' sidecar file is also honoured."
            echo "  --no-verify        Skip image integrity check (NOT RECOMMENDED)"
            echo "  --force-locked     Allow flashing even if TARGET bootloader is locked"
            echo "                     (almost certainly fails; only for unusual setups)"
            echo ""
            echo "  Safety: --c1/--c2/--c3 verify image integrity (SHA-256), probe TARGET"
            echo "  via 'fastboot getvar' (unlocked, secure, current-slot, version-bootloader,"
            echo "  version-baseband, anti-rollback-version), and refuse to flash a locked"
            echo "  bootloader unless --force-locked is supplied.  Boot-type detection covers"
            echo "  Android 10–16: boot, init_boot (GKI 2.0, A13+), vendor_boot (GKI, A12+),"
            echo "  recovery (A-only)."
            echo ""
            echo "  No arguments: show interactive menu"
            echo ""
            echo "  HOST   = this machine ($(uname -s)/$(uname -m))"
            echo "  TARGET = the device being flashed (connected via USB/OTG/wireless)"
            echo ""
            echo "  Prerequisite: Enable USB debugging on TARGET:"
            echo "    Settings → About phone → tap 'Build number' 7 times"
            echo "    Settings → Developer options → USB debugging → ON"
            ;;
        *)  show_menu ;;
    esac
}

main "$@"
