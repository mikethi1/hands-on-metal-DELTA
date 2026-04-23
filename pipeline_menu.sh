#!/usr/bin/env bash
# pipeline_menu.sh
# ============================================================
# hands-on-metal — Analysis Pipeline Menu  (Phases 5-8)
#
# Interactive launcher for the host-side analysis workflow:
#   Phase 5 · Module Installation & Data Collection
#   Phase 6 · Analysis Pipeline
#   Phase 7 · Reporting & Sharing
#   Phase 8 · Utility / Framework
#
# For the core device workflow (Phases 1-4), press 'm' inside
# this menu or run:
#   bash terminal_menu.sh
#
# Usage:
#   bash pipeline_menu.sh
# ============================================================

set -eu

# ── Reopen stdin from /dev/tty when piped (curl | bash) ───────
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec < /dev/tty
elif [ ! -t 0 ]; then
    echo "Error: no interactive terminal available (stdin is not a tty)." >&2
    echo "Run 'bash pipeline_menu.sh' from an interactive terminal session." >&2
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
HOM_MENU_TITLE="hands-on-metal  ·  Analysis Pipeline"
HOM_MENU_SCRIPT_NAME="pipeline_menu"
HOM_OTHER_MENU="$REPO_ROOT/terminal_menu.sh"
HOM_OTHER_MENU_LABEL="device menu   (m)"

# ── Phase 5-8 script index ────────────────────────────────────
build_script_index() {
    SCRIPT_LABELS=()
    SCRIPT_PATHS=()
    SCRIPT_TYPES=()

    local _ordered_scripts=(
        # ── Phase 5: Module Installation & Data Collection ────
        "shell:magisk-module/customize.sh"
        "shell:magisk-module/service.sh"
        "shell:magisk-module/collect.sh"
        "shell:recovery-zip/collect_recovery.sh"
        "shell:recovery-zip/collect_factory.sh"
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

main "$@"
