#!/system/bin/sh
# core/boot_image.sh
# ============================================================
# Guided boot/init_boot image acquisition and validation.
#
# Acquisition strategy (first match wins):
#
#   1. **Root / block-device path** — if the running shell has
#      root access (uid 0) and the target partition's block
#      device is reachable, DD-copy the live partition image.
#
#   2. **Pre-placed image file** — scan well-known locations on
#      /sdcard/Download and the boot_work directory for an
#      already-extracted boot.img / init_boot.img.
#
#   3. **Google factory image download** — for Google Pixel
#      devices whose codename is in the partition index, offer
#      to download the factory image ZIP and extract the
#      matching boot.img or init_boot.img automatically.
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
#                              (root_dd | pre_placed | factory_download | user_prompt)
# ============================================================

SCRIPT_NAME="boot_image"

OUT="${OUT:-/sdcard/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
BOOT_WORK_DIR="$OUT/boot_work"
PARTITION_INDEX="${PARTITION_INDEX:-$(dirname "$0")/../build/partition_index.json}"

# Portable temp directory (Termux sets $TMPDIR; /tmp may not exist)
_TMP="${TMPDIR:-/tmp}"

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
# Scans well-known download / working directories for an image
# file whose name matches the target partition.  Returns the
# first match found.

_find_pre_placed_image() {
    local boot_part="$1"
    local candidate

    for candidate in \
        "$BOOT_WORK_DIR/${boot_part}_original.img" \
        "$BOOT_WORK_DIR/${boot_part}.img" \
        "/sdcard/Download/${boot_part}.img" \
        "/sdcard/Download/${boot_part}_original.img" \
        "/sdcard/${boot_part}.img" \
        "/data/local/tmp/${boot_part}.img"; do
        if [ -f "$candidate" ] && [ -s "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
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

_download_factory_boot_image() {
    local codename="$1" boot_part="$2" build_id="$3"

    _has_cmd curl  || { log_warn "curl not available — cannot download factory image"; return 1; }
    _has_cmd unzip || { log_warn "unzip not available — cannot extract factory image"; return 1; }

    # Build ID is required so we download the exact matching firmware.
    if [ -z "$build_id" ]; then
        log_warn "Build ID not available — cannot determine factory image URL"
        return 1
    fi

    local build_id_lower
    build_id_lower=$(echo "$build_id" | tr 'A-Z' 'a-z')

    local factory_url="https://dl.google.com/dl/android/aosp/${codename}-${build_id_lower}-factory.zip"
    local factory_zip="$_TMP/hom_factory_${codename}_${build_id_lower}.zip"

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

    # Google factory ZIPs are ZIP-in-ZIP:
    #   outer: {codename}-{build_id}/image-{codename}-{build_id}.zip
    # The inner ZIP contains boot.img, init_boot.img, etc.

    local extract_dir="$_TMP/hom_factory_extract"
    mkdir -p "$extract_dir"

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
        if unzip -jo "$factory_zip" "*/${boot_part}.img" \
                -d "$extract_dir" 2>/dev/null; then
            local found="$extract_dir/${boot_part}.img"
            if [ -f "$found" ] && [ -s "$found" ]; then
                echo "$found"
                rm -f "$factory_zip"
                return 0
            fi
        fi
        log_warn "Could not locate ${boot_part}.img inside factory ZIP"
        rm -f "$factory_zip"
        rm -rf "$extract_dir"
        return 1
    fi

    log_info "Extracting inner ZIP: $inner_zip"
    unzip -jo "$factory_zip" "$inner_zip" -d "$extract_dir" 2>/dev/null || {
        log_warn "Failed to extract inner ZIP from factory image"
        rm -f "$factory_zip"
        rm -rf "$extract_dir"
        return 1
    }

    local inner_zip_path="$extract_dir/$(basename "$inner_zip")"

    # Step 2: extract boot.img or init_boot.img from inner ZIP
    if unzip -jo "$inner_zip_path" "${boot_part}.img" \
            -d "$extract_dir" 2>/dev/null; then
        local target_img="$extract_dir/${boot_part}.img"
        if [ -f "$target_img" ] && [ -s "$target_img" ]; then
            ux_print "  ✓  Extracted ${boot_part}.img from factory image"
            echo "$target_img"
            rm -f "$factory_zip" "$inner_zip_path"
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
        if unzip -jo "$inner_zip_path" "boot.img" \
                -d "$extract_dir" 2>/dev/null; then
            local fallback_img="$extract_dir/boot.img"
            if [ -f "$fallback_img" ] && [ -s "$fallback_img" ]; then
                ux_print "  ✓  Extracted boot.img as fallback"
                echo "$fallback_img"
                rm -f "$factory_zip" "$inner_zip_path"
                return 0
            fi
        fi
    fi

    log_warn "Failed to extract ${boot_part}.img from factory image"
    rm -f "$factory_zip" "$inner_zip_path"
    rm -rf "$extract_dir"
    return 1
}

# ── main function ─────────────────────────────────────────────

run_boot_image_acquire() {
    ux_section "Boot Image Acquisition"
    ux_step_info "Boot Image Acquire" \
        "Locates and copies the boot/init_boot partition image to internal storage" \
        "Magisk must patch this image before flashing; we need a local copy to work with"

    mkdir -p "$BOOT_WORK_DIR" "$_TMP"

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

        boot_dev=$(_reg_get "HOM_DEV_$(echo "$boot_part" | tr 'a-z' 'A-Z' | tr '-' '_')_DEV")

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

    # ── 2. Pre-placed image file ──────────────────────────────

    if [ -z "$acquire_method" ]; then
        ux_print "  Scanning for pre-placed image files..."

        local pre_placed
        pre_placed=$(_find_pre_placed_image "$boot_part" 2>/dev/null || true)

        if [ -n "$pre_placed" ]; then
            ux_print "  ✓  Found pre-placed image: $pre_placed"
            log_info "Pre-placed image found: $pre_placed"

            if [ "$pre_placed" != "$out_img" ]; then
                log_exec "cp_boot_image" cp "$pre_placed" "$out_img"
            fi

            if [ -f "$out_img" ] && [ -s "$out_img" ]; then
                boot_dev="$pre_placed"
                acquire_method="pre_placed"
            else
                log_warn "Copy of pre-placed image failed"
            fi
        else
            ux_print "  No pre-placed ${boot_part}.img found in common locations."
        fi
    fi

    # ── 3. Google factory image download (Pixel devices) ──────

    if [ -z "$acquire_method" ]; then
        local codename build_id
        codename=$(_reg_get HOM_DEV_DEVICE)
        build_id=$(_reg_get HOM_DEV_BUILD_ID)
        # Fallback: try reading build ID from system properties directly
        if [ -z "$build_id" ]; then
            build_id=$(getprop ro.build.id 2>/dev/null || true)
        fi

        if [ -n "$codename" ] && _is_google_device_supported "$codename"; then
            ux_print ""
            ux_print "  This looks like a Google Pixel device ($codename)."
            ux_print "  A factory image can be downloaded to extract ${boot_part}.img."

            if [ -n "$build_id" ]; then
                ux_print "  Build ID: $build_id"
            fi

            local do_download="yes"
            # In interactive mode, ask confirmation
            if [ -t 0 ] 2>/dev/null; then
                ux_prompt do_download \
                    "Download factory image for $codename (build $build_id)? [yes/no]" \
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
                    ux_print "  ✓  Factory image acquired successfully"
                else
                    log_warn "Factory image download/extraction did not produce a valid image"
                    ux_print "  ✗  Factory image acquisition failed."
                fi
            else
                ux_print "  Skipping factory download (user declined)."
            fi
        else
            if [ -n "$codename" ]; then
                log_info "Device codename '$codename' not in Google factory image index"
            fi
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
            "  b) Extract it from a factory image ZIP on your PC and push:" \
            "       adb push ${boot_part}.img /sdcard/Download/" \
            "  c) Enter a block device path if you know it:" \
            "       /dev/block/bootdevice/by-name/$boot_part" \
            "       /dev/block/by-name/$boot_part" \
            "       /dev/block/platform/<soc>/by-name/$boot_part" \
            "" \
            "Run:  ls /dev/block/bootdevice/by-name/  to list partition names."

        if [ "$boot_part" = "init_boot" ]; then
            ux_print ""
            ux_print "  NOTE: This device uses init_boot (Android 13+)."
            ux_print "  Make sure you extract init_boot.img (not boot.img)"
            ux_print "  from the factory image."
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
