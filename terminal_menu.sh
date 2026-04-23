#!/usr/bin/env bash
# terminal_menu.sh
# ============================================================
# hands-on-metal — Device Workflow Menu  (Phases 1-4)
#
# Interactive launcher for the core device-side workflow:
#   Phase 1 · Setup & Build
#   Phase 2 · Environment & Device Detection
#   Phase 3 · Boot Image & Pre-patch Analysis
#   Phase 4 · Patch & Flash
#
# For the analysis pipeline (Phases 5-8), press 'm' inside this
# menu or run:
#   bash pipeline_menu.sh
#
# Usage:
#   bash terminal_menu.sh
#
# Can also be launched remotely:
#   curl -fsSL https://raw.githubusercontent.com/mikethi/hands-on-metal/main/terminal_menu.sh | bash
# ============================================================

set -eu

# ── Reopen stdin from /dev/tty when piped (curl | bash) ───────
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec < /dev/tty
elif [ ! -t 0 ]; then
    echo "Error: no interactive terminal available (stdin is not a tty)." >&2
    echo "Run 'bash terminal_menu.sh' from an interactive terminal session." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Host-side dependency check ────────────────────────────────
# shellcheck disable=SC1091
source "$REPO_ROOT/check_deps.sh" || exit 1

# ── Shared menu library (display, prereqs, run logic) ─────────
# shellcheck source=core/menu_lib.sh
source "$REPO_ROOT/core/menu_lib.sh"

# ── Menu identity ─────────────────────────────────────────────
HOM_MENU_TITLE="hands-on-metal  ·  Device Workflow"
HOM_MENU_SCRIPT_NAME="terminal_menu"
HOM_OTHER_MENU="$REPO_ROOT/pipeline_menu.sh"
HOM_OTHER_MENU_LABEL="pipeline menu (m)"

# ── Phase 1-4 script index ────────────────────────────────────
build_script_index() {
    SCRIPT_LABELS=()
    SCRIPT_PATHS=()
    SCRIPT_TYPES=()

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

main "$@"
