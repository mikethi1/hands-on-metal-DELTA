# recovery-zip/tools/README.md
# Busybox Static Binary

This directory must contain a statically compiled `busybox-arm64` binary before
the recovery ZIP is built. It is not committed to the repository because
pre-built binaries are large and architecture-specific.

## Quick setup (recommended)

The easiest way to populate this directory (and build both flashable ZIPs) is to
run the full dependency fetcher from the repository root:

```bash
bash build/fetch_all_deps.sh
```

This downloads busybox, the Magisk binaries, and builds everything in one step.

## Obtaining busybox-arm64 manually

**Option 1 — Download a pre-built binary (recommended):**

```bash
curl -L -o recovery-zip/tools/busybox-arm64 \
  https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv8l
chmod +x recovery-zip/tools/busybox-arm64
```

**Option 2 — Cross-compile from source:**

```bash
# Requires an aarch64 cross-toolchain (e.g. aarch64-linux-gnu-gcc)
git clone https://git.busybox.net/busybox
cd busybox
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
# Enable CONFIG_STATIC=y in the defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
cp busybox ../recovery-zip/tools/busybox-arm64
```

## Building the flashable ZIP

After placing `busybox-arm64` in this directory, you can build either way:

**Using the build script (recommended):**

```bash
bash build/build_offline_zip.sh
```

**Manually:**

```bash
cd recovery-zip/
zip -r ../hands-on-metal-recovery.zip META-INF/ tools/
```

Flash `hands-on-metal-recovery.zip` via OrangeFox or TWRP:

```
Boot into TWRP/OrangeFox → Install → select hands-on-metal-recovery.zip → swipe to confirm → reboot
```
