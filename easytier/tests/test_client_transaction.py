"""Client install lifecycle regression with real download/staging, mocked host service."""
import contextlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest import mock

import test_download_transaction as fixtures
import test_lifecycle as lifecycle

P=Path(__file__).resolve().parents[1]/'easytier-cf-debian.py'
spec=importlib.util.spec_from_file_location('client_transaction_regression',P)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class ClientTransactionTests(unittest.TestCase):
    def setup_install(self,td,stack):
        paths=lifecycle.LifecycleTests().setup_paths(td,stack)
        for key,value in paths.items():stack.enter_context(mock.patch.object(m,key,value))
        managed=tuple(paths[k] for k in ('CFG','STATE','CORE','CLI','SCRIPT','UNIT_FILE'))
        stack.enter_context(mock.patch.object(m,'MANAGED',managed))
        # First install, not a pre-existing instance: leave just bootstrap script.
        for path in managed:
            if path!=paths['SCRIPT']:path.unlink()
        paths['UNIT_LINK'].unlink();paths['COMMAND'].unlink()
        paths['SCRIPT'].write_bytes(P.read_bytes())
        payload,rel=fixtures.release_zip()
        stack.enter_context(mock.patch.object(m,'env_check'))
        stack.enter_context(mock.patch.object(m,'svc_state',return_value={'active':False,'enabled':False}))
        stack.enter_context(mock.patch.object(m.urllib.request,'urlopen',return_value=__import__('io').BytesIO(payload)))
        config=dict(role='client',name='client',ip='10.66.66.2/24',domain='mesh.example.test',network='test',secret='s'*54,subnet='10.66.66.0/24',server_name='custom-server')
        stack.enter_context(mock.patch.object(m,'get_config',return_value=config))
        stack.enter_context(mock.patch.object(m,'run',side_effect=lambda argv,**kw:subprocess.CompletedProcess(argv,0,'easytier-core 2.6.4' if '--version' in argv else '', '')))
        args=types.SimpleNamespace(dry_run=False,update=False,join=None,no_prompt=False)
        return paths,args,rel

    def test_failed_local_rpc_keeps_evidence_before_rollback_removes_binary(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            paths,args,rel=self.setup_install(td,stack)
            events=[];original=m.rollback
            def health():
                self.assertTrue(paths['CORE'].is_file());events.append('health')
                raise m.SetupError('RPC not ready')
            def evidence(backup,reason):
                self.assertTrue(paths['CORE'].is_file());self.assertTrue(paths['CLI'].is_file())
                events.append('evidence');return m.atom(Path(backup)/'fixture-diagnostics.json','{}')
            def rollback(backup):events.append('rollback');return original(backup)
            stack.enter_context(mock.patch.object(m,'health',side_effect=health))
            stack.enter_context(mock.patch.object(m,'capture_failure_diagnostics',side_effect=evidence))
            stack.enter_context(mock.patch.object(m,'rollback',side_effect=rollback))
            with self.assertRaisesRegex(m.SetupError,'RPC not ready'):m.install(args,rel)
            self.assertEqual(events,['health','evidence','rollback'])
            self.assertFalse(paths['CORE'].exists());self.assertFalse(paths['CLI'].exists())
            self.assertTrue(any((path/'fixture-diagnostics.json').exists() for path in paths['BACKUPS'].iterdir()))

    def test_peer_check_timeout_after_local_success_does_not_rollback(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            paths,args,rel=self.setup_install(td,stack)
            stack.enter_context(mock.patch.object(m,'health'))
            stack.enter_context(mock.patch.object(m,'peer_check',side_effect=m.CommandTimeout('probe timeout')))
            rollback=stack.enter_context(mock.patch.object(m,'rollback'))
            m.install(args,rel)
            rollback.assert_not_called()
            self.assertTrue(paths['CORE'].is_file());self.assertTrue(paths['CLI'].is_file())
            self.assertEqual(json.loads(paths['STATE'].read_text())['role'],'client')
            self.assertTrue(paths['COMMAND'].is_symlink())

if __name__=='__main__':unittest.main()
