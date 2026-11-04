#!/usr/bin/env python3
"""mnemo-push VPS 服务：接收手机推送（写）+ 为 Mac 端 MCP 提供只读查询（读）。

只监听 127.0.0.1，由 nginx 反代到同一个随机路径。写和读使用两把不同的密钥：

写（手机 App / Termux 脚本，PUSH_KEY = /etc/mnemo-recv/key）
    X-Push-Ts:  Unix 秒
    X-Push-Sig: hex(HMAC-SHA256(push_key, ts + "\n" + hex(sha256(body))))
    body: NDJSON，每行一条记录，按 (device, sourceType, id) 去重入库；device 为记录里的可选字段，默认 ""
          或 "ping:<nonce>"：只测试连通与密钥，返回 {"ok":true,"pong":true}

读（Mac MCP，READ_KEY = /etc/mnemo-recv/read.key）
    X-Read-Ts:  Unix 秒
    X-Read-Sig: hex(HMAC-SHA256(read_key, "read\n" + ts + "\n" + hex(sha256(body))))
    body: {"tool": "...", "args": {...}}
    响应头 X-Read-Resp-Sig = hex(HMAC-SHA256(read_key, "resp\n" + 请求签名 + "\n" + hex(sha256(响应体))))

两种请求都：时间偏差 > 300s 拒绝；同一签名只接受一次（防重放）；鉴权失败返回 404。
"""
import datetime, hashlib, hmac, json, os, sqlite3, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = ("127.0.0.1", int(os.environ.get("MNEMO_PORT", "20953")))
ETC = os.environ.get("MNEMO_ETC", "/etc/mnemo-recv")
DB = os.environ.get("MNEMO_DB", "/var/lib/mnemo-recv/mnemo.db")
MAX_BODY = 64 * 1024 * 1024
SKEW = 300
TZ = datetime.timezone(datetime.timedelta(hours=int(os.environ.get("MNEMO_TZ_HOURS", "8"))))

# 来源名：MCP 参数里的复数名 -> 库里的 sourceType
SOURCES = {"transcripts": "transcript", "meetings": "meeting", "memories": "memory",
           "timeline_cards": "card", "cards": "card", "todos": "todo", "open_loops": "todo"}


def read_key(name):
    try:
        return open(os.path.join(ETC, name), "rb").read().strip()
    except FileNotFoundError:
        return None


PUSH_KEY = read_key("key")
READ_KEY = read_key("read.key")


def db():
    c = sqlite3.connect(DB, timeout=30)
    c.row_factory = sqlite3.Row
    c.execute("pragma journal_mode=wal")
    c.executescript(SCHEMA)
    return c


SCHEMA = """
create table if not exists items(
  device text not null default '', source_type text not null, id integer not null,
  time_ms integer, title text, text text, raw text not null,
  received_at integer not null,
  primary key(device, source_type, id));
create index if not exists items_time on items(time_ms);
create table if not exists seen_sigs(sig text primary key, at integer not null);
"""


def migrate():
    """旧版主键为 (source_type, id)：迁移为 (device, source_type, id)，旧数据 device=''。"""
    c = sqlite3.connect(DB, timeout=30)
    try:
        cols = [r[1] for r in c.execute("pragma table_info(items)")]
        if cols and "device" not in cols:
            c.executescript("""
            begin;
            alter table items rename to items_v1;
            drop index if exists items_time;
            """ + SCHEMA + """
            insert into items(device,source_type,id,time_ms,title,text,raw,received_at)
              select '',source_type,id,time_ms,title,text,raw,received_at from items_v1;
            drop table items_v1;
            commit;
            """)
        else:
            c.executescript(SCHEMA)
    finally:
        c.close()


def _device(a):
    d = a.get("device")
    return None if d is None else str(d)


def sign(key, *parts):
    return hmac.new(key, "\n".join(parts).encode(), hashlib.sha256).hexdigest()


def sha(b):
    return hashlib.sha256(b).hexdigest()


# ---------------- 只读查询 ----------------

def _int(a, k, d, lo=None, hi=None):
    try:
        v = int(a.get(k, d))
    except (TypeError, ValueError):
        v = d
    if lo is not None:
        v = max(lo, v)
    if hi is not None:
        v = min(hi, v)
    return v


def _window(a):
    """fromMs/toMs 优先，否则 days（含今天）+ dayOffset（往前偏移天数）。返回 (from_ms, to_ms) 或 (None, None)。"""
    if a.get("fromMs") is not None or a.get("toMs") is not None:
        return _int(a, "fromMs", 0), _int(a, "toMs", 2 ** 62)
    if a.get("days") is None:
        return None, None
    days, offset = _int(a, "days", 7, 1, 3650), _int(a, "dayOffset", 0, 0, 3650)
    today = datetime.datetime.now(TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    end = today + datetime.timedelta(days=1 - offset)
    start = end - datetime.timedelta(days=days)
    return int(start.timestamp() * 1000), int(end.timestamp() * 1000)


def _rows(c, types, a, default_limit=20, order="time_ms desc", extra="", params=()):
    where, args = [], []
    if _device(a) is not None:
        where.append("device = ?")
        args.append(_device(a))
    if types:
        where.append("source_type in (%s)" % ",".join("?" * len(types)))
        args += types
    f, t = _window(a)
    if f is not None:
        where.append("time_ms >= ? and time_ms < ?")
        args += [f, t]
    q = (a.get("query") or "").strip()
    if q:
        for word in q.split()[:8]:  # 多个词：全部包含
            where.append("(coalesce(text,'') like ? or coalesce(title,'') like ?)")
            args += ["%" + word + "%"] * 2
    if extra:
        where.append(extra)
        args += list(params)
    limit = _int(a, "limit", default_limit, 1, 500)
    sql = "select raw from items %s order by %s limit ? offset ?" % (
        ("where " + " and ".join(where)) if where else "", order)
    return [json.loads(r["raw"]) for r in c.execute(sql, args + [limit, _int(a, "offset", 0, 0)])]


def _pack(tool, results, a, default_chars):
    """按 maxChars 截断总字符数，格式与手机 gateway 返回保持一致。"""
    budget, out, truncated = _int(a, "maxChars", default_chars, 200, 2_000_000), [], False
    for r in results:
        t = r.get("text") or ""
        if len(t) > budget:
            r = dict(r, text=t[:budget] + "…")
            truncated = True
        budget -= len(r.get("text") or "")
        out.append(r)
        if budget <= 0:
            truncated = truncated or len(out) < len(results)
            break
    return {"tool": tool, "results": out, "resultCount": len(out), "truncated": truncated, "source": "vps"}


def q_available_days(c, a):
    days, offset = _int(a, "days", 30, 1, 3650), _int(a, "offset", 0, 0, 3650)
    f, t = _window({"days": days, "dayOffset": offset})   # available_days 的 offset 表示往前偏移天数
    tz = "%+d hours" % (TZ.utcoffset(None).total_seconds() // 3600)
    dev = _device(a)
    rows = c.execute(
        "select date(time_ms/1000,'unixepoch',?) d, source_type, count(*) n from items "
        "where time_ms >= ? and time_ms < ? and (? is null or device = ?) group by d, source_type order by d",
        (tz, f, t, dev, dev)).fetchall()
    by = {}
    for r in rows:
        by.setdefault(r["d"], {})[r["source_type"]] = r["n"]
    res = [{"sourceType": "day", "title": d, "metadata": m,
            "text": ", ".join("%s=%d" % kv for kv in sorted(m.items()))} for d, m in sorted(by.items())]
    return {"tool": "available_days", "results": res, "resultCount": len(res), "source": "vps"}


def q_search_evidence(c, a):
    srcs = a.get("sources") or []
    types = sorted({SOURCES.get(s, s) for s in srcs}) if srcs else ["meeting", "memory", "card", "todo"]
    if a.get("includeTranscripts") and "transcript" not in types:
        types.append("transcript")
    return _pack("search_evidence", _rows(c, types, a, 20), a, 20000)


def q_get_transcripts(c, a):
    extra, params = "", ()
    if a.get("sinceId") is not None:
        extra, params = "id > ?", (_int(a, "sinceId", 0),)
    order = "id asc" if a.get("sinceId") is not None else "time_ms desc"
    return _pack("get_transcripts", _rows(c, ["transcript"], a, 50, order, extra, params), a, 40000)


def q_get_memory_item(c, a):
    st = SOURCES.get(a.get("sourceType", ""), a.get("sourceType", ""))
    dev = _device(a)
    r = c.execute("select raw from items where source_type=? and id=? and (? is null or device = ?) "
                  "order by received_at desc limit 1", (st, _int(a, "id", -1), dev, dev)).fetchone()
    return {"tool": "get_memory_item", "results": [json.loads(r["raw"])] if r else [], "resultCount": 1 if r else 0,
            "source": "vps"}


def q_get_open_loops(c, a):
    return _pack("get_open_loops", _rows(c, ["todo"], dict(a, days=a.get("days")), 50), a, 20000)


def q_sync_status(c, a):
    rows = c.execute("select device, source_type, count(*) n, max(time_ms) latest, max(received_at) recv "
                     "from items group by device, source_type").fetchall()
    fmt = lambda ms: datetime.datetime.fromtimestamp(ms / 1000, TZ).isoformat(timespec="seconds") if ms else None
    res = [{"device": r["device"], "sourceType": r["source_type"], "count": r["n"], "latestItem": fmt(r["latest"]),
            "lastReceived": fmt((r["recv"] or 0) * 1000)} for r in rows]
    return {"tool": "sync_status", "results": res, "resultCount": len(res), "source": "vps"}


QUERIES = {
    "available_days": q_available_days,
    "search_evidence": q_search_evidence,
    "get_transcripts": q_get_transcripts,
    "get_memory_item": q_get_memory_item,
    "get_open_loops": q_get_open_loops,
    "sync_status": q_sync_status,
}


# ---------------- HTTP ----------------

class H(BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""

    def log_message(self, fmt, *a):  # 不记录请求细节
        pass

    def reply(self, code, obj, headers=None):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)
        return b

    def do_GET(self):
        self.reply(404, {})

    def _fresh(self, c, sig):
        now = int(time.time())
        c.execute("delete from seen_sigs where at < ?", (now - 2 * SKEW,))
        try:
            c.execute("insert into seen_sigs values(?,?)", (sig, now))
            c.commit()
            return True
        except sqlite3.IntegrityError:
            return False

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.reply(400, {})
        if n <= 0 or n > MAX_BODY:
            return self.reply(413, {})
        body = self.rfile.read(n)
        if self.headers.get("X-Read-Sig"):
            return self.handle_read(body)
        return self.handle_push(body)

    def _check(self, key, ts, sig, *parts):
        if not key or not ts.isdigit() or abs(time.time() - int(ts)) > SKEW:
            return False
        return hmac.compare_digest(sign(key, *parts), sig)

    def handle_read(self, body):
        ts, sig = self.headers.get("X-Read-Ts", ""), self.headers.get("X-Read-Sig", "")
        if not self._check(READ_KEY, ts, sig, "read", ts, sha(body)):
            return self.reply(404, {})
        c = db()
        try:
            if not self._fresh(c, sig):
                return self.reply(409, {"error": "replay"})
            try:
                req = json.loads(body)
                fn = QUERIES[req.get("tool", "")]
                args = req.get("args") or {}
                if not isinstance(args, dict):
                    raise ValueError
                out, code = fn(c, args), 200
            except (KeyError, ValueError, TypeError, json.JSONDecodeError):
                out, code = {"error": "bad request", "tools": sorted(QUERIES)}, 400
            b = json.dumps(out, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(b)))
            self.send_header("X-Read-Resp-Sig", sign(READ_KEY, "resp", sig, sha(b)))
            self.end_headers()
            self.wfile.write(b)
        finally:
            c.close()

    def handle_push(self, body):
        ts, sig = self.headers.get("X-Push-Ts", ""), self.headers.get("X-Push-Sig", "")
        # 推送签名格式沿用 v1：HMAC(key, ts + "\n" + sha256hex(body))
        if not self._check(PUSH_KEY, ts, sig, ts, sha(body)):
            return self.reply(404, {})  # 鉴权失败与不存在不可区分
        c = db()
        try:
            if not self._fresh(c, sig):
                return self.reply(409, {"error": "replay"})
            if body.startswith(b"ping:"):
                return self.reply(200, {"ok": True, "pong": True})
            now, new = int(time.time()), 0
            for line in body.decode("utf-8").splitlines():
                if not line.strip():
                    continue
                r = json.loads(line)
                st, rid = str(r.get("sourceType", "")), r.get("id")
                if not st or rid is None:
                    continue
                dev = str(r.get("device") or "")[:64]
                cur = c.execute(
                    "insert into items(device,source_type,id,time_ms,title,text,raw,received_at) values(?,?,?,?,?,?,?,?) "
                    "on conflict(device,source_type,id) do update set time_ms=excluded.time_ms, title=excluded.title, "
                    "text=excluded.text, raw=excluded.raw, received_at=excluded.received_at "
                    "where length(excluded.raw) >= length(items.raw)",
                    (dev, st, int(rid), r.get("timeMs"), r.get("title"), r.get("text"),
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
    migrate()
    ThreadingHTTPServer(LISTEN, H).serve_forever()
