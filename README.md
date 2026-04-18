# hands-on-metal

> ⚠️ **Experimental** — This project is under active development. Use at your
> own risk and always have a backup of your device before flashing anything.

A guided, fully offline root workflow for Android devices.
Collects real hardware data, patches the boot image via Magisk, and uploads
a privacy-safe diagnostic bundle — all without leaving the device or a single
trusted PC.

---

## What It Can Do

- **Root any supported Android device** (API 21–35+) via Magisk — either through the Magisk app or from TWRP / OrangeFox recovery, with no computer required.
- **Auto-detect your device** — identifies A/B slots, System-as-Root, dynamic partitions, Treble, AVB version, and the correct boot partition (`init_boot`, `boot`, or `vendor_boot`).
- **Prevent bricks** — reads the anti-rollback index and security patch level before patching so you never flash a downgrade that fuses the bootloader.
- **Collect real hardware data** — mirrors regulators, display adapters, device-tree, pinctrl, VINTF manifests, and HAL symbols in read-only mode.
- **Analyse and report** — a host-side Python pipeline parses logs, builds a SQLite hardware database, runs failure analysis, and generates human-readable reports.
- **Protect your privacy** — all PII is stripped before any data leaves the device; uploads are explicit opt-in only.
- **Work fully offline** — a single bundle ZIP contains the complete repo, all binaries, and both flashable ZIPs so you can work without any network access.
- **Resume after reboots** — the state machine persists progress across reboots and re-runs automatically on the next boot.
- **Auto-detect OTA updates** — if the Android version, security patch, or A/B slot changes between boots, the workflow re-runs against the new system image automatically.
- **Run everything from one menu** — an interactive terminal launcher (`terminal_menu.sh`) lists every script and lets you run any of them with arguments.

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                      hands-on-metal workflow                    │
│                                                                 │
│  1. ENV DETECT    Probe shell, Python, Termux, tools, SELinux   │
│  2. PROFILE       Read device props, partitions, AVB, Treble    │
│  3. ACQUIRE       Copy the boot/init_boot image (read-only)     │
│  4. PATCH         Magisk-patch the image with device flags       │
│  5. FLASH         Write patched image; verify SHA-256            │
│  6. VERIFY        Confirm Magisk root; install module            │
│                                                                 │
│  On reboot → service.sh re-checks OTA/slot changes, then       │
│  runs env_detect → setup_termux → collect (hardware data).      │
│                                                                 │
│  Host-side pipeline (Python, stdlib only):                      │
│    parse_logs → failure_analysis → build_table → report         │
│    → optional upload with privacy redaction                     │
└─────────────────────────────────────────────────────────────────┘
```

There are **three install paths**:

| Path | When to use | How |
|------|-------------|-----|
| **Mode A — Magisk module** | Magisk is already installed | Flash the module ZIP via the Magisk app |
| **Mode B — Recovery ZIP** | No Magisk yet; you have TWRP or OrangeFox | Flash the recovery ZIP from recovery |
| **Mode C — ADB/Fastboot** | No recovery; bootloader unlocked; have a PC | Temporary TWRP boot, ADB sideload, or direct fastboot flash |

All three paths run the same guided state machine. See [docs/INSTALL_HUB.md](docs/INSTALL_HUB.md) for a full decision tree.

---

## Features

| Feature | Description |
|---------|-------------|
| **Guided install flow** | State-machine-driven steps (ENV → PROFILE → ACQUIRE → PATCH → FLASH → VERIFY) survive reboots and resume automatically |
| **Auto device profiling** | Detects A/B slots, System-as-Root, dynamic partitions, Treble, AVB version, init\_boot vs boot vs vendor\_boot |
| **Anti-rollback protection** | Reads the device's anti-rollback index before patching so you never flash a downgrade that bricks the bootloader |
| **Dual install paths** | Flash via the **Magisk app** (Mode A) *or* via **TWRP / OrangeFox** without Magisk pre-installed (Mode B) |
| **OTA auto-detection** | Detects Android version, security patch, or A/B slot changes between boots and automatically re-runs the workflow |
| **Termux bootstrap** | Auto-installs Termux + Python + required packages when no system Python is found; works with any Termux version and setup |
| **Live hardware collection** | Mirrors `/sys/class/regulator`, `/sys/class/display`, `/proc/device-tree`, pinctrl, VINTF manifests, HAL symbols, and more — read-only, never mounts RW |
| **Sandbox / CI / Termux detection** | Detects non-device environments and logs the same clear warning + conclusion in every context; records `HOM_HW_ENV` for downstream tools |
| **Regulator data sanity check** | Logs the first 10 regulator entries (name + microvolts) and emits `[OK]` / `[WARN]` so you immediately know whether real display-adapter voltages were captured |
| **Host-side pipeline** | Python scripts parse logs, build a SQLite hardware map, analyse failures, generate reports, and upload a redacted bundle |
| **Privacy-safe sharing** | All PII stripped by `core/privacy.sh` before any data leaves the device; explicit opt-in for every upload |
| **Offline ZIP builder** | `build/build_offline_zip.sh` produces self-contained flashable ZIPs for all install paths |
| **Full dependency fetcher** | `build/fetch_all_deps.sh` uses `git` + `curl` to pull the repo and every binary, then creates a single offline bundle ZIP |
| **Host-assisted flash** | `build/host_flash.sh` — Mode C: fastboot boot / flash / ADB sideload for devices with no recovery (see [ADB_FASTBOOT_INSTALL.md](docs/ADB_FASTBOOT_INSTALL.md)) |
| **Interactive terminal menu** | `terminal_menu.sh` lists all project scripts and lets you run any of them with arguments from a single launcher |
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
| `tar` | Any | Bundle creation via `git archive` |
| `sha256sum` | Any (`shasum -a 256` on macOS) | Checksum verification |
| `adb` | Optional | Pushing ZIPs / reading logs without physical transfer |
| `file` / `nm` / `readelf` | Optional | Verifying bundled ARM binaries; used by `parse_symbols.py` |
| `c++filt` | Optional | C++ symbol demangling (`parse_symbols.py`) |
| `openssl` | Optional | Fallback SHA-256 hashing on device |

Run `bash check_deps.sh` to verify all dependencies in one step.
The check runs automatically when using `terminal_menu.sh` or the build scripts.

> **No third-party Python packages are required.**  
> All pipeline scripts use the Python standard library (`sqlite3`, `argparse`, `json`,
> `urllib`, `gzip`, `lzma`, `bz2`, `pathlib`, …).
> Optional packages `lz4` and `zstandard` improve boot image decompression coverage.

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
| [`fileserver/`](fileserver/) | Minimal HTTP file server — download via `curl`/`wget`, upload via `curl -F` (stdlib only, see [fileserver/README.md](fileserver/README.md)) |
| [`halium-shim/`](halium-shim/) | C shim + Makefile for Halium/libhybris bridge research |
| [`tests/`](tests/) | Python unit tests for `parse_logs`, `build_table`, and `fileserver` |
| [`setup.sh`](setup.sh) | One-step bootstrap — clones the repo, checks deps, fetches binaries, builds ZIPs |
| [`terminal_menu.sh`](terminal_menu.sh) | Interactive terminal launcher — run any project script from one menu |
| [`check_deps.sh`](check_deps.sh) | Host-side dependency checker — verifies all required tools are installed |
| [`docs/`](docs/) | Full documentation (see below) |

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/INSTALL_HUB.md](docs/INSTALL_HUB.md) | **Start here** — choose Magisk path vs recovery path based on your device state |
| [docs/INSTALL.md](docs/INSTALL.md) | Mode A: install via the Magisk app |
| [docs/RECOVERY_INSTALL.md](docs/RECOVERY_INSTALL.md) | Mode B: install via TWRP / OrangeFox |
| [docs/ADB_FASTBOOT_INSTALL.md](docs/ADB_FASTBOOT_INSTALL.md) | Mode C: install via ADB sideload / fastboot (no recovery needed) |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Every known failure mode with decision trees and remediation — including sandbox, CI, and Termux environments |
| [docs/MAINTAINER.md](docs/MAINTAINER.md) | How to obtain optional binaries, cut releases, and manage the partition index |
| [docs/SUPPORT_POLICY.md](docs/SUPPORT_POLICY.md) | Supported device families and Android versions |
| [docs/GOVERNANCE.md](docs/GOVERNANCE.md) | Contribution rules, new-device reports, decision process |
| [docs/FORK_CONTRACT.md](docs/FORK_CONTRACT.md) | Privacy variable definitions and fork obligations |

---

## Quick start

### 1 — Clone and fetch all dependencies

**One-liner** (requires `curl`; `git` is auto-installed if missing):

```bash
curl -fsSL https://raw.githubusercontent.com/mikethi/hands-on-metal/main/setup.sh | bash
cd hands-on-metal               # enter the repo after setup
```

**Or clone first**, then run the setup script locally:

```bash
git clone https://github.com/mikethi/hands-on-metal.git
cd hands-on-metal
bash setup.sh
```

If `git` is not installed the script attempts to install it automatically
using the system package manager (`apt-get`, `pkg`, `dnf`, `pacman`, or
`brew` / `xcode-select`). If automatic installation fails, it prints
platform-specific manual install instructions and exits.
The script is safe to re-run — it skips steps that are already complete.

`fetch_all_deps.sh` will:

1. Download `busybox-arm64` (static, arm64) from busybox.net
2. Download the Magisk v30.7 APK and extract `magisk64`, `magisk32`, and `magiskinit64`
3. Build both flashable ZIPs (`dist/hands-on-metal-magisk-module-<ver>.zip` and `dist/hands-on-metal-recovery-<ver>.zip`)
4. Create `dist/hands-on-metal-full-bundle-<ver>.zip` — a single ZIP containing the complete repo snapshot, all tools, both flashable ZIPs, and SHA-256 checksums

### 2 — Build the flashable ZIPs only (no binary downloads)

> **Tip:** All examples below assume the repo is at `~/hands-on-metal`. If you
> cloned it elsewhere, replace `~/hands-on-metal` with the actual path.

If you already have the binaries in `tools/` or want device-side binaries:

```bash
cd ~/hands-on-metal
source check_deps.sh
bash build/build_offline_zip.sh
```

To build without bundled tools (rely on what's already on the device):

```bash
cd ~/hands-on-metal
source check_deps.sh
bash build/build_offline_zip.sh --no-tools
```

### 3 — Flash to your device

**Mode A — Magisk already installed:**

```bash
cd ~/hands-on-metal
source check_deps.sh
# Push the ZIP to the device
adb push dist/hands-on-metal-magisk-module-v2.0.0.zip /sdcard/

# Then on the device:
# Magisk app → Modules → Install from storage → select the ZIP → reboot
```

**Mode B — no Magisk yet (flash from TWRP / OrangeFox):**

```bash
cd ~/hands-on-metal
source check_deps.sh
# Push the ZIP to the device
adb push dist/hands-on-metal-recovery-v2.0.0.zip /sdcard/

# Then on the device:
# Boot into TWRP/OrangeFox → Install → select the ZIP → swipe to confirm → reboot
```

### 4 — Run the host-side pipeline after collection

After your device has booted and collected hardware data, pull the logs and
run the pipeline on your PC:

```bash
cd ~/hands-on-metal
source check_deps.sh
RUN_ID="20250417_143022"   # ← replace with your actual RUN_ID

# Pull logs from device to your PC
adb pull /sdcard/hands-on-metal/logs/ ./logs/
adb pull /sdcard/hands-on-metal/live_dump/ ./live_dump/

# Parse the master log
python pipeline/parse_logs.py \
    --log "./logs/master_${RUN_ID}.log" \
    --out /tmp/parsed.json

# Run failure analysis
python pipeline/failure_analysis.py \
    --parsed /tmp/parsed.json \
    --out /tmp/analysis.json

# Build the hardware database
python pipeline/build_table.py \
    --db hardware_map.sqlite \
    --dump ./live_dump \
    --mode A \
    --run-id "$RUN_ID"

# Generate a human-readable report
python pipeline/report.py --db hardware_map.sqlite
```

### 5 — Run the unit tests

```bash
cd ~/hands-on-metal
source check_deps.sh
python -m pytest tests/
```

### 6 — Interactive terminal menu (optional)

Launch a single interactive menu that lists every script in the project and
lets you run any of them with arguments:

```bash
cd ~/hands-on-metal
source check_deps.sh
bash terminal_menu.sh
```

The menu lists all shell scripts (`build/`, `core/`, `magisk-module/`,
`recovery-zip/`) and all pipeline Python scripts (`pipeline/*.py`). Select a
number, enter optional arguments, and the script runs immediately.

> **Note:** argument input is space-separated; embedded space quoting is not
> supported inside the menu prompt.

---

## Dependency stack

All dependencies are pulled by `build/fetch_all_deps.sh`.

### Binaries (ARM64 — bundled in offline ZIPs)

| Binary | Version | Source | License |
|--------|---------|--------|---------|
| `busybox-arm64` | 1.31.0 | [busybox.net/downloads/binaries/](https://busybox.net/downloads/binaries/) | GPL-2.0 |
| `magisk64` | v30.7 | [github.com/topjohnwu/Magisk releases](https://github.com/topjohnwu/Magisk/releases) | GPL-3.0 |
| `magisk32` | v30.7 | [github.com/topjohnwu/Magisk releases](https://github.com/topjohnwu/Magisk/releases) | GPL-3.0 |
| `magiskinit64` | v30.7 | [github.com/topjohnwu/Magisk releases](https://github.com/topjohnwu/Magisk/releases) | GPL-3.0 |

### Python (host-side pipeline — stdlib only)

| Module | Use |
|--------|-----|
| `sqlite3` | `hardware_map.sqlite` database |
| `urllib` | `upload.py`, `github_notify.py` — GitHub API calls |
| `gzip` / `lzma` / `bz2` | `unpack_images.py` — boot image decompression |
| `hashlib` / `struct` / `io` | `unpack_images.py` — image parsing |
| `xml.etree.ElementTree` | `parse_manifests.py` — VINTF XML parsing |
| `subprocess` | `parse_symbols.py` — calls `c++filt`; `build_table.py` — runs sub-scripts |
| `argparse`, `json`, `pathlib`, `re`, `os`, `sys` | All scripts |

Optional packages (improve boot image decompression coverage):

| Package | Use |
|---------|-----|
| `lz4` | `unpack_images.py` — LZ4-compressed boot images |
| `zstandard` | `unpack_images.py` — Zstandard-compressed boot images |

### Shell / on-device tools

| Tool | Source |
|------|--------|
| `sh` / `mksh` | Android `/system/bin/sh` or Magisk busybox |
| `getprop` / `setprop` | Android system |
| `dd` | Boot image read/write (`boot_image.sh`, `flash.sh`, `collect.sh`) |
| `mount` / `umount` | Partition access (`collect_recovery.sh`, `env_detect.sh`) |
| `busybox` (optional) | Bundled in the ZIPs, or system busybox |
| `zip` / `unzip` | Host PC; used by `build_offline_zip.sh` and `fetch_all_deps.sh` |
| `curl` | Host PC; used by `fetch_all_deps.sh` |
| `tar` | Host PC; used by `fetch_all_deps.sh` (git archive) |
| `sha256sum` / `openssl` | Checksum verification (host and device) |
| `nm` / `readelf` | Vendor library symbol analysis (`collect.sh`, `parse_symbols.py`) |
| `c++filt` (optional) | C++ symbol demangling (`parse_symbols.py`) |
| `dmsetup` (optional) | dm-crypt / dm-verity table inspection (`collect.sh`) |
| `lshal` / `lsmod` / `modinfo` | HAL and kernel module inventory (`collect.sh`) |
| `dmesg` | Kernel log collection (`collect.sh`) |
| `adb` (optional) | [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools) |

### Termux (auto-bootstrapped when no system Python exists)

`setup_termux.sh` installs the following via `pkg` (compatible with any Termux version and any setup — Play Store, F-Droid, or GitHub release):

```
python  git  curl  wget  openssh  sqlite  zip
```

---

## libhybris / Halium research notes

See [`tools/README.md`](tools/README.md) for details on using decompiled
`libhybris.so` linker maps and the `halium-shim/` C shim to reconstruct
compatible userspace bridge logic.
