#!/usr/bin/env bash
# recovery-zip/collect_factory.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Hands-on-metal — Mode F: Factory Image Collection (no root)
#
# Parses and extracts hardware variable data from an OEM factory
# backup ZIP (e.g. a Google Pixel factory image downloaded from
# developers.google.com/android/images) WITHOUT requiring root
# access.  All operations are read-only on the ZIP itself.
#
# What it does:
#   1. Locates a factory ZIP in $HOM_FACTORY_ZIP, common download
#      directories, or a user-supplied path.
#   2. Lists the outer ZIP to find the inner image ZIP
#      (image-<codename>-<build>.zip) and extracts it to a temp
#      staging directory.
#   3. From the image ZIP, extracts:
#        boot.img / init_boot.img   — boot images for patching
#        dtbo.img                   — device-tree blob overlay
#        vbmeta.img                 — verified-boot metadata
#        system/build.prop          — system build properties
#        vendor/build.prop          — vendor build properties
#   4. Parses key hardware properties from build.prop files and
#      writes them into the shared env registry so downstream
#      pipeline steps (unpack_images.py, build_table.py, etc.)
#      can consume them alongside live-collected data.
#   5. Copies the extracted image files into
#      $OUT/factory_dump/boot_images/ so pipeline/unpack_images.py
#      can locate them automatically.
#
# Safety guarantees:
#   • No root required — uses only unzip, find, mkdir, cp, grep
#   • Never modifies the source factory ZIP
#   • Never writes outside $OUT/factory_dump/
#   • Cleans up the temp staging directory on exit
#
# Usage:
#   bash recovery-zip/collect_factory.sh
#   HOM_FACTORY_ZIP=/path/to/factory.zip bash recovery-zip/collect_factory.sh
# ============================================================

set -u

OUT="${OUT:-${HOME:-/tmp}/hands-on-metal}"
FACTORY_DUMP_DIR="$OUT/factory_dump"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
LOG="$FACTORY_DUMP_DIR/collect_factory.log"
MANIFEST="$FACTORY_DUMP_DIR/factory_manifest.txt"

# Temp staging dir (cleaned on exit)
_STAGE_DIR=""

# ── helpers ──────────────────────────────────────────────────

log() { mkdir -p "$FACTORY_DUMP_DIR"; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

die() { log "ERROR: $*"; exit 1; }

# Write/update a variable in the shared env registry
reg_set() {
    local cat="$1" key="$2" val="$3"
    local tmp="${ENV_REGISTRY}.tmp"
    grep -v "^${key}=" "$ENV_REGISTRY" > "$tmp" 2>/dev/null || true
    printf '%s="%s"  # cat:%s mode:F\n' "$key" "$val" "$cat" >> "$tmp"
    mv "$tmp" "$ENV_REGISTRY"
}

# Copy a file into the factory dump preserving a relative path under $FACTORY_DUMP_DIR
copy_file_to() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if cp "$src" "$dst" 2>/dev/null; then
        echo "${dst#$FACTORY_DUMP_DIR/}" >> "$MANIFEST"
    fi
}

cleanup() {
    if [ -n "$_STAGE_DIR" ] && [ -d "$_STAGE_DIR" ]; then
        rm -rf "$_STAGE_DIR"
    fi
}
trap cleanup EXIT

# ── init ─────────────────────────────────────────────────────

mkdir -p "$FACTORY_DUMP_DIR"
: > "$MANIFEST"
[ -f "$ENV_REGISTRY" ] || : > "$ENV_REGISTRY"

log "=== collect_factory.sh start (Mode F — no root) ==="

# ── dependency check ─────────────────────────────────────────

for _cmd in unzip find grep; do
    command -v "$_cmd" >/dev/null 2>&1 || die "Required tool not found: $_cmd"
done

# ── 1. Locate the factory ZIP ─────────────────────────────────

log "Locating factory ZIP..."

FACTORY_ZIP="${HOM_FACTORY_ZIP:-}"

if [ -z "$FACTORY_ZIP" ] || [ ! -f "$FACTORY_ZIP" ]; then
    # Search common locations for a factory ZIP
    for _search_dir in \
        "${HOME:-/tmp}/Downloads" \
        "${HOME:-/tmp}/downloads" \
        "/sdcard/Download" \
        "/sdcard/Downloads" \
        "/sdcard" \
        "/data/local/tmp" \
        "$OUT"; do
        [ -d "$_search_dir" ] || continue
        _found=$(find "$_search_dir" -maxdepth 2 -name "*.zip" 2>/dev/null | \
            grep -i '\(factory\|image-\|ota\)' | head -1 || true)
        if [ -n "$_found" ] && [ -f "$_found" ]; then
            FACTORY_ZIP="$_found"
            log "  Auto-detected factory ZIP: $FACTORY_ZIP"
            break
        fi
    done
fi

if [ -z "$FACTORY_ZIP" ] || [ ! -f "$FACTORY_ZIP" ]; then
    # Interactive prompt (only when stdin is a terminal)
    if [ -t 0 ]; then
        printf '\n  No factory ZIP found automatically.\n'
        printf '  Enter path to factory ZIP (or press Enter to abort): '
        read -r FACTORY_ZIP
        FACTORY_ZIP=$(echo "$FACTORY_ZIP" | sed "s|^~|${HOME:-~}|")
    fi
fi

[ -n "$FACTORY_ZIP" ] && [ -f "$FACTORY_ZIP" ] \
    || die "No factory ZIP found. Set HOM_FACTORY_ZIP=/path/to/factory.zip and re-run."

log "  Using factory ZIP: $FACTORY_ZIP"
reg_set factory HOM_FACTORY_ZIP_PATH "$FACTORY_ZIP"

# ── 2. List and validate outer ZIP ───────────────────────────

log "Inspecting outer factory ZIP..."

# Peek at ZIP contents to find the inner image ZIP
IMAGE_ZIP_ENTRY=$(unzip -l "$FACTORY_ZIP" 2>/dev/null | \
    awk '{print $NF}' | grep -i '^image-.*\.zip$' | head -1 || true)

if [ -z "$IMAGE_ZIP_ENTRY" ]; then
    # Some OEM ZIPs have the image ZIP in a subdirectory
    IMAGE_ZIP_ENTRY=$(unzip -l "$FACTORY_ZIP" 2>/dev/null | \
        awk '{print $NF}' | grep -i 'image-.*\.zip$' | head -1 || true)
fi

if [ -z "$IMAGE_ZIP_ENTRY" ]; then
    # Fallback: the ZIP itself may be the image ZIP (image-*.zip downloaded directly)
    _zip_name=$(basename "$FACTORY_ZIP")
    case "$_zip_name" in
        image-*.zip)
            log "  Factory ZIP appears to be a direct image ZIP (no outer wrapper)"
            IMAGE_ZIP_PATH="$FACTORY_ZIP"
            ;;
        *)
            die "Could not find an inner image-*.zip inside $FACTORY_ZIP. Is this a factory image?"
            ;;
    esac
else
    log "  Found inner image ZIP: $IMAGE_ZIP_ENTRY"
fi

# ── 3. Extract inner image ZIP to staging area ───────────────

_STAGE_DIR=$(mktemp -d "${TMPDIR:-${HOME:-/tmp}/tmp}/hom_factory_XXXXXXXX" 2>/dev/null \
             || mktemp -d /tmp/hom_factory_XXXXXXXX)

log "  Staging to: $_STAGE_DIR"

if [ -z "${IMAGE_ZIP_PATH:-}" ]; then
    log "  Extracting inner image ZIP from outer factory ZIP..."
    unzip -q "$FACTORY_ZIP" "$IMAGE_ZIP_ENTRY" -d "$_STAGE_DIR" 2>/dev/null \
        || die "Failed to extract $IMAGE_ZIP_ENTRY from $FACTORY_ZIP"
    IMAGE_ZIP_PATH="$_STAGE_DIR/$IMAGE_ZIP_ENTRY"
fi

[ -f "$IMAGE_ZIP_PATH" ] || die "Image ZIP not found after extraction: $IMAGE_ZIP_PATH"

log "  Image ZIP ready: $IMAGE_ZIP_PATH"
reg_set factory HOM_FACTORY_IMAGE_ZIP "$IMAGE_ZIP_PATH"

# List available entries in the image ZIP
_IMAGE_ENTRIES=$(unzip -l "$IMAGE_ZIP_PATH" 2>/dev/null | awk '{print $NF}' | tail -n +4 || true)
log "  Image ZIP entries: $(echo "$_IMAGE_ENTRIES" | wc -l | tr -d ' ') files"

# ── 4. Extract boot images ────────────────────────────────────

log "Extracting boot images..."

BOOT_IMG_DIR="$FACTORY_DUMP_DIR/boot_images"
mkdir -p "$BOOT_IMG_DIR"

_extract_image() {
    local entry="$1" dest="$2"
    if echo "$_IMAGE_ENTRIES" | grep -qxF "$entry" 2>/dev/null; then
        unzip -q -o "$IMAGE_ZIP_PATH" "$entry" -d "$_STAGE_DIR/images" 2>/dev/null && \
        cp "$_STAGE_DIR/images/$entry" "$dest" 2>/dev/null && {
            echo "boot_images/$(basename "$dest")" >> "$MANIFEST"
            log "  Extracted: $entry"
            return 0
        }
    fi
    return 1
}

# boot.img / init_boot.img
if _extract_image "init_boot.img" "$BOOT_IMG_DIR/init_boot.img"; then
    reg_set factory HOM_FACTORY_INIT_BOOT_IMG "$BOOT_IMG_DIR/init_boot.img"
    reg_set factory HOM_BOOT_IMG_PATH "$BOOT_IMG_DIR/init_boot.img"
    reg_set factory HOM_BOOT_IMG_METHOD "factory_zip"
elif _extract_image "boot.img" "$BOOT_IMG_DIR/boot.img"; then
    reg_set factory HOM_FACTORY_BOOT_IMG "$BOOT_IMG_DIR/boot.img"
    reg_set factory HOM_BOOT_IMG_PATH "$BOOT_IMG_DIR/boot.img"
    reg_set factory HOM_BOOT_IMG_METHOD "factory_zip"
else
    log "  [WARN] Neither init_boot.img nor boot.img found in image ZIP"
fi

# dtbo.img
_extract_image "dtbo.img" "$BOOT_IMG_DIR/dtbo.img" && \
    reg_set factory HOM_FACTORY_DTBO_IMG "$BOOT_IMG_DIR/dtbo.img" || true

# vbmeta.img
_extract_image "vbmeta.img" "$BOOT_IMG_DIR/vbmeta.img" && \
    reg_set factory HOM_FACTORY_VBMETA_IMG "$BOOT_IMG_DIR/vbmeta.img" || true

# vendor_boot.img (GKI devices)
_extract_image "vendor_boot.img" "$BOOT_IMG_DIR/vendor_boot.img" && \
    reg_set factory HOM_FACTORY_VENDOR_BOOT_IMG "$BOOT_IMG_DIR/vendor_boot.img" || true

reg_set factory HOM_FACTORY_BOOT_IMG_DIR "$BOOT_IMG_DIR"

# ── 5. Parse build.prop files ─────────────────────────────────

log "Extracting and parsing build.prop files..."

mkdir -p "$_STAGE_DIR/props"

_parse_build_prop() {
    local prop_file="$1" prop_label="$2"
    [ -f "$prop_file" ] || return 0
    log "  Parsing $prop_label ($prop_file)"
    copy_file_to "$prop_file" "$FACTORY_DUMP_DIR/props/$(basename "$prop_label").prop"

    while IFS='=' read -r k v; do
        case "$k" in
            ''|\#*) continue ;;
            ro.board.platform|ro.hardware|ro.product.board|ro.product.device|\
            ro.product.model|ro.build.fingerprint|ro.vendor.build.fingerprint|\
            ro.soc.manufacturer|ro.soc.model|ro.chipname|ro.arch|\
            ro.product.cpu.abi|ro.product.cpu.abilist|\
            ro.kernel.version|ro.build.version.release|\
            ro.build.version.sdk|ro.build.id|\
            ro.crypto.state|ro.crypto.type|\
            ro.product.name|ro.product.brand)
                ENV_KEY="HOM_PROP_$(echo "$k" | tr '.' '_' | tr '[:lower:]' '[:upper:]')"
                reg_set factory "$ENV_KEY" "$v"
                ;;
        esac
    done < "$prop_file"
}

# system/build.prop
_SYSPROP_ENTRY=$(echo "$_IMAGE_ENTRIES" | grep -i '^system/build\.prop$' | head -1 || true)
if [ -n "$_SYSPROP_ENTRY" ]; then
    unzip -q -o "$IMAGE_ZIP_PATH" "$_SYSPROP_ENTRY" -d "$_STAGE_DIR/props" 2>/dev/null || true
    _parse_build_prop "$_STAGE_DIR/props/$_SYSPROP_ENTRY" "system_build"
fi

# vendor/build.prop
_VENDPROP_ENTRY=$(echo "$_IMAGE_ENTRIES" | grep -i '^vendor/build\.prop$' | head -1 || true)
if [ -n "$_VENDPROP_ENTRY" ]; then
    unzip -q -o "$IMAGE_ZIP_PATH" "$_VENDPROP_ENTRY" -d "$_STAGE_DIR/props" 2>/dev/null || true
    _parse_build_prop "$_STAGE_DIR/props/$_VENDPROP_ENTRY" "vendor_build"
fi

# ── 6. Detect device info from ZIP filename if props are absent ─

log "Inferring device/build info from ZIP filename..."

_zip_basename=$(basename "$FACTORY_ZIP" .zip)
# Pixel factory ZIPs: <codename>-<build_id>-factory-<hash>.zip
# Image ZIPs: image-<codename>-<build_id>.zip
_detected_codename=""
_detected_build_id=""

case "$(basename "$IMAGE_ZIP_PATH" .zip)" in
    image-*-*)
        _stem="$(basename "$IMAGE_ZIP_PATH" .zip)"
        _stem="${_stem#image-}"                         # strip "image-"
        _detected_build_id="${_stem##*-}"               # last segment
        _detected_codename="${_stem%-*}"                # everything before last -
        ;;
esac

# Fallback: try outer ZIP name: <codename>-<build_id>-factory-<hash>
if [ -z "$_detected_codename" ]; then
    case "$_zip_basename" in
        *-*-factory-*)
            _detected_codename="${_zip_basename%%-*}"
            _detected_build_id="$(echo "$_zip_basename" | cut -d- -f2)"
            ;;
    esac
fi

[ -n "$_detected_codename" ] && {
    reg_set factory HOM_FACTORY_CODENAME "$_detected_codename"
    log "  Codename (from filename): $_detected_codename"
}
[ -n "$_detected_build_id" ] && {
    reg_set factory HOM_FACTORY_BUILD_ID "$_detected_build_id"
    log "  Build ID (from filename): $_detected_build_id"
}

# ── 7. Record execution context ───────────────────────────────

_uid=$(id -u 2>/dev/null || echo 9999)
reg_set shell HOM_EXEC_NODE "unprivileged_factory"
reg_set shell HOM_EXEC_UID "$_uid"
reg_set factory HOM_RECOVERY_MODE "F"
reg_set factory HOM_FACTORY_DUMP_DIR "$FACTORY_DUMP_DIR"
reg_set factory HOM_FACTORY_MANIFEST "$MANIFEST"

# ── 8. Hardware data sanity check ────────────────────────────

_hw_env="factory_zip"
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux/files/usr" ]; then
    _hw_env="termux_factory_zip"
fi
if [ -z "$(getprop ro.product.model 2>/dev/null)" ] && [ ! -f /system/build.prop ]; then
    _hw_env="sandbox_factory_zip"
    log "[INFO ] Running in sandbox/CI — factory ZIP data only, no live device properties."
fi
reg_set collect HOM_HW_ENV "$_hw_env"
log "[INFO ] hw_env=$_hw_env recorded to env registry."

# ── done ─────────────────────────────────────────────────────

TOTAL=$(wc -l < "$MANIFEST")
VAR_COUNT=$(grep -c "mode:F" "$ENV_REGISTRY" 2>/dev/null || echo 0)
log "=== collect_factory.sh complete: $TOTAL files, $VAR_COUNT env vars written ==="
log ""
log "Next step: run pipeline/unpack_images.py to unpack the extracted images."
log "  Image dir: $BOOT_IMG_DIR"
log "  Registry : $ENV_REGISTRY"
