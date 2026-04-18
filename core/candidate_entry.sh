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
#   /sdcard/hands-on-metal/candidates/<brand>_<device>_api<N>_<RUN_ID>.json
# ============================================================

SCRIPT_NAME="${SCRIPT_NAME:-candidate_entry}"

OUT="${OUT:-/sdcard/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
CANDIDATE_DIR="$OUT/candidates"
_HOM_BASE_ROOT="${REPO_ROOT:-${MODPATH:-}}"
if [ -n "$_HOM_BASE_ROOT" ]; then
    PARTITION_INDEX="${PARTITION_INDEX:-$_HOM_BASE_ROOT/build/partition_index.json}"
else
    PARTITION_INDEX="${PARTITION_INDEX:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/build/partition_index.json}"
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
_match_family() {
    local platform soc_mfr
    platform=$(_reg_get HOM_DEV_PLATFORM)
    soc_mfr=$(_reg_get HOM_DEV_SOC_MFR)

    [ ! -f "$PARTITION_INDEX" ] && { echo "none"; return; }

    # Extract soc_match arrays from the JSON using grep/sed (no jq required).
    # Each device_family block has one or more soc_match entries.
    # We look for a prefix match against platform or soc_mfr.
    local family_name=""
    local in_family=""
    local fam=""

    while IFS= read -r line; do
        # Detect family key: "  \"<name>\": {"
        if printf '%s' "$line" | grep -qE '^\s+"[a-z_]+"\s*:\s*\{'; then
            fam=$(printf '%s' "$line" | sed 's/.*"\([a-z_]*\)".*/\1/')
            in_family="$fam"
        fi

        # Detect soc_match values within current family
        if [ -n "$in_family" ] && printf '%s' "$line" | grep -q '"soc_match"'; then
            # Read until closing ]
            : # handled by looking at next lines
        fi

        if [ -n "$in_family" ] && printf '%s' "$line" | grep -qE '"(msm|sm|sdm|qcom|gs|mt|mediatek|exynos|tensor|kirin|hi|unisoc|sc|tegra)"'; then
            local prefix
            prefix=$(printf '%s' "$line" | sed 's/.*"\([a-z]*\)".*/\1/')
            local plat_lower
            plat_lower=$(printf '%s' "$platform" | tr '[:upper:]' '[:lower:]')
            local mfr_lower
            mfr_lower=$(printf '%s' "$soc_mfr" | tr '[:upper:]' '[:lower:]')
            case "$plat_lower" in
                "$prefix"*) family_name="$in_family"; break ;;
            esac
            case "$mfr_lower" in
                "$prefix"*) family_name="$in_family"; break ;;
            esac
        fi
    done < "$PARTITION_INDEX"

    echo "${family_name:-none}"
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
