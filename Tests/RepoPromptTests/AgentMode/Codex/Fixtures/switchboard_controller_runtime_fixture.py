"""Real private Switchboard bridge plus a synthetic, loopback-only Responses peer.

Only the launching XCTest process may pair. Capabilities travel on its private
pipe. This fixture never loads a real credential store or contacts a provider.
The separate Swift harness launches the real Codex binary under an OS sandbox.
"""
import base64
import contextlib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import socket
import socketserver
import stat
import sys
import threading
import time
import types

PINNED_SHA256 = "4c3c266aa359d8be224943dbdc935b8b6f58e754e6c77f19f6fa574f89b31774"
MARKER = "RP_CONTROLLER_RETAINED_CONTEXT"
wire = sys.stdout
captured = io.StringIO()
denied = {"network": 0, "subprocess": 0, "credential_file": 0}


def audit(event, args):
    if event == "socket.__new__" and args[1] not in {socket.AF_UNIX, socket.AF_INET}:
        denied["network"] += 1
        raise RuntimeError("fixture_denied")
    if event == "socket.bind" and isinstance(args[1], tuple) and args[1][0] != "127.0.0.1":
        denied["network"] += 1
        raise RuntimeError("fixture_denied")
    if event == "socket.connect" and isinstance(args[1], tuple):
        denied["network"] += 1
        raise RuntimeError("fixture_denied")
    if event in {"socket.getaddrinfo", "socket.gethostbyaddr", "socket.gethostbyname"}:
        denied["network"] += 1
        raise RuntimeError("fixture_denied")
    if event in {"subprocess.Popen", "os.system", "os.posix_spawn", "os.fork"}:
        denied["subprocess"] += 1
        raise RuntimeError("fixture_denied")
    if event == "open" and isinstance(args[0], (str, bytes)):
        path = Path(os.fsdecode(args[0]))
        if (set(path.parts).intersection({".codex", ".aws", ".ssh", ".netrc", "Keychains"})
                or path.name in {"auth.json", "credentials.json"}):
            denied["credential_file"] += 1
            raise RuntimeError("fixture_denied")


def emit(value):
    wire.write(json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n")
    wire.flush()


def fake_token(label, generation):
    email = label + "@example.invalid"
    claims = {"email": email, "iat": int(time.time()) - 1000 + generation,
              "exp": int(time.time()) + 86400 + generation,
              "session_id": "fixture-session-" + email, "generation": generation,
              "https://api.openai.com/auth": {"chatgpt_account_id": "fixture-" + email,
                                            "chatgpt_plan_type": "pro"}}
    def enc(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    return enc({"alg": "none"}) + "." + enc(claims) + ".SYNTHETIC"


class LocalServer(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer normally resolves its hostname. This fixture needs no DNS.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def run():
    source, parent, raw_directory, fault = sys.argv[1:]
    if int(parent) != os.getppid() or fault != "none":
        raise RuntimeError("fixture_invalid")
    directory = Path(raw_directory)
    if (directory.resolve() != directory or directory.is_symlink() or list(directory.iterdir())
            or directory.stat().st_uid != os.getuid()
            or stat.S_IMODE(directory.stat().st_mode) != 0o700):
        raise RuntimeError("fixture_invalid")
    sys.addaudithook(audit)
    source_bytes = Path(source).read_bytes()
    if hashlib.sha256(source_bytes).hexdigest() != PINNED_SHA256:
        raise RuntimeError("fixture_source_mismatch")
    module_name = "controller_pinned_repoprompt_bridge"
    bridge = types.ModuleType(module_name)
    bridge.__file__ = source
    sys.modules[module_name] = bridge
    exec(compile(source_bytes, source, "exec"), bridge.__dict__)

    lock = threading.Lock()
    tokens = {(label, generation): fake_token(label, generation)
              for label, generation in (("a", 1), ("a", 2), ("b", 1))}
    generations = {"a": 1, "b": 1}
    requests, calls, capabilities = [], [], []
    state = {"hold_next": False, "hold_next_request": False, "held": False, "held_stage": None, "reject_a": False, "reject_all_a": False,
             "no_capacity": False, "protocol_errors": 0}
    release = threading.Event()
    expires = int(time.time()) + 3600

    def provider(account, **kwargs):
        if account not in {"a@example.invalid", "b@example.invalid"}:
            raise bridge.BridgeError("grant_unavailable")
        label = account[0]
        with lock:
            previous = kwargs.get("previous")
            calls.append({"account": label, "refresh": previous is not None,
                          "previous_account": previous["account_id"] if previous else None})
            if state["no_capacity"]:
                raise bridge.BridgeError("grant_unavailable")
            generation = generations[label]
            return bridge.Grant(account, "fixture-" + account,
                                tokens[(label, generation)], expires + generation, "pro")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass

        def setup(self):
            super().setup()
            self.connection.settimeout(10)

        def answer(self, code, data):
            raw = json.dumps(data).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_CONNECT(self):
            self.answer(403, {})

        def do_GET(self):
            if self.headers.get("Upgrade"):
                with lock:
                    state["protocol_errors"] += 1
                return self.answer(403, {})
            self.answer(200, {"models": [], "data": []})

        def do_POST(self):
            if self.path != "/backend-api/codex/responses":
                with lock:
                    state["protocol_errors"] += 1
                return self.answer(403, {})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4 * 1024 * 1024:
                    raise ValueError("fixture_body_limit")
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise ValueError("fixture_body_shape")
                if (len(self.headers.get_all("Content-Type", [])) != 1
                        or self.headers.get_content_type() != "application/json"
                        or len(self.headers.get_all("Authorization", [])) != 1
                        or len(self.headers.get_all("ChatGPT-Account-Id", [])) != 1):
                    raise ValueError("fixture_header_shape")
                authorization = self.headers.get("Authorization", "")
                if not authorization.startswith("Bearer "):
                    raise ValueError("fixture_auth_scheme")
                token = authorization[len("Bearer "):]
                identity = next((key for key, value in tokens.items() if value == token), None)
                if identity is None or self.headers.get("ChatGPT-Account-Id") != "fixture-" + identity[0] + "@example.invalid":
                    raise ValueError("fixture_identity_mismatch")
            except (ValueError, TypeError, StopIteration):
                with lock:
                    state["protocol_errors"] += 1
                return self.answer(403, {})
            label, generation = identity
            with lock:
                hold_request = state["hold_next_request"]
                if hold_request:
                    state["hold_next_request"] = False
                    state["held"] = True
                    state["held_stage"] = "request"
                    release.clear()
            if hold_request:
                released = release.wait(timeout=30)
                with lock:
                    state["held"] = False
                    state["held_stage"] = None
                    if not released:
                        state["protocol_errors"] += 1
                if not released:
                    return self.answer(503, {})
            with lock:
                reject = (state["reject_a"] or state["reject_all_a"]) and label == "a"
                if reject:
                    state["reject_a"] = False
                held = state["hold_next"] and not reject
                if held:
                    state["hold_next"] = False
                    state["held"] = True
                    state["held_stage"] = "response"
                    release.clear()
                requests.append({"account": label, "generation": generation,
                                 "status": 401 if reject else 200,
                                 "contains_marker": MARKER in json.dumps(body.get("input", []))})
                number = len(requests)
            if reject:
                return self.answer(401, {"error": {"message": "Synthetic expired authorization",
                                                  "type": "invalid_request_error", "code": "invalid_api_key"}})
            item = {"id": "msg_" + str(number), "type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": "SYNTHETIC " + label + " " + str(generation), "annotations": []}]}
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            def event(value):
                self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
                self.wfile.flush()
            event({"type": "response.created", "response": {"id": "resp_" + str(number), "status": "in_progress", "output": []}})
            if held:
                released = release.wait(timeout=30)
                with lock:
                    state["held"] = False
                    state["held_stage"] = None
                    if not released:
                        state["protocol_errors"] += 1
                if not released:
                    self.close_connection = True
                    return
            event({"type": "response.output_item.added", "output_index": 0, "item": item})
            event({"type": "response.output_item.done", "output_index": 0, "item": item})
            event({"type": "response.completed", "response": {"id": "resp_" + str(number), "status": "completed", "output": [item],
                   "usage": {"input_tokens": 10, "output_tokens": 4, "total_tokens": 14}}})
            self.close_connection = True

    runtime = bridge.Bridge(provider)
    http = LocalServer(("127.0.0.1", 0), Handler)
    http_thread = threading.Thread(target=http.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    http_thread.start()
    try:
        with bridge.Server(runtime, directory / "session.sock") as server:
            def pair():
                envelope = runtime.pair(bridge.process_peer(int(parent)), str(server.path), server.peer)
                capabilities.append(envelope["capability"])
                return envelope
            emit({"envelope": pair(), "source_pinned": True,
                  "responses_url": "http://127.0.0.1:" + str(http.server_port) + "/backend-api/codex",
                  "model": "gpt-5.6-sol", "marker": MARKER})
            while True:
                raw = sys.stdin.buffer.readline(129)
                if not raw:
                    return
                if len(raw) > 128 or not raw.endswith(b"\n"):
                    raise RuntimeError("fixture_invalid")
                command = json.loads(raw)
                if set(command) != {"op"}:
                    raise RuntimeError("fixture_invalid")
                op = command["op"]
                if op in {"queue_a", "queue_b"}:
                    emit(runtime.queue_account(op[-1] + "@example.invalid"))
                elif op == "renew_a":
                    with lock:
                        generations["a"] = 2
                    emit({"renewed": True})
                elif op == "hold_next_response":
                    with lock:
                        state["hold_next"] = True
                    emit({"armed": True})
                elif op == "hold_next_request":
                    with lock:
                        state["hold_next_request"] = True
                    emit({"armed": True})
                elif op == "release_response":
                    release.set()
                    emit({"released": True})
                elif op == "reject_next_a":
                    with lock:
                        state["reject_a"] = True
                    emit({"armed": True})
                elif op == "reject_all_a":
                    with lock:
                        state["reject_all_a"] = True
                    emit({"armed": True})
                elif op == "no_capacity":
                    with lock:
                        state["no_capacity"] = True
                    emit({"armed": True})
                elif op == "revoke":
                    runtime.revoke_all()
                    emit({"revoked": True})
                elif op == "pair_replacement":
                    emit({"envelope": pair()})
                elif op == "status":
                    with lock:
                        result = {"requests": list(requests), "provider_calls": list(calls),
                                  "held": state["held"], "held_stage": state["held_stage"], "protocol_errors": state["protocol_errors"]}
                    result.update(status=runtime.public_status(), logs_empty=captured.getvalue() == "",
                                  denied_operations=dict(denied))
                    public = json.dumps(result) + captured.getvalue()
                    result["redacted"] = all(secret not in public for secret in (*tokens.values(), *capabilities, str(server.path)))
                    emit(result)
                elif op == "stop":
                    emit({"stopped": True})
                    return
                else:
                    raise RuntimeError("fixture_invalid")
    finally:
        release.set()
        http.shutdown()
        http.server_close()
        http_thread.join(timeout=2)


if __name__ == "__main__":
    try:
        with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
            run()
    except Exception:
        emit({"error": "fixture_failed"})
        raise SystemExit(1) from None
