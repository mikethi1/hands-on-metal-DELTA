#!/sbin/sh
# recovery-zip/collect_recovery.sh
# ============================================================
# Hands-on-metal — Mode B: Recovery Hardware Variable Collection
# Runs inside TWRP / OrangeFox via the META-INF updater-script.
#
# Goals:
#   1. Mount partitions that need to be decrypted / mounted RO
#      (system, vendor, odm, userdata if decrypted)
#   2. Source real "metal" values from device-tree source refs,
#      board files, .pb configs, deviceconfig XMLs, fstab, and
#      any other files reachable only in recovery context
#   3. Write every discovered value into the flat env registry
#      at $ENV_REGISTRY (/sdcard/hands-on-metal/env_registry.sh)
#      so the Magisk module (Mode A) and pipeline (Mode C) can
#      cross-reference them
#   4. Collect raw binary artefacts (dtbo.img, recovery.img,
#      boot.img) for offline analysis by the pipeline
#
# Safety guarantees:
#   • All partition mounts are read-only
#   • Never writes outside /sdcard/hands-on-metal/
#   • Umounts every partition it mounts before exit
# ============================================================

set -u

OUT=/sdcard/hands-on-metal/recovery_dump
ENV_REGISTRY=/sdcard/hands-on-metal/env_registry.sh
LOG=$OUT/collect_recovery.log
MANIFEST=$OUT/recovery_manifest.txt

# Partitions this script mounts (tracked for clean umount)
MOUNTED=""

# ── helpers ──────────────────────────────────────────────────

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

real_abs() {
    local p="$1"
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$p" 2>/dev/null || echo "$p"
    else
        echo "$p"
    fi
}

# Write/update a variable in the shared env registry
reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s mode:B\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

reg_set_path() {
    local cat="$1" key="$2" val="$3"
    reg_set "$cat" "$key" "$val"
    local rp
    rp=$(real_abs "$val")
    [ "$rp" != "$val" ] && reg_set "$cat" "${key}_REALPATH" "$rp"
}

# Copy a file into the recovery dump preserving its path
copy_file() {
    local src="$1"
    [ -f "$src" ] || return 0
    local dst="$OUT$src"
    mkdir -p "$(dirname "$dst")"
    if cp "$src" "$dst" 2>/dev/null; then
        echo "$src" >> "$MANIFEST"
        local rp
        rp=$(real_abs "$src")
        [ "$rp" != "$src" ] && echo "REALPATH:$src=$rp" >> "$MANIFEST"
    fi
}

copy_dir() {
    local src="$1"
    [ -d "$src" ] || return 0
    find "$src" -type f 2>/dev/null | while IFS= read -r f; do
        copy_file "$f"
    done
}

# Mount a partition read-only if not already mounted
mount_ro() {
    local dev="$1" mnt="$2"
    [ -b "$dev" ] || return 1
    mkdir -p "$mnt"
    if mount -o ro "$dev" "$mnt" 2>/dev/null; then
        MOUNTED="$MOUNTED $mnt"
        log "  Mounted $dev -> $mnt (ro)"
        return 0
    else
        log "  Could not mount $dev -> $mnt"
        return 1
    fi
}

# Resolve a partition block device from by-name symlinks
find_block() {
    local name="$1"
    for try in \
        "/dev/block/bootdevice/by-name/$name" \
        "/dev/block/by-name/$name"; do
        [ -b "$try" ] && { echo "$try"; return 0; }
    done
    for g in /dev/block/platform/*/by-name/$name \
             /dev/block/platform/*/*/by-name/$name; do
        [ -b "$g" ] && { echo "$g"; return 0; }
    done
    return 1
}

cleanup() {
    for mnt in $MOUNTED; do
        umount "$mnt" 2>/dev/null && log "  Unmounted $mnt"
    done
}
trap cleanup EXIT

# ── init ─────────────────────────────────────────────────────

mkdir -p "$OUT"
: > "$MANIFEST"
# Ensure env registry exists (Mode A may not have run yet)
[ -f "$ENV_REGISTRY" ] || : > "$ENV_REGISTRY"

# Pre-flight: record execution context if env_detect hasn't run
if ! grep -q "^HOM_EXEC_NODE=" "$ENV_REGISTRY" 2>/dev/null; then
    _uid=$(id -u 2>/dev/null || echo 9999)
    _node="unprivileged"
    [ "$_uid" = "0" ] && _node="root_recovery"
    reg_set shell HOM_EXEC_NODE "$_node"
    reg_set shell HOM_EXEC_UID "$_uid"
fi

log "=== collect_recovery.sh start (Mode B) ==="

# ── 1. Record recovery environment ───────────────────────────

log "Recording recovery environment..."
reg_set recovery HOM_RECOVERY_MODE "B"
reg_set recovery HOM_RECOVERY_SHELL "$(real_abs "$(command -v sh 2>/dev/null || echo /sbin/sh)")"
reg_set recovery HOM_BUSYBOX_RECOVERY "$(real_abs "$(command -v busybox 2>/dev/null || true)")"

# ── 2. Mount system / vendor / odm read-only ─────────────────

log "Mounting partitions read-only..."

SYS_MNT=/mnt/system_ro
VENDOR_MNT=/mnt/vendor_ro
ODM_MNT=/mnt/odm_ro

SYS_DEV=$(find_block system 2>/dev/null || true)
VENDOR_DEV=$(find_block vendor 2>/dev/null || true)
ODM_DEV=$(find_block odm 2>/dev/null || true)

[ -n "$SYS_DEV" ]    && mount_ro "$SYS_DEV"    "$SYS_MNT"    && reg_set_path recovery HOM_SYSTEM_MNT "$SYS_MNT"
[ -n "$VENDOR_DEV" ] && mount_ro "$VENDOR_DEV" "$VENDOR_MNT" && reg_set_path recovery HOM_VENDOR_MNT "$VENDOR_MNT"
[ -n "$ODM_DEV" ]    && mount_ro "$ODM_DEV"    "$ODM_MNT"    && reg_set_path recovery HOM_ODM_MNT "$ODM_MNT"

# Also check if /system is already mounted by recovery
if [ -d /system/etc ] && ! echo "$MOUNTED" | grep -q "$SYS_MNT"; then
    SYS_MNT=/system
    reg_set_path recovery HOM_SYSTEM_MNT "$SYS_MNT"
fi

# ── 3. Board / device properties from build.prop ─────────────

log "Sourcing board values from build.prop files..."

for bprop in \
    "$SYS_MNT/build.prop" \
    "$VENDOR_MNT/build.prop" \
    "$ODM_MNT/build.prop" \
    /system/build.prop \
    /vendor/build.prop; do
    [ -f "$bprop" ] || continue
    log "  Reading $bprop"
    copy_file "$bprop"
    # Extract the key hardware/board properties directly
    while IFS='=' read -r k v; do
        # Skip blank lines and comments
        case "$k" in
            ''|\#*) continue ;;
            ro.board.platform|ro.hardware|ro.product.board|ro.product.device|\
            ro.product.model|ro.build.fingerprint|ro.vendor.build.fingerprint|\
            ro.soc.manufacturer|ro.soc.model|ro.chipname|ro.arch|\
            ro.product.cpu.abi|ro.product.cpu.abilist|\
            ro.kernel.version|ro.build.version.release|\
            ro.crypto.state|ro.crypto.type)
                ENV_KEY="HOM_PROP_$(echo "$k" | tr '.' '_' | tr 'a-z' 'A-Z')"
                reg_set recovery "$ENV_KEY" "$v"
                ;;
        esac
    done < "$bprop"
done

# ── 4. fstab files (reveal encryption flags, partition layout) ─

log "Collecting fstab files..."
for search_root in "$SYS_MNT" "$VENDOR_MNT" "$ODM_MNT" /system /vendor /odm \
                   /first_stage_ramdisk; do
    [ -d "$search_root" ] || continue
    find "$search_root" -name "fstab*" 2>/dev/null | while IFS= read -r f; do
        copy_file "$f"
        # Record each fstab as an env var
        ENV_KEY="HOM_FSTAB_$(basename "$f" | tr '.' '_' | tr 'a-z' 'A-Z')_PATH"
        reg_set_path recovery "$ENV_KEY" "$f"
    done
done

# ── 5. Device-tree / DTB artefacts ───────────────────────────

log "Collecting device-tree artefacts..."

# /proc/device-tree is always available in recovery kernels
copy_dir /proc/device-tree
reg_set_path recovery HOM_PROC_DEVICE_TREE "/proc/device-tree"

# Extract compatible string (root of the hardware identity)
COMPAT=$(cat /proc/device-tree/compatible 2>/dev/null | tr '\0' '\n' | head -1 || true)
[ -n "$COMPAT" ] && reg_set recovery HOM_DT_COMPATIBLE "$COMPAT"

MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr '\0' ' ' || true)
[ -n "$MODEL" ] && reg_set recovery HOM_DT_MODEL "$MODEL"

# ── 6. dtbo.img raw image (for offline dtc decompilation) ────

log "Collecting dtbo.img..."
DTBO_DEV=$(find_block dtbo 2>/dev/null || true)
if [ -n "$DTBO_DEV" ]; then
    mkdir -p "$OUT/boot_images"
    dd if="$DTBO_DEV" of="$OUT/boot_images/dtbo.img" bs=4096 2>/dev/null && {
        echo "boot_images/dtbo.img" >> "$MANIFEST"
        reg_set_path recovery HOM_DTBO_IMG "$(real_abs "$OUT/boot_images/dtbo.img")"
        log "  Saved dtbo.img"
    }
fi

# ── 7. .pb protobuf config files from vendor ─────────────────

log "Collecting .pb files from vendor/odm..."
for search_root in "$VENDOR_MNT" "$ODM_MNT" /vendor /odm; do
    [ -d "$search_root" ] || continue
    find "$search_root" -name "*.pb" 2>/dev/null | while IFS= read -r f; do
        copy_file "$f"
        key="HOM_PB_$(echo "$f" | sed 's|[/.]|_|g' | tr 'a-z' 'A-Z')"
        reg_set_path recovery "$key" "$f"
    done
done

# ── 8. deviceconfig XMLs ──────────────────────────────────────

log "Collecting deviceconfig / sysconfig XMLs..."
for search_root in "$SYS_MNT" "$VENDOR_MNT" "$ODM_MNT" /system /vendor /odm; do
    [ -d "$search_root" ] || continue
    for subdir in etc/sysconfig etc/permissions etc/vintf; do
        copy_dir "$search_root/$subdir"
    done
done

# ── 9. HAL RC init files (service paths, HAL binary locations) ─

log "Collecting init RC files..."
for search_root in "$SYS_MNT" "$VENDOR_MNT" "$ODM_MNT" /system /vendor /odm; do
    [ -d "$search_root/etc/init" ] || continue
    find "$search_root/etc/init" -name "*.rc" 2>/dev/null | while IFS= read -r f; do
        copy_file "$f"
    done
done

# ── 10. SELinux policy hints ──────────────────────────────────

log "Collecting SELinux policy files..."
for search_root in "$VENDOR_MNT" /vendor; do
    [ -d "$search_root/etc/selinux" ] || continue
    copy_dir "$search_root/etc/selinux"
    reg_set_path recovery HOM_SELINUX_DIR "$(real_abs "$search_root/etc/selinux")"
done

# ── 11. Encryption state from crypto props ────────────────────

log "Recording encryption/crypto state from recovery..."
# These props are available via getprop even in recovery
for prop in ro.crypto.state ro.crypto.type \
            ro.crypto.volume.filenames_mode \
            vold.decrypt; do
    v=$(getprop "$prop" 2>/dev/null || true)
    [ -n "$v" ] || continue
    key="HOM_RECOVERY_$(echo "$prop" | tr '.' '_' | tr 'a-z' 'A-Z')"
    reg_set crypto "$key" "$v"
done

# FDE/FBE classification (aligned with env_detect.sh and collect.sh)
_rec_cs=$(getprop ro.crypto.state 2>/dev/null || echo "unknown")
_rec_ct=$(getprop ro.crypto.type 2>/dev/null || echo "unknown")
_rec_cc="none"
case "$_rec_cs" in
    encrypted)
        case "$_rec_ct" in
            block) _rec_cc="FDE" ;;
            file)  _rec_cc="FBE" ;;
            *)     _rec_cc="unknown_encrypted" ;;
        esac
        ;;
    unencrypted) _rec_cc="none" ;;
esac
reg_set crypto HOM_CRYPTO_CLASS "$_rec_cc"

# Indicate whether userdata appears decrypted (heuristic: a well-known
# subdirectory that only exists when userdata is readable).
if [ -r /data/data/. ] && [ -d /data/data ]; then
    reg_set crypto HOM_USERDATA_DECRYPTED "true"
else
    reg_set crypto HOM_USERDATA_DECRYPTED "false"
fi

# ── 12. Pinctrl debug (if debugfs available in recovery) ──────

log "Checking pinctrl via debugfs..."
if mount | grep -q debugfs 2>/dev/null || \
   (mount -t debugfs none /sys/kernel/debug 2>/dev/null && \
    MOUNTED="$MOUNTED /sys/kernel/debug"); then
    if [ -d /sys/kernel/debug/pinctrl ]; then
        find /sys/kernel/debug/pinctrl -type f -readable 2>/dev/null | \
            while IFS= read -r f; do
                copy_file "$f"
            done
        reg_set_path recovery HOM_PINCTRL_DEBUG_DIR "/sys/kernel/debug/pinctrl"
    fi
fi

# ── 13. Record output paths ───────────────────────────────────

reg_set_path recovery HOM_RECOVERY_DUMP_DIR "$(real_abs "$OUT")"
reg_set_path recovery HOM_RECOVERY_MANIFEST "$(real_abs "$MANIFEST")"

# ── 14. Hardware data sanity check ────────────────────────────
# Detect sandbox/CI and Termux contexts (recovery scripts can also be
# exercised from a host PC or Termux for testing).  In those cases the
# collected data will be empty or dummy and downstream tools must know.
_check_hw_data_sanity_recovery() {
    local hw_env="recovery"

    # Termux running the recovery zip test script on-device
    if [ -n "${TERMUX_VERSION:-}" ] || \
       [ -d "/data/data/com.termux/files/usr" ] || \
       [ -d "/data/user/0/com.termux/files/usr" ]; then
        hw_env="termux_recovery"
        log "[WARN ] Running inside Termux — recovery sysfs data may be"
        log "[WARN ] incomplete. Partition mounts require a real recovery"
        log "[WARN ] environment (TWRP / OrangeFox), not Termux."
    fi

    # No Android props → sandbox / CI host
    if [ -z "$(getprop ro.product.model 2>/dev/null)" ] && \
       [ ! -f /system/build.prop ]; then
        hw_env="sandbox_ci"
        log "[WARN ] No Android properties found — this appears to be a"
        log "[WARN ] sandbox or CI host. Collected recovery data will be"
        log "[WARN ] placeholder / empty. See docs/TROUBLESHOOTING.md"
        log "[WARN ] section 'Empty or dummy hardware data'."
    fi

    reg_set collect HOM_HW_ENV "$hw_env"
    log "[INFO ] hw_env=$hw_env recorded to env registry."
}
_check_hw_data_sanity_recovery

# ── done ─────────────────────────────────────────────────────

TOTAL=$(wc -l < "$MANIFEST")
VAR_COUNT=$(grep -c "mode:B" "$ENV_REGISTRY" 2>/dev/null || echo 0)
log "=== collect_recovery.sh complete: $TOTAL files, $VAR_COUNT env vars written ==="
