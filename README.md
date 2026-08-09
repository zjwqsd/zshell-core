# zshell-core

Zig execution core for zshell.

ShellCore contains the operating-system execution capabilities only. It has no MCP server, OAuth implementation, public HTTP gateway or tunnel logic.

## Responsibilities

- execute short-lived commands
- manage background jobs
- manage persistent shell sessions
- report local environment information
- provide local Human Control on a loopback port starting at `8766`
- actively connect to exactly one configured gateway
- declare its own unique device name and current workspace
- reconnect automatically after connection loss

## Connection configuration

Required:

```text
ZSHELL_GATEWAY_ADDR=192.168.1.20:8767
ZSHELL_DEVICE_TOKEN=<same 24-512 character secret as gateway>
ZSHELL_DEVICE_NAME=<unique name chosen for this Core instance>
```

`ZSHELL_DEVICE_NAME` is mandatory. ShellCore does not infer it from the hostname and the gateway does not assign one.

Examples:

```text
ZSHELL_DEVICE_NAME=windows-laptop
ZSHELL_DEVICE_NAME=4090-server
ZSHELL_DEVICE_NAME=laptop-project-a
ZSHELL_DEVICE_NAME=laptop-project-b
```

This makes multiple Core instances on the same physical computer explicit: give each workspace its own name.

At handshake time ShellCore also sends its current working directory as `workspace`. The gateway exposes it through `device_list`, but routing is always by `name`.

`ZSHELL_GATEWAY_ADDR` currently accepts an IP literal plus port, for example `192.168.1.20:8767`.

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

## Run

Linux:

```bash
export ZSHELL_GATEWAY_ADDR=192.168.1.20:8767
export ZSHELL_DEVICE_TOKEN='replace-with-the-shared-device-secret'
export ZSHELL_DEVICE_NAME='4090-server'
./zig-out/bin/zshell-core
```

PowerShell:

```powershell
$env:ZSHELL_GATEWAY_ADDR = "192.168.1.20:8767"
$env:ZSHELL_DEVICE_TOKEN = "replace-with-the-shared-device-secret"
$env:ZSHELL_DEVICE_NAME = "windows-laptop"
.\zig-out\bin\zshell-core.exe
```

If the gateway is unavailable, ShellCore stays running and retries every two seconds.

If another connected Core already owns the same name, the gateway rejects this instance. It keeps retrying, so it can connect after the conflicting instance disconnects.

## Multiple workspaces on one computer

Start one Core from each workspace with a different name:

```powershell
cd D:\Projects\A
$env:ZSHELL_DEVICE_NAME = "laptop-project-a"
.\zshell-core.exe
```

```powershell
cd D:\Projects\B
$env:ZSHELL_DEVICE_NAME = "laptop-project-b"
.\zshell-core.exe
```

The Human Control server automatically selects an unused loopback port from `8766` through `8799`, so multiple Core instances do not compete for one fixed local port. The selected URL is printed in the startup log.

## Human Control

The local Human Control interface remains independent of the gateway. The first instance normally uses:

```text
http://127.0.0.1:8766
```

Additional local instances choose the next available port. Human Control can block new Agent mutations, inspect local jobs/shells/events, and terminate active work.

Stopping the `zshell-core` process immediately withdraws that device from the gateway after transport failure/heartbeat detection.

## Security

ShellCore removes `ZSHELL_DEVICE_TOKEN` from child commands and persistent shells. The device transport is intended for a trusted network/private VPN because protocol v1 uses raw TCP without built-in TLS.
