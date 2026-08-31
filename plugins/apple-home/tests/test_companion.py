import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


PLUGIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN))
import companion  # noqa: E402


class FakeConnection:
    def __init__(self, response):
        self.response = response
        self.sent = b""
        self.timeout = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def settimeout(self, value):
        self.timeout = value

    def sendall(self, value):
        self.sent += value

    def recv(self, _):
        response, self.response = self.response, b""
        return response


class CompanionTests(unittest.TestCase):
    def descriptor(self, root, **overrides):
        payload = {
            "schemaVersion": 1,
            "host": "127.0.0.1",
            "port": 49152,
            "token": "x" * 43,
            "appVersion": "0.2.0",
            "pid": 1234,
        }
        payload.update(overrides)
        path = Path(root) / "bridge.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        path.chmod(0o600)
        return path

    def test_descriptor_requires_owner_only_regular_loopback_file(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.descriptor(root)
            with mock.patch.dict(
                os.environ, {"APPLE_HOME_COMPANION_DESCRIPTOR": str(path)}
            ):
                self.assertEqual(companion._descriptor(), ("127.0.0.1", 49152, "x" * 43))
            path.chmod(0o644)
            with mock.patch.dict(
                os.environ, {"APPLE_HOME_COMPANION_DESCRIPTOR": str(path)}
            ):
                with self.assertRaisesRegex(companion.CompanionError, "mode 0600"):
                    companion._descriptor()
            path.chmod(0o400)
            with mock.patch.dict(
                os.environ, {"APPLE_HOME_COMPANION_DESCRIPTOR": str(path)}
            ):
                with self.assertRaisesRegex(companion.CompanionError, "mode 0600"):
                    companion._descriptor()
            path.chmod(0o600)
            path = self.descriptor(root, host="192.168.1.10")
            with mock.patch.dict(
                os.environ, {"APPLE_HOME_COMPANION_DESCRIPTOR": str(path)}
            ):
                with self.assertRaisesRegex(companion.CompanionError, "loopback"):
                    companion._descriptor()

    def test_descriptor_rejects_symlink_and_missing_file(self):
        with tempfile.TemporaryDirectory() as root:
            target = self.descriptor(root)
            link = Path(root) / "link.json"
            link.symlink_to(target)
            with mock.patch.dict(
                os.environ, {"APPLE_HOME_COMPANION_DESCRIPTOR": str(link)}
            ):
                with self.assertRaises(companion.CompanionError):
                    companion._descriptor()
            with mock.patch.dict(
                os.environ,
                {"APPLE_HOME_COMPANION_DESCRIPTOR": str(Path(root) / "missing")},
            ):
                with self.assertRaisesRegex(companion.CompanionError, "not running"):
                    companion._descriptor()

    def test_descriptor_rejects_invalid_schema_port_and_token(self):
        with tempfile.TemporaryDirectory() as root:
            for overrides, message in (
                ({"schemaVersion": 2}, "unsupported schema"),
                ({"port": 0}, "invalid port"),
                ({"port": True}, "invalid port"),
                ({"token": "short"}, "invalid token"),
            ):
                path = self.descriptor(root, **overrides)
                with self.subTest(overrides=overrides):
                    with mock.patch.dict(
                        os.environ, {"APPLE_HOME_COMPANION_DESCRIPTOR": str(path)}
                    ):
                        with self.assertRaisesRegex(companion.CompanionError, message):
                            companion._descriptor()

    def test_call_sends_authenticated_request_and_returns_result(self):
        connection = FakeConnection(b'{"ok":true,"result":{"homes":[]}}\n')
        with mock.patch.object(
            companion, "_descriptor", return_value=("127.0.0.1", 49152, "secret" * 8)
        ):
            with mock.patch.object(
                companion.socket, "create_connection", return_value=connection
            ) as connect:
                result = companion.call("inventory", timeout=2)
        self.assertEqual(result, {"homes": []})
        connect.assert_called_once_with(("127.0.0.1", 49152), timeout=2)
        request = json.loads(connection.sent.decode("utf-8"))
        self.assertEqual(request["schemaVersion"], 1)
        self.assertEqual(request["operation"], "inventory")
        self.assertEqual(request["token"], "secret" * 8)
        self.assertEqual(connection.timeout, 2)

    def test_call_maps_companion_and_transport_failures(self):
        with mock.patch.object(
            companion, "_descriptor", return_value=("::1", 49152, "secret" * 8)
        ):
            connection = FakeConnection(
                b'{"ok":false,"error":{"code":"denied","message":"Approval required"}}\n'
            )
            with mock.patch.object(
                companion.socket, "create_connection", return_value=connection
            ):
                with self.assertRaisesRegex(companion.CompanionError, "Approval required"):
                    companion.call("run_scene")
            with mock.patch.object(
                companion.socket, "create_connection", side_effect=ConnectionRefusedError()
            ):
                with self.assertRaisesRegex(companion.CompanionError, "could not reach"):
                    companion.call("status")
            connection = FakeConnection(b'{"ok":true,"result":{}}')
            with mock.patch.object(
                companion.socket, "create_connection", return_value=connection
            ):
                with self.assertRaisesRegex(companion.CompanionError, "newline"):
                    companion.call("status")
            connection = FakeConnection(b'{"ok":true,"result":[]}\n')
            with mock.patch.object(
                companion.socket, "create_connection", return_value=connection
            ):
                with self.assertRaisesRegex(companion.CompanionError, "invalid result"):
                    companion.call("status")
            connection = FakeConnection(
                b'{"ok":false,"error":{"message":"missing code"}}\n'
            )
            with mock.patch.object(
                companion.socket, "create_connection", return_value=connection
            ):
                with self.assertRaisesRegex(companion.CompanionError, "invalid error"):
                    companion.call("status")
        with self.assertRaisesRegex(companion.CompanionError, "unsupported"):
            companion.call("delete_home")

    def test_call_rejects_invalid_json_oversized_frames_and_timeouts(self):
        with mock.patch.object(
            companion, "_descriptor", return_value=("127.0.0.1", 49152, "secret" * 8)
        ):
            for response, message in (
                (b"not-json\n", "invalid JSON"),
                (b"x" * (companion.MAX_MESSAGE_BYTES + 1), "exceeded 1 MiB"),
                (b'{"result":{}}\n', "response envelope"),
            ):
                with self.subTest(message=message):
                    connection = FakeConnection(response)
                    with mock.patch.object(
                        companion.socket, "create_connection", return_value=connection
                    ):
                        with self.assertRaisesRegex(companion.CompanionError, message):
                            companion.call("status")
        for timeout in (0, -1, 301, float("nan"), True, "15"):
            with self.subTest(timeout=timeout):
                with self.assertRaises(companion.CompanionError):
                    companion.call("status", timeout=timeout)


if __name__ == "__main__":
    unittest.main()
