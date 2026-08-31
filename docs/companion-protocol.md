# Apple Home companion protocol

The Mac Catalyst companion is the only process that talks to HomeKit. The MCP
server connects to it over one authenticated, loopback-only TCP request.

## Descriptor

The companion writes this file with owner-only `0600` permissions:

```text
~/Library/Containers/com.henryvanness.apple-home-bridge/Data/Library/
Application Support/Apple Home Bridge/bridge.json
```

```json
{
  "schemaVersion": 1,
  "host": "127.0.0.1",
  "port": 49152,
  "token": "a-random-per-install-secret",
  "appVersion": "0.2.0",
  "pid": 1234
}
```

`APPLE_HOME_COMPANION_DESCRIPTOR` may point the MCP at another descriptor for
development. The host must remain `127.0.0.1` or `::1`.

## Exchange

Each TCP connection carries one UTF-8 JSON request line and one JSON response
line, then closes. Requests and responses are limited to 1 MiB.

```json
{"schemaVersion":1,"token":"...","operation":"inventory","arguments":{}}
```

```json
{"ok":true,"result":{"homes":[]}}
```

```json
{"ok":false,"error":{"code":"not_authorized","message":"Home access was denied"}}
```

Supported operations are `status`, `inventory`, `read_characteristic`,
`write_characteristic`, `list_scenes`, and `run_scene`.

All objects use HomeKit UUIDs. Characteristic writes must be checked against
HomeKit's readable/writable properties and metadata before execution. Writes
and scenes require `confirm: true`. Locks, garage doors, security systems,
cameras, alarms, access-control, and emergency functions require an in-app
human approval gate or fail closed.
