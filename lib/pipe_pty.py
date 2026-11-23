#!/usr/bin/env python3
"""PTY relay for running interactive commands over systemd-run --pipe."""
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios


def main() -> int:
    rows, cols = int(sys.argv[1]), int(sys.argv[2])
    cmd = sys.argv[3:]
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def _setup() -> None:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    proc = subprocess.Popen(
        cmd,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        preexec_fn=_setup,
        close_fds=True,
    )
    os.close(slave)

    def _forward_eof() -> None:
        try:
            os.write(master, b"\x04")
        except OSError:
            pass

    stdin_open = True
    while True:
        rfds = [master] + ([0] if stdin_open else [])
        ready, _, _ = select.select(rfds, [], [])
        if master in ready:
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            os.write(1, data)
        if 0 in ready:
            try:
                data = os.read(0, 4096)
            except OSError:
                stdin_open = False
                continue
            if not data:
                stdin_open = False
                _forward_eof()
            else:
                os.write(master, data)
    os.close(master)
    rc = proc.wait()
    return rc if rc >= 0 else 128 + (-rc)


if __name__ == "__main__":
    sys.exit(main())
