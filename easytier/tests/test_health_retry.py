"""Bounded retries and evidence capture must precede rollback, never fake online success."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

P=Path(__file__).resolve().parents[1]/'easytier-cf-debian.py'
spec=importlib.util.spec_from_file_location('health_retry_tests',P)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class HealthTests(unittest.TestCase):
    def clock(self):
        clock=[0.0]
        return clock,lambda:clock[0],lambda delay:clock.__setitem__(0,clock[0]+delay)

    def test_health_retries_cli_timeout_and_requires_connector_array(self):
        clock,now,pause=self.clock()
        replies=iter([m.CommandTimeout('probe timeout'),None,{'bad':'not array'},[]])
        def run(args,**kw):
            if args[0]=='systemctl':return subprocess.CompletedProcess(args,0,'active\n','')
            answer=next(replies)
            self.assertIn('-n',args);self.assertIn('cf-mesh',args)
            self.assertEqual(args[-2:],['connector','list'])
            self.assertEqual(kw['timeout'],4)
            if isinstance(answer,Exception):raise answer
            return subprocess.CompletedProcess(args,0,json.dumps(answer),'')
        with mock.patch.object(m,'run',side_effect=run),mock.patch.object(m,'load_state',return_value={'role':'client'}),mock.patch.object(m.time,'monotonic',side_effect=now),mock.patch.object(m.time,'sleep',side_effect=pause),contextlib.redirect_stdout(io.StringIO()):
            m.health()
        self.assertEqual(clock[0],3)

    def test_health_has_outer_deadline_not_first_timeout_failure(self):
        clock,now,pause=self.clock();attempts=[]
        def run(args,**kw):
            if args[0]=='systemctl':return subprocess.CompletedProcess(args,0,'active\n','')
            attempts.append(kw['timeout']);clock[0]+=kw['timeout'];raise m.CommandTimeout('timeout')
        with mock.patch.object(m,'run',side_effect=run),mock.patch.object(m.time,'monotonic',side_effect=now),mock.patch.object(m.time,'sleep',side_effect=pause),contextlib.redirect_stdout(io.StringIO()),self.assertRaises(m.SetupError) as caught:
            m.health()
        self.assertGreaterEqual(len(attempts),2);self.assertGreaterEqual(clock[0],30);self.assertLessEqual(clock[0],30.1)
        self.assertIn('本机服务/RPC',str(caught.exception))

    def test_server_needs_gateway_health_in_addition_to_core(self):
        clock,now,pause=self.clock()
        with mock.patch.object(m,'run',return_value=subprocess.CompletedProcess([],0,'active','')),mock.patch.object(m,'cli_query',return_value=[]),mock.patch.object(m,'load_state',return_value={'role':'server','gateway_version':3}),mock.patch.object(m,'control_call',side_effect=[m.SetupError('not ready'),{'gateway_version':3}]) as control,mock.patch.object(m.time,'monotonic',side_effect=now),mock.patch.object(m.time,'sleep',side_effect=pause),contextlib.redirect_stdout(io.StringIO()):
            m.health()
        self.assertEqual(control.call_count,2)

    def test_peer_timeout_is_advisory_and_bounded(self):
        clock,now,pause=self.clock()
        def query(*args,**kw):clock[0]+=kw['timeout'];raise m.CommandTimeout('timeout')
        with mock.patch.object(m,'cli_query',side_effect=query),mock.patch.object(m,'load_state',return_value={'role':'client','ip':'10.66.66.2/24'}),mock.patch.object(m.time,'monotonic',side_effect=now),mock.patch.object(m.time,'sleep',side_effect=pause):
            result=m.peer_check()
        self.assertIn('本地安装保留',result);self.assertNotIn('已连接',result);self.assertLessEqual(clock[0],12.1)

    def test_manual_enrollment_does_not_require_server_hostname_vps(self):
        with mock.patch.object(m,'load_state',return_value={'role':'client','server_name':'vps','ip':'10.66.66.2/24'}),mock.patch.object(m,'cli_query',return_value=[{'cost':'Local','hostname':'my-client','tunnel_proto':'-','ipv4':'10.66.66.2'},{'cost':'1','hostname':'custom-server','tunnel_proto':'wss','ipv4':'10.66.66.1'}]):
            self.assertIn('WSS peer 已连接',m.peer_check())

    def test_failure_evidence_is_private_bounded_and_redacted(self):
        secret='x'*54;token='c'*64
        raw='network_secret = "'+secret+'"\nhttps://mesh.test/join/'+token+'\n'+('log'*30000)
        def run(args,**kw):return subprocess.CompletedProcess(args,1,raw,'')
        with tempfile.TemporaryDirectory() as td,mock.patch.object(m,'read_secret_from_config',return_value=secret),mock.patch.object(m,'run',side_effect=run),contextlib.redirect_stderr(io.StringIO()):
            target=m.capture_failure_diagnostics(Path(td),m.CommandTimeout('probe timeout'))
            self.assertEqual(target.stat().st_mode&0o777,0o600)
            output=target.read_text();self.assertNotIn(secret,output);self.assertNotIn(token,output)
            data=json.loads(output);self.assertIn('journal',data)
            self.assertLessEqual(len(data['journal']['stdout']),65536)

    def test_failed_install_captures_evidence_before_rollback(self):
        text=P.read_text();start=text.index('def install(');end=text.index('def cli_query(',start)
        failure=text[start:end].split('except Exception as exc:',1)[1]
        self.assertLess(failure.index('capture_failure_diagnostics'),failure.index('rollback(bak)'))


if __name__=='__main__':unittest.main()
