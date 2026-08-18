# zshell-core

Zig execution core for zshell.

ShellCore contains the operating-system execution capabilities and connects outbound to one zshell Gateway over WebSocket or HTTP transport. It has no MCP or OAuth server.

## Responsibilities

- execute short-lived commands
- manage direct-process background jobs
- manage interactive terminal sessions (PTY on Linux, ConPTY on Windows)
- read/write files
- stream files between ShellCore devices through Gateway
- report environment information
- provide a local libvaxis TUI for monitoring and Human Control
- connect outbound to the Gateway device endpoint using the transport selected by `ZSHELL_GATEWAY_URL`
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

Transport selection is determined only by the URL scheme:

```text
ws://, wss://     -> WebSocket
http://, https:// -> HTTP
```

For environments where WebSocket is unavailable, use the HTTP device endpoint:

```text
ZSHELL_GATEWAY_URL=https://zshell.example.com/device/http
```

For a trusted LAN you may use `ws://.../device/ws` or `http://.../device/http`. The plain-text schemes are unencrypted; use `wss://` or `https://` on untrusted networks. ShellCore does not automatically fall back between transports.

`ZSHELL_DEVICE_NAME` is mandatory. The gateway does not generate or rewrite device names. Multiple Core instances on one physical machine should use different names.

## Build

Requires Zig 0.16.0 or newer. Dependencies such as libvaxis are declared in `build.zig.zon` and are fetched automatically on the first build; generated dependency/cache directories such as `zig-pkg/`, `.zig-cache/` and `zig-out/` are not part of the repository.

A fresh checkout can be built directly:

```bash
git clone git@github.com:zjwqsd/zshell-core.git
cd zshell-core
zig build -Doptimize=ReleaseSmall
```

`ReleaseSmall` is the recommended mode for binaries that will be copied to other machines. On the tested x86_64 Linux build it produces a self-contained binary of roughly 1.8 MiB.

For development and tests:

```bash
zig build
zig build test
```

Use `-Doptimize=ReleaseSafe` instead when you prefer additional runtime safety checks over minimum binary size.

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

Both transports authenticate with the same bearer device token and preserve protocol-v3 message semantics (`hello`/`hello_ack`, `call`/`result`, `ping`/`pong`, transfer control). `ZSHELL_GATEWAY_URL` selects the transport by scheme; there is no separate transport flag or environment variable.

WebSocket mode keeps the existing wire protocol unchanged, including text control messages, `ZTF1` binary transfer frames, heartbeat behavior and reconnects.

HTTP mode establishes a device session with `POST /device/http`, receives Gateway messages through long polling, and posts results/pongs/control messages back to the session. File bytes use separate `application/octet-stream` endpoints and are never Base64 encoded. HTTP and WebSocket file transfers both use 1 MiB chunks to reduce per-chunk overhead while keeping bounded memory usage.

## Cross-device file transfer

File transfer is always available; unlike browser automation it does not require a startup flag or external executable. Gateway can relay between any transport combination: WebSocket -> WebSocket, WebSocket -> HTTP, HTTP -> WebSocket, or HTTP -> HTTP.

The source computes SHA-256 while streaming. WebSocket sources use 1 MiB `ZTF1` binary frames; HTTP sources use 1 MiB raw `application/octet-stream` chunks. Gateway preserves transfer ID and sequence ordering and applies backpressure without buffering the whole file. The target writes to `<target>.zshell-part`, computes its own SHA-256, verifies size and hash against the source, then renames the temporary file to the requested destination. Failed or cancelled transfers remove the temporary part file.

The target side is a mutating action and obeys Human Control: a new transfer is rejected while the human owns execution control. Running transfers are left unchanged, matching the behavior of existing running jobs and executions.

## Terminal UI and Human Control

ShellCore runs a local libvaxis/vxfw terminal UI. It does not open a local HTTP control port. The dashboard shows exec, job and shell activity together with recent events and selected-resource details.

Keyboard controls:

```text
j/k       move selection
Enter     open/close detail
/         filter resources
t         toggle Agent/Human Control
x         terminate exec / stop job / kill shell (Human Control)
a         attach to a running shell (Human Control)
q         stop ShellCore
```

Shell attach connects the local terminal to the existing PTY/ConPTY session. Press `Ctrl+]` to detach and return to the dashboard without killing the shell.

While Human Control is active, mutating agent operations remain blocked by the existing control-state checks. Runtime logs and important lifecycle state are surfaced through the Events view so terminal output does not corrupt the TUI.

Stopping `zshell-core` closes the device transport; the gateway then removes it from the live registry.
