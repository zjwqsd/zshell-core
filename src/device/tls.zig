const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.os.tag == .linux and builtin.abi == .android;
const android_ca_pem = if (is_android) @embedFile("cacert.pem") else "";
const pem_decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");

pub fn configureClient(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    io: std.Io,
    ca_bundle_path: ?[]const u8,
) !void {
    var bundle: std.crypto.Certificate.Bundle = .empty;
    errdefer bundle.deinit(allocator);
    const now = std.Io.Clock.real.now(io);

    if (ca_bundle_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.CABundlePathMustBeAbsolute;
        try bundle.addCertsFromFilePathAbsolute(allocator, io, now, path);
    } else if (is_android) {
        try addPemBundle(&bundle, allocator, now.toSeconds(), android_ca_pem);
    } else {
        return;
    }

    client.ca_bundle.deinit(allocator);
    client.ca_bundle = bundle;
    client.now = now;
}

fn addPemBundle(
    bundle: *std.crypto.Certificate.Bundle,
    allocator: std.mem.Allocator,
    now_sec: i64,
    pem: []const u8,
) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    var start_index: usize = 0;

    while (std.mem.findPos(u8, pem, start_index, begin_marker)) |begin_start| {
        const cert_start = begin_start + begin_marker.len;
        const cert_end = std.mem.findPos(u8, pem, cert_start, end_marker) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + end_marker.len;

        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        const upper_bound = encoded.len / 4 * 3 + 3;
        try bundle.bytes.ensureUnusedCapacity(allocator, upper_bound);
        const dest = bundle.bytes.allocatedSlice()[decoded_start..];
        bundle.bytes.items.len += try pem_decoder.decode(dest, encoded);
        try bundle.parseCert(allocator, decoded_start, now_sec);
    }
}
