"""Check Codex developer-note delivery using an isolated app-server and a loopback fake model."""
import argparse
import json
import os
import pathlib
import queue
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
requests = []

class Model(BaseHTTPRequestHandler):

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_error(404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(body)
        rid = f'resp_{len(requests)}'
        msg = {'type': 'message', 'id': f'msg_{len(requests)}', 'role': 'assistant', 'status': 'completed', 'phase': 'final_answer', 'content': [{'type': 'output_text', 'text': 'Mock answer.', 'annotations': []}]}
        resp = {'id': rid, 'status': 'completed', 'output': [msg], 'usage': {'input_tokens': 20, 'output_tokens': 3, 'total_tokens': 23}}
        events = [{'type': 'response.created', 'response': {'id': rid}}, {'type': 'response.output_item.added', 'output_index': 0, 'item': msg}, {'type': 'response.output_item.done', 'output_index': 0, 'item': msg}, {'type': 'response.completed', 'response': resp}]
        data = ''.join(('event: ' + v['type'] + '\ndata: ' + json.dumps(v) + '\n\n' for v in events)).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

class RPC:

    def __init__(self, binary, home, env):
        self.q = queue.Queue()
        self.i = 0
        self.p = subprocess.Popen([str(binary), 'app-server'], cwd=home, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        threading.Thread(target=self.reader, daemon=True).start()
        self.call('initialize', {'clientInfo': {'name': 'rpce_note_test', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized'})

    def reader(self):
        for l in self.p.stdout:
            self.q.put(json.loads(l))

    def send(self, m):
        self.p.stdin.write(json.dumps(m) + '\n')
        self.p.stdin.flush()

    def get(self, predicate):
        end = time.monotonic() + 30
        while True:
            m = self.q.get(timeout=max(0.01, end - time.monotonic()))
            if predicate(m):
                return m

    def call(self, method, params):
        self.i += 1
        self.send({'id': self.i, 'method': method, 'params': params})
        m = self.get(lambda m: m.get('id') == self.i and ('result' in m or 'error' in m))
        if 'error' in m:
            raise RuntimeError(m)
        return m['result']

    def turn(self, tid, text):
        prev = len(requests)
        status = self.call('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': text, 'text_elements': []}]})
        self.done(status['turn']['id'])
        assert len(requests) == prev + 1, (prev, len(requests))
        return requests[-1]

    def done(self, tid=None):
        m = self.get(lambda m: m.get('method') == 'turn/completed' and (tid is None or m['params']['turn']['id'] == tid))
        assert m['params']['turn']['status'] == 'completed', m

    def stop(self):
        self.p.terminate()
        self.p.wait(timeout=5)

def copies(req, note):

    def walk(v):
        if isinstance(v, str):
            return v.count(note)
        if isinstance(v, list):
            return sum(map(walk, v))
        if isinstance(v, dict):
            return sum(map(walk, v.values()))
        return 0
    return walk(req)

MINIMUM_VERSION = (0, 170, 0)
CONFIGURED = 'Configured developer sentinel'

def parse_version(text):
    parts = text.strip().removeprefix('codex-cli ').split('-')[0].split('.')
    return tuple(int(p) for p in parts[:3])

def check(req, note, notes, configured=1, legacy=False):
    text = json.dumps(req)
    assert copies(req, note) == notes, (copies(req, note), notes)
    assert text.count(CONFIGURED) == configured, (text.count(CONFIGURED), configured)
    assert ('Legacy base sentinel' in text) == legacy

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', type=pathlib.Path, required=True)
    args = parser.parse_args()
    binary = args.codex.resolve()
    version = subprocess.check_output([str(binary), '--version'], text=True).strip()
    if parse_version(version) < MINIMUM_VERSION:
        parser.error(f'expected Codex 0.170.0 or newer (the native-instructions floor); got {version}')
    print(version, flush=True)
    fixture = pathlib.Path(__file__).resolve().parents[2] / 'Tests/RepoPromptTests/Fixtures/CodexNativeDeveloperNote.txt'
    note = fixture.read_bytes().decode('utf-8')
    # RepoPrompt appends the configured developer_instructions because a provided value replaces it.
    composed = note + '\n\n' + CONFIGURED
    srv = ThreadingHTTPServer(('127.0.0.1', 0), Model)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='rpce-codex-note-') as tmp:
        home = pathlib.Path(tmp)
        (home / 'config.toml').write_text(f'model = "gpt-6.2-sol"\n model_provider = "fake"\n developer_instructions = "{CONFIGURED}"\n [model_providers.fake]\n name = "Fake"\n base_url = "http://127.0.0.1:{srv.server_port}/v1"\n wire_api = "responses"\n request_max_retries = 0\n stream_max_retries = 0\n ')
        env = {k: os.environ[k] for k in ('PATH', 'TMPDIR', 'LANG') if k in os.environ}
        env.update(HOME=tmp, CODEX_HOME=tmp, CODEX_SQLITE_HOME=tmp)
        p = RPC(binary, home, env)
        try:
            assert p.call('config/read', {'includeLayers': False})['config'].get('developer_instructions') == CONFIGURED
            bare = p.call('thread/start', {'developerInstructions': note})['thread']['id']
            check(p.turn(bare, 'note alone'), note, 1, configured=0)
            print('note alone replaces configured developer_instructions', flush=True)
            new = p.call('thread/start', {'developerInstructions': composed})['thread']['id']
            check(p.turn(new, 'new thread first turn'), note, 1)
            print('fresh: one note, configured kept', flush=True)
            p.call('thread/compact/start', {'threadId': new})
            p.done()
            check(p.turn(new, 'turn after compact'), note, 1)
            print('after compaction: one note, configured kept', flush=True)
            old = p.call('thread/start', {'baseInstructions': 'Legacy base sentinel'})['thread']['id']
            check(p.turn(old, 'old thread first turn'), note, 0, legacy=True)
            unknown = p.call('thread/start', {'baseInstructions': 'Legacy base sentinel'})['thread']['id']
            check(p.turn(unknown, 'unknown-mode thread first turn'), note, 0, legacy=True)
        finally:
            p.stop()
        p = RPC(binary, home, env)
        try:
            assert p.call('thread/resume', {'threadId': new, 'developerInstructions': composed})['thread']['id'] == new
            check(p.turn(new, 'after cold resume'), note, 1)
            print('native after cold resume: one note', flush=True)
            # Known legacy threads resume without the note; the RepoPrompt base already carries it.
            assert p.call('thread/resume', {'threadId': old})['thread']['id'] == old
            check(p.turn(old, 'legacy after cold resume'), note, 0, legacy=True)
            p.call('thread/compact/start', {'threadId': old})
            p.done()
            check(p.turn(old, 'legacy after compact'), note, 0, legacy=True)
            print('legacy: no note through resume and compaction', flush=True)
            # Conversations saved before the mode was recorded keep the #1833 behavior.
            assert p.call('thread/resume', {'threadId': unknown, 'developerInstructions': composed})['thread']['id'] == unknown
            p.call('thread/compact/start', {'threadId': unknown})
            p.done()
            req = p.turn(unknown, 'unknown-mode after compact')
            assert copies(req, note) <= 1 and 'Legacy base sentinel' in json.dumps(req)
            print('unknown mode after compact', copies(req, note), flush=True)
            # Why the mode is recorded: a native thread resumed without the note loses it at compaction.
            assert p.call('thread/resume', {'threadId': bare})['thread']['id'] == bare
            p.call('thread/compact/start', {'threadId': bare})
            p.done()
            print('native resumed without note, after compact:', copies(p.turn(bare, 'dropped note'), note), 'notes', flush=True)
        finally:
            p.stop()
        p = RPC(binary, home, env)
        try:
            assert p.call('thread/resume', {'threadId': new, 'developerInstructions': composed, 'config': {'features.computer_use': True}})['thread']['id'] == new
            check(p.turn(new, 'after enabling Computer Use'), note, 1)
            p.call('thread/compact/start', {'threadId': new})
            p.done()
            check(p.turn(new, 'Computer Use after compact'), note, 1)
            print('CU rebind and compaction: one note', flush=True)
        finally:
            p.stop()
if __name__ == '__main__':
    main()
