import sys
import tempfile
import unittest
from pathlib import Path


PIPELINE_DIR = Path(__file__).resolve().parents[1] / "pipeline"
if str(PIPELINE_DIR) not in sys.path:
    sys.path.insert(0, str(PIPELINE_DIR))

import parse_logs  # noqa: E402


class ParseLogsTests(unittest.TestCase):
    def test_parse_master_log_extracts_all_record_types(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log_path = Path(tmp) / "master_123.log"
            log_path.write_text(
                "\n".join(
                    [
                        '[2026-01-01T00:00:00Z][VAR  ][env] RUN_ID="RID123" # run identifier',
                        '[2026-01-01T00:00:01Z][VAR  ][env] MODE="A"',
                        "[2026-01-01T00:00:02Z][EXEC ][runner] do something",
                        "[2026-01-01T00:00:03Z][INFO ][runner] info message",
                        "[2026-01-01T00:00:04Z][WARN ][runner] warning message",
                        "[2026-01-01T00:00:05Z][ERROR][runner] error message",
                        "malformed line should be ignored",
                    ]
                ),
                encoding="utf-8",
            )

            out = parse_logs.parse_master_log(log_path)

        self.assertEqual(out["run_id"], "RID123")
        self.assertEqual(len(out["variables"]), 2)
        self.assertEqual(out["variables"][0]["name"], "RUN_ID")
        self.assertEqual(out["variables"][0]["desc"], "run identifier")
        self.assertEqual(len(out["commands"]), 1)
        self.assertEqual(len(out["info"]), 1)
        self.assertEqual(len(out["warnings"]), 1)
        self.assertEqual(len(out["errors"]), 1)

    def test_parse_manifest_file_filters_invalid_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "run_manifest_1.txt"
            manifest.write_text(
                "\n".join(
                    [
                        "2026-01-01T00:00:00Z|ENV|OK|done",
                        "2026-01-01T00:00:01Z|PATCH|FAIL|bad image",
                        "2026-01-01T00:00:02Z|VERIFY|SKIP|not needed",
                        "this row is invalid",
                    ]
                ),
                encoding="utf-8",
            )

            steps = parse_logs.parse_manifest_file(manifest)

        self.assertEqual(len(steps), 3)
        self.assertEqual(steps[0]["step"], "ENV")
        self.assertEqual(steps[1]["status"], "FAIL")
        self.assertEqual(steps[2]["note"], "not needed")

    def test_merge_results_combines_lists_and_prefers_known_run_id(self) -> None:
        merged = parse_logs.merge_results(
            [
                {
                    "run_id": "UNKNOWN",
                    "log_file": "a.log",
                    "variables": [{"name": "A"}],
                    "commands": [{"cmd": "x"}],
                    "errors": [],
                    "warnings": [],
                    "info": [],
                },
                {
                    "run_id": "RID999",
                    "log_file": "b.log",
                    "variables": [{"name": "B"}],
                    "commands": [],
                    "errors": [{"message": "boom"}],
                    "warnings": [{"message": "warn"}],
                    "info": [{"message": "ok"}],
                },
            ],
            [{"step": "ENV"}],
        )

        self.assertEqual(merged["run_id"], "RID999")
        self.assertEqual(merged["log_files"], ["a.log", "b.log"])
        self.assertEqual(len(merged["variables"]), 2)
        self.assertEqual(len(merged["commands"]), 1)
        self.assertEqual(len(merged["errors"]), 1)
        self.assertEqual(len(merged["warnings"]), 1)
        self.assertEqual(len(merged["info"]), 1)
        self.assertEqual(merged["steps"], [{"step": "ENV"}])


if __name__ == "__main__":
    unittest.main()
