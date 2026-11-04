#!/data/data/com.termux/files/usr/bin/python3
"""极米记得 -> VPS 增量同步（在手机 Termux 里运行）。

从 127.0.0.1:8723 的 mnemosyne gateway 只读拉取数据（HMAC 签名，与官方 bridge v10 一致），
写入本地队列；配置了 PUSH_URL 时再推送到 VPS。通行证 secret 永不离开手机。

配置文件 ~/.mnemo-push.env（chmod 600）：
    MNEMOSYNE_TOKEN=tokenId.secret     # 建议在 App 里为本脚本单独开一张通行证，需开启 full transcripts
    MNEMOSYNE_AGENT=custom             # 与通行证允许的 agent 一致
    PUSH_URL=                          # VPS 接收端地址，留空则只在本地积累
    PUSH_KEY=                          # VPS 推送密钥（与通行证无关）
用法：python mnemo_push.py [--days N]
"""
import hashlib, hmac, json, os, secrets, sys, time, urllib.request, urllib.error
from pathlib import Path

HOME = Path.home()
STATE = HOME / ".mnemo-push.state.json"
QUEUE = HOME / "mnemo-queue"
BASE = "http://127.0.0.1:8723"
BRIDGE_VERSION = "10"


def load_env():
    env = {}
    p = HOME / ".mnemo-push.env"
    if p.exists():
        for line in p.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    env.update({k: v for k, v in os.environ.items() if k.startswith(("MNEMOSYNE_", "PUSH_"))})
    return env


ENV = load_env()
TOKEN = ENV.get("MNEMOSYNE_TOKEN", "")
AGENT = ENV.get("MNEMOSYNE_AGENT", "custom").strip().lower()
if "." not in TOKEN.strip(".") :
    sys.exit("缺少或无效的 MNEMOSYNE_TOKEN（格式 tokenId.secret）")
TOKEN_ID, SECRET = TOKEN.split(".", 1)
KEY = SECRET.encode()


def gateway(name, args=None, timeout=60):
    """签名请求 gateway，并校验响应签名（防止端口被别的程序冒充）。"""
    path = "/v1/" + name
    body = "" if args is None else json.dumps(args, separators=(",", ":"))
    ts, nonce = str(int(time.time() * 1000)), secrets.token_hex(32)
    canonical = "\n".join(["mnemosyne-request-v1", TOKEN_ID, ts, nonce, "POST", path, AGENT, BRIDGE_VERSION, body])
    sig = hmac.new(KEY, canonical.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(BASE + path, data=body.encode(), method="POST", headers={
        "Content-Type": "application/json",
        "X-Mnemosyne-Agent": AGENT,
        "X-Mnemosyne-Bridge": BRIDGE_VERSION,
        "X-Mnemosyne-Request-Auth": ":".join(["v1", TOKEN_ID, ts, nonce, sig]),
    })
    # 本机回环不走代理
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        resp = opener.open(req, timeout=timeout)
        status, text = resp.status, resp.read().decode()
        rsig = resp.headers.get("X-Mnemosyne-Response-Auth", "")
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode()
        rsig = e.headers.get("X-Mnemosyne-Response-Auth", "")
    expect = hmac.new(KEY, "\n".join(["mnemosyne-response-v1", nonce, str(status), text]).encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expect, rsig):
        raise RuntimeError(f"{name}: 响应签名校验失败（HTTP {status}），停止")
    if status != 200:
        raise RuntimeError(f"{name}: HTTP {status} {text[:200]}")
    return json.loads(text)


def results(data):
    return data.get("results", []) if isinstance(data, dict) else []


def collect(state, days):
    items = []
    gateway("ping", timeout=5)  # bridge 用 1.5s，Termux 放宽

    # 1. 转录：按 id 增量翻页
    since = state.get("transcript_since_id", 0)
    while True:
        args = {"fullText": True, "limit": 200, "maxChars": 200000}
        args.update({"sinceId": since} if since else {"days": days})
        page = results(gateway("get_transcripts", args, timeout=180))
        if not page:
            break
        items += page
        newest = max(int(r.get("id", 0)) for r in page)
        if newest <= since:
            break
        since = newest
    state["transcript_since_id"] = since

    # 2. 其它来源：数据量小，按时间窗口全量拉，接收端按 (sourceType,id) 去重
    for src in ("meetings", "memories", "timeline_cards"):
        offset = 0
        while True:
            page = results(gateway("search_evidence", {"sources": [src], "days": days, "limit": 100, "offset": offset, "maxChars": 100000}, timeout=90))
            items += page
            if len(page) < 100:
                break
            offset += 100
    items += results(gateway("get_open_loops", {"days": days, "limit": 200}))
    return items


def push(path, url, key):
    body = path.read_bytes()
    ts = str(int(time.time()))
    sig = hmac.new(key.encode(), ts.encode() + b"\n" + hashlib.sha256(body).hexdigest().encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/x-ndjson", "User-Agent": "mnemo-push/1.0", "X-Push-Ts": ts, "X-Push-Sig": sig})
    with urllib.request.urlopen(req, timeout=60) as r:  # 走系统代理 / VPN
        return r.status == 200


def main():
    days = int(sys.argv[sys.argv.index("--days") + 1]) if "--days" in sys.argv else 2
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    QUEUE.mkdir(mode=0o700, exist_ok=True)

    items = collect(state, days)
    if items:
        f = QUEUE / f"{int(time.time())}.ndjson"
        f.write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items))
        os.chmod(f, 0o600)
    STATE.write_text(json.dumps(state))
    print(f"拉取 {len(items)} 条，transcript_since_id={state.get('transcript_since_id')}")

    url, key = ENV.get("PUSH_URL"), ENV.get("PUSH_KEY")
    if not (url and key):
        print("未配置 PUSH_URL/PUSH_KEY，数据留在", QUEUE)
        return
    for f in sorted(QUEUE.glob("*.ndjson")):
        try:
            if push(f, url, key):
                f.unlink()
                print("已推送", f.name)
        except Exception as e:
            print("推送失败，下次重试:", f.name, e)
            break


if __name__ == "__main__":
    main()
