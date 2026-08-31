# Apple Home MCP plugin

This directory contains the dependency-free stdio MCP server used by the
`apple-home` Codex plugin.

Create a Shortcuts folder named `Apple Home MCP`, then add shortcuts named:

- `Read - <name>` for Home state output
- `Control - <name>` for one device action
- `Scene - <name>` for one Home scene

Read shortcuts should finish with **Stop and Output** and return UTF-8 text or
JSON. Controls and scenes require explicit confirmation at tool-call time.

Run tests from the repository root:

```bash
/usr/bin/python3 -m unittest discover -s plugins/apple-home/tests -v
```
