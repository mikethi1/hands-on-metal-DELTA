#!/system/bin/sh
# core/magisk_patch.sh
# shellcheck disable=SC3043  # local is supported by Android mksh and BusyBox ash
# ============================================================
# Magisk boot image patch orchestration.
#
# Workflow:
#   1. Locate the Magisk binary (from PATH, /data/adb/magisk/,
#      or the bundled offline copy in the ZIP).
#   2. Determine device-specific patch flags.
#   3. Apply anti-rollback–aware patch options when required.
#   4. Run magisk --patch-boot (or the boot-patcher script).
#   5. Validate the patched image (magic + size sanity).
#   6. Record the patched image path and SHA-256.
#
# Requires: logging.sh, ux.sh, anti_rollback.sh (check run first)
#
# ENV_REGISTRY variables consumed:
#   HOM_BOOT_IMG_PATH           — unpatched image
#   HOM_DEV_BOOT_PART           — boot | init_boot
#   HOM_DEV_IS_AB               — true/false
#   HOM_DEV_SAR                 — true/false
#   HOM_DEV_AVB_STATE           — AVB state
#   HOM_ARB_REQUIRE_MAY2026_FLAGS — true/false
#
# ENV_REGISTRY variables written:
#   HOM_PATCHED_IMG_PATH        — path to patched image
#   HOM_PATCHED_IMG_SHA256      — SHA-256 of patched image
#   HOM_MAGISK_BIN              — Magisk binary used
#   HOM_MAGISK_VERSION          — Magisk version string
# ============================================================

# shellcheck disable=SC2034  # consumed by core/logging.sh when sourced
SCRIPT_NAME="magisk_patch"

OUT="${OUT:-$HOME/hands-on-metal}"
ENV_REGISTRY="${ENV_REGISTRY:-$OUT/env_registry.sh}"
BOOT_WORK_DIR="$OUT/boot_work"

# tools/ directory where build/fetch_all_deps.sh places all Magisk binaries.
# Preferred over /data/adb/magisk/ because it works without root (Termux).
# Resolution order: REPO_ROOT → MODPATH → OUT → current directory.
_HOM_TOOLS_DIR="${REPO_ROOT:+$REPO_ROOT/tools}"
[ -z "$_HOM_TOOLS_DIR" ] && [ -n "${MODPATH:-}" ] \
    && _HOM_TOOLS_DIR="$(cd "$MODPATH/.." 2>/dev/null && pwd)/tools"
[ -z "$_HOM_TOOLS_DIR" ] && _HOM_TOOLS_DIR="${OUT:-$HOME/hands-on-metal}/tools"

# Bundled offline Magisk binaries (placed by build/fetch_all_deps.sh).
# Defaults point to tools/ first (no-root Termux); /data/adb/magisk/ is the
# rooted-device fallback and is checked separately inside the _find_* helpers.
BUNDLED_MAGISK="${BUNDLED_MAGISK:-$_HOM_TOOLS_DIR/magisk64}"
BUNDLED_MAGISK32="${BUNDLED_MAGISK32:-$_HOM_TOOLS_DIR/magisk32}"
BUNDLED_MAGISKINIT="${BUNDLED_MAGISKINIT:-$_HOM_TOOLS_DIR/magiskinit}"
BUNDLED_MAGISKBOOT="${BUNDLED_MAGISKBOOT:-$_HOM_TOOLS_DIR/magiskboot}"
BUNDLED_BOOT_PATCH_SH="${BUNDLED_BOOT_PATCH_SH:-$_HOM_TOOLS_DIR/boot_patch.sh}"
# stub.apk — Magisk v27+: embedded into the ramdisk by magiskboot during patch.
BUNDLED_STUB_APK="${BUNDLED_STUB_APK:-$_HOM_TOOLS_DIR/stub.apk}"
# init-ld  — Magisk v27+: ELF binary injected into the ramdisk as the new init.
BUNDLED_INIT_LD="${BUNDLED_INIT_LD:-$_HOM_TOOLS_DIR/init-ld}"

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
        echo "UNAVAILABLE"
    fi
}

_dir_writable() {
    local dir="$1"
    local probe="$dir/.boot_magisk_write_probe_$$"
    [ -n "$dir" ] || return 1
    mkdir -p "$dir" 2>/dev/null || true
    [ -d "$dir" ] || return 1
    # Use touch (external command) rather than `: > "$probe"` so that the
    # shell's own file-open error is not printed to the terminal on mksh/ash
    # even when 2>/dev/null is appended.
    if touch "$probe" 2>/dev/null; then
        rm -f "$probe" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Locate the best available Magisk binary.
_find_magisk() {
    # 1. PATH
    local mg; mg=$(command -v magisk 2>/dev/null || true)
    [ -x "$mg" ] && { echo "$mg"; return 0; }

    # 2. Standard Magisk install locations
    for try in \
        /data/adb/magisk/magisk64 \
        /data/adb/magisk/magisk32 \
        /data/adb/magisk/magisk \
        /sbin/magisk \
        /system/bin/magisk; do
        [ -x "$try" ] && { echo "$try"; return 0; }
    done

    # 3. Bundled offline copy
    for try in "$BUNDLED_MAGISK" "$BUNDLED_MAGISK32"; do
        [ -x "$try" ] && { echo "$try"; return 0; }
    done

    # 4. Binaries fetched by build/fetch_all_deps.sh (tools/)
    local base
    for base in "${REPO_ROOT:-}" "${MODPATH:-}" "${OUT:-}" "${PWD:-}"; do
        [ -n "$base" ] || continue
        for try in \
            "$base/tools/magisk64" \
            "$base/tools/magisk32" \
            "$base/magisk64" \
            "$base/magisk32"; do
            [ -x "$try" ] && { echo "$try"; return 0; }
        done
    done

    return 1
}

# Locate magiskboot — the low-level boot image tool used by boot_patch.sh.
# Works without root; reads/writes boot image files directly.
_find_magiskboot() {
    # 1. PATH
    local mb; mb=$(command -v magiskboot 2>/dev/null || true)
    [ -x "$mb" ] && { echo "$mb"; return 0; }

    # 2. Standard Magisk install locations
    for try in \
        /data/adb/magisk/magiskboot \
        /sbin/magiskboot \
        /system/bin/magiskboot; do
        [ -x "$try" ] && { echo "$try"; return 0; }
    done

    # 3. Bundled copy
    [ -x "$BUNDLED_MAGISKBOOT" ] && { echo "$BUNDLED_MAGISKBOOT"; return 0; }

    # 4. Tools directories
    local base
    for base in "${REPO_ROOT:-}" "${MODPATH:-}" "${OUT:-}" "${PWD:-}"; do
        [ -n "$base" ] || continue
        for try in \
            "$base/tools/magiskboot" \
            "$base/magiskboot"; do
            [ -x "$try" ] && { echo "$try"; return 0; }
        done
    done

    return 1
}

# Locate Magisk's boot_patch.sh script.
# Works without root; sets env vars to control patch behaviour.
_find_boot_patch_sh() {
    # 1. Standard Magisk install locations
    for try in \
        /data/adb/magisk/boot_patch.sh \
        /data/adb/magisk.d/boot_patch.sh; do
        [ -f "$try" ] && { echo "$try"; return 0; }
    done

    # 2. Bundled copy
    [ -f "$BUNDLED_BOOT_PATCH_SH" ] && { echo "$BUNDLED_BOOT_PATCH_SH"; return 0; }

    # 3. Tools directories
    local base
    for base in "${REPO_ROOT:-}" "${MODPATH:-}" "${OUT:-}" "${PWD:-}"; do
        [ -n "$base" ] || continue
        for try in \
            "$base/tools/boot_patch.sh" \
            "$base/boot_patch.sh"; do
            [ -f "$try" ] && { echo "$try"; return 0; }
        done
    done

    return 1
}

# Validate patched image (Android boot magic present and size >= original).
_validate_patched() {
    local orig="$1" patched="$2"
    [ -f "$patched" ] || return 1

    # Magic check
    local magic; magic=$(dd if="$patched" bs=1 count=8 2>/dev/null | cat)
    case "$magic" in
        ANDROID!|VNDRBOOT) ;;
        *) log_warn "Patched image magic unexpected"; return 1 ;;
    esac

    # Size sanity: patched must be >= 50% of original
    local orig_sz patched_sz
    orig_sz=$(wc -c < "$orig" 2>/dev/null || echo 0)
    patched_sz=$(wc -c < "$patched" 2>/dev/null || echo 0)

    if [ "$orig_sz" -gt 0 ] && [ "$patched_sz" -lt $((orig_sz / 2)) ]; then
        log_error "Patched image is less than 50% of original size (orig=$orig_sz patched=$patched_sz)"
        return 1
    fi

    return 0
}

# ── main function ─────────────────────────────────────────────

run_magisk_patch() {
    ux_section "Magisk Boot Image Patching"
    ux_step_info "Magisk Patch" \
        "Patches the boot/init_boot image with Magisk's root payload" \
        "The patched image, when flashed, gives Magisk persistent root access while \
passing AVB verification through the correct flags"

    # ── 1. Read prerequisites from env registry ───────────────

    local boot_img boot_part is_ab sar avb_state may2026_flags
    boot_img=$(_reg_get HOM_BOOT_IMG_PATH)
    boot_part=$(_reg_get HOM_DEV_BOOT_PART)
    is_ab=$(_reg_get HOM_DEV_IS_AB)
    sar=$(_reg_get HOM_DEV_SAR)
    avb_state=$(_reg_get HOM_DEV_AVB_STATE)
    may2026_flags=$(_reg_get HOM_ARB_REQUIRE_MAY2026_FLAGS)

    log_var "boot_img"     "$boot_img"     "image to be patched"
    log_var "boot_part"    "$boot_part"    "partition type being patched"
    log_var "is_ab"        "$is_ab"        "A/B slot device"
    log_var "sar"          "$sar"          "System-as-Root"
    log_var "avb_state"    "$avb_state"    "AVB verified boot state"
    log_var "may2026_flags" "$may2026_flags" "require May-2026 compatible patch flags"

    if [ -z "$boot_img" ] || [ ! -f "$boot_img" ]; then
        ux_abort "Magisk patch: boot image not found at '$boot_img'. Run boot image acquisition first."
    fi

    # ── 2. Find Magisk binary ─────────────────────────────────

    local magisk_bin
    magisk_bin=$(_find_magisk) || \
        ux_abort "Magisk binary not found. Ensure Magisk is installed or the offline bundle is complete."

    local magisk_ver
    magisk_ver=$("$magisk_bin" -v 2>/dev/null | head -1 || echo "unknown")
    local magisk_ver_code
    magisk_ver_code=$("$magisk_bin" -V 2>/dev/null | head -1 || echo "0")

    _reg_set magisk HOM_MAGISK_BIN        "$magisk_bin"
    _reg_set magisk HOM_MAGISK_VERSION    "$magisk_ver"
    _reg_set magisk HOM_MAGISK_VER_CODE   "$magisk_ver_code"

    log_var "HOM_MAGISK_BIN"      "$magisk_bin"      "Magisk binary path"
    log_var "HOM_MAGISK_VERSION"  "$magisk_ver"      "Magisk version string"
    log_var "HOM_MAGISK_VER_CODE" "$magisk_ver_code" "Magisk numeric version code"

    ux_print "  Magisk binary: $magisk_bin"
    ux_print "  Magisk version: $magisk_ver (code: $magisk_ver_code)"

    # ── May-2026 Magisk version gate (re-check) ──────────────
    # anti_rollback.sh may have set HOM_ARB_REQUIRE_MAY2026_FLAGS
    # before the Magisk binary was located.  Now that we know the
    # real version code, enforce the minimum again.
    if [ "$may2026_flags" = "true" ]; then
        local min_code=30700
        if [ "$magisk_ver_code" -lt "$min_code" ] 2>/dev/null; then
            ux_abort "Magisk $magisk_ver_code too old for May-2026 anti-rollback policy (need >= $min_code / v30.7). Upgrade Magisk before proceeding."
        fi
        log_info "Magisk version $magisk_ver_code >= $min_code — OK for May-2026 policy"
    fi

    # ── 3. Build patch flags ──────────────────────────────────

    # MAGISK_PATCH_FLAGS environment variables control magisk --boot-patch.
    # Reference: https://github.com/topjohnwu/Magisk/blob/master/scripts/boot_patch.sh
    export KEEPVERITY="false"
    export KEEPFORCEENCRYPT="false"
    export PATCHVBMETAFLAG="false"
    export RECOVERYMODE="false"
    export LEGACYSAR="false"

    # A/B: keep vbmeta intact so the other slot stays bootable
    if [ "$is_ab" = "true" ]; then
        KEEPVERITY="true"
        log_info "A/B device: KEEPVERITY=true"
    fi

    # SAR: legacy SAR devices need the legacy flag
    if [ "$sar" = "true" ] && [ "${boot_part}" = "boot" ]; then
        LEGACYSAR="true"
        log_info "SAR device with boot partition: LEGACYSAR=true"
    fi

    # May-2026 policy: patch the vbmeta flag in the boot image header
    # and preserve the security patch level / rollback index.
    if [ "$may2026_flags" = "true" ]; then
        PATCHVBMETAFLAG="true"
        log_info "May-2026 policy active: PATCHVBMETAFLAG=true"
        ux_print "  May-2026 flag: PATCHVBMETAFLAG=true (required for SPL >= 2026-05-07)"
    fi

    # Force-encrypt: keep it enabled so /data stays encrypted after root
    KEEPFORCEENCRYPT="true"

    log_var "KEEPVERITY"         "$KEEPVERITY"         "do not strip dm-verity from vbmeta"
    log_var "KEEPFORCEENCRYPT"   "$KEEPFORCEENCRYPT"   "preserve forceencrypt flag on /data"
    log_var "PATCHVBMETAFLAG"    "$PATCHVBMETAFLAG"    "patch vbmeta flag in boot header (May-2026)"
    log_var "RECOVERYMODE"       "$RECOVERYMODE"       "patch as recovery image"
    log_var "LEGACYSAR"          "$LEGACYSAR"          "legacy system-as-root handling"

    export KEEPVERITY KEEPFORCEENCRYPT PATCHVBMETAFLAG RECOVERYMODE LEGACYSAR

    ux_print "  Patch flags:"
    ux_print "    KEEPVERITY=$KEEPVERITY"
    ux_print "    KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT"
    ux_print "    PATCHVBMETAFLAG=$PATCHVBMETAFLAG"
    ux_print "    LEGACYSAR=$LEGACYSAR"

    # ── 4. Run Magisk patch ───────────────────────────────────

    local patched_img="$BOOT_WORK_DIR/${boot_part}_patched.img"

    # Preferred path: boot_patch.sh + magiskboot.
    # Works without root — reads and writes boot image files directly.
    # Magisk v26+ removed --boot-patch from the main binary; this is the
    # correct offline API for all versions from v25 onward.
    #
    # Fallback: magisk --boot-patch (only works on older builds where the
    # standalone binary still includes the subcommand).

    ux_print "  Running Magisk patch (this may take 30–60 seconds)..."

    local stage_dir_candidates
    stage_dir_candidates=$(printf '%s\n' \
        "${TMPDIR:-}" \
        "$BOOT_WORK_DIR" \
        "/data/local/tmp" \
        "${HOME:-}/tmp" \
        "${PWD:-.}")

    local search_dir
    local magisk_out_dir
    magisk_out_dir=""
    while IFS= read -r search_dir; do
        [ -n "$search_dir" ] || continue
        if _dir_writable "$search_dir"; then
            magisk_out_dir="$search_dir"
            break
        fi
    done << EOF
$stage_dir_candidates
EOF
    [ -n "$magisk_out_dir" ] || ux_abort "No writable staging directory available for Magisk patching."
    ux_print "  Magisk staging dir: $magisk_out_dir"

    local patch_rc=0
    local found_patched=""
    local f

    # ── Locate boot_patch.sh + magiskboot ────────────────────────
    # All three siblings (magisk64/magisk32, magiskboot, boot_patch.sh) are
    # placed in the same tools/ dir by the build scripts, so check alongside
    # the already-resolved magisk_bin first before doing a wider search.
    local magiskboot_bin boot_patch_sh _magisk_dir
    _magisk_dir="$(dirname "$magisk_bin")"
    magiskboot_bin=$(_find_magiskboot 2>/dev/null || true)
    [ -z "$magiskboot_bin" ] && [ -x "$_magisk_dir/magiskboot" ] \
        && magiskboot_bin="$_magisk_dir/magiskboot"
    boot_patch_sh=$(_find_boot_patch_sh 2>/dev/null || true)
    [ -z "$boot_patch_sh" ] && [ -f "$_magisk_dir/boot_patch.sh" ] \
        && boot_patch_sh="$_magisk_dir/boot_patch.sh"

    if [ -x "$magiskboot_bin" ] && [ -f "$boot_patch_sh" ]; then
        log_info "boot_patch.sh path: $boot_patch_sh  magiskboot: $magiskboot_bin"

        # boot_patch.sh resolves sibling binaries via MAGISKBIN=$(dirname $0),
        # so we copy everything into an isolated work directory.
        local work_dir="$magisk_out_dir/magisk_patch_work_${RUN_ID:-$$}"
        mkdir -p "$work_dir" || ux_abort "Cannot create patch work dir: $work_dir"

        cp "$magiskboot_bin" "$work_dir/magiskboot" && chmod +x "$work_dir/magiskboot"
        cp "$boot_patch_sh"  "$work_dir/boot_patch.sh"

        # util_functions.sh — sourced by boot_patch.sh when present
        local util_fn
        util_fn="$(dirname "$boot_patch_sh")/util_functions.sh"
        [ -f "$util_fn" ] && cp "$util_fn" "$work_dir/util_functions.sh"

        # Magisk payload binary — boot_patch.sh calls it as 'magisk'
        if cp "$magisk_bin" "$work_dir/magisk" 2>/dev/null; then
            chmod +x "$work_dir/magisk" 2>/dev/null || true
        fi

        # magiskinit — injected into the boot ramdisk as the new init binary
        local try
        for try in \
            "$_magisk_dir/magiskinit" \
            "$_magisk_dir/magiskinit64" \
            "$BUNDLED_MAGISKINIT" \
            /data/adb/magisk/magiskinit; do
            if [ -x "$try" ]; then
                cp "$try" "$work_dir/magiskinit" && chmod +x "$work_dir/magiskinit"
                break
            fi
        done

        # stub.apk — required by magiskboot for ramdisk injection (Magisk v27+)
        for try in \
            "$_magisk_dir/stub.apk" \
            "$BUNDLED_STUB_APK" \
            /data/adb/magisk/stub.apk; do
            if [ -f "$try" ]; then
                cp "$try" "$work_dir/stub.apk"
                log_info "Copied stub.apk from $try"
                break
            fi
        done
        [ -f "$work_dir/stub.apk" ] || \
            log_warn "stub.apk not found — ramdisk patch will likely fail on Magisk v27+"

        # init-ld — ELF binary injected into the boot ramdisk (Magisk v27+)
        for try in \
            "$_magisk_dir/init-ld" \
            "$BUNDLED_INIT_LD" \
            /data/adb/magisk/init-ld; do
            if [ -f "$try" ]; then
                cp "$try" "$work_dir/init-ld" && chmod +x "$work_dir/init-ld"
                log_info "Copied init-ld from $try"
                break
            fi
        done
        [ -f "$work_dir/init-ld" ] || \
            log_warn "init-ld not found — ramdisk patch will likely fail on Magisk v27+"

        local img_in="$work_dir/${boot_part}.img"
        cp "$boot_img" "$img_in" || ux_abort "Cannot copy boot image to patch work dir"

        log_exec "magisk_boot_patch" \
            env TMPDIR="$work_dir" \
                OUTFD="${OUTFD:-2}" \
                KEEPVERITY="$KEEPVERITY" \
                KEEPFORCEENCRYPT="$KEEPFORCEENCRYPT" \
                PATCHVBMETAFLAG="$PATCHVBMETAFLAG" \
                RECOVERYMODE="$RECOVERYMODE" \
                LEGACYSAR="$LEGACYSAR" \
            sh "$work_dir/boot_patch.sh" "$img_in"
        patch_rc=$?

        # boot_patch.sh writes new-boot.img into TMPDIR (work_dir)
        for f in "$work_dir/new-boot.img" "$work_dir"/magisk_patched_*.img; do
            [ -f "$f" ] && { found_patched="$f"; break; }
        done
        [ -n "$found_patched" ] && mv "$found_patched" "$patched_img"
        rm -rf "$work_dir"

    else
        # ── Fallback: magisk --boot-patch (older / rooted builds) ────
        log_warn "magiskboot/boot_patch.sh not found — falling back to magisk --boot-patch"
        local tmp_input="$magisk_out_dir/boot_magisk_${boot_part}_in_${RUN_ID:-$$}.img"
        cp "$boot_img" "$tmp_input" 2>/dev/null || \
            ux_abort "Could not copy boot image to staging dir: $magisk_out_dir"

        log_exec "magisk_boot_patch" \
            env TMPDIR="$magisk_out_dir" "$magisk_bin" --boot-patch "$tmp_input"
        patch_rc=$?

        for f in "$magisk_out_dir"/magisk_patched_*.img; do
            [ -f "$f" ] && { found_patched="$f"; break; }
        done
        while [ -z "$found_patched" ] && IFS= read -r search_dir; do
            [ -n "$search_dir" ] || continue
            [ "$search_dir" = "$magisk_out_dir" ] && continue
            for f in "$search_dir"/magisk_patched_*.img; do
                [ -f "$f" ] && { found_patched="$f"; break; }
            done
            [ -n "$found_patched" ] && break
        done << EOF
$stage_dir_candidates
EOF
        if [ -n "$found_patched" ]; then
            mv "$found_patched" "$patched_img"
        fi
        rm -f "$tmp_input"
    fi

    [ -f "$patched_img" ] && log_info "Magisk patched output: $patched_img"

    if [ ! -f "$patched_img" ]; then
        ux_abort "Magisk patch produced no output image (rc=$patch_rc). Check logs at $LOG_DIR."
    fi

    # ── 5. Validate patched image ─────────────────────────────

    ux_print "  Validating patched image..."
    if ! _validate_patched "$boot_img" "$patched_img"; then
        ux_abort "Patched image failed validation. Do NOT flash. Check $SCRIPT_LOG."
    fi

    # ── 6. Record patched image details ──────────────────────

    local patched_sha256
    patched_sha256=$(_sha256 "$patched_img")

    _reg_set magisk HOM_PATCHED_IMG_PATH   "$patched_img"
    _reg_set magisk HOM_PATCHED_IMG_SHA256 "$patched_sha256"

    log_var "HOM_PATCHED_IMG_PATH"   "$patched_img"    "path to the Magisk-patched boot image"
    log_var "HOM_PATCHED_IMG_SHA256" "$patched_sha256" "SHA-256 of patched image"

    ux_print "  Patched image: $patched_img"
    ux_print "  SHA-256 (patched): $patched_sha256"

    ux_step_result "Magisk Patch" "OK" \
        "patched image ready at $patched_img"
    manifest_step "magisk_patch" "OK" \
        "out=$patched_img sha256=$patched_sha256 may2026=$may2026_flags"
}
