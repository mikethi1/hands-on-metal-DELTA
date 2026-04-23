#!/usr/bin/env python3
"""
pipeline/parse_manifests.py
===========================
Parse VINTF hardware manifests and sysconfig XMLs captured by Mode A/B
and insert the data into the hardware_map SQLite database.

Reads:
  <dump_dir>/vendor/etc/manifest.xml
  <dump_dir>/vendor/etc/vintf/**/*.xml
  <dump_dir>/system/etc/vintf/**/*.xml
  <dump_dir>/odm/etc/vintf/**/*.xml
  <dump_dir>/vendor/etc/sysconfig/**/*.xml
  <dump_dir>/vendor/etc/permissions/**/*.xml
  <dump_dir>/getprop.txt                    — for board-level props

Output tables:
  vintf_hal, hardware_block, sysconfig_entry, android_prop

Usage:
  python pipeline/parse_manifests.py --db hardware_map.sqlite \
      --dump /sdcard/hands-on-metal/boot_work --run-id 1
"""

import argparse
import os
import re
import sqlite3
import sys
from pathlib import Path
from xml.etree import ElementTree as ET


# ── HAL name → (hw_name, category) heuristics ──────────────────────────────
HAL_HW_MAP: list[tuple[str, tuple[str, str]]] = [
    ("graphics.allocator",  ("gralloc",     "display")),
    ("graphics.composer",   ("hwcomposer",  "display")),
    ("graphics.mapper",     ("gralloc",     "display")),
    ("camera.provider",     ("camera",      "imaging")),
    ("camera.device",       ("camera",      "imaging")),
    ("audio",               ("audio",       "audio")),
    ("sensors",             ("sensors",     "sensor")),
    ("gnss",                ("gps",         "sensor")),
    ("gps",                 ("gps",         "sensor")),
    ("bluetooth",           ("bluetooth",   "misc")),
    ("wifi",                ("wifi",        "misc")),
    ("radio",               ("modem",       "modem")),
    ("thermal",             ("thermal",     "thermal")),
    ("power",               ("power",       "power")),
    ("vibrator",            ("vibrator",    "input")),
    ("light",               ("lights",      "input")),
    ("biometrics",          ("fingerprint", "input")),
    ("nfc",                 ("nfc",         "misc")),
    ("drm",                 ("drm",         "misc")),
    ("usb",                 ("usb",         "misc")),
    ("memtrack",            ("memtrack",    "misc")),
    ("keymaster",           ("keymaster",   "misc")),
    ("health",              ("health",      "power")),
    ("neuralnetworks",      ("nnapi",       "misc")),
    ("contexthub",          ("contexthub",  "sensor")),
]


def hal_to_hw(hal_name: str) -> tuple[str, str] | None:
    lower = hal_name.lower()
    for frag, hw in HAL_HW_MAP:
        if frag in lower:
            return hw
    return None


# ── DB helpers ───────────────────────────────────────────────────────────────

def get_or_create_hw(cur: sqlite3.Cursor, run_id: int,
                     name: str, category: str) -> int:
    cur.execute(
        "SELECT hw_id FROM hardware_block WHERE run_id=? AND name=?",
        (run_id, name),
    )
    row = cur.fetchone()
    if row:
        return row[0]
    cur.execute(
        "INSERT INTO hardware_block (run_id, name, category) VALUES (?,?,?)",
        (run_id, name, category),
    )
    return cur.lastrowid  # type: ignore[return-value]


# ── VINTF manifest parser ────────────────────────────────────────────────────
# Supports both HIDL (<hal format="hidl">) and AIDL (<hal format="aidl">)
# manifest structures.

def _text(el: ET.Element | None) -> str:
    return (el.text or "").strip() if el is not None else ""


def parse_manifest_xml(path: Path, run_id: int,
                       cur: sqlite3.Cursor) -> int:
    """Parse one manifest XML file; return number of HAL entries inserted."""
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        print(f"  warn: XML parse error in {path}: {exc}", file=sys.stderr)
        return 0

    root = tree.getroot()
    inserted = 0

    for hal in root.iter("hal"):
        hal_format = hal.get("format", "hidl")
        hal_name = _text(hal.find("name"))
        if not hal_name:
            continue

        version = _text(hal.find("version"))
        transport_el = hal.find("transport")
        transport = _text(transport_el) if transport_el is not None else ""

        hw_info = hal_to_hw(hal_name)
        hw_id: int | None = None
        if hw_info:
            hw_id = get_or_create_hw(cur, run_id, hw_info[0], hw_info[1])

        # AIDL HALs declare interfaces via <fqname>Interface/instance</fqname>.
        # HIDL HALs use the <interface>/<instance> sub-element structure.
        fqnames = hal.findall("fqname")
        interfaces = hal.findall(".//interface")

        if fqnames:
            # AIDL path: split "IFoo/default" → interface="IFoo", instance="default"
            for fq in fqnames:
                fq_text = _text(fq)
                if "/" in fq_text:
                    iface_name, _, instance = fq_text.partition("/")
                else:
                    iface_name, instance = fq_text, ""
                # Version may also be embedded as "@N" prefix in older manifests
                if fq_text.startswith("@"):
                    parts = fq_text.lstrip("@").split("::", 1)
                    ver_part = parts[0] if parts else ""
                    rest = parts[1] if len(parts) > 1 else ""
                    if "/" in rest:
                        iface_name, _, instance = rest.partition("/")
                    if not version and ver_part:
                        version = ver_part
                try:
                    cur.execute(
                        """INSERT OR IGNORE INTO vintf_hal
                           (run_id, hw_id, hal_format, hal_name, version,
                            interface, instance, transport, source_file)
                           VALUES (?,?,?,?,?,?,?,?,?)""",
                        (run_id, hw_id, hal_format, hal_name, version,
                         iface_name, instance, transport, str(path)),
                    )
                    inserted += cur.rowcount
                except sqlite3.Error:
                    pass
        elif interfaces:
            # HIDL path
            for iface in interfaces:
                iface_name = _text(iface.find("name"))
                for inst in iface.findall("instance"):
                    instance = _text(inst)
                    try:
                        cur.execute(
                            """INSERT OR IGNORE INTO vintf_hal
                               (run_id, hw_id, hal_format, hal_name, version,
                                interface, instance, transport, source_file)
                               VALUES (?,?,?,?,?,?,?,?,?)""",
                            (run_id, hw_id, hal_format, hal_name, version,
                             iface_name, instance, transport, str(path)),
                        )
                        inserted += cur.rowcount
                    except sqlite3.Error:
                        pass
        else:
            # HAL with no interface block (native or minimal)
            try:
                cur.execute(
                    """INSERT OR IGNORE INTO vintf_hal
                       (run_id, hw_id, hal_format, hal_name, version,
                        interface, instance, transport, source_file)
                       VALUES (?,?,?,?,?,?,?,?,?)""",
                    (run_id, hw_id, hal_format, hal_name, version,
                     None, None, transport, str(path)),
                )
                inserted += cur.rowcount
            except sqlite3.Error:
                pass

        # Update hardware_block.hal_interface if not set
        if hw_id and hal_name and version:
            iface_str = f"{hal_name}@{version}" if version else hal_name
            cur.execute(
                """UPDATE hardware_block
                   SET hal_interface = ?
                   WHERE hw_id = ? AND hal_interface IS NULL""",
                (iface_str, hw_id),
            )

    return inserted


# ── Sysconfig / permissions XML parser ──────────────────────────────────────
# These files are flat key-value-like or feature-flag XMLs.
# We store every element tag + its attributes as key=value pairs.

def parse_sysconfig_xml(path: Path, run_id: int,
                        cur: sqlite3.Cursor) -> int:
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        print(f"  warn: XML parse error in {path}: {exc}", file=sys.stderr)
        return 0

    inserted = 0
    for el in tree.getroot().iter():
        for attr_key, attr_val in el.attrib.items():
            key = f"{el.tag}.{attr_key}"
            try:
                cur.execute(
                    """INSERT OR IGNORE INTO sysconfig_entry
                       (run_id, source, key, value) VALUES (?,?,?,?)""",
                    (run_id, str(path), key, attr_val),
                )
                inserted += cur.rowcount
            except sqlite3.Error:
                pass
        if el.text and el.text.strip():
            try:
                cur.execute(
                    """INSERT OR IGNORE INTO sysconfig_entry
                       (run_id, source, key, value) VALUES (?,?,?,?)""",
                    (run_id, str(path), el.tag, el.text.strip()),
                )
                inserted += cur.rowcount
            except sqlite3.Error:
                pass
    return inserted


# ── getprop parser ───────────────────────────────────────────────────────────
PROP_RE = re.compile(r"^\[([^\]]+)\]:\s*\[([^\]]*)\]")

# ── default.prop / build.prop parser (key=value format) ─────────────────────
# Ramdisk prop files (default.prop, prop.default, build.prop) use the plain
# key=value format written by the build system, unlike getprop's [key]:[value].
PROP_KV_RE = re.compile(r"^([^#=\s]+)\s*=\s*(.*)$")


def _get_env_registry_val(key: str) -> str:
    """Return the value of *key* from ~/hands-on-metal/env_registry.sh, or ''."""
    reg = Path.home() / "hands-on-metal" / "env_registry.sh"
    if not reg.exists():
        return ""
    try:
        for line in reg.read_text(errors="replace").splitlines():
            if not line.startswith(key + "="):
                continue
            rest = line[len(key) + 1:]
            if rest.startswith('"'):
                parts = rest.split('"', 2)
                return parts[1] if len(parts) >= 2 else ""
            return rest.split()[0]
    except OSError:
        pass
    return ""


def parse_getprop(path: Path, run_id: int, cur: sqlite3.Cursor) -> int:
    if not path.exists():
        return 0
    inserted = 0
    for line in path.read_text(errors="replace").splitlines():
        m = PROP_RE.match(line.strip())
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        try:
            cur.execute(
                "INSERT OR IGNORE INTO android_prop (run_id, key, value) VALUES (?,?,?)",
                (run_id, key, val),
            )
            inserted += cur.rowcount
        except sqlite3.Error:
            pass
    return inserted


def parse_default_prop(path: Path, run_id: int, cur: sqlite3.Cursor) -> int:
    """Parse a ramdisk key=value prop file (default.prop, build.prop, etc.).

    Complements parse_getprop() which handles the [key]:[value] format from
    'getprop' output.  Ramdisk prop files use the simpler key=value format
    written by the Android build system.
    """
    if not path.exists():
        return 0
    inserted = 0
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = PROP_KV_RE.match(line)
        if not m:
            continue
        key, val = m.group(1).strip(), m.group(2).strip()
        try:
            cur.execute(
                "INSERT OR IGNORE INTO android_prop (run_id, key, value) VALUES (?,?,?)",
                (run_id, key, val),
            )
            inserted += cur.rowcount
        except sqlite3.Error:
            pass
    return inserted




def parse_board_summary(path: Path, run_id: int,
                        cur: sqlite3.Cursor, db: sqlite3.Connection) -> None:
    if not path.exists():
        return
    props: dict[str, str] = {}
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            props[k.strip()] = v.strip()

    cur.execute(
        """UPDATE collection_run SET
           ro_board    = COALESCE(ro_board,    ?),
           ro_platform = COALESCE(ro_platform, ?),
           ro_hardware = COALESCE(ro_hardware, ?),
           device_model= COALESCE(device_model,?)
           WHERE run_id = ?""",
        (
            props.get("ro.product.board"),
            props.get("ro.board.platform"),
            props.get("ro.hardware"),
            props.get("ro.product.model"),
            run_id,
        ),
    )


# ── Main ─────────────────────────────────────────────────────────────────────

def _find_xmls(dump: Path, rel_pattern: str) -> list[Path]:
    """Glob for XML files under dump matching a relative pattern."""
    return sorted(dump.glob(rel_pattern))


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Parse VINTF manifests and sysconfig into hardware_map.sqlite"
    )
    ap.add_argument("--db",     required=True)
    ap.add_argument("--dump",   required=True)
    ap.add_argument("--run-id", required=True, type=int, dest="run_id")
    args = ap.parse_args()

    dump = Path(args.dump)

    db = sqlite3.connect(args.db)
    schema = Path(__file__).parent.parent / "schema" / "hardware_map.sql"
    if schema.exists():
        db.executescript(schema.read_text())

    cur = db.cursor()

    # 1. Getprop
    gp_path = dump / "getprop.txt"
    getprop_total = parse_getprop(gp_path, args.run_id, cur)
    print(f"getprop: {getprop_total} properties inserted")

    # 2. Board summary
    parse_board_summary(dump / "board_summary.txt", args.run_id, cur, db)

    # 2b. Ramdisk prop files (default.prop, prop.default, build.prop) written
    #     by pipeline/unpack_images.py (option 10) into HOM_RAMDISK_DIR.
    #     These use the key=value build-system format rather than getprop's
    #     [key]:[value] format, so they need the separate parse_default_prop().
    ramdisk_dir_str = (
        os.environ.get("HOM_RAMDISK_DIR")
        or _get_env_registry_val("HOM_RAMDISK_DIR")
    )
    ramdisk_prop_total = 0
    if ramdisk_dir_str:
        ramdisk_dir = Path(ramdisk_dir_str)
        if ramdisk_dir.is_dir():
            for prop_name in ("default.prop", "prop.default", "build.prop"):
                for prop_path in sorted(ramdisk_dir.rglob(prop_name)):
                    n = parse_default_prop(prop_path, args.run_id, cur)
                    if n:
                        print(f"  ramdisk prop {prop_path.name}: {n} properties")
                    ramdisk_prop_total += n
    if ramdisk_prop_total:
        print(f"Ramdisk props: {ramdisk_prop_total} properties from ramdisk extraction")
    elif ramdisk_dir_str:
        print("Ramdisk props: 0 (HOM_RAMDISK_DIR set but no prop files found)")
    else:
        print("Ramdisk props: skipped (HOM_RAMDISK_DIR not set — run unpack_images.py first)")

    # 3. VINTF manifests
    manifest_patterns = [
        "**/manifest.xml",
        "**/vintf/**/*.xml",
        "**/compatibility_matrix*.xml",
    ]
    vintf_total = 0
    seen: set[Path] = set()
    for pat in manifest_patterns:
        for xml_path in dump.glob(pat):
            if xml_path in seen:
                continue
            seen.add(xml_path)
            n = parse_manifest_xml(xml_path, args.run_id, cur)
            if n:
                print(f"  manifest {xml_path.name}: {n} HAL entries")
            vintf_total += n
    print(f"VINTF total: {vintf_total} entries")

    # 4. Sysconfig / permissions XMLs
    sc_patterns = [
        "**/sysconfig/**/*.xml",
        "**/permissions/**/*.xml",
    ]
    sc_total = 0
    sc_seen: set[Path] = set()
    for pat in sc_patterns:
        for xml_path in dump.glob(pat):
            if xml_path in sc_seen:
                continue
            sc_seen.add(xml_path)
            n = parse_sysconfig_xml(xml_path, args.run_id, cur)
            sc_total += n
    print(f"Sysconfig/permissions: {sc_total} entries")

    if getprop_total == 0 and vintf_total == 0 and sc_total == 0 and ramdisk_prop_total == 0:
        print(
            "error: parser found no getprop/manifests/sysconfig data "
            f"under dump path: {dump}",
            file=sys.stderr,
        )
        print(
            "hint: run collection first and pass --dump to the directory that "
            "contains getprop.txt and vendor/system XML trees",
            file=sys.stderr,
        )
        db.close()
        sys.exit(1)

    db.commit()
    db.close()
    print("Manifest/sysconfig import complete.")


if __name__ == "__main__":
    main()
