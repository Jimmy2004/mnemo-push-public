#!/usr/bin/env python3
"""VPS 接收端：接收手机 mnemo_push.py 推送的 NDJSON，校验签名后去重入库。

只监听 127.0.0.1，由 nginx 反代。签名：
    X-Push-Ts:  Unix 秒
    X-Push-Sig: hex(HMAC-SHA256(key, ts + "\n" + hex(sha256(body))))
时间偏差 > 300s 拒绝；同一签名只接受一次（防重放）。
"""
import hashlib, hmac, json, os, sqlite3, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = ("127.0.0.1", int(os.environ.get("MNEMO_PORT", "20953")))
KEY = open(os.environ.get("MNEMO_KEY_FILE", "/etc/mnemo-recv/key"), "rb").read().strip()
DB = os.environ.get("MNEMO_DB", "/var/lib/mnemo-recv/mnemo.db")
MAX_BODY = 64 * 1024 * 1024
SKEW = 300


def db():
    c = sqlite3.connect(DB, timeout=30)
    c.execute("pragma journal_mode=wal")
    c.executescript("""
    create table if not exists items(
      source_type text not null, id integer not null,
      time_ms integer, title text, text text, raw text not null,
      received_at integer not null,
      primary key(source_type, id));
    create index if not exists items_time on items(time_ms);
    create table if not exists seen_sigs(sig text primary key, at integer not null);
    """)
    return c


class H(BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""

    def log_message(self, fmt, *a):  # 不记录请求细节
        pass

    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self.reply(404, {})

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.reply(400, {})
        if n <= 0 or n > MAX_BODY:
            return self.reply(413, {})
        body = self.rfile.read(n)
        ts = self.headers.get("X-Push-Ts", "")
        sig = self.headers.get("X-Push-Sig", "")
        if not ts.isdigit() or abs(time.time() - int(ts)) > SKEW:
            return self.reply(404, {})
        exp = hmac.new(KEY, ts.encode() + b"\n" + hashlib.sha256(body).hexdigest().encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(exp, sig):
            return self.reply(404, {})  # 鉴权失败与不存在不可区分

        c = db()
        try:
            now = int(time.time())
            c.execute("delete from seen_sigs where at < ?", (now - 2 * SKEW,))
            try:
                c.execute("insert into seen_sigs values(?,?)", (sig, now))
            except sqlite3.IntegrityError:
                return self.reply(409, {"error": "replay"})
            new = 0
            for line in body.decode("utf-8").splitlines():
                if not line.strip():
                    continue
                r = json.loads(line)
                st, rid = str(r.get("sourceType", "")), r.get("id")
                if not st or rid is None:
                    continue
                cur = c.execute(
                    "insert into items(source_type,id,time_ms,title,text,raw,received_at) values(?,?,?,?,?,?,?) "
                    "on conflict(source_type,id) do update set time_ms=excluded.time_ms, title=excluded.title, "
                    "text=excluded.text, raw=excluded.raw, received_at=excluded.received_at "
                    "where length(excluded.raw) >= length(items.raw)",
                    (st, int(rid), r.get("timeMs"), r.get("title"), r.get("text"),
                     json.dumps(r, ensure_ascii=False), now))
                new += cur.rowcount
            c.commit()
            self.reply(200, {"ok": True, "upserted": new})
        except (ValueError, json.JSONDecodeError):
            c.rollback()
            self.reply(400, {})
        finally:
            c.close()


if __name__ == "__main__":
    db().close()
    ThreadingHTTPServer(LISTEN, H).serve_forever()
