# hands-on-metal — Governance Guide

This document defines the process for:
1. Reviewing and approving new device/version candidate entries
2. Propagating approved entries to forks
3. Modifying scripts based on log-driven failure evidence
4. Compatibility spec version management

See also: [FORK_CONTRACT.md](FORK_CONTRACT.md), [SUPPORT_POLICY.md](SUPPORT_POLICY.md)

---

## 1. New device / Android version onboarding

### 1.1 How candidates are created

When `core/candidate_entry.sh` runs and finds no matching family in
`build/partition_index.json`, it:

1. Collects all `HOM_DEV_*` variables from the env registry.
2. Writes a JSON candidate file to `/sdcard/hands-on-metal/candidates/`.
3. If `GITHUB_TOKEN` is available, opens a GitHub issue using the
   [New Device template](.github/ISSUE_TEMPLATE/new_device.yml).

### 1.2 Maintainer review checklist

Before adding a new `device_families` entry to `partition_index.json`:

- [ ] Verify `brand`, `model`, `device`, `soc_manufacturer`, `soc_model`, `platform`
- [ ] Confirm `is_ab` (check `HOM_DEV_IS_AB` from the candidate)
- [ ] Confirm `boot_partition` (`boot` or `init_boot`, based on API level)
- [ ] Verify `by_name_hint` path with `HOM_BLOCK_BY_NAME` from the candidate
- [ ] Check `init_boot_api_min` (should be 33 for all new families)
- [ ] Test at least one successful install before marking as `known-supported`
- [ ] Add 2+ `example_devices` entries
- [ ] Bump `_version` and `_updated` in `partition_index.json`

### 1.3 Entry format

Add to `build/partition_index.json` under `device_families`:

```json
"<family_id>": {
  "description": "...",
  "soc_match": ["prefix1", "prefix2"],
  "is_ab": true,
  "boot_partition": "boot",
  "init_boot_api_min": 33,
  "example_devices": ["Brand Model A", "Brand Model B"],
  "by_name_hint": "/dev/block/by-name/",
  "support_tier": "known-supported",
  "notes": ""
}
```

`support_tier` must be one of: `known-supported`, `known-partial`, `experimental`, `unknown`

### 1.4 Propagating to forks

After merging a new entry:

1. Bump the `_version` field (SemVer).
2. Tag the commit: `git tag partition-index-vX.Y.Z`
3. Forks should update their bundled `partition_index.json` from the upstream tag.
4. The `core/candidate_entry.sh` script checks the bundled index version against
   the latest tag at runtime (if network is available) and warns if stale.

---

## 2. Script modification based on log evidence

### 2.1 How to use failure logs to justify a script change

1. Collect `master_*.log` and `var_audit_*.log` from the failing device.
2. Run `pipeline/parse_logs.py` to extract structured failure data.
3. Run `pipeline/failure_analysis.py` to identify the probable root cause.
4. Open a GitHub issue with the analysis output (redacted by default).

### 2.2 Change process

When a script change is needed based on log evidence:

1. **Issue**: Open a GitHub issue titled `fix(<script>): <short description>`.
   - Attach the redacted analysis JSON from `failure_analysis.py`.
   - Include the candidate device entry if the failure is device-specific.
2. **Fix**: Implement the change in the smallest possible scope.
3. **Test**: Add the device/API combo to the test matrix in the issue.
4. **Update index**: If the fix is device-specific, add/update the `device_families` entry.
5. **Merge**: Review and merge; bump `module.prop` version.

### 2.3 GitHub notification on failure

If a run is authenticated (user has `GITHUB_TOKEN`) and fails, the pipeline
can automatically send a failure report. This requires:

```bash
export GITHUB_TOKEN=ghp_...
bash terminal_menu.sh
# Select option 24 (pipeline/github_notify.py), then enter arguments:
#   --repo mikethi/hands-on-metal --analysis ~/tmp/analysis.json --run-id <RUN_ID>
# After completion, press 's' for the suggested next step
```

The notification includes:
- Summarized failure cause
- Redacted device snapshot
- Link to the troubleshooting guide section for the identified failure
- Suggested next steps

---

## 3. Compatibility spec version management

### 3.1 What the version covers

The `_version` field in `partition_index.json` tracks both:
- The set of known device families
- The schema of candidate entry JSON records (see [FORK_CONTRACT.md](FORK_CONTRACT.md) §3)

### 3.2 Version bump policy

| Change type | Version bump |
|-------------|-------------|
| Add a new device family | MINOR (x.Y.z) |
| Change existing family fields | PATCH (x.y.Z) |
| Change candidate JSON schema | MAJOR (X.y.z) |
| Change log format | MAJOR (X.y.z) |

### 3.3 Fork version check

Forks should call `core/candidate_entry.sh` which checks:
```sh
bundled_ver=$(cat "$PARTITION_INDEX" | grep '"_version"' | ...)
# warn if bundled_ver < latest_upstream_ver
```

If the fork's bundled index is more than 1 MINOR version behind, a warning
is printed during device profiling.

---

## 4. Private data intake path

For users who opt in to sharing unredacted diagnostic data:

1. **Local**: Written to `/sdcard/hands-on-metal/private/` (gitignored by `.gitignore`).
2. **Remote**: Uploaded as a **secret GitHub Gist** (not publicly searchable).
   - Only the Gist URL is logged; the URL is not committed to git.
   - The repo owner can access secret Gists created by authenticated users.
3. **No git commits**: Personal data is NEVER written to git history in any branch.

The `pipeline/upload.py` script enforces these rules.

---

## 5. Roadmap

- [ ] Host-assisted (ADB/fastboot) install path
- [ ] ARM32-only device support improvements
- [ ] Samsung Odin-format partition compatibility
- [ ] MediaTek scatter-file based devices
- [ ] Automated partition_index.json CI validation
- [ ] Web-based candidate submission form (no GitHub account required)
