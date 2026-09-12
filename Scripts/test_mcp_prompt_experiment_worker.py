#!/usr/bin/env python3
"""Real pinned MCPAdapter + headless RPCE stdio; deterministic host model replies.

Run with the assembled bundled interpreter after a coordinated MCP build.
No providers, credentials, app session, or live workspace are used.
"""
import hashlib
import json
import os
import subprocess
import select
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
WORKER = Path(os.environ.get('REPOPROMPT_TEST_GEPA_WORKER', ROOT / 'AppResources/PromptExperiments/gepa_worker.py')).resolve()
sys.path.insert(0, str(WORKER.parent))
from mcp_evaluation import evaluate_mcp, ACTIVE_CHILDREN, MCPAdapter


class InfrastructureFailure(BaseException):
    pass


class MCPExperimentTests(unittest.TestCase):
    def setup_trial(self, directory):
        root = Path(directory)
        project = root / 'reviewed-project'; project.mkdir()
        marker = 'MCP_READ_' + uuid.uuid4().hex
        (project / 'README.md').write_text(marker)
        out = root / 'outputs'; out.mkdir()
        server = Path(os.environ.get('RPCE_TEST_MCP_SERVER', ROOT / '.build/debug/repoprompt-mcp')).resolve()
        self.assertTrue(server.is_file(), 'Build repoprompt-mcp through conductor first')
        definitions = json.loads((ROOT / 'docs/spec/mcp-domain-canonical-tool-definitions.generated.json').read_text())['tools']
        tool = next(t for t in definitions if t['name']=='read_file')
        body = {'output_dir':str(out), 'mcp_adapter':{
            'server_path':str(server),'server_sha256':hashlib.sha256(server.read_bytes()).hexdigest(),
            'project_root':str(project),'tool_names':['read_file'],'component':'system_prompt',
            'tool_definitions_json':json.dumps([tool]),'instructions':'Answer using the reviewed file.'}}
        return body, marker, {'id':'read','input':'Read README.md and return its complete contents.','split':'training'}

    def run_trial(self, body, marker, example, *, bad_choice=False, provider_failure=False):
        operations=[]; events=[]; grades=[]
        def host(operation, payload):
            operations.append(operation)
            if operation=='mcp_begin':return {'output':str(uuid.uuid4())}
            if operation=='mcp_model':
                self.assertNotIn('HOST_PRIVATE_GRADING',json.dumps(payload))
                if provider_failure:raise InfrastructureFailure('provider unavailable')
                if payload['phase']==1:
                    return {'output':json.dumps({'action':'call_tool','tool':'prompt_experiment' if bad_choice else 'read_file','arguments':{'path':'README.md'}})}
                self.assertIn(marker,json.dumps(payload['messages']))
                return {'output':marker}
            if operation=='mcp_grade':
                grades.append(payload)
                return {'ok':True,'score':0.0 if payload['candidate_failure'] else 1.0,
                        'feedback':'HOST_PRIVATE_GRADING','output':json.dumps(payload['trace'])}
            self.fail(operation)
        result=evaluate_mcp('Use read_file to find the requested evidence.',example,body,host,events.append,InfrastructureFailure,lambda _:None)
        self.assertFalse(ACTIVE_CHILDREN)
        for e in events:
            if e['state']=='closed':
                with self.assertRaises(ProcessLookupError):os.kill(e['pid'],0)
        return result,operations,events,grades

    def test_real_tool_call_and_fresh_process_trace(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-adapter-') as directory:
            body,marker,example=self.setup_trial(directory)
            result,ops,events,grades=self.run_trial(body,marker,example)
            self.assertEqual(result['score'],1.0)
            self.assertEqual(ops,['mcp_begin','mcp_model','mcp_model','mcp_grade'])
            self.assertEqual([e['state'] for e in events],['started','closed'])
            self.assertEqual(len(grades[0]['trace']['tool_calls']),1)
            self.assertIn(marker,json.dumps(grades[0]['trace']['tool_calls'][0]['result']))
            self.assertEqual(Path(body['mcp_adapter']['project_root'],'README.md').read_text(),marker)

    def test_control_tool_choice_is_candidate_failure_without_tool_call(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-adapter-') as directory:
            body,marker,example=self.setup_trial(directory)
            result,ops,_,grades=self.run_trial(body,marker,example,bad_choice=True)
            self.assertEqual(result['score'],0.0)
            self.assertEqual(ops,['mcp_begin','mcp_model','mcp_grade'])
            self.assertEqual(grades[0]['trace']['tool_calls'],[])

    def test_provider_failure_is_not_an_upstream_zero_score_and_reaps_server(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-adapter-') as directory:
            body,marker,example=self.setup_trial(directory)
            with self.assertRaisesRegex(InfrastructureFailure, 'provider unavailable'):self.run_trial(body,marker,example,provider_failure=True)
            self.assertFalse(ACTIVE_CHILDREN)

    def test_swallowed_upstream_second_pass_failure_is_not_graded(self):
        async def broken_second_pass(*args, **kwargs):
            raise RuntimeError('synthetic second-pass failure')
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-adapter-') as directory:
            body,marker,example=self.setup_trial(directory)
            with patch.object(MCPAdapter, '_second_pass', broken_second_pass):
                with self.assertRaisesRegex(InfrastructureFailure, 'swallowed an incomplete trajectory'):
                    self.run_trial(body,marker,example)
            self.assertFalse(ACTIVE_CHILDREN)

    def test_real_gepa_search_uses_real_mcp_and_host_reflection(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-search-') as directory:
            body,marker,example=self.setup_trial(directory)
            body.update(run_name='real-mcp-search',run_dir=str(Path(directory)/'gepa-run'),
                        objective='Use read_file and return the complete requested evidence.',
                        background='Deterministic integration test, not quality evidence.',
                        examples=[example],seed_candidate='Guess without reading.',
                        reflection_minibatch_size=1,skip_perfect_score=True,
                        max_evaluations=12,stop_at_score=1.0,perfect_score=1.0)
            leases={}; operations=[]; events=[]; completed=None
            with tempfile.TemporaryFile(mode='w+') as stderr:
                process=subprocess.Popen([sys.executable,'-I','-B',str(WORKER)],
                    stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,text=True,bufsize=1,
                    env={'HOME':directory,'TMPDIR':directory,'PATH':'/usr/bin:/bin'})
                try:
                    process.stdin.write(json.dumps({'protocol_version':1,'type':'run','request':body})+'\n');process.stdin.flush()
                    for _ in range(200):
                        self.assertTrue(select.select([process.stdout],[],[],20)[0], 'Worker protocol stalled')
                        line=process.stdout.readline();self.assertTrue(line)
                        event=json.loads(line);events.append(event)
                        self.assertNotEqual(event['type'],'failed',event)
                        if event['type']=='completed':
                            completed=event['result'];break
                        if event['type']!='host_request':continue
                        op=event['operation'];payload=event['payload'];operations.append(op)
                        reply={'type':'host_response','id':event['id'],'ok':True}
                        if op=='reflect':reply['output']='```\nRead the requested evidence with read_file.\n```'
                        elif op=='mcp_begin':
                            lease=str(uuid.uuid4());leases[lease]=payload['candidate'];reply['output']=lease
                        elif op=='mcp_model':
                            candidate=leases[payload['evaluation_id']]
                            if payload['phase']==1:
                                reply['output']=json.dumps({'action':'call_tool','tool':'read_file','arguments':{'path':'README.md'}}) if candidate.startswith('Read') else json.dumps({'action':'answer','answer':'guess'})
                            else:
                                self.assertIn(marker,json.dumps(payload['messages']));reply['output']=marker
                        elif op=='mcp_grade':
                            score=float(payload['answer']==marker and not payload['candidate_failure'])
                            reply.update(score=score,feedback='Read the file instead of guessing.',output=json.dumps(payload['trace']))
                        else:self.fail(op)
                        process.stdin.write(json.dumps(reply)+'\n');process.stdin.flush()
                    process.stdin.close();process.wait(timeout=10)
                    stderr.seek(0);details=stderr.read()
                    self.assertEqual(process.returncode,0,details)
                    self.assertIsNotNone(completed,details)
                    self.assertEqual(completed['engine'],'gepa')
                    self.assertEqual(completed['baseline_score'],0.0)
                    self.assertEqual(completed['best_score'],1.0)
                    self.assertGreater(len(completed['candidates']),1)
                    self.assertIn('reflect',operations)
                    self.assertTrue(any('tool_completed' in e['output'] for e in completed['evaluations']))
                    self.assertEqual(sum(e.get('state')=='started' for e in events),sum(e.get('state')=='closed' for e in events))
                finally:
                    if process.poll() is None:process.kill();process.wait(timeout=5)
                    for stream in (process.stdin,process.stdout):stream.close()

    def test_worker_cancellation_reaps_active_mcp_server_before_first_evaluation(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-cancel-') as directory:
            body,marker,example=self.setup_trial(directory)
            body.update(run_name='cancel-test',run_dir=str(Path(directory)/'gepa-run'),
                        objective='Read evidence',background='Deterministic cancellation test',
                        examples=[example],stage='preparation',preparation_candidates=['Read README.md.'],
                        max_evaluations=2,perfect_score=1.0)
            process=subprocess.Popen([sys.executable,'-I','-B',str(WORKER)],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1,
                env={'HOME':directory,'TMPDIR':directory,'PATH':'/usr/bin:/bin'})
            pid=None
            try:
                process.stdin.write(json.dumps({'protocol_version':1,'type':'run','request':body})+'\n');process.stdin.flush()
                while True:
                    self.assertTrue(select.select([process.stdout],[],[],20)[0], 'Worker failed to reach the model callback')
                    line=process.stdout.readline();self.assertTrue(line)
                    event=json.loads(line)
                    self.assertNotEqual(event['type'],'failed',event)
                    if event['type']=='mcp_process' and event['state']=='started':pid=event['pid']
                    if event['type']=='host_request':
                        if event['operation']=='mcp_model':break
                        self.assertEqual(event['operation'],'mcp_begin')
                        process.stdin.write(json.dumps({'type':'host_response','id':event['id'],'ok':True,'output':str(uuid.uuid4())})+'\n');process.stdin.flush()
                self.assertIsNotNone(pid)
                process.terminate()
                output,_=process.communicate(timeout=10)
                self.assertNotIn('"type":"completed"',output)
                self.assertIn('"type":"cancelled"',output)
                self.assertEqual(process.returncode,130)
                with self.assertRaises(ProcessLookupError):os.kill(pid,0)
            finally:
                if process.poll() is None:process.kill();process.wait(timeout=5)
                if pid is not None:
                    try:os.kill(pid,0)
                    except ProcessLookupError:pass
                    else:os.kill(pid,9)
                for stream in (process.stdin,process.stdout,process.stderr):stream.close()

    def test_changed_schema_fails_before_any_model_call(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-adapter-') as directory:
            body,_,example=self.setup_trial(directory)
            tools=json.loads(body['mcp_adapter']['tool_definitions_json']);tools[0]['inputSchema']['required']=['wrong']
            body['mcp_adapter']['tool_definitions_json']=json.dumps(tools)
            calls=[]
            def host(op,payload):
                calls.append(op)
                self.assertEqual(op,'mcp_begin')
                return {'output':str(uuid.uuid4())}
            with self.assertRaisesRegex(InfrastructureFailure, 'MCP exposed schema differs'):
                evaluate_mcp('Read the file.',example,body,host,lambda _:None,InfrastructureFailure,lambda _:None)
            self.assertEqual(calls,['mcp_begin'])
            self.assertFalse(ACTIVE_CHILDREN)


if __name__=='__main__':unittest.main()
