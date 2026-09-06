"""Synthetic control plane around the checksum-pinned production Python bridge.

Only this process's Swift parent may pair. Pairing travels on an anonymous pipe,
never a file/log. The imported production module owns the actual Unix protocol.
"""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import socket
import sys
import threading
import time
import types

PINNED_SHA256 = "15dc53bd2ceee9156c41029d27b23948e67e104cceabbba30123eec7bff57dc8"
TOKENS = ("SYNTHETIC-CROSS-A-ONE", "SYNTHETIC-CROSS-A-TWO", "SYNTHETIC-CROSS-B-ONE")
wire = sys.stdout
captured = io.StringIO()
denied = {"network": 0, "subprocess": 0, "credential_file": 0}


def audit(event, args):
    if event == "socket.__new__" and args[1] != socket.AF_UNIX:
        denied["network"] += 1
        raise RuntimeError("fixture_denied")
    if event in {"subprocess.Popen", "os.system", "os.posix_spawn", "os.fork"}:
        denied["subprocess"] += 1
        raise RuntimeError("fixture_denied")
    if event == "open" and isinstance(args[0], (str, bytes)):
        path = os.fsdecode(args[0])
        parts = Path(path).parts
        if (any(part in {".codex", ".aws", ".ssh", ".netrc", "Keychains"} for part in parts)
                or Path(path).name in {"auth.json", "credentials.json"}):
            denied["credential_file"] += 1
            raise RuntimeError("fixture_denied")


def emit(value):
    # This descriptor is the private parent pipe, separate from captured logs.
    wire.write(json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n")
    wire.flush()


def run():
    source, expected_parent, directory, fault = sys.argv[1:]
    if int(expected_parent) != os.getppid() or fault not in {"none", "refresh_identity", "hold_register"}:
        raise RuntimeError("fixture_invalid")
    sys.addaudithook(audit)
    source_bytes = Path(source).read_bytes()
    if hashlib.sha256(source_bytes).hexdigest() != PINNED_SHA256:
        raise RuntimeError("fixture_source_mismatch")
    module_name = "synthetic_pinned_repoprompt_bridge"
    bridge = types.ModuleType(module_name)
    bridge.__file__ = source
    sys.modules[module_name] = bridge
    # Compile the verified bytes directly; never trust a neighboring .pyc cache.
    exec(compile(source_bytes, source, "exec"), bridge.__dict__)
    directory = Path(directory)
    if directory.resolve() != directory or list(directory.iterdir()):
        raise RuntimeError("fixture_invalid")
    expires = int(time.time()) + 3600
    lock = threading.Lock()
    grants = {
        "a@example.invalid": bridge.Grant("a@example.invalid", "synthetic-cross-account-a", TOKENS[0], expires, "plus"),
        "b@example.invalid": bridge.Grant("b@example.invalid", "synthetic-cross-account-b", TOKENS[2], expires, "plus"),
    }
    calls = []

    def provider(account, **kwargs):
        with lock:
            previous = kwargs.get("previous")
            calls.append({"account": account, "refresh": previous is not None,
                          "previous_account": previous["account_id"] if previous else None})
            if previous is not None and fault == "refresh_identity":
                return bridge.Grant(account, grants["b@example.invalid"].account_id, TOKENS[2], expires, "plus")
            return grants[account]

    runtime = bridge.Bridge(provider)
    registration_bound = threading.Event()
    release_registration = threading.Event()
    if fault == "hold_register":
        original_handle = runtime.handle

        def gated_handle(request, peer, **kwargs):
            response = original_handle(request, peer, **kwargs)
            if request.get("op") == "register" and response.get("result") == {"registered": True}:
                registration_bound.set()
                release_registration.wait(timeout=2.5)
            return response

        # Preserve Server's default handler/response_current identity check.
        runtime.handle = gated_handle
    with bridge.Server(runtime, directory / "session.sock") as server:
        envelope = runtime.pair(bridge.process_peer(int(expected_parent)), str(server.path), server.peer)
        emit({"envelope": envelope, "source_pinned": True})
        for raw in sys.stdin.buffer:
            if len(raw) > 128:
                raise RuntimeError("fixture_invalid")
            command = json.loads(raw)
            if set(command) != {"op"}:
                raise RuntimeError("fixture_invalid")
            op = command["op"]
            if op in {"queue_a", "queue_b"}:
                emit(runtime.queue_account("a@example.invalid" if op == "queue_a" else "b@example.invalid"))
            elif op == "renew_a":
                with lock:
                    grants["a@example.invalid"] = bridge.Grant("a@example.invalid", "synthetic-cross-account-a", TOKENS[1], expires + 60, "plus")
                emit({"renewed": True})
            elif op == "revoke":
                runtime.revoke_all()
                emit({"revoked": True})
            elif op == "status":
                with runtime.lock:
                    bindings = [{"consent": c.binding[0], "session": c.binding[1], "controller": c.binding[2],
                                 "thread": c.thread, "applied_revision": c.applied["selection_revision"] if c.applied else None}
                                for c in runtime.consents.values() if c.binding]
                with lock:
                    observed_calls = list(calls)
                receipt = {"status": runtime.public_status(), "bindings": bindings, "provider_calls": observed_calls,
                           "denied_operations": dict(denied), "logs_empty": captured.getvalue() == ""}
                serialized = json.dumps(receipt)
                receipt["redacted"] = all(secret not in serialized + captured.getvalue()
                                          for secret in (*TOKENS, envelope["capability"], str(server.path)))
                emit(receipt)
            elif op == "wait_registration":
                emit({"bound": registration_bound.wait(timeout=2)})
            elif op == "release_registration":
                release_registration.set()
                emit({"released": True})
            elif op == "stop":
                emit({"stopped": True})
                return
            else:
                raise RuntimeError("fixture_invalid")


if __name__ == "__main__":
    try:
        with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
            run()
    except Exception:
        emit({"error": "fixture_failed"})
        raise SystemExit(1) from None
