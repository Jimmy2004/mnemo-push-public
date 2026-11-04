#!/bin/sh
# 在 VPS 上以 root 运行：sh install.sh（在 server/ 目录下）
set -e
id mnemo >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin mnemo
install -d -m 750 -o root -g mnemo /etc/mnemo-recv
[ -f /etc/mnemo-recv/key ]  || (umask 027; python3 -c "import secrets;print(secrets.token_hex(32))" > /etc/mnemo-recv/key)
chgrp mnemo /etc/mnemo-recv/key; chmod 640 /etc/mnemo-recv/key
[ -f /etc/mnemo-recv/path ] || python3 -c "import secrets;print(secrets.token_urlsafe(24))" > /etc/mnemo-recv/path
install -d -m 700 -o mnemo -g mnemo /var/lib/mnemo-recv
install -m 644 mnemo_recv.py /usr/local/lib/mnemo_recv.py
install -m 644 deploy/mnemo-recv.service /etc/systemd/system/mnemo-recv.service
systemctl daemon-reload && systemctl enable --now mnemo-recv
echo "接收端已启动。把 deploy/nginx-location.conf 加进 nginx（路径见 /etc/mnemo-recv/path），nginx -t 后 reload。"
