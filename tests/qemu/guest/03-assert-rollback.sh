#!/bin/sh
# 证据①-B：无控制面等待超时后，核对事务已自动还原到基线。
set -u
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
nftport() { nft list chain ip ferry tproxy_prerouting 2>/dev/null | grep -o 'tproxy to :[0-9]*' | head -1 | cut -d: -f2; }
dnsup() { uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | head -1; }
rule_n() { ip rule | grep -c 'fwmark 0x1 lookup 100'; }
kernel_up() { pgrep -f /usr/bin/mihomo >/dev/null 2>&1; }

i=0
while [ $i -lt 100 ]; do
	S=$(/usr/bin/ferry-txnctl status 2>/dev/null)
	case "$S" in *'"pending":true'*) sleep 2; i=$((i+2)); continue;; esac
	break
done
echo "waited ${i}s status=$S"

A_P=$(nftport); A_D=$(dnsup); A_R=$(rule_n); A_K=$(kernel_up && echo up || echo down)
echo "after_rollback: port=$A_P dns=$A_D rule=$A_R kernel=$A_K"
[ "$A_P" = 7890 ] && ok "nft TPROXY 已还原到基线 7890（当前 $A_P）" || bad "nft 未还原（$A_P）"
[ "$A_D" = 127.0.0.1#1053 ] && ok "dnsmasq 上游已还原（$A_D）" || bad "dnsmasq 未还原（$A_D）"
[ "$A_R" = 1 ] && ok "ip rule 策略路由已还原（$A_R 条）" || bad "ip rule 未还原（$A_R）"
[ "$A_K" = up ] && ok "内核运行状态已还原（$A_K）" || bad "内核状态异常（$A_K）"
[ "$(uci -q get ferry.main.proxy_port)" = 7890 ] && ok "UCI 改动键已还原（proxy_port=7890）" \
	|| bad "UCI 未还原（$(uci -q get ferry.main.proxy_port)）"
grep -q 'reason=timeout' /etc/ferry/txn/history.log 2>/dev/null \
	&& ok "history 记录 reason=timeout" || bad "history 无 timeout 记录"
echo "=== ROLLBACK_ASSERT_DONE PASS=$PASS FAIL=$FAIL ==="
