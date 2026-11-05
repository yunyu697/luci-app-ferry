#!/bin/sh
# 建立“已确认保留”的基线：apply -> 确认 -> 快照运行态，供后续回滚/关闭测试对比。
set -u
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
nftport() { nft list chain ip ferry tproxy_prerouting 2>/dev/null | grep -o 'tproxy to :[0-9]*' | head -1 | cut -d: -f2; }
dnsup() { uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | head -1; }
rule_n() { ip rule | grep -c 'fwmark 0x1 lookup 100'; }
kernel_up() { pgrep -f /usr/bin/mihomo >/dev/null 2>&1; }

/etc/init.d/ferry stop >/dev/null 2>&1
sleep 2
[ "$(dnsup)" = 223.5.5.5 ] && ok "停止态 DNS = 原生上游 223.5.5.5" || bad "停止态 DNS 异常（$(dnsup)）"

/etc/init.d/ferry reload >/dev/null 2>&1
sleep 4
/usr/bin/ferry-txnctl confirm >/dev/null 2>&1
sleep 2

P=$(nftport); D=$(dnsup); R=$(rule_n); K=$(kernel_up && echo up || echo down)
S=$(/usr/bin/ferry-txnctl status 2>/dev/null)
echo "baseline: port=$P dns=$D rule=$R kernel=$K"
echo "status: $S"
if [ -z "$P" ]; then
	# 失败现场：状态自检 + 最近日志 + 生成的 nft 文件 + 直接重放一次加载错误
	echo "--- diag: ferry status ---"; /etc/init.d/ferry status 2>&1
	echo "--- diag: logread ---"; logread | tail -25
	echo "--- diag: nft file ---"; cat /var/etc/ferry/ferry-v4.nft 2>/dev/null
	echo "--- diag: nft -f replay ---"; nft -f /var/etc/ferry/ferry-v4.nft 2>&1
fi
[ "$P" = 7890 ] && ok "TPROXY 命中端口 7890" || bad "TPROXY 端口异常（$P）"
[ "$D" = 127.0.0.1#1053 ] && ok "dnsmasq 被内核 DNS 接管（127.0.0.1#1053）" || bad "dnsmasq 未接管（$D）"
[ "$R" = 1 ] && ok "fwmark 策略路由存在（1 条）" || bad "策略路由异常（$R）"
[ "$K" = up ] && ok "mihomo 内核在运行" || bad "mihomo 未运行"
nft list ruleset 2>/dev/null | grep -q 'chain tproxy_prerouting' && ok "nft ruleset 含 tproxy_prerouting 链" || bad "nft ruleset 缺 tproxy 链"
case "$S" in *'"pending":false'*) ok "事务已确认（pending=false）";; *) bad "事务未确认：$S";; esac

# 记录基线值，供驱动脚本归档
cat > /tmp/ferry-baseline.txt <<EOF
port=$P
dns=$D
rule=$R
kernel=$K
EOF
[ -s /etc/ferry/txn/baseline.uci ] && ok "baseline.uci 已落盘" || bad "baseline.uci 缺失"
echo "=== BASELINE_DONE PASS=$PASS FAIL=$FAIL ==="
