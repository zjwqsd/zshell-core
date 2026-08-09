const std = @import("std");

pub const EncodedOutput = struct {
    encoding: []const u8,
    data: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: EncodedOutput, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
    }
};

/// Preserve process output byte-for-byte across the internal JSON boundary.
/// UTF-8 is sent directly; arbitrary bytes are base64 encoded.
pub fn encode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !EncodedOutput {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{ .encoding = "utf8", .data = bytes };
    }

    const encoded_size = std.base64.standard.Encoder.calcSize(bytes.len);
    const buffer = try allocator.alloc(u8, encoded_size);
    const encoded = std.base64.standard.Encoder.encode(buffer, bytes);

    return .{
        .encoding = "base64",
        .data = encoded,
        .owned = buffer,
    };
}
