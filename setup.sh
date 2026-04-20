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
#   bash setup.sh             # syncs repo first by default
#   bash setup.sh --no-sync   # skip sync and use current checkout
#
# The script is safe to re-run — it skips steps that are
# already complete (existing clone, existing binaries, etc.).
# ============================================================

set -e

FORCE_REPO_SYNC=true

usage() {
    echo "Usage: bash setup.sh [--no-sync] [--help]"
    echo "  (default)         Fetch and pull (fast-forward only) before setup continues."
    echo "  --no-sync         Skip repo sync and continue with current checkout."
    echo "  --help            Show this help and exit."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-sync)
            FORCE_REPO_SYNC=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

_hom_sync_repo() {
    local repo_dir="${1:-.}"
    echo "Syncing repository in '$repo_dir'..."
    if ! git -C "$repo_dir" fetch --tags --prune; then
        echo "ERROR: git fetch failed in '$repo_dir'." >&2
        return 1
    fi
    if ! git -C "$repo_dir" pull --ff-only; then
        echo "ERROR: git pull --ff-only failed in '$repo_dir'." >&2
        echo "       Check for local/uncommitted changes or branch divergence." >&2
        echo "       Run: git -C '$repo_dir' status" >&2
        return 1
    fi
}

# ── Helper: auto-install a package if the command is missing ──
# Usage: _hom_auto_install <command> <pkg_name> [<termux_pkg>]
# If <termux_pkg> is omitted, <pkg_name> is used for Termux too.
_hom_pkg_index_updated=false

_hom_auto_install() {
    local cmd="$1" pkg="$2" termux_pkg="${3:-$2}"

    command -v "$cmd" >/dev/null 2>&1 && return 0

    echo "$cmd is not installed — attempting automatic install..."

    local _installed=false

    if [ -d "/data/data/com.termux/files/usr" ] || [ -n "${TERMUX_VERSION:-}" ]; then
        # Termux on Android
        pkg install -y "$termux_pkg" && _installed=true
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian / Ubuntu
        if [ "$_hom_pkg_index_updated" = false ]; then
            sudo apt-get update -qq
            _hom_pkg_index_updated=true
        fi
        sudo apt-get install -y -qq "$pkg" && _installed=true
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora
        sudo dnf install -y "$pkg" && _installed=true
    elif command -v pacman >/dev/null 2>&1; then
        # Arch / Manjaro
        sudo pacman -S --noconfirm "$pkg" && _installed=true
    elif command -v brew >/dev/null 2>&1; then
        # macOS with Homebrew
        brew install "$pkg" && _installed=true
    fi

    if [ "$_installed" = false ] || ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Could not auto-install $cmd ($pkg)." >&2
        echo "  Please install it manually and re-run this script." >&2
        exit 1
    fi

    echo "$cmd installed successfully."
}

# ── Auto-install required tools ──────────────────────────────
# git is needed to clone; the rest are needed by build scripts.

# Special case: macOS without Homebrew needs xcode-select for git
if ! command -v git >/dev/null 2>&1 && [ "$(uname)" = "Darwin" ] && ! command -v brew >/dev/null 2>&1; then
    echo "Installing Xcode Command Line Tools (includes git)..."
    xcode-select --install 2>/dev/null || true
    echo "Follow the on-screen dialog, then re-run this script." >&2
    exit 1
fi

_hom_auto_install git      git
_hom_auto_install zip      zip
_hom_auto_install unzip    unzip
_hom_auto_install curl     curl
_hom_auto_install python3  python3   python   # Termux package is "python" but provides python3
_hom_auto_install tar      tar

# sha256sum OR shasum — at least one must be present
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    _hom_auto_install sha256sum coreutils
fi

unset _hom_pkg_index_updated
unset -f _hom_auto_install

# ── If we are already inside the repo, use it in-place ────────
if [ -f "check_deps.sh" ] && [ -d "build" ] && [ -f "build/fetch_all_deps.sh" ]; then
    echo "Running inside an existing hands-on-metal checkout."
    if [ "$FORCE_REPO_SYNC" = true ]; then
        if ! _hom_sync_repo "."; then
            echo "ERROR: repository sync failed." >&2
            exit 1
        fi
    fi
else
    if [ -d "hands-on-metal" ]; then
        echo "Directory 'hands-on-metal' already exists — pulling latest..."
        if [ "$FORCE_REPO_SYNC" = true ]; then
            if ! _hom_sync_repo "hands-on-metal"; then
                echo "ERROR: repository sync failed." >&2
                exit 1
            fi
        else
            echo "Skipping repo sync (--no-sync)."
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

# ── Launch interactive menu ──────────────────────────────────
# After setup, drop the user into the terminal menu by default.
echo ""
echo "Setup complete — launching terminal menu..."
echo ""
if [ -e /dev/tty ]; then
    exec bash terminal_menu.sh </dev/tty
else
    echo "No interactive terminal available."
    echo "Run 'bash terminal_menu.sh' from an interactive terminal session to continue."
fi
