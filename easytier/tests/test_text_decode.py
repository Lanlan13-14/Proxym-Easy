"""Exercise actual non-UTF8 child output and binary state removal, without real systemd."""
import contextlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import test_lifecycle as lifecycle

P=Path(__file__).resolve().parents[1]/'easytier-cf-debian.py'
spec=importlib.util.spec_from_file_location('decode_error_tests',P)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class TextDecodeTests(unittest.TestCase):
    def test_child_stdout_and_stderr_invalid_utf8_do_not_crash(self):
        result=m.run([sys.executable,'-c',"import os;os.write(1,b'active\\n\\xff');os.write(2,b'warning\\xfe')"],check=False)
        self.assertEqual(result.returncode,0);self.assertIn('active',result.stdout)
        self.assertIn('\ufffd',result.stdout);self.assertIn('\ufffd',result.stderr)

    def test_invalid_state_is_actionable_error_not_unhandled_unicode(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td)/'settings.json';state.write_bytes(b'\xff\xfe\x00bad');state.chmod(0o600)
            with mock.patch.object(m,'STATE',state),self.assertRaisesRegex(m.SetupError,'UTF-8'):m.load_state()

    def test_uninstall_backs_up_invalid_metadata_and_binary_executables_exactly(self):
        # Reuse isolated path setup only; lifecycle module uses its own imported installer.
        import test_lifecycle as other
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            paths=lifecycle.LifecycleTests().setup_paths(td,stack)
            for key,value in paths.items():stack.enter_context(mock.patch.object(m,key,value))
            stack.enter_context(mock.patch.object(m,'MANAGED',tuple(paths[k] for k in ('CFG','STATE','CORE','CLI','GATEWAY','SCRIPT','UNIT_FILE'))))
            corrupt=b'\xff\xfe\x00invalid-state';binary=b'\x7fELF\x00\xff\xfe\xa0'
            paths['STATE'].write_bytes(corrupt);paths['CORE'].write_bytes(binary);paths['CLI'].write_bytes(binary+b'cli')
            paths['UNIT_FILE'].write_bytes(m.MARK.encode()+b'\n# non-utf8 comment \xff\n')
            stack.enter_context(mock.patch('builtins.input',return_value='UNINSTALL'))
            calls=[]
            def run(args,**kwargs):
                calls.append(args)
                if args[:2]==['systemctl','is-active']:
                    # Real subprocess with invalid localized output exercises decoding in snapshot.
                    return m_run([sys.executable,'-c',"import os;os.write(1,b'inactive\\n');os.write(2,b'localized\\xff')"],**kwargs)
                if args[:2]==['systemctl','is-enabled']:
                    return m_run([sys.executable,'-c',"import os;os.write(1,b'disabled\\n');os.write(2,b'localized\\xfe')"],**kwargs)
                return m_run([sys.executable,'-c','pass'],**kwargs)
            m_run=m.run
            stack.enter_context(mock.patch.object(m,'run',side_effect=run))
            m.uninstall()
            backup=next(paths['BACKUPS'].iterdir())
            self.assertEqual((backup/'files/settings.json').read_bytes(),corrupt)
            self.assertEqual((backup/'files/easytier-core').read_bytes(),binary)
            self.assertFalse(paths['STATE'].exists());self.assertFalse(paths['COMMAND'].exists())
            self.assertTrue(any(x[:2]==['systemctl','stop'] for x in calls))
            self.assertTrue(all('cloudflared' not in x for x in calls))

if __name__=='__main__':unittest.main()
