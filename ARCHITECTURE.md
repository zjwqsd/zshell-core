# ShellCore architecture

```text
                         ws:// LAN
                            or
                        wss:// public
                              |
                              v
                       zshell-gateway
                              ^
                              |
+-----------------------------+--------------------------+
| zshell-core (Zig)                                      |
|                                                        |
| device/client.zig            lifecycle / hello / retry |
| device/websocket_client.zig  WebSocket + TLS transport |
| protocol/dispatcher.zig      operation dispatch        |
| tools/*                      exec / env / files        |
| jobs/*                       background jobs           |
| shells/*                     persistent shells         |
| control/*                    local Human Control       |
+--------------------------------------------------------+
```

## Separation rule

ShellCore understands the private device application protocol carried over WebSocket. It does not implement MCP or OAuth.

## Identity

Every Core instance requires `ZSHELL_DEVICE_NAME`. The name is the gateway routing key for the lifetime of that connection. Core also reports its current working directory as `workspace` metadata.

## Lifecycle

1. initialize jobs and persistent-shell managers
2. bind Human Control to the first free loopback port in `8766..8799`
3. read `ZSHELL_GATEWAY_URL`, `ZSHELL_DEVICE_TOKEN` and `ZSHELL_DEVICE_NAME`
4. open a WebSocket to `/device/ws`
5. authenticate the Upgrade request with the device token
6. send the protocol-v2 hello containing device metadata
7. receive calls and dispatch them locally
8. return results on the same WebSocket
9. on disconnect, wait two seconds and reconnect

## Transport security

`wss://` uses TLS and validates the remote certificate through Zig's HTTP/TLS client. Use it for public networks. `ws://` has no encryption and is intended only for trusted LANs.

The WebSocket client validates the HTTP 101 upgrade and `Sec-WebSocket-Accept`, masks client frames, rejects masked server frames, rejects unsupported fragmentation/RSV bits, and caps messages at 8 MiB.
