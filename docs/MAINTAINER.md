# hands-on-metal — Maintainer Guide

This guide covers building the offline bundle, updating the partition index, adding supported devices, and maintaining the scripts.

---

## Repository layout

```
hands-on-metal/
├── core/                    Shared scripts (sourced by both paths)
│   ├── logging.sh           Timestamped logging, var audit, log_exec
│   ├── state_machine.sh     Persistent reboot-safe install state
│   ├── ux.sh                User-facing print/prompt helpers
│   ├── device_profile.sh    Device detection (model, AVB, A/B, Treble)
│   ├── boot_image.sh        Boot image acquisition + validation
│   ├── anti_rollback.sh     May-2026 anti-rollback guard
│   ├── magisk_patch.sh      Magisk boot image patching
│   └── flash.sh             Flash execution (Magisk + recovery paths)
│
├── magisk-module/           Magisk module ZIP source
│   ├── META-INF/…/update-binary   Module installer entry point
│   ├── customize.sh         Full guided wizard (sourced by update-binary)
│   ├── service.sh           On-boot data collection service
│   ├── env_detect.sh        Shell/tool environment detection
│   ├── setup_termux.sh      Conditional Termux bootstrap
│   ├── collect.sh           Live hardware data collection
│   └── module.prop          Module metadata
│
├── recovery-zip/            Recovery (TWRP) ZIP source
│   ├── META-INF/…/update-binary   Full guided recovery installer
│   ├── collect_recovery.sh  Recovery-mode hardware collection
│   └── tools/README.md      How to obtain busybox
│
├── build/
│   ├── build_offline_zip.sh  Build script
│   └── partition_index.json  Offline partition naming database
│
├── check_deps.sh            Host-side dependency checker
├── terminal_menu.sh         Interactive terminal launcher
│
├── docs/
│   ├── INSTALL.md            User guide (Magisk path)
│   ├── RECOVERY_INSTALL.md   User guide (recovery path)
│   └── MAINTAINER.md         This file
│
├── pipeline/                Python analysis pipeline (host-side)
├── schema/                  SQLite schema
└── halium-shim/             Halium shim C code
```

---

## Building the offline ZIPs

### 1. Install prerequisites

```bash
# Linux
apt-get install zip unzip curl git tar  # or brew install zip on macOS

# Verify everything is installed:
bash check_deps.sh
```

### 2. Obtain optional bundled tools

The ZIPs work without bundled tools (they use whatever is on the device), but bundling them makes the recovery ZIP fully self-contained.

Create a `tools/` directory at the repo root:

```bash
mkdir -p tools/

# Busybox (static arm64 — required for recovery path)
curl -L -o tools/busybox-arm64 \
  https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv8l
chmod +x tools/busybox-arm64

# Magisk binaries (download the Magisk apk and extract)
# Magisk APK is a zip; the binaries are inside it.
# Example for Magisk 30.7:
curl -L -o /tmp/magisk.apk \
  https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk
unzip -j /tmp/magisk.apk 'lib/arm64-v8a/libmagisk64.so' -d /tmp/
cp /tmp/libmagisk64.so tools/magisk64
chmod +x tools/magisk64

unzip -j /tmp/magisk.apk 'lib/armeabi-v7a/libmagisk32.so' -d /tmp/
cp /tmp/libmagisk32.so tools/magisk32
chmod +x tools/magisk32
```

> **Legal note**: Magisk is licensed under GPL-3.0. When distributing a bundle containing Magisk binaries, you must comply with the GPL-3.0 terms, including making the corresponding source code available. The official source is at https://github.com/topjohnwu/Magisk. Treble Check (kevintresuelo) is licensed under Apache-2.0. The partition detection logic in this repo independently re-implements equivalent checks.

### 3. Run the build script

```bash
bash build/build_offline_zip.sh
# Output in dist/:
#   hands-on-metal-magisk-module-v1.0.0.zip
#   hands-on-metal-recovery-v1.0.0.zip
#   checksums-v1.0.0.sha256
```

With a custom version:

```bash
bash build/build_offline_zip.sh --version v2.0.0
```

Without tool validation warnings:

```bash
bash build/build_offline_zip.sh --no-tools
```

---

## Updating the partition index

`build/partition_index.json` is the offline device database. Update it when:

- A new device family with different partition naming is encountered.
- A new Android version changes partition conventions (e.g., API 33 `init_boot`).
- New anti-rollback policy thresholds become known.

### Schema overview

```json
{
  "partition_types": { ... },   // boot/init_boot/vendor_boot definitions
  "by_name_paths": [ ... ],     // glob patterns for block device discovery
  "device_families": { ... },   // per-SoC/family partition hints
  "anti_rollback": { ... },     // SPL thresholds and required flags
  "magisk_versions": { ... }    // supported/recommended Magisk versions
}
```

### Adding a new device family

```json
"device_families": {
  "my_new_soc_ab": {
    "description": "Vendor SoC with A/B slots",
    "soc_match": ["vendor_prefix"],
    "is_ab": true,
    "boot_partition": "boot",
    "init_boot_api_min": 33,
    "example_devices": ["Device Model A", "Device Model B"],
    "by_name_hint": "/dev/block/by-name/"
  }
}
```

---

## Online index refresh (optional)

`core/boot_image.sh` reads `$PARTITION_INDEX` for offline hints. To add online refresh:

1. Publish an updated `partition_index.json` at a stable URL.
2. Add a `_refresh_index()` function in `boot_image.sh` that:
   - Checks network connectivity.
   - Downloads the updated index to `/sdcard/hands-on-metal/partition_index.json`.
   - Falls back to the bundled index if the download fails.

The bundled index ensures the workflow is always fully offline-capable.

---

## State machine

The install state is persisted at:

```
/data/adb/modules/hands-on-metal-collector/.install_state
```

Format: `STATE|TIMESTAMP`

To reset and re-run the wizard:

```bash
rm /data/adb/modules/hands-on-metal-collector/.install_state
```

State sequence:

```
INIT → ENV_DETECTED → DEVICE_PROFILED → BOOT_IMG_ACQUIRED
     → BOOT_IMG_PATCHED → ANTI_ROLLBACK_CHECKED → FLASH_QUEUED
     → FLASHED → ROOT_VERIFIED → COMPLETE
```

Each core script guards its entry with `sm_require STATE` and exits after `sm_set_state NEXT_STATE`.

---

## Logging system

All scripts produce three log files (per run, identified by `RUN_ID`):

| File | Contents |
|------|----------|
| `logs/master_<RUN_ID>.log` | All log lines from all scripts |
| `logs/<script>_<RUN_ID>.log` | Per-script log |
| `logs/var_audit_<RUN_ID>.log` | Variable audit trail (name, value, description) |
| `logs/run_manifest_<RUN_ID>.txt` | Step results: `timestamp\|step\|status\|note` |

To add a new variable to the audit trail:

```sh
log_var "MY_VAR" "$my_val" "human-readable description of what this variable means"
```

To add a new step to the manifest:

```sh
manifest_step "my_step_name" "OK" "optional note"
```

---

## Adding a new core script

1. Create `core/my_script.sh`.
2. Source `logging.sh` and `ux.sh` at the top.
3. Implement a `run_my_script()` function.
4. Add the call to `magisk-module/customize.sh` and `recovery-zip/META-INF/…/update-binary` in the right sequence.
5. Update the state machine sequence if a new state is needed.
6. Add the script to the `unzip` list in `build/build_offline_zip.sh`.

---

## Anti-rollback policy notes (May 2026)

Starting with security patch level 2026-05-07, Android's AVB anti-rollback protection becomes more strictly enforced and Magisk adopted a policy update to match. The relevant Magisk patch flags are:

- `PATCHVBMETAFLAG=true` — patches the vbmeta flag byte in the boot image header, which is required for the device to boot the patched image without failing AVB verification on SPL >= 2026-05-07.
- `KEEPVERITY=true` — for A/B devices, must not strip dm-verity signatures.
- `KEEPFORCEENCRYPT=true` — preserves the `forceencrypt` flag so /data remains encrypted.

The `core/anti_rollback.sh` script automatically detects whether the May-2026 policy is active and sets `HOM_ARB_REQUIRE_MAY2026_FLAGS=true` in the env registry. `core/magisk_patch.sh` reads this and adjusts `PATCHVBMETAFLAG` accordingly.

---

## Running the test suite (host-side)

The pipeline scripts have Python unit tests:

```bash
cd pipeline/
python -m pytest tests/        # if tests/ exists
python parse_pinctrl.py --help
python build_table.py --help
```

Shell scripts can be linted with ShellCheck:

```bash
# Install: apt-get install shellcheck / brew install shellcheck
shellcheck core/*.sh magisk-module/*.sh recovery-zip/collect_recovery.sh
```

---

## Release process

1. Update `magisk-module/module.prop` version.
2. Update `build/partition_index.json` `_updated` field.
3. Run `bash build/build_offline_zip.sh --version vX.Y.Z`.
4. Verify ZIPs: `sha256sum -c dist/checksums-vX.Y.Z.sha256`.
5. Tag the commit: `git tag vX.Y.Z`.
6. Upload `dist/*.zip` and `dist/checksums-*.sha256` to the GitHub release.
