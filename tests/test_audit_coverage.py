import sys
import tempfile
import unittest
from pathlib import Path


PIPELINE_DIR = Path(__file__).resolve().parents[1] / "pipeline"
if str(PIPELINE_DIR) not in sys.path:
    sys.path.insert(0, str(PIPELINE_DIR))

import audit_coverage  # noqa: E402


class StaticGapTests(unittest.TestCase):
    """Sanity checks for the static cross-reference logic."""

    def test_parse_schema_columns_extracts_known_tables(self) -> None:
        sql = """
        CREATE TABLE IF NOT EXISTS foo (
            foo_id INTEGER PRIMARY KEY,
            name   TEXT NOT NULL,
            value  TEXT,
            UNIQUE (foo_id, name)
        );
        CREATE TABLE bar (
            bar_id INTEGER PRIMARY KEY AUTOINCREMENT,
            payload TEXT
        );
        """
        tables = audit_coverage.parse_schema_columns(sql)
        self.assertEqual(set(tables.keys()), {"foo", "bar"})
        self.assertEqual(tables["foo"], {"foo_id", "name", "value"})
        self.assertEqual(tables["bar"], {"bar_id", "payload"})

    def test_collect_parser_inserts_finds_columns_in_real_parsers(self) -> None:
        # Use the actual repository parsers.  At a minimum, build_table.py
        # inserts into iomem_region with the four expected columns.
        inserts = audit_coverage.collect_parser_inserts(
            audit_coverage.PARSER_SCRIPTS
        )
        self.assertIn("iomem_region", inserts)
        self.assertTrue(
            {"start_hex", "end_hex", "name"}.issubset(inserts["iomem_region"]),
            f"missing columns in iomem_region inserts: {inserts['iomem_region']}",
        )
        # parse_manifests inserts into vintf_hal
        self.assertIn("vintf_hal", inserts)
        self.assertIn("hal_name", inserts["vintf_hal"])

    def test_static_gap_report_against_real_repo_has_no_unknown_inserts(self) -> None:
        sql = audit_coverage.SCHEMA_FILE.read_text()
        schema = audit_coverage.parse_schema_columns(sql)
        inserts = audit_coverage.collect_parser_inserts(
            audit_coverage.PARSER_SCRIPTS
        )
        report = audit_coverage.static_gap_report(schema, inserts)
        # The schema must declare every column any parser writes; otherwise
        # build_table runs would crash at runtime.
        self.assertEqual(
            report["insert_unknown"], [],
            f"INSERTs target columns missing from the schema: "
            f"{report['insert_unknown']}",
        )


class DumpAuditTests(unittest.TestCase):
    def _make_min_dump(self, root: Path) -> Path:
        dump = root / "live_dump"
        dump.mkdir()
        # Create just enough to trigger MISSING/EMPTY/OK across categories.
        (dump / "manifest.txt").write_text("getprop.txt\nboard_summary.txt\n")
        (dump / "getprop.txt").write_text("[ro.product.model]: [test]\n")
        (dump / "board_summary.txt").write_text("")           # EMPTY
        # leave encryption_state.txt MISSING
        (dump / "proc").mkdir()
        (dump / "proc" / "iomem").write_text("00-ff : Reserved\n")
        (dump / "proc" / "device-tree").mkdir()               # EMPTY dir
        return dump

    def test_per_dump_audit_classifies_files_correctly(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            dump = self._make_min_dump(Path(td))
            results = audit_coverage.per_dump_audit(dump)

        by_path = {rel: (status, sev) for status, sev, rel, _why in results}

        self.assertEqual(by_path["manifest.txt"][0], "OK")
        self.assertEqual(by_path["getprop.txt"][0], "OK")
        self.assertEqual(by_path["board_summary.txt"][0], "EMPTY")
        self.assertEqual(by_path["encryption_state.txt"][0], "MISSING")
        self.assertEqual(by_path["proc/iomem"][0], "OK")
        self.assertEqual(by_path["proc/device-tree"][0], "EMPTY")
        # An unmentioned optional artefact is reported as MISSING (optional).
        self.assertEqual(by_path["vendor_symbols"], ("MISSING", "optional"))

    def test_render_markdown_includes_static_and_dump_sections(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            dump = self._make_min_dump(Path(td))
            sql = audit_coverage.SCHEMA_FILE.read_text()
            schema = audit_coverage.parse_schema_columns(sql)
            inserts = audit_coverage.collect_parser_inserts(
                audit_coverage.PARSER_SCRIPTS
            )
            static = audit_coverage.static_gap_report(schema, inserts)
            results = audit_coverage.per_dump_audit(dump)
            md = audit_coverage.render_markdown(static, dump, results)

        self.assertIn("# hands-on-metal coverage audit", md)
        self.assertIn("## Static cross-reference", md)
        self.assertIn("Per-dump audit", md)
        self.assertIn("[MISSING]", md)
        self.assertIn("[EMPTY]", md)

    def test_main_writes_to_out_file(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            dump = self._make_min_dump(Path(td))
            out = Path(td) / "report.md"
            rc = audit_coverage.main(
                ["--static", "--dump", str(dump), "--out", str(out)]
            )
            self.assertEqual(rc, 0)
            self.assertTrue(out.exists())
            self.assertGreater(out.stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
