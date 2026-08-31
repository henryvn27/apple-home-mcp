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

## HomeKit boundary

Inventory includes homes, rooms, zones, accessories, services,
characteristics, and action sets. Each object includes its stable HomeKit UUID.
Characteristics include the public properties and metadata needed to interpret
their values: format, units, minimum, maximum, step size, maximum length, and
valid values when HomeKit supplies them.

Every read or write identifies the full `home_id`, `accessory_id`, `service_id`,
and `characteristic_id` path. The companion resolves that path against its live
Home graph on every request. It performs a fresh read only when HomeKit marks
the characteristic readable. It writes only when HomeKit marks the
characteristic writable and the value matches the characteristic format and
metadata.

Writes and scenes require `confirm: true`. This confirms the agent call; it
does not bypass companion policy. Locks, garage doors, security systems,
cameras, alarms, access control, emergency functions, and equivalent
high-consequence services use an in-app human approval gate:

1. The first request is queued, returns `human_approval_required`, and displays
   its exact target and action in the companion.
2. The user approves or rejects it in the companion.
3. Approval permits one identical retry within 60 seconds. The grant is bound
   to the operation, full UUID path or scene, and exact scalar value.
4. The grant is consumed before mutation. Changed, expired, replayed, rejected,
   queue-overflowed, or post-restart requests fail closed.

The Home graph, writable/readable properties, safety classification, and value
metadata are resolved and validated again immediately before mutation.

The bridge covers controls available through Apple's public HomeKit APIs. It
does not emulate private Siri services, scrape Home data, or call private
iCloud endpoints.
