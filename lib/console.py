#!/usr/bin/env python3
"""Drive the Archboot live system over a UTM TCP serial console.

Waits for Archboot's boot prompt, opens a root shell, copies files in
(base64 over the serial line, verified by SHA-256), runs a command, and
optionally powers the machine off. All console output goes to --log; lines
starting with "==>" are echoed to stdout as progress.

Exit status is the command's exit status (or 2 for console/timeout errors).
"""

import argparse
import base64
import hashlib
import os
import re
import socket
import sys
import threading
import time
import uuid

ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1bP[^\x1b]*\x1b\\")
# Archboot colours the words: "...\x1b[92mCTRL-C\x1b[m for \x1b[1mbash\x1b[m prompt."
_SGR = rb"(?:\x1b\[[0-9;]*m)*"
BOOT_PROMPT = re.compile(rb"CTRL-C" + _SGR + rb"\s+for\s+" + _SGR + rb"bash" + _SGR + rb"\s+prompt")


class ConsoleError(Exception):
    pass


class Console:
    def __init__(self, port, log_path, connect_timeout=120):
        deadline = time.time() + connect_timeout
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise ConsoleError(f"could not connect to serial port {port}")
                time.sleep(1)
        self.sock.settimeout(None)
        self.log = open(log_path, "ab", buffering=0)
        self.buf = bytearray()
        self.cond = threading.Condition()
        self.closed = False
        self._line = bytearray()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            try:
                data = self.sock.recv(65536)
            except OSError:
                data = b""
            with self.cond:
                if not data:
                    self.closed = True
                    self.cond.notify_all()
                    return
                self.buf += data
                self.cond.notify_all()
            self.log.write(data)
            self._progress(data)

    def _progress(self, data):
        for b in data:
            if b == 0x0A:
                line = ANSI.sub(b"", bytes(self._line)).replace(b"\r", b"").strip()
                if line.startswith(b"==>"):
                    print(line.decode(errors="replace"), flush=True)
                self._line.clear()
            else:
                self._line.append(b)

    def send(self, data):
        if isinstance(data, str):
            data = data.encode()
        self.sock.sendall(data)

    def mark(self):
        with self.cond:
            return len(self.buf)

    def wait_for(self, pattern, start, timeout):
        deadline = time.time() + timeout
        with self.cond:
            while True:
                m = pattern.search(self.buf, start)
                if m:
                    return m
                if self.closed:
                    raise ConsoleError("serial console closed")
                left = deadline - time.time()
                if left <= 0:
                    raise ConsoleError(f"timed out after {timeout}s waiting for {pattern.pattern!r}")
                self.cond.wait(left)

    def run(self, cmd, timeout):
        """Run a shell command and return its exit status."""
        tag = "__RC" + uuid.uuid4().hex[:12]
        start = self.mark()
        # The echoed command contains "<tag> $?", never "<tag>_<digits>__".
        self.send(f"{cmd}; printf '%s_%s__\\n' {tag} $?\n")
        m = self.wait_for(re.compile(tag.encode() + rb"_(\d+)__"), start, timeout)
        return int(m.group(1))

    def put(self, local, remote, timeout=120):
        data = open(local, "rb").read()
        digest = hashlib.sha256(data).hexdigest()
        encoded = base64.encodebytes(data).decode()  # 76-char lines, under the tty line limit
        self.send(f"base64 -d > '{remote}' <<'__B64_EOF__'\n")
        for line in encoded.splitlines():
            self.send(line + "\n")
            time.sleep(0.002)
        self.send("__B64_EOF__\n")
        rc = self.run(f"echo '{digest}  {remote}' | sha256sum -c --quiet", timeout)
        if rc != 0:
            raise ConsoleError(f"checksum mismatch copying {local} to {remote}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--boot-timeout", type=int, default=300)
    ap.add_argument("--put", action="append", default=[], metavar="LOCAL=REMOTE")
    ap.add_argument("--run", required=True, metavar="COMMAND")
    ap.add_argument("--run-timeout", type=int, default=2400)
    ap.add_argument("--poweroff", action="store_true")
    args = ap.parse_args()

    try:
        con = Console(args.port, args.log)
        print("==> Waiting for Archboot to boot", flush=True)
        con.wait_for(BOOT_PROMPT, 0, args.boot_timeout)
        time.sleep(1)
        con.send(b"\x03")  # Ctrl-C: skip the login menu, get a bash prompt
        time.sleep(2)
        if con.run("stty -echo; export TERM=dumb PS1='# '", 30) != 0:
            raise ConsoleError("could not set up the shell")
        print("==> Shell ready; copying scripts", flush=True)
        for spec in args.put:
            local, remote = spec.split("=", 1)
            con.put(local, remote)
        rc = con.run(args.run, args.run_timeout)
        if rc == 0 and args.poweroff:
            con.send("sync; poweroff\n")
        return rc
    except ConsoleError as e:
        print(f"==> ERROR: {e}", file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    sys.exit(main())
