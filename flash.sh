#!/usr/bin/env bash
# flash.sh
# ============================================================
# hands-on-metal — Complete Flash Workflow (root entrypoint)
#
# A single-command wrapper around build/host_flash.sh.  Drives
# the host-assisted flash for all three install paths:
#
#   Mode A — Magisk already installed
#            Build ZIP, then push it to the device and flash it
#            from the Magisk app:
#              bash flash.sh
#              # (use the menu's "push ZIP to device" sub-option,
#              #  or just connect the device and pick the option
#              #  matching your situation)
#
#   Mode B — TWRP / OrangeFox recovery (no Magisk yet)
#            Boot recovery on the target, then sideload the
#            recovery ZIP:
#              bash flash.sh --c3 dist/hands-on-metal-recovery-*.zip
#
#   Mode C — No recovery; bootloader unlocked; PC connected
#            Temporary TWRP boot or direct fastboot flash:
#              bash flash.sh --c1 path/to/twrp.img
#              bash flash.sh --c2 path/to/patched_boot.img
#
# Common options:
#   -s SERIAL   Target a specific device when several are connected.
#
# Run with no arguments to enter the interactive sub-menu in
# build/host_flash.sh, which lists every supported flash path
# and walks through it step by step.
#
# All arguments are forwarded verbatim to build/host_flash.sh.
# ============================================================

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# host_flash.sh prints its own completion / next-step messages,
# so we just delegate.
exec bash build/host_flash.sh "$@"
