# Apple Home MCP plugin

This directory contains the dependency-free stdio MCP server and local
companion client used by the `apple-home` Codex plugin.

For direct access, launch the Apple Home Bridge companion on iPhone, iPad, or
Mac Catalyst and grant it Home permission. The plugin can then inventory the
Home graph, refresh readable characteristics, write metadata-valid values, and
run scenes. Every write and scene requires explicit confirmation; sensitive
services also require approval in the companion or fail closed.

The curated Shortcuts bridge remains available when the companion is not
installed. Create a Shortcuts folder named `Apple Home MCP`, then add shortcuts
named:

- `Read - <name>` for Home state output
- `Control - <name>` for one device action
- `Scene - <name>` for one Home scene

Read shortcuts should finish with **Stop and Output** and return UTF-8 text or
JSON. Controls and scenes require explicit confirmation at tool-call time.

Run tests from the repository root:

```bash
/usr/bin/python3 -m unittest discover -s plugins/apple-home/tests -v
/usr/bin/python3 -m py_compile plugins/apple-home/server.py plugins/apple-home/companion.py
```
