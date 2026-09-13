#!/usr/bin/env python3
"""Real pinned MCPAdapter + headless RPCE stdio; deterministic host model replies.

Run with the assembled bundled interpreter after a coordinated MCP build.
No providers, credentials, app session, or live workspace are used.
"""
import hashlib
import json
import os
import re
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
from mcp_evaluation import (
    ACTIVE_CHILDREN,
    MCPAdapter,
    MUTABLE_COMPONENT_SENTINEL_PREFIX,
    composition_contract,
    evaluate_mcp,
    mutable_component_sentinel,
    prompt_surface_for_config,
)


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
            surface = result['prompt_surface']
            self.assertEqual(surface['mutable_insertion_count'], 1)
            self.assertEqual(
                surface['rendered_system_utf8_bytes'],
                surface['candidate_utf8_bytes'] + surface['fixed_scaffold_utf8_bytes'],
            )
            self.assertEqual(surface['model_passes'], 2)
            self.assertEqual(
                grades[0]['trace']['prompt_surface'],
                surface,
            )

    def test_prompt_surface_uses_exact_composed_renderer_not_naked_candidate(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-surface-') as directory:
            body, _, _ = self.setup_trial(directory)
            candidate = 'You are a helpful assistant with access to tools.'
            surface, rendered, template = prompt_surface_for_config(
                candidate, body['mcp_adapter'])
            self.assertEqual(surface['candidate_utf8_bytes'], 49)
            self.assertGreater(surface['rendered_system_utf8_bytes'], 49)
            self.assertGreater(surface['fixed_scaffold_utf8_bytes'], 0)
            self.assertEqual(
                surface['rendered_system_utf8_bytes'],
                len(rendered.encode('utf-8')),
            )
            self.assertEqual(template.count(MUTABLE_COMPONENT_SENTINEL_PREFIX), 1)
            contract = composition_contract(body['mcp_adapter'])
            marker_pattern = re.escape(MUTABLE_COMPONENT_SENTINEL_PREFIX) + r'[0-9a-f]{64}__'
            self.assertEqual(
                re.sub(marker_pattern, '<MUTABLE>', template),
                re.sub(
                    marker_pattern,
                    '<MUTABLE>',
                    contract.split(
                        '--- BEGIN RENDERED TEMPLATE ---\n', 1
                    )[1].split('\n--- END RENDERED TEMPLATE ---', 1)[0],
                ),
            )
            self.assertIn('Do not repeat', contract)
            self.assertIn(
                'Based on the tool response, please provide your final answer.',
                contract,
            )
            definitions = json.loads(body['mcp_adapter']['tool_definitions_json'])
            sentinel = mutable_component_sentinel(
                candidate, body['mcp_adapter'], definitions)
            self.assertEqual(
                sentinel,
                mutable_component_sentinel(
                    candidate, body['mcp_adapter'], definitions),
            )
            occupied = candidate + body['mcp_adapter']['instructions'] + json.dumps(definitions)
            self.assertNotIn(sentinel, occupied)

    def test_apply_edits_mutates_only_fresh_evaluation_copy_and_records_evidence(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-apply-') as directory:
            body, marker, example = self.setup_trial(directory)
            definitions = json.loads(
                (ROOT / 'docs/spec/mcp-domain-canonical-tool-definitions.generated.json').read_text()
            )['tools']
            tool = next(t for t in definitions if t['name'] == 'apply_edits')
            body['mcp_adapter'].update(
                tool_names=['apply_edits'],
                tool_definitions_json=json.dumps([tool]),
                component='tool_description_apply_edits',
            )
            operations = []
            grades = []

            def host(operation, payload):
                operations.append(operation)
                if operation == 'mcp_begin':
                    return {'output': str(uuid.uuid4())}
                if operation == 'mcp_model':
                    if payload['phase'] == 1:
                        return {'output': json.dumps({
                            'action': 'call_tool',
                            'tool': 'apply_edits',
                            'arguments': {
                                'path': 'README.md',
                                'search': marker,
                                'replace': 'UPDATED_BY_EXPERIMENT',
                            },
                        })}
                    self.assertIn('edits_applied', json.dumps(payload['messages']))
                    return {'output': 'edit complete'}
                if operation == 'mcp_grade':
                    grades.append(payload)
                    mutation = payload['trace']['project_mutation']
                    return {
                        'ok': True,
                        'score': float(
                            mutation['source_snapshot_unchanged']
                            and mutation['changed_paths'] == ['README.md']
                        ),
                        'feedback': 'isolated edit checked',
                        'output': json.dumps(payload['trace']),
                    }
                self.fail(operation)

            result = evaluate_mcp(
                'Use apply_edits for the requested replacement.',
                example,
                body,
                host,
                lambda _: None,
                InfrastructureFailure,
                lambda _: None,
            )
            self.assertEqual(result['score'], 1.0)
            self.assertEqual(
                operations,
                ['mcp_begin', 'mcp_model', 'mcp_model', 'mcp_grade'],
            )
            self.assertEqual(
                Path(body['mcp_adapter']['project_root'], 'README.md').read_text(),
                marker,
            )
            self.assertEqual(
                grades[0]['trace']['project_mutation']['changed_paths'],
                ['README.md'],
            )

    def test_expected_apply_edits_error_reaches_grader_as_evidence(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-expected-error-') as directory:
            body, marker, example = self.setup_trial(directory)
            definitions = json.loads(
                (ROOT / 'docs/spec/mcp-domain-canonical-tool-definitions.generated.json').read_text()
            )['tools']
            tool = next(t for t in definitions if t['name'] == 'apply_edits')
            body['mcp_adapter'].update(
                tool_names=['apply_edits'],
                tool_definitions_json=json.dumps([tool]),
                component='tool_description_apply_edits',
            )
            grades = []

            def host(operation, payload):
                if operation == 'mcp_begin':
                    return {'output': str(uuid.uuid4())}
                if operation == 'mcp_model':
                    if payload['phase'] == 1:
                        return {'output': json.dumps({
                            'action': 'call_tool',
                            'tool': 'apply_edits',
                            'arguments': {
                                'path': 'README.md',
                                'search': 'INTENTIONALLY_ABSENT_TEXT',
                                'replace': 'SHOULD_NOT_APPEAR',
                            },
                        })}
                    return {'output': 'No change: the requested search text was absent.'}
                if operation == 'mcp_grade':
                    grades.append(payload)
                    tool_result = payload['trace']['tool_calls'][0]['result']
                    mutation = payload['trace']['project_mutation']
                    return {
                        'ok': True,
                        'score': float(
                            not payload['candidate_failure']
                            and tool_result['isError']
                            and mutation['changed_paths'] == []
                            and mutation['source_snapshot_unchanged']
                        ),
                        'feedback': 'expected tool error graded from evidence',
                        'output': json.dumps(payload['trace']),
                    }
                self.fail(operation)

            result = evaluate_mcp(
                'Attempt the exact edit and report an absent search honestly.',
                example,
                body,
                host,
                lambda _: None,
                InfrastructureFailure,
                lambda _: None,
            )
            self.assertEqual(result['score'], 1.0)
            self.assertFalse(grades[0]['candidate_failure'])
            self.assertTrue(grades[0]['trace']['tool_calls'][0]['result']['isError'])
            self.assertEqual(
                Path(body['mcp_adapter']['project_root'], 'README.md').read_text(),
                marker,
            )

    def test_source_response_above_asyncio_default_limit_reaches_grading_intact(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-large-response-') as directory:
            body, marker, example = self.setup_trial(directory)
            # Valid tool output, not a malformed protocol or bad candidate. The
            # tail marker proves the boundary does not silently truncate evidence.
            contents = ('source context ' * 6000) + marker
            Path(body['mcp_adapter']['project_root'], 'README.md').write_text(contents)
            result, operations, _, grades = self.run_trial(body, marker, example)
            self.assertEqual(result['score'], 1.0)
            self.assertEqual(operations, ['mcp_begin', 'mcp_model', 'mcp_model', 'mcp_grade'])
            response = grades[0]['trace']['tool_calls'][0]['result']
            self.assertGreater(len(json.dumps(response).encode()), 65536)
            self.assertIn(contents, json.dumps(response))
            self.assertFalse(ACTIVE_CHILDREN)

    def test_response_size_bound_fails_before_models_and_reaps_server(self):
        with tempfile.TemporaryDirectory(prefix='rpce-mcp-response-bound-') as directory:
            body, _, example = self.setup_trial(directory)
            operations = []
            def host(op, payload):
                operations.append(op)
                self.assertEqual(op, 'mcp_begin')
                return {'output': str(uuid.uuid4())}
            # The schema listing alone exceeds this deliberately tiny test limit.
            with patch('mcp_evaluation.MAX_MCP_RESPONSE_BYTES', 1024):
                with self.assertRaisesRegex(InfrastructureFailure, 'MCP transport failed'):
                    evaluate_mcp('Read the file.', example, body, host, lambda _: None,
                                 InfrastructureFailure, lambda _: None)
            self.assertEqual(operations, ['mcp_begin'])
            self.assertFalse(ACTIVE_CHILDREN)

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
                        max_evaluations=12,max_provider_retries=1,
                        stop_at_score=1.0,perfect_score=1.0)
            leases={}; operations=[]; events=[]; completed=None
            failed_second_pass = False
            failed_second_pass_identity = None
            retried_second_pass = False
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
                        if op=='reflect':
                            serialized_prompt = json.dumps(payload['prompt'])
                            self.assertIn('RPCE MCP PROMPT COMPOSITION CONTRACT', serialized_prompt)
                            self.assertIn(MUTABLE_COMPONENT_SENTINEL_PREFIX, serialized_prompt)
                            self.assertIn('Input Schema:', serialized_prompt)
                            reply['output']='```\nRead the requested evidence with read_file.\n```'
                        elif op=='mcp_begin':
                            lease=str(uuid.uuid4());leases[lease]=payload['candidate'];reply['output']=lease
                        elif op=='mcp_model':
                            candidate=leases[payload['evaluation_id']]
                            if payload['phase']==1:
                                reply['output']=json.dumps({'action':'call_tool','tool':'read_file','arguments':{'path':'README.md'}}) if candidate.startswith('Read') else json.dumps({'action':'answer','answer':'guess'})
                            elif not failed_second_pass:
                                failed_second_pass = True
                                failed_second_pass_identity = (payload['evaluation_id'], payload['phase'])
                                reply.update(ok=False, failure_kind='infrastructure',
                                             failure_code='provider_transport_interrupted',
                                             error='safe provider failure')
                            else:
                                if (payload['evaluation_id'], payload['phase']) == failed_second_pass_identity:
                                    retried_second_pass = True
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
                    self.assertTrue(completed['pareto_frontier_indices'])
                    self.assertEqual(
                        len(completed['candidate_prompt_surfaces']),
                        len(completed['candidates']),
                    )
                    self.assertIn('reflect',operations)
                    self.assertTrue(failed_second_pass)
                    self.assertTrue(retried_second_pass)
                    retries = [event for event in events if event['type'] == 'provider_retry']
                    self.assertEqual(len(retries), 1)
                    self.assertEqual(retries[0]['operation'], 'mcp_model')
                    self.assertEqual(retries[0]['failure_code'], 'provider_transport_interrupted')
                    repeated = [event for event in events
                                if event['type'] == 'host_request'
                                and event['operation'] == 'mcp_model'
                                and (event['payload']['evaluation_id'], event['payload']['phase'])
                                == failed_second_pass_identity]
                    self.assertEqual(len(repeated), 2)
                    self.assertEqual(repeated[0]['logical_callback_id'], repeated[1]['logical_callback_id'])
                    successful = [e for e in completed['evaluations'] if 'tool_completed' in e['output']]
                    self.assertTrue(successful)
                    for evaluation in successful:
                        trace = json.loads(evaluation['output'])
                        self.assertEqual(len(trace['tool_calls']), 1, 'provider retry must not repeat the tool')
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
