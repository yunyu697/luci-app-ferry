#!/bin/sh
# 证据①-A：应用新配置（proxy_port 7892），进入 pending 后立即退出，模拟“关浏览器/断 SSH”。
set -u
uci set ferry.main.proxy_port='7892'
uci commit ferry
/etc/init.d/ferry reload >/dev/null 2>&1
sleep 4
P=$(nft list chain ip ferry tproxy_prerouting 2>/dev/null | grep -o 'tproxy to :[0-9]*' | head -1 | cut -d: -f2)
S=$(/usr/bin/ferry-txnctl status 2>/dev/null)
echo "after_apply: port=$P status=$S"
case "$S" in *'"pending":true'*) echo "PENDING_TRUE";; *) echo "PENDING_FALSE";; esac
echo "=== APPLY_DONE ==="
