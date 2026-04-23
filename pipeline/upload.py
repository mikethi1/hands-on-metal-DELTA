#!/usr/bin/env python3
"""
pipeline/upload.py
==================
Upload a hands-on-metal share bundle.

DEFAULT (no auth, no network):
  Reads the local share/ bundle and prints a summary.
  Use this mode to review what would be shared before doing anything.

  python pipeline/upload.py --bundle /sdcard/hands-on-metal/share/<RUN_ID>/

AUTHENTICATED UPLOAD (opt-in, requires --token):
  Creates a public GitHub Gist with an upload-time redacted bundle.

  python pipeline/upload.py \\
      --bundle /sdcard/hands-on-metal/share/<RUN_ID>/ \\
      --token "$GITHUB_TOKEN"

PRIVATE UPLOAD (opt-in, requires --token + explicit consent):
  Creates a SECRET GitHub Gist (URL-based access only, not searchable).
  Also writes a copy to --private-dir for local reference.
  The bundle content must still be fully assembled before this is called.

  python pipeline/upload.py \\
      --bundle /sdcard/hands-on-metal/share/<RUN_ID>/ \\
      --token "$GITHUB_TOKEN" \\
      --private \\
      --consent "I consent to sharing unredacted diagnostic data"

Notes:
  - No token → local summary only (default)
  - Token without --private → prompt + public Gist, redacted content
  - Token + --private + consent → secret Gist, content passed as-is
  - Local share bundle stays on-device; redaction is applied at upload time
  - This script never reads env_registry.sh or log files directly;
    it only reads the pre-built share bundle from core/share.sh
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone


_REQUIRED_CONSENT = "I consent to sharing unredacted diagnostic data"
_REDACTED = "#"
_PII_NAME_PATTERNS = (
    "IMEI", "IMSI", "MEID", "MSISDN", "ICCID", "SIM_ID", "SIM_SERIAL",
    "PHONE_NUMBER", "PHONE_NUM", "SUBSCRIBER", "OWNER_NAME", "OWNER_EMAIL",
    "ACCOUNT_NAME", "ACCOUNT_ID", "USER_NAME", "WIFI_SSID", "WIFI_PSK",
    "WIFI_PASSWORD", "BLUETOOTH_NAME", "BT_NAME", "GPS_LATITUDE",
    "GPS_LONGITUDE", "GPS_COORDS", "LOCATION", "EMAIL", "FINGERPRINT",
    "BUILD_FINGERPRINT", "SERIAL_NUMBER", "HW_SERIAL", "HARDWARE_SERIAL",
    "DEVICE_SERIAL", "WLAN_MAC", "WIFI_MAC", "BT_MAC", "BLUETOOTH_MAC",
    "ETH_MAC", "MAC_ADDR", "MAC_ADDRESS",
)
_PII_VALUE_PATTERNS = (
    # 15-digit telecom IDs (IMEI/IMSI-like identifiers)
    re.compile(r"^[0-9]{15}$"),
    # 14-digit / 14-hex identifiers (legacy telecom IDs / MEID-like)
    re.compile(r"^[0-9]{14}$"),
    re.compile(r"^[0-9A-Fa-f]{14}$"),
    # 19-20 digit SIM card identifiers (ICCID-like)
    re.compile(r"^[0-9]{19,20}$"),
    # Phone number variants
    re.compile(r"^[0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}$"),
    re.compile(r"^(\+[0-9]{1,3})?[ .-]?[0-9]{3}[ .-][0-9]{3}[ .-][0-9]{4}$"),
    # Email address
    re.compile(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"),
    # MAC addresses (with separators and compact)
    re.compile(r"^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$"),
    re.compile(r"^[0-9A-Fa-f]{12}$"),
)
_KEYVAL_RE = re.compile(r'([A-Z0-9_]+)="([^"]*)"')


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── Bundle loader ─────────────────────────────────────────────────────────────

def load_bundle(bundle_dir: Path) -> dict[str, str]:
    """Load all files from a share/ bundle directory."""
    files: dict[str, str] = {}
    if not bundle_dir.is_dir():
        raise SystemExit(f"Bundle directory not found: {bundle_dir}")

    for f in sorted(bundle_dir.iterdir()):
        if f.is_file():
            files[f.name] = f.read_text(errors="replace")

    if not files:
        raise SystemExit(f"Bundle directory is empty: {bundle_dir}")

    return files


def summarise_bundle(files: dict[str, str]) -> None:
    """Print a human-readable summary of the bundle to stdout."""
    print("\n=== hands-on-metal share bundle ===")

    if "share_bundle.json" in files:
        try:
            data = json.loads(files["share_bundle.json"])
            run_id = data.get("run_id", "unknown")
            generated = data.get("generated_at", "unknown")
            var_count = len(data.get("variables", {}))
            steps = data.get("steps", [])
            failed = [s for s in steps if s.get("status") == "FAIL"]
            print(f"Run ID     : {run_id}")
            print(f"Generated  : {generated}")
            print(f"Variables  : {var_count}")
            print(f"Steps      : {len(steps)} ({len(failed)} failed)")
            print(f"PII-redacted: {data.get('pii_redacted', True)}")

            # Key device vars
            vv = data.get("variables", {})
            for key, label in [
                ("HOM_DEV_BRAND", "Brand"),
                ("HOM_DEV_MODEL", "Model"),
                ("HOM_DEV_SDK_INT", "API"),
                ("HOM_DEV_ANDROID_VER", "Android"),
                ("HOM_DEV_IS_AB", "A/B"),
                ("HOM_DEV_BOOT_PART", "Boot partition"),
                ("HOM_DEV_AVB_STATE", "AVB state"),
                ("HOM_MAGISK_VER_CODE", "Magisk"),
                ("HOM_CANDIDATE_FAMILY_MATCHED", "Device family"),
            ]:
                val = vv.get(key, "")
                if val:
                    print(f"  {label:<18}: {val}")

            if failed:
                print(f"\nFailed steps:")
                for s in failed:
                    print(f"  ❌ {s['step']} — {s.get('note', '')}")
        except json.JSONDecodeError:
            print("(could not parse share_bundle.json)")

    print(f"\nFiles in bundle:")
    for name, content in files.items():
        print(f"  {name}  ({len(content):,} chars)")

    if "README.txt" in files:
        print(f"\n--- README ---")
        print(files["README.txt"])


def _is_pii_name(name: str) -> bool:
    upper_name = name.upper()
    return any(token in upper_name for token in _PII_NAME_PATTERNS)


def _is_pii_value(value: str) -> bool:
    return any(pat.fullmatch(value) for pat in _PII_VALUE_PATTERNS)


def _redact_value(name: str, value: str) -> str:
    if _is_pii_name(name) or _is_pii_value(value):
        return _REDACTED
    return value


def _redact_keyval_text(content: str) -> str:
    def _replace(match: re.Match[str]) -> str:
        key = match.group(1)
        value = match.group(2)
        safe = _redact_value(key, value)
        return f'{key}="{safe}"'
    return _KEYVAL_RE.sub(_replace, content)


def redact_for_repo_upload(files: dict[str, str]) -> dict[str, str]:
    """Return a copy of *files* with upload-time privacy redaction applied."""
    out = dict(files)
    for name, content in files.items():
        if name == "share_bundle.json":
            try:
                data = json.loads(content)
            except json.JSONDecodeError:
                out[name] = _redact_keyval_text(content)
                continue
            variables = data.get("variables", {})
            if isinstance(variables, dict):
                data["variables"] = {
                    k: _redact_value(str(k), str(v))
                    for k, v in variables.items()
                }
            data["pii_redacted"] = True
            data["sharing_mode"] = "repo_upload_redacted"
            out[name] = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
            continue
        if name in ("env_registry.txt", "var_audit.txt"):
            out[name] = _redact_keyval_text(content)
    return out


def confirm_repo_upload(assume_yes: bool) -> bool:
    """Prompt user before sending local data to GitHub."""
    if assume_yes:
        return True
    if not sys.stdin.isatty():
        print(
            "Upload canceled: non-interactive session and no --yes flag.\n"
            "Re-run with --yes to confirm upload.",
            file=sys.stderr,
        )
        return False
    answer = input("Send bundle to GitHub now? [y/yes/N]: ").strip().lower()
    return answer in ("y", "yes")


# ── GitHub Gist upload ────────────────────────────────────────────────────────

def upload_gist(
    files: dict[str, str],
    token: str,
    public: bool,
    description: str,
) -> str:
    """Upload files dict to a GitHub Gist; return the Gist HTML URL."""
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
        raise RuntimeError(f"GitHub API {exc.code}: {body}") from exc


# ── Private local dir ─────────────────────────────────────────────────────────

def write_private_local(files: dict[str, str], private_dir: Path) -> None:
    """Write bundle files to a local private directory (gitignored)."""
    private_dir.mkdir(parents=True, exist_ok=True)
    # Ensure the directory is gitignored so nothing commits accidentally
    gitignore = private_dir / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text("*\n", encoding="utf-8")
    for name, content in files.items():
        (private_dir / name).write_text(content, encoding="utf-8")
    print(f"Private copy written to: {private_dir}", file=sys.stderr)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description=(
            "Upload a hands-on-metal share bundle. "
            "Default (no --token): local summary only. "
            "With --token: upload to GitHub Gist. "
            "With --private + consent: secret Gist."
        )
    )
    ap.add_argument(
        "--bundle",
        required=True,
        help="Path to the share/<RUN_ID>/ directory created by core/share.sh",
    )
    ap.add_argument(
        "--token",
        default="",
        help=(
            "GitHub personal access token with 'gist' scope. "
            "If not provided, only a local summary is shown. "
            "Can also be set via GITHUB_TOKEN environment variable. "
            "This is an opt-in feature — the default is local-only."
        ),
    )
    ap.add_argument(
        "--private",
        action="store_true",
        help=(
            "Create a secret Gist (URL-only access, not publicly searchable). "
            "Requires --consent. Use when sharing unredacted data with a maintainer."
        ),
    )
    ap.add_argument(
        "--consent",
        default="",
        help=(
            f"Required with --private. "
            f"Must be exactly: \"{_REQUIRED_CONSENT}\""
        ),
    )
    ap.add_argument(
        "--private-dir",
        default="",
        help=(
            "Local directory to write private bundle copy (default: "
            "<bundle-dir>/../private/). Only used with --private."
        ),
    )
    ap.add_argument(
        "--description",
        default="hands-on-metal install diagnostic",
        help="Gist description (optional)",
    )
    ap.add_argument(
        "--yes",
        action="store_true",
        help="Skip confirmation prompt and proceed with upload.",
    )
    args = ap.parse_args()

    # Validate private consent
    if args.private:
        if args.consent != _REQUIRED_CONSENT:
            ap.error(
                f"--private requires --consent with the exact text:\n"
                f"  \"{_REQUIRED_CONSENT}\""
            )

    bundle_dir = Path(args.bundle)
    files = load_bundle(bundle_dir)

    # Always show local summary
    summarise_bundle(files)

    # Resolve token
    token = args.token or os.environ.get("GITHUB_TOKEN", "")

    # No token → local-only mode (done)
    if not token:
        print(
            "\nNo GITHUB_TOKEN provided — local summary only.\n"
            "To upload to GitHub, set GITHUB_TOKEN and re-run with --token.\n"
            "See README.txt in the bundle directory for instructions.",
            file=sys.stderr,
        )
        return

    if not confirm_repo_upload(args.yes):
        print("Keeping bundle local only (upload aborted).", file=sys.stderr)
        return

    upload_files = files
    if not args.private:
        upload_files = redact_for_repo_upload(files)

    # Write private local copy first (if --private)
    if args.private:
        priv_dir = (
            Path(args.private_dir)
            if args.private_dir
            else bundle_dir.parent / "private" / bundle_dir.name
        )
        write_private_local(upload_files, priv_dir)

    # Upload to Gist
    public_gist = not args.private  # public Gist for redacted; secret for private
    visibility = "secret" if args.private else "public"
    print(f"\nUploading {visibility} Gist to GitHub...", file=sys.stderr)

    try:
        url = upload_gist(
            upload_files,
            token=token,
            public=public_gist,
            description=args.description,
        )
        print(f"Upload successful ({visibility} Gist):")
        print(url)
    except RuntimeError as exc:
        print(f"Upload failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
