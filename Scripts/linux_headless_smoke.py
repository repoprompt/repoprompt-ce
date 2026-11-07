#!/usr/bin/env python3
"""Linux system test for `repoprompt-mcp --backend headless` over stdio.

Usage: python3 Scripts/linux_headless_smoke.py --binary <path-to-repoprompt-mcp>

Creates a throwaway repo and isolated headless profile, then exercises real MCP
initialization, repository reads, search, parsing, selected context, explicit
mutation consent, edits, restart persistence and clean EOF shutdown. Also checks
the terminal CLI modes and rejects outside-root paths and deleted-image decoys.
Exits non-zero at the first failure. Python stdlib only.
"""

import argparse
import hashlib
import json
import os
import pty
import queue
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time

TIMEOUT_SECONDS = 30
DELETED_IMAGE_FLAG = "--as-deleted-image"


class SmokeFailure(Exception):
    pass


def headless_env(base):
    for name in ("repo", "profile"):
        os.makedirs(os.path.join(base, name), exist_ok=True)
    environment = {key: os.environ[key] for key in ("PATH", "HOME", "LD_LIBRARY_PATH") if key in os.environ}
    environment.update({
        "XDG_DATA_HOME": os.path.join(base, "data"),
        "XDG_STATE_HOME": os.path.join(base, "state"),
        "XDG_CONFIG_HOME": os.path.join(base, "config"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "REPOPROMPT_MCP_HEADLESS_PROFILE": "linux-smoke",
        "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": os.path.join(base, "profile"),
        "REPOPROMPT_MCP_WORKING_DIRS": os.path.join(base, "repo"),
    })
    return environment


class HeadlessServer:
    active = []

    def __init__(self, binary, env, stderr_path):
        self.stderr_path = stderr_path
        with open(stderr_path, "wb") as log:
            self.proc = subprocess.Popen(
                [binary, "--backend", "headless"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=log,
                env=env,
                start_new_session=True,
            )
        self.active.append(self)
        self.lines = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self.next_id = 0

    def _pump(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while True:
            try:
                line = self.lines.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                raise SmokeFailure(f"no reply to {method} within {TIMEOUT_SECONDS}s") from None
            if line is None:
                raise SmokeFailure(f"server closed stdout during {method}")
            reply = json.loads(line)
            if reply.get("id") == self.next_id:
                return reply

    def initialize(self):
        reply = self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "linux-headless-smoke", "version": "1"},
        })
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return reply

    def call_tool(self, name, arguments):
        reply = self.request("tools/call", {"name": name, "arguments": arguments})
        result = reply.get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        return bool(result.get("isError")) or "error" in reply, text or json.dumps(reply.get("error"))

    def close(self):
        if not self.proc.stdin.closed:
            self.proc.stdin.close()
        try:
            return self.proc.wait(timeout=TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            self.abort()
            return "timeout"

    def abort(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait(timeout=5)
        self.proc.stdout.close()
        self.proc.stdin.close()


def require(step, condition, detail):
    if not condition:
        raise SmokeFailure(f"{step}: {detail}")
    print(f"PASS {step}", flush=True)


def driver_fingerprint():
    # Same material the server derives from /proc/<parent pid>/exe.
    path = os.path.normpath(os.readlink("/proc/self/exe"))
    info = os.lstat(path)
    return hashlib.sha256(f"{path}|{info.st_dev}|{info.st_ino}".encode()).hexdigest()


def policy_grant(binary, env, fingerprint, root):
    # The policy CLI requires TTYs on stdin and stderr and an interactive "yes".
    master, slave = pty.openpty()
    proc = None
    try:
        proc = subprocess.Popen(
            [binary, "policy", "grant", "--principal-fingerprint", fingerprint,
             "--operation", "file_actions.create", "--operation", "apply_edits.*",
             "--root", root, "--expires-in", "600"],
            stdin=slave, stderr=slave, stdout=subprocess.PIPE, env=env,
            start_new_session=True,
        )
        os.close(slave)
        slave = None
        prompt = bytearray()
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while b"Type 'yes'" not in prompt:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SmokeFailure("policy grant did not request confirmation before its deadline")
            ready, _, _ = select.select([master], [], [], remaining)
            if not ready:
                raise SmokeFailure("policy grant did not request confirmation before its deadline")
            try:
                chunk = os.read(master, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                raise SmokeFailure("policy grant closed its terminal before confirmation: "
                                   + prompt.decode(errors="replace")[-2000:])
            prompt.extend(chunk)
            if len(prompt) > 65536:
                raise SmokeFailure("policy grant exceeded the confirmation output limit")
        os.write(master, b"yes\n")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SmokeFailure("policy grant exceeded its deadline")
        out, _ = proc.communicate(timeout=remaining)
        return proc.returncode, out.decode(errors="replace").strip(), prompt.decode(errors="replace").strip()
    finally:
        try:
            if proc is not None:
                if proc.poll() is None:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                proc.wait(timeout=5)
        finally:
            if proc is not None and proc.stdout is not None:
                proc.stdout.close()
            if slave is not None:
                os.close(slave)
            os.close(master)


def run_smoke(binary, base):
    env = headless_env(base)
    repo = env["REPOPROMPT_MCP_WORKING_DIRS"]
    hello, created = os.path.join(repo, "hello.txt"), os.path.join(repo, "new.txt")
    with open(hello, "w") as handle:
        handle.write("hello linux\n")
    with open(os.path.join(repo, "example.py"), "w") as handle:
        handle.write("def linux_port_smoke():\n    return 'hello linux'\n")
    outside = os.path.join(base, "outside.txt")
    with open(outside, "w") as handle:
        handle.write("OUTSIDE_ROOT_MUST_NOT_LEAK\n")
    os.symlink(outside, os.path.join(repo, "escape.txt"))
    subprocess.run(["git", "init", "-q", repo], env=env, check=True, timeout=TIMEOUT_SECONDS)
    server = HeadlessServer(binary, env, os.path.join(base, "server.stderr"))

    info = server.initialize().get("result", {}).get("serverInfo", {})
    require("initialize", info.get("name") == "RepoPrompt CE", f"serverInfo={info}")

    tools = {tool["name"] for tool in server.request("tools/list", {}).get("result", {}).get("tools", [])}
    expected = {"read_file", "get_file_tree", "file_search", "file_actions", "apply_edits"}
    require("tools/list", expected <= tools, f"missing {sorted(expected - tools)} from {sorted(tools)}")

    is_error, text = server.call_tool("read_file", {"path": hello})
    require("read_file", not is_error and "hello linux" in text, text[:200])

    is_error, text = server.call_tool("get_file_tree", {"type": "files"})
    require("file tree", not is_error and "example.py" in text, text[:300])
    is_error, text = server.call_tool("file_search", {"pattern": "hello linux", "regex": False, "mode": "content"})
    require("content search", not is_error and "hello linux" in text, text[:300])
    is_error, text = server.call_tool("get_code_structure", {"paths": [os.path.join(repo, "example.py")]})
    require("real parser CodeMap", not is_error and "linux_port_smoke" in text, text[:300])
    for path in (outside, os.path.join(repo, "escape.txt")):
        is_error, text = server.call_tool("read_file", {"path": path})
        require("root fence " + os.path.basename(path), is_error and "OUTSIDE_ROOT_MUST_NOT_LEAK" not in text, text[:300])

    is_error, text = server.call_tool("manage_selection", {"op": "set", "paths": [hello]})
    require("select context", not is_error, text[:300])
    is_error, text = server.call_tool("prompt", {"op": "set", "text": "LINUX_PERSISTED_PROMPT"})
    require("set prompt", not is_error, text[:300])
    is_error, text = server.call_tool("workspace_context", {"op": "snapshot"})
    snapshot = json.loads(text) if not is_error else {}
    require("workspace context snapshot", not is_error and hello in snapshot.get("selection", [])
            and snapshot.get("prompt") == "LINUX_PERSISTED_PROMPT", text[:300])

    create = {"action": "create", "path": created, "content": "created\n"}
    is_error, text = server.call_tool("file_actions", create)
    require("create denied with grantMissing",
            is_error and "no active grant covers this operation" in text
            and not os.path.exists(created), text[:200])

    rc, out, prompt = policy_grant(binary, env, driver_fingerprint(), repo)
    require("policy grant", rc == 0 and "stored at policy revision" in out, f"exit={rc} out={out!r} tty={prompt!r}")

    is_error, text = server.call_tool("file_actions", create)
    require("create allowed after grant", not is_error and os.path.isfile(created), text[:200])

    is_error, text = server.call_tool("apply_edits", {"path": hello, "search": "hello linux", "replace": "hello granted"})
    with open(hello) as handle:
        edited = handle.read()
    require("apply_edits allowed after grant", not is_error and "hello granted" in edited, text[:200])

    rc = server.close()
    require("stdin EOF exits cleanly", rc == 0, f"exit={rc}")

    restarted = HeadlessServer(binary, env, os.path.join(base, "restart.stderr"))
    restarted.initialize()
    is_error, text = restarted.call_tool("prompt", {"op": "get"})
    require("durable prompt after process restart", not is_error and "LINUX_PERSISTED_PROMPT" in text, text[:300])
    is_error, text = restarted.call_tool("read_file", {"path": created})
    require("durable mutation after process restart", not is_error and "created" in text, text[:300])
    require("restart EOF exits cleanly", restarted.close() == 0, "restart did not shut down")

    run_cli_smoke(binary, env, hello)


def run_cli_smoke(binary, env, hello):
    cases = [
        ("CLI tool list", ["-l"], "", 0, "read_file"),
        ("CLI exec tree", ["-e", "tree"], "", 0, "example.py"),
        ("CLI direct call", ["-c", "read_file", "-j", json.dumps({"path": hello}), "--raw-json"], "", 0, "hello granted"),
        ("CLI persisted prompt", ["-c", "prompt", "-j", '{"op":"get"}'], "", 0, "LINUX_PERSISTED_PROMPT"),
        ("CLI interactive REPL", ["-i"], "tree\nexit\n", 0, "example.py"),
        ("CLI detached agent requires persistent session",
         ["-c", "agent_run", "-j", '{"op":"start","detach":true}'], "", 1, "long-lived MCP connection"),
    ]
    for label, arguments, input_text, expected_code, expected in cases:
        proc = subprocess.Popen([binary, *arguments], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=env, start_new_session=True)
        try:
            out, err = proc.communicate(input_text, timeout=TIMEOUT_SECONDS)
            if "--raw-json" in arguments:
                json.loads(out)
            result_text = out if expected_code == 0 else out + err
            require(label, proc.returncode == expected_code and expected in result_text,
                    f"exit={proc.returncode} stdout={out[-1000:]!r} stderr={err[-1000:]!r}")
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait(timeout=5)
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()


def run_deleted_image_check(binary, base):
    # Re-run this script under a private interpreter copy that then unlinks itself.
    os.makedirs(base, exist_ok=True)
    interpreter = os.path.join(base, "python3")
    shutil.copy2(os.path.realpath(sys.executable), interpreter)
    # A copied interpreter cannot locate a relocatable toolchain's standard
    # library relative to its new path. Retain this interpreter's actual roots.
    environment = os.environ.copy()
    environment["PYTHONHOME"] = os.pathsep.join((sys.base_prefix, sys.base_exec_prefix))
    result = subprocess.run([interpreter, os.path.abspath(__file__), "--binary", binary, DELETED_IMAGE_FLAG],
                            capture_output=True, text=True, env=environment,
                            timeout=4 * TIMEOUT_SECONDS)
    detail = (result.stdout + result.stderr).strip()
    require("extra deleted parent image is not fingerprinted", result.returncode == 0, detail)


def as_deleted_image(binary):
    image = os.readlink("/proc/self/exe")
    os.unlink(image)
    with open(image + " (deleted)", "w") as decoy:
        decoy.write("decoy\n")
    base = os.path.dirname(image)
    env = headless_env(base)
    target = os.path.join(env["REPOPROMPT_MCP_WORKING_DIRS"], "x.txt")
    server = HeadlessServer(binary, env, os.path.join(base, "deleted-image.stderr"))
    server.initialize()
    is_error, text = server.call_tool("file_actions", {"action": "create", "path": target, "content": "x"})
    server.close()
    if not (is_error and "client principal is not verified" in text and not os.path.exists(target)):
        print(f"expected principalUnverified for an unlinked parent image, got: {text[:200]}")
        return 1
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument(DELETED_IMAGE_FLAG, action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv[1:])
    binary = os.path.abspath(args.binary)
    if args.as_deleted_image:
        try:
            return as_deleted_image(binary)
        finally:
            for server in HeadlessServer.active:
                server.abort()
    base = os.path.realpath(tempfile.mkdtemp(prefix="rpce-linux-headless-smoke-"))
    try:
        run_smoke(binary, os.path.join(base, "smoke"))
        run_deleted_image_check(binary, os.path.join(base, "deleted-image"))
    except (SmokeFailure, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        for log in ("smoke/server.stderr", "deleted-image/deleted-image.stderr"):
            path = os.path.join(base, log)
            if os.path.exists(path):
                with open(path, errors="replace") as handle:
                    tail = handle.read()[-2000:]
                if tail:
                    print(f"--- {log} (tail)\n{tail}", file=sys.stderr)
        print(f"Artifacts kept in {base}", file=sys.stderr)
        return 1
    finally:
        for server in HeadlessServer.active:
            server.abort()
    shutil.rmtree(base)
    print("Linux headless smoke passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
