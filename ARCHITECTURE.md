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
| device/transfer.zig          binary file streaming     |
| protocol/dispatcher.zig      operation dispatch        |
| tools/*                      exec / env / files        |
| jobs/*                       direct background jobs    |
| shells/*                     PTY / ConPTY terminals    |
| control/*                    local Human Control       |
+--------------------------------------------------------+
```

## Separation rule

ShellCore understands the private device application protocol carried over WebSocket. It does not implement MCP or OAuth.

## Identity

Every Core instance requires `ZSHELL_DEVICE_NAME`. The name is the gateway routing key for the lifetime of that connection. Core also reports its current working directory as `workspace` metadata.

## Lifecycle

1. initialize job and interactive-terminal managers
2. bind Human Control to the first free loopback port in `8766..8799`
3. read `ZSHELL_GATEWAY_URL`, `ZSHELL_DEVICE_TOKEN` and `ZSHELL_DEVICE_NAME`
4. open a WebSocket to `/device/ws`
5. authenticate the Upgrade request with the device token
6. send the protocol-v3 hello containing device metadata
7. receive text calls/transfer controls and binary transfer chunks
8. dispatch normal calls locally; stream transfer chunks directly to/from files
9. return results and transfer state on the same WebSocket
10. on disconnect, wait two seconds and reconnect

## Transport security

`wss://` uses TLS and validates the remote certificate through Zig's HTTP/TLS client. Use it for public networks. `ws://` has no encryption and is intended only for trusted LANs.

The WebSocket client validates the HTTP 101 upgrade and `Sec-WebSocket-Accept`, masks client frames, rejects masked server frames, rejects unsupported fragmentation/RSV bits, and caps messages at 8 MiB.

## Transfer data path

```text
source file
   | read 256 KiB + SHA-256
   v
source Core -- binary WebSocket --> Gateway -- binary WebSocket --> target Core
                                                              |
                                                              v
                                                target.zshell-part
                                                              | verify size/hash
                                                              v
                                                        atomic rename
```

Binary transfer frames use a fixed header (`ZTF1`, 16-byte transfer ID, 64-bit sequence) followed by raw file bytes. JSON/text frames remain responsible for prepare/start/commit/cancel/failure control. Source streaming runs on a worker thread so the main device reader can continue processing ping, cancellation and ordinary control messages; WebSocket writes are serialized by the Core transport.
