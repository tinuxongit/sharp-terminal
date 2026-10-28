//! Win32 takes UTF-16 text, often in fixed-size buffers. std.unicode's
//! utf8ToUtf16Le does not bounds-check its destination, so in release
//! builds an oversized title, notification or search string from the
//! terminal would write past the buffer. Truncating text goes through here.
const std = @import("std");

/// Convert as much of `utf8` as fits in `dest`, keeping one slot for the
/// zero terminator, without splitting a surrogate pair. Invalid UTF-8
/// becomes an empty string. Returns the length without the terminator.
pub fn fromUtf8(dest: []u16, utf8: []const u8) usize {
    std.debug.assert(dest.len > 0);
    const capacity = dest.len - 1;
    var len: usize = 0;
    const view = std.unicode.Utf8View.init(utf8) catch {
        dest[0] = 0;
        return 0;
    };
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            if (len + 1 > capacity) break;
            dest[len] = std.mem.nativeToLittle(u16, @intCast(cp));
            len += 1;
        } else {
            if (len + 2 > capacity) break;
            const high: u16 = @as(u16, @intCast((cp - 0x10000) >> 10)) + 0xD800;
            const low: u16 = @as(u16, @intCast(cp & 0x3FF)) + 0xDC00;
            dest[len] = std.mem.nativeToLittle(u16, high);
            dest[len + 1] = std.mem.nativeToLittle(u16, low);
            len += 2;
        }
    }
    dest[len] = 0;
    return len;
}
