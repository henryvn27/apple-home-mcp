# Security

## Direct HomeKit companion

The Apple Home Bridge companion uses Apple's public HomeKit APIs and the Home
permission granted to the app. That permission can expose the user's Home
graph: home and room names, accessories, services, characteristic values, and
scenes. Treat this data as sensitive.

The MCP server and companion communicate over loopback TCP. The companion
binds only to `127.0.0.1` or `::1` and writes its port and a random bearer token
to an owner-only, mode-`0600` descriptor. Each connection accepts one
size-limited JSON request and returns one size-limited JSON response. The MCP
client rejects symlinked, incorrectly owned, incorrectly permissioned, or
non-loopback descriptors.

This protects the bridge from other local accounts and unauthenticated local
connections. It is not a sandbox between processes running as the same macOS
user: a process that can read that user's private files can also read the
descriptor token.

The companion resolves every UUID path against its current Home graph. Reads
require HomeKit's readable property. Writes require its writable property and
must match the characteristic's type, range, step, units, length, and valid
values when present. Every write and scene call requires `confirm: true` after
the user requests the physical action.

Confirmation does not bypass companion policy. Locks, garage doors, security
systems, alarms, access control, cameras, emergency functions, and equivalent
high-consequence services require an in-app human approval gate. The app shows
the exact target and value. An approval grants one identical retry for 60
seconds and is fingerprinted to the operation, full UUID path or scene, and
exact scalar value. It is consumed before mutation. Rejection, changed input,
expiry, replay, queue overflow, or app restart fails closed. Do not use this
project for emergency or life-safety automation.

The bridge does not use private HomeKit APIs, scrape Home data, or call private
iCloud endpoints. It cannot reproduce Siri behavior that Apple does not expose
through public HomeKit APIs.

## Shortcuts fallback

Without the companion, the server can discover and run only shortcuts inside
one exact Shortcuts folder, `Apple Home MCP` by default. Eligible shortcuts use
one of three prefixes:

- `Read - ` for state queries
- `Control - ` for one physical action
- `Scene - ` for a Home scene

The server resolves the shortcut's native identifier before running it. User
input is passed as a mode-`0600` temporary file and deleted immediately. It
does not invoke a shell, and no user value becomes executable source.

The server cannot inspect a shortcut's steps, so this folder is a user-managed
allowlist. Do not place high-consequence controls in it; unlike the direct
companion, the Shortcuts fallback cannot add an in-app approval gate.

## Remote access

Local Codex use requires no API key. Home data and actions stay on the device
unless the user deliberately exposes the MCP server through a tunnel. A tunnel
can carry occupancy, climate, sensor, and security-related data as well as
physical control requests. Protect its credentials and revoke it when it is no
longer needed.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/henryvn27/apple-home-mcp/security/advisories/new).
Include the affected version, reproduction steps, and expected impact. Do not
open a public issue for an unpatched vulnerability.
