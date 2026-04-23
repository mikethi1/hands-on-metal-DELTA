#!/usr/bin/env python3
"""
pipeline/github_notify.py
==========================
Send a GitHub Issue or comment when an authenticated install run fails.
Summarizes the failure cause, includes redacted diagnostics, and links
to the relevant troubleshooting section.

Requires: GITHUB_TOKEN with 'issues:write' scope.

Usage:
  # Open a new issue:
  python pipeline/github_notify.py \\
      --repo mikethi/hands-on-metal \\
      --analysis ~/tmp/analysis.json \\
      --run-id 20260101T120000Z

  # Comment on an existing issue:
  python pipeline/github_notify.py \\
      --repo mikethi/hands-on-metal \\
      --analysis ~/tmp/analysis.json \\
      --issue 42

Environment variables:
  GITHUB_TOKEN   Required — GitHub PAT with repo/issues scope
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone


_GITHUB_API = "https://api.github.com"


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _api_request(
    path: str,
    token: str,
    payload: dict | None = None,
    method: str = "POST",
) -> dict:
    url = f"{_GITHUB_API}{path}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub API {exc.code} at {url}: {body}") from exc


# ── Notification body builder ─────────────────────────────────────────────────

def build_issue_body(analysis: dict, run_id: str) -> str:
    """Build the Markdown body for a GitHub issue or comment."""
    overall = analysis.get("overall_result", "UNKNOWN")
    failures = analysis.get("failures", [])
    top = analysis.get("top_cause") or (failures[0] if failures else None)
    snapshot = analysis.get("device_snapshot", {})
    step_summary = analysis.get("step_summary", {})
    analyzed_at = analysis.get("analyzed_at", _now_iso())

    lines: list[str] = []

    lines.append(f"## 🔩 hands-on-metal Install Failure Report")
    lines.append(f"")
    lines.append(f"| Field | Value |")
    lines.append(f"|-------|-------|")
    lines.append(f"| Run ID | `{run_id}` |")
    lines.append(f"| Analyzed at | {analyzed_at} |")
    lines.append(f"| Overall result | **{overall}** |")
    lines.append(f"| Errors | {analysis.get('failure_count', 0)} |")
    lines.append(f"| Warnings | {analysis.get('warning_count', 0)} |")
    lines.append(f"")

    # Device snapshot (already redacted by failure_analysis.py)
    if snapshot:
        lines.append("### Device")
        lines.append("")
        lines.append("| Property | Value |")
        lines.append("|----------|-------|")
        display_keys = [
            ("HOM_DEV_MODEL", "Model"),
            ("HOM_DEV_BRAND", "Brand"),
            ("HOM_DEV_SDK_INT", "Android API"),
            ("HOM_DEV_ANDROID_VER", "Android Version"),
            ("HOM_DEV_SPL", "Security Patch"),
            ("HOM_DEV_IS_AB", "A/B Slots"),
            ("HOM_DEV_BOOT_PART", "Boot Partition"),
            ("HOM_DEV_DYNAMIC_PARTITIONS", "Dynamic Partitions"),
            ("HOM_DEV_AVB_STATE", "AVB State"),
            ("HOM_MAGISK_VER_CODE", "Magisk Version"),
            ("HOM_ARB_ROLLBACK_RISK", "Rollback Risk"),
            ("HOM_ARB_MAY2026_ACTIVE", "May-2026 Policy"),
            ("HOM_ENV_CLASS", "Install Environment"),
            ("HOM_CANDIDATE_FAMILY_MATCHED", "Device Family"),
        ]
        for key, label in display_keys:
            val = snapshot.get(key, "")
            if val:
                lines.append(f"| {label} | `{val}` |")
        lines.append("")

    # Top cause
    if top:
        lines.append("### Most probable cause")
        lines.append("")
        lines.append(
            f"**[{top['signature_id']}] {top['name']}** "
            f"(confidence: {top['confidence']:.0%})"
        )
        lines.append("")
        lines.append(f"> {top['probable_cause']}")
        lines.append("")

        if top.get("remediation"):
            lines.append("### Suggested remediation steps")
            lines.append("")
            for i, step in enumerate(top["remediation"], 1):
                lines.append(f"{i}. {step}")
            lines.append("")

        if top.get("docs_link"):
            lines.append(
                f"📖 [Troubleshooting guide]"
                f"(https://github.com/mikethi/hands-on-metal/blob/main/{top['docs_link']})"
            )
            lines.append("")

    # Step summary
    if step_summary:
        lines.append("### Step results")
        lines.append("")
        lines.append("| Step | Status |")
        lines.append("|------|--------|")
        for step, status in step_summary.items():
            emoji = "✅" if status == "OK" else ("❌" if status == "FAIL" else "⏭️")
            lines.append(f"| {step} | {emoji} {status} |")
        lines.append("")

    # All matched signatures
    if len(failures) > 1:
        lines.append("<details>")
        lines.append("<summary>All matched failure signatures</summary>")
        lines.append("")
        for f in failures:
            lines.append(
                f"- **[{f['signature_id']}]** {f['name']} "
                f"— confidence {f['confidence']:.0%}"
            )
        lines.append("")
        lines.append("</details>")
        lines.append("")

    lines.append("---")
    lines.append("*Generated by [hands-on-metal](https://github.com/mikethi/hands-on-metal) "
                 "pipeline/github_notify.py — diagnostic data is redacted by default.*")

    return "\n".join(lines)


def build_issue_title(analysis: dict, run_id: str) -> str:
    top = analysis.get("top_cause")
    if top:
        return f"Install failure [{top['signature_id']}]: {top['name']} (run {run_id})"
    overall = analysis.get("overall_result", "UNKNOWN")
    return f"Install {overall} (run {run_id})"


# ── Issue label helper ────────────────────────────────────────────────────────

def _ensure_label(owner: str, repo: str, token: str, name: str, color: str) -> None:
    """Create the label if it doesn't exist; silently skip if it does."""
    try:
        _api_request(
            f"/repos/{owner}/{repo}/labels",
            token=token,
            payload={"name": name, "color": color},
        )
    except RuntimeError as exc:
        if "422" not in str(exc):  # 422 = already exists
            print(f"Warning: could not create label '{name}': {exc}", file=sys.stderr)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Send a GitHub issue/comment when an install run fails"
    )
    ap.add_argument(
        "--repo",
        required=True,
        help="GitHub repository in owner/name format (e.g. mikethi/hands-on-metal)",
    )
    ap.add_argument(
        "--analysis",
        required=True,
        help="Path to failure_analysis.json",
    )
    ap.add_argument(
        "--run-id",
        default="",
        help="Run ID string (used in issue title and body)",
    )
    ap.add_argument(
        "--issue",
        type=int,
        default=0,
        help="If provided, add a comment to this issue number instead of opening a new one",
    )
    ap.add_argument(
        "--token",
        default="",
        help="GitHub PAT (or set GITHUB_TOKEN env var)",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the issue body without sending",
    )
    args = ap.parse_args()

    token = args.token or os.environ.get("GITHUB_TOKEN", "")
    if not token and not args.dry_run:
        ap.error("GITHUB_TOKEN is required (set env var or use --token)")

    # Load analysis
    analysis = json.loads(Path(args.analysis).read_text(encoding="utf-8"))
    run_id = args.run_id or analysis.get("run_id", "UNKNOWN")

    # Only notify on failures
    if analysis.get("overall_result") == "OK" and not args.dry_run:
        print("Install result is OK — no notification needed.", file=sys.stderr)
        return

    body = build_issue_body(analysis, run_id)
    title = build_issue_title(analysis, run_id)

    if args.dry_run:
        print(f"=== Issue title ===\n{title}\n")
        print(f"=== Issue body ===\n{body}")
        return

    owner, repo = args.repo.split("/", 1)

    if args.issue:
        # Add comment to existing issue
        result = _api_request(
            f"/repos/{owner}/{repo}/issues/{args.issue}/comments",
            token=token,
            payload={"body": body},
        )
        url = result.get("html_url", "")
        print(f"Comment added: {url}")
    else:
        # Create new issue
        _ensure_label(owner, repo, token, "install-failure", "d73a4a")
        _ensure_label(owner, repo, token, "automated", "0075ca")

        top = analysis.get("top_cause")
        labels = ["install-failure", "automated"]
        if top and top.get("signature_id") == "UNKNOWN_DEVICE":
            labels.append("new-device")
            _ensure_label(owner, repo, token, "new-device", "e4e669")

        result = _api_request(
            f"/repos/{owner}/{repo}/issues",
            token=token,
            payload={
                "title": title,
                "body": body,
                "labels": labels,
            },
        )
        url = result.get("html_url", "")
        print(f"Issue created: {url}")


if __name__ == "__main__":
    main()
