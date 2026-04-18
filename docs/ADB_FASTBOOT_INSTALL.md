# hands-on-metal — ADB Sideload & Fastboot Install Guide (Mode C)

> **Use this guide if the TARGET device has NO custom recovery (no TWRP /
> OrangeFox) and no root access.**
> If Magisk is already installed on the TARGET, see [INSTALL.md](INSTALL.md).
> If the TARGET has a custom recovery, see [RECOVERY_INSTALL.md](RECOVERY_INSTALL.md).

---

## Terminology

| Term | Meaning |
|------|---------|
| **HOST** | The machine running `host_flash.sh` — a PC (Linux/macOS/Windows) or another Android device (Termux via USB OTG or wireless ADB) |
| **TARGET** | The device being flashed — connected to HOST via USB, OTG cable, or wireless ADB |

All commands in this guide run **on HOST**. Actions that require
physical interaction with the TARGET device are clearly labeled
*"On TARGET:"*.

---

## Overview

This guide covers three scenarios for TARGET devices without a custom recovery:

| Scenario | What HOST needs | What TARGET needs | Section |
|----------|----------------|-------------------|---------|
| **C1 — Temporary TWRP boot** | `adb` + `fastboot` + TWRP .img | Unlocked bootloader | [C1](#c1--temporary-twrp-boot-via-fastboot) |
| **C2 — Direct fastboot flash** | `adb` + `fastboot` + pre-patched boot image | Unlocked bootloader | [C2](#c2--direct-fastboot-flash) |
| **C3 — ADB sideload** | `adb` + recovery ZIP | Custom recovery (TWRP/OrangeFox) | [C3](#c3--adb-sideload-with-custom-recovery) |

> **Important:** Stock Android recovery on TARGET does NOT accept unsigned
> ZIPs. ADB sideload only works with a custom recovery that supports
> unsigned ZIP flashing. If TARGET has no custom recovery, use C1 or C2.

---

## Prerequisites (all scenarios)

### On HOST (the machine running the script)

| Requirement | How to check |
|-------------|-------------|
| ADB + fastboot installed | `adb version` and `fastboot --version` |
| USB/OTG cable or wireless ADB | `adb devices` shows TARGET |

Install ADB and fastboot if you don't have them. `host_flash.sh`
auto-detects the HOST OS and shows the correct instructions, but here's
the quick reference:

```bash
# Linux (Debian/Ubuntu)
sudo apt-get install android-tools-adb android-tools-fastboot

# Linux (Fedora)
sudo dnf install android-tools

# Linux (Arch)
sudo pacman -S android-tools

# macOS (Homebrew)
brew install android-platform-tools

# Windows
# Download from https://developer.android.com/tools/releases/platform-tools
# Extract and add to PATH

# Termux (Android — flashing another device via OTG or wireless ADB)
pkg install android-tools
```

#### HOST-specific notes

| HOST OS | Notes |
|---------|-------|
| **Linux** | If `adb devices` shows "no permissions", add a udev rule or run: `sudo usermod -aG plugdev $USER` then log out and back in |
| **macOS** | Click "Allow" when macOS prompts about USB accessories. If tools not found after install, restart terminal |
| **Windows** | Install TARGET's USB driver (OEM or Google USB Driver). In PowerShell use `.\adb.exe` instead of `adb` |
| **Termux** | ADB requires wireless debugging (`adb pair` + `adb connect`) or USB OTG. Fastboot requires USB OTG — wireless does not support fastboot |

### On TARGET (the device being flashed)

| Requirement | How to check |
|-------------|-------------|
| Unlocked bootloader (C1, C2) | TARGET shows unlock warning at boot |
| USB debugging enabled | Settings → Developer options → USB debugging on TARGET |
| Wireless debugging (Termux HOST) | Settings → Developer options → Wireless debugging on TARGET |

### Multi-device support

When multiple devices are connected, `host_flash.sh` prompts you to
select the TARGET. You can also specify it directly:

```bash
# List connected devices
adb devices
fastboot devices

# Target a specific device by serial
bash build/host_flash.sh -s ABC123XYZ --c2 patched_boot.img
```

---

## Environment capability matrix

The installer adapts automatically based on what capabilities are available.
This matrix shows which boot image acquisition methods and flash paths work
for every combination of root access and recovery availability. These map
directly to the prerequisite IDs used by the terminal menu (`terminal_menu.sh`)
and dependency checker (`check_deps.sh`).

### Boot image acquisition methods

| # | Method | Prereqs¹ | Fallback input? | Notes |
|---|--------|---------|:-:|---|
| 1 | **Root DD** — live partition copy | `root` `android_device` | None | Automatic; fastest path |
| 2 | **Pre-placed file** — scan known paths | `android_device` | None | Place file at `/sdcard/Download/boot.img` before install |
| 3 | **Factory download** — Google Pixel only | `android_device` network `cmd:curl` `cmd:unzip` | Confirmation² | Non-interactive: auto-accepts `yes` |
| 4 | **User prompt** — manual path entry | `android_device` (+ `root` for block devices) | Path prompt² | Non-interactive: uses `/sdcard/Download/boot.img` |

¹ Prereq IDs match `terminal_menu.sh` → `get_prereqs_for_script()`  
² Only in interactive mode (stdin is a TTY). In TWRP/sideload, defaults are used silently.

### Flash paths

| Path | Prereqs¹ | Used by | Notes |
|------|---------|---------|-------|
| **A — Magisk path** (`run_flash_magisk_path`) | `root` `boot_image` | `customize.sh` (Mode A) | DD to boot partition + reboot |
| **B — Recovery path** (`run_flash_recovery_path`) | `root` `boot_image` | `update-binary` (Mode B) | DD to boot + install Magisk module + reboot |
| **C — Fastboot path** (host-side) | `cmd:adb` `cmd:fastboot` | This guide (Mode C) | `fastboot flash boot` from PC |

### Which methods work in your situation

| Your situation | Root? | Recovery? | Connection | Acquisition methods | Flash path | Install mode |
|---------------|:---:|:---:|---|---|---|---|
| **Magisk installed** | ✓ | ✗ | USB (pref) | 1→2→3→4 (all available) | A (Magisk) | [INSTALL.md](INSTALL.md) |
| **TWRP / OrangeFox** | ✓ | ✓ | USB (pref) | 1→2→3→4 (all available) | B (Recovery) | [RECOVERY_INSTALL.md](RECOVERY_INSTALL.md) |
| **Unlocked BL + PC (USB)** | ✗ | ✗ | USB | 2→3→4 (no root DD) | C (Fastboot) | This guide (C1 or C2) |
| **Unlocked BL + PC + temp TWRP** | ✓³ | ✓³ | USB | 1→2→3→4 (all via temp TWRP) | B (Recovery) | This guide (C1) |
| **No root, WiFi ADB only** ⁶ | ✗ | ✗ | WiFi | 2 (pre-place), dump | Dump only⁴ | `--wifi-setup` + `--dump` |
| **No root, WiFi → USB** ⁶ | ✗ | ✗ | WiFi → USB | 2→3→4 | C (Fastboot) | WiFi setup → `adb reboot bootloader` → USB flash |
| **Termux self-loopback** ⁶ | ✗ | ✗ | WiFi (self) | 2 (pre-place) | None⁵ | `--wifi-setup` self-loopback |
| **Locked bootloader** | ✗ | ✗ | Any | None | None | Unlock first |
| **No PC, no root, no recovery** | ✗ | ✗ | None | None | None | Not possible |

³ `fastboot boot twrp.img` gives you a temporary recovery with root.  
⁴ WiFi ADB cannot flash — use `--dump` to collect data, then connect USB for fastboot.  
⁵ Self-loopback cannot flash the same device — pre-place boot image, then connect to a PC.  
⁶ **Last resort** — WiFi ADB rows. Always prefer USB or OTG first.

> **Key insight:** Root access enables method 1 (root DD) and is required
> for flash paths A and B. Without root, you must pre-place the boot image
> (method 2) or use the fastboot flash path (C) from a PC.
>
> **WiFi ADB is always a last resort.** It is offered as an option
> (menu item 6) and as an interactive fallback when USB/OTG detection
> fails. Prefer USB cable or USB OTG for all operations.

## Where user input is required (fallback only)

The installer is designed to be **fully automatic**. User input is only
needed as a **fallback** when automatic detection fails. Most installs
complete with no prompts beyond the initial flash/sideload action.

### What runs automatically (no input needed)

The guided installer handles these steps without any user input:

| Step | What the installer does automatically |
|------|--------------------------------------|
| Environment detection | Probes shell tools, block devices, crypto state |
| Device profile | Reads model, API level, A/B slots, SAR, AVB, Treble |
| Boot image acquisition | Tries **four methods in order** before asking you (see below) |
| Anti-rollback check | Compares SPL and AVB rollback index — blocks or proceeds |
| Magisk patch | Applies correct flags (`KEEPVERITY`, `KEEPFORCEENCRYPT`, etc.) |
| Flash + verify | Writes patched image, verifies SHA-256, reboots |

### Boot image acquisition — automatic fallback chain

The installer tries each method in order and **stops at the first success**.
User input is the **last resort** — method 4 of 4:

```
Method 1: Root DD (automatic)
  └─ Has root + block device found? → DD copy from live partition
       └─ Success → done (no input needed)
       └─ Fail → try method 2

Method 2: Pre-placed file (automatic)
  └─ Image already at /sdcard/Download/boot.img or boot_work/?
       └─ Found → done (no input needed)
       └─ Not found → try method 3

Method 3: Google factory download (automatic on Pixel; confirmation in interactive mode)
  └─ Google Pixel + network + curl + unzip available?
       └─ Non-interactive (TWRP): downloads automatically (no input)
       └─ Interactive (terminal): asks confirmation (see Fallback Prompt 1)
       └─ Not a Pixel or no network → try method 4

Method 4: Manual user prompt (FALLBACK — only if methods 1–3 all failed)
  └─ Interactive: asks for block device or image path (see Fallback Prompt 2)
  └─ Non-interactive (TWRP): uses /sdcard/Download/boot.img as default
```

> **In most cases, method 1 or 2 succeeds and you see no prompts at all.**

### Bootloader unlock (one-time, before any install)

This is the only step that **always** requires user input — it's a one-time
setup, not part of the installer itself:

| Step | Where | What you do |
|------|-------|-------------|
| Enable Developer options | Device: Settings → About phone | Tap **Build number** 7 times |
| Enable OEM unlocking | Device: Developer options | Toggle **OEM unlocking** ON |
| Enable USB debugging | Device: Developer options | Toggle **USB debugging** ON |
| Authorize PC | Device: popup dialog | Tap **Allow** (check "Always allow from this computer") |
| Unlock command | PC terminal | `fastboot flashing unlock` (or `fastboot oem unlock` on older devices) |
| Confirm unlock | Device: bootloader screen | Press **Volume Up** to confirm (**this wipes all data**) |

### C1 — Temporary TWRP boot (required input)

These are the only manual steps — everything after flashing/sideloading the
ZIP is automatic:

| Step | Where | What you do | What you see |
|------|-------|-------------|-------------|
| Reboot to bootloader | PC terminal | `adb reboot bootloader` | Device shows "FASTBOOT" on screen |
| Boot TWRP | PC terminal | `fastboot boot twrp.img` | TWRP home screen loads |
| Start ADB sideload (option B) | Device: TWRP | Tap **Advanced** → **ADB Sideload** → **Swipe to start** | "Now send the package..." |
| Send ZIP (option B) | PC terminal | `adb sideload hands-on-metal-recovery-*.zip` | Progress percentage shown |
| OR push ZIP (option A) | PC terminal | `adb push hands-on-metal-recovery-*.zip /sdcard/` | Transfer completes |
| Flash ZIP (option A) | Device: TWRP | Tap **Install** → navigate to ZIP → **Swipe to confirm** | Installer output scrolls on screen |

After this, the installer runs automatically. You only see fallback prompts
if the boot image can't be found (see below).

### C2 — Direct fastboot flash (required input)

All steps are on the PC — no installer prompts:

| Step | Where | What you do | What you see |
|------|-------|-------------|-------------|
| Reboot to bootloader | PC terminal | `adb reboot bootloader` | "FASTBOOT" on device screen |
| Flash patched image | PC terminal | `fastboot flash boot patched_boot.img` | `OKAY` + transfer speed |
| Reboot | PC terminal | `fastboot reboot` | Device reboots to Android |

### C3 — ADB sideload (required input)

| Step | Where | What you do | What you see |
|------|-------|-------------|-------------|
| Boot into recovery | PC terminal | `adb reboot recovery` | TWRP/OrangeFox home screen |
| Start sideload mode | Device: TWRP | **Advanced** → **ADB Sideload** → **Swipe** | "Now send the package..." |
| Send ZIP | PC terminal | `adb sideload hands-on-metal-recovery-*.zip` | Progress bar/percentage |

After sideload completes, the installer runs automatically with no prompts
(TWRP sideload is non-interactive — all fallbacks use safe defaults).

### Fallback prompts (only when automatic acquisition fails)

These prompts **only appear in interactive mode** (ADB shell / Termux). In
TWRP flash or sideload, the installer uses defaults and never prompts.

#### Fallback Prompt 1 — Google Pixel factory download confirmation

**When:** Device is a Google Pixel, root DD failed, no pre-placed image found,
and you're running interactively.

```
  This looks like a Google Pixel device (shiba).
  A factory image can be downloaded to extract init_boot.img.
  Build ID: AP4A.250205.002

Download factory image for shiba (build AP4A.250205.002)? [yes/no] [yes]:
```

**Your input:** Press **Enter** to accept `yes`, or type `no` + Enter to skip.

**Non-interactive (TWRP):** Automatically uses `yes` — no prompt shown.

#### Fallback Prompt 2 — Manual boot partition path

**When:** All three automatic methods failed (no root DD, no pre-placed file,
no factory download) and you're running interactively. This is the **last
resort**.

```
ACTION REQUIRED — please follow these steps:
  1) The installer could not automatically obtain the boot image.
  2)
  3) You can provide the image in one of these ways:
  4)
  5)   a) Place boot.img in /sdcard/Download/ and re-run
  6)   b) Extract it from a factory image ZIP on your PC and push:
  7)        adb push boot.img /sdcard/Download/
  8)   c) Enter a block device path if you know it:
  9)        /dev/block/bootdevice/by-name/boot
  10)       /dev/block/by-name/boot
  11)       /dev/block/platform/<soc>/by-name/boot
  12)
  13) Run:  ls /dev/block/bootdevice/by-name/  to list partition names.

Enter full path to boot block device or image file [/sdcard/Download/boot.img]:
```

**Your input:** Type the full path to your boot image or block device, then
press **Enter**. Or press **Enter** to use the default path.

**Non-interactive (TWRP):** Automatically uses `/sdcard/Download/boot.img`.
If that file doesn't exist, the installer aborts with a clear error.

> **Tip — avoid all fallback prompts:** Push the boot image to the device
> before running the installer. The automatic pre-placed file scan (method 2)
> will find it and skip all prompts:
> ```bash
> adb push boot.img /sdcard/Download/
> ```

### No prompts after boot image acquisition

Once the boot image is acquired (by any method), the remaining steps —
anti-rollback check, Magisk patch, flash, SHA-256 verification, and reboot —
run **entirely without user input**. They either succeed or abort with a clear
error message, leaving the device in a safe, bootable state.

### After install — verification (all modes)

| Step | Where | What you do | What you see |
|------|-------|-------------|-------------|
| Open Magisk | Device: app drawer | Tap **Magisk** app | Home screen shows "Installed" with version |
| Verify root | Device: Termux or ADB shell | Run `su` | Prompt changes to `#` (root shell) |
| Check logs | Device or PC | Browse `/sdcard/hands-on-metal/logs/` | `master_*.log` with full install timeline |

### Mode A — Magisk module path (user input points)

If Magisk is already installed and you're using Mode A ([INSTALL.md](INSTALL.md)):

| Step | Where | What you do | What you see |
|------|-------|-------------|-------------|
| Open Magisk | Device | Tap **Magisk** app | Home screen |
| Go to Modules | Device | Tap **Modules** (bottom nav) | Module list |
| Install from storage | Device | Tap **Install from storage** | File picker opens |
| Select ZIP | Device | Navigate to and tap the `.zip` file | Installer runs with live output |
| Boot image prompt (if needed) | Device: installer output | Type path + Enter (see Prompt 2 above) | Only if auto-discovery fails |
| Reboot | Automatic | Installer reboots after flash | Device restarts |

---

## C1 — Temporary TWRP boot via fastboot

HOST boots TWRP **temporarily** (in RAM only) on TARGET without permanently
installing it. After reboot, TARGET's stock recovery returns. This is the
safest option for TARGET devices with no recovery.

### Using the guided script (recommended)

```bash
# On HOST — interactive:
bash build/host_flash.sh --c1

# On HOST — with TWRP image path:
bash build/host_flash.sh --c1 twrp-<device>.img

# On HOST — targeting a specific device:
bash build/host_flash.sh -s ABC123XYZ --c1 twrp-<device>.img
```

The script auto-detects HOST OS, finds TARGET, shows a confirmation
banner with TARGET model/serial, and guides you through sideloading.

### Manual steps

#### Step 1 — Download TWRP for TARGET

Find TARGET's TWRP image at [twrp.me](https://twrp.me/Devices/)
or your device's community forums. Download the `.img` file to HOST.

#### Step 2 — Boot TARGET into the bootloader

```bash
# On HOST — if TARGET is connected via ADB:
adb reboot bootloader

# On HOST (Termux) — if TARGET is on wireless ADB:
adb -s <target_ip>:<port> reboot bootloader
# Note: TARGET will disconnect from wireless. Reconnect via USB OTG for fastboot.
```

Or physically on TARGET: power off, then hold **Power + Volume Down**
(varies by device — see [device-specific key combos](#device-specific-bootloader-key-combinations)).

#### Step 3 — Temporarily boot TWRP on TARGET

```bash
# On HOST:
fastboot boot twrp-<device>-<version>.img

# On HOST — with specific serial:
fastboot -s ABC123XYZ boot twrp-<device>.img
```

> **Note:** Some TARGET devices (e.g., Samsung) do not support `fastboot boot`.
> For Samsung, use Odin or Heimdall on HOST to flash TWRP to the recovery partition.

#### Step 4 — Transfer and flash the hands-on-metal ZIP to TARGET

Once TWRP is running on TARGET, you have two options:

**Option A — Push from HOST and flash on TARGET:**

```bash
# On HOST:
adb push dist/hands-on-metal-recovery-v2.0.0.zip /sdcard/

# On TARGET: TWRP → Install → select the ZIP → swipe to confirm
```

**Option B — ADB sideload from HOST to TARGET:**

```bash
# On TARGET: TWRP → Advanced → ADB Sideload → swipe to start

# On HOST:
adb sideload dist/hands-on-metal-recovery-v2.0.0.zip
```

#### Step 5 — Reboot

The installer flashes the patched boot image on TARGET and reboots
automatically. After reboot, on TARGET, open the Magisk app to confirm root.

---

## C2 — Direct fastboot flash

HOST patches the boot image and flashes it directly to TARGET via fastboot.
No recovery needed on TARGET.

### Using the guided script (recommended)

```bash
# On HOST — interactive:
bash build/host_flash.sh --c2

# On HOST — with patched image:
bash build/host_flash.sh --c2 patched_boot.img

# On HOST — targeting a specific device:
bash build/host_flash.sh -s ABC123XYZ --c2 patched_boot.img
```

### Manual steps

#### Step 1 — Extract TARGET's current boot image (on HOST)

**Option A — From a factory image (on HOST):**

```bash
# On HOST — download TARGET device's factory image from the OEM
# Google: https://developers.google.com/android/images
# Extract boot.img (or init_boot.img for Android 13+)
unzip factory-image.zip '*/image-*.zip'
unzip image-*.zip boot.img init_boot.img
```

**Option B — Via ADB from TARGET (requires root on TARGET):**

```bash
# On HOST — find TARGET's boot partition:
adb shell ls /dev/block/bootdevice/by-name/ 2>/dev/null || \
    adb shell ls /dev/block/by-name/

# On HOST — copy boot image from TARGET (requires root shell on TARGET):
adb shell su -c "dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot_original.img"
adb pull /sdcard/boot_original.img
```

#### Step 2 — Patch with Magisk (on HOST or a helper device)

Install the Magisk app on an emulator or another device, or use the Magisk
CLI:

```bash
# On HOST — transfer boot.img to a device with Magisk installed:
adb push boot.img /sdcard/Download/

# On that helper device: Magisk app → Install → Select and Patch a File
# → select boot.img from Downloads
# → patched file saved to /sdcard/Download/magisk_patched-*.img

# On HOST — pull patched image back:
adb pull /sdcard/Download/magisk_patched-*.img patched_boot.img
```

#### Step 3 — Flash TARGET from HOST

```bash
# On HOST — reboot TARGET to bootloader:
adb reboot bootloader

# On HOST — verify TARGET is listed:
fastboot devices

# On HOST — flash the patched boot image to TARGET:
# For devices with boot partition:
fastboot flash boot patched_boot.img

# For Android 13+ devices with init_boot:
fastboot flash init_boot patched_init_boot.img

# On HOST — reboot TARGET:
fastboot reboot
```

#### Step 4 — Verify (on TARGET)

After reboot, on TARGET, install and open the Magisk app to confirm root.

---

## C3 — ADB sideload (with custom recovery)

> **This only works if TARGET has a custom recovery (TWRP / OrangeFox).**
> Stock recovery rejects unsigned ZIPs.

### Using the guided script (recommended)

```bash
# On HOST — interactive:
bash build/host_flash.sh --c3

# On HOST — with ZIP path:
bash build/host_flash.sh --c3 dist/hands-on-metal-recovery-v2.0.0.zip

# On HOST — targeting a specific device:
bash build/host_flash.sh -s ABC123XYZ --c3 recovery.zip
```

### Manual steps

#### Step 1 — Boot TARGET into recovery

```bash
# On HOST:
adb reboot recovery

# On HOST (Termux, wireless ADB):
adb -s <target_ip>:<port> reboot recovery
```

Or use the device-specific key combo on TARGET (see below).

#### Step 2 — Start ADB sideload mode on TARGET

On TARGET device (physical interaction):

1. Tap **Advanced** (TWRP) or **Tools** (OrangeFox)
2. Tap **ADB Sideload**
3. Swipe to start sideload mode

#### Step 3 — Sideload from HOST to TARGET

```bash
# On HOST:
adb sideload dist/hands-on-metal-recovery-v2.0.0.zip

# On HOST — with specific serial:
adb -s ABC123XYZ sideload dist/hands-on-metal-recovery-v2.0.0.zip
```

The guided installer runs on TARGET automatically — same as flashing the
ZIP directly from recovery storage.

#### Step 4 — Reboot

The installer reboots TARGET after flashing. On TARGET, open the Magisk
app to confirm root.

---

## Useful ADB commands reference

All commands below run **on HOST**. Replace `adb` with
`adb -s <serial>` when multiple devices are connected, or when running
from Termux with wireless debugging.

### Rebooting TARGET into different modes

```bash
# Reboot TARGET to recovery (custom or stock)
adb reboot recovery

# Reboot TARGET to bootloader / fastboot mode
adb reboot bootloader

# Reboot TARGET to system (normal boot)
adb reboot

# Reboot TARGET to download mode (Samsung only)
adb reboot download
```

### Diagnosing TARGET via ADB shell

```bash
# Check if TARGET is rooted
adb shell su -c "id"
# Expected: uid=0(root)

# List available partitions on TARGET
adb shell ls -la /dev/block/bootdevice/by-name/ 2>/dev/null || \
    adb shell ls -la /dev/block/by-name/

# Check TARGET's current boot slot (A/B devices)
adb shell getprop ro.boot.slot_suffix

# Check TARGET's Android version and API level
adb shell getprop ro.build.version.release
adb shell getprop ro.build.version.sdk

# Check TARGET's security patch level
adb shell getprop ro.build.version.security_patch

# Check TARGET's model and codename
adb shell getprop ro.product.model
adb shell getprop ro.product.device

# Check if TARGET has init_boot partition (Android 13+)
adb shell ls /dev/block/bootdevice/by-name/init_boot* 2>/dev/null || \
    adb shell ls /dev/block/by-name/init_boot* 2>/dev/null || \
    echo "No init_boot partition on TARGET — use boot instead"

# Check TARGET's bootloader lock state
adb shell getprop ro.boot.verifiedbootstate
adb shell getprop ro.boot.flash.locked
```

### Transferring files from HOST to TARGET

```bash
# Push the hands-on-metal ZIP from HOST to TARGET
adb push dist/hands-on-metal-recovery-v2.0.0.zip /sdcard/

# Push a boot image from HOST to TARGET
adb push boot.img /sdcard/Download/

# Pull logs from TARGET to HOST after install
adb pull /sdcard/hands-on-metal/logs/ ./hom-logs/

# Pull hardware data from TARGET to HOST
adb pull /sdcard/hands-on-metal/live_dump/ ./hom-dump/
```

### Emergency recovery commands (run on HOST)

```bash
# If TARGET is bootlooping — get TARGET to fastboot
# On TARGET: power off (hold power 10+ seconds), then hold Power + Volume Down

# On HOST — flash stock boot image to TARGET to recover:
fastboot flash boot stock_boot.img
fastboot reboot

# On HOST — if TARGET is in fastboot and you have a TWRP image:
fastboot boot twrp.img
# Then from TWRP on TARGET, flash stock firmware or restore backup
```

---

## Device-to-device flashing (Termux HOST → TARGET)

When HOST is an Android device running Termux and TARGET is another
Android device:

| Priority | Connection | ADB? | Fastboot? | Notes |
|:---:|-----------|:---:|:---:|---|
| 1st | **USB OTG cable** | ✓ | ✓ | Physical cable from HOST's USB-C/micro to TARGET. **Always preferred.** |
| 2nd | **Wireless debugging** | ✓ | ✗ | Last resort. TARGET must have Android 11+. No fastboot. |

### USB OTG setup (Termux → TARGET) — preferred

```bash
# On HOST (Termux):
pkg install android-tools

# On TARGET: enable USB debugging
#   Settings → About phone → tap 'Build number' 7 times
#   Settings → Developer options → USB debugging → ON

# Connect TARGET via USB OTG cable
# TARGET will prompt "Allow USB debugging?" — tap Allow

# Verify:
adb devices

# Fastboot also works via OTG:
adb reboot bootloader
fastboot devices
```

### Wireless ADB setup (Termux → TARGET) — last resort

> **Only use this if USB OTG is not available.**
> No fastboot support. Slower transfers. Requires Android 11+ on TARGET.

```bash
# On TARGET: Settings → Developer options → Wireless debugging → enable
# On TARGET: tap "Pair device with pairing code" → note the ip:port and code

# On HOST (Termux):
pkg install android-tools

# Pair with TARGET (one-time):
adb pair 192.168.1.100:37123
# Enter pairing code when prompted

# Connect to TARGET:
adb connect 192.168.1.100:42456

# Verify TARGET is connected:
adb devices
# Should show: 192.168.1.100:42456   device

# Now run any Mode C command:
bash build/host_flash.sh --c3 recovery.zip
```

> **Limitation:** Wireless ADB does not support fastboot. If you need
> C1 or C2, you must use a USB OTG cable.

---

## WiFi ADB for non-rooted TARGET devices

> **WiFi ADB is a last resort.** Always prefer USB cable (PC → TARGET)
> or USB OTG (Termux → TARGET) — both are faster and support all modes
> including fastboot. Use WiFi ADB only when USB/OTG is unavailable.

Android 11+ includes **Wireless Debugging** — a built-in feature that
enables ADB over WiFi **without root**. Use it as a fallback when:

- No USB cable or OTG adapter is available
- USB port is damaged or occupied
- TARGET is physically distant from HOST
- You need to pre-place files or run diagnostics before a USB session

The script offers WiFi setup **as an option** (menu item 6) and
**as an interactive fallback** when USB/OTG device detection fails.

### Connection priority (always try in this order)

| Priority | Connection | ADB | Fastboot | Speed | When to use |
|:---:|-----------|:---:|:---:|---|---|
| 1st | **USB cable** (PC → TARGET) | ✓ | ✓ | Fast | Always preferred |
| 2nd | **USB OTG** (Termux → TARGET) | ✓ | ✓ | Fast | Device-to-device |
| 3rd | **WiFi ADB** (any HOST → TARGET) | ✓ | ✗ | Slow | Last resort only |

### What works over WiFi ADB without root

| Action | WiFi ADB (no root) | Notes |
|--------|:--:|---|
| Push files to TARGET | ✓ | `adb push boot.img /sdcard/Download/` |
| Pull files from TARGET | ✓ | `adb pull /sdcard/ ./backup/` |
| Read device properties | ✓ | `adb shell getprop ro.product.model` |
| List partition names (symlinks) | ✓ | `adb shell ls /dev/block/by-name/` — **names only, not data** |
| Read /proc/partitions (sizes) | ✓ | Block device sizes in sectors — no partition names |
| Read /proc (cpuinfo, version) | ✓ | Most /proc files are world-readable |
| Read VINTF manifests | ✓ | `/vendor/etc/vintf/manifest.xml` etc. |
| Run `dumpsys` services | ✓ | display, SurfaceFlinger, battery, etc. |
| Reboot to recovery/bootloader | ✓ | `adb reboot recovery` / `adb reboot bootloader` |
| **Read partition DATA** (dd) | ✗ | SELinux blocks `/dev/block/*` reads for UID 2000 |
| **Flash boot partition** | ✗ | Requires root DD or fastboot |
| **Fastboot commands** | ✗ | Fastboot protocol not supported over WiFi |
| **ADB sideload in TWRP** | ✓¹ | After `adb reboot recovery`, reconnect via USB |

> **Important:** `/dev/block/by-name/` contains **symlinks only** — you can
> see partition names (boot, dtbo, vbmeta, etc.) and which block device node
> they map to (e.g., `boot → /dev/block/sda18`), but you **cannot read the
> actual partition data** without root. SELinux policy
> (`u:object_r:block_device:s0`) blocks reads from the `shell` user (UID
> 2000). This applies to both USB ADB and WiFi ADB — the permission model
> is identical.

¹ After rebooting TARGET to recovery, the WiFi ADB connection drops.
You must reconnect via USB cable for sideload, or re-pair in recovery
if TWRP supports wireless ADB.

### Guided WiFi setup via `host_flash.sh`

```bash
# On HOST — interactive WiFi ADB pairing and connection:
bash build/host_flash.sh --wifi-setup

# Supports:
# - PC → non-rooted TARGET over WiFi
# - Termux → non-rooted TARGET over WiFi
# - Termux self-loopback (same device connects to its own wireless debugging)
```

The script guides you through:
1. Enabling wireless debugging on TARGET
2. Pairing (one-time) with the 6-digit code
3. Connecting to TARGET's debugging port
4. Verifying the connection

### Self-loopback (Termux on same non-rooted device)

This connects Termux ADB to its own device's wireless debugging port.
No root needed. Useful for:

- Pre-placing a boot image (`adb push boot.img /sdcard/Download/`)
  so the installer's fallback method 2 can find it
- Running diagnostics before connecting to a PC
- Rebooting to bootloader (`adb reboot bootloader`) then connecting USB

```bash
# On device (Termux):
bash build/host_flash.sh --wifi-setup
# Choose option 1 (self-loopback)
# Follow prompts to pair and connect

# After connecting:
adb push boot.img /sdcard/Download/    # pre-place for installer
adb reboot bootloader                  # then connect USB for fastboot
```

> **Self-loopback limitations:** You cannot flash the device you're
> running on via ADB/fastboot — the device can't reboot to
> fastboot and maintain the connection. For flashing, use a PC
> (Mode C1/C2) or Magisk app (Mode A).

---

## Elevated ADB access without root (Shizuku / LADB)

**Shizuku** and **LADB** provide ADB shell-level (UID 2000) permissions
on TARGET **without root**. This is higher than normal app permissions
but lower than root (UID 0).

### How it works

These tools use Android 11+'s **Wireless Debugging** to start an
ADB-privilege process on-device:

| Tool | What it does | Install |
|------|-------------|---------|
| **[Shizuku](https://shizuku.rikka.app/)** | Runs a background service that grants ADB shell-level access to compatible apps via its API | [Google Play](https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api) / [GitHub](https://github.com/RikkaApps/Shizuku/releases) |
| **[LADB](https://github.com/tytydraco/LADB)** | On-device ADB shell terminal — gives a command line with `shell` user privileges | [Google Play](https://play.google.com/store/apps/details?id=com.draco.ladb) / [GitHub](https://github.com/tytydraco/LADB/releases) |

### What elevated access enables vs. root vs. standard

| Capability | Standard ADB | Elevated (Shizuku/LADB) | Root (UID 0) |
|-----------|:---:|:---:|:---:|
| Read device properties (`getprop`) | ✓ | ✓ | ✓ |
| Push/pull files to `/sdcard/` | ✓ | ✓ | ✓ |
| List partition names (by-name symlinks) | ✓ | ✓ | ✓ |
| Read `/proc/partitions` (block sizes) | ✓ | ✓ | ✓ |
| Read `/proc/cpuinfo`, `/proc/meminfo` | ✓ | ✓ | ✓ |
| Read `/proc/iomem` (full detail) | Partial | ✓ | ✓ |
| Read `/proc/interrupts` (full detail) | Partial | ✓ | ✓ |
| Full logcat (no PID filter) | ✗ | ✓ | ✓ |
| Read `Settings.Secure`, `Settings.Global` | ✗ | ✓ | ✓ |
| Run `pm` / `am` / `cmd` commands | ✗ | ✓ | ✓ |
| Read more vendor/system files | Partial | ✓ | ✓ |
| **Read partition DATA** (dd /dev/block/*) | ✗ | ✗ | ✓ |
| **Flash boot images** | ✗ | ✗ | ✓ (or fastboot) |
| **Modify `/system`** | ✗ | ✗ | ✓ |

> **Note on /dev/block/ access:** Both standard ADB and Shizuku/LADB run
> as UID 2000 (`shell`). SELinux blocks all reads from `/dev/block/*` device
> nodes for this UID. You can list partition **names** via the by-name
> symlinks, but you **cannot read the actual partition data**. Only root
> (UID 0) can `dd` block devices to extract boot images.

### Setup via `host_flash.sh`

```bash
# Interactive Shizuku/LADB setup and detection:
bash build/host_flash.sh --elevated-setup

# The dump command auto-detects elevated access:
bash build/host_flash.sh --dump
# → Uses elevated access for better /proc, /sys, logcat collection
```

### Setting up Shizuku (step by step)

1. **Enable Developer Options** on TARGET:
   Settings → About phone → tap "Build number" 7 times
2. **Enable Wireless Debugging** on TARGET:
   Settings → Developer options → Wireless debugging → ON
3. **Install Shizuku** on TARGET (Google Play or GitHub)
4. **Start Shizuku**:
   Open Shizuku app → "Start via Wireless debugging" → follow pairing
5. **Verify**: `host_flash.sh --elevated-setup` will detect it automatically

### Setting up LADB (step by step)

1. **Enable Developer Options** and **Wireless Debugging** (same as above)
2. **Install LADB** on TARGET (Google Play or GitHub)
3. **Open LADB** → pair when prompted
4. You now have an on-device ADB shell with elevated privileges
5. Commands like `cat /proc/iomem` now return full output

---

## Diagnostic dump from TARGET (with or without root)

`host_flash.sh --dump` collects diagnostic and partition data from TARGET.
It adapts to what's available — collecting more data when root is present.

```bash
# On HOST — dump to default directory:
bash build/host_flash.sh --dump

# On HOST — dump to specific directory:
bash build/host_flash.sh --dump ./my-device-dump/

# On HOST — with WiFi ADB:
bash build/host_flash.sh -s 192.168.1.100:42456 --dump
```

### What the dump collects

| Data | Standard ADB | Elevated (Shizuku) | Root | Pipeline use |
|------|:---:|:---:|:---:|---|
| Device properties (`getprop`) | ✓ | ✓ | ✓ | `parse_manifests.py` — board summary |
| Partition names (by-name symlinks) | ✓ | ✓ | ✓ | `failure_analysis.py` — partition check |
| `/proc/partitions` (block sizes) | ✓ | ✓ | ✓ | Partition size analysis |
| `/proc/mounts` (mounted partitions) | ✓ | ✓ | ✓ | Filesystem type, encryption flags |
| `/proc/cpuinfo`, `/proc/meminfo` | ✓ | ✓ | ✓ | `build_table.py` — hardware catalog |
| `/proc/iomem` | Partial | ✓ | ✓ (full) | `build_table.py` — MMIO address map |
| `/proc/interrupts` | Partial | ✓ | ✓ | `build_table.py` — IRQ assignments |
| Device tree (`/proc/device-tree`) | ✓ | ✓ | ✓ | `build_table.py` — SoC peripheral map |
| Loaded kernel modules | ✓ | ✓ | ✓ | `build_table.py` — driver inventory |
| VINTF manifests (vendor/system) | ✓ | ✓ | ✓ | `parse_manifests.py` — HAL catalog |
| `dumpsys` (display, audio, camera) | ✓ | ✓ | ✓ | Manual analysis |
| Logcat (full, no PID filter) | ✗ | ✓ | ✓ | Debugging, issue reports |
| Build/security info summary | ✓ | ✓ | ✓ | `failure_analysis.py` — version check |
| **Boot/init_boot partition DATA** | ✗ | ✗ | ✓ | `unpack_images.py` — kernel, ramdisk, fstab |
| **dtbo partition DATA** | ✗ | ✗ | ✓ | `unpack_images.py` — device tree overlays |
| **vbmeta partition DATA** | ✗ | ✗ | ✓ | Anti-rollback index, AVB chain analysis |
| **SELinux policy binary** | ✗ | ✗ | ✓ | Policy analysis, device-specific contexts |

> **Partition names vs. partition DATA:** Without root, the dump collects
> partition **names** (symlinks in `/dev/block/by-name/` — e.g., `boot →
> sda18`) and **sizes** (from `/proc/partitions`). The actual partition
> **data** (the raw bytes — kernel, ramdisk, vbmeta hash trees) can only
> be read with root via `dd`. SELinux blocks all `/dev/block/*` reads
> for UID 2000 (both standard ADB and Shizuku/LADB).

### What you can do with partition dumps

**1. Pre-flash analysis** — understand TARGET before committing to flash:

```bash
# Run failure analysis against the dump
python pipeline/failure_analysis.py --dump ./hom-dump/ \
    --index build/partition_index.json
```

Checks anti-rollback, partition compatibility, known device issues,
and boot image format (v0–v4) before you flash anything.

**2. Boot image extraction → patch → fastboot flash (C2)**:

With root, the dump extracts `boot.img` (or `init_boot.img`). This
image can be transferred to another device's Magisk app for patching,
then flashed back via fastboot:

```bash
# 1. Dump includes boot.img
ls ./hom-dump/boot_images/

# 2. Transfer to a device with Magisk for patching
adb push ./hom-dump/boot_images/boot.img /sdcard/Download/
# On that device: Magisk → Patch a File → select boot.img
adb pull /sdcard/Download/magisk_patched-*.img ./patched_boot.img

# 3. Flash back to TARGET
bash build/host_flash.sh --c2 ./patched_boot.img
```

**3. Hardware catalog** — build a full SQLite hardware database:

```bash
python pipeline/build_table.py --dump ./hom-dump/ --mode C
# Creates hardware_map.sqlite with:
#   - iomem address ranges → peripheral names
#   - IRQ assignments → driver names
#   - Device tree nodes → SoC components
#   - VINTF HAL interfaces → hardware features
#   - Kernel modules → driver inventory
```

**4. Ramdisk extraction** — inspect init configuration:

```bash
python pipeline/unpack_images.py --dump ./hom-dump/ --run-id 1
# Extracts from boot.img:
#   - fstab.*     → partition encryption flags, filesystem types
#   - init.rc     → service definitions, early boot actions
#   - default.prop → build properties embedded in ramdisk
```

**5. Cross-device comparison** — compare partition layouts, HALs,
and hardware across different devices or after OTA updates by
running dumps before and after.

---

## Device-specific bootloader key combinations

These are physical actions **on TARGET**:

| TARGET device family | Bootloader (fastboot) | Recovery |
|---------------------|----------------------|----------|
| Google Pixel | Power + Vol Down | Power + Vol Down → select "Recovery" |
| Samsung | Power + Vol Down + Bixby/Home | Power + Vol Up + Bixby/Home |
| OnePlus | Power + Vol Up + Vol Down | Power + Vol Down → select "Recovery" |
| Xiaomi / POCO / Redmi | Power + Vol Down | Power + Vol Up |
| Motorola | Power + Vol Down | Power + Vol Down → select "Recovery" |
| ASUS | Power + Vol Down | Power + Vol Up |
| LG | Power + Vol Down (hold until logo appears twice) | Power + Vol Down + Vol Up |
| Sony | Power + Vol Down (with USB connected to HOST) | Power + Vol Down → select "Recovery" |

> After entering fastboot mode, TARGET's screen shows "FASTBOOT" or
> "Fastboot Mode". On HOST, run `fastboot devices` to verify the connection.

---

## Can I use ADB sideload without any recovery?

**No.** ADB sideload requires a recovery environment on TARGET (stock or
custom) that implements the sideload protocol. Without any recovery on TARGET:

- Use **C1** (temporary TWRP boot via `fastboot boot` from HOST) if TARGET supports it.
- Use **C2** (direct fastboot flash from HOST) to patch and flash the boot image.

Stock Android recovery supports `adb sideload` but **only for OEM-signed OTA
packages**. The hands-on-metal recovery ZIP is not OEM-signed, so stock
recovery will reject it. You need TWRP / OrangeFox on TARGET for sideloading
unsigned ZIPs.

---

## Does Magisk patch the boot image live? Integrity & anti-rollback

### Live patching (Mode A — Magisk already installed)

**Yes, Magisk patches the boot image while Android is running.** The workflow:

1. `boot_image.sh` copies the active boot/init_boot partition via `dd` →
   `/sdcard/hands-on-metal/boot_work/boot_original.img` (read-only, no writes).
2. `magisk_patch.sh` copies that image to `/data/local/tmp` and runs
   `magisk --boot-patch` to inject the Magisk root payload.
3. `flash.sh` writes the patched image back to the boot partition via `dd`
   and verifies the SHA-256 checksum after writing.

The original unpatched image is kept at `boot_work/boot_original.img` as a
backup. If the post-flash checksum doesn't match, the installer **refuses
to reboot** so you can restore the original.

### Will this mess up integrity (verified boot / AVB)?

**Magisk is designed to coexist with AVB, but verified boot state changes:**

| Aspect | What happens | Risk |
|--------|-------------|------|
| **AVB verified boot state** | Changes from `green` → `yellow` or `orange` | Low — device still boots; warning screen shown once |
| **dm-verity (system partition)** | **Preserved** — `KEEPVERITY=true` on A/B devices | None — system partition stays verified |
| **Encryption (/data)** | **Preserved** — `KEEPFORCEENCRYPT=true` always set | None — data stays encrypted |
| **Play Integrity / SafetyNet** | May fail hardware attestation (detects modified boot) | Medium — some apps (banking, DRM) may not work |
| **vbmeta flags** | Patched by `PATCHVBMETAFLAG=true` when May-2026 policy is active | None — required for devices with SPL ≥ 2026-05-07 |
| **Boot image header SPL** | Preserved by Magisk ≥ 30.7 | None — no SPL downgrade occurs |

**Key safety flags set by `magisk_patch.sh`:**

```
KEEPVERITY=true          # A/B devices: don't strip dm-verity
KEEPFORCEENCRYPT=true    # Always: preserve /data encryption
PATCHVBMETAFLAG=true     # May-2026 policy: patch vbmeta flag in header
LEGACYSAR=true           # Only on legacy System-as-Root devices
```

### Will this mess up anti-rollback?

**No — the installer actively prevents anti-rollback violations:**

1. `anti_rollback.sh` reads the device's current SPL and the boot image's
   embedded SPL.
2. If the image SPL is **older** than the device SPL → **install is blocked**.
   You cannot accidentally flash a downgrade that burns fuses.
3. For devices with SPL ≥ 2026-05-07 (May-2026 policy), Magisk must be ≥ v30.7.
   Older Magisk versions are rejected because they don't handle
   `PATCHVBMETAFLAG` correctly.
4. The AVB rollback index stored in RPMB/fuses is checked when readable.
5. `flash.sh` re-verifies the anti-rollback flags one final time before the
   irreversible `dd` write.

**What can still go wrong:**

| Scenario | Protection | What to do |
|----------|-----------|------------|
| Image SPL < device SPL | Blocked by `anti_rollback.sh` | Get a boot image matching your current firmware |
| Magisk too old for May-2026 | Blocked at two checkpoints | Upgrade to Magisk ≥ 30.7 |
| Wrong partition (boot vs init_boot) | Auto-detected by `device_profile.sh` | Verify `HOM_DEV_BOOT_PART` in logs |
| Power loss during flash | Post-flash SHA-256 mismatch detected | Restore `boot_original.img` from recovery or fastboot |
| A/B slot mismatch | Slot suffix auto-detected | Check `HOM_DEV_SLOT_SUFFIX` if issues occur |

### Restoring if something goes wrong

If the device bootloops after a live patch:

```bash
# Option 1: fastboot (no recovery needed)
# Power off → hold Power + Vol Down → enter fastboot
fastboot flash boot /path/to/boot_original.img
fastboot reboot

# Option 2: ADB from recovery (if accessible)
adb reboot recovery
# In TWRP terminal:
dd if=/sdcard/hands-on-metal/boot_work/boot_original.img \
   of=/dev/block/bootdevice/by-name/boot bs=4096
reboot
```

---

## Boot image sources and GKI generic boot images

### Where does the boot image come from?

`core/boot_image.sh` acquires the boot/init_boot image using a priority
chain. Each step is tried only if the previous one did not succeed:

| Priority | Method | Needs root? | Notes |
|----------|--------|:-----------:|-------|
| 1 | **Root DD** — copy from live block device | ✅ | Fastest, always matches running firmware |
| 2 | **Pre-placed / backup scan** | ❌ | Scans boot_work, /sdcard/Download, Magisk stock backup, TWRP / OrangeFox / PBRP / SHRP / RedWolf / CWM / Nandroid backup folders |
| 3 | **Google factory download** (Pixels) | ❌ | Requires `curl` + `unzip` and network. Auto-detects codename + build ID |
| 4 | **GKI generic boot image** (Android 12+) | ❌ | For ANY GKI-compatible device. Downloads from ci.android.com |
| 5 | **OEM-specific guidance** | ❌ | Shows Samsung / Xiaomi / OnePlus / Motorola / ASUS / Sony download links |
| 6 | **User prompt** | ❌ | Final fallback — enter a path or block device manually |

**The `boot_image` prerequisite in the menu shows as "ready" when any
of these sources are available** (root detected, backup found, or Android
12+ GKI device).

### Magisk GitHub repo — does it host factory images?

**No.** The Magisk repository ([topjohnwu/Magisk](https://github.com/topjohnwu/Magisk))
only contains the Magisk app and rooting tools. It does **not** host OEM
factory boot images.

However, **Magisk saves the original stock boot image** whenever it
patches. This backup is stored at:

```
/data/adb/magisk/stock_boot.img
/data/adb/magisk/stock_boot_<partition>.img
```

The scanner checks this location automatically. This stock backup is
the best source for re-patching or recovering root if live patching
fails (see [Fallback root recovery](#fallback-root-recovery-using-backup-images) below).

### GKI generic boot images (Android 12+ / API 31+)

Starting with Android 12, most devices use the
[Generic Kernel Image (GKI)](https://source.android.com/docs/core/architecture/partitions/generic-boot)
format. The boot image is standardized — Google publishes prebuilt
generic boot images for every GKI kernel version.

**This means you can download a matching generic boot image for ANY
GKI-compatible device, not just Pixels.**

| Android version | API | GKI kernel | ci.android.com branch | init_boot? |
|----------------|:---:|:----------:|----------------------|:-----------:|
| Android 12     | 31  | 5.10       | `aosp_kernel-common-android12-5.10` | ❌ boot only |
| Android 13     | 33  | 5.10 / 5.15 | `aosp_kernel-common-android13-5.10` or `...-5.15` | ✅ init_boot introduced |
| Android 14     | 34  | 5.15 / 6.1 | `aosp_kernel-common-android14-5.15` or `...-6.1` | ✅ |
| Android 15     | 35  | 6.1 / 6.6 | `aosp_kernel-common-android15-6.6` | ✅ |
| Android 16     | 36  | 6.6 / 6.12 | `aosp_kernel-common-android16-6.12` | ✅ |

**How to download:**

1. Check your kernel version: `uname -r` → e.g. `6.1.43`
2. Open `https://ci.android.com/builds/branches/<branch>/grid`
3. Click the latest green build → **Artifacts** tab
4. Download `boot.img` (or `init_boot.img` for Android 13+)
5. Push to device: `adb push boot.img /sdcard/Download/`
6. Re-run the installer

For automated download, use the AOSP `download_from_ci` script:
`https://android.googlesource.com/kernel/build/+/refs/heads/main/gki/download_from_ci`

> **Note:** `boot_image.sh` auto-detects GKI compatibility by checking
> `ro.build.version.sdk >= 31` and matching the kernel version to the
> correct AOSP branch.

### OEM-specific firmware sources

For non-Google, non-GKI devices, the boot image must come from the
OEM's firmware package:

| OEM | Source | Extraction |
|-----|--------|------------|
| Samsung | [SamFw](https://samfw.com/), [SamMobile](https://www.sammobile.com/firmware/), Frija (PC tool) | `AP_*.tar.md5` → `boot.img.lz4` → `lz4 -d boot.img.lz4 boot.img` |
| Xiaomi / Redmi / POCO | [XiaomiFirmwareUpdater](https://xiaomifirmwareupdater.com/), [MIUI Downloads](https://new.c.mi.com/global/miuidownload/) | `payload.bin` → `payload-dumper-go -p boot payload.bin` |
| OnePlus / OPPO / Realme | [OnePlus service](https://service.oneplus.com/), OxygenUpdater app | `payload.bin` → `payload-dumper-go -p boot payload.bin` |
| Motorola | [Lolinet mirrors](https://mirrors.lolinet.com/firmware/moto/) | ZIP contains `boot.img` directly |
| ASUS | [ASUS support](https://www.asus.com/support/) | `payload.bin` → `payload-dumper-go -p boot payload.bin` |
| Sony | XperiFirm (XDA), Newflasher | `.sin` → flashtool → `boot.img` |

**Generic payload.bin extraction** (works for most modern OEMs):

```bash
pip install payload-dumper-go   # or download from GitHub
payload-dumper-go -p boot -o . payload.bin
```

---

## Fallback root recovery using backup images

If live Magisk patching fails (bootloop, checksum mismatch, or patch
error), you can use a backup boot image to **recover root access**
without needing to start from scratch.

### Sources for stock boot images (for recovery)

| Source | Location | Root needed? |
|--------|----------|:------------:|
| Magisk stock backup | `/data/adb/magisk/stock_boot.img` | ✅ to read |
| TWRP Nandroid backup | `/sdcard/TWRP/BACKUPS/<serial>/<date>/boot.emmc.win` | ❌ |
| OrangeFox backup | `/sdcard/Fox/BACKUPS/<serial>/<date>/boot.emmc.win` | ❌ |
| PBRP / SHRP / RedWolf | `/sdcard/<recovery>/BACKUPS/…/boot.emmc.win` | ❌ |
| CWM / Nandroid | `/sdcard/clockworkmod/backup/<date>/boot.img` | ❌ |
| GKI generic image | ci.android.com (Android 12+) | ❌ |
| OEM factory download | See [OEM sources](#oem-specific-firmware-sources) above | ❌ |

> **TWRP `.emmc.win` files** are raw partition dumps — identical to
> `.img` files. Compressed backups (`.win.gz`, `.win.lz4`) are
> automatically decompressed by `boot_image.sh`.

### Recovery workflow

```
  Stock boot.img (from backup)
       │
       ▼
  Magisk app → Install → Patch a File → select boot.img
       │
       ▼
  magisk_patched-XXXXX.img (on device or transferred to HOST)
       │
       ▼
  fastboot flash boot magisk_patched-XXXXX.img   (Mode C2)
       │
       ▼
  Root restored ✓
```

**Step-by-step:**

```bash
# 1. Get the stock boot image from any backup source above
#    (boot_image.sh scans all these locations automatically)

# 2. Transfer to a device with Magisk app installed
adb push boot.img /sdcard/Download/

# 3. On that device: Magisk → Install → Patch a File → select boot.img
#    Magisk creates: /sdcard/Download/magisk_patched-XXXXX.img

# 4. Pull the patched image back to HOST
adb pull /sdcard/Download/magisk_patched-*.img .

# 5. Flash via fastboot (Mode C2)
adb reboot bootloader
fastboot flash boot magisk_patched-XXXXX.img
fastboot reboot
```

This workflow also works with GKI generic boot images — patch the
generic image with Magisk, then flash it to the device.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `fastboot boot` not supported | Device doesn't support booting unsigned images. Use `fastboot flash recovery twrp.img` to permanently install TWRP, or use C2 |
| `adb sideload` says "signature verification failed" | You're in stock recovery — switch to TWRP/OrangeFox, or use C1/C2 |
| `fastboot devices` shows nothing | Check USB cable, install drivers (Windows), or try a different port |
| `adb reboot bootloader` doesn't work | Phone may not have USB debugging enabled. Use hardware key combo instead |
| "FAILED (remote: 'Flashing is not allowed')" | Bootloader is locked. Unlock first (see [INSTALL_HUB.md](INSTALL_HUB.md)) |
| Device stuck in fastboot | `fastboot reboot` or hold Power for 15 seconds |

For more troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Related documentation

| Document | Purpose |
|----------|---------|
| [INSTALL_HUB.md](INSTALL_HUB.md) | Choose the right install path |
| [INSTALL.md](INSTALL.md) | Mode A: Magisk module path |
| [RECOVERY_INSTALL.md](RECOVERY_INSTALL.md) | Mode B: Recovery ZIP path |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Full troubleshooting guide |
