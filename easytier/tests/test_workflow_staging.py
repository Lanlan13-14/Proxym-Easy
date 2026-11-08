"""Run the real staging shell fragment, including artifact permission loss.

Synthetic ELF bytes are only test fixtures and are never executed or published.
No GitHub API, git push, production paths, or configured credentials are used.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/build-easytier-gateway.yml'
NAMES = ('easytier-gateway-linux-amd64', 'easytier-gateway-linux-arm64')


def static_elf(machine=62, dynamic=False):
    data = bytearray(300_000)
    ident = b'\x7fELF\x02\x01\x01' + bytes(9)
    struct.pack_into('<16sHHIQQQIHHHHHH', data, 0,
                     ident, 2, machine, 1, 0x400078, 64, 0, 0, 64, 56, 1, 64, 0, 0)
    interp = b'/lib/ld-test.so.1\x00'
    struct.pack_into('<IIQQQQQQ', data, 64, 3 if dynamic else 1, 4,
                     120, 0x400078, 0x400078, len(interp), len(interp), 1)
    data[120:120 + len(interp)] = interp
    return bytes(data)


def staging_fragment():
    text = WORKFLOW.read_text()
    marker = '      - name: Verify artifacts and commit beside installer\n'
    if text.count(marker) != 1:
        raise AssertionError('Expected one staging step')
    step = text.split(marker, 1)[1]
    body = step.split('        run: |\n', 1)[1]
    lines = []
    for line in body.splitlines():
        if not line.startswith('          '):
            break
        line = line[10:]
        if line.startswith('git add '):
            break  # Do not run git staging, commits, fetches or pushes.
        lines.append(line)
    if not lines or not any('write_text(' in line for line in lines):
        raise AssertionError('Actual artifact verification/copy/manifest fragment not found')
    return '\n'.join(lines) + '\n'


class WorkflowStagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for command in ('bash', 'readelf', 'rg', 'install', 'sha256sum', 'python3'):
            if shutil.which(command) is None:
                raise AssertionError('Staging regression requires ' + command)
        cls.fragment = staging_fragment()

    def execute_fragment(self, root, *, mode=0o644, dynamic=False, wrong_hash=False):
        stage = root / 'staged'
        stage.mkdir()
        (root / 'easytier').mkdir()
        for index, name in enumerate(NAMES):
            raw = static_elf(62 if index == 0 else 183, dynamic=dynamic and index == 0)
            source = stage / name
            source.write_bytes(raw)
            source.chmod(mode)
            digest = ('0' * 64 if wrong_hash and index == 0 else hashlib.sha256(raw).hexdigest())
            (stage / (name + '.sha256')).write_text(digest + '  ' + name + '\n')
        env = dict(os.environ, SOURCE_SHA='a' * 40, GO_VERSION='1.27.3',
                   RUN_URL='https://github.com/Lanlan13-14/Proxym-Easy/actions/runs/12345')
        return subprocess.run(['bash', '-e'], input=self.fragment, text=True,
                              cwd=root, env=env, capture_output=True, timeout=15)

    def test_downloaded_artifacts_without_execute_bit_are_validated_then_installed_0755(self):
        for mode in (0o644, 0o600):
            with self.subTest(mode=oct(mode)), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                result = self.execute_fragment(root, mode=mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                manifest = json.loads((root / 'easytier/easytier-gateway-build.json').read_text())
                self.assertEqual(manifest['commit'], 'a' * 40)
                self.assertEqual(manifest['go'], '1.27.3')
                self.assertIs(manifest['cgo'], False)
                self.assertEqual(manifest['format'], 'easytier-gateway-build-v1')
                self.assertEqual({item['name'] for item in manifest['assets']}, set(NAMES))
                for asset in manifest['assets']:
                    target = root / 'easytier' / asset['name']
                    self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
                    self.assertEqual(target.read_bytes(), (root / 'staged' / asset['name']).read_bytes())
                    self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), asset['sha256'])
                    self.assertEqual(target.stat().st_size, asset['size'])

    def test_bad_checksum_stops_before_install_or_manifest(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = self.execute_fragment(root, wrong_hash=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list((root / 'easytier').iterdir()), [])

    def test_dynamic_elf_stops_before_install_or_manifest(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            result = self.execute_fragment(root, dynamic=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Dynamic gateway binary rejected', result.stderr)
            self.assertEqual(list((root / 'easytier').iterdir()), [])
