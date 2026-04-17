# hands-on-metal **********warning********* experimental 

A guided, fully offline root workflow for Android devices.  
Collects real hardware data, patches the boot image via Magisk, and uploads
a privacy-safe diagnostic bundle — all without leaving the device or a single
trusted PC.

---

## Features

| Feature | Description |
|---------|-------------|
| **Guided install flow** | State-machine-driven steps (ENV → PROFILE → ACQUIRE → PATCH → FLASH → VERIFY) survive reboots and resume automatically |
| **Auto device profiling** | Detects A/B slots, System-as-Root, dynamic partitions, Treble, AVB version, init\_boot vs boot vs vendor\_boot |
| **Anti-rollback protection** | Reads the device's anti-rollback index before patching so you never flash a downgrade that bricks the bootloader |
| **Dual install paths** | Flash via the **Magisk app** (Mode A) *or* via **TWRP / OrangeFox** without Magisk pre-installed (Mode B) |
| **Termux bootstrap** | Auto-installs Termux + Python + required packages when no system Python is found; works with any Termux version and setup |
| **Live hardware collection** | Mirrors `/sys/class/regulator`, `/sys/class/display`, `/proc/device-tree`, pinctrl, VINTF manifests, HAL symbols, and more — read-only, never mounts RW |
| **Sandbox / CI / Termux detection** | Detects non-device environments and logs the same clear warning + conclusion in every context; records `HOM_HW_ENV` for downstream tools |
| **Regulator data sanity check** | Logs the first 10 regulator entries (name + microvolts) and emits `[OK]` / `[WARN]` so you immediately know whether real display-adapter voltages were captured |
| **Host-side pipeline** | Python scripts parse logs, build a SQLite hardware map, analyse failures, generate reports, and upload a redacted bundle |
| **Privacy-safe sharing** | All PII stripped by `core/privacy.sh` before any data leaves the device; explicit opt-in for every upload |
| **Offline ZIP builder** | `build/build_offline_zip.sh` produces self-contained flashable ZIPs for both install paths |
| **Full dependency fetcher** | `build/fetch_all_deps.sh` uses `git` + `curl` to pull the repo and every binary, then creates a single offline bundle ZIP |
| **Halium / libhybris shim** | C shim and Makefile for building a compatible userspace bridge from decompiled linker-map data |

---

## Minimum requirements

### On-device (Android)

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| Android version | 5.0 (API 21) | Tested through API 35 / Android 15 |
| Bootloader | **Unlocked** | Required before any root operation |
| Custom recovery | TWRP ≥ 3.x or OrangeFox | Required for Mode B (recovery path) |
| Magisk | ≥ 25000 (v25.0) | Required for Mode A (module path) |
| Storage permission | Granted | `/sdcard/hands-on-metal/` is the only write location |
| Root shell | `uid=0` via Magisk or recovery | `service.sh` / `update-binary` run as root |

### Host-side (PC / Mac / Linux / Termux)

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| Python | 3.8+ | All pipeline scripts; **stdlib only — no pip deps required** |
| `git` | Any modern version | Cloning the repo and running `fetch_all_deps.sh` |
| `zip` / `unzip` | Any | Building and extracting flashable ZIPs |
| `curl` | Any | Downloading Magisk APK and busybox binary |
| `sha256sum` | Any (`shasum -a 256` on macOS) | Checksum verification |
| `adb` | Optional | Pushing ZIPs / reading logs without physical transfer |
| `file` / `nm` / `readelf` | Optional | Verifying bundled ARM binaries; used by `parse_symbols.py` |

> **No third-party Python packages are required.**  
> All pipeline scripts use the Python standard library (`sqlite3`, `argparse`, `json`,
> `urllib`, `gzip`, `lzma`, `bz2`, `pathlib`, …).

---

## Repository contents

| Path | What it does |
|------|-------------|
| [`magisk-module/`](magisk-module/) | Magisk module: `service.sh`, `collect.sh`, `env_detect.sh`, `setup_termux.sh`, `customize.sh`, `module.prop` |
| [`recovery-zip/`](recovery-zip/) | TWRP/OrangeFox flashable ZIP: `collect_recovery.sh`, `META-INF/` |
| [`core/`](core/) | Shared shell library: state machine, device profiling, boot image, Magisk patch, flash, anti-rollback, UX, logging, privacy, share |
| [`pipeline/`](pipeline/) | Host-side Python pipeline: log parser, manifest parser, pinctrl parser, symbol parser, image unpacker, DB builder, failure analyser, report generator, uploader, GitHub notifier |
| [`schema/`](schema/) | SQLite schema (`hardware_map.sql`) |
| [`build/`](build/) | `build_offline_zip.sh`, `fetch_all_deps.sh`, `partition_index.json` |
| [`tools/`](tools/) | Optional binaries (`busybox-arm64`, `magisk64`, `magisk32`, `magiskinit64`) — not committed; fetched by `fetch_all_deps.sh` |
| [`halium-shim/`](halium-shim/) | C shim + Makefile for Halium/libhybris bridge research |
| [`docs/`](docs/) | Full documentation (see below) |

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/INSTALL_HUB.md](docs/INSTALL_HUB.md) | **Start here** — choose Magisk path vs recovery path based on your device state |
| [docs/INSTALL.md](docs/INSTALL.md) | Mode A: install via the Magisk app |
| [docs/RECOVERY_INSTALL.md](docs/RECOVERY_INSTALL.md) | Mode B: install via TWRP / OrangeFox |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Every known failure mode with decision trees and remediation — including sandbox, CI, and Termux environments |
| [docs/MAINTAINER.md](docs/MAINTAINER.md) | How to obtain optional binaries, cut releases, and manage the partition index |
| [docs/SUPPORT_POLICY.md](docs/SUPPORT_POLICY.md) | Supported device families and Android versions |
| [docs/GOVERNANCE.md](docs/GOVERNANCE.md) | Contribution rules, new-device reports, decision process |
| [docs/FORK_CONTRACT.md](docs/FORK_CONTRACT.md) | Privacy variable definitions and fork obligations |

---

## Quick start

### 1 — Clone and fetch all dependencies

```bash
git clone https://github.com/mikethi/hands-on-metal.git
cd hands-on-metal
bash build/fetch_all_deps.sh
```

`fetch_all_deps.sh` will:

1. Download `busybox-arm64` (static, arm64) from busybox.net
2. Download the Magisk v27.0 APK and extract `magisk64`, `magisk32`, and `magiskinit64`
3. Build both flashable ZIPs (`dist/hands-on-metal-magisk-module-<ver>.zip` and `dist/hands-on-metal-recovery-<ver>.zip`)
4. Create `dist/hands-on-metal-full-bundle-<ver>.zip` — a single ZIP containing the complete repo snapshot, all tools, both flashable ZIPs, and SHA-256 checksums

### 2 — Flash to your device

**Mode A — Magisk already installed:**
```bash
adb push dist/hands-on-metal-magisk-module-v2.0.0.zip /sdcard/
# Magisk app → Modules → Install from storage → select the ZIP → reboot
```

**Mode B — no Magisk yet (flash from TWRP / OrangeFox):**
```bash
adb push dist/hands-on-metal-recovery-v2.0.0.zip /sdcard/
# Boot TWRP/OrangeFox → Install → select the ZIP → reboot
```

### 3 — Run the host-side pipeline after collection

```bash
python pipeline/parse_logs.py \
    --log /sdcard/hands-on-metal/logs/master_<RUN_ID>.log \
    --out /tmp/parsed.json

python pipeline/failure_analysis.py \
    --parsed /tmp/parsed.json \
    --out /tmp/analysis.json

python pipeline/build_table.py \
    --db hardware_map.sqlite \
    --dump /sdcard/hands-on-metal/live_dump \
    --mode A \
    --run-id <RUN_ID>

python pipeline/report.py --db hardware_map.sqlite
```

### Optional — Run scripts from an interactive terminal menu

If you prefer a single launcher in terminal, use:

```bash
bash terminal_menu.sh
```

The menu lists all shell scripts (`build/`, `core/`, `magisk-module/`, `recovery-zip/`)
and all pipeline Python scripts (`pipeline/*.py`), then lets you run any of them
with optional arguments.

Note: argument input is space-separated; embedded space quoting is not supported
inside the menu prompt.

---

## Dependency stack

All dependencies are pulled by `build/fetch_all_deps.sh`.

### Binaries (ARM64 — bundled in offline ZIPs)

| Binary | Version | Source | License |
|--------|---------|--------|---------|
| `busybox-arm64` | 1.35.0 | [busybox.net/downloads/binaries/](https://busybox.net/downloads/binaries/) | GPL-2.0 |
| `magisk64` | v27.0 | [github.com/topjohnwu/Magisk releases](https://github.com/topjohnwu/Magisk/releases) | GPL-3.0 |
| `magisk32` | v27.0 | [github.com/topjohnwu/Magisk releases](https://github.com/topjohnwu/Magisk/releases) | GPL-3.0 |
| `magiskinit64` | v27.0 | [github.com/topjohnwu/Magisk releases](https://github.com/topjohnwu/Magisk/releases) | GPL-3.0 |

### Python (host-side pipeline — stdlib only)

| Module | Use |
|--------|-----|
| `sqlite3` | `hardware_map.sqlite` database |
| `urllib` | `upload.py`, `github_notify.py` — GitHub API calls |
| `gzip` / `lzma` / `bz2` | `unpack_images.py` — boot image decompression |
| `argparse`, `json`, `pathlib`, `re`, `os`, `sys` | All scripts |

### Shell / on-device tools

| Tool | Source |
|------|--------|
| `sh` / `mksh` | Android `/system/bin/sh` or Magisk busybox |
| `getprop` | Android system |
| `busybox` (optional) | Bundled in the ZIPs, or system busybox |
| `zip` / `unzip` | Host PC; used by `build_offline_zip.sh` |
| `curl` | Host PC; used by `fetch_all_deps.sh` |
| `adb` (optional) | [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools) |

### Termux (auto-bootstrapped when no system Python exists)

`setup_termux.sh` installs the following via `pkg` (compatible with any Termux version and any setup — Play Store, F-Droid, or GitHub release):

```
python  git  curl  wget  openssh  sqlite
```

---

## libhybris / Halium research notes

See [`tools/README.md`](tools/README.md) for details on using decompiled
`libhybris.so` linker maps and the `halium-shim/` C shim to reconstruct
compatible userspace bridge logic.
