# recovery-zip/tools/README.md
# Busybox Static Binary

This directory must contain a statically compiled `busybox-arm64` binary before
the recovery ZIP is built.  It is not committed to the repository because
pre-built binaries are large and architecture-specific.

## Obtaining busybox-arm64

**Option 1 — Download a pre-built binary (recommended):**

```bash
# From the official busybox static builds
curl -L -o tools/busybox-arm64 \
  https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox_ARM64
chmod +x tools/busybox-arm64
```

**Option 2 — Cross-compile from source:**

```bash
# Requires an aarch64 cross-toolchain (e.g. aarch64-linux-gnu-gcc)
git clone https://git.busybox.net/busybox
cd busybox
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
# Enable CONFIG_STATIC=y in the defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
cp busybox ../tools/busybox-arm64
```

## Building the flashable ZIP

After placing `busybox-arm64` in this directory:

```bash
cd recovery-zip/
zip -r ../hands-on-metal-recovery.zip META-INF/ tools/
```

Flash `hands-on-metal-recovery.zip` via OrangeFox or TWRP.
