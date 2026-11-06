#!/usr/bin/env python3
"""Fictional bridge-v10 gateway for local development; Python standard library only."""
import argparse
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import secrets
import sys
import threading
import time

SOURCES = {"meetings": "meeting", "memories": "memory", "timeline_cards": "card"}
COUNTS = {"transcript": 250, "meeting": 3, "memory": 120, "card": 5, "todo": 4}
DAY = 86400000


def sign(secret, data):
    return hmac.new(secret, data, hashlib.sha256).hexdigest()


class State:
    def __init__(self, token, logging):
        self.token_id, secret = token.split(".", 1)
        self.secret = secret.encode()
        self.logging = logging
        self.lock = threading.Lock()
        self.nonces = set()
        now = int(time.time() * 1000)
        self.items = {}
        for kind, count in COUNTS.items():
            self.items[kind] = [self.record(kind, i, now - ((count - i) % 30) * DAY - 60000)
                                for i in range(1, count + 1)]

    @staticmethod
    def record(kind, rid, stamp):
        return {"sourceType": kind, "id": rid, "timeMs": stamp,
                "title": f"虚构测试 {kind} #{rid}", "text": f"测试数据 #{rid}（{kind}，完全虚构）"}

    def add(self, count):
        with self.lock:
            last = self.items["transcript"][-1]["id"]
            now = int(time.time() * 1000)
            self.items["transcript"].extend(self.record("transcript", last + i, now) for i in range(1, count + 1))

    def results(self, tool, args):
        def integer(key, default, low=0, high=1000000):
            v = args.get(key, default)
            if isinstance(v, bool) or not isinstance(v, int) or not low <= v <= high:
                raise ValueError(f"invalid {key}")
            return v

        limit = integer("limit", 50, 1, 10000)
        days = integer("days", 0, 0, 3650)
        cutoff = int(time.time() * 1000) - days * DAY if days else 0
        if tool == "ping":
            return []
        with self.lock:
            if tool == "get_transcripts":
                since = integer("sinceId", 0, 0, 2**63 - 1)
                rows = [dict(r) for r in self.items["transcript"] if r["id"] > since and r["timeMs"] >= cutoff]
                rows.sort(key=lambda r: r["id"])
                rows = rows[:limit]
                if "fullText" in args and not isinstance(args["fullText"], bool):
                    raise ValueError("fullText must be boolean")
                if not args.get("fullText", False):
                    rows = [dict(r, text=r["text"][:200]) for r in rows]
            elif tool == "search_evidence":
                sources = args.get("sources", list(SOURCES))
                if not isinstance(sources, list) or any(not isinstance(s, str) or s not in SOURCES for s in sources):
                    raise ValueError("sources must contain meetings/memories/timeline_cards")
                rows = [dict(r) for src in dict.fromkeys(sources) for r in self.items[SOURCES[src]] if r["timeMs"] >= cutoff]
                rows.sort(key=lambda r: (-r["timeMs"], r["sourceType"], r["id"]))
                offset = integer("offset", 0)
                rows = rows[offset:offset + limit]
            elif tool == "get_open_loops":
                rows = [dict(r) for r in self.items["todo"] if r["timeMs"] >= cutoff][:limit]
            else:
                raise KeyError(tool)
        budget = integer("maxChars", 200000, 0, 2000000)
        out = []
        for r in rows:
            if budget <= 0:
                break
            r["text"] = r["text"][:budget]
            budget -= len(r["text"])
            out.append(r)
        return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    @property
    def state(self):
        return self.server.state

    def nonce(self):
        parts = self.headers.get("X-Mnemosyne-Request-Auth", "").split(":")
        return parts[3] if len(parts) >= 4 and parts[3] else None

    def reply(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        nonce = self.nonce()
        if nonce is not None:
            canonical = f"mnemosyne-response-v1\n{nonce}\n{status}\n".encode() + body
            self.send_header("X-Mnemosyne-Response-Auth", sign(self.state.secret, canonical))
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def authorized(self, body):
        # Duplicate security headers are ambiguous and rejected.
        for name in ["X-Mnemosyne-Request-Auth", "X-Mnemosyne-Agent", "X-Mnemosyne-Bridge", "Content-Length"]:
            if len(self.headers.get_all(name, [])) != 1:
                return False
        parts = self.headers.get("X-Mnemosyne-Request-Auth", "").split(":")
        if len(parts) != 5:
            return False
        version, tid, ts, nonce, sig = parts
        agent = self.headers.get("X-Mnemosyne-Agent", "").lower()
        if (version != "v1" or tid != self.state.token_id or not nonce or
                self.headers.get("X-Mnemosyne-Bridge") != "10" or not agent or
                not re.fullmatch(r"[0-9]{13}", ts) or
                abs(int(time.time() * 1000) - int(ts)) > 300000 or
                not re.fullmatch(r"[0-9a-f]{64}", sig)):
            return False
        canonical = "\n".join(["mnemosyne-request-v1", tid, ts, nonce, "POST", self.path, agent, "10"]).encode() + b"\n" + body
        if not hmac.compare_digest(sign(self.state.secret, canonical), sig):
            return False
        with self.state.lock:
            if nonce in self.state.nonces:
                return False
            # Retain all accepted nonces for the lifetime of this test server.
            self.state.nonces.add(nonce)
        return True

    def do_POST(self):
        try:
            if self.headers.get("Transfer-Encoding"):
                return self.reply(401, {"error": "unsupported framing"})
            try:
                length = int(self.headers.get("Content-Length", "-1"))
            except ValueError:
                return self.reply(401, {"error": "invalid body length"})
            if not 0 <= length <= 4 * 1024 * 1024:
                return self.reply(401, {"error": "invalid body length"})
            self.connection.settimeout(10)
            body = self.rfile.read(length)
            if len(body) != length or not self.authorized(body):
                return self.reply(401, {"error": "unauthorized"})
            if not re.fullmatch(r"/v1/[a-z_]+", self.path):
                return self.reply(404, {"error": "unknown path"})
            tool = self.path[4:]
            args = json.loads(body) if body else {}
            if not isinstance(args, dict):
                raise ValueError("parameters must be object")
            rows = self.state.results(tool, args)
            if self.state.logging:
                # Only supported tool parameters, never arbitrary credential-like input.
                allowed = {k: args[k] for k in ("days", "sinceId", "limit", "fullText", "maxChars", "sources", "offset") if k in args}
                print(f"{tool} args={json.dumps(allowed, ensure_ascii=False)} count={len(rows)}", file=sys.stderr, flush=True)
            self.reply(200, {"results": rows})
        except KeyError:
            self.reply(404, {"error": "unknown tool"})
        except (ValueError, UnicodeError):
            self.reply(400, {"error": "invalid parameters"})
        except (OSError, TimeoutError):
            self.close_connection = True

    def reject_method(self):
        self.reply(405, {"error": "POST required"})

    do_GET = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = reject_method


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8723)
    parser.add_argument("--token", default=os.environ.get("FAKE_GATEWAY_TOKEN"))
    parser.add_argument("--add", type=int, default=0)
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--log", action="store_true")
    args = parser.parse_args()
    if args.add < 0 or not 0 < args.interval < float("inf") or not 0 <= args.port <= 65535:
        parser.error("invalid add/interval/port")
    token = args.token
    if token is None:
        token = secrets.token_hex(8) + "." + secrets.token_hex(32)
        print(f"Local test token: {token}", file=sys.stderr, flush=True)
    if not re.fullmatch(r"[^.\s:]+\.[^\s:]+", token):
        parser.error("token must be tokenId.secret")
    state = State(token, args.log)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    server.state = state
    stop = threading.Event()

    def additions():
        while not stop.wait(args.interval):
            state.add(args.add)

    if args.add:
        threading.Thread(target=additions, daemon=True).start()
    print(f"Fake gateway listening on {server.server_address[0]}:{server.server_address[1]}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()


if __name__ == "__main__":
    main()
