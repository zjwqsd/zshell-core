# zshell-core

Zig execution core for zshell.

ShellCore contains the operating-system execution capabilities and connects outbound to one zshell Gateway over WebSocket. It has no MCP or OAuth server.

## Responsibilities

- execute short-lived commands
- manage direct-process background jobs
- manage interactive terminal sessions (PTY on Linux, ConPTY on Windows)
- read/write files
- stream files between ShellCore devices through Gateway
- report environment information
- provide local Human Control on loopback ports starting at `8766`
- connect outbound to `/device/ws`
- declare its own device name and workspace
- reconnect automatically after transport loss
- optionally provide browser automation when started with `--browser`

## Connection configuration

Required:

```text
ZSHELL_GATEWAY_URL=wss://zshell.example.com/device/ws
ZSHELL_DEVICE_TOKEN=<same 24-512 character device secret as gateway>
ZSHELL_DEVICE_NAME=<unique name chosen for this Core instance>
```

For a trusted LAN you may use:

```text
ZSHELL_GATEWAY_URL=ws://192.168.1.20:8765/device/ws
```

`ws://` is unencrypted, so use it only on a trusted LAN. For public or otherwise untrusted networks use `wss://`.

`ZSHELL_DEVICE_NAME` is mandatory. The gateway does not generate or rewrite device names. Multiple Core instances on one physical machine should use different names.

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

## Run

Linux:

```bash
export ZSHELL_GATEWAY_URL='wss://zshell.example.com/device/ws'
export ZSHELL_DEVICE_TOKEN='replace-with-a-long-secret'
export ZSHELL_DEVICE_NAME='4090-server'
./zig-out/bin/zshell-core
```

PowerShell:

```powershell
$env:ZSHELL_GATEWAY_URL = "wss://zshell.example.com/device/ws"
$env:ZSHELL_DEVICE_TOKEN = "replace-with-a-long-secret"
$env:ZSHELL_DEVICE_NAME = "windows-laptop"
.\zig-out\bin\zshell-core.exe
```

If the gateway is unavailable, ShellCore remains running and retries every two seconds.

## Optional browser capability

Browser automation is opt-in. The default startup does not initialize, discover, or create browser state:

```bash
./zig-out/bin/zshell-core
```

Enable browser tools explicitly with:

```bash
./zig-out/bin/zshell-core --browser
```

When `--browser` is used, ShellCore performs startup preflight before connecting to Gateway. Both of these must be available:

- `agent-browser` on `PATH`, or configured with `ZSHELL_AGENT_BROWSER_EXECUTABLE`
- Google Chrome/Chromium, or configured with `ZSHELL_BROWSER_EXECUTABLE`

If either dependency is missing, ShellCore exits instead of starting with a partially working browser subsystem. Without `--browser`, `browser_status` reports `enabled=false` and every other `browser_*` operation returns `BrowserFeatureDisabled`.

`--no-browser` is also accepted for explicit browser-free startup. `--browser` and `--no-browser` cannot be combined.

## Transport

The WebSocket upgrade includes the device token in the HTTP `Authorization` header. After the upgrade, Core sends its name, workspace, OS, architecture and version as the protocol-v3 hello message.

Protocol v3 carries normal calls/results and transfer-control messages as WebSocket text frames. Cross-device file payloads use raw WebSocket binary frames, so file bytes are not base64-encoded and do not pass through the MCP/model context. Client-to-server WebSocket frames are masked as required by RFC 6455, server frames are validated, and individual messages larger than 8 MiB are rejected.

## Cross-device file transfer

File transfer is always available; unlike browser automation it does not require a startup flag or external executable. Gateway coordinates a source Core and a target Core over their existing outbound WebSockets.

The source reads the file in 256 KiB chunks and computes SHA-256 while streaming. Gateway forwards each binary frame directly to the target and does not buffer the whole file. The target writes to `<target>.zshell-part`, computes its own SHA-256, verifies size and hash against the source, then renames the temporary file to the requested destination. Failed or cancelled transfers remove the temporary part file.

The target side is a mutating action and obeys Human Control: a new transfer is rejected while the human owns execution control. Running transfers are left unchanged, matching the behavior of existing running jobs and executions.

## Human Control

Human Control remains local and independent of the gateway. The first Core normally binds:

```text
http://127.0.0.1:8766
```

Additional Core instances choose the next available loopback port through `8799`.

Stopping `zshell-core` immediately closes the device transport; the gateway then removes it from the live registry.
