#!/bin/sh
# 在本机（Mac/Linux）一条命令部署到 VPS：
#   ./server/deploy.sh root@1.2.3.4 --domain example.com [-i ~/.ssh/id_rsa.pem] [其它 install.sh 参数]
set -eu
[ $# -ge 1 ] || { sed -n '2,3p' "$0"; exit 1; }
TARGET=$1; shift
SSH_OPTS=""
ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) SSH_OPTS="$SSH_OPTS -i $2"; shift ;;
    *) ARGS="$ARGS $1" ;;
  esac
  shift
done
HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE=/root/mnemo-push-server
# shellcheck disable=SC2086
ssh $SSH_OPTS "$TARGET" "mkdir -p $REMOTE"
# shellcheck disable=SC2086
scp -q $SSH_OPTS "$HERE/install.sh" "$HERE/mnemo_recv.py" "$TARGET:$REMOTE/"
# shellcheck disable=SC2086
ssh -t $SSH_OPTS "$TARGET" "cd $REMOTE && sh install.sh$ARGS"
