#!/bin/sh
# guest 端安装冒烟：真实 ipk/apk 安装 → 文件/版本 → 服务拉起 → WebUI → 卸载/升级保留
#
# 用法：sh install-smoke.sh <ipk|apk> <期望版本，如 1.0.0-r13>
#
# 由 tests/qemu/install-smoke.sh 通过 SSH 在官方 x86_64 镜像里执行。
# 只使用 guest 自带工具（opkg/apk、uci、nft、wget、jsonfilter），不做任何外网配置改动。
set -u

KIND="${1:-ipk}"
VER="${2:-}"
REL="${3:-}"
PKG="/tmp/ferry.$KIND"
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
say() { echo "===== $*"; }

say "0. 系统基线"
# shellcheck disable=SC1091
. /etc/openwrt_release 2>/dev/null || true
echo "DISTRIB_DESCRIPTION=${DISTRIB_DESCRIPTION:-unknown}"
echo "model=$(cat /tmp/sysinfo/model 2>/dev/null)"
echo "arch=$(uname -m) kver=$(uname -r)"
echo "package_manager=$KIND"
[ -f "$PKG" ] && echo "package=$(basename "$PKG") size=$(wc -c <"$PKG")" || bad "包文件不存在：$PKG"

say "0.1 guest 出网（在线依赖解析需要；预装齐全时不依赖）"
# 官方 x86 单网口镜像没有默认路由，这里显式把 slirp 网关（192.168.1.2）设为默认出口
ip route add default via 192.168.1.2 2>/dev/null
[ -s /etc/resolv.conf ] || echo 'nameserver 192.168.1.2' >/etc/resolv.conf
i=0
NET=0
FEED_URL=""
[ -n "$REL" ] && FEED_URL="http://downloads.openwrt.org/releases/$REL/targets/x86/64/Packages"
while [ "$i" -lt 10 ]; do
	if [ -n "$FEED_URL" ] && uclient-fetch -q -T 8 -O /dev/null "$FEED_URL" >/dev/null 2>&1; then
		NET=1
		break
	fi
	i=$((i + 1))
	sleep 2
done
if [ "$NET" = 1 ]; then
	ok "guest 可出网（feed 索引可下载）"
else
	echo "NOTE: guest 无法出网；后续安装只能依赖预装 kmod，缺失依赖会直接体现在安装结果里"
fi

say "1. 预装 kmod（官方 x86 feed 不含目标 kmods）"
# 注意：kmod 预装失败一律只记 NOTE，不判 FAIL。
# 原因：本用例跑 redirect 模式，不依赖 nft_tproxy；且 25.12 x86 targets feed 未发布
# kmod-nf-tproxy（kmod-nft-tproxy 的依赖），属于上游 feed 缺口，不是本应用缺陷。
# 真正决定成败的是第 2 步的包安装与第 3 步的服务拉起。
KMOD_N=0
for f in /tmp/kmod-*.ipk /tmp/kmod-*.apk; do
	[ -f "$f" ] || continue
	KMOD_N=$((KMOD_N + 1))
done
echo "kmod_files=$KMOD_N"
if [ "$KMOD_N" -eq 0 ]; then
	echo "NOTE: 没有可用的 kmod 预取文件（宿主侧 kmods 抓取失败，继续按无 kmod 安装）"
elif [ "$KIND" = apk ]; then
	# 逐个安装，单个失败（依赖在目标 feed 缺失）不影响其它 kmod
	KMOD_OK=0
	KMOD_NG=0
	for f in /tmp/kmod-*.apk; do
		aptmp=$(basename "$f")
		if apk add --allow-untrusted "$f" >/tmp/kmods.log 2>&1; then
			KMOD_OK=$((KMOD_OK + 1))
		else
			KMOD_NG=$((KMOD_NG + 1))
			ERR1=$(grep -m1 -E 'no such package|unsatisfied|ERROR' /tmp/kmods.log | cut -c1-120)
			echo "NOTE: apk 预装 $aptmp 跳过（$ERR1）"
		fi
	done
	[ "$KMOD_NG" -eq 0 ] && ok "apk 预装 kmod 全部成功（$KMOD_OK 个）" \
		|| echo "NOTE: apk 预装 kmod 成功 $KMOD_OK 个，跳过 $KMOD_NG 个（记录不判失败）"
else
	for f in /tmp/kmod-*.ipk; do
		opkg install --force-depends "$f" >/tmp/kmods.log 2>&1
		RC=$?
		[ "$RC" = 0 ] && ok "opkg 预装 $(basename "$f")" \
			|| echo "NOTE: opkg 预装 $(basename "$f") 跳过（rc=$RC，记录不判失败）"
	done
fi
if lsmod 2>/dev/null | grep -q nft_tproxy; then
	ok "nft_tproxy 模块可用（依赖链真实满足）"
else
	echo "NOTE: nft_tproxy 未加载（redirect 模式不需要，记录不判失败）"
fi

say "2. 安装包"
if [ "$KIND" = apk ]; then
	apk add --allow-untrusted "$PKG" >/tmp/install.log 2>&1
	RC=$?
else
	opkg install "$PKG" >/tmp/install.log 2>&1
	RC=$?
fi
tail -15 /tmp/install.log
[ "$RC" = 0 ] && ok "安装成功（rc=0）" || bad "安装失败（rc=$RC）"

for f in /etc/init.d/ferry /etc/init.d/ferry-watchdog /etc/uci-defaults/50-ferry \
	/usr/lib/ferry/common.sh /usr/lib/ferry/generate.sh /usr/lib/ferry/firewall.sh \
	/usr/lib/ferry/transaction.sh /usr/lib/ferry/kernel.sh /usr/lib/ferry/uninstall.sh \
	/usr/lib/ferry/kernels-builtin.tsv /usr/bin/ferry-txnctl /usr/bin/ferry-diag \
	/usr/libexec/rpcd/luci-ferry-kernel /usr/libexec/rpcd/luci-ferry-safety \
	/usr/share/luci/menu.d/luci-app-ferry.json /usr/share/rpcd/acl.d/luci-app-ferry.json \
	/www/luci-static/resources/view/ferry/main.js \
	/www/luci-static/resources/ferry/store.js; do
	[ -e "$f" ] && ok "已安装 $f" || bad "缺失 $f"
done
[ -x /etc/init.d/ferry ] && ok "init 脚本可执行位正常" || bad "init 脚本不可执行（权限丢失）"
[ -x /usr/libexec/rpcd/luci-ferry-kernel ] && ok "rpcd 后端可执行位正常" || bad "rpcd 后端不可执行"

say "2.1 版本元数据"
if [ "$KIND" = apk ]; then
	V=$(apk list --installed 2>/dev/null | grep '^luci-app-ferry' | head -1 | awk '{print $1}')
	[ -n "$V" ] || V=$(apk info -e luci-app-ferry 2>/dev/null | head -1)
else
	V=$(sed -n 's/^Version: //p' /usr/lib/opkg/info/luci-app-ferry.control 2>/dev/null)
fi
echo "installed_version=$V"
[ -n "$VER" ] && echo "$V" | grep -q "$VER" && ok "包元数据版本含 $VER" || bad "包元数据版本异常（$V，期望含 $VER）"

say "2.2 升级保留登记"
KB=/lib/upgrade/keep.d/ferry
if [ -s "$KB" ] && grep -q '^/etc/ferry$' "$KB"; then
	ok "keep.d 已登记 /etc/ferry（含内核目录，sysupgrade 保留）"
else
	bad "keep.d 缺失或未登记 /etc/ferry"
fi

say "3. 配置并拉起服务（redirect 模式，真实 mihomo）"
gzip -dc /tmp/mihomo.gz >/usr/bin/mihomo 2>/tmp/gzip.log
chmod 0755 /usr/bin/mihomo
[ -x /usr/bin/mihomo ] && ok "内核二进制已就位" || bad "内核二进制解压失败"
/usr/bin/mihomo -v >/tmp/mihomo-v.log 2>&1 && ok "mihomo 可执行（$(head -1 /tmp/mihomo-v.log)）" \
	|| { bad "mihomo 无法执行"; tail -3 /tmp/mihomo-v.log; }

mkdir -p /etc/ferry
cp /tmp/test-config.yaml /etc/ferry/test-config.yaml
uci set ferry.main.enabled='1'
uci set ferry.main.kernel='mihomo'
uci set ferry.main.bin_path='/usr/bin/mihomo'
uci set ferry.main.config_path='/etc/ferry/test-config.yaml'
uci set ferry.main.deploy='router'
uci set ferry.main.mode='redirect'
uci set ferry.main.rule_update='0'
uci set ferry.main.final_policy='direct'
uci set ferry.main.enable_ipv6='0'
uci set ferry.main.proxy_port='7890'
uci commit ferry

T0=$(date +%s)
/etc/init.d/ferry start 2>&1 | tail -20
T1=$(date +%s)
DUR=$((T1 - T0))
echo "start_duration=${DUR}s"
[ "$DUR" -le 20 ] && ok "start 未死等端口（${DUR}s <= 20s）" || bad "start 阻塞 ${DUR}s"
sleep 8
/etc/init.d/ferry status 2>&1 | tail -3
pgrep -f /usr/bin/mihomo >/dev/null 2>&1 && ok "mihomo 进程在运行" || bad "mihomo 未运行"
[ -s /etc/ferry/status.json ] && ok "status.json 已生成" || bad "status.json 缺失"
netstat -lnt 2>/dev/null | grep -q ':7890 ' && ok "代理端口 7890 已监听" || bad "7890 未监听"
nft list tables 2>/dev/null | grep -q ferry && ok "nft 表已安装（redirect 接管生效）" \
	|| bad "nft 表未安装（未接管流量）"

say "4. WebUI 可访问"
ps 2>/dev/null | grep '[u]httpd' >/dev/null 2>&1 && ok "uhttpd 在运行" || bad "uhttpd 未运行"
if uclient-fetch -q -T 10 -O /tmp/view.js http://127.0.0.1/luci-static/resources/view/ferry/main.js >/tmp/webui.log 2>&1; then
	[ -s /tmp/view.js ] && ok "LuCI 静态资源取回（$(wc -c </tmp/view.js) bytes）" || bad "静态资源为空"
	grep -q 'view.extend' /tmp/view.js && ok "静态资源内容为本应用视图" || bad "静态资源内容异常"
else
	bad "LuCI 静态资源请求失败"
	tail -3 /tmp/webui.log
fi
# 未登录访问 /cgi-bin/luci/ 时，官方镜像的 LuCI 会直接回 403（无会话），这属于 LuCI 行为，
# 不是本应用缺陷；这里只做记录，判定落在「静态资源 200」与「rpcd/menu 注册」上。
ENTRY_OUT=$(uclient-fetch -T 10 -O /tmp/luci.html http://127.0.0.1/cgi-bin/luci/ 2>&1)
ENTRY_RC=$?
echo "NOTE: luci_entry rc=$ENTRY_RC $(echo "$ENTRY_OUT" | tr '\n' ' ' | cut -c1-100)"
ls /usr/share/luci/menu.d/luci-app-ferry.json >/dev/null 2>&1 && ok "LuCI 菜单已注册" || bad "LuCI 菜单未注册"
grep -q 'ferry/main' /usr/share/luci/menu.d/luci-app-ferry.json && ok "菜单指向本应用视图（ferry/main）" \
	|| bad "菜单未指向 view/ferry/main"
if ubus list 2>/dev/null | grep -q 'luci-ferry'; then
	ok "rpcd 后端 ubus 对象已注册（$(ubus list 2>/dev/null | grep -c 'luci-ferry') 个）"
else
	bad "rpcd 后端 ubus 对象未注册（安装后 rpcd 未刷新）"
fi

say "5. 卸载：清理运行态 + 保留用户配置"
uci set ferry.main.probe_marker='install-smoke'
uci commit ferry
if [ "$KIND" = apk ]; then
	apk del luci-app-ferry >/tmp/del.log 2>&1
	RC=$?
else
	opkg remove luci-app-ferry >/tmp/del.log 2>&1
	RC=$?
fi
tail -10 /tmp/del.log
[ "$RC" = 0 ] && ok "卸载命令 rc=0" || bad "卸载失败（rc=$RC）"
sleep 3
pgrep -f /usr/bin/mihomo >/dev/null 2>&1 && bad "卸载后 mihomo 仍在运行（prerm 未生效）" || ok "卸载后内核已退出"
nft list tables 2>/dev/null | grep -q ferry && bad "卸载后 nft 表残留" || ok "卸载后 nft 表已清理"
[ -e /usr/lib/ferry/uninstall.sh ] && bad "包文件仍存在" || ok "包文件已删除"
if [ -f /etc/config/ferry ]; then
	ok "conffile /etc/config/ferry 卸载后保留"
	grep -q probe_marker /etc/config/ferry && ok "配置内容未被清空" || bad "配置内容丢失"
else
	bad "conffile /etc/config/ferry 被删除（配置保护失效）"
fi
[ -d /etc/ferry ] && ok "用户数据目录 /etc/ferry 保留" || bad "/etc/ferry 被误删"

say "6. 重装（升级路径：配置与用户数据保留）"
if [ "$KIND" = apk ]; then
	apk add --allow-untrusted "$PKG" >/tmp/reinstall.log 2>&1
	RC=$?
else
	opkg install "$PKG" >/tmp/reinstall.log 2>&1
	RC=$?
fi
[ "$RC" = 0 ] && ok "重装成功（rc=0）" || { bad "重装失败（rc=$RC）"; tail -8 /tmp/reinstall.log; }
[ -f /etc/config/ferry ] && ok "重装后 conffile 存在" || bad "重装后 conffile 丢失"
grep -q probe_marker /etc/config/ferry && ok "升级保留：probe_marker 仍在" || bad "升级丢失用户配置"
[ -x /etc/init.d/ferry ] && ok "重装后 init 脚本就位" || bad "重装后 init 脚本缺失"

say "7. 重启前再拉起（供重启持久化验证）"
/etc/init.d/ferry enable >/dev/null 2>&1
if ls /etc/rc.d/S*ferry >/dev/null 2>&1; then
	ok "已登记开机自启（rc.d 链接存在）"
else
	bad "开机自启未登记（rc.d 缺链接）"
fi
/etc/init.d/ferry start >/tmp/start2.log 2>&1
sleep 5
pgrep -f /usr/bin/mihomo >/dev/null 2>&1 && ok "重启前服务已运行" || { bad "重启前服务未运行"; tail -5 /tmp/start2.log; }

echo "=== INSTALL_SMOKE_DONE PASS=$PASS FAIL=$FAIL ==="
