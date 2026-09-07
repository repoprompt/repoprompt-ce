"""Pinned actual protocol-2 bridge/engine with synthetic local Responses only.

The XCTest parent owns the separately sandboxed genuine RP Codex child. This
fixture's grants/quota/rule file are synthetic. No native RPC is rewritten.
"""
import contextlib
import ctypes
import hashlib
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import stat
import sys
import threading
import time
import types

# Exact Switchboard c6c077f0 package subset, not a mutable working checkout.
PINNED = {
    "__init__.py": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "config.py": "35d93a127416545899dda8c2759e09513420fceadfac9f56520da20eee909837",
    "rotation_rules.py": "f2c2b221765ce39b2711caae5844945d8e24a8e777bc9511bf337152e146d165",
    "repoprompt_bridge.py": "3bf4bc729a8efdd0a6d64c40cff78ce5645f8141bf8980ed26399653519280b8",
    "global_rotation_wire.py": "c8bbf1d2091201576385fe9d5de48bb516775db051730008f95e8d6660fca659",
    "global_rotation.py": "b40844d8ea9a2a3dce66e8db49b9601e57b83c770aa5f8f3388291d5cc61b084",
}
HELPER_SHA = "a2febf015f149cc8b6999c95b30f96691b229d2d1f20d6126d9ab96b3eb9d4bb"
stage = "helper_integrity"
helper_path = Path(__file__).with_name("switchboard_controller_runtime_fixture.py")
helper_bytes = helper_path.read_bytes()
if hashlib.sha256(helper_bytes).hexdigest() != HELPER_SHA:
    raise SystemExit(1)
helpers = types.ModuleType("private_controller_helpers")
helpers.__file__ = str(helper_path)
exec(compile(helper_bytes, str(helper_path), "exec"), helpers.__dict__)


class BSDInfo(ctypes.Structure):
    _fields_ = [(k, ctypes.c_uint32) for k in ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "rfu")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(k, ctypes.c_uint32) for k in ("nfiles", "pgid", "pjobc", "tdev", "tpgid", "nice")]
    _fields_ += [("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


def run():
    global stage
    stage = "interpreter"
    # The pinned Switchboard source requires Python 3.11+. In particular, its
    # runtime annotations intentionally use PEP 604 without postponed
    # evaluation. Fail with an allowlisted stage instead of a traceback.
    if sys.version_info < (3, 11):
        raise RuntimeError("fixture_interpreter_unsupported")
    stage = "arguments"
    source, parent, raw_directory, fault, resources = sys.argv[1:]
    parent = int(parent)
    directory = Path(raw_directory)
    source = Path(source)
    resources = Path(resources)
    if (parent != os.getppid() or fault != "none" or directory.resolve() != directory
            or directory.is_symlink() or list(directory.iterdir()) or directory.stat().st_uid != os.getuid()
            or stat.S_IMODE(directory.stat().st_mode) != 0o700 or source.resolve() != source
            or resources.resolve() != resources):
        raise RuntimeError("fixture_invalid")
    package = source / "switchboard"
    stage = "source_integrity"
    verified = {}
    for name, digest in PINNED.items():
        path = package / name
        verified[name] = path.read_bytes()
        if path.is_symlink() or hashlib.sha256(verified[name]).hexdigest() != digest:
            raise RuntimeError("fixture_source_mismatch")

    def audit(event, args):
        helpers.audit(event, args)
        if event == "open" and isinstance(args[0], (str, bytes)):
            path = Path(os.fsdecode(args[0]))
            if path.is_relative_to(package) and path.suffix == ".py" and path.name not in PINNED:
                raise RuntimeError("fixture_unpinned_import")
            flags = args[2] if len(args) > 2 and isinstance(args[2], int) else 0
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT) and not path.is_relative_to(directory):
                raise RuntimeError("fixture_outside_write")
    sys.addaudithook(audit)
    # Execute exactly the bytes just verified, not a mutable import/pyc cache.
    stage = "source_load"
    package_module = types.ModuleType("switchboard")
    package_module.__path__ = [str(package)]
    package_module.__package__ = "switchboard"
    sys.modules["switchboard"] = package_module
    for name in ("config", "rotation_rules", "repoprompt_bridge", "global_rotation_wire", "global_rotation"):
        stage = "source_load_" + name
        module_name = "switchboard." + name
        module = types.ModuleType(module_name)
        module.__file__ = str(package / (name + ".py"))
        module.__package__ = "switchboard"
        sys.modules[module_name] = module
        setattr(package_module, name, module)
        exec(compile(verified[name + ".py"], module.__file__, "exec"), module.__dict__)
    from switchboard import repoprompt_bridge as bridge
    from switchboard import global_rotation, rotation_rules

    lock = threading.RLock()
    requests, capabilities = [], []
    tokens = {label: helpers.fake_token(label, 1) for label in ("a", "b")}
    state = dict(offset=0, hold_next=False, held=False, protocol_errors=0, no_capacity=False)
    release = threading.Event()
    expires = int(time.time()) + 3600
    rule = dict(id="synthetic-rule", name="Synthetic exact root", provider="codex",
        accounts=["a@example.invalid", "b@example.invalid"], trigger_used_percent=80,
        destination_remaining_percent=50, cooldown_minutes=1, freshness_seconds=60,
        new_sessions=False, session_ids=[])
    config = dict(version=2, revision=1, paused=False, rulesets=[rule],
                  enrollment_epochs={"synthetic-rule": "b" * 32})
    rotation_rules.validate(config)
    # This is a fresh private fixture file, never an installed/global rule path.
    assert rotation_rules.PATH == directory / "rotation-rules.json"
    rotation_rules.PATH.write_text(json.dumps(config))
    rotation_rules.PATH.chmod(0o600)
    stage = "private_state"

    def now():
        return time.time() + state["offset"]

    def provider(account, **kwargs):
        with lock:
            if account not in rule["accounts"] or state["no_capacity"]:
                raise bridge.BridgeError("grant_unavailable")
            return bridge.Grant(account, "fixture-" + account, tokens[account[0]], expires, "pro")

    @contextlib.contextmanager
    def grant_admission(expected, *, deadline=None):
        with lock:
            if deadline is not None and time.monotonic() >= deadline:
                raise bridge.BridgeError("unavailable")
            if any(provider(account) != grant for account, grant in expected.items()):
                raise bridge.BridgeError("grant_unavailable")
            yield

    def observer(account, grant):
        return dict(provider="codex", account=account, error=None, credential_ready=True,
            usage=0.9 if account.startswith("a@") else 0.1, observed_at=now(), credential_expires_at=grant.expires_at)

    expected_native = resources / "BundledRuntimes/Codex/aarch64-apple-darwin/bin/codex"
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)

    def native_checker(value, owner):
        try:
            actual = bridge.process_peer(value["pid"])
            info = BSDInfo()
            return (actual.uid == os.getuid() == owner.uid and owner.pid == parent
                and actual.seconds == value["start"]["seconds"] and actual.microseconds == value["start"]["microseconds"]
                and actual.executable == str(expected_native)
                and libproc.proc_pidinfo(actual.pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info)
                and info.ppid == parent)
        except Exception:
            return False

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *args):
            pass
        def setup(self):
            super().setup()
            self.connection.settimeout(10)
        def handle(self):
            try: super().handle()
            except (BrokenPipeError, ConnectionResetError, TimeoutError): pass
        def answer(self, code, value):
            data = json.dumps(value).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def do_CONNECT(self):
            self.answer(403, {})
        def do_GET(self):
            if self.headers.get("Upgrade"):
                with lock: state["protocol_errors"] += 1
                return self.answer(403, {})
            self.answer(200, {"models": [], "data": []})
        def do_POST(self):
            try:
                if self.path != "/backend-api/codex/responses": raise ValueError()
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4 * 1024 * 1024: raise ValueError()
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict): raise ValueError()
                if any(len(self.headers.get_all(key, [])) != 1 for key in ("Content-Type", "Authorization", "ChatGPT-Account-Id")): raise ValueError()
                if self.headers.get_content_type() != "application/json": raise ValueError()
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "): raise ValueError()
                label = next(k for k, v in tokens.items() if v == auth[7:])
                if self.headers.get("ChatGPT-Account-Id") != "fixture-" + label + "@example.invalid": raise ValueError()
            except (ValueError, TypeError, StopIteration):
                with lock: state["protocol_errors"] += 1
                return self.answer(403, {})
            with lock:
                requests.append(dict(account=label, contains_marker=helpers.MARKER in json.dumps(body.get("input", []))))
                number = len(requests)
                held = state["hold_next"]
                if held: state.update(hold_next=False, held=True); release.clear()
            item = dict(id="msg_" + str(number), type="message", role="assistant", status="completed",
                content=[dict(type="output_text", text="SYNTHETIC " + label, annotations=[])])
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            def event(value):
                self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode()); self.wfile.flush()
            event(dict(type="response.created", response=dict(id="resp_" + str(number), status="in_progress", output=[])))
            if held:
                success = release.wait(timeout=20)
                with lock:
                    state["held"] = False
                    if not success: state["protocol_errors"] += 1
                if not success: self.close_connection = True; return
            event(dict(type="response.output_item.added", output_index=0, item=item))
            event(dict(type="response.output_item.done", output_index=0, item=item))
            event(dict(type="response.completed", response=dict(id="resp_" + str(number), status="completed", output=[item],
                usage=dict(input_tokens=10, output_tokens=4, total_tokens=14))))
            self.close_connection = True

    runtime = bridge.Bridge(provider)
    engine = global_rotation.AutomaticRotation(runtime, global_rotation.MetadataStore(directory / "automatic.json"),
        observer=observer, now=now, native_checker=native_checker, grant_admission=grant_admission)
    stage = "loopback_server"
    http = helpers.LocalServer(("127.0.0.1", 0), Handler)
    http_thread = threading.Thread(target=http.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    http_thread.start()
    try:
        stage = "bridge_server"
        with bridge.Server(runtime, directory / "session.sock") as server:
            stage = "pairing"
            envelope = runtime.pair(bridge.process_peer(parent), str(server.path), server.peer)
            capabilities.append(envelope["capability"])
            stage = "ready"
            helpers.emit(dict(envelope=envelope, source_pinned=True, responses_url="http://127.0.0.1:" + str(http.server_port) + "/backend-api/codex", model="gpt-5.6-sol", marker=helpers.MARKER))
            stage = "commands"
            while True:
                raw = sys.stdin.buffer.readline(129)
                if not raw: return
                if len(raw) > 128 or not raw.endswith(b"\n"): raise RuntimeError("fixture_invalid")
                command = json.loads(raw)
                if not isinstance(command, dict) or set(command) != {"op"}: raise RuntimeError("fixture_invalid")
                op = command["op"]
                if op == "queue_a": helpers.emit(runtime.queue_account("a@example.invalid"))
                elif op == "offer":
                    consents = [c for c in runtime.consents.values() if c.binding and c.thread and not c.revoked]
                    if len(consents) != 1: raise RuntimeError("fixture_scope")
                    with lock: state["offset"] = 61
                    engine.offer(consents[0].binding[0], "synthetic-rule")
                    helpers.emit(dict(offered=True))
                elif op == "plan": engine.plan(); helpers.emit(dict(planned=True))
                elif op == "pause": rotation_rules.pause_all(rotation_rules.load()["revision"]); helpers.emit(dict(pausing=True))
                elif op == "hold_next_response":
                    with lock: state["hold_next"] = True
                    helpers.emit(dict(armed=True))
                elif op == "release_response": release.set(); helpers.emit(dict(released=True))
                elif op == "no_capacity":
                    with lock: state["no_capacity"] = True
                    helpers.emit(dict(armed=True))
                elif op == "status":
                    with lock: result = dict(requests=list(requests), held=state["held"], protocol_errors=state["protocol_errors"])
                    result.update(automatic=engine.public_status(), status=runtime.public_status(), logs_empty=helpers.captured.getvalue() == "")
                    public = json.dumps(result) + helpers.captured.getvalue()
                    fingerprints = [hashlib.sha256(token.encode()).hexdigest() for token in tokens.values()]
                    result["redacted"] = all(value not in public for value in (*tokens.values(), *fingerprints, *capabilities, str(server.path)))
                    helpers.emit(result)
                elif op == "stop": helpers.emit(dict(stopped=True)); return
                else: raise RuntimeError("fixture_invalid")
    finally:
        release.set()
        engine.close()
        engine.wait_preparations(timeout=2)
        http.shutdown(); http.server_close(); http_thread.join(timeout=2)


if __name__ == "__main__":
    try:
        with contextlib.redirect_stdout(helpers.captured), contextlib.redirect_stderr(helpers.captured): run()
    except Exception:
        helpers.emit(dict(error="fixture_failed", stage=stage))
        raise SystemExit(1) from None
