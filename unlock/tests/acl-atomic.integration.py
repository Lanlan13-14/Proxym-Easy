#!/usr/bin/env python3
"""Optional real nft regression; run under unshare -n with NFT_BINARY."""
import os
import pathlib
import subprocess
import tempfile

if os.readlink('/proc/self/ns/net') == os.readlink('/proc/1/ns/net'):
    raise SystemExit('refusing host network: use unshare -n')
root = pathlib.Path(__file__).resolve().parents[1]
nft = pathlib.Path(os.environ['NFT_BINARY']).resolve()
with tempfile.TemporaryDirectory(prefix='proxym-nft-real-') as name:
    tmp = pathlib.Path(name)
    (tmp / 'nft').symlink_to(nft)
    env = dict(os.environ, PATH=str(tmp)+':'+os.environ['PATH'], RUNTIME_DIR=str(tmp),
        ALLOWED_IPS='203.0.113.7/32,2001:db8::/48', ENABLE_ACL='1',
        CONTROL_CENTER_URL='', ENABLE_DNS='1', DNS_UDP_PORT='5533',
        ENABLE_DOT='0', ENABLE_DOH='1', DOH_PORT='9857', ENABLE_SOCKS5='0')
    def run(*args, **kwargs):
        return subprocess.run(args, env=env, capture_output=True, text=True, **kwargs)
    def dump():
        result = run(str(nft), '-s', 'list', 'table', 'inet', 'unlock_acl', check=True)
        return result.stdout
    result = run('sh', str(root / 'scripts/apply-acl.sh'))
    assert result.returncode == 0, result.stderr
    before = dump()
    assert '203.0.113.7' in before and '5533' in before and '9857' in before
    env['ALLOWED_IPS'] = '198.51.100.8/32'
    result = run('sh', str(root / 'scripts/apply-acl.sh'))
    assert result.returncode == 0, result.stderr
    second = dump()
    assert '198.51.100.8' in second and '203.0.113.7' not in second
    # A kernel validation failure *after* deletion has been parsed must roll
    # the whole batch back, not leave an absent or partially rebuilt table.
    result = run(str(nft), '-f', '-', input='delete table inet unlock_acl\nadd table inet unlock_acl\nadd rule inet unlock_acl absent tcp dport 443 drop\n')
    assert result.returncode != 0
    assert dump() == second, 'kernel rejected batch changed previous ACL'
    env['ALLOWED_IPS'] = '203.0.113.7;flush ruleset'
    result = run('sh', str(root / 'scripts/apply-acl.sh'))
    assert result.returncode != 0
    assert dump() == second
    print('REAL_NFT_ATOMIC_REPLACEMENT_ROLLBACK_PASS')
