#!/usr/bin/env python3
"""
pipeline/audit_coverage.py
==========================
Static cross-reference and per-dump completeness audit for the
hands-on-metal hardware-data pipeline.

Two modes (combinable):

  --static       Emit a Markdown gap report cross-referencing:
                   • files written by collect.sh / collect_recovery.sh
                   • files read by pipeline/parse_*.py + unpack_images.py
                   • tables/columns declared in schema/hardware_map.sql
                 The report identifies:
                   1. Collected-but-never-parsed paths
                   2. Parsed-but-never-collected paths
                   3. Schema-orphan columns (in schema, no parser INSERT)
                   4. INSERTs targeting columns missing from the schema

  --dump <dir>   Emit a per-dump [MISSING]/[EMPTY] audit listing each
                 expected artefact under <dir> (matching the existing
                 sanity-check style used by collect.sh).

Output is Markdown by default; pass --out <file> to write to disk
instead of stdout.  The script depends only on the Python standard
library so it can run in the same minimal environments as the rest of
the pipeline.

Usage:
  python pipeline/audit_coverage.py --static
  python pipeline/audit_coverage.py --dump ./live_dump
  python pipeline/audit_coverage.py --static --dump ./live_dump --out audit.md
"""

from __future__ import annotations

import argparse
import io
import re
import sys
from pathlib import Path


# ── Repository layout ───────────────────────────────────────────────────────
HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SCHEMA_FILE = REPO / "schema" / "hardware_map.sql"
COLLECT_SCRIPTS = (
    REPO / "magisk-module" / "collect.sh",
    REPO / "recovery-zip" / "collect_recovery.sh",
)
PARSER_SCRIPTS = sorted(
    list(HERE.glob("parse_*.py"))
    + [HERE / "unpack_images.py", HERE / "build_table.py"]
)


# ── Static cross-reference data ─────────────────────────────────────────────
# Each entry is (relative path under live_dump/, producing script).
# Keep this list in sync when collect.sh / collect_recovery.sh change.
COLLECTED_ARTIFACTS: list[tuple[str, str]] = [
    # Mode A — live root-adaptive collector
    ("getprop.txt",                            "magisk-module/collect.sh"),
    ("lshal.txt",                              "magisk-module/collect.sh"),
    ("lshal_full.txt",                         "magisk-module/collect.sh"),
    ("dmesg.txt",                              "magisk-module/collect.sh"),
    ("lsmod.txt",                              "magisk-module/collect.sh"),
    ("modinfo.txt",                            "magisk-module/collect.sh"),
    ("board_summary.txt",                      "magisk-module/collect.sh"),
    ("encryption_state.txt",                   "magisk-module/collect.sh"),
    ("dmsetup_table.txt",                      "magisk-module/collect.sh"),
    ("dmsetup_info.txt",                       "magisk-module/collect.sh"),
    ("dmsetup_ls.txt",                         "magisk-module/collect.sh"),
    ("manifest.txt",                           "magisk-module/collect.sh"),
    ("collect.log",                            "magisk-module/collect.sh"),
    ("proc/cmdline",                           "magisk-module/collect.sh"),
    ("proc/iomem",                             "magisk-module/collect.sh"),
    ("proc/interrupts",                        "magisk-module/collect.sh"),
    ("proc/clocks",                            "magisk-module/collect.sh"),
    ("proc/cpuinfo",                           "magisk-module/collect.sh"),
    ("proc/meminfo",                           "magisk-module/collect.sh"),
    ("proc/version",                           "magisk-module/collect.sh"),
    ("proc/devices",                           "magisk-module/collect.sh"),
    ("proc/misc",                              "magisk-module/collect.sh"),
    ("proc/device-tree/",                      "magisk-module/collect.sh"),
    ("sys/kernel/debug/pinctrl/",              "magisk-module/collect.sh"),
    ("sys/bus/platform/devices/",              "magisk-module/collect.sh"),
    ("sys/class/display/",                     "magisk-module/collect.sh"),
    ("sys/class/graphics/",                    "magisk-module/collect.sh"),
    ("sys/class/drm/",                         "magisk-module/collect.sh"),
    ("sys/class/backlight/",                   "magisk-module/collect.sh"),
    ("sys/class/camera/",                      "magisk-module/collect.sh"),
    ("sys/class/video4linux/",                 "magisk-module/collect.sh"),
    ("sys/class/sound/",                       "magisk-module/collect.sh"),
    ("sys/class/input/",                       "magisk-module/collect.sh"),
    ("sys/class/thermal/",                     "magisk-module/collect.sh"),
    ("sys/class/power_supply/",                "magisk-module/collect.sh"),
    ("sys/class/led/",                         "magisk-module/collect.sh"),
    ("sys/class/regulator/",                   "magisk-module/collect.sh"),
    ("sys/class/gpio/",                        "magisk-module/collect.sh"),
    ("sys/class/pwm/",                         "magisk-module/collect.sh"),
    ("sys/class/i2c/",                         "magisk-module/collect.sh"),
    ("sys/class/spi/",                         "magisk-module/collect.sh"),
    ("sys/class/uio/",                         "magisk-module/collect.sh"),
    ("sys/class/firmware-info/",               "magisk-module/collect.sh"),
    ("sys/bus/i2c/devices/",                   "magisk-module/collect.sh"),
    ("sys/bus/spi/devices/",                   "magisk-module/collect.sh"),
    ("sys/module/dm_crypt/",                   "magisk-module/collect.sh"),
    ("sys/module/dm_verity/",                  "magisk-module/collect.sh"),
    ("vendor/etc/manifest.xml",                "magisk-module/collect.sh"),
    ("vendor/etc/vintf/",                      "magisk-module/collect.sh"),
    ("vendor/etc/sysconfig/",                  "magisk-module/collect.sh"),
    ("vendor/etc/permissions/",                "magisk-module/collect.sh"),
    ("vendor/etc/init/",                       "magisk-module/collect.sh"),
    ("vendor/etc/selinux/",                    "magisk-module/collect.sh"),
    ("vendor/etc/compatibility_matrix.xml",    "magisk-module/collect.sh"),
    ("system/etc/manifest.xml",                "magisk-module/collect.sh"),
    ("system/etc/vintf/",                      "magisk-module/collect.sh"),
    ("system/etc/sysconfig/",                  "magisk-module/collect.sh"),
    ("system/etc/permissions/",                "magisk-module/collect.sh"),
    ("system/etc/init/",                       "magisk-module/collect.sh"),
    ("system/etc/compatibility_matrix.xml",    "magisk-module/collect.sh"),
    ("odm/etc/manifest.xml",                   "magisk-module/collect.sh"),
    ("odm/etc/vintf/",                         "magisk-module/collect.sh"),
    ("odm/etc/sysconfig/",                     "magisk-module/collect.sh"),
    ("odm/etc/permissions/",                   "magisk-module/collect.sh"),
    ("odm/etc/init/",                          "magisk-module/collect.sh"),
    ("vendor_symbols/",                        "magisk-module/collect.sh"),
    ("vendor_elf/",                            "magisk-module/collect.sh"),
    ("boot_images/boot.img",                   "magisk-module/collect.sh"),
    ("boot_images/vendor_boot.img",            "magisk-module/collect.sh"),
    ("boot_images/recovery.img",               "magisk-module/collect.sh"),
    ("boot_images/init_boot.img",              "magisk-module/collect.sh"),

    # Mode B — recovery collector (writes under recovery_dump/, but the
    # pipeline pulls them into the same on-host dump directory layout).
    ("boot_images/dtbo.img",                   "recovery-zip/collect_recovery.sh"),
    ("recovery_manifest.txt",                  "recovery-zip/collect_recovery.sh"),
    ("collect_recovery.log",                   "recovery-zip/collect_recovery.sh"),
]


# Each entry: (relative path / pattern, parser script).  A trailing '/'
# means "directory tree".  Globs ('**', '*') are matched textually here;
# the static gap analysis treats them as wildcards when comparing with
# COLLECTED_ARTIFACTS.
PARSED_ARTIFACTS: list[tuple[str, str]] = [
    ("getprop.txt",                            "pipeline/parse_manifests.py"),
    ("board_summary.txt",                      "pipeline/parse_manifests.py"),
    ("**/manifest.xml",                        "pipeline/parse_manifests.py"),
    ("**/vintf/**/*.xml",                      "pipeline/parse_manifests.py"),
    ("**/compatibility_matrix*.xml",           "pipeline/parse_manifests.py"),
    ("**/sysconfig/**/*.xml",                  "pipeline/parse_manifests.py"),
    ("**/permissions/**/*.xml",                "pipeline/parse_manifests.py"),
    ("vendor_symbols/",                        "pipeline/parse_symbols.py"),
    ("vendor_elf/",                            "pipeline/parse_symbols.py"),
    ("sys/kernel/debug/pinctrl/",              "pipeline/parse_pinctrl.py"),
    ("proc/iomem",                             "pipeline/build_table.py"),
    ("proc/interrupts",                        "pipeline/build_table.py"),
    ("proc/device-tree/",                      "pipeline/build_table.py"),
    ("lsmod.txt",                              "pipeline/build_table.py"),
    ("manifest.txt",                           "pipeline/build_table.py"),
    ("hom_shim.jsonl",                         "pipeline/build_table.py"),
    ("partitions/",                            "pipeline/unpack_images.py"),
    ("boot_images/",                           "pipeline/unpack_images.py"),
]


# Per-dump expectation list.  severity ∈ {required, recommended, optional}.
# kind ∈ {file, dir}.
EXPECTED_PER_DUMP: list[tuple[str, str, str, str]] = [
    # (relative path, kind, severity, reason)
    ("manifest.txt",                  "file", "required",
        "manifest of every captured file (used by build_table.index_files)"),
    ("getprop.txt",                   "file", "required",
        "Android properties (parse_manifests.parse_getprop)"),
    ("board_summary.txt",             "file", "required",
        "ro.* board props (parse_manifests.parse_board_summary)"),
    ("collect.log",                   "file", "recommended",
        "collector log (helps diagnose [SKIP]/[WARN] paths)"),
    ("encryption_state.txt",          "file", "recommended",
        "FDE/FBE classification source"),
    ("lshal.txt",                     "file", "recommended",
        "HAL service list"),
    ("lsmod.txt",                     "file", "recommended",
        "kernel modules (build_table.import_lsmod)"),
    ("dmesg.txt",                     "file", "optional",
        "root-only kernel log"),
    ("modinfo.txt",                   "file", "optional",
        "root-only module info"),

    ("proc/cmdline",                  "file", "recommended",
        "kernel boot args"),
    ("proc/iomem",                    "file", "recommended",
        "memory map (build_table.import_iomem)"),
    ("proc/interrupts",               "file", "recommended",
        "IRQ table (build_table.import_interrupts)"),
    ("proc/cpuinfo",                  "file", "recommended", "CPU info"),
    ("proc/meminfo",                  "file", "recommended", "RAM totals"),
    ("proc/version",                  "file", "recommended", "kernel version"),

    ("proc/device-tree",              "dir",  "recommended",
        "DT walk (build_table.import_dt_nodes)"),
    ("sys/kernel/debug/pinctrl",      "dir",  "optional",
        "pinctrl mapping, root-only"),
    ("sys/class/regulator",           "dir",  "recommended",
        "regulator microvolts (display adapter analysis)"),
    ("sys/class/display",             "dir",  "recommended",
        "display adapter sysfs"),
    ("sys/class/thermal",             "dir",  "recommended",
        "thermal zones"),
    ("sys/class/power_supply",        "dir",  "recommended",
        "battery / charger"),

    ("vendor_symbols",                "dir",  "optional",
        "nm output, root-only (parse_symbols)"),
    ("vendor_elf",                    "dir",  "optional",
        "readelf output, root-only"),
    ("boot_images",                   "dir",  "optional",
        "raw boot/vendor_boot/dtbo.img (unpack_images)"),
]


# ── Schema parser ───────────────────────────────────────────────────────────
_CREATE_TABLE_RE = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\((.*?)\);",
    re.IGNORECASE | re.DOTALL,
)
_INSERT_RE = re.compile(
    r"INSERT(?:\s+OR\s+\w+)?\s+INTO\s+(\w+)\s*\(([^)]+)\)",
    re.IGNORECASE,
)


def parse_schema_columns(sql: str) -> dict[str, set[str]]:
    """Return {table_name: {column_name, ...}} from the schema SQL."""
    tables: dict[str, set[str]] = {}
    for m in _CREATE_TABLE_RE.finditer(sql):
        name = m.group(1)
        body = m.group(2)
        cols: set[str] = set()
        for raw in _split_columns(body):
            line = raw.strip()
            if not line:
                continue
            tokens = line.split()
            if not tokens:
                continue
            head = tokens[0]
            head_up = head.upper()
            # Skip table-level constraints
            if head_up in {
                "PRIMARY", "UNIQUE", "FOREIGN", "CHECK", "CONSTRAINT", "INDEX",
            }:
                continue
            # Identifier validation
            if re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*$", head):
                cols.add(head)
        tables[name] = cols
    return tables


def _split_columns(body: str) -> list[str]:
    """Split a CREATE TABLE body on top-level commas (ignoring those inside
    parenthesised expressions like CHECK(...) or GENERATED AS (...))."""
    parts: list[str] = []
    depth = 0
    buf: list[str] = []
    for ch in body:
        if ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            depth -= 1
            buf.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        parts.append("".join(buf))
    return parts


def collect_parser_inserts(parser_files: list[Path]) -> dict[str, set[str]]:
    """Return {table_name: {column_name written by some parser, ...}}."""
    result: dict[str, set[str]] = {}
    for f in parser_files:
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        for m in _INSERT_RE.finditer(text):
            table = m.group(1)
            cols = [c.strip() for c in m.group(2).split(",") if c.strip()]
            result.setdefault(table, set()).update(cols)
    return result


# ── Static gap analysis ─────────────────────────────────────────────────────

def _norm(p: str) -> str:
    """Drop trailing slash (so 'foo/' == 'foo' for set comparison)."""
    return p.rstrip("/")


def _matches_collected(parsed: str, collected_paths: set[str]) -> bool:
    """Return True if a parsed path/glob is plausibly satisfied by something
    the collector writes.  Globs are treated leniently — we only check that
    *some* collected path could feed the pattern."""
    parsed = parsed.strip()
    if "*" not in parsed:
        # Direct path or directory tree
        n = _norm(parsed)
        if n in collected_paths:
            return True
        # Directory-tree match: any collected path under this prefix counts
        return any(c == n or c.startswith(n + "/") for c in collected_paths)

    # Glob: match the suffix after the last '**' or '*'.
    # We extract the literal segments around the wildcards and consider the
    # pattern satisfied if some collected path either contains every literal
    # segment, or sits in a relevant ancestor directory and shares the
    # pattern's file-extension suffix.
    # e.g. "**/vintf/**/*.xml" → look for any collected path containing
    # "/vintf/" and ending in ".xml" (or a directory likely to contain such).
    suffix = parsed.split("*")[-1]   # e.g. ".xml" or "manifest.xml"
    needles = [seg for seg in re.split(r"\*+", parsed) if seg and seg != "/"]
    for c in collected_paths:
        if all(n.strip("/") in c for n in needles):
            return True
        # File-extension fallback for directory trees
        if suffix and not c.endswith("/") and c.endswith(suffix):
            return True
        if needles and any(n.strip("/") in c for n in needles):
            # Directory tree — treat as a satisfying ancestor
            if any(c.startswith(n.strip("/")) or n.strip("/") in c
                   for n in needles):
                return True
    return False


def static_gap_report(
    schema_tables: dict[str, set[str]],
    parser_inserts: dict[str, set[str]],
) -> dict[str, object]:
    parsed_paths = {_norm(p) for p, _ in PARSED_ARTIFACTS}
    collected_paths = {_norm(p) for p, _ in COLLECTED_ARTIFACTS}

    # 1. Collected-but-never-parsed
    collected_unused: list[tuple[str, str]] = []
    for path, src in COLLECTED_ARTIFACTS:
        if not _matches_parsed(_norm(path), parsed_paths):
            collected_unused.append((path, src))

    # 2. Parsed-but-never-collected
    parsed_unsatisfied: list[tuple[str, str]] = []
    for path, parser in PARSED_ARTIFACTS:
        if not _matches_collected(path, collected_paths):
            parsed_unsatisfied.append((path, parser))

    # 3a. Schema columns with no parser INSERT
    schema_orphan: list[tuple[str, str]] = []
    for table, cols in schema_tables.items():
        written = parser_inserts.get(table, set())
        for col in sorted(cols):
            # Skip surrogate primary keys and bookkeeping columns that are
            # populated by AUTOINCREMENT or SQL DEFAULT clauses, not by
            # explicit INSERT column lists.
            if col.endswith("_id") and col == _pk_for(table):
                continue
            if col in {"updated_at", "collected_at", "pct_populated"}:
                continue
            if col not in written:
                schema_orphan.append((table, col))

    # 3b. INSERT to columns not in the schema
    insert_unknown: list[tuple[str, str]] = []
    for table, cols in parser_inserts.items():
        schema_cols = schema_tables.get(table)
        if schema_cols is None:
            insert_unknown.append((table, "<unknown table>"))
            continue
        for col in sorted(cols):
            if col not in schema_cols:
                insert_unknown.append((table, col))

    return {
        "collected_unused": collected_unused,
        "parsed_unsatisfied": parsed_unsatisfied,
        "schema_orphan": schema_orphan,
        "insert_unknown": insert_unknown,
    }


def _pk_for(table: str) -> str:
    """Return the conventional primary-key column name for a schema table.
    The hardware_map.sql convention is '<short>_id' (e.g. hardware_block →
    hw_id, vintf_hal → vhal_id).  We just look at the existing first column
    in the tables dict — but to keep this pure we hard-code the mapping."""
    return {
        "collection_run":       "run_id",
        "android_prop":         "prop_id",
        "hardware_block":       "hw_id",
        "symbol":               "sym_id",
        "pinctrl_controller":   "ctrl_id",
        "pinctrl_pin":          "pin_id",
        "pinctrl_group":        "grp_id",
        "pinctrl_group_pin":    "",     # composite
        "vintf_hal":            "vhal_id",
        "sysconfig_entry":      "sc_id",
        "ioctl_code":           "ioctl_id",
        "call_sequence":        "call_id",
        "dt_node":              "node_id",
        "iomem_region":         "iomem_id",
        "irq_entry":            "irq_id",
        "kernel_module":        "mod_id",
        "collected_file":       "file_id",
        "env_var":              "env_id",
    }.get(table, "")


def _matches_parsed(collected: str, parsed_paths: set[str]) -> bool:
    """Return True if a collected path is consumed by some parser pattern."""
    # Direct or directory-tree match
    if collected in parsed_paths:
        return True
    for p in parsed_paths:
        if collected.startswith(p + "/") or p.startswith(collected + "/"):
            return True
    # Glob-style match against PARSED_ARTIFACTS (handles **/manifest.xml etc.)
    base = collected.rsplit("/", 1)[-1]
    for pat, _ in PARSED_ARTIFACTS:
        pat_norm = _norm(pat)
        if "*" in pat_norm:
            needles = [seg for seg in re.split(r"\*+", pat_norm)
                       if seg and seg != "/"]
            if needles and all(n.strip("/") in collected for n in needles):
                return True
            suffix = pat_norm.split("*")[-1]
            if suffix and base.endswith(suffix.lstrip("/")):
                # Confirm it sits under a directory the parser scans
                # (e.g. "vintf" or "sysconfig")
                if any(n.strip("/") in collected for n in needles):
                    return True
    return False


# ── Per-dump audit ──────────────────────────────────────────────────────────

def per_dump_audit(dump: Path) -> list[tuple[str, str, str, str]]:
    """Return list of (status, severity, rel_path, reason).

    status ∈ {OK, EMPTY, MISSING}.
    """
    results: list[tuple[str, str, str, str]] = []
    for rel, kind, severity, reason in EXPECTED_PER_DUMP:
        target = dump / rel
        if kind == "file":
            if not target.exists():
                results.append(("MISSING", severity, rel, reason))
            elif not target.is_file():
                results.append(("MISSING", severity, rel,
                                f"{reason} (expected file, found other)"))
            else:
                try:
                    size = target.stat().st_size
                except OSError:
                    size = 0
                if size == 0:
                    results.append(("EMPTY", severity, rel, reason))
                else:
                    results.append(("OK", severity, rel, reason))
        else:  # dir
            if not target.exists():
                results.append(("MISSING", severity, rel, reason))
            elif not target.is_dir():
                results.append(("MISSING", severity, rel,
                                f"{reason} (expected dir, found other)"))
            else:
                try:
                    has_any = any(target.iterdir())
                except OSError:
                    has_any = False
                if not has_any:
                    results.append(("EMPTY", severity, rel, reason))
                else:
                    results.append(("OK", severity, rel, reason))
    return results


# ── Markdown rendering ──────────────────────────────────────────────────────

def render_markdown(
    static: dict[str, object] | None,
    dump_path: Path | None,
    dump_results: list[tuple[str, str, str, str]] | None,
) -> str:
    out = io.StringIO()
    out.write("# hands-on-metal coverage audit\n\n")

    if static is not None:
        collected_unused = static["collected_unused"]      # type: ignore[index]
        parsed_unsatisfied = static["parsed_unsatisfied"]  # type: ignore[index]
        schema_orphan = static["schema_orphan"]            # type: ignore[index]
        insert_unknown = static["insert_unknown"]          # type: ignore[index]

        out.write("## Static cross-reference\n\n")
        out.write(
            f"- collectors scanned: "
            f"{', '.join(str(p.relative_to(REPO)) for p in COLLECT_SCRIPTS)}\n"
        )
        out.write(
            f"- parsers scanned: "
            f"{', '.join(str(p.relative_to(REPO)) for p in PARSER_SCRIPTS)}\n"
        )
        out.write(f"- schema: {SCHEMA_FILE.relative_to(REPO)}\n\n")

        out.write("### 1. Collected but never parsed\n\n")
        if not collected_unused:
            out.write("_None — every collected artefact is consumed._\n\n")
        else:
            out.write("| path | written by |\n|---|---|\n")
            for path, src in collected_unused:  # type: ignore[misc]
                out.write(f"| `{path}` | `{src}` |\n")
            out.write("\n")

        out.write("### 2. Parsed but never collected\n\n")
        if not parsed_unsatisfied:
            out.write("_None — every parser input is produced by a collector._\n\n")
        else:
            out.write("| path / glob | parser |\n|---|---|\n")
            for path, parser in parsed_unsatisfied:  # type: ignore[misc]
                out.write(f"| `{path}` | `{parser}` |\n")
            out.write("\n")

        out.write("### 3a. Schema columns with no parser INSERT\n\n")
        if not schema_orphan:
            out.write("_None — every schema column is written by some parser._\n\n")
        else:
            out.write("| table | column |\n|---|---|\n")
            for table, col in schema_orphan:  # type: ignore[misc]
                out.write(f"| `{table}` | `{col}` |\n")
            out.write("\n")

        out.write("### 3b. INSERTs targeting columns missing from the schema\n\n")
        if not insert_unknown:
            out.write("_None — every INSERT column is declared in the schema._\n\n")
        else:
            out.write("| table | column |\n|---|---|\n")
            for table, col in insert_unknown:  # type: ignore[misc]
                out.write(f"| `{table}` | `{col}` |\n")
            out.write("\n")

    if dump_path is not None and dump_results is not None:
        out.write(f"## Per-dump audit: `{dump_path}`\n\n")
        counts: dict[str, int] = {"OK": 0, "EMPTY": 0, "MISSING": 0}
        for status, _sev, _rel, _why in dump_results:
            counts[status] = counts.get(status, 0) + 1
        out.write(
            f"- OK: **{counts['OK']}**, EMPTY: **{counts['EMPTY']}**, "
            f"MISSING: **{counts['MISSING']}**\n\n"
        )
        out.write("| status | severity | path | reason |\n|---|---|---|---|\n")
        # Sort: required-missing first, then required-empty, then everything
        # else, then OK.
        sev_order = {"required": 0, "recommended": 1, "optional": 2}
        st_order = {"MISSING": 0, "EMPTY": 1, "OK": 2}
        for status, sev, rel, why in sorted(
            dump_results,
            key=lambda r: (st_order[r[0]], sev_order.get(r[1], 9), r[2]),
        ):
            tag = f"`[{status}]`"
            out.write(f"| {tag} | {sev} | `{rel}` | {why} |\n")
        out.write("\n")

    return out.getvalue()


# ── Main ────────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Coverage audit for hands-on-metal collectors, "
                    "parsers, and schema."
    )
    ap.add_argument("--static", action="store_true",
                    help="Emit the static cross-reference gap report.")
    ap.add_argument("--dump", default=None,
                    help="Path to a live_dump/ directory to audit for "
                         "missing/empty artefacts.")
    ap.add_argument("--out", default=None,
                    help="Write the report to a file (default: stdout).")
    ap.add_argument("--strict", action="store_true",
                    help="Exit non-zero if any required artefact is "
                         "MISSING or EMPTY in --dump, or if either gap "
                         "set is non-empty in --static.")
    args = ap.parse_args(argv)

    if not args.static and not args.dump:
        # Default to both static and (if available) ./live_dump
        args.static = True

    static_data = None
    if args.static:
        sql_text = SCHEMA_FILE.read_text() if SCHEMA_FILE.exists() else ""
        schema_tables = parse_schema_columns(sql_text)
        parser_inserts = collect_parser_inserts(PARSER_SCRIPTS)
        static_data = static_gap_report(schema_tables, parser_inserts)

    dump_results = None
    dump_path: Path | None = None
    if args.dump:
        dump_path = Path(args.dump)
        if not dump_path.exists():
            print(f"ERROR: --dump path does not exist: {dump_path}",
                  file=sys.stderr)
            return 2
        dump_results = per_dump_audit(dump_path)

    md = render_markdown(static_data, dump_path, dump_results)

    if args.out:
        Path(args.out).write_text(md, encoding="utf-8")
    else:
        sys.stdout.write(md)

    if args.strict:
        bad = 0
        if dump_results:
            bad += sum(
                1 for status, sev, _, _ in dump_results
                if sev == "required" and status in ("MISSING", "EMPTY")
            )
        if static_data:
            bad += len(static_data["parsed_unsatisfied"])  # type: ignore[arg-type]
            bad += len(static_data["insert_unknown"])      # type: ignore[arg-type]
        if bad:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
