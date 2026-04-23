#!/usr/bin/env python3
"""
pipeline/parse_pinctrl.py
=========================
Parse the /sys/kernel/debug/pinctrl sysfs tree captured by Mode A/B
and insert pin controller, pin, and group data into the SQLite DB.

Reads:
  <dump_dir>/sys/kernel/debug/pinctrl/<controller>/
    pins               — list of pins (pin N: gpio<name>)
    pingroups          — list of groups and their pins
    pinmux-functions   — list of mux functions per group
    pinmux-pins        — current mux assignment per pin
    gpio-ranges        — GPIO range info

Output tables:
  pinctrl_controller, pinctrl_pin, pinctrl_group, pinctrl_group_pin

Usage:
  python pipeline/parse_pinctrl.py --db hardware_map.sqlite \
      --dump /sdcard/hands-on-metal/live_dump --run-id 1
"""

import argparse
import re
import sqlite3
import sys
from pathlib import Path


# ── Heuristics: group name → hardware block ─────────────────────────────────
# If a pinctrl group name contains one of these fragments, associate it with
# the corresponding hardware block.
GROUP_HW_HINTS: list[tuple[str, tuple[str, str]]] = [
    ("mdss",        ("display",     "display")),
    ("dsi",         ("display",     "display")),
    ("dp_",         ("display",     "display")),
    ("cam",         ("camera",      "imaging")),
    ("csi",         ("camera",      "imaging")),
    ("mclk",        ("camera",      "imaging")),
    ("audio",       ("audio",       "audio")),
    ("mi2s",        ("audio",       "audio")),
    ("tdm",         ("audio",       "audio")),
    ("uart",        ("modem",       "modem")),
    ("qup",         ("misc",        "misc")),
    ("spi",         ("misc",        "misc")),
    ("i2c",         ("misc",        "misc")),
    ("usb",         ("usb",         "misc")),
    ("bt",          ("bluetooth",   "misc")),
    ("wlan",        ("wifi",        "misc")),
    ("wifi",        ("wifi",        "misc")),
    ("gps",         ("gps",         "sensor")),
    ("gnss",        ("gps",         "sensor")),
    ("nfc",         ("nfc",         "misc")),
    ("finger",      ("fingerprint", "input")),
    ("ts_",         ("touchscreen", "input")),
    ("touch",       ("touchscreen", "input")),
    ("vibr",        ("vibrator",    "input")),
    ("led",         ("lights",      "input")),
]


def group_to_hw(grp_name: str) -> tuple[str, str] | None:
    lower = grp_name.lower()
    for frag, hw in GROUP_HW_HINTS:
        if frag in lower:
            return hw
    return None


# ── Parsers ─────────────────────────────────────────────────────────────────

# "pin 42 (gpio42)" or "pin 42 (PA7)" etc.
PINS_RE = re.compile(r"pin\s+(\d+)\s+\(([^)]+)\)")

# "group: cam_sensor_mclk0\n pins: 1 2 3"
PINGROUPS_RE = re.compile(
    r"group:\s*(\S+).*?pins:\s*([\d\s]+)",
    re.DOTALL,
)

# "pin 42 (gpio42): <function> <group>"
PINMUX_PINS_RE = re.compile(
    r"pin\s+(\d+)\s+\([^)]*\):\s*(\S+)"
)


def parse_pins(text: str) -> dict[int, str]:
    """Return {pin_num: gpio_name} from the 'pins' file."""
    result: dict[int, str] = {}
    for m in PINS_RE.finditer(text):
        result[int(m.group(1))] = m.group(2)
    return result


def parse_pingroups(text: str) -> dict[str, list[int]]:
    """Return {group_name: [pin_num, ...]} from the 'pingroups' file."""
    result: dict[str, list[int]] = {}
    for m in PINGROUPS_RE.finditer(text):
        grp = m.group(1).strip()
        pins = [int(p) for p in m.group(2).split() if p.strip().isdigit()]
        result[grp] = pins
    return result


def parse_pinmux_pins(text: str) -> dict[int, str]:
    """Return {pin_num: function} from the 'pinmux-pins' file."""
    result: dict[int, str] = {}
    for m in PINMUX_PINS_RE.finditer(text):
        result[int(m.group(1))] = m.group(2)
    return result


def read_file(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


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


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Parse pinctrl sysfs into hardware_map.sqlite")
    ap.add_argument("--db",     required=True)
    ap.add_argument("--dump",   required=True)
    ap.add_argument("--run-id", required=True, type=int, dest="run_id")
    args = ap.parse_args()

    dump = Path(args.dump)
    pinctrl_root = dump / "sys" / "kernel" / "debug" / "pinctrl"

    if not pinctrl_root.exists():
        print(f"pinctrl directory not found: {pinctrl_root}", file=sys.stderr)
        sys.exit(1)

    db = sqlite3.connect(args.db)
    schema = Path(__file__).parent.parent / "schema" / "hardware_map.sql"
    if schema.exists():
        db.executescript(schema.read_text())

    cur = db.cursor()

    controllers = [d for d in pinctrl_root.iterdir() if d.is_dir()]
    print(f"Found {len(controllers)} pinctrl controller(s)")

    for ctrl_dir in sorted(controllers):
        ctrl_name = ctrl_dir.name
        print(f"  Processing controller: {ctrl_name}")

        # Dev name from the 'gpio-ranges' or the dir name
        dev_name = ctrl_name

        cur.execute(
            """INSERT OR IGNORE INTO pinctrl_controller (run_id, name, dev_name)
               VALUES (?,?,?)""",
            (args.run_id, ctrl_name, dev_name),
        )
        cur.execute(
            "SELECT ctrl_id FROM pinctrl_controller WHERE run_id=? AND name=?",
            (args.run_id, ctrl_name),
        )
        ctrl_id: int = cur.fetchone()[0]

        # Parse pins
        pins_text = read_file(ctrl_dir / "pins")
        pin_map = parse_pins(pins_text)          # {pin_num: gpio_name}

        # Parse pinmux to get current function per pin
        pinmux_text = read_file(ctrl_dir / "pinmux-pins")
        func_map = parse_pinmux_pins(pinmux_text)  # {pin_num: function}

        # Insert pins
        pin_db_ids: dict[int, int] = {}
        for pin_num, gpio_name in pin_map.items():
            function = func_map.get(pin_num)
            cur.execute(
                """INSERT OR IGNORE INTO pinctrl_pin
                   (ctrl_id, pin_num, gpio_name, function)
                   VALUES (?,?,?,?)""",
                (ctrl_id, pin_num, gpio_name, function),
            )
            cur.execute(
                "SELECT pin_id FROM pinctrl_pin WHERE ctrl_id=? AND pin_num=?",
                (ctrl_id, pin_num),
            )
            row = cur.fetchone()
            if row:
                pin_db_ids[pin_num] = row[0]

        print(f"    {len(pin_map)} pins")

        # Parse groups
        groups_text = read_file(ctrl_dir / "pingroups")
        group_map = parse_pingroups(groups_text)  # {grp_name: [pin_nums]}

        for grp_name, pin_nums in group_map.items():
            hw_info = group_to_hw(grp_name)
            hw_id: int | None = None
            if hw_info:
                hw_id = get_or_create_hw(cur, args.run_id, hw_info[0], hw_info[1])

            cur.execute(
                """INSERT OR IGNORE INTO pinctrl_group
                   (ctrl_id, grp_name, hw_id)
                   VALUES (?,?,?)""",
                (ctrl_id, grp_name, hw_id),
            )
            cur.execute(
                "SELECT grp_id FROM pinctrl_group WHERE ctrl_id=? AND grp_name=?",
                (ctrl_id, grp_name),
            )
            grp_row = cur.fetchone()
            if not grp_row:
                continue
            grp_id: int = grp_row[0]

            # Update pin → hw association via group
            for pin_num in pin_nums:
                db_pin_id = pin_db_ids.get(pin_num)
                if db_pin_id and hw_id:
                    cur.execute(
                        "UPDATE pinctrl_pin SET hw_id=? WHERE pin_id=? AND hw_id IS NULL",
                        (hw_id, db_pin_id),
                    )
                if db_pin_id:
                    cur.execute(
                        """INSERT OR IGNORE INTO pinctrl_group_pin (grp_id, pin_id)
                           VALUES (?,?)""",
                        (grp_id, db_pin_id),
                    )

        print(f"    {len(group_map)} groups")

    db.commit()
    db.close()
    print("pinctrl import complete.")


if __name__ == "__main__":
    main()
