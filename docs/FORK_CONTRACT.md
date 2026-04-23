# hands-on-metal — Cross-Fork / Cross-Repo Contract

**Schema version: 1.0.0**

Every fork of `hands-on-metal` MUST use the variable names, log formats,
field meanings, and file paths defined in this document. Variables with the
same name always mean exactly the same thing across all forks. Forks that
add new variables must prefix them with `HOM_` and submit an entry to the
device candidate database (see [GOVERNANCE.md](GOVERNANCE.md)).

---

## 1. Canonical env-registry variable dictionary

All variables are written to `/sdcard/hands-on-metal/env_registry.sh`
as `KEY="VALUE"  # cat:<category>`.

### 1.1 Device identity (`cat:device`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_DEV_MODEL` | string | Marketing model name (`ro.product.model`) |
| `HOM_DEV_BRAND` | string | Manufacturer brand (`ro.product.brand`) |
| `HOM_DEV_DEVICE` | string | Board / codename (`ro.product.device`) |
| `HOM_DEV_CODENAME` | string | Product name (`ro.product.name`) |
| `HOM_DEV_FINGERPRINT` | string | Build fingerprint (`ro.build.fingerprint`) |
| `HOM_DEV_FIRST_API_LEVEL` | int | API level device shipped with |
| `HOM_DEV_SDK_INT` | int | Current SDK integer |
| `HOM_DEV_ANDROID_VER` | string | Android version string (e.g. `14`) |
| `HOM_DEV_SPL` | YYYY-MM-DD | Security patch level |
| `HOM_DEV_BUILD_ID` | string | Build ID (e.g. `AP4A.250405.002`) — used for factory image downloads |
| `HOM_DEV_IS_AB` | bool | `true` if A/B (seamless) updates |
| `HOM_DEV_SLOT_SUFFIX` | string | `_a` or `_b` or empty |
| `HOM_DEV_CURRENT_SLOT` | string | Human-readable current slot |
| `HOM_DEV_SAR` | bool/likely | System-as-Root enabled |
| `HOM_DEV_DYNAMIC_PARTITIONS` | bool | Uses dynamic/super partitions |
| `HOM_DEV_TREBLE_ENABLED` | bool | Project Treble compliance |
| `HOM_DEV_TREBLE_VINTF_VER` | string | VNDK/VINTF version |
| `HOM_DEV_AVB_VERSION` | string | AVB version from bootloader |
| `HOM_DEV_AVB_STATE` | string | `green`/`yellow`/`orange`/`red` |
| `HOM_DEV_AVB_ALGO` | string | AVB algorithm from vbmeta |
| `HOM_DEV_BOOT_PART` | string | Partition to patch: `boot` or `init_boot` |
| `HOM_DEV_BOOT_DEV` | path | Block device for boot |
| `HOM_DEV_INIT_BOOT_DEV` | path | Block device for init_boot |
| `HOM_DEV_VENDOR_BOOT_DEV` | path | Block device for vendor_boot |
| `HOM_DEV_SOC_MFR` | string | SoC manufacturer |
| `HOM_DEV_SOC_MODEL` | string | SoC model number |
| `HOM_DEV_PLATFORM` | string | `ro.board.platform` |
| `HOM_DEV_HARDWARE` | string | `ro.hardware` |

### 1.2 Boot image (`cat:boot`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_BOOT_IMG_PATH` | path | Local copy of unpatched boot image |
| `HOM_BOOT_IMG_SHA256` | hex | SHA-256 of unpatched image |
| `HOM_BOOT_PART_SRC` | path | Block device or source the image was obtained from |
| `HOM_BOOT_IMG_METHOD` | enum | How the image was acquired: `root_dd`, `pre_placed`, `factory_download`, `user_prompt` |
| `HOM_BOOT_IMG_HAS_CURL` | bool | Whether curl is available for downloads |
| `HOM_BOOT_IMG_HAS_UNZIP` | bool | Whether unzip is available for extraction |

### 1.3 Anti-rollback (`cat:avb`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_ARB_MAY2026_ACTIVE` | bool | SPL >= 2026-05-07 |
| `HOM_ARB_IMG_SPL` | YYYY-MM-DD or UNKNOWN | SPL in image header |
| `HOM_ARB_ROLLBACK_RISK` | bool | Image SPL < device SPL |
| `HOM_ARB_DEV_ROLLBACK_IDX` | int or UNKNOWN | AVB rollback index |
| `HOM_ARB_REQUIRE_MAY2026_FLAGS` | bool | Must use PATCHVBMETAFLAG |

### 1.4 Magisk patch (`cat:magisk`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_MAGISK_BIN` | path | Magisk binary used for patching |
| `HOM_MAGISK_VERSION` | string | Magisk version string |
| `HOM_MAGISK_VER_CODE` | int | Magisk numeric version code |
| `HOM_PATCHED_IMG_PATH` | path | Magisk-patched boot image |
| `HOM_PATCHED_IMG_SHA256` | hex | SHA-256 of patched image |

### 1.5 Flash (`cat:flash`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_FLASH_PRE_SHA256` | hex | Block device SHA-256 before flash |
| `HOM_FLASH_POST_SHA256` | hex | Block device SHA-256 after flash |
| `HOM_FLASH_STATUS` | OK/FAIL | Final flash result |

### 1.6 Shell environment (`cat:shell`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_SHELL_PATH` | path | Resolved path to `sh` |
| `HOM_SHELL_BANNER` | string | Shell version banner |
| `HOM_MAGISK_BIN` | path | Magisk binary path |
| `HOM_BUSYBOX` | path or MISSING | Busybox path |
| `HOM_TOOL_<TOOL>` | path or MISSING | Per-tool availability |
| `HOM_WHOAMI` | string | Output of `id` command |
| `HOM_SELINUX_CONTEXT` | string | Current SELinux context |
| `HOM_SELINUX_ENFORCE` | 0/1 | SELinux enforcing mode |
| `HOM_ENV_CLASS` | magisk/recovery/host | Install environment class |

### 1.7 Python / Termux (`cat:python`, `cat:termux`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_PYTHON_CANONICAL` | path | Best available Python binary |
| `HOM_PYTHON_VERSION` | string | Python version |
| `HOM_PYTHON_COUNT` | int | Number of Python installs found |
| `HOM_TERMUX_INSTALLED` | bool | Termux APK present |
| `HOM_TERMUX_PREFIX` | path | Termux `usr/` prefix |
| `HOM_TERMUX_PYTHON` | path | Termux Python binary |
| `HOM_TERMUX_SHOULD_INSTALL` | bool | Termux install needed |

### 1.8 Paths (`cat:path`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_OUT_DIR` | path | `/sdcard/hands-on-metal` |
| `HOM_ENV_REGISTRY` | path | `env_registry.sh` path |
| `HOM_LIVE_DUMP` | path | Live hardware dump directory |
| `HOM_BLOCK_BY_NAME` | path | `/dev/block/*/by-name` directory |

### 1.9 Privacy (`cat:privacy`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_PRIVACY_REDACT` | bool | `true` = PII redaction enabled (default) |
| `HOM_PRIVACY_OPT_IN_FULL` | bool | `true` = user consented to unredacted upload |

### 1.10 Crypto (`cat:crypto`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_CRYPTO_STATE` | string | `encrypted`/`unencrypted` |
| `HOM_CRYPTO_TYPE` | string | `FBE`/`FDE` |
| `HOM_CRYPTO_FILENAMES_MODE` | string | Filename encryption mode |
| `HOM_VOLD_DECRYPT` | string | vold decrypt state |

### 1.11 Recovery (`cat:recovery`)

| Variable | Type | Description |
|----------|------|-------------|
| `HOM_RECOVERY_MODE` | string | `B` (recovery mode) |
| `HOM_RECOVERY_DUMP_DIR` | path | Recovery dump output path |
| `HOM_USERDATA_DECRYPTED` | bool | /data readable in recovery |
| `HOM_DT_COMPATIBLE` | string | Root DT compatible string |
| `HOM_DT_MODEL` | string | DT model string |

---

## 2. Log file format (versioned)

**Format version: 1.0**

### 2.1 Master log (`logs/master_<RUN_ID>.log`)

Each line follows this exact format (space-padded level field):

```
[YYYY-MM-DDTHH:MM:SSZ][LEVEL][SCRIPT_NAME] message
```

Level values (exactly as written, 5 chars + trailing space):
- `INFO ` — informational
- `WARN ` — non-fatal warning
- `ERROR` — error condition
- `DEBUG` — debug (omitted from stderr)
- `VAR  ` — variable audit entry
- `EXEC ` — command execution output

### 2.2 Variable audit log (`logs/var_audit_<RUN_ID>.txt`)

One line per variable:

```
[YYYY-MM-DDTHH:MM:SSZ][VAR  ][SCRIPT_NAME] NAME="VALUE"  # description
```

If `HOM_PRIVACY_REDACT=true` and the variable matches a PII pattern, value is `#`.

### 2.3 Run manifest (`logs/run_manifest_<RUN_ID>.txt`)

One pipe-separated row per step result:

```
YYYY-MM-DDTHH:MM:SSZ|step_name|STATUS|optional note
```

STATUS values: `OK`, `FAIL`, `SKIP`, `PENDING`

### 2.4 Per-script log (`logs/<script_name>_<RUN_ID>.log`)

Same format as the master log, but filtered to lines from that script.

---

## 3. Device candidate record format

Candidate records are created by `core/candidate_entry.sh` when an unknown
device/Android combination is detected. Each record is a JSON file at:

```
/sdcard/hands-on-metal/candidates/<brand>_<device>_api<sdk_int>_<RUN_ID>.json
```

**Schema version 1.0** (all fields from `HOM_DEV_*` registry variables):

```json
{
  "schema_version": "1.0",
  "run_id": "20260101T120000Z",
  "submitted_at": "YYYY-MM-DDTHH:MM:SSZ",
  "device": {
    "brand": "...",
    "model": "...",
    "device": "...",
    "codename": "...",
    "fingerprint": "...",  // redacted if HOM_PRIVACY_REDACT=true
    "android_version": "...",
    "api_level": 0,
    "first_api_level": 0,
    "spl": "YYYY-MM-DD",
    "soc_manufacturer": "...",
    "soc_model": "...",
    "platform": "...",
    "hardware": "...",
    "is_ab": false,
    "slot_suffix": "...",
    "dynamic_partitions": false,
    "treble_enabled": false,
    "vndk_version": "...",
    "avb_version": "...",
    "avb_state": "...",
    "boot_partition": "...",
    "boot_dev": "...",
    "init_boot_dev": "...",
    "vendor_boot_dev": "..."
  },
  "partition_index_family_matched": "none|<family_name>",
  "install_result": "OK|FAIL|PARTIAL",
  "failure_step": "...",
  "failure_message": "...",
  "suggested_family": "...",
  "notes": "auto-generated candidate — needs maintainer review"
}
```

---

## 4. Error record format

Error records are generated by `pipeline/failure_analysis.py`:

```json
{
  "run_id": "...",
  "analyzed_at": "...",
  "failures": [
    {
      "step": "...",
      "error_message": "...",
      "probable_cause": "...",
      "confidence": 0.0,
      "remediation": ["step1", "step2"],
      "signature_id": "..."
    }
  ],
  "device_snapshot": { ... },
  "redacted": true
}
```

---

## 5. Compatibility spec versioning

The `_version` field in `build/partition_index.json` tracks the spec version.
Forks MUST check this version at runtime and warn if their bundled index is
older than what the device database reports.

Use `HOM_PARTITION_INDEX_VERSION` in the env registry to record the version
of the bundled index in use.

---

## 6. Fork compliance checklist

A fork is compliant with this contract if it:

- [ ] Uses all `HOM_DEV_*` variable names exactly as specified above
- [ ] Writes log lines in the exact format described in Section 2
- [ ] Writes the run manifest with pipe-separated fields
- [ ] Creates candidate records when unknown device/version is detected
- [ ] Sets `HOM_PRIVACY_REDACT=true` by default
- [ ] Does not commit personal data to git history
- [ ] Checks `partition_index.json` schema version before use
