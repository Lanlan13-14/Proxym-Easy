#!/usr/bin/env python3
"""Optional real-binary regression. Invoke with unshare -n and SMARTDNS_BINARY.

Uses only loopback in a private network namespace; does not start WARP/nft.
"""
import os
import pathlib
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
if os.readlink('/proc/self/ns/net') == os.readlink('/proc/1/ns/net'):
    raise SystemExit('refusing host network: use unshare -n')
binary = pathlib.Path(os.environ['SMARTDNS_BINARY']).resolve()
subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
with tempfile.TemporaryDirectory(prefix='proxym-smartdns-real-') as name:
    base = pathlib.Path(name)
    config = base / 'smartdns.conf'
    config.write_text('bind 127.0.0.1:55353\nbind-tcp 127.0.0.1:55353\ncache-persist no\nlog-console yes\naddress /probe.invalid/203.0.113.4\n')
    (base / 'smartdns').symlink_to(binary)
    env = dict(os.environ, CONF_DIR=str(base), DNS_UDP_PORT='55353', PATH=str(base)+':'+os.environ['PATH'])
    helper = str(ROOT / 'scripts/smartdns-process.py')
    command = ['python3', helper, 'start', str(config)]
    probe = ['python3', str(ROOT / 'scripts/dns-health.py')]
    def wait_ready():
        for _ in range(30):
            if subprocess.run(probe, env=env, capture_output=True).returncode == 0:
                return
            time.sleep(.1)
        raise AssertionError('real SmartDNS did not answer or old port was not released')
    with (base / 'smartdns.log').open('w') as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        try:
            wait_ready()
            assert os.getpgid(process.pid) == process.pid
            os.killpg(process.pid, signal.SIGSTOP)
            assert subprocess.run(probe, env=env, capture_output=True, timeout=4).returncode != 0
            subprocess.run(['python3', helper, 'stop', str(process.pid)], check=True, timeout=5)
            process.wait(timeout=3)
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            wait_ready()
            print('REAL_SMARTDNS_GROUP_RESTART_PASS')
        finally:
            subprocess.run(['python3', helper, 'stop', str(process.pid)], check=True, timeout=5)
            process.wait(timeout=3)
