"""Client for the local Apple Home Mac Catalyst companion."""

import json
import math
import os
import socket
import stat
from pathlib import Path


SCHEMA_VERSION = 1
MAX_MESSAGE_BYTES = 1024 * 1024
OPERATIONS = {
    "status",
    "inventory",
    "read_characteristic",
    "write_characteristic",
    "list_scenes",
    "run_scene",
}
DEFAULT_DESCRIPTOR = Path.home() / (
    "Library/Containers/com.henryvanness.apple-home-bridge/Data/Library/"
    "Application Support/Apple Home Bridge/bridge.json"
)


class CompanionError(Exception):
    pass


def descriptor_path():
    configured = os.environ.get("APPLE_HOME_COMPANION_DESCRIPTOR")
    if configured is None:
        return DEFAULT_DESCRIPTOR
    if not configured or "\x00" in configured:
        raise CompanionError("APPLE_HOME_COMPANION_DESCRIPTOR must be a safe path")
    return Path(configured).expanduser()


def _descriptor():
    path = descriptor_path()
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor_fd = os.open(path, flags)
    except FileNotFoundError:
        raise CompanionError(
            "Apple Home Bridge is not running; open the companion app on this Mac"
        )
    except OSError as error:
        raise CompanionError("could not inspect Apple Home Bridge descriptor: %s" % error)
    try:
        details = os.fstat(descriptor_fd)
        if not stat.S_ISREG(details.st_mode):
            raise CompanionError("Apple Home Bridge descriptor must be a regular file")
        if details.st_uid != os.getuid() or stat.S_IMODE(details.st_mode) != 0o600:
            raise CompanionError(
                "Apple Home Bridge descriptor must be owned by you and mode 0600"
            )
        if details.st_size > 64 * 1024:
            raise CompanionError("Apple Home Bridge descriptor is too large")
        with os.fdopen(descriptor_fd, "r", encoding="utf-8", closefd=True) as stream:
            descriptor_fd = None
            payload = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CompanionError("Apple Home Bridge descriptor is invalid: %s" % error)
    finally:
        if descriptor_fd is not None:
            os.close(descriptor_fd)
    if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
        raise CompanionError("Apple Home Bridge descriptor has an unsupported schema")
    host = payload.get("host")
    port = payload.get("port")
    token = payload.get("token")
    if host not in {"127.0.0.1", "::1"}:
        raise CompanionError("Apple Home Bridge must bind to loopback only")
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        raise CompanionError("Apple Home Bridge descriptor has an invalid port")
    if not isinstance(token, str) or not 32 <= len(token) <= 512:
        raise CompanionError("Apple Home Bridge descriptor has an invalid token")
    return host, port, token


def _arguments(arguments):
    if arguments is None:
        return {}
    if not isinstance(arguments, dict):
        raise CompanionError("companion arguments must be an object")
    return arguments


def _read_line(connection):
    chunks = []
    size = 0
    while True:
        chunk = connection.recv(min(65536, MAX_MESSAGE_BYTES + 1 - size))
        if not chunk:
            break
        newline = chunk.find(b"\n")
        if newline >= 0:
            chunks.append(chunk[:newline])
            break
        chunks.append(chunk)
        size += len(chunk)
        if size > MAX_MESSAGE_BYTES:
            raise CompanionError("Apple Home Bridge response exceeded 1 MiB")
    raw = b"".join(chunks)
    if len(raw) > MAX_MESSAGE_BYTES:
        raise CompanionError("Apple Home Bridge response exceeded 1 MiB")
    if not raw:
        raise CompanionError("Apple Home Bridge returned no response")
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise CompanionError("Apple Home Bridge returned invalid JSON")


def call(operation, arguments=None, *, timeout=15):
    if operation not in OPERATIONS:
        raise CompanionError("unsupported Apple Home Bridge operation")
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
        raise CompanionError("companion timeout must be a number")
    if not math.isfinite(timeout) or not 0 < timeout <= 300:
        raise CompanionError("companion timeout must be greater than 0 and at most 300 seconds")
    host, port, token = _descriptor()
    request = json.dumps(
        {
            "schemaVersion": SCHEMA_VERSION,
            "token": token,
            "operation": operation,
            "arguments": _arguments(arguments),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"
    if len(request) > MAX_MESSAGE_BYTES:
        raise CompanionError("Apple Home Bridge request exceeded 1 MiB")
    try:
        with socket.create_connection((host, port), timeout=timeout) as connection:
            connection.settimeout(timeout)
            connection.sendall(request)
            response = _read_line(connection)
    except (OSError, TimeoutError) as error:
        raise CompanionError("could not reach Apple Home Bridge: %s" % error)
    if not isinstance(response, dict) or not isinstance(response.get("ok"), bool):
        raise CompanionError("Apple Home Bridge returned an invalid response envelope")
    if response["ok"]:
        if "result" not in response:
            raise CompanionError("Apple Home Bridge response is missing its result")
        return response["result"]
    error = response.get("error")
    if not isinstance(error, dict) or not isinstance(error.get("message"), str):
        raise CompanionError("Apple Home Bridge returned an invalid error")
    raise CompanionError(error["message"][:500])
