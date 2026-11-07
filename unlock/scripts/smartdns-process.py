#!/usr/bin/env python3
"""Keep SmartDNS -R supervisor and workers in one private lifecycle group."""
import os
import signal
import sys
import time


def stop_group(pid):
    if pid <= 1 or pid == os.getpgrp():
        raise ValueError("refusing to stop a non-private SmartDNS group")
    try:
        if os.getpgid(pid) != pid:
            raise ValueError("SmartDNS PID is not a private group leader")
    except ProcessLookupError:
        # The supervisor may have exited while its workers still own sockets.
        pass
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "start":
        os.setsid()
        os.execvp("smartdns", ["smartdns", "-R", "-c", sys.argv[2], "-f"])
    elif len(sys.argv) == 3 and sys.argv[1] == "stop":
        stop_group(int(sys.argv[2]))
    else:
        raise SystemExit("usage: smartdns-process.py {start CONFIG|stop PID}")
