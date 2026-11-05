#!/bin/sh
# 证据②-B：看门狗被杀 -> 服务重启时由 start_service 检测 pending 并 startup-detect 还原。
set -u
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
nftport() { nft list chain ip ferry tproxy_prerouting 2>/dev/null | grep -o 'tproxy to :[0-9]*' | head -1 | cut -d: -f2; }
dnsup() { uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | head -1; }
kernel_up() { pgrep -f /usr/bin/mihomo >/dev/null 2>&1; }

uci set ferry.main.proxy_port='7892'
uci commit ferry
/etc/init.d/ferry reload >/dev/null 2>&1
sleep 3
case "$(/usr/bin/ferry-txnctl status 2>/dev/null)" in *'"pending":true'*) ok "apply 后进入 pending";; *) bad "未进入 pending";; esac

/etc/init.d/ferry-watchdog stop >/dev/null 2>&1
for p in $(pgrep -f /usr/lib/ferry/watchdog.sh 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 2
pgrep -f /usr/lib/ferry/watchdog.sh >/dev/null 2>&1 \
	&& bad "看门狗仍在运行（未杀干净）" || ok "看门狗已停止（WD_DEAD）"

# 模拟“服务重启/下次 boot”：start_service 先 detect pending
/etc/init.d/ferry restart >/dev/null 2>&1
i=0
while [ $i -lt 40 ]; do
	case "$(/usr/bin/ferry-txnctl status 2>/dev/null)" in *'"pending":true'*) sleep 2; i=$((i+2)); continue;; esac
	break
done
sleep 2
A_P=$(nftport); A_D=$(dnsup); A_K=$(kernel_up && echo up || echo down)
echo "after_startup_detect: port=$A_P dns=$A_D kernel=$A_K"
[ "$A_P" = 7890 ] && ok "nft 已还原 7890" || bad "nft 未还原（$A_P）"
[ "$A_D" = 127.0.0.1#1053 ] && ok "dnsmasq 已还原" || bad "dnsmasq 未还原（$A_D）"
[ "$A_K" = up ] && ok "内核已恢复运行" || bad "内核未运行"
grep -q 'reason=startup-detect' /etc/ferry/txn/history.log 2>/dev/null \
	&& ok "history 记录 reason=startup-detect" || bad "history 缺 startup-detect"

/etc/init.d/ferry-watchdog start
i=0; WD=0
while [ $i -lt 15 ]; do
	pgrep -f /usr/lib/ferry/watchdog.sh >/dev/null 2>&1 && { WD=1; break; }
	sleep 1; i=$((i+1))
done
[ "$WD" = 1 ] && ok "看门狗已重新拉起（${i}s，pgrep 命中）" || { bad "看门狗未恢复"; logread | tail -6; }
if [ "$FAIL" -gt 0 ]; then
	echo "--- diag: status ---"; /usr/bin/ferry-txnctl status 2>&1
	echo "--- diag: nft tables ---"; nft list tables 2>&1
	echo "--- diag: dnsmasq ---"; uci -q get dhcp.@dnsmasq[0].server 2>&1; ls -l /etc/ferry/dnsmasq-backup /etc/ferry/dnsmasq-native 2>&1
	echo "--- diag: logread ---"; logread | tail -40
	echo "--- diag: procd ---"; ubus call service list '{"name":"ferry"}' 2>&1 | head -40
fi
echo "=== CRASH_B_DONE PASS=$PASS FAIL=$FAIL ==="
