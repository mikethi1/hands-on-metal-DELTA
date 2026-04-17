#!/usr/bin/env python3
"""
pipeline/failure_analysis.py
=============================
Analyze parsed install logs to identify failure causes and produce
ranked remediation hints.

Input: JSON produced by parse_logs.py
Output: Structured failure analysis JSON with confidence-ranked causes
        and remediation steps for each failure.

Usage:
  python pipeline/failure_analysis.py \
      --parsed parsed.json \
      --out analysis.json

  # Pipe from parse_logs:
  python pipeline/parse_logs.py --log logs/ --out - | \
      python pipeline/failure_analysis.py --parsed - --out analysis.json
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional


# ── Failure signature database ───────────────────────────────────────────────
# Each signature describes one known failure mode that can be identified from
# log content. Signatures are matched in order; all matching signatures are
# returned, ranked by confidence.

@dataclass
class Signature:
    id: str
    name: str
    # Keywords that must appear in error/warning messages (case-insensitive)
    error_keywords: list[str] = field(default_factory=list)
    # Variable name=value pairs that indicate this failure
    var_indicators: list[tuple[str, str]] = field(default_factory=list)
    # Step names that must have FAIL status
    failed_steps: list[str] = field(default_factory=list)
    # Base confidence (0.0–1.0)
    base_confidence: float = 0.5
    probable_cause: str = ""
    remediation: list[str] = field(default_factory=list)
    docs_link: str = ""


SIGNATURES: list[Signature] = [
    Signature(
        id="BOOT_PART_MISSING",
        name="Boot partition not found",
        error_keywords=["boot partition not found", "could not auto-discover",
                        "boot partition", "no boot device", "boot_dev=missing",
                        "hom_dev_boot_dev=missing"],
        var_indicators=[("HOM_DEV_BOOT_DEV", "MISSING"), ("HOM_DEV_BOOT_DEV", "")],
        failed_steps=["boot_image"],
        base_confidence=0.9,
        probable_cause=(
            "The installer could not locate the boot partition block device. "
            "The by-name symlink path may differ on this device family."
        ),
        remediation=[
            "List available partitions: ls /dev/block/bootdevice/by-name/ "
            "or ls /dev/block/by-name/ or ls /dev/block/platform/*/by-name/",
            "Set the correct by-name directory in env_registry.sh: "
            "HOM_BLOCK_BY_NAME=\"/dev/block/<correct_path>/by-name\"",
            "Check INSTALL_HUB.md for your device family's by-name path.",
            "If the device is unknown, a candidate entry has been created in "
            "/sdcard/hands-on-metal/candidates/ — submit it via GitHub Issues.",
        ],
        docs_link="docs/TROUBLESHOOTING.md#boot-partition-not-found",
    ),

    Signature(
        id="ANTI_ROLLBACK",
        name="Anti-rollback check blocked flash",
        error_keywords=["rollback risk", "anti-rollback", "spl mismatch",
                        "image spl", "rollback fuse", "cannot proceed safely",
                        "blocked"],
        var_indicators=[("HOM_ARB_ROLLBACK_RISK", "true")],
        failed_steps=["anti_rollback"],
        base_confidence=0.95,
        probable_cause=(
            "The boot image Security Patch Level (SPL) is older than the "
            "device's current SPL. Flashing would trigger anti-rollback "
            "fuse burning, potentially bricking the device."
        ),
        remediation=[
            "Download the correct boot.img from the firmware matching your "
            "current build fingerprint (ro.build.fingerprint).",
            "Get factory/OTA images from your OEM or developers.google.com/android/images.",
            "Extract boot.img: unzip factory.zip '*/image-*.zip' && unzip image-*.zip boot.img",
            "Copy to device: adb push boot.img /sdcard/hands-on-metal/boot_work/",
            "Re-run the installer and provide the correct path when prompted.",
        ],
        docs_link="docs/TROUBLESHOOTING.md#anti-rollback-check-fails",
    ),

    Signature(
        id="MAY2026_FLAGS",
        name="May-2026 AVB policy requires PATCHVBMETAFLAG",
        error_keywords=["patchvbmetaflag", "may-2026", "may 2026",
                        "2026-05-01", "avb policy"],
        var_indicators=[
            ("HOM_ARB_MAY2026_ACTIVE", "true"),
            ("HOM_ARB_REQUIRE_MAY2026_FLAGS", "true"),
        ],
        base_confidence=0.85,
        probable_cause=(
            "The device SPL is >= 2026-05-01. Magisk must be built with "
            "PATCHVBMETAFLAG=true for this policy. "
            "The installer sets this automatically when Magisk >= 27.0 is used."
        ),
        remediation=[
            "Upgrade Magisk to version 27.0 or newer.",
            "The anti_rollback.sh script sets PATCHVBMETAFLAG automatically "
            "for Magisk >= 27.0 — ensure the bundled magisk64 is up to date.",
            "Re-build the offline ZIP with a current Magisk binary (see MAINTAINER.md).",
        ],
        docs_link="docs/TROUBLESHOOTING.md#anti-rollback-check-fails",
    ),

    Signature(
        id="MAGISK_MISSING",
        name="Magisk binary not found",
        error_keywords=["magisk binary not found", "magisk not found",
                        "no magisk binary", "magisk64 missing", "magisk32 missing"],
        var_indicators=[("HOM_MAGISK_BIN", ""), ("HOM_MAGISK_BIN", "MISSING")],
        failed_steps=["magisk_patch"],
        base_confidence=0.9,
        probable_cause=(
            "No Magisk binary could be located on the device or in the bundle. "
            "Either Magisk is not installed (recovery path) or the offline ZIP "
            "was built without bundled binaries."
        ),
        remediation=[
            "For the recovery path: rebuild the ZIP with bundled magisk64 "
            "(see tools/README.md and MAINTAINER.md).",
            "Alternatively, copy magisk64 to /sdcard/hands-on-metal/tools/ "
            "before flashing the recovery ZIP.",
            "For the Magisk path: reinstall Magisk via the Magisk app first.",
            "Verify the Magisk binary is executable: chmod 755 /data/adb/magisk/magisk64",
        ],
        docs_link="docs/TROUBLESHOOTING.md#magisk-binary-not-found",
    ),

    Signature(
        id="MAGISK_OLD",
        name="Magisk version too old",
        error_keywords=["magisk version", "too old", "minmagisk", "25000",
                        "version below minimum"],
        var_indicators=[],
        failed_steps=[],
        base_confidence=0.8,
        probable_cause=(
            "The installed Magisk version is below the minimum required (25.0 / 25000). "
            "Old versions lack init_boot support and May-2026 AVB policy handling."
        ),
        remediation=[
            "Download Magisk 27.0+ from https://github.com/topjohnwu/Magisk/releases",
            "Install via the Magisk app: Modules → Direct Install → select APK",
            "Or flash the updated recovery ZIP with the newer bundled magisk64.",
        ],
        docs_link="docs/TROUBLESHOOTING.md#magisk-binary-not-found",
    ),

    Signature(
        id="FLASH_VERIFY_FAIL",
        name="Flash verification (SHA-256) failed",
        error_keywords=["sha-256 mismatch", "sha256 mismatch", "post-flash",
                        "verification failed", "flash verification"],
        var_indicators=[("HOM_FLASH_STATUS", "FAIL")],
        failed_steps=["flash"],
        base_confidence=0.9,
        probable_cause=(
            "The SHA-256 hash of the boot partition after flashing does not match "
            "the patched image. This may indicate a write error or wrong target partition."
        ),
        remediation=[
            "Do NOT reboot — the boot partition may be in an inconsistent state.",
            "Restore the original boot image from recovery: "
            "dd if=/sdcard/hands-on-metal/boot_work/boot_original.img "
            "of=/dev/block/bootdevice/by-name/boot bs=4096",
            "Retry once — transient eMMC errors are possible.",
            "If the error persists, verify HOM_FLASH_TARGET points to the correct partition.",
        ],
        docs_link="docs/TROUBLESHOOTING.md#flash-verification-fails",
    ),

    Signature(
        id="WRONG_PATCH_TARGET",
        name="Wrong partition patched (boot vs init_boot)",
        error_keywords=["init_boot", "wrong partition", "boot patched instead",
                        "init_boot patched instead"],
        var_indicators=[],
        failed_steps=[],
        base_confidence=0.7,
        probable_cause=(
            "The installer may have patched 'boot' instead of 'init_boot' "
            "(or vice versa) for this Android version. "
            "API 33+ devices require init_boot; API 32 and below require boot."
        ),
        remediation=[
            "Check HOM_DEV_SDK_INT and HOM_DEV_BOOT_PART in the var_audit log.",
            "For API 33+: set HOM_DEV_BOOT_PART=init_boot in env_registry.sh.",
            "For API 32 and below: set HOM_DEV_BOOT_PART=boot.",
            "Delete the state sentinel and re-run: rm /data/adb/modules/hands-on-metal-collector/.install_state",
        ],
        docs_link="docs/TROUBLESHOOTING.md#device-bootloops",
    ),

    Signature(
        id="NOT_ROOT",
        name="Shell not running as root",
        error_keywords=["not running as root", "uid=0 required",
                        "permission denied", "root access required",
                        "selinux denial", "avc: denied"],
        var_indicators=[],
        failed_steps=[],
        base_confidence=0.8,
        probable_cause=(
            "The script is not running with root privileges. "
            "SELinux may be blocking access to /dev/block/* or the script "
            "was invoked without root."
        ),
        remediation=[
            "For Magisk path: ensure Magisk is installed and the module runs via service.sh.",
            "For recovery path: run from TWRP terminal which runs as root by default.",
            "For ADB: use 'adb root' or 'adb shell su -c ...'",
            "If SELinux is blocking: check 'cat /proc/self/attr/current' and "
            "compare with expected context in TROUBLESHOOTING.md.",
        ],
        docs_link="docs/TROUBLESHOOTING.md",
    ),

    Signature(
        id="STORAGE_FULL",
        name="Output directory not writable / storage full",
        error_keywords=["no space left", "read-only file system", "cannot write",
                        "storage full", "write failed", "sdcard not writable"],
        var_indicators=[],
        failed_steps=[],
        base_confidence=0.75,
        probable_cause=(
            "The /sdcard/hands-on-metal/ directory is not writable. "
            "Storage may be full, encrypted, or not yet mounted."
        ),
        remediation=[
            "Check available space: df -h /sdcard",
            "If storage is encrypted and not mounted, unlock the device first.",
            "Free up space on /sdcard and retry.",
            "If running early in boot, wait for /sdcard to be mounted (service.sh waits 10s).",
        ],
        docs_link="docs/TROUBLESHOOTING.md",
    ),

    Signature(
        id="MAGISK_PATCH_NO_OUTPUT",
        name="Magisk patch produced no output image",
        error_keywords=["no output image", "patch produced no output",
                        "patched image not found", "magisk --boot-patch failed"],
        var_indicators=[],
        failed_steps=["magisk_patch"],
        base_confidence=0.85,
        probable_cause=(
            "magisk --boot-patch ran but no output image was produced. "
            "Common causes: /data/local/tmp not writable, image is encrypted "
            "or corrupted, or Magisk version mismatch."
        ),
        remediation=[
            "Check /data/local/tmp is writable: ls -la /data/local/tmp",
            "Re-acquire the boot image from the partition (it may have been corrupted).",
            "Upgrade to Magisk 27.0+ for init_boot compatibility.",
            "Check the magisk_patch log: cat /sdcard/hands-on-metal/logs/magisk_patch_*.log",
        ],
        docs_link="docs/TROUBLESHOOTING.md#magisk-patch-fails",
    ),

    Signature(
        id="UNKNOWN_DEVICE",
        name="Unknown device / not in compatibility database",
        error_keywords=["unknown device", "no matching family", "candidate entry",
                        "partition_index", "not found in database"],
        var_indicators=[("HOM_CANDIDATE_FAMILY_MATCHED", "none")],
        failed_steps=[],
        base_confidence=0.7,
        probable_cause=(
            "This device/Android combination is not in the partition_index.json "
            "compatibility database. The installer continues with best-effort "
            "heuristics but may need manual intervention."
        ),
        remediation=[
            "The installer auto-created a candidate record in /sdcard/hands-on-metal/candidates/",
            "Submit the candidate via GitHub Issues (template: .github/ISSUE_TEMPLATE/new_device.yml).",
            "If install failed: manually check ls /dev/block/*/by-name/ and provide "
            "the correct partition path when prompted.",
            "See GOVERNANCE.md for how to contribute a new device entry.",
        ],
        docs_link="docs/TROUBLESHOOTING.md#unknown-device",
    ),
]


# ── Matching logic ────────────────────────────────────────────────────────────

def _match_signature(sig: Signature, parsed: dict) -> float:
    """
    Return a confidence score (0.0 = no match, > 0.0 = matched).
    Confidence is boosted by each additional matching indicator.
    """
    score = 0.0
    matched_indicators = 0
    total_checks = (
        len(sig.error_keywords) +
        len(sig.var_indicators) +
        len(sig.failed_steps)
    )
    if total_checks == 0:
        return 0.0

    # Check error/warning messages
    all_messages = [
        e["message"].lower()
        for e in parsed.get("errors", []) + parsed.get("warnings", [])
    ]
    for kw in sig.error_keywords:
        if any(kw.lower() in msg for msg in all_messages):
            matched_indicators += 1

    # Check variable values
    var_map: dict[str, str] = {
        v["name"].upper(): v["value"]
        for v in parsed.get("variables", [])
    }
    for var_name, expected_val in sig.var_indicators:
        actual = var_map.get(var_name.upper(), "")
        if expected_val == "" and actual == "":
            matched_indicators += 1
        elif expected_val and expected_val.lower() in actual.lower():
            matched_indicators += 1

    # Check failed steps
    failed_step_names = {
        s["step"].lower()
        for s in parsed.get("steps", [])
        if s.get("status") == "FAIL"
    }
    for step in sig.failed_steps:
        if step.lower() in failed_step_names:
            matched_indicators += 1

    if matched_indicators == 0:
        return 0.0

    # Scale confidence by fraction of indicators matched
    score = sig.base_confidence * (matched_indicators / total_checks)
    # Boost if ALL indicators matched
    if matched_indicators == total_checks:
        score = min(1.0, score + 0.1)

    return round(score, 3)


def _build_device_snapshot(parsed: dict) -> dict:
    """Extract key device variables from parsed log for the analysis output."""
    var_map = {v["name"]: v["value"] for v in parsed.get("variables", [])}
    keys = [
        "HOM_DEV_MODEL", "HOM_DEV_BRAND", "HOM_DEV_DEVICE",
        "HOM_DEV_SDK_INT", "HOM_DEV_ANDROID_VER", "HOM_DEV_SPL",
        "HOM_DEV_IS_AB", "HOM_DEV_BOOT_PART", "HOM_DEV_BOOT_DEV",
        "HOM_DEV_DYNAMIC_PARTITIONS", "HOM_DEV_AVB_STATE",
        "HOM_MAGISK_VER_CODE", "HOM_ARB_ROLLBACK_RISK",
        "HOM_ARB_MAY2026_ACTIVE", "HOM_CANDIDATE_FAMILY_MATCHED",
        "HOM_FLASH_STATUS", "HOM_ENV_CLASS",
    ]
    return {k: var_map.get(k, "") for k in keys}


# ── Main analysis ─────────────────────────────────────────────────────────────

def analyze(parsed: dict) -> dict:
    """Run all signatures against parsed log; return ranked failure analysis."""
    matches = []
    for sig in SIGNATURES:
        conf = _match_signature(sig, parsed)
        if conf > 0:
            matches.append({
                "signature_id": sig.id,
                "name": sig.name,
                "confidence": conf,
                "probable_cause": sig.probable_cause,
                "remediation": sig.remediation,
                "docs_link": sig.docs_link,
                "step": (
                    parsed["steps"][-1]["step"]
                    if parsed.get("steps") else ""
                ),
            })

    # Sort by confidence descending
    matches.sort(key=lambda x: x["confidence"], reverse=True)

    # Determine overall install outcome
    step_statuses = {s["step"]: s["status"] for s in parsed.get("steps", [])}
    overall = "OK"
    if parsed.get("errors"):
        overall = "FAIL"
    elif any(v == "FAIL" for v in step_statuses.values()):
        overall = "FAIL"
    elif not step_statuses:
        overall = "UNKNOWN"

    return {
        "run_id": parsed.get("run_id", "UNKNOWN"),
        "analyzed_at": _now_iso(),
        "overall_result": overall,
        "failure_count": len(parsed.get("errors", [])),
        "warning_count": len(parsed.get("warnings", [])),
        "step_summary": step_statuses,
        "failures": matches,
        "top_cause": matches[0] if matches else None,
        "device_snapshot": _build_device_snapshot(parsed),
        "redacted": True,
    }


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Analyze parsed install logs and produce ranked failure analysis"
    )
    ap.add_argument(
        "--parsed",
        required=True,
        help="Path to parsed.json from parse_logs.py, or '-' for stdin",
    )
    ap.add_argument(
        "--out",
        default="-",
        help="Output JSON file, or '-' for stdout (default: stdout)",
    )
    args = ap.parse_args()

    # Load parsed input
    if args.parsed == "-":
        raw = sys.stdin.read()
    else:
        raw = Path(args.parsed).read_text(encoding="utf-8")
    parsed = json.loads(raw)

    result = analyze(parsed)

    # Print summary to stderr
    top = result.get("top_cause")
    print(
        f"Analysis: overall={result['overall_result']} "
        f"errors={result['failure_count']} warnings={result['warning_count']} "
        f"signatures_matched={len(result['failures'])}",
        file=sys.stderr,
    )
    if top:
        print(
            f"Top cause: [{top['signature_id']}] {top['name']} "
            f"(confidence={top['confidence']:.0%})",
            file=sys.stderr,
        )
        print(f"  → {top['docs_link']}", file=sys.stderr)

    # Write output
    json_str = json.dumps(result, indent=2)
    if args.out == "-":
        print(json_str)
    else:
        Path(args.out).write_text(json_str, encoding="utf-8")
        print(f"Analysis written to: {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
