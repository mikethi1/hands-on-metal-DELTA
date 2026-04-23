#!/usr/bin/env python3
"""
fileserver/server.py
====================
Minimal HTTP file server for hands-on-metal.

Lets you **download** files with ``curl`` / ``wget`` and **upload** files with
``curl -F``.  Uses only the Python standard library — no pip dependencies.

Quick start
-----------
    python fileserver/server.py                          # defaults
    python fileserver/server.py --port 9000 --dir ~/tmp/my-files

Download a file::

    curl  http://localhost:8080/myfile.zip -o myfile.zip
    wget  http://localhost:8080/myfile.zip

Upload a file::

    curl -F "file=@local.zip" http://localhost:8080/upload

List files (browser or curl)::

    curl http://localhost:8080/
"""

from __future__ import annotations

import argparse
import html
import mimetypes
import os
import re
import secrets
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import unquote, quote

# Maximum upload size: 500 MB (configurable via --max-upload)
_DEFAULT_MAX_UPLOAD = 500 * 1024 * 1024

# Streaming download chunk size — large enough to amortise syscalls but small
# enough to keep memory bounded for multi-GB files.
_STREAM_CHUNK = 64 * 1024


# ── Multipart form-data parser (replaces deprecated cgi module) ──────────────

def _extract_boundary(content_type: str) -> str | None:
    """Extract the boundary string from a multipart Content-Type header."""
    match = re.search(r"boundary=([^\s;]+)", content_type)
    return match.group(1) if match else None


def _parse_multipart(
    body: bytes, boundary: str
) -> tuple[str | None, bytes | None]:
    """Parse multipart body and return (filename, data) for the 'file' field.

    Returns (None, None) if no valid 'file' field with a filename is found.
    """
    delim = f"--{boundary}".encode()
    parts = body.split(delim)

    for part in parts:
        # Skip preamble, epilogue, and closing delimiter
        if not part or part.strip() == b"--" or part.strip() == b"":
            continue

        # Split headers from body (separated by \r\n\r\n)
        header_end = part.find(b"\r\n\r\n")
        if header_end == -1:
            continue

        header_block = part[:header_end].decode("utf-8", errors="replace")
        # +4 to skip the \r\n\r\n separator
        data = part[header_end + 4 :]

        # Strip trailing \r\n (part delimiter padding)
        if data.endswith(b"\r\n"):
            data = data[:-2]

        # Check for Content-Disposition with name="file" and a filename
        cd_match = re.search(
            r'Content-Disposition:\s*form-data;\s*name="file";\s*filename="([^"]+)"',
            header_block,
            re.IGNORECASE,
        )
        if cd_match:
            return cd_match.group(1), data

    return None, None


class FileServerHandler(BaseHTTPRequestHandler):
    """Handle GET (download / list) and POST (upload) requests."""

    # Set by ``serve()`` before the server starts.
    storage_dir: Path = Path("files")
    max_upload: int = _DEFAULT_MAX_UPLOAD
    auth_token: str | None = None  # if set, required on every request

    # ── auth ─────────────────────────────────────────────────

    def _check_auth(self) -> bool:
        """Return True if the request is authorised (or auth is disabled).

        When a token is configured, it may be supplied via either:
          * Authorization: Bearer <token>
          * ?token=<token> query string
        """
        if not self.auth_token:
            return True

        # Header check
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            supplied = header[len("Bearer "):].strip()
            if secrets.compare_digest(supplied, self.auth_token):
                return True

        # Query-string check (handy for curl/wget without custom headers)
        if "?" in self.path:
            query = self.path.split("?", 1)[1]
            for part in query.split("&"):
                if part.startswith("token="):
                    supplied = unquote(part[len("token="):])
                    if secrets.compare_digest(supplied, self.auth_token):
                        return True

        return False

    @staticmethod
    def _strip_query(path: str) -> str:
        """Return the path with any query string removed."""
        return path.split("?", 1)[0]

    # ── GET — download a file or list the directory ──────────

    def do_GET(self) -> None:  # noqa: N802
        if not self._check_auth():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Bearer realm="hands-on-metal"')
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"401 Unauthorized\n")
            return

        rel = unquote(self._strip_query(self.path)).lstrip("/")

        # Reject path-traversal attempts
        try:
            target = (self.storage_dir / rel).resolve()
            if not str(target).startswith(str(self.storage_dir.resolve())):
                self._send_error(403, "Forbidden")
                return
        except (ValueError, OSError):
            self._send_error(400, "Bad request")
            return

        if target.is_file():
            self._serve_file(target)
        elif target.is_dir():
            self._serve_listing(target, rel)
        else:
            self._send_error(404, "Not found")

    # ── POST /upload — accept a file upload ──────────────────

    def do_POST(self) -> None:  # noqa: N802
        if not self._check_auth():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Bearer realm="hands-on-metal"')
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"401 Unauthorized\n")
            return

        if self._strip_query(self.path).rstrip("/") != "/upload":
            self._send_error(404, "POST only accepted at /upload")
            return

        content_type = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in content_type:
            self._send_error(400, "Expected multipart/form-data")
            return

        # Read the body up to max_upload
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > self.max_upload:
            self._send_error(
                413,
                f"File too large (limit {self.max_upload // (1024 * 1024)} MB)",
            )
            return

        try:
            raw = self.rfile.read(content_length)
        except Exception as exc:
            self._send_error(400, f"Could not read request body: {exc}")
            return

        # Extract boundary from Content-Type header
        boundary = _extract_boundary(content_type)
        if not boundary:
            self._send_error(400, "Missing boundary in Content-Type")
            return

        # Parse the multipart body manually (avoids deprecated cgi module)
        filename, file_data = _parse_multipart(raw, boundary)
        if filename is None or file_data is None:
            self._send_error(400, "Missing 'file' field or filename")
            return

        # Sanitise the filename: keep only the basename, drop path separators
        safe_name = Path(filename).name
        if not safe_name:
            self._send_error(400, "Invalid filename")
            return

        dest = self.storage_dir / safe_name

        # Avoid overwriting — append a timestamp suffix if the name exists
        if dest.exists():
            stem = dest.stem
            suffix = dest.suffix
            ts = int(time.time())
            safe_name = f"{stem}_{ts}{suffix}"
            dest = self.storage_dir / safe_name

        try:
            dest.write_bytes(file_data)
        except Exception as exc:
            self._send_error(500, f"Failed to save file: {exc}")
            return

        body = f"OK — saved as {safe_name} ({len(file_data):,} bytes)\n"
        self._send_response(201, body, "text/plain")
        self.log_message("Uploaded %s (%d bytes)", safe_name, len(file_data))

    # ── helpers ──────────────────────────────────────────────

    def _serve_file(self, path: Path) -> None:
        try:
            size = path.stat().st_size
            fh = path.open("rb")
        except OSError as exc:
            self._send_error(500, f"Read error: {exc}")
            return

        # Detect Content-Type by extension; fall back to binary
        content_type, _ = mimetypes.guess_type(path.name)
        if not content_type:
            content_type = "application/octet-stream"

        try:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(size))
            self.send_header(
                "Content-Disposition",
                f'attachment; filename="{path.name}"',
            )
            self.end_headers()
            while True:
                chunk = fh.read(_STREAM_CHUNK)
                if not chunk:
                    break
                self.wfile.write(chunk)
        finally:
            fh.close()

    def _serve_listing(self, directory: Path, rel: str) -> None:
        try:
            entries = sorted(directory.iterdir())
        except OSError as exc:
            self._send_error(500, f"Cannot list directory: {exc}")
            return

        lines = [
            "<!doctype html><html><head>",
            "<meta charset='utf-8'>",
            "<title>hands-on-metal file server</title>",
            "<style>",
            "body{font-family:monospace;margin:2em}",
            "a{text-decoration:none;color:#0366d6}",
            "a:hover{text-decoration:underline}",
            "li{margin:0.3em 0}",
            ".upload{margin-top:2em;padding:1em;border:1px solid #ddd;border-radius:4px}",
            "</style>",
            "</head><body>",
            "<h1>&#128230; hands-on-metal file server</h1>",
        ]

        if rel:
            parent = "/".join(rel.rstrip("/").split("/")[:-1])
            lines.append(f'<p><a href="/{parent}">⬆ parent directory</a></p>')

        lines.append(f"<p><strong>/{html.escape(rel)}</strong></p><ul>")

        for entry in entries:
            name = entry.name
            if entry.is_dir():
                name += "/"
            href = quote(f"/{rel}/{name}".replace("//", "/"))
            size = ""
            if entry.is_file():
                s = entry.stat().st_size
                if s < 1024:
                    size = f" ({s} B)"
                elif s < 1024 * 1024:
                    size = f" ({s / 1024:.1f} KB)"
                else:
                    size = f" ({s / (1024 * 1024):.1f} MB)"
            lines.append(
                f'<li><a href="{href}">{html.escape(name)}</a>{size}</li>'
            )

        if not entries:
            lines.append("<li><em>(empty)</em></li>")

        lines += [
            "</ul>",
            '<div class="upload">',
            "<h2>Upload a file</h2>",
            '<form method="POST" action="/upload" enctype="multipart/form-data">',
            '<input type="file" name="file">',
            '<button type="submit">Upload</button>',
            "</form>",
            "<p>Or from the command line:</p>",
            '<pre>curl -F "file=@yourfile.zip" http://&lt;host&gt;:&lt;port&gt;/upload</pre>',
            "</div>",
            "</body></html>",
        ]

        body = "\n".join(lines)
        self._send_response(200, body, "text/html; charset=utf-8")

    def _send_response(self, code: int, body: str, content_type: str) -> None:
        encoded = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _send_error(self, code: int, message: str) -> None:
        self._send_response(code, f"{code} {message}\n", "text/plain")


# ── Entry point ───────────────────────────────────────────────────────────────

def serve(
    host: str = "0.0.0.0",
    port: int = 8080,
    directory: str = "files",
    max_upload: int = _DEFAULT_MAX_UPLOAD,
    auth_token: str | None = None,
) -> None:
    """Start the file server."""
    storage = Path(directory).resolve()
    storage.mkdir(parents=True, exist_ok=True)

    FileServerHandler.storage_dir = storage
    FileServerHandler.max_upload = max_upload
    FileServerHandler.auth_token = auth_token

    server = HTTPServer((host, port), FileServerHandler)
    auth_line = (
        f"  Auth token        : {auth_token}\n"
        f"                       (send via 'Authorization: Bearer <token>' "
        f"or '?token=<token>')\n"
        if auth_token
        else "  Auth              : disabled (anyone on the network can read/write)\n"
    )
    print(
        f"hands-on-metal file server listening on http://{host}:{port}\n"
        f"  Storage directory : {storage}\n"
        f"  Max upload size   : {max_upload // (1024 * 1024)} MB\n"
        f"{auth_line}"
        f"\n"
        f"  Download : curl  http://{host}:{port}/<filename> -o <filename>\n"
        f"             wget  http://{host}:{port}/<filename>\n"
        f"  Upload   : curl -F \"file=@<filename>\" http://{host}:{port}/upload\n"
        f"  List     : curl  http://{host}:{port}/\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        server.server_close()


def main() -> None:
    ap = argparse.ArgumentParser(
        description=(
            "Minimal HTTP file server — download via curl/wget, "
            "upload via curl -F."
        ),
    )
    ap.add_argument(
        "--host",
        default="0.0.0.0",
        help="Bind address (default: 0.0.0.0)",
    )
    ap.add_argument(
        "--port",
        type=int,
        default=8080,
        help="Listen port (default: 8080)",
    )
    ap.add_argument(
        "--dir",
        default="files",
        help=(
            "Directory to serve and store uploaded files "
            "(default: ./files — created automatically)"
        ),
    )
    ap.add_argument(
        "--max-upload",
        type=int,
        default=_DEFAULT_MAX_UPLOAD,
        help="Maximum upload size in bytes (default: 500 MB)",
    )
    ap.add_argument(
        "--token",
        default=os.environ.get("HOM_FILESERVER_TOKEN"),
        help=(
            "Require this bearer token on every request. "
            "May also be set via the HOM_FILESERVER_TOKEN env var. "
            "Mutually exclusive with --auto-token."
        ),
    )
    ap.add_argument(
        "--auto-token",
        action="store_true",
        help=(
            "Generate a fresh random token at startup and print it. "
            "Useful for ad-hoc transfers when you don't want to pick one."
        ),
    )
    args = ap.parse_args()

    token = args.token
    if args.auto_token:
        if token:
            ap.error("--token and --auto-token are mutually exclusive")
        token = secrets.token_urlsafe(24)

    serve(
        host=args.host,
        port=args.port,
        directory=args.dir,
        max_upload=args.max_upload,
        auth_token=token,
    )


if __name__ == "__main__":
    main()
