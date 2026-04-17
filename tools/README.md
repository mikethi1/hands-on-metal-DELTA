# tools/ — Bundled Offline Binaries

This directory holds optional pre-built binaries that make the ZIPs fully self-contained.  
**None of these are committed to the repository** — obtain them locally before building the ZIPs.

## Required binaries

| File | Purpose | Source |
|------|---------|--------|
| `busybox-arm64` | Static busybox for recovery shell | [busybox.net](https://busybox.net/downloads/binaries/) |
| `magisk64` | Magisk 64-bit binary for patching | Extracted from Magisk APK (see below) |
| `magisk32` | Magisk 32-bit binary (older SoCs) | Extracted from Magisk APK (see below) |
| `magiskinit64` | Magisk init binary | Extracted from Magisk APK |

## How to obtain

```bash
# 1. busybox (static arm64)
curl -L -o tools/busybox-arm64 \
  https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox_ARM64
chmod +x tools/busybox-arm64

# 2. Magisk binaries — extract from the official APK
MAGISK_VER="v27.0"
curl -L -o /tmp/magisk.apk \
  "https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VER}/Magisk-${MAGISK_VER}.apk"

unzip -j /tmp/magisk.apk 'lib/arm64-v8a/libmagisk64.so'   -d /tmp/
unzip -j /tmp/magisk.apk 'lib/armeabi-v7a/libmagisk32.so' -d /tmp/
unzip -j /tmp/magisk.apk 'lib/arm64-v8a/libmagiskinit.so' -d /tmp/

cp /tmp/libmagisk64.so   tools/magisk64   && chmod +x tools/magisk64
cp /tmp/libmagisk32.so   tools/magisk32   && chmod +x tools/magisk32
cp /tmp/libmagiskinit.so tools/magiskinit64 && chmod +x tools/magiskinit64

rm /tmp/magisk.apk /tmp/lib*.so
```

> **Legal**: Magisk is GPL-3.0 licensed. By distributing binaries you must also make the source available.  
> Official source: https://github.com/topjohnwu/Magisk

## Verifying binaries

```bash
# Busybox
./tools/busybox-arm64 --help | head -1

# Magisk
# (binaries are arm64, run on device or via QEMU arm64 emulation)
file tools/magisk64   # should say "ELF 64-bit LSB executable, ARM aarch64"
file tools/magisk32   # should say "ELF 32-bit LSB executable, ARM"
```

## Building without bundled tools

```bash
bash build/build_offline_zip.sh --no-tools
```

The ZIPs will still work — they use whatever is already on the device (system Magisk binary, system busybox). Bundling is only needed for a fully standalone offline package.
