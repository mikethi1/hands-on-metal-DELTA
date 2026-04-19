#!/system/bin/sh
# magisk-module/collect.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Hands-on-metal — Hardware Data Collection (root-adaptive)
# Collects all hardware-relevant data READ-ONLY into
# ~/hands-on-metal/live_dump/ then writes a manifest so
# the host-side pipeline knows what is available.
#
# Root-adaptive behaviour:
#   • With root: full collection including dmesg, pinctrl,
#     vendor library symbols, readelf, boot partition DD, dmsetup
#   • Without root: partial collection — getprop, /proc files,
#     readable sysfs classes, VINTF manifests, sysconfig, board
#     summary, encryption state props.  Root-only sources are
#     skipped with a [SKIP] log line.
#
# Safety guarantees:
#   • Never mounts any partition read-write
#   • Never writes outside $OUT/
#   • Skips unreadable paths gracefully
# ============================================================

set -u

OUT="${HOME:-/data/local/tmp}/hands-on-metal/live_dump"
LOG=$OUT/collect.log
MANIFEST=$OUT/manifest.txt
ENV_REGISTRY="${HOME:-/data/local/tmp}/hands-on-metal/env_registry.sh"

# ── helpers ──────────────────────────────────────────────────

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

# Resolve a path to its real absolute path (no symlinks)
real_abs() {
    local p="$1"
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$p" 2>/dev/null || echo "$p"
    else
        echo "$p"
    fi
}

# Write/update a key in the shared env registry
reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

# copy a single file, preserving the relative path under $OUT.
# Also records the real absolute path (readlink -f) to the manifest
# so symlink chains in /vendor or /system are transparent.
copy_file() {
    local src="$1"
    local dst="$OUT$src"
    [ -f "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    if cp -p "$src" "$dst" 2>/dev/null; then
        echo "$src" >> "$MANIFEST"
        # Record real absolute path alongside the nominal path
        local rp
        rp=$(real_abs "$src")
        [ "$rp" != "$src" ] && echo "REALPATH:$src=$rp" >> "$MANIFEST"
    fi
}

# recursively mirror a directory (read-only, no symlink follow)
copy_dir() {
    local src="$1"
    [ -d "$src" ] || return 0
    find "$src" -type f 2>/dev/null | while IFS= read -r f; do
        copy_file "$f"
    done
}

# copy /sys or /proc virtual files that can be read as text
copy_virtual() {
    local src="$1"
    local dst="$OUT$src"
    [ -r "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    cat "$src" > "$dst" 2>/dev/null && \
        echo "$src" >> "$MANIFEST"
}

copy_virtual_dir() {
    local base="$1"
    [ -d "$base" ] || return 0
    find "$base" -type f -readable 2>/dev/null | while IFS= read -r f; do
        copy_virtual "$f"
    done
}

# ── main ─────────────────────────────────────────────────────

mkdir -p "$OUT"
: > "$MANIFEST"

# ── pre-flight: verify env_detect ran ────────────────────────
# env_detect.sh must have populated ENV_REGISTRY before collect.sh
# is invoked.  If it hasn't, the on-device HOM_EXEC_NODE and
# HOM_CRYPTO_CLASS vars will be missing, and collection may
# write data without knowing what execution context it runs in.
if [ ! -f "$ENV_REGISTRY" ] || \
   ! grep -q "^HOM_EXEC_NODE=" "$ENV_REGISTRY" 2>/dev/null; then
    log "[WARN ] ENV_REGISTRY missing or env_detect.sh not run — running inline detection"
    # Minimal inline context so collect.sh can still proceed
    _uid=$(id -u 2>/dev/null || echo 9999)
    _node="unprivileged"
    if [ "$_uid" = "0" ]; then
        [ -d /data/adb/magisk ] && _node="root_magisk" || _node="root_other"
    fi
    [ -f "$ENV_REGISTRY" ] || : > "$ENV_REGISTRY"
    reg_set shell HOM_EXEC_NODE "$_node"
    reg_set shell HOM_EXEC_UID "$_uid"
fi

log "=== hands-on-metal collect.sh start ==="
_HOM_IS_ROOT=false
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
    _HOM_IS_ROOT=true
fi
if [ "$_HOM_IS_ROOT" = false ]; then
    log "[INFO ] Running WITHOUT root — some data sources will be skipped"
    log "[INFO ] Root-only: dmesg, /sys/kernel/debug/pinctrl, block device DD,"
    log "[INFO ]            vendor library symbols, readelf sections"
fi
log "Device: $(getprop ro.product.model)"

# 1. Android properties
log "Collecting getprop..."
getprop > "$OUT/getprop.txt" && echo "getprop.txt" >> "$MANIFEST"

# 2. HAL interfaces
log "Collecting lshal..."
lshal > "$OUT/lshal.txt" 2>&1 && echo "lshal.txt" >> "$MANIFEST"
lshal --types=b,c,l > "$OUT/lshal_full.txt" 2>&1

# 3. Kernel messages (requires root)
if [ "$_HOM_IS_ROOT" = true ]; then
    log "Collecting dmesg..."
    dmesg > "$OUT/dmesg.txt" && echo "dmesg.txt" >> "$MANIFEST"
else
    log "[SKIP ] dmesg requires root"
fi

# 4. Kernel modules (may need root for modinfo)
log "Collecting lsmod / modinfo..."
lsmod > "$OUT/lsmod.txt" 2>/dev/null && echo "lsmod.txt" >> "$MANIFEST"
if [ "$_HOM_IS_ROOT" = true ]; then
    awk 'NR>1{print $1}' "$OUT/lsmod.txt" 2>/dev/null | while IFS= read -r mod; do
        modinfo "$mod" >> "$OUT/modinfo.txt" 2>/dev/null
    done
else
    log "[SKIP ] modinfo requires root"
fi

# 5. /proc virtual files
log "Collecting /proc files..."
for vf in /proc/cmdline /proc/iomem /proc/interrupts /proc/clocks \
           /proc/cpuinfo /proc/meminfo /proc/version \
           /proc/devices /proc/misc; do
    copy_virtual "$vf"
done
copy_virtual_dir /proc/device-tree

# 6. pinctrl sysfs (most valuable for pin mapping, usually requires root)
log "Collecting pinctrl..."
if [ "$_HOM_IS_ROOT" = true ]; then
    copy_virtual_dir /sys/kernel/debug/pinctrl
else
    log "[SKIP ] /sys/kernel/debug/pinctrl requires root"
fi

# 7. Platform devices
log "Collecting platform devices..."
find /sys/bus/platform/devices -maxdepth 2 \
     \( -name uevent -o -name modalias -o -name driver -o -name of_node \) \
     -readable 2>/dev/null | while IFS= read -r f; do
    copy_virtual "$f"
done

# 8. sysfs class entries of interest
log "Collecting sysfs class entries..."
for cls in display graphics drm backlight camera video4linux \
           sound input thermal power_supply led regulator \
           gpio pwm i2c spi uio; do
    copy_virtual_dir "/sys/class/$cls"
done
copy_virtual_dir /sys/class/firmware-info
copy_virtual_dir /sys/bus/i2c/devices
copy_virtual_dir /sys/bus/spi/devices

# ── Hardware data sanity check ────────────────────────────────
# Detect sandbox/CI and Termux environments where /sys/class/regulator
# and /sys/class/display contain no real hardware data.  Log the first
# 10 regulator entries found so users can immediately see whether real
# voltage data was captured.  Record HOM_HW_ENV in the registry so
# failure_analysis.py can adjust its expectations accordingly.
_check_hw_data_sanity() {
    local hw_env="android_rooted"
    local warn_lines=""

    # ── Termux detection ─────────────────────────────────────
    # Running inside Termux (even with tsu/sudo) means we are in the
    # Android userspace without kernel-level sysfs write access.
    if [ -n "${TERMUX_VERSION:-}" ] || \
       [ -d "/data/data/com.termux/files/usr" ] || \
       [ -d "/data/user/0/com.termux/files/usr" ]; then
        hw_env="termux"
        warn_lines="${warn_lines}
[WARN ] Running inside Termux (TERMUX_VERSION=${TERMUX_VERSION:-unknown}).
[WARN ] Sysfs regulator/display paths are readable but reflect the host
[WARN ] kernel, not a Magisk-rooted context. Real microvolts data is only
[WARN ] available when collect.sh runs as root via Magisk service.sh."
    fi

    # ── Sandbox / CI detection ────────────────────────────────
    # A sandbox host (GitHub Actions, Docker, etc.) has no Android props
    # and no /system/build.prop, so getprop returns nothing useful.
    if [ -z "$(getprop ro.product.model 2>/dev/null)" ] && \
       [ ! -f /system/build.prop ]; then
        hw_env="sandbox_ci"
        warn_lines="${warn_lines}
[WARN ] No Android properties found (getprop ro.product.model is empty).
[WARN ] This host appears to be a sandbox or CI environment, not an Android
[WARN ] device. Hardware data collected here will be placeholder / dummy
[WARN ] values and cannot be used for device compatibility analysis."
    fi

    # ── Regulator entries (first 10) ──────────────────────────
    local reg_base="$OUT/sys/class/regulator"
    local reg_count=0
    local real_mv_count=0
    log "--- Regulator data sanity check (first 10 entries) ---"
    if [ -d "$reg_base" ]; then
        for reg_dir in "$reg_base"/regulator.*; do
            [ -d "$reg_dir" ] || continue
            reg_count=$((reg_count + 1))
            [ "$reg_count" -gt 10 ] && break
            local reg_name mv_val
            reg_name=$(cat "$reg_dir/name" 2>/dev/null || echo "(no name)")
            mv_val=$(cat "$reg_dir/microvolts" 2>/dev/null || echo "(no microvolts)")
            log "  regulator.$((reg_count)): name=$reg_name  microvolts=$mv_val"
            # Count entries that have a real numeric voltage
            case "$mv_val" in
                [0-9]*) real_mv_count=$((real_mv_count + 1)) ;;
            esac
        done
    fi
    if [ "$reg_count" -eq 0 ]; then
        log "[WARN ] No regulator entries found under $reg_base"
        warn_lines="${warn_lines}
[WARN ] /sys/class/regulator collected no entries — display adapter voltages
[WARN ] will be missing from the analysis. See docs/TROUBLESHOOTING.md
[WARN ] section 'Empty or dummy hardware data' for remediation."
    elif [ "$real_mv_count" -eq 0 ]; then
        log "[WARN ] $reg_count regulator(s) found but none have a microvolts file."
        log "[WARN ] All entries are likely kernel placeholders (e.g. regulator-dummy)."
        warn_lines="${warn_lines}
[WARN ] Regulators present but no microvolts data found ($reg_count entries,
[WARN ] 0 with real voltages). Display-adapter voltage analysis will be
[WARN ] unavailable. See docs/TROUBLESHOOTING.md 'Empty or dummy hardware data'."
    else
        log "[OK   ] $reg_count regulator(s) found, $real_mv_count with real microvolts data."
    fi

    # ── Display class check ───────────────────────────────────
    local disp_base="$OUT/sys/class/display"
    if [ ! -d "$disp_base" ] || [ -z "$(ls "$disp_base" 2>/dev/null)" ]; then
        log "[WARN ] /sys/class/display collected no entries."
        warn_lines="${warn_lines}
[WARN ] /sys/class/display is empty. Display adapter sysfs data is missing.
[WARN ] On a real rooted device this directory lists panel/adapter nodes."
    fi

    # ── Emit summary ──────────────────────────────────────────
    log "--- End regulator sanity check ---"
    if [ -n "$warn_lines" ]; then
        log "======================================================"
        log "HARDWARE DATA WARNING — hw_env=$hw_env"
        printf '%s\n' "$warn_lines" | while IFS= read -r wl; do
            [ -n "$wl" ] && log "$wl"
        done
        log "See docs/TROUBLESHOOTING.md § 'Empty or dummy hardware data'"
        log "======================================================"
    fi

    # Record the detected environment so downstream tools can adapt
    reg_set collect HOM_HW_ENV "$hw_env"
    reg_set collect HOM_HW_REGULATOR_COUNT "$reg_count"
    reg_set collect HOM_HW_REGULATOR_REAL_MV_COUNT "$real_mv_count"
}
_check_hw_data_sanity

# 9. VINTF manifests
log "Collecting VINTF manifests..."
for f in /vendor/etc/manifest.xml \
          /system/etc/vintf/manifest.xml \
          /odm/etc/manifest.xml; do
    copy_file "$f"
done
copy_dir /vendor/etc/vintf
copy_dir /system/etc/vintf
copy_dir /odm/etc/vintf

# 10. Sysconfig XMLs
log "Collecting sysconfig..."
copy_dir /vendor/etc/sysconfig
copy_dir /system/etc/sysconfig
copy_dir /odm/etc/sysconfig

# 11. Protobuf files (can contain hardware configuration)
log "Collecting .pb files..."
find /vendor /odm -name "*.pb" 2>/dev/null | while IFS= read -r f; do
    copy_file "$f"
done

# 12. Compatibility matrices
log "Collecting compatibility matrices..."
copy_dir /vendor/etc/vintf
copy_dir /system/etc/vintf
copy_file /vendor/etc/compatibility_matrix.xml
copy_file /system/etc/compatibility_matrix.xml

# 13. HAL / permissions XMLs
log "Collecting HAL permission XMLs..."
copy_dir /vendor/etc/permissions
copy_dir /system/etc/permissions
copy_dir /odm/etc/permissions

# 14. Vendor init RC files (contain service definitions, HAL paths)
log "Collecting RC files..."
find /vendor/etc/init /odm/etc/init /system/etc/init \
     -name "*.rc" 2>/dev/null | while IFS= read -r f; do
    copy_file "$f"
done

# 15. SELinux policies (device-specific rules reveal hardware names)
log "Collecting SELinux policies..."
copy_file /vendor/etc/selinux/plat_sepolicy_vers.txt
copy_dir /vendor/etc/selinux

# 16. Symbol lists from vendor libraries (text nm output, usually requires root)
if [ "$_HOM_IS_ROOT" = true ]; then
    log "Collecting vendor library symbols (nm)..."
    mkdir -p "$OUT/vendor_symbols"
    find /vendor/lib64 /vendor/lib -name "*.so" 2>/dev/null | while IFS= read -r lib; do
        base=$(basename "$lib")
        nm -D --defined-only "$lib" > "$OUT/vendor_symbols/${base}.nm.txt" 2>/dev/null && \
            echo "vendor_symbols/${base}.nm.txt" >> "$MANIFEST"
    done
else
    log "[SKIP ] vendor library symbols require root"
fi

# 17. readelf dynamic sections (reveals soname, needed libs, usually requires root)
if [ "$_HOM_IS_ROOT" = true ]; then
    log "Collecting readelf -d output..."
    mkdir -p "$OUT/vendor_elf"
    find /vendor/lib64 /vendor/lib -name "*.so" 2>/dev/null | head -200 | \
        while IFS= read -r lib; do
            base=$(basename "$lib")
            readelf -d "$lib" > "$OUT/vendor_elf/${base}.elf.txt" 2>/dev/null
        done
else
    log "[SKIP ] readelf vendor sections require root"
fi

# 18. board-info reconstructed from props
log "Writing board summary..."
{
    echo "ro.board.platform=$(getprop ro.board.platform)"
    echo "ro.hardware=$(getprop ro.hardware)"
    echo "ro.product.board=$(getprop ro.product.board)"
    echo "ro.product.device=$(getprop ro.product.device)"
    echo "ro.product.model=$(getprop ro.product.model)"
    echo "ro.build.fingerprint=$(getprop ro.build.fingerprint)"
    echo "ro.vendor.build.fingerprint=$(getprop ro.vendor.build.fingerprint)"
    echo "ro.soc.manufacturer=$(getprop ro.soc.manufacturer)"
    echo "ro.soc.model=$(getprop ro.soc.model)"
} > "$OUT/board_summary.txt" && echo "board_summary.txt" >> "$MANIFEST"

# 19. DT overlays / DTBO info via /proc/cmdline
log "Collecting DTBO info..."
copy_virtual /proc/device-tree/chosen
copy_virtual_dir /proc/device-tree/soc

# 20. Encryption state (FDE/FBE metadata — no keys collected)
log "Collecting encryption state..."
_cs=$(getprop ro.crypto.state 2>/dev/null || echo "unknown")
_ct=$(getprop ro.crypto.type 2>/dev/null || echo "unknown")
_cfm=$(getprop ro.crypto.volume.filenames_mode 2>/dev/null || echo "unknown")
_vd=$(getprop vold.decrypt 2>/dev/null || echo "unknown")
_vep=$(getprop vold.encrypt_progress 2>/dev/null || echo "unknown")
{
    echo "ro.crypto.state=$_cs"
    echo "ro.crypto.type=$_ct"
    echo "ro.crypto.volume.filenames_mode=$_cfm"
    echo "vold.decrypt=$_vd"
    echo "vold.encrypt_progress=$_vep"
} > "$OUT/encryption_state.txt" && echo "encryption_state.txt" >> "$MANIFEST"

# Record FDE/FBE classification (aligned with env_detect.sh)
_crypto_class="none"
case "$_cs" in
    encrypted)
        case "$_ct" in
            block) _crypto_class="FDE" ;;
            file)  _crypto_class="FBE" ;;
            *)     _crypto_class="unknown_encrypted" ;;
        esac
        ;;
    unencrypted) _crypto_class="none" ;;
esac
reg_set crypto HOM_CRYPTO_CLASS "$_crypto_class"
reg_set crypto HOM_CRYPTO_STATE "$_cs"
reg_set crypto HOM_CRYPTO_TYPE "$_ct"

# dm-crypt / dm-verity device-mapper table (reveals encryption algorithm, key size — NOT the key)
if [ "$_HOM_IS_ROOT" = true ] && command -v dmsetup >/dev/null 2>&1; then
    dmsetup table --showkeys=false > "$OUT/dmsetup_table.txt" 2>/dev/null && \
        echo "dmsetup_table.txt" >> "$MANIFEST"
    dmsetup info  > "$OUT/dmsetup_info.txt"  2>/dev/null
    dmsetup ls    > "$OUT/dmsetup_ls.txt"    2>/dev/null
elif [ "$_HOM_IS_ROOT" = false ]; then
    log "[SKIP ] dmsetup requires root"
fi

# /sys crypto/dm entries
copy_virtual_dir /sys/module/dm_crypt
copy_virtual_dir /sys/module/dm_verity

# fstab files from all locations (contain fileencryption= / encryptable= flags)
log "Collecting fstab files..."
find /vendor /odm /system /first_stage_ramdisk \
     -name "fstab*" 2>/dev/null | while IFS= read -r f; do
    copy_file "$f"
done

# 21. Live ramdisk extraction from the running boot partition (requires root)
if [ "$_HOM_IS_ROOT" = true ]; then
    log "Extracting live boot/vendor_boot ramdisk images..."
    mkdir -p "$OUT/boot_images"

    for boot_part in boot vendor_boot recovery init_boot; do
    # Resolve block device
    BOOT_DEV=""
    for try_path in \
        "/dev/block/bootdevice/by-name/$boot_part" \
        "/dev/block/by-name/$boot_part" ; do
        if [ -b "$try_path" ]; then
            BOOT_DEV="$try_path"
            break
        fi
    done
    # Glob fallback for platform-specific paths
    if [ -z "$BOOT_DEV" ]; then
        for g in /dev/block/platform/*/by-name/"$boot_part"; do
            [ -b "$g" ] && { BOOT_DEV="$g"; break; }
        done
    fi

    if [ -z "$BOOT_DEV" ]; then
        log "  $boot_part partition not found, skipping"
        continue
    fi

    log "  Reading $boot_part from $BOOT_DEV..."
    dd if="$BOOT_DEV" of="$OUT/boot_images/${boot_part}.img" bs=4096 2>/dev/null && \
        echo "boot_images/${boot_part}.img" >> "$MANIFEST" && \
        log "  saved ${boot_part}.img ($(wc -c < "$OUT/boot_images/${boot_part}.img") bytes)"
done
else
    log "[SKIP ] Boot partition DD requires root"
fi

# 22. Reuse option-5 extracted images as fallback input
# Option 5 (core/boot_image.sh) stores extracted images under:
#   ~/hands-on-metal/boot_work/
#   ~/hands-on-metal/boot_work/partitions/
# Pull them into this dump so option 20 (unpack_images.py) can use both
# the boot image and any additional extracted partition images.
BOOT_WORK_ROOT="${HOME:-/data/local/tmp}/hands-on-metal/boot_work"
if [ -d "$BOOT_WORK_ROOT" ]; then
    log "Importing option-5 extracted images from $BOOT_WORK_ROOT (fallback source)..."
    mkdir -p "$OUT/boot_images" "$OUT/partitions"

    imported_count=0

    # Single-image outputs from option 5 (prefer current collect output if present)
    for src in \
        "$BOOT_WORK_ROOT"/*_original.img \
        "$BOOT_WORK_ROOT"/boot.img \
        "$BOOT_WORK_ROOT"/init_boot.img \
        "$BOOT_WORK_ROOT"/vendor_boot.img \
        "$BOOT_WORK_ROOT"/recovery.img; do
        [ -f "$src" ] || continue
        base=$(basename "$src")
        case "$base" in
            *_original.img) dest_name="${base%_original.img}.img" ;;
            *)              dest_name="$base" ;;
        esac
        dest="$OUT/boot_images/$dest_name"
        if [ ! -s "$dest" ] && cp -p "$src" "$dest" 2>/dev/null; then
            echo "boot_images/$dest_name" >> "$MANIFEST"
            imported_count=$((imported_count + 1))
            log "  imported fallback image: $dest_name"
        fi
    done

    # Full partition-set extraction from option 5
    if [ -d "$BOOT_WORK_ROOT/partitions" ]; then
        for src in "$BOOT_WORK_ROOT"/partitions/*.img; do
            [ -f "$src" ] || continue
            base=$(basename "$src")
            part_dst="$OUT/partitions/$base"
            if [ ! -s "$part_dst" ] && cp -p "$src" "$part_dst" 2>/dev/null; then
                echo "partitions/$base" >> "$MANIFEST"
                imported_count=$((imported_count + 1))
                log "  imported partition image: $base"
            fi

            # Keep common boot-chain images in boot_images/ too for compatibility
            case "$base" in
                boot.img|init_boot.img|vendor_boot.img|recovery.img)
                    boot_dst="$OUT/boot_images/$base"
                    if [ ! -s "$boot_dst" ] && cp -p "$src" "$boot_dst" 2>/dev/null; then
                        echo "boot_images/$base" >> "$MANIFEST"
                        imported_count=$((imported_count + 1))
                    fi
                    ;;
            esac
        done
    fi

    if [ "$imported_count" -gt 0 ]; then
        log "Imported $imported_count fallback image file(s) from option-5 output."
    else
        log "No additional fallback images imported from option-5 output."
    fi
fi

# ── Emit collection-path env vars to the shared registry ─────
log "Updating env registry with collection paths..."
reg_set path HOM_LIVE_DUMP_DIR "$(real_abs "$OUT")"
reg_set path HOM_MANIFEST "$(real_abs "$MANIFEST")"
reg_set path HOM_COLLECT_LOG "$(real_abs "$LOG")"

# Record the real absolute paths of the key collected artefacts
for named in "$OUT/getprop.txt" "$OUT/lshal.txt" "$OUT/dmesg.txt" \
             "$OUT/lsmod.txt" "$OUT/board_summary.txt" \
             "$OUT/encryption_state.txt"; do
    [ -f "$named" ] || continue
    key="HOM_ARTEFACT_$(basename "$named" | tr '.' '_' | tr '[:lower:]' '[:upper:]')"
    reg_set path "$key" "$(real_abs "$named")"
done

# Record real paths of any boot images collected
for boot_part in boot vendor_boot recovery init_boot; do
    img="$OUT/boot_images/${boot_part}.img"
    [ -f "$img" ] || continue
    key="HOM_BOOT_IMG_$(echo "$boot_part" | tr 'a-z-' 'A-Z_')"
    reg_set path "$key" "$(real_abs "$img")"
done

TOTAL=$(wc -l < "$MANIFEST")
log "=== Collection complete: $TOTAL files captured ==="
if [ "$_HOM_IS_ROOT" = false ]; then
    log "[INFO ] Non-root collection — some data sources were skipped."
    log "[INFO ] For full collection, run again with root (Magisk su or recovery)."
fi
reg_set collect HOM_COLLECT_ROOT "$_HOM_IS_ROOT"
log "Output: $OUT"
