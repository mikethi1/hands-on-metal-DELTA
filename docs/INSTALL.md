# hands-on-metal — User Install Guide (Magisk Path)

> **Use this guide if Magisk is already installed on your device.**
> If you do not have Magisk, see [RECOVERY_INSTALL.md](RECOVERY_INSTALL.md).

---

## Prerequisites

| Requirement | How to check |
|-------------|-------------|
| Android 9.0+ (API 28+) | Settings → About phone → Android version |
| Magisk 25.0+ (versionCode ≥ 25000) | Open Magisk app → version shown on home screen |
| USB debugging (for adb, optional) | Settings → Developer options → USB debugging |
| ≥ 500 MB free on /sdcard | |

---

## Step 0 — Download the module ZIP

Obtain `hands-on-metal-magisk-module-<version>.zip` from the [releases page](https://github.com/mikethi/hands-on-metal/releases) or build it yourself:

```bash
bash build/build_offline_zip.sh
# Output: dist/hands-on-metal-magisk-module-<version>.zip
```

Copy the ZIP to your device's internal storage.

---

## Step 1 — Flash the module in Magisk

1. Open the **Magisk** app.
2. Tap **Modules** (bottom navigation).
3. Tap **Install from storage**.
4. Navigate to and select `hands-on-metal-magisk-module-<version>.zip`.
5. The guided wizard runs immediately.

### What you will see during install

```
╔══════════════════════════════════════════╗
║   hands-on-metal  Root Workflow          ║
╚══════════════════════════════════════════╝

STEP : Environment Detection
WHAT : Probes shell, Python, Termux, available tools, SELinux context, and key paths
WHY  : Ensures all prerequisites are present before running collection or patching scripts

[ OK ] Environment Detection

STEP : Device Profile
WHAT : Reads device properties, partition layout, AVB state, and Treble status
WHY  : The rest of the workflow depends on knowing the exact device model, API level...

  Model      : Google Pixel 8 (shiba)
  Android    : 14  (API 34, first: 33)
  Patch level: 2025-12-01
  A/B updates: true  (current slot: _b)
  Boot part  : init_boot
  Treble     : true  (VNDK 34)
  AVB        : v2.1  state=green

[ OK ] Device Profile — partition to patch: init_boot
```

### Boot image acquisition

The installer will try to auto-discover your boot partition.  
If it cannot find it automatically, it will ask:

```
ACTION REQUIRED — please follow these steps:
  1) The installer could not find the init_boot partition automatically.
  2) Common locations:
  3)   /dev/block/bootdevice/by-name/init_boot
  ...
Enter full path to init_boot block device or image file [/dev/block/bootdevice/by-name/init_boot]:
```

Press **Enter** to accept the default, or type the correct path.

### Anti-rollback check

```
STEP : Anti-Rollback Check
WHAT : Compares the device's stored security patch level and AVB rollback index
       against the boot image being patched
WHY  : Flashing an image with an older security patch level can permanently brick the device

  Device SPL : 2025-12-01
  Image SPL  : 2025-12-01
  May-2026 policy not yet active

[ OK ] Anti-Rollback Check
```

If the check **fails** (image SPL older than device), the installer will stop and explain what to do — it will **not** flash.

### Magisk patch and flash

The installer patches the image and flashes it automatically. The device reboots once flash is verified.

---

## Step 2 — After reboot

1. Open **Magisk** → home screen shows "Installed" with a version.
2. Check `/sdcard/hands-on-metal/` for hardware data.
3. Check `/sdcard/hands-on-metal/logs/` for full install logs.

---

## Where user input is required

The Magisk-path installer runs inside the Magisk app's module installer. It
is interactive — if a prompt appears, you type your response directly in the
Magisk output console.

| When | Where | What you do | Details |
|------|-------|-------------|---------|
| **Select ZIP** | Device: Magisk app | **Modules** → **Install from storage** → select the `.zip` | File picker opens |
| **Boot image prompt (if needed)** | Device: Magisk installer output | Type the path to your boot image + press Enter | Only appears if auto-discovery fails (see below) |
| **Google Pixel download prompt** | Device: Magisk installer output | Press Enter to accept `yes`, or type `no` | Only on Pixel devices when boot partition isn't found |
| **After reboot** | Device | Open Magisk app → confirm root; open Termux → run `su` | Verification step |

### Boot image prompt — what it looks like

If the installer can't find your boot partition automatically, you'll see:

```
ACTION REQUIRED — please follow these steps:
  1) The installer could not automatically obtain the boot image.
  ...
  5)   a) Place boot.img in /sdcard/Download/ and re-run
  6)   b) Extract it from a factory image ZIP on your PC and push:
  7)        adb push boot.img /sdcard/Download/
  8)   c) Enter a block device path if you know it:
  9)        /dev/block/bootdevice/by-name/boot
  ...

Enter full path to boot block device or image file [/sdcard/Download/boot.img]:
```

**Your input:** Type the full path (e.g., `/dev/block/by-name/boot`) and press
Enter, or just press Enter to use the default.

> **Tip:** To avoid this prompt, push the boot image before flashing:
> ```bash
> adb push boot.img /sdcard/Download/
> ```

### All other steps are automatic

Anti-rollback check, Magisk patch, flash, and SHA-256 verification all run
without prompts. They either succeed or abort with a clear error and safe
device state.

---

## Troubleshooting

| Symptom | Where to look |
|---------|--------------|
| Install fails silently | `/sdcard/hands-on-metal/logs/master_*.log` |
| Boot partition not found | Run `ls /dev/block/bootdevice/by-name/` in Termux/adb shell |
| Anti-rollback check fails | Obtain a newer firmware image; see note below |
| Magisk patch fails | Check `magisk_patch_*.log` in log directory |
| Device bootloops | Flash stock boot image from recovery |

### Anti-rollback: getting the right boot image

If your device's security patch level is higher than the boot image you're trying to patch:

1. Download the full OTA/firmware for your exact device and build matching or newer than your current SPL.
2. Extract the `boot.img` or `init_boot.img` from it.
3. Place the image at `/sdcard/hands-on-metal/boot_work/` and re-run the wizard.

---

## What gets installed

| Location | Contents |
|----------|----------|
| `/data/adb/modules/hands-on-metal-collector/` | Magisk module files |
| `/sdcard/hands-on-metal/live_dump/` | Hardware data (collected on first boot) |
| `/sdcard/hands-on-metal/boot_work/` | Original and patched boot images |
| `/sdcard/hands-on-metal/logs/` | Full install and run logs |
| `/sdcard/hands-on-metal/env_registry.sh` | Sourceable device profile |

---

## Uninstall

1. Magisk app → Modules → hands-on-metal-collector → Delete.
2. Reboot.
3. (Optional) Delete `/sdcard/hands-on-metal/` to remove collected data.
