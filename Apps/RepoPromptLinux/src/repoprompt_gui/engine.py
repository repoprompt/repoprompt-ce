"""An asynchronous, persistent MCP stdio client owned by the desktop window."""

from collections import deque
from dataclasses import dataclass
import json
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, Signal

Callback = Callable[[object, Exception | None], None]
MAX_FRAME_BYTES = 64 * 1024 * 1024


class EngineError(Exception):
    pass


def tool_value(result: dict) -> object:
    text = "\n".join(item.get("text", "") for item in result.get("content", []) if item.get("type") == "text")
    if result.get("isError"):
        raise EngineError(text or "The engine could not complete this operation.")
    if "structuredContent" in result:
        return result["structuredContent"]
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return text


@dataclass
class Request:
    identifier: int
    method: str
    params: dict
    callback: Callback


class EngineClient(QObject):
    ready = Signal()
    failed = Signal(str)
    busy_changed = Signal(bool)
    closed = Signal()

    def __init__(self, binary: Path, repository: Path, profile: Path, parent=None, timeout_ms=60_000):
        super().__init__(parent)
        self.binary, self.repository, self.profile = binary, repository, profile
        self.timeout_ms = timeout_ms
        self.tools: dict[str, dict] = {}
        self.is_ready = False
        self._stopping = False
        self._failed = False
        self._buffer = bytearray()
        self._stderr = b""
        self._next_id = 0
        self._queue: deque[Request] = deque()
        self._active: Request | None = None
        self.process = QProcess(self)
        self.process.setProcessChannelMode(QProcess.ProcessChannelMode.SeparateChannels)
        self.process.setUnixProcessParameters(QProcess.UnixProcessFlag.CreateNewSession)
        environment = QProcessEnvironment.systemEnvironment()
        environment.insert("REPOPROMPT_MCP_HEADLESS_PROFILE", "linux-gui")
        environment.insert("REPOPROMPT_MCP_HEADLESS_PROFILE_DIR", str(profile))
        environment.insert("REPOPROMPT_MCP_WORKING_DIRS", str(repository))
        self.process.setProcessEnvironment(environment)
        self.process.setWorkingDirectory(str(repository))
        self.process.started.connect(self._initialize)
        self.process.readyReadStandardOutput.connect(self._read)
        self.process.readyReadStandardError.connect(self._read_stderr)
        self.process.errorOccurred.connect(self._process_error)
        self.process.finished.connect(self._finished)
        self._deadline = QTimer(self)
        self._deadline.setSingleShot(True)
        self._deadline.timeout.connect(lambda: self._fail("The context engine timed out. Reopen the repository to reconnect."))
        self._shutdown_deadline = QTimer(self)
        self._shutdown_deadline.setSingleShot(True)
        self._shutdown_deadline.timeout.connect(self._kill)

    @property
    def busy(self):
        return self._active is not None or bool(self._queue)

    def start(self):
        self.process.start(str(self.binary), ["--backend", "headless"])

    def _initialize(self):
        self._request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "RepoPrompt CE Linux GUI", "version": "0.1.0"},
        }, self._initialized)

    def _initialized(self, result, error):
        if error:
            self._fail(str(error))
            return
        self._write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self._request("tools/list", {}, self._listed_tools)

    def _listed_tools(self, result, error):
        if error or not isinstance(result, dict) or not isinstance(result.get("tools"), list):
            self._fail(str(error or "The engine returned an invalid tool catalog."))
            return
        if not all(isinstance(tool, dict) and isinstance(tool.get("name"), str) for tool in result["tools"]):
            self._fail("The engine returned an invalid tool catalog.")
            return
        self.tools = {tool["name"]: tool for tool in result["tools"]}
        required = {"read_file", "file_search", "manage_selection", "prompt", "workspace_context"}
        if not required.issubset(self.tools):
            self._fail("This engine does not support the desktop workflow. Install the Linux headless build.")
            return
        self.is_ready = True
        self.ready.emit()

    def call_tool(self, name: str, arguments: dict, callback: Callback):
        if not self.is_ready or self._stopping or self._failed:
            callback(None, EngineError("Open a repository to connect to the context engine."))
            return
        if name not in self.tools:
            callback(None, EngineError(f"The current engine does not provide {name}."))
            return

        def completed(result, error):
            if error:
                callback(None, error)
                return
            try:
                value = tool_value(result)
            except (EngineError, TypeError, AttributeError) as failure:
                callback(None, EngineError(str(failure)))
                return
            callback(value, None)

        self._request("tools/call", {"name": name, "arguments": arguments}, completed)

    def _request(self, method, params, callback):
        if len(self._queue) >= 128:
            callback(None, EngineError("Too many operations are queued. Wait for the current work to finish."))
            return
        self._next_id += 1
        self._queue.append(Request(self._next_id, method, params, callback))
        self.busy_changed.emit(True)
        self._send_next()

    def _send_next(self):
        if self._active is not None or self._stopping or self._failed:
            return
        if not self._queue:
            self.busy_changed.emit(False)
            return
        self._active = self._queue.popleft()
        self._deadline.start(self.timeout_ms)
        self._write({"jsonrpc": "2.0", "id": self._active.identifier,
                     "method": self._active.method, "params": self._active.params})

    def _write(self, message):
        data = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
        if self.process.write(data) < 0:
            self._fail("Cannot send a request to the context engine.")

    def _read(self):
        self._buffer.extend(bytes(self.process.readAllStandardOutput()))
        while b"\n" in self._buffer:
            line, _, rest = self._buffer.partition(b"\n")
            self._buffer = bytearray(rest)
            if len(line) > MAX_FRAME_BYTES:
                self._fail("The engine response exceeded the desktop message limit.")
                return
            if not line.strip():
                continue
            try:
                message = json.loads(line)
                if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
                    raise ValueError("not JSON-RPC")
            except (ValueError, UnicodeError):
                self._fail("The context engine returned an invalid response.")
                return
            if "method" in message:
                if "id" in message:
                    self._write({"jsonrpc": "2.0", "id": message["id"], "error": {
                        "code": -32601, "message": "The desktop client does not provide this method."}})
                continue
            if self._active is None or message.get("id") != self._active.identifier:
                continue
            request, self._active = self._active, None
            self._deadline.stop()
            error = message.get("error")
            failure = EngineError(str(error.get("message", error))) if isinstance(error, dict) else None
            request.callback(message.get("result"), failure)
            self._send_next()
        if len(self._buffer) > MAX_FRAME_BYTES:
            self._fail("The engine response exceeded the desktop message limit.")

    def _read_stderr(self):
        self._stderr = (self._stderr + bytes(self.process.readAllStandardError()))[-16_384:]

    def _process_error(self, error):
        if not self._stopping and error == QProcess.ProcessError.FailedToStart:
            self._fail(f"Cannot start the context engine: {self.process.errorString()}")

    def _finished(self, code, _status):
        self._shutdown_deadline.stop()
        if not self._stopping and not self._failed:
            detail = self._stderr.decode("utf-8", errors="replace").strip()[-2000:]
            self._fail(f"The context engine exited ({code})." + (f"\n{detail}" if detail else ""))
        self.closed.emit()

    def _fail(self, message):
        if self._failed or self._stopping:
            return
        self._failed, self.is_ready = True, False
        self._deadline.stop()
        requests = ([self._active] if self._active else []) + list(self._queue)
        self._active = None
        self._queue.clear()
        # Stop the process before accepting another operation after an uncertain timeout.
        self.process.closeWriteChannel()
        self._shutdown_deadline.start(3000)
        for request in requests:
            request.callback(None, EngineError(message))
        self.busy_changed.emit(False)
        self.failed.emit(message)

    def shutdown(self):
        """EOF lets the engine cancel its provider work and flush durable state."""
        self._stopping, self.is_ready = True, False
        self._deadline.stop()
        self._active = None
        self._queue.clear()
        self.process.closeWriteChannel()
        if self.process.state() != QProcess.ProcessState.NotRunning:
            self._shutdown_deadline.start(5000)
        else:
            self.closed.emit()

    def _kill(self):
        # Qt owns the child handle; avoid signalling a numeric process group that
        # could outlive its leader. The engine owns its provider teardown on EOF.
        if self.process.state() != QProcess.ProcessState.NotRunning:
            self.process.kill()
