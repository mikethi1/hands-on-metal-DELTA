# hands-on-metal — Comprehensive Troubleshooting Guide

This guide covers every known failure mode across all supported Android versions
and device families. Each section includes a decision tree, root cause analysis,
and remediation steps.

See also: [INSTALL_HUB.md](INSTALL_HUB.md) to choose the right install path.

---

## How to read failure logs

All logs are written to `/sdcard/hands-on-metal/logs/`.

| File | What to look for |
|------|-----------------|
| `master_<RUN_ID>.log` | Full timeline; search for `[ERROR]` and `[FAIL]` |
| `var_audit_<RUN_ID>.txt` | Every variable value at time of capture |
| `run_manifest_<RUN_ID>.txt` | Step-by-step results; scan the STATUS column |
| `<script>_<RUN_ID>.log` | Per-script detail for the failing step |

Use the host-side pipeline to parse logs automatically:

```bash
python pipeline/parse_logs.py \
    --log /sdcard/hands-on-metal/logs/master_<RUN_ID>.log \
    --out /tmp/parsed.json

python pipeline/failure_analysis.py \
    --parsed /tmp/parsed.json \
    --out /tmp/analysis.json
```

---

## Boot partition not found {#boot-partition-not-found}

**Symptoms:**
- Installer prints "Could not auto-discover / boot partition"
- `HOM_DEV_BOOT_DEV=MISSING` in env_registry.sh

**Decision tree:**
```
1. Is the bootloader unlocked?
   NO  → Unlock bootloader first (see INSTALL_HUB.md)
   YES → Continue

2. Can you list partitions?
   Run in TWRP terminal or adb shell:
     ls /dev/block/bootdevice/by-name/
     ls /dev/block/by-name/

   No output / command not found?
   → Your device uses a platform-specific by-name path.
     Try: ls /dev/block/platform/
     Look for a directory containing 'by-name'

3. Is "boot" or "init_boot" in the partition list?
   NO  → Unusual device layout. Check:
           ls /dev/block/
         Some devices use mmcblk0p* naming without symlinks.
         File a new-device report (see GOVERNANCE.md).
   YES → Enter the full path manually when prompted.
```

**Android version / device notes:**

| Scenario | Cause | Fix |
|----------|-------|-----|
| API 33+ device shows no init_boot | Device updated from API 32 stock | Use `boot` instead; disable `init_boot` check |
| Samsung non-AB | Platform path `/dev/block/platform/...` | Enter path manually |
| MediaTek with `/dev/block/by-name/` | by-name not under bootdevice | Use `/dev/block/by-name/boot` |
| A/B device, wrong slot | Partition found but has slot suffix | Try `boot_a` or `boot_b` explicitly |

**Logs to check:**
- `[VAR  ]` lines for `HOM_DEV_BOOT_PART`, `HOM_DEV_BOOT_DEV`, `HOM_DEV_INIT_BOOT_DEV`
- `[ERROR]` lines from `boot_image` script

---

## Anti-rollback check fails {#anti-rollback-check-fails}

**Symptoms:**
- `ROLLBACK RISK DETECTED` printed on screen
- `HOM_ARB_ROLLBACK_RISK=true` in env_registry.sh
- Install aborted with "cannot proceed safely"

**Decision tree:**
```
1. What is the image SPL vs device SPL?
   (Check HOM_ARB_IMG_SPL and HOM_DEV_SPL in var_audit log)

   Image SPL < Device SPL?
   YES → You are trying to flash an older firmware. This is blocked.

2. Where did you get the boot image?
   → Extracted from an older OTA ZIP?
      Download the latest OTA for your exact device + build.
   → Provided manually?
      Get the boot.img from the full firmware matching your current SPL.

3. Device SPL >= 2026-05-01 (May-2026 policy)?
   YES → Magisk MUST use PATCHVBMETAFLAG=true.
         anti_rollback.sh sets HOM_ARB_REQUIRE_MAY2026_FLAGS=true automatically.
         magisk_patch.sh reads this and adjusts flags.
         If you're building manually, ensure your Magisk is >= 30.7.
```

**How to get the correct boot image:**

1. Find your exact build fingerprint:
   ```
   adb shell getprop ro.build.fingerprint
   ```
2. Download the full OTA or factory image for that exact build from your OEM.
3. Extract `boot.img` or `init_boot.img`:
   ```bash
   # From a factory zip:
   unzip factory.zip '*/image-*.zip'
   unzip image-*.zip boot.img init_boot.img
   # Copy to device:
   adb push boot.img /sdcard/hands-on-metal/boot_work/
   ```
4. When prompted for the boot image path, enter `/sdcard/hands-on-metal/boot_work/boot.img`.

---

## Magisk binary not found {#magisk-binary-not-found}

**Symptoms:**
- "Magisk binary not found" abort
- `HOM_MAGISK_BIN` is empty or missing in env_registry.sh

**Decision tree:**
```
1. Magisk path install (module flash via Magisk app)?
   → Magisk should always be present. Check:
     ls /data/adb/magisk/
     ls /sbin/magisk
   If missing: Magisk installation is corrupt. Reinstall Magisk first.

2. Recovery path install?
   → Offline bundle not built with magisk64.
     Run: ls $WORK_DIR/tools/
     If magisk64 is missing:
       Build the ZIPs with bundled Magisk (see MAINTAINER.md).
       Or: Copy magisk64 to /sdcard/hands-on-metal/tools/ before flashing.
```

**For older 32-bit devices:**
- 32-bit ARM devices need `magisk32` not `magisk64`.
- Check: `cat /proc/cpuinfo | grep -i arch` or `getprop ro.product.cpu.abi`
- If `armeabi-v7a`, ensure `tools/magisk32` is in the bundle.

---

## Flash verification fails {#flash-verification-fails}

**Symptoms:**
- "Post-flash SHA-256 mismatch" or "Flash verification failed"
- `HOM_FLASH_STATUS` is `FAIL`
- Device is still in recovery / not rebooted

**⚠️ Do NOT reboot if verification failed. The boot partition may be in an inconsistent state.**

**Decision tree:**
```
1. Can you still reach recovery?
   YES → Boot into TWRP and flash the ORIGINAL stock boot.img first.
         Then retry the full install.

2. Pre-flash SHA matches but post-flash doesn't?
   → Hardware write issue:
     • Retry once — transient eMMC errors are possible.
     • If repeated: device storage may have bad blocks. Run:
       dd if=/dev/zero of=/dev/block/bootdevice/by-name/boot bs=4096
       Then retry. (This wipes the partition — recovery required anyway.)

3. Pre-flash SHA doesn't match expected either?
   → You may be reading from the wrong partition.
     Verify HOM_FLASH_TARGET in logs and re-run.
```

**Restoring from a bad state:**
```bash
# From TWRP terminal or adb shell in recovery:
dd if=/sdcard/hands-on-metal/boot_work/boot_original.img \
   of=/dev/block/bootdevice/by-name/boot bs=4096
# This restores the unpatched original. Device will be unrooted but bootable.
```

---

## Device bootloops after reboot {#device-bootloops}

**Symptoms:**
- Device repeatedly restarts; cannot reach Android home screen
- Recovery boots fine

**Decision tree:**
```
1. Boot into recovery (hold Power + Vol Down at power-on, device-specific).

2. Is TWRP / OrangeFox accessible?
   YES → Flash the original stock boot image:
         Install → select: /sdcard/hands-on-metal/boot_work/boot_original.img
         OR use adb sideload with stock firmware.

3. No custom recovery?
   → Use fastboot:
     adb reboot bootloader
     fastboot flash boot stock_boot.img
     fastboot reboot

4. After restoring stock, review logs:
   cat /sdcard/hands-on-metal/logs/master_*.log | grep ERROR
   Look for: AVB failure, wrong SPL, SELinux denial, missing init binary
```

**Common bootloop causes by Android version:**

| API | Common cause | Fix |
|-----|-------------|-----|
| 33+ | init_boot patched but device boots boot | Set `HOM_DEV_BOOT_PART=init_boot` |
| 31–32 | KEEPVERITY=false on A/B | Ensure KEEPVERITY=true for A/B |
| 29–30 | Dynamic partition change | Do not modify super; only patch boot |
| 28 | SAR flag mismatch | Set LEGACYSAR correctly |
| <28 | Encryption flags wrong | KEEPFORCEENCRYPT=true required |

---

## Magisk patch fails or produces no output {#magisk-patch-fails}

**Symptoms:**
- "Magisk patch produced no output image"
- `magisk --boot-patch` returns non-zero

**Common causes:**
1. `/data/local/tmp` not writable — SELinux policy blocks write.
   ```bash
   # Temporary workaround: relax context
   chcon u:object_r:adb_data_file:s0 /data/local/tmp
   ```
2. Boot image is encrypted or corrupted — re-acquire from the partition.
3. Magisk version too old — upgrade to 30.7+ for init_boot support.
4. Init_boot too small — some devices have <8MB init_boot; this is unusual.

**Per-script log:**
```
cat /sdcard/hands-on-metal/logs/magisk_patch_*.log
```
Look for the exit code after `EXEC[magisk_boot_patch]`.

---

## Unknown device / new Android version {#unknown-device}

**Symptoms:**
- No entry found in `build/partition_index.json` for your device
- Installer continues but creates a file in `/sdcard/hands-on-metal/candidates/`

**What happens automatically:**
1. The installer uses best-effort heuristics (tries all known by-name paths).
2. `core/candidate_entry.sh` writes a JSON draft to `candidates/`.
3. A GitHub issue is opened (if `GITHUB_TOKEN` is set and a run fails).

**What you can do:**
1. Check if the install still succeeded despite the unknown device warning.
2. Review the candidate file:
   ```bash
   cat /sdcard/hands-on-metal/candidates/*.json
   ```
3. Submit a new-device report via GitHub Issues using the provided template.
4. If install failed, check the partition by-name list and provide the correct path manually.

---

## Analyzing failure logs with the pipeline {#analyzing-failure-logs}

The host-side Python pipeline can parse logs and generate ranked failure analysis:

```bash
# On your laptop/desktop (Python 3.9+)

# 1. Pull logs from device
adb pull /sdcard/hands-on-metal/logs/ /tmp/hom_logs/

# 2. Parse the master log
python pipeline/parse_logs.py \
    --log "/tmp/hom_logs/master_*.log" \
    --out /tmp/parsed.json

# 3. Run failure analysis
python pipeline/failure_analysis.py \
    --parsed /tmp/parsed.json \
    --out /tmp/analysis.json

# 4. View results
cat /tmp/analysis.json
```

The analysis output includes:
- Most probable failure cause (with confidence score)
- Step where failure occurred
- Ranked remediation steps
- Variables that may have contributed

---

## Sending diagnostic data

By default, all diagnostic data is **redacted** — serial numbers, IMEIs,
phone numbers, email addresses, and other PII are replaced with `#`.

To send logs for maintainer review:

```bash
# Redacted (default) — safe for public sharing
python pipeline/upload.py \
    --log /tmp/hom_logs/ \
    --analysis /tmp/analysis.json

# Opt-in: include unredacted data (private, maintainer-only)
python pipeline/upload.py \
    --log /tmp/hom_logs/ \
    --analysis /tmp/analysis.json \
    --private \
    --token "$GITHUB_TOKEN"
```

See [FORK_CONTRACT.md](FORK_CONTRACT.md) §1.9 for privacy variable definitions.

---

## Empty or dummy hardware data (sandbox, CI, or Termux) {#empty-hw-data}

`collect.sh` mirrors `/sys/class/regulator`, `/sys/class/display`, and related
sysfs trees to capture real hardware data — including the microvolts values used
to identify display-adapter power rails.  In three environments that data is
absent or meaningless:

| Environment | `HOM_HW_ENV` value | What you see |
|---|---|---|
| Real rooted device (Magisk service) | `android_rooted` | All regulators with real `microvolts` values |
| Termux (any version, with or without `tsu`) | `termux` | Kernel's own regulators, but `microvolts` may be missing; display sysfs entries absent |
| CI / sandbox host (GitHub Actions, Docker) | `sandbox_ci` | Only `regulator-dummy` entries; no `microvolts` files; no display class |
| TWRP / recovery running collect_recovery.sh | `recovery` | No live sysfs; only mounted-partition files |
| Termux running recovery zip manually | `termux_recovery` | Same as recovery + Termux warnings |

`collect.sh` logs a warning and records `HOM_HW_ENV` in `env_registry.sh`
automatically.  `failure_analysis.py` reads this value and adjusts its
expectations so you always receive the same clear conclusion regardless of
where the script ran.

### How to verify the first 10 regulator entries contain real data

After running `collect.sh`, check the log:

```
grep "regulator\." /sdcard/hands-on-metal/live_dump/collect.log | head -12
```

**Real hardware output** (display adapter rails visible):
```
regulator.1: name=vdd_display_oled   microvolts=1800000
regulator.2: name=vdd_display_vci    microvolts=3000000
regulator.3: name=vdd_display_iovcc  microvolts=1800000
regulator.4: name=smps1              microvolts=900000
...
[OK   ] 24 regulator(s) found, 24 with real microvolts data.
```

**Sandbox / CI output** (dummy only — no real data):
```
regulator.1: name=regulator-dummy  microvolts=(no microvolts)
[WARN ] 1 regulator(s) found but none have a microvolts file.
[WARN ] All entries are likely kernel placeholders (e.g. regulator-dummy).
```

**Termux output** (kernel regulators present, display missing):
```
[WARN ] Running inside Termux (TERMUX_VERSION=0.118.0).
regulator.1: name=regulator-dummy  microvolts=(no microvolts)
[WARN ] /sys/class/display collected no entries.
```

### Remediation by environment

**Sandbox / CI** — collect.sh is not designed to run on a host PC.  It must
run on a real Android device as root via Magisk `service.sh`.  If you are
testing the pipeline, use the sample data under `tools/` (see `tools/README.md`).

**Termux without root** — Termux alone cannot read protected sysfs nodes or
write to `/sdcard/hands-on-metal/` without Storage permission.  Grant Storage
permission to Termux (`termux-setup-storage`) and use `tsu` (Termux su) to
elevate, then re-run:

```bash
# inside Termux with Magisk-root available
tsu
sh /data/adb/modules/hands-on-metal/collect.sh
```

If `tsu` is unavailable, install it:

```bash
pkg install tsu
```

**Termux — display class missing** — `/sys/class/display` is only populated
when the display driver is active.  This is normal in Termux when the screen
is off or the display driver does not expose sysfs nodes.  Real display-adapter
voltage data is captured by the Magisk service path, not Termux.

**Recovery (collect_recovery.sh)** — the recovery script does not collect
live sysfs data by design.  It reads mounted partition files.  Regulator and
display voltage data is only available via the Magisk path (Mode A).

### env_registry.sh variables written by the sanity check

| Variable | Meaning |
|---|---|
| `HOM_HW_ENV` | Detected execution environment (`android_rooted`, `termux`, `sandbox_ci`, `recovery`, `termux_recovery`) |
| `HOM_HW_REGULATOR_COUNT` | Total regulator entries found under `/sys/class/regulator` |
| `HOM_HW_REGULATOR_REAL_MV_COUNT` | Entries that had a numeric `microvolts` value |

`failure_analysis.py` uses `HOM_HW_ENV` to skip voltage-related checks when
the environment cannot produce real data, so the analysis output remains
accurate and actionable in all environments.

---

## Per-device troubleshooting notes

### Samsung devices

- Samsung uses `dm-verity` aggressively; KEEPVERITY=true is always required.
- Some Exynos models encrypt the boot image header — the installer handles this.
- Recovery (TWRP) must be a device-specific build, not a generic GSI TWRP.
- If `boot` is not writable from recovery, try the Magisk-path install instead.

### Xiaomi / POCO / Redmi

- Global ROM and CN ROM have different partition layouts on some models.
- MIUI may prevent flashing from the Magisk app; use recovery path.
- HyperOS (MIUI 15+) strengthens AVB — ensure Magisk 30.7+.

### OnePlus

- ColorOS / OxygenOS 12+ uses init_boot; older OxygenOS uses boot.
- A/B devices need the boot image from the correct slot.
- Some models have a hidden `op_bootstrap` partition — do not modify it.

### Google Pixel

- Pixel 6+ uses Google Tensor with init_boot on API 33+.
- Factory images are always available at developers.google.com/android/images.
- Android Flash Tool can be used for bootloader unlock and stock restore.

### MediaTek

- `/dev/block/by-name/` (not `bootdevice/by-name/`) on most MTK devices.
- Some older MTK devices (MT6xxx) use scatter-file flashing, not fastboot.
- SP Flash Tool may be required if fastboot is unavailable.
