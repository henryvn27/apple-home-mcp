# Security

## Boundary

Apple Home MCP never talks to private HomeKit or iCloud APIs. It can discover
and run only shortcuts inside one exact Shortcuts folder, `Apple Home MCP` by
default. Eligible shortcuts must use one of three prefixes:

- `Read - ` for state queries
- `Control - ` for one physical action
- `Scene - ` for a Home scene

The server resolves the shortcut's native identifier before running it. User
input is passed as a mode-`0600` temporary file and deleted immediately after
the command returns. No shell is used, and no user value becomes executable
source.

Every control or scene call requires `confirm: true` and is marked destructive
and non-idempotent for compatible MCP clients. The server cannot inspect what a
shortcut does, so the folder itself is a user-managed allowlist. Do not add
door locks, garage doors, alarms, cameras, security systems, or other
high-consequence shortcuts. Do not use this project for emergency or safety
automation.

## Data and permissions

Local Codex use requires no API key. Home data, Shortcuts permissions, and
execution stay on the Mac. A read shortcut may return sensitive occupancy,
climate, or sensor data; expose the MCP server through a tunnel only if you
understand and accept that boundary.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/henryvn27/apple-home-mcp/security/advisories/new).
Include the affected version, reproduction steps, and expected impact. Do not
open a public issue for an unpatched vulnerability.
