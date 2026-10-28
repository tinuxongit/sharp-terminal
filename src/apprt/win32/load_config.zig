//! The exe's load configuration, which tells Windows to look for the DLLs
//! sharp.exe imports in System32 only. Without it the exe's own folder is
//! searched first, so a portable copy unzipped beside a planted
//! dwmapi.dll (say, in Downloads) would run it. Every import is a system
//! DLL; conpty.dll is loaded at runtime by full path (os/Conpty.zig).
//!
//! The linker points the PE's load config directory at the symbol named
//! `_load_config_used`, as MSVC's CRT and LLD agree; MinGW's CRT defines
//! none. Windows reads only the fields `size` covers.

/// IMAGE_LOAD_CONFIG_DIRECTORY64 as Windows 10 defines it.
const LoadConfig = extern struct {
    size: u32,
    time_date_stamp: u32 = 0,
    major_version: u16 = 0,
    minor_version: u16 = 0,
    global_flags_clear: u32 = 0,
    global_flags_set: u32 = 0,
    critical_section_default_timeout: u32 = 0,
    decommit_free_block_threshold: u64 = 0,
    decommit_total_free_threshold: u64 = 0,
    lock_prefix_table: u64 = 0,
    maximum_allocation_size: u64 = 0,
    virtual_memory_threshold: u64 = 0,
    process_affinity_mask: u64 = 0,
    process_heap_flags: u32 = 0,
    csd_version: u16 = 0,
    dependent_load_flags: u16,
    edit_list: u64 = 0,
    // Zero: MinGW's CRT sets up its own stack cookie.
    security_cookie: u64 = 0,
    se_handler_table: u64 = 0,
    se_handler_count: u64 = 0,
    // The fields after SEHandlerCount (Control Flow Guard and later),
    // zeroed: the loader expects the full Windows 10 structure.
    rest: [0x140 - 112]u8 = @splat(0),
};

const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x00000800;

export const _load_config_used: LoadConfig = .{
    .size = @sizeOf(LoadConfig),
    .dependent_load_flags = LOAD_LIBRARY_SEARCH_SYSTEM32,
};

comptime {
    if (@offsetOf(LoadConfig, "dependent_load_flags") != 78 or @sizeOf(LoadConfig) != 0x140)
        @compileError("LoadConfig no longer matches IMAGE_LOAD_CONFIG_DIRECTORY64");
}
