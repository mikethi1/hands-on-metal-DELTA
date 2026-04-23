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
bash terminal_menu.sh
# Select option 1 (build/build_offline_zip.sh)
# After completion, press 's' for the suggested next step: option 3 (build/host_flash.sh)
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

The Magisk-path installer runs inside the Magisk app's module installer.
**Magisk runs as root (`uid=0`)**, so the installer has full access to block
devices. In most cases the install completes with no prompts at all — user
input is only a **fallback** when automatic detection fails.

### Your environment: root ✓, recovery ✗

Mode A always has root (Magisk provides it). This means:

| Capability | Status | Prereq ID¹ |
|-----------|:---:|---|
| Root access | ✓ Always available | `root` |
| Android device | ✓ Running on device | `android_device` |
| Magisk binary | ✓ Magisk is installed | `magisk_binary` |
| Recovery | ✗ Not booted into recovery | — |
| Boot image | Acquired automatically (via root DD) | `boot_image` |

¹ Prereq IDs match `terminal_menu.sh` → `get_prereqs_for_script()`.

### Boot image acquisition — automatic fallback chain

Because root is available, the first method (root DD) almost always succeeds.
The installer tries each method in order — user input is the **last resort**:

| # | Method | Prereqs | User input? |
|---|--------|---------|:-:|
| 1 | **Root DD** — copy live boot partition via `dd` | `root` `android_device` | None — automatic |
| 2 | **Pre-placed file** — scan `/sdcard/Download/`, `boot_work/` | `android_device` | None — automatic |
| 3 | **Factory download** — Google Pixel only | `android_device` network `cmd:curl` `cmd:unzip` | Fallback: confirmation |
| 4 | **Manual path** — ask for block device or file path | `android_device` (+ `root` for block devices) | Fallback: path prompt |

> **In Mode A, method 1 succeeds in the vast majority of cases.** You will
> only see fallback prompts if the block device can't be auto-discovered
> (unusual partition layout or missing by-name symlinks).

### Flash path: A (Magisk path)

Flash uses `run_flash_magisk_path()` in `core/flash.sh`:
- Prereqs: `root` + `boot_image` (both always satisfied in Mode A)
- DD writes patched image to boot partition
- SHA-256 verified post-flash
- Automatic reboot on success
- **No user input required**

### Required input (always needed)

| When | Where | What you do |
|------|-------|-------------|
| **Select ZIP** | Device: Magisk app | **Modules** → **Install from storage** → select the `.zip` |
| **After reboot** | Device | Open Magisk app → confirm root; open Termux → run `su` |

### Fallback input (only when automatic methods fail)

#### Fallback Prompt 1 — Google Pixel factory download (Pixel only)

**When:** Root DD failed + no pre-placed file + device is a Google Pixel.

```
Download factory image for shiba (build AP4A.250205.002)? [yes/no] [yes]:
```

**Your input:** Press **Enter** to accept `yes`, or type `no` + Enter to skip.

#### Fallback Prompt 2 — Manual boot image path (last resort)

**When:** All three automatic methods failed.

```
Enter full path to boot block device or image file [/sdcard/Download/boot.img]:
```

**Your input:** Type the path (e.g., `/dev/block/by-name/boot`) and press
Enter, or just press Enter to use the default.

> **Tip — avoid all fallback prompts:** Push the boot image to the device
> before flashing. Method 2 (pre-placed file) will find it automatically:
> ```bash
> adb push boot.img /sdcard/Download/
> ```

### What if I have no root and no recovery?

Mode A **requires Magisk to already be installed** — which means root is
always available. If you have neither root nor recovery, you cannot use
Mode A. See [ADB_FASTBOOT_INSTALL.md](ADB_FASTBOOT_INSTALL.md) for
Mode C (fastboot-based install without root or recovery).

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
