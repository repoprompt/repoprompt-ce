"""RPCE boundary around the pinned upstream MCPAdapter; not a replacement optimizer.

Candidates are text. Only the approved component changes. The upstream two-pass
adapter performs real stdio MCP calls against a fresh read-only headless server.
"""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import os
import pathlib
import signal
import shutil
import sys
import tempfile
import time

from gepa.adapters.mcp_adapter.mcp_adapter import MCPAdapter
from gepa.adapters.mcp_adapter import mcp_adapter as upstream
from gepa.adapters.mcp_adapter.mcp_client import StdioMCPClient
from mcp import StdioServerParameters
from jsonschema import validate as validate_schema
from jsonschema.exceptions import ValidationError

# Match the native worker NDJSON reader's explicit bound. asyncio defaults to
# 64 KiB, below legitimate search results with surrounding source context.
MAX_MCP_RESPONSE_BYTES = 16 * 1024 * 1024
ACTIVE_CHILDREN: set[int] = set()


def project_manifest(root: pathlib.Path):
    records = []
    for path in sorted(root.rglob('*')):
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            data = path.read_bytes()
            records.append({'path': relative, 'sha256': hashlib.sha256(data).hexdigest(),
                            'bytes': len(data)})
    return records


def stop_children():
    for pid in tuple(ACTIVE_CHILDREN):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pid, signal.SIGKILL)


def sandbox_profile(project: pathlib.Path, scratch: pathlib.Path, server: pathlib.Path) -> str:
    def q(path):
        return json.dumps(str(path))
    parent_executables = {pathlib.Path(sys.executable), pathlib.Path(sys.executable).resolve()}
    parent_identity_reads = ' '.join(f'(literal {q(path)})' for path in parent_executables)
    # No network, live workspace, app storage, credentials, or source-project writes.
    # The server reads only the Python parent's executable identity so the domain
    # mutation policy can authenticate this run-scoped stdio client.
    return f'''(version 1)
(deny default)
(allow process*)
(allow sysctl-read)
(allow mach-lookup (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent"))
(allow file-read* (literal "/") (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/Library") (subpath {q(project)}) (subpath {q(scratch)}) (subpath {q(server.parent.parent)}) {parent_identity_reads})
(allow file-write* (subpath {q(scratch)}))'''


def evaluate_mcp(candidate, example, body, host_call, emit, failure_type, record_usage):
    started = time.monotonic()
    config = body['mcp_adapter']
    server = pathlib.Path(config['server_path']).resolve(strict=True)
    source_project = pathlib.Path(config['project_root']).resolve(strict=True)
    if hashlib.sha256(server.read_bytes()).hexdigest() != config['server_sha256']:
        raise failure_type('MCP server identity changed')
    definitions = json.loads(config['tool_definitions_json'])
    tools = config['tool_names']
    if {t['name'] for t in definitions} != set(tools):
        raise failure_type('MCP tool definitions do not match the seal')
    lease = host_call('mcp_begin', {'candidate': candidate, 'example': example})['output']
    scratch = pathlib.Path(tempfile.mkdtemp(prefix='mcp-eval-', dir=body['output_dir'])).resolve()
    project = scratch / 'project'
    source_manifest = project_manifest(source_project)
    shutil.copytree(source_project, project)
    trace = {'schema_version': 1, 'adapter': 'upstream_gepa_mcp_adapter_two_pass',
             'evaluation_id': lease, 'events': [], 'tool_calls': [], 'models': []}
    phase = 0
    candidate_failure = False

    def event(name, **fields):
        trace['events'].append(dict(event=name, elapsed_seconds=time.monotonic()-started, **fields))

    class ScopedClient(StdioMCPClient):
        async def start(self):
            try:
                self.stderr_bytes = 0
                self.process = await asyncio.create_subprocess_exec(
                    self.command, *self.args, stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                    cwd=str(scratch), start_new_session=True, limit=MAX_MCP_RESPONSE_BYTES)
                async def drain_stderr():
                    while chunk := await self.process.stderr.read(65536):
                        self.stderr_bytes += len(chunk)
                self.stderr_task = asyncio.create_task(drain_stderr())
                ACTIVE_CHILDREN.add(self.process.pid)
                event('server_started', pid=self.process.pid)
                emit({'protocol_version': 1, 'type': 'mcp_process', 'state': 'started', 'pid': self.process.pid})
            except Exception as error:
                raise failure_type('MCP server spawn failed') from error

        async def send_request(self, method, params=None):
            try:
                # Individual transport protection, not an experiment-wide deadline.
                return await asyncio.wait_for(super().send_request(method, params), timeout=300)
            except Exception as error:
                event('transport_failure', method=method, exception_type=type(error).__name__)
                raise failure_type('MCP transport failed') from error

        async def list_tools(self):
            listed = await super().list_tools()
            actual = {t['name']: t for t in listed}
            for expected in definitions:
                if expected['name'] not in actual or actual[expected['name']]['inputSchema'] != expected['inputSchema']:
                    raise failure_type('MCP exposed schema differs from the sealed schema')
            if set(actual) != set(tools):
                raise failure_type('Headless MCP exposed tools outside the sealed allowlist')
            event('schema_verified')
            return [actual[name] for name in tools]

        async def call_tool(self, name, arguments):
            nonlocal candidate_failure
            if name not in tools or len(trace['tool_calls']) >= 1:
                raise failure_type('MCP adapter exceeded its sealed tool authority')
            call = {'name': name, 'arguments': arguments, 'dispatched': False}
            trace['tool_calls'].append(call)
            try:
                validate_schema(arguments, next(t['inputSchema'] for t in definitions if t['name']==name))
            except ValidationError:
                candidate_failure = True
                call['argument_validation'] = 'rejected'
                return {'isError': True, 'content': [{'type':'text','text':'Arguments do not match the sealed tool schema.'}]}
            event('tool_started')
            call['dispatched'] = True
            result = await super().call_tool(name, arguments)
            call['result'] = result
            # A valid tool invocation may intentionally return an error (for
            # example, an expected absent-search edit). Preserve that outcome
            # as grading evidence instead of converting it into an automatic
            # candidate failure. Protocol/schema/authority violations above
            # remain hard candidate failures.
            event('tool_completed', is_error=bool(result.get('isError', False)))
            return result

        async def close(self):
            if not self.process:
                return
            pid = self.process.pid
            try:
                if self.process.stdin:
                    self.process.stdin.close()
                try:
                    await asyncio.wait_for(self.process.wait(), 3)
                except asyncio.TimeoutError:
                    self.process.terminate()
                    try:
                        await asyncio.wait_for(self.process.wait(), 2)
                    except asyncio.TimeoutError:
                        self.process.kill()
                        await self.process.wait()
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(pid, signal.SIGKILL)
                try:
                    await asyncio.wait_for(self.stderr_task, 2)
                except asyncio.TimeoutError:
                    self.stderr_task.cancel()
                event('server_closed', pid=pid, exit_status=self.process.returncode, stderr_bytes=self.stderr_bytes)
                emit({'protocol_version':1,'type':'mcp_process','state':'closed','pid':pid})
            finally:
                if self.process.returncode is None:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(pid, signal.SIGKILL)
                    await self.process.wait()
                ACTIVE_CHILDREN.discard(pid)

    def task_model(messages):
        nonlocal phase, candidate_failure
        phase += 1
        if phase > 2:
            raise failure_type('Upstream adapter exceeded two model passes')
        event('model_started', phase=phase)
        response = host_call('mcp_model', {'evaluation_id': lease, 'phase': phase, 'messages': messages})
        record_usage(response)
        output = response.get('output')
        if not isinstance(output, str):
            raise failure_type('MCP model callback returned no text')
        trace['models'].append({'phase':phase,'messages':messages,'output':output})
        if phase == 1:
            try:
                choice = json.loads(output)
                if not isinstance(choice, dict) or choice.get('action') not in ('call_tool','answer'):
                    candidate_failure = True
                elif choice['action']=='call_tool' and choice.get('tool') not in tools:
                    candidate_failure = True
            except ValueError:
                candidate_failure = True
        event('model_completed', phase=phase)
        return output

    env = {'HOME':str(scratch), 'TMPDIR':str(scratch), 'PATH':'/usr/bin:/bin',
           'REPOPROMPT_MCP_HEADLESS_PROFILE':'gepa-evaluation',
           'REPOPROMPT_MCP_HEADLESS_PROFILE_DIR':str(scratch/'profile'),
           'REPOPROMPT_MCP_WORKING_DIRS':str(project),
           'REPOPROMPT_MCP_EXPERIMENT_TOOLS':','.join(tools)}
    params = StdioServerParameters(command='/usr/bin/sandbox-exec', args=[
        '-p',sandbox_profile(project,scratch,server),'/usr/bin/env','-i',
        *[f'{k}={v}' for k,v in env.items()],str(server),'--backend','headless'])
    # The pinned upstream stdio client ignores StdioServerParameters.env. Supply an
    # explicit env -i argv inside the sandbox, and wrap only lifecycle/validation.
    original_factory = upstream.create_mcp_client
    clients = []
    def client_factory(**_):
        client = ScopedClient(params.command, params.args)
        clients.append(client)
        return client
    upstream.create_mcp_client = client_factory
    try:
        adapter = MCPAdapter(tool_names=tools, task_model=task_model,
                             metric_fn=lambda *_:0.0, server_params=params,
                             base_system_prompt=config['instructions'], enable_two_pass=True)
        result = adapter.evaluate([{'user_query':example['input'],'tool_arguments':{},
                                  'reference_answer':None,'additional_context':{}}],
                                  {config['component']:(config['instructions'] + '\n' + candidate if config['component']=='system_prompt' else candidate)},capture_traces=True)
        if len(result.outputs)!=1 or phase == 0:
            raise failure_type('Upstream MCP adapter did not produce a complete evaluation')
        trace['upstream_trajectory'] = result.trajectories
        events = trace['events']
        started_models = [e['phase'] for e in events if e['event']=='model_started']
        completed_models = [e['phase'] for e in events if e['event']=='model_completed']
        trajectories = result.trajectories or []
        valid = (sum(e['event']=='schema_verified' for e in events)==1
                 and started_models == completed_models == list(range(1,phase+1))
                 and len(trajectories)==1 and len(trace['models'])==phase)
        if valid:
            trajectory = trajectories[0]
            malformed_choice = candidate_failure and phase == 1 and not trace['tool_calls']
            valid = ((malformed_choice or trajectory['model_first_pass_output'] == trace['models'][0]['output'])
                     and (malformed_choice or trajectory['model_final_output'] == trace['models'][-1]['output'])
                     and bool(trajectory['tool_called']) == bool(trace['tool_calls']))
            dispatched = sum(c['dispatched'] for c in trace['tool_calls'])
            valid = valid and dispatched == sum(e['event']=='tool_completed' for e in events)
            if trace['tool_calls']:
                valid = valid and phase == 2 and trajectory['selected_tool'] == trace['tool_calls'][0]['name']
        if not valid:
            raise failure_type('Upstream MCP adapter swallowed an incomplete trajectory')
        answer = result.outputs[0]['final_answer']
        final_manifest = project_manifest(project)
        source_after = project_manifest(source_project)
        if source_after != source_manifest:
            raise failure_type('Reviewed source snapshot changed during isolated MCP evaluation')
        before = {entry['path']: entry for entry in source_manifest}
        after = {entry['path']: entry for entry in final_manifest}
        changed = sorted(path for path in before.keys() | after.keys()
                         if before.get(path) != after.get(path))
        trace['project_mutation'] = {
            'workspace': 'fresh_per_evaluation_copy',
            'source_snapshot_unchanged': True,
            'changed_paths': changed,
            'before_file_count': len(source_manifest),
            'after_file_count': len(final_manifest),
        }
        response = host_call('mcp_grade', {'evaluation_id':lease,'answer':answer,
            'trace':trace,'candidate_failure':candidate_failure})
        response['elapsed_seconds'] = time.monotonic()-started
        return response
    finally:
        upstream.create_mcp_client = original_factory
        for client in clients:
            process = client.process
            if process and process.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                with contextlib.suppress(ChildProcessError):
                    os.waitpid(process.pid, 0)
                ACTIVE_CHILDREN.discard(process.pid)
        # Rich artifacts stay local; failure logs expose only payload-free phase/PID.
        (scratch/'trajectory.json').write_text(json.dumps(trace,indent=2))
