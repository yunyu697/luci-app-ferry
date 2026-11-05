#!/bin/sh
# 证据②-C：设备硬断电重启后，启动检测 pending 并还原。
set -u
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
nftport() { nft list chain ip ferry tproxy_prerouting 2>/dev/null | grep -o 'tproxy to :[0-9]*' | head -1 | cut -d: -f2; }
dnsup() { uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | head -1; }
kernel_up() { pgrep -f /usr/bin/mihomo >/dev/null 2>&1; }

S=$(/usr/bin/ferry-txnctl status 2>/dev/null)
echo "status_after_boot: $S"
case "$S" in *'"pending":true'*) bad "重启后仍处于 pending";; *) ok "启动检测已清除 pending";; esac
P=$(nftport); D=$(dnsup); R=$(ip rule | grep -c 'fwmark 0x1 lookup 100'); K=$(kernel_up && echo up || echo down)
echo "after_boot: port=$P dns=$D rule=$R kernel=$K"
[ "$P" = 7890 ] && ok "nft 已还原基线 7890" || bad "nft 未还原（$P）"
[ "$D" = 127.0.0.1#1053 ] && ok "dnsmasq 已还原" || bad "dnsmasq 未还原（$D）"
[ "$R" = 1 ] && ok "策略路由已还原" || bad "策略路由未还原（$R）"
[ "$K" = up ] && ok "内核已启动" || bad "内核未运行"
CNT=$(grep -c 'reason=startup-detect' /etc/ferry/txn/history.log 2>/dev/null)
echo "startup_detect_count=$CNT"
[ "${CNT:-0}" -ge 1 ] && ok "history 记录 startup-detect（$CNT 次）" || bad "history 缺 startup-detect"
echo "=== CRASH_C_DONE PASS=$PASS FAIL=$FAIL ==="
