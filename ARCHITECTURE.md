# ShellCore architecture

```text
                  trusted LAN / private VPN
                           |
                           | ShellCore initiates TCP
                           v
                    zshell-gateway
                           ^
                           |
+--------------------------+---------------------------+
| zshell-core (Zig)                                    |
|                                                      |
| device/client.zig       connection + reconnect       |
| protocol/dispatcher.zig operation dispatch           |
| tools/*                 exec / environment / jobs    |
| shells/*                persistent shells            |
| executions/*            execution tracking           |
| control/*               local Human Control :8766    |
+------------------------------------------------------+
```

## Separation rule

ShellCore understands only the private device protocol. It does not import or implement MCP or OAuth concepts.

## Lifecycle

1. initialize local jobs and persistent-shell managers
2. start local Human Control on loopback `:8766`
3. connect to `ZSHELL_GATEWAY_ADDR`
4. authenticate with `ZSHELL_DEVICE_TOKEN`
5. receive operation calls and dispatch them locally
6. on disconnect, wait two seconds and reconnect

The gateway is the only remote peer configured by ShellCore.
