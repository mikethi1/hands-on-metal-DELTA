# tools/ — Bundled Offline Binaries

This directory holds optional pre-built binaries that make the ZIPs fully self-contained.
**None of these are committed to the repository** — obtain them locally before building the ZIPs.

## Quick setup (recommended)

The easiest way to populate this directory is to run the full dependency fetcher
from the repository root. It downloads everything, builds both flashable ZIPs,
and creates a single offline bundle:

```bash
cat <<'EOF' > /tmp/hands-on-metal-fetch-deps.sh
#!/usr/bin/env bash
set -e
bash build/fetch_all_deps.sh
EOF
chmod +x /tmp/hands-on-metal-fetch-deps.sh
/tmp/hands-on-metal-fetch-deps.sh
```

## Required binaries

| File | Purpose | Source |
|------|---------|--------|
| `busybox-arm64` | Static busybox for recovery shell | [busybox.net](https://busybox.net/downloads/binaries/) |
| `magisk64` | Magisk 64-bit binary for patching | Extracted from Magisk APK (see below) |
| `magisk32` | Magisk 32-bit binary (older SoCs) | Extracted from Magisk APK (see below) |
| `magiskinit64` | Magisk init binary | Extracted from Magisk APK |

## Manual setup (if not using fetch_all_deps.sh)

```bash
cat <<'EOF' > /tmp/hands-on-metal-manual-setup.sh
#!/usr/bin/env bash
set -e

# 1. busybox (static arm64)
curl -L -o tools/busybox-arm64 \
  https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv8l
chmod +x tools/busybox-arm64

# 2. Magisk binaries — extract from the official APK
MAGISK_VER="v30.7"
_TMP="${TMPDIR:-/tmp}"
curl -L -o "$_TMP/magisk.apk" \
  "https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VER}/Magisk-${MAGISK_VER}.apk"

unzip -jo "$_TMP/magisk.apk" 'lib/arm64-v8a/libmagisk.so'    -d "$_TMP/"
cp "$_TMP/libmagisk.so"     tools/magisk64   && chmod +x tools/magisk64

unzip -jo "$_TMP/magisk.apk" 'lib/armeabi-v7a/libmagisk.so'  -d "$_TMP/"
cp "$_TMP/libmagisk.so"     tools/magisk32   && chmod +x tools/magisk32

unzip -jo "$_TMP/magisk.apk" 'lib/arm64-v8a/libmagiskinit.so' -d "$_TMP/"
cp "$_TMP/libmagiskinit.so" tools/magiskinit64 && chmod +x tools/magiskinit64

rm "$_TMP/magisk.apk" "$_TMP"/lib*.so
EOF
chmod +x /tmp/hands-on-metal-manual-setup.sh
/tmp/hands-on-metal-manual-setup.sh
```

> **Legal**: Magisk is GPL-3.0 licensed. By distributing binaries you must also make the source available.
> Official source: https://github.com/topjohnwu/Magisk

## Verifying binaries

```bash
cat <<'EOF' > /tmp/hands-on-metal-verify-bins.sh
#!/usr/bin/env bash
set -e
# Busybox
file tools/busybox-arm64   # should say "ELF 64-bit LSB executable, ARM aarch64"

# Magisk
file tools/magisk64         # should say "ELF 64-bit LSB executable, ARM aarch64"
file tools/magisk32         # should say "ELF 32-bit LSB executable, ARM"
EOF
chmod +x /tmp/hands-on-metal-verify-bins.sh
/tmp/hands-on-metal-verify-bins.sh
```

## Building without bundled tools

```bash
cat <<'EOF' > /tmp/hands-on-metal-build-no-tools.sh
#!/usr/bin/env bash
set -e
bash build/build_offline_zip.sh --no-tools
EOF
chmod +x /tmp/hands-on-metal-build-no-tools.sh
/tmp/hands-on-metal-build-no-tools.sh
```

The ZIPs will still work — they use whatever is already on the device (system
Magisk binary, system busybox). Bundling is only needed for a fully standalone
offline package.
