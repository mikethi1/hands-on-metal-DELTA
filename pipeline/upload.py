#!/usr/bin/env python3
"""
pipeline/upload.py
==================
Privacy-aware diagnostic upload for hands-on-metal install failures.

Default (redacted) mode:
  - Reads logs, analysis JSON, and env_registry.sh
  - Applies PII redaction (all variables matching PII patterns → '#')
  - Uploads a public GitHub Gist with the redacted bundle

Private (opt-in) mode  [--private]:
  - Skips PII redaction
  - Creates a SECRET GitHub Gist (URL-only access, not publicly searchable)
  - Also writes the bundle to /sdcard/hands-on-metal/private/ locally
  - Never commits to git history

Usage:
  # Redacted upload (default, safe for public sharing):
  python pipeline/upload.py \\
      --logs /tmp/hom_logs/ \\
      --analysis /tmp/analysis.json \\
      --token "$GITHUB_TOKEN"

  # Unredacted private upload (requires explicit consent):
  python pipeline/upload.py \\
      --logs /tmp/hom_logs/ \\
      --analysis /tmp/analysis.json \\
      --token "$GITHUB_TOKEN" \\
      --private \\
      --consent "I consent to sharing unredacted diagnostic data"

Environment variables:
  GITHUB_TOKEN   GitHub personal access token with gist scope
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone


# ── PII redaction ─────────────────────────────────────────────────────────────
# These patterns mirror core/privacy.sh so behavior is consistent
# between on-device shell redaction and host-side Python redaction.

_PII_NAME_FRAGMENTS = {
    "IMEI", "IMSI", "MEID", "MSISDN", "ICCID", "SIM_ID", "SIM_SERIAL",
    "PHONE_NUMBER", "PHONE_NUM", "SUBSCRIBER", "OWNER_NAME", "OWNER_EMAIL",
    "ACCOUNT_NAME", "ACCOUNT_ID", "USER_NAME", "WIFI_SSID", "WIFI_PSK",
    "WIFI_PASSWORD", "BLUETOOTH_NAME", "BT_NAME", "GPS_LATITUDE",
    "GPS_LONGITUDE", "GPS_COORDS", "LOCATION", "EMAIL", "FINGERPRINT",
    "BUILD_FINGERPRINT",
}

_PII_VALUE_RES = [
    re.compile(r"^\d{14,15}$"),                                      # IMEI/IMSI
    re.compile(r"^\d{19,20}$"),                                      # ICCID
    re.compile(r"^\d{3}[-. ]\d{3}[-. ]\d{4}$"),                     # US phone
    re.compile(r"^(\+\d{1,3})?[ .-]?\d{3}[ .-]\d{3}[ .-]\d{4}$"),  # intl phone
    re.compile(r"^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$"),  # email
]

_REDACTED = "#"


def _is_pii_name(name: str) -> bool:
    upper = name.upper()
    return any(frag in upper for frag in _PII_NAME_FRAGMENTS)


def _is_pii_value(value: str) -> bool:
    return any(rx.match(value) for rx in _PII_VALUE_RES)


def redact_value(name: str, value: str) -> str:
    """Return the value with PII replaced by '#'."""
    if _is_pii_name(name) or (value and _is_pii_value(value)):
        return _REDACTED
    return value


def redact_env_registry(text: str) -> str:
    """Redact an env_registry.sh file's PII values."""
    lines = []
    for line in text.splitlines():
        m = re.match(r'^(\w+)="([^"]*)"(\s.*)?$', line)
        if m:
            name, value, rest = m.group(1), m.group(2), m.group(3) or ""
            safe = redact_value(name, value)
            lines.append(f'{name}="{safe}"{rest}')
        else:
            lines.append(line)
    return "\n".join(lines)


def redact_analysis(analysis: dict) -> dict:
    """Redact PII from the device_snapshot in an analysis dict."""
    import copy
    a = copy.deepcopy(analysis)
    snapshot = a.get("device_snapshot", {})
    for k, v in snapshot.items():
        snapshot[k] = redact_value(k, str(v))
    a["redacted"] = True
    return a


# ── Bundle builder ─────────────────────────────────────────────────────────────

def build_bundle(
    logs_dir: Path | None,
    analysis_path: Path | None,
    private: bool,
) -> dict[str, str]:
    """
    Collect all relevant files into a dict mapping filename → content.
    Applies redaction unless private=True.
    """
    files: dict[str, str] = {}

    # env_registry.sh
    registry_candidates = []
    if logs_dir:
        registry_candidates += list(logs_dir.glob("**/env_registry.sh"))
        registry_candidates += list(logs_dir.glob("env_registry.sh"))
    for rp in registry_candidates[:1]:
        text = rp.read_text(errors="replace")
        if not private:
            text = redact_env_registry(text)
        files["env_registry.sh"] = text

    # Master log
    if logs_dir:
        for lf in sorted(logs_dir.glob("**/master_*.log"))[:1]:
            files["master.log"] = lf.read_text(errors="replace")

    # Var audit
    if logs_dir:
        for lf in sorted(logs_dir.glob("**/var_audit_*.txt"))[:1]:
            text = lf.read_text(errors="replace")
            if not private:
                # Redact values in VAR lines
                redacted_lines = []
                for line in text.splitlines():
                    m = re.search(r'\[VAR\s*\]\[[^\]]+\]\s*(\w+)="([^"]*)"', line)
                    if m:
                        name, value = m.group(1), m.group(2)
                        safe = redact_value(name, value)
                        line = line.replace(f'"{value}"', f'"{safe}"', 1)
                    redacted_lines.append(line)
                text = "\n".join(redacted_lines)
            files["var_audit.txt"] = text

    # Run manifest
    if logs_dir:
        for lf in sorted(logs_dir.glob("**/run_manifest_*.txt"))[:1]:
            files["run_manifest.txt"] = lf.read_text(errors="replace")

    # Analysis JSON
    if analysis_path and analysis_path.exists():
        analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
        if not private:
            analysis = redact_analysis(analysis)
        files["failure_analysis.json"] = json.dumps(analysis, indent=2)

    # Summary README for the Gist
    mode_label = "UNREDACTED (private)" if private else "REDACTED (public)"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    files["README.md"] = (
        f"# hands-on-metal install diagnostic bundle\n\n"
        f"Generated: {ts}  \n"
        f"Mode: **{mode_label}**  \n\n"
        "See [hands-on-metal](https://github.com/mikethi/hands-on-metal) "
        "for documentation and troubleshooting guides.\n"
    )

    return files


# ── GitHub Gist upload ────────────────────────────────────────────────────────

def upload_gist(
    files: dict[str, str],
    token: str,
    private: bool,
    description: str = "hands-on-metal install diagnostic",
) -> str:
    """Upload files to GitHub Gist; return the Gist URL."""
    public = not private  # public Gist for redacted; secret Gist for private
    payload = json.dumps({
        "description": description,
        "public": public,
        "files": {name: {"content": content} for name, content in files.items()},
    }).encode("utf-8")

    req = urllib.request.Request(
        "https://api.github.com/gists",
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            return result.get("html_url", "")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub API error {exc.code}: {body}") from exc


# ── Local private folder write ────────────────────────────────────────────────

def write_local_private(files: dict[str, str], out_dir: Path) -> None:
    """Write bundle to a local private directory (never committed to git)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    # Write a .gitignore to prevent accidental commits
    gi = out_dir / ".gitignore"
    if not gi.exists():
        gi.write_text("*\n", encoding="utf-8")
    for name, content in files.items():
        (out_dir / name).write_text(content, encoding="utf-8")
    print(f"Private bundle written to: {out_dir}", file=sys.stderr)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Upload hands-on-metal diagnostics to GitHub Gist with privacy controls"
    )
    ap.add_argument(
        "--logs",
        help="Path to the logs directory (contains master_*.log, env_registry.sh, etc.)",
    )
    ap.add_argument("--analysis", help="Path to failure_analysis.json")
    ap.add_argument(
        "--token",
        default="",
        help="GitHub personal access token (or set GITHUB_TOKEN env var)",
    )
    ap.add_argument(
        "--private",
        action="store_true",
        help="Opt-in to unredacted private upload (creates secret Gist + local copy)",
    )
    ap.add_argument(
        "--consent",
        default="",
        help=(
            'Required with --private: must be exactly '
            '"I consent to sharing unredacted diagnostic data"'
        ),
    )
    ap.add_argument(
        "--local-private-dir",
        default="/sdcard/hands-on-metal/private",
        help="Local directory for private bundle (default: /sdcard/hands-on-metal/private)",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Build the bundle and show file names but do not upload",
    )
    args = ap.parse_args()

    # Validate private consent
    if args.private:
        required_consent = "I consent to sharing unredacted diagnostic data"
        if args.consent != required_consent:
            ap.error(
                f"--private requires --consent '{required_consent}' "
                "(exact string required to confirm opt-in)"
            )

    # Resolve token
    import os
    token = args.token or os.environ.get("GITHUB_TOKEN", "")

    logs_dir = Path(args.logs) if args.logs else None
    analysis_path = Path(args.analysis) if args.analysis else None

    # Build bundle
    print("Building diagnostic bundle...", file=sys.stderr)
    bundle = build_bundle(logs_dir, analysis_path, private=args.private)

    mode = "private (unredacted)" if args.private else "public (redacted)"
    print(f"Bundle mode: {mode}", file=sys.stderr)
    print(f"Files: {list(bundle.keys())}", file=sys.stderr)

    if args.dry_run:
        for name, content in bundle.items():
            print(f"\n--- {name} ({len(content)} chars) ---")
            print(content[:500] + ("..." if len(content) > 500 else ""))
        return

    # Write local private copy first (always, when --private)
    if args.private:
        write_local_private(bundle, Path(args.local_private_dir))

    # Upload to Gist
    if not token:
        print(
            "No GITHUB_TOKEN — skipping Gist upload. "
            "Bundle is available locally if --private was set.",
            file=sys.stderr,
        )
        return

    print("Uploading to GitHub Gist...", file=sys.stderr)
    try:
        url = upload_gist(bundle, token, private=args.private)
        visibility = "secret" if args.private else "public"
        print(f"Upload successful ({visibility} Gist):")
        print(url)
    except RuntimeError as exc:
        print(f"Upload failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
