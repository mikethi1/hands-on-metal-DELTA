#!/system/bin/sh
# core/share.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Write a local shareable bundle of hardware/install variables
# to ~/hands-on-metal/share/<RUN_ID>/.
#
# This is the DEFAULT sharing mode — no network, no GitHub token,
# no authentication required.  Works straight from the repo.
#
# The bundle remains local by default and preserves full values.
# Upload-time redaction/prompt is handled by pipeline/upload.py.
#
# Contents:
#   share_bundle.json   — local vars + run results (JSON)
#   env_registry.txt    — local env_registry snapshot (text)
#   run_manifest.txt    — step-by-step results
#   var_audit.txt       — variable audit log (local full values)
#   README.txt          — instructions for manual submission
#
# Opt-in authenticated upload:
#   python pipeline/upload.py --logs <share_dir> --token "$GITHUB_TOKEN"
#   python pipeline/github_notify.py --repo owner/repo --analysis analysis.json
#
# Requires: logging.sh, privacy.sh sourced.
# ============================================================

SCRIPT_NAME="${SCRIPT_NAME:-share}"

OUT="${OUT:-$HOME/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
LOG_DIR="${LOG_DIR:-$OUT/logs}"
SHARE_DIR="$OUT/share/${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

# ── helpers ───────────────────────────────────────────────────

_reg_get() {
    grep "^${1}=" "$ENV_REGISTRY" 2>/dev/null | \
        cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//'
}

_json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'
}

# ── build the share bundle ─────────────────────────────────────

run_share() {
    ux_section "Share Bundle"
    ux_step_info "Share" \
        "Writes a local diagnostic bundle to share/ for review/submission" \
        "No network access required. Upload flow prompts before any send."

    mkdir -p "$SHARE_DIR"

    # ── 1. Local env_registry snapshot ────────────────────────
    local env_out="$SHARE_DIR/env_registry.txt"
    printf '# hands-on-metal env_registry — LOCAL (not upload-redacted)\n' > "$env_out"
    printf '# RUN_ID: %s\n' "$RUN_ID" >> "$env_out"
    printf '# Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$env_out"

    while IFS= read -r line; do
        # Parse key="value"  # cat:xxx lines
        case "$line" in
            \#*|'') printf '%s\n' "$line" >> "$env_out"; continue ;;
        esac
        local key val rest
        key=$(printf '%s' "$line" | cut -d= -f1)
        val=$(printf '%s' "$line" | cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//')
        rest=$(printf '%s' "$line" | grep -o '#.*' || true)
        printf '%s="%s"  %s\n' "$key" "$val" "$rest" >> "$env_out"
    done < "$ENV_REGISTRY"

    # ── 2. Copy run_manifest ──────────────────────────────────
    local manifest_src="$LOG_DIR/run_manifest_${RUN_ID}.txt"
    if [ -f "$manifest_src" ]; then
        cp "$manifest_src" "$SHARE_DIR/run_manifest.txt"
    fi

    # ── 3. Local var_audit copy ───────────────────────────────
    local audit_src="$LOG_DIR/var_audit_${RUN_ID}.txt"
    local audit_out="$SHARE_DIR/var_audit.txt"
    if [ -f "$audit_src" ]; then
        cp "$audit_src" "$audit_out"
    fi

    # ── 4. Build share_bundle.json ────────────────────────────
    local bundle_out="$SHARE_DIR/share_bundle.json"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Collect all vars from registry into JSON (local full copy)
    {
        printf '{\n'
        printf '  "schema_version": "1.0",\n'
        printf '  "run_id": "%s",\n' "$(_json_str "${RUN_ID:-}")"
        printf '  "generated_at": "%s",\n' "$ts"
        printf '  "pii_redacted": false,\n'
        printf '  "sharing_mode": "local_full",\n'
        printf '  "variables": {\n'
    } > "$bundle_out"

    local first_var=1
    while IFS= read -r line; do
        case "$line" in \#*|'') continue ;; esac
        local key val
        key=$(printf '%s' "$line" | cut -d= -f1)
        val=$(printf '%s' "$line" | cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//')
        [ -z "$key" ] && continue
        if [ "$first_var" -eq 1 ]; then
            first_var=0
        else
            printf ',\n' >> "$bundle_out"
        fi
        printf '    "%s": "%s"' "$(_json_str "$key")" "$(_json_str "$val")" >> "$bundle_out"
    done < "$ENV_REGISTRY"

    printf '\n  },\n' >> "$bundle_out"

    # Step results
    printf '  "steps": [\n' >> "$bundle_out"
    local first_step=1
    if [ -f "$manifest_src" ]; then
        while IFS='|' read -r mts mstep mstatus mnote; do
            [ -z "$mstep" ] && continue
            if [ "$first_step" -eq 1 ]; then first_step=0; else printf ',\n' >> "$bundle_out"; fi
            printf '    {"ts":"%s","step":"%s","status":"%s","note":"%s"}' \
                "$(_json_str "$mts")" "$(_json_str "$mstep")" \
                "$(_json_str "$mstatus")" "$(_json_str "$mnote")" >> "$bundle_out"
        done < "$manifest_src"
    fi
    {
        printf '\n  ]\n'
        printf '}\n'
    } >> "$bundle_out"

    # ── 5. Write README ───────────────────────────────────────
    cat > "$SHARE_DIR/README.txt" << READMEEOF
hands-on-metal diagnostic bundle
=================================
Run ID  : ${RUN_ID:-unknown}
Created : $ts
Mode    : local only (no authentication, no network)
PII     : local full data (redaction is applied only if you upload)

Contents
--------
  share_bundle.json  — machine-readable bundle of local variables and step results
  env_registry.txt   — environment registry snapshot (local full values)
  run_manifest.txt   — step-by-step install results
  var_audit.txt      — variable audit log (local full values)

How to share
------------
Keep this folder local by default. To send to GitHub, use upload.py and confirm:
  python pipeline/upload.py --bundle $SHARE_DIR --token "\$GITHUB_TOKEN"

Or use the pipeline to parse and analyze locally:
  python pipeline/parse_logs.py --log $OUT/logs/ --out ~/tmp/parsed.json
  python pipeline/failure_analysis.py --parsed ~/tmp/parsed.json --out ~/tmp/analysis.json

Authenticated upload (opt-in):
  export GITHUB_TOKEN=ghp_...
  python pipeline/upload.py --bundle $SHARE_DIR --token "\$GITHUB_TOKEN"
  python pipeline/github_notify.py --repo mikethi/hands-on-metal \\
      --analysis ~/tmp/analysis.json --run-id ${RUN_ID:-unknown}

Your data
---------
This local bundle may contain personal identifiers.
If you choose to upload via pipeline/upload.py, the script prompts first
and applies redaction to public repo uploads.

What IS included: device model and brand, Android version, API level,
partition layout, AVB state, install step results, Magisk version,
SoC family, and all diagnostic variables needed to reproduce the issue.
READMEEOF

    log_var "HOM_SHARE_DIR" "$SHARE_DIR" "local share bundle directory"
    log_info "Share bundle written to: $SHARE_DIR"

    ux_print "  Share bundle : $SHARE_DIR"
    ux_print "  Contents:"
    ux_print "    share_bundle.json  var_audit.txt  run_manifest.txt"
    ux_print "  Bundle stays local by default."
    ux_print "  upload.py prompts before sending to GitHub."
    ux_print "  See README.txt in the share folder for full instructions."
    ux_print ""
    ux_print "  Authenticated upload (opt-in):"
    ux_print "    export GITHUB_TOKEN=ghp_..."
    ux_print "    python pipeline/upload.py --bundle $SHARE_DIR --token \"\$GITHUB_TOKEN\""

    ux_step_result "Share" "OK" "bundle at $SHARE_DIR"
    manifest_step "share" "OK" "dir=$SHARE_DIR"
}
