#!/usr/bin/env python3
"""
pipeline/report.py
==================
Generate all output artifacts from the hardware_map SQLite database:

  1. hardware_report.html  — visual table with progress bars per hardware block
  2. symbol_table.tsv      — flat export of all symbols with hardware associations
  3. ioctl_codebook.tsv    — all discovered ioctl codes with decoded metadata
  4. call_sequences/       — one JSON file per hardware block with ordered call log

Usage:
  python pipeline/report.py --db hardware_map.sqlite [--out output/]
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path


# ── HTML report ──────────────────────────────────────────────────────────────

HTML_HEAD = """\
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Hands-on-Metal Hardware Report</title>
  <style>
    body { font-family: system-ui, sans-serif; background: #0d1117; color: #c9d1d9;
           margin: 0; padding: 1rem 2rem; }
    h1   { color: #58a6ff; }
    h2   { color: #8b949e; font-size: 0.95rem; font-weight: normal; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 2rem; }
    th { background: #161b22; color: #58a6ff; text-align: left;
         padding: 0.5rem 0.75rem; border-bottom: 1px solid #30363d; font-size: 0.85rem; }
    td { padding: 0.45rem 0.75rem; border-bottom: 1px solid #21262d; font-size: 0.83rem; }
    tr:hover td { background: #161b22; }
    .bar-wrap { background: #21262d; border-radius: 4px; height: 12px;
                min-width: 120px; position: relative; }
    .bar-fill { height: 12px; border-radius: 4px; background: #238636; }
    .bar-fill.med  { background: #d29922; }
    .bar-fill.low  { background: #da3633; }
    .pct   { font-family: monospace; }
    .tag   { background: #1f6feb; color: #c9d1d9; padding: 1px 6px;
             border-radius: 3px; font-size: 0.75rem; }
    .tag.B { background: #388bfd22; color: #388bfd; border: 1px solid #388bfd55; }
    .tag.C { background: #3fb95022; color: #3fb950; border: 1px solid #3fb95055; }
    .tag.D { background: #f7853e22; color: #f7853e; border: 1px solid #f7853e55; }
    code   { background: #161b22; padding: 1px 5px; border-radius: 3px;
             font-size: 0.8rem; color: #79c0ff; }
    section.run { margin-bottom: 3rem; }
    .run-meta { background: #161b22; border: 1px solid #30363d; border-radius: 6px;
                padding: 0.75rem 1rem; margin-bottom: 1rem; font-size: 0.82rem; }
  </style>
</head>
<body>
<h1>🔩 Hands-on-Metal Hardware Intelligence Report</h1>
"""

HTML_FOOT = "</body></html>\n"


def bar(pct: float) -> str:
    cls = "low" if pct < 33 else ("med" if pct < 66 else "")
    return (
        f'<div class="bar-wrap">'
        f'<div class="bar-fill {cls}" style="width:{pct:.0f}%"></div>'
        f'</div>'
    )


def escape(s: str | None) -> str:
    if not s:
        return ""
    return (str(s)
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;"))


def render_run(cur: sqlite3.Cursor, run: dict) -> str:
    run_id = run["run_id"]
    html: list[str] = []
    html.append('<section class="run">')
    html.append(
        f'<div class="run-meta">'
        f'<strong>Run {run_id}</strong> &nbsp;|&nbsp; '
        f'Mode <span class="tag">{escape(run["mode"])}</span> &nbsp;|&nbsp; '
        f'Device: <code>{escape(run["device_model"] or "unknown")}</code> &nbsp;|&nbsp; '
        f'Platform: <code>{escape(run["ro_platform"] or "?")}</code> &nbsp;|&nbsp; '
        f'Board: <code>{escape(run["ro_board"] or "?")}</code> &nbsp;|&nbsp; '
        f'Collected: {escape(run["collected_at"])}'
        f'</div>'
    )

    # Hardware blocks table
    cur.execute(
        """SELECT name, category, hal_interface, hal_instance, pinctrl_group,
                  total_fields, filled_fields, pct_populated,
                  (SELECT COUNT(*) FROM symbol      WHERE hw_id=h.hw_id) as syms,
                  (SELECT COUNT(*) FROM ioctl_code  WHERE hw_id=h.hw_id) as ioctls,
                  (SELECT COUNT(*) FROM call_sequence WHERE hw_id=h.hw_id) as calls,
                  (SELECT COUNT(*) FROM pinctrl_group WHERE hw_id=h.hw_id) as pgrps
           FROM hardware_block h
           WHERE run_id=?
           ORDER BY pct_populated DESC, name""",
        (run_id,),
    )
    rows = cur.fetchall()

    if not rows:
        html.append("<p>No hardware blocks found for this run.</p>")
        html.append("</section>")
        return "\n".join(html)

    html.append(
        "<table>"
        "<thead><tr>"
        "<th>Hardware</th>"
        "<th>Category</th>"
        "<th>HAL Interface</th>"
        "<th>Pinctrl Group</th>"
        "<th>Symbols</th>"
        "<th>ioctl Codes</th>"
        "<th>Call Events</th>"
        "<th>Pin Groups</th>"
        "<th>Fill Rate</th>"
        "<th>%</th>"
        "</tr></thead><tbody>"
    )
    for r in rows:
        (name, cat, hal_iface, hal_inst, pctrl, total, filled, pct,
         syms, ioctls, calls, pgrps) = r
        pct = pct or 0.0
        html.append(
            f"<tr>"
            f"<td><code>{escape(name)}</code></td>"
            f"<td>{escape(cat)}</td>"
            f"<td><code>{escape(hal_iface or '')}</code></td>"
            f"<td><code>{escape(pctrl or '')}</code></td>"
            f"<td>{syms}</td>"
            f"<td>{ioctls}</td>"
            f"<td>{calls}</td>"
            f"<td>{pgrps}</td>"
            f"<td>{bar(pct)}</td>"
            f"<td class='pct'>{pct:.1f}%</td>"
            f"</tr>"
        )
    html.append("</tbody></table>")

    # Summary counts
    cur.execute(
        """SELECT
           (SELECT COUNT(*) FROM symbol         WHERE run_id=?) as sym_cnt,
           (SELECT COUNT(*) FROM vintf_hal       WHERE run_id=?) as hal_cnt,
           (SELECT COUNT(*) FROM pinctrl_pin     p
            JOIN pinctrl_controller c ON c.ctrl_id=p.ctrl_id
            WHERE c.run_id=?)                                 as pin_cnt,
           (SELECT COUNT(*) FROM ioctl_code      WHERE run_id=?) as ioctl_cnt,
           (SELECT COUNT(*) FROM call_sequence   WHERE run_id=?) as call_cnt,
           (SELECT COUNT(*) FROM dt_node         WHERE run_id=?) as dt_cnt,
           (SELECT COUNT(*) FROM collected_file  WHERE run_id=?) as file_cnt""",
        (run_id,) * 7,
    )
    s = cur.fetchone()
    html.append(
        f"<h2>Totals — "
        f"{s[0]} symbols &nbsp;·&nbsp; "
        f"{s[1]} HAL entries &nbsp;·&nbsp; "
        f"{s[2]} pins &nbsp;·&nbsp; "
        f"{s[3]} ioctl codes &nbsp;·&nbsp; "
        f"{s[4]} call events &nbsp;·&nbsp; "
        f"{s[5]} DT nodes &nbsp;·&nbsp; "
        f"{s[6]} collected files"
        f"</h2>"
    )

    html.append("</section>")
    return "\n".join(html)


def generate_html(db: sqlite3.Connection, out_path: Path) -> None:
    cur = db.cursor()
    cur.execute(
        """SELECT run_id, mode, device_model, ro_board, ro_platform,
                  ro_hardware, collected_at, source_dir
           FROM collection_run ORDER BY run_id"""
    )
    runs = [
        dict(zip(
            ["run_id","mode","device_model","ro_board","ro_platform",
             "ro_hardware","collected_at","source_dir"],
            row
        ))
        for row in cur.fetchall()
    ]

    parts = [HTML_HEAD]
    for run in runs:
        parts.append(render_run(cur, run))
    parts.append(HTML_FOOT)

    out_path.write_text("\n".join(parts), encoding="utf-8")
    print(f"  HTML report: {out_path}")


# ── symbol_table.tsv ─────────────────────────────────────────────────────────

def export_symbol_tsv(db: sqlite3.Connection, out_path: Path) -> None:
    cur = db.cursor()
    cur.execute(
        """SELECT s.run_id, h.name, h.category,
                  s.library, s.mangled, s.demangled,
                  s.sym_type, s.binding, s.section, s.address,
                  s.android_api, s.linux_equiv
           FROM symbol s
           LEFT JOIN hardware_block h ON h.hw_id = s.hw_id
           ORDER BY s.run_id, h.name, s.library, s.mangled"""
    )
    header = (
        "run_id\thw_name\tcategory\tlibrary\tmangled\tdemangled\t"
        "type\tbinding\tsection\taddress\tandroid_api\tlinux_equiv\n"
    )
    rows = cur.fetchall()
    lines = [header]
    for r in rows:
        lines.append("\t".join("" if v is None else str(v) for v in r) + "\n")
    out_path.write_text("".join(lines), encoding="utf-8")
    print(f"  Symbol table TSV: {out_path} ({len(rows)} rows)")


# ── ioctl_codebook.tsv ───────────────────────────────────────────────────────

def export_ioctl_tsv(db: sqlite3.Connection, out_path: Path) -> None:
    cur = db.cursor()
    cur.execute(
        """SELECT i.run_id, h.name, i.code_hex, i.direction,
                  i.buf_size, i.driver_name, i.description
           FROM ioctl_code i
           LEFT JOIN hardware_block h ON h.hw_id = i.hw_id
           ORDER BY i.run_id, i.code_hex"""
    )
    header = "run_id\thw_name\tcode_hex\tdirection\tbuf_size\tdriver\tdescription\n"
    rows = cur.fetchall()
    lines = [header]
    for r in rows:
        lines.append("\t".join("" if v is None else str(v) for v in r) + "\n")
    out_path.write_text("".join(lines), encoding="utf-8")
    print(f"  ioctl codebook TSV: {out_path} ({len(rows)} rows)")


# ── call_sequences/*.json ────────────────────────────────────────────────────

def export_call_sequences(db: sqlite3.Connection, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    cur = db.cursor()

    # Get all hw_ids that have call_sequence entries
    cur.execute(
        """SELECT DISTINCT cs.run_id, h.hw_id, h.name
           FROM call_sequence cs
           LEFT JOIN hardware_block h ON h.hw_id = cs.hw_id
           ORDER BY cs.run_id, h.name"""
    )
    hw_list = cur.fetchall()

    # Also export run-level sequences (hw_id IS NULL)
    run_ids: set[int] = set()
    for _, _, _ in hw_list:
        pass  # collected below

    for run_id, hw_id, hw_name in hw_list:
        hw_name = hw_name or "unknown"
        cur.execute(
            """SELECT order_idx, layer, android_fn, mangled_sym,
                      hybris_wrapper, ic.code_hex, cs.buf_hex,
                      return_value, timestamp_ns,
                      binder_iface, binder_txn_code
               FROM call_sequence cs
               LEFT JOIN ioctl_code ic ON ic.ioctl_id = cs.ioctl_id
               WHERE cs.run_id=? AND cs.hw_id IS ?
               ORDER BY order_idx""",
            (run_id, hw_id),
        )
        events = []
        for row in cur.fetchall():
            events.append({
                "order":          row[0],
                "layer":          row[1],
                "android_fn":     row[2],
                "mangled_sym":    row[3],
                "hybris_wrapper": row[4],
                "ioctl_code":     row[5],
                "buf_hex":        row[6],
                "return_value":   row[7],
                "timestamp_ns":   row[8],
                "binder_iface":   row[9],
                "binder_txn_code":row[10],
            })
        if not events:
            continue
        fname = f"run{run_id}_{hw_name.replace('/', '_')}.json"
        (out_dir / fname).write_text(
            json.dumps({"run_id": run_id, "hw_name": hw_name,
                        "events": events}, indent=2),
            encoding="utf-8",
        )

    print(f"  Call sequences: {out_dir}/ ({len(hw_list)} files)")


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Generate reports from hardware_map.sqlite")
    ap.add_argument("--db",  required=True, help="Path to hardware_map.sqlite")
    ap.add_argument("--out", default=".",   help="Output directory (default: current dir)")
    args = ap.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        print(f"Database not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    db = sqlite3.connect(str(db_path))

    print("Generating reports...")
    generate_html(db,          out / "hardware_report.html")
    export_symbol_tsv(db,      out / "symbol_table.tsv")
    export_ioctl_tsv(db,       out / "ioctl_codebook.tsv")
    export_call_sequences(db,  out / "call_sequences")

    db.close()
    print("Done.")


if __name__ == "__main__":
    main()
