#!/bin/sh
# Ferry 公共函数：配置读取、路径、日志、DNS 衔接、profile 迁移
# 仅使用 BusyBox ash 兼容语法

# 设备上固定 /lib/functions.sh；离线测试可用 PM_FUNCTIONS_SH 注入 config_* 替身
PM_FUNCTIONS_SH=${PM_FUNCTIONS_SH:-/lib/functions.sh}
[ -f "$PM_FUNCTIONS_SH" ] && . "$PM_FUNCTIONS_SH"

PM_RUN_DIR=${PM_RUN_DIR:-/var/etc/ferry}
PM_MIHOMO_DIR=${PM_MIHOMO_DIR:-/etc/mihomo}
PM_SINGBOX_DIR=${PM_SINGBOX_DIR:-/etc/sing-box}

# 持久化目录：节点、profile、规则编译产物（与 UCI 分离）
# 允许环境变量覆盖，仅用于离线测试；设备上保持默认值
PM_CONF_DIR=${PM_CONF_DIR:-/etc/ferry}
PM_NODES_FILE=$PM_CONF_DIR/nodes.json
PM_PROFILES_FILE=$PM_CONF_DIR/profiles.json
PM_ACTIVE_FILE=$PM_CONF_DIR/active
PM_NODES_LST=$PM_CONF_DIR/nodes.lst
PM_RULES_LST=$PM_CONF_DIR/rules.lst
PM_CUSTOM_LST=$PM_CONF_DIR/custom.lst
PM_STATUS_FILE=$PM_CONF_DIR/status.json
PM_RULE_CACHE=$PM_CONF_DIR/rules-cache

PM_NFT_TABLE=ferry
PM_NFT_TABLE6=ferry6
PM_IP_MARK=1
PM_IP_ROUTE_TABLE=100

PM_LOG_TAG=ferry

# ---------------------------------------------------------------------------
# 包管理器探测（OpenWRT main/apk 分支 vs 23.05/24.10 与 ImmortalWrt 的 opkg）
# 可选参数是根目录前缀，仅用于离线测试：pm_pkgmgr /tmp/fake-root
# ---------------------------------------------------------------------------
pm_pkgmgr() {
	local root="${1:-}"
	if [ -z "$root" ] && command -v apk >/dev/null 2>&1; then
		echo apk; return 0
	fi
	if [ -d "$root/etc/apk" ] || [ -x "$root/sbin/apk" ] || [ -x "$root/usr/bin/apk" ]; then
		echo apk; return 0
	fi
	if [ -z "$root" ] && command -v opkg >/dev/null 2>&1; then
		echo opkg; return 0
	fi
	if [ -d "$root/etc/opkg" ] || [ -x "$root/bin/opkg" ] || [ -x "$root/usr/bin/opkg" ]; then
		echo opkg; return 0
	fi
	echo none
	return 1
}

# 查询本机是否已安装某包：apk info -e / opkg list-installed
pm_pkg_installed() {
	local name="$1" mgr
	[ -n "$name" ] || return 1
	mgr=$(pm_pkgmgr) || return 1
	case "$mgr" in
		apk)  apk info -e "$name" >/dev/null 2>&1 ;;
		opkg) opkg list-installed 2>/dev/null | grep -q "^$name " ;;
		*)    return 1 ;;
	esac
}

# 精简固件不一定带 timeout（busybox 未编译该 applet），退化为直接执行
pm_timeout() {
	local s="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$s" "$@"
	else
		"$@"
	fi
}

# 给出等价的本机安装命令（文档/状态页复用）
pm_pkg_install_hint() {
	local file="$1" mgr
	mgr=$(pm_pkgmgr) || mgr=none
	case "$mgr" in
		apk)  echo "apk add --allow-untrusted $file" ;;
		opkg) echo "opkg install $file" ;;
		*)    echo "未知包管理器，请手动安装：$file" ;;
	esac
}


pm_log() {
	local msg="$1" level="${2:-info}"
	logger -t "$PM_LOG_TAG" -p "daemon.$level" "$msg" 2>/dev/null
	if [ -t 2 ]; then
		echo "[ferry] $msg" >&2
	fi
	return 0
}

# 生成期告警：去重写入 /var/etc/ferry/warnings.txt，最终落到 status.json
pm_warn() {
	[ -n "$1" ] || return 0
	mkdir -p "$PM_RUN_DIR"
	if [ -f "$PM_RUN_DIR/warnings.txt" ] && grep -qxF "$1" "$PM_RUN_DIR/warnings.txt" 2>/dev/null; then
		return 0
	fi
	printf '%s\n' "$1" >> "$PM_RUN_DIR/warnings.txt"
	pm_log "$1" warning
	return 0
}

pm_json_esc() {
	printf '%s' "$1" | tr -d '\r\n\t' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

pm_load() {
	config_load ferry

	config_get_bool PM_ENABLED    main enabled            0
	config_get      PM_KERNEL     main kernel             mihomo
	config_get      PM_MODE       main mode               tproxy
	config_get      PM_DEPLOY     main deploy             router
	config_get      PM_PROXY_PORT main proxy_port         7890
	config_get      PM_MIXED_PORT main mixed_port         7891
	config_get      PM_DNS_PORT   main dns_port           1053
	config_get_bool PM_HIJACK_DNS main hijack_dns         1
	config_get_bool PM_ROUTER_DNS main router_dns         1
	config_get      PM_DNS_MODE   main dns_mode           fake-ip
	config_get      PM_SUB_URL    main sub_url            ''
	config_get      PM_CONFIG_PATH main config_path       ''
	config_get      PM_BIN_PATH   main bin_path           ''
	config_get      PM_LOG_LEVEL  main log_level          info
	config_get      PM_LAN_IFACE  main lan_iface          ''
	config_get      PM_BYPASS_CIDR main bypass_cidr       ''
	config_get      PM_BYPASS_IP  main bypass_ip          ''
	config_get_bool PM_ENABLE_IPV6 main enable_ipv6       1
	config_get_bool PM_BLOCK_QUIC main block_quic         1
	config_get      PM_TUN_STACK  main tun_stack          system
	config_get      PM_FW_BACKEND main firewall_backend   auto
	config_get      PM_RULE_MIRROR main rule_mirror       github
	config_get      PM_RULE_MIRROR_CUSTOM main rule_mirror_custom ''
	config_get      PM_RULE_MIRROR_BACKUP main rule_mirror_backup ''
	config_get_bool PM_RULE_UPDATE main rule_update       1
	config_get      PM_FINAL      main final_policy       proxy
	config_get      PM_PROFILE    main profile            ''
	config_get      PM_ROLLBACK_TIMEOUT main rollback_timeout 60

	# 宽容处理非法枚举值
	case "$PM_KERNEL" in
		mihomo|singbox) ;;
		*) PM_KERNEL=mihomo ;;
	esac
	case "$PM_MODE" in
		tproxy|tun|redirect) ;;
		*) PM_MODE=tproxy ;;
	esac
	case "$PM_DEPLOY" in
		router|bypass|client) ;;
		*) PM_DEPLOY=router ;;
	esac
	case "$PM_FW_BACKEND" in
		auto|nft|iptables) ;;
		*) PM_FW_BACKEND=auto ;;
	esac
	case "$PM_TUN_STACK" in
		system|gvisor|mixed) ;;
		*) PM_TUN_STACK=system ;;
	esac
	case "$PM_RULE_MIRROR" in
		github|ghproxy|jsdelivr|custom) ;;
		*) PM_RULE_MIRROR=github ;;
	esac
	case "$PM_FINAL" in
		proxy|direct) ;;
		*) PM_FINAL=proxy ;;
	esac

	[ -n "$PM_LAN_IFACE" ] || PM_LAN_IFACE=$(pm_detect_lan_iface)
	PM_LAN_IFACES=$PM_LAN_IFACE

	# 管理口永久 bypass：LAN 接口所在网段 + 路由器自身地址（含 IPv6）。
	# 结果由 firewall.sh 写进独立 mgmt 集合，用户配置无法覆盖。
	PM_MGMT_CIDRS=$(pm_mgmt_cidrs)

	# UCI 的 profile 字段优先；兼容旧迁移只写了 active 文件的情况
	PM_PROFILE_ID=$PM_PROFILE
	if [ -z "$PM_PROFILE_ID" ] && [ -f "$PM_ACTIVE_FILE" ]; then
		PM_PROFILE_ID=$(cat "$PM_ACTIVE_FILE" 2>/dev/null | tr -d '\r\n')
	fi
	[ -z "$PM_PROFILE_ID" ] && PM_PROFILE_ID=default

	# 旧版本只有 /etc/config/ferry：首次启动补一个默认 profile，绝不覆盖已有文件
	pm_migrate_legacy

	PM_RUNTIME_CONFIG=''
	pm_panel_load
	return 0
}

pm_is_client() { [ "${PM_DEPLOY:-}" = client ]; }
pm_is_bypass() { [ "${PM_DEPLOY:-}" = bypass ]; }

# ---------------- Dashboard 面板（独立包 luci-app-ferry-dashboard，可选） ----------------
# 面板状态单独放 /etc/config/ferry-dashboard：卸载面板包时整份删除，
# 主包不保存任何面板状态，因此"卸载后面板自动消失"不依赖卸载脚本的记忆。
# secret 只落 /etc/ferry/panel.secret（0600），既不进 UCI 也不进 www 静态文件。
PM_PANEL_CONF=ferry-dashboard
PM_PANEL_SECRET_FILE=${PM_PANEL_SECRET_FILE:-/etc/ferry/panel.secret}

pm_panel_opt() { uci -q get "$PM_PANEL_CONF.main.$1" 2>/dev/null; }

pm_panel_enabled() {
	case "$(pm_panel_opt enabled)" in
		1|on|true|yes|enabled) return 0 ;;
	esac
	return 1
}

pm_panel_port() {
	local p
	p=$(pm_panel_opt port)
	case "$p" in
		''|*[!0-9]*) p=9090 ;;
	esac
	[ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null || p=9090
	echo "$p"
}

# secret：单行、仅 [0-9A-Za-z_-]；文件必须是普通文件（拒绝符号链接），权限强制 0600
# 不用 stat（极简固件常缺该 applet），改用 ls -ld 的首字段判断
pm_panel_secret() {
	local f="$PM_PANEL_SECRET_FILE" s perm
	[ -f "$f" ] && [ ! -L "$f" ] || return 1
	perm=$(ls -ld "$f" 2>/dev/null | awk '{print $1}')
	case "$perm" in
		-rw-------) ;;
		*)
			chmod 600 "$f" 2>/dev/null || return 1
			perm=$(ls -ld "$f" 2>/dev/null | awk '{print $1}')
			[ "$perm" = "-rw-------" ] || return 1
			;;
	esac
	s=$(head -n 1 "$f" 2>/dev/null | tr -d '\r\n')
	case "$s" in
		''|*[!0-9A-Za-z_-]*) return 1 ;;
	esac
	echo "$s"
}

# 绑定地址：只接受 LAN 接口上的 IPv4 地址，明确拒绝 0.0.0.0 / 通配 / IPv6
pm_panel_bind() {
	local ip iface
	iface=${PM_LAN_IFACE:-$(pm_detect_lan_iface)}
	ip=$(uci -q get "$PM_PANEL_CONF.main.bind" 2>/dev/null)
	case "$ip" in
		''|0.0.0.0|'*'|*:*|*[!0-9.]*) ip='' ;;
	esac
	if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
		ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '$3 == "inet" { sub(/\/.*/, "", $4); print $4; exit }')
	fi
	[ -n "$ip" ] || ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	ip=${ip%%/*}
	case "$ip" in
		''|0.0.0.0|*[!0-9.]*) return 1 ;;
	esac
	echo "$ip"
}

# 一次算好注入所需的三件套，避免生成阶段反复调 uci/ip。
# PM_PANEL_REASON: disabled / no_secret / no_bind / ready / self_config / sub_config
pm_panel_load() {
	PM_PANEL_WANT=0
	PM_PANEL_ENABLED=0
	PM_PANEL_INJECTED=0
	PM_PANEL_PORT=9090
	PM_PANEL_BIND=''
	PM_PANEL_SECRET=''
	PM_PANEL_REASON=disabled

	pm_panel_enabled || return 0
	PM_PANEL_WANT=1
	PM_PANEL_ENABLED=1
	PM_PANEL_PORT=$(pm_panel_port)
	PM_PANEL_BIND=$(pm_panel_bind) || PM_PANEL_BIND=''
	PM_PANEL_SECRET=$(pm_panel_secret) || PM_PANEL_SECRET=''
	if [ -z "$PM_PANEL_SECRET" ]; then
		PM_PANEL_ENABLED=0
		PM_PANEL_REASON=no_secret
		return 0
	fi
	if [ -z "$PM_PANEL_BIND" ]; then
		PM_PANEL_ENABLED=0
		PM_PANEL_REASON=no_bind
		return 0
	fi
	PM_PANEL_REASON=ready
	return 0
}

pm_detect_lan_iface() {
	local d
	d=$(uci -q get network.lan.device)
	[ -z "$d" ] && d=$(uci -q get network.lan.ifname)
	[ -z "$d" ] && d=br-lan
	echo "$d"
}

# IPv4 点分地址 + 前缀 -> 网络 CIDR（纯整数运算，兼容 busybox awk）
pm_ipv4_cidr() {
	echo "$1 $2" | awk '{
		split($1, a, ".")
		p = $2 + 0
		if (p < 0 || p > 32) p = 32
		size = 2 ^ (32 - p)
		n = ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4]
		base = int(n / size) * size
		printf "%d.%d.%d.%d/%d\n", int(base / 16777216) % 256, int(base / 65536) % 256, int(base / 256) % 256, base % 256, p
	}'
}

# 点分 netmask -> 前缀长度
pm_netmask_prefix() {
	echo "$1" | awk -F. '{
		p = 0
		for (i = 1; i <= 4; i++) {
			v = $i + 0
			while (v > 0) { p += v % 2; v = int(v / 2) }
		}
		print p
	}'
}

# 输出空格分隔的管理口 CIDR（IPv4 + IPv6）
pm_mgmt_cidrs() {
	local iface out='' raw addr pfx net ip4 nv
	iface=$PM_LAN_IFACE
	[ -n "$iface" ] || iface=br-lan

	if command -v ip >/dev/null 2>&1; then
		raw=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '$3 == "inet" { print $4 }')
		for addr in $raw; do
			ip4=${addr%/*}
			pfx=${addr#*/}
			[ "$pfx" = "$addr" ] && pfx=32
			net=$(pm_ipv4_cidr "$ip4" "$pfx")
			case " $out " in *" $net "*) ;; *) out="$out $net" ;; esac
		done

		raw=$(ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk '$3 == "inet6" { print $4 }')
		for addr in $raw; do
			case " $out " in *" $addr "*) ;; *) out="$out $addr" ;; esac
		done
	fi

	# ip 命令不可用（极简固件）：退回 UCI 的 ipaddr/netmask，至少保住路由器自身地址
	if [ -z "$out" ]; then
		ip4=$(uci -q get network.lan.ipaddr 2>/dev/null)
		nv=$(uci -q get network.lan.netmask 2>/dev/null)
		if [ -n "$ip4" ]; then
			case "$ip4" in */*) out="$out $ip4" ;; *)
				pfx=32
				[ -n "$nv" ] && pfx=$(pm_netmask_prefix "$nv")
				net=$(pm_ipv4_cidr "$ip4" "$pfx")
				out="$out $net"
				;;
			esac
		fi
	fi

	# 最后兜底：路由器 LAN 地址总是 /32 进入 bypass，即使网段识别失败
	echo "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	return 0
}

pm_kernel_bin() {
	local b
	if [ "$PM_KERNEL" = singbox ]; then b=sing-box; else b=mihomo; fi
	if [ -n "${PM_BIN_PATH:-}" ]; then
		echo "$PM_BIN_PATH"
	elif [ -x "${PM_KERNEL_DIR:-/etc/ferry/kernels/current}/$b" ]; then
		# 插件专属目录里的 current 指针（内核管理安装的版本）
		echo "${PM_KERNEL_DIR:-/etc/ferry/kernels/current}/$b"
	else
		# 兼容：插件没有安装内核时，仍可用系统自带二进制（只读，不覆盖）
		echo "${PM_BIN_DIR:-/usr/bin}/$b"
	fi
}

pm_kernel_dir() {
	if [ "$PM_KERNEL" = singbox ]; then
		echo "$PM_SINGBOX_DIR"
	else
		echo "$PM_MIHOMO_DIR"
	fi
}

# mihomo 自带 DNS 监听；sing-box 非 TUN 模式用 direct inbound 充当 DNS 监听
pm_kernel_has_dns() {
	case "$PM_KERNEL" in
		mihomo) return 0 ;;
		singbox) [ "$PM_MODE" != tun ] && return 0 || return 1 ;;
	esac
	return 1
}

# 是否需要把局域网 53 端口重定向到本机 DNS 端口
pm_dns_local() {
	pm_is_client && return 1
	[ "$PM_HIJACK_DNS" = 1 ] && pm_kernel_has_dns
}

# TUN 是否自动接管整机路由：主路由 true，旁路由 false（避免抢主路由的转发）
pm_tun_autoroute() {
	if pm_is_bypass; then
		echo false
	else
		echo true
	 fi
}

# TPROXY 需要 fwmark + 策略路由把报文投递到本机
pm_need_tproxy_route() {
	pm_is_client && return 1
	# 只有真正的 TPROXY 模式才需要策略路由；DNS 全部走 nat REDIRECT 到本机监听
	[ "$PM_MODE" = tproxy ]
}

pm_port_listening() {
	local port="$1"
	command -v netstat >/dev/null 2>&1 || return 0
	netstat -lnt 2>/dev/null | grep -q ":$port "
}

pm_wait_ready() {
	local i=0 port="$PM_PROXY_PORT"

	if pm_is_client; then
		port=$PM_MIXED_PORT
		[ "$port" = 0 ] && port=7891
	fi

	if [ "$PM_MODE" = tun ] && ! pm_is_client; then
		sleep 3
		pgrep -f "$(pm_kernel_bin)" >/dev/null 2>&1
		return $?
	fi

	command -v netstat >/dev/null 2>&1 || { sleep 3; return 0; }

	while [ "$i" -lt 20 ]; do
		if pm_port_listening "$port"; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

pm_count_nodes() {
	local n=0
	[ -f "$PM_NODES_LST" ] || { echo 0; return 0; }
	n=$(grep -c '^BEGIN$' "$PM_NODES_LST" 2>/dev/null)
	echo "${n:-0}"
}

pm_count_rules() {
	local n=0
	[ -f "$PM_RULES_LST" ] || { echo 0; return 0; }
	n=$(grep -c . "$PM_RULES_LST" 2>/dev/null)
	echo "${n:-0}"
}

# 规则同步的整体状态：self（自备配置不同步）/ failed / stale / skipped / ok
# 优先级 failed > stale > skipped > ok，与规则分类逐项状态一致
pm_rule_sync_overall() {
	local f="$PM_RUN_DIR/rules-status.txt" geo st has_ok=0 has_stale=0 has_skipped=0

	[ -n "$PM_RULE_SYNC_MODE" ] && { echo "$PM_RULE_SYNC_MODE"; return 0; }
	[ -f "$f" ] || { echo skipped; return 0; }

	while read -r geo st; do
		[ -n "$geo" ] || continue
		case "$st" in
			failed)  echo failed; return 0 ;;
			stale)   has_stale=1 ;;
			skipped) has_skipped=1 ;;
			ok)      has_ok=1 ;;
		esac
	done < "$f"

	if [ "$has_stale" = 1 ]; then
		echo stale
	elif [ "$has_skipped" = 1 ]; then
		echo skipped
	elif [ "$has_ok" = 1 ]; then
		echo ok
	else
		echo skipped
	fi
	return 0
}

# 输出指定状态的分类名（JSON 数组元素），例如 ok / stale / skipped / failed
pm_rule_sync_list() {
	local f="$PM_RUN_DIR/rules-status.txt" geo st first=1

	[ -f "$f" ] || return 0
	while read -r geo st; do
		[ -n "$geo" ] || continue
		[ "$st" = "$1" ] || continue
		[ "$first" = 1 ] || printf ','
		printf '"%s"' "$(pm_json_esc "$geo")"
		first=0
	done < "$f"
	return 0
}

# 把本次启动的配置结果与告警写到 /etc/ferry/status.json，供 LuCI 读取展示
pm_status_write() {
	local first=1 line
	mkdir -p "$PM_CONF_DIR"
	{
		printf '{"profile":"%s","deploy":"%s","kernel":"%s","mode":"%s","enabled":%s,"nodes":%s,"rules":%s,"updated":"%s","warnings":[' \
			"$(pm_json_esc "$PM_PROFILE_ID")" "$PM_DEPLOY" "$PM_KERNEL" "$PM_MODE" \
			"${PM_ENABLED:-0}" "$(pm_count_nodes)" "$(pm_count_rules)" \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		if [ -f "$PM_RUN_DIR/warnings.txt" ]; then
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				[ "$first" = 1 ] || printf ','
				printf '"%s"' "$(pm_json_esc "$line")"
				first=0
			done < "$PM_RUN_DIR/warnings.txt"
		fi
		printf '],"rule_sync":{"state":"%s","ok":[' "$(pm_rule_sync_overall)"
		pm_rule_sync_list ok
		printf '],"stale":['
		pm_rule_sync_list stale
		printf '],"skipped":['
		pm_rule_sync_list skipped
		printf '],"failed":['
		pm_rule_sync_list failed
		printf ']},"panel":{"enabled":%s,"injected":%s,"port":%s,"bind":"%s","reason":"%s"}}\n' \
			"${PM_PANEL_WANT:-0}" "${PM_PANEL_INJECTED:-0}" "${PM_PANEL_PORT:-9090}" \
			"$(pm_json_esc "${PM_PANEL_BIND:-}")" "$(pm_json_esc "${PM_PANEL_REASON:-disabled}")"
	} > "$PM_STATUS_FILE.tmp" && mv "$PM_STATUS_FILE.tmp" "$PM_STATUS_FILE"
	return 0
}

# 旧配置迁移：只在 profiles.json 不存在时执行
pm_migrate_legacy() {
	[ -f "$PM_PROFILES_FILE" ] && return 0
	[ -f /etc/config/ferry ] || return 0

	mkdir -p "$PM_CONF_DIR" "$PM_RULE_CACHE" "$PM_MIHOMO_DIR/providers" "$PM_SINGBOX_DIR"
	local id=default
	{
		printf '{"version":1,"active":"%s","profiles":[{"id":"%s",' "$id" "$id"
		printf '"name":"默认（由旧配置迁移）",'
		printf '"deploy":"%s","kernel":"%s","mode":"%s",' \
			"$PM_DEPLOY" "$PM_KERNEL" "$PM_MODE"
		printf '"preset":"daily","nodes":[],"updated":"%s","rules":[' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		printf '{"cat":"cn","target":"direct","enabled":true},'
		printf '{"cat":"ads","target":"reject","enabled":true},'
		printf '{"cat":"streaming","target":"proxy","enabled":true},'
		printf '{"cat":"ai","target":"proxy","enabled":true},'
		printf '{"cat":"telegram","target":"proxy","enabled":true},'
		printf '{"cat":"dev","target":"proxy","enabled":true},'
		printf '{"cat":"academic","target":"proxy","enabled":true},'
		printf '{"cat":"game","target":"proxy","enabled":true},'
		printf '{"cat":"custom","target":"proxy","enabled":true}'
		printf '],"custom_domains":[],"custom_cidrs":[]}]}\n'
	} > "$PM_PROFILES_FILE.tmp"
	mv "$PM_PROFILES_FILE.tmp" "$PM_PROFILES_FILE"
	printf '%s\n' "$id" > "$PM_ACTIVE_FILE"
	PM_PROFILE_ID=$id
	pm_log "旧配置已迁移为默认 profile（节点与规则请在 LuCI 中补充）"
	return 0
}

# ---------- dnsmasq 上游改写（路由器自身 DNS 走内核） ----------

PM_DNSMASQ_SECTION='dhcp.@dnsmasq[0]'
# 允许测试覆盖；设备上保持默认值
PM_DHCP_FILE=${PM_DHCP_FILE:-/etc/config/dhcp}
PM_DNSMASQ_INIT=${PM_DNSMASQ_INIT:-/etc/init.d/dnsmasq}

# 备份必须放在持久化目录：/var/etc 是 tmpfs，重启后备份丢失，
# 会导致下次 apply 把本工具改写过的值当成“原始值”，停用/卸载时再写回 → DNS 断
pm_dnsmasq_backup_dir() {
	echo "$PM_CONF_DIR/dnsmasq-backup"
}

# 原始上游的“只读记录”：每次从干净配置采集时刷新，还原时只读不删。
# 一次性备份（dnsmasq-backup）会被还原消耗；崩溃点恰好落在“已消耗未补采”时，
# 没有这份记录就只能把本工具写入的 127.0.0.1#port 误当原始值（导致临时关闭后 DNS 半关）。
pm_dnsmasq_native_record_dir() {
	echo "$PM_CONF_DIR/dnsmasq-native"
}

# 是否是本工具自己写入的上游值（127.0.0.1#port / [::1]#port）
pm_dnsmasq_is_own_server() {
	printf '%s\n' "$1" | grep -Eq '^(127\.0\.0\.1|\[::1\]|::1)#[0-9]+$'
}

# 当前 dnsmasq 上游里是否已经包含本工具写入的值
pm_dnsmasq_has_own_server() {
	uci -q get "$PM_DNSMASQ_SECTION.server" 2>/dev/null | \
		grep -Eq '^(127\.0\.0\.1|\[::1\]|::1)#[0-9]+$'
}

# 过滤上游条目：$1=源文件 $2=输出文件
# 本工具写入的值只计数不输出；含空白等无法识别的行只计数、告警、不输出
# 结果通过 PM_DNSMASQ_VALID_COUNT / PM_DNSMASQ_OWN_COUNT / PM_DNSMASQ_BAD_COUNT 返回

# 单个条目：自身值/损坏值只计数，合法值写入目标文件
pm_dnsmasq_store_entry() {
	local line="$1" dst="$2"

	if pm_dnsmasq_is_own_server "$line"; then
		PM_DNSMASQ_OWN_COUNT=$((PM_DNSMASQ_OWN_COUNT + 1))
		return 0
	fi
	# 含空白或控制字符的条目视为损坏内容：保留现状，不作为原始值写回
	if [ "$line" != "$(printf '%s' "$line" | tr -d '[:space:][:cntrl:]')" ]; then
		PM_DNSMASQ_BAD_COUNT=$((PM_DNSMASQ_BAD_COUNT + 1))
		pm_log "dnsmasq 上游备份条目无法识别，已跳过：$line" warning
		return 0
	fi
	printf '%s\n' "$line" >> "$dst"
	PM_DNSMASQ_VALID_COUNT=$((PM_DNSMASQ_VALID_COUNT + 1))
	return 0
}

pm_dnsmasq_filter_servers() {
	local src="$1" dst="$2" line w ok
	PM_DNSMASQ_VALID_COUNT=0
	PM_DNSMASQ_OWN_COUNT=0
	PM_DNSMASQ_BAD_COUNT=0
	: > "$dst"
	[ -f "$src" ] || return 0

	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r')
		[ -n "$line" ] || continue

		# 新备份用 uci show 采集（"key='value'"），天然一行一条，先剥掉外壳
		case "$line" in
			*"='"*"'" )
				line=${line#*=}
				line=${line#\'}
				line=${line%\'}
				;;
		esac

		# 兼容旧版用 uci get 写的单行多值格式（"1.1.1.1 8.8.8.8"）：
		# 只有整行每个字段都像服务器条目（含数字 / 以 / 或 @ 开头）时才拆分；
		# 否则整行按损坏条目处理，避免把 "not a valid server line" 拆成多个垃圾上游。
		case "$line" in
			*[[:space:]]*)
				ok=1
				for w in $line; do
					case "$w" in
						*[0-9]*|/*|@*) ;;
						*) ok=0 ;;
					esac
				done
				if [ "$ok" = 1 ]; then
					for w in $line; do
						pm_dnsmasq_store_entry "$w" "$dst"
					done
					continue
				fi
				;;
		esac

		pm_dnsmasq_store_entry "$line" "$dst"
	done < "$src"
	return 0
}

pm_dnsmasq_reload() {
	[ -x "$PM_DNSMASQ_INIT" ] || return 0
	"$PM_DNSMASQ_INIT" reload >/dev/null 2>&1 || "$PM_DNSMASQ_INIT" restart >/dev/null 2>&1
	return 0
}

# 硬重启：先等旧实例真正退出再拉起，避免“found already running DHCP-server”导致的崩溃循环
pm_dnsmasq_restart() {
	local i=0
	[ -x "$PM_DNSMASQ_INIT" ] || return 0
	"$PM_DNSMASQ_INIT" stop >/dev/null 2>&1
	while [ $i -lt 10 ] && pgrep -x dnsmasq >/dev/null 2>&1; do
		sleep 1
		i=$((i+1))
	done
	"$PM_DNSMASQ_INIT" start >/dev/null 2>&1
	return 0
}

# 旧版本把备份写在 tmpfs；迁移到持久化目录并清理旧文件
pm_dnsmasq_migrate_legacy_backup() {
	local bakdir legacy="$PM_RUN_DIR/dnsmasq.server.bak"
	bakdir=$(pm_dnsmasq_backup_dir)
	[ -f "$legacy" ] || return 0
	if [ ! -f "$bakdir/server" ]; then
		cp "$legacy" "$bakdir/server" 2>/dev/null
		[ -f "$PM_RUN_DIR/dnsmasq.noresolv.bak" ] && cp "$PM_RUN_DIR/dnsmasq.noresolv.bak" "$bakdir/noresolv" 2>/dev/null
		pm_log "dnsmasq 备份已从 $PM_RUN_DIR 迁移到 $bakdir"
	fi
	rm -f "$legacy" "$PM_RUN_DIR/dnsmasq.noresolv.bak"
	return 0
}

pm_dnsmasq_apply() {
	pm_is_client && return 0
	[ "$PM_ROUTER_DNS" = 1 ] || return 0
	pm_kernel_has_dns || return 0
	[ -f "$PM_DHCP_FILE" ] || return 0
	uci -q get "$PM_DNSMASQ_SECTION" >/dev/null 2>&1 || return 0

	local bakdir native tmp need_capture=0
	bakdir=$(pm_dnsmasq_backup_dir)
	native=$(pm_dnsmasq_native_record_dir)
	mkdir -p "$bakdir" "$PM_RUN_DIR"
	pm_dnsmasq_migrate_legacy_backup

	# 当前上游如果还是“干净”的（不含本工具写入值），它就是真实原始值，
	# 允许刷新备份（可覆盖 uninstall 残留、用户手工改过的配置）；
	# 如果已经含本工具写入值（重启/崩溃后重入），只在缺备份时补记，绝不覆盖旧备份
	if ! pm_dnsmasq_has_own_server; then
		need_capture=1
	elif [ ! -s "$bakdir/server" ]; then
		# 0 字节备份有两种可能：原始上游本来就是空（合法记录），或断电时数据未落盘。
		# 只读记录有内容时用它修复备份；记录存在但为空说明原值就是空，保留空备份；
		# 连记录都没有才算真的缺备份。
		if [ -s "$native/server" ]; then
			cp "$native/server" "$bakdir/server" 2>/dev/null
			[ -f "$native/noresolv" ] && cp "$native/noresolv" "$bakdir/noresolv" 2>/dev/null
		elif [ ! -f "$native/server" ]; then
			need_capture=1
		fi
	fi

	if [ "$need_capture" = 1 ]; then
		if pm_dnsmasq_has_own_server; then
			# 当前配置只剩本工具写入值（还原已消费备份后又在崩溃点重入）：
			# 不能把自身值当原始值，用最近一次记录的原始上游补回备份；
			# 连记录都没有时宁可没有备份，也不要写一份空备份污染后续还原
			if [ -f "$native/server" ]; then
				cp "$native/server" "$bakdir/server" 2>/dev/null
				[ -f "$native/noresolv" ] && cp "$native/noresolv" "$bakdir/noresolv" 2>/dev/null
				pm_log "dnsmasq 原始上游备份缺失，已用最近一次原始上游记录补回"
			else
				rm -f "$bakdir/server" "$bakdir/noresolv"
				pm_log "dnsmasq 原始上游未知（无备份、无记录），跳过捕获" warning
			fi
		else
			tmp="$PM_RUN_DIR/dnsmasq.current"
			# 用 uci show：列表值输出为 'a' 'b'（引号空格分隔）。按引号边界拆成一行一条，
			# 否则整串会被当成一个上游值写回。uci get 则会把多值挤成 "a b" 一行，无法区分坏值。
			uci -q show "$PM_DNSMASQ_SECTION.server" 2>/dev/null | \
				sed -e "s/^[^=]*=//" -e "s/' '/|/g" -e "s/^'//" -e "s/'$//" | \
				tr '|' '\n' > "$tmp" || : > "$tmp"
			pm_dnsmasq_filter_servers "$tmp" "$bakdir/server"
			uci -q get "$PM_DNSMASQ_SECTION.noresolv" > "$bakdir/noresolv" 2>/dev/null || : > "$bakdir/noresolv"
			rm -f "$tmp"
			if [ ! -s "$bakdir/server" ] && [ -s "$native/server" ]; then
				# 当前配置没有显式上游（例如它已被上一次还原清空）时，不要用空值覆盖
				# 已记录的原始上游，否则后续“临时关闭/回滚”会没有可还原的目标，变成 DNS 半关
				pm_log "当前 dnsmasq 无显式上游，保留已记录的原始上游：$(tr '\n' ' ' < "$native/server")" warning
				cp "$native/server" "$bakdir/server" 2>/dev/null
				cp "$native/noresolv" "$bakdir/noresolv" 2>/dev/null
			else
				mkdir -p "$native"
				cp "$bakdir/server" "$native/server" 2>/dev/null
				cp "$bakdir/noresolv" "$native/noresolv" 2>/dev/null
			fi
	fi
	# 断电保护：原始上游记录先落盘，再改 dnsmasq，
	# 否则硬断电会留下 0 字节备份，后续临时关闭/回滚就没有可还原目标
	sync
	fi

	uci -q delete "$PM_DNSMASQ_SECTION.server"
	uci -q add_list "$PM_DNSMASQ_SECTION.server=127.0.0.1#$PM_DNS_PORT"
	uci -q set "$PM_DNSMASQ_SECTION.noresolv=1"
	uci -q commit dhcp
	pm_dnsmasq_restart
	pm_log "dnsmasq 上游已指向 127.0.0.1#$PM_DNS_PORT"
	return 0
}

pm_dnsmasq_restore() {
	local bakdir native src nvsrc filtered sv nv
	bakdir=$(pm_dnsmasq_backup_dir)
	native=$(pm_dnsmasq_native_record_dir)
	# 升级后若只在旧的 /var 里留有备份，先迁移再做恢复
	if [ -f "$PM_RUN_DIR/dnsmasq.server.bak" ]; then
		mkdir -p "$bakdir"
		pm_dnsmasq_migrate_legacy_backup
	fi
	# 优先一次性备份；备份缺失时退回只读原始记录。
	# 0 字节备份是合法记录（原始上游本来就是空），不能当成“无备份”直接返回。
	src="$bakdir/server"
	[ -f "$src" ] || src="$native/server"
	[ -f "$src" ] || return 0
	# 备份为空但只读记录有真实内容（断电未落盘）时，用记录恢复
	if [ ! -s "$src" ] && [ -s "$native/server" ] && [ "$src" != "$native/server" ]; then
		src="$native/server"
	fi
	[ -f "$PM_DHCP_FILE" ] || return 0
	uci -q get "$PM_DNSMASQ_SECTION" >/dev/null 2>&1 || return 0

	# 写回前先过滤：本工具写入的值不能当原始值；旧版本污染的备份也能被纠正
	# 过滤结果写到 tmpfs（备份目录可能已被上一次还原删除）
	mkdir -p "$PM_RUN_DIR"
	filtered="$PM_RUN_DIR/dnsmasq.server.sanitized"
	pm_dnsmasq_filter_servers "$src" "$filtered"

	# 备份非空但全部无法识别：宁可保留现状并告警，也不覆盖用户配置
	if [ "$PM_DNSMASQ_VALID_COUNT" = 0 ] && [ "$PM_DNSMASQ_BAD_COUNT" -gt 0 ]; then
		rm -f "$filtered"
		pm_log "dnsmasq 备份 $src 内容无法识别，为避免覆盖用户配置跳过恢复，请手动检查 $PM_DHCP_FILE" err
		return 1
	# 断电保护：原始上游记录先落盘，再改 dnsmasq，
	# 否则硬断电会留下 0 字节备份，后续临时关闭/回滚就没有可还原目标
	sync
	fi

	uci -q delete "$PM_DNSMASQ_SECTION.server"
	while IFS= read -r sv; do
		[ -n "$sv" ] && uci -q add_list "$PM_DNSMASQ_SECTION.server=$sv"
	done < "$filtered"

	nvsrc="$bakdir/noresolv"
	[ "$src" = "$bakdir/server" ] || nvsrc="$native/noresolv"
	nv=''
	[ -f "$nvsrc" ] && nv=$(tr -d '\r\n' < "$nvsrc" 2>/dev/null)
	case "$nv" in
		1|0) uci -q set "$PM_DNSMASQ_SECTION.noresolv=$nv" ;;
		*)   uci -q delete "$PM_DNSMASQ_SECTION.noresolv" ;;
	esac

	uci -q commit dhcp
	pm_dnsmasq_restart

	rm -f "$filtered"
	# 只消费一次性备份；原始记录长期保留，供崩溃点/再次接管使用
	if [ "$src" = "$bakdir/server" ]; then
		# 消费备份前先把内容补进只读记录，避免下次接管时“既无备份也无记录”
		mkdir -p "$native"
		cp "$src" "$native/server" 2>/dev/null
		[ -f "$bakdir/noresolv" ] && cp "$bakdir/noresolv" "$native/noresolv" 2>/dev/null
		rm -f "$bakdir/server" "$bakdir/noresolv"
		rmdir "$bakdir" 2>/dev/null
	fi
	pm_log "已恢复 dnsmasq 原始上游配置"
	return 0
}
