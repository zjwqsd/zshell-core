# zshell-core

Zig execution core for zshell.

ShellCore contains the operating-system execution capabilities only. It has no MCP server, OAuth implementation, public HTTP gateway or tunnel logic.

## Responsibilities

- execute short-lived commands
- manage background jobs
- manage persistent shell sessions
- report local environment information
- provide local Human Control on `127.0.0.1:8766`
- actively connect to exactly one configured gateway
- reconnect automatically after connection loss

## Connection configuration

Required:

```text
ZSHELL_DEVICE_TOKEN=<same 24-512 character secret as gateway>
```

Optional:

```text
ZSHELL_GATEWAY_ADDR=127.0.0.1:8767
ZSHELL_DEVICE_NAME=shellcore
```

`ZSHELL_GATEWAY_ADDR` currently accepts an IP literal plus port, for example `192.168.1.20:8767`.

One ShellCore process connects to one gateway. The gateway itself accepts only one active ShellCore, so the resulting topology is intentionally one-to-one.

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

## Human Control

The local Human Control interface remains independent of the gateway:

```text
http://127.0.0.1:8766
```

It can take execution control, inspect local jobs/shells/events, and terminate active work.

## Security

ShellCore removes `ZSHELL_DEVICE_TOKEN` from child commands and persistent shells. The device transport is intended for a trusted LAN/private VPN because protocol v1 uses raw TCP without built-in TLS.
