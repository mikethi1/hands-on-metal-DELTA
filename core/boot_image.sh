#!/system/bin/sh
# core/boot_image.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Guided boot/init_boot image acquisition and validation.
#
# Acquisition strategy (first match wins):
#
#   1. **Root / block-device path** — if the running shell has
#      root access (uid 0) and the target partition's block
#      device is reachable, DD-copy the live partition image.
#
#   2. **Pre-placed / backup image** — scan well-known locations:
#      - boot_work directory and /sdcard/Download
#      - Magisk stock boot backup (/data/adb/magisk/stock_boot.img)
#        NOTE: The Magisk GitHub repo does NOT host factory images.
#        Magisk saves the original unpatched boot image here when
#        it patches.  This is the best source for re-patching or
#        recovering root if live patching fails.
#      - TWRP / OrangeFox / PBRP / SHRP / RedWolf Nandroid backups
#        (.emmc.win raw dumps, including .gz and .lz4 compressed)
#      - CWM / Nandroid backup directories
#
#   3. **Google factory image download** — for Google Pixel
#      devices whose codename is in the partition index, offer
#      to download the factory image ZIP and extract the
#      matching boot.img or init_boot.img automatically.
#
#   3b. **GKI generic boot image** (Android 12+ / API 31+) —
#       for ANY device using the Generic Kernel Image (GKI) format,
#       Google publishes prebuilt generic boot images at ci.android.com.
#       The device's kernel version is matched to the correct AOSP
#       GKI branch (5.10, 5.15, 6.1, 6.6, 6.12).
#       Ref: https://source.android.com/docs/core/architecture/partitions/generic-boot
#
#   3c. **OEM-specific guidance** — for non-Google devices, show
#       download links for OEM firmware (Samsung/Xiaomi/OnePlus/
#       Motorola/ASUS/Sony) and payload.bin extraction instructions.
#
#   4. **User-guided manual path** — prompt the user to supply
#      a path to a block device or image file.
#
# Boot vs init_boot:
#   • API < 33 or devices without an init_boot partition →
#     patch the *boot* partition.
#   • API ≥ 33 with init_boot present → patch *init_boot*.
#   The script reads HOM_DEV_BOOT_PART (set by device_profile.sh)
#   and adjusts automatically.
#
# Self-contained dependency checks:
#   Before any work, the script verifies that the minimal set of
#   tools it needs (dd, cp, etc.) is available and reports
#   missing optional tools (curl, unzip) that would limit
#   certain acquisition paths.
#
# Requires: logging.sh, ux.sh sourced first.
#           device_profile.sh must have run (HOM_DEV_* variables).
#
# Outputs written to ENV_REGISTRY:
#   HOM_BOOT_IMG_PATH       — path to the local copy of the image
#   HOM_BOOT_IMG_SHA256     — SHA-256 of the unpatched image
#   HOM_BOOT_PART_SRC       — source the image was obtained from
#   HOM_BOOT_IMG_METHOD     — how the image was acquired
#                              (root_dd | magisk_stock_backup | recovery_backup |
#                               nandroid_backup | pre_placed | factory_download |
#                               gki_download | user_prompt)
# ============================================================

# shellcheck disable=SC2034  # consumed by core/logging.sh when sourced
SCRIPT_NAME="boot_image"

OUT="${OUT:-$HOME/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
BOOT_WORK_DIR="$OUT/boot_work"
OPTION5_PARTITIONS_DIR="${OPTION5_PARTITIONS_DIR:-$BOOT_WORK_DIR/partitions}"
_HOM_RESOLVED_ROOT="${REPO_ROOT:-${MODPATH:-}}"
if [ -n "$_HOM_RESOLVED_ROOT" ]; then
    PARTITION_INDEX="${PARTITION_INDEX:-$_HOM_RESOLVED_ROOT/build/partition_index.json}"
else
    case "$0" in
        */*) _HOM_SCRIPT_RESOLVED_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" ;;
        *)   _HOM_SCRIPT_RESOLVED_ROOT="${PWD:-.}" ;;
    esac
    PARTITION_INDEX="${PARTITION_INDEX:-$_HOM_SCRIPT_RESOLVED_ROOT/build/partition_index.json}"
fi

# Portable temp directory (Termux sets $TMPDIR; fallback is $HOME/tmp)
_TMP="${TMPDIR:-${HOME:-.}/tmp}"

# ── helpers ───────────────────────────────────────────────────

_reg_get() {
    grep "^${1}=" "$ENV_REGISTRY" 2>/dev/null | \
        cut -d= -f2- | sed 's/^"//;s/"[[:space:]].*//'
}

_reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        log_warn "sha256sum/openssl not available — skipping checksum"
        echo "UNAVAILABLE"
    fi
}

_find_block() {
    local name="$1"
    for try in \
        "/dev/block/bootdevice/by-name/$name" \
        "/dev/block/by-name/$name"; do
        [ -b "$try" ] && { echo "$try"; return 0; }
    done
    for g in /dev/block/platform/*/by-name/"$name" \
             /dev/block/platform/*/*/by-name/"$name"; do
        [ -b "$g" ] && { echo "$g"; return 0; }
    done
    return 1
}

# Validate that a file starts with Android boot image magic.
# Supports: ANDROID! (boot/recovery), VNDRBOOT (vendor_boot)
_validate_boot_magic() {
    local file="$1"
    [ -f "$file" ] || { log_error "validate: file not found: $file"; return 1; }
    local magic
    magic=$(dd if="$file" bs=1 count=8 2>/dev/null | cat)
    case "$magic" in
        ANDROID!) log_info "Boot image magic: ANDROID! (standard boot)"; return 0 ;;
        VNDRBOOT) log_info "Boot image magic: VNDRBOOT (vendor_boot)"; return 0 ;;
        *)
            log_warn "Unexpected magic bytes in image (not a standard Android boot image)"
            log_warn "First 8 bytes: $(dd if="$file" bs=1 count=8 2>/dev/null | od -A n -t x1 | tr -d ' \n')"
            return 1
            ;;
    esac
}

# Heuristic: detect whether a boot/init_boot image already contains
# Kali NetHunter (or another Kali chroot) init artifacts in its
# ramdisk.  A positive result means the user has previously customised
# this image; Magisk patching is safe (magiskboot overlays on top of
# the existing ramdisk and preserves arbitrary additions), but we want
# the user to know we are about to patch their custom image — not a
# stock one — so the NetHunter chroot keeps booting after flash.
#
# Echoes "yes" if NetHunter-style markers are found, "no" otherwise.
# Uses only `grep -a` so it works under busybox / toybox without
# requiring an unpacked ramdisk.
_detect_kali_nethunter_in_image() {
    local file="$1"
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        echo "no"
        return 0
    fi
    # Markers that don't appear in stock AOSP boot/init_boot images
    # but do appear in NetHunter-modified ramdisks (chroot launcher,
    # custom init.rc, kernel cmdline references).
    if grep -a -E -q \
            -e 'init\.nethunter\.rc' \
            -e '/data/local/nhsystem' \
            -e 'kalifs' \
            -e 'NetHunter' \
            "$file" 2>/dev/null; then
        echo "yes"
        return 0
    fi
    echo "no"
}

# Return 0 if we are running as root (uid 0).
_have_root() {
    local uid
    uid=$(id -u 2>/dev/null || echo 9999)
    [ "$uid" = "0" ]
}

# Check whether the essential tool $1 is available.
_has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Return 0 if $1 appears as a whole line in the newline-separated list $2.
_in_list() {
    printf '%s\n' "$2" | grep -qxF "$1" 2>/dev/null
}

# Heuristic: try to extract a build ID string from a raw boot/init_boot image.
# Scans the binary for common Android build property patterns embedded in the
# image (works best on LZ4-legacy or uncompressed ramdisks; may return empty
# for GZip-compressed ramdisks).
# Echoes the build ID (e.g. "CP1A.260305.018"), or empty if not detectable.
_extract_build_id_from_image() {
    local file="$1" result=""
    [ -f "$file" ] || { echo ""; return 0; }

    # 1. ro.build.id=VALUE (prop.default / default.prop in the ramdisk)
    result=$(grep -a -m1 -o 'ro\.build\.id=[^[:space:][:cntrl:]/]*' \
        "$file" 2>/dev/null | sed 's/ro\.build\.id=//' || true)
    [ -n "$result" ] && { echo "$result"; return 0; }

    # 2. ro.build.fingerprint=brand/product/device:ver/BUILD_ID/incr:type/keys
    #    The build ID is field 4 when split on '/'.
    result=$(grep -a -m1 -o 'ro\.build\.fingerprint=[^[:space:][:cntrl:]]*' \
        "$file" 2>/dev/null | cut -d/ -f4 || true)
    [ -n "$result" ] && { echo "$result"; return 0; }

    # 3. Kernel command line: androidboot.buildid=VALUE
    result=$(grep -a -m1 -o 'androidboot\.buildid=[^[:space:]]*' \
        "$file" 2>/dev/null | sed 's/androidboot\.buildid=//' || true)
    [ -n "$result" ] && { echo "$result"; return 0; }

    echo ""
}

# ── dependency self-check ─────────────────────────────────────
# Validates that the tools THIS script needs are present.
# Logs missing optional tools so acquisition paths that depend
# on them can be skipped gracefully.

_boot_image_check_deps() {
    local missing_required="" missing_optional=""

    # Required tools: dd (block copy), cp (file copy)
    for cmd in dd cp; do
        _has_cmd "$cmd" || missing_required="$missing_required $cmd"
    done

    if [ -n "$missing_required" ]; then
        log_error "Missing required tools:$missing_required"
        ux_abort "Cannot proceed — missing required tools:$missing_required"
    fi

    # Optional tools — their absence limits specific paths
    for cmd in curl unzip; do
        _has_cmd "$cmd" || missing_optional="$missing_optional $cmd"
    done

    if [ -n "$missing_optional" ]; then
        log_warn "Missing optional tools:$missing_optional — some acquisition paths will be unavailable"
        ux_print "  ⚠  Missing optional tools:$missing_optional"
    fi

    _reg_set boot HOM_BOOT_IMG_HAS_CURL  "$(_has_cmd curl  && echo true || echo false)"
    _reg_set boot HOM_BOOT_IMG_HAS_UNZIP "$(_has_cmd unzip && echo true || echo false)"
}

# ── pre-placed image scanner ─────────────────────────────────
# Scans well-known download, working, and backup directories for
# an image file whose name matches the target partition.
#
# Search order (first match wins):
#   1. Boot work directory and standard download locations
#   2. Magisk stock boot backup (/data/adb/magisk/stock_boot*.img)
#      NOTE: The Magisk GitHub repo (topjohnwu/Magisk) does NOT
#      host factory boot images — only the Magisk app and tools.
#      However, when Magisk patches a boot image it saves the
#      original unpatched copy at /data/adb/magisk/stock_boot.img.
#      This requires root to read /data/adb/.
#   3. TWRP / OrangeFox / PBRP / SHRP / RedWolf backup folders
#      (.emmc.win files are raw dd dumps — same format as .img)
#   4. CWM / Nandroid backup folders
#
# TWRP compressed backups (.win.gz / .win.lz4) are also found.
# Decompression is handled by the caller in run_boot_image_acquire.

_find_pre_placed_image() {
    # $1 = boot partition name (boot / init_boot)
    # $2 = (optional) newline-separated list of paths already seen/declined — skipped
    local boot_part="$1"
    local excluded="${2:-}"
    local candidate

    # ── Direct image files in standard locations ──────────────
    for candidate in \
        "$BOOT_WORK_DIR/${boot_part}_original.img" \
        "$BOOT_WORK_DIR/${boot_part}.img" \
        "/sdcard/Download/${boot_part}.img" \
        "/sdcard/Download/${boot_part}_original.img" \
        "/sdcard/${boot_part}.img" \
        "/data/local/tmp/${boot_part}.img"; do
        if [ -f "$candidate" ] && [ -s "$candidate" ]; then
            _in_list "$candidate" "$excluded" && continue
            echo "$candidate"
            return 0
        fi
    done

    # ── Magisk stock boot backup ──────────────────────────────
    # Magisk saves the original unpatched boot image when it patches.
    # This is the BEST source for re-patching or recovery if a live
    # Magisk patch fails — you can patch this backup offline and
    # flash it via fastboot (Mode C2) to regain root.
    for candidate in \
        "/data/adb/magisk/stock_boot.img" \
        "/data/adb/magisk/stock_boot_${boot_part}.img"; do
        if [ -f "$candidate" ] && [ -s "$candidate" ]; then
            _in_list "$candidate" "$excluded" && continue
            log_info "Found Magisk stock boot backup: $candidate"
            echo "$candidate"
            return 0
        fi
    done

    # ── TWRP / OrangeFox / PBRP / SHRP / RedWolf backups ─────
    # Custom recovery Nandroid backups store raw partition dumps.
    # TWRP naming: BACKUPS/<serial>/<YYYY-MM-DD--HH-MM-SS>/<part>.emmc.win
    # The .win files are raw dd dumps (identical to .img).
    # May be compressed: .win.gz (gzip) or .win.lz4 (lz4).
    #
    # These backup images can be used to RECOVER ROOT ACCESS even
    # if live patching fails: extract stock boot → patch with Magisk
    # on another device or PC → flash via fastboot (Mode C2).
    local bdir
    for bdir in \
        /sdcard/TWRP/BACKUPS \
        /sdcard/Fox/BACKUPS \
        /sdcard/OrangeFox/BACKUPS \
        /sdcard/PBRP/BACKUPS \
        /sdcard/SHRP/BACKUPS \
        /sdcard/RedWolf/BACKUPS; do
        [ -d "$bdir" ] 2>/dev/null || continue
        # Uncompressed .win (preferred)
        for candidate in "$bdir"/*/*/"${boot_part}.emmc.win"; do
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                _in_list "$candidate" "$excluded" && continue
                log_info "Found TWRP backup boot image: $candidate"
                echo "$candidate"
                return 0
            fi
        done
        # Gzip compressed .win.gz
        for candidate in "$bdir"/*/*/"${boot_part}.emmc.win.gz"; do
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                _in_list "$candidate" "$excluded" && continue
                log_info "Found compressed TWRP backup: $candidate (gzip)"
                echo "$candidate"
                return 0
            fi
        done
        # LZ4 compressed .win.lz4
        for candidate in "$bdir"/*/*/"${boot_part}.emmc.win.lz4"; do
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                _in_list "$candidate" "$excluded" && continue
                log_info "Found compressed TWRP backup: $candidate (lz4)"
                echo "$candidate"
                return 0
            fi
        done
        # Some recoveries use plain .img naming
        for candidate in "$bdir"/*/*/"${boot_part}.img"; do
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                _in_list "$candidate" "$excluded" && continue
                log_info "Found recovery backup boot image: $candidate"
                echo "$candidate"
                return 0
            fi
        done
    done

    # ── CWM / Nandroid backup folders ─────────────────────────
    for bdir in \
        /sdcard/clockworkmod/backup \
        /sdcard/nandroid; do
        [ -d "$bdir" ] 2>/dev/null || continue
        for candidate in "$bdir"/*/"${boot_part}.img"; do
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                _in_list "$candidate" "$excluded" && continue
                log_info "Found CWM/Nandroid backup: $candidate"
                echo "$candidate"
                return 0
            fi
        done
    done

    return 1
}

# ── GKI (Generic Kernel Image) detection ─────────────────────
# Android 12+ devices with GKI use a standardized boot image
# format.  Google publishes prebuilt GKI boot images at
# ci.android.com for every kernel version (5.10, 5.15, 6.1, 6.6,
# 6.12).  These can be used on ANY GKI-compatible device —
# not just Pixels.
#
# Reference: https://source.android.com/docs/core/architecture/partitions/generic-boot
#
# GKI version mapping:
#   Android 12 (API 31) → kernel 5.10
#   Android 13 (API 33) → kernel 5.10 or 5.15, init_boot partition introduced
#   Android 14 (API 34) → kernel 5.15 or 6.1
#   Android 15 (API 35) → kernel 6.1 or 6.6
#   Android 16 (API 36) → kernel 6.6 or 6.12
#
# When GKI is in use, the boot partition contains only the
# standardized kernel (no vendor ramdisk), so a generic boot.img
# matching the kernel branch can serve as a base for Magisk
# patching.  For devices with init_boot (API 33+), the generic
# ramdisk is in init_boot and that is what Magisk patches.

_is_gki_device() {
    local api_level
    api_level=$(getprop ro.build.version.sdk 2>/dev/null || echo 0)
    # GKI was introduced with Android 12 (API 31)
    [ "$api_level" -ge 31 ] 2>/dev/null
}

# Determine the GKI kernel branch for the running device.
# Returns the ci.android.com branch name, e.g. "aosp_kernel-common-android14-6.1"
_gki_branch_for_device() {
    local api_level kernel_ver branch=""
    api_level=$(getprop ro.build.version.sdk 2>/dev/null || echo 0)
    kernel_ver=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' || echo "")

    # Map kernel version to the correct AOSP GKI branch
    case "$kernel_ver" in
        5.10)
            if [ "$api_level" -ge 33 ]; then
                branch="aosp_kernel-common-android13-5.10"
            else
                branch="aosp_kernel-common-android12-5.10"
            fi
            ;;
        5.15)
            if [ "$api_level" -ge 34 ]; then
                branch="aosp_kernel-common-android14-5.15"
            else
                branch="aosp_kernel-common-android13-5.15"
            fi
            ;;
        6.1)  branch="aosp_kernel-common-android14-6.1" ;;
        6.6)  branch="aosp_kernel-common-android15-6.6" ;;
        6.12) branch="aosp_kernel-common-android16-6.12" ;;
        *)
            # Unknown kernel version — cannot determine GKI branch
            log_info "Kernel version $kernel_ver does not map to a known GKI branch"
            return 1
            ;;
    esac

    echo "$branch"
}

# Download a GKI boot image from ci.android.com.
# This works for ANY Android 12+ device using GKI — not just Pixels.
#
# ci.android.com artifact URL pattern:
#   https://ci.android.com/builds/submitted/<build_id>/<target>/latest/boot.img
#
# Since the CI build IDs change with each release, this function
# provides the user with the correct branch URL and instructions
# to download the matching boot.img artifact manually.  For
# automated download, the AOSP download_from_ci script can be used:
#   https://android.googlesource.com/kernel/build/+/refs/heads/main/gki/download_from_ci

_offer_gki_download() {
    local boot_part="$1" branch="$2"

    ux_print ""
    ux_print "  ┌──────────────────────────────────────────────────────┐"
    ux_print "  │  GKI Generic Boot Image — works on any GKI device   │"
    ux_print "  └──────────────────────────────────────────────────────┘"
    ux_print ""
    ux_print "  This device runs a GKI-compatible kernel."
    ux_print "  Google publishes prebuilt generic boot images for every"
    ux_print "  GKI kernel version.  These work on ANY device using GKI"
    ux_print "  — not just Pixels."
    ux_print ""
    ux_print "  GKI branch for this device: $branch"
    ux_print "  Kernel:  $(uname -r 2>/dev/null || echo unknown)"
    ux_print "  Android: $(getprop ro.build.version.release 2>/dev/null || echo unknown) (API $(getprop ro.build.version.sdk 2>/dev/null || echo unknown))"
    ux_print ""
    ux_print "  Download the matching boot.img from:"
    ux_print "    https://ci.android.com/builds/branches/$branch/grid"
    ux_print ""
    ux_print "  Steps:"
    ux_print "    1. Open the URL above in a browser"
    ux_print "    2. Click the latest green build → Artifacts tab"
    ux_print "    3. Download boot.img (or boot-gz.img)"
    ux_print "    4. Push to device:"
    ux_print "       adb push boot.img /sdcard/Download/"
    ux_print "    5. Re-run this script"
    ux_print ""

    if [ "$boot_part" = "init_boot" ]; then
        ux_print "  NOTE: This device uses init_boot (Android 13+)."
        ux_print "  Download init_boot.img instead of boot.img from the artifacts."
        ux_print ""
    fi

    ux_print "  For automated download, use AOSP's download_from_ci script:"
    ux_print "    https://android.googlesource.com/kernel/build/+/refs/heads/main/gki/download_from_ci"
    ux_print ""

    # If curl is available, try to let the user paste a direct URL
    if _has_cmd curl && [ -t 0 ] 2>/dev/null; then
        ux_print "  Or paste a direct download URL for boot.img / init_boot.img:"
        local gki_url=""
        ux_prompt gki_url \
            "GKI boot image URL (or press Enter to skip)" \
            ""
        if [ -n "$gki_url" ]; then
            local gki_out="$_TMP/hom_gki_${boot_part}.img"
            ux_print "  Downloading GKI image..."
            if curl -fSL --retry 3 --connect-timeout 30 --max-time 300 \
                    -o "$gki_out" "$gki_url" 2>/dev/null; then
                if [ -f "$gki_out" ] && [ -s "$gki_out" ]; then
                    ux_print "  ✓  Downloaded GKI image"
                    echo "$gki_out"
                    return 0
                fi
            fi
            ux_print "  ✗  Download failed.  Place the image manually and re-run."
            rm -f "$gki_out"
        fi
    fi

    return 1
}

# ── User-supplied local file (boot.img / init_boot.img / factory ZIP) ──
# Looks in the user's downloads directory for a usable file the user
# may already have placed there manually.  Accepts any of:
#   • ${boot_part}.img  (preferred — boot.img or init_boot.img)
#   • boot.img / init_boot.img (other partition; will be flagged)
#   • <codename>-<build>-factory*.zip  (Google factory archive)
# Echoes the resolved path on stdout, or empty if the user skipped /
# nothing was confirmed.  Always returns 0.
_default_downloads_dir() {
    # Prefer Termux user-storage symlink when it actually resolves to
    # a directory (created by `termux-setup-storage`); else fall back
    # to the standard /sdcard/Download path used everywhere else in
    # this script.
    if [ -n "$HOME" ] && [ -d "$HOME/storage/downloads" ]; then
        echo "$HOME/storage/downloads"
    elif [ -d "/sdcard/Download" ]; then
        echo "/sdcard/Download"
    else
        echo "/sdcard/Download"
    fi
}

_autodetect_local_image() {
    # $1 = search dir, $2 = boot_part, $3 = codename, $4 = build_id_lower
    local dir="$1" bp="$2" cn="$3" bid="$4"
    local cand

    # 1. Exact partition image match wins
    if [ -f "$dir/${bp}.img" ] && [ -s "$dir/${bp}.img" ]; then
        echo "$dir/${bp}.img"; return 0
    fi

    # 2. Matching factory ZIP for this device + build
    if [ -n "$cn" ] && [ -n "$bid" ]; then
        for cand in "$dir/${cn}-${bid}-factory"*.zip; do
            [ -f "$cand" ] && [ -s "$cand" ] && { echo "$cand"; return 0; }
        done
    fi

    # 3. Any factory ZIP for this codename (different build still useful)
    if [ -n "$cn" ]; then
        for cand in "$dir/${cn}-"*-factory*.zip; do
            [ -f "$cand" ] && [ -s "$cand" ] && { echo "$cand"; return 0; }
        done
    fi

    # 4. The "other" boot partition image — still a candidate, the
    #    caller will warn if it is not the right partition type.
    if [ "$bp" = "init_boot" ] && [ -f "$dir/boot.img" ] && [ -s "$dir/boot.img" ]; then
        echo "$dir/boot.img"; return 0
    fi
    if [ "$bp" = "boot" ] && [ -f "$dir/init_boot.img" ] && [ -s "$dir/init_boot.img" ]; then
        echo "$dir/init_boot.img"; return 0
    fi

    echo ""
}

_classify_local_image() {
    # Echoes "zip" or "img" or "unknown" based on file extension /
    # magic.  Used so the caller can route the file to the factory
    # extractor or treat it as a raw image.
    local f="$1"
    case "$f" in
        *.zip|*.ZIP) echo "zip"; return 0 ;;
        *.img|*.IMG) echo "img"; return 0 ;;
    esac
    # Magic-byte sniff — first 4 bytes
    local head
    head=$(dd if="$f" bs=4 count=1 2>/dev/null | od -An -c 2>/dev/null | tr -d ' \n')
    case "$head" in
        PK*)         echo "zip" ;;   # ZIP local file header
        ANDROID*)    echo "img" ;;
        *)           echo "unknown" ;;
    esac
}

_confirm_yn() {
    # $1 = prompt text.  Returns 0 for yes (empty / Y / y / yes), 1 otherwise.
    local prompt="$1" answer=""
    if [ -t 0 ]; then
        printf '\n%s [Y/n]: ' "$prompt" >&2
        read -r answer </dev/tty 2>/dev/null || answer=""
    else
        answer="Y"
    fi
    case "$answer" in
        ''|y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

_confirm_yn_timeout() {
    # $1 = prompt text, $2 = timeout seconds (default 30).
    # Returns 0 for yes (or on timeout — auto-proceeds), 1 for no.
    local prompt="$1" timeout="${2:-30}" answer=""
    if [ -t 0 ]; then
        printf '\n%s [Y/n] (auto-yes in %ss): ' "$prompt" "$timeout" >&2
        # shellcheck disable=SC3045  # read -t: mksh/bash/busybox-ash extension
        if read -r -t "$timeout" answer </dev/tty 2>/dev/null; then
            : # got an answer before timeout
        else
            printf '\n  (no response — proceeding automatically)\n' >&2
            answer="Y"
        fi
    else
        answer="Y"
    fi
    case "$answer" in
        ''|y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

_prompt_option5_env_table_mode() {
    # Prompt user to choose env-table mode for option 5 after boot-image
    # detection output is shown.
    #
    # Writes:
    #   HOM_OPTION5_ENV_TABLE_MODE
    #   HOM_OPTION5_ENV_TABLE_REAL_LINK
    #   HOM_OPTION5_ENV_TABLE_FACTORY_LINK
    #   HOM_OPTION5_ENV_TABLE_BOTH_LINK
    #   HOM_OPTION5_ENV_TABLE_SELECTED_LINK
    local mode="both" input="" input_normalized="" links_dir_ok=1
    local links_dir="$BOOT_WORK_DIR/env_table_links"
    local real_link="$links_dir/real_hardware_env_table.link"
    local factory_link="$links_dir/factory_image_env_table.link"
    local both_link="$links_dir/both_env_tables.link"
    local selected_link="$both_link"

    if ! mkdir -p "$links_dir" 2>/dev/null; then
        log_warn "Could not create env-table links directory: $links_dir. Link placeholders may be unavailable."
        links_dir_ok=0
    fi
    if [ "$links_dir_ok" -eq 1 ]; then
        if ! ln -sfn /dev/null "$real_link" 2>/dev/null; then
            log_warn "Could not create /dev/null link: $real_link"
        fi
        if ! ln -sfn /dev/null "$factory_link" 2>/dev/null; then
            log_warn "Could not create /dev/null link: $factory_link"
        fi
        if ! ln -sfn /dev/null "$both_link" 2>/dev/null; then
            log_warn "Could not create /dev/null link: $both_link"
        fi
    fi

    ux_print ""
    ux_print "  ┌────────────────────────────────────────────────────────────────────┐"
    ux_print "  │ Option 5 — Environment Table Selection                            │"
    ux_print "  ├────────────────────────────────────────────────────────────────────┤"
    ux_print "  │ 1) Real hardware env table                                        │"
    ux_print "  ├────────────────────────────────────────────────────────────────────┤"
    ux_print "  │ 2) Factory image based environment table                          │"
    ux_print "  ├────────────────────────────────────────────────────────────────────┤"
    ux_print "  │ 3) Both tables                                                     │"
    ux_print "  ├────────────────────────────────────────────────────────────────────┤"
    ux_print "  │ Links: see below (all point to /dev/null placeholders)            │"
    ux_print "  └────────────────────────────────────────────────────────────────────┘"
    ux_print "    real   : $real_link"
    ux_print "    factory: $factory_link"
    ux_print "    both   : $both_link"

    if [ -t 0 ] 2>/dev/null; then
        ux_prompt input \
            "Choose env table mode [1=real, 2=factory, 3=both]" \
            "3"
    else
        input="3"
        log_info "Non-interactive mode: defaulting option 5 env table mode to both"
    fi

    input_normalized=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')

    case "$input_normalized" in
        1|real|hardware)
            mode="real_hardware"
            selected_link="$real_link"
            ;;
        2|factory|factory_image)
            mode="factory_image"
            selected_link="$factory_link"
            ;;
        3|both)
            mode="both"
            selected_link="$both_link"
            ;;
        *)
            log_warn "Invalid env table mode input '$input' — defaulting to both"
            mode="both"
            selected_link="$both_link"
            ;;
    esac

    _reg_set boot HOM_OPTION5_ENV_TABLE_MODE "$mode"
    _reg_set boot HOM_OPTION5_ENV_TABLE_REAL_LINK "$real_link"
    _reg_set boot HOM_OPTION5_ENV_TABLE_FACTORY_LINK "$factory_link"
    _reg_set boot HOM_OPTION5_ENV_TABLE_BOTH_LINK "$both_link"
    _reg_set boot HOM_OPTION5_ENV_TABLE_SELECTED_LINK "$selected_link"

    ux_print "  ✓  Selected env table mode: $mode"
    ux_print "     Active link: $selected_link"
}

_prompt_local_user_image() {
    # $1=boot_part, $2=codename, $3=build_id_lower
    # Echoes resolved path (or empty) on stdout.
    local boot_part="$1" codename="$2" build_id_lower="$3"
    local search_dir auto user_input candidate
    search_dir=$(_default_downloads_dir)
    auto=$(_autodetect_local_image "$search_dir" "$boot_part" "$codename" "$build_id_lower")

    ux_print ""
    ux_print "  ── Local image / factory ZIP ──────────────────"
    ux_print "  You can supply any of these and the script will"
    ux_print "  figure out the rest:"
    ux_print "    • ${boot_part}.img   (preferred for this device)"
    if [ "$boot_part" = "init_boot" ]; then
        ux_print "    • boot.img        (will warn — wrong partition)"
    else
        ux_print "    • init_boot.img   (will warn — wrong partition)"
    fi
    if [ -n "$codename" ] && [ -n "$build_id_lower" ]; then
        ux_print "    • ${codename}-${build_id_lower}-factory*.zip  (factory archive)"
    else
        ux_print "    • <codename>-<build>-factory*.zip  (factory archive)"
    fi
    ux_print "  Default search directory: $search_dir"
    if [ -n "$auto" ]; then
        ux_print "  Auto-detected: $auto"
        ux_print "  PRESS ENTER FOR DEFAULT (the auto-detected file above)"
    else
        ux_print "  No matching file auto-detected in $search_dir"
        ux_print "  PRESS ENTER to skip and use the online factory download"
    fi
    ux_print "  Or type a filename (relative to the directory above)"
    ux_print "  or an absolute path."

    # Non-interactive: just take the auto-detected value (or none).
    if [ ! -t 0 ]; then
        if [ -n "$auto" ]; then
            log_info "Non-interactive: using auto-detected local image $auto"
            echo "$auto"
        fi
        return 0
    fi

    ux_prompt user_input "  Filename or path" ""

    if [ -z "$user_input" ]; then
        # Blank → use the default if we have one
        if [ -z "$auto" ]; then
            log_info "User pressed ENTER with no auto-detected default — skipping local file"
            return 0
        fi
        if _confirm_yn "Continue with auto-detected file: $auto ?"; then
            echo "$auto"
        else
            log_info "User declined auto-detected default $auto"
        fi
        return 0
    fi

    # Resolve relative paths against the default search dir
    case "$user_input" in
        /*) candidate="$user_input" ;;
        *)  candidate="$search_dir/$user_input" ;;
    esac

    if [ ! -f "$candidate" ] || [ ! -s "$candidate" ]; then
        ux_print "  ✗  File not found or empty: $candidate"
        log_warn "User-supplied path does not exist: $candidate"
        return 0
    fi

    if _confirm_yn "Use this file: $candidate ?"; then
        echo "$candidate"
    else
        log_info "User declined supplied file $candidate"
    fi
    return 0
}

# ── Google factory image download ────────────────────────────
# For supported Pixel codenames, downloads the factory image ZIP,
# extracts the inner image-*.zip, and pulls boot.img or
# init_boot.img from it.
#
# Requires: curl, unzip, and a codename present in the
# partition index factory_image_sources.google.supported_codenames.

_is_google_device_supported() {
    local codename="$1"
    [ -f "$PARTITION_INDEX" ] || return 1
    # Simple grep — avoids python/jq dependency.  The JSON list
    # is formatted one entry per line by convention.
    grep -q "\"${codename}\"" "$PARTITION_INDEX" 2>/dev/null || return 1
    # Double-check it is inside the factory_image_sources section
    # (matches only codename strings under supported_codenames).
    # NOTE: This sed range depends on "factory_image_sources" appearing
    # before "pre_run_condition_checks" in partition_index.json.
    local in_section
    in_section=$(sed -n '/"factory_image_sources"/,/"pre_run_condition_checks"/p' \
        "$PARTITION_INDEX" 2>/dev/null | grep -c "\"${codename}\"" || echo 0)
    [ "$in_section" -gt 0 ]
}

# Extract the full standard boot-chain partition image set from an
# already-extracted inner image-*.zip into "$BOOT_WORK_DIR/partitions/".
#
# This complements the single Magisk-target image returned by
# _download_factory_boot_image when the user explicitly opts in:
# callers still get back the one image they need to patch, and can
# also choose to extract boot.img, init_boot.img, vendor_boot.img,
# dtbo.img, vbmeta*.img and recovery.img for recovery / inspection.
#
# Writes ONLY to stderr (via ux_print / log_info) so it is safe to
# call from inside a function whose stdout is captured via $(...).
#
# Usage: _extract_all_partitions_from_inner_zip <inner_zip_path>
_find_zip_member_by_basename() {
    # $1 = zip path
    # $2 = basename to find (e.g., boot.img)
    local zip_path="$1"
    local base_name="$2"
    [ -f "$zip_path" ] || return 1
    _has_cmd unzip || return 1

    local member
    member=$(
        unzip -Z1 "$zip_path" 2>/dev/null \
            | awk -v n="$base_name" '
                {
                    m=$0
                    sub(/^.*\//, "", m)
                    if (m == n) {
                        print $0
                        exit
                    }
                }'
    )
    [ -n "$member" ] || return 1
    printf '%s\n' "$member"
    return 0
}

_extract_zip_member_by_basename() {
    # $1 = zip path
    # $2 = basename to extract (e.g., vendor_boot.img)
    # $3 = output directory
    local zip_path="$1"
    local base_name="$2"
    local out_dir="$3"
    local member=""

    member=$(_find_zip_member_by_basename "$zip_path" "$base_name" || true)
    [ -n "$member" ] || return 1
    mkdir -p "$out_dir" 2>/dev/null || return 1
    unzip -joq "$zip_path" "$member" -d "$out_dir" 2>/dev/null || return 1
    [ -s "$out_dir/$base_name" ]
}

_extract_all_partitions_from_inner_zip() {
    # $1 = path to inner image-*.zip
    # $2 = optional output directory for extracted partition images
    local inner_zip_path="$1"
    local part_dir="${2:-$OPTION5_PARTITIONS_DIR}"
    [ -f "$inner_zip_path" ] || return 1
    _has_cmd unzip || return 1

    mkdir -p "$part_dir" 2>/dev/null || return 1

    # Standard boot-chain images shipped in Google factory inner ZIPs.
    # Not every image is present on every device / firmware — missing
    # entries are tolerated silently.
    local candidates="boot.img init_boot.img vendor_boot.img dtbo.img vbmeta.img vbmeta_system.img vbmeta_vendor.img recovery.img"

    local extracted_count=0
    local extracted_names=""
    local img
    for img in $candidates; do
        if _extract_zip_member_by_basename "$inner_zip_path" "$img" "$part_dir"; then
            extracted_count=$((extracted_count + 1))
            extracted_names="$extracted_names $img"
            log_info "Extracted partition image: $img -> $part_dir/$img"
        fi
    done

    if [ "$extracted_count" -gt 0 ]; then
        _reg_set boot HOM_OPTION5_PARTITIONS_DIR "$part_dir"
        ux_print "  ✓  Extracted $extracted_count partition image(s) to $part_dir"
        ux_print "    ${extracted_names# }"
        return 0
    fi

    log_warn "No standard partition images found inside inner ZIP"
    _reg_set boot HOM_OPTION5_PARTITIONS_DIR ""
    return 1
}

_download_factory_boot_image() {
    local codename="$1" boot_part="$2" build_id="$3" local_zip="${4:-}"

    _has_cmd unzip || { log_warn "unzip not available — cannot extract factory image"; return 1; }

    # Build ID is required so we know which firmware to expect.
    if [ -z "$build_id" ]; then
        log_warn "Build ID not available — cannot determine factory image URL"
        return 1
    fi

    local build_id_lower
    build_id_lower=$(echo "$build_id" | tr '[:upper:]' '[:lower:]')

    local factory_zip

    if [ -n "$local_zip" ] && [ -f "$local_zip" ] && [ -s "$local_zip" ]; then
        # User-supplied (or auto-detected) local factory ZIP — no download.
        factory_zip="$local_zip"
        log_info "Using local factory ZIP: $factory_zip"
        ux_print "  Using local factory ZIP: $factory_zip"
    else
        _has_cmd curl || { log_warn "curl not available — cannot download factory image"; return 1; }

        local factory_url="https://dl.google.com/dl/android/aosp/${codename}-${build_id_lower}-factory.zip"
        factory_zip="$BOOT_WORK_DIR/factory_${codename}_${build_id_lower}.zip"

        ux_print "  Downloading Google factory image..."
        ux_print "  URL: $factory_url"
        log_info "Factory image download: $factory_url → $factory_zip"

        local curl_log="$_TMP/hom_factory_curl.log"
        if ! curl -fSL --retry 3 --retry-delay 2 \
                --connect-timeout 30 --max-time 600 \
                -o "$factory_zip" "$factory_url" 2>"$curl_log"; then
            log_warn "Factory image download failed (HTTP error or network issue)"
            log_warn "curl output: $(cat "$curl_log" 2>/dev/null || true)"
            ux_print "  ✗  Download failed.  The build ID may not match an available"
            ux_print "     factory image, or the device may not be a Google Pixel."
            ux_print "     URL tried: $factory_url"
            rm -f "$factory_zip" "$curl_log"
            return 1
        fi

        ux_print "  ✓  Downloaded factory ZIP"
        rm -f "$curl_log"
    fi

    _reg_set boot HOM_OPTION5_FACTORY_ZIP_PATH "$factory_zip"

    # Google factory ZIPs are ZIP-in-ZIP:
    #   outer: {codename}-{build_id}/image-{codename}-{build_id}.zip
    # The inner ZIP contains boot.img, init_boot.img, etc.

    local extract_dir="$BOOT_WORK_DIR/factory_extract"
    mkdir -p "$extract_dir"
    _reg_set boot HOM_OPTION5_EXTRACT_DIR "$extract_dir"

    # Step 1: extract the inner image-*.zip from the outer ZIP
    local inner_zip
    inner_zip=$(unzip -l "$factory_zip" 2>/dev/null \
        | grep -o "[^ ]*image-${codename}-[^ ]*\\.zip" | head -1 || true)

    # Broader fallback if codename-specific pattern did not match
    if [ -z "$inner_zip" ]; then
        inner_zip=$(unzip -l "$factory_zip" 2>/dev/null \
            | grep -o '[^ ]*image-[^ ]*\.zip' | head -1 || true)
    fi

    if [ -z "$inner_zip" ]; then
        # Some factory ZIPs place boot.img directly at the top level
        log_info "No inner image-*.zip found; trying direct extraction"
        if unzip -joq "$factory_zip" "*/${boot_part}.img" \
                -d "$extract_dir" 2>/dev/null; then
            local found="$extract_dir/${boot_part}.img"
            if [ -f "$found" ] && [ -s "$found" ]; then
                _reg_set boot HOM_OPTION5_EXTRACTED_IMG_PATH "$found"
                echo "$found"
                return 0
            fi
        fi
        log_warn "Could not locate ${boot_part}.img inside factory ZIP"
        return 1
    fi

    log_info "Extracting inner ZIP: $inner_zip"

    # Verify the inner ZIP's embedded build ID matches the device's
    # current build, so the extracted ${boot_part}.img is partition-
    # compatible (vbmeta digest, kernel ABI, ramdisk layout).  A
    # mismatch is the #1 cause of failed Magisk patches and
    # anti-rollback bricks.
    local inner_build
    inner_build=$(echo "$inner_zip" \
        | sed -n "s|.*image-${codename}-\\([^./]*\\)\\.zip.*|\\1|p" \
        | tr '[:upper:]' '[:lower:]')
    if [ -n "$inner_build" ] && [ "$inner_build" != "$build_id_lower" ]; then
        log_warn "Factory ZIP build mismatch: device=$build_id_lower zip=$inner_build"
        ux_print "  ⚠  Build mismatch detected!"
        ux_print "       Device build : $build_id_lower"
        ux_print "       Factory ZIP  : $inner_build"
        ux_print "     Patching with a mismatched ${boot_part}.img can brick the"
        ux_print "     device (anti-rollback / vbmeta digest mismatch)."
        if [ -t 0 ] 2>/dev/null; then
            if ! _confirm_yn "Continue with mismatched factory ZIP anyway?"; then
                log_warn "User aborted due to factory ZIP build mismatch"
                return 1
            fi
        else
            log_warn "Non-interactive: refusing mismatched factory ZIP"
            return 1
        fi
    elif [ -n "$inner_build" ]; then
        log_info "Factory ZIP build matches device: $build_id_lower"
        ux_print "  ✓  Build match: $inner_build"
    fi

    unzip -joq "$factory_zip" "$inner_zip" -d "$extract_dir" 2>/dev/null || {
        log_warn "Failed to extract inner ZIP from factory image"
        return 1
    }

    local inner_zip_path
    inner_zip_path="$extract_dir/$(basename "$inner_zip")"
    _reg_set boot HOM_OPTION5_INNER_ZIP_PATH "$inner_zip_path"

    # Step 2: extract boot.img or init_boot.img from inner ZIP
    local partitions_dir="$OPTION5_PARTITIONS_DIR"
    if _extract_zip_member_by_basename "$inner_zip_path" "${boot_part}.img" "$extract_dir"; then
        local target_img="$extract_dir/${boot_part}.img"
        if [ -f "$target_img" ] && [ -s "$target_img" ]; then
            ux_print "  ✓  Extracted ${boot_part}.img from factory image"
            # Optional: extract the full boot-chain image set only if
            # the user explicitly asks for it.
            local extract_extra="no"
            if [ -t 0 ] 2>/dev/null; then
                ux_prompt extract_extra \
                    "  Extract additional partition images too (boot/vendor_boot/dtbo/vbmeta/recovery)? [yes/no]" \
                    "no"
            else
                log_info "Non-interactive mode: skipping additional partition extraction"
            fi
            if [ "$extract_extra" = "yes" ] || [ "$extract_extra" = "y" ]; then
                _extract_all_partitions_from_inner_zip "$inner_zip_path" "$partitions_dir" || true
            fi
            _reg_set boot HOM_OPTION5_EXTRACTED_IMG_PATH "$target_img"
            echo "$target_img"
            return 0
        fi
    fi

    # If init_boot was requested but not found, the device might
    # still use plain boot on this firmware version.
    if [ "$boot_part" = "init_boot" ]; then
        log_warn "init_boot.img not found in factory image — this firmware may pre-date API 33"
        ux_print "  ⚠  init_boot.img not present in this factory image."
        ux_print "     This firmware may pre-date Android 13 / API 33."
        ux_print "     Falling back to boot.img."
        if _extract_zip_member_by_basename "$inner_zip_path" "boot.img" "$extract_dir"; then
            local fallback_img="$extract_dir/boot.img"
            if [ -f "$fallback_img" ] && [ -s "$fallback_img" ]; then
                ux_print "  ✓  Extracted boot.img as fallback"
                local extract_extra="no"
                if [ -t 0 ] 2>/dev/null; then
                    ux_prompt extract_extra \
                        "  Extract additional partition images too (boot/vendor_boot/dtbo/vbmeta/recovery)? [yes/no]" \
                        "no"
                else
                    log_info "Non-interactive mode: skipping additional partition extraction"
                fi
                if [ "$extract_extra" = "yes" ] || [ "$extract_extra" = "y" ]; then
                    _extract_all_partitions_from_inner_zip "$inner_zip_path" "$partitions_dir" || true
                fi
                _reg_set boot HOM_OPTION5_EXTRACTED_IMG_PATH "$fallback_img"
                echo "$fallback_img"
                return 0
            fi
        fi
    fi

    log_warn "Failed to extract ${boot_part}.img from factory image"
    return 1
}

# ── main function ─────────────────────────────────────────────

run_boot_image_acquire() {
    ux_section "Boot Image Acquisition"
    ux_step_info "Boot Image Acquire" \
        "Locates and copies the boot/init_boot partition image to internal storage" \
        "Magisk must patch this image before flashing; we need a local copy to work with"

    mkdir -p "$BOOT_WORK_DIR" "$_TMP"
    _reg_set boot HOM_OPTION5_FACTORY_ZIP_PATH ""
    _reg_set boot HOM_OPTION5_EXTRACT_DIR ""
    _reg_set boot HOM_OPTION5_INNER_ZIP_PATH ""
    _reg_set boot HOM_OPTION5_EXTRACTED_IMG_PATH ""
    _reg_set boot HOM_OPTION5_PARTITIONS_DIR ""

    # ── 0. Self-contained dependency check ────────────────────

    _boot_image_check_deps

    # Determine which partition to target
    local boot_part
    boot_part=$(_reg_get HOM_DEV_BOOT_PART)
    boot_part="${boot_part:-boot}"

    log_var "boot_part" "$boot_part" "target partition type (boot or init_boot)"
    ux_print "  Target partition type: $boot_part"

    # Explain boot vs init_boot to the user
    if [ "$boot_part" = "init_boot" ]; then
        ux_print "  ℹ  This device uses init_boot (Android 13+ / API 33+)."
        ux_print "     Magisk patches init_boot instead of boot on this device."
    else
        ux_print "  ℹ  This device uses the standard boot partition."
    fi

    local boot_dev=""
    local out_img="$BOOT_WORK_DIR/${boot_part}_original.img"
    local acquire_method=""

    # ── 1. Root path — DD from live block device ──────────────

    if _have_root; then
        log_info "Running as root (uid 0) — attempting block device acquisition"
        ux_print "  Root access detected — trying live partition copy..."

        boot_dev=$(_reg_get "HOM_DEV_$(echo "$boot_part" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_DEV")

        # Cross-check the stored path is actually a block device
        if [ -n "$boot_dev" ] && [ -b "$boot_dev" ]; then
            log_info "Using registry block device: $boot_part at $boot_dev"
        else
            # Try fresh discovery
            boot_dev=$(_find_block "$boot_part" 2>/dev/null || true)
        fi

        if [ -n "$boot_dev" ] && [ -b "$boot_dev" ]; then
            ux_print "  Auto-discovered: $boot_dev"
            log_info "DD copy: $boot_dev → $out_img"
            log_exec "dd_boot_image" dd if="$boot_dev" of="$out_img" bs=4096

            if [ -f "$out_img" ] && [ -s "$out_img" ]; then
                acquire_method="root_dd"
                ux_print "  ✓  Copied $boot_part via dd from live device"
            else
                log_warn "DD copy produced empty output — trying other methods"
                boot_dev=""
            fi
        else
            log_info "Block device for $boot_part not found — trying other methods"
            ux_print "  Block device not found — trying other acquisition methods..."
        fi
    else
        log_info "Not running as root — block device path unavailable"
        ux_print "  No root access — block device copy unavailable."
        ux_print "  Will try pre-placed image or factory download..."
    fi

    # Retrieve device build and codename here — needed in both step 2
    # (pre-placed image build-ID matching) and step 3 (local/factory file).
    local codename build_id build_id_lower=""
    codename=$(_reg_get HOM_DEV_DEVICE)
    build_id=$(_reg_get HOM_DEV_BUILD_ID)
    # Fallback: try reading build ID from system properties directly
    if [ -z "$build_id" ]; then
        build_id=$(getprop ro.build.id 2>/dev/null || true)
    fi
    if [ -n "$build_id" ]; then
        build_id_lower=$(echo "$build_id" | tr '[:upper:]' '[:lower:]')
    fi

    # ── 2. Pre-placed image file ──────────────────────────────
    # Scans: boot_work dir, /sdcard/Download, Magisk stock backup,
    # TWRP/OrangeFox/PBRP/SHRP/RedWolf/CWM/Nandroid backup folders.
    #
    # TWRP .emmc.win files are raw dd dumps (same as .img).
    # Compressed backups (.win.gz, .win.lz4) are decompressed here.
    #
    # If a backup boot image is found, it can also be used as a
    # FALLBACK TO RECOVER ROOT if live Magisk patching fails:
    #   backup boot.img → Magisk patch → fastboot flash → root.

    if [ -z "$acquire_method" ]; then
        ux_print "  Scanning for pre-placed and backup images..."
        ux_print "    (boot_work, /sdcard/Download, Magisk stock backup,"
        ux_print "     TWRP, OrangeFox, PBRP, SHRP, RedWolf, CWM, Nandroid)"

        local pre_placed skipped_images="" _pp_accepted
        while true; do
            pre_placed=$(_find_pre_placed_image "$boot_part" "$skipped_images" 2>/dev/null || true)
            [ -n "$pre_placed" ] || break

            log_info "Pre-placed/backup image found: $pre_placed"

            # ── Build-ID check ────────────────────────────────
            # Try to extract the build ID embedded in the image binary.
            local img_build img_build_lower=""
            img_build=$(_extract_build_id_from_image "$pre_placed")
            if [ -n "$img_build" ]; then
                img_build_lower=$(echo "$img_build" | tr '[:upper:]' '[:lower:]')
            fi

            # ── User confirmation ─────────────────────────────
            _pp_accepted=0  # default: accepted (non-interactive / no build info)
            if [ -t 0 ] 2>/dev/null; then
                if [ -n "$img_build" ] && [ -n "$build_id_lower" ]; then
                    if [ "$img_build_lower" = "$build_id_lower" ]; then
                        # Build match: show info, auto-proceed after 30 s
                        ux_print "  ✓  Found image: $pre_placed"
                        ux_print "     Image build : $img_build"
                        ux_print "     Device build: $build_id"
                        ux_print "     ✓  Builds match."
                        log_info "Build ID match: image=$img_build device=$build_id"
                        _confirm_yn_timeout "Use this image (builds match)?" || _pp_accepted=1
                    else
                        # Build mismatch: show both numbers, require explicit Y/N
                        ux_print "  ⚠  Found image: $pre_placed"
                        ux_print "     Image build : $img_build"
                        ux_print "     Device build: $build_id"
                        ux_print "     Builds do NOT match — a mismatched image may cause"
                        ux_print "     boot failures or anti-rollback bricks."
                        log_warn "Build ID mismatch: image=$img_build device=$build_id"
                        _confirm_yn "Use this image despite build mismatch?" || _pp_accepted=1
                    fi
                else
                    # Build ID not determinable from image binary
                    ux_print "  ✓  Found image: $pre_placed"
                    _confirm_yn "Use this detected image: $pre_placed?" || _pp_accepted=1
                fi
            fi

            if [ "$_pp_accepted" -ne 0 ]; then
                log_info "User declined image $pre_placed — searching for next candidate"
                # Append path on its own line so _in_list can match it exactly.
                skipped_images="$(printf '%s\n%s' "$skipped_images" "$pre_placed")"
                continue
            fi

            # ── Copy / decompress ─────────────────────────────
            case "$pre_placed" in
                *.win.gz)
                    ux_print "  Decompressing gzip TWRP backup..."
                    if _has_cmd gzip; then
                        gzip -dc "$pre_placed" > "$out_img" 2>/dev/null
                        log_info "Decompressed gzip backup: $pre_placed → $out_img"
                    else
                        log_warn "gzip not available — cannot decompress $pre_placed"
                        ux_print "  ✗  gzip not available to decompress backup"
                        pre_placed=""
                    fi
                    ;;
                *.win.lz4)
                    ux_print "  Decompressing lz4 TWRP backup..."
                    if _has_cmd lz4; then
                        lz4 -dc "$pre_placed" > "$out_img" 2>/dev/null
                        log_info "Decompressed lz4 backup: $pre_placed → $out_img"
                    else
                        log_warn "lz4 not available — cannot decompress $pre_placed"
                        ux_print "  ✗  lz4 not available to decompress backup"
                        ux_print "     Install: apt install lz4 (host) / pkg install lz4 (Termux)"
                        pre_placed=""
                    fi
                    ;;
                *)
                    # Uncompressed — direct copy (.img or .emmc.win)
                    if [ "$pre_placed" != "$out_img" ]; then
                        log_exec "cp_boot_image" cp "$pre_placed" "$out_img"
                    fi
                    ;;
            esac

            if [ -n "$pre_placed" ] && [ -f "$out_img" ] && [ -s "$out_img" ]; then
                boot_dev="$pre_placed"
                # Classify the source for logging
                case "$pre_placed" in
                    /data/adb/magisk/*)  acquire_method="magisk_stock_backup" ;;
                    *TWRP*|*Fox*|*PBRP*|*SHRP*|*RedWolf*)
                                         acquire_method="recovery_backup" ;;
                    *clockworkmod*|*nandroid*)
                                         acquire_method="nandroid_backup" ;;
                    *)                   acquire_method="pre_placed" ;;
                esac

                ux_print "  ✓  Acquired via: $acquire_method"

                # If from a backup, note the recovery-from-backup path
                case "$acquire_method" in
                    magisk_stock_backup|recovery_backup|nandroid_backup)
                        ux_print ""
                        ux_print "  ℹ  This image came from a backup."
                        ux_print "     If live Magisk patching fails, you can use this as a"
                        ux_print "     FALLBACK TO RECOVER ROOT:"
                        ux_print "       1. Transfer this image to another device with Magisk"
                        ux_print "       2. Magisk app → Install → Patch a File → select image"
                        ux_print "       3. Transfer patched image back to HOST"
                        ux_print "       4. fastboot flash ${boot_part} magisk_patched-*.img"
                        ux_print "     See Mode C2 in docs/ADB_FASTBOOT_INSTALL.md"
                        ;;
                esac
            else
                log_warn "Copy/decompress of pre-placed image failed"
            fi
            break
        done

        if [ -z "$acquire_method" ]; then
            ux_print "  No usable pre-placed or backup ${boot_part}.img found."
        fi
    fi

    # Prompt exactly after boot-image detection output is shown.
    _prompt_option5_env_table_mode

    # ── 3. Local user file (boot.img / init_boot.img / factory ZIP)
    #       or Google factory image download (Pixel devices) ──────

    if [ -z "$acquire_method" ]; then
        # ── 3a. Ask the user for a local file first (img or zip) ──
        local user_path=""
        user_path=$(_prompt_local_user_image "$boot_part" "$codename" "$build_id_lower")

        if [ -n "$user_path" ]; then
            local kind
            kind=$(_classify_local_image "$user_path")
            log_info "User-supplied local file: $user_path (classified as $kind)"
            ux_print "  Detected file type: $kind"

            case "$kind" in
                zip)
                    if [ -z "$build_id" ]; then
                        log_warn "Build ID not known — factory ZIP extraction may fail"
                    fi
                    local extracted_img=""
                    extracted_img=$(_download_factory_boot_image \
                        "$codename" "$boot_part" "$build_id" "$user_path" || true)
                    if [ -n "$extracted_img" ] && [ -f "$extracted_img" ] && [ -s "$extracted_img" ]; then
                        cp "$extracted_img" "$out_img"
                        boot_dev="local_factory_zip:$user_path"
                        acquire_method="local_factory_zip"
                        ux_print "  ✓  Extracted ${boot_part}.img from local factory ZIP"
                    else
                        log_warn "Failed to extract ${boot_part}.img from local ZIP $user_path"
                        ux_print "  ✗  Could not extract ${boot_part}.img from $user_path"
                    fi
                    ;;
                img)
                    case "$user_path" in
                        *"${boot_part}".img|*"${boot_part}".IMG) : ;;
                        *)
                            ux_print "  ⚠  This file does not look like ${boot_part}.img."
                            ux_print "     Magisk on this device should patch ${boot_part}.img."
                            if ! _confirm_yn "Use it anyway?"; then
                                user_path=""
                            fi
                            ;;
                    esac
                    if [ -n "$user_path" ]; then
                        log_exec "cp_local_user_image" cp "$user_path" "$out_img"
                        if [ -f "$out_img" ] && [ -s "$out_img" ]; then
                            boot_dev="local_user_image:$user_path"
                            acquire_method="local_user_image"
                            ux_print "  ✓  Copied $user_path to $out_img"
                        else
                            log_warn "Copy of $user_path failed"
                            ux_print "  ✗  Copy failed."
                        fi
                    fi
                    ;;
                *)
                    log_warn "Unrecognised file type for $user_path — neither ZIP nor Android boot image"
                    ux_print "  ✗  Unrecognised file type — expected .img or .zip."
                    ;;
            esac
        fi

        # ── 3b. Fall through to Google factory download if needed ──
        if [ -z "$acquire_method" ] && [ -n "$codename" ] && _is_google_device_supported "$codename"; then
            local android_release android_sdk
            android_release=$(_reg_get HOM_DEV_ANDROID_VER)
            [ -z "$android_release" ] && android_release=$(getprop ro.build.version.release 2>/dev/null || true)
            android_sdk=$(_reg_get HOM_DEV_SDK_INT)
            [ -z "$android_sdk" ] && android_sdk=$(getprop ro.build.version.sdk 2>/dev/null || true)

            ux_print ""
            ux_print "  This looks like a Google Pixel device ($codename)."
            ux_print "  A factory image can be downloaded to extract ${boot_part}.img."
            ux_print "  Match target — these MUST equal what the device is running:"
            ux_print "    Codename     : $codename"
            ux_print "    Build ID     : ${build_id:-<unknown>}"
            ux_print "    Android      : ${android_release:-?} (API ${android_sdk:-?})"
            ux_print "  Google URL    : https://dl.google.com/dl/android/aosp/${codename}-${build_id_lower}-factory.zip"

            if [ -z "$build_id" ]; then
                ux_print "  ⚠  Build ID could not be read — download URL cannot be"
                ux_print "     constructed reliably.  Aborting fallback download."
            else
                local do_download="yes"
                # In interactive mode, ask confirmation
                if [ -t 0 ] 2>/dev/null; then
                    ux_prompt do_download \
                        "Download factory image matching build $build_id (Android ${android_release:-?})? [yes/no]" \
                        "yes"
                fi

                if [ "$do_download" = "yes" ] || [ "$do_download" = "y" ]; then
                    local extracted_img
                    extracted_img=$(_download_factory_boot_image "$codename" "$boot_part" "$build_id" || true)

                    if [ -n "$extracted_img" ] && [ -f "$extracted_img" ] && [ -s "$extracted_img" ]; then
                        cp "$extracted_img" "$out_img"
                        rm -f "$extracted_img"
                        boot_dev="factory:${codename}/${build_id}"
                        acquire_method="factory_download"
                        ux_print "  ✓  Factory image acquired successfully (build $build_id)"
                    else
                        log_warn "Factory image download/extraction did not produce a valid image"
                        ux_print "  ✗  Factory image acquisition failed."
                        ux_print "     The build $build_id may not be hosted by Google"
                        ux_print "     (e.g. beta/preview/developer build).  Provide the"
                        ux_print "     matching ${codename}-${build_id_lower}-factory.zip"
                        ux_print "     manually and re-run this option."
                    fi
                else
                    ux_print "  Skipping factory download (user declined)."
                fi
            fi
        elif [ -z "$acquire_method" ]; then
            if [ -n "$codename" ]; then
                log_info "Device codename '$codename' not in Google factory image index"
            fi
        fi
    fi

    # ── 3b. GKI Generic Boot Image (Android 12+ / API 31+) ──────
    # For ANY device using GKI (Generic Kernel Image), Google publishes
    # prebuilt generic boot images at ci.android.com.
    # Reference: https://source.android.com/docs/core/architecture/partitions/generic-boot
    #
    # This works on any GKI-compatible device — not just Pixels.
    # The TARGET device must be running Android 12+ with a GKI kernel.

    if [ -z "$acquire_method" ] && _is_gki_device; then
        local gki_branch
        gki_branch=$(_gki_branch_for_device 2>/dev/null || true)

        if [ -n "$gki_branch" ]; then
            ux_print ""
            ux_print "  This device uses GKI (Android 12+ Generic Kernel Image)."
            ux_print "  Kernel: $(uname -r 2>/dev/null || echo unknown) → branch: $gki_branch"

            local do_gki="yes"
            if [ -t 0 ] 2>/dev/null; then
                ux_prompt do_gki \
                    "Try GKI generic boot image for this kernel? [yes/no]" \
                    "yes"
            fi

            if [ "$do_gki" = "yes" ] || [ "$do_gki" = "y" ]; then
                local gki_img
                gki_img=$(_offer_gki_download "$boot_part" "$gki_branch" || true)

                if [ -n "$gki_img" ] && [ -f "$gki_img" ] && [ -s "$gki_img" ]; then
                    cp "$gki_img" "$out_img"
                    rm -f "$gki_img"
                    boot_dev="gki:$gki_branch"
                    acquire_method="gki_download"
                    ux_print "  ✓  GKI generic boot image acquired"
                fi
            fi
        fi
    fi

    # ── 3c. OEM-specific factory image sources ────────────────
    # NOTE: The Magisk GitHub repository (topjohnwu/Magisk) does NOT
    # host factory boot images.  Magisk is a rooting tool only.
    # However, Magisk saves the original stock boot image when patching
    # — this is checked in the backup scanner above (step 2).
    #
    # For non-Google, non-GKI devices, the boot image must come from
    # the OEM's firmware package.  Show OEM-specific guidance.

    if [ -z "$acquire_method" ]; then
        local manufacturer
        manufacturer=$(getprop ro.product.manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)

        if [ -n "$manufacturer" ]; then
            ux_print ""
            ux_print "  OEM-specific boot image sources for this device:"
            ux_print ""
            case "$manufacturer" in
                samsung|sec)
                    ux_print "    Samsung firmware sources:"
                    ux_print "      • SamFw:      https://samfw.com/"
                    ux_print "      • SamMobile:   https://www.sammobile.com/firmware/"
                    ux_print "      • Frija (PC):  Windows tool for direct Samsung server download"
                    ux_print "    Extract: AP_*.tar.md5 → boot.img.lz4 → lz4 -d boot.img.lz4 boot.img"
                    ;;
                xiaomi|redmi|poco)
                    ux_print "    Xiaomi / Redmi / POCO firmware sources:"
                    ux_print "      • XiaomiFirmwareUpdater: https://xiaomifirmwareupdater.com/"
                    ux_print "      • MIUI Downloads:        https://new.c.mi.com/global/miuidownload/"
                    ux_print "    Extract: payload.bin → payload-dumper-go -p ${boot_part} payload.bin"
                    ;;
                oneplus|oppo|realme)
                    ux_print "    OnePlus / OPPO / Realme firmware sources:"
                    ux_print "      • OnePlus:        https://service.oneplus.com/"
                    ux_print "      • OxygenUpdater:  Google Play / GitHub (automated OTA download)"
                    ux_print "    Extract: payload.bin → payload-dumper-go -p ${boot_part} payload.bin"
                    ;;
                motorola|lenovo)
                    ux_print "    Motorola / Lenovo firmware sources:"
                    ux_print "      • Motorola:  https://mirrors.lolinet.com/firmware/moto/"
                    ux_print "      • Lenovo:    https://support.lenovo.com/"
                    ux_print "    Extract: ZIP contains ${boot_part}.img directly"
                    ;;
                asus)
                    ux_print "    ASUS firmware: https://www.asus.com/support/ → select model"
                    ux_print "    Extract: payload.bin → payload-dumper-go -p ${boot_part} payload.bin"
                    ;;
                sony)
                    ux_print "    Sony firmware: XperiFirm desktop tool (XDA)"
                    ux_print "    Extract: .sin files → flashtool/newflasher → ${boot_part}.img"
                    ;;
                nothing)
                    ux_print "    Nothing firmware: official OTA or XDA community links"
                    ux_print "    Extract: payload.bin → payload-dumper-go -p ${boot_part} payload.bin"
                    ;;
                *)
                    ux_print "    Check your OEM's support / downloads page for firmware"
                    ux_print "    XDA Forums: https://xdaforums.com/ — search for your device"
                    ;;
            esac
            ux_print ""
            ux_print "    Generic extraction for payload.bin OTAs (most modern OEMs):"
            ux_print "      pip install payload-dumper-go   # or GitHub releases"
            ux_print "      payload-dumper-go -p ${boot_part} -o . payload.bin"
            ux_print ""
        fi
    fi

    # ── 4. User-guided manual path (final fallback) ───────────

    if [ -z "$acquire_method" ]; then
        ux_print ""
        ux_instructions \
            "The installer could not automatically obtain the $boot_part image." \
            "" \
            "You can provide the image in one of these ways:" \
            "" \
            "  a) Place ${boot_part}.img in /sdcard/Download/ and re-run" \
            "  b) Extract it from a factory/OTA image on your PC and push:" \
            "       adb push ${boot_part}.img /sdcard/Download/" \
            "  c) Enter a block device path if you know it:" \
            "       /dev/block/bootdevice/by-name/$boot_part" \
            "       /dev/block/by-name/$boot_part" \
            "       /dev/block/platform/<soc>/by-name/$boot_part" \
            "" \
            "  d) For GKI devices (Android 12+): download from ci.android.com" \
            "     See the GKI guidance shown above" \
            "" \
            "  e) Use a backup image to RECOVER ROOT if live patching fails:" \
            "     TWRP backup → Magisk patch on another device → fastboot flash" \
            "" \
            "Run:  ls /dev/block/bootdevice/by-name/  to list partition names."

        if [ "$boot_part" = "init_boot" ]; then
            ux_print ""
            ux_print "  NOTE: This device uses init_boot (Android 13+)."
            ux_print "  Make sure you extract init_boot.img (not boot.img)"
            ux_print "  from the factory/GKI image."
        fi

        ux_prompt boot_dev \
            "Enter full path to $boot_part block device or image file" \
            "/sdcard/Download/${boot_part}.img"

        log_var "boot_dev" "$boot_dev" "user-supplied path for $boot_part"

        # Verify the path exists
        if [ ! -b "$boot_dev" ] && [ ! -f "$boot_dev" ]; then
            ux_abort "Cannot read $boot_dev — not a block device or file. Aborting."
        fi

        # Copy to working directory
        if [ -b "$boot_dev" ]; then
            if ! _have_root; then
                ux_abort "Reading block device $boot_dev requires root access. Aborting."
            fi
            log_exec "dd_boot_image" dd if="$boot_dev" of="$out_img" bs=4096
        else
            log_exec "cp_boot_image" cp "$boot_dev" "$out_img"
        fi

        if [ ! -f "$out_img" ] || [ ! -s "$out_img" ]; then
            ux_abort "Copy of $boot_part failed — output file is missing or empty."
        fi

        acquire_method="user_prompt"
    fi

    # ── 5. Validate boot image magic ──────────────────────────

    ux_print "  Validating image format..."
    if ! _validate_boot_magic "$out_img"; then
        ux_print "  WARNING: Image magic check failed — the file may not be a valid boot image."
        ux_print "  Proceeding, but patching may fail."
        manifest_step "boot_img_magic_check" "FAIL" "unexpected magic"
    else
        ux_step_result "Boot image magic check" "OK"
        manifest_step "boot_img_magic_check" "OK"
    fi

    # ── 5b. Detect Kali NetHunter / custom init in ramdisk ────
    # Magisk's patcher overlays its own changes on top of the
    # existing ramdisk and preserves arbitrary 3rd-party additions
    # (init.<x>.rc, chroot launchers, kernel modules under /lib/
    # modules, etc.).  We just need to make sure the *acquired*
    # image is the user's customised one — not a stock factory
    # image silently substituted in — so the NetHunter chroot keeps
    # booting after the Magisk-patched image is flashed.

    local has_nethunter
    has_nethunter=$(_detect_kali_nethunter_in_image "$out_img")
    _reg_set boot HOM_BOOT_IMG_NETHUNTER "$has_nethunter"
    log_var "HOM_BOOT_IMG_NETHUNTER" "$has_nethunter" \
        "Kali NetHunter init artifacts detected in acquired ${boot_part}.img"

    if [ "$has_nethunter" = "yes" ]; then
        ux_print ""
        ux_print "  ℹ  Kali NetHunter init artifacts detected in this ${boot_part}.img."
        ux_print "     Magisk will patch on top and PRESERVE them — your NetHunter"
        ux_print "     chroot should keep booting after the patched image is flashed."
        ux_print "     (acquisition source: ${acquire_method:-unknown})"
        case "$acquire_method" in
            factory_download)
                # Implausible but loud — a stock Google factory ZIP
                # should never contain NetHunter strings.
                log_warn "NetHunter strings found in a stock factory image — investigate"
                ux_print "  ⚠  Unexpected: stock factory image contains NetHunter strings."
                ;;
        esac
    elif [ "$acquire_method" = "factory_download" ]; then
        # Stock image acquired via fallback download — make sure the
        # user knows their NetHunter install (if any was on the live
        # partition) is NOT in this image.
        ux_print ""
        ux_print "  ℹ  Acquired via stock Google factory download."
        ux_print "     If this device previously had Kali NetHunter installed,"
        ux_print "     that ramdisk customisation is NOT in this image and will"
        ux_print "     not survive flashing.  To preserve NetHunter, supply your"
        ux_print "     existing ${boot_part}.img instead and re-run option 5."
    fi

    # ── 6. SHA-256 pre-patch checksum ─────────────────────────

    local sha256
    sha256=$(_sha256 "$out_img")
    log_var "HOM_BOOT_IMG_SHA256" "$sha256" "SHA-256 of unpatched $boot_part image"
    ux_print "  SHA-256 (pre-patch): $sha256"

    # ── 7. Record to env registry ─────────────────────────────

    _reg_set boot HOM_BOOT_IMG_PATH   "$out_img"
    _reg_set boot HOM_BOOT_IMG_SHA256 "$sha256"
    _reg_set boot HOM_BOOT_PART_SRC   "${boot_dev:-unknown}"
    _reg_set boot HOM_BOOT_IMG_METHOD "$acquire_method"

    log_var "HOM_BOOT_IMG_METHOD" "$acquire_method" "image acquisition method"

    ux_step_result "Boot Image Acquire" "OK" \
        "method=$acquire_method saved to $out_img"
    manifest_step "boot_img_acquire" "OK" \
        "method=$acquire_method src=${boot_dev:-unknown} sha256=$sha256"
}
