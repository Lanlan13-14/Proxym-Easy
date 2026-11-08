"""Tests for non-secret origin proof and safely preserving ACL-blocked clients."""
import contextlib
import http.client
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import types
import unittest
from unittest import mock

P=Path(__file__).resolve().parents[1]/'easytier-cf-debian.py'
spec=importlib.util.spec_from_file_location('route_proof_regression',P)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class RouteProofTests(unittest.TestCase):
    def test_real_http_proof_never_consumes_invitation(self):
        gateway=m.build_gateway(0,1);t=threading.Thread(target=gateway.serve_forever,daemon=True);t.start()
        payload=dict(format='easytier-cf-join-v1',domain='mesh.example.test',network='test',secret='s'*54,subnet='10.20.0.0/24',server_name='vps')
        token=gateway.grant.issue(payload)['token'];nonce='b'*32
        try:
            instance=m.probe_tunnel_endpoint('http://127.0.0.1:'+str(gateway.server_port)+'/join/check/'+nonce,nonce)
            self.assertEqual(instance,gateway.instance_id);self.assertEqual(gateway.grant.status(token),'active')
            connection=http.client.HTTPConnection('127.0.0.1',gateway.server_port,timeout=3)
            connection.request('POST','/join/'+token,body=b'',headers={'X-EasyTier-Join':'1'})
            r=connection.getresponse();self.assertEqual(r.status,200);self.assertEqual(json.loads(r.read()),payload);connection.close()
        finally:gateway.shutdown();gateway.server_close();t.join(2)

    def test_check_binds_local_and_public_to_same_instance(self):
        local=dict(ok=True,domain='mesh.example.test',port=22333,instance_id='a'*32)
        state=dict(role='server',domain=local['domain'])
        with mock.patch.object(m,'load_state',return_value=state),mock.patch.object(m.os,'geteuid',return_value=0),mock.patch.object(m,'control_call',return_value=local),mock.patch.object(m,'probe_tunnel_endpoint',side_effect=['a'*32,'a'*32]) as probe:
            self.assertEqual(m.check_tunnel(),local)
        self.assertIn('http://127.0.0.1:22333',probe.call_args_list[0].args[0])
        self.assertIn('https://mesh.example.test',probe.call_args_list[1].args[0])
        with mock.patch.object(m,'load_state',return_value=state),mock.patch.object(m.os,'geteuid',return_value=0),mock.patch.object(m,'control_call',return_value=local),mock.patch.object(m,'probe_tunnel_endpoint',side_effect=['a'*32,'c'*32]):
            with self.assertRaisesRegex(m.SetupError,'其他网关实例'):m.check_tunnel()

    def test_invalid_origin_prevents_new_token_issue(self):
        with mock.patch.object(m,'load_state',return_value={'role':'server'}),mock.patch.object(m.os,'geteuid',return_value=0),mock.patch.object(m,'check_tunnel',side_effect=m.SetupError('empty 200')),mock.patch.object(m,'control_call') as control:
            with self.assertRaisesRegex(m.SetupError,'empty 200'):m.issue_join_link()
            control.assert_not_called()

    def test_empty_or_forged_response_never_passes(self):
        opener=mock.Mock();reply=mock.MagicMock();opener.open.return_value=reply
        for raw in (b'',b'{}',json.dumps({'format':'easytier-cf-gateway-v1','nonce':'wrong','instance_id':'a'*32}).encode()):
            reply.__enter__.return_value.read.return_value=raw
            with self.subTest(raw=raw),mock.patch.object(m.urllib.request,'build_opener',return_value=opener),self.assertRaises(m.SetupError):m.probe_tunnel_endpoint('https://mesh.example.test/join/check/'+'b'*32,'b'*32)

class BlockedManagementTests(unittest.TestCase):
    def test_no_state_is_not_an_excuse_to_accept_failed_rpc(self):
        with mock.patch.object(m,'load_state',return_value=None):self.assertFalse(m.client_management_blocked())
        with mock.patch.object(m,'load_state',return_value={'role':'server'}):self.assertFalse(m.client_management_blocked())

    def test_active_tun_and_owned_core_required_for_acl_degradation(self):
        with tempfile.TemporaryDirectory() as td:
            base=Path(td);core=base/'core';core.write_text('binary');cfg=base/'config.toml';cfg.write_text('fixture')
            process=base/'proc';(process/'net').mkdir(parents=True);(process/'fd').mkdir()
            (process/'exe').symlink_to(core)
            # Explicit NUL delimiters, including before the numeric portal address.
            (process/'cmdline').write_bytes(b'core\0-c\0'+str(cfg).encode()+b'\0--rpc-portal\0'+b'127.0.0.1:15888\0')
            (process/'net/tcp').write_text('header\n0: 0100007F:3E10 00000000:0000 0A 0 0 0 0 0 99\n')
            (process/'fd/9').symlink_to('socket:[99]')
            original=m.Path
            # Path('/proc')/pid needs an intermediate directory in the fixture.
            root=base/'virtualproc';root.mkdir();(root/'55').symlink_to(process,target_is_directory=True)
            def path(value):return root if str(value)=='/proc' else original(value)
            def run(argv,**kw):
                if argv[0]=='systemctl':out='MainPID=55\nActiveState=active\nSubState=running\n'
                elif argv[0]=='ip':out=json.dumps([{'flags':['UP'],'addr_info':[{'family':'inet','local':'10.20.0.2','prefixlen':24}]}])
                else:out='Rpc portal client IP 10.42.3.85 not in whitelist: [V4(127.0.0.0/8)], ignoring client.'
                return types.SimpleNamespace(returncode=0,stdout=out)
            with mock.patch.object(m,'Path',side_effect=path),mock.patch.object(m,'CORE',core),mock.patch.object(m,'CFG',cfg),mock.patch.object(m,'load_state',return_value={'role':'client','ip':'10.20.0.2/24'}),mock.patch.object(m,'run',side_effect=run):
                self.assertTrue(m.client_management_blocked())
                (process/'fd/9').unlink();self.assertFalse(m.client_management_blocked())

    def test_final_rpc_timeout_degrades_only_when_independent_proof_passes(self):
        for allowed in (True,False):
            with self.subTest(allowed=allowed),mock.patch.object(m.time,'monotonic',side_effect=[0,31]),mock.patch.object(m,'client_management_blocked',return_value=allowed):
                if allowed:self.assertEqual(m.health(),'management-blocked')
                else:
                    with self.assertRaises(m.SetupError):m.health()

if __name__=='__main__':unittest.main()
