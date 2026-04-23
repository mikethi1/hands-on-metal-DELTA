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
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET
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


# ── Supplemental file parsers (for --dump enrichment) ────────────────────────

# Known ARM CPU part numbers → DTS compatible strings
_ARM_PART_COMPAT: dict[str, str] = {
    "0xd40": "arm,cortex-a76",
    "0xd41": "arm,cortex-a77",
    "0xd44": "arm,cortex-x1",
    "0xd46": "arm,cortex-a510",
    "0xd47": "arm,cortex-a710",
    "0xd4d": "arm,cortex-a715",
    "0xd4e": "arm,cortex-x3",
    "0xd80": "arm,cortex-a520",
    "0xd81": "arm,cortex-a720",
    "0xd82": "arm,cortex-x4",
}


def _parse_cpuinfo(dump_dir: Path | None) -> dict[str, Any]:
    """Parse proc/cpuinfo and return CPU cluster topology.

    Returns ``{"clusters": [{compat, start_cpu, end_cpu, part}], "total": int}``.
    Adjacent CPUs with the same CPU part are grouped into one cluster.
    """
    empty: dict[str, Any] = {"clusters": [], "total": 0}
    if dump_dir is None:
        return empty
    path = dump_dir / "proc" / "cpuinfo"
    if not path.exists():
        return empty

    processors: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            if "processor" in current:
                processors.append(current)
            current = {}
            continue
        if ":" in line:
            key, _, val = line.partition(":")
            current[key.strip().lower().replace(" ", "_")] = val.strip()
    if "processor" in current:
        processors.append(current)

    clusters: list[dict[str, Any]] = []
    last_part: str | None = None
    for i, cpu in enumerate(processors):
        part = cpu.get("cpu_part", "").lower()
        if part != last_part:
            if clusters:
                clusters[-1]["end_cpu"] = i - 1
            compat = _ARM_PART_COMPAT.get(part, "arm,cortex-a?")
            clusters.append({"compat": compat, "start_cpu": i,
                              "end_cpu": i, "part": part})
            last_part = part
    if clusters:
        clusters[-1]["end_cpu"] = len(processors) - 1

    return {"clusters": clusters, "total": len(processors)}


def _parse_meminfo(dump_dir: Path | None) -> int:
    """Return MemTotal in bytes from proc/meminfo, or 0 if unavailable."""
    if dump_dir is None:
        return 0
    path = dump_dir / "proc" / "meminfo"
    if not path.exists():
        return 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("MemTotal:"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    return int(parts[1]) * 1024
                except ValueError:
                    pass
    return 0


def _parse_permissions(dump_dir: Path | None) -> set[str]:
    """Return set of feature names declared in vendor/system etc/permissions/*.xml."""
    if dump_dir is None:
        return set()
    features: set[str] = set()
    for perm_dir in [
        dump_dir / "vendor" / "etc" / "permissions",
        dump_dir / "system" / "etc" / "permissions",
    ]:
        if not perm_dir.exists():
            continue
        for xml_file in perm_dir.glob("*.xml"):
            try:
                text = xml_file.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for m in re.finditer(r'<feature\s+name="([^"]+)"', text):
                features.add(m.group(1))
    return features


def _parse_fstab_peripherals(dump_dir: Path | None) -> dict[str, str]:
    """Extract UFS and USB peripheral addresses from vendor/etc/fstab.* files.

    Returns a dict that may contain ``"ufs_block_addr"`` (e.g. ``"13200000.ufs"``)
    and ``"usb_platform_addr"`` (e.g. ``"11210000.usb"``).
    """
    if dump_dir is None:
        return {}
    result: dict[str, str] = {}
    vendor_etc = dump_dir / "vendor" / "etc"
    if not vendor_etc.exists():
        return result
    for fstab_file in vendor_etc.glob("fstab.*"):
        try:
            text = fstab_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "ufs_block_addr" not in result:
            m = re.search(r"/dev/block/platform/([0-9a-f]+\.[a-z]+)/", text)
            if m:
                result["ufs_block_addr"] = m.group(1)
        if "usb_platform_addr" not in result:
            m = re.search(r"/devices/platform/([0-9a-f]+\.[a-z]+)", text)
            if m:
                result["usb_platform_addr"] = m.group(1)
    return result


def _parse_audio_strategies(path: Path | None) -> dict[str, Any]:
    """Parse a ComponentTypeSet XML for ProductStrategy entries.

    Returns ``{"standard": [...names], "vendor": [{name, id}]}``.
    Standard strategies are those named ``STRATEGY_*``; vendor strategies
    are those with an explicit ``Identifier:`` mapping (e.g. ``vx_1000``).
    """
    empty: dict[str, Any] = {"standard": [], "vendor": []}
    if path is None or not path.exists():
        return empty
    try:
        tree = ET.parse(str(path))
        root = tree.getroot()
    except ET.ParseError:
        return empty

    standard: list[str] = []
    vendor: list[dict[str, str]] = []
    for comp in root.iter("Component"):
        name = comp.get("Name", "")
        mapping = comp.get("Mapping", "")
        if name.startswith("STRATEGY_"):
            standard.append(name)
        else:
            ident = ""
            for part in mapping.split(","):
                if part.startswith("Identifier:"):
                    ident = part.split(":", 1)[1].strip()
            if ident:
                vendor.append({"name": name, "id": ident})
    return {"standard": standard, "vendor": vendor}


def _generate_cpus_node(cpu_info: dict[str, Any]) -> list[str]:
    """Return DTS lines for a ``cpus {}`` block from parsed cpuinfo data."""
    lines: list[str] = [
        "\tcpus {",
        "\t\t#address-cells = <1>;",
        "\t\t#size-cells = <0>;",
        "",
    ]
    cluster_labels = ["Little", "Mid", "Big", "Prime"]
    for ci, cluster in enumerate(cpu_info["clusters"]):
        label = (cluster_labels[ci] if ci < len(cluster_labels)
                 else f"Cluster {ci}")
        count = cluster["end_cpu"] - cluster["start_cpu"] + 1
        cpu_name = cluster["compat"].split(",")[-1].upper()
        lines.append(f"\t\t/* {label} cluster: {count}x {cpu_name} */")
        for cpu_idx in range(cluster["start_cpu"], cluster["end_cpu"] + 1):
            lines += [
                f"\t\tcpu{cpu_idx}: cpu@{cpu_idx:x} {{",
                f'\t\t\tcompatible = "{cluster["compat"]}";',
                '\t\t\tdevice_type = "cpu";',
                f"\t\t\treg = <{hex(cpu_idx)}>;",
                '\t\t\tenable-method = "psci";',
                "\t\t};",
            ]
        lines.append("")
    lines += ["\t};", ""]
    return lines


# ── Load working copies from DB ───────────────────────────────────────────────

def _load_props(cur: sqlite3.Cursor, run_id: int) -> dict[str, str]:
    """Return {key: value} dict of android_prop rows (working copy)."""
    cur.execute(
        "SELECT key, value FROM android_prop WHERE run_id=?", (run_id,)
    )
    return {k: (v or "") for k, v in cur.fetchall()}


def _load_sysconfig(cur: sqlite3.Cursor, run_id: int) -> dict[str, str]:
    """Return {key: value} dict of sysconfig_entry rows for the run."""
    cur.execute(
        "SELECT key, value FROM sysconfig_entry WHERE run_id=?", (run_id,)
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

def generate_deviceinfo(
    props: dict[str, str],
    modules: list[dict[str, Any]],
    sysconfig: dict[str, str] | None = None,
    dump_dir: Path | None = None,
    audio_strategies: dict[str, Any] | None = None,
) -> str:
    """
    Build the postmarketOS ``deviceinfo`` file content.

    Pops every property it uses from *props* and removes every module it
    includes from *modules*, leaving only unconsumed data in both.
    *sysconfig* carries values from sysconfig_entry (proc.cmdline,
    boot.pagesize, boot.cmdline) collected by the pipeline.
    """
    sys = sysconfig or {}

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

    # Consume related properties so they are counted as used
    _pop_prop(props, "ro.product.name")
    _pop_prop(props, "ro.build.product")

    # Codename: prefer ro.product.board, fall back to device
    board_name   = _pop_prop(props, "ro.product.board")
    codename     = (board_name or device or "unknown").lower().replace(" ", "_")

    # Year: derive from build date UTC if available
    build_date   = _pop_prop(props, "ro.build.date.utc")
    year = ""
    if build_date and build_date.isdigit():
        import datetime
        try:
            year = str(datetime.datetime.utcfromtimestamp(int(build_date)).year)
        except (OSError, OverflowError):
            pass

    lines += [
        kv("deviceinfo_format_version", "0"),
        kv("deviceinfo_name", model or device or "Unknown"),
        kv("deviceinfo_manufacturer", manufacturer or brand or "Unknown"),
        kv("deviceinfo_codename", codename),
        kv("deviceinfo_year", year),
    ]

    # ── Board / platform ─────────────────────────────────────────────────────
    platform     = _pop_prop(props, "ro.board.platform")
    hardware     = _pop_prop(props, "ro.hardware")
    _pop_prop(props, "ro.soc.manufacturer")
    soc_model    = _pop_prop(props, "ro.soc.model")

    # Build DTB path following postmarketOS convention for Samsung/Exynos/Google:
    # exynos/<manufacturer>/<platform>-<board>  or  <platform>-<board>
    soc_mfr = sys.get("soc.manufacturer", "").lower()
    if not soc_mfr:
        soc_mfr = (manufacturer or "").lower()
    exynos_keywords = ("samsung", "google", "exynos", "gs1", "zuma")
    if any(kw in soc_mfr or kw in (platform or "").lower() for kw in exynos_keywords):
        mfr_dir = "google" if "google" in soc_mfr else "samsung"
        dtb_guess = f"exynos/{mfr_dir}/{platform}-{codename}" if platform else codename
    elif platform and codename and codename != platform:
        dtb_guess = f"{platform}-{codename}"
    elif platform:
        dtb_guess = platform
    else:
        dtb_guess = hardware or ""

    lines += [
        "",
        "# Board / platform",
        kv("deviceinfo_dtb", dtb_guess),
        kv("deviceinfo_soc", soc_model or platform or hardware or ""),
        kv("deviceinfo_chassis", _chassis_from_props(props)),
        kv("deviceinfo_external_storage", _external_storage_from_props(props)),
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
    w = _pop_prop(props, "ro.sf.lcd_density")
    _pop_prop(props, "persist.sys.sf.native_mode")

    lines += [
        "",
        "# Display  [? fill from DTS or datasheet]",
        kv("deviceinfo_screen_width", ""),
        kv("deviceinfo_screen_height", ""),
        kv("deviceinfo_screen_density", w),
    ]

    # ── Kernel modules for initramfs ─────────────────────────────────────────
    initfs_mods: list[str] = []
    remaining: list[dict[str, Any]] = []
    for m in modules:
        if m["use_count"] and int(m["use_count"]) > 0:
            initfs_mods.append(m["name"])
        else:
            remaining.append(m)
    modules[:] = remaining

    lines += [
        "",
        "# Kernel modules placed in the initramfs",
        kv("deviceinfo_modules_initfs", " ".join(initfs_mods)),
    ]

    # ── Boot image layout ────────────────────────────────────────────────────
    _pop_prop(props, "ro.boot.hardware")          # consume; value not reused here
    _pop_prop(props, "ro.bootimage.build.fingerprint")
    hdr_ver = _pop_prop(props, "ro.boot.header_version")

    # Android 13+ uses header_version 4 with GKI
    api_level = _pop_prop(props, "ro.product.first_api_level")
    if not hdr_ver:
        if api_level and int(api_level) >= 33:
            hdr_ver = "4"
        else:
            hdr_ver = "2"

    # Page size: prefer value collected from boot image header, then default
    raw_pagesize = sys.get("boot.pagesize", "")
    pagesize = raw_pagesize if raw_pagesize and raw_pagesize != "0" else "4096"

    # Kernel cmdline: prefer /proc/cmdline (live), then boot image header cmdline
    kernel_cmdline = (sys.get("proc.cmdline", "")
                      or sys.get("boot.cmdline", ""))

    # Non-Qualcomm device: qcdt is always false
    is_qcom = "qcom" in (platform or "").lower() or "msm" in (hardware or "").lower()

    lines += [
        "",
        "# Boot image",
        kv("deviceinfo_flash_method", "fastboot"),
        kv("deviceinfo_flash_fastboot_partition_vbmeta", "vbmeta"),
        kv("deviceinfo_flash_fastboot_partition_dtbo", "dtbo"),
        kv("deviceinfo_generate_bootimg", "true"),
        kv("deviceinfo_header_version", hdr_ver),
        kv("deviceinfo_flash_pagesize", pagesize),
        kv("deviceinfo_bootimg_qcdt", "true" if is_qcom else "false"),
    ]

    lines += [
        "",
        "# Kernel cmdline",
        kv("deviceinfo_kernel_cmdline", kernel_cmdline),
    ]

    # ── UFS / storage ─────────────────────────────────────────────────────────
    lines += [
        "",
        "# UFS / rootfs",
        kv("deviceinfo_rootfs_image_sector_size", "4096"),
    ]

    # ── Hardware features (from vendor/system permissions) ───────────────────
    features = _parse_permissions(dump_dir)
    if features:
        # Categorise features into human-readable groups for the comment block
        _FEATURE_GROUPS: list[tuple[str, str]] = [
            ("camera",    "Camera"),
            ("nfc",       "NFC"),
            ("bluetooth", "Bluetooth"),
            ("wifi",      "Wi-Fi"),
            ("location.gps", "GPS"),
            ("sensor",    "Sensors"),
            ("telephony", "Telephony"),
            ("usb",       "USB"),
            ("audio",     "Audio"),
            ("vulkan",    "Vulkan/GPU"),
            ("opengles",  "OpenGL ES"),
            ("uwb",       "UWB"),
            ("se.omapi",  "Secure Element (OMAPI)"),
            ("context_hub", "Context Hub / Ambient"),
        ]
        lines.append("")
        lines.append("# Detected hardware features (from vendor/system permissions):")
        for keyword, label in _FEATURE_GROUPS:
            matched = sorted(f for f in features if keyword in f)
            if matched:
                lines.append(f"#   {label}: {', '.join(matched)}")

    # ── Audio strategies ─────────────────────────────────────────────────────
    ast = audio_strategies or {}
    std_count    = len(ast.get("standard", []))
    vendor_count = len(ast.get("vendor", []))
    if std_count or vendor_count:
        lines.append("")
        lines.append("# Audio routing strategies:")
        if std_count:
            lines.append(f"#   Standard (AOSP): {', '.join(ast['standard'])}")
        if vendor_count:
            v = ast["vendor"]
            id_range = f"{v[0]['id']}--{v[-1]['id']}" if len(v) > 1 else v[0]["id"]
            lines.append(f"#   Vendor-specific : {vendor_count} strategies"
                         f" (IDs {id_range})")

    # ── CPU info ─────────────────────────────────────────────────────────────
    cpu_info = _parse_cpuinfo(dump_dir)
    if cpu_info["total"]:
        cluster_strs = []
        for cl in cpu_info["clusters"]:
            cnt = cl["end_cpu"] - cl["start_cpu"] + 1
            cluster_strs.append(f"{cnt}x {cl['compat'].split(',')[-1].upper()}")
        lines.append("")
        lines.append(f"# CPU topology: {cpu_info['total']} cores — "
                     + " + ".join(cluster_strs))

    # ── RAM info ─────────────────────────────────────────────────────────────
    mem_bytes = _parse_meminfo(dump_dir)
    if mem_bytes:
        mem_gib = mem_bytes / (1024 ** 3)
        lines.append(f"# RAM (MemTotal): {mem_gib:.1f} GiB")

    # ── Fingerprint for reference ─────────────────────────────────────────────
    fp = _pop_prop(props, "ro.build.fingerprint")
    lines += [
        "",
        f"# Source build fingerprint: {fp}",
    ]

    return "\n".join(lines) + "\n"


def _chassis_from_props(props: dict[str, str]) -> str:
    """Derive deviceinfo_chassis from ro.build.characteristics."""
    chars = _pop_prop(props, "ro.build.characteristics")
    if not chars:
        return "handset"
    chars_lower = chars.lower()
    if "tablet" in chars_lower:
        return "tablet"
    if "watch" in chars_lower:
        return "watch"
    if "television" in chars_lower or "tv" in chars_lower:
        return "television"
    return "handset"


def _external_storage_from_props(props: dict[str, str]) -> str:
    """Derive deviceinfo_external_storage.

    ro.build.characteristics is consumed by _chassis_from_props, which the
    caller must invoke first.  Any remaining indication of SD-card support
    is inferred from the model name as a secondary signal.
    """
    model = props.get("ro.product.model", "").lower()
    if "tablet" in model:
        return "true"
    return "false"


# ── DTS synthesiser ───────────────────────────────────────────────────────────

def generate_dts(
    props: dict[str, str],
    dt_nodes: list[dict[str, Any]],
    iomem:    list[dict[str, Any]],
    irqs:     list[dict[str, Any]],
    pinctrl:  dict[str, Any],
    modules:  list[dict[str, Any]],
    sysconfig: dict[str, str] | None = None,
    dump_dir: Path | None = None,
) -> str:
    """
    Synthesise a Device Tree Source from the hardware data.

    Pops / removes consumed rows from each working-copy list/dict.
    The generated DTS is a best-effort scaffold; it will need manual
    completion before it can be compiled and used.
    *sysconfig* carries proc.cmdline and boot.cmdline from sysconfig_entry.
    *dump_dir* enables supplemental enrichment (cpuinfo, meminfo, fstab).
    """
    sys = sysconfig or {}

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

    # ── chosen node with bootargs ─────────────────────────────────────────────
    # Prefer /proc/cmdline (live kernel), then boot image header cmdline.
    kernel_cmdline = sys.get("proc.cmdline", "") or sys.get("boot.cmdline", "")
    lines += [
        "\tchosen {",
    ]
    if kernel_cmdline:
        escaped_cmdline = kernel_cmdline.replace('"', '\\"')
        lines.append(f'\t\tbootargs = "{escaped_cmdline}";')
    else:
        lines.append('\t\t/* bootargs = "...";  [? fill from boot image] */')
    lines += [
        "\t};",
        "",
    ]

    # ── CPU topology (from proc/cpuinfo when dump_dir is available) ───────────
    cpu_info = _parse_cpuinfo(dump_dir)
    if cpu_info["total"] > 0:
        lines += _generate_cpus_node(cpu_info)

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
    elif dump_dir is not None:
        # Fallback: derive memory size from /proc/meminfo when iomem is absent
        mem_bytes = _parse_meminfo(dump_dir)
        if mem_bytes:
            size = _hex_to_cells(f"{mem_bytes:x}")
            lines += [
                "\t/* Memory from /proc/meminfo — confirm base address with",
                "\t   downstream DTS or /proc/iomem */",
                "\tmemory@80000000 {",
                '\t\tdevice_type = "memory";',
                f"\t\treg = <0x0 0x80000000 {size}>; /* [? confirm base address] */",
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

        # Extract the @addr suffix for the node name (e.g. "uart@10870000")
        at_pos = last_part.find("@")
        reg_addr = last_part[at_pos + 1:] if at_pos != -1 else ""

        lines.append(f"\t\t{label}: {last_part} {{")

        # compatible — emit all strings (null-separated in DT, space after decode)
        if compat:
            compat_list = [c.strip().rstrip(",") for c in compat.split("\x00") if c.strip()]
            if not compat_list:
                compat_list = [compat.split()[0].rstrip(",")]
            compat_str = ", ".join(f'"{c}"' for c in compat_list)
            lines.append(f"\t\t\tcompatible = {compat_str};")

        # reg — use parsed binary hex cells when available; fall back to @addr stub
        if reg:
            lines.append(f"\t\t\treg = <{reg}>;")
        elif reg_addr:
            lines.append(
                f"\t\t\treg = <0x0 0x{reg_addr} 0x0 0x1000>; /* size [?] */"
            )

        # interrupts — emit as real DTS cells when available
        if interrupts:
            lines.append(f"\t\t\tinterrupts = <{interrupts}>;")

        # clocks — emit as real DTS cells when available
        if clocks:
            lines.append(f"\t\t\tclocks = <{clocks}>;")

        lines += [
            "\t\t\tstatus = \"disabled\"; /* [? enable when driver ready] */",
            "\t\t};",
            "",
        ]
        consumed_node_ids.add(node["node_id"])

    # Remove consumed nodes from working copy
    dt_nodes[:] = [n for n in dt_nodes if n["node_id"] not in consumed_node_ids]

    lines += ["\t};", ""]  # close soc

    # ── Platform peripheral stubs from fstab (UFS, USB) ──────────────────────
    periph = _parse_fstab_peripherals(dump_dir)
    ufs_entry = periph.get("ufs_block_addr", "")  # e.g. "13200000.ufs"
    if ufs_entry and "." in ufs_entry:
        ufs_addr, _, ufs_suffix = ufs_entry.partition(".")
        lines += [
            f"\t{ufs_suffix}: ufs@{ufs_addr} {{",
            '\t\tcompatible = "samsung,exynos-ufs"; /* [? verify driver compat] */',
            f"\t\treg = <0x0 0x{ufs_addr} 0x0 0x10000>; /* [? verify size] */",
            '\t\tstatus = "okay";',
            "\t};",
            "",
        ]
    usb_entry = periph.get("usb_platform_addr", "")  # e.g. "11210000.usb"
    if usb_entry and "." in usb_entry:
        usb_addr, _, usb_suffix = usb_entry.partition(".")
        lines += [
            f"\t{usb_suffix}: usb@{usb_addr} {{",
            '\t\tcompatible = "samsung,exynos-dwusb3"; /* [? verify driver compat] */',
            f"\t\treg = <0x0 0x{usb_addr} 0x0 0x10000>; /* [? verify size] */",
            '\t\tstatus = "okay";',
            "\t};",
            "",
        ]
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


# ── APKBUILD generator ────────────────────────────────────────────────────────

def generate_apkbuild(
    props: dict[str, str],
    features: set[str] | None = None,
    audio_strategies: dict[str, Any] | None = None,
) -> str:
    """Generate a postmarketOS APKBUILD scaffold for the device.

    *props* should be the full (not yet consumed) Android property dict,
    or at minimum contain the identity keys.
    *features* is the set of ``android.hardware.*`` feature names.
    *audio_strategies* is the parsed result of ``_parse_audio_strategies``.
    """
    model        = props.get("ro.product.model", "Unknown")
    manufacturer = props.get("ro.product.manufacturer", "Unknown")
    device       = props.get("ro.product.device", "unknown")
    board        = props.get("ro.product.board", device)
    brand        = props.get("ro.product.brand", manufacturer.lower())
    codename     = (board or device).lower().replace("-", "_").replace(" ", "_")
    mfr_lower    = (brand or manufacturer).lower().replace(" ", "")
    arch         = _arch_from_abi(props.get("ro.product.cpu.abi", "arm64-v8a"))

    has_nfc  = bool(features and any("nfc" in f for f in features))
    has_wifi = bool(features and any("wifi" in f for f in features))
    has_bt   = bool(features and any("bluetooth" in f for f in features))

    # Build an informative depends list
    depends_parts = [
        "postmarketos-base",
        f"linux-{mfr_lower}-{codename}",
        "mkbootimg",
    ]

    ast = audio_strategies or {}
    vendor_strat_count = len(ast.get("vendor", []))

    lines: list[str] = [
        "# Reference: <https://postmarketos.org/apkbuild>",
        "# Maintainer:",
        "# Co-Maintainer:",
        "",
        f'pkgname="device-{mfr_lower}-{codename}"',
        f'pkgdesc="{manufacturer} {model}"',
        'pkgver=1',
        'pkgrel=0',
        'url="https://postmarketos.org"',
        'license="MIT"',
        f'arch="{arch}"',
        'options="!check !archcheck"',
        f'depends="{" ".join(depends_parts)}"',
        'makedepends="devicepkg-dev"',
        f'subpackages="$pkgname-nonfree-firmware:nonfree_firmware"',
        'source="deviceinfo"',
        "",
    ]

    # Notes block
    notes: list[str] = []
    if has_nfc:
        notes.append("# NFC: driver required — check kernel config for nfc/nxp_nci or similar")
    if has_wifi:
        notes.append("# Wi-Fi: broadcom FMAC firmware usually needed (linux-firmware-brcm)")
    if has_bt:
        notes.append("# Bluetooth: btbcm / btlinux firmware needed")
    if vendor_strat_count:
        v = ast["vendor"]
        id_range = (f"{v[0]['id']}--{v[-1]['id']}" if len(v) > 1 else v[0]["id"])
        std_names = ", ".join(ast.get("standard", []))
        notes.append(
            f"# Audio: {vendor_strat_count} vendor strategies (IDs {id_range}) "
            f"+ standard ({std_names})"
        )
        notes.append(
            "#        copy audio_policy_engine_product_strategies.xml into the package"
        )
    if notes:
        lines += notes + [""]

    lines += [
        "build() {",
        "\tdevicepkg_build $startdir $pkgname",
        "}",
        "",
        "package() {",
        "\tdevicepkg_package $startdir $pkgname",
        "}",
        "",
        "nonfree_firmware() {",
        f'\tpkgdesc="Firmware blobs for {manufacturer} {model}"',
        f'\tdepends="firmware-{mfr_lower}-{codename}"',
        '\tmkdir "$subpkgdir"',
        "}",
        "",
    ]
    return "\n".join(lines)


# ── Orchestrator ──────────────────────────────────────────────────────────────

def export(
    db_path: Path,
    run_id: int | None,
    out_dir: Path,
    dump_dir: Path | None = None,
    audio_strategies_xml: Path | None = None,
) -> None:
    """
    Main export function.

    Opens *db_path* read-only, loads working copies of each table for
    *run_id* (latest run if None), generates all output files into
    *out_dir*, and prints a summary.

    *dump_dir* enables supplemental enrichment from the original collection
    directory (proc/cpuinfo, proc/meminfo, vendor/etc/permissions, fstab).
    *audio_strategies_xml* is an optional path to a ComponentTypeSet XML file
    (e.g. ``audio_policy_engine_product_strategies.xml``).
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
    sysconfig = _load_sysconfig(cur, run_id)      # dict  — bare-metal values
    dt_nodes  = _load_dt_nodes(cur, run_id)       # list  — pops as consumed
    iomem     = _load_iomem(cur, run_id)          # list
    irqs      = _load_irqs(cur, run_id)           # list
    modules   = _load_modules(cur, run_id)        # list
    hals      = _load_hals(cur, run_id)           # list
    pinctrl   = _load_pinctrl(cur, run_id)        # dict  — del as consumed
    hw_blocks = _load_hw_blocks(cur, run_id)      # list

    db.close()

    # Snapshot identity props needed for APKBUILD before generators consume them
    props_snap: dict[str, str] = {k: props[k] for k in (
        "ro.product.model", "ro.product.manufacturer", "ro.product.device",
        "ro.product.board", "ro.product.brand", "ro.product.cpu.abi",
    ) if k in props}

    total_loaded = (
        len(props) + len(dt_nodes) + len(iomem) + len(irqs)
        + len(modules) + len(hals) + len(pinctrl) + len(hw_blocks)
    )
    print(f"  Loaded {total_loaded} rows across 8 table types.")

    out_dir.mkdir(parents=True, exist_ok=True)

    # Pre-parse supplemental sources
    audio_strat = _parse_audio_strategies(audio_strategies_xml)

    # ── 1. deviceinfo ─────────────────────────────────────────────────────────
    print("  [1/6] Generating deviceinfo...")
    di_text = generate_deviceinfo(
        props, modules, sysconfig,
        dump_dir=dump_dir, audio_strategies=audio_strat,
    )
    (out_dir / "deviceinfo").write_text(di_text, encoding="utf-8")

    # ── 2. DTS ────────────────────────────────────────────────────────────────
    print("  [2/6] Synthesising DTS...")
    dts_text = generate_dts(
        props, dt_nodes, iomem, irqs, pinctrl, modules, sysconfig,
        dump_dir=dump_dir,
    )
    (out_dir / f"{codename}.dts").write_text(dts_text, encoding="utf-8")

    # ── 3. modules-initfs (remaining modules not yet placed in deviceinfo) ────
    print("  [3/6] Writing modules-initfs...")
    mod_text = generate_modules_initfs(modules)
    (out_dir / "modules-initfs").write_text(mod_text, encoding="utf-8")

    # ── 4. HAL list ───────────────────────────────────────────────────────────
    print("  [4/6] Writing HAL interface list...")
    hal_text = generate_hal_list(hals)
    (out_dir / "hal_interfaces.txt").write_text(hal_text, encoding="utf-8")

    # ── 5. Hardware summary ───────────────────────────────────────────────────
    print("  [5/6] Writing hardware block summary...")
    hw_text = generate_hw_summary(hw_blocks)
    (out_dir / "hardware_summary.txt").write_text(hw_text, encoding="utf-8")

    # ── 6. APKBUILD ───────────────────────────────────────────────────────────
    print("  [6/6] Writing APKBUILD...")
    features = _parse_permissions(dump_dir)
    apkbuild_text = generate_apkbuild(props_snap, features, audio_strat)
    (out_dir / "APKBUILD").write_text(apkbuild_text, encoding="utf-8")

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
    print(f"    APKBUILD            — postmarketOS package build script")
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
    ap.add_argument(
        "--dump", default=None,
        help=(
            "Path to the original collection dump directory.  "
            "Enables supplemental enrichment from proc/cpuinfo, proc/meminfo, "
            "vendor/etc/permissions, and fstab files."
        ),
    )
    ap.add_argument(
        "--audio-strategies", default=None, dest="audio_strategies",
        help=(
            "Path to a ComponentTypeSet XML file (e.g. "
            "audio_policy_engine_product_strategies.xml) containing "
            "ProductStrategy entries to include in deviceinfo and APKBUILD."
        ),
    )
    args = ap.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        ap.error(f"Database not found: {db_path}")

    dump_dir = Path(args.dump) if args.dump else None
    audio_xml = Path(args.audio_strategies) if args.audio_strategies else None

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

    export(db_path, args.run_id, out_dir,
           dump_dir=dump_dir, audio_strategies_xml=audio_xml)


if __name__ == "__main__":
    main()
