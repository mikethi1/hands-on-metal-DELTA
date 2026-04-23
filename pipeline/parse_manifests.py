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
      --dump /sdcard/hands-on-metal/live_dump --run-id 1
"""

import argparse
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

        # Each <interface> under the HAL
        interfaces = hal.findall(".//interface")
        if not interfaces:
            # HAL with no interface block (native)
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
        else:
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


# ── Board summary parser ─────────────────────────────────────────────────────

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
    n = parse_getprop(gp_path, args.run_id, cur)
    print(f"getprop: {n} properties inserted")

    # 2. Board summary
    parse_board_summary(dump / "board_summary.txt", args.run_id, cur, db)

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

    db.commit()
    db.close()
    print("Manifest/sysconfig import complete.")


if __name__ == "__main__":
    main()
