#!/bin/sh
# 证据③-恢复：临时关闭后一键恢复，行为与关闭前一致。
set -u
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
nftport() { nft list chain ip ferry tproxy_prerouting 2>/dev/null | grep -o 'tproxy to :[0-9]*' | head -1 | cut -d: -f2; }
dnsup() { uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | head -1; }

/usr/bin/ferry-txnctl enable
sleep 5
E_P=$(nftport); E_D=$(dnsup)
E_K=$(pgrep -f /usr/bin/mihomo >/dev/null 2>&1 && echo up || echo down)
E_R=$(ip rule | grep -c 'fwmark 0x1 lookup 100')
echo "after_enable: port=$E_P dns=$E_D kernel=$E_K rule=$E_R"
[ "$E_P" = 7890 ] && ok "接管规则恢复（tproxy=7890）" || bad "接管规则未恢复（$E_P）"
[ "$E_D" = 127.0.0.1#1053 ] && ok "DNS 接管恢复（127.0.0.1#1053）" || bad "DNS 形态未恢复（$E_D）"
[ "$E_K" = up ] && ok "内核恢复运行" || bad "内核未恢复"
[ "$E_R" = 1 ] && ok "策略路由恢复" || bad "策略路由未恢复（$E_R）"
[ "$(/usr/bin/ferry-txnctl status 2>/dev/null | grep -c '"tmp_off":false')" = 1 ] \
	&& ok "tmp_off 标记已清除" || bad "tmp_off 标记未清除"
echo "=== TMPON_DONE PASS=$PASS FAIL=$FAIL ==="
