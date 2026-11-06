#!/bin/sh
# guest 端重启后持久化断言：服务自启、配置保留、WebUI 可访问
#
# 用法：sh install-smoke-boot.sh <ipk|apk>
set -u

KIND="${1:-ipk}"
PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "PASS: $*"
}
bad() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $*"
}

i=0
while [ "$i" -lt 20 ]; do
	ps 2>/dev/null | grep '[u]httpd' >/dev/null 2>&1 && break
	i=$((i + 1))
	sleep 2
done

echo "===== 重启后状态（package_manager=$KIND）"
if ls /etc/rc.d/S*ferry >/dev/null 2>&1; then
	ok "开机自启链接重启后保留"
else
	bad "开机自启链接丢失"
fi
[ -f /etc/config/ferry ] && ok "conffile /etc/config/ferry 重启后存在" || bad "conffile 丢失"
[ "$(uci -q get ferry.main.enabled)" = 1 ] && ok "enabled=1 重启后保留" || bad "enabled 未保留"
[ "$(uci -q get ferry.main.probe_marker)" = install-smoke ] && ok "用户自定义配置重启后保留" || bad "自定义配置丢失"

[ -x /usr/bin/mihomo ] && ok "内核二进制重启后仍在" || bad "内核二进制丢失"
# mihomo 由 procd 拉起需要几秒，给 30s 窗口
i=0
while [ "$i" -lt 30 ]; do
	pgrep -f /usr/bin/mihomo >/dev/null 2>&1 && break
	i=$((i + 2))
	sleep 2
done
pgrep -f /usr/bin/mihomo >/dev/null 2>&1 && ok "重启后 mihomo 自启" || bad "重启后 mihomo 未自启"
[ -s /etc/ferry/status.json ] && ok "重启后 status.json 已生成" || bad "重启后 status.json 缺失"
# nft 规则由 start 脚本下发；实测 25.12 上重启后会晚于 mihomo 进程几秒出现，
# 因此给 20s 收敛窗口并记录实际耗时（不是放宽标准：窗口内不出现仍判失败）
i=0
NFT_OK=0
NFT_WAIT=0
while [ "$i" -lt 20 ]; do
	if nft list tables 2>/dev/null | grep -q ferry; then NFT_OK=1; break; fi
	i=$((i + 2))
	NFT_WAIT=$i
	sleep 2
done
if [ "$NFT_OK" = 1 ]; then
	ok "重启后 nft 接管规则已恢复（等待 ${NFT_WAIT}s）"
else
	bad "重启后 nft 规则未恢复（20s 内未出现 ferry 表）"
	echo "--- 诊断：nft tables ---"
	nft list tables 2>&1 | head -5
	echo "--- 诊断：/etc/ferry ---"
	ls -l /etc/ferry 2>&1 | head -10
	echo "--- 诊断：logread ferry ---"
	logread 2>/dev/null | grep -i ferry | tail -10
fi

ps 2>/dev/null | grep '[u]httpd' >/dev/null 2>&1 && ok "重启后 uhttpd 在运行" || bad "重启后 uhttpd 未运行"
if uclient-fetch -q -T 10 -O /tmp/view.js \
	http://127.0.0.1/luci-static/resources/view/ferry/main.js >/tmp/webui.log 2>&1; then
	[ -s /tmp/view.js ] && ok "重启后 WebUI 静态资源可取回" || bad "重启后静态资源为空"
else
	bad "重启后 WebUI 静态资源请求失败"
	tail -3 /tmp/webui.log
fi

if [ "$KIND" = apk ]; then
	apk list --installed 2>/dev/null | grep -q '^luci-app-ferry' && ok "包仍处于已安装状态" || bad "包未安装"
else
	opkg list-installed 2>/dev/null | grep -q '^luci-app-ferry ' && ok "包仍处于已安装状态" || bad "包未安装"
fi

echo "=== BOOT_SMOKE_DONE PASS=$PASS FAIL=$FAIL ==="
