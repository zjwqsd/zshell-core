# ShellCore architecture

```text
                  trusted network / private VPN
                           |
                           | ShellCore initiates TCP
                           v
                    zshell-gateway
                           ^
                           |
+--------------------------+---------------------------+
| zshell-core (Zig)                                    |
|                                                      |
| device/client.zig       connect / identity / retry   |
| protocol/dispatcher.zig operation dispatch           |
| tools/*                 exec / environment / files   |
| jobs/*                  background jobs              |
| shells/*                persistent shells            |
| executions/*            execution tracking           |
| control/*               local Human Control          |
+------------------------------------------------------+
```

## Separation rule

ShellCore understands only the private device protocol. It does not implement MCP or OAuth.

## Identity

Every Core instance requires an explicit `ZSHELL_DEVICE_NAME`. The name is stable for the lifetime of that process and is the gateway routing key.

The Core also reports the working directory from which it was started. This `workspace` is metadata for the Agent and is not used as an identity key.

## Lifecycle

1. initialize local jobs and persistent-shell managers
2. bind Human Control to the first free loopback port in `8766..8799`
3. read `ZSHELL_DEVICE_NAME`, `ZSHELL_GATEWAY_ADDR`, and `ZSHELL_DEVICE_TOKEN`
4. connect to the configured gateway
5. send name, workspace, OS, architecture and Core version in the handshake
6. receive operation calls and dispatch them locally
7. on disconnect or rejection, wait two seconds and reconnect

A user can withdraw a device at any time by stopping its Core process.
