#!/system/bin/sh
# magisk-module/collect.sh
# ============================================================
# Hands-on-metal — Mode A: Live Root Collection
# Runs on a rooted Android device with Magisk.
# Collects all hardware-relevant data READ-ONLY into
# /sdcard/hands-on-metal/live_dump/ then writes a manifest so
# the host-side pipeline knows what is available.
#
# Safety guarantees:
#   • Never mounts any partition read-write
#   • Never writes outside /sdcard/hands-on-metal/
#   • Skips unreadable paths gracefully
# ============================================================

set -u

OUT=/sdcard/hands-on-metal/live_dump
LOG=$OUT/collect.log
MANIFEST=$OUT/manifest.txt
ENV_REGISTRY=/sdcard/hands-on-metal/env_registry.sh

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
    printf '%s=%s  # cat:%s\n' "$key" "$val" "$cat" >> "$tmp"
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
log "=== hands-on-metal collect.sh start ==="
log "Device: $(getprop ro.product.model)"

# 1. Android properties
log "Collecting getprop..."
getprop > "$OUT/getprop.txt" && echo "getprop.txt" >> "$MANIFEST"

# 2. HAL interfaces
log "Collecting lshal..."
lshal > "$OUT/lshal.txt" 2>&1 && echo "lshal.txt" >> "$MANIFEST"
lshal --types=b,c,l > "$OUT/lshal_full.txt" 2>&1

# 3. Kernel messages
log "Collecting dmesg..."
dmesg > "$OUT/dmesg.txt" && echo "dmesg.txt" >> "$MANIFEST"

# 4. Kernel modules
log "Collecting lsmod / modinfo..."
lsmod > "$OUT/lsmod.txt" && echo "lsmod.txt" >> "$MANIFEST"
lsmod | awk 'NR>1{print $1}' | while IFS= read -r mod; do
    modinfo "$mod" >> "$OUT/modinfo.txt" 2>/dev/null
done

# 5. /proc virtual files
log "Collecting /proc files..."
for vf in /proc/cmdline /proc/iomem /proc/interrupts /proc/clocks \
           /proc/cpuinfo /proc/meminfo /proc/version \
           /proc/devices /proc/misc; do
    copy_virtual "$vf"
done
copy_virtual_dir /proc/device-tree

# 6. pinctrl sysfs (most valuable for pin mapping)
log "Collecting pinctrl..."
copy_virtual_dir /sys/kernel/debug/pinctrl

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

# 16. Symbol lists from vendor libraries (text nm output)
log "Collecting vendor library symbols (nm)..."
mkdir -p "$OUT/vendor_symbols"
find /vendor/lib64 /vendor/lib -name "*.so" 2>/dev/null | while IFS= read -r lib; do
    base=$(basename "$lib")
    nm -D --defined-only "$lib" > "$OUT/vendor_symbols/${base}.nm.txt" 2>/dev/null && \
        echo "vendor_symbols/${base}.nm.txt" >> "$MANIFEST"
done

# 17. readelf dynamic sections (reveals soname, needed libs)
log "Collecting readelf -d output..."
mkdir -p "$OUT/vendor_elf"
find /vendor/lib64 /vendor/lib -name "*.so" 2>/dev/null | head -200 | \
    while IFS= read -r lib; do
        base=$(basename "$lib")
        readelf -d "$lib" > "$OUT/vendor_elf/${base}.elf.txt" 2>/dev/null
    done

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
{
    echo "ro.crypto.state=$(getprop ro.crypto.state)"
    echo "ro.crypto.type=$(getprop ro.crypto.type)"
    echo "ro.crypto.volume.filenames_mode=$(getprop ro.crypto.volume.filenames_mode)"
    echo "vold.decrypt=$(getprop vold.decrypt)"
    echo "vold.encrypt_progress=$(getprop vold.encrypt_progress)"
} > "$OUT/encryption_state.txt" && echo "encryption_state.txt" >> "$MANIFEST"

# dm-crypt / dm-verity device-mapper table (reveals encryption algorithm, key size — NOT the key)
if command -v dmsetup >/dev/null 2>&1; then
    dmsetup table --showkeys=false > "$OUT/dmsetup_table.txt" 2>/dev/null && \
        echo "dmsetup_table.txt" >> "$MANIFEST"
    dmsetup info  > "$OUT/dmsetup_info.txt"  2>/dev/null
    dmsetup ls    > "$OUT/dmsetup_ls.txt"    2>/dev/null
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

# 21. Live ramdisk extraction from the running boot partition
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
        for g in /dev/block/platform/*/by-name/$boot_part; do
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

# done

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
    key="HOM_ARTEFACT_$(basename "$named" | tr '.' '_' | tr 'a-z' 'A-Z')"
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
log "Output: $OUT"
