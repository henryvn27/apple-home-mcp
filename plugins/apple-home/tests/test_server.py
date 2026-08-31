import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


PLUGIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN))
import server  # noqa: E402


UUIDS = {
    "folder": "00000000-0000-0000-0000-000000000000",
    "read": "11111111-1111-1111-1111-111111111111",
    "control": "22222222-2222-2222-2222-222222222222",
    "scene": "33333333-3333-3333-3333-333333333333",
    "ignored": "44444444-4444-4444-4444-444444444444",
}
FOLDER_LISTING = "Apple Home MCP (%s)\n" % UUIDS["folder"]
LISTING = "\n".join(
    [
        "Read - Living Room Temperature (%s)" % UUIDS["read"],
        "Control - Desk Lamp (%s)" % UUIDS["control"],
        "Scene - Good Night (%s)" % UUIDS["scene"],
        "Unrelated Shortcut (%s)" % UUIDS["ignored"],
        "",
    ]
)


def completed(stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)


class ServerTests(unittest.TestCase):
    def test_protocol_round_trip_lists_all_tools(self):
        requests = "\n".join(
            [
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"},
                    }
                ),
                json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
                json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
                "",
            ]
        )
        process = subprocess.run(
            ["/usr/bin/python3", str(PLUGIN / "server.py")],
            input=requests,
            capture_output=True,
            text=True,
            check=True,
        )
        responses = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(responses[0]["result"]["serverInfo"]["version"], "0.2.0")
        self.assertEqual(
            [tool["name"] for tool in responses[1]["result"]["tools"]],
            [
                "get_home_bridge_status",
                "list_home_inventory",
                "read_home_characteristic",
                "write_home_characteristic",
                "list_homekit_scenes",
                "run_homekit_scene",
                "list_home_actions",
                "read_home_state",
                "run_home_action",
                "run_home_scene",
            ],
        )

    def test_annotations_match_physical_effects(self):
        annotations = {tool["name"]: tool["annotations"] for tool in server.TOOLS}
        for name in (
            "get_home_bridge_status",
            "list_home_inventory",
            "read_home_characteristic",
            "list_homekit_scenes",
            "list_home_actions",
            "read_home_state",
        ):
            self.assertTrue(annotations[name]["readOnlyHint"])
            self.assertFalse(annotations[name]["destructiveHint"])
            self.assertTrue(annotations[name]["idempotentHint"])
        for name in (
            "write_home_characteristic",
            "run_homekit_scene",
            "run_home_action",
            "run_home_scene",
        ):
            self.assertFalse(annotations[name]["readOnlyHint"])
            self.assertTrue(annotations[name]["destructiveHint"])
            self.assertFalse(annotations[name]["idempotentHint"])

    def test_normalizes_reads_controls_scenes_and_input(self):
        read = server.normalize_arguments(
            "read_home_state",
            {"name": " Temperature ", "input": "room=living", "timeout_seconds": 20},
        )
        self.assertEqual(
            read,
            {
                "action": "read_home_state",
                "kind": "read",
                "name": "Temperature",
                "input": "room=living",
                "timeout_seconds": 20,
            },
        )
        control = server.normalize_arguments(
            "run_home_action", {"name": "Desk Lamp", "confirm": True}
        )
        self.assertEqual(control["kind"], "control")
        self.assertEqual(control["timeout_seconds"], 60)
        scene = server.normalize_arguments(
            "run_home_scene", {"name": "Good Night", "confirm": True}
        )
        self.assertEqual(scene["kind"], "scene")

    def test_normalizes_direct_homekit_operations(self):
        read = server.normalize_arguments(
            "read_home_characteristic",
            {
                "home_id": UUIDS["folder"].upper(),
                "accessory_id": UUIDS["read"],
                "service_id": UUIDS["control"],
                "characteristic_id": UUIDS["scene"],
            },
        )
        self.assertEqual(read["companion_operation"], "read_characteristic")
        self.assertEqual(
            read["companion_arguments"]["home_id"], UUIDS["folder"].lower()
        )
        write = server.normalize_arguments(
            "write_home_characteristic",
            {
                "home_id": UUIDS["folder"],
                "accessory_id": UUIDS["read"],
                "service_id": UUIDS["control"],
                "characteristic_id": UUIDS["scene"],
                "value": 42.5,
                "confirm": True,
            },
        )
        self.assertEqual(write["companion_operation"], "write_characteristic")
        self.assertEqual(write["companion_arguments"]["value"], 42.5)
        scene = server.normalize_arguments(
            "run_homekit_scene",
            {
                "home_id": UUIDS["folder"],
                "scene_id": UUIDS["scene"],
                "confirm": True,
            },
        )
        self.assertEqual(scene["companion_operation"], "run_scene")
        with self.assertRaisesRegex(server.UserError, "HomeKit UUID"):
            server.normalize_arguments(
                "list_homekit_scenes", {"home_id": "not-a-uuid"}
            )
        with self.assertRaisesRegex(server.UserError, "finite"):
            server.normalize_arguments(
                "write_home_characteristic",
                {
                    "home_id": UUIDS["folder"],
                    "accessory_id": UUIDS["read"],
                    "service_id": UUIDS["control"],
                    "characteristic_id": UUIDS["scene"],
                    "value": float("nan"),
                    "confirm": True,
                },
            )

    def test_controls_require_explicit_confirmation(self):
        for name in (
            "write_home_characteristic",
            "run_homekit_scene",
            "run_home_action",
            "run_home_scene",
        ):
            for value in (None, False, "yes", 1):
                if name == "write_home_characteristic":
                    arguments = {
                        "home_id": UUIDS["folder"],
                        "accessory_id": UUIDS["read"],
                        "service_id": UUIDS["control"],
                        "characteristic_id": UUIDS["scene"],
                        "value": True,
                    }
                elif name == "run_homekit_scene":
                    arguments = {
                        "home_id": UUIDS["folder"],
                        "scene_id": UUIDS["scene"],
                    }
                else:
                    arguments = {"name": "Example"}
                if value is not None:
                    arguments["confirm"] = value
                with self.subTest(name=name, value=value):
                    with self.assertRaisesRegex(server.UserError, "confirm must be true"):
                        server.normalize_arguments(name, arguments)

    def test_invalid_inputs_fail_closed(self):
        cases = [
            ("list_home_actions", {"name": "x"}, "unknown argument"),
            ("read_home_state", {"name": ""}, "cannot be empty"),
            (
                "read_home_state",
                {"name": "Temperature", "timeout_seconds": True},
                "integer from 1 to 300",
            ),
            (
                "read_home_state",
                {"name": "Temperature", "timeout_seconds": 301},
                "integer from 1 to 300",
            ),
            ("read_home_state", {"name": "bad\x00name"}, "null byte"),
        ]
        for name, arguments, message in cases:
            with self.subTest(name=name, arguments=arguments):
                with self.assertRaisesRegex(server.UserError, message):
                    server.normalize_arguments(name, arguments)

    def test_discovers_only_prefixed_shortcuts_and_uses_exact_folder(self):
        with mock.patch.object(
            server.subprocess,
            "run",
            side_effect=[
                completed(stdout=FOLDER_LISTING),
                completed(stdout=LISTING),
            ],
        ) as run:
            folder, groups, ignored = server._discover_shortcuts()
        self.assertEqual(folder, "Apple Home MCP")
        self.assertEqual(groups["read"][0]["name"], "Living Room Temperature")
        self.assertEqual(groups["control"][0]["identifier"], UUIDS["control"])
        self.assertEqual(groups["scene"][0]["name"], "Good Night")
        self.assertEqual(ignored, 1)
        self.assertEqual(
            run.call_args_list[0].args[0],
            ["/usr/bin/shortcuts", "list", "--folders", "--show-identifiers"],
        )
        self.assertEqual(
            run.call_args_list[1].args[0],
            [
                "/usr/bin/shortcuts",
                "list",
                "--folder-name",
                UUIDS["folder"],
                "--show-identifiers",
            ],
        )

    def test_custom_folder_is_bounded_and_supported(self):
        with mock.patch.dict(server.os.environ, {"APPLE_HOME_MCP_FOLDER": "My Home"}):
            with mock.patch.object(
                server.subprocess,
                "run",
                side_effect=[
                    completed(stdout="My Home (%s)\n" % UUIDS["folder"]),
                    completed(stdout=""),
                ],
            ) as run:
                folder, _, _ = server._discover_shortcuts()
        self.assertEqual(folder, "My Home")
        self.assertEqual(run.call_args_list[1].args[0][3], UUIDS["folder"])
        with mock.patch.dict(server.os.environ, {"APPLE_HOME_MCP_FOLDER": " "}):
            with self.assertRaisesRegex(server.UserError, "cannot be empty"):
                server._folder_name()

    def test_duplicate_or_malformed_listings_fail_closed(self):
        duplicate = "\n".join(
            [
                "Read - Temperature (%s)" % UUIDS["read"],
                "Read - temperature (%s)" % UUIDS["control"],
            ]
        )
        with mock.patch.object(
            server.subprocess,
            "run",
            side_effect=[completed(stdout=FOLDER_LISTING), completed(stdout=duplicate)],
        ):
            with self.assertRaisesRegex(server.UserError, "More than one read"):
                server._discover_shortcuts()
        with mock.patch.object(
            server.subprocess,
            "run",
            side_effect=[
                completed(stdout=FOLDER_LISTING),
                completed(stdout="Read - Bad"),
            ],
        ):
            with self.assertRaisesRegex(server.UserError, "unrecognized"):
                server._discover_shortcuts()

    def test_status_reports_missing_folder_without_running_actions(self):
        with mock.patch.object(
            server.subprocess,
            "run",
            return_value=completed(
                stdout="Another Folder (%s)\n" % UUIDS["ignored"]
            ),
        ) as run:
            result = server.invoke_home({"action": "get_home_bridge_status"})
        self.assertFalse(result["available"])
        self.assertIn("Create a Shortcuts folder", result["reason"])
        self.assertEqual(run.call_count, 1)

    def test_list_returns_public_names_without_identifiers(self):
        with mock.patch.object(
            server.subprocess,
            "run",
            side_effect=[
                completed(stdout=FOLDER_LISTING),
                completed(stdout=LISTING),
            ],
        ):
            result = server.invoke_home({"action": "list_home_actions"})
        self.assertEqual(result["reads"][0]["name"], "Living Room Temperature")
        self.assertNotIn("identifier", result["reads"][0])
        self.assertEqual(result["ignored_shortcuts"], 1)

    def test_direct_homekit_calls_use_the_companion_contract(self):
        payload = server.normalize_arguments(
            "read_home_characteristic",
            {
                "home_id": UUIDS["folder"],
                "accessory_id": UUIDS["read"],
                "service_id": UUIDS["control"],
                "characteristic_id": UUIDS["scene"],
            },
        )
        with mock.patch.object(
            server.companion, "call", return_value={"value": 72}
        ) as call:
            result = server.invoke_home(payload)
        self.assertEqual(result, {"value": 72})
        call.assert_called_once_with("read_characteristic", payload["companion_arguments"])

    def test_bridge_status_prefers_homekit_and_preserves_shortcuts(self):
        shortcuts = {
            "available": True,
            "folder": "Apple Home MCP",
            "reads": 1,
            "controls": 2,
            "scenes": 3,
            "ignored_shortcuts": 0,
        }
        with mock.patch.object(server, "_shortcuts_status", return_value=shortcuts):
            with mock.patch.object(
                server.companion,
                "call",
                return_value={"available": True, "authorized": True},
            ):
                result = server.invoke_home({"action": "get_home_bridge_status"})
        self.assertTrue(result["available"])
        self.assertEqual(result["mode"], "homekit")
        self.assertEqual(result["shortcuts"], shortcuts)

    def test_run_uses_exact_identifier_and_deletes_temporary_input(self):
        groups = {
            "read": [
                {
                    "name": "Temperature",
                    "shortcut_name": "Read - Temperature",
                    "identifier": UUIDS["read"],
                }
            ],
            "control": [],
            "scene": [],
        }
        observed_path = []

        def fake_run(command, **kwargs):
            self.assertEqual(command[:3], ["/usr/bin/shortcuts", "run", UUIDS["read"]])
            self.assertEqual(command[3], "--input-path")
            path = Path(command[4])
            observed_path.append(path)
            self.assertEqual(path.read_text(), "room=living")
            self.assertNotIn("shell", kwargs)
            return completed(stdout=b'{"temperature":72}', stderr=b"")

        with mock.patch.object(
            server, "_discover_shortcuts", return_value=("Apple Home MCP", groups, 0)
        ):
            with mock.patch.object(server.subprocess, "run", side_effect=fake_run):
                result = server._run_shortcut(
                    "read", "temperature", "room=living", 30
                )
        self.assertEqual(result["output"], {"temperature": 72})
        self.assertFalse(observed_path[0].exists())

    def test_run_returns_plain_text_and_rejects_unknown_names(self):
        groups = {
            "read": [],
            "control": [
                {
                    "name": "Desk Lamp",
                    "shortcut_name": "Control - Desk Lamp",
                    "identifier": UUIDS["control"],
                }
            ],
            "scene": [],
        }
        with mock.patch.object(
            server, "_discover_shortcuts", return_value=("Apple Home MCP", groups, 0)
        ):
            with mock.patch.object(
                server.subprocess,
                "run",
                return_value=completed(stdout=b"Lamp is on", stderr=b""),
            ):
                result = server._run_shortcut("control", "Desk Lamp", None, 60)
            self.assertEqual(result["output"], "Lamp is on")
            with self.assertRaisesRegex(server.UserError, "No control shortcut"):
                server._run_shortcut("control", "Unknown", None, 60)

    def test_run_maps_timeout_failure_and_binary_output(self):
        groups = {
            "read": [
                {
                    "name": "State",
                    "shortcut_name": "Read - State",
                    "identifier": UUIDS["read"],
                }
            ],
            "control": [],
            "scene": [],
        }
        with mock.patch.object(
            server, "_discover_shortcuts", return_value=("Apple Home MCP", groups, 0)
        ):
            with mock.patch.object(
                server.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 5)
            ):
                with self.assertRaisesRegex(server.UserError, "within 5 seconds"):
                    server._run_shortcut("read", "State", None, 5)
            with mock.patch.object(
                server.subprocess,
                "run",
                return_value=completed(stderr=b"denied", returncode=1),
            ):
                with self.assertRaisesRegex(server.UserError, "denied"):
                    server._run_shortcut("read", "State", None, 5)
            with mock.patch.object(
                server.subprocess,
                "run",
                return_value=completed(stdout=b"\xff", stderr=b""),
            ):
                with self.assertRaisesRegex(server.UserError, "UTF-8"):
                    server._run_shortcut("read", "State", None, 5)

    def test_call_tool_returns_structured_content_and_errors(self):
        with mock.patch.object(
            server,
            "invoke_home",
            return_value={"available": True, "reads": 1, "controls": 1, "scenes": 1},
        ):
            result = server.call_tool(
                {"name": "get_home_bridge_status", "arguments": {}}
            )
        self.assertTrue(result["structuredContent"]["available"])
        self.assertNotIn("isError", result)
        error = server.call_tool(
            {"name": "run_home_action", "arguments": {"name": "Lamp"}}
        )
        self.assertTrue(error["isError"])
        self.assertIn("confirm must be true", error["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
