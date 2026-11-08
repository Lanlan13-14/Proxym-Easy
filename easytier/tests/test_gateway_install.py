"""Go gateway installer transaction contracts; no real /etc/systemd/network writes.

The production downloader is exercised with in-memory pinned asset responses:
SHA-256, exact size, staging, permissions, ELF/version gates are not bypassed.
Only ELF execution is mocked; synthetic bytes are NEVER release artifacts.
Native data-plane/HTTP integration lives in go_gateway_harness and its callers.
"""
import ast
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

import test_lifecycle as lifecycle
from go_gateway_harness import GoGateway, gateway_binary, read_http_headers

SCRIPT = Path(__file__).resolve().parents[1] / 'easytier-cf-debian.py'
spec = importlib.util.spec_from_file_location('go_gateway_install_regression', SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
MANAGED_NAMES = ('CFG', 'STATE', 'CORE', 'CLI', 'GATEWAY', 'SCRIPT', 'UNIT_FILE')
SECRET = 'MEMFD_ONLY_TEST_SECRET_' + 's' * 48


def elf_fixture(arch='aarch64', size=300_000, dynamic=False):
    raw = bytearray(size)
    raw[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<H', raw, 18, {'aarch64': 183, 'x86_64': 62}[arch])
    struct.pack_into('<Q', raw, 32, 64)
    struct.pack_into('<HH', raw, 54, 56, int(dynamic))
    if dynamic:
        struct.pack_into('<I', raw, 64, 3)
    return bytes(raw)


def pinned_asset(data, arch='aarch64'):
    suffix = 'arm64' if arch == 'aarch64' else 'amd64'
    return {'name': 'easytier-gateway-linux-' + suffix,
            'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}


class GatewayDownloadTests(unittest.TestCase):
    def test_fetch_manifest_is_https_project_actions_go1273_and_two_arch_pinned(self):
        arm=elf_fixture('aarch64'); amd=elf_fixture('x86_64')
        manifest={'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,
                  'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345',
                  'assets':[pinned_asset(arm,'aarch64'),pinned_asset(amd,'x86_64')]}
        manifest_response=mock.MagicMock(); manifest_response.__enter__.return_value.read.return_value=json.dumps(manifest).encode()
        run_response=mock.MagicMock(); run_response.__enter__.return_value.read.return_value=json.dumps({'path':'.github/workflows/build-easytier-gateway.yml','head_sha':'a'*40,'event':'push','head_branch':'main','status':'completed','conclusion':'success'}).encode()
        compare_response=mock.MagicMock(); compare_response.__enter__.return_value.read.return_value=json.dumps({'status':'identical'}).encode()
        with mock.patch.object(m.urllib.request,'urlopen',side_effect=(manifest_response,run_response,compare_response)) as open_url:
            data,assets=m.fetch_gateway_manifest()
        self.assertEqual(open_url.call_args_list[0].args[0].full_url,'https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/easytier/easytier-gateway-build.json')
        self.assertEqual(open_url.call_args_list[0].kwargs,{'timeout':15})
        self.assertEqual(open_url.call_args_list[1].args[0].full_url,'https://api.github.com/repos/Lanlan13-14/Proxym-Easy/actions/runs/12345')
        self.assertEqual(open_url.call_args_list[2].args[0].full_url,'https://api.github.com/repos/Lanlan13-14/Proxym-Easy/compare/'+manifest['commit']+'...main')
        self.assertEqual(open_url.call_count,3)
        self.assertEqual(data['commit'],manifest['commit']); self.assertEqual(set(assets),{'aarch64','x86_64'})
        self.assertEqual(assets['x86_64']['sha256'],hashlib.sha256(amd).hexdigest())

    def test_manifest_rejects_older_go_forged_run_duplicate_arch_and_oversize(self):
        base={'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,
              'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345',
              'assets':[pinned_asset(elf_fixture(),'aarch64'),pinned_asset(elf_fixture('x86_64'),'x86_64')]}
        for mutate in (lambda d:d.update(go='1.22.0'),lambda d:d.update(run='https://evil.example/actions/runs/12345'),
                       lambda d:d.update(commit='g'*40),lambda d:d.update(assets=[d['assets'][0],d['assets'][0]]),
                       lambda d:d.update(assets=[d['assets'][0]])):
            data=json.loads(json.dumps(base));mutate(data)
            manifest_response=mock.MagicMock();manifest_response.__enter__.return_value.read.return_value=json.dumps(data).encode()
            with mock.patch.object(m.urllib.request,'urlopen',return_value=manifest_response):
                with self.assertRaises(m.SetupError):m.fetch_gateway_manifest()
        manifest_response=mock.MagicMock();manifest_response.__enter__.return_value.read.return_value=json.dumps(base).encode()
        run_response=mock.MagicMock();run_response.__enter__.return_value.read.return_value=json.dumps({'path':'.github/workflows/build-easytier-gateway.yml','head_sha':'a'*40,'event':'pull_request','head_branch':'main','status':'completed','conclusion':'success'}).encode()
        with mock.patch.object(m.urllib.request,'urlopen',side_effect=(manifest_response,run_response)):
            with self.assertRaises(m.SetupError):m.fetch_gateway_manifest()
        with mock.patch.object(m.urllib.request,'urlopen') as opened:
            oversized=mock.MagicMock();oversized.__enter__.return_value.read.return_value=b'{'*32769
            opened.return_value=oversized
            with self.assertRaisesRegex(m.SetupError,'大小限制'):m.fetch_gateway_manifest()
            opened.assert_called_once()
            self.assertEqual(opened.call_args.args[0].full_url,m.GATEWAY_MANIFEST_URL)

    def run_download(self, root, data, asset, *, arch='aarch64', version=None):
        stage = Path(root) / 'stage'
        stage.mkdir()
        manifest={'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,
                  'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345',
                  'assets':[pinned_asset(data,'aarch64'),pinned_asset(elf_fixture('x86_64'),'x86_64')]}
        manifest_response=mock.MagicMock();manifest_response.__enter__.return_value.read.return_value=json.dumps(manifest).encode()
        run_data={'path':'.github/workflows/build-easytier-gateway.yml','head_sha':'a'*40,'event':'push','head_branch':'main','status':'completed','conclusion':'success'}
        run_response=mock.MagicMock();run_response.__enter__.return_value.read.return_value=json.dumps(run_data).encode()
        latest=mock.MagicMock();latest.__enter__.return_value.read.return_value=json.dumps({'status':'identical'}).encode()
        with mock.patch.object(m.platform,'machine',return_value=arch), \
             mock.patch.object(m.urllib.request,'urlopen',side_effect=(manifest_response,run_response,latest,io.BytesIO(data))) as fetch, \
             mock.patch.object(m,'run',return_value=subprocess.CompletedProcess([],0,version or 'easytier-gateway '+m.GATEWAY_VERSION+'\n','')) as run:
            target,returned_manifest=m.download_gateway(stage)
        self.assertEqual(returned_manifest['_validated_run']['head_sha'],manifest['commit'])
        return target,fetch,run

    def test_pinned_hash_size_elf_version_permissions_and_actions_url(self):
        for machine, arch in (('aarch64', 'aarch64'), ('arm64', 'aarch64'), ('x86_64', 'x86_64')):
            with self.subTest(machine=machine), tempfile.TemporaryDirectory() as td:
                data = elf_fixture(arch)
                asset = pinned_asset(data, arch)
                target,fetch,run=self.run_download(td,data,asset,arch=machine)
                self.assertEqual(target.read_bytes(), data)
                self.assertEqual(target.stat().st_mode & 0o777, 0o755)
                self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(target.name, 'easytier-gateway')
                request = fetch.call_args.args[0]
                self.assertIn(request.full_url, ('https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/easytier/easytier-gateway-linux-amd64', 'https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/main/easytier/easytier-gateway-linux-arm64'))
                self.assertEqual(request.get_header('Accept'), 'application/octet-stream')
                run.assert_called_once()
                self.assertEqual(run.call_args.args[0][1:], ['--version'])

    def test_unpinned_assets_fail_closed_before_network(self):
        data = elf_fixture()
        manifest={'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,
                  'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345',
                  'assets':[pinned_asset(data,'aarch64'),pinned_asset(elf_fixture('x86_64'),'x86_64')]}
        with tempfile.TemporaryDirectory() as td, mock.patch.object(m, 'fetch_gateway_manifest', return_value=(manifest,{})), \
             mock.patch.object(m.urllib.request, 'urlopen') as fetch, \
             mock.patch.object(m, 'run') as run:
            with self.assertRaisesRegex(m.SetupError, 'GitHub Actions'):
                m.download_gateway(Path(td))
            fetch.assert_not_called()
            run.assert_not_called()
            self.assertEqual(list(Path(td).iterdir()), [])

    def test_invalid_asset_metadata_never_fetches_or_executes(self):
        data = elf_fixture()
        good = pinned_asset(data)
        cases=({'sha256':'0'*63},{'size':99_999},{'size':20_000_001},{'name':'evil/../gateway'})
        for changed in cases:
            manifest={'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,
                      'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345',
                      'assets':[{**good,**changed},pinned_asset(elf_fixture('x86_64'),'x86_64')]}
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as td, \
                 mock.patch.object(m.platform,'machine',return_value='aarch64'), \
                 mock.patch.object(m.urllib.request,'urlopen',return_value=io.BytesIO(json.dumps(manifest).encode())) as fetch, \
                 mock.patch.object(m,'run') as run:
                with self.assertRaises(m.SetupError): m.download_gateway(Path(td))
                self.assertGreaterEqual(fetch.call_count,1)
                run.assert_not_called()

    def test_short_long_and_wrong_hash_assets_rejected_before_elf_execution(self):
        data = elf_fixture()
        good = pinned_asset(data)
        for body, asset in ((data[:-1], good), (data + b'x', good), (data, {**good, 'sha256': '0' * 64})):
            manifest={'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,
                      'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345',
                      'assets':[asset,pinned_asset(elf_fixture('x86_64'),'x86_64')]}
            with self.subTest(size=len(body), digest=asset['sha256'][:4]), tempfile.TemporaryDirectory() as td, \
                 mock.patch.object(m.platform, 'machine', return_value='aarch64'), \
                 mock.patch.object(m, 'fetch_gateway_manifest', return_value=(manifest,{'aarch64':asset})), \
                 mock.patch.object(m.urllib.request, 'urlopen', return_value=io.BytesIO(body)), \
                 mock.patch.object(m, 'check_gateway_elf') as check, mock.patch.object(m, 'run') as run:
                with self.assertRaises(m.SetupError):
                    m.download_gateway(Path(td))
                check.assert_not_called()
                run.assert_not_called()

    def test_network_failure_and_wrong_version_never_succeed(self):
        data = elf_fixture()
        manifest={'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,
                  'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345',
                  'assets':[pinned_asset(data,'aarch64'),pinned_asset(elf_fixture('x86_64'),'x86_64')]}
        with tempfile.TemporaryDirectory() as td, \
             mock.patch.object(m.platform, 'machine', return_value='aarch64'), \
             mock.patch.object(m, 'fetch_gateway_manifest', return_value=(manifest,{'aarch64':pinned_asset(data)})), \
             mock.patch.object(m.urllib.request, 'urlopen', side_effect=OSError('offline')), \
             mock.patch.object(m, 'run') as run:
            with self.assertRaisesRegex(m.SetupError, '旧服务未切换'):
                m.download_gateway(Path(td))
            run.assert_not_called()
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.object(m.urllib.request, 'urlopen', side_effect=(
                    io.BytesIO(json.dumps({'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345','assets':[pinned_asset(data,'aarch64'),pinned_asset(elf_fixture('x86_64'),'x86_64')]}).encode()),
                    io.BytesIO(json.dumps({'path':'.github/workflows/build-easytier-gateway.yml','head_sha':'a'*40,'event':'push','head_branch':'main','status':'completed','conclusion':'success'}).encode()),
                    io.BytesIO(json.dumps({'status':'identical'}).encode()),
                    io.BytesIO(data))), mock.patch.object(m.platform,'machine',return_value='aarch64'), mock.patch.object(m,'run',return_value=subprocess.CompletedProcess([],0,'easytier-gateway 0.0.0','')):
                with self.assertRaisesRegex(m.SetupError,'版本'):
                    m.download_gateway(Path(td))

    def test_conflicting_download_directory_or_symlink_never_fetches(self):
        data = elf_fixture()
        manifest={'format':'easytier-gateway-build-v1','go':'1.27.3','cgo':False,'commit':'a'*40,
                  'run':'https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345',
                  'assets':[pinned_asset(data,'aarch64'),pinned_asset(elf_fixture('x86_64'),'x86_64')]}
        for link in (False, True):
            with self.subTest(symlink=link), tempfile.TemporaryDirectory() as td, \
                 mock.patch.object(m.platform, 'machine', return_value='aarch64'), \
                 mock.patch.object(m, 'fetch_gateway_manifest', return_value=(manifest,{'aarch64':pinned_asset(data)})), \
                 mock.patch.object(m.urllib.request, 'urlopen') as fetch:
                root = Path(td)
                target = root / 'gateway-download'
                if link:
                    target.symlink_to(root / 'missing')
                else:
                    target.mkdir()
                with self.assertRaises(m.SetupError):
                    m.download_gateway(root)
                fetch.assert_not_called()

    def test_elf_rejects_wrong_arch_dynamic_truncated_and_non_elf(self):
        for data in (elf_fixture('x86_64'), elf_fixture(dynamic=True), b'\x7fELF', b'x' * 300):
            with self.subTest(size=len(data)), tempfile.TemporaryDirectory() as td:
                target = Path(td) / 'candidate'
                target.write_bytes(data)
                with self.assertRaises(m.SetupError):
                    m.check_gateway_elf(target, 'aarch64')


class GatewayTransactionTests(unittest.TestCase):
    def setup_install(self, td, stack):
        paths = lifecycle.LifecycleTests().setup_paths(td, stack)
        for key, value in paths.items():
            stack.enter_context(mock.patch.object(m, key, value))
        stack.enter_context(mock.patch.object(m, 'MANAGED', tuple(paths[key] for key in MANAGED_NAMES)))
        stack.enter_context(mock.patch.object(m, 'env_check'))
        stack.enter_context(mock.patch.object(m, 'svc_state', return_value={'active': True, 'enabled': True}))
        run = stack.enter_context(mock.patch.object(m, 'run', side_effect=lambda argv, **kw:
                                  subprocess.CompletedProcess(argv, 0, '', '')))
        stack.enter_context(mock.patch.object(m, 'health'))
        state = json.loads(paths['STATE'].read_text())
        state['gateway_version'] = 2
        m.atom(paths['STATE'], json.dumps(state))
        m.atom(paths['CFG'], m.render(dict(state, secret=SECRET), state['version']))
        args = types.SimpleNamespace(dry_run=False, update=True, join=None, join_link=None,
                                     no_prompt=True, role=None, domain=None, ip=None,
                                     name=None, network=None, listen_port=None)
        rel = {'tag': 'v2.6.4'}
        return paths, args, rel, run

    @staticmethod
    def fake_core_download(rel, stage):
        core, cli = Path(stage) / 'core-new', Path(stage) / 'cli-new'
        core.write_bytes(b'new-core')
        cli.write_bytes(b'new-cli')
        return core, cli

    def test_production_managed_paths_include_gateway_without_relocating_core(self):
        self.assertEqual(m.MANAGED, tuple(getattr(m, key) for key in MANAGED_NAMES))
        for key, name in (('CFG', 'config.toml'), ('CORE', 'easytier-core'), ('CLI', 'easytier-cli'),
                          ('SCRIPT', 'easytier-cf-debian.py'), ('GATEWAY', 'easytier-gateway')):
            self.assertEqual(getattr(m, key), Path('/etc/easytier') / name)

    def test_install_gateway_download_failure_never_stops_or_mutates_old_service(self):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, args, rel, run = self.setup_install(td, stack)
            before = {key: paths[key].read_bytes() for key in MANAGED_NAMES}
            stack.enter_context(mock.patch.object(m, 'download', side_effect=self.fake_core_download))
            gateway = stack.enter_context(mock.patch.object(m, 'download_gateway', side_effect=m.SetupError('gateway offline')))
            rollback = stack.enter_context(mock.patch.object(m, 'rollback', wraps=m.rollback))
            stack.enter_context(mock.patch.object(m, 'capture_failure_diagnostics'))
            with self.assertRaisesRegex(m.SetupError, 'gateway offline'):
                m.install(args, rel)
            gateway.assert_called_once()
            service_mutations = [call.args[0] for call in run.call_args_list
                                 if call.args[0][:2] in (['systemctl', 'stop'], ['systemctl', 'restart'])]
            self.assertEqual(service_mutations, [], 'download failure must not stop/restart the old service')
            rollback.assert_not_called()
            self.assertEqual({key: paths[key].read_bytes() for key in MANAGED_NAMES}, before)
            self.assertEqual(list(paths['TMP'].iterdir()), [])

    def _interrupt_install_at(self, phase):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, args, rel, run = self.setup_install(td, stack)
            before = {key: paths[key].read_bytes() for key in MANAGED_NAMES}
            service = {'active': True, 'enabled': True}
            stack.enter_context(mock.patch.object(m, 'svc_state', side_effect=lambda: dict(service)))
            stack.enter_context(mock.patch.object(m, 'download', side_effect=self.fake_core_download))
            injected = []
            original_atom = m.atom

            def download_gateway(stage):
                if phase == 'download':
                    injected.append(phase)
                    raise KeyboardInterrupt()
                return lifecycle.fake_gateway_download(stage)

            def atom(path, data, mode=0o600):
                original_atom(path, data, mode)
                if phase == 'gateway-write' and path == paths['GATEWAY'] and not injected:
                    injected.append(phase)
                    raise KeyboardInterrupt()

            def command(argv, **kwargs):
                if argv[:2] == ['systemctl', 'stop']:
                    service['active'] = False
                    if phase == 'service-stop' and not injected:
                        injected.append(phase)
                        raise KeyboardInterrupt()
                elif argv[:2] == ['systemctl', 'start']:
                    service['active'] = True
                elif argv[:2] == ['systemctl', 'enable']:
                    service['enabled'] = True
                elif argv[:2] == ['systemctl', 'disable']:
                    service['enabled'] = False
                return subprocess.CompletedProcess(argv, 0, '', '')

            run.side_effect = command
            stack.enter_context(mock.patch.object(m, 'download_gateway', side_effect=download_gateway))
            stack.enter_context(mock.patch.object(m, 'atom', side_effect=atom))
            rollback = stack.enter_context(mock.patch.object(m, 'rollback', wraps=m.rollback))
            diagnostics = stack.enter_context(mock.patch.object(m, 'capture_failure_diagnostics'))
            with self.assertRaises(KeyboardInterrupt):
                m.install(args, rel)
            self.assertEqual(injected, [phase])
            self.assertEqual({key: paths[key].read_bytes() for key in MANAGED_NAMES}, before)
            self.assertEqual(service, {'active': True, 'enabled': True})
            self.assertEqual(paths['UNIT_LINK'].resolve(), paths['UNIT_FILE'])
            self.assertEqual(paths['COMMAND'].resolve(), paths['SCRIPT'])
            self.assertEqual(list(paths['TMP'].iterdir()), [])
            if phase == 'download':
                rollback.assert_not_called()
                diagnostics.assert_not_called()
                self.assertFalse(any(call.args[0][:2] in (['systemctl', 'stop'], ['systemctl', 'start'])
                                     for call in run.call_args_list))
            else:
                rollback.assert_called_once()
                diagnostics.assert_called_once()
                self.assertIn(mock.call(['systemctl', 'start', m.UNIT], check=False), run.call_args_list)

    def test_install_interrupt_during_download_preserves_live_service_without_rollback(self):
        self._interrupt_install_at('download')

    def test_install_interrupt_after_gateway_write_restores_all_managed_files(self):
        self._interrupt_install_at('gateway-write')

    def test_install_interrupt_after_service_stop_restores_files_and_service(self):
        self._interrupt_install_at('service-stop')

    def test_repair_gateway_download_failure_never_restarts_or_mutates_old_service(self):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, _, _, run = self.setup_install(td, stack)
            before = {key: paths[key].read_bytes() for key in MANAGED_NAMES}
            stack.enter_context(mock.patch.object(m, 'download_gateway', side_effect=m.SetupError('gateway offline')))
            rollback = stack.enter_context(mock.patch.object(m, 'rollback', wraps=m.rollback))
            with self.assertRaisesRegex(m.SetupError, 'gateway offline'):
                m.repair_gateway()
            rollback.assert_not_called()
            run.assert_not_called()
            self.assertEqual({key: paths[key].read_bytes() for key in MANAGED_NAMES}, before)
            self.assertEqual(list(paths['TMP'].iterdir()), [])

    def test_gateway_snapshot_rollback_and_legacy_absent_binary(self):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, _, _, _ = self.setup_install(td, stack)
            old = b'\x7fELF-old-managed-gateway'
            m.atom(paths['GATEWAY'], old, 0o755)
            backup = m.snapshot()
            metadata = json.loads((backup / 'backup.json').read_text())
            self.assertIn(paths['GATEWAY'].name, metadata['present'])
            self.assertEqual((backup / 'files' / paths['GATEWAY'].name).read_bytes(), old)
            m.atom(paths['GATEWAY'], b'replacement', 0o755)
            m.rollback(backup)
            self.assertEqual(paths['GATEWAY'].read_bytes(), old)
            self.assertEqual(paths['GATEWAY'].stat().st_mode & 0o777, 0o755)
            paths['GATEWAY'].unlink()
            legacy = m.snapshot()
            m.atom(paths['GATEWAY'], b'new-go-binary', 0o755)
            m.rollback(legacy)
            self.assertFalse(paths['GATEWAY'].exists(), 'rollback of pre-Go state must remove Go binary')

    def test_gateway_symlink_is_rejected_by_ownership_and_snapshot(self):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, _, _, _ = self.setup_install(td, stack)
            paths['GATEWAY'].unlink()
            paths['GATEWAY'].symlink_to(paths['CORE'])
            with self.assertRaises(m.SetupError):
                m.ownership()
            with self.assertRaises(m.SetupError):
                m.snapshot()

    def test_server_install_migrates_gateway_preserving_config_identity_and_port(self):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, args, rel, run = self.setup_install(td, stack)
            old_config = paths['CFG'].read_bytes()
            old_state = json.loads(paths['STATE'].read_text())
            paths['GATEWAY'].unlink()  # A real pre-Go installation has no binary.
            stack.enter_context(mock.patch.object(m, 'download', side_effect=self.fake_core_download))
            gateway = stack.enter_context(mock.patch.object(m, 'download_gateway', side_effect=lifecycle.fake_gateway_download))
            m.install(args, rel)
            gateway.assert_called_once()
            self.assertEqual(paths['GATEWAY'].read_bytes(), lifecycle.FAKE_GATEWAY)
            self.assertEqual(paths['GATEWAY'].stat().st_mode & 0o777, 0o755)
            self.assertEqual(paths['CFG'].read_bytes(), old_config)
            state = json.loads(paths['STATE'].read_text())
            for key in ('name', 'ip', 'domain', 'network', 'subnet', 'server_name', 'listen_port'):
                self.assertEqual(state[key], old_state[key], key)
            self.assertEqual(state['gateway_version'], 3)
            self.assertEqual(state['gateway_build'], 'go1.27.3:' + 'a'*40)
            self.assertNotIn('secret', state)
            self.assertIn('--serve-gateway', paths['UNIT_FILE'].read_text())
            self.assertEqual(m.read_secret_from_config(), SECRET)
            self.assertEqual(list(paths['TMP'].iterdir()), [])
            self.assertIn(mock.call(['systemctl', 'stop', m.UNIT]), run.call_args_list)

    def test_repair_migrates_legacy_listener_from_config_without_rotating_identity(self):
        for active in (True, False):
            with self.subTest(active=active), tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
                paths, _, _, run = self.setup_install(td, stack)
                state = json.loads(paths['STATE'].read_text())
                del state['listen_port']
                m.atom(paths['STATE'], json.dumps(state))
                paths['GATEWAY'].unlink()
                before = {key: paths[key].read_bytes() for key in ('CFG', 'CORE', 'CLI')}
                stack.enter_context(mock.patch.object(m, 'svc_state', return_value={'active': active, 'enabled': True}))
                stack.enter_context(mock.patch.object(m, 'download_gateway', side_effect=lifecycle.fake_gateway_download))
                health = stack.enter_context(mock.patch.object(m, 'health'))
                m.repair_gateway()
                self.assertEqual({key: paths[key].read_bytes() for key in before}, before)
                result = json.loads(paths['STATE'].read_text())
                self.assertEqual(result['listen_port'], 22222)
                self.assertEqual(result['gateway_version'], 3)
                self.assertEqual(result['gateway_build'], 'go1.27.3:' + 'a'*40)
                self.assertEqual(result['ip'], state['ip'])
                self.assertEqual(m.read_secret_from_config(), SECRET)
                self.assertEqual(paths['GATEWAY'].read_bytes(), lifecycle.FAKE_GATEWAY)
                self.assertEqual(list(paths['TMP'].iterdir()), [])
                calls = [call.args[0] for call in run.call_args_list]
                if active:
                    self.assertIn(['systemctl', 'restart', m.UNIT], calls)
                    health.assert_called_once()
                else:
                    self.assertFalse(any(argv[1] in ('start', 'restart') for argv in calls))
                    health.assert_not_called()

    def test_repair_health_failure_restores_managed_gateway_and_settings(self):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, _, _, _ = self.setup_install(td, stack)
            before = {key: paths[key].read_bytes() for key in MANAGED_NAMES}
            stack.enter_context(mock.patch.object(m, 'download_gateway', side_effect=lifecycle.fake_gateway_download))
            stack.enter_context(mock.patch.object(m, 'health', side_effect=m.SetupError('not ready')))
            stack.enter_context(mock.patch.object(m, 'capture_failure_diagnostics'))
            with self.assertRaisesRegex(m.SetupError, 'not ready'):
                m.repair_gateway()
            self.assertEqual({key: paths[key].read_bytes() for key in MANAGED_NAMES}, before)
            self.assertEqual(list(paths['TMP'].iterdir()), [])

    def test_uninstall_backs_up_gateway_bytes_and_removes_only_managed_binary(self):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, _, _, _ = self.setup_install(td, stack)
            original = b'\x7fELF\xff\x00gateway-uninstall-sentinel'
            m.atom(paths['GATEWAY'], original, 0o755)
            unknown = paths['ROOT'] / 'operator-note'
            unknown.write_text('keep')
            stack.enter_context(mock.patch.object(m, 'svc_state', return_value={'active': False, 'enabled': False}))
            stack.enter_context(mock.patch('builtins.input', return_value='UNINSTALL'))
            m.uninstall()
            backup = next(paths['BACKUPS'].iterdir())
            self.assertEqual((backup / 'files' / paths['GATEWAY'].name).read_bytes(), original)
            self.assertFalse(paths['GATEWAY'].exists())
            self.assertEqual(unknown.read_text(), 'keep')
            for key in MANAGED_NAMES:
                self.assertFalse(paths[key].exists(), key)

    def test_client_install_and_repair_never_download_gateway(self):
        for operation in ('install', 'repair'):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
                paths, args, rel, _ = self.setup_install(td, stack)
                state = json.loads(paths['STATE'].read_text())
                state.update(role='client', name='client', ip='10.66.66.2/24')
                for key in ('listen_port', 'gateway_version', 'gateway_build'):
                    state.pop(key, None)
                m.atom(paths['STATE'], json.dumps(state))
                m.atom(paths['CFG'], m.render(dict(state, secret=SECRET), state['version']))
                paths['GATEWAY'].unlink()
                stack.enter_context(mock.patch.object(m, 'download', side_effect=self.fake_core_download))
                gateway = stack.enter_context(mock.patch.object(m, 'download_gateway', side_effect=AssertionError('client gateway download')))
                stack.enter_context(mock.patch.object(m, 'peer_check', return_value='fixture peer advisory'))
                if operation == 'install':
                    m.install(args, rel)
                else:
                    m.repair_gateway()
                gateway.assert_not_called()
                self.assertFalse(paths['GATEWAY'].exists())
                self.assertNotIn('--serve-gateway', paths['UNIT_FILE'].read_text())
                self.assertIn(str(paths['CORE']) + ' -c ' + str(paths['CFG']), paths['UNIT_FILE'].read_text())
                self.assertEqual(json.loads(paths['STATE'].read_text())['role'], 'client')
                self.assertEqual(list(paths['TMP'].iterdir()), [])

    def test_memfd_exec_has_no_argv_or_environment_secret_and_closes_on_exec_error(self):
        class ExecReplacement(BaseException):
            pass
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            paths, _, _, _ = self.setup_install(td, stack)
            inspected = []
            def execve(binary, argv, env):
                self.assertEqual(binary, str(paths['GATEWAY']))
                self.assertEqual(argv[:2], [binary, '--config-fd'])
                self.assertEqual(len(argv), 3)
                self.assertFalse(SECRET in json.dumps(argv) or any(SECRET in str(value) for value in env.values()),
                                 'invitation secret must not enter argv/environment')
                fd = int(argv[2])
                self.assertTrue(os.get_inheritable(fd))
                self.assertEqual(os.fstat(fd).st_nlink, 0)
                self.assertIn('memfd:', os.readlink('/proc/self/fd/' + str(fd)))
                boot = json.loads(os.read(fd, 65537))
                self.assertEqual(boot['payload']['secret'], SECRET)
                self.assertEqual(boot['listen_port'], 22222)
                self.assertEqual(boot['core_path'], str(paths['CORE']))
                self.assertEqual(boot['config_path'], str(paths['CFG']))
                self.assertEqual(boot['control_path'], str(paths['TMP'] / 'invite-control.sock'))
                self.assertEqual(boot['rpc_port'], m.RPC)
                inspected.append(fd)
                raise ExecReplacement()
            stack.enter_context(mock.patch.object(m.os, 'execve', side_effect=execve))
            popen = stack.enter_context(mock.patch.object(m.subprocess, 'Popen'))
            threads = stack.enter_context(mock.patch('threading.Thread'))
            with self.assertRaises(ExecReplacement):
                m.serve_gateway()
            popen.assert_not_called()
            threads.assert_not_called()
            self.assertEqual(len(inspected), 1)
            with self.assertRaises(OSError):
                os.fstat(inspected[0])
            self.assertEqual(list(paths['TMP'].iterdir()), [])
            self.assertNotIn(SECRET, paths['STATE'].read_text())

    def test_python_no_longer_contains_gateway_data_plane_or_exec_fallback(self):
        tree = ast.parse(SCRIPT.read_text())
        names = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef))}
        self.assertTrue({'build_gateway', 'JoinGrant', 'make_control_server'}.isdisjoint(names))
        serve = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'serve_gateway')
        calls = [node.func.attr for node in ast.walk(serve)
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)]
        self.assertIn('memfd_create', calls)
        self.assertIn('execve', calls)
        self.assertTrue({'Popen', 'Thread', 'serve_forever', 'recv', 'sendall', 'accept'}.isdisjoint(calls))

    def test_real_serve_gateway_replaces_python_pid_and_erases_boot_fd(self):
        payload = dict(format='easytier-cf-join-v1', domain='mesh.example.test', network='test',
                       secret=SECRET, subnet='10.66.66.0/24', server_name='vps')
        with GoGateway(payload, through_installer=True) as gateway:
            process = Path('/proc') / str(gateway.process.pid)
            # The Popen PID began as Python. It now owns a native Go executable.
            self.assertTrue(os.path.samefile(process / 'exe', gateway_binary()))
            command = (process / 'cmdline').read_bytes().split(b'\0')
            self.assertEqual(command[:2], [str(gateway_binary()).encode(), b'--config-fd'])
            self.assertNotIn(SECRET.encode(), (process / 'cmdline').read_bytes())
            self.assertFalse(SECRET.encode() in (process / 'environ').read_bytes(),
                             'native process environment contains invitation secret')
            links = [os.readlink(path) for path in (process / 'fd').iterdir() if path.is_symlink()]
            self.assertFalse(any('easytier-gateway-boot' in link for link in links),
                             'Go must close its inherited memfd after decoding')
            self.assertEqual(gateway.control('health')['gateway_version'], 3)
            token = gateway.issue()
            with mock.patch.object(m, 'control_path', return_value=gateway.control_path):
                self.assertEqual(m.control_call('status', token)['status'], 'active')
            ws = socket.create_connection(gateway.address, timeout=3)
            try:
                ws.sendall(b'GET / HTTP/1.1\r\nHost: mesh.example.test\r\nUpgrade: websocket\r\n'
                           b'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                           b'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')
                self.assertTrue(read_http_headers(ws).startswith(b'HTTP/1.1 101 '))
                ws.sendall(b'GO_EXEC_DATA_PLANE')
                echoed = bytearray()
                while len(echoed) < len(b'GO_EXEC_DATA_PLANE'):
                    block = ws.recv(4096)
                    self.assertTrue(block)
                    echoed.extend(block)
                self.assertEqual(echoed, b'GO_EXEC_DATA_PLANE')
            finally:
                ws.close()
            self.assertNotIn(SECRET, (gateway.root / 'installer-launch.py').read_text())
            self.assertNotIn(SECRET, (gateway.root / 'settings.json').read_text())


if __name__ == '__main__':
    unittest.main()
