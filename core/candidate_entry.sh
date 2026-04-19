#!/system/bin/sh
# core/candidate_entry.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Auto-create a candidate device/version entry when the current
# device is not found in the partition_index.json database.
#
# Workflow:
#   1. Read all HOM_DEV_* variables from the env registry.
#   2. Match against device_families in partition_index.json.
#   3. If no match found → create a JSON candidate file.
#   4. Log the discovery so maintainers can review it.
#   5. Optionally queue a GitHub issue (if GITHUB_TOKEN is set).
#
# Requires: logging.sh, ux.sh, privacy.sh sourced first.
#
# Outputs:
#   ~/hands-on-metal/candidates/<brand>_<device>_api<N>_<RUN_ID>.json
# ============================================================

SCRIPT_NAME="${SCRIPT_NAME:-candidate_entry}"

OUT="${OUT:-$HOME/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
CANDIDATE_DIR="$OUT/candidates"
_HOM_RESOLVED_ROOT="${REPO_ROOT:-${MODPATH:-}}"
if [ -n "$_HOM_RESOLVED_ROOT" ]; then
    PARTITION_INDEX="${PARTITION_INDEX:-$_HOM_RESOLVED_ROOT/build/partition_index.json}"
else
    case "$0" in
        */*) _HOM_SCRIPT_RESOLVED_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" ;;
        *)   _HOM_SCRIPT_RESOLVED_ROOT="${PWD:-.}" ;;
    esac
    PARTITION_INDEX="${PARTITION_INDEX:-$_HOM_SCRIPT_RESOLVED_ROOT/build/partition_index.json}"
fi

# ── helpers ───────────────────────────────────────────────────

_reg_get() {
    grep "^${1}=" "$ENV_REGISTRY" 2>/dev/null | \
        cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//'
}

_reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

_json_str() {
    # Escape stdin for JSON output. Reads from stdin so callers can pipe in,
    # e.g.  printf '%s' "$x" | _json_str
    sed 's/\\/\\\\/g;s/"/\\"/g;s/	/\\t/g'
}

# ── family matching ───────────────────────────────────────────
# Returns the name of the matching device_family, or "none".
# Prefers a family whose is_ab field matches the device's A/B status.
_match_family() {
    local platform soc_mfr soc_model hardware is_ab
    platform=$(_reg_get HOM_DEV_PLATFORM)
    soc_mfr=$(_reg_get HOM_DEV_SOC_MFR)
    soc_model=$(_reg_get HOM_DEV_SOC_MODEL)
    hardware=$(_reg_get HOM_DEV_HARDWARE)
    is_ab=$(_reg_get HOM_DEV_IS_AB)

    [ ! -f "$PARTITION_INDEX" ] && { echo "none"; return; }

    # Lower-case all device identifiers once for comparison.
    local plat_lower mfr_lower model_lower hw_lower
    plat_lower=$(printf '%s' "$platform"  | tr '[:upper:]' '[:lower:]')
    mfr_lower=$(printf '%s'  "$soc_mfr"   | tr '[:upper:]' '[:lower:]')
    model_lower=$(printf '%s' "$soc_model" | tr '[:upper:]' '[:lower:]')
    hw_lower=$(printf '%s'   "$hardware"  | tr '[:upper:]' '[:lower:]')

    # Parse the partition_index.json line-by-line (no jq required).
    # Strategy:
    #   • Track which device_family block we are currently in.
    #   • Track whether we are inside a soc_match array.
    #   • Track the family's is_ab value for A/B disambiguation.
    #   • Prefer an is_ab-exact match; fall back to any soc match.
    local in_family="" fam_is_ab="" in_soc_match=0 soc_hit=0
    local exact_match="" partial_match=""

    while IFS= read -r line; do

        # ── New family block detected ───────────────────────────
        if printf '%s' "$line" | grep -qE '^\s+"[a-z_]+"\s*:\s*\{'; then
            # Flush the previous family if it had a soc match.
            if [ "$soc_hit" -eq 1 ] && [ -n "$in_family" ]; then
                if [ -z "$exact_match" ] && [ "$fam_is_ab" = "$is_ab" ]; then
                    exact_match="$in_family"
                elif [ -z "$partial_match" ]; then
                    partial_match="$in_family"
                fi
            fi
            in_family=$(printf '%s' "$line" | sed 's/.*"\([a-z_]*\)".*/\1/')
            in_soc_match=0
            fam_is_ab=""
            soc_hit=0
        fi

        # ── Read is_ab for the current family ──────────────────
        if [ -n "$in_family" ] && [ "$in_soc_match" -eq 0 ] && \
           printf '%s' "$line" | grep -qE '"is_ab"\s*:\s*(true|false)'; then
            fam_is_ab=$(printf '%s' "$line" | grep -oE 'true|false' | head -1)
        fi

        # ── Track soc_match array boundaries ───────────────────
        if [ -n "$in_family" ] && printf '%s' "$line" | grep -q '"soc_match"'; then
            in_soc_match=1
        fi
        if [ "$in_soc_match" -eq 1 ] && printf '%s' "$line" | grep -qE '^\s*\]'; then
            in_soc_match=0
        fi

        # ── Compare soc_match prefix against device identifiers ─
        # Use [a-z0-9_]* so that prefixes like "gs101" or "mt6" are
        # captured correctly (the original [a-z]* dropped the digits).
        if [ "$in_soc_match" -eq 1 ] && [ "$soc_hit" -eq 0 ] && \
           printf '%s' "$line" | grep -qE '^\s*"[a-z0-9]'; then
            local prefix
            prefix=$(printf '%s' "$line" | sed 's/.*"\([a-z0-9_]*\)".*/\1/')
            [ -n "$prefix" ] || continue
            case "$plat_lower"  in "$prefix"*) soc_hit=1 ;; esac
            [ "$soc_hit" -eq 0 ] && case "$mfr_lower"   in "$prefix"*) soc_hit=1 ;; esac
            [ "$soc_hit" -eq 0 ] && case "$model_lower" in "$prefix"*) soc_hit=1 ;; esac
            [ "$soc_hit" -eq 0 ] && case "$hw_lower"    in "$prefix"*) soc_hit=1 ;; esac
        fi

    done < "$PARTITION_INDEX"

    # Flush the last family.
    if [ "$soc_hit" -eq 1 ] && [ -n "$in_family" ]; then
        if [ -z "$exact_match" ] && [ "$fam_is_ab" = "$is_ab" ]; then
            exact_match="$in_family"
        elif [ -z "$partial_match" ]; then
            partial_match="$in_family"
        fi
    fi

    echo "${exact_match:-${partial_match:-none}}"
}

# ── main function ─────────────────────────────────────────────

run_candidate_entry() {
    ux_section "Device Compatibility Check"
    ux_step_info "Candidate Entry" \
        "Checks if this device/Android combination is in the known database" \
        "Unknown devices are recorded for maintainer review and future support"

    # ── 1. Read device profile ────────────────────────────────

    local brand model device codename fingerprint
    local api spl first_api android_ver
    local is_ab slot dyn_parts treble vndk
    local avb_ver avb_state boot_part boot_dev init_boot_dev vendor_boot_dev
    local soc_mfr soc_model platform hardware

    brand=$(_reg_get HOM_DEV_BRAND)
    model=$(_reg_get HOM_DEV_MODEL)
    device=$(_reg_get HOM_DEV_DEVICE)
    codename=$(_reg_get HOM_DEV_CODENAME)
    fingerprint=$(_reg_get HOM_DEV_FINGERPRINT)
    api=$(_reg_get HOM_DEV_SDK_INT)
    first_api=$(_reg_get HOM_DEV_FIRST_API_LEVEL)
    spl=$(_reg_get HOM_DEV_SPL)
    android_ver=$(_reg_get HOM_DEV_ANDROID_VER)
    is_ab=$(_reg_get HOM_DEV_IS_AB)
    slot=$(_reg_get HOM_DEV_SLOT_SUFFIX)
    dyn_parts=$(_reg_get HOM_DEV_DYNAMIC_PARTITIONS)
    treble=$(_reg_get HOM_DEV_TREBLE_ENABLED)
    vndk=$(_reg_get HOM_DEV_TREBLE_VINTF_VER)
    avb_ver=$(_reg_get HOM_DEV_AVB_VERSION)
    avb_state=$(_reg_get HOM_DEV_AVB_STATE)
    boot_part=$(_reg_get HOM_DEV_BOOT_PART)
    boot_dev=$(_reg_get HOM_DEV_BOOT_DEV)
    init_boot_dev=$(_reg_get HOM_DEV_INIT_BOOT_DEV)
    vendor_boot_dev=$(_reg_get HOM_DEV_VENDOR_BOOT_DEV)
    soc_mfr=$(_reg_get HOM_DEV_SOC_MFR)
    soc_model=$(_reg_get HOM_DEV_SOC_MODEL)
    platform=$(_reg_get HOM_DEV_PLATFORM)
    hardware=$(_reg_get HOM_DEV_HARDWARE)

    # ── 2. Check family match ─────────────────────────────────

    ux_print "  Matching device against partition_index..."
    ux_print "    platform  : ${platform:-(not set — run device_profile first)}"
    ux_print "    soc_mfr   : ${soc_mfr:-(not set)}"
    ux_print "    soc_model : ${soc_model:-(not set)}"
    ux_print "    hardware  : ${hardware:-(not set)}"
    ux_print "    is_ab     : ${is_ab:-(not set)}"

    local matched_family
    matched_family=$(_match_family)

    log_var "HOM_CANDIDATE_FAMILY_MATCHED" "$matched_family" \
        "device_family entry matched in partition_index.json (none = unknown)"

    # Persist to env_registry so apply_defaults.sh can read it
    _reg_set candidate HOM_CANDIDATE_FAMILY_MATCHED "$matched_family"

    if [ "$matched_family" != "none" ]; then
        ux_print "  Device family matched: $matched_family"
        ux_step_result "Candidate Entry" "OK" "known device family: $matched_family"
        manifest_step "candidate_entry" "OK" "family=$matched_family"
        return 0
    fi

    # ── 3. Unknown device — create candidate record ───────────

    ux_print "  Device not found in compatibility database."
    ux_print "  Continuing with best-effort heuristics."
    ux_print "  Creating candidate entry for maintainer review..."

    mkdir -p "$CANDIDATE_DIR"

    # Sanitize brand/device for filename
    local safe_brand safe_device
    safe_brand=$(printf '%s' "${brand:-unknown}" | tr 'A-Z ' 'a-z_' | tr -cd 'a-z0-9_')
    safe_device=$(printf '%s' "${device:-unknown}" | tr 'A-Z ' 'a-z_' | tr -cd 'a-z0-9_')
    local api_str="${api:-0}"
    local candidate_file="$CANDIDATE_DIR/${safe_brand}_${safe_device}_api${api_str}_${RUN_ID}.json"

    # Apply privacy redaction to fingerprint
    local safe_fingerprint
    safe_fingerprint=$(hom_redact_value "HOM_DEV_FINGERPRINT" "$fingerprint")

    # Write JSON candidate record
    cat > "$candidate_file" << EOF
{
  "schema_version": "1.0",
  "run_id": "$(printf '%s' "$RUN_ID" | _json_str)",
  "submitted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo UNKNOWN)",
  "device": {
    "brand": "$(printf '%s' "$brand" | _json_str)",
    "model": "$(printf '%s' "$model" | _json_str)",
    "device": "$(printf '%s' "$device" | _json_str)",
    "codename": "$(printf '%s' "$codename" | _json_str)",
    "fingerprint": "$(printf '%s' "$safe_fingerprint" | _json_str)",
    "android_version": "$(printf '%s' "$android_ver" | _json_str)",
    "api_level": $api_str,
    "first_api_level": ${first_api:-0},
    "spl": "$(printf '%s' "$spl" | _json_str)",
    "soc_manufacturer": "$(printf '%s' "$soc_mfr" | _json_str)",
    "soc_model": "$(printf '%s' "$soc_model" | _json_str)",
    "platform": "$(printf '%s' "$platform" | _json_str)",
    "hardware": "$(printf '%s' "$hardware" | _json_str)",
    "is_ab": ${is_ab:-false},
    "slot_suffix": "$(printf '%s' "$slot" | _json_str)",
    "dynamic_partitions": ${dyn_parts:-false},
    "treble_enabled": ${treble:-false},
    "vndk_version": "$(printf '%s' "$vndk" | _json_str)",
    "avb_version": "$(printf '%s' "$avb_ver" | _json_str)",
    "avb_state": "$(printf '%s' "$avb_state" | _json_str)",
    "boot_partition": "$(printf '%s' "$boot_part" | _json_str)",
    "boot_dev": "$(printf '%s' "$boot_dev" | _json_str)",
    "init_boot_dev": "$(printf '%s' "$init_boot_dev" | _json_str)",
    "vendor_boot_dev": "$(printf '%s' "$vendor_boot_dev" | _json_str)"
  },
  "partition_index_family_matched": "none",
  "install_result": "PENDING",
  "failure_step": "",
  "failure_message": "",
  "suggested_family": "",
  "privacy_redacted": true,
  "notes": "auto-generated candidate — needs maintainer review"
}
EOF

    log_var "HOM_CANDIDATE_FILE" "$candidate_file" "candidate entry written for unknown device"
    log_info "Candidate entry created: $candidate_file"

    ux_print "  Candidate file: $candidate_file"
    ux_print "  Please submit this to the project via a GitHub issue."
    ux_print "  See: https://github.com/mikethi/hands-on-metal/issues/new?template=new_device.yml"

    ux_step_result "Candidate Entry" "OK" "unknown device — candidate created"
    manifest_step "candidate_entry" "OK" \
        "family=none candidate=$candidate_file"
}

# Update the candidate record with install result (call after flash step)
update_candidate_result() {
    local result="$1"    # OK | FAIL | PARTIAL
    local step="${2:-}"
    local message="${3:-}"

    # Find the most recent candidate file for this RUN_ID
    local cfile
    # shellcheck disable=SC2012  # ls -t for newest is simpler than find here; controlled paths
    cfile=$(ls -t "$CANDIDATE_DIR"/*_"${RUN_ID}".json 2>/dev/null | head -1)
    [ -f "$cfile" ] || return 0

    # Simple in-place replacement without jq
    local tmp="${cfile}.tmp"
    sed "s/\"install_result\": \"PENDING\"/\"install_result\": \"${result}\"/" \
        "$cfile" > "$tmp" 2>/dev/null || return 0
    if [ -n "$step" ]; then
        sed -i "s/\"failure_step\": \"\"/\"failure_step\": \"$(printf '%s' "$step" | _json_str)\"/" \
            "$tmp" 2>/dev/null || true
    fi
    if [ -n "$message" ]; then
        sed -i "s/\"failure_message\": \"\"/\"failure_message\": \"$(printf '%s' "$message" | _json_str)\"/" \
            "$tmp" 2>/dev/null || true
    fi
    mv "$tmp" "$cfile"
    log_info "Candidate record updated: result=$result step=$step"
}
