import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

PIPELINE_DIR = Path(__file__).resolve().parents[1] / "pipeline"
if str(PIPELINE_DIR) not in sys.path:
    sys.path.insert(0, str(PIPELINE_DIR))

import build_table              # noqa: E402
import export_postmarketos as ep # noqa: E402


def _db_with_run() -> tuple[sqlite3.Connection, int]:
    """Return an in-memory DB with schema applied and one collection_run row."""
    db = sqlite3.connect(":memory:")
    build_table.apply_schema(db)
    cur = db.cursor()
    cur.execute(
        """INSERT INTO collection_run
           (mode, device_model, ro_board, ro_platform, ro_hardware)
           VALUES (?,?,?,?,?)""",
        ("A", "Test Device", "testboard", "testplatform", "testhw"),
    )
    run_id = cur.lastrowid
    db.commit()
    return db, run_id


class SafeIdentTests(unittest.TestCase):
    def test_alphanumeric_passthrough(self) -> None:
        self.assertEqual(ep._safe_ident("abc_123"), "abc_123")

    def test_spaces_and_dashes_converted(self) -> None:
        self.assertEqual(ep._safe_ident("my-node name"), "my_node_name")

    def test_leading_digit_prefixed(self) -> None:
        self.assertFalse(ep._safe_ident("1node")[0].isdigit())

    def test_empty_string_returns_node(self) -> None:
        self.assertEqual(ep._safe_ident(""), "node")


class HexToCellsTests(unittest.TestCase):
    def test_two_cell_default(self) -> None:
        result = ep._hex_to_cells("80000000")
        self.assertIn("0x80000000", result)

    def test_single_cell_mode(self) -> None:
        result = ep._hex_to_cells("80000000", addr_cells=1)
        self.assertEqual(result, "0x80000000")

    def test_invalid_hex(self) -> None:
        self.assertEqual(ep._hex_to_cells("notahex"), "0x0 0x0")


class ArchFromAbiTests(unittest.TestCase):
    def test_arm64(self) -> None:
        self.assertEqual(ep._arch_from_abi("arm64-v8a"), "aarch64")

    def test_armv7(self) -> None:
        self.assertEqual(ep._arch_from_abi("armeabi-v7a"), "armhf")

    def test_x86_64(self) -> None:
        self.assertEqual(ep._arch_from_abi("x86_64"), "x86_64")

    def test_unknown_defaults_to_aarch64(self) -> None:
        self.assertEqual(ep._arch_from_abi("mips"), "aarch64")


class LoadPropsTests(unittest.TestCase):
    def test_load_props_returns_dict(self) -> None:
        db, run_id = _db_with_run()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO android_prop (run_id, key, value) VALUES (?,?,?)",
            (run_id, "ro.product.model", "PixelTest"),
        )
        db.commit()
        props = ep._load_props(cur, run_id)
        self.assertIsInstance(props, dict)
        self.assertEqual(props.get("ro.product.model"), "PixelTest")


class GenerateDeviceinfoTests(unittest.TestCase):
    def _props(self) -> dict[str, str]:
        return {
            "ro.product.model":        "Test Device",
            "ro.product.manufacturer": "ACME",
            "ro.product.device":       "testdevice",
            "ro.board.platform":       "testplatform",
            "ro.hardware":             "testhw",
            "ro.product.cpu.abi":      "arm64-v8a",
            "ro.build.fingerprint":    "acme/test/fp",
            "ro.product.brand":        "testbrand",
            "ro.product.name":         "testname",
            "ro.build.product":        "testdevice",
            "ro.soc.model":            "TestSoC",
            "ro.soc.manufacturer":     "ACME",
            "ro.product.cpu.abilist":  "arm64-v8a,armeabi-v7a",
            "ro.product.cpu.abilist32": "armeabi-v7a",
            "ro.product.cpu.abilist64": "arm64-v8a",
            "ro.sf.lcd_density":       "420",
            "persist.sys.sf.native_mode": "0",
            "ro.boot.hardware":        "testplatform",
            "ro.bootimage.build.fingerprint": "fp",
            "ro.boot.header_version":  "4",
            "ro.product.first_api_level": "33",
        }

    def test_deviceinfo_contains_required_fields(self) -> None:
        props = self._props()
        modules: list[dict] = [
            {"mod_id": 1, "name": "wlan", "size": 100, "use_count": 2, "used_by": ""},
            {"mod_id": 2, "name": "snd", "size": 50, "use_count": 0, "used_by": ""},
        ]
        text = ep.generate_deviceinfo(props, modules)
        self.assertIn("deviceinfo_format_version", text)
        self.assertIn("deviceinfo_name", text)
        self.assertIn("Test Device", text)
        self.assertIn("ACME", text)
        self.assertIn("deviceinfo_arch", text)
        self.assertIn("aarch64", text)
        self.assertIn("deviceinfo_modules_initfs", text)
        self.assertIn("wlan", text)

    def test_active_modules_consumed(self) -> None:
        props = self._props()
        modules: list[dict] = [
            {"mod_id": 1, "name": "wlan", "size": 100, "use_count": 2, "used_by": ""},
            {"mod_id": 2, "name": "snd", "size": 50, "use_count": 0, "used_by": ""},
        ]
        ep.generate_deviceinfo(props, modules)
        # Active module (use_count=2) should be consumed; inactive remains
        remaining_names = [m["name"] for m in modules]
        self.assertNotIn("wlan", remaining_names)
        self.assertIn("snd", remaining_names)

    def test_known_props_consumed(self) -> None:
        props = self._props()
        modules: list[dict] = []
        ep.generate_deviceinfo(props, modules)
        # Key identity props must have been consumed
        for key in ("ro.product.model", "ro.product.manufacturer",
                    "ro.board.platform", "ro.product.cpu.abi"):
            self.assertNotIn(key, props, f"prop {key!r} was not consumed")


class GenerateDtsTests(unittest.TestCase):
    def _make_args(self) -> tuple:
        props = {
            "ro.product.model": "TestDevice",
            "ro.product.device": "td1",
            "ro.board.platform": "testplatform",
            "ro.hardware": "testhw",
            "ro.build.description": "build_desc",
        }
        dt_nodes = [
            {
                "node_id": 1,
                "path": "/",
                "compatible": "vendor,td1",
                "reg": "",
                "interrupts": "",
                "clocks": "",
            },
            {
                "node_id": 2,
                "path": "/soc/uart@7af0000",
                "compatible": "qcom,msm-uartdm",
                "reg": "",
                "interrupts": "0 26 4",
                "clocks": "xo",
            },
        ]
        iomem = [
            {"iomem_id": 1, "start_hex": "80000000", "end_hex": "ffffffff", "name": "System RAM"},
            {"iomem_id": 2, "start_hex": "00000000", "end_hex": "00000fff", "name": "Reserved"},
        ]
        irqs = [
            {"irq_id": 1, "irq_num": 26, "count": 500, "name": "msm_uartdm"},
        ]
        pinctrl: dict = {}
        modules: list[dict] = []
        return props, dt_nodes, iomem, irqs, pinctrl, modules

    def test_dts_starts_with_header(self) -> None:
        dts = ep.generate_dts(*self._make_args())
        self.assertTrue(dts.startswith("/dts-v1/;"))

    def test_memory_node_generated(self) -> None:
        dts = ep.generate_dts(*self._make_args())
        # DTS generates a memory@ node with device_type = "memory"
        self.assertIn("device_type", dts)
        self.assertIn("memory@", dts)

    def test_reserved_memory_section(self) -> None:
        dts = ep.generate_dts(*self._make_args())
        self.assertIn("reserved-memory", dts)

    def test_soc_node_included(self) -> None:
        dts = ep.generate_dts(*self._make_args())
        self.assertIn("soc:", dts)

    def test_dt_nodes_consumed(self) -> None:
        args = list(self._make_args())
        dt_nodes = args[1]
        ep.generate_dts(*args)
        self.assertEqual(len(dt_nodes), 0)

    def test_irqs_consumed(self) -> None:
        args = list(self._make_args())
        irqs = args[3]
        ep.generate_dts(*args)
        self.assertEqual(len(irqs), 0)

    def test_iomem_consumed(self) -> None:
        args = list(self._make_args())
        iomem = args[2]
        ep.generate_dts(*args)
        self.assertEqual(len(iomem), 0)


class GenerateModulesTests(unittest.TestCase):
    def test_all_modules_consumed(self) -> None:
        modules = [
            {"mod_id": 1, "name": "wlan", "size": 100, "use_count": 0, "used_by": ""},
            {"mod_id": 2, "name": "snd",  "size": 50,  "use_count": 0, "used_by": ""},
        ]
        text = ep.generate_modules_initfs(modules)
        self.assertIn("wlan", text)
        self.assertIn("snd", text)
        self.assertEqual(len(modules), 0)


class GenerateHalListTests(unittest.TestCase):
    def test_hals_consumed(self) -> None:
        hals = [
            {
                "vhal_id": 1,
                "hal_format": "hidl",
                "hal_name": "android.hardware.audio@7.0",
                "version": "7.0",
                "interface": "IDevicesFactory",
                "instance": "default",
                "transport": "hwbinder",
                "source_file": "manifest.xml",
            }
        ]
        text = ep.generate_hal_list(hals)
        self.assertIn("android.hardware.audio", text)
        self.assertEqual(len(hals), 0)


class GenerateHwSummaryTests(unittest.TestCase):
    def test_hw_blocks_consumed(self) -> None:
        hw = [
            {
                "hw_id": 1,
                "name": "display",
                "category": "display",
                "hal_interface": "IComposer",
                "hal_instance": None,
                "pinctrl_group": None,
                "pct_populated": 75.0,
            }
        ]
        text = ep.generate_hw_summary(hw)
        self.assertIn("display", text)
        self.assertEqual(len(hw), 0)


class ExportEndToEndTests(unittest.TestCase):
    """Integration: populate the DB, call export(), verify output files exist."""

    def setUp(self) -> None:
        self.db_fd, self.db_file = tempfile.mkstemp(suffix=".sqlite")
        self.db_path = Path(self.db_file)
        self.out_dir = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        import os
        try:
            os.close(self.db_fd)
        except OSError:
            pass
        self.db_path.unlink(missing_ok=True)

    def _populate_db(self) -> int:
        db = sqlite3.connect(str(self.db_path))
        build_table.apply_schema(db)
        cur = db.cursor()
        cur.execute(
            """INSERT INTO collection_run
               (mode, device_model, ro_board, ro_platform, ro_hardware)
               VALUES (?,?,?,?,?)""",
            ("A", "IntegTest Device", "husky", "zuma", "husky"),
        )
        run_id = cur.lastrowid

        # android_prop
        props = {
            "ro.product.model": "IntegTest",
            "ro.product.manufacturer": "Google",
            "ro.product.device": "husky",
            "ro.product.brand": "google",
            "ro.product.name": "husky",
            "ro.build.product": "husky",
            "ro.board.platform": "zuma",
            "ro.hardware": "husky",
            "ro.soc.model": "Tensor G3",
            "ro.soc.manufacturer": "Google",
            "ro.product.cpu.abi": "arm64-v8a",
            "ro.product.cpu.abilist": "arm64-v8a",
            "ro.product.cpu.abilist32": "armeabi-v7a",
            "ro.product.cpu.abilist64": "arm64-v8a",
            "ro.build.fingerprint": "google/husky/fp:14/UPB5.230623.004/10300000:user/release-keys",
            "ro.sf.lcd_density": "480",
            "persist.sys.sf.native_mode": "0",
            "ro.boot.hardware": "husky",
            "ro.bootimage.build.fingerprint": "google/husky/fp",
            "ro.boot.header_version": "4",
            "ro.product.first_api_level": "33",
        }
        for k, v in props.items():
            cur.execute(
                "INSERT INTO android_prop (run_id, key, value) VALUES (?,?,?)",
                (run_id, k, v),
            )

        # dt_node
        cur.execute(
            "INSERT INTO dt_node (run_id, path, compatible) VALUES (?,?,?)",
            (run_id, "/soc/uart@10000", "qcom,msm-uartdm"),
        )

        # iomem
        cur.execute(
            "INSERT INTO iomem_region (run_id, start_hex, end_hex, name) VALUES (?,?,?,?)",
            (run_id, "80000000", "ffffffff", "System RAM"),
        )
        cur.execute(
            "INSERT INTO iomem_region (run_id, start_hex, end_hex, name) VALUES (?,?,?,?)",
            (run_id, "00000000", "00000fff", "Reserved"),
        )

        # irq_entry
        cur.execute(
            "INSERT INTO irq_entry (run_id, irq_num, count, name) VALUES (?,?,?,?)",
            (run_id, 32, 1000, "msm_uartdm"),
        )

        # kernel_module
        cur.execute(
            "INSERT INTO kernel_module (run_id, name, size, use_count, used_by) VALUES (?,?,?,?,?)",
            (run_id, "wlan", 1000000, 3, "cfg80211"),
        )
        cur.execute(
            "INSERT INTO kernel_module (run_id, name, size, use_count, used_by) VALUES (?,?,?,?,?)",
            (run_id, "snd_soc", 50000, 0, ""),
        )

        # vintf_hal
        cur.execute(
            """INSERT INTO vintf_hal (run_id, hal_format, hal_name, version,
               interface, instance, transport, source_file)
               VALUES (?,?,?,?,?,?,?,?)""",
            (run_id, "hidl", "android.hardware.audio@7.0", "7.0",
             "IDevicesFactory", "default", "hwbinder", "manifest.xml"),
        )

        # hardware_block
        cur.execute(
            """INSERT INTO hardware_block (run_id, name, category, hal_interface)
               VALUES (?,?,?,?)""",
            (run_id, "audio", "audio",
             "android.hardware.audio@7.0::IDevicesFactory"),
        )

        db.commit()
        db.close()
        return run_id

    def test_export_creates_expected_files(self) -> None:
        run_id = self._populate_db()
        ep.export(self.db_path, run_id, self.out_dir)

        self.assertTrue((self.out_dir / "deviceinfo").exists())
        self.assertTrue((self.out_dir / "modules-initfs").exists())
        self.assertTrue((self.out_dir / "hal_interfaces.txt").exists())
        self.assertTrue((self.out_dir / "hardware_summary.txt").exists())

        # At least one .dts file must be present
        dts_files = list(self.out_dir.glob("*.dts"))
        self.assertEqual(len(dts_files), 1)

    def test_deviceinfo_content_correct(self) -> None:
        run_id = self._populate_db()
        ep.export(self.db_path, run_id, self.out_dir)
        content = (self.out_dir / "deviceinfo").read_text()
        self.assertIn("IntegTest", content)
        self.assertIn("Google", content)
        self.assertIn("aarch64", content)
        self.assertIn("deviceinfo_arch", content)

    def test_dts_contains_soc_and_memory(self) -> None:
        run_id = self._populate_db()
        ep.export(self.db_path, run_id, self.out_dir)
        dts = list(self.out_dir.glob("*.dts"))[0].read_text()
        self.assertIn("/dts-v1/;", dts)
        self.assertIn("soc:", dts)
        self.assertIn("device_type", dts)

    def test_hal_list_contains_audio(self) -> None:
        run_id = self._populate_db()
        ep.export(self.db_path, run_id, self.out_dir)
        content = (self.out_dir / "hal_interfaces.txt").read_text()
        self.assertIn("android.hardware.audio", content)

    def test_modules_initfs_contains_wlan(self) -> None:
        """wlan module (use_count=3) should end up in deviceinfo modules_initfs field.
        snd_soc (use_count=0) is inactive so it appears in the modules-initfs file."""
        run_id = self._populate_db()
        ep.export(self.db_path, run_id, self.out_dir)
        di = (self.out_dir / "deviceinfo").read_text()
        # wlan is active (use_count=3) → placed in deviceinfo_modules_initfs
        self.assertIn("wlan", di)
        # modules-initfs file contains the inactive module
        mods_file = (self.out_dir / "modules-initfs").read_text()
        self.assertIn("snd_soc", mods_file)

    def test_export_latest_run_when_no_run_id(self) -> None:
        run_id = self._populate_db()
        ep.export(self.db_path, None, self.out_dir)
        self.assertTrue((self.out_dir / "deviceinfo").exists())


if __name__ == "__main__":
    unittest.main()
