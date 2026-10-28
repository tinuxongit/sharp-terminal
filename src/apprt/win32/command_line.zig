//! Writing one argument of a Windows command line so that Windows'
//! parser (CommandLineToArgvW, the C runtime) splits it back unchanged.
const std = @import("std");

/// Write `prefix` and `value` as one quoted argument: backslashes before a
/// quote are doubled and the quote escaped, and trailing backslashes are
/// doubled so they don't escape the closing quote.
pub fn quote(out: *std.Io.Writer, prefix: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try out.writeByte('"');
    try out.writeAll(prefix);
    var backslashes: usize = 0;
    for (value) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        try out.splatByteAll('\\', if (c == '"') backslashes * 2 + 1 else backslashes);
        backslashes = 0;
        try out.writeByte(c);
    }
    try out.splatByteAll('\\', backslashes * 2);
    try out.writeByte('"');
}
