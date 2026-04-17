# hands-on-metal — User Install Guide (Recovery / TWRP Path)

> **Use this guide if Magisk is NOT yet installed on your device.**
> If Magisk is already installed, see [INSTALL.md](INSTALL.md).

---

## Overview

This ZIP installs Magisk root from scratch using TWRP or OrangeFox recovery. It runs a fully guided workflow:

```
TWRP → Flash ZIP → Device profile → Boot image copy → Anti-rollback check
     → Magisk patch → Flash patched boot → Install module → Reboot → Rooted!
```

No computer required. Everything runs on-device.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Unlocked bootloader | Required to boot TWRP and flash custom images |
| TWRP ≥ 3.5 or OrangeFox | Must support the device |
| Android 9.0+ firmware installed | The recovery workflow targets the currently installed Android |
| ≥ 500 MB free on /sdcard | For image copies, logs, and data |

---

## Step 0 — Download the recovery ZIP

Obtain `hands-on-metal-recovery-<version>.zip` from the [releases page](https://github.com/mikethi/hands-on-metal/releases) or build it:

```bash
# On a Linux/macOS host with zip installed
bash build/build_offline_zip.sh
# Output: dist/hands-on-metal-recovery-<version>.zip
```

Transfer the ZIP to your device's internal storage or SD card.

---

## Step 1 — Boot into TWRP / OrangeFox

Reboot into recovery:

- Hold **Power + Volume Down** (most devices) until the recovery appears, **or**
- Run `adb reboot recovery` from a computer, **or**
- Select "Reboot → Recovery" from Magisk/advanced power menu if available.

---

## Step 2 — Flash the ZIP

1. In TWRP: tap **Install**.
2. Navigate to `hands-on-metal-recovery-<version>.zip`.
3. Swipe to confirm flash.

The guided installer starts immediately. You will see live progress:

```
╔══════════════════════════════════════════╗
║   hands-on-metal  Recovery Installer     ║
║   Guided Magisk Root Workflow            ║
╚══════════════════════════════════════════╝

Logs: /sdcard/hands-on-metal/logs/
```

---

## What the installer does (step by step)

### Step 1 — Environment Detection
```
STEP : Environment Detection
WHAT : Probes available shell tools, block device layout, and crypto state
WHY  : Without knowing what tools are available we cannot safely locate partitions
```
Records which tools are available (busybox, dd, sha256sum, etc.) and where the block device symlinks are.

### Step 2 — Device Profile
```
  Model      : Samsung Galaxy S23 (dm1q)
  Android    : 14  (API 34, first: 33)
  Patch level: 2025-11-01
  A/B updates: true  (current slot: _a)
  Boot part  : boot
  Dynamic pts: true
  Treble     : true  (VNDK 34)
  AVB        : v2.0  state=green
```
Identifies the exact boot partition to patch and checks AVB/Treble state.

### Step 3 — Boot Image Acquisition
```
  Auto-discovered: /dev/block/bootdevice/by-name/boot
  Copying boot → /sdcard/hands-on-metal/boot_work/boot_original.img
  SHA-256 (pre-patch): a3f2c9...
```
Copies the current boot image. **The partition is only read — never written at this step.**

If auto-discovery fails, the installer prints clear instructions:
```
ACTION REQUIRED:
  1) Common locations:
  2)   /dev/block/bootdevice/by-name/boot
  3)   /dev/block/by-name/boot
  4) Run: ls /dev/block/bootdevice/by-name/  to list all partitions
```

### Step 4 — Anti-Rollback Check
```
STEP : Anti-Rollback Check
WHAT : Compares device SPL and AVB rollback index against the boot image
WHY  : Prevents permanently bricking the device via AVB fuse-burning
```
- If image SPL ≥ device SPL: **safe to proceed**.
- If image SPL < device SPL: **install is blocked**. The installer explains what firmware to obtain.

### Step 5 — Magisk Patch
```
STEP : Magisk Patch
  Patch flags:
    KEEPVERITY=true
    KEEPFORCEENCRYPT=true
    PATCHVBMETAFLAG=false
    LEGACYSAR=false
  Patched image: /sdcard/hands-on-metal/boot_work/boot_patched.img
  SHA-256 (patched): 9d1e7b...
```
Uses the bundled (offline) Magisk binary to patch the image with the correct device-specific flags.

### Step 6 — Flash + Module Install
```
STEP : Flash + Module Install
  Target : /dev/block/bootdevice/by-name/boot_a
  Pre-flash SHA-256 (4MiB): f1c0...
  Flashing...
  Post-flash SHA-256 (4MiB): 9d1e7b...
  [ OK ] Flash Patched Boot — SHA-256 verified
  Installing hands-on-metal Magisk module...
```
Writes the patched image to the active boot slot and installs the Magisk module files. If the SHA-256 after flash doesn't match the expected value, the install is **aborted** (device stays bootable).

### Step 7 — Recovery Hardware Collection
The installer also collects hardware metadata, VINTF manifests, and fstab files while in recovery — this feeds the offline analysis pipeline later.

### Step 8 — Reboot
```
  Rebooting into system in 5 seconds...
  After reboot: open Magisk app to confirm root.
```

---

## Step 3 — After reboot

1. Open **Magisk** app → should show "Installed".
2. If Magisk app is not installed, download it from [github.com/topjohnwu/Magisk/releases](https://github.com/topjohnwu/Magisk/releases) and install the APK.
3. Verify root: open a terminal (Termux) and run `su`.
4. Review logs at `/sdcard/hands-on-metal/logs/`.

---

## Troubleshooting

| Symptom | What to do |
|---------|-----------|
| Nothing happens after flash | Logs are at `/sdcard/hands-on-metal/logs/` — check in TWRP file manager |
| "Boot partition not found" | See instructions printed on screen; use TWRP terminal to list `/dev/block/bootdevice/by-name/` |
| Anti-rollback check fails | Download newer firmware matching your SPL; extract boot.img |
| Flash verification fails | Do NOT reboot; use TWRP to flash the original stock boot image first |
| Device bootloops after reboot | Boot into TWRP → flash stock boot.img for your firmware |
| Magisk not showing root | Magisk needs its own APK installed — install it from the releases page |

### Recovering from a bad flash

If the device bootloops:

1. Boot back into TWRP.
2. Flash the **stock boot.img** for your exact firmware build (`adb sideload` or copy to /sdcard).
3. Reboot — device will be un-rooted but bootable.
4. Review logs at `/sdcard/hands-on-metal/logs/master_*.log` to understand what went wrong.

---

## Files created

| Path | Contents |
|------|----------|
| `/sdcard/hands-on-metal/boot_work/` | Original + patched boot images |
| `/sdcard/hands-on-metal/recovery_dump/` | Recovery hardware data |
| `/sdcard/hands-on-metal/logs/` | Full install logs with all variable values |
| `/sdcard/hands-on-metal/env_registry.sh` | Device profile registry |
| `/data/adb/modules/hands-on-metal-collector/` | Magisk module (active after root) |
