//! Shell profiles from profiles.zon, resolved against what is installed:
//! hidden when their program is missing, repeated per Visual Studio or WSL
//! distribution, and drawn with their program's icon.
const std = @import("std");
const w32 = @import("win32.zig");
const wide_string = @import("wide_string.zig");
const config_file = @import("config_file.zig");
const global = @import("../../global.zig");

pub const Source = enum { fixed, visual_studio, wsl };

pub const Template = struct {
    name: []const u8,
    command: []const u8,
    icon: []const u8,
    requires: ?[]const u8 = null,
    source: Source = .fixed,
    default: bool = false,
};

pub const Menu = struct {
    profile_shortcut: []const u8,
};

pub const Sidebar = struct {
    search_placeholder: []const u8,
    local: []const u8,
    wsl: []const u8,
    servers: []const u8,
    /// The title of the folder picker behind a section's "+".
    pick_folder: []const u8,
    /// The hint in the box Servers' "+" opens.
    server_placeholder: []const u8,
    /// The Servers menu when there is nothing to list.
    no_servers: []const u8,
};

pub const Data = struct {
    hidden_wsl_prefixes: []const []const u8,
    profiles: []const Template,
    sidebar: Sidebar,
    menu: Menu,
};

pub const data: Data = @import("profiles.zon");

comptime {
    var defaults = 0;
    for (data.profiles) |t| {
        if (t.default) defaults += 1;
        const placeholder = switch (t.source) {
            .fixed => continue,
            .visual_studio => "{vs}",
            .wsl => "{distro}",
        };
        if (std.mem.indexOf(u8, t.command, placeholder) == null)
            @compileError("profiles.zon: '" ++ t.name ++ "' repeats per " ++ @tagName(t.source) ++ " but its command never uses " ++ placeholder);
    }
    if (defaults != 1) @compileError("profiles.zon: exactly one profile must be .default");
}

pub const Profile = struct {
    name: Text,
    command: Text,
    icon: Text,
    default: bool,
    source: Source,
};

/// A string inside List.text, stored as a position so the list can be
/// copied freely.
pub const Text = struct { start: u16, len: u16 };

/// The profiles installed right now, in menu order. Strings live in the
/// list itself, so it is a plain value with no cleanup.
pub const List = struct {
    items: [max_profiles]Profile = undefined,
    len: usize = 0,
    text: [8 * 1024]u8 = undefined,
    used: usize = 0,

    pub const max_profiles = 32;

    /// The first profile from `source`, such as the first WSL distribution.
    pub fn first(self: *const List, source: Source) ?usize {
        for (self.items[0..self.len], 0..) |item, i| {
            if (item.source == source) return i;
        }
        return null;
    }

    pub fn str(self: *const List, t: Text) []const u8 {
        return self.text[t.start..][0..t.len];
    }

    pub fn name(self: *const List, i: usize) []const u8 {
        return self.str(self.items[i].name);
    }

    pub fn command(self: *const List, i: usize) []const u8 {
        return self.str(self.items[i].command);
    }

    pub fn icon(self: *const List, i: usize) []const u8 {
        return self.str(self.items[i].icon);
    }

    /// The profile `configured` selects: the matching one, or the default
    /// profile when the setting is absent.
    pub fn selected(self: *const List, configured: ?[]const u8) ?usize {
        for (0..self.len) |i| {
            if (configured) |c| {
                if (config_file.sameValue(c, self.command(i))) return i;
            } else if (self.items[i].default) return i;
        }
        return null;
    }

    /// A placeholder and what replaces it.
    const Sub = struct { []const u8, []const u8 };

    fn add(self: *List, t: Template, subs: []const Sub) void {
        if (self.len == self.items.len) return;
        const start = self.used;
        const name_ = self.expand(t.name, subs) orelse return;
        const command_ = self.expand(t.command, subs) orelse return;
        const icon_ = self.expand(t.icon, subs) orelse return;
        if (t.requires) |r| {
            const requires = self.expand(r, subs) orelse return;
            const exists = programExists(self.str(requires));
            // The requirement is only checked, never kept.
            self.used = requires.start;
            if (!exists) {
                self.used = start;
                return;
            }
        }
        self.items[self.len] = .{ .name = name_, .command = command_, .icon = icon_, .default = t.default, .source = t.source };
        self.len += 1;
    }

    fn expand(self: *List, template: []const u8, subs: []const Sub) ?Text {
        const out = self.text[self.used..];
        var n: usize = 0;
        var rest = template;
        while (rest.len > 0) {
            // The earliest placeholder in what is left.
            var at: ?usize = null;
            var sub: Sub = .{ "", "" };
            for (subs) |s| {
                const i = std.mem.indexOf(u8, rest, s[0]) orelse continue;
                if (at == null or i < at.?) {
                    at = i;
                    sub = s;
                }
            }
            const literal = rest[0 .. at orelse rest.len];
            if (n + literal.len > out.len) return null;
            @memcpy(out[n..][0..literal.len], literal);
            n += literal.len;
            rest = rest[literal.len..];
            if (at != null) {
                if (n + sub[1].len > out.len) return null;
                @memcpy(out[n..][0..sub[1].len], sub[1]);
                n += sub[1].len;
                rest = rest[sub[0].len..];
            }
        }
        const start: u16 = @intCast(self.used);
        self.used += n;
        return .{ .start = start, .len = @intCast(n) };
    }
};

pub fn detect() List {
    var list: List = .{};
    var distros: Distros = .{};
    distros.load();

    for (data.profiles) |t| {
        switch (t.source) {
            .fixed => list.add(t, &.{}),
            .visual_studio => for (VisualStudio.all()) |*vs| {
                list.add(t, &.{ .{ "{vs}", vs.folder() }, .{ "{vs_year}", vs.year() } });
            },
            .wsl => {
                for (distros.names[0..distros.len]) |*name| list.add(t, &.{.{ "{distro}", std.mem.sliceTo(name, 0) }});
            },
        }
    }
    return list;
}

/// Visual Studio installations as its installer records them, the source
/// vswhere reads: a folder per instance under %ProgramData%\Microsoft\
/// VisualStudio\Packages\_Instances whose state.json names the install
/// folder and product year. Read once per run, since detect() runs often.
const VisualStudio = struct {
    folder_buf: [260]u8,
    folder_len: usize,
    year_buf: [8]u8,
    year_len: usize,

    var found: [4]VisualStudio = undefined;
    var count: usize = 0;
    var loaded = false;

    fn folder(self: *const VisualStudio) []const u8 {
        return self.folder_buf[0..self.folder_len];
    }

    fn year(self: *const VisualStudio) []const u8 {
        return self.year_buf[0..self.year_len];
    }

    fn all() []const VisualStudio {
        if (!loaded) {
            loaded = true;
            load();
            // Newest first, as vswhere lists them.
            std.mem.sort(VisualStudio, found[0..count], {}, struct {
                fn newer(_: void, a: VisualStudio, b: VisualStudio) bool {
                    return std.mem.order(u8, a.year(), b.year()) == .gt;
                }
            }.newer);
        }
        return found[0..count];
    }

    fn load() void {
        const alloc = std.heap.page_allocator;
        const io = global.io();
        const program_data = global.environ().getAlloc(alloc, "ProgramData") catch return;
        defer alloc.free(program_data);
        const root = std.fs.path.join(alloc, &.{ program_data, "Microsoft", "VisualStudio", "Packages", "_Instances" }) catch return;
        defer alloc.free(root);
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory or count == found.len) continue;
            const path = std.fs.path.join(alloc, &.{ root, entry.name, "state.json" }) catch continue;
            defer alloc.free(path);
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024)) catch continue;
            defer alloc.free(text);
            const json = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
            const State = struct {
                installationPath: []const u8,
                catalogInfo: struct { productLineVersion: []const u8 = "" } = .{},
            };
            const parsed = std.json.parseFromSlice(State, alloc, json, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const state = parsed.value;
            const vs_year = state.catalogInfo.productLineVersion;
            if (state.installationPath.len > 260 or vs_year.len > 8) continue;
            var vs: VisualStudio = .{ .folder_buf = undefined, .folder_len = state.installationPath.len, .year_buf = undefined, .year_len = vs_year.len };
            @memcpy(vs.folder_buf[0..vs.folder_len], state.installationPath);
            @memcpy(vs.year_buf[0..vs.year_len], vs_year);
            found[count] = vs;
            count += 1;
        }
    }
};

/// A program name on PATH, or an absolute path to a file or folder.
pub fn programExists(name: []const u8) bool {
    var wide: [260]u16 = undefined;
    _ = wide_string.fromUtf8(&wide, name);
    if (std.fs.path.isAbsolute(name)) return w32.GetFileAttributesW(@ptrCast(&wide)) != w32.INVALID_FILE_ATTRIBUTES;
    return w32.SearchPathW(null, @ptrCast(&wide), null, 0, null, null) != 0;
}

/// Installed WSL distributions, as WSL registers them per user.
const Distros = struct {
    names: [16][64:0]u8 = undefined,
    len: usize = 0,

    fn load(self: *Distros) void {
        var lxss: w32.HKEY = undefined;
        const path = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss");
        if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, path, 0, w32.KEY_READ, &lxss) != w32.ERROR_SUCCESS) return;
        defer _ = w32.RegCloseKey(lxss);

        var index: u32 = 0;
        while (self.len < self.names.len) : (index += 1) {
            var key_name: [64:0]u16 = @splat(0);
            var key_len: u32 = key_name.len;
            if (w32.RegEnumKeyExW(lxss, index, &key_name, &key_len, null, null, null, null) != w32.ERROR_SUCCESS) break;
            var key: w32.HKEY = undefined;
            if (w32.RegOpenKeyExW(lxss, &key_name, 0, w32.KEY_READ, &key) != w32.ERROR_SUCCESS) continue;
            defer _ = w32.RegCloseKey(key);

            var value: [64:0]u16 = @splat(0);
            var size: u32 = (value.len - 1) * 2;
            var kind: u32 = 0;
            if (w32.RegQueryValueExW(key, std.unicode.utf8ToUtf16LeStringLiteral("DistributionName"), null, &kind, @ptrCast(&value), &size) != w32.ERROR_SUCCESS or kind != w32.REG_SZ) continue;

            var name: [64:0]u8 = @splat(0);
            const wide = std.mem.sliceTo(&value, 0);
            // A UTF-16 unit needs up to 3 UTF-8 bytes; skip names too long.
            if (wide.len * 3 > name.len) continue;
            _ = std.unicode.utf16LeToUtf8(&name, wide) catch continue;
            if (hidden(std.mem.sliceTo(&name, 0))) continue;
            self.names[self.len] = name;
            self.len += 1;
        }
    }

    fn hidden(name: []const u8) bool {
        for (data.hidden_wsl_prefixes) |prefix| {
            if (std.mem.startsWith(u8, name, prefix)) return true;
        }
        return false;
    }
};

/// Program icons, extracted once per program and size and kept until the
/// app exits, since tabs and menus redraw them often.
pub const Icons = struct {
    entries: [32]Entry = undefined,
    len: usize = 0,

    const Entry = struct { hash: u64, size: i32, icon: ?w32.HICON };

    pub fn get(self: *Icons, program: []const u8, size: i32) ?w32.HICON {
        const hash = std.hash.Wyhash.hash(0, program);
        for (self.entries[0..self.len]) |e| {
            if (e.hash == hash and e.size == size) return e.icon;
        }
        const icon = extract(program, size);
        if (self.len < self.entries.len) {
            self.entries[self.len] = .{ .hash = hash, .size = size, .icon = icon };
            self.len += 1;
        }
        return icon;
    }

    pub fn deinit(self: *Icons) void {
        for (self.entries[0..self.len]) |e| {
            if (e.icon) |icon| _ = w32.DestroyIcon(icon);
        }
        self.len = 0;
    }

    fn extract(program: []const u8, size: i32) ?w32.HICON {
        var name: [260]u16 = undefined;
        _ = wide_string.fromUtf8(&name, program);
        var full: [260]u16 = @splat(0);
        const path: [*:0]const u16 = if (std.fs.path.isAbsolute(program))
            @ptrCast(&name)
        else if (w32.SearchPathW(null, @ptrCast(&name), null, full.len - 1, &full, null) != 0)
            @ptrCast(&full)
        else
            return null;
        var icon: ?w32.HICON = null;
        if (w32.PrivateExtractIconsW(path, 0, size, size, &icon, null, 1, 0) == 0) return null;
        return icon;
    }
};
