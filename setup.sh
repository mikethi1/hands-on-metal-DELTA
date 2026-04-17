#!/usr/bin/env bash
# setup.sh
# ============================================================
# hands-on-metal — One-Step Bootstrap
#
# Downloads (clones) the full repository, verifies host-side
# dependencies, fetches all binaries, and builds the flashable
# ZIPs in one shot.
#
# Usage (run from anywhere):
#   curl -fsSL https://raw.githubusercontent.com/mikethi/hands-on-metal/main/setup.sh | bash
#
# Or clone first and run locally:
#   bash setup.sh
#
# The script is safe to re-run — it skips steps that are
# already complete (existing clone, existing binaries, etc.).
# ============================================================

set -e

# ── git is needed to clone — auto-install if missing ─────────
if ! command -v git >/dev/null 2>&1; then
    echo "git is not installed — attempting automatic install..."

    _installed=false

    if [ -d "/data/data/com.termux/files/usr" ] || [ -n "${TERMUX_VERSION:-}" ]; then
        # Termux on Android
        pkg install -y git && _installed=true
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian / Ubuntu
        sudo apt-get update -qq && sudo apt-get install -y -qq git && _installed=true
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora
        sudo dnf install -y git && _installed=true
    elif command -v pacman >/dev/null 2>&1; then
        # Arch / Manjaro
        sudo pacman -S --noconfirm git && _installed=true
    elif command -v brew >/dev/null 2>&1; then
        # macOS with Homebrew
        brew install git && _installed=true
    elif [ "$(uname)" = "Darwin" ]; then
        # macOS without Homebrew — xcode-select triggers the CLT installer
        echo "Installing Xcode Command Line Tools (includes git)..."
        xcode-select --install 2>/dev/null || true
        echo "Follow the on-screen dialog, then re-run this script." >&2
        exit 1
    fi

    if [ "$_installed" = false ] || ! command -v git >/dev/null 2>&1; then
        echo "ERROR: Could not auto-install git." >&2
        echo "  Please install it manually and re-run this script:" >&2
        echo "    Debian / Ubuntu : sudo apt install git" >&2
        echo "    Termux          : pkg install git"      >&2
        echo "    Fedora          : sudo dnf install git"  >&2
        echo "    Arch / Manjaro  : sudo pacman -S git"    >&2
        echo "    macOS           : xcode-select --install" >&2
        exit 1
    fi

    unset _installed
    echo "git installed successfully."
fi

# ── If we are already inside the repo, use it in-place ────────
if [ -f "check_deps.sh" ] && [ -d "build" ] && [ -f "build/fetch_all_deps.sh" ]; then
    echo "Running inside an existing hands-on-metal checkout."
else
    if [ -d "hands-on-metal" ]; then
        echo "Directory 'hands-on-metal' already exists — pulling latest..."
        if ! git -C hands-on-metal pull --ff-only 2>/dev/null; then
            echo "  ⚠  Could not update existing clone (network or merge issue)." >&2
            echo "     Continuing with the current version." >&2
        fi
    else
        git clone https://github.com/mikethi/hands-on-metal.git
    fi
    cd hands-on-metal
fi

# ── Verify host tools then fetch binaries + build ZIPs ────────
# check_deps.sh sets HOM_DEPS_CHECKED=1 so fetch_all_deps.sh
# skips the redundant re-check automatically.
source check_deps.sh
bash build/fetch_all_deps.sh
