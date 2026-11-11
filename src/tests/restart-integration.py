#!/usr/bin/env python3
"""Real process restart / crash acceptance harness for the durable RealWorld server.

Executed by a maintainer (``make test-restart``), never by the build. Python is
only the external test DRIVER: production persistence is entirely Protos.

What it does, all inside a fresh temporary directory it creates and removes:
  * preprovisions the data directory and an empty journal (no lock file);
  * starts the installed Protos runtime with explicit Network, Entropy, Clock
    and --allow-filesystem=<that directory> grants and one FIXED, PUBLIC,
    TEST-ONLY signing key shared across restarts;
  * waits for the REALWORLD_HTTP_READY line (never an arbitrary sleep), and
    fails if readiness is announced when startup must fail;
  * makes real HTTP requests to 127.0.0.1:3000, stops ("quit") and restarts;
  * checks a second concurrent writer is refused (lock_unavailable);
  * SIGKILLs a running server (POSIX only), checks the stale lock is refused,
    removes it as an operator would, and checks acknowledged writes survive;
  * corrupts / truncates DISPOSABLE COPIES of the journal and checks the
    conservative recovery contract (fail closed, explicit tail repair only).

PASS markers are printed only after all assertions of a step completed. Output
from the server is echoed with tokens and the key redacted.

Limits: SIGKILL kills the process, not the machine. It cannot show that data
survives power loss or an OS crash, and filesystem/device sync semantics are
platform specific. Results apply only to the platform and runtime tested.
Port 3000 on 127.0.0.1 must be free (checked first). A JVM pass says nothing
about a Native Image build, and vice versa: report which runtime PROTOS was.
"""

import base64
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROTOS = os.environ.get("PROTOS", "protos")
PROTOS_ARGS = shlex.split(os.environ.get("PROTOS_ARGS", "-Dpolyglot.engine.WarnInterpreterOnly=false"))
BASE = "http://127.0.0.1:3000/api"
JOURNAL = "realworld.journal"
LOCK = "realworld.journal.lock"
READY = "REALWORLD_HTTP_READY="
FAILED = "REALWORLD_HTTP_STARTUP_FAILED="
STARTUP_TIMEOUT = 120.0
# Public test-only key material (32 octets). Never use outside this harness.
TEST_KEY = base64.urlsafe_b64encode(b"restart-harness-public-key-32oct").decode().rstrip("=")

SECRETS = {TEST_KEY}
# Every started server, so that any failure path still terminates it.
STARTED = []


def redact(text):
    for secret in sorted(SECRETS, key=len, reverse=True):
        if secret:
            text = text.replace(secret, "<redacted>")
    return text


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


class Server:
    """One server process with line-oriented stdout monitoring."""

    def __init__(self, data_dir, grant=True, extra_env=None):
        command = [PROTOS, *PROTOS_ARGS, "--allow-network", "--allow-entropy", "--allow-clock"]
        if grant:
            command.append("--allow-filesystem=" + data_dir)
        command += ["--service=service", os.path.join("src", "main.protos")]
        env = dict(os.environ)
        env["REALWORLD_JWT_KEY_BASE64URL"] = TEST_KEY
        env.pop("REALWORLD_JOURNAL_REPAIR", None)
        env.update(extra_env or {})
        self.lines = []
        self.condition = threading.Condition()
        self.process = subprocess.Popen(
            command, cwd=REPO, env=env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        STARTED.append(self)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            with self.condition:
                self.lines.append(line.rstrip("\n"))
                self.condition.notify_all()
        with self.condition:
            self.condition.notify_all()

    def outcome(self):
        """Block until readiness, a startup failure line, or process exit."""
        deadline = time.monotonic() + STARTUP_TIMEOUT
        with self.condition:
            while True:
                for line in self.lines:
                    if line.startswith(READY):
                        return "ready"
                if any(line.startswith(FAILED) for line in self.lines):
                    return "failed"
                if self.process.poll() is not None and not self.reader.is_alive():
                    return "exited"
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return "timeout"
                self.condition.wait(timeout=min(remaining, 1.0))

    def has(self, prefix):
        with self.condition:
            return any(line.startswith(prefix) for line in self.lines)

    def quit(self):
        if self.process.poll() is None:
            self.process.stdin.write("quit\n")
            self.process.stdin.flush()
        self.process.wait(timeout=60)

    def kill(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGKILL)
        self.process.wait(timeout=30)

    def stop_quietly(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=30)

    def transcript(self):
        with self.condition:
            return "\n".join(redact(line) for line in self.lines)


def expect_ready(server):
    state = server.outcome()
    if state != "ready":
        raise Failure("server did not become ready (" + state + ")\n" + server.transcript())


def expect_refused(server, label):
    state = server.outcome()
    try:
        require(
            state in ("failed", "exited"),
            f"server must refuse ({label or 'unlabelled'}), got {state}. "
            + server.transcript()
        )
        if label is not None:
            require(server.has("REALWORLD_JOURNAL_FAILURE=" + label),
                    "missing failure label " + label + "\n" + server.transcript())
        # A startup-failure label is emitted BEFORE journal cleanup.
        # Do not kill the process before it can release its own lock.
        try:
            server.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            raise Failure(
                "refused server did not terminate: "
                + (label or "unlabelled")
                + "\n"
                + server.transcript()
            )
    finally:
        server.stop_quietly()


def http(method, path, body=None, token=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    if token is not None:
        SECRETS.add(token)
        request.add_header("Authorization", "Token " + token)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        raw = error.read()
        return error.code, (json.loads(raw) if raw else None)


def call(method, path, status, body=None, token=None):
    actual, payload = http(method, path, body, token)
    require(actual == status, "%s %s: expected %d, got %d" % (method, path, status, actual))
    return payload


def user(name, password):
    return {"user": {"username": name, "email": name + "@example.test", "password": password}}


def login(name, password):
    return {"user": {"email": name + "@example.test", "password": password}}


def provision(root):
    data = os.path.join(root, "data")
    os.mkdir(data)
    open(os.path.join(data, JOURNAL), "xb").close()
    return data


def copy_store(source, root, name):
    target = os.path.join(root, name)
    shutil.copytree(source, target)
    lock = os.path.join(target, LOCK)
    if os.path.exists(lock):
        os.remove(lock)
    return target


def port_free():
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind(("127.0.0.1", 3000))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def main():
    if not port_free():
        print("REALWORLD_RESTART_INTEGRATION=FAIL: 127.0.0.1:3000 is already in use; "
              "stop the other server first", file=sys.stderr)
        return 1
    root = tempfile.mkdtemp(prefix="realworld-restart-")
    data = provision(root)
    tokens = {}
    try:
        # -- missing grant / missing journal fail closed ----------------------
        expect_refused(Server(data, grant=False), None)
        empty_dir = os.path.join(root, "nojournal")
        os.mkdir(empty_dir)
        expect_refused(Server(empty_dir), "journal_unavailable")
        require(not os.path.exists(os.path.join(empty_dir, LOCK)), "lock left after missing journal")
        print("RESTART_FAIL_CLOSED=PASS")

        # -- first run: populate --------------------------------------------
        server = Server(data)
        expect_ready(server)
        require(os.path.exists(os.path.join(data, LOCK)), "lock not held while running")
        tokens["alice"] = call("POST", "/users", 201, user("alice", "alice password one"))["user"]["token"]
        bob_old = call("POST", "/users", 201, user("bob", "bob password one"))["user"]["token"]
        call("POST", "/articles", 201, {"article": {"title": "Durable", "description": "D",
             "body": "B", "tagList": ["persist"]}}, tokens["alice"])
        call("POST", "/articles/durable/comments", 201, {"comment": {"body": "First"}}, bob_old)
        call("POST", "/profiles/alice/follow", 200, None, bob_old)
        call("POST", "/articles/durable/favorite", 200, None, bob_old)
        tokens["bob"] = call("PUT", "/user", 200, {"user": {"password": "bob password two"}}, bob_old)["user"]["token"]
        call("GET", "/user", 401, None, bob_old)

        # -- second writer refused while the first runs ------------------------
        expect_refused(Server(data), "lock_unavailable")
        print("RESTART_SECOND_WRITER=PASS")

        server.quit()
        require(not os.path.exists(os.path.join(data, LOCK)), "lock not released by graceful stop")

        # -- graceful restart: recovered state + authentication ----------------
        server = Server(data)
        expect_ready(server)
        me = call("GET", "/user", 200, None, tokens["alice"])["user"]
        require(me["username"] == "alice", "alice identity lost")
        call("GET", "/user", 200, None, tokens["bob"])
        call("GET", "/user", 401, None, bob_old)
        call("POST", "/users/login", 200, login("bob", "bob password two"))
        call("POST", "/users/login", 401, login("bob", "bob password one"))
        article = call("GET", "/articles/durable", 200, None, tokens["bob"])["article"]
        require(article["favorited"] and article["favoritesCount"] == 1, "favorite lost")
        require(call("GET", "/profiles/alice", 200, None, tokens["bob"])["profile"]["following"], "follow lost")
        comments = call("GET", "/articles/durable/comments", 200)["comments"]
        require(len(comments) == 1 and comments[0]["id"] == 1, "comment lost")
        created = call("POST", "/articles/durable/comments", 201, {"comment": {"body": "Second"}}, tokens["alice"])
        require(created["comment"]["id"] == 2, "comment id reused")
        print("RESTART_GRACEFUL=PASS")

        # -- SIGKILL after an acknowledged write -------------------------------
        if hasattr(signal, "SIGKILL"):
            call("POST", "/users", 201, user("carol", "carol password"))
            server.kill()
            require(os.path.exists(os.path.join(data, LOCK)), "lock should survive SIGKILL")
            expect_refused(Server(data), "lock_unavailable")   # never stolen
            print("RESTART_STALE_LOCK_REFUSED=PASS")
            os.remove(os.path.join(data, LOCK))                 # operator action
            server = Server(data)
            expect_ready(server)
            call("POST", "/users/login", 200, login("carol", "carol password"))
            print("RESTART_SIGKILL_ACKNOWLEDGED=PASS")
        else:
            print("RESTART_SIGKILL=SKIPPED (no SIGKILL on this platform)")
        server.quit()

        # -- corruption and truncation on disposable copies --------------------
        with open(os.path.join(data, JOURNAL), "rb") as handle:
            original = handle.read()
        require(len(original) > 200, "journal unexpectedly small")

        corrupt = copy_store(data, root, "corrupt")
        damaged = bytearray(original)
        damaged[60] ^= 0x5A
        with open(os.path.join(corrupt, JOURNAL), "wb") as handle:
            handle.write(damaged)
        expect_refused(Server(corrupt), None)
        print("RESTART_CORRUPTION_REFUSED=PASS")

        # Construct a torn frame with the NEXT expected sequence.
        # Reusing the first frame's header would be a sequence gap,
        # which recovery must classify as corruption, not a torn tail.
        offset = 0
        next_sequence = 1
        while offset < len(original):
            require(original[offset:offset + 4] == b"PRWJ",
                    "unexpected journal magic in test fixture")
            require(offset + 36 <= len(original),
                    "incomplete committed frame in test fixture")
            sequence = int.from_bytes(original[offset + 8:offset + 16], "big")
            require(sequence == next_sequence,
                    "unexpected journal sequence in test fixture")
            payload_length = int.from_bytes(
                original[offset + 32:offset + 36], "big"
            )
            offset += 44 + payload_length
            require(offset <= len(original),
                    "invalid committed frame length in test fixture")
            next_sequence += 1

        # Version 1 header: magic, version, flags, reserved, sequence,
        # transaction ID, payload length. Only 1 of 100 payload bytes
        # is present; the checksum is absent.
        torn_header = (
            b"PRWJ"
            + bytes([1, 0, 0, 0])
            + next_sequence.to_bytes(8, "big")
            + bytes([165]) * 16
            + (100).to_bytes(4, "big")
        )
        torn_tail = torn_header + b"{"
        require(len(torn_tail) == 37, "unexpected torn fixture length")

        torn = copy_store(data, root, "torn")
        with open(os.path.join(torn, JOURNAL), "wb") as handle:
            handle.write(original + torn_tail)
        expect_refused(Server(torn), "incomplete_tail_requires_repair")
        require(
            not os.path.exists(os.path.join(torn, LOCK)),
            "rejected recovery retained its lock after process exit"
        )
        with open(os.path.join(torn, JOURNAL), "rb") as handle:
            require(handle.read() == original + torn_tail,
                    "unauthorized recovery modified journal")
        server = Server(torn, extra_env={"REALWORLD_JOURNAL_REPAIR": "truncate-incomplete-tail"})
        expect_ready(server)
        call("POST", "/users/login", 200, login("bob", "bob password two"))
        server.quit()
        with open(os.path.join(torn, JOURNAL), "rb") as handle:
            require(handle.read() == original, "repair did not stop at the last complete frame")
        print("RESTART_TAIL_REPAIR=PASS")

        print("REALWORLD_RESTART_INTEGRATION=PASS")
        return 0
    except Failure as failure:
        print("REALWORLD_RESTART_INTEGRATION=FAIL: " + redact(str(failure)), file=sys.stderr)
        return 1
    finally:
        for server in STARTED:
            try:
                server.stop_quietly()
            except Exception:  # cleanup must continue for the others
                pass
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
