import os
from pathlib import Path
import tempfile
import time
import unittest

from PySide6.QtCore import QProcess
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

from repoprompt_gui.engine import EngineClient, tool_value

APP = QApplication.instance() or QApplication([])
APP.setQuitOnLastWindowClosed(False)
ENGINE = os.environ.get("REPOPROMPT_GUI_TEST_ENGINE", "")


def wait_for(condition, timeout=15):
    deadline = time.monotonic() + timeout
    while not condition():
        APP.processEvents()
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out waiting for Qt/engine operation")
        QTest.qWait(10)
    APP.processEvents()


def call(client, name, arguments):
    result = []
    client.call_tool(name, arguments, lambda value, error: result.append((value, error)))
    wait_for(lambda: bool(result))
    value, error = result[0]
    if error:
        raise error
    return value


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rpce-gui-protocol-")
        self.root = Path(self.temporary.name)
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.shutdown()
        wait_for(lambda: all(c.process.state() == QProcess.ProcessState.NotRunning for c in self.clients))
        self.temporary.cleanup()

    def fake_client(self, behavior, timeout_ms=1000):
        binary = self.root / f"engine-{len(self.clients)}"
        binary.write_text("#!/usr/bin/env python3\n" + '''
import json, sys, time
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    if request['method'] == 'initialize': result = {}
    elif request['method'] == 'tools/list':
        result = {'tools': [{'name': name} for name in ('read_file','file_search','manage_selection','prompt','workspace_context')]}
    else:
''' + "\n".join("        " + line for line in behavior.splitlines()) + '''
        continue
    print(json.dumps({'jsonrpc':'2.0', 'id':request['id'], 'result':result}), flush=True)
''')
        binary.chmod(0o755)
        client = EngineClient(binary, self.root, self.root / "profile", timeout_ms=timeout_ms)
        self.clients.append(client)
        client.start()
        wait_for(lambda: client.is_ready)
        return client

    def test_fragmented_unicode_response_is_reassembled(self):
        client = self.fake_client('''payload = json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'content':[{'type':'text','text':json.dumps('héllo 界',ensure_ascii=False)}]}},ensure_ascii=False).encode()
for byte in payload + b'\\n':
    sys.stdout.buffer.write(bytes([byte])); sys.stdout.buffer.flush()
    time.sleep(0.0001)''')
        self.assertEqual(call(client, "read_file", {"path": "résumé.py"}), "héllo 界")

    def test_timeout_fails_pending_request_and_stops_engine(self):
        client = self.fake_client("time.sleep(0.3)", timeout_ms=100)
        results, failures = [], []
        client.failed.connect(failures.append)
        client.call_tool("read_file", {}, lambda value, error: results.append(error))
        wait_for(lambda: bool(failures))
        self.assertFalse(client.is_ready)
        self.assertEqual(len(results), 1)
        self.assertIn("timed out", str(results[0]))
        wait_for(lambda: client.process.state() == QProcess.ProcessState.NotRunning)

    def test_malformed_response_fails_without_hanging_the_queue(self):
        client = self.fake_client("print('not-json', flush=True)")
        failures = []
        client.failed.connect(failures.append)
        client.call_tool("read_file", {}, lambda *_: None)
        wait_for(lambda: bool(failures))
        self.assertIn("invalid response", failures[0])

    def test_unresponsive_engine_is_killed_after_eof_grace_period(self):
        client = self.fake_client("time.sleep(30)", timeout_ms=100)
        failures = []
        client.failed.connect(failures.append)
        client.call_tool("read_file", {}, lambda *_: None)
        wait_for(lambda: bool(failures))
        wait_for(lambda: client.process.state() == QProcess.ProcessState.NotRunning, timeout=6)

    def test_tool_error_is_recoverable(self):
        with self.assertRaisesRegex(Exception, "denied"):
            tool_value({"isError": True, "content": [{"type": "text", "text": "denied"}]})
        self.assertEqual(tool_value({"content": [{"type": "text", "text": '{"prompt":"ok"}'}]}), {"prompt": "ok"})


@unittest.skipUnless(ENGINE, "Set REPOPROMPT_GUI_TEST_ENGINE to run real-engine integration tests")
class RealEngineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rpce-gui-engine-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "repo"
        self.root.mkdir()
        self.file = self.root / "résumé 'one'.py"
        self.file.write_text('def greet():\n    return "hello 界"\n')
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.shutdown()
        wait_for(lambda: all(c.process.state() == QProcess.ProcessState.NotRunning for c in self.clients))
        self.temporary.cleanup()

    def open(self):
        client = EngineClient(Path(ENGINE).resolve(), self.root, self.base / "profile")
        self.clients.append(client)
        client.start()
        wait_for(lambda: client.is_ready)
        return client

    def test_prompt_and_selection_persist_across_clean_eof_restart(self):
        client = self.open()
        self.assertEqual(call(client, "read_file", {"path": str(self.file)}), self.file.read_text())
        call(client, "prompt", {"op": "set", "text": "Explain greet."})
        call(client, "manage_selection", {"op": "set", "paths": [str(self.file)]})
        client.shutdown()
        wait_for(lambda: client.process.state() == QProcess.ProcessState.NotRunning)
        restarted = self.open()
        snapshot = call(restarted, "workspace_context", {"op": "snapshot"})
        self.assertEqual(snapshot["prompt"], "Explain greet.")
        self.assertEqual(snapshot["selection"], [str(self.file)])

    def test_outside_root_and_symlink_reads_are_refused_then_valid_read_succeeds(self):
        outside = self.base / "outside.txt"
        outside.write_text("PRIVATE_OUTSIDE_CONTENT")
        (self.root / "escape.txt").symlink_to(outside)
        client = self.open()
        for path in (outside, self.root / "escape.txt"):
            with self.assertRaises(Exception) as failure:
                call(client, "read_file", {"path": str(path)})
            self.assertNotIn("PRIVATE_OUTSIDE_CONTENT", str(failure.exception))
        self.assertEqual(call(client, "read_file", {"path": str(self.file)}), self.file.read_text())
