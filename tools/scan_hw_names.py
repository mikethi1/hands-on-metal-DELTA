#!/usr/bin/env python3
"""
tools/scan_hw_names.py
======================
Standalone, read-only hardware-group scanner.

Walks a dump directory (or a ZIP produced by collect.sh) and looks for
every piece of data related to named hardware components:

  • VINTF manifest XML  — <hal> names and AIDL <fqname> descriptors
  • ComponentTypeSet XML — audio product strategy IDs (Name= / Identifier=)
  • sysconfig / permissions XML — declared <feature> names
  • getprop.txt        — hardware-relevant Android properties
  • lshal / lshal_full — runtime HAL listing (if present)
  • lsmod             — kernel modules

All names are matched against the same prefix table used by the
libhybris shim (g_aidl_table) so findings are grouped by the same
hardware category the shim would log at runtime.

Nothing is written, modified, or imported from any other pipeline script.

Usage
-----
  python tools/scan_hw_names.py --dump /path/to/live_dump
  python tools/scan_hw_names.py --zip  /path/to/live_dump.zip
  python tools/scan_hw_names.py --dump /path/to/live_dump --category audio
  python tools/scan_hw_names.py --dump . --json  > hw_names.json
"""

import argparse
import io
import json
import re
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

# ── AIDL descriptor prefix table ─────────────────────────────────────────────
# Mirrors halium-shim/shim.c  g_aidl_table[] exactly.
# Format: (prefix, category)
AIDL_TABLE: list[tuple[str, str]] = [
    ("android.hardware.audio",                  "audio"),
    ("android.hardware.biometrics",             "biometrics"),
    ("android.hardware.bluetooth",              "bluetooth"),
    ("android.hardware.boot",                   "boot"),
    ("android.hardware.camera",                 "camera"),
    ("android.hardware.contexthub",             "contexthub"),
    ("android.hardware.drm",                    "drm"),
    ("android.hardware.dumpstate",              "dumpstate"),
    ("android.hardware.gatekeeper",             "gatekeeper"),
    ("android.hardware.gnss",                   "gps"),
    ("android.hardware.graphics",               "display"),
    ("android.hardware.health",                 "health"),
    ("android.hardware.input",                  "input"),
    ("android.hardware.keymaster",              "keymaster"),
    ("android.hardware.light",                  "lights"),
    ("android.hardware.media",                  "codec"),
    ("android.hardware.memtrack",               "memtrack"),
    ("android.hardware.nfc",                    "nfc"),
    ("android.hardware.neuralnetworks",         "nnapi"),
    ("android.hardware.oemlock",                "oemlock"),
    ("android.hardware.power",                  "power"),
    ("android.hardware.radio",                  "modem"),
    ("android.hardware.secure_element",         "se"),
    ("android.hardware.security",               "security"),
    ("android.hardware.sensors",                "sensors"),
    ("android.hardware.thermal",                "thermal"),
    ("android.hardware.usb",                    "usb"),
    ("android.hardware.vibrator",               "vibrator"),
    ("android.hardware.weaver",                 "weaver"),
    ("android.hardware.wifi",                   "wifi"),
    ("android.system",                          "system"),
    ("com.google.input",                        "touchscreen"),
    ("hardware.google",                         "google_hw"),
    ("vendor.google.battery",                   "battery"),
    ("vendor.google.bluetooth_ext",             "bluetooth"),
    ("vendor.google.camera",                    "camera"),
    ("vendor.google.edgetpu",                   "tpu"),
    ("vendor.google.wireless_charger",          "charger"),
    ("vendor.samsung_slsi.telephony",           "modem"),
    ("vendor.dolby",                            "audio"),
]

# ── Audio product strategy table ─────────────────────────────────────────────
# Mirrors halium-shim/shim.c  g_strategies[] exactly.
# Standard AOSP strategies have id=None; vendor strategies have id=1000-1039.
STRATEGIES: list[tuple[int | None, str]] = [
    (None, "STRATEGY_PHONE"),
    (None, "STRATEGY_SONIFICATION"),
    (None, "STRATEGY_ENFORCED_AUDIBLE"),
    (None, "STRATEGY_ACCESSIBILITY"),
    (None, "STRATEGY_SONIFICATION_RESPECTFUL"),
    (None, "STRATEGY_ASSISTANT"),
    (None, "STRATEGY_MEDIA"),
    (None, "STRATEGY_DTMF"),
    (None, "STRATEGY_CALL_ASSISTANT"),
    (None, "STRATEGY_TRANSMITTED_THROUGH_SPEAKER"),
    *[(1000 + i, f"vx_{1000 + i}") for i in range(40)],
]
STRATEGY_BY_ID: dict[int, str] = {sid: name for sid, name in STRATEGIES if sid is not None}
STRATEGY_BY_NAME: dict[str, int | None] = {name: sid for sid, name in STRATEGIES}

# Getprop keys that carry hardware-relevant data
HW_PROP_PREFIXES = (
    "ro.hardware",
    "ro.board",
    "ro.product",
    "ro.build",
    "ro.vendor",
    "ro.soc",
    "persist.vendor",
    "ro.treble",
    "ro.vndk",
    "ro.apex",
    "ro.debuggable",
    "ro.secure",
    "init_boot",
    "vendor_boot",
)

# Kernel module → hardware category heuristics
MODULE_HW: list[tuple[str, str]] = [
    ("mali",         "display"),
    ("kgsl",         "display"),
    ("msm_drm",      "display"),
    ("exynos",       "display"),
    ("drm",          "display"),
    ("v4l2",         "camera"),
    ("video",        "camera"),
    ("camera",       "camera"),
    ("bt",           "bluetooth"),
    ("bcmbt",        "bluetooth"),
    ("btlinux",      "bluetooth"),
    ("qca_cld",      "wifi"),
    ("bcmdhd",       "wifi"),
    ("wlan",         "wifi"),
    ("wifi",         "wifi"),
    ("sound",        "audio"),
    ("snd",          "audio"),
    ("tfa",          "audio"),
    ("cs40l",        "vibrator"),
    ("vibrator",     "vibrator"),
    ("nfc",          "nfc"),
    ("thermal",      "thermal"),
    ("modem",        "modem"),
    ("mdm",          "modem"),
    ("gnss",         "gps"),
    ("gps",          "gps"),
    ("sensors",      "sensors"),
    ("iio",          "sensors"),
    ("binder",       "system"),
    ("hwbinder",     "system"),
    ("vndbinder",    "system"),
    ("uhid",         "input"),
    ("udc",          "usb"),
    ("usb",          "usb"),
    ("edgetpu",      "tpu"),
]


# ── Category resolution ───────────────────────────────────────────────────────

def aidl_category(name: str) -> str:
    """Return hardware category for a HAL / AIDL descriptor name."""
    for prefix, cat in AIDL_TABLE:
        if name.startswith(prefix):
            return cat
    return "unknown"


def module_category(mod: str) -> str:
    lower = mod.lower()
    for frag, cat in MODULE_HW:
        if frag in lower:
            return cat
    return "unknown"


# ── Text helpers ──────────────────────────────────────────────────────────────

def _text(el: ET.Element | None) -> str:
    return (el.text or "").strip() if el is not None else ""


# ── File readers (path or zip member) ────────────────────────────────────────

class DumpReader:
    """Abstract access to either a real directory or a ZIP archive."""

    def __init__(self, dump_path: Path | None, zip_path: Path | None) -> None:
        self._dir  = dump_path
        self._zip  = zipfile.ZipFile(zip_path) if zip_path else None
        # Normalise: find the top-level prefix inside the zip (e.g. "live_dump/")
        self._zpfx = ""
        if self._zip:
            tops = {n.split("/")[0] for n in self._zip.namelist() if "/" in n}
            if len(tops) == 1:
                self._zpfx = tops.pop() + "/"

    def read_text(self, rel: str) -> str | None:
        """Return file contents as str, or None if not found."""
        if self._zip:
            candidate = self._zpfx + rel
            try:
                with self._zip.open(candidate) as f:
                    return f.read().decode("utf-8", errors="replace")
            except KeyError:
                return None
        else:
            p = self._dir / rel  # type: ignore[operator]
            if p.exists():
                return p.read_text(errors="replace")
            return None

    def glob_xml(self, rel_dir: str) -> list[tuple[str, str]]:
        """Return [(rel_path, content)] for all XML files under rel_dir."""
        results: list[tuple[str, str]] = []
        if self._zip:
            prefix = self._zpfx + rel_dir
            for name in self._zip.namelist():
                if name.startswith(prefix) and name.endswith(".xml") and not name.endswith("/"):
                    try:
                        with self._zip.open(name) as f:
                            content = f.read().decode("utf-8", errors="replace")
                        results.append((name[len(self._zpfx):], content))
                    except Exception:
                        pass
        else:
            base = self._dir / rel_dir  # type: ignore[operator]
            if base.is_dir():
                for p in sorted(base.rglob("*.xml")):
                    results.append((str(p.relative_to(self._dir)), p.read_text(errors="replace")))
        return results

    def list_files(self, rel_dir: str) -> list[str]:
        """Return relative paths of all files directly under rel_dir."""
        result: list[str] = []
        if self._zip:
            prefix = self._zpfx + rel_dir
            for name in self._zip.namelist():
                if name.startswith(prefix) and not name.endswith("/"):
                    result.append(name[len(self._zpfx):])
        else:
            base = self._dir / rel_dir  # type: ignore[operator]
            if base.is_dir():
                result = [str(p.relative_to(self._dir)) for p in sorted(base.iterdir()) if p.is_file()]
        return result

    def close(self) -> None:
        if self._zip:
            self._zip.close()


# ── Parsers ───────────────────────────────────────────────────────────────────

def parse_vintf_xml(rel_path: str, content: str) -> list[dict]:
    """Return list of HAL records from one VINTF manifest / component XML."""
    records: list[dict] = []
    try:
        root = ET.fromstring(content)
    except ET.ParseError:
        return records

    for hal in root.iter("hal"):
        hal_format = hal.get("format", "hidl")
        hal_name   = _text(hal.find("name"))
        if not hal_name:
            continue
        version   = _text(hal.find("version"))
        category  = aidl_category(hal_name)

        # Collect instances — AIDL uses <fqname>, HIDL uses <interface>/<instance>
        instances: list[str] = []
        for fq in hal.findall("fqname"):
            fq_text = _text(fq)
            if fq_text:
                instances.append(fq_text)
        if not instances:
            for iface in hal.findall(".//interface"):
                iname = _text(iface.find("name"))
                for inst in iface.findall("instance"):
                    instances.append(f"{iname}/{_text(inst)}")
        if not instances:
            instances = ["(no instance)"]

        for inst in instances:
            # Build the canonical unique identifier:
            #   AIDL: <name>/<Interface>/<instance>
            #         e.g. android.hardware.bluetooth/IBluetoothHci/default
            #   HIDL: <name>@<version>::<Interface>/<instance>
            #         e.g. android.hardware.bluetooth.audio@2.0::IBluetoothAudioProvidersFactory/default
            if hal_format == "hidl" and "::" in inst:
                # fqname already contains @version::Interface/instance
                uid = f"{hal_name}{inst}" if inst.startswith("@") else f"{hal_name}@{version}::{inst}"
            elif hal_format == "hidl" and version:
                uid = f"{hal_name}@{version}::{inst}"
            else:
                # AIDL: name/Interface/instance (fqname is "Interface/instance")
                uid = f"{hal_name}/{inst}"

            records.append({
                "source":    rel_path,
                "type":      "hal",
                "format":    hal_format,
                "name":      hal_name,
                "version":   version,
                "instance":  inst,
                "uid":       uid,
                "category":  category,
            })
    return records


def parse_component_type_set(rel_path: str, content: str) -> list[dict]:
    """Return strategy records from a ComponentTypeSet XML (audio policy engine)."""
    records: list[dict] = []
    try:
        root = ET.fromstring(content)
    except ET.ParseError:
        return records

    # Only process files that look like ComponentTypeSet XMLs
    if root.tag not in ("ComponentTypeSet", "ProductStrategies", "ProductStrategy",
                         "EngineConfigurableProductStrategies"):
        # Also accept the pattern where <ProductStrategies> is a sub-element
        ps = root.find(".//ComponentTypeSet") or root.find(".//ProductStrategies")
        if ps is None:
            return records
        root = ps

    def _process(node: ET.Element) -> None:
        comp_name = node.get("Name") or node.get("name") or ""
        identifier = node.get("Identifier") or node.get("identifier") or ""
        if not comp_name:
            return
        sid: int | None = None
        try:
            sid = int(identifier)
        except (ValueError, TypeError):
            pass
        kind = "vendor" if (sid is not None and 1000 <= sid <= 1039) else "aosp"
        # Unique identifier: numeric Identifier when present, else the Name string itself
        uid = str(sid) if sid is not None else comp_name
        records.append({
            "source":    rel_path,
            "type":      "audio_strategy",
            "name":      comp_name,
            "id":        sid,
            "uid":       uid,
            "kind":      kind,
            "category":  "audio",
        })
        for child in node:
            _process(child)

    for child in root:
        _process(child)
    return records


def parse_sysconfig_features(rel_path: str, content: str) -> list[dict]:
    """Return declared <feature name=…> entries from sysconfig / permissions XMLs."""
    records: list[dict] = []
    try:
        root = ET.fromstring(content)
    except ET.ParseError:
        return records
    for el in root.iter("feature"):
        fname = el.get("name") or ""
        if fname:
            records.append({
                "source":   rel_path,
                "type":     "feature",
                "name":     fname,
                "uid":      fname,          # feature name IS the unique identifier
                "category": aidl_category(fname),
            })
    return records


PROP_RE = re.compile(r"^\[([^\]]+)\]:\s*\[([^\]]*)\]")

def parse_getprop(content: str) -> list[dict]:
    """Return hardware-relevant properties from getprop.txt."""
    records: list[dict] = []
    for line in content.splitlines():
        m = PROP_RE.match(line.strip())
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if any(key.startswith(p) for p in HW_PROP_PREFIXES):
            records.append({"type": "prop", "key": key, "value": val,
                            "uid": key, "category": "system"})
    return records


def parse_lshal(content: str) -> list[dict]:
    """Parse lshal / lshal_full output into HAL records.
    Format varies; we look for lines containing '@' (HIDL) or '/' (AIDL)."""
    records: list[dict] = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # HIDL: android.hardware.foo@1.0::IFoo/default
        # AIDL: android.hardware.foo.IFoo/default
        name = line.split()[0] if line.split() else line
        if "@" in name or (name.count(".") >= 2 and "/" in name):
            base = name.split("@")[0].split("::")[0].split("/")[0]
            cat  = aidl_category(base)
            records.append({
                "source":   "lshal",
                "type":     "lshal",
                "name":     name,
                "uid":      name,           # lshal already prints the full fqname
                "base":     base,
                "category": cat,
            })
    return records


def parse_lsmod(content: str) -> list[dict]:
    """Parse lsmod output."""
    records: list[dict] = []
    for line in content.splitlines():
        parts = line.split()
        if not parts or parts[0] in ("Module", "Name"):
            continue
        mod_name = parts[0]
        size     = parts[1] if len(parts) > 1 else ""
        used_by  = parts[3] if len(parts) > 3 else ""
        records.append({
            "type":     "kmodule",
            "name":     mod_name,
            "uid":      mod_name,           # module name is the kernel-level unique ID
            "size":     size,
            "used_by":  used_by,
            "category": module_category(mod_name),
        })
    return records


# ── Scanner orchestration ─────────────────────────────────────────────────────

def scan(reader: DumpReader) -> dict[str, list[dict]]:
    """Run all scanners; return findings grouped by category."""
    all_records: list[dict] = []

    # 1. VINTF manifests
    for rel_dir in ("system/etc/vintf", "vendor/etc/vintf", "odm/etc/vintf"):
        for rel_path, content in reader.glob_xml(rel_dir):
            all_records.extend(parse_vintf_xml(rel_path, content))

    # 2. ComponentTypeSet / audio policy engine XMLs
    for rel_dir in ("vendor/etc/audio", "system/etc/audio", "vendor/etc"):
        for rel_path, content in reader.glob_xml(rel_dir):
            recs = parse_component_type_set(rel_path, content)
            if recs:
                all_records.extend(recs)

    # 3. Sysconfig / permissions
    for rel_dir in ("system/etc/sysconfig", "system/etc/permissions",
                    "vendor/etc/sysconfig", "vendor/etc/permissions"):
        for rel_path, content in reader.glob_xml(rel_dir):
            all_records.extend(parse_sysconfig_features(rel_path, content))

    # 4. getprop
    gp = reader.read_text("getprop.txt")
    if gp:
        all_records.extend(parse_getprop(gp))

    # 5. lshal / lshal_full
    for fname in ("lshal.txt", "lshal_full.txt"):
        content = reader.read_text(fname)
        if content and "command not found" not in content:
            all_records.extend(parse_lshal(content))

    # 6. lsmod
    lsmod = reader.read_text("lsmod.txt")
    if lsmod:
        all_records.extend(parse_lsmod(lsmod))

    # Group by category
    grouped: dict[str, list[dict]] = {}
    for rec in all_records:
        cat = rec.get("category", "unknown")
        grouped.setdefault(cat, []).append(rec)

    return grouped


# ── Reporting ─────────────────────────────────────────────────────────────────

_CATEGORY_ORDER = [
    "audio", "bluetooth", "camera", "display", "modem", "wifi",
    "sensors", "gps", "nfc", "usb", "vibrator", "input", "touchscreen",
    "power", "thermal", "health", "codec", "security", "keymaster",
    "gatekeeper", "weaver", "se", "biometrics", "tpu", "charger",
    "battery", "oemlock", "memtrack", "nnapi", "drm", "dumpstate",
    "boot", "contexthub", "lights", "google_hw", "system", "unknown",
]


def _dedup(records: list[dict]) -> list[dict]:
    seen: set[str] = set()
    out:  list[dict] = []
    for r in records:
        key = f"{r.get('type')}|{r.get('name')}|{r.get('instance','')}"
        if key not in seen:
            seen.add(key)
            out.append(r)
    return out


def print_report(grouped: dict[str, list[dict]],
                 filter_cat: str | None) -> None:
    cats = _CATEGORY_ORDER + sorted(set(grouped) - set(_CATEGORY_ORDER))
    for cat in cats:
        if cat not in grouped:
            continue
        if filter_cat and cat != filter_cat:
            continue
        records = _dedup(grouped[cat])
        print(f"\n{'━' * 70}")
        print(f"  CATEGORY: {cat.upper()}  ({len(records)} items)")
        print(f"{'━' * 70}")

        by_type: dict[str, list[dict]] = {}
        for r in records:
            by_type.setdefault(r["type"], []).append(r)

        for rtype, recs in sorted(by_type.items()):
            print(f"\n  [{rtype}]")
            for r in recs:
                uid = r.get("uid", "")
                if rtype == "hal":
                    src = r.get("source", "")
                    # uid is the full canonical identifier — print it first
                    print(f"    uid  : {uid}")
                    print(f"    fmt  : {r['format']}  name: {r['name']}"
                          + (f"  ver: {r['version']}" if r.get("version") else ""))
                    if r.get("instance") and r["instance"] != "(no instance)":
                        print(f"    inst : {r['instance']}")
                    if src:
                        print(f"    src  : {src}")
                    print()
                elif rtype == "audio_strategy":
                    sid  = r.get("id")
                    kind = r.get("kind", "")
                    print(f"    uid  : {uid}  name: {r['name']}  [{kind}]")
                elif rtype == "feature":
                    print(f"    uid  : {uid}")
                elif rtype == "prop":
                    print(f"    uid  : {uid}  =  {r['value']}")
                elif rtype == "lshal":
                    print(f"    uid  : {uid}")
                elif rtype == "kmodule":
                    used = f"  used_by={r['used_by']}" if r.get("used_by") else ""
                    print(f"    uid  : {uid}  size={r['size']}{used}")


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Read-only scanner for hardware-group named components in a dump."
    )
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--dump", metavar="DIR",
                     help="Path to an extracted dump directory (live_dump/)")
    src.add_argument("--zip",  metavar="ZIP",
                     help="Path to a live_dump.zip archive")
    ap.add_argument("--category", metavar="CAT",
                    help="Filter output to a single hardware category (e.g. audio)")
    ap.add_argument("--json", action="store_true",
                    help="Emit JSON instead of a human-readable report")
    args = ap.parse_args()

    dump_path = Path(args.dump) if args.dump else None
    zip_path  = Path(args.zip)  if args.zip  else None

    if dump_path and not dump_path.is_dir():
        ap.error(f"--dump path does not exist or is not a directory: {dump_path}")
    if zip_path and not zip_path.is_file():
        ap.error(f"--zip path does not exist: {zip_path}")

    reader  = DumpReader(dump_path, zip_path)
    grouped = scan(reader)
    reader.close()

    if args.json:
        # Flatten to a list for JSON output
        flat: list[dict] = []
        for cat, recs in sorted(grouped.items()):
            for r in _dedup(recs):
                flat.append(r)
        print(json.dumps(flat, indent=2))
    else:
        total = sum(len(_dedup(v)) for v in grouped.values())
        cat_filter = args.category.lower() if args.category else None
        print(f"scan_hw_names — {total} items found across {len(grouped)} categories")
        print_report(grouped, cat_filter)


if __name__ == "__main__":
    main()
