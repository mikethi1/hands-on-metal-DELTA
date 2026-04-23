-- ============================================================
-- hands-on-metal: hardware_map.sql
-- Unified SQLite schema for the Halium Hardware Intelligence
-- Gatherer.  All three collection modes (A/B/C) populate these
-- tables.  The pipeline/ scripts are the primary writers; the
-- schema is intentionally append-friendly so partial runs can
-- be resumed without data loss.
-- ============================================================

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ------------------------------------------------------------
-- Run metadata
-- Records each collection run so rows from different devices /
-- sessions can be distinguished.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collection_run (
    run_id       INTEGER PRIMARY KEY AUTOINCREMENT,
    mode         TEXT    NOT NULL CHECK (mode IN ('A','B','C')),  -- A=live,B=recovery,C=shim
    device_model TEXT,
    ro_board     TEXT,
    ro_platform  TEXT,
    ro_hardware  TEXT,
    collected_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    source_dir   TEXT             -- absolute path to the dump directory
);

-- ------------------------------------------------------------
-- Android properties (getprop dump, Mode A)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS android_prop (
    prop_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id   INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    key      TEXT NOT NULL,
    value    TEXT,
    UNIQUE (run_id, key)
);
CREATE INDEX IF NOT EXISTS idx_prop_key ON android_prop(key);

-- ------------------------------------------------------------
-- Hardware blocks
-- One row per logical hardware unit (gralloc, camera, audio).
-- The percentage columns are recomputed by build_table.py every
-- run; store raw counts so the formula is transparent.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hardware_block (
    hw_id           INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    category        TEXT NOT NULL,       -- display/imaging/audio/sensor/modem/power/input/thermal/misc
    hal_interface   TEXT,
    hal_instance    TEXT,
    pinctrl_group   TEXT,
    total_fields    INTEGER NOT NULL DEFAULT 0,
    filled_fields   INTEGER NOT NULL DEFAULT 0,
    pct_populated   REAL    GENERATED ALWAYS AS (
                        CASE WHEN total_fields = 0 THEN 0.0
                             ELSE ROUND(100.0 * filled_fields / total_fields, 1)
                        END
                    ) STORED,
    UNIQUE (run_id, name)
);
CREATE INDEX IF NOT EXISTS idx_hw_name     ON hardware_block(name);
CREATE INDEX IF NOT EXISTS idx_hw_category ON hardware_block(category);

-- ------------------------------------------------------------
-- Symbol table
-- Populated from nm/readelf over vendor .so files.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS symbol (
    sym_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    hw_id       INTEGER REFERENCES hardware_block(hw_id)  ON DELETE SET NULL,
    library     TEXT NOT NULL,
    mangled     TEXT NOT NULL,
    demangled   TEXT,
    sym_type    TEXT,
    binding     TEXT,
    section     TEXT,
    address     TEXT,
    source_file TEXT,
    android_api TEXT,
    linux_equiv TEXT,
    UNIQUE (run_id, library, mangled)
);
CREATE INDEX IF NOT EXISTS idx_sym_demangled ON symbol(demangled);
CREATE INDEX IF NOT EXISTS idx_sym_library   ON symbol(library);
CREATE INDEX IF NOT EXISTS idx_sym_hw        ON symbol(hw_id);

-- ------------------------------------------------------------
-- Pinctrl map
-- Parsed from /sys/kernel/debug/pinctrl/*/
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pinctrl_controller (
    ctrl_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id   INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    name     TEXT NOT NULL,
    dev_name TEXT,
    UNIQUE (run_id, name)
);

CREATE TABLE IF NOT EXISTS pinctrl_pin (
    pin_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    ctrl_id   INTEGER REFERENCES pinctrl_controller(ctrl_id) ON DELETE CASCADE,
    pin_num   INTEGER NOT NULL,
    gpio_name TEXT,
    function  TEXT,
    hw_id     INTEGER REFERENCES hardware_block(hw_id) ON DELETE SET NULL,
    UNIQUE (ctrl_id, pin_num)
);
CREATE INDEX IF NOT EXISTS idx_pin_gpio ON pinctrl_pin(gpio_name);

CREATE TABLE IF NOT EXISTS pinctrl_group (
    grp_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    ctrl_id  INTEGER REFERENCES pinctrl_controller(ctrl_id) ON DELETE CASCADE,
    grp_name TEXT NOT NULL,
    hw_id    INTEGER REFERENCES hardware_block(hw_id) ON DELETE SET NULL,
    UNIQUE (ctrl_id, grp_name)
);

CREATE TABLE IF NOT EXISTS pinctrl_group_pin (
    grp_id INTEGER REFERENCES pinctrl_group(grp_id) ON DELETE CASCADE,
    pin_id INTEGER REFERENCES pinctrl_pin(pin_id)   ON DELETE CASCADE,
    PRIMARY KEY (grp_id, pin_id)
);

-- ------------------------------------------------------------
-- VINTF / HAL manifest entries
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vintf_hal (
    vhal_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    hw_id       INTEGER REFERENCES hardware_block(hw_id)  ON DELETE SET NULL,
    hal_format  TEXT,
    hal_name    TEXT NOT NULL,
    version     TEXT,
    interface   TEXT,
    instance    TEXT,
    transport   TEXT,
    source_file TEXT,
    UNIQUE (run_id, hal_name, version, interface, instance)
);
CREATE INDEX IF NOT EXISTS idx_vhal_name ON vintf_hal(hal_name);

-- ------------------------------------------------------------
-- Sysconfig / board properties
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sysconfig_entry (
    sc_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id  INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    source  TEXT NOT NULL,
    key     TEXT NOT NULL,
    value   TEXT,
    UNIQUE (run_id, source, key)
);

-- ------------------------------------------------------------
-- ioctl code book
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ioctl_code (
    ioctl_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    hw_id       INTEGER REFERENCES hardware_block(hw_id)  ON DELETE SET NULL,
    code_hex    TEXT NOT NULL,
    direction   TEXT CHECK (direction IN ('READ','WRITE','READWRITE','NONE')),
    buf_size    INTEGER,
    driver_name TEXT,
    description TEXT,
    UNIQUE (run_id, code_hex)
);
CREATE INDEX IF NOT EXISTS idx_ioctl_hw ON ioctl_code(hw_id);

-- ------------------------------------------------------------
-- Binary call sequences (Mode C)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS call_sequence (
    call_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER REFERENCES collection_run(run_id)  ON DELETE CASCADE,
    hw_id           INTEGER REFERENCES hardware_block(hw_id)   ON DELETE SET NULL,
    order_idx       INTEGER NOT NULL,
    layer           TEXT NOT NULL CHECK (layer IN ('android','hybris','linux','binder')),
    android_fn      TEXT,
    mangled_sym     TEXT,
    hybris_wrapper  TEXT,
    ioctl_id        INTEGER REFERENCES ioctl_code(ioctl_id) ON DELETE SET NULL,
    buf_hex         TEXT,
    return_value    TEXT,
    timestamp_ns    INTEGER,
    binder_iface    TEXT,
    binder_txn_code INTEGER
);
CREATE INDEX IF NOT EXISTS idx_call_hw    ON call_sequence(hw_id);
CREATE INDEX IF NOT EXISTS idx_call_order ON call_sequence(run_id, order_idx);

-- ------------------------------------------------------------
-- Kernel / device-tree nodes (Mode A)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dt_node (
    node_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id     INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    path       TEXT NOT NULL,
    compatible TEXT,
    reg        TEXT,
    interrupts TEXT,
    clocks     TEXT,
    hw_id      INTEGER REFERENCES hardware_block(hw_id) ON DELETE SET NULL,
    UNIQUE (run_id, path)
);
CREATE INDEX IF NOT EXISTS idx_dt_compatible ON dt_node(compatible);

-- ------------------------------------------------------------
-- iomem regions (Mode A, /proc/iomem)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iomem_region (
    iomem_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id    INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    start_hex TEXT NOT NULL,
    end_hex   TEXT NOT NULL,
    name      TEXT,
    hw_id     INTEGER REFERENCES hardware_block(hw_id) ON DELETE SET NULL
);

-- ------------------------------------------------------------
-- IRQ entries (Mode A, /proc/interrupts)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS irq_entry (
    irq_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id     INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    irq_num    INTEGER NOT NULL,
    count      INTEGER,
    cpu_counts TEXT,
    name       TEXT,
    hw_id      INTEGER REFERENCES hardware_block(hw_id) ON DELETE SET NULL,
    UNIQUE (run_id, irq_num)
);

-- ------------------------------------------------------------
-- Kernel modules (Mode A, lsmod)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kernel_module (
    mod_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id    INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    name      TEXT NOT NULL,
    size      INTEGER,
    use_count INTEGER,
    used_by   TEXT,
    hw_id     INTEGER REFERENCES hardware_block(hw_id) ON DELETE SET NULL,
    UNIQUE (run_id, name)
);

-- ------------------------------------------------------------
-- Audio product strategies  (ComponentTypeSet XML)
-- Populated from audio_policy_engine_product_strategies.xml or
-- any ComponentTypeSet XML found under vendor/etc/audio/.
-- standard_name  — e.g. STRATEGY_MEDIA (no Identifier mapping)
-- vendor_id      — numeric Identifier from Mapping= (vendor only)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audio_strategy (
    strat_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id        INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    component_name TEXT NOT NULL,   -- the Name= attribute
    standard_name  TEXT,            -- same as component_name when STRATEGY_*
    vendor_id      INTEGER,         -- Identifier value; NULL for standard strategies
    source_file    TEXT,
    UNIQUE (run_id, component_name)
);
CREATE INDEX IF NOT EXISTS idx_strat_run ON audio_strategy(run_id);

-- ------------------------------------------------------------
-- Collected file index
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collected_file (
    file_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id     INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    src_path   TEXT NOT NULL,
    local_path TEXT NOT NULL,
    sha256     TEXT,
    size_bytes INTEGER,
    UNIQUE (run_id, src_path)
);
CREATE INDEX IF NOT EXISTS idx_file_src ON collected_file(src_path);

-- ------------------------------------------------------------
-- Environment variable registry
-- Written by all three modes (A=live Magisk, B=recovery, C=shim).
-- Captures resolved paths, tool availability flags, Python
-- versions, Termux state, package locations, and any other
-- key=value fact discovered at runtime.  The 'source' column
-- records which script wrote the row; 'real_path' stores the
-- readlink -f expansion when the value is a filesystem path.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS env_var (
    env_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id      INTEGER REFERENCES collection_run(run_id) ON DELETE CASCADE,
    mode        TEXT    NOT NULL CHECK (mode IN ('A','B','C')),
    key         TEXT    NOT NULL,
    value       TEXT,
    real_path   TEXT,                        -- readlink -f result, when applicable
    source      TEXT    NOT NULL,            -- script that emitted this row (e.g. env_detect.sh)
    category    TEXT    NOT NULL DEFAULT 'general',
                                             -- shell / python / termux / package / path / crypto / recovery
    updated_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE (run_id, key)                     -- last writer wins via INSERT OR REPLACE
);
CREATE INDEX IF NOT EXISTS idx_env_key      ON env_var(key);
CREATE INDEX IF NOT EXISTS idx_env_category ON env_var(category);
CREATE INDEX IF NOT EXISTS idx_env_mode     ON env_var(mode);
