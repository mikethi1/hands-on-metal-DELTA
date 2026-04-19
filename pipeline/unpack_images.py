#!/usr/bin/env python3
"""
pipeline/unpack_images.py
=========================
Host-side parser for Android boot/ramdisk images.

Handles:
  • boot.img header versions 0–4 (legacy → GKI)
  • vendor_boot.img (v3/v4 GKI vendor ramdisk)
  • Ramdisk compression: gzip, lz4 (framed), lz4 (legacy), lzma, zstd, bzip2
  • CPIO archive extraction (newc / odc)
  • Android Verified Boot (AVB) footer stripping (so the payload is readable)
  • dm-crypt / FBE metadata detection in fstab entries
  • Raw sparse image detection

Key files extracted from the ramdisk:
  fstab.*         — filesystem table (partition encryption flags, fstype)
  init.rc         — root init script (service defs, HAL references)
  init.*.rc       — device-specific init scripts
  ueventd.rc / ueventd.*.rc  — device permissions / sysfs rules
  default.prop / prop.default — early properties
  lib/modules/**  — kernel modules packed into the ramdisk

All extracted files land under:
  <dump_dir>/ramdisk/<image_stem>/

Fstab entries are also parsed into the sysconfig_entry table with
the key prefix "fstab.<mount_point>.<field>".

Usage:
  python pipeline/unpack_images.py --db hardware_map.sqlite \\
      --dump /path/to/dump --run-id 1

Image discovery order (first match wins per path):
  1. HOM_BOOT_IMG_PATH from the live environment or
     ~/hands-on-metal/env_registry.sh (written by core/boot_image.sh,
     option 5 — the canonical acquired image).
  2. ~/hands-on-metal/boot_work/partitions/ and ~/hands-on-metal/boot_work/
     (option-5 factory-ZIP extraction output, override via HOM_BOOT_WORK_DIR).
  3. Recursive extraction-first search inside the --dump directory:
       <dump_dir>/partitions/   (Mode B recovery images)
       <dump_dir>/boot_images/  (explicit location)
       <dump_dir>/              (fallback)
     All nested ZIP/TAR archives are expanded first and then searched
     recursively for image payloads.

Compressed backups (.win.gz, .win.lz4, .img.lz4) found in the fallback
search are decompressed on the fly into boot_work/ so their resolved paths
are known to all subsequent pipeline steps.
"""

import argparse
import hashlib
import io
import os
import re
import sqlite3
import struct
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import Optional

# ── Optional compression library imports ────────────────────────────────────
try:
    import lz4.frame as _lz4_frame
    _HAS_LZ4 = True
except ImportError:
    _HAS_LZ4 = False

try:
    import zstandard as _zstd
    _HAS_ZSTD = True
except ImportError:
    _HAS_ZSTD = False

import gzip
import lzma
import bz2

# Timeout for the lz4 CLI decompression subprocess.  Large compressed images
# (e.g. TWRP full-nandroid backups) can exceed 1 GiB; 5 minutes is generous
# but avoids hanging forever on very slow storage.
_DECOMPRESS_TIMEOUT = 300


# ════════════════════════════════════════════════════════════════════════════
# AVB footer stripping
# AVB appends a 64-byte footer at the very end of the image that contains
# the offset of the vbmeta struct.  We detect it and truncate so that the
# remaining payload bytes are the actual partition content.
# ════════════════════════════════════════════════════════════════════════════

AVB_FOOTER_MAGIC = b"AVBf"
AVB_FOOTER_SIZE  = 64


def strip_avb_footer(data: bytes) -> bytes:
    """Return data with AVB footer removed if present."""
    if len(data) >= AVB_FOOTER_SIZE and data[-AVB_FOOTER_SIZE:-AVB_FOOTER_SIZE + 4] == AVB_FOOTER_MAGIC:
        return data[:-AVB_FOOTER_SIZE]
    return data


# ════════════════════════════════════════════════════════════════════════════
# Android Sparse Image detection / rejection
# We do not expand sparse images (that requires simg2img); instead we note
# their presence and skip them.
# ════════════════════════════════════════════════════════════════════════════

SPARSE_MAGIC = 0xED26FF3A


def is_sparse_image(data: bytes) -> bool:
    if len(data) < 4:
        return False
    magic = struct.unpack_from("<I", data, 0)[0]
    return magic == SPARSE_MAGIC


# ════════════════════════════════════════════════════════════════════════════
# Boot image header parsing
# Android Boot Image Specification:
#   https://source.android.com/docs/core/architecture/bootloader/boot-image-header
#
# v0 / v1 / v2 share the same base layout; v3 / v4 (GKI) differ significantly.
# ════════════════════════════════════════════════════════════════════════════

BOOT_MAGIC = b"ANDROID!"
VENDOR_BOOT_MAGIC = b"VNDRBOOT"

# v0/v1/v2 header (all fields little-endian uint32 unless noted)
_HDR_V0_FMT = (
    "8s"    # magic
    "I"     # kernel_size
    "I"     # kernel_addr
    "I"     # ramdisk_size
    "I"     # ramdisk_addr
    "I"     # second_size
    "I"     # second_addr
    "I"     # tags_addr
    "I"     # page_size
    "I"     # header_version  (was "dt_size" in v0)
    "I"     # os_version
    "16s"   # name
    "512s"  # cmdline
    "32s"   # sha1
    "1024s" # extra_cmdline
)
HDR_V0_SIZE = struct.calcsize("<" + "".join(_HDR_V0_FMT))
HDR_V0_STRUCT = struct.Struct("<" + "".join(_HDR_V0_FMT))

# v1 adds: recovery_dtbo_size + recovery_dtbo_offset + header_size
_HDR_V1_EXTRA = struct.Struct("<IQI")

# v2 adds: dtb_size + dtb_addr
_HDR_V2_EXTRA = struct.Struct("<IQ")

# v3 header (GKI)
_HDR_V3_FMT = (
    "8s"    # magic
    "I"     # kernel_size
    "I"     # ramdisk_size
    "I"     # os_version
    "I"     # header_size
    "16s"   # reserved
    "I"     # header_version (must be 3)
    "1536s" # cmdline
)
HDR_V3_STRUCT = struct.Struct("<" + "".join(_HDR_V3_FMT))

# v4 adds: signature_size after the v3 fields
_HDR_V4_EXTRA = struct.Struct("<I")

# vendor_boot v3/v4 header
_VENDOR_HDR_V3_FMT = (
    "8s"    # magic
    "I"     # header_version
    "I"     # page_size
    "I"     # kernel_addr
    "I"     # ramdisk_addr
    "I"     # vendor_ramdisk_size
    "2048s" # cmdline
    "I"     # tags_addr
    "16s"   # name
    "I"     # header_size
    "I"     # dtb_size
    "Q"     # dtb_addr
)
VENDOR_HDR_V3_STRUCT = struct.Struct("<" + "".join(_VENDOR_HDR_V3_FMT))

# vendor_boot v4 adds: vendor_ramdisk_table_size, vendor_ramdisk_table_entry_num,
#                      vendor_ramdisk_table_entry_size, bootconfig_size
_VENDOR_HDR_V4_EXTRA = struct.Struct("<IIII")


def _round_up(n: int, page: int) -> int:
    return ((n + page - 1) // page) * page


class BootImage:
    """Parsed representation of a boot.img or vendor_boot.img."""

    def __init__(self) -> None:
        self.version: int = 0
        self.page_size: int = 4096
        self.kernel_data: bytes = b""
        self.ramdisk_data: bytes = b""
        self.second_data: bytes = b""
        self.dtb_data: bytes = b""
        self.cmdline: str = ""
        self.name: str = ""
        self.vendor: bool = False  # True for vendor_boot.img


def parse_boot_image(data: bytes) -> BootImage | None:
    """Parse a (possibly AVB-stripped) boot.img blob; return BootImage or None."""
    data = strip_avb_footer(data)
    if len(data) < 8:
        return None
    magic = data[:8]

    if magic == BOOT_MAGIC:
        return _parse_android_boot(data)
    if magic == VENDOR_BOOT_MAGIC:
        return _parse_vendor_boot(data)
    return None


def _parse_android_boot(data: bytes) -> BootImage | None:
    if len(data) < HDR_V0_SIZE:
        return None

    fields = HDR_V0_STRUCT.unpack_from(data, 0)
    (magic, kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
     second_size, second_addr, tags_addr, page_size, header_version,
     os_version, name_b, cmdline_b, sha1, extra_cmdline_b) = fields

    img = BootImage()
    img.page_size = page_size if page_size else 4096
    img.name      = name_b.rstrip(b"\x00").decode("utf-8", errors="replace")
    img.cmdline   = (cmdline_b + extra_cmdline_b).rstrip(b"\x00").decode("utf-8", errors="replace")
    img.version   = header_version & 0xFF  # low byte is version in v0/v1/v2

    if img.version >= 3:
        # v3 / v4 GKI — completely different layout
        return _parse_android_boot_v3(data)

    ps = img.page_size

    # Compute offsets (page-aligned)
    hdr_pages     = 1
    kernel_pages  = _round_up(kernel_size, ps) // ps
    ramdisk_pages = _round_up(ramdisk_size, ps) // ps
    second_pages  = _round_up(second_size, ps) // ps

    off_kernel  = hdr_pages * ps
    off_ramdisk = off_kernel  + kernel_pages  * ps
    off_second  = off_ramdisk + ramdisk_pages * ps

    if img.version >= 2:
        # Skip v1 recovery_dtbo and v2 dtb — read dtb if present
        # For our purposes just grab the ramdisk
        pass

    img.kernel_data  = data[off_kernel  : off_kernel  + kernel_size]
    img.ramdisk_data = data[off_ramdisk : off_ramdisk + ramdisk_size]
    if second_size:
        img.second_data = data[off_second : off_second + second_size]

    return img


def _parse_android_boot_v3(data: bytes) -> BootImage | None:
    if len(data) < HDR_V3_STRUCT.size:
        return None
    fields = HDR_V3_STRUCT.unpack_from(data, 0)
    (magic, kernel_size, ramdisk_size, os_version, header_size,
     reserved, header_version, cmdline_b) = fields

    img = BootImage()
    img.version  = header_version
    img.page_size = 4096  # fixed at 4096 for v3/v4
    img.cmdline  = cmdline_b.rstrip(b"\x00").decode("utf-8", errors="replace")

    # v4: signature_size follows
    sig_size = 0
    if header_version == 4:
        sig_size = _HDR_V4_EXTRA.unpack_from(data, HDR_V3_STRUCT.size)[0]

    ps = img.page_size
    hdr_pages     = _round_up(header_size, ps) // ps
    kernel_pages  = _round_up(kernel_size, ps) // ps
    ramdisk_pages = _round_up(ramdisk_size, ps) // ps

    off_kernel  = hdr_pages * ps
    off_ramdisk = off_kernel + kernel_pages * ps

    img.kernel_data  = data[off_kernel  : off_kernel  + kernel_size]
    img.ramdisk_data = data[off_ramdisk : off_ramdisk + ramdisk_size]
    return img


def _parse_vendor_boot(data: bytes) -> BootImage | None:
    if len(data) < VENDOR_HDR_V3_STRUCT.size:
        return None
    fields = VENDOR_HDR_V3_STRUCT.unpack_from(data, 0)
    (magic, hdr_version, page_size, kernel_addr, ramdisk_addr,
     vendor_ramdisk_size, cmdline_b, tags_addr, name_b,
     header_size, dtb_size, dtb_addr) = fields

    img = BootImage()
    img.vendor    = True
    img.version   = hdr_version
    img.page_size = page_size if page_size else 4096
    img.name      = name_b.rstrip(b"\x00").decode("utf-8", errors="replace")
    img.cmdline   = cmdline_b.rstrip(b"\x00").decode("utf-8", errors="replace")

    ps = img.page_size
    hdr_pages     = _round_up(header_size, ps) // ps
    ramdisk_pages = _round_up(vendor_ramdisk_size, ps) // ps
    dtb_pages     = _round_up(dtb_size, ps) // ps

    off_ramdisk = hdr_pages * ps
    off_dtb     = off_ramdisk + ramdisk_pages * ps

    img.ramdisk_data = data[off_ramdisk : off_ramdisk + vendor_ramdisk_size]
    if dtb_size:
        img.dtb_data = data[off_dtb : off_dtb + dtb_size]

    return img


# ════════════════════════════════════════════════════════════════════════════
# Ramdisk decompression
# Android ramdisks can be gzip, lz4 (with or without the legacy frame format),
# lzma, zstd, or bzip2.  We try each in order.
# ════════════════════════════════════════════════════════════════════════════

def _try_gzip(data: bytes) -> bytes | None:
    if data[:2] != b"\x1f\x8b":
        return None
    try:
        return gzip.decompress(data)
    except Exception:
        return None


def _try_lz4(data: bytes) -> bytes | None:
    # lz4 framed: magic 0x184D2204
    # lz4 legacy: magic 0x184C2102
    if data[:4] not in (b"\x04\x22\x4d\x18", b"\x02\x21\x4c\x18"):
        return None
    if not _HAS_LZ4:
        result = _try_lz4_cli(data)
        if result is not None:
            return result
        print("  warn: lz4 ramdisk detected but python-lz4 is not installed and "
              "lz4 CLI fallback failed; install either `pip install lz4` "
              "or an `lz4` command-line tool", file=sys.stderr)
        return None
    try:
        return _lz4_frame.decompress(data)
    except Exception:
        result = _try_lz4_cli(data)
        if result is not None:
            return result
        return None


def _lz4_stdin_cli_commands() -> tuple[list[str], ...]:
    """Candidate commands for decoding LZ4 data from stdin."""
    return (
        ["lz4", "-dc", "-"],
        ["lz4", "-l", "-dc", "-"],
        ["lz4cat"],
        ["unlz4", "-c"],
    )


def _lz4_file_cli_commands(src: Path) -> tuple[list[str], ...]:
    """Candidate commands for decoding an LZ4-compressed file."""
    src_str = str(src)
    return (
        ["lz4", "-dc", "--", src_str],
        ["lz4", "-l", "-dc", "--", src_str],
        ["lz4cat", "--", src_str],
        ["unlz4", "-c", "--", src_str],
    )


def _try_lz4_cli(data: bytes) -> bytes | None:
    """Try LZ4 decompression via external lz4 CLI using stdin/stdout."""
    for cmd in _lz4_stdin_cli_commands():
        try:
            result = subprocess.run(
                cmd,
                input=data,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=_DECOMPRESS_TIMEOUT,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            continue
        if result.returncode == 0:
            return result.stdout
    return None


def _try_lz4_cli_file(src: Path, out_path: Path) -> tuple[bool, bytes]:
    """Try LZ4 decompression of *src* via external CLI variants into *out_path*."""
    last_stderr = b""
    for cmd in _lz4_file_cli_commands(src):
        try:
            with open(str(out_path), "wb") as f_out:
                result = subprocess.run(
                    cmd,
                    stdout=f_out,
                    stderr=subprocess.PIPE,
                    timeout=_DECOMPRESS_TIMEOUT,
                )
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            out_path.unlink(missing_ok=True)
            continue
        if result.returncode == 0 and out_path.stat().st_size > 0:
            return True, b""
        last_stderr = result.stderr
        out_path.unlink(missing_ok=True)
    return False, last_stderr


def _try_lzma(data: bytes) -> bytes | None:
    # XZ: FD 37 7A 58 5A 00   LZMA: first byte 0x5D usually
    if data[:6] == b"\xfd7zXZ\x00" or (data[0] == 0x5D and len(data) > 13):
        try:
            return lzma.decompress(data)
        except Exception:
            return None
    return None


def _try_zstd(data: bytes) -> bytes | None:
    if data[:4] != b"\x28\xb5\x2f\xfd":
        return None
    if not _HAS_ZSTD:
        print("  warn: zstd ramdisk detected but zstandard not installed; "
              "run: pip install zstandard", file=sys.stderr)
        return None
    try:
        dctx = _zstd.ZstdDecompressor()
        return dctx.decompress(data, max_output_size=256 * 1024 * 1024)
    except Exception:
        return None


def _try_bz2(data: bytes) -> bytes | None:
    if data[:2] != b"BZ":
        return None
    try:
        return bz2.decompress(data)
    except Exception:
        return None


def decompress_ramdisk(data: bytes) -> bytes | None:
    """Try all known compression formats; return raw cpio bytes or None."""
    for fn in (_try_gzip, _try_lz4, _try_lzma, _try_zstd, _try_bz2):
        result = fn(data)
        if result is not None:
            return result
    # Already uncompressed cpio?
    if data[:6] in (b"070701", b"070702", b"070707"):
        return data
    return None


# ════════════════════════════════════════════════════════════════════════════
# CPIO extraction (newc format — 070701/070702; odc — 070707)
# We only extract files that are useful for hardware analysis.
# ════════════════════════════════════════════════════════════════════════════

TARGET_NAMES = {
    "fstab", "init.rc", "ueventd.rc", "default.prop",
    "prop.default", "build.prop",
}
TARGET_PREFIXES = ("init.", "ueventd.", "fstab.", "lib/modules/")
TARGET_SUFFIXES = (".rc", ".prop", ".fstab", ".ko", ".so", ".pb")

# ── .pb (protobuf) bare-metal value extractor ────────────────────────────────
# Maps filename substrings → sysconfig category key prefix.
_PB_CATEGORY: list[tuple[str, str]] = [
    ("pwrctrl",   "pwrctrl"),
    ("power",     "pwrctrl"),
    ("pmu",       "pwrctrl"),
    ("pin",       "pins"),
    ("gpio",      "pins"),
    ("reg",       "reg"),
    ("regulator", "reg"),
    ("device",    "deviceinfo"),
    ("hardware",  "deviceinfo"),
    ("board",     "deviceinfo"),
]

_PB_HEX_RE    = re.compile(r"0x[0-9a-fA-F]{4,}")
_PB_PIN_RE    = re.compile(r"\bgp[phabn]\d+[-_]?\d*\b|\bgpio\d+\b", re.IGNORECASE)
_PB_PWR_RE    = re.compile(r"\bpd_\w+\b|\bpwrctrl\b|\bpmic\w*\b", re.IGNORECASE)
_PB_COMPAT_RE = re.compile(r"\b[\w]{2,},[\w-]+\b")


def _ingest_pb_file(pb_path: Path, src_path: str, run_id: int,
                    cur: sqlite3.Cursor) -> None:
    """Extract bare-metal values from a binary .pb protobuf file.

    Reads the raw bytes, recovers printable ASCII strings ≥ 4 chars,
    then filters for hardware-relevant patterns (register addresses,
    pin identifiers, power domains, compatible strings) and stores up
    to 64 results per file in sysconfig_entry so that export_postmarketos
    and report.py can surface them.
    """
    try:
        raw = pb_path.read_bytes()
    except OSError:
        return

    stem = pb_path.stem.lower()
    category = "ramdisk_pb"
    for frag, cat in _PB_CATEGORY:
        if frag in stem:
            category = cat
            break

    # Recover printable ASCII strings (min 4 chars) from binary blob
    strings: list[str] = []
    buf: list[str] = []
    for byte in raw:
        ch = chr(byte)
        if 0x20 <= byte < 0x7F:  # printable ASCII
            buf.append(ch)
        else:
            if len(buf) >= 4:
                strings.append("".join(buf))
            buf.clear()
    if len(buf) >= 4:
        strings.append("".join(buf))

    # Keep only hardware-relevant strings
    hw_strings: list[str] = []
    for s in strings:
        if (_PB_HEX_RE.search(s) or _PB_PIN_RE.search(s)
                or _PB_PWR_RE.search(s) or _PB_COMPAT_RE.search(s)):
            hw_strings.append(s)

    for i, val in enumerate(hw_strings[:64]):
        key = f"pb.{category}.{pb_path.name}.{i}"
        try:
            cur.execute(
                """INSERT OR IGNORE INTO sysconfig_entry
                   (run_id, source, key, value) VALUES (?,?,?,?)""",
                (run_id, src_path, key, val[:512]),
            )
        except sqlite3.Error:
            pass


def _want_file(name: str) -> bool:
    base = name.lstrip("/").split("/")[-1]
    stripped = name.lstrip("/")
    if base in TARGET_NAMES:
        return True
    for pfx in TARGET_PREFIXES:
        if stripped.startswith(pfx):
            return True
    for sfx in TARGET_SUFFIXES:
        if base.endswith(sfx):
            return True
    return False


def _align4(n: int) -> int:
    return (n + 3) & ~3


def extract_cpio_newc(data: bytes, out_dir: Path) -> list[str]:
    """Extract a newc CPIO archive; return list of extracted paths."""
    extracted: list[str] = []
    pos = 0

    while pos < len(data):
        if pos + 110 > len(data):
            break
        hdr = data[pos:pos + 110]
        if hdr[:6] not in (b"070701", b"070702"):
            break

        # Parse fixed-width hex fields
        def _hex(start: int, length: int = 8) -> int:
            return int(hdr[start:start + length], 16)

        namesize = _hex(94)
        filesize = _hex(54)

        pos += 110
        # Name (null-terminated, padded to 4-byte boundary after header+name)
        name_raw = data[pos:pos + namesize]
        name = name_raw.rstrip(b"\x00").decode("utf-8", errors="replace")
        pos += _align4(110 + namesize) - 110

        if name == "TRAILER!!!":
            break

        file_data = data[pos:pos + filesize]
        pos += _align4(filesize)

        if name and _want_file(name):
            out_path = out_dir / name.lstrip("/")
            out_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                out_path.write_bytes(file_data)
                extracted.append(name)
            except OSError:
                pass

    return extracted


def extract_cpio_odc(data: bytes, out_dir: Path) -> list[str]:
    """Extract an odc (old portable) CPIO archive."""
    extracted: list[str] = []
    pos = 0

    while pos < len(data):
        if pos + 76 > len(data):
            break
        hdr = data[pos:pos + 76]
        if hdr[:6] != b"070707":
            break

        def _oct(start: int, length: int) -> int:
            return int(hdr[start:start + length], 8)

        namesize = _oct(59, 6)
        filesize = _oct(65, 11)

        pos += 76
        name_raw = data[pos:pos + namesize]
        name = name_raw.rstrip(b"\x00").decode("utf-8", errors="replace")
        pos += namesize

        if name == "TRAILER!!!":
            break

        file_data = data[pos:pos + filesize]
        pos += filesize

        if name and _want_file(name):
            out_path = out_dir / name.lstrip("/")
            out_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                out_path.write_bytes(file_data)
                extracted.append(name)
            except OSError:
                pass

    return extracted


def extract_cpio(data: bytes, out_dir: Path) -> list[str]:
    if data[:6] in (b"070701", b"070702"):
        return extract_cpio_newc(data, out_dir)
    if data[:6] == b"070707":
        return extract_cpio_odc(data, out_dir)
    return []


# ════════════════════════════════════════════════════════════════════════════
# Fstab parser + DB import
# fstab format:  <device>  <mount_point>  <type>  <options>  <dump>  <pass>
# The options field contains encryption flags:
#   encryptable=       FDE encryption key path
#   fileencryption=    FBE policy (contents:filenames[:mode])
#   keydirectory=      metadata encryption key dir
#   avb=               AVB vbmeta partition
#   logical_block_size / physical_block_size
# ════════════════════════════════════════════════════════════════════════════

def parse_fstab(text: str, source: str, run_id: int,
                cur: sqlite3.Cursor) -> int:
    """Parse one fstab file and insert entries into sysconfig_entry; return count."""
    inserted = 0
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        device, mount, fstype, options = parts[0], parts[1], parts[2], parts[3]
        base_key = f"fstab.{mount.replace('/', '_')}"

        for k, v in [
            ("device", device),
            ("type",   fstype),
            ("options", options),
        ]:
            try:
                cur.execute(
                    """INSERT OR IGNORE INTO sysconfig_entry
                       (run_id, source, key, value) VALUES (?,?,?,?)""",
                    (run_id, source, f"{base_key}.{k}", v),
                )
                inserted += cur.rowcount
            except sqlite3.Error:
                pass

        # Break out individual mount options
        for opt in options.split(","):
            if "=" in opt:
                ok, _, ov = opt.partition("=")
            else:
                ok, ov = opt, "1"
            ok = ok.strip()
            ov = ov.strip()
            if ok in ("encryptable", "forceencrypt", "fileencryption", "keydirectory",
                      "avb", "logical_block_size", "physical_block_size",
                      "metadata_encryption", "wrappedkey"):
                try:
                    cur.execute(
                        """INSERT OR IGNORE INTO sysconfig_entry
                           (run_id, source, key, value) VALUES (?,?,?,?)""",
                        (run_id, source,
                         f"{base_key}.enc.{ok}", ov),
                    )
                    inserted += cur.rowcount
                except sqlite3.Error:
                    pass

        # Detect and report encryption type
        enc_type = "none"
        if "fileencryption=" in options:
            enc_type = "fbe"
        elif "encryptable=" in options or "forceencrypt=" in options:
            enc_type = "fde"
        if enc_type != "none":
            try:
                cur.execute(
                    """INSERT OR IGNORE INTO sysconfig_entry
                       (run_id, source, key, value) VALUES (?,?,?,?)""",
                    (run_id, source, f"{base_key}.enc_type", enc_type),
                )
                inserted += cur.rowcount
            except sqlite3.Error:
                pass

    return inserted


# ════════════════════════════════════════════════════════════════════════════
# dm-crypt / dm-verity metadata detection
# On an FDE device the raw userdata partition starts with a 16-KiB
# "crypto footer" at a magic offset.  We detect its presence without
# trying to decrypt so the pipeline can note the encryption state.
# ════════════════════════════════════════════════════════════════════════════

CRYPT_FOOTER_MAGIC = 0xD0B5B1C4  # MAGIC_CRYPT_FOOTER


def detect_fde_footer(data: bytes) -> bool:
    """Return True if data contains an Android FDE crypto footer magic."""
    # Footer can appear at multiple offsets depending on partition size;
    # check the first 64 KiB.
    check_size = min(len(data), 65536)
    for offset in range(0, check_size - 4, 4):
        val = struct.unpack_from("<I", data, offset)[0]
        if val == CRYPT_FOOTER_MAGIC:
            return True
    return False


DM_VERITY_MAGIC = b"verity"


def detect_dm_verity(data: bytes) -> bool:
    """Return True if data looks like a dm-verity protected image."""
    return DM_VERITY_MAGIC in data[:4096]


# ════════════════════════════════════════════════════════════════════════════
# Path helpers
# ════════════════════════════════════════════════════════════════════════════

def _path_relative_to(path: Path, base: Path) -> str:
    """Return path as base-relative POSIX string when possible."""
    try:
        return path.resolve().relative_to(base.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def _default_dump_dir() -> Path:
    """Prefer option-5 extraction root; fall back to live_dump."""
    hom_root = Path.home() / "hands-on-metal"
    boot_work = hom_root / "boot_work"
    live_dump = hom_root / "live_dump"
    return boot_work if boot_work.exists() else live_dump


def _get_env_registry_val(key: str) -> str:
    """Return the value of *key* from ~/hands-on-metal/env_registry.sh, or ''.

    The registry uses lines of the form:
        KEY="VALUE"  # cat:category
    Written by core/* scripts via _reg_set().
    """
    reg = Path.home() / "hands-on-metal" / "env_registry.sh"
    if not reg.exists():
        return ""
    try:
        for line in reg.read_text(errors="replace").splitlines():
            if not line.startswith(key + "="):
                continue
            rest = line[len(key) + 1:]          # everything after '='
            if rest.startswith('"'):
                parts = rest.split('"', 2)
                return parts[1] if len(parts) >= 2 else ""
            return rest.split()[0]              # unquoted value (edge case)
    except OSError:
        pass
    return ""


def _set_env_registry_val(key: str, value: str,
                          category: str = "unpack") -> None:
    """Write *key*=*value* to ~/hands-on-metal/env_registry.sh.

    Creates the registry file if it does not yet exist.  Any existing line
    for the same key is replaced so the file stays idempotent across runs.
    The format matches core/*'s _reg_set() shell helper:
        KEY="VALUE"  # cat:<category>
    """
    reg = Path.home() / "hands-on-metal" / "env_registry.sh"
    try:
        reg.parent.mkdir(parents=True, exist_ok=True)
        existing: list[str] = []
        if reg.exists():
            existing = reg.read_text(errors="replace").splitlines()
        # Drop any previous line for this key.
        filtered = [ln for ln in existing if not ln.startswith(key + "=")]
        filtered.append(f'{key}="{value}"  # cat:{category}')
        reg.write_text("\n".join(filtered) + "\n")
    except OSError as exc:
        print(f"  warn: could not write {key} to env_registry: {exc}",
              file=sys.stderr)


def _decompress_image(src: Path, dest_dir: Path) -> Optional[Path]:
    """Decompress a .gz or .lz4 compressed partition image into *dest_dir*.

    Handles:
      • .gz  — gzip (TWRP .win.gz, Samsung boot.img.gz)
      • .lz4 — LZ4 framed (TWRP .win.lz4, Samsung boot.img.lz4)

    The output filename strips the compression suffix and any TWRP
    .emmc.win infix so the result looks like a plain *.img file.
    The decompressed path is returned on success; None on failure.
    The caller is responsible for adding the returned path to its
    discovery list so it is visible to subsequent pipeline steps.
    """
    suffix = src.suffix.lower()
    if suffix not in (".gz", ".lz4"):
        return None

    # Build a clean output filename.
    stem = src.stem                         # drop last extension (.gz / .lz4)
    for infix in (".emmc.win", ".emmc", ".win"):
        if stem.endswith(infix):
            stem = stem[: -len(infix)]
            break
    out_name = stem + ".img"

    try:
        dest_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        print(f"    ↳ cannot create decompression dir {dest_dir}: {exc}",
              file=sys.stderr)
        return None

    out_path = dest_dir / out_name
    print(f"    ↳ decompressing {suffix[1:].upper()} backup: "
          f"{src.name} → {out_path}")

    try:
        if suffix == ".gz":
            with gzip.open(str(src), "rb") as f_in, \
                 open(str(out_path), "wb") as f_out:
                while True:
                    chunk = f_in.read(1 << 20)   # 1 MiB chunks
                    if not chunk:
                        break
                    f_out.write(chunk)
            return out_path

        # .lz4 — prefer the Python binding; fall back to the lz4 CLI tool.
        if _HAS_LZ4:
            try:
                with open(str(src), "rb") as f_in, \
                     open(str(out_path), "wb") as f_out:
                    ctx = _lz4_frame.LZ4FrameDecompressor()
                    while True:
                        chunk = f_in.read(1 << 20)
                        if not chunk:
                            break
                        f_out.write(ctx.decompress(chunk))
                return out_path
            except Exception as lz4_err:
                print(f"    ↳ lz4.frame failed: {lz4_err} — trying lz4 CLI",
                      file=sys.stderr)
                out_path.unlink(missing_ok=True)

        # CLI fallback (lz4 tool from Termux / apt).
        ok, err = _try_lz4_cli_file(src, out_path)
        if ok:
            return out_path
        if err:
            print(
                "    ↳ lz4 CLI failed: "
                + err.decode(errors="replace").strip(),
                file=sys.stderr,
            )
        else:
            print("    ↳ lz4 tool unavailable or timed out",
                  file=sys.stderr)
        return None

    except OSError as exc:
        print(f"    ↳ decompression failed for {src.name}: {exc}",
              file=sys.stderr)
        out_path.unlink(missing_ok=True)
        return None


# ════════════════════════════════════════════════════════════════════════════
# Main image processing pipeline
# ════════════════════════════════════════════════════════════════════════════

def process_image(img_path: Path, dump: Path, run_id: int,
                  cur: sqlite3.Cursor) -> dict:
    """
    Process one boot/vendor_boot image file.
    Returns a dict with status info.
    """
    image_rel = _path_relative_to(img_path, dump)
    result: dict = {"path": image_rel, "status": "ok",
                    "ramdisk_files": [], "enc_detected": False}

    raw = img_path.read_bytes()

    # Detect encryption / special formats before parsing
    if is_sparse_image(raw):
        result["status"] = "sparse_image_skipped"
        print(f"    ↳ sparse image, skipping (run simg2img first): {img_path.name}")
        return result

    if detect_fde_footer(raw[:65536]):
        result["enc_detected"] = True
        print(f"    ↳ FDE crypto footer detected in {img_path.name}")
        try:
            cur.execute(
                """INSERT OR IGNORE INTO sysconfig_entry
                   (run_id, source, key, value) VALUES (?,?,?,?)""",
                (run_id, f"image:{image_rel}", "encryption.fde_footer", "detected"),
            )
        except sqlite3.Error:
            pass

    if detect_dm_verity(raw):
        print(f"    ↳ dm-verity signature detected in {img_path.name}")
        try:
            cur.execute(
                """INSERT OR IGNORE INTO sysconfig_entry
                   (run_id, source, key, value) VALUES (?,?,?,?)""",
                (run_id, f"image:{image_rel}", "encryption.dm_verity", "detected"),
            )
        except sqlite3.Error:
            pass

    # Parse boot image structure
    img = parse_boot_image(raw)
    if img is None:
        result["status"] = "not_a_boot_image"
        return result

    print(f"    ↳ boot image v{img.version}, ramdisk={len(img.ramdisk_data)} bytes")

    # Store bare-metal boot image values: kernel cmdline and page size
    for sc_key, sc_val in (
        ("boot.pagesize", str(img.page_size)),
        ("boot.cmdline",  img.cmdline),
    ):
        if sc_val and sc_val != "0":
            try:
                cur.execute(
                    """INSERT OR IGNORE INTO sysconfig_entry
                       (run_id, source, key, value) VALUES (?,?,?,?)""",
                    (run_id, f"image:{image_rel}", sc_key, sc_val),
                )
            except sqlite3.Error:
                pass

    if not img.ramdisk_data:
        result["status"] = "no_ramdisk"
        return result

    # Decompress ramdisk
    cpio_data = decompress_ramdisk(img.ramdisk_data)
    if cpio_data is None:
        result["status"] = "ramdisk_decompress_failed"
        print(f"    ↳ could not decompress ramdisk (unknown format)", file=sys.stderr)
        return result

    print(f"    ↳ ramdisk decompressed: {len(cpio_data)} bytes")

    safe_stem = "".join(ch if ch.isalnum() else "_" for ch in img_path.stem)
    if not safe_stem:
        safe_stem = "image"

    # Extract CPIO
    out_dir = dump / "ramdisk" / safe_stem
    out_dir.mkdir(parents=True, exist_ok=True)
    files = extract_cpio(cpio_data, out_dir)
    result["ramdisk_files"] = files
    print(f"    ↳ extracted {len(files)} relevant files to {out_dir.relative_to(dump)}/")

    # Parse fstab files and ingest .pb files found in the ramdisk
    for fname in files:
        fname_lower = fname.lower()
        if "fstab" in fname_lower:
            fpath = out_dir / fname.lstrip("/")
            if fpath.exists():
                text = fpath.read_text(errors="replace")
                n = parse_fstab(text, f"ramdisk:{image_rel}/{fname}",
                                run_id, cur)
                if n:
                    print(f"      fstab {fname}: {n} entries")
        elif fname_lower.endswith(".pb"):
            fpath = out_dir / fname.lstrip("/")
            if fpath.exists():
                _ingest_pb_file(fpath, f"ramdisk:{image_rel}/{fname}", run_id, cur)

    # Register extracted files in collected_file
    for fname in files:
        src_path = f"ramdisk:{image_rel}/{fname}"
        local_rel = (Path("ramdisk") / safe_stem / fname.lstrip("/")).as_posix()
        p = dump / local_rel
        size = p.stat().st_size if p.exists() else None
        try:
            cur.execute(
                """INSERT OR IGNORE INTO collected_file
                   (run_id, src_path, local_path, size_bytes)
                   VALUES (?,?,?,?)""",
                (run_id, src_path, local_rel, size),
            )
        except sqlite3.Error:
            pass

    # Save DTB if present (for vendor_boot)
    if img.dtb_data:
        dtb_out = dump / "ramdisk" / safe_stem / "dtb.img"
        dtb_out.write_bytes(img.dtb_data)
        print(f"    ↳ DTB saved ({len(img.dtb_data)} bytes)")

    return result


# ════════════════════════════════════════════════════════════════════════════
# Image discovery
# ════════════════════════════════════════════════════════════════════════════

IMAGE_NAMES = ("boot.img", "vendor_boot.img", "recovery.img",
               "init_boot.img")

_ARCHIVE_SUFFIXES = (
    ".zip",
    ".tar",
    ".tgz",
    ".tar.gz",
    ".tbz2",
    ".tar.bz2",
    ".txz",
    ".tar.xz",
)
_TAR_SUFFIXES = tuple(sfx for sfx in _ARCHIVE_SUFFIXES if sfx != ".zip")


def _is_archive_file(path: Path) -> bool:
    name = path.name.lower()
    return any(name.endswith(sfx) for sfx in _ARCHIVE_SUFFIXES)


def _is_tar_file(path: Path) -> bool:
    name = path.name.lower()
    return any(name.endswith(sfx) for sfx in _TAR_SUFFIXES)


def _safe_extract_zip(src: Path, out_dir: Path) -> bool:
    out_resolved = out_dir.resolve()
    try:
        with zipfile.ZipFile(src, "r") as zf:
            members = [m for m in zf.infolist() if not m.is_dir()]
            if not members:
                return False
            for member in members:
                if member.create_system == 3:  # Unix
                    mode = (member.external_attr >> 16) & 0xFFFF
                    # ZIP external_attr stores Unix mode bits in the upper
                    # 16 bits. 0o170000 = S_IFMT (file type mask);
                    # 0o120000 = S_IFLNK (symlink file type).
                    if (mode & 0o170000) == 0o120000:
                        continue
                rel = Path(member.filename)
                if rel.is_absolute() or ".." in rel.parts:
                    continue
                target = out_dir / rel
                try:
                    target.resolve().relative_to(out_resolved)
                except ValueError:
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(member, "r") as f_in, open(target, "wb") as f_out:
                    while True:
                        chunk = f_in.read(1 << 20)
                        if not chunk:
                            break
                        f_out.write(chunk)
        return True
    except (OSError, zipfile.BadZipFile):
        return False


def _safe_extract_tar(src: Path, out_dir: Path) -> bool:
    out_resolved = out_dir.resolve()
    try:
        with tarfile.open(src, "r:*") as tf:
            members = [m for m in tf.getmembers() if m.isfile()]
            if not members:
                return False
            for member in members:
                rel = Path(member.name)
                if rel.is_absolute() or ".." in rel.parts:
                    continue
                target = out_dir / rel
                try:
                    target.resolve().relative_to(out_resolved)
                except ValueError:
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                f_in = tf.extractfile(member)
                # Defensive guard for malformed archives despite m.isfile().
                if f_in is None:
                    continue
                with f_in, open(target, "wb") as f_out:
                    while True:
                        chunk = f_in.read(1 << 20)
                        if not chunk:
                            break
                        f_out.write(chunk)
        return True
    except (OSError, tarfile.TarError):
        return False


def _extract_nested_archives(roots: list[Path], cache_root: Path) -> list[Path]:
    """Recursively extract archives under *roots* into *cache_root*.

    Returned list preserves search order and contains both original roots and
    all extracted sub-roots so callers can recursively search nested content.
    """
    ordered_roots: list[Path] = []
    seen_roots: set[str] = set()
    for root in roots:
        if not root.exists():
            continue
        key = str(root.resolve())
        if key in seen_roots:
            continue
        seen_roots.add(key)
        ordered_roots.append(root)

    try:
        cache_root.mkdir(parents=True, exist_ok=True)
    except OSError:
        return ordered_roots

    seen_archives: set[str] = set()
    idx = 0
    while idx < len(ordered_roots):
        current = ordered_roots[idx]
        idx += 1
        for candidate in sorted(current.rglob("*")):
            if not candidate.is_file() or not _is_archive_file(candidate):
                continue
            try:
                akey = str(candidate.resolve())
            except OSError:
                akey = str(candidate)
            if akey in seen_archives:
                continue
            seen_archives.add(akey)

            try:
                st = candidate.stat()
                digest_src = f"{akey}:{st.st_size}:{st.st_dev}:{st.st_ino}"
            except OSError:
                digest_src = akey
            digest = hashlib.sha256(digest_src.encode("utf-8", errors="replace")).hexdigest()[:24]
            out_dir = cache_root / f"{candidate.stem}_{digest}"
            out_dir.mkdir(parents=True, exist_ok=True)

            ok = False
            if candidate.name.lower().endswith(".zip"):
                ok = _safe_extract_zip(candidate, out_dir)
            elif _is_tar_file(candidate):
                ok = _safe_extract_tar(candidate, out_dir)
            else:
                continue
            if not ok:
                continue
            try:
                rkey = str(out_dir.resolve())
            except OSError:
                rkey = str(out_dir)
            if rkey not in seen_roots:
                seen_roots.add(rkey)
                ordered_roots.append(out_dir)

    return ordered_roots


def find_images(dump: Path) -> list[Path]:
    """Return an ordered, de-duplicated list of boot/recovery images to process.

    Search priority (first wins per unique resolved path):

    1. **Option-5 known image** — ``HOM_BOOT_IMG_PATH`` from the live
       environment or ``env_registry.sh``.  This is the canonical image
       acquired and validated by ``core/boot_image.sh`` (option 5).

    2. **boot_work directory** — ``HOM_BOOT_WORK_DIR`` (env / registry) or
       ``~/hands-on-metal/boot_work``.  Covers the single acquired image *and*
       any additional partition images extracted from factory ZIPs by option 5
       into ``boot_work/partitions/``.

    3. **Extraction-first recursive search** inside *dump* (the ``--dump``
       directory). Nested ZIP/TAR archives are extracted first, then
       compressed backups (``.win.gz``, ``.win.lz4``, ``.img.lz4``) are
       decompressed into ``boot_work/`` on the fly so their resolved paths are
       known to all subsequent pipeline steps.
    """
    found: list[Path] = []
    _seen: set[str] = set()

    def _add(p: Path) -> None:
        try:
            key = str(p.resolve())
        except OSError:
            key = str(p)
        if key not in _seen and p.is_file() and p.stat().st_size > 0:
            _seen.add(key)
            found.append(p)

    # ── Priority 1: image known from option-5 (HOM_BOOT_IMG_PATH) ──────────
    # core/boot_image.sh writes this variable to env_registry.sh after every
    # successful acquisition.  Check the live env first (same shell session),
    # then the persisted registry (cross-session / re-invocation).
    known_val = (
        os.environ.get("HOM_BOOT_IMG_PATH")
        or _get_env_registry_val("HOM_BOOT_IMG_PATH")
    )
    if known_val:
        _add(Path(known_val))

    # ── Priority 2: boot_work directory (option-5 output tree) ─────────────
    # boot_work/partitions/ receives all images extracted from factory ZIPs
    # via _extract_all_partitions_from_inner_zip().  boot_work/ itself holds
    # the single acquired image (same as HOM_BOOT_IMG_PATH in most cases).
    boot_work_val = (
        os.environ.get("HOM_BOOT_WORK_DIR")
        or _get_env_registry_val("HOM_BOOT_WORK_DIR")
        or str(Path.home() / "hands-on-metal" / "boot_work")
    )
    boot_work = Path(boot_work_val)
    for bw_dir in (boot_work / "partitions", boot_work):
        if not bw_dir.exists():
            continue
        for name in IMAGE_NAMES:
            c = bw_dir / name
            if c.exists():
                _add(c)
        for img in sorted(bw_dir.glob("*.img")):
            if any(n in img.name for n in ("boot", "recovery", "ramdisk")):
                _add(img)

    # ── Priority 3: fallback search roots inside --dump ────────────────────
    search_dirs: list[Path] = [dump / "partitions", dump / "boot_images", dump]

    # Also check a sibling boot_work when dump is not already boot_work.
    sibling_boot_work = dump.parent / "boot_work"
    try:
        _sibling_resolved = sibling_boot_work.resolve()
        _boot_work_resolved = boot_work.resolve()
    except OSError:
        _sibling_resolved = sibling_boot_work
        _boot_work_resolved = boot_work
    if _sibling_resolved != _boot_work_resolved:
        search_dirs.extend([sibling_boot_work / "partitions", sibling_boot_work])

    # De-duplicate directories while preserving order.
    uniq_dirs: list[Path] = []
    seen_dirs: set[str] = set()
    for d in search_dirs:
        try:
            key = str(d.resolve())
        except OSError:
            key = str(d)
        if key in seen_dirs:
            continue
        seen_dirs.add(key)
        uniq_dirs.append(d)

    # Expand nested archive trees first so image discovery can start at the
    # extraction root and walk all nested archive content before parsing.
    extract_cache = boot_work / "extracted_archives"
    deep_dirs = _extract_nested_archives(uniq_dirs, extract_cache)

    for search_dir in deep_dirs:
        if not search_dir.exists():
            continue
        # Also recursively discover *.img candidates.
        for img in sorted(search_dir.rglob("*.img")):
            if img.name in IMAGE_NAMES or any(n in img.name for n in ("boot", "recovery", "ramdisk")):
                _add(img)
        # Decompress .gz / .lz4 compressed backups found during the fallback
        # search (e.g. TWRP .win.gz, Samsung boot.img.lz4).  The decompressed
        # image is written into boot_work/ so its location is persistently known
        # alongside other option-5 output images.
        for pattern in ("*.gz", "*.lz4"):
            for comp in sorted(search_dir.rglob(pattern)):
                if any(n in comp.name
                       for n in ("boot", "recovery", "ramdisk", ".win")):
                    dec = _decompress_image(comp, boot_work)
                    if dec is not None:
                        _add(dec)

    return found


# ════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Unpack Android boot/ramdisk images into the hardware_map database"
    )
    ap.add_argument("--db",     default="hardware_map.sqlite",
                    help="Path to hardware_map.sqlite (default: ./hardware_map.sqlite)")
    ap.add_argument("--dump",   default=str(_default_dump_dir()),
                    help="Root of the collection dump directory "
                         "(default: ~/hands-on-metal/boot_work if present, else ~/hands-on-metal/live_dump)")
    ap.add_argument("--run-id", default=1, type=int, dest="run_id",
                    help="Run ID for DB rows (default: 1)")
    ap.add_argument("--image",  default=None,
                    help="Explicit path to a single image file (skips auto-discovery)")
    args = ap.parse_args()

    dump    = Path(args.dump)
    db_path = Path(args.db)

    db = sqlite3.connect(str(db_path))
    schema = Path(__file__).parent.parent / "schema" / "hardware_map.sql"
    if schema.exists():
        db.executescript(schema.read_text())

    cur = db.cursor()

    if args.image:
        images = [Path(args.image)]
    else:
        images = find_images(dump)

    if not images:
        print(
            "No boot images found.\n"
            "  Option 5 (core/boot_image.sh) is the recommended way to acquire\n"
            "  the boot image — run it first, then re-run this script.\n"
            f"  Fallback search was: {dump}/partitions/, {dump}/boot_images/, {dump}/\n"
            "  You can also use --image <path> to supply an image directly.",
            file=sys.stderr,
        )
        sys.exit(0)

    print(f"Processing {len(images)} image(s)...")
    total_files = 0
    for img_path in images:
        print(f"  {img_path.name}")
        result = process_image(img_path, dump, args.run_id, cur)
        total_files += len(result.get("ramdisk_files", []))

    db.commit()
    db.close()
    print(f"\nDone — {total_files} ramdisk files extracted total.")
    print("Tip: re-run build_table.py or report.py to refresh the database.")

    # Register the extraction paths in env_registry so that downstream
    # pipeline steps (parse_manifests.py, build_table.py, report.py …)
    # know where to find the extracted ramdisk files without having to
    # re-discover them.
    ramdisk_dir = dump / "ramdisk"
    if ramdisk_dir.exists():
        _set_env_registry_val("HOM_RAMDISK_DIR",    str(ramdisk_dir))
        _set_env_registry_val("HOM_UNPACK_DUMP_DIR", str(dump))
        print(f"Registered HOM_RAMDISK_DIR={ramdisk_dir} in env_registry.")


if __name__ == "__main__":
    main()
