# hands-on-metal — Installation Hub

Choose your path based on your current state and device. Each path links to
detailed guides and troubleshooting decision trees.

---

## Quick route selector

```
Do you have TWRP, OrangeFox, or any custom recovery installed?
│
├─ YES ──► Is Magisk already installed and active?
│           │
│           ├─ YES ──► [Magisk path → INSTALL.md](INSTALL.md)
│           │           Flash the module ZIP via the Magisk app.
│           │
│           └─ NO  ──► [Recovery path → RECOVERY_INSTALL.md](RECOVERY_INSTALL.md)
│                       Flash the recovery ZIP via TWRP/OrangeFox.
│
└─ NO  ──► Is your bootloader unlocked?
            │
            ├─ YES ──► Boot a custom recovery first:
            │           See "Unlocking and flashing a recovery" below.
            │
            └─ NO  ──► Unlock your bootloader first:
                        See "Bootloader unlock" below.
```

---

## By Android version

| Android | API | Recommended path | Key notes |
|---------|-----|-----------------|-----------|
| 5–7 (Lollipop–Nougat) | 21–25 | Recovery path | A/B rare; boot only; no init_boot |
| 8 (Oreo) | 26–27 | Recovery path | Treble enabled; SAR on Pixel |
| 9 (Pie) | 28 | Recovery or Magisk | SAR required on new devices |
| 10–12 (Q–S) | 29–32 | Either path | Dynamic partitions; vendor_boot |
| 13 (Tiramisu) | 33 | Either path | init_boot introduced; Magisk patches init_boot |
| 14 (Upside Down Cake) | 34 | Either path | EROFS common; stricter AVB |
| 15+ | 35+ | Either path | May-2026 AVB policy active |
| Unknown / future | 36+ | Recovery path | Candidate entry auto-created |

---

## By device family / chipset

| SoC Family | Typical by-name path | Notes |
|-----------|---------------------|-------|
| Qualcomm (Snapdragon) | `/dev/block/bootdevice/by-name/` | A/B on newer, non-AB on older |
| MediaTek | `/dev/block/by-name/` | Both A/B and non-AB families |
| Google Tensor (Pixel 6+) | `/dev/block/by-name/` | A/B; init_boot on API 33+ |
| Samsung Exynos | `/dev/block/by-name/` | A/B; custom AVB on some |
| Samsung Exynos (non-AB) | `/dev/block/platform/*/by-name/` | Older flagships |
| HiSilicon Kirin | `/dev/block/platform/*/by-name/` | Non-AB; limited TWRP support |
| Unisoc (Spreadtrum) | `/dev/block/by-name/` | Non-AB; limited recovery |
| NVIDIA Tegra | `/dev/block/platform/*/by-name/` | Tablets; non-AB |

> Not seeing your device? The installer will still attempt auto-discovery
> and create a candidate entry if the device is unknown.

---

## By risk level

| Risk level | When to use | Path |
|-----------|-------------|------|
| **Low** | Magisk already installed; device backed up | Magisk path |
| **Medium** | Custom recovery installed; no current root | Recovery path |
| **High** | Bootloader just unlocked; first-time root | Recovery path + extra care |
| **Critical** | No recovery, encrypted data, no backup | Stop — backup first |

---

## Unlocking and flashing a custom recovery

> ⚠️ **Unlocking the bootloader wipes all data on most devices. Back up first.**

### Generic steps (most Android devices)

1. Enable **Developer options**: Settings → About phone → tap Build number 7 times.
2. Enable **OEM unlocking**: Developer options → OEM unlocking.
3. Enable **USB debugging**: Developer options → USB debugging.
4. Connect to a computer with ADB/fastboot installed.
5. Reboot to bootloader: `adb reboot bootloader`
6. Unlock: `fastboot flashing unlock` (or `fastboot oem unlock` on older devices)
7. Confirm on-device when prompted (this **wipes data**).
8. Flash recovery: `fastboot flash recovery twrp.img` (use device-specific TWRP build)
9. Reboot to recovery: `fastboot reboot recovery`

### Device-specific notes

| Device | Notes |
|--------|-------|
| Google Pixel | Use Android Flash Tool or `fastboot flashing unlock`; no OEM step needed |
| Samsung | Requires Odin + specific TWRP build; OEM unlock in Developer options |
| OnePlus (recent) | MSM Download Tool may be needed for unbrick recovery |
| Xiaomi | MI Unlock Tool required; 7-day wait enforced by server |
| Motorola | `fastboot oem unlock UNLOCK_CODE` where code comes from Motorola portal |

---

## Bootloader unlock

General guidance:
1. Back up all data — unlock wipes the device.
2. Check your carrier/region — some carrier-locked devices cannot be unlocked.
3. Follow your OEM's official process (linked above for common brands).
4. After unlock, the device boots with a warning screen — this is normal.

---

## After installation — verification steps

After any installation path, verify root is working:

1. Open Magisk app → home screen shows "Installed" with version number.
2. Open Termux → run `su` → prompt changes to `#`.
3. Check `/sdcard/hands-on-metal/logs/` for the full install log.
4. Check `/sdcard/hands-on-metal/env_registry.sh` for device profile.

---

## Troubleshooting

If anything goes wrong, see the comprehensive troubleshooting guide:
**[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**

Key sections:
- [Boot partition not found](TROUBLESHOOTING.md#boot-partition-not-found)
- [Anti-rollback check fails](TROUBLESHOOTING.md#anti-rollback-check-fails)
- [Magisk binary not found](TROUBLESHOOTING.md#magisk-binary-not-found)
- [Flash verification fails](TROUBLESHOOTING.md#flash-verification-fails)
- [Device bootloops after reboot](TROUBLESHOOTING.md#device-bootloops)
- [Unknown device / new Android version](TROUBLESHOOTING.md#unknown-device)
- [Analyzing failure logs](TROUBLESHOOTING.md#analyzing-failure-logs)

---

## Related documentation

| Document | Purpose |
|----------|---------|
| [INSTALL.md](INSTALL.md) | Magisk-path detailed guide |
| [RECOVERY_INSTALL.md](RECOVERY_INSTALL.md) | Recovery-path detailed guide |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Comprehensive troubleshooting |
| [SUPPORT_POLICY.md](SUPPORT_POLICY.md) | Device and Android version support tiers |
| [FORK_CONTRACT.md](FORK_CONTRACT.md) | Cross-fork variable dictionary |
| [MAINTAINER.md](MAINTAINER.md) | Build, release, and device database maintenance |
| [GOVERNANCE.md](GOVERNANCE.md) | New device onboarding process |
