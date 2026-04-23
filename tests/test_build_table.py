import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


PIPELINE_DIR = Path(__file__).resolve().parents[1] / "pipeline"
if str(PIPELINE_DIR) not in sys.path:
    sys.path.insert(0, str(PIPELINE_DIR))

import build_table  # noqa: E402

TMP_SOURCE_DIR = os.path.expanduser("~/tmp")


class BuildTableTests(unittest.TestCase):
    def _db_with_schema(self) -> sqlite3.Connection:
        db = sqlite3.connect(":memory:")
        build_table.apply_schema(db)
        return db

    def test_dt_to_hw_matches_path_or_compatible(self) -> None:
        self.assertEqual(
            build_table.dt_to_hw("/soc/mdss@0", ""),
            ("display", "display"),
        )
        self.assertEqual(
            build_table.dt_to_hw("/soc/node", "qcom,cam-v1"),
            ("camera", "imaging"),
        )
        self.assertIsNone(build_table.dt_to_hw("/soc/other", "vendor,none"))

    def test_import_iomem_parses_valid_rows_only(self) -> None:
        db = self._db_with_schema()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO collection_run (mode, source_dir) VALUES (?,?)",
            ("A", TMP_SOURCE_DIR),
        )
        run_id = cur.lastrowid
        db.commit()

        with tempfile.TemporaryDirectory() as tmp:
            dump = Path(tmp)
            (dump / "proc").mkdir(parents=True)
            (dump / "proc" / "iomem").write_text(
                "\n".join(
                    [
                        "00000000-00000fff : Reserved",
                        "00100000-00100fff : System RAM",
                        "invalid line",
                    ]
                ),
                encoding="utf-8",
            )
            inserted = build_table.import_iomem(cur, run_id, dump)

        self.assertEqual(inserted, 2)
        cur.execute(
            "SELECT start_hex, end_hex, name FROM iomem_region WHERE run_id=? ORDER BY iomem_id",
            (run_id,),
        )
        self.assertEqual(
            cur.fetchall(),
            [("00000000", "00000fff", "Reserved"), ("00100000", "00100fff", "System RAM")],
        )

    def test_import_interrupts_and_lsmod_handle_noise(self) -> None:
        db = self._db_with_schema()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO collection_run (mode, source_dir) VALUES (?,?)",
            ("A", TMP_SOURCE_DIR),
        )
        run_id = cur.lastrowid
        db.commit()

        with tempfile.TemporaryDirectory() as tmp:
            dump = Path(tmp)
            (dump / "proc").mkdir(parents=True)
            (dump / "proc" / "interrupts").write_text(
                "\n".join(
                    [
                        "           CPU0       CPU1",
                        "42:        10         20   msm_gpio",
                        "NMI:       1          1    ignored",
                        "43:        5          malformed_counter   uart",
                    ]
                ),
                encoding="utf-8",
            )
            (dump / "lsmod.txt").write_text(
                "\n".join(
                    [
                        "Module                  Size  Used by",
                        "wlan                 12345  2 cfg80211",
                        "badline",
                        "bt_drv               5000   nope",
                    ]
                ),
                encoding="utf-8",
            )

            irq_inserted = build_table.import_interrupts(cur, run_id, dump)
            mod_inserted = build_table.import_lsmod(cur, run_id, dump)

        self.assertEqual(irq_inserted, 2)
        cur.execute("SELECT irq_num, count, cpu_counts, name FROM irq_entry WHERE run_id=? ORDER BY irq_num", (run_id,))
        irq_rows = cur.fetchall()
        self.assertEqual(irq_rows[0], (42, 30, json.dumps([10, 20]), "msm_gpio"))
        self.assertEqual(irq_rows[1], (43, 5, json.dumps([5]), "malformed_counter uart"))

        self.assertEqual(mod_inserted, 2)
        cur.execute("SELECT name, size, use_count, used_by FROM kernel_module WHERE run_id=? ORDER BY name", (run_id,))
        self.assertEqual(
            cur.fetchall(),
            [("bt_drv", 5000, 0, ""), ("wlan", 12345, 2, "cfg80211")],
        )

    def test_import_dt_nodes_index_files_and_update_fill_rates(self) -> None:
        db = self._db_with_schema()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO collection_run (mode, source_dir) VALUES (?,?)",
            ("A", TMP_SOURCE_DIR),
        )
        run_id = cur.lastrowid
        cur.execute(
            "INSERT INTO hardware_block (run_id, name, category, hal_interface) VALUES (?,?,?,?)",
            (run_id, "audio", "audio", "android.hardware.audio@7.0::IDevicesFactory"),
        )
        hw_id = cur.lastrowid
        cur.execute(
            "INSERT INTO symbol (run_id, hw_id, library, mangled) VALUES (?,?,?,?)",
            (run_id, hw_id, "libaudio.so", "_Z3foo"),
        )
        db.commit()

        with tempfile.TemporaryDirectory() as tmp:
            dump = Path(tmp)
            dt_audio = dump / "proc" / "device-tree" / "soc" / "audio@1"
            dt_audio.mkdir(parents=True)
            (dt_audio / "compatible").write_bytes(b"qcom,audio\x00")
            (dt_audio / "reg").write_bytes(b"0x01\x00")
            (dt_audio / "interrupts").write_bytes(b"5\x00")
            (dt_audio / "clocks").write_bytes(b"xo\x00")

            manifest = dump / "manifest.txt"
            manifest.write_text("/proc/device-tree/soc/audio@1/compatible\n/missing/file\n", encoding="utf-8")

            dt_inserted = build_table.import_dt_nodes(cur, run_id, dump)
            file_inserted = build_table.index_files(cur, run_id, dump, manifest)
            db.commit()

        self.assertGreaterEqual(dt_inserted, 1)
        self.assertEqual(file_inserted, 2)

        cur.execute("SELECT COUNT(*) FROM dt_node WHERE run_id=?", (run_id,))
        self.assertGreater(cur.fetchone()[0], 0)
        cur.execute("SELECT COUNT(*) FROM hardware_block WHERE run_id=? AND name='audio'", (run_id,))
        self.assertEqual(cur.fetchone()[0], 1)

        build_table.update_fill_rates(db, run_id)
        cur.execute("SELECT total_fields, filled_fields FROM hardware_block WHERE hw_id=?", (hw_id,))
        total_fields, filled_fields = cur.fetchone()
        self.assertEqual(total_fields, len(build_table.FIELD_CHECKS) + 1)
        self.assertGreaterEqual(filled_fields, 3)  # hal_interface + symbol + dt_node

    def test_update_fill_rates_rejects_invalid_identifiers(self) -> None:
        db = self._db_with_schema()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO collection_run (mode, source_dir) VALUES (?,?)",
            ("A", TMP_SOURCE_DIR),
        )
        run_id = cur.lastrowid
        cur.execute(
            "INSERT INTO hardware_block (run_id, name, category) VALUES (?,?,?)",
            (run_id, "display", "display"),
        )
        db.commit()

        original = build_table.FIELD_CHECKS
        try:
            build_table.FIELD_CHECKS = [("valid_table", "invalid@column", "x")]
            with self.assertRaises(ValueError):
                build_table.update_fill_rates(db, run_id)
        finally:
            build_table.FIELD_CHECKS = original

    def test_read_dt_cells_parses_binary_reg(self) -> None:
        """_read_dt_cells must decode big-endian uint32 arrays correctly."""
        import struct
        import tempfile
        raw = struct.pack(">4I", 0, 0x10400000, 0x10000, 0)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "reg"
            p.write_bytes(raw)
            result = build_table._read_dt_cells(p)
        self.assertIn("0x10400000", result)
        self.assertIn("0x10000", result)
        self.assertIn("0x0", result)

    def test_read_dt_cells_returns_empty_for_non_multiple_of_4(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "reg"
            p.write_bytes(b"\x01\x02\x03")  # 3 bytes — not divisible by 4
            result = build_table._read_dt_cells(p)
        self.assertEqual(result, "")

    def test_read_dt_cells_returns_empty_for_missing_file(self) -> None:
        result = build_table._read_dt_cells(Path("/nonexistent/reg"))
        self.assertEqual(result, "")

    def test_import_dt_nodes_stores_hex_reg(self) -> None:
        """reg values in dt_node must be hex strings, not garbled binary."""
        import struct
        db = self._db_with_schema()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO collection_run (mode, source_dir) VALUES (?,?)",
            ("A", TMP_SOURCE_DIR),
        )
        run_id = cur.lastrowid
        db.commit()

        with tempfile.TemporaryDirectory() as tmp:
            dump = Path(tmp)
            uart_dir = dump / "proc" / "device-tree" / "soc" / "uart@10870000"
            uart_dir.mkdir(parents=True)
            (uart_dir / "compatible").write_bytes(b"samsung,exynos-uart\x00")
            # reg = <0x00 0x10870000 0x100>  (3 cells, 12 bytes)
            (uart_dir / "reg").write_bytes(struct.pack(">3I", 0, 0x10870000, 0x100))

            build_table.import_dt_nodes(cur, run_id, dump)
            db.commit()

        cur.execute("SELECT reg FROM dt_node WHERE run_id=?", (run_id,))
        row = cur.fetchone()
        self.assertIsNotNone(row)
        self.assertIn("0x10870000", row[0])

    def test_import_cmdline_stores_value(self) -> None:
        db = self._db_with_schema()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO collection_run (mode, source_dir) VALUES (?,?)",
            ("A", TMP_SOURCE_DIR),
        )
        run_id = cur.lastrowid
        db.commit()

        with tempfile.TemporaryDirectory() as tmp:
            dump = Path(tmp)
            proc_dir = dump / "proc"
            proc_dir.mkdir()
            (proc_dir / "cmdline").write_text(
                "earlycon=exynos4210,0x10870000 console=ttySAC0,115200\x00",
                encoding="utf-8",
            )
            build_table.import_cmdline(cur, run_id, dump)
            db.commit()

        cur.execute(
            "SELECT value FROM sysconfig_entry WHERE run_id=? AND key=?",
            (run_id, "proc.cmdline"),
        )
        row = cur.fetchone()
        self.assertIsNotNone(row)
        self.assertIn("earlycon=exynos4210", row[0])

    def test_exynos_dt_hints_recognised(self) -> None:
        self.assertEqual(
            build_table.dt_to_hw("/soc/uart@10870000", "samsung,exynos-uart"),
            ("uart", "misc"),
        )
        self.assertEqual(
            build_table.dt_to_hw("/soc/ufs@13200000", "samsung,exynos-ufs"),
            ("storage", "misc"),
        )
        self.assertEqual(
            build_table.dt_to_hw("/soc/pmu@15460000", "samsung,gs101-pmu"),
            ("power", "power"),
        )


if __name__ == "__main__":
    unittest.main()
