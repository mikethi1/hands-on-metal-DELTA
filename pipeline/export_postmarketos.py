#!/usr/bin/env python3
"""
pipeline/export_postmarketos.py
================================
Generate postmarketOS device-port scaffold files from the hardware_map
SQLite database populated by the rest of the hands-on-metal pipeline.

This parser works on **in-memory working copies** of each DB table for
the requested run.  As each row is consumed to produce an output file,
it is removed from the working copy so subsequent searches are over a
progressively smaller set.  Nothing is written back to the database;
the DB is opened read-only.

Output files (written to --out directory):
  deviceinfo              postmarketOS shell-variable device config
  <codename>.dts          synthesised DTS from dt_node, iomem, IRQ, pinctrl
  modules-initfs          one module name per line (from lsmod / kernel_module)
  hal_interfaces.txt      discovered VINTF HAL entries
  hardware_summary.txt    per-hardware-block summary

Usage:
  python pipeline/export_postmarketos.py \\
      --db hardware_map.sqlite \\
      [--run-id 1]            # defaults to latest run \\
      [--out postmarketos/]   # default: ./postmarketos_<codename>

Called automatically by build_table.py when --pmos is passed, or run
standalone after build_table.py has populated the database.
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path
from textwrap import indent
from typing import Any


# ── Helpers ───────────────────────────────────────────────────────────────────

def _pop_prop(props: dict[str, str], key: str, default: str = "") -> str:
    """Return and remove a property from the working-copy dict."""
    return props.pop(key, default) or default


def _safe_ident(s: str) -> str:
    """Return a DTS-safe label (alphanumeric + underscore, no leading digit)."""
    out = "".join(c if c.isalnum() or c == "_" else "_" for c in s)
    if out and out[0].isdigit():
        out = "_" + out
    return out or "node"


def _hex_to_cells(hex_str: str, addr_cells: int = 2) -> str:
    """Format a hex number as a DTS reg pair (<high low>) or single cell."""
    try:
        val = int(hex_str, 16)
    except (ValueError, TypeError):
        return "0x0 0x0"
    if addr_cells == 1:
        return f"0x{val:x}"
    high = (val >> 32) & 0xFFFFFFFF
    low  = val & 0xFFFFFFFF
    return f"0x{high:x} 0x{low:x}"


def _arch_from_abi(abi: str) -> str:
    abi = abi.lower()
    if "arm64" in abi or "aarch64" in abi:
        return "aarch64"
    if "arm" in abi:
        return "armhf"
    if "x86_64" in abi:
        return "x86_64"
    if "x86" in abi:
        return "x86"
    return "aarch64"  # sane default for modern Android


# ── Load working copies from DB ───────────────────────────────────────────────

def _load_props(cur: sqlite3.Cursor, run_id: int) -> dict[str, str]:
    """Return {key: value} dict of android_prop rows (working copy)."""
    cur.execute(
        "SELECT key, value FROM android_prop WHERE run_id=?", (run_id,)
    )
    return {k: (v or "") for k, v in cur.fetchall()}


def _load_dt_nodes(cur: sqlite3.Cursor, run_id: int) -> list[dict[str, Any]]:
    """Return list of dt_node dicts (working copy, sorted depth-first)."""
    cur.execute(
        """SELECT node_id, path, compatible, reg, interrupts, clocks
           FROM dt_node WHERE run_id=?
           ORDER BY path""",
        (run_id,),
    )
    cols = ("node_id", "path", "compatible", "reg", "interrupts", "clocks")
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def _load_iomem(cur: sqlite3.Cursor, run_id: int) -> list[dict[str, Any]]:
    """Return list of iomem_region dicts (working copy)."""
    cur.execute(
        "SELECT iomem_id, start_hex, end_hex, name FROM iomem_region WHERE run_id=?",
        (run_id,),
    )
    cols = ("iomem_id", "start_hex", "end_hex", "name")
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def _load_irqs(cur: sqlite3.Cursor, run_id: int) -> list[dict[str, Any]]:
    """Return list of irq_entry dicts (working copy)."""
    cur.execute(
        "SELECT irq_id, irq_num, count, name FROM irq_entry WHERE run_id=?",
        (run_id,),
    )
    cols = ("irq_id", "irq_num", "count", "name")
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def _load_modules(cur: sqlite3.Cursor, run_id: int) -> list[dict[str, Any]]:
    """Return list of kernel_module dicts (working copy)."""
    cur.execute(
        "SELECT mod_id, name, size, use_count, used_by FROM kernel_module WHERE run_id=?",
        (run_id,),
    )
    cols = ("mod_id", "name", "size", "use_count", "used_by")
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def _load_hals(cur: sqlite3.Cursor, run_id: int) -> list[dict[str, Any]]:
    """Return list of vintf_hal dicts (working copy)."""
    cur.execute(
        """SELECT vhal_id, hal_format, hal_name, version,
                  interface, instance, transport, source_file
           FROM vintf_hal WHERE run_id=?
           ORDER BY hal_name""",
        (run_id,),
    )
    cols = ("vhal_id", "hal_format", "hal_name", "version",
            "interface", "instance", "transport", "source_file")
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def _load_pinctrl(cur: sqlite3.Cursor, run_id: int) -> dict[str, Any]:
    """Return nested pinctrl structure: {ctrl_name: {pins: [...], groups: [...]}}."""
    cur.execute(
        "SELECT ctrl_id, name, dev_name FROM pinctrl_controller WHERE run_id=?",
        (run_id,),
    )
    controllers: dict[int, dict[str, Any]] = {}
    for ctrl_id, name, dev_name in cur.fetchall():
        controllers[ctrl_id] = {
            "ctrl_id": ctrl_id,
            "name": name,
            "dev_name": dev_name or "",
            "pins": [],
            "groups": [],
        }

    if controllers:
        ctrl_ids = ",".join(str(c) for c in controllers)
        cur.execute(
            f"SELECT ctrl_id, pin_num, gpio_name, function "  # noqa: S608
            f"FROM pinctrl_pin WHERE ctrl_id IN ({ctrl_ids}) "
            "ORDER BY ctrl_id, pin_num",
        )
        for ctrl_id, pin_num, gpio_name, function in cur.fetchall():
            if ctrl_id in controllers:
                controllers[ctrl_id]["pins"].append(
                    {"pin_num": pin_num, "gpio_name": gpio_name or "", "function": function or ""}
                )

        cur.execute(
            f"SELECT ctrl_id, grp_name "  # noqa: S608
            f"FROM pinctrl_group WHERE ctrl_id IN ({ctrl_ids}) "
            "ORDER BY ctrl_id, grp_name",
        )
        for ctrl_id, grp_name in cur.fetchall():
            if ctrl_id in controllers:
                controllers[ctrl_id]["groups"].append(grp_name)

    return {v["name"]: v for v in controllers.values()}


def _load_hw_blocks(cur: sqlite3.Cursor, run_id: int) -> list[dict[str, Any]]:
    """Return list of hardware_block dicts (working copy)."""
    cur.execute(
        """SELECT hw_id, name, category, hal_interface, hal_instance,
                  pinctrl_group, pct_populated
           FROM hardware_block WHERE run_id=?
           ORDER BY category, name""",
        (run_id,),
    )
    cols = ("hw_id", "name", "category", "hal_interface", "hal_instance",
            "pinctrl_group", "pct_populated")
    return [dict(zip(cols, row)) for row in cur.fetchall()]


# ── deviceinfo generator ──────────────────────────────────────────────────────

def generate_deviceinfo(props: dict[str, str], modules: list[dict[str, Any]]) -> str:
    """
    Build the postmarketOS ``deviceinfo`` file content.

    Pops every property it uses from *props* and removes every module it
    includes from *modules*, leaving only unconsumed data in both.
    """
    lines: list[str] = [
        "#!/bin/sh",
        "# Reference: <https://postmarketos.org/deviceinfo>",
        "# Generated by hands-on-metal pipeline/export_postmarketos.py",
        "# Review and correct values marked with [?] before use.",
        "",
    ]

    def kv(key: str, value: str) -> str:
        escaped = value.replace('"', '\\"')
        return f'{key}="{escaped}"'

    # ── Identity ──────────────────────────────────────────────────────────────
    model        = _pop_prop(props, "ro.product.model")
    manufacturer = _pop_prop(props, "ro.product.manufacturer")
    device       = _pop_prop(props, "ro.product.device")
    brand        = _pop_prop(props, "ro.product.brand")

    # Also consume related properties so they are counted as used
    _pop_prop(props, "ro.product.name")
    _pop_prop(props, "ro.build.product")

    lines += [
        kv("deviceinfo_format_version", "0"),
        kv("deviceinfo_name", model or device or "Unknown"),
        kv("deviceinfo_manufacturer", manufacturer or brand or "Unknown"),
        kv("deviceinfo_date", ""),
    ]

    # ── Board / platform ─────────────────────────────────────────────────────
    platform     = _pop_prop(props, "ro.board.platform")
    hardware     = _pop_prop(props, "ro.hardware")
    board        = _pop_prop(props, "ro.product.board")
    _pop_prop(props, "ro.soc.manufacturer")
    soc_model    = _pop_prop(props, "ro.soc.model")

    # Best guess DTB path:  <platform>.dtb or board/<platform>-<board>.dtb
    if platform and board and board != platform:
        dtb_guess = f"{platform}-{board}"
    elif platform:
        dtb_guess = platform
    else:
        dtb_guess = hardware or ""

    lines += [
        "",
        "# Board / platform",
        kv("deviceinfo_dtb", dtb_guess),
        kv("deviceinfo_soc", soc_model or platform or hardware or ""),
    ]

    # ── Architecture ─────────────────────────────────────────────────────────
    abi        = _pop_prop(props, "ro.product.cpu.abi")
    _pop_prop(props, "ro.product.cpu.abilist")
    _pop_prop(props, "ro.product.cpu.abilist32")
    _pop_prop(props, "ro.product.cpu.abilist64")
    arch       = _arch_from_abi(abi)

    lines += [
        "",
        "# Architecture",
        kv("deviceinfo_arch", arch),
    ]

    # ── Screen ───────────────────────────────────────────────────────────────
    # Look for display info props (may not exist in all dumps)
    w = _pop_prop(props, "ro.sf.lcd_density")   # density proxy — no direct w/h props
    _pop_prop(props, "persist.sys.sf.native_mode")

    lines += [
        "",
        "# Display  [? fill from DTS or datasheet]",
        kv("deviceinfo_screen_width", ""),
        kv("deviceinfo_screen_height", ""),
        kv("deviceinfo_screen_density", w),
    ]

    # ── Kernel modules for initramfs ─────────────────────────────────────────
    # Consume modules with use_count > 0 (actively loaded) first.
    initfs_mods: list[str] = []
    remaining: list[dict[str, Any]] = []
    for m in modules:
        if m["use_count"] and int(m["use_count"]) > 0:
            initfs_mods.append(m["name"])
            # row consumed — do NOT append to remaining
        else:
            remaining.append(m)
    modules[:] = remaining  # mutate caller's list in-place

    lines += [
        "",
        "# Kernel modules placed in the initramfs",
        kv("deviceinfo_modules_initfs", " ".join(initfs_mods)),
    ]

    # ── Boot image layout ────────────────────────────────────────────────────
    cmdline = _pop_prop(props, "ro.boot.hardware")
    _pop_prop(props, "ro.bootimage.build.fingerprint")
    hdr_ver = _pop_prop(props, "ro.boot.header_version")

    # Android 13+ uses header_version 4 with GKI
    if not hdr_ver:
        api_level = _pop_prop(props, "ro.product.first_api_level")
        if api_level and int(api_level) >= 33:
            hdr_ver = "4"
        else:
            _pop_prop(props, "ro.product.first_api_level")
            hdr_ver = "2"
    else:
        _pop_prop(props, "ro.product.first_api_level")

    lines += [
        "",
        "# Boot image",
        kv("deviceinfo_flash_method", "fastboot"),
        kv("deviceinfo_external_disk", "false"),
        kv("deviceinfo_generate_bootimg", "true"),
        kv("deviceinfo_bootimg_header_version", hdr_ver),
        kv("deviceinfo_bootimg_pagesize", "4096  # [? verify against mkbootimg]"),
        kv("deviceinfo_bootimg_base", "0x00000000  # [? verify against mkbootimg]"),
        kv("deviceinfo_bootimg_offset_ramdisk", "0x01000000  # [?]"),
        kv("deviceinfo_bootimg_offset_second", "0x00000000  # [?]"),
        kv("deviceinfo_bootimg_offset_tags", "0x00000100  # [?]"),
    ]

    # ── Kernel cmdline ────────────────────────────────────────────────────────
    lines += [
        "",
        "# Kernel cmdline  [? extract from boot.img with unpackbootimg]",
        kv("deviceinfo_kernel_cmdline", ""),
    ]

    # ── Fingerprint for reference ─────────────────────────────────────────────
    fp = _pop_prop(props, "ro.build.fingerprint")
    lines += [
        "",
        f"# Source build fingerprint: {fp}",
    ]

    return "\n".join(lines) + "\n"


# ── DTS synthesiser ───────────────────────────────────────────────────────────

def generate_dts(
    props: dict[str, str],
    dt_nodes: list[dict[str, Any]],
    iomem:    list[dict[str, Any]],
    irqs:     list[dict[str, Any]],
    pinctrl:  dict[str, Any],
    modules:  list[dict[str, Any]],
) -> str:
    """
    Synthesise a Device Tree Source from the hardware data.

    Pops / removes consumed rows from each working-copy list/dict.
    The generated DTS is a best-effort scaffold; it will need manual
    completion before it can be compiled and used.
    """
    lines: list[str] = [
        "/dts-v1/;",
        "/* Generated by hands-on-metal — review before use */",
        "",
    ]

    # ── Header node ──────────────────────────────────────────────────────────
    model        = _pop_prop(props, "ro.product.model")
    device       = _pop_prop(props, "ro.product.device")
    platform     = _pop_prop(props, "ro.board.platform")
    hardware     = _pop_prop(props, "ro.hardware")
    _pop_prop(props, "ro.build.description")

    # Attempt to extract a compatible string from dt_nodes root node
    root_compat = ""
    root_nodes_after: list[dict[str, Any]] = []
    for node in dt_nodes:
        if node["path"] in ("/", ""):
            root_compat = node["compatible"] or ""
            # consumed
        else:
            root_nodes_after.append(node)
    dt_nodes[:] = root_nodes_after

    if not root_compat and platform:
        root_compat = f"vendor,{device or hardware or 'device'}"

    lines += [
        "/ {",
        f'\tmodel = "{model or device or "Unknown Android device"}";',
        f'\tcompatible = "{root_compat}";',
        "",
        "\t#address-cells = <2>;",
        "\t#size-cells = <2>;",
        "",
    ]

    # ── Memory nodes from iomem ───────────────────────────────────────────────
    # Consume rows whose name looks like "System RAM"
    mem_rows: list[dict[str, Any]] = []
    other_iomem: list[dict[str, Any]] = []
    for r in iomem:
        name_lower = (r["name"] or "").lower()
        if "system ram" in name_lower or "dram" in name_lower or "memory" in name_lower:
            mem_rows.append(r)
        else:
            other_iomem.append(r)
    iomem[:] = other_iomem  # remove consumed rows from working copy

    if mem_rows:
        lines.append("\t/* Memory regions from /proc/iomem */")
        for i, r in enumerate(mem_rows):
            start = _hex_to_cells(r["start_hex"])
            size_val = int(r["end_hex"], 16) - int(r["start_hex"], 16) + 1
            size = _hex_to_cells(f"{size_val:x}")
            label = f"memory@{r['start_hex']}"
            lines += [
                f"\t{label} {{",
                '\t\tdevice_type = "memory";',
                f"\t\treg = <{start} {size}>;",
                "\t};",
                "",
            ]

    # ── Reserved memory table from remaining iomem ────────────────────────────
    reserved: list[dict[str, Any]] = []
    general_iomem: list[dict[str, Any]] = []
    for r in iomem:
        name_lower = (r["name"] or "").lower()
        if "reserved" in name_lower or "carveout" in name_lower or "cma" in name_lower:
            reserved.append(r)
        else:
            general_iomem.append(r)
    iomem[:] = general_iomem  # remove consumed rows

    if reserved:
        lines += [
            "\treserved-memory {",
            "\t\t#address-cells = <2>;",
            "\t\t#size-cells = <2>;",
            "\t\tranges;",
            "",
        ]
        for r in reserved:
            start = _hex_to_cells(r["start_hex"])
            size_val = int(r["end_hex"], 16) - int(r["start_hex"], 16) + 1
            size = _hex_to_cells(f"{size_val:x}")
            lbl = _safe_ident((r["name"] or "reserved").replace(" ", "_").lower())
            lines += [
                f"\t\t{lbl}: {lbl}@{r['start_hex']} {{",
                f"\t\t\treg = <{start} {size}>;",
                "\t\t\tno-map;",
                "\t\t};",
                "",
            ]
        lines.append("\t};")
        lines.append("")

    # ── SOC node (groups hardware sub-nodes) ──────────────────────────────────
    lines += [
        "\tsoc: soc {",
        "\t\t#address-cells = <2>;",
        "\t\t#size-cells = <2>;",
        "\t\tranges;",
        "",
    ]

    # Map each dt_node into the SOC node. Consume the row as we write it.
    consumed_node_ids: set[int] = set()
    for node in list(dt_nodes):
        node_path  = node["path"]
        compat     = (node["compatible"] or "").replace("\x00", " ").strip()
        reg        = (node["reg"] or "").strip()
        interrupts = (node["interrupts"] or "").strip()
        clocks     = (node["clocks"] or "").strip()

        # Derive a DTS node name from the path's last component
        parts = [p for p in node_path.split("/") if p]
        if not parts:
            continue
        last_part = parts[-1]
        label = _safe_ident(last_part)

        # Try to produce a register address from the node name (often has @addr)
        at_pos = last_part.find("@")
        reg_addr = last_part[at_pos + 1:] if at_pos != -1 else ""

        lines.append(f"\t\t{label}: {last_part} {{")
        if compat:
            first_compat = compat.split()[0].rstrip(",")
            lines.append(f'\t\t\tcompatible = "{first_compat}";')
        if reg_addr:
            lines.append(f"\t\t\treg = <0x0 0x{reg_addr} 0x0 0x1000>; /* size [?] */")
        elif reg:
            lines.append(f"\t\t\t/* reg raw: {reg!r} */")
        if interrupts:
            lines.append(f"\t\t\t/* interrupts: {interrupts!r} */")
        if clocks:
            lines.append(f"\t\t\t/* clocks: {clocks!r} */")
        lines += [
            "\t\t\tstatus = \"disabled\"; /* [? enable when driver ready] */",
            "\t\t};",
            "",
        ]
        consumed_node_ids.add(node["node_id"])

    # Remove consumed nodes from working copy
    dt_nodes[:] = [n for n in dt_nodes if n["node_id"] not in consumed_node_ids]

    lines += ["\t};", ""]  # close soc

    # ── Pinctrl blocks ────────────────────────────────────────────────────────
    consumed_ctrl_names: list[str] = []
    for ctrl_name, ctrl in list(pinctrl.items()):
        lbl = _safe_ident(ctrl_name)
        lines += [
            f"\t{lbl}_pinctrl: pinctrl@{lbl} {{",
            f'\t\tcompatible = "pinctrl-{lbl}"; /* [? match vendor driver] */',
            "",
        ]
        # Emit a group stub per group (consume groups)
        for grp in ctrl["groups"]:
            glbl = _safe_ident(grp)
            lines += [
                f"\t\t{glbl}_pins: {glbl} {{",
                "\t\t\t/* [? add pins, function, drive-strength, bias] */",
                "\t\t};",
                "",
            ]
        lines += ["\t};", ""]
        consumed_ctrl_names.append(ctrl_name)

    for k in consumed_ctrl_names:
        del pinctrl[k]   # consumed

    # ── Close root node ───────────────────────────────────────────────────────
    # Add a comment about any remaining unconsumed iomem entries
    if iomem:
        lines.append("\t/* Remaining iomem regions (unmapped in DTS above): */")
        for r in iomem:
            lines.append(f"\t/* {r['start_hex']}-{r['end_hex']} : {r['name']} */")
        lines.append("")
        iomem.clear()   # mark all as consumed

    # Add IRQ comment block (consume all)
    if irqs:
        lines.append("\t/* IRQs observed in /proc/interrupts: */")
        for r in irqs:
            lines.append(f"\t/* IRQ {r['irq_num']:4d} : {r['name']} (count {r['count']}) */")
        lines.append("")
        irqs.clear()

    # Remaining kernel modules as a comment (do NOT clear — generate_modules_initfs owns that)
    if modules:
        lines.append("\t/* Kernel modules loaded at collection time: */")
        for m in modules:
            lines.append(f"\t/* module: {m['name']} ({m['size']} bytes) */")
        lines.append("")

    lines += ["};", ""]
    return "\n".join(lines)


# ── Kernel module list ────────────────────────────────────────────────────────

def generate_modules_initfs(modules: list[dict[str, Any]]) -> str:
    """
    Write one module name per line; consume every row from *modules*.

    The caller should pass the same list it passed to ``generate_deviceinfo``
    so that only the modules NOT already selected for initfs appear here.
    """
    out: list[str] = [
        "# modules-initfs",
        "# Generated by hands-on-metal — review before use.",
        "# Add/remove entries based on what your kernel build includes.",
        "",
    ]
    for m in modules:
        out.append(m["name"])
    modules.clear()
    return "\n".join(out) + "\n"


# ── HAL interface list ────────────────────────────────────────────────────────

def generate_hal_list(hals: list[dict[str, Any]]) -> str:
    """Write a human-readable HAL interface summary; consume all rows."""
    lines: list[str] = [
        "# VINTF HAL Interfaces discovered by hands-on-metal",
        "# Format: [format] hal_name version interface/instance (transport)",
        "",
    ]
    for h in hals:
        parts = [
            f"[{h['hal_format'] or '?'}]",
            h["hal_name"] or "?",
        ]
        if h["version"]:
            parts.append(f"@{h['version']}")
        iface = "/".join(filter(None, [h["interface"], h["instance"]]))
        if iface:
            parts.append(iface)
        if h["transport"]:
            parts.append(f"({h['transport']})")
        if h["source_file"]:
            parts.append(f"[from {h['source_file']}]")
        lines.append(" ".join(parts))
    hals.clear()
    return "\n".join(lines) + "\n"


# ── Hardware block summary ────────────────────────────────────────────────────

def generate_hw_summary(hw_blocks: list[dict[str, Any]]) -> str:
    """Write a human-readable hardware summary; consume all rows."""
    lines: list[str] = [
        "# Hardware Block Summary — hands-on-metal",
        f"# {'Name':<25} {'Category':<12} {'HAL Interface':<50} {'Fill%':>6}",
        "#" + "-" * 100,
    ]
    for h in hw_blocks:
        pct = h["pct_populated"] or 0.0
        lines.append(
            f"  {h['name']:<25} {h['category']:<12} "
            f"{(h['hal_interface'] or ''):<50} {pct:>5.1f}%"
        )
    hw_blocks.clear()
    return "\n".join(lines) + "\n"


# ── Orchestrator ──────────────────────────────────────────────────────────────

def export(db_path: Path, run_id: int | None, out_dir: Path) -> None:
    """
    Main export function.

    Opens *db_path* read-only, loads working copies of each table for
    *run_id* (latest run if None), generates all output files into
    *out_dir*, and prints a summary.
    """
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    cur = db.cursor()

    # Resolve run_id
    if run_id is None:
        cur.execute("SELECT MAX(run_id) FROM collection_run")
        row = cur.fetchone()
        if not row or row[0] is None:
            print("ERROR: database contains no collection runs.", file=sys.stderr)
            sys.exit(1)
        run_id = row[0]

    cur.execute(
        """SELECT mode, device_model, ro_board, ro_platform, ro_hardware
           FROM collection_run WHERE run_id=?""",
        (run_id,),
    )
    run_row = cur.fetchone()
    if not run_row:
        print(f"ERROR: run_id {run_id} not found in database.", file=sys.stderr)
        sys.exit(1)

    _, device_model, ro_board, ro_platform, ro_hardware = run_row
    codename = (ro_board or ro_platform or ro_hardware or device_model or "device").lower()
    codename = _safe_ident(codename.replace("-", "_").replace(" ", "_"))

    print(f"  Exporting run {run_id}  codename={codename}")

    # ── Load all working copies ───────────────────────────────────────────────
    print("  Loading working copies from DB...")
    props     = _load_props(cur, run_id)          # dict  — pops as consumed
    dt_nodes  = _load_dt_nodes(cur, run_id)       # list  — pops as consumed
    iomem     = _load_iomem(cur, run_id)          # list
    irqs      = _load_irqs(cur, run_id)           # list
    modules   = _load_modules(cur, run_id)        # list
    hals      = _load_hals(cur, run_id)           # list
    pinctrl   = _load_pinctrl(cur, run_id)        # dict  — del as consumed
    hw_blocks = _load_hw_blocks(cur, run_id)      # list

    db.close()

    total_loaded = (
        len(props) + len(dt_nodes) + len(iomem) + len(irqs)
        + len(modules) + len(hals) + len(pinctrl) + len(hw_blocks)
    )
    print(f"  Loaded {total_loaded} rows across 8 table types.")

    out_dir.mkdir(parents=True, exist_ok=True)

    # ── 1. deviceinfo ─────────────────────────────────────────────────────────
    print("  [1/5] Generating deviceinfo...")
    di_text = generate_deviceinfo(props, modules)
    (out_dir / "deviceinfo").write_text(di_text, encoding="utf-8")

    # ── 2. DTS ────────────────────────────────────────────────────────────────
    print("  [2/5] Synthesising DTS...")
    dts_text = generate_dts(props, dt_nodes, iomem, irqs, pinctrl, modules)
    (out_dir / f"{codename}.dts").write_text(dts_text, encoding="utf-8")

    # ── 3. modules-initfs (remaining modules not yet placed in deviceinfo) ────
    print("  [3/5] Writing modules-initfs...")
    mod_text = generate_modules_initfs(modules)
    (out_dir / "modules-initfs").write_text(mod_text, encoding="utf-8")

    # ── 4. HAL list ───────────────────────────────────────────────────────────
    print("  [4/5] Writing HAL interface list...")
    hal_text = generate_hal_list(hals)
    (out_dir / "hal_interfaces.txt").write_text(hal_text, encoding="utf-8")

    # ── 5. Hardware summary ───────────────────────────────────────────────────
    print("  [5/5] Writing hardware block summary...")
    hw_text = generate_hw_summary(hw_blocks)
    (out_dir / "hardware_summary.txt").write_text(hw_text, encoding="utf-8")

    # ── Residual props (not consumed by any generator) ────────────────────────
    if props:
        remaining_props_text = "\n".join(
            f"{k}={v}" for k, v in sorted(props.items())
        ) + "\n"
        (out_dir / "remaining_props.txt").write_text(
            "# Android props not consumed by any generator — review for additional data.\n"
            + remaining_props_text,
            encoding="utf-8",
        )

    print(f"\n  ✓ Output written to: {out_dir}")
    print(f"    deviceinfo          — postmarketOS device config")
    print(f"    {codename}.dts{' '*(20-len(codename))}— synthesised device tree source")
    print(f"    modules-initfs      — kernel modules for initramfs")
    print(f"    hal_interfaces.txt  — VINTF HAL entries")
    print(f"    hardware_summary.txt— hardware block fill-rate summary")
    if (out_dir / "remaining_props.txt").exists():
        print(f"    remaining_props.txt — unconsumed Android properties")
    print()
    print("  ⚠  Generated files are scaffolds only.  Review all [?] annotations")
    print("     and consult the device datasheet / downstream kernel source.")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Export postmarketOS device-port scaffold from hardware_map.sqlite"
    )
    ap.add_argument(
        "--db", required=True,
        help="Path to hardware_map.sqlite built by build_table.py",
    )
    ap.add_argument(
        "--run-id", type=int, default=None,
        help="Collection run ID to export (default: latest run)",
    )
    ap.add_argument(
        "--out", default=None,
        help="Output directory (default: ./postmarketos_<codename>/)",
    )
    args = ap.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        ap.error(f"Database not found: {db_path}")

    out_dir = Path(args.out) if args.out else None

    # Resolve output dir: need codename first if not supplied
    if out_dir is None:
        db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        cur = db.cursor()
        run_id_val = args.run_id
        if run_id_val is None:
            cur.execute("SELECT MAX(run_id) FROM collection_run")
            r = cur.fetchone()
            run_id_val = r[0] if r else 1
        cur.execute(
            "SELECT ro_board, ro_platform, ro_hardware, device_model "
            "FROM collection_run WHERE run_id=?",
            (run_id_val,),
        )
        row = cur.fetchone()
        db.close()
        codename = "device"
        if row:
            for field in row:
                if field:
                    codename = field.lower().replace("-", "_").replace(" ", "_")
                    codename = _safe_ident(codename)
                    break
        out_dir = Path(f"postmarketos_{codename}")

    export(db_path, args.run_id, out_dir)


if __name__ == "__main__":
    main()
