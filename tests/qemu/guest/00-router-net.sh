#!/bin/sh
# 路由器 guest 网络断言：eth0 = WAN（QEMU slirp DHCP），eth1 = LAN 203.0.113.1。
# 拓扑由 run-acceptance.sh 的 bootstrap_net 在串口阶段完成；这里只验证，不改配置。
# 测试 LAN 故意用 203.0.113.0/24（不在默认 bypass 列表），确保 TPROXY 会命中。
set -u
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

sleep 2
ip -4 -o addr show eth0 2>/dev/null | grep -q '10.0.2' && ok "WAN eth0 已从 slirp 取得地址" || bad "WAN eth0 未取得 DHCP 地址"
ip -4 -o addr show eth1 2>/dev/null | grep -q '203.0.113.1' && ok "LAN eth1 = 203.0.113.1/24" || bad "LAN eth1 地址未生效"
ip route 2>/dev/null | grep -q 'default' && ok "默认路由存在" || bad "缺少默认路由"
ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && ok "路由器 WAN 可出网（ping 223.5.5.5）" || bad "路由器 WAN 不可出网"
# 补充证据：TCP 探测（ICMP 在 slirp 下可能被丢弃；原 ICMP 断言保留不删）
if command -v uclient-fetch >/dev/null 2>&1; then
	i=0; OKB=0
	while [ $i -lt 2 ]; do
		uclient-fetch -q -T 10 -O /tmp/wan-probe.html http://www.baidu.com >/tmp/wan-tcp.log 2>&1
		[ -s /tmp/wan-probe.html ] && { OKB=1; break; }
		i=$((i+1)); sleep 2
	done
	[ "$OKB" = 1 ] && ok "路由器 WAN TCP 探测成功（uclient-fetch 取到报文）" || { bad "路由器 WAN TCP 探测失败"; tail -3 /tmp/wan-tcp.log; }
else
	bad "路由器 WAN TCP 探测无法执行（镜像无 uclient-fetch）"
fi
pgrep -x dnsmasq >/dev/null 2>&1 && ok "dnsmasq 在运行" || bad "dnsmasq 未运行"
echo "=== ROUTER_NET_DONE PASS=$PASS FAIL=$FAIL ==="
