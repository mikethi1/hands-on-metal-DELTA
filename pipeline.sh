#!/usr/bin/env bash
# pipeline.sh
# ============================================================
# hands-on-metal — Complete Host-Side Pipeline Workflow (root entrypoint)
#
# After the device has booted with the patched image and finished
# collecting hardware data into /sdcard/hands-on-metal/, this
# script pulls the artefacts back to the host and runs the
# Python pipeline end-to-end:
#
#   1. adb pull /sdcard/hands-on-metal/logs/      → ./logs/
#   2. adb pull /sdcard/hands-on-metal/live_dump/ → ./live_dump/
#   3. python pipeline/parse_logs.py --log ./logs --out ./parsed.json
#
# (Optional) When --mode A|B|C is supplied, also runs:
#   4. python pipeline/build_table.py --db hardware_map.sqlite \
#         --dump ./live_dump --mode <MODE>
#
# Usage:
#   bash pipeline.sh                  # pull + parse_logs only
#   bash pipeline.sh --mode A         # also build the SQLite table
#   bash pipeline.sh --skip-pull      # use existing local logs/ + live_dump/
#   bash pipeline.sh --audit          # also run pipeline/audit_coverage.py
#   bash pipeline.sh -s SERIAL        # target a specific adb device
#   bash pipeline.sh --help
#
# Re-runnable: existing local files are overwritten by adb pull.
# ============================================================

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── argument parsing ──────────────────────────────────────────
MODE=""
SKIP_PULL=false
ADB_SERIAL=""
RUN_AUDIT=false

usage() {
    # Print the header comment block (everything from line 2 until the
    # first non-comment line).
    awk 'NR==1 {next} /^[^#]/ {exit} {sub(/^#[ \t]*/, ""); print}' "${BASH_SOURCE[0]}"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)        MODE="$2"; shift 2 ;;
        --mode=*)      MODE="${1#*=}"; shift ;;
        --skip-pull)   SKIP_PULL=true; shift ;;
        --audit)       RUN_AUDIT=true; shift ;;
        -s)            ADB_SERIAL="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Run 'bash pipeline.sh --help' for usage." >&2
            exit 2
            ;;
    esac
done

case "$MODE" in
    ""|A|B|C) ;;
    *) echo "ERROR: --mode must be A, B, or C (got: $MODE)" >&2; exit 2 ;;
esac

ADB=(adb)
if [ -n "$ADB_SERIAL" ]; then
    ADB=(adb -s "$ADB_SERIAL")
fi

# ── dependency check ──────────────────────────────────────────
if [ "${HOM_DEPS_CHECKED:-}" != "1" ]; then
    # shellcheck disable=SC1091
    source check_deps.sh
fi

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    PYTHON=python
fi
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "ERROR: python3 (or python) not found in PATH." >&2
    exit 1
fi

# ── 1 & 2: pull artefacts from device ─────────────────────────
if [ "$SKIP_PULL" = false ]; then
    if ! command -v adb >/dev/null 2>&1; then
        echo "ERROR: adb is required to pull logs from the device." >&2
        echo "       Install Android Platform Tools, or re-run with --skip-pull" >&2
        echo "       to use existing local ./logs/ and ./live_dump/ directories." >&2
        exit 1
    fi

    echo "→ Pulling logs from device..."
    mkdir -p logs live_dump
    "${ADB[@]}" pull /sdcard/hands-on-metal/logs/      ./logs/      || {
        echo "ERROR: adb pull of /sdcard/hands-on-metal/logs/ failed." >&2
        echo "       Is the device connected and authorised?" >&2
        exit 1
    }
    "${ADB[@]}" pull /sdcard/hands-on-metal/live_dump/ ./live_dump/ || {
        echo "  ⚠  Could not pull live_dump/ (it may not exist yet — collection may still be running)."
    }
else
    echo "→ Skipping adb pull (using existing ./logs/ and ./live_dump/)."
fi

if [ ! -d ./logs ] || [ -z "$(ls -A ./logs 2>/dev/null)" ]; then
    echo "ERROR: no logs found in $REPO_ROOT/logs/." >&2
    echo "       Either let the device finish collecting and re-run," >&2
    echo "       or pre-populate ./logs/ and re-run with --skip-pull." >&2
    exit 1
fi

# ── 3: parse_logs ─────────────────────────────────────────────
echo "→ Parsing logs..."
"$PYTHON" pipeline/parse_logs.py --log ./logs --out ./parsed.json
echo "  ✓ Wrote $REPO_ROOT/parsed.json"

# ── 4 (optional): build_table ─────────────────────────────────
if [ -n "$MODE" ]; then
    if [ ! -d ./live_dump ] || [ -z "$(ls -A ./live_dump 2>/dev/null)" ]; then
        echo "ERROR: --mode $MODE was requested but ./live_dump/ is empty." >&2
        echo "       build_table.py needs the collected dump directory." >&2
        exit 1
    fi
    echo "→ Building hardware_map.sqlite (mode $MODE)..."
    "$PYTHON" pipeline/build_table.py \
        --db hardware_map.sqlite \
        --dump ./live_dump \
        --mode "$MODE"
    echo "  ✓ Wrote $REPO_ROOT/hardware_map.sqlite"
fi

# ── 5 (optional): coverage audit ──────────────────────────────
if [ "$RUN_AUDIT" = true ]; then
    echo "→ Running coverage audit (pipeline/audit_coverage.py)..."
    audit_args=(--static --out coverage_audit.md)
    if [ -d ./live_dump ] && [ -n "$(ls -A ./live_dump 2>/dev/null)" ]; then
        audit_args+=(--dump ./live_dump)
    fi
    "$PYTHON" pipeline/audit_coverage.py "${audit_args[@]}"
    echo "  ✓ Wrote $REPO_ROOT/coverage_audit.md"
fi

echo ""
echo "✓ Pipeline complete."
if [ -z "$MODE" ]; then
    echo ""
    echo "Next step — build the SQLite hardware map (pick the install mode you used):"
    echo "    bash pipeline.sh --mode A   # Magisk module path"
    echo "    bash pipeline.sh --mode B   # recovery ZIP path"
    echo "    bash pipeline.sh --mode C   # ADB/fastboot path"
fi
