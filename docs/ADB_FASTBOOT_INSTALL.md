# hands-on-metal — ADB Sideload & Fastboot Install Guide (Mode C)

> **Use this guide if your device has NO custom recovery (no TWRP / OrangeFox)
> and NO GSI slot.**
> If you already have a custom recovery, see [RECOVERY_INSTALL.md](RECOVERY_INSTALL.md).
> If Magisk is already installed, see [INSTALL.md](INSTALL.md).

---

## Overview

This guide covers three scenarios for devices without a custom recovery:

| Scenario | What you need | Section |
|----------|---------------|---------|
| **C1 — Temporary TWRP boot** | PC + fastboot + unlocked bootloader | [Temporary TWRP via fastboot boot](#c1--temporary-twrp-boot-via-fastboot) |
| **C2 — Direct fastboot flash** | PC + fastboot + pre-patched boot image | [Direct fastboot flash](#c2--direct-fastboot-flash) |
| **C3 — ADB sideload** | Custom recovery's sideload mode | [ADB sideload](#c3--adb-sideload-with-custom-recovery) |

> **Important:** Stock Android recovery does NOT accept unsigned ZIPs. ADB
> sideload only works with a custom recovery (TWRP / OrangeFox) that supports
> unsigned ZIP flashing. If your device has no custom recovery at all, use
> scenarios C1 or C2 instead.

---

## Prerequisites (all scenarios)

| Requirement | How to check |
|-------------|-------------|
| Unlocked bootloader | Device shows unlock warning at boot |
| USB debugging enabled | Settings → Developer options → USB debugging |
| ADB + fastboot on PC | `adb version` and `fastboot --version` |
| USB cable | Data-capable (not charge-only) |

Install ADB and fastboot if you don't have them:

```bash
# Linux (Debian/Ubuntu)
sudo apt-get install android-tools-adb android-tools-fastboot

# macOS (Homebrew)
brew install android-platform-tools

# Windows
# Download from https://developer.android.com/tools/releases/platform-tools
# Extract and add to PATH
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

| Your situation | Root? | Recovery? | Acquisition methods | Flash path | Install mode |
|---------------|:---:|:---:|---|---|---|
| **Magisk installed** | ✓ | ✗ | 1→2→3→4 (all available) | A (Magisk) | [INSTALL.md](INSTALL.md) |
| **TWRP / OrangeFox** | ✓ | ✓ | 1→2→3→4 (all available) | B (Recovery) | [RECOVERY_INSTALL.md](RECOVERY_INSTALL.md) |
| **Unlocked BL + PC, no root, no recovery** | ✗ | ✗ | 2→3→4 (no root DD) | C (Fastboot) | This guide (C1 or C2) |
| **Unlocked BL + PC + temp TWRP** | ✓³ | ✓³ | 1→2→3→4 (all via temp TWRP) | B (Recovery) | This guide (C1) |
| **Locked bootloader** | ✗ | ✗ | None | None | Unlock first |
| **No PC, no root, no recovery** | ✗ | ✗ | None | None | Not possible |

³ `fastboot boot twrp.img` gives you a temporary recovery with root.

> **Key insight:** Root access enables method 1 (root DD) and is required
> for flash paths A and B. Without root, you must pre-place the boot image
> (method 2) or use the fastboot flash path (C) from a PC.

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

This boots TWRP **temporarily** (in RAM only) without permanently installing
it. After reboot, the stock recovery returns. This is the safest option for
devices with no recovery.

### Step 1 — Download TWRP for your device

Find your device-specific TWRP image at [twrp.me](https://twrp.me/Devices/)
or your device's community forums. Download the `.img` file (not the `.zip`).

### Step 2 — Boot into the bootloader

From a running Android system:

```bash
adb reboot bootloader
```

Or power off, then hold **Power + Volume Down** (varies by device — see
[device-specific key combos](#device-specific-bootloader-key-combinations) below).

### Step 3 — Temporarily boot TWRP

```bash
# Boot TWRP image without installing it
fastboot boot twrp-<device>-<version>.img
```

> **Note:** Some devices (e.g., Samsung) do not support `fastboot boot`.
> For Samsung, use Odin or Heimdall to flash TWRP to the recovery partition.

### Step 4 — Transfer and flash the hands-on-metal ZIP

Once TWRP is running, you have two options:

**Option A — Push and flash:**

```bash
# Push the recovery ZIP to the device
adb push dist/hands-on-metal-recovery-v2.0.0.zip /sdcard/

# On device: TWRP → Install → select the ZIP → swipe to confirm
```

**Option B — ADB sideload:**

```bash
# On device: TWRP → Advanced → ADB Sideload → swipe to start

# On PC:
adb sideload dist/hands-on-metal-recovery-v2.0.0.zip
```

### Step 5 — Reboot

The installer flashes the patched boot image and reboots automatically.
After reboot, open the Magisk app to confirm root.

---

## C2 — Direct fastboot flash

If you cannot boot any recovery at all, you can patch the boot image on your
PC and flash it directly via fastboot. This bypasses recovery entirely.

### Step 1 — Extract your current boot image

**Option A — From a factory image:**

```bash
# Download your device's factory image from the OEM
# Google: https://developers.google.com/android/images
# Extract boot.img (or init_boot.img for Android 13+)
unzip factory-image.zip '*/image-*.zip'
unzip image-*.zip boot.img init_boot.img
```

**Option B — Via ADB from a running device (requires root or permissive adb):**

```bash
# Find the boot partition
adb shell ls /dev/block/bootdevice/by-name/ 2>/dev/null || \
    adb shell ls /dev/block/by-name/

# Copy boot image (requires root shell)
adb shell su -c "dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot_original.img"
adb pull /sdcard/boot_original.img
```

### Step 2 — Patch with Magisk on PC

Install the Magisk app on an emulator or another device, or use the Magisk
CLI:

```bash
# Transfer boot.img to a device with Magisk installed
adb push boot.img /sdcard/Download/

# On that device: Magisk app → Install → Select and Patch a File
# → select boot.img from Downloads
# → patched file saved to /sdcard/Download/magisk_patched-*.img

# Pull patched image back to PC
adb pull /sdcard/Download/magisk_patched-*.img patched_boot.img
```

### Step 3 — Boot into bootloader and flash

```bash
# Reboot target device to bootloader
adb reboot bootloader

# Wait for fastboot mode
fastboot devices   # verify device is listed

# Flash the patched boot image
# For devices with boot partition:
fastboot flash boot patched_boot.img

# For Android 13+ devices with init_boot:
fastboot flash init_boot patched_init_boot.img

# Reboot
fastboot reboot
```

### Step 4 — Verify

After reboot, install and open the Magisk app to confirm root is active.

---

## C3 — ADB sideload (with custom recovery)

> **This only works if you have a custom recovery (TWRP / OrangeFox)
> installed.** Stock recovery rejects unsigned ZIPs.

### Step 1 — Boot into recovery

```bash
adb reboot recovery
```

Or use the device-specific key combo (see below).

### Step 2 — Start ADB sideload mode

In TWRP / OrangeFox:

1. Tap **Advanced** (TWRP) or **Tools** (OrangeFox)
2. Tap **ADB Sideload**
3. Swipe to start sideload mode

### Step 3 — Sideload the ZIP

```bash
adb sideload dist/hands-on-metal-recovery-v2.0.0.zip
```

The guided installer runs automatically — same as flashing the ZIP directly
from recovery storage.

### Step 4 — Reboot

The installer reboots the device after flashing. Open Magisk app to confirm root.

---

## Useful ADB commands reference

### Rebooting into different modes

```bash
# Reboot to recovery (custom or stock)
adb reboot recovery

# Reboot to bootloader / fastboot mode
adb reboot bootloader

# Reboot to system (normal boot)
adb reboot

# Reboot to download mode (Samsung only)
adb reboot download
```

### On-device diagnostics via ADB shell

```bash
# Check if device is rooted
adb shell su -c "id"
# Expected: uid=0(root)

# List available partitions
adb shell ls -la /dev/block/bootdevice/by-name/ 2>/dev/null || \
    adb shell ls -la /dev/block/by-name/

# Check current boot slot (A/B devices)
adb shell getprop ro.boot.slot_suffix

# Check Android version and API level
adb shell getprop ro.build.version.release
adb shell getprop ro.build.version.sdk

# Check security patch level
adb shell getprop ro.build.version.security_patch

# Check device model and codename
adb shell getprop ro.product.model
adb shell getprop ro.product.device

# Check if init_boot partition exists (Android 13+)
adb shell ls /dev/block/bootdevice/by-name/init_boot* 2>/dev/null || \
    adb shell ls /dev/block/by-name/init_boot* 2>/dev/null || \
    echo "No init_boot partition found — use boot instead"

# Check bootloader lock state
adb shell getprop ro.boot.verifiedbootstate
adb shell getprop ro.boot.flash.locked
```

### Transferring files

```bash
# Push the hands-on-metal ZIP to device
adb push dist/hands-on-metal-recovery-v2.0.0.zip /sdcard/

# Push a boot image to device
adb push boot.img /sdcard/Download/

# Pull logs from device after install
adb pull /sdcard/hands-on-metal/logs/ ./hom-logs/

# Pull hardware data
adb pull /sdcard/hands-on-metal/live_dump/ ./hom-dump/
```

### Emergency recovery commands

```bash
# If device is bootlooping — get to fastboot
# Power off (hold power 10+ seconds), then hold Power + Volume Down

# From fastboot: flash stock boot image to recover
fastboot flash boot stock_boot.img
fastboot reboot

# If device is in fastboot and you have a TWRP image:
fastboot boot twrp.img
# Then from TWRP, flash stock firmware or restore backup
```

---

## Device-specific bootloader key combinations

| Device family | Bootloader (fastboot) | Recovery |
|--------------|----------------------|----------|
| Google Pixel | Power + Vol Down | Power + Vol Down → select "Recovery" |
| Samsung | Power + Vol Down + Bixby/Home | Power + Vol Up + Bixby/Home |
| OnePlus | Power + Vol Up + Vol Down | Power + Vol Down → select "Recovery" |
| Xiaomi / POCO / Redmi | Power + Vol Down | Power + Vol Up |
| Motorola | Power + Vol Down | Power + Vol Down → select "Recovery" |
| ASUS | Power + Vol Down | Power + Vol Up |
| LG | Power + Vol Down (hold until logo appears twice) | Power + Vol Down + Vol Up |
| Sony | Power + Vol Down (with USB connected) | Power + Vol Down → select "Recovery" |

> After entering fastboot mode, the device screen shows "FASTBOOT" or
> "Fastboot Mode". Use `fastboot devices` on your PC to verify the connection.

---

## Can I use ADB sideload without any recovery?

**No.** ADB sideload requires a recovery environment (stock or custom) that
implements the sideload protocol. Without any recovery partition:

- Use **C1** (temporary TWRP boot via `fastboot boot`) if your device supports it.
- Use **C2** (direct fastboot flash) to patch and flash the boot image from your PC.

Stock Android recovery supports `adb sideload` but **only for OEM-signed OTA
packages**. The hands-on-metal recovery ZIP is not OEM-signed, so stock
recovery will reject it. You need TWRP / OrangeFox for sideloading unsigned
ZIPs.

---

## Does Magisk patch the boot image live? Integrity & anti-rollback

### Live patching (Mode A — Magisk already installed)

**Yes, Magisk patches the boot image while Android is running.** The workflow:

1. `boot_image.sh` copies the active boot/init\_boot partition via `dd` →
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
| Wrong partition (boot vs init\_boot) | Auto-detected by `device_profile.sh` | Verify `HOM_DEV_BOOT_PART` in logs |
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
