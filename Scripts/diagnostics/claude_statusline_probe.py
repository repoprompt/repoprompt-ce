#!/usr/bin/env python3
"""Explicit, credential-free Claude status-line compatibility probe (not a usage cache)."""
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import sys

MAX_INPUT = 65536
MAX_LOG = 262144
SENTINEL = "RPCE_STATUSLINE_PROBE"


def private_file(path, flags):
    fd = os.open(str(path), flags | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        os.close(fd)
        raise ValueError("not a private regular file")
    return fd


def check_root(root):
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("not a private directory")


def sanitized(payload):
    limits = payload.get("rate_limits")
    windows = {}
    if isinstance(limits, dict):
        for name in ("five_hour", "seven_day"):
            window = limits.get(name)
            if not isinstance(window, dict):
                continue
            values = {}
            for key in ("used_percentage", "resets_at"):
                value = window.get(key)
                if type(value) not in (int, float) or not math.isfinite(value):
                    continue
                if key == "used_percentage" and not 0 <= value <= 100:
                    continue
                if key == "resets_at" and not 0 < value < 253402300800:
                    continue
                values[key] = value
            if values:
                windows[name] = values
    version = payload.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?", version) or len(version) > 128:
        version = None
    canonical = json.dumps(windows, sort_keys=True, separators=(",", ":"))
    return {"cliVersion": version, "windows": windows,
            "windowsHash": hashlib.sha256(canonical.encode()).hexdigest()}


def prepare(root):
    root = root.absolute()
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    check_root(root)
    collector = root / "collector.py"
    fd = private_file(collector, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
    with os.fdopen(fd, "wb") as output:
        output.write(Path(__file__).read_bytes())
    settings = root / "settings.json"
    command = shlex.join([sys.executable, "-I", str(collector), "capture", str(root)])
    fd = private_file(settings, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
    with os.fdopen(fd, "w") as output:
        json.dump({"statusLine": {"type": "command", "command": command}}, output)
    print(settings)


def capture(root):
    def timed_out(_signum, _frame):
        raise TimeoutError("probe timeout")
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(2)
    try:
        check_root(root)
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return
        record = sanitized(payload)
        record["receivedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        record["payloadBytes"] = len(raw)
        data = (json.dumps(record, sort_keys=True, allow_nan=False) + "\n").encode()
        fd = private_file(root / "invocations.ndjson", os.O_WRONLY | os.O_APPEND | os.O_CREAT)
        with os.fdopen(fd, "ab", buffering=0) as output:
            fcntl.flock(output, fcntl.LOCK_EX)
            if os.fstat(output.fileno()).st_size + len(data) > MAX_LOG:
                return
            output.write(data)
        # Deliberate fixed diagnostic token: detect contamination of stream-json.
        print(SENTINEL)
    except (OSError, ValueError, TimeoutError, OverflowError, RecursionError):
        pass
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("prepare", "capture"):
        sys.exit("usage: claude_statusline_probe.py prepare|capture PRIVATE_DIRECTORY")
    if sys.argv[1] == "prepare":
        prepare(Path(sys.argv[2]))
    else:
        capture(Path(sys.argv[2]))
