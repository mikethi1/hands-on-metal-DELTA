import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


PIPELINE_DIR = Path(__file__).resolve().parents[1] / "pipeline"
if str(PIPELINE_DIR) not in sys.path:
    sys.path.insert(0, str(PIPELINE_DIR))

import unpack_images  # noqa: E402


class UnpackImagesTests(unittest.TestCase):
    def test_try_lz4_uses_cli_fallback_without_python_lz4(self) -> None:
        lz4_magic = b"\x04\x22\x4d\x18"
        fake_input = lz4_magic + b"payload"
        fake_output = b"070701cpio"
        completed = subprocess.CompletedProcess(
            args=["lz4", "-dc", "-"], returncode=0, stdout=fake_output, stderr=b""
        )

        with mock.patch.object(unpack_images, "_HAS_LZ4", False), \
             mock.patch("unpack_images.subprocess.run", return_value=completed) as run_mock:
            out = unpack_images._try_lz4(fake_input)

        self.assertEqual(out, fake_output)
        run_mock.assert_called_once()

    def test_try_lz4_returns_none_when_cli_fails(self) -> None:
        lz4_magic = b"\x04\x22\x4d\x18"
        fake_input = lz4_magic + b"payload"
        completed = subprocess.CompletedProcess(
            args=["lz4", "-dc", "-"], returncode=1, stdout=b"", stderr=b"decode failed"
        )

        with mock.patch.object(unpack_images, "_HAS_LZ4", False), \
             mock.patch("unpack_images.subprocess.run", return_value=completed):
            out = unpack_images._try_lz4(fake_input)

        self.assertIsNone(out)

    def test_try_lz4_returns_none_when_cli_missing(self) -> None:
        lz4_magic = b"\x04\x22\x4d\x18"
        fake_input = lz4_magic + b"payload"
        with mock.patch.object(unpack_images, "_HAS_LZ4", False), \
             mock.patch("unpack_images.subprocess.run", side_effect=FileNotFoundError):
            out = unpack_images._try_lz4(fake_input)
        self.assertIsNone(out)

    def test_try_lz4_falls_back_to_cli_when_python_lz4_errors(self) -> None:
        lz4_magic = b"\x04\x22\x4d\x18"
        fake_input = lz4_magic + b"payload"
        fake_output = b"070701cpio"
        completed = subprocess.CompletedProcess(
            args=["lz4", "-dc", "-"], returncode=0, stdout=fake_output, stderr=b""
        )
        fake_lz4 = mock.Mock()
        fake_lz4.decompress.side_effect = RuntimeError("decode failed")
        with mock.patch.object(unpack_images, "_HAS_LZ4", True), \
             mock.patch.object(unpack_images, "_lz4_frame", fake_lz4, create=True), \
             mock.patch("unpack_images.subprocess.run", return_value=completed):
            out = unpack_images._try_lz4(fake_input)
        self.assertEqual(out, fake_output)


if __name__ == "__main__":
    unittest.main()
