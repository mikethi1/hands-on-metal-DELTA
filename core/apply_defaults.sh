#!/system/bin/sh
# core/apply_defaults.sh
# ============================================================
# Load device family defaults from partition_index.json and
# write them into env_registry.sh as HOM_DEFAULT_* variables.
#
# These defaults describe the EXPECTED configuration for the
# detected device family.  They are used by:
#   • magisk_patch.sh  — to pick the right Magisk flags
#   • failure_analysis — to detect deviations that caused failures
#   • candidate_entry  — to populate suggested_family
#
# All defaults are written with a "default:" tag so scripts know
# they come from the index rather than from live device detection.
# They can be overridden by editing env_registry.sh before the
# next step runs — this is intentional to support manual correction
# on unknown or unusual devices.
#
# Requires: logging.sh sourced; HOM_DEV_* vars already in registry
#           (i.e., device_profile.sh must have run first).
#
# Usage: sourced by customize.sh after device_profile.sh
# ============================================================

SCRIPT_NAME="${SCRIPT_NAME:-apply_defaults}"

OUT="${OUT:-/sdcard/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
PARTITION_INDEX="${PARTITION_INDEX:-$(dirname "$0")/../build/partition_index.json}"

# ── helpers ───────────────────────────────────────────────────

_reg_get() {
    grep "^${1}=" "$ENV_REGISTRY" 2>/dev/null | \
        cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//'
}

_reg_set_default() {
    local key="$1" val="$2" desc="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    # Only write if not already overridden by a non-default value
    if grep -q "^${key}=" "$ENV_REGISTRY" 2>/dev/null; then
        existing=$(grep "^${key}=" "$ENV_REGISTRY" | head -1)
        # Don't overwrite if it was set without the "default:" tag (i.e., live detected)
        if ! printf '%s' "$existing" | grep -q 'default:'; then
            log_debug "apply_defaults: $key already set (live value) — skipping"
            return
        fi
    fi
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:defaults default:%s\n' "$key" "$val" "$desc" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
    log_var "$key" "$val" "default from partition_index: $desc"
}

# ── JSON value extractor (no jq) ──────────────────────────────
# Extract a simple string or boolean from a flat JSON key within a block.
_json_get() {
    local file="$1" key="$2"
    # Match "key": "value" or "key": true/false/null
    grep -o "\"${key}\":[[:space:]]*[^,}]*" "$file" 2>/dev/null | head -1 | \
        sed 's/.*:[[:space:]]*//' | \
        sed 's/^"//;s/"//' | \
        sed 's/[[:space:]]*$//'
}

# ── family matching ───────────────────────────────────────────
_find_family_block_start() {
    local family="$1" file="$2"
    grep -n "\"${family}\"[[:space:]]*:[[:space:]]*{" "$file" 2>/dev/null | head -1 | cut -d: -f1
}

# Extract value of a key within a named block in partition_index.json
# Uses line-range approach: finds the family block, then searches within it.
_family_key() {
    local family="$1" key="$2"
    [ ! -f "$PARTITION_INDEX" ] && return
    # Extract the device_families section crudely with grep context
    # Works for simple flat values within the family block
    awk "
        /\"${family}\"[[:space:]]*:[[:space:]]*\{/ { in_fam=1 }
        in_fam && /\"${key}\"[[:space:]]*:/ {
            gsub(/.*\"${key}\"[[:space:]]*:[[:space:]]*/,\"\")
            gsub(/[,}].*/,\"\")
            gsub(/\"/,\"\")
            gsub(/[[:space:]]*/,\"\")
            print
            exit
        }
        in_fam && /^\s*\}[[:space:]]*,?[[:space:]]*$/ && depth>0 { in_fam=0 }
    " "$PARTITION_INDEX" 2>/dev/null
}

# ── version check ─────────────────────────────────────────────
_check_index_version() {
    [ ! -f "$PARTITION_INDEX" ] && {
        log_warn "apply_defaults: partition_index.json not found at $PARTITION_INDEX"
        return 1
    }
    local ver
    ver=$(grep '"_version"' "$PARTITION_INDEX" 2>/dev/null | \
          sed 's/.*"_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    log_var "HOM_PARTITION_INDEX_VERSION" "$ver" "bundled partition_index.json schema version"
    log_info "apply_defaults: partition_index version $ver"
}

# ── main function ─────────────────────────────────────────────

run_apply_defaults() {
    ux_section "Apply Family Defaults"
    ux_step_info "Apply Defaults" \
        "Loads known-good defaults for this device family from the compatibility database" \
        "Defaults are written as HOM_DEFAULT_* variables and can be overridden in env_registry.sh"

    _check_index_version || {
        ux_step_result "Apply Defaults" "SKIP" "partition_index.json not available"
        manifest_step "apply_defaults" "SKIP" "index not found"
        return 0
    }

    # Get the matched family (set by candidate_entry.sh)
    local family
    family=$(_reg_get HOM_CANDIDATE_FAMILY_MATCHED)

    if [ -z "$family" ] || [ "$family" = "none" ]; then
        ux_print "  No known device family matched — using API-level defaults only."
        _apply_api_level_defaults
        ux_step_result "Apply Defaults" "OK" "API-level defaults applied (no family match)"
        manifest_step "apply_defaults" "OK" "source=api_level"
        return 0
    fi

    ux_print "  Loading defaults for family: $family"

    # ── partition_model defaults ──────────────────────────────
    local sdk_int
    sdk_int=$(_reg_get HOM_DEV_SDK_INT)

    # Determine patch target based on API level and family default
    local patch_target
    if [ "${sdk_int:-0}" -ge 33 ] 2>/dev/null; then
        # Try init_boot target for API 33+
        patch_target=$(_family_key "$family" "patch_target_api_33_plus")
    fi
    [ -z "$patch_target" ] && patch_target=$(_family_key "$family" "patch_target")
    [ -z "$patch_target" ] && patch_target="boot"

    local has_recovery
    has_recovery=$(_family_key "$family" "has_recovery_partition")
    local has_super
    has_super=$(_family_key "$family" "has_super")

    _reg_set_default "HOM_DEFAULT_PATCH_TARGET"      "$patch_target" "partition to patch (from family defaults)"
    _reg_set_default "HOM_DEFAULT_HAS_RECOVERY"      "${has_recovery:-false}" "recovery partition present"
    _reg_set_default "HOM_DEFAULT_HAS_SUPER"         "${has_super:-false}" "dynamic partitions (super) present"

    # ── AVB behavior defaults ─────────────────────────────────
    local avb_ver avb_verity avb_vbmeta avb_rollback
    avb_ver=$(_family_key "$family" "avb_version")
    avb_verity=$(_family_key "$family" "enforce_verity")
    avb_vbmeta=$(_family_key "$family" "vbmeta_partition")
    avb_rollback=$(_family_key "$family" "rollback_protection")

    _reg_set_default "HOM_DEFAULT_AVB_VERSION"        "${avb_ver:-none}" "expected AVB version for this family"
    _reg_set_default "HOM_DEFAULT_AVB_ENFORCE_VERITY" "${avb_verity:-false}" "dm-verity enforced"
    _reg_set_default "HOM_DEFAULT_AVB_VBMETA"         "${avb_vbmeta:-false}" "vbmeta partition present"
    _reg_set_default "HOM_DEFAULT_AVB_ROLLBACK"       "${avb_rollback:-false}" "rollback protection active"

    # ── Magisk required_flags defaults ────────────────────────
    local kv kfe pvmf lsar
    kv=$(_family_key "$family" "KEEPVERITY")
    kfe=$(_family_key "$family" "KEEPFORCEENCRYPT")
    pvmf=$(_family_key "$family" "PATCHVBMETAFLAG")
    lsar=$(_family_key "$family" "LEGACYSAR")

    # PATCHVBMETAFLAG is "spl_dependent" for most modern families —
    # resolve it now based on the device's actual SPL.
    if [ "$pvmf" = "spl_dependent" ]; then
        local spl
        spl=$(_reg_get HOM_DEV_SPL)
        # Compare SPL to 2026-05-07
        if [ -n "$spl" ] && [ "$spl" \> "2026-05-06" ] 2>/dev/null; then
            pvmf="true"
        else
            pvmf="false"
        fi
    fi

    _reg_set_default "HOM_DEFAULT_KEEPVERITY"       "${kv:-false}"   "KEEPVERITY flag for Magisk patch"
    _reg_set_default "HOM_DEFAULT_KEEPFORCEENCRYPT" "${kfe:-false}"  "KEEPFORCEENCRYPT flag for Magisk patch"
    _reg_set_default "HOM_DEFAULT_PATCHVBMETAFLAG"  "${pvmf:-false}" "PATCHVBMETAFLAG for Magisk patch"
    _reg_set_default "HOM_DEFAULT_LEGACYSAR"        "${lsar:-false}" "LEGACYSAR flag (non-A/B SAR devices)"

    ux_print "  Patch target  : $patch_target"
    ux_print "  KEEPVERITY    : ${kv:-false}   KEEPFORCEENCRYPT: ${kfe:-false}"
    ux_print "  PATCHVBMETA   : ${pvmf:-false}   LEGACYSAR: ${lsar:-false}"

    ux_step_result "Apply Defaults" "OK" "family=$family patch=$patch_target"
    manifest_step "apply_defaults" "OK" "family=$family patch=$patch_target"
}

# ── API-level-only defaults (no family match) ─────────────────
# Falls back to the android_version_profiles in partition_index.json
_apply_api_level_defaults() {
    local sdk_int
    sdk_int=$(_reg_get HOM_DEV_SDK_INT)
    [ -z "$sdk_int" ] && return

    # Determine patch target from API level alone
    local patch_target="boot"
    [ "${sdk_int:-0}" -ge 33 ] 2>/dev/null && patch_target="init_boot"

    local keepverity="false"
    [ "${sdk_int:-0}" -ge 26 ] 2>/dev/null && keepverity="true"

    local keepforceencrypt="false"
    [ "${sdk_int:-0}" -ge 24 ] 2>/dev/null && keepforceencrypt="true"

    local patchvbmetaflag="false"
    local spl
    spl=$(_reg_get HOM_DEV_SPL)
    if [ -n "$spl" ] && [ "$spl" \> "2026-04-30" ] 2>/dev/null; then
        patchvbmetaflag="true"
    fi

    _reg_set_default "HOM_DEFAULT_PATCH_TARGET"      "$patch_target"       "inferred from API level $sdk_int"
    _reg_set_default "HOM_DEFAULT_KEEPVERITY"         "$keepverity"         "inferred from API level $sdk_int"
    _reg_set_default "HOM_DEFAULT_KEEPFORCEENCRYPT"   "$keepforceencrypt"   "inferred from API level $sdk_int"
    _reg_set_default "HOM_DEFAULT_PATCHVBMETAFLAG"    "$patchvbmetaflag"    "inferred from SPL $spl"
    _reg_set_default "HOM_DEFAULT_LEGACYSAR"          "false"               "assumed false for unknown family"
}
