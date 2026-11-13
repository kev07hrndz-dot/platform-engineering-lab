"""Generate a throwaway cosign key pair with `zarf tools gen-key`.

`gen-key` only reads its password from a terminal, so this runs it on a
pseudo-terminal, answers the terminal's cursor-position query, and submits an
empty password. The files cosign.key and cosign.pub are written to the current
directory. They are test material for scripts/sign-validate.sh and must never
sign a real release.

Usage: python3 gen-test-key.py [path-to-zarf]
"""
import os
import pty
import select
import signal
import sys
import time

TIMEOUT_SECONDS = 30
CURSOR_QUERY = b"\x1b[6n"
CURSOR_REPLY = b"\x1b[1;1R"

zarf = sys.argv[1] if len(sys.argv) > 1 else "zarf"
pid, fd = pty.fork()
if pid == 0:
    os.execvp(zarf, [zarf, "tools", "gen-key", "--no-color"])

deadline = time.time() + TIMEOUT_SECONDS
answers = 0
finished = False
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.5)
    if not ready:
        if os.waitpid(pid, os.WNOHANG)[0]:
            finished = True
            break
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    for _ in range(data.count(CURSOR_QUERY)):
        os.write(fd, CURSOR_REPLY)
    if b"assword" in data and answers < 3:
        os.write(fd, b"\r")
        answers += 1

if not finished:
    try:
        ended, _ = os.waitpid(pid, os.WNOHANG)
        if not ended:
            time.sleep(1)
            ended, _ = os.waitpid(pid, os.WNOHANG)
        if not ended:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
    except ChildProcessError:
        pass

if not (os.path.exists("cosign.key") and os.path.exists("cosign.pub")):
    sys.exit("gen-test-key: zarf tools gen-key did not write cosign.key and cosign.pub")
