#!/usr/bin/env python3
"""
pipeline/parse_logs.py
======================
Parse hands-on-metal install logs into structured JSON records.

Reads the master log written by core/logging.sh and extracts:
  - variables  (VAR   lines)
  - commands   (EXEC  lines)
  - info       (INFO  lines)
  - warnings   (WARN  lines)
  - errors     (ERROR lines)
  - steps      (run_manifest rows: timestamp|step|STATUS|note)

Output JSON schema:
  {
    "run_id": str,
    "parsed_at": ISO8601,
    "log_file": str,
    "variables": [{"ts":…, "script":…, "name":…, "value":…, "desc":…}],
    "commands":  [{"ts":…, "script":…, "output":…}],
    "steps":     [{"ts":…, "step":…, "status":…, "note":…}],
    "errors":    [{"ts":…, "script":…, "message":…}],
    "warnings":  [{"ts":…, "script":…, "message":…}]
  }

Usage:
  python pipeline/parse_logs.py --log /path/to/master_*.log --out parsed.json
  python pipeline/parse_logs.py --log /path/to/logs/ --out parsed.json
  python pipeline/parse_logs.py --manifest /path/to/run_manifest_*.txt --out parsed.json
"""

import argparse
import glob
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


# ── Log line regex ────────────────────────────────────────────────────────────
# Format: [YYYY-MM-DDTHH:MM:SSZ][LEVEL][SCRIPT_NAME] message
_LINE_RE = re.compile(
    r"^\[(?P<ts>[^\]]+)\]\[(?P<level>[A-Z ]{5})\]\[(?P<script>[^\]]+)\]\s*(?P<msg>.*)$"
)

# VAR line: NAME="VALUE"  # description
_VAR_RE = re.compile(r'^(?P<name>\w+)="(?P<value>[^"]*)"(?:\s+#\s*(?P<desc>.*))?$')

# Run manifest line: TS|step|STATUS|note
_MANIFEST_RE = re.compile(
    r"^(?P<ts>[^|]+)\|(?P<step>[^|]+)\|(?P<status>OK|FAIL|SKIP|PENDING)\|?(?P<note>.*)$"
)


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_master_log(path: Path) -> dict:
    """Parse a single master log file into structured records."""
    variables: list[dict] = []
    commands: list[dict] = []
    errors: list[dict] = []
    warnings: list[dict] = []
    info: list[dict] = []
    run_id = "UNKNOWN"

    text = path.read_text(errors="replace")

    for line in text.splitlines():
        m = _LINE_RE.match(line.strip())
        if not m:
            continue

        ts = m.group("ts").strip()
        level = m.group("level").strip()
        script = m.group("script").strip()
        msg = m.group("msg").strip()

        if level == "VAR":
            vm = _VAR_RE.match(msg)
            if vm:
                variables.append({
                    "ts": ts,
                    "script": script,
                    "name": vm.group("name"),
                    "value": vm.group("value"),
                    "desc": (vm.group("desc") or "").strip(),
                })
                # Extract run_id from RUN_ID variable
                if vm.group("name") == "RUN_ID":
                    run_id = vm.group("value")
        elif level == "EXEC":
            commands.append({"ts": ts, "script": script, "output": msg})
        elif level == "ERROR":
            errors.append({"ts": ts, "script": script, "message": msg})
        elif level == "WARN":
            warnings.append({"ts": ts, "script": script, "message": msg})
        elif level == "INFO":
            info.append({"ts": ts, "script": script, "message": msg})

    return {
        "run_id": run_id,
        "log_file": str(path),
        "variables": variables,
        "commands": commands,
        "errors": errors,
        "warnings": warnings,
        "info": info,
    }


def parse_manifest_file(path: Path) -> list[dict]:
    """Parse a run_manifest_*.txt file into step records."""
    steps: list[dict] = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        m = _MANIFEST_RE.match(line)
        if m:
            steps.append({
                "ts": m.group("ts").strip(),
                "step": m.group("step").strip(),
                "status": m.group("status").strip(),
                "note": m.group("note").strip(),
            })
    return steps


def merge_results(results: list[dict], steps: list[dict]) -> dict:
    """Merge multiple parsed log dicts and step records into one output."""
    merged: dict = {
        "parsed_at": _now_iso(),
        "run_id": "UNKNOWN",
        "log_files": [],
        "variables": [],
        "commands": [],
        "errors": [],
        "warnings": [],
        "info": [],
        "steps": steps,
    }

    for r in results:
        if r["run_id"] != "UNKNOWN":
            merged["run_id"] = r["run_id"]
        merged["log_files"].append(r["log_file"])
        merged["variables"].extend(r["variables"])
        merged["commands"].extend(r["commands"])
        merged["errors"].extend(r["errors"])
        merged["warnings"].extend(r["warnings"])
        merged["info"].extend(r["info"])

    return merged


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Parse hands-on-metal install logs into structured JSON"
    )
    ap.add_argument(
        "--log",
        help="Path to master log file or directory containing logs/*.log files. "
             "Supports glob patterns.",
    )
    ap.add_argument(
        "--manifest",
        help="Path to run_manifest_*.txt file (optional; also searched in --log dir)",
    )
    ap.add_argument(
        "--out",
        default="-",
        help="Output JSON file path, or '-' for stdout (default: stdout)",
    )
    args = ap.parse_args()

    if not args.log and not args.manifest:
        ap.error("At least one of --log or --manifest is required")

    log_paths: list[Path] = []
    manifest_paths: list[Path] = []

    # Resolve log files
    if args.log:
        p = Path(args.log)
        if p.is_dir():
            # Search for master_*.log and run_manifest_*.txt inside
            log_paths = sorted(p.glob("master_*.log"))
            log_paths += sorted(p.glob("logs/master_*.log"))
            manifest_paths = sorted(p.glob("run_manifest_*.txt"))
            manifest_paths += sorted(p.glob("logs/run_manifest_*.txt"))
        elif "*" in str(p):
            log_paths = sorted(Path(".").glob(str(p)))
        elif p.is_file():
            log_paths = [p]
        else:
            print(f"Warning: log path not found: {p}", file=sys.stderr)

    # Resolve manifest files
    if args.manifest:
        mp = Path(args.manifest)
        if "*" in str(mp):
            manifest_paths += sorted(Path(".").glob(str(mp)))
        elif mp.is_file():
            manifest_paths.append(mp)

    if not log_paths and not manifest_paths:
        print("No log files found.", file=sys.stderr)
        sys.exit(1)

    # Parse
    results = [parse_master_log(p) for p in log_paths]
    steps: list[dict] = []
    for mp in manifest_paths:
        steps.extend(parse_manifest_file(mp))

    output = merge_results(results, steps)

    # Summary
    print(
        f"Parsed: {len(log_paths)} log file(s), {len(manifest_paths)} manifest(s)",
        file=sys.stderr,
    )
    print(
        f"  variables={len(output['variables'])} errors={len(output['errors'])} "
        f"warnings={len(output['warnings'])} steps={len(output['steps'])}",
        file=sys.stderr,
    )

    # Write output
    json_str = json.dumps(output, indent=2)
    if args.out == "-":
        print(json_str)
    else:
        Path(args.out).write_text(json_str, encoding="utf-8")
        print(f"Output written to: {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
