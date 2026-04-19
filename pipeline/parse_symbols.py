#!/usr/bin/env python3
"""
pipeline/parse_symbols.py
=========================
Parse vendor shared-library symbol tables produced by Mode A/B collection
and insert them into the hardware_map SQLite database.

Reads:
  <dump_dir>/vendor_symbols/*.nm.txt   — output of: nm -D --defined-only <lib>
  <dump_dir>/vendor_elf/*.elf.txt      — output of: readelf -d <lib>

For each symbol:
  - Attempts to demangle C++ names via c++filt
  - Tries to associate the symbol with a hardware_block row based on
    well-known library → hardware-name prefix heuristics.

Usage:
  python pipeline/parse_symbols.py --db hardware_map.sqlite \
      --dump /sdcard/hands-on-metal/boot_work --run-id 1
"""

import argparse
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path


# ── Library → hardware-name heuristics ─────────────────────────────────────
# Maps substrings in the .so filename to a (name, category) tuple that matches
# the hardware_block table.  Ordered from most-specific to least-specific.
LIB_HW_MAP: list[tuple[str, tuple[str, str]]] = [
    ("gralloc",     ("gralloc",     "display")),
    ("hwcomposer",  ("hwcomposer",  "display")),
    ("display",     ("display",     "display")),
    ("mdss",        ("display",     "display")),
    ("camera",      ("camera",      "imaging")),
    ("cam_",        ("camera",      "imaging")),
    ("audio",       ("audio",       "audio")),
    ("sound",       ("audio",       "audio")),
    ("sensors",     ("sensors",     "sensor")),
    ("sensor",      ("sensors",     "sensor")),
    ("gps",         ("gps",         "sensor")),
    ("gnss",        ("gps",         "sensor")),
    ("bluetooth",   ("bluetooth",   "misc")),
    ("bt_",         ("bluetooth",   "misc")),
    ("wifi",        ("wifi",        "misc")),
    ("wlan",        ("wifi",        "misc")),
    ("modem",       ("modem",       "modem")),
    ("ril",         ("modem",       "modem")),
    ("power",       ("power",       "power")),
    ("thermal",     ("thermal",     "thermal")),
    ("vibrator",    ("vibrator",    "input")),
    ("light",       ("lights",      "input")),
    ("fingerprint", ("fingerprint", "input")),
    ("keymaster",   ("keymaster",   "misc")),
    ("drm",         ("drm",         "misc")),
    ("memtrack",    ("memtrack",    "misc")),
    ("nfc",         ("nfc",         "misc")),
    ("usb",         ("usb",         "misc")),
]


def lib_to_hw(library: str) -> tuple[str, str] | None:
    """Return (hw_name, category) for a .so library filename, or None."""
    lower = library.lower()
    for fragment, hw in LIB_HW_MAP:
        if fragment in lower:
            return hw
    return None


# ── c++filt demangling ──────────────────────────────────────────────────────

def demangle_batch(symbols: list[str]) -> list[str]:
    """Run c++filt on a batch of symbols; return demangled list."""
    if not symbols:
        return []
    try:
        proc = subprocess.run(
            ["c++filt"],
            input="\n".join(symbols),
            capture_output=True,
            text=True,
            timeout=30,
        )
        lines = proc.stdout.splitlines()
        # Pad if c++filt returned fewer lines than input
        while len(lines) < len(symbols):
            lines.append(symbols[len(lines)])
        return lines
    except FileNotFoundError:
        return symbols  # c++filt not available; return as-is
    except subprocess.TimeoutExpired:
        return symbols


# ── nm output parser ────────────────────────────────────────────────────────
# Format: [address] type name
# Example: 0000000000001234 T _ZN9MyClass6methodEv
NM_RE = re.compile(
    r"^(?P<addr>[0-9a-fA-F]+|-+)?\s+"
    r"(?P<binding>[a-zA-Z])\s+"
    r"(?P<mangled>\S+)$"
)

# Symbol type letter → (sym_type, binding, section) mapping
SYM_TYPE_MAP: dict[str, tuple[str, str, str]] = {
    "T": ("FUNC",   "GLOBAL", ".text"),
    "t": ("FUNC",   "LOCAL",  ".text"),
    "W": ("FUNC",   "WEAK",   ".text"),
    "w": ("FUNC",   "WEAK",   ".text"),
    "D": ("OBJECT", "GLOBAL", ".data"),
    "d": ("OBJECT", "LOCAL",  ".data"),
    "B": ("OBJECT", "GLOBAL", ".bss"),
    "b": ("OBJECT", "LOCAL",  ".bss"),
    "R": ("OBJECT", "GLOBAL", ".rodata"),
    "r": ("OBJECT", "LOCAL",  ".rodata"),
    "V": ("OBJECT", "WEAK",   ".data"),
    "v": ("OBJECT", "WEAK",   ".data"),
    "U": ("UNDEF",  "GLOBAL", "UND"),
}


def parse_nm_file(nm_path: Path) -> list[dict]:
    """Parse a single .nm.txt file; return list of raw symbol dicts."""
    library = nm_path.stem.removesuffix(".nm")
    records: list[dict] = []
    try:
        text = nm_path.read_text(errors="replace")
    except OSError:
        return records

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = NM_RE.match(line)
        if not m:
            continue
        letter = m.group("binding")
        type_info = SYM_TYPE_MAP.get(letter, ("NOTYPE", "GLOBAL", ""))
        records.append({
            "library": library,
            "address": m.group("addr") or "",
            "mangled": m.group("mangled"),
            "sym_type": type_info[0],
            "binding":  type_info[1],
            "section":  type_info[2],
        })
    return records


# ── Database helpers ────────────────────────────────────────────────────────

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
        """INSERT INTO hardware_block (run_id, name, category)
           VALUES (?, ?, ?)""",
        (run_id, name, category),
    )
    return cur.lastrowid  # type: ignore[return-value]


def insert_symbols(db: sqlite3.Connection, run_id: int,
                   records: list[dict]) -> int:
    """Insert symbol records into DB; return count of inserted rows."""
    cur = db.cursor()
    inserted = 0

    # Group by library so we can batch-demangle per library
    from itertools import groupby
    key_fn = lambda r: r["library"]
    records.sort(key=key_fn)

    for library, group in groupby(records, key=key_fn):
        batch = list(group)
        mangles = [r["mangled"] for r in batch]
        demangled = demangle_batch(mangles)

        hw_info = lib_to_hw(library)
        hw_id: int | None = None
        if hw_info:
            hw_id = get_or_create_hw(cur, run_id, hw_info[0], hw_info[1])

        for rec, dem in zip(batch, demangled):
            try:
                cur.execute(
                    """INSERT OR IGNORE INTO symbol
                       (run_id, hw_id, library, mangled, demangled,
                        sym_type, binding, section, address)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        run_id, hw_id,
                        rec["library"], rec["mangled"], dem,
                        rec["sym_type"], rec["binding"],
                        rec["section"], rec["address"],
                    ),
                )
                inserted += cur.rowcount
            except sqlite3.Error as exc:
                print(f"  warn: insert symbol failed: {exc}", file=sys.stderr)

    db.commit()
    return inserted


# ── Main ────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Parse vendor .so symbols into hardware_map.sqlite")
    ap.add_argument("--db",     required=True, help="Path to hardware_map.sqlite")
    ap.add_argument("--dump",   required=True, help="Root of the collection dump directory")
    ap.add_argument("--run-id", required=True, type=int, dest="run_id",
                    help="collection_run.run_id to associate symbols with")
    args = ap.parse_args()

    dump = Path(args.dump)
    sym_dir = dump / "vendor_symbols"

    if not sym_dir.exists():
        print(f"No vendor_symbols directory found at {sym_dir}", file=sys.stderr)
        sys.exit(1)

    db = sqlite3.connect(args.db)
    # Apply schema if tables don't exist
    schema_path = Path(__file__).parent.parent / "schema" / "hardware_map.sql"
    if schema_path.exists():
        db.executescript(schema_path.read_text())

    nm_files = sorted(sym_dir.glob("*.nm.txt"))
    if not nm_files:
        print("No .nm.txt files found; run Mode A/B collection first.", file=sys.stderr)
        sys.exit(1)

    print(f"Parsing {len(nm_files)} nm files from {sym_dir}...")
    all_records: list[dict] = []
    for f in nm_files:
        recs = parse_nm_file(f)
        print(f"  {f.name}: {len(recs)} symbols")
        all_records.extend(recs)

    print(f"Total symbols parsed: {len(all_records)}")
    n = insert_symbols(db, args.run_id, all_records)
    print(f"Inserted {n} new symbol rows (duplicates skipped).")

    db.close()


if __name__ == "__main__":
    main()
