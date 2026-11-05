#!/bin/sh
# 客户端 guest：eth0 = slirp（仅供 SSH 管理），eth1 = 路由器 LAN（203.0.113.2）。
# 关掉本机 dnsmasq/firewall，默认路由指向路由器。
set -u
KIND="${1:-ipk}"
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

sleep 2
ip -4 -o addr show 2>/dev/null | grep -q 'inet 10.0.2' && ok "管理面（br-lan/eth0）有 slirp 地址" || bad "管理面无 slirp 地址"

uci set network.lan2=interface
uci set network.lan2.device='eth1'
uci set network.lan2.proto='static'
uci set network.lan2.ipaddr='203.0.113.2'
uci set network.lan2.netmask='255.255.255.0'
uci commit network
/etc/init.d/network reload >/dev/null 2>&1
sleep 3

SLIRP_GW=$(ip route | awk '/default/ && ($NF=="br-lan" || $NF=="eth0") {print $3; exit}')
[ -n "$SLIRP_GW" ] && ip route del default via "$SLIRP_GW" 2>/dev/null
ip route replace default via 203.0.113.1 dev eth1 metric 10

/etc/init.d/dnsmasq stop >/dev/null 2>&1
/etc/init.d/firewall stop >/dev/null 2>&1
# 先用公共 DNS 装工具，流量断言脚本会临时切到 203.0.113.1
printf 'nameserver 223.5.5.5\n' > /etc/resolv.conf
sleep 2

ip -4 -o addr show eth1 2>/dev/null | grep -q '203.0.113.2' && ok "eth1 = 203.0.113.2/24" || bad "eth1 地址未生效"
ip route | grep -q 'default via 203.0.113.1' && ok "默认路由指向 203.0.113.1" || bad "默认路由未切到测试 LAN"
ping -c 2 -W 2 203.0.113.1 >/dev/null 2>&1 && ok "client -> router 连通" || bad "client 无法 ping 路由器"
ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1 && ok "client 可经路由器出网" || bad "client 无法出网"

if ! command -v curl >/dev/null 2>&1; then
	i=0
	while [ $i -lt 3 ]; do
		if [ "$KIND" = apk ]; then
			apk add curl >/dev/null 2>&1
		else
			opkg update >/dev/null 2>&1
			opkg install curl >/dev/null 2>&1
		fi
		command -v curl >/dev/null 2>&1 && break
		i=$((i+1))
		sleep 3
	done
fi
command -v curl >/dev/null 2>&1 && ok "curl 可用" || bad "curl 安装失败"
echo "=== CLIENT_NET_DONE PASS=$PASS FAIL=$FAIL ==="
