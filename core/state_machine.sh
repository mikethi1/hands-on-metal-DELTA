#!/system/bin/sh
# core/state_machine.sh
# ============================================================
# Persistent, reboot-safe state machine for the install flow.
# State is written to /data so it survives reboots.
#
# State order (strict sequence):
#   INIT → ENV_DETECTED → DEVICE_PROFILED → BOOT_IMG_ACQUIRED
#   → BOOT_IMG_PATCHED → ANTI_ROLLBACK_CHECKED → FLASH_QUEUED
#   → FLASHED → ROOT_VERIFIED → COMPLETE
#
# Public API:
#   sm_set_state  STATE         — advance to STATE (writes state file)
#   sm_get_state               — print current state name
#   sm_get_timestamp           — print timestamp of last state change
#   sm_require    STATE        — return 1 if current < required
#   sm_is_complete             — return 0 if state == COMPLETE
#   sm_reset                   — delete state file (start over)
#   sm_print_status            — log current state summary
# ============================================================

# Requires logging.sh to be sourced first.

STATE_FILE="${STATE_FILE:-/data/adb/modules/hands-on-metal-collector/.install_state}"

# Canonical state list — order defines precedence.
_SM_STATES="INIT ENV_DETECTED DEVICE_PROFILED BOOT_IMG_ACQUIRED BOOT_IMG_PATCHED ANTI_ROLLBACK_CHECKED FLASH_QUEUED FLASHED ROOT_VERIFIED COMPLETE"

# ── internal: return 0-based index of STATE, or -1 if unknown ─
_sm_index() {
    local target="$1"
    local i=0
    for s in $_SM_STATES; do
        [ "$s" = "$target" ] && { echo "$i"; return 0; }
        i=$((i + 1))
    done
    echo "-1"
}

# ── public: write new state ───────────────────────────────────
sm_set_state() {
    local new_state="$1"
    local idx; idx=$(_sm_index "$new_state")
    if [ "$idx" = "-1" ]; then
        log_error "sm_set_state: unknown state '$new_state'"
        return 1
    fi
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "UNKNOWN")
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    printf '%s|%s\n' "$new_state" "$ts" > "$STATE_FILE"
    log_var "SM_STATE" "$new_state" "install state machine — advanced at $ts"
    manifest_step "sm_transition" "OK" "→ $new_state"
}

# ── public: read current state ────────────────────────────────
sm_get_state() {
    if [ -f "$STATE_FILE" ]; then
        cut -d'|' -f1 < "$STATE_FILE"
    else
        echo "INIT"
    fi
}

# ── public: read timestamp of last transition ─────────────────
sm_get_timestamp() {
    if [ -f "$STATE_FILE" ]; then
        cut -d'|' -f2 < "$STATE_FILE"
    else
        echo "never"
    fi
}

# ── public: guard — require at least STATE ────────────────────
# Returns 0 if current state index >= required state index.
sm_require() {
    local required="$1"
    local current; current=$(sm_get_state)
    local cur_idx; cur_idx=$(_sm_index "$current")
    local req_idx; req_idx=$(_sm_index "$required")
    if [ "$cur_idx" -lt "$req_idx" ]; then
        log_error "sm_require: need '$required' (idx $req_idx) but current is '$current' (idx $cur_idx)"
        return 1
    fi
    return 0
}

# ── public: complete check ────────────────────────────────────
sm_is_complete() {
    [ "$(sm_get_state)" = "COMPLETE" ]
}

# ── public: reset — delete state file ────────────────────────
sm_reset() {
    rm -f "$STATE_FILE"
    log_info "State machine reset (state file deleted)"
    manifest_step "sm_reset" "OK" "state file deleted"
}

# ── public: print a summary of current state ─────────────────
sm_print_status() {
    local current; current=$(sm_get_state)
    local ts; ts=$(sm_get_timestamp)
    log_info "Current install state: $current (since $ts)"
    log_var "SM_STATE" "$current" "current install state (from state file)"
    log_var "SM_TIMESTAMP" "$ts" "timestamp of last state transition"
}
