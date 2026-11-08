"""Exercise the production download and first-install paths, including mkdtemp regression."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest import mock
import zipfile

SCRIPT=Path(__file__).resolve().parents[1]/'easytier-cf-debian.py'
spec=importlib.util.spec_from_file_location('installer_transaction_tests',SCRIPT)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


def release_zip():
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w') as z:
        z.writestr('easytier-linux-aarch64/easytier-core',b'core-fixture')
        z.writestr('easytier-linux-aarch64/easytier-cli',b'cli-fixture')
    data=out.getvalue()
    return data,dict(tag='v2.6.4',arch='aarch64',asset='easytier-test.zip',url='https://example.test/asset.zip',size=len(data),digest=hashlib.sha256(data).hexdigest())


class DownloadTransactionTests(unittest.TestCase):
    def fake_run(self,argv,**kwargs):
        return subprocess.CompletedProcess(argv,0,'easytier-core 2.6.4' if '--version' in argv else '', '')

    def test_download_accepts_existing_mkdtemp_and_checks_hash(self):
        data,rel=release_zip()
        with tempfile.TemporaryDirectory() as td:
            temp=Path(td)/'tmp';temp.mkdir();stage=Path(tempfile.mkdtemp(prefix='stage-',dir=temp))
            with mock.patch.object(m,'TMP',temp),mock.patch.object(m.urllib.request,'urlopen',return_value=io.BytesIO(data)),mock.patch.object(m,'run',side_effect=self.fake_run):
                core,cli=m.download(rel,stage)
            self.assertEqual(core.read_bytes(),b'core-fixture');self.assertEqual(cli.read_bytes(),b'cli-fixture')
            self.assertEqual(core.stat().st_mode&0o777,0o755)

    def test_download_refuses_nonempty_stage_before_network(self):
        data,rel=release_zip()
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);stage=root/'stage';stage.mkdir();(stage/'sentinel').write_text('keep')
            with mock.patch.object(m,'TMP',root),mock.patch.object(m.urllib.request,'urlopen') as fetch,self.assertRaises(m.SetupError):m.download(rel,stage)
            fetch.assert_not_called();self.assertEqual((stage/'sentinel').read_text(),'keep')

    def test_download_refuses_stage_symlink_before_network(self):
        data,rel=release_zip()
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);dest=root/'dest';dest.mkdir();stage=root/'stage';stage.symlink_to(dest)
            with mock.patch.object(m,'TMP',root),mock.patch.object(m.urllib.request,'urlopen') as fetch,self.assertRaises(m.SetupError):m.download(rel,stage)
            fetch.assert_not_called()

    def test_hash_failure_is_reported_before_extraction(self):
        data,rel=release_zip();rel['digest']='0'*64
        with tempfile.TemporaryDirectory() as td:
            temp=Path(td)/'tmp';stage=temp/'stage'
            with mock.patch.object(m,'TMP',temp),mock.patch.object(m.urllib.request,'urlopen',return_value=io.BytesIO(data)),self.assertRaisesRegex(m.SetupError,'SHA-256'):m.download(rel,stage)
            self.assertFalse((stage/'bin').exists())

    def test_real_install_transaction_reaches_state_unit_and_shortcut(self):
        data,rel=release_zip()
        s=dict(role='server',name='vps',ip='10.66.66.1/24',domain='mesh.example.test',network='test-net',secret='s'*54,subnet='10.66.66.0/24',server_name='vps',listen_port=22222)
        args=types.SimpleNamespace(dry_run=False,update=False,join=None,no_prompt=False)
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)/'etc/easytier';root.mkdir(parents=True)
            paths=dict(ROOT=root,BACKUPS=root/'backups',TMP=root/'tmp',CORE=root/'easytier-core',CLI=root/'easytier-cli',CFG=root/'config.toml',STATE=root/'settings.json',JOIN=root/'join.json',SCRIPT=root/'easytier-cf-debian.py',UNIT_FILE=root/'easytier-cf.service',UNIT_LINK=Path(td)/'systemd/easytier-cf.service',COMMAND=Path(td)/'bin/easytier-easy')
            paths['UNIT_LINK'].parent.mkdir();paths['SCRIPT'].write_bytes(SCRIPT.read_bytes())
            managed=tuple(paths[k] for k in ('CFG','STATE','CORE','CLI','SCRIPT','UNIT_FILE'))
            import contextlib
            with contextlib.ExitStack() as stack:
                for key,value in paths.items():stack.enter_context(mock.patch.object(m,key,value))
                stack.enter_context(mock.patch.object(m,'MANAGED',managed))
                stack.enter_context(mock.patch.object(m,'env_check'))
                stack.enter_context(mock.patch.object(m,'svc_state',return_value={'active':False,'enabled':False}))
                stack.enter_context(mock.patch.object(m,'get_config',return_value=s))
                stack.enter_context(mock.patch.object(m,'health'))
                stack.enter_context(mock.patch.object(m,'run',side_effect=self.fake_run))
                stack.enter_context(mock.patch.object(m.urllib.request,'urlopen',return_value=io.BytesIO(data)))
                stack.enter_context(mock.patch.object(m,'rollback'))
                m.install(args,rel)
                self.assertEqual(json.loads(paths['STATE'].read_text())['listen_port'],22222)
                self.assertIn('ws://127.0.0.1:22222',paths['CFG'].read_text())
                self.assertEqual(paths['UNIT_LINK'].resolve(),paths['UNIT_FILE'])
                self.assertEqual(paths['COMMAND'].resolve(),paths['SCRIPT'])
                self.assertFalse(paths['JOIN'].exists())
                self.assertEqual(list(paths['TMP'].iterdir()),[])
                m.rollback.assert_not_called()

if __name__=='__main__':unittest.main()
