import json
import sys
import unittest
from pathlib import Path
from unittest import mock


PIPELINE_DIR = Path(__file__).resolve().parents[1] / "pipeline"
if str(PIPELINE_DIR) not in sys.path:
    sys.path.insert(0, str(PIPELINE_DIR))

import upload  # noqa: E402


class UploadTests(unittest.TestCase):
    def test_redact_for_repo_upload_redacts_sensitive_fields(self) -> None:
        files = {
            "share_bundle.json": json.dumps(
                {
                    "pii_redacted": False,
                    "sharing_mode": "local_full",
                    "variables": {
                        "HOM_DEV_MODEL": "Pixel 8",
                        "HOM_DEV_IMEI": "123456789012345",
                        "HOM_WIFI_MAC": "AA:BB:CC:DD:EE:FF",
                    },
                }
            ),
            "env_registry.txt": 'HOM_DEV_IMEI="123456789012345"\nHOM_DEV_MODEL="Pixel 8"\n',
            "var_audit.txt": '[VAR  ][x] HOM_WIFI_MAC="AA:BB:CC:DD:EE:FF"\n',
            "README.txt": "leave unchanged",
        }

        out = upload.redact_for_repo_upload(files)
        parsed = json.loads(out["share_bundle.json"])
        self.assertTrue(parsed["pii_redacted"])
        self.assertEqual(parsed["sharing_mode"], "repo_upload_redacted")
        self.assertEqual(parsed["variables"]["HOM_DEV_IMEI"], "#")
        self.assertEqual(parsed["variables"]["HOM_WIFI_MAC"], "#")
        self.assertEqual(parsed["variables"]["HOM_DEV_MODEL"], "Pixel 8")
        self.assertIn('HOM_DEV_IMEI="#"', out["env_registry.txt"])
        self.assertIn('HOM_WIFI_MAC="#"', out["var_audit.txt"])
        self.assertEqual(out["README.txt"], "leave unchanged")

    def test_confirm_repo_upload_yes_flag_skips_prompt(self) -> None:
        with mock.patch("builtins.input") as input_mock:
            self.assertTrue(upload.confirm_repo_upload(yes=True))
        input_mock.assert_not_called()

    def test_confirm_repo_upload_defaults_to_no(self) -> None:
        with mock.patch.object(sys.stdin, "isatty", return_value=True), \
             mock.patch("builtins.input", return_value="n"):
            self.assertFalse(upload.confirm_repo_upload(False))

    def test_confirm_repo_upload_accepts_yes(self) -> None:
        with mock.patch.object(sys.stdin, "isatty", return_value=True), \
             mock.patch("builtins.input", return_value="yes"):
            self.assertTrue(upload.confirm_repo_upload(False))

    def test_confirm_repo_upload_rejects_non_tty_without_yes(self) -> None:
        with mock.patch.object(sys.stdin, "isatty", return_value=False):
            self.assertFalse(upload.confirm_repo_upload(False))

    def test_confirm_repo_upload_explicit_is_tty_false_rejects(self) -> None:
        with mock.patch("builtins.input") as input_mock:
            self.assertFalse(upload.confirm_repo_upload(False, is_tty=False))
        input_mock.assert_not_called()

    def test_redact_for_repo_upload_handles_non_json_share_bundle(self) -> None:
        files = {
            "share_bundle.json": 'HOM_DEV_IMEI="123456789012345"',
            "env_registry.txt": 'HOM_DEV_IMEI="123456789012345"\n',
        }
        out = upload.redact_for_repo_upload(files)
        self.assertEqual(out["share_bundle.json"], 'HOM_DEV_IMEI="#"')
        self.assertEqual(out["env_registry.txt"], 'HOM_DEV_IMEI="#"\n')

    def test_redact_for_repo_upload_string_non_json_is_unchanged(self) -> None:
        raw = "not-json-token=abc123"
        self.assertEqual(upload.redact_for_repo_upload(raw), raw)

    def test_redact_for_repo_upload_string_json_recursively_redacts_secret_keys(self) -> None:
        raw = json.dumps(
            {
                "token": "abc",
                "nested": {
                    "authorization": "Bearer abc",
                    "other": [{"password": "pw"}, {"secret": "s"}],
                },
            }
        )
        redacted = upload.redact_for_repo_upload(raw)
        self.assertIsInstance(redacted, str)
        parsed = json.loads(redacted)
        self.assertEqual(parsed["token"], "#")
        self.assertEqual(parsed["nested"]["authorization"], "#")
        self.assertEqual(parsed["nested"]["other"][0]["password"], "#")
        self.assertEqual(parsed["nested"]["other"][1]["secret"], "#")


if __name__ == "__main__":
    unittest.main()
