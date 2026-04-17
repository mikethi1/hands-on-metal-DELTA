#!/system/bin/sh
# core/boot_image.sh
# ============================================================
# Guided boot image acquisition and validation.
#
# Flow:
#   1. Auto-discover the boot partition block device.
#   2. If auto-discovery fails → guide user to specify path.
#   3. DD-copy the image to /sdcard/hands-on-metal/boot_work/.
#   4. Validate the image format (Android boot magic check).
#   5. Record SHA-256 pre-patch checksum.
#
# Requires: logging.sh, ux.sh, device_profile.sh (for HOM_DEV_BOOT_PART)
#
# Outputs written to ENV_REGISTRY:
#   HOM_BOOT_IMG_PATH   — path to the local copy of the image
#   HOM_BOOT_IMG_SHA256 — SHA-256 of the unpatched image
#   HOM_BOOT_PART_SRC   — block device the image was read from
# ============================================================

SCRIPT_NAME="boot_image"

OUT="${OUT:-/sdcard/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
BOOT_WORK_DIR="$OUT/boot_work"
PARTITION_INDEX="${PARTITION_INDEX:-$(dirname "$0")/../build/partition_index.json}"

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
# Supports: ANDROID! (boot/recovery), VNDRBOOT (vendor_boot), IMGDIFF
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

# ── main function ─────────────────────────────────────────────

run_boot_image_acquire() {
    ux_section "Boot Image Acquisition"
    ux_step_info "Boot Image Acquire" \
        "Locates and copies the boot/init_boot partition image to internal storage" \
        "Magisk must patch this image before flashing; we need a local copy to work with"

    mkdir -p "$BOOT_WORK_DIR"

    # Determine which partition to target
    local boot_part
    boot_part=$(_reg_get HOM_DEV_BOOT_PART)
    boot_part="${boot_part:-boot}"

    log_var "boot_part" "$boot_part" "target partition type (boot or init_boot)"
    ux_print "  Target partition type: $boot_part"

    # ── 1. Auto-discover block device ─────────────────────────

    local boot_dev
    boot_dev=$(_reg_get "HOM_DEV_$(echo "$boot_part" | tr 'a-z' 'A-Z' | tr '-' '_')_DEV")

    # Cross-check the stored path is actually a block device
    if [ -n "$boot_dev" ] && [ -b "$boot_dev" ]; then
        log_info "Auto-discovered: $boot_part at $boot_dev"
        ux_print "  Auto-discovered: $boot_dev"
    else
        # Try fresh discovery
        boot_dev=$(_find_block "$boot_part" 2>/dev/null || true)
        if [ -z "$boot_dev" ] || [ ! -b "$boot_dev" ]; then
            ux_print ""
            ux_print "  Could not auto-discover /$boot_part block device."
        fi
    fi

    # ── 2. User-guided fallback ────────────────────────────────

    if [ -z "$boot_dev" ] || [ ! -b "$boot_dev" ]; then
        ux_instructions \
            "The installer could not find the $boot_part partition automatically." \
            "Common locations:" \
            "  /dev/block/bootdevice/by-name/$boot_part" \
            "  /dev/block/by-name/$boot_part" \
            "  /dev/block/platform/<soc>/by-name/$boot_part" \
            "" \
            "You may also supply a path to an already-extracted image file:" \
            "  /sdcard/Download/$boot_part.img" \
            "" \
            "Run:  ls /dev/block/bootdevice/by-name/  to list all partition names."

        ux_prompt boot_dev \
            "Enter full path to $boot_part block device or image file" \
            "/dev/block/bootdevice/by-name/$boot_part"
    fi

    log_var "boot_dev" "$boot_dev" "block device or image file path for $boot_part"

    # ── 3. Verify source exists ────────────────────────────────

    if [ ! -b "$boot_dev" ] && [ ! -f "$boot_dev" ]; then
        ux_abort "Cannot read $boot_dev — not a block device or file. Aborting."
    fi

    # ── 4. Copy / DD to working directory ─────────────────────

    local out_img="$BOOT_WORK_DIR/${boot_part}_original.img"

    ux_print "  Copying $boot_part → $out_img ..."
    log_info "Starting DD copy: $boot_dev → $out_img"

    if [ -b "$boot_dev" ]; then
        log_exec "dd_boot_image" dd if="$boot_dev" of="$out_img" bs=4096
    else
        log_exec "cp_boot_image" cp "$boot_dev" "$out_img"
    fi

    if [ ! -f "$out_img" ] || [ ! -s "$out_img" ]; then
        ux_abort "Copy of $boot_part failed — output file is missing or empty."
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

    # ── 6. SHA-256 pre-patch checksum ─────────────────────────

    local sha256
    sha256=$(_sha256 "$out_img")
    log_var "HOM_BOOT_IMG_SHA256" "$sha256" "SHA-256 of unpatched $boot_part image"
    ux_print "  SHA-256 (pre-patch): $sha256"

    # ── 7. Record to env registry ─────────────────────────────

    _reg_set boot HOM_BOOT_IMG_PATH   "$out_img"
    _reg_set boot HOM_BOOT_IMG_SHA256 "$sha256"
    _reg_set boot HOM_BOOT_PART_SRC   "$boot_dev"

    ux_step_result "Boot Image Acquire" "OK" "saved to $out_img"
    manifest_step "boot_img_acquire" "OK" "src=$boot_dev sha256=$sha256"
}
