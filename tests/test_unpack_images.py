import subprocess
import sys
import unittest
import gzip
import tempfile
from pathlib import Path
from unittest import mock


PIPELINE_DIR = Path(__file__).resolve().parents[1] / "pipeline"
if str(PIPELINE_DIR) not in sys.path:
    sys.path.insert(0, str(PIPELINE_DIR))

import unpack_images  # noqa: E402


class UnpackImagesTests(unittest.TestCase):
    @staticmethod
    def _newc_entry(name: str, payload: bytes) -> bytes:
        name_bytes = name.encode("utf-8") + b"\x00"
        namesize = len(name_bytes)
        filesize = len(payload)
        fields = [
            b"070701",
            b"00000000",  # ino
            b"000081A4",  # mode
            b"00000000",  # uid
            b"00000000",  # gid
            b"00000001",  # nlink
            b"00000000",  # mtime
            f"{filesize:08x}".encode("ascii"),
            b"00000000",  # devmajor
            b"00000000",  # devminor
            b"00000000",  # rdevmajor
            b"00000000",  # rdevminor
            f"{namesize:08x}".encode("ascii"),
            b"00000000",  # check
        ]
        header = b"".join(fields)
        if len(header) != 110:
            raise ValueError("invalid newc header length")

        def _pad4(buf: bytes) -> bytes:
            return buf + (b"\x00" * ((4 - (len(buf) % 4)) % 4))

        return header + _pad4(name_bytes) + _pad4(payload)

    def test_decompress_ramdisk_recovers_gzip_with_prefixed_bytes(self) -> None:
        cpio_payload = b"070701cpio"
        ramdisk = gzip.compress(cpio_payload)
        wrapped = (b"\x00" * 256) + ramdisk
        out = unpack_images.decompress_ramdisk(wrapped)
        self.assertEqual(out, cpio_payload)

    def test_decompress_ramdisk_recovers_cpio_with_prefixed_bytes(self) -> None:
        cpio_payload = b"070701cpio"
        wrapped = b"prefix-junk" + cpio_payload
        out = unpack_images.decompress_ramdisk(wrapped)
        self.assertEqual(out, cpio_payload)

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

    def test_try_lz4_cli_retries_legacy_command_variant(self) -> None:
        lz4_magic = b"\x04\x22\x4d\x18"
        fake_input = lz4_magic + b"payload"
        first = subprocess.CompletedProcess(
            args=["lz4", "-dc", "-"], returncode=1, stdout=b"", stderr=b"fail"
        )
        second = subprocess.CompletedProcess(
            args=["lz4", "-l", "-dc", "-"], returncode=0, stdout=b"070701cpio", stderr=b""
        )
        with mock.patch.object(unpack_images, "_HAS_LZ4", False), \
             mock.patch("unpack_images.subprocess.run", side_effect=[first, second]) as run_mock:
            out = unpack_images._try_lz4(fake_input)
        self.assertEqual(out, b"070701cpio")
        self.assertEqual(run_mock.call_count, 2)

    def test_try_lz4_cli_accepts_empty_output(self) -> None:
        lz4_magic = b"\x04\x22\x4d\x18"
        fake_input = lz4_magic + b"payload"
        completed = subprocess.CompletedProcess(
            args=["lz4", "-dc", "-"], returncode=0, stdout=b"", stderr=b""
        )
        with mock.patch.object(unpack_images, "_HAS_LZ4", False), \
             mock.patch("unpack_images.subprocess.run", return_value=completed):
            out = unpack_images._try_lz4(fake_input)
        self.assertEqual(out, b"")

    def test_try_lz4_block_decodes_cpio(self) -> None:
        fake_input = b"raw-lz4-block-data"
        fake_block = mock.Mock()
        fake_block.decompress.return_value = b"070701cpio"
        with mock.patch.object(unpack_images, "_HAS_LZ4_BLOCK", True), \
             mock.patch.object(unpack_images, "_lz4_block", fake_block, create=True):
            out = unpack_images._try_lz4_block(fake_input)
        self.assertEqual(out, b"070701cpio")

    def test_try_lz4_block_returns_none_without_module(self) -> None:
        fake_input = b"raw-lz4-block-data"
        with mock.patch.object(unpack_images, "_HAS_LZ4_BLOCK", False):
            out = unpack_images._try_lz4_block(fake_input)
        self.assertIsNone(out)

    def test_try_lz4_block_returns_raw_output(self) -> None:
        fake_input = b"raw-lz4-block-data"
        fake_block = mock.Mock()
        fake_block.decompress.return_value = b"not-a-cpio-payload"
        with mock.patch.object(unpack_images, "_HAS_LZ4_BLOCK", True), \
             mock.patch.object(unpack_images, "_lz4_block", fake_block, create=True):
            out = unpack_images._try_lz4_block(fake_input)
        self.assertEqual(out, b"not-a-cpio-payload")

    def test_extract_cpio_newc_malformed_header_does_not_raise(self) -> None:
        bad = b"070701" + (b"Z" * 104)
        with tempfile.TemporaryDirectory() as td:
            out = unpack_images.extract_cpio(bad, Path(td))
        self.assertEqual(out, [])

    def test_extract_cpio_newc_rejects_parent_traversal_name(self) -> None:
        archive = (
            self._newc_entry("../outside.prop", b"leak")
            + self._newc_entry("TRAILER!!!", b"")
        )
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            out = unpack_images.extract_cpio(archive, out_dir)
            self.assertEqual(out, [])
            self.assertFalse((out_dir.parent / "outside.prop").exists())

    def test_extract_cpio_newc_rejects_windows_backslash_path(self) -> None:
        archive = (
            self._newc_entry(r"..\outside.prop", b"leak")
            + self._newc_entry("TRAILER!!!", b"")
        )
        with tempfile.TemporaryDirectory() as td:
            out_dir = Path(td)
            out = unpack_images.extract_cpio(archive, out_dir)
            self.assertEqual(out, [])


if __name__ == "__main__":
    unittest.main()
