#!/usr/bin/env python3
"""Dependency-free MCP server for Apple HomeKit and Shortcuts."""

import json
import math
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import companion


PROTOCOL_VERSION = "2025-06-18"
SERVER_VERSION = "0.2.0"
SHORTCUTS = "/usr/bin/shortcuts"
DEFAULT_FOLDER = "Apple Home MCP"
DEFAULT_TIMEOUT = 60
MAX_OUTPUT_BYTES = 1024 * 1024
PREFIXES = {
    "read": "Read - ",
    "control": "Control - ",
    "scene": "Scene - ",
}
IDENTIFIER_RE = re.compile(
    r"^(?P<name>.+) \((?P<identifier>[0-9A-Fa-f]{8}"
    r"-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}"
    r"-[0-9A-Fa-f]{12})\)$"
)
UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)


def _annotations(title, *, read_only, destructive=False, idempotent=True):
    return {
        "title": title,
        "readOnlyHint": read_only,
        "destructiveHint": destructive,
        "idempotentHint": idempotent,
        "openWorldHint": False,
    }


NAME_SCHEMA = {
    "type": "string",
    "minLength": 1,
    "maxLength": 256,
    "description": "Exact action name returned by list_home_actions, without its prefix.",
}
INPUT_SCHEMA = {
    "type": "string",
    "maxLength": 16384,
    "description": (
        "Optional UTF-8 text supplied to the shortcut as a temporary input file."
    ),
}
TIMEOUT_SCHEMA = {
    "type": "integer",
    "minimum": 1,
    "maximum": 300,
    "default": DEFAULT_TIMEOUT,
}
CONFIRM_SCHEMA = {
    "type": "boolean",
    "const": True,
    "description": (
        "Must be true only after the user explicitly requested this physical action."
    ),
}
UUID_SCHEMA = {
    "type": "string",
    "pattern": (
        r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
        r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
    ),
    "description": "Exact HomeKit UUID returned by list_home_inventory.",
}
VALUE_SCHEMA = {
    "oneOf": [
        {"type": "boolean"},
        {"type": "number"},
        {"type": "string", "maxLength": 1024},
    ],
    "description": "Value validated against the characteristic's HomeKit metadata.",
}


TOOLS = [
    {
        "name": "get_home_bridge_status",
        "title": "Get Apple Home Bridge Status",
        "description": (
            "Check the direct HomeKit companion and curated Shortcuts fallback "
            "without reading a characteristic or running an action."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "annotations": _annotations("Get Apple Home Bridge Status", read_only=True),
    },
    {
        "name": "list_home_inventory",
        "title": "List Apple Home Inventory",
        "description": (
            "List HomeKit homes, rooms, zones, accessories, services, characteristics, "
            "properties, metadata, and stable UUIDs from the local companion."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "annotations": _annotations("List Apple Home Inventory", read_only=True),
    },
    {
        "name": "read_home_characteristic",
        "title": "Read Apple Home Characteristic",
        "description": (
            "Refresh and return one exact readable HomeKit characteristic by UUID."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "home_id": UUID_SCHEMA,
                "accessory_id": UUID_SCHEMA,
                "service_id": UUID_SCHEMA,
                "characteristic_id": UUID_SCHEMA,
            },
            "required": [
                "home_id",
                "accessory_id",
                "service_id",
                "characteristic_id",
            ],
            "additionalProperties": False,
        },
        "annotations": _annotations("Read Apple Home Characteristic", read_only=True),
    },
    {
        "name": "write_home_characteristic",
        "title": "Write Apple Home Characteristic",
        "description": (
            "Write one exact HomeKit characteristic after metadata validation and "
            "explicit confirmation. High-risk controls require companion approval."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "home_id": UUID_SCHEMA,
                "accessory_id": UUID_SCHEMA,
                "service_id": UUID_SCHEMA,
                "characteristic_id": UUID_SCHEMA,
                "value": VALUE_SCHEMA,
                "confirm": CONFIRM_SCHEMA,
            },
            "required": [
                "home_id",
                "accessory_id",
                "service_id",
                "characteristic_id",
                "value",
                "confirm",
            ],
            "additionalProperties": False,
        },
        "annotations": _annotations(
            "Write Apple Home Characteristic",
            read_only=False,
            destructive=True,
            idempotent=False,
        ),
    },
    {
        "name": "list_homekit_scenes",
        "title": "List Apple HomeKit Scenes",
        "description": "List HomeKit action sets and scenes with stable UUIDs.",
        "inputSchema": {
            "type": "object",
            "properties": {"home_id": UUID_SCHEMA},
            "additionalProperties": False,
        },
        "annotations": _annotations("List Apple HomeKit Scenes", read_only=True),
    },
    {
        "name": "run_homekit_scene",
        "title": "Run Apple HomeKit Scene",
        "description": (
            "Run one exact HomeKit action set after explicit confirmation. "
            "High-risk scenes require companion approval."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "home_id": UUID_SCHEMA,
                "scene_id": UUID_SCHEMA,
                "confirm": CONFIRM_SCHEMA,
            },
            "required": ["home_id", "scene_id", "confirm"],
            "additionalProperties": False,
        },
        "annotations": _annotations(
            "Run Apple HomeKit Scene",
            read_only=False,
            destructive=True,
            idempotent=False,
        ),
    },
    {
        "name": "list_home_actions",
        "title": "List Apple Home Actions",
        "description": (
            "List curated Read, Control, and Scene shortcuts from the exact Apple "
            "Home MCP folder. No shortcut is run."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "annotations": _annotations("List Apple Home Actions", read_only=True),
    },
    {
        "name": "read_home_state",
        "title": "Read Apple Home State",
        "description": (
            "Run one exact Read-prefixed shortcut and return its text or JSON output."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": NAME_SCHEMA,
                "input": INPUT_SCHEMA,
                "timeout_seconds": TIMEOUT_SCHEMA,
            },
            "required": ["name"],
            "additionalProperties": False,
        },
        "annotations": _annotations("Read Apple Home State", read_only=True),
    },
    {
        "name": "run_home_action",
        "title": "Run Apple Home Action",
        "description": (
            "Run one exact Control-prefixed shortcut. This may change physical "
            "accessories and requires explicit user confirmation."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": NAME_SCHEMA,
                "input": INPUT_SCHEMA,
                "timeout_seconds": TIMEOUT_SCHEMA,
                "confirm": CONFIRM_SCHEMA,
            },
            "required": ["name", "confirm"],
            "additionalProperties": False,
        },
        "annotations": _annotations(
            "Run Apple Home Action",
            read_only=False,
            destructive=True,
            idempotent=False,
        ),
    },
    {
        "name": "run_home_scene",
        "title": "Run Apple Home Scene",
        "description": (
            "Run one exact Scene-prefixed shortcut. This may change several physical "
            "accessories and requires explicit user confirmation."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": NAME_SCHEMA,
                "input": INPUT_SCHEMA,
                "timeout_seconds": TIMEOUT_SCHEMA,
                "confirm": CONFIRM_SCHEMA,
            },
            "required": ["name", "confirm"],
            "additionalProperties": False,
        },
        "annotations": _annotations(
            "Run Apple Home Scene",
            read_only=False,
            destructive=True,
            idempotent=False,
        ),
    },
]
TOOL_NAMES = {tool["name"] for tool in TOOLS}


class UserError(Exception):
    pass


def _arguments(arguments, allowed):
    if not isinstance(arguments, dict):
        raise UserError("arguments must be an object")
    unknown = sorted(set(arguments) - allowed)
    if unknown:
        raise UserError(
            "unknown argument%s: %s"
            % ("" if len(unknown) == 1 else "s", ", ".join(unknown))
        )
    return arguments


def _text(value, field, maximum, *, required=False, allow_empty=False):
    if value is None and not required:
        return None
    if not isinstance(value, str):
        raise UserError("%s must be a string" % field)
    value = value.strip() if not allow_empty else value
    if required and not value:
        raise UserError("%s cannot be empty" % field)
    if "\x00" in value:
        raise UserError("%s cannot contain a null byte" % field)
    if len(value) > maximum:
        raise UserError("%s must be at most %d characters" % (field, maximum))
    return value


def _timeout(arguments):
    value = arguments.get("timeout_seconds", DEFAULT_TIMEOUT)
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 300:
        raise UserError("timeout_seconds must be an integer from 1 to 300")
    return value


def _uuid(value, field):
    value = _text(value, field, 36, required=True)
    if not UUID_RE.fullmatch(value):
        raise UserError("%s must be a HomeKit UUID" % field)
    return value.lower()


def _confirmed(arguments):
    if arguments.get("confirm") is not True:
        raise UserError(
            "confirm must be true after the user explicitly requests this action"
        )


def _characteristic_target(arguments):
    return {
        "home_id": _uuid(arguments.get("home_id"), "home_id"),
        "accessory_id": _uuid(arguments.get("accessory_id"), "accessory_id"),
        "service_id": _uuid(arguments.get("service_id"), "service_id"),
        "characteristic_id": _uuid(
            arguments.get("characteristic_id"), "characteristic_id"
        ),
    }


def _characteristic_value(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        if not math.isfinite(value):
            raise UserError("value must be a finite HomeKit value")
        return value
    if isinstance(value, str):
        if "\x00" in value or len(value) > 1024:
            raise UserError("value must be at most 1024 safe characters")
        return value
    raise UserError("value must be a string, number, or boolean")


def _folder_name():
    folder = os.environ.get("APPLE_HOME_MCP_FOLDER", DEFAULT_FOLDER).strip()
    if not folder:
        raise UserError("APPLE_HOME_MCP_FOLDER cannot be empty")
    if "\x00" in folder or len(folder) > 256:
        raise UserError("APPLE_HOME_MCP_FOLDER must be at most 256 safe characters")
    return folder


def normalize_arguments(name, arguments):
    if name in {
        "get_home_bridge_status",
        "list_home_inventory",
        "list_home_actions",
    }:
        _arguments(arguments, set())
        return {"action": name}

    if name == "read_home_characteristic":
        arguments = _arguments(
            arguments,
            {"home_id", "accessory_id", "service_id", "characteristic_id"},
        )
        return {
            "action": name,
            "companion_operation": "read_characteristic",
            "companion_arguments": _characteristic_target(arguments),
        }
    if name == "write_home_characteristic":
        arguments = _arguments(
            arguments,
            {
                "home_id",
                "accessory_id",
                "service_id",
                "characteristic_id",
                "value",
                "confirm",
            },
        )
        _confirmed(arguments)
        if "value" not in arguments:
            raise UserError("value is required")
        target = _characteristic_target(arguments)
        target.update({"value": _characteristic_value(arguments["value"]), "confirm": True})
        return {
            "action": name,
            "companion_operation": "write_characteristic",
            "companion_arguments": target,
        }
    if name == "list_homekit_scenes":
        arguments = _arguments(arguments, {"home_id"})
        payload = {
            "action": name,
            "companion_operation": "list_scenes",
            "companion_arguments": {},
        }
        if "home_id" in arguments:
            payload["companion_arguments"]["home_id"] = _uuid(
                arguments["home_id"], "home_id"
            )
        return payload
    if name == "run_homekit_scene":
        arguments = _arguments(arguments, {"home_id", "scene_id", "confirm"})
        _confirmed(arguments)
        return {
            "action": name,
            "companion_operation": "run_scene",
            "companion_arguments": {
                "home_id": _uuid(arguments.get("home_id"), "home_id"),
                "scene_id": _uuid(arguments.get("scene_id"), "scene_id"),
                "confirm": True,
            },
        }
    if name == "read_home_state":
        arguments = _arguments(arguments, {"name", "input", "timeout_seconds"})
        payload = {
            "action": name,
            "kind": "read",
            "name": _text(arguments.get("name"), "name", 256, required=True),
            "timeout_seconds": _timeout(arguments),
        }
    elif name in {"run_home_action", "run_home_scene"}:
        arguments = _arguments(
            arguments, {"name", "input", "timeout_seconds", "confirm"}
        )
        _confirmed(arguments)
        payload = {
            "action": name,
            "kind": "control" if name == "run_home_action" else "scene",
            "name": _text(arguments.get("name"), "name", 256, required=True),
            "timeout_seconds": _timeout(arguments),
        }
    else:
        raise UserError("unknown tool")
    if "input" in arguments:
        payload["input"] = _text(
            arguments["input"], "input", 16384, allow_empty=True
        )
    return payload


def _run_list(command, timeout_message):
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise UserError(timeout_message)
    except OSError as error:
        raise UserError("could not launch Apple Shortcuts: %s" % error)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        detail = detail.splitlines()[-1] if detail else "Shortcuts command failed"
        raise UserError(detail[:500])
    return completed.stdout


def _identifier_listing(stdout, noun):
    entries = []
    for raw_line in stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        match = IDENTIFIER_RE.fullmatch(line)
        if not match:
            raise UserError("Shortcuts returned an unrecognized %s listing" % noun)
        entries.append(
            {"name": match.group("name"), "identifier": match.group("identifier")}
        )
    return entries


def _list_process():
    folder = _folder_name()
    folders = _identifier_listing(
        _run_list(
            [SHORTCUTS, "list", "--folders", "--show-identifiers"],
            "Shortcuts did not list folders in 15 seconds",
        ),
        "folder",
    )
    matches = [item for item in folders if item["name"] == folder]
    if not matches:
        raise UserError(
            "Create a Shortcuts folder named “%s” and add prefixed Home shortcuts"
            % folder
        )
    if len(matches) > 1:
        raise UserError("More than one Shortcuts folder is named “%s”" % folder)
    stdout = _run_list(
        [
            SHORTCUTS,
            "list",
            "--folder-name",
            matches[0]["identifier"],
            "--show-identifiers",
        ],
        "Shortcuts did not list the Apple Home MCP folder in 15 seconds",
    )
    return folder, stdout


def _discover_shortcuts():
    folder, stdout = _list_process()
    groups = {"read": [], "control": [], "scene": []}
    ignored = 0
    seen = {kind: set() for kind in groups}
    for raw_line in stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        match = IDENTIFIER_RE.fullmatch(line)
        if not match:
            raise UserError("Shortcuts returned an unrecognized shortcut listing")
        shortcut_name = match.group("name")
        classified = False
        for kind, prefix in PREFIXES.items():
            if shortcut_name.startswith(prefix):
                name = shortcut_name[len(prefix) :].strip()
                if not name:
                    raise UserError("A %s shortcut has an empty action name" % kind)
                key = name.casefold()
                if key in seen[kind]:
                    raise UserError("More than one %s shortcut is named “%s”" % (kind, name))
                seen[kind].add(key)
                groups[kind].append(
                    {
                        "name": name,
                        "shortcut_name": shortcut_name,
                        "identifier": match.group("identifier"),
                    }
                )
                classified = True
                break
        if not classified:
            ignored += 1
    for entries in groups.values():
        entries.sort(key=lambda item: item["name"].casefold())
    return folder, groups, ignored


def _public_actions(folder, groups, ignored):
    def visible(entries):
        return [
            {"name": item["name"], "shortcut_name": item["shortcut_name"]}
            for item in entries
        ]

    return {
        "folder": folder,
        "reads": visible(groups["read"]),
        "controls": visible(groups["control"]),
        "scenes": visible(groups["scene"]),
        "ignored_shortcuts": ignored,
    }


def _shortcuts_status():
    try:
        folder, groups, ignored = _discover_shortcuts()
    except UserError as error:
        return {
            "available": False,
            "folder": _folder_name(),
            "reason": str(error),
            "reads": 0,
            "controls": 0,
            "scenes": 0,
        }
    return {
        "available": True,
        "folder": folder,
        "reads": len(groups["read"]),
        "controls": len(groups["control"]),
        "scenes": len(groups["scene"]),
        "ignored_shortcuts": ignored,
    }


def _bridge_status():
    shortcuts = _shortcuts_status()
    try:
        homekit = companion.call("status", timeout=3)
        if not isinstance(homekit, dict) or not isinstance(
            homekit.get("available"), bool
        ):
            raise companion.CompanionError(
                "Apple Home Bridge returned an invalid status"
            )
    except companion.CompanionError as error:
        homekit = {"available": False, "reason": str(error)}
    result = dict(shortcuts)
    result.update(
        {
            "available": homekit["available"] or shortcuts["available"],
            "mode": (
                "homekit"
                if homekit["available"]
                else "shortcuts" if shortcuts["available"] else "unavailable"
            ),
            "homekit": homekit,
            "shortcuts": shortcuts,
        }
    )
    return result


def _select_shortcut(kind, name):
    folder, groups, ignored = _discover_shortcuts()
    matches = [item for item in groups[kind] if item["name"].casefold() == name.casefold()]
    if not matches:
        raise UserError("No %s shortcut named “%s” exists in “%s”" % (kind, name, folder))
    return matches[0], folder, groups, ignored


def _run_shortcut(kind, name, input_text, timeout_seconds):
    shortcut, _, _, _ = _select_shortcut(kind, name)
    command = [SHORTCUTS, "run", shortcut["identifier"]]
    input_path = None
    try:
        if input_text is not None:
            with tempfile.NamedTemporaryFile(
                "w", encoding="utf-8", suffix=".txt", delete=False
            ) as temporary:
                temporary.write(input_text)
                input_path = Path(temporary.name)
            command.extend(["--input-path", str(input_path)])
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                timeout=timeout_seconds,
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise UserError(
                "Home shortcut “%s” did not finish within %d seconds"
                % (name, timeout_seconds)
            )
        except OSError as error:
            raise UserError("could not launch Apple Shortcuts: %s" % error)
    finally:
        if input_path is not None:
            input_path.unlink(missing_ok=True)

    stdout = completed.stdout or b""
    stderr = completed.stderr or b""
    if completed.returncode != 0:
        detail = stderr.decode("utf-8", errors="replace").strip()
        detail = detail.splitlines()[-1] if detail else "shortcut failed"
        raise UserError("Home shortcut “%s” failed: %s" % (name, detail[:500]))
    if len(stdout) > MAX_OUTPUT_BYTES:
        raise UserError("Home shortcut output exceeded 1 MiB")
    try:
        rendered = stdout.decode("utf-8").strip()
    except UnicodeDecodeError:
        raise UserError("Home shortcuts must return UTF-8 text or JSON")
    output = None
    if rendered:
        try:
            output = json.loads(rendered)
        except json.JSONDecodeError:
            output = rendered
    return {
        "kind": kind,
        "name": shortcut["name"],
        "shortcut_name": shortcut["shortcut_name"],
        "completed": True,
        "output": output,
    }


def invoke_home(payload):
    action = payload["action"]
    if action == "get_home_bridge_status":
        return _bridge_status()
    if action == "list_home_actions":
        return _public_actions(*_discover_shortcuts())
    if action == "list_home_inventory":
        try:
            return companion.call("inventory")
        except companion.CompanionError as error:
            raise UserError(str(error))
    if "companion_operation" in payload:
        try:
            return companion.call(
                payload["companion_operation"], payload["companion_arguments"]
            )
        except companion.CompanionError as error:
            raise UserError(str(error))
    if action in {"read_home_state", "run_home_action", "run_home_scene"}:
        return _run_shortcut(
            payload["kind"],
            payload["name"],
            payload.get("input"),
            payload["timeout_seconds"],
        )
    raise UserError("unknown tool")


def _tool_result(text, structured=None, is_error=False):
    result = {"content": [{"type": "text", "text": text}]}
    if structured is not None:
        result["structuredContent"] = structured
    if is_error:
        result["isError"] = True
    return result


def call_tool(params):
    if not isinstance(params, dict) or params.get("name") not in TOOL_NAMES:
        raise UserError("unknown tool")
    name = params["name"]
    try:
        payload = normalize_arguments(name, params.get("arguments", {}))
        result = invoke_home(payload)
    except UserError as error:
        return _tool_result(str(error), is_error=True)

    if name == "get_home_bridge_status":
        message = (
            "Apple Home bridge is ready."
            if result["available"]
            else "Apple Home bridge needs setup."
        )
    elif name == "list_home_actions":
        message = "Found %d reads, %d controls, and %d scenes." % (
            len(result["reads"]),
            len(result["controls"]),
            len(result["scenes"]),
        )
    elif name == "list_home_inventory":
        message = "Listed direct HomeKit inventory."
    elif name == "read_home_characteristic":
        message = "Read HomeKit characteristic."
    elif name == "write_home_characteristic":
        message = "Wrote HomeKit characteristic."
    elif name == "list_homekit_scenes":
        message = "Listed HomeKit scenes."
    elif name == "run_homekit_scene":
        message = "Ran HomeKit scene."
    elif name == "read_home_state":
        message = "Read “%s”." % result["name"]
    elif name == "run_home_action":
        message = "Ran home action “%s”." % result["name"]
    else:
        message = "Ran home scene “%s”." % result["name"]
    return _tool_result(message, result)


def _response(message_id, result):
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def _error(message_id, code, message):
    return {
        "jsonrpc": "2.0",
        "id": message_id,
        "error": {"code": code, "message": message},
    }


def handle_message(message):
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return _error(None, -32600, "Invalid Request")
    method = message.get("method")
    message_id = message.get("id")
    if message_id is None:
        return None
    if method == "initialize":
        return _response(
            message_id,
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "apple-home", "version": SERVER_VERSION},
                "instructions": (
                    "Use the direct HomeKit companion for granular inventory, fresh "
                    "characteristic reads, validated writes, and scenes. Stable UUIDs "
                    "come from list_home_inventory. Set confirm=true only after the "
                    "user explicitly requests a physical write or scene. The curated "
                    "Apple Home MCP Shortcuts folder remains a fallback."
                ),
            },
        )
    if method == "ping":
        return _response(message_id, {})
    if method == "tools/list":
        return _response(message_id, {"tools": TOOLS})
    if method == "tools/call":
        try:
            return _response(message_id, call_tool(message.get("params")))
        except UserError as error:
            return _error(message_id, -32602, str(error))
    return _error(message_id, -32601, "Method not found")


def main():
    for raw_line in sys.stdin:
        try:
            message = json.loads(raw_line)
            response = handle_message(message)
        except json.JSONDecodeError:
            response = _error(None, -32700, "Parse error")
        except Exception as error:
            print("apple-home server error: %s" % error, file=sys.stderr)
            response = _error(None, -32603, "Internal error")
        if response is not None:
            print(
                json.dumps(response, ensure_ascii=False, separators=(",", ":")),
                flush=True,
            )


if __name__ == "__main__":
    main()
