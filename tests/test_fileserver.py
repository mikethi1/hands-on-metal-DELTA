import io
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

FILESERVER_DIR = Path(__file__).resolve().parents[1] / "fileserver"
if str(FILESERVER_DIR) not in sys.path:
    sys.path.insert(0, str(FILESERVER_DIR))

import server as fileserver  # noqa: E402


def _multipart_body(filename: str, data: bytes, field: str = "file") -> tuple[bytes, str]:
    """Build a minimal multipart/form-data body and return (body, content_type)."""
    boundary = "----TestBoundary7MA4YWxkTrZu0gW"
    parts = [
        f"------TestBoundary7MA4YWxkTrZu0gW\r\n"
        f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n",
    ]
    body = parts[0].encode() + data + b"\r\n------TestBoundary7MA4YWxkTrZu0gW--\r\n"
    content_type = f"multipart/form-data; boundary=----TestBoundary7MA4YWxkTrZu0gW"
    return body, content_type


class FileServerTests(unittest.TestCase):
    """Integration tests — spins up the server on a random port per test."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        cls.storage = Path(cls.tmp.name) / "files"
        cls.storage.mkdir()

        # Pick a free port by binding to 0
        from http.server import HTTPServer

        fileserver.FileServerHandler.storage_dir = cls.storage
        fileserver.FileServerHandler.max_upload = 10 * 1024 * 1024  # 10 MB for tests
        cls.httpd = HTTPServer(("127.0.0.1", 0), fileserver.FileServerHandler)
        cls.port = cls.httpd.server_address[1]
        cls.base = f"http://127.0.0.1:{cls.port}"

        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.httpd.shutdown()
        cls.tmp.cleanup()

    # ── GET tests ────────────────────────────────────────────

    def test_root_listing_returns_html(self) -> None:
        resp = urllib.request.urlopen(f"{self.base}/")
        body = resp.read().decode()
        self.assertEqual(resp.status, 200)
        self.assertIn("hands-on-metal file server", body)

    def test_download_existing_file(self) -> None:
        (self.storage / "hello.txt").write_text("hello world")
        resp = urllib.request.urlopen(f"{self.base}/hello.txt")
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.read(), b"hello world")

    def test_download_missing_file_returns_404(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(f"{self.base}/no-such-file.bin")
        self.assertEqual(ctx.exception.code, 404)

    def test_path_traversal_is_blocked(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(f"{self.base}/../../../etc/passwd")
        self.assertIn(ctx.exception.code, (403, 404))

    # ── POST /upload tests ───────────────────────────────────

    def test_upload_file(self) -> None:
        payload = b"test data 12345"
        body, ct = _multipart_body("test_upload.bin", payload)
        req = urllib.request.Request(
            f"{self.base}/upload",
            data=body,
            headers={"Content-Type": ct},
            method="POST",
        )
        resp = urllib.request.urlopen(req)
        self.assertEqual(resp.status, 201)
        self.assertTrue((self.storage / "test_upload.bin").exists())
        self.assertEqual((self.storage / "test_upload.bin").read_bytes(), payload)

    def test_upload_duplicate_gets_renamed(self) -> None:
        (self.storage / "dup.txt").write_text("original")
        payload = b"duplicate"
        body, ct = _multipart_body("dup.txt", payload)
        req = urllib.request.Request(
            f"{self.base}/upload",
            data=body,
            headers={"Content-Type": ct},
            method="POST",
        )
        resp = urllib.request.urlopen(req)
        self.assertEqual(resp.status, 201)
        # Original is untouched
        self.assertEqual((self.storage / "dup.txt").read_text(), "original")
        # A renamed copy exists
        renamed = [
            f for f in self.storage.iterdir() if f.name.startswith("dup_") and f.name.endswith(".txt")
        ]
        self.assertEqual(len(renamed), 1)
        self.assertEqual(renamed[0].read_bytes(), payload)

    def test_upload_wrong_path_returns_404(self) -> None:
        body, ct = _multipart_body("x.txt", b"data")
        req = urllib.request.Request(
            f"{self.base}/wrong",
            data=body,
            headers={"Content-Type": ct},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 404)

    def test_upload_missing_file_field_returns_400(self) -> None:
        body, ct = _multipart_body("x.txt", b"data", field="notfile")
        req = urllib.request.Request(
            f"{self.base}/upload",
            data=body,
            headers={"Content-Type": ct},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 400)

    # ── Subdirectory listing ─────────────────────────────────

    def test_subdirectory_listing(self) -> None:
        sub = self.storage / "subdir"
        sub.mkdir(exist_ok=True)
        (sub / "nested.txt").write_text("nested content")
        resp = urllib.request.urlopen(f"{self.base}/subdir/")
        body = resp.read().decode()
        self.assertEqual(resp.status, 200)
        self.assertIn("nested.txt", body)

    def test_download_from_subdirectory(self) -> None:
        sub = self.storage / "subdir2"
        sub.mkdir(exist_ok=True)
        (sub / "deep.bin").write_bytes(b"\x00\x01\x02")
        resp = urllib.request.urlopen(f"{self.base}/subdir2/deep.bin")
        self.assertEqual(resp.read(), b"\x00\x01\x02")


if __name__ == "__main__":
    unittest.main()
