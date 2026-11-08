import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock

P=Path(__file__).resolve().parents[1]/'easytier-cf-debian.py'
spec=importlib.util.spec_from_file_location('installer_port_tests',P)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


def args(**kw):
    data=dict(join=None,join_link=None,role='server',name='vps',ip='10.66.66.1/24',domain='mesh.example.test',network='testnet',listen_port=None,no_prompt=False,update=False,dry_run=False)
    data.update(kw);return types.SimpleNamespace(**data)

class ManagementTests(unittest.TestCase):
    def test_port_is_prompted_and_rendered(self):
        with mock.patch('builtins.input',return_value='23456') as prompt:
            s=m.get_config(args(),None,'v2.6.4')
        self.assertIn('回源端口',prompt.call_args.args[0]);self.assertEqual(s['listen_port'],23456)
        self.assertIn('ws://127.0.0.1:23456',m.render(s,'v2.6.4'))
        self.assertNotIn('ws://127.0.0.1:11011',m.render(s,'v2.6.4'))

    def test_invalid_ports_rejected(self):
        for value in (-1,0,65536,15888,True,'abc'):
            with self.subTest(value=value), self.assertRaises(m.SetupError): m.parse_port(value)

    def test_upgrade_keeps_existing_port_or_explicitly_changes(self):
        with tempfile.TemporaryDirectory() as td:
            cfg=Path(td)/'config.toml';cfg.write_text('network_secret = "'+'s'*54+'"\nlisteners=["ws://127.0.0.1:34567"]\n')
            old=dict(role='server',name='vps',ip='10.66.66.1/24',domain='mesh.example.test',network='testnet',subnet='10.66.66.0/24',server_name='vps',listen_port=34567)
            with mock.patch.object(m,'CFG',cfg):
                self.assertEqual(m.get_config(args(update=True),old,'v2.6.4')['listen_port'],34567)
                self.assertEqual(m.get_config(args(update=True,listen_port=45678),old,'v2.6.4')['listen_port'],45678)
                old.pop('listen_port')
                self.assertEqual(m.get_config(args(update=True),old,'v2.6.4')['listen_port'],34567)

    def test_shortcut_is_symlink_and_refuses_existing_file(self):
        with tempfile.TemporaryDirectory() as td:
            command=Path(td)/'bin/easytier-easy';script=Path(td)/'easytier-cf-debian.py';script.write_text('#! /usr/bin/env python3\n')
            with mock.patch.object(m,'COMMAND',command), mock.patch.object(m,'SCRIPT',script):
                m.install_shortcut();self.assertEqual(command.resolve(),script);m.install_shortcut()
                command.unlink();command.write_text('untouched')
                with self.assertRaises(m.SetupError):m.install_shortcut()
                self.assertEqual(command.read_text(),'untouched')

    def test_installed_menu_quit_does_not_query_or_install(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td)/'settings.json';state.write_text('{}')
            with mock.patch.object(m,'STATE',state),mock.patch.object(m.os,'geteuid',return_value=0),mock.patch.object(m.sys,'argv',['easytier-easy']),mock.patch('builtins.input',return_value='0'),mock.patch.object(m,'latest_release') as latest,mock.patch.object(m,'install') as install:
                self.assertEqual(m.main(),0);latest.assert_not_called();install.assert_not_called()

    def test_fetch_requires_https_valid_host_and_disallows_redirects(self):
        for link in ('http://unsafe.test/join/'+'a'*64,'https://evil.test/join/'+'a'*64,'https://test.trycloudflare.com.evil.test/join/'+'a'*64,'https://test.trycloudflare.com/join/'+'a'*64+'?x=1'):
            with self.subTest(link=link),self.assertRaises(m.SetupError):m.fetch_join_link(link)

if __name__=='__main__':unittest.main()
