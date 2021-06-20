const std = @import("std");

pub fn setBuffer(comptime T: type, ptr: [*]T, data: []const T, max_length: usize) usize {
    const buf_ptr = @ptrCast([*]T, ptr);
    const copy_len = std.math.min(max_length - 1, data.len);

    @memcpy(buf_ptr, data.ptr, copy_len);
    std.mem.set(u8, buf_ptr[copy_len..max_length], 0);

    return copy_len;
}
