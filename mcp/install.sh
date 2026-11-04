#!/bin/sh
# 在 Mac/Linux 上安装 mnemosyne-cloud 只读 MCP（从自己的 VPS 读取「极米记得」数据）
#
#   sh mcp/install.sh --url 'https://<域名>/<随机路径>' --read-key '<只读密钥>'
#   sh mcp/install.sh --check        只做连通性自检
#   sh mcp/install.sh --uninstall
#
# 两个值由 VPS 上的 `sh install.sh --show` 输出。
set -eu
DIR="$HOME/.mnemosyne/cloud"
NAME=mnemosyne-cloud
URL=""; KEY=""; MODE=install
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL=${2:?}; shift ;;
    --read-key) KEY=${2:?}; shift ;;
    --check) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "[x] 未知参数：$1"; exit 1 ;;
  esac
  shift
done

NODE=$(command -v node || true)
[ -n "$NODE" ] || { echo "[x] 需要 Node.js 18+"; exit 1; }
"$NODE" -e 'process.exit(+process.versions.node.split(".")[0] < 18 ? 1 : 0)' || { echo "[x] 需要 Node.js 18+"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)

if [ "$MODE" = uninstall ]; then
  command -v claude >/dev/null && claude mcp remove -s user "$NAME" >/dev/null 2>&1 || true
  rm -rf "$DIR"; echo "[ok] 已卸载 $NAME"; exit 0
fi

if [ "$MODE" = install ]; then
  case "$URL" in https://*) ;; *) echo "[x] --url 必须是 https:// 开头"; exit 1 ;; esac
  printf '%s' "$KEY" | grep -Eq '^[0-9a-f]{64}$' || { echo "[x] --read-key 应为 64 位十六进制"; exit 1; }
  umask 077
  mkdir -p "$DIR"; chmod 700 "$DIR"
  cp "$HERE/index.mjs" "$DIR/index.mjs"
  printf '%s\n' "$KEY" > "$DIR/read.key"; chmod 600 "$DIR/read.key"
  printf '{"url":"%s","readKeyFile":"%s"}\n' "$URL" "$DIR/read.key" > "$DIR/config.json"; chmod 600 "$DIR/config.json"
  echo "[ok] 已写入 $DIR（密钥文件权限 600，未写入任何 MCP 配置明文）"
fi

echo "==> 自检：连接 VPS"
"$NODE" "$DIR/index.mjs" --check || { echo "[x] 自检失败，未注册 MCP"; exit 1; }
echo "[ok] VPS 只读查询与响应签名校验通过"

[ "$MODE" = check ] && exit 0
if command -v claude >/dev/null; then
  claude mcp remove -s user "$NAME" >/dev/null 2>&1 || true
  claude mcp add -s user "$NAME" -- "$NODE" "$DIR/index.mjs" >/dev/null
  echo "[ok] 已注册到 Claude Code（用户级）：$NAME。重启 Claude 后生效"
else
  echo "[!] 未找到 claude 命令。其它客户端请手动添加 MCP："
  echo "    {\"mcpServers\":{\"$NAME\":{\"command\":\"$NODE\",\"args\":[\"$DIR/index.mjs\"]}}}"
fi
