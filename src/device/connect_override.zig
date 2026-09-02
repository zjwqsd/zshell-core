const std = @import("std");

/// Optionally connect the HTTP client to a different physical host while
/// preserving the URI host for TLS SNI, certificate verification, HTTP Host,
/// and connection-pool identity. This is useful when name resolution is done
/// by a platform-native bootstrapper (for example Android's resolver).
pub fn acquire(
    client: *std.http.Client,
    uri: std.Uri,
    connect_host: ?[]const u8,
) !?*std.http.Client.Connection {
    const physical_text = connect_host orelse return null;
    if (physical_text.len == 0) return error.EmptyGatewayConnectHost;

    var logical_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const logical_host = try uri.getHost(&logical_buffer);
    const physical_host = try std.Io.net.HostName.init(physical_text);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    const port: u16 = uri.port orelse switch (protocol) { .plain => 80, .tls => 443 };

    return try client.connectTcpOptions(.{
        .host = physical_host,
        .port = port,
        .protocol = protocol,
        .proxied_host = logical_host,
        .proxied_port = port,
    });
}

pub fn releaseIfUnowned(
    client: *std.http.Client,
    io: std.Io,
    connection: ?*std.http.Client.Connection,
) void {
    const conn = connection orelse return;
    conn.closing = true;
    client.connection_pool.release(conn, io);
}
