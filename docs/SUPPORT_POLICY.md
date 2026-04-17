# hands-on-metal — Device and Android Version Support Policy

This document defines the support model for all forks and deployments of
hands-on-metal. Every fork must use the same tier names, environment class
identifiers, and variable names defined here.

See also:
- [FORK_CONTRACT.md](FORK_CONTRACT.md) — canonical variable dictionary and versioned spec
- [INSTALL_HUB.md](INSTALL_HUB.md) — routing guide for all install scenarios
- [GOVERNANCE.md](GOVERNANCE.md) — how to add new devices and Android versions

---

## 1. Android Version Support Tiers

| Tier | Definition | Scope |
|------|-----------|-------|
| **supported** | Fully tested; scripts run without manual intervention | Android 9–15 (API 28–35) |
| **partial** | Works with documented limitations or extra steps | Android 6–8 (API 23–27) |
| **experimental** | Scripts run but output may be incomplete | Android 5 and below (API < 23) |
| **unknown** | New API level not yet in the compatibility database | Triggers `candidate_entry.sh` |

### Android version → install path mapping

| Android Version | API | init_boot? | A/B default? | Notes |
|----------------|-----|-----------|-------------|-------|
| 5.x Lollipop | 21–22 | no | no | `boot` only; no dynamic partitions |
| 6.x Marshmallow | 23 | no | no | adoptable storage, FDE |
| 7.x Nougat | 24–25 | no | some | first seamless A/B OTA devices |
| 8.x Oreo | 26–27 | no | some | Project Treble; vendor partition |
| 9.x Pie | 28 | no | common | SAR required; GSI support |
| 10 | 29 | no | yes (GKI) | Dynamic partitions (super); GPT required |
| 11 | 30 | no | yes | GKI 1.0; vendor_boot introduced |
| 12 / 12L | 31–32 | no | yes | GKI 2.0; vendor_boot required |
| 13 | 33 | **yes** | yes | init_boot introduced; Magisk patches init_boot |
| 14 | 34 | yes | yes | EROFS for system; stricter AVB |
| 15 | 35 | yes | yes | May-2026 AVB policy (see anti_rollback.sh) |
| 16+ (future) | 36+ | yes | yes | Auto-creates candidate entry |

---

## 2. Device Support Tiers

| Tier | Definition |
|------|-----------|
| **known-supported** | Device family entry exists in `build/partition_index.json`; at least one successful run recorded |
| **known-partial** | Device family entry exists; install completes with manual steps or caveats |
| **unknown** | No matching entry found; `candidate_entry.sh` creates a draft record |

Factors that affect support level:
- SoC family (Qualcomm, MediaTek, Samsung Exynos, Google Tensor, Kirin, Unisoc, NVIDIA)
- A/B vs non-A/B slot layout
- Dynamic partitions (super)
- AVB version and state
- Carrier/region-specific bootloader variants

---

## 3. Environment Classes

Each install runs in one of these environment classes. Scripts use `HOM_ENV_CLASS`
to select behaviors:

| Class | Value | Description |
|-------|-------|-------------|
| Magisk path | `magisk` | Magisk is already installed; flash via Magisk app |
| Recovery path | `recovery` | Booted into TWRP/OrangeFox; full root bootstrap |
| Host-assisted path | `host` | ADB + fastboot from a computer; used for bootloader unlock |

The env class is detected by `magisk-module/env_detect.sh` and written to
`HOM_ENV_CLASS` in the env registry.

---

## 4. What "applies any customization" means per class

### Magisk path
- Device profile auto-selects `init_boot` vs `boot`
- A/B slot detection → correct `KEEPVERITY` flag
- May-2026 AVB policy detection → `PATCHVBMETAFLAG`
- SoC-specific by-name hints from `partition_index.json`

### Recovery path
- All of the above, plus:
- Busybox bootstrap from bundled binary
- Magisk binary from offline bundle
- Partition mount/umount for hardware collection

### Host-assisted path
- Covered in `docs/INSTALL_HUB.md` under "Advanced / no recovery available"
- Fastboot flash path (future; planned in GOVERNANCE.md roadmap)

---

## 5. Unknown device / new Android version onboarding

When the installed Android API level or device family is not found in
`build/partition_index.json`, the workflow automatically:

1. Continues the install using best-effort heuristics
2. Runs `core/candidate_entry.sh` to collect all available device facts
3. Saves a draft JSON record to `/sdcard/hands-on-metal/candidates/`
4. (If GitHub-authenticated) Opens a GitHub issue using the new-device template

See [GOVERNANCE.md](GOVERNANCE.md) for how maintainers review and approve
candidate entries.
