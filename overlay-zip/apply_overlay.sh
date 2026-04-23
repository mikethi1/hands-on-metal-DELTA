#!/sbin/sh
# overlay-zip/apply_overlay.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# hands-on-metal — Hardware Voltage Overlay Application
#
# Called by update-binary (TWRP and Magisk paths) and by the
# Magisk module service.sh on every boot.
#
# What it does:
#   1. Source hom_bare_metal.sh — loads all known-good constants
#      from board_summary.txt (ro.hardware, ro.board.platform, etc.)
#      plus the pre-confirmed voltage rail → hw category map.
#   2. For every rail in hom_hw_voltage_map.json:
#        a. Build the env_registry key for that rail/group pair.
#        b. Check whether the env_registry already has a matching
#           entry whose value equals a bare-metal constant → SKIP.
#        c. Otherwise write the entry to env_registry.
#   3. Copy overlay payload files to $OVERLAY_OUT for the pipeline.
#   4. Log every skipped and written entry so the installer can
#      report the counts.
#
# Environment expected:
#   OVERLAY_SRC  — directory containing the extracted overlay/ tree
#   ENV_REGISTRY — path to ~/hands-on-metal/env_registry.sh
#   OVERLAY_OUT  — destination for overlay file copies
#   LOG_DIR      — directory for overlay.log
# ============================================================

set -u

OVERLAY_SRC="${OVERLAY_SRC:-$(dirname "$0")/overlay}"
ENV_REGISTRY="${ENV_REGISTRY:-/sdcard/hands-on-metal/env_registry.sh}"
OVERLAY_OUT="${OVERLAY_OUT:-/sdcard/hands-on-metal/overlay}"
LOG_DIR="${LOG_DIR:-/sdcard/hands-on-metal/logs}"
LOG="$LOG_DIR/overlay.log"

mkdir -p "$OVERLAY_OUT" "$LOG_DIR"
[ -f "$ENV_REGISTRY" ] || : > "$ENV_REGISTRY"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

# Write/update one key in the env_registry (last-writer-wins)
reg_set() {
    local cat="$1" key="$2" val="$3" note="${4:-}"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s mode:overlay%s\n' \
        "$key" "$val" "$cat" "${note:+ $note}" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

# ── Step 1: source bare-metal constants ───────────────────────

BM_SH="$OVERLAY_SRC/hom_bare_metal.sh"
if [ -f "$BM_SH" ]; then
    # shellcheck source=/dev/null
    . "$BM_SH"
    log "Sourced bare-metal constants from $BM_SH"
else
    log "WARNING: $BM_SH not found — bare-metal skip logic disabled"
fi

# Build a lookup of all known bare-metal values from the sourced vars.
# We test each registry key against these to decide skip vs write.
_is_known_value() {
    # Returns 0 (true) if $1 matches any bare-metal constant value
    local v="$1"
    for bm_val in \
        "${HOM_BM_BOARD_PLATFORM:-zuma}" \
        "${HOM_BM_HARDWARE:-husky}" \
        "${HOM_BM_PRODUCT_BOARD:-husky}" \
        "${HOM_BM_PRODUCT_DEVICE:-husky}" \
        "${HOM_BM_PRODUCT_MODEL:-Pixel 8 Pro}" \
        "${HOM_BM_BUILD_FINGERPRINT:-google/husky/husky:16/CP1A.260305.018/14887507:user/release-keys}" \
        "${HOM_BM_SOC_MANUFACTURER:-Google}" \
        "${HOM_BM_SOC_MODEL:-Tensor G3}" \
        "${HOM_BM_CPU_ABI:-arm64-v8a}"; do
        [ "$v" = "$bm_val" ] && return 0
    done
    return 1
}

# Also skip if the env_registry already has this exact key=value
_already_in_registry() {
    local key="$1" val="$2"
    grep -q "^${key}=\"${val}\"" "$ENV_REGISTRY" 2>/dev/null
}

log "=== apply_overlay.sh start ==="

# ── Step 2: write device identity into registry (from bare-metal constants) ──
# These are already-known — written once with a bare_metal tag so every other
# script that reads the registry can identify them without re-probing.

_write_bm_prop() {
    local key="$1" val="$2"
    local rkey
    rkey="HOM_BM_$(echo "$key" | tr '.' '_' | tr '[:lower:]' '[:upper:]')"
    if _already_in_registry "$rkey" "$val"; then
        log "  skip (registry) $rkey=$val  # skipped:bare_metal"
    elif _is_known_value "$val"; then
        reg_set "bare_metal" "$rkey" "$val" "# skipped:bare_metal"
        log "  write (bm) $rkey=$val  # skipped:bare_metal"
    else
        reg_set "bare_metal" "$rkey" "$val" "# written"
        log "  write $rkey=$val  # written"
    fi
}

_write_bm_prop "ro.board.platform"           "zuma"
_write_bm_prop "ro.hardware"                 "husky"
_write_bm_prop "ro.product.board"            "husky"
_write_bm_prop "ro.product.device"           "husky"
_write_bm_prop "ro.product.model"            "Pixel 8 Pro"
_write_bm_prop "ro.build.fingerprint"        "google/husky/husky:16/CP1A.260305.018/14887507:user/release-keys"
_write_bm_prop "ro.vendor.build.fingerprint" "google/husky/husky:16/CP1A.260305.018/14887507:user/release-keys"
_write_bm_prop "ro.soc.manufacturer"         "Google"
_write_bm_prop "ro.soc.model"                "Tensor G3"
_write_bm_prop "ro.product.cpu.abi"          "arm64-v8a"

# ── Step 3: apply voltage rail → hw group entries ─────────────
# We use a simple shell loop over a flat key=value list derived from
# hom_hw_voltage_map.json.  This avoids needing jq or Python on the
# device — the JSON is the source of truth for humans and the pipeline,
# and this script carries the same data in shell-native form.
#
# Format: _apply_rail RAIL PMIC HW_GROUP [ODPM_CHANNEL] [PROTECTION_EVENT]
#
# The env_registry key written is:
#   HOM_VOLTAGE_RAIL_<RAIL>_HW=<HW_GROUP>          (primary hw group)
#   HOM_VOLTAGE_RAIL_<RAIL>_PMIC=<main|sub>         (which PMIC)
#   HOM_VOLTAGE_RAIL_<RAIL>_ODPM=<CHn>              (ODPM channel, if known)
#   HOM_VOLTAGE_PROT_<EVENT>_RAIL=<RAIL>            (protection event → rail)
#   HOM_VOLTAGE_PROT_<EVENT>_HW=<HW_GROUP>

_apply_rail() {
    local rail="$1" pmic="$2" hw="$3"
    local odpm="${4:-}" prot="${5:-}"
    local rkey_hw rkey_pmic rkey_odpm rkey_prot_rail rkey_prot_hw

    rkey_hw="HOM_VOLTAGE_RAIL_${rail}_HW"
    rkey_pmic="HOM_VOLTAGE_RAIL_${rail}_PMIC"

    if _already_in_registry "$rkey_hw" "$hw"; then
        log "  skip (registry) $rail hw=$hw  # skipped:bare_metal"
    else
        reg_set "voltage" "$rkey_hw"   "$hw"   "# written"
        reg_set "voltage" "$rkey_pmic" "$pmic" "# written"
        log "  write $rail hw=$hw pmic=$pmic  # written"
    fi

    if [ -n "$odpm" ]; then
        rkey_odpm="HOM_VOLTAGE_RAIL_${rail}_ODPM"
        _already_in_registry "$rkey_odpm" "$odpm" || {
            reg_set "voltage" "$rkey_odpm" "$odpm" "# written"
        }
    fi

    if [ -n "$prot" ]; then
        rkey_prot_rail="HOM_VOLTAGE_PROT_${prot}_RAIL"
        rkey_prot_hw="HOM_VOLTAGE_PROT_${prot}_HW"
        _already_in_registry "$rkey_prot_rail" "$rail" || {
            reg_set "voltage" "$rkey_prot_rail" "$rail" "# written"
            reg_set "voltage" "$rkey_prot_hw"   "$hw"   "# written"
        }
    fi
}

# ── Main PMIC (S2MPG12) — sourced from battery_mitigation RC + power.stats RC
_apply_rail "BUCK1M"  "main" "power"   ""     "ocp_cpu1_lvl"
_apply_rail "BUCK2M"  "main" "power"   ""     "ocp_cpu2_lvl"
_apply_rail "BUCK3M"  "main" "display" ""     "ocp_gpu_lvl"
_apply_rail "BUCK4M"  "main" "system"  ""     ""
_apply_rail "BUCK5M"  "main" "modem"   ""     ""
_apply_rail "BUCK6M"  "main" "tpu"     ""     "ocp_tpu_lvl"
_apply_rail "BUCK7M"  "main" "power"   ""     ""
_apply_rail "BUCK8M"  "main" "power"   ""     ""
_apply_rail "BUCK9M"  "main" "modem"   "CH0"  ""   # VSYS_PWR_MMWAVE on sub6 SKUs
_apply_rail "BUCK10M" "main" "power"   ""     ""

# ── Sub PMIC (S2MPG13) — sourced from battery_mitigation RC + init.zuma RC
_apply_rail "BUCK1S"  "sub"  "power"   ""     ""
_apply_rail "BUCK2S"  "sub"  "power"   ""     ""
_apply_rail "BUCK3S"  "sub"  "display" ""     ""
_apply_rail "BUCK4S"  "sub"  "system"  ""     ""
_apply_rail "BUCK5S"  "sub"  "modem"   ""     ""
_apply_rail "BUCK6S"  "sub"  "tpu"     ""     ""
_apply_rail "BUCK7S"  "sub"  "power"   ""     ""
_apply_rail "BUCK8S"  "sub"  "power"   ""     ""
_apply_rail "BUCK9S"  "sub"  "power"   ""     ""
_apply_rail "BUCK10S" "sub"  "power"   ""     ""
_apply_rail "BUCKDS"  "sub"  "power"   ""     ""
_apply_rail "BUCKBS"  "sub"  "power"   ""     ""
_apply_rail "BUCKCS"  "sub"  "power"   ""     ""
_apply_rail "BUCKAS"  "sub"  "power"   ""     ""
_apply_rail "BUCK12S" "sub"  "display" "CH11" ""  # DSI display supply

# ── Battery protection events (not rail-specific) ─────────────
_apply_prot() {
    local event="$1" hw="$2"
    local rk="HOM_VOLTAGE_PROT_${event}_HW"
    _already_in_registry "$rk" "$hw" && {
        log "  skip (registry) prot $event  # skipped:bare_metal"
        return
    }
    reg_set "voltage" "$rk" "$hw" "# written"
    log "  write prot $event hw=$hw  # written"
}
_apply_prot "batoilo_lvl"      "battery"
_apply_prot "batoilo2_lvl"     "battery"
_apply_prot "uvlo1_lvl"        "battery"
_apply_prot "uvlo2_lvl"        "battery"
_apply_prot "smpl_lvl"         "battery"
_apply_prot "dvfs_rel"         "power"
_apply_prot "soft_ocp_cpu1_lvl" "power"
_apply_prot "soft_ocp_cpu2_lvl" "power"
_apply_prot "soft_ocp_gpu_lvl"  "display"
_apply_prot "soft_ocp_tpu_lvl"  "tpu"

# ── Record cross-group source files ───────────────────────────
# These are the factory-image files that contained voltage data for
# ≥ 2 hw groups — written once so the pipeline can skip re-scanning them.
_mark_scanned() {
    local path="$1" groups="$2"
    local key
    key="HOM_VOLTAGE_SRC_$(echo "$path" | sed 's|[/.]|_|g' | tr '[:lower:]' '[:upper:]')"
    _already_in_registry "$key" "$groups" || {
        reg_set "voltage_src" "$key" "$groups" "# written"
        log "  write cross-group src $path groups=$groups  # written"
    }
}
_mark_scanned \
    "vendor/etc/init/vendor.google.battery_mitigation-default.rc" \
    "battery,power,display,tpu,modem,system"
_mark_scanned \
    "vendor/etc/init/android.hardware.power.stats-service.pixel.rc" \
    "power,modem"
_mark_scanned \
    "vendor/etc/init/hw/init.zuma.rc" \
    "display,battery,system"

# ── Step 4: copy overlay files to $OVERLAY_OUT ────────────────
log "Copying overlay payload files to $OVERLAY_OUT ..."
if cp -r "$OVERLAY_SRC"/. "$OVERLAY_OUT/" 2>/dev/null; then
    log "  Copied overlay payload"
else
    log "  WARNING: could not copy overlay payload"
fi

# ── Done ──────────────────────────────────────────────────────
SKIPPED=$(grep -c "skipped:bare_metal" "$LOG" 2>/dev/null || echo 0)
WRITTEN=$(grep -c "# written"          "$LOG" 2>/dev/null || echo 0)
log "=== apply_overlay.sh complete: $WRITTEN written, $SKIPPED skipped (bare-metal known) ==="
