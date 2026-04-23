#!/system/bin/sh
# core/privacy.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Privacy-by-default redaction for hands-on-metal.
#
# By default (HOM_PRIVACY_REDACT=true), any variable value
# that matches a known PII pattern is replaced with '#' before
# it is written to logs or uploaded.
#
# The replacement character '#' is used per the project spec.
#
# Public API:
#   hom_redact_value  VARNAME VALUE   → prints safe value to stdout
#   hom_is_pii_name   VARNAME        → returns 0 if name is PII-sensitive
#   hom_is_pii_value  VALUE          → returns 0 if value looks like PII
#
# Usage in logging.sh:
#   safe_val=$(hom_redact_value "$name" "$value")
#   # use safe_val instead of $value in log output
#
# Configuration (read from env registry or environment):
#   HOM_PRIVACY_REDACT       (default: true)
#   HOM_PRIVACY_OPT_IN_FULL  (default: false) — set to true to disable redaction
# ============================================================

# ── PII-sensitive variable name patterns ─────────────────────
# Variables whose names match any of these patterns are always
# treated as PII regardless of value content.
_HOM_PII_NAME_PATTERNS="
IMEI
IMSI
MEID
MSISDN
ICCID
SIM_ID
SIM_SERIAL
PHONE_NUMBER
PHONE_NUM
SUBSCRIBER
OWNER_NAME
OWNER_EMAIL
ACCOUNT_NAME
ACCOUNT_ID
USER_NAME
WIFI_SSID
WIFI_PSK
WIFI_PASSWORD
BLUETOOTH_NAME
BT_NAME
GPS_LATITUDE
GPS_LONGITUDE
GPS_COORDS
LOCATION
EMAIL
FINGERPRINT
BUILD_FINGERPRINT
SERIAL_NUMBER
HW_SERIAL
HARDWARE_SERIAL
DEVICE_SERIAL
WLAN_MAC
WIFI_MAC
BT_MAC
BLUETOOTH_MAC
ETH_MAC
MAC_ADDR
MAC_ADDRESS
"
# HOM_DEV_FINGERPRINT is included via FINGERPRINT match.
# Build fingerprints contain device serial info on some OEMs.
# All MAC address fields uniquely identify hardware — always redacted.

# ── PII value heuristics ──────────────────────────────────────
# Returns 0 (true) if the value looks like PII.
# Patterns are POSIX ERE compatible (used with grep -E).
_HOM_PII_VALUE_PATTERNS="
^[0-9]{15}$
^[0-9]{14}$
^[0-9A-Fa-f]{14}$
^[0-9]{19,20}$
^[0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}$
^(\+[0-9]{1,3})?[ .-]?[0-9]{3}[ .-][0-9]{3}[ .-][0-9]{4}$
^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$
^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$
^[0-9A-Fa-f]{12}$
"
# Patterns cover: IMEI/IMSI (15 digits), MEID (14 hex), ICCID (19-20 digits),
# US/intl phone numbers, email addresses,
# colon/dash-separated MAC addresses (xx:xx:xx:xx:xx:xx),
# and compact 12-char hex MACs.

# ── Redaction sentinel ────────────────────────────────────────
_HOM_REDACTED="#"

# ── internal: check if value matches any PII value pattern ────
_hom_value_looks_like_pii() {
    local val="$1"
    [ -z "$val" ] && return 1
    local pat
    for pat in $_HOM_PII_VALUE_PATTERNS; do
        if printf '%s' "$val" | grep -qE "$pat" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ── public: check if variable NAME is PII-sensitive ──────────
# Returns 0 if the name matches a PII pattern, 1 otherwise.
hom_is_pii_name() {
    local name
    name=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    local pat
    for pat in $_HOM_PII_NAME_PATTERNS; do
        [ -z "$pat" ] && continue
        case "$name" in
            *"$pat"*) return 0 ;;
        esac
    done
    return 1
}

# ── public: check if VALUE looks like PII ────────────────────
# Returns 0 if the value looks like PII, 1 otherwise.
hom_is_pii_value() {
    _hom_value_looks_like_pii "$1"
}

# ── public: redact a value if needed ─────────────────────────
# Usage: safe_val=$(hom_redact_value VARNAME VALUE)
# Prints the safe value to stdout.
# If redaction is disabled (HOM_PRIVACY_OPT_IN_FULL=true), prints value as-is.
hom_redact_value() {
    local name="$1"
    local value="$2"

    # Opt-in to full (unredacted) mode skips all redaction.
    if [ "${HOM_PRIVACY_OPT_IN_FULL:-false}" = "true" ]; then
        printf '%s' "$value"
        return 0
    fi

    # Default: redaction enabled unless explicitly disabled.
    if [ "${HOM_PRIVACY_REDACT:-true}" = "false" ]; then
        printf '%s' "$value"
        return 0
    fi

    # Check name-based PII
    if hom_is_pii_name "$name"; then
        printf '%s' "$_HOM_REDACTED"
        return 0
    fi

    # Check value-based PII (only for non-empty values)
    if [ -n "$value" ] && _hom_value_looks_like_pii "$value"; then
        printf '%s' "$_HOM_REDACTED"
        return 0
    fi

    # Not PII — return as-is
    printf '%s' "$value"
}

# ── Ensure registry defaults are set ─────────────────────────
# These are written to the env registry so downstream tools see them.
if [ -n "${ENV_REGISTRY:-}" ] && [ -f "${ENV_REGISTRY:-}" ]; then
    # Only write if not already set
    if ! grep -q "^HOM_PRIVACY_REDACT=" "$ENV_REGISTRY" 2>/dev/null; then
        printf 'HOM_PRIVACY_REDACT="true"  # cat:privacy\n' >> "$ENV_REGISTRY" 2>/dev/null || true
    fi
    if ! grep -q "^HOM_PRIVACY_OPT_IN_FULL=" "$ENV_REGISTRY" 2>/dev/null; then
        printf 'HOM_PRIVACY_OPT_IN_FULL="false"  # cat:privacy\n' >> "$ENV_REGISTRY" 2>/dev/null || true
    fi
fi
