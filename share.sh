#!/usr/bin/env bash
# share.sh
# ============================================================
# hands-on-metal — Phase 7: Share Bundle + Upload (root entrypoint)
#
# Creates a shareable diagnostic bundle and offers an opt-in
# upload in one step.  The two pipeline options are inlined as
# self-contained code blocks.
#
# ┌─ Code Block A · Create Share Bundle (pipeline option: share)┐
# │  Script: core/share.sh                                     │
# │  Relies on: ENV_REGISTRY (must exist — run detect.sh and   │
# │             collect.sh first), LOG_DIR, RUN_ID             │
# │  Settings : SCRIPT_NAME="share", OUT, ENV_REGISTRY,        │
# │             LOG_DIR, SHARE_DIR, RUN_ID                     │
# │  Builds a local bundle at $OUT/share/<RUN_ID>/ containing: │
# │    share_bundle.json  — local vars + run results (JSON)    │
# │    env_registry.txt   — env_registry snapshot (text)       │
# │    run_manifest.txt   — step-by-step results               │
# │    var_audit.txt      — variable audit log (full values)   │
# │    README.txt         — instructions for manual submission  │
# │  PII redaction is opt-in and handled by upload.py.         │
# │  Writes : SHARE_DIR path (used by Block B)                 │
# └────────────────────────────────────────────────────────────┘
#
# ┌─ Code Block B · Upload (pipeline option: upload) ──────────┐
# │  Script: pipeline/upload.py                                │
# │  Relies on: SHARE_DIR created by Block A                   │
# │  Settings : GITHUB_TOKEN (optional — env var or --token),  │
# │             HOM_FILESERVER_URL (optional)                  │
# │  Behaviour:                                                 │
# │    With GITHUB_TOKEN   → upload to GitHub Gist + print URL │
# │    Without GITHUB_TOKEN→ print local summary only (dry run)│
# │  PII redaction happens here before any upload.             │
# │  Writes : Gist URL to stdout (if token is set)             │
# └────────────────────────────────────────────────────────────┘
#
# Usage:
#   bash share.sh                    # build bundle + offer upload
#   bash share.sh -s SERIAL          # target device serial (ADB scope)
#   bash share.sh --out DIR          # use DIR as the working directory
#   bash share.sh --run-id ID        # tag the bundle with a custom run ID
#   bash share.sh --token TOKEN      # GitHub token for Gist upload
#   bash share.sh --no-upload        # build bundle only (skip Block B)
#   bash share.sh --help
# ============================================================

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── Device scope ──────────────────────────────────────────────
ADB_SERIAL=""
OUT="${OUT:-$HOME/hands-on-metal}"
_RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
_GITHUB_TOKEN="${GITHUB_TOKEN:-}"
_NO_UPLOAD=false

usage() {
    awk 'NR==1 {next} /^[^#]/ {exit} {sub(/^#[ \t]*/, ""); print}' \
        "${BASH_SOURCE[0]}"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s)           ADB_SERIAL="$2"; shift 2 ;;
        -s*)          ADB_SERIAL="${1#-s}"; shift ;;
        --out)        OUT="$2"; shift 2 ;;
        --out=*)      OUT="${1#*=}"; shift ;;
        --run-id)     _RUN_ID="$2"; shift 2 ;;
        --run-id=*)   _RUN_ID="${1#*=}"; shift ;;
        --token)      _GITHUB_TOKEN="$2"; shift 2 ;;
        --token=*)    _GITHUB_TOKEN="${1#*=}"; shift ;;
        --no-upload)  _NO_UPLOAD=true; shift ;;
        -h|--help)    usage ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Run 'bash share.sh --help' for usage." >&2
            exit 2
            ;;
    esac
done

export ADB_SERIAL OUT
export RUN_ID="$_RUN_ID"
[ -n "$_GITHUB_TOKEN" ] && export GITHUB_TOKEN="$_GITHUB_TOKEN"

# ── Dependency check ──────────────────────────────────────────
if [ "${HOM_DEPS_CHECKED:-}" != "1" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/check_deps.sh"
fi

# ── Load env registry ─────────────────────────────────────────
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
export ENV_REGISTRY
if [ -f "$ENV_REGISTRY" ]; then
    # shellcheck source=/dev/null
    source "$ENV_REGISTRY" 2>/dev/null || true
else
    echo "WARNING: env_registry not found at $ENV_REGISTRY" >&2
    echo "  Run detect.sh and collect.sh first for a complete bundle." >&2
fi

# ════════════════════════════════════════════════════════════════
# Code Block A · Create Share Bundle  (core/share.sh)
#   Settings : SCRIPT_NAME="share", OUT, ENV_REGISTRY,
#              LOG_DIR, SHARE_DIR, RUN_ID
#   Relied-on vars (from ENV_REGISTRY):
#              HOM_DEV_MODEL, HOM_DEV_SERIAL, HOM_DEV_CODENAME
#              HOM_PATCHED_IMG_SHA256, HOM_FLASH_STATUS
#              (all HOM_* vars are bundled as-is; redaction
#               happens in Block B / upload.py)
#   Writes   : $OUT/share/$RUN_ID/ bundle files
# ════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Block A · Create Share Bundle"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Block A settings
export SCRIPT_NAME="share"
LOG_DIR="${LOG_DIR:-$OUT/logs}"
SHARE_DIR="$OUT/share/$RUN_ID"
export LOG_DIR SHARE_DIR

mkdir -p "$OUT" "$SHARE_DIR"

echo "  Block A settings:"
echo "    OUT       = $OUT"
echo "    RUN_ID    = $RUN_ID"
echo "    SHARE_DIR = $SHARE_DIR"
echo "    LOG_DIR   = $LOG_DIR"
echo ""

# Source framework required by core/share.sh
# shellcheck source=core/logging.sh
source "$REPO_ROOT/core/logging.sh"
# shellcheck source=core/ux.sh
source "$REPO_ROOT/core/ux.sh"
# shellcheck source=core/privacy.sh
source "$REPO_ROOT/core/privacy.sh" 2>/dev/null || true

# Source share.sh (defines run_share + all helpers)
# shellcheck source=core/share.sh
source "$REPO_ROOT/core/share.sh"

# Execute Block A
run_share

echo ""
echo "  ✓ Block A complete."
echo "    Bundle: $SHARE_DIR"
ls -1 "$SHARE_DIR" 2>/dev/null | sed 's/^/      /'

if [ "$_NO_UPLOAD" = true ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " ✓ Bundle created (--no-upload: upload skipped)."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "To upload later:"
    echo "    python3 pipeline/upload.py --bundle \"$SHARE_DIR\""
    echo "    export GITHUB_TOKEN=<token> && bash share.sh --run-id $RUN_ID"
    exit 0
fi

# ════════════════════════════════════════════════════════════════
# Code Block B · Upload  (pipeline/upload.py)
#   Relies on: SHARE_DIR created by Block A
#   Settings : GITHUB_TOKEN (optional — for Gist upload),
#              HOM_FILESERVER_URL (optional — for file server push)
#   PII redaction is applied by upload.py before any network send.
#   Writes   : Gist URL to stdout (if GITHUB_TOKEN is set)
# ════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Block B · Upload"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Block B settings
UPLOAD_PY="$REPO_ROOT/pipeline/upload.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "  WARNING: python3 not found — upload skipped." >&2
    echo "    Bundle preserved at: $SHARE_DIR" >&2
    exit 0
fi

if [ ! -f "$UPLOAD_PY" ]; then
    echo "  WARNING: pipeline/upload.py not found — upload skipped." >&2
    echo "    Bundle preserved at: $SHARE_DIR" >&2
    exit 0
fi

echo "  Block B settings:"
echo "    SHARE_DIR    = $SHARE_DIR"
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "    GITHUB_TOKEN = #### (set — will upload to Gist)"
else
    echo "    GITHUB_TOKEN = (not set — local summary only)"
fi
if [ -n "${HOM_FILESERVER_URL:-}" ]; then
    echo "    FILESERVER   = ${HOM_FILESERVER_URL}"
fi
echo ""

if [ -n "${GITHUB_TOKEN:-}" ]; then
    python3 "$UPLOAD_PY" --bundle "$SHARE_DIR" --token "$GITHUB_TOKEN"
else
    python3 "$UPLOAD_PY" --bundle "$SHARE_DIR"
    echo ""
    echo "  NOTE: no GITHUB_TOKEN set — local summary only."
    echo "  To upload: export GITHUB_TOKEN=<token> && bash share.sh --run-id $RUN_ID"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✓ Share complete."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Bundle: $SHARE_DIR"
