#!/sbin/sh
# overlay-zip/overlay/hom_bare_metal.sh
# ============================================================
# hands-on-metal — Bare-Metal Device Constants
#
# Shell-sourceable.  Provides every ground-truth hardware identity
# value for the Pixel 8 Pro (codename husky, SoC zuma / Tensor G3).
#
# Source: board_summary.txt (collected from the live device),
#         plus PMIC identity from factory image RC files.
#
# Usage:
#   . /path/to/hom_bare_metal.sh
#   echo "$HOM_BM_HARDWARE"     # → husky
#   echo "$HOM_BM_SOC_MODEL"    # → Tensor G3
#
# Naming convention:
#   HOM_BM_<PROP_KEY_UPPERCASED_DOTS_TO_UNDERSCORES>
#
# These values are used by apply_overlay.sh to decide whether an
# entry that would be written to the env_registry is already known
# (bare-metal confirmed) and can be skipped.
# ============================================================

# shellcheck disable=SC2034  # constants are intentionally consumed by scripts that source this file

# ── Android properties (from board_summary.txt) ───────────────
HOM_BM_BOARD_PLATFORM="zuma"
HOM_BM_HARDWARE="husky"
HOM_BM_PRODUCT_BOARD="husky"
HOM_BM_PRODUCT_DEVICE="husky"
HOM_BM_PRODUCT_MODEL="Pixel 8 Pro"
HOM_BM_BUILD_FINGERPRINT="google/husky/husky:16/CP1A.260305.018/14887507:user/release-keys"
HOM_BM_VENDOR_BUILD_FINGERPRINT="google/husky/husky:16/CP1A.260305.018/14887507:user/release-keys"
HOM_BM_SOC_MANUFACTURER="Google"
HOM_BM_SOC_MODEL="Tensor G3"
HOM_BM_CPU_ABI="arm64-v8a"

# ── PMIC identity (from vendor init RC files) ─────────────────
HOM_BM_PMIC_MAIN="S2MPG12"
HOM_BM_PMIC_SUB="S2MPG13"

# ── Hardware token set (confirmed present on this SoC) ────────
HOM_BM_HW_TOKENS="husky zuma mali trusty google arm64-v8a Tensor_G3 Pixel_8_Pro"

# ── Kernel modules confirmed on this board ────────────────────
HOM_BM_KERNEL_MODULES="mali_kbase gsa trusty bcmbt edgetpu qca_cld3_wlan"

# ── ODPM channel assignments (from power.stats RC) ────────────
# ODPM = On-Die Power Monitor; channels are written to
# /sys/bus/iio/devices/iio:device0/enabled_rails at early-boot.
HOM_BM_ODPM_CH0="BUCK9M"    # VSYS_PWR_MMWAVE (sub6 SKUs)
HOM_BM_ODPM_CH11="BUCK12S"  # Display DSI supply

# ── Cross-group voltage source files (already scanned) ────────
# Files in the factory image that contain voltage data for ≥2 hw groups.
# The pipeline skips re-scanning these because the data is already here.
HOM_BM_VOLTAGE_SRC_1="vendor/etc/init/vendor.google.battery_mitigation-default.rc"
HOM_BM_VOLTAGE_SRC_1_GROUPS="battery,power,display,tpu,modem,system"
HOM_BM_VOLTAGE_SRC_2="vendor/etc/init/android.hardware.power.stats-service.pixel.rc"
HOM_BM_VOLTAGE_SRC_2_GROUPS="power,modem"
HOM_BM_VOLTAGE_SRC_3="vendor/etc/init/hw/init.zuma.rc"
HOM_BM_VOLTAGE_SRC_3_GROUPS="display,battery,system"
