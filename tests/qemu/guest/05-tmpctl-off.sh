#!/bin/sh
# 证据③-关：临时关闭代理，撤接管 + 停内核 + DNS 完整回原生上游。
set -u
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
dnsup() { uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | head -1; }
tables() { nft list tables 2>/dev/null | grep -ci ferry; }

echo "before: dns=$(dnsup) tables=$(tables)"
/usr/bin/ferry-txnctl disable
sleep 4
D_D=$(dnsup); D_T=$(tables)
D_K=$(pgrep -f /usr/bin/mihomo >/dev/null 2>&1 && echo up || echo down)
echo "after_disable: dns=$D_D tables=$D_T kernel=$D_K"
[ "$D_T" = 0 ] && ok "ferry nft 表已撤销（0）" || bad "接管规则残留（$D_T）"
[ "$D_K" = down ] && ok "内核已停止" || bad "内核仍在运行"
[ "$D_D" = 223.5.5.5 ] && ok "DNS 完整回到原生上游（223.5.5.5）" || bad "DNS 半关（$D_D）"
[ "$(/usr/bin/ferry-txnctl status 2>/dev/null | grep -c '"tmp_off":true')" = 1 ] \
	&& ok "tmp_off 标记已置位" || bad "tmp_off 标记缺失"
[ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = 1 ] && ok "noresolv 保持原生值 1" || bad "noresolv 被改动"
if [ "$FAIL" -gt 0 ]; then
	echo "--- diag: dnsmasq files ---"; ls -l /etc/ferry/dnsmasq-backup /etc/ferry/dnsmasq-native 2>&1
	cat /etc/ferry/dnsmasq-backup/server /etc/ferry/dnsmasq-native/server 2>/dev/null
	echo "--- diag: logread ---"; logread | grep -i -E 'dnsmasq|临时关闭|还原' | tail -25
fi
echo "=== TMPOFF_DONE PASS=$PASS FAIL=$FAIL ==="
