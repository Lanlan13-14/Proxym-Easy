"""Safe local-filesystem migration/uninstall tests; systemd calls are mocked."""
import contextlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

P=Path(__file__).resolve().parents[1]/'easytier-cf-debian.py'
spec=importlib.util.spec_from_file_location('lifecycle_test_module',P)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class LifecycleTests(unittest.TestCase):
    def setup_paths(self,td,stack):
        root=Path(td)/'etc/easytier';root.mkdir(parents=True)
        paths=dict(ROOT=root,BACKUPS=root/'backups',TMP=root/'tmp',CORE=root/'easytier-core',CLI=root/'easytier-cli',CFG=root/'config.toml',STATE=root/'settings.json',JOIN=root/'join.json',SCRIPT=root/'easytier-cf-debian.py',UNIT_FILE=root/'easytier-cf.service',UNIT_LINK=Path(td)/'systemd/easytier-cf.service',COMMAND=Path(td)/'bin/easytier-easy')
        for name,value in paths.items():stack.enter_context(mock.patch.object(m,name,value))
        managed=tuple(paths[k] for k in ('CFG','STATE','CORE','CLI','SCRIPT','UNIT_FILE'))
        stack.enter_context(mock.patch.object(m,'MANAGED',managed))
        stack.enter_context(mock.patch.object(m.os,'geteuid',return_value=0))
        for path in managed:path.write_text('old-file')
        paths['UNIT_FILE'].write_text(m.MARK+'\nold-service')
        state=dict(format='easytier-cf-state-v1',role='server',name='server',ip='10.66.66.1/24',domain='mesh.example.test',network='test',subnet='10.66.66.0/24',server_name='server',version='v2.6.4',listen_port=22222)
        paths['STATE'].write_text(json.dumps(state));paths['STATE'].chmod(0o600)
        paths['CFG'].write_text('network_secret="'+'s'*54+'"\nlisteners=["ws://127.0.0.1:22222"]\n')
        paths['UNIT_LINK'].parent.mkdir(parents=True);paths['UNIT_LINK'].symlink_to(paths['UNIT_FILE'])
        paths['COMMAND'].parent.mkdir(parents=True);paths['COMMAND'].symlink_to(paths['SCRIPT'])
        return paths

    def run_ok(self,argv,**kw):return subprocess.CompletedProcess(argv,0,'','')

    def test_uninstall_cancel_has_no_system_or_file_changes(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            paths=self.setup_paths(td,stack)
            stack.enter_context(mock.patch('builtins.input',return_value='no'))
            run=stack.enter_context(mock.patch.object(m,'run'))
            m.uninstall();run.assert_not_called();self.assertTrue(paths['STATE'].exists());self.assertFalse(paths['BACKUPS'].exists())

    def test_uninstall_backs_up_then_removes_only_managed_files(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            paths=self.setup_paths(td,stack)
            unknown=paths['ROOT']/'user-file';unknown.write_text('keep')
            stack.enter_context(mock.patch('builtins.input',return_value='UNINSTALL'))
            run=stack.enter_context(mock.patch.object(m,'run',side_effect=self.run_ok))
            stack.enter_context(mock.patch.object(m,'svc_state',return_value={'active':False,'enabled':False}))
            m.uninstall()
            for key in ('CFG','STATE','CORE','CLI','SCRIPT','UNIT_FILE','UNIT_LINK','COMMAND'):self.assertFalse(paths[key].exists(),key)
            self.assertEqual(unknown.read_text(),'keep')
            backups=list(paths['BACKUPS'].iterdir());self.assertEqual(len(backups),1)
            self.assertIn('s'*54,(backups[0]/'files/config.toml').read_text())
            commands=[x.args[0] for x in run.call_args_list]
            self.assertEqual(commands[0],['systemctl','stop',m.UNIT])
            self.assertTrue(all('cloudflared' not in str(x) for x in commands))

    def test_uninstall_refuses_to_delete_when_stop_fails(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            paths=self.setup_paths(td,stack)
            stack.enter_context(mock.patch('builtins.input',return_value='UNINSTALL'))
            stack.enter_context(mock.patch.object(m,'svc_state',return_value={'active':True,'enabled':True}))
            stack.enter_context(mock.patch.object(m,'run',side_effect=m.SetupError('stop failed')))
            with self.assertRaises(m.SetupError):m.uninstall()
            self.assertTrue(paths['STATE'].exists());self.assertTrue(paths['COMMAND'].is_symlink());self.assertTrue(paths['BACKUPS'].exists())

    def test_repair_preserves_config_binaries_ip_secret_and_origin_port(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            paths=self.setup_paths(td,stack);before={k:paths[k].read_bytes() for k in ('CFG','CORE','CLI')}
            stack.enter_context(mock.patch.object(m,'env_check'))
            stack.enter_context(mock.patch.object(m,'svc_state',return_value={'active':True,'enabled':True}))
            run=stack.enter_context(mock.patch.object(m,'run',side_effect=self.run_ok));health=stack.enter_context(mock.patch.object(m,'health'))
            m.repair_gateway()
            for key,data in before.items():self.assertEqual(paths[key].read_bytes(),data)
            state=json.loads(paths['STATE'].read_text());self.assertEqual(state['listen_port'],22222);self.assertEqual(state['gateway_version'],2)
            self.assertIn('--serve-gateway',paths['UNIT_FILE'].read_text());self.assertEqual(paths['SCRIPT'].read_bytes(),P.read_bytes())
            health.assert_called_once();self.assertIn(mock.call(['systemctl','restart',m.UNIT]),run.call_args_list)
            backup=next(paths['BACKUPS'].iterdir());self.assertEqual((backup/'files/easytier-cf-debian.py').read_text(),'old-file')

    def test_server_and_client_have_different_service_exec(self):
        self.assertIn('--serve-gateway',m.unit_text({'role':'server'}))
        client=m.unit_text({'role':'client'});self.assertNotIn('--serve-gateway',client);self.assertIn(str(m.CORE)+' -c ',client)

if __name__=='__main__':unittest.main()
