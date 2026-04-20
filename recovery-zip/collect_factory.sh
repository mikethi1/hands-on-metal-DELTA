#!/usr/bin/env bash
# recovery-zip/collect_factory.sh
# shellcheck disable=SC3043  # local is supported by bash/mksh/busybox-ash
# ============================================================
# Hands-on-metal — Mode F: Factory Image Collection (no root)
#
# Parses and extracts hardware data from an OEM factory backup
# ZIP (e.g. a Google Pixel factory image from
# developers.google.com/android/images) WITHOUT requiring root.
#
# Extraction logic mirrors the proven path in core/boot_image.sh:
#   _download_factory_boot_image  →  outer-zip / inner-zip split
#   _extract_all_partitions_from_inner_zip  →  per-image loop
#
# What this script does:
#   1. Locates the factory ZIP via $HOM_FACTORY_ZIP, common
#      download dirs, or an interactive prompt.
#   2. Extracts the inner image-<codename>-<build>.zip from the
#      outer factory ZIP (same as boot_image.sh does).
#   3. Verifies the inner-ZIP build ID matches the device's
#      current build (warns on mismatch, same logic as boot_image.sh).
#   4. Extracts all standard boot-chain images from the inner ZIP:
#        boot.img  init_boot.img  vendor_boot.img
#        dtbo.img  vbmeta.img     vbmeta_system.img
#        vbmeta_vendor.img        recovery.img
#      Uses the EXACT same grep-Eq pattern as boot_image.sh so the
#      same image set is produced in both code paths.
#   5. Outputs to TWO locations that downstream steps already know:
#        $OUT/boot_work/partitions/   ← where unpack_images.py looks
#        $HOM_FACTORY_DUMP_DIR/boot_images/  ← factory-specific copy
#   6. Parses android-info.txt (board / required-bootloader /
#      required-baseband) exactly as device_profile.sh does.
#   7. Writes all discovered facts to the shared env registry so
#      subsequent steps (anti_rollback, magisk_patch, unpack_images)
#      can consume them without re-reading the ZIP.
#
# Variables set in env registry (additive — never clears existing):
#   HOM_BOOT_IMG_PATH        path to init_boot.img or boot.img
#   HOM_BOOT_IMG_METHOD      "factory_zip"
#   HOM_FACTORY_DUMP_DIR     factory_dump output directory
#   HOM_FACTORY_MANIFEST     path to factory_manifest.txt
#   HOM_FACTORY_ZIP_PATH     path to the factory ZIP used
#   HOM_FACTORY_BUILD_ID     build ID extracted from inner-ZIP name
#   HOM_FACTORY_CODENAME     codename extracted from inner-ZIP name
#   HOM_FACTORY_BOOT_IMG_DIR path to boot_images/ copy
#   HOM_FACTORY_INIT_BOOT_IMG / HOM_FACTORY_BOOT_IMG / …
#   HOM_DEV_FACTORY_BOARD, HOM_DEV_FACTORY_REQUIRED_BOOTLOADER/BASEBAND
#   HOM_EXEC_NODE / HOM_EXEC_UID / HOM_RECOVERY_MODE
#
# No root required — uses only: bash, unzip, find, mkdir, cp, grep.
# ============================================================

set -u

OUT="${OUT:-${HOME:-/tmp}/hands-on-metal}"
FACTORY_DUMP_DIR="${HOM_FACTORY_DUMP_DIR_OVERRIDE:-$OUT/factory_dump}"
BOOT_WORK_PARTS="$OUT/boot_work/partitions"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
LOG="$FACTORY_DUMP_DIR/collect_factory.log"
MANIFEST="$FACTORY_DUMP_DIR/factory_manifest.txt"

# Temp staging dir (cleaned on exit)
_STAGE_DIR=""

# ── helpers ──────────────────────────────────────────────────

_mklog() { mkdir -p "$FACTORY_DUMP_DIR"; }
log()  { _mklog; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $*" | tee -a "$LOG"; }
die()  { log "ERROR: $*"; exit 1; }

# Write/update one variable in the shared env registry.
# Uses the same format as core/device_profile.sh and core/boot_image.sh.
reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s mode:F\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

# Record a path into the factory manifest.
record_file() {
    local dst="$1"
    echo "${dst#$FACTORY_DUMP_DIR/}" >> "$MANIFEST"
}

cleanup() {
    if [ -n "$_STAGE_DIR" ] && [ -d "$_STAGE_DIR" ]; then
        rm -rf "$_STAGE_DIR"
    fi
}
trap cleanup EXIT

# ── init ─────────────────────────────────────────────────────

mkdir -p "$FACTORY_DUMP_DIR" "$BOOT_WORK_PARTS"
: > "$MANIFEST"
[ -f "$ENV_REGISTRY" ] || : > "$ENV_REGISTRY"

log "=== collect_factory.sh start (Mode F — no root required) ==="

# ── dependency check ─────────────────────────────────────────

command -v unzip >/dev/null 2>&1 || die "unzip is required but not installed"

# ── 1. Locate the factory ZIP ─────────────────────────────────

log "Locating factory ZIP..."

# Honour explicit override first (mirrors HOM_FACTORY_ZIP env var)
FACTORY_ZIP="${HOM_FACTORY_ZIP:-}"

if [ -z "$FACTORY_ZIP" ] || [ ! -f "$FACTORY_ZIP" ]; then
    # Auto-detect in common download locations
    # (same set of dirs used by boot_image.sh _default_downloads_dir)
    for _sdir in \
        "${HOME:-/tmp}/storage/downloads" \
        "${HOME:-/tmp}/Downloads" \
        "/sdcard/Download" \
        "/sdcard/Downloads" \
        "/sdcard" \
        "/data/local/tmp" \
        "$OUT"; do
        [ -d "$_sdir" ] || continue
        # Match the Google factory zip naming convention:
        #   <codename>-<build>-factory*.zip  OR  image-<codename>-<build>.zip
        _found=$(find "$_sdir" -maxdepth 2 \( \
            -name '*-factory*.zip' -o -name 'image-*.zip' \
        \) 2>/dev/null | head -1 || true)
        if [ -n "$_found" ] && [ -f "$_found" ]; then
            FACTORY_ZIP="$_found"
            log "  Auto-detected: $FACTORY_ZIP"
            break
        fi
    done
fi

if [ -z "$FACTORY_ZIP" ] || [ ! -f "$FACTORY_ZIP" ]; then
    # Interactive fallback — only when stdin is a terminal
    if [ -t 0 ]; then
        printf '\n  No factory ZIP found automatically.\n'
        printf '  Enter path to factory ZIP (or press Enter to abort): '
        read -r FACTORY_ZIP
        FACTORY_ZIP="${FACTORY_ZIP/#\~/${HOME:-~}}"
    fi
fi

[ -n "$FACTORY_ZIP" ] && [ -f "$FACTORY_ZIP" ] \
    || die "No factory ZIP found. Set HOM_FACTORY_ZIP=/path/to/factory.zip and re-run."

log "  Using factory ZIP: $FACTORY_ZIP"
reg_set factory HOM_FACTORY_ZIP_PATH "$FACTORY_ZIP"

# ── 2. Locate inner image-*.zip inside outer factory ZIP ──────
# Google factory ZIPs are ZIP-in-ZIP:
#   outer: <codename>-<build>/image-<codename>-<build>.zip
# This is the same two-step pattern used in boot_image.sh
# (_download_factory_boot_image, lines 865-895).

log "Inspecting outer factory ZIP..."

_STAGE_DIR=$(mktemp -d "${TMPDIR:-${HOME:-/tmp}/tmp}/hom_factory_XXXXXXXX" 2>/dev/null \
             || mktemp -d /tmp/hom_factory_XXXXXXXX)

# Detect codename from the device registry (set by device_profile.sh)
# so we can use the codename-specific grep pattern exactly as boot_image.sh does.
_CODENAME="${HOM_DEV_DEVICE:-${HOM_DEV_CODENAME:-}}"
_BUILD_ID_LOWER="${HOM_DEV_BUILD_ID:-}"
if [ -n "$_BUILD_ID_LOWER" ]; then
    _BUILD_ID_LOWER=$(printf '%s' "$_BUILD_ID_LOWER" | tr '[:upper:]' '[:lower:]')
fi

# Try the codename-specific pattern first (boot_image.sh line 867-868)
INNER_ZIP_ENTRY=""
if [ -n "$_CODENAME" ]; then
    INNER_ZIP_ENTRY=$(unzip -l "$FACTORY_ZIP" 2>/dev/null \
        | grep -o "[^ ]*image-${_CODENAME}-[^ ]*\\.zip" | head -1 || true)
fi
# Broader fallback (boot_image.sh line 873)
if [ -z "$INNER_ZIP_ENTRY" ]; then
    INNER_ZIP_ENTRY=$(unzip -l "$FACTORY_ZIP" 2>/dev/null \
        | grep -o '[^ ]*image-[^ ]*\.zip' | head -1 || true)
fi

if [ -z "$INNER_ZIP_ENTRY" ]; then
    # Some vendors place images directly at the top level of the ZIP.
    # Try extracting the target image(s) directly.
    log "  No inner image-*.zip found; checking for direct top-level images..."
    local _direct_found=0
    for _img in init_boot.img boot.img dtbo.img vbmeta.img vendor_boot.img; do
        if unzip -l "$FACTORY_ZIP" 2>/dev/null | grep -qE "[[:space:]]${_img}\$"; then
            unzip -joq "$FACTORY_ZIP" "$_img" -d "$_STAGE_DIR" 2>/dev/null || true
            if [ -s "$_STAGE_DIR/$_img" ]; then
                _direct_found=$(( _direct_found + 1 ))
                log "  Direct extract: $_img"
            fi
        fi
    done
    if [ "$_direct_found" -gt 0 ]; then
        # Copy directly extracted images to both output locations
        log "  Proceeding with $_direct_found directly-extracted image(s)"
        INNER_ZIP_PATH=""   # signal to skip inner-zip handling below
    else
        die "Could not locate inner image-*.zip or any boot images inside $FACTORY_ZIP"
    fi
else
    # Normal path: extract the inner zip first
    log "  Inner image ZIP: $INNER_ZIP_ENTRY"
    unzip -joq "$FACTORY_ZIP" "$INNER_ZIP_ENTRY" -d "$_STAGE_DIR" 2>/dev/null \
        || die "Failed to extract $INNER_ZIP_ENTRY from $FACTORY_ZIP"
    INNER_ZIP_PATH="$_STAGE_DIR/$(basename "$INNER_ZIP_ENTRY")"
    [ -f "$INNER_ZIP_PATH" ] || die "Inner ZIP not found after extraction: $INNER_ZIP_PATH"
fi

# ── 3. Build ID verification (same logic as boot_image.sh 900-928) ──

if [ -n "${INNER_ZIP_ENTRY:-}" ] && [ -n "$_BUILD_ID_LOWER" ]; then
    _INNER_BUILD=$(printf '%s' "$INNER_ZIP_ENTRY" \
        | sed -n "s|.*image-${_CODENAME:-[^-]*}-\\([^/]*\\)\\.zip|\1|p" \
        | tr '[:upper:]' '[:lower:]' || true)
    if [ -n "$_INNER_BUILD" ] && [ "$_INNER_BUILD" != "$_BUILD_ID_LOWER" ]; then
        log "  ⚠  Build mismatch: device=$_BUILD_ID_LOWER  factory-ZIP=$_INNER_BUILD"
        log "     Patching a mismatched boot image risks anti-rollback / vbmeta failures."
        if [ -t 0 ]; then
            printf '\n  ⚠  Build mismatch: device=%s  factory-ZIP=%s\n' \
                "$_BUILD_ID_LOWER" "$_INNER_BUILD"
            printf '     Continue anyway? [y/N]: '
            read -r _yn
            case "$_yn" in y|Y) ;; *)
                log "  User aborted due to build mismatch."
                exit 1 ;;
            esac
        else
            log "  Non-interactive: refusing mismatched factory ZIP."
            exit 1
        fi
    elif [ -n "$_INNER_BUILD" ]; then
        log "  ✓  Build match: $_INNER_BUILD"
        reg_set factory HOM_FACTORY_BUILD_ID "$_INNER_BUILD"
    fi
fi

# Infer codename and build ID from inner-zip filename even when
# the device registry (device_profile.sh) hasn't been run yet.
if [ -n "${INNER_ZIP_ENTRY:-}" ]; then
    _stem="$(basename "$INNER_ZIP_ENTRY" .zip)"   # e.g. image-husky-ap4a.250405.002
    _stem="${_stem#image-}"                         # e.g. husky-ap4a.250405.002
    _inferred_build="${_stem##*-}"                  # e.g. ap4a.250405.002
    _inferred_codename="${_stem%-*}"                # e.g. husky
    [ -z "${HOM_FACTORY_CODENAME:-}" ] && {
        reg_set factory HOM_FACTORY_CODENAME "$_inferred_codename"
        log "  Codename (from inner-zip name): $_inferred_codename"
    }
    [ -z "${HOM_FACTORY_BUILD_ID:-}" ] && [ -n "$_inferred_build" ] && {
        reg_set factory HOM_FACTORY_BUILD_ID "$_inferred_build"
        log "  Build ID (from inner-zip name): $_inferred_build"
    }
fi
reg_set factory HOM_FACTORY_ZIP_PATH "$FACTORY_ZIP"

# ── 4. Extract all standard boot-chain images ─────────────────
# Mirrors _extract_all_partitions_from_inner_zip in boot_image.sh
# (lines 760-806) exactly: same candidates list, same grep-Eq test,
# same unzip -joq invocation, same error tolerance.

BOOT_IMG_DIR="$FACTORY_DUMP_DIR/boot_images"
mkdir -p "$BOOT_IMG_DIR"

# Standard boot-chain images (boot_image.sh line 771)
_CANDIDATES="boot.img init_boot.img vendor_boot.img dtbo.img vbmeta.img vbmeta_system.img vbmeta_vendor.img recovery.img"

# When we have an inner ZIP, get its listing once (cheaper than per-image probing)
_LISTING=""
if [ -n "${INNER_ZIP_PATH:-}" ] && [ -f "${INNER_ZIP_PATH:-}" ]; then
    _LISTING=$(unzip -l "$INNER_ZIP_PATH" 2>/dev/null || true)
fi
# For direct-extract path, listing already evaluated by head count above.

_EXTRACTED_COUNT=0
_EXTRACTED_NAMES=""
_IMG_STAGE="$_STAGE_DIR/images"
mkdir -p "$_IMG_STAGE"

for _img in $_CANDIDATES; do
    if [ -n "$_LISTING" ]; then
        # Inner-ZIP path: check listing then extract (boot_image.sh line 785-795)
        printf '%s\n' "$_LISTING" | grep -Eq "[[:space:]]${_img}\$" || continue
        if unzip -joq "$INNER_ZIP_PATH" "$_img" -d "$_IMG_STAGE" 2>/dev/null \
                && [ -s "$_IMG_STAGE/$_img" ]; then
            _src="$_IMG_STAGE/$_img"
        else
            log "  [WARN] Failed to extract $_img from inner ZIP"
            continue
        fi
    elif [ -f "$_STAGE_DIR/$_img" ] && [ -s "$_STAGE_DIR/$_img" ]; then
        # Direct-extract path: file already in staging dir
        _src="$_STAGE_DIR/$_img"
    else
        continue
    fi

    # Copy to boot_work/partitions/ (unpack_images.py's primary search path)
    cp "$_src" "$BOOT_WORK_PARTS/$_img" 2>/dev/null && \
        log "  ✓  $BOOT_WORK_PARTS/$_img"

    # Copy to factory_dump/boot_images/ (factory-specific secondary copy)
    cp "$_src" "$BOOT_IMG_DIR/$_img" 2>/dev/null && \
        record_file "$BOOT_IMG_DIR/$_img"

    _EXTRACTED_COUNT=$(( _EXTRACTED_COUNT + 1 ))
    _EXTRACTED_NAMES="$_EXTRACTED_NAMES $_img"
done

[ "$_EXTRACTED_COUNT" -gt 0 ] \
    || die "No standard partition images found in factory ZIP"

log "  Extracted $_EXTRACTED_COUNT image(s):$_EXTRACTED_NAMES"
reg_set factory HOM_FACTORY_BOOT_IMG_DIR "$BOOT_IMG_DIR"

# ── 5. Set HOM_BOOT_IMG_PATH to the Magisk-patchable image ────
# Priority: init_boot.img (API 33+) > boot.img (same as boot_image.sh)

if [ -f "$BOOT_WORK_PARTS/init_boot.img" ] && [ -s "$BOOT_WORK_PARTS/init_boot.img" ]; then
    reg_set factory HOM_BOOT_IMG_PATH   "$BOOT_WORK_PARTS/init_boot.img"
    reg_set factory HOM_BOOT_IMG_METHOD "factory_zip"
    reg_set factory HOM_FACTORY_INIT_BOOT_IMG "$BOOT_WORK_PARTS/init_boot.img"
    log "  HOM_BOOT_IMG_PATH → init_boot.img (factory ZIP)"
elif [ -f "$BOOT_WORK_PARTS/boot.img" ] && [ -s "$BOOT_WORK_PARTS/boot.img" ]; then
    reg_set factory HOM_BOOT_IMG_PATH   "$BOOT_WORK_PARTS/boot.img"
    reg_set factory HOM_BOOT_IMG_METHOD "factory_zip"
    reg_set factory HOM_FACTORY_BOOT_IMG "$BOOT_WORK_PARTS/boot.img"
    log "  HOM_BOOT_IMG_PATH → boot.img (factory ZIP)"
fi

# ── 6. Parse android-info.txt ─────────────────────────────────
# Mirrors device_profile.sh _dp_find_factory_zip block (lines 429-443):
# board=, require version-bootloader=, require version-baseband=

if [ -n "${INNER_ZIP_PATH:-}" ] && [ -f "${INNER_ZIP_PATH:-}" ]; then
    _AINFO_REL=$(unzip -l "$INNER_ZIP_PATH" 2>/dev/null \
        | grep -oE '[^ ]*android-info\.txt' | head -1 || true)
    if [ -n "$_AINFO_REL" ]; then
        _AINFO_FILE="$_STAGE_DIR/android-info.txt"
        if unzip -p "$INNER_ZIP_PATH" "$_AINFO_REL" > "$_AINFO_FILE" 2>/dev/null \
                && [ -s "$_AINFO_FILE" ]; then
            _FACTORY_BOARD=$(awk -F= '/^board=/ {print $2; exit}' "$_AINFO_FILE" | tr -d '\r')
            _FACTORY_REQ_BL=$(awk -F= '/^require version-bootloader=/ {print $2; exit}' "$_AINFO_FILE" | tr -d '\r')
            _FACTORY_REQ_BB=$(awk -F= '/^require version-baseband=/ {print $2; exit}' "$_AINFO_FILE" | tr -d '\r')
            [ -n "$_FACTORY_BOARD"  ] && reg_set factory HOM_DEV_FACTORY_BOARD               "$_FACTORY_BOARD"
            [ -n "$_FACTORY_REQ_BL" ] && reg_set factory HOM_DEV_FACTORY_REQUIRED_BOOTLOADER "$_FACTORY_REQ_BL"
            [ -n "$_FACTORY_REQ_BB" ] && reg_set factory HOM_DEV_FACTORY_REQUIRED_BASEBAND   "$_FACTORY_REQ_BB"
            log "  android-info: board=${_FACTORY_BOARD:-?}  req-bl=${_FACTORY_REQ_BL:-?}  req-bb=${_FACTORY_REQ_BB:-?}"
        fi
    fi
fi

# ── 7. Record execution context ───────────────────────────────

_uid=$(id -u 2>/dev/null || echo 9999)
reg_set shell   HOM_EXEC_NODE     "unprivileged_factory"
reg_set shell   HOM_EXEC_UID      "$_uid"
reg_set factory HOM_RECOVERY_MODE "F"
reg_set factory HOM_FACTORY_DUMP_DIR  "$FACTORY_DUMP_DIR"
reg_set factory HOM_FACTORY_MANIFEST  "$MANIFEST"

_hw_env="factory_zip"
[ -n "${TERMUX_VERSION:-}" ] && _hw_env="termux_factory_zip"
[ -z "$(getprop ro.product.model 2>/dev/null)" ] && ! [ -f /system/build.prop ] \
    && _hw_env="sandbox_factory_zip"
reg_set collect HOM_HW_ENV "$_hw_env"

# ── done ─────────────────────────────────────────────────────

_VAR_COUNT=$(grep -c "mode:F" "$ENV_REGISTRY" 2>/dev/null || echo 0)
_FILE_COUNT=$(wc -l < "$MANIFEST" 2>/dev/null || echo 0)
log "=== collect_factory.sh complete: $_FILE_COUNT images, $_VAR_COUNT env vars (mode:F) ==="
log ""
log "Partition images → $BOOT_WORK_PARTS"
log "Registry        → $ENV_REGISTRY"
log ""
log "Next step: run pipeline/unpack_images.py"
log "  Or patch boot image: core/magisk_patch.sh (reads HOM_BOOT_IMG_PATH)"
