#!/bin/sh
# Ferry 一键清理：停止服务、移除接管规则与策略路由、还原 dnsmasq 上游。
#
# 用法：
#   /usr/lib/ferry/uninstall.sh                保留用户数据（节点/profile/规则缓存/内核版本库）
#   /usr/lib/ferry/uninstall.sh --purge        删除用户数据，但保留内核版本库
#   /usr/lib/ferry/uninstall.sh --purge-kernels 连同内核版本库一起删除（显式选择）
#
# 幂等：可重复执行。优先复用包内的 common.sh/firewall.sh（与启动路径逻辑一致）；
# 包文件已被删除时退回内置的最小清理逻辑，仍可手动执行。

set -u

# 包管理器以 prerm 调用本脚本时环境里可能没有 IPKG_INSTROOT；
# /lib/functions.sh（由 common.sh source）在 set -u 下会因该变量未定义而报错，
# 导致后续清理步骤全部跳过，所以先补一个空值。
IPKG_INSTROOT=${IPKG_INSTROOT:-}
export IPKG_INSTROOT

# 路径允许用环境变量覆盖，仅用于离线测试；设备上使用默认值
PM_CONF_DIR=${PM_CONF_DIR:-/etc/ferry}
PM_RUN_DIR=${PM_RUN_DIR:-/var/etc/ferry}
PM_DHCP_FILE=${PM_DHCP_FILE:-/etc/config/dhcp}
PM_INIT_SCRIPT=${PM_INIT_SCRIPT:-/etc/init.d/ferry}
PM_RC_DIR=${PM_RC_DIR:-/etc/rc.d}
PM_LIB_DIR=${PM_LIB_DIR:-/usr/lib/ferry}

PM_DNSMASQ_SECTION='dhcp.@dnsmasq[0]'
PM_BACKUP_DIR="$PM_CONF_DIR/dnsmasq-backup"

PM_NFT_TABLE=ferry
PM_NFT_TABLE6=ferry6
PM_IP_MARK=1
PM_IP_ROUTE_TABLE=100

PURGE=0
PURGE_KERNELS=0
for arg in "$@"; do
	case "$arg" in
		--purge) PURGE=1 ;;
		--purge-kernels) PURGE=1; PURGE_KERNELS=1 ;;
	esac
done

info() { echo "[ferry] $*"; }

USE_LIB=0
if [ -f "$PM_LIB_DIR/common.sh" ] && [ -f "$PM_LIB_DIR/firewall.sh" ]; then
	# shellcheck disable=SC1090,SC1091
	. "$PM_LIB_DIR/common.sh"
	# shellcheck disable=SC1090,SC1091
	. "$PM_LIB_DIR/firewall.sh"
	USE_LIB=1
fi

stop_service() {
	if [ -x "$PM_INIT_SCRIPT" ]; then
		info "停止服务并取消开机自启"
		"$PM_INIT_SCRIPT" stop >/dev/null 2>&1
		"$PM_INIT_SCRIPT" disable >/dev/null 2>&1
		rm -f "$PM_RC_DIR/S99ferry" "$PM_RC_DIR/K10ferry" 2>/dev/null
		# 事务看门狗也取消，避免卸载后残留进程
		if [ -x /etc/init.d/ferry-watchdog ]; then
			/etc/init.d/ferry-watchdog stop >/dev/null 2>&1
			/etc/init.d/ferry-watchdog disable >/dev/null 2>&1
		fi
		rm -rf "$PM_CONF_DIR/txn" "$PM_CONF_DIR/tmp-off" 2>/dev/null
		return 0
	fi
	# init 脚本已不在（例如包已卸掉后手工补清理）：直接结束内核进程
	info "未找到 $PM_INIT_SCRIPT，直接结束内核进程"
	pkill -f '/usr/bin/mihomo' 2>/dev/null
	pkill -f '/usr/bin/sing-box' 2>/dev/null
	return 0
}

teardown_rules() {
	if [ "$USE_LIB" = 1 ]; then
		pm_fw_down
		return 0
	fi

	info "清理 nftables / iptables 接管规则"
	nft delete table ip "$PM_NFT_TABLE" 2>/dev/null
	nft delete table ip6 "$PM_NFT_TABLE6" 2>/dev/null

	local table chain i
	for table in nat mangle; do
		for chain in PM_DNS PM_REDIR PM_TPROXY PM_QUIC; do
			i=0
			while [ "$i" -lt 4 ]; do
				iptables -t "$table" -D PREROUTING -j "$chain" 2>/dev/null || break
				i=$((i + 1))
			done
			iptables -t "$table" -F "$chain" 2>/dev/null
			iptables -t "$table" -X "$chain" 2>/dev/null
		done
	done

	rm -f "$PM_RUN_DIR/ferry-v4.nft" "$PM_RUN_DIR/ferry-v6.nft" 2>/dev/null
	return 0
}

teardown_routes() {
	info "清理 TPROXY 策略路由"
	local i=0
	while [ "$i" -lt 2 ]; do
		ip rule del fwmark "$PM_IP_MARK" table "$PM_IP_ROUTE_TABLE" 2>/dev/null
		ip route del local default dev lo table "$PM_IP_ROUTE_TABLE" 2>/dev/null
		ip -6 rule del fwmark "$PM_IP_MARK" table "$PM_IP_ROUTE_TABLE" 2>/dev/null
		ip -6 route del local default dev lo table "$PM_IP_ROUTE_TABLE" 2>/dev/null
		i=$((i + 1))
	done
	return 0
}

restore_dns() {
	if [ "$USE_LIB" = 1 ]; then
		pm_dnsmasq_restore
		return 0
	fi

	[ -f "$PM_BACKUP_DIR/server" ] || return 0
	[ -f "$PM_DHCP_FILE" ] || return 0
	uci -q get "$PM_DNSMASQ_SECTION" >/dev/null 2>&1 || return 0

	info "还原 dnsmasq 上游"
	local tmp="$PM_BACKUP_DIR/server.restore" line nv
	: > "$tmp"
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r')
		[ -n "$line" ] || continue
		# 不把本工具写入的值当原始值
		printf '%s\n' "$line" | grep -Eq '^(127\.0\.0\.1|\[::1\]|::1)#[0-9]+$' && continue
		printf '%s\n' "$line" >> "$tmp"
	done < "$PM_BACKUP_DIR/server"

	uci -q delete "$PM_DNSMASQ_SECTION.server"
	while IFS= read -r line; do
		[ -n "$line" ] && uci -q add_list "$PM_DNSMASQ_SECTION.server=$line"
	done < "$tmp"

	nv=''
	[ -f "$PM_BACKUP_DIR/noresolv" ] && nv=$(tr -d '\r\n' < "$PM_BACKUP_DIR/noresolv" 2>/dev/null)
	case "$nv" in
		1|0) uci -q set "$PM_DNSMASQ_SECTION.noresolv=$nv" ;;
		*)   uci -q delete "$PM_DNSMASQ_SECTION.noresolv" ;;
	esac

	uci -q commit dhcp
	if [ -x /etc/init.d/dnsmasq ]; then
		/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1
	fi
	rm -f "$PM_BACKUP_DIR/server" "$PM_BACKUP_DIR/noresolv" "$tmp"
	return 0
}

cleanup_state() {
	rm -rf "$PM_RUN_DIR" 2>/dev/null
	if [ "$PURGE" = 1 ]; then
		info "删除 $PM_CONF_DIR 下的用户数据（节点、profile、规则缓存、状态）"
		# 内核二进制是用户自行下载的资产：默认不删，只有 --purge-kernels 才删
		# （不整体 rm -rf，避免误删 kernels/ 与用户编辑过的 mirrors.json）
		local f
		for f in nodes.json profiles.json status.json nodes.lst rules.lst custom.lst; do
			rm -f "$PM_CONF_DIR/$f" 2>/dev/null
		done
		rm -rf "$PM_CONF_DIR/config" "$PM_CONF_DIR/rules-cache" "$PM_CONF_DIR/dnsmasq-backup" "$PM_CONF_DIR/dnsmasq-native" 2>/dev/null
		if [ "$PURGE_KERNELS" = 1 ]; then
			info "按显式选择删除内核版本库 $PM_CONF_DIR/kernels"
			rm -rf "$PM_CONF_DIR/kernels" "$PM_CONF_DIR/mirrors.json" 2>/dev/null
		else
			info "保留内核版本库 $PM_CONF_DIR/kernels（如需删除请显式执行 --purge-kernels）"
			# 没有内核版本库时目录里已无可保留内容，直接清掉空壳目录
			[ -d "$PM_CONF_DIR/kernels" ] || rm -rf "$PM_CONF_DIR" 2>/dev/null
		fi
	else
		info "保留 $PM_CONF_DIR（节点/profile/规则缓存/内核版本库）；彻底清理请执行 --purge"
	fi
	return 0
}

info "开始卸载清理（purge=$PURGE，复用包内脚本=$USE_LIB）"
stop_service
teardown_rules
teardown_routes
restore_dns
cleanup_state
info "清理完成"
exit 0
