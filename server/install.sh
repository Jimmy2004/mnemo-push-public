#!/bin/sh
# mnemo-push VPS 接收端一键安装（幂等，可重复运行）
#
# 用法（在 VPS 上，以 root 运行，当前目录为 server/）：
#   sh install.sh --domain example.com          安装 + 自动接入 nginx 中 server_name 为该域名的站点
#   sh install.sh --no-nginx                     只安装服务，nginx 自己配置
#   sh install.sh --show                         重新显示 PUSH_URL / PUSH_KEY
#   sh install.sh --rotate-key                   更换推送密钥（手机需重新粘贴）
#   sh install.sh --rotate-read-key              更换 Mac MCP 只读密钥（Mac 需重新配置）
#   sh install.sh --uninstall [--purge]          卸载（--purge 同时删除数据库和密钥）
# 其它选项：--port N（默认 20953） --nginx-conf FILE（不自动查找） --yes（不确认）
set -eu

PORT=20953
DOMAIN=""
NGINX_CONF=""
MODE=install
NO_NGINX=0
PURGE=0
ASSUME_YES=0

ETC=/etc/mnemo-recv
LIB=/usr/local/lib/mnemo_recv.py
DATA=/var/lib/mnemo-recv
UNIT=/etc/systemd/system/mnemo-recv.service
MARK="# mnemo-recv"
HERE=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN=${2:?}; shift ;;
    --port) PORT=${2:?}; shift ;;
    --nginx-conf) NGINX_CONF=${2:?}; shift ;;
    --no-nginx) NO_NGINX=1 ;;
    --show) MODE=show ;;
    --rotate-key) MODE=rotate ;;
    --rotate-read-key) MODE=rotate_read ;;
    --uninstall) MODE=uninstall ;;
    --purge) PURGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "未知参数：$1（--help 查看用法）" ;;
  esac
  shift
done

[ "$(id -u)" = 0 ] || die "请以 root 运行"
command -v systemctl >/dev/null || die "需要 systemd"
command -v python3 >/dev/null || die "需要 python3（apt install python3 / dnf install python3）"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "需要 Python 3.8+"
case "$PORT" in *[!0-9]*|'') die "--port 必须是数字" ;; esac

# ---------- nginx 辅助 ----------
find_conf() {   # 找到包含 server_name $DOMAIN 的配置文件
  [ -n "$NGINX_CONF" ] && { echo "$NGINX_CONF"; return; }
  grep -rlsE "server_name[^;]*[[:space:]]$DOMAIN[[:space:];]" /etc/nginx /etc/s-ui-edge /usr/local/nginx/conf /www/server/nginx/conf 2>/dev/null | head -1
}

main_conf_for() {   # 找到加载该文件的主配置（用于 nginx -t / reload）
  f=$1
  if grep -q "^[[:space:]]*http[[:space:]]*{" "$f"; then echo "$f"; return; fi
  for m in /etc/nginx/nginx.conf /usr/local/nginx/conf/nginx.conf /www/server/nginx/conf/nginx.conf; do
    [ -f "$m" ] && { echo "$m"; return; }
  done
  echo "$f"
}

reload_nginx() {   # 优先使用加载该主配置的 systemd 服务
  m=$1
  svc=$(grep -lsE "ExecStart=.*nginx.*-c[[:space:]]*$m" /etc/systemd/system/*.service /lib/systemd/system/*.service 2>/dev/null | head -1)
  if [ -n "$svc" ]; then systemctl reload "$(basename "$svc")"
  elif [ "$m" = /etc/nginx/nginx.conf ] && systemctl is-active -q nginx; then systemctl reload nginx
  else nginx -s reload -c "$m"; fi
}

nginx_add() {   # 在 server_name 为 $DOMAIN 的 server 块末尾插入 location（备份 + 校验 + 失败回滚）
  conf=$1; path=$2
  if grep -q "$MARK" "$conf"; then
    ok "nginx 已有 mnemo-recv 路径，跳过"
    return
  fi
  main=$(main_conf_for "$conf")
  bak="$conf.bak-mnemo-$(date +%s)"
  cp -p "$conf" "$bak"
  python3 -I - "$conf" "$DOMAIN" "$path" "$PORT" "$MARK" <<'PY'
import re, sys
conf, domain, path, port, mark = sys.argv[1:]
s = open(conf).read()
# 逐个 server 块匹配大括号，找到 server_name 含该域名的那个
for m in re.finditer(r'\bserver\s*\{', s):
    i, depth = m.end(), 1
    while depth and i < len(s):
        depth += {'{': 1, '}': -1}.get(s[i], 0); i += 1
    block = s[m.start():i]
    if re.search(r'server_name[^;]*\s' + re.escape(domain) + r'[\s;]', block):
        loc = ("\n  location = /%s { %s\n    client_max_body_size 64m;\n    proxy_pass http://127.0.0.1:%s;\n"
               "    proxy_request_buffering on; proxy_read_timeout 120s;\n"
               "    add_header Cache-Control \"no-store\" always;\n  }\n") % (path, mark, port)
        s = s[:i - 1] + loc + s[i - 1:]
        open(conf, 'w').write(s)
        sys.exit(0)
sys.exit("在 %s 中没有找到 server_name 为 %s 的 server 块" % (conf, domain))
PY
  if nginx -t -c "$main" >/dev/null 2>&1; then
    reload_nginx "$main"
    ok "已接入 nginx：$conf（备份：$bak）"
  else
    cp -p "$bak" "$conf"
    nginx -t -c "$main" || true
    die "nginx 配置校验失败，已恢复原配置"
  fi
}

nginx_remove() {
  for f in $(grep -rlsF "$MARK" /etc/nginx /etc/s-ui-edge /usr/local/nginx/conf /www/server/nginx/conf 2>/dev/null); do
    cp -p "$f" "$f.bak-mnemo-$(date +%s)"
    python3 -I - "$f" "$MARK" <<'PY'
import re, sys
f, mark = sys.argv[1:]
s = open(f).read()
s = re.sub(r'\n?[ \t]*location = /\S+ \{ ' + re.escape(mark) + r'.*?\n[ \t]*\}\n', '\n', s, flags=re.S)
open(f, 'w').write(s)
PY
    main=$(main_conf_for "$f")
    nginx -t -c "$main" >/dev/null 2>&1 && reload_nginx "$main" && ok "已从 $f 移除 nginx 路径"
  done
}

push_url() {
  p=$(cat "$ETC/path")
  host=$DOMAIN
  [ -z "$host" ] && [ -f "$ETC/domain" ] && host=$(cat "$ETC/domain")
  if [ -n "$host" ]; then echo "https://$host/$p"; else echo "https://<你的域名>/$p"; fi
}

new_key() {   # $1 = 文件名
  (umask 027; python3 -c "import secrets;print(secrets.token_hex(32))" > "$ETC/$1.new")
  chgrp mnemo "$ETC/$1.new"; chmod 640 "$ETC/$1.new"; mv -f "$ETC/$1.new" "$ETC/$1"
}

show() {
  [ -f "$ETC/key" ] || die "尚未安装"
  echo
  echo "────────── ① 手机：复制下面两行，在 App「② 云端」点「粘贴推送配置」 ──────────"
  echo "PUSH_URL=$(push_url)"
  echo "PUSH_KEY=$(cat "$ETC/key")"
  echo
  echo "────────── ② Mac：在本机终端运行下面这条，安装只读 MCP（需先 clone 仓库） ──────────"
  echo "sh mcp/install.sh --url '$(push_url)' --read-key '$(cat "$ETC/read.key")'"
  echo "──────────────────────────────────────────────────────────────────────────────"
  echo "（两把密钥只显示在本终端：写密钥给手机，读密钥给 Mac，互不通用。"
  echo "  请勿发到聊天或提交到仓库；重新显示：sh install.sh --show）"
}

selftest() {   # 本机直连接收端，用正确签名推一条测试数据，验证后删除
  python3 -I - "$PORT" "$ETC/key" <<'PY'
import hashlib, hmac, json, sys, time, urllib.request
port, keyfile = sys.argv[1:]
key = open(keyfile, 'rb').read().strip()
body = json.dumps({"sourceType": "_selftest", "id": 1, "text": "ok"}).encode()
ts = str(int(time.time()))
sig = hmac.new(key, ts.encode() + b"\n" + hashlib.sha256(body).hexdigest().encode(), hashlib.sha256).hexdigest()
req = urllib.request.Request("http://127.0.0.1:%s/" % port, data=body, method="POST",
                             headers={"X-Push-Ts": ts, "X-Push-Sig": sig})
for _ in range(10):
    try:
        print(json.load(urllib.request.urlopen(req, timeout=5))); break
    except Exception as e:
        err = e; time.sleep(1)
else:
    sys.exit("自检失败：%s" % err)
PY
  python3 -I - "$PORT" "$ETC/read.key" <<'PY'
import hashlib, hmac, json, sys, time, urllib.request, secrets
port, keyfile = sys.argv[1:]
key = open(keyfile, 'rb').read().strip()
body = json.dumps({"tool": "sync_status", "args": {}, "nonce": secrets.token_hex(8)}).encode()
ts = str(int(time.time()))
sig = hmac.new(key, b"read\n" + ts.encode() + b"\n" + hashlib.sha256(body).hexdigest().encode(), hashlib.sha256).hexdigest()
r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:%s/" % port, data=body, method="POST",
        headers={"X-Read-Ts": ts, "X-Read-Sig": sig}), timeout=5)
raw = r.read()
exp = hmac.new(key, b"resp\n" + sig.encode() + b"\n" + hashlib.sha256(raw).hexdigest().encode(), hashlib.sha256).hexdigest()
assert hmac.compare_digest(exp, r.headers.get("X-Read-Resp-Sig", "")), "读接口响应签名不匹配"
print("read ok:", [(x["sourceType"], x["count"]) for x in json.loads(raw)["results"]])
PY
  python3 -I -c "import sqlite3;c=sqlite3.connect('$DATA/mnemo.db');c.execute(\"delete from items where source_type='_selftest'\");c.commit()"
}

# ---------- 各模式 ----------
case "$MODE" in
show) show; exit 0 ;;

rotate|rotate_read)
  [ -f "$ETC/key" ] || die "尚未安装"
  if [ "$MODE" = rotate ]; then new_key key; ok "已更换推送密钥，手机需重新粘贴"
  else new_key read.key; ok "已更换只读密钥，Mac 需重新运行 mcp/install.sh"; fi
  systemctl restart mnemo-recv
  show; exit 0 ;;

uninstall)
  if [ "$ASSUME_YES" = 0 ]; then
    printf '确认卸载 mnemo-recv%s？[y/N] ' "$([ $PURGE = 1 ] && echo '（并删除所有已同步数据和密钥）')"
    read -r a; [ "$a" = y ] || [ "$a" = Y ] || exit 1
  fi
  systemctl disable --now mnemo-recv 2>/dev/null || true
  rm -f "$UNIT" "$LIB"; systemctl daemon-reload
  nginx_remove
  if [ "$PURGE" = 1 ]; then rm -rf "$ETC" "$DATA"; userdel mnemo 2>/dev/null || true; ok "已卸载并清除数据"
  else ok "已卸载（数据保留在 $DATA，密钥保留在 $ETC）"; fi
  exit 0 ;;
esac

# ---------- 安装 ----------
[ -f "$HERE/mnemo_recv.py" ] || die "找不到 $HERE/mnemo_recv.py，请在 server/ 目录内运行"
[ "$NO_NGINX" = 1 ] || [ -n "$DOMAIN" ] || [ -n "$NGINX_CONF" ] || \
  die "请指定 --domain 你的域名（接入 nginx），或 --no-nginx 自行配置"
if [ "$NO_NGINX" = 0 ]; then
  command -v nginx >/dev/null || die "未找到 nginx；可改用 --no-nginx"
  [ -n "$DOMAIN" ] || die "--nginx-conf 需要配合 --domain 使用"
fi

say "1/5 创建用户与目录"
id mnemo >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin mnemo
install -d -m 750 -o root -g mnemo "$ETC"
install -d -m 700 -o mnemo -g mnemo "$DATA"
ok "用户 mnemo、$ETC、$DATA"

say "2/5 生成推送密钥、只读密钥与随机路径（已存在则保留）"
[ -f "$ETC/key" ]      || new_key key
[ -f "$ETC/read.key" ] || new_key read.key
chgrp mnemo "$ETC/key" "$ETC/read.key"; chmod 640 "$ETC/key" "$ETC/read.key"
[ -f "$ETC/path" ] || python3 -c "import secrets;print(secrets.token_urlsafe(24))" > "$ETC/path"
[ -n "$DOMAIN" ] && echo "$DOMAIN" > "$ETC/domain"
ok "密钥与路径就绪"

say "3/5 安装接收服务（127.0.0.1:$PORT）"
if ss -ltn 2>/dev/null | grep -q "127.0.0.1:$PORT " && ! systemctl is-active -q mnemo-recv; then
  die "端口 $PORT 已被其它程序占用，请用 --port 指定其它端口"
fi
install -m 644 "$HERE/mnemo_recv.py" "$LIB"
cat > "$UNIT" <<EOF
[Unit]
Description=Mnemosyne push receiver
After=network.target

[Service]
User=mnemo
Group=mnemo
Environment=MNEMO_PORT=$PORT
ExecStart=/usr/bin/env python3 -I $LIB
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q mnemo-recv
systemctl restart mnemo-recv
ok "mnemo-recv 已启动"

say "4/5 自检（本机签名推送一条测试数据）"
selftest
ok "写入、只读查询、签名校验均正常（测试数据已删除）"

say "5/5 接入 nginx"
if [ "$NO_NGINX" = 1 ]; then
  warn "已跳过。请在你的 HTTPS 站点里加入："
  printf '  location = /%s {\n    client_max_body_size 64m;\n    proxy_pass http://127.0.0.1:%s;\n  }\n' "$(cat "$ETC/path")" "$PORT"
else
  conf=$(find_conf)
  [ -n "$conf" ] || die "在常见目录中找不到 server_name 为 $DOMAIN 的 nginx 配置，请用 --nginx-conf 指定"
  nginx_add "$conf" "$(cat "$ETC/path")"
fi

ok "安装完成"
show
