#!/usr/bin/env python3
"""
pipeline/build_table.py
=======================
Orchestrates all parsers to build the hardware_map SQLite database from
a dump directory collected by Mode A, B, or C.

Steps:
  1. Create/verify the DB schema
  2. Insert a collection_run row
  3. Run parse_symbols   (vendor .so nm output)
  4. Run parse_pinctrl   (/sys/kernel/debug/pinctrl)
  5. Run parse_manifests (VINTF / sysconfig XMLs, getprop)
  6. Parse /proc/iomem, /proc/interrupts, lsmod
  7. Walk the device tree nodes from /proc/device-tree
  8. Parse Mode C shim JSONL logs (if present)
  9. Update hardware_block.filled_fields / total_fields scores
 10. Register all collected files in the collected_file table

Usage:
  python pipeline/build_table.py \\
      --db hardware_map.sqlite \\
      --dump /path/to/live_dump \\
      --mode A              # A | B | C

After this completes, run:
  python pipeline/report.py --db hardware_map.sqlite
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path


# ── Schema path ──────────────────────────────────────────────────────────────
HERE = Path(__file__).parent
SCHEMA = HERE.parent / "schema" / "hardware_map.sql"


# ── Helpers ──────────────────────────────────────────────────────────────────

def apply_schema(db: sqlite3.Connection) -> None:
    if SCHEMA.exists():
        db.executescript(SCHEMA.read_text())


def run_submodule(script: Path, extra_args: list[str]) -> None:
    """Run a pipeline sub-script via subprocess."""
    cmd = [sys.executable, str(script)] + extra_args
    print(f"  → {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=False)
    if result.returncode != 0:
        print(f"  warn: {script.name} exited with code {result.returncode}",
              file=sys.stderr)


def read_file(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


# ── /proc/iomem parser ───────────────────────────────────────────────────────
# Format: "00000000-00000fff : Reserved"

IOMEM_RE = re.compile(r"([0-9a-f]+)-([0-9a-f]+)\s*:\s*(.+)", re.IGNORECASE)


def import_iomem(cur: sqlite3.Cursor, run_id: int, dump: Path) -> int:
    text = read_file(dump / "proc" / "iomem")
    if not text:
        return 0
    inserted = 0
    for line in text.splitlines():
        m = IOMEM_RE.search(line)
        if not m:
            continue
        cur.execute(
            """INSERT INTO iomem_region (run_id, start_hex, end_hex, name)
               VALUES (?,?,?,?)""",
            (run_id, m.group(1), m.group(2), m.group(3).strip()),
        )
        inserted += 1
    return inserted


# ── /proc/interrupts parser ──────────────────────────────────────────────────
# Header: " CPU0  CPU1 ..."
# Data:   "  42: 12345 67890 ...  driver_name"

def import_interrupts(cur: sqlite3.Cursor, run_id: int, dump: Path) -> int:
    text = read_file(dump / "proc" / "interrupts")
    if not text:
        return 0
    inserted = 0
    lines = text.splitlines()
    for line in lines[1:]:  # skip header
        parts = line.split()
        if len(parts) < 2:
            continue
        irq_str = parts[0].rstrip(":")
        if not irq_str.isdigit():
            continue
        irq_num = int(irq_str)
        # Count columns until we hit a non-digit token
        counts = []
        name_parts = []
        for p in parts[1:]:
            if p.isdigit():
                counts.append(int(p))
            else:
                name_parts.append(p)
        name = " ".join(name_parts)
        total = sum(counts)
        try:
            cur.execute(
                """INSERT OR IGNORE INTO irq_entry
                   (run_id, irq_num, count, cpu_counts, name)
                   VALUES (?,?,?,?,?)""",
                (run_id, irq_num, total, json.dumps(counts), name),
            )
            inserted += cur.rowcount
        except sqlite3.Error:
            pass
    return inserted


# ── lsmod parser ────────────────────────────────────────────────────────────
# Format: "module_name  size  use_count  [used_by, ...]"

def import_lsmod(cur: sqlite3.Cursor, run_id: int, dump: Path) -> int:
    text = read_file(dump / "lsmod.txt")
    if not text:
        return 0
    inserted = 0
    for line in text.splitlines()[1:]:  # skip header
        parts = line.split()
        if len(parts) < 3:
            continue
        name = parts[0]
        size = int(parts[1]) if parts[1].isdigit() else 0
        use_count = int(parts[2]) if parts[2].isdigit() else 0
        used_by = parts[3] if len(parts) > 3 else ""
        try:
            cur.execute(
                """INSERT OR IGNORE INTO kernel_module
                   (run_id, name, size, use_count, used_by)
                   VALUES (?,?,?,?,?)""",
                (run_id, name, size, use_count, used_by),
            )
            inserted += cur.rowcount
        except sqlite3.Error:
            pass
    return inserted


# ── /proc/device-tree walker ─────────────────────────────────────────────────
# Each virtual file under /proc/device-tree is a binary blob; we only
# read the 'compatible' and 'reg' files as they contain ASCII / integers.

DT_HW_HINTS: list[tuple[str, tuple[str, str]]] = [
    ("mdss",       ("display",  "display")),
    ("dsi@",       ("display",  "display")),
    ("qcom,dp",    ("display",  "display")),
    ("camera",     ("camera",   "imaging")),
    ("qcom,cam",   ("camera",   "imaging")),
    ("audio",      ("audio",    "audio")),
    ("sound",      ("audio",    "audio")),
    ("sensors",    ("sensors",  "sensor")),
    ("qcom,gnss",  ("gps",      "sensor")),
    ("bluetooth",  ("bluetooth","misc")),
    ("wcnss",      ("bluetooth","misc")),
    ("wifi",       ("wifi",     "misc")),
    ("qcom,wcn",   ("wifi",     "misc")),
    ("thermal",    ("thermal",  "thermal")),
    ("qcom,pmic",  ("power",    "power")),
    ("usb@",       ("usb",      "misc")),
    ("nfc",        ("nfc",      "misc")),
    ("fingerprint",("fingerprint","input")),
    ("gpio",       ("gpio",     "misc")),
    ("i2c@",       ("misc",     "misc")),
    ("spi@",       ("misc",     "misc")),
]


def dt_to_hw(path_lower: str, compat: str) -> tuple[str, str] | None:
    for frag, hw in DT_HW_HINTS:
        if frag in path_lower or frag in compat.lower():
            return hw
    return None


def import_dt_nodes(cur: sqlite3.Cursor, run_id: int, dump: Path) -> int:
    dt_root = dump / "proc" / "device-tree"
    if not dt_root.exists():
        return 0
    inserted = 0

    def _read_dt_file(p: Path) -> str:
        try:
            raw = p.read_bytes()
            return raw.decode("utf-8", errors="replace").rstrip("\x00").strip()
        except OSError:
            return ""

    def _walk(node_dir: Path, node_path: str) -> None:
        nonlocal inserted
        if not node_dir.is_dir():
            return

        compatible = _read_dt_file(node_dir / "compatible")
        reg = _read_dt_file(node_dir / "reg")
        interrupts = _read_dt_file(node_dir / "interrupts")
        clocks = _read_dt_file(node_dir / "clocks")

        if compatible or reg:
            hw_info = dt_to_hw(node_path.lower(), compatible)
            hw_id: int | None = None
            if hw_info:
                cur.execute(
                    "SELECT hw_id FROM hardware_block WHERE run_id=? AND name=?",
                    (run_id, hw_info[0]),
                )
                row = cur.fetchone()
                if row:
                    hw_id = row[0]
                else:
                    cur.execute(
                        """INSERT INTO hardware_block (run_id, name, category)
                           VALUES (?,?,?)""",
                        (run_id, hw_info[0], hw_info[1]),
                    )
                    hw_id = cur.lastrowid

            try:
                cur.execute(
                    """INSERT OR IGNORE INTO dt_node
                       (run_id, path, compatible, reg, interrupts, clocks, hw_id)
                       VALUES (?,?,?,?,?,?,?)""",
                    (run_id, node_path, compatible[:512] if compatible else None,
                     reg[:256] if reg else None,
                     interrupts[:256] if interrupts else None,
                     clocks[:256] if clocks else None,
                     hw_id),
                )
                inserted += cur.rowcount
            except sqlite3.Error:
                pass

        for child in sorted(node_dir.iterdir()):
            if child.is_dir():
                _walk(child, f"{node_path}/{child.name}")

    _walk(dt_root, "")
    return inserted


# ── Mode C JSONL shim log parser ─────────────────────────────────────────────

def import_shim_log(cur: sqlite3.Cursor, run_id: int,
                    log_path: Path) -> int:
    if not log_path.exists():
        return 0
    inserted = 0
    ioctl_cache: dict[str, int] = {}

    def get_or_create_ioctl(code_hex: str, detail: str) -> int | None:
        if code_hex in ioctl_cache:
            return ioctl_cache[code_hex]
        # Decode direction and size from the code
        try:
            code = int(code_hex, 16)
        except ValueError:
            return None
        dir_bits = (code >> 30) & 0x3
        size = (code >> 16) & 0x3FFF
        dir_map = {0: "NONE", 1: "WRITE", 2: "READ", 3: "READWRITE"}
        direction = dir_map.get(dir_bits, "NONE")

        # Extract fd_path from detail string
        driver = ""
        m = re.search(r"fd_path=(\S+)", detail)
        if m:
            driver = m.group(1)

        cur.execute(
            """INSERT OR IGNORE INTO ioctl_code
               (run_id, code_hex, direction, buf_size, driver_name)
               VALUES (?,?,?,?,?)""",
            (run_id, code_hex, direction, size, driver),
        )
        cur.execute(
            "SELECT ioctl_id FROM ioctl_code WHERE run_id=? AND code_hex=?",
            (run_id, code_hex),
        )
        row = cur.fetchone()
        ioctl_id: int | None = row[0] if row else None
        if ioctl_id:
            ioctl_cache[code_hex] = ioctl_id
        return ioctl_id

    with log_path.open(errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue

            layer   = rec.get("layer", "linux")
            event   = rec.get("event", "")
            idx     = rec.get("idx", 0)
            ts_ns   = rec.get("ts_ns", 0)
            ret_val = str(rec.get("ret", ""))

            ioctl_id: int | None = None
            if event == "ioctl":
                detail = rec.get("detail", "")
                code_hex = rec.get("code", "0x0")
                ioctl_id = get_or_create_ioctl(code_hex, detail)

                # Extract buf hex from detail
                buf_hex = ""
                m = re.search(r"buf=([0-9a-fA-F]+)", detail)
                if m:
                    buf_hex = m.group(1)

                try:
                    cur.execute(
                        """INSERT INTO call_sequence
                           (run_id, order_idx, layer, ioctl_id,
                            buf_hex, return_value, timestamp_ns)
                           VALUES (?,?,?,?,?,?,?)""",
                        (run_id, idx, layer, ioctl_id,
                         buf_hex or None, ret_val, ts_ns),
                    )
                    inserted += 1
                except sqlite3.Error:
                    pass

            elif event == "hw_get_module":
                android_fn = rec.get("id", "")
                try:
                    cur.execute(
                        """INSERT INTO call_sequence
                           (run_id, order_idx, layer, android_fn,
                            return_value, timestamp_ns)
                           VALUES (?,?,?,?,?,?)""",
                        (run_id, idx, "android", android_fn, ret_val, ts_ns),
                    )
                    inserted += 1
                except sqlite3.Error:
                    pass

            elif event in ("open", "openat"):
                path_str = rec.get("path", "")
                try:
                    cur.execute(
                        """INSERT INTO call_sequence
                           (run_id, order_idx, layer, android_fn,
                            return_value, timestamp_ns)
                           VALUES (?,?,?,?,?,?)""",
                        (run_id, idx, "linux", f"open:{path_str}",
                         ret_val, ts_ns),
                    )
                    inserted += 1
                except sqlite3.Error:
                    pass

    return inserted


# ── Collected-file index ──────────────────────────────────────────────────────

def index_files(cur: sqlite3.Cursor, run_id: int,
                dump: Path, manifest_path: Path) -> int:
    if not manifest_path.exists():
        return 0
    inserted = 0
    for line in manifest_path.read_text(errors="replace").splitlines():
        src = line.strip()
        if not src:
            continue
        local = str(dump / src.lstrip("/"))
        p = Path(local)
        size: int | None = None
        sha256: str | None = None
        if p.exists():
            size = p.stat().st_size
        try:
            cur.execute(
                """INSERT OR IGNORE INTO collected_file
                   (run_id, src_path, local_path, sha256, size_bytes)
                   VALUES (?,?,?,?,?)""",
                (run_id, src, local, sha256, size),
            )
            inserted += cur.rowcount
        except sqlite3.Error:
            pass
    return inserted


# ── Fill-rate scoring ─────────────────────────────────────────────────────────
# For each hardware_block, count how many key relational fields are populated
# and set filled_fields / total_fields accordingly.

FIELD_CHECKS: list[tuple[str, str, str]] = [
    # (table, join_col, description)
    ("symbol",        "hw_id", "has_symbols"),
    ("vintf_hal",     "hw_id", "has_hal"),
    ("pinctrl_group", "hw_id", "has_pinctrl"),
    ("ioctl_code",    "hw_id", "has_ioctl"),
    ("call_sequence", "hw_id", "has_call_seq"),
    ("dt_node",       "hw_id", "has_dt_node"),
    ("iomem_region",  "hw_id", "has_iomem"),
    ("irq_entry",     "hw_id", "has_irq"),
    ("kernel_module", "hw_id", "has_module"),
]


def update_fill_rates(db: sqlite3.Connection, run_id: int) -> None:
    cur = db.cursor()
    cur.execute(
        "SELECT hw_id FROM hardware_block WHERE run_id=?", (run_id,)
    )
    hw_ids = [row[0] for row in cur.fetchall()]

    total_fields = len(FIELD_CHECKS) + 1  # +1 for hal_interface

    # Pre-validate all table/column names against a strict whitelist so that
    # FIELD_CHECKS entries can never be used for SQL injection, even if the
    # constant is accidentally modified in future.
    _VALID_IDENT = re.compile(r'^[a-z_][a-z0-9_]*$')
    for table, col, _ in FIELD_CHECKS:
        if not _VALID_IDENT.match(table) or not _VALID_IDENT.match(col):
            raise ValueError(f"Unexpected table/column identifier: {table!r}.{col!r}")

    for hw_id in hw_ids:
        filled = 0

        # Check hal_interface text field
        cur.execute(
            "SELECT hal_interface FROM hardware_block WHERE hw_id=?", (hw_id,)
        )
        row = cur.fetchone()
        if row and row[0]:
            filled += 1

        # Check related-table presence (identifiers validated above)
        for table, col, _ in FIELD_CHECKS:
            try:
                cur.execute(
                    f"SELECT 1 FROM {table} WHERE {col}=? LIMIT 1",  # noqa: S608
                    (hw_id,),
                )
                if cur.fetchone():
                    filled += 1
            except sqlite3.OperationalError:
                pass

        cur.execute(
            """UPDATE hardware_block
               SET total_fields=?, filled_fields=?
               WHERE hw_id=?""",
            (total_fields, filled, hw_id),
        )

    db.commit()


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Build hardware_map.sqlite from a dump directory")
    ap.add_argument("--db",     required=True, help="Path to (or new) hardware_map.sqlite")
    ap.add_argument("--dump",   required=True, help="Root of the collection dump directory")
    ap.add_argument("--mode",   required=True, choices=["A", "B", "C"],
                    help="Collection mode: A=live, B=recovery, C=shim")
    ap.add_argument("--shim-log", default=None,
                    help="Path to Mode C shim JSONL log (default: <dump>/hom_shim.jsonl)")
    args = ap.parse_args()

    dump   = Path(args.dump)
    db_path = Path(args.db)

    print(f"Building {db_path} from {dump} (mode {args.mode})")

    db = sqlite3.connect(str(db_path))
    apply_schema(db)

    # 1. Create collection_run row
    cur = db.cursor()
    cur.execute(
        """INSERT INTO collection_run (mode, source_dir) VALUES (?,?)""",
        (args.mode, str(dump)),
    )
    run_id: int = cur.lastrowid  # type: ignore[assignment]
    db.commit()
    print(f"  run_id = {run_id}")

    # 2. Sub-module parsers
    base_args = ["--db", str(db_path), "--dump", str(dump), "--run-id", str(run_id)]

    print("\n[1/3] Parsing symbols...")
    run_submodule(HERE / "parse_symbols.py", base_args)

    print("\n[2/3] Parsing pinctrl...")
    run_submodule(HERE / "parse_pinctrl.py", base_args)

    print("\n[3/3] Parsing manifests & props...")
    run_submodule(HERE / "parse_manifests.py", base_args)

    # 3a. Unpack boot/ramdisk images
    print("\n[3b] Unpacking boot/ramdisk images...")
    run_submodule(HERE / "unpack_images.py", base_args)

    # 3. Direct imports (no sub-module)
    cur = db.cursor()

    print("\n[4] Importing /proc/iomem...")
    n = import_iomem(cur, run_id, dump)
    print(f"    {n} iomem regions")

    print("[5] Importing /proc/interrupts...")
    n = import_interrupts(cur, run_id, dump)
    print(f"    {n} IRQ entries")

    print("[6] Importing lsmod...")
    n = import_lsmod(cur, run_id, dump)
    print(f"    {n} kernel modules")

    print("[7] Walking device-tree nodes...")
    n = import_dt_nodes(cur, run_id, dump)
    print(f"    {n} DT nodes")

    # 4. Mode C shim log
    if args.mode == "C" or args.shim_log:
        shim_log = Path(args.shim_log) if args.shim_log else (dump / "hom_shim.jsonl")
        print(f"\n[8] Importing shim log: {shim_log}...")
        n = import_shim_log(cur, run_id, shim_log)
        print(f"    {n} call sequence events")

    # 5. File index
    manifest_path = dump / "manifest.txt"
    print(f"\n[9] Indexing collected files from {manifest_path}...")
    n = index_files(cur, run_id, dump, manifest_path)
    print(f"    {n} files indexed")

    db.commit()

    # 6. Fill-rate scores
    print("\n[10] Computing hardware fill-rate scores...")
    update_fill_rates(db, run_id)

    db.close()
    print(f"\nDone. Database: {db_path}")
    print("Run: python pipeline/report.py --db", db_path)


if __name__ == "__main__":
    main()
