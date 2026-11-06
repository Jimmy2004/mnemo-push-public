#!/usr/bin/env python3
"""Local orchestration; no third-party Python dependencies. Invoked by run_local_e2e.sh."""
import collections
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

TOOLS = Path(__file__).resolve().parent
EXPECTED = {"transcript": 250, "meeting": 3, "memory": 120, "card": 5, "todo": 4}
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def post(url, body, headers):
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with HTTP.open(request, timeout=2) as response:
            return response.status, response.read(), response.headers
    except urllib.error.HTTPError as error:
        return error.code, error.read(), error.headers


def push(url, key, body):
    ts = str(int(time.time()))
    sig = hmac.new(key.encode(), (ts + "\n" + hashlib.sha256(body).hexdigest()).encode(), hashlib.sha256).hexdigest()
    headers = {"X-Push-Ts": ts, "X-Push-Sig": sig, "Content-Type": "application/x-ndjson"}
    return post(url, body, headers), headers


def wait_ready(label, child, probe, logfile):
    print(f"I am waiting for {label}. The completion condition is a valid signed ping response. Per-round timeout is 20 seconds.", flush=True)
    deadline = time.monotonic() + 20
    while True:
        require(child.poll() is None, f"{label} exited; log: {logfile.read_text()[-2000:]}")
        try:
            if probe():
                print(f"PASS {label} ready", flush=True)
                return
        except (OSError, ValueError):
            pass
        remaining = deadline - time.monotonic()
        require(remaining > 0, f"{label} readiness timeout; log: {logfile.read_text()[-2000:]}")
        # Condition polling, never an assumed startup delay.
        time.sleep(min(2, remaining))


def gateway_probe(url, token):
    tid, secret = token.split(".", 1)
    ts, nonce = str(int(time.time() * 1000)), secrets.token_hex(32)
    canonical = "\n".join(["mnemosyne-request-v1", tid, ts, nonce, "POST", "/v1/ping", "claude", "10", ""])
    signature = hmac.new(secret.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    code, body, headers = post(url + "/v1/ping", b"", {
        "X-Mnemosyne-Agent": "claude", "X-Mnemosyne-Bridge": "10",
        "X-Mnemosyne-Request-Auth": f"v1:{tid}:{ts}:{nonce}:{signature}"})
    expected = hmac.new(secret.encode(), f"mnemosyne-response-v1\n{nonce}\n{code}\n".encode() + body, hashlib.sha256).hexdigest()
    return code == 200 and hmac.compare_digest(expected, headers.get("X-Mnemosyne-Response-Auth", ""))


def main():
    require(len(sys.argv) == 1, "Usage: bash tools/run_local_e2e.sh")
    require(shutil.which("swift") is not None, "Swift 5.9+ required (Xcode Command Line Tools)")
    children, handles = [], []
    with tempfile.TemporaryDirectory(prefix="mnemo-local-e2e-") as tmp:
        root = Path(tmp)
        try:
            token, key = secrets.token_hex(8) + "." + secrets.token_hex(32), secrets.token_hex(32)
            gateway_port, recv_port = port(), port()
            while recv_port == gateway_port:
                recv_port = port()
            etc = root / "etc"
            etc.mkdir(mode=0o700)
            (etc / "key").write_text(key)
            (etc / "key").chmod(0o600)
            db = root / "mnemo.db"
            env = dict(os.environ, FAKE_GATEWAY_TOKEN=token)
            recv_env = dict(os.environ, MNEMO_ETC=str(etc), MNEMO_DB=str(db), MNEMO_PORT=str(recv_port))
            specs = [
                ("gateway", [sys.executable, str(TOOLS / "fake_gateway.py"), "--port", str(gateway_port), "--log"], env),
                ("receiver", [sys.executable, str(TOOLS.parent / "server/mnemo_recv.py")], recv_env),
            ]
            for label, command, child_env in specs:
                logfile = root / (label + ".log")
                handle = logfile.open("w")
                handles.append(handle)
                child = subprocess.Popen(command, cwd=root, env=child_env, stdout=handle, stderr=handle)
                children.append(child)
                url = f"http://127.0.0.1:{gateway_port if label == 'gateway' else recv_port}"
                if label == "gateway":
                    probe = lambda: gateway_probe(url, token)
                else:
                    probe = lambda: push(url, key, ("ping:" + secrets.token_hex(16)).encode())[0][0] == 200
                wait_ready(label, child, probe, logfile)
            recv_url = f"http://127.0.0.1:{recv_port}/local-test"
            all_expected = {}
            for index, device in enumerate(["", "mac-e2e"]):
                state = root / f"state-{index}"
                command = ["swift", "run", "--package-path", str(TOOLS / "e2e"), "mnemo-e2e",
                           "--token", token, "--port", str(gateway_port), "--device", device,
                           "--days", "0", "--rounds", "2", "--state-dir", str(state), "--keep-state"]
                print(f"Running MnemoCore: device={device!r} (build/run timeout 300s)", flush=True)
                # Synchronous child completion is the condition; no guessed delay.
                try:
                    result = subprocess.run(command, timeout=300, check=False)
                except subprocess.TimeoutExpired:
                    raise RuntimeError("Swift build/run timed out after 300 seconds") from None
                require(result.returncode == 0, f"Swift harness failed: exit {result.returncode}")
                files = sorted((state / "queue").glob("*.ndjson"))
                require(bool(files), "Swift produced no NDJSON queue")
                records = {}
                for file in files:
                    for line in file.read_text().splitlines():
                        item = json.loads(line)
                        require(item.get("device", "") == device, "queue device mismatch")
                        records[(item["sourceType"], int(item["id"]))] = item
                    body = file.read_bytes()
                    (code, response, _), headers = push(recv_url, key, body)
                    require(code == 200 and json.loads(response).get("ok"), f"push failed HTTP {code}")
                    require(post(recv_url, body, headers)[0] == 409, "receiver must reject exact signature replay")
                    # Distinct body/signature; same records must upsert without new rows.
                    require(push(recv_url, key, body + b"\n")[0][0] == 200, "dedup repost failed")
                counts = dict(collections.Counter(st for st, _ in records))
                require(counts == EXPECTED, f"queue pagination incomplete: {counts}, expected {EXPECTED}")
                all_expected.update({(device, st, rid): item for (st, rid), item in records.items()})
                with sqlite3.connect(db) as conn:
                    actual = {(d, st, rid): json.loads(raw) for d, st, rid, raw in conn.execute(
                        "select device,source_type,id,raw from items")}
                    require(actual == all_expected, "SQLite records/device isolation/dedup mismatch")
                    require(conn.execute("select count(*) from items").fetchone()[0] == len(all_expected), "row count mismatch")
                print(f"PASS device={device!r}: {counts}; replay rejected; duplicate records deduplicated", flush=True)
            print("PASS local E2E: gateway signatures → MnemoCore pull/queue → Python signed HTTP → receiver SQLite (764 unique rows)", flush=True)
        finally:
            for child in reversed(children):
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
            for handle in handles:
                handle.close()


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print(f"FAIL {error}", file=sys.stderr)
        sys.exit(1)
