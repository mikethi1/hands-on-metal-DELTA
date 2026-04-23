#!/system/bin/sh
# core/ux.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# User-experience helpers — printing, prompting, instructions.
# Works in three contexts:
#   1. TWRP/recovery: output via OUTFD file descriptor
#   2. Interactive shell (Termux/ADB): output to stderr + stdin
#   3. Background service (Magisk boot): output logged only
#
# Requires logging.sh to be sourced first.
#
# Public API:
#   ux_print     MESSAGE
#   ux_sep
#   ux_section   TITLE
#   ux_step_info STEP_NAME WHAT WHY
#   ux_step_result STEP OK|FAIL [NOTE]
#   ux_prompt    VARNAME "prompt text" DEFAULT
#   ux_instructions LINES...
#   ux_progress  PCT         (0-100, TWRP progress bar)
#   ux_abort     MESSAGE     (print + exit 1)
# ============================================================

# OUTFD is set by TWRP/recovery framework.  Default is empty
# (meaning we write to stderr only).
OUTFD="${OUTFD:-}"

# ── internal ─────────────────────────────────────────────────
_ux_outfd() {
    local msg="$1"
    if [ -n "$OUTFD" ]; then
        printf 'ui_print %s\n' "$msg" > /proc/self/fd/"$OUTFD" 2>/dev/null || true
        printf 'ui_print \n'           > /proc/self/fd/"$OUTFD" 2>/dev/null || true
    fi
}

# ── public: print one line to user ───────────────────────────
# UX output is written to:
#   • TWRP/recovery UI (via OUTFD), if available
#   • stderr (visible in adb shell / Termux)
#   • the script's log files (tagged [UX]) — but NOT re-emitted to
#     stderr by the logger, otherwise the user sees every UX line
#     twice (once direct, once as "[…INFO…] [UX] …").
ux_print() {
    local msg="$*"
    _ux_outfd "$msg"
    # Always write to stderr (visible in adb shell / Termux)
    printf '%s\n' "$msg" >&2
    # Mirror to log files only (avoid duplicate stderr emission).
    if command -v _hom_ts >/dev/null 2>&1; then
        local _ux_ts _ux_line
        _ux_ts=$(_hom_ts)
        _ux_line="[$_ux_ts][INFO ][${SCRIPT_NAME:-unknown}] [UX] $msg"
        printf '%s\n' "$_ux_line" >> "${SCRIPT_LOG:-/dev/null}" 2>/dev/null || true
        printf '%s\n' "$_ux_line" >> "${MASTER_LOG:-/dev/null}" 2>/dev/null || true
    fi
}

# ── public: separator line ────────────────────────────────────
ux_sep() {
    ux_print "──────────────────────────────────────────"
}

# ── public: section header ────────────────────────────────────
ux_section() {
    ux_sep
    ux_print "▶  $*"
    ux_sep
}

# ── public: step explainer ────────────────────────────────────
# Shows the user what the step does, why it is needed, and what
# success/failure means — before the step executes.
# Usage: ux_step_info "Step Name" "what it does" "why needed"
ux_step_info() {
    local step="$1"
    local what="$2"
    local why="$3"
    ux_sep
    ux_print "STEP : $step"
    ux_print "WHAT : $what"
    ux_print "WHY  : $why"
    ux_sep
}

# ── public: step result ───────────────────────────────────────
# Usage: ux_step_result "Step Name" OK|FAIL [optional note]
ux_step_result() {
    local step="$1"
    local result="$2"
    local note="${3:-}"
    if [ "$result" = "OK" ]; then
        ux_print "[ OK ] $step${note:+  — $note}"
    else
        ux_print "[FAIL] $step${note:+  — $note}"
    fi
}

# ── public: interactive prompt ────────────────────────────────
# In interactive mode (stdin is a tty), read a line from the user.
# In non-interactive mode (service, TWRP), use the default.
# Usage: ux_prompt VARNAME "Prompt text" DEFAULT_VALUE
ux_prompt() {
    local varname="$1"
    local prompt="$2"
    local default="$3"

    if [ -t 0 ]; then
        printf '\n%s [%s]: ' "$prompt" "$default" >&2
        local answer
        read -r answer </dev/tty 2>/dev/null || answer=""
        local chosen="${answer:-$default}"
        eval "$varname=\"\$chosen\""
        log_var "$varname" "$chosen" "user input (prompt: $prompt)"
    else
        # Non-interactive: use default and log it
        eval "$varname=\"\$default\""
        log_var "$varname" "$default" "non-interactive default (prompt: $prompt)"
        ux_print "  [auto] $prompt → $default"
    fi
}

# ── public: action instructions ──────────────────────────────
# Print a numbered list of manual actions the user must perform.
# Usage: ux_instructions "Step 1 text" "Step 2 text" ...
ux_instructions() {
    ux_sep
    ux_print "ACTION REQUIRED — please follow these steps:"
    local n=1
    for line in "$@"; do
        ux_print "  $n) $line"
        n=$((n + 1))
    done
    ux_sep
}

# ── public: TWRP progress bar ────────────────────────────────
# Moves the TWRP progress bar to PCT% (0-100).
ux_progress() {
    local pct="$1"
    if [ -n "$OUTFD" ]; then
        # TWRP expects a float 0.00–1.00
        local frac
        frac=$(awk "BEGIN{printf \"%.2f\", $pct/100}" 2>/dev/null || echo "0.00")
        printf 'set_progress %s\n' "$frac" > /proc/self/fd/"$OUTFD" 2>/dev/null || true
    fi
}

# ── public: abort with message ───────────────────────────────
ux_abort() {
    local msg="$*"
    ux_print ""
    ux_print "╔══════════════════════════════════════════╗"
    ux_print "║  INSTALLATION ABORTED                    ║"
    ux_print "╠══════════════════════════════════════════╣"
    ux_print "║  $msg"
    ux_print "╚══════════════════════════════════════════╝"
    ux_print ""
    log_error "ABORT: $msg"
    manifest_step "ABORT" "FAIL" "$msg"
    exit 1
}
