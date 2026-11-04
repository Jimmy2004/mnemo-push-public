#!/data/data/com.termux/files/usr/bin/bash
# 只读探测本机 MCP 服务：不写入、不修改任何数据。
# 用法: bash probe.sh [端口] [pass(可选)]
PORT=${1:-8723}
PASS=${2:-}
BASE="http://127.0.0.1:$PORT"
AUTH=()
[ -n "$PASS" ] && AUTH=(-H "Authorization: Bearer $PASS")

# 输出时把长 token/uuid 打码
mask() { sed -E 's/([A-Za-z0-9_-]{6})[A-Za-z0-9_.-]{18,}/\1***/g'; }

echo "== 1. 端口连通性 ($BASE)"
code=$(curl -s -m2 -o /dev/null -w "%{http_code}" "$BASE/")
if [ "$code" = "000" ]; then
  echo "127.0.0.1:$PORT 无响应 -> 服务可能只绑定在 Tailscale 网卡上"
  exit 1
fi
echo "/ -> HTTP $code"

echo; echo "== 2. 常见路径"
for p in /mcp /mcp/ /sse /health /status /api /v1; do
  r=$(curl -s -m3 -o /tmp/probe_b -w "%{http_code} %{content_type}" "${AUTH[@]}" "$BASE$p")
  printf "%-8s %s  " "$p" "$r"; head -c 120 /tmp/probe_b | tr '\n' ' ' | mask; echo
done

echo; echo "== 3. MCP initialize 握手 (POST /mcp)"
curl -s -m5 -D /tmp/probe_h -o /tmp/probe_b -X POST "$BASE/mcp" "${AUTH[@]}" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
head -1 /tmp/probe_h
grep -iE "^(content-type|mcp-session-id|www-authenticate):" /tmp/probe_h | mask
head -c 600 /tmp/probe_b | mask; echo

SID=$(grep -i "^mcp-session-id:" /tmp/probe_h | cut -d' ' -f2 | tr -d '\r')
if grep -q '"result"' /tmp/probe_b; then
  echo; echo "== 4. tools/list (只列工具名)"
  curl -s -m5 -X POST "$BASE/mcp" "${AUTH[@]}" ${SID:+-H "Mcp-Session-Id: $SID"} \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  curl -s -m5 -X POST "$BASE/mcp" "${AUTH[@]}" ${SID:+-H "Mcp-Session-Id: $SID"} \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | grep -oE '"name" *: *"[^"]+"' | sort -u
fi
rm -f /tmp/probe_b /tmp/probe_h
echo; echo "== 完成"
