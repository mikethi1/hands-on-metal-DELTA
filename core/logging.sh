#!/system/bin/sh
# core/logging.sh
# ============================================================
# Shared logging framework for hands-on-metal scripts.
# Source this file from every script that needs logging.
#
# Caller should set before sourcing:
#   LOG_DIR     (default: /sdcard/hands-on-metal/logs)
#   SCRIPT_NAME (default: unknown)
#   RUN_ID      (default: auto-generated timestamp)
#
# Public API:
#   log_info  MESSAGE
#   log_warn  MESSAGE
#   log_error MESSAGE
#   log_debug MESSAGE
#   log_var   VARNAME VALUE "description"
#   log_exec  "step label" COMMAND [ARGS...]
#   log_banner MESSAGE
#   manifest_step STEP STATUS NOTE
# ============================================================

LOG_DIR="${LOG_DIR:-/sdcard/hands-on-metal/logs}"
SCRIPT_NAME="${SCRIPT_NAME:-unknown}"

# Generate a run ID once; child scripts inherit it via export.
if [ -z "${RUN_ID:-}" ]; then
    RUN_ID=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo "NOTS$$")
    export RUN_ID
fi

MASTER_LOG="$LOG_DIR/master_${RUN_ID}.log"
SCRIPT_LOG="$LOG_DIR/${SCRIPT_NAME}_${RUN_ID}.log"
RUN_MANIFEST="$LOG_DIR/run_manifest_${RUN_ID}.txt"
VAR_AUDIT="$LOG_DIR/var_audit_${RUN_ID}.txt"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# ── internal helpers ──────────────────────────────────────────

_hom_ts() {
    date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "UNKNOWN"
}

_log_line() {
    local level="$1"; shift
    local ts; ts=$(_hom_ts)
    local line="[$ts][$level][$SCRIPT_NAME] $*"
    printf '%s\n' "$line" >> "$SCRIPT_LOG"  2>/dev/null || true
    printf '%s\n' "$line" >> "$MASTER_LOG"  2>/dev/null || true
    # Emit to stderr for interactive/TWRP sessions (suppress DEBUG)
    case "$level" in
        DEBUG) ;;
        *)     printf '%s\n' "$line" >&2 ;;
    esac
}

# ── public log levels ─────────────────────────────────────────

log_info()  { _log_line "INFO " "$@"; }
log_warn()  { _log_line "WARN " "$@"; }
log_error() { _log_line "ERROR" "$@"; }
log_debug() { _log_line "DEBUG" "$@"; }

# ── variable audit trail ──────────────────────────────────────
# Records every significant variable with its name, value and a
# human-readable description so the audit log is fully self-explanatory.
# Usage: log_var VARNAME VALUE "human description"
log_var() {
    local name="$1"
    local value="$2"
    local desc="${3:-}"
    local ts; ts=$(_hom_ts)
    local line="[$ts][VAR  ][$SCRIPT_NAME] $name=\"$value\"  # $desc"
    printf '%s\n' "$line" >> "$VAR_AUDIT"   2>/dev/null || true
    printf '%s\n' "$line" >> "$MASTER_LOG"  2>/dev/null || true
}

# ── run manifest ──────────────────────────────────────────────
# Append one step result to the manifest file.
# Usage: manifest_step STEP_NAME STATUS NOTE
# STATUS must be: OK | FAIL | SKIP | PENDING
manifest_step() {
    local step="$1"
    local status="$2"
    local note="${3:-}"
    local ts; ts=$(_hom_ts)
    printf '%s|%s|%s|%s\n' "$ts" "$step" "$status" "$note" \
        >> "$RUN_MANIFEST" 2>/dev/null || true
    log_info "STEP[$step] => $status${note:+  ($note)}"
}

# ── log_exec ─────────────────────────────────────────────────
# Run a command and capture its full stdout+stderr into the log.
# Usage: log_exec "step description" COMMAND [ARGS...]
# Returns the command's exit code unchanged.
log_exec() {
    local step="$1"; shift
    log_info "EXEC[$step] running: $*"

    local tmp_out
    tmp_out=$(mktemp 2>/dev/null || echo "/tmp/_hom_exec_$$")

    "$@" > "$tmp_out" 2>&1
    local rc=$?

    if [ -s "$tmp_out" ]; then
        while IFS= read -r ol; do
            _log_line "EXEC " "[OUTPUT][$step] $ol"
        done < "$tmp_out"
    fi
    rm -f "$tmp_out"

    local status
    status=$([ "$rc" -eq 0 ] && echo OK || echo FAIL)
    manifest_step "$step" "$status" "rc=$rc"
    return "$rc"
}

# ── section banner ────────────────────────────────────────────
log_banner() {
    local bar="========================================"
    log_info "$bar"
    log_info "  $*"
    log_info "$bar"
}

log_info "logging.sh loaded (SCRIPT=$SCRIPT_NAME RUN_ID=$RUN_ID LOG_DIR=$LOG_DIR)"
