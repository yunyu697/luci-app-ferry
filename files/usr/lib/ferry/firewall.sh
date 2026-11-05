#!/bin/sh
# Ferry 流量接管：nftables 优先，iptables 兼容；含 TPROXY 策略路由与清理

pm_builtin_bypass4_list() {
	echo '127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 224.0.0.0/4 240.0.0.0/4'
	# 注意：本函数输出以空格分隔，供 iptables 循环使用
}

pm_bypass_elements() {
	local fam="$1" out item has_colon

	if [ "$fam" = ip6 ]; then
		out='::1/128,fc00::/7,fe80::/10,ff00::/8'
	else
		out='127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10,224.0.0.0/4,240.0.0.0/4'
	fi

	for item in ${PM_BYPASS_CIDR:-} ${PM_BYPASS_IP:-}; do
		[ -n "$item" ] || continue
		has_colon=0
		case "$item" in *:*) has_colon=1 ;; esac
		if [ "$fam" = ip ] && [ "$has_colon" = 1 ]; then
			continue
		fi
		if [ "$fam" = ip6 ] && [ "$has_colon" = 0 ]; then
			continue
		fi
		out="$out,$item"
	done
	echo "$out"
}

# 管理口网段：来自 common.sh 的 PM_MGMT_CIDRS（LAN 网段 + 路由器自身地址）。
# 独立成集合，规则写死且永远排在任何接管规则之前；用户 bypass 配置无法移除。
pm_mgmt_elements() {
	local fam="$1" item out='' has_colon
	for item in $PM_MGMT_CIDRS; do
		[ -n "$item" ] || continue
		has_colon=0
		case "$item" in *:*) has_colon=1 ;; esac
		if [ "$fam" = ip ] && [ "$has_colon" = 1 ]; then
			continue
		fi
		if [ "$fam" = ip6 ] && [ "$has_colon" = 0 ]; then
			continue
		fi
		if [ -n "$out" ]; then
			out="$out,$item"
		else
			out="$item"
		fi
	done
	echo "$out"
}

pm_lanif_elements() {
	local out='' iface
	for iface in $PM_LAN_IFACES; do
		if [ -n "$out" ]; then
			out="$out, \"$iface\""
		else
			out="\"$iface\""
		fi
	done
	[ -n "$out" ] || out='"br-lan"'
	echo "$out"
}

# 生成 nft 规则文件： $1=ip|ip6  $2=表名  $3=输出文件
pm_nft_build() {
	local fam="$1" table="$2" file="$3"
	local daddr setname dtype mgname mgelem

	if [ "$fam" = ip6 ]; then
		daddr='ip6 daddr'
		setname='bypass6'
		dtype='ipv6_addr'
		mgname='mgmt6'
	else
		daddr='ip daddr'
		setname='bypass4'
		dtype='ipv4_addr'
		mgname='mgmt4'
	fi
	mgelem=$(pm_mgmt_elements "$fam")

	{
		printf 'table %s %s {\n' "$fam" "$table"
		printf '\tset %s {\n\t\ttype %s\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { %s }\n\t}\n' \
			"$setname" "$dtype" "$(pm_bypass_elements "$fam")"
		# 管理口集合：硬编码，空集合不输出
		if [ -n "$mgelem" ]; then
			printf '\t# mgmt: management subnet/router address, never captured\n'
			printf '\tset %s {\n\t\ttype %s\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { %s }\n\t}\n' \
				"$mgname" "$dtype" "$mgelem"
		fi
		printf '\tset lanif {\n\t\ttype ifname\n\t\telements = { %s }\n\t}\n' "$(pm_lanif_elements)"

		# 1) DNS 劫持：局域网 53 -> 内核 DNS 监听端口（仅内核自带 DNS 时启用）
		if pm_dns_local; then
			printf '\tchain dns_prerouting {\n'
			printf '\t\ttype nat hook prerouting priority -110; policy accept;\n'
			printf '\t\t%s @%s return\n' "$daddr" "$setname"
			printf '\t\tiifname @lanif udp dport 53 redirect to :%s\n' "$PM_DNS_PORT"
			printf '\t\tiifname @lanif tcp dport 53 redirect to :%s\n' "$PM_DNS_PORT"
			printf '\t}\n'
		fi

		if [ "$PM_MODE" = tproxy ]; then
			printf '\tchain tproxy_prerouting {\n'
			printf '\t\ttype filter hook prerouting priority -150; policy accept;\n'
			printf '\t\tiifname != @lanif return\n'
			if [ -n "$mgelem" ]; then
				printf '\t\t%s @%s return\n' "$daddr" "$mgname"
			fi
			printf '\t\t%s @%s return\n' "$daddr" "$setname"
			if pm_dns_local; then
				printf '\t\tudp dport 53 return\n'
				printf '\t\ttcp dport 53 return\n'
			fi
			printf '\t\tmeta l4proto tcp meta mark set %s tproxy to :%s\n' "$PM_IP_MARK" "$PM_PROXY_PORT"
			printf '\t\tmeta l4proto udp meta mark set %s tproxy to :%s\n' "$PM_IP_MARK" "$PM_PROXY_PORT"
			printf '\t}\n'
		elif [ "$PM_MODE" = redirect ]; then
			printf '\tchain redir_prerouting {\n'
			printf '\t\ttype nat hook prerouting priority -100; policy accept;\n'
			printf '\t\tiifname != @lanif return\n'
			if [ -n "$mgelem" ]; then
				printf '\t\t%s @%s return\n' "$daddr" "$mgname"
			fi
			printf '\t\t%s @%s return\n' "$daddr" "$setname"
			printf '\t\tmeta l4proto tcp redirect to :%s\n' "$PM_PROXY_PORT"
			printf '\t}\n'

			if [ "$PM_BLOCK_QUIC" = 1 ]; then
				printf '\tchain quic_guard {\n'
				printf '\t\ttype filter hook prerouting priority -150; policy accept;\n'
				printf '\t\tiifname != @lanif return\n'
				if [ -n "$mgelem" ]; then
					printf '\t\t%s @%s return\n' "$daddr" "$mgname"
				fi
				printf '\t\t%s @%s return\n' "$daddr" "$setname"
				printf '\t\tiifname @lanif udp dport 443 reject\n'
				printf '\t}\n'
			fi
		fi

		printf '}\n'
	} > "$3"
	return 0
}

pm_nft_up() {
	local f4="$PM_RUN_DIR/ferry-v4.nft"
	local f6="$PM_RUN_DIR/ferry-v6.nft"
	local err
	mkdir -p "$PM_RUN_DIR"

	# TPROXY 依赖内核模块；缺失时给出明确原因，而不是把 nft 的 ENOENT 抛给用户
	if [ "$PM_MODE" = tproxy ]; then
		modprobe nft_tproxy 2>/dev/null
		if ! grep -q '^nft_tproxy' /proc/modules 2>/dev/null; then
			pm_log "TPROXY 无法启用：缺少内核模块 kmod-nft-tproxy（安装该模块后重试）" err
			return 1
		fi
	fi

	nft delete table ip "$PM_NFT_TABLE" 2>/dev/null
	pm_nft_build ip "$PM_NFT_TABLE" "$f4" || return 1
	err=$(nft -f "$f4" 2>&1)
	if [ $? -ne 0 ]; then
		pm_log "nft 规则加载失败（IPv4）：$err" err
		return 1
	fi

	if [ "$PM_ENABLE_IPV6" = 1 ]; then
		nft delete table ip6 "$PM_NFT_TABLE6" 2>/dev/null
		pm_nft_build ip6 "$PM_NFT_TABLE6" "$f6" || return 1
		err=$(nft -f "$f6" 2>&1)
		if [ $? -ne 0 ]; then
			pm_log "nft 规则加载失败（IPv6），IPv6 将保持直连：$err" warning
			nft delete table ip6 "$PM_NFT_TABLE6" 2>/dev/null
		fi
	fi
	return 0
}

pm_nft_down() {
	nft delete table ip "$PM_NFT_TABLE" 2>/dev/null
	nft delete table ip6 "$PM_NFT_TABLE6" 2>/dev/null
	return 0
}

# ---------------- iptables 兼容路径（IPv4） ----------------

pm_ipt_chain_down() {
	local table="$1" chain="$2" i
	# 多次删除跳转，兼容上次异常退出留下的重复规则
	for i in 1 2 3 4; do
		iptables -t "$table" -D PREROUTING -j "$chain" 2>/dev/null || break
	done
	iptables -t "$table" -F "$chain" 2>/dev/null
	iptables -t "$table" -X "$chain" 2>/dev/null
	return 0
}

# iptables 路径的管理口 RETURN：先于任何接管规则插入
pm_ipt_mgmt_rules() {
	local table="$1" chain="$2" iface item
	for iface in $PM_LAN_IFACES; do
		for item in $PM_MGMT_CIDRS; do
			[ -n "$item" ] || continue
			case "$item" in *:*) continue ;; esac
			iptables -t "$table" -A "$chain" -i "$iface" -d "$item" -j RETURN 2>/dev/null
		done
	done
}

pm_ipt_up() {
	local iface item

	command -v iptables >/dev/null 2>&1 || {
		pm_log "未找到 iptables，无法使用 iptables 后端" err
		return 1
	}

	pm_ipt_chain_down nat PM_DNS
	pm_ipt_chain_down nat PM_REDIR
	pm_ipt_chain_down mangle PM_TPROXY
	pm_ipt_chain_down mangle PM_QUIC

	if pm_dns_local; then
		iptables -t nat -N PM_DNS
		for iface in $PM_LAN_IFACES; do
			for item in $(pm_builtin_bypass4_list) $PM_BYPASS_CIDR $PM_BYPASS_IP; do
				[ -n "$item" ] || continue
				case "$item" in *:*) continue ;; esac
				iptables -t nat -A PM_DNS -i "$iface" -d "$item" -j RETURN
			done
			iptables -t nat -A PM_DNS -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$PM_DNS_PORT"
			iptables -t nat -A PM_DNS -i "$iface" -p tcp --dport 53 -j REDIRECT --to-ports "$PM_DNS_PORT"
		done
		iptables -t nat -I PREROUTING 1 -j PM_DNS
	fi

	if [ "$PM_MODE" = tproxy ]; then
		modprobe xt_TPROXY 2>/dev/null
		if ! grep -q '^xt_TPROXY' /proc/modules 2>/dev/null; then
			pm_log "TPROXY 无法启用：缺少内核模块 xt_TPROXY（kmod-ipt-tproxy）" err
			return 1
		fi
		iptables -t mangle -N PM_TPROXY
		pm_ipt_mgmt_rules mangle PM_TPROXY
		for iface in $PM_LAN_IFACES; do
			for item in $(pm_builtin_bypass4_list) $PM_BYPASS_CIDR $PM_BYPASS_IP; do
				[ -n "$item" ] || continue
				case "$item" in *:*) continue ;; esac
				iptables -t mangle -A PM_TPROXY -i "$iface" -d "$item" -j RETURN
			done
			if pm_dns_local; then
				iptables -t mangle -A PM_TPROXY -i "$iface" -p udp --dport 53 -j RETURN
				iptables -t mangle -A PM_TPROXY -i "$iface" -p tcp --dport 53 -j RETURN
			fi
			iptables -t mangle -A PM_TPROXY -i "$iface" -p tcp \
				-j TPROXY --on-ip 127.0.0.1 --on-port "$PM_PROXY_PORT" \
				--tproxy-mark "$PM_IP_MARK/$PM_IP_MARK"
			iptables -t mangle -A PM_TPROXY -i "$iface" -p udp \
				-j TPROXY --on-ip 127.0.0.1 --on-port "$PM_PROXY_PORT" \
				--tproxy-mark "$PM_IP_MARK/$PM_IP_MARK"
		done
		iptables -t mangle -I PREROUTING 1 -j PM_TPROXY
	elif [ "$PM_MODE" = redirect ]; then
		iptables -t nat -N PM_REDIR
		pm_ipt_mgmt_rules nat PM_REDIR
		for iface in $PM_LAN_IFACES; do
			for item in $(pm_builtin_bypass4_list) $PM_BYPASS_CIDR $PM_BYPASS_IP; do
				[ -n "$item" ] || continue
				case "$item" in *:*) continue ;; esac
				iptables -t nat -A PM_REDIR -i "$iface" -d "$item" -j RETURN
			done
			iptables -t nat -A PM_REDIR -i "$iface" -p tcp -j REDIRECT --to-ports "$PM_PROXY_PORT"
		done
		# 注意用 -A：mihomo 的 PM_DNS 已插在 PREROUTING 首位，REDIRECT 链必须排在它后面
		iptables -t nat -A PREROUTING -j PM_REDIR

		if [ "$PM_BLOCK_QUIC" = 1 ]; then
			iptables -t mangle -N PM_QUIC
			pm_ipt_mgmt_rules mangle PM_QUIC
			for iface in $PM_LAN_IFACES; do
				for item in $(pm_builtin_bypass4_list) $PM_BYPASS_CIDR $PM_BYPASS_IP; do
					[ -n "$item" ] || continue
					case "$item" in *:*) continue ;; esac
					iptables -t mangle -A PM_QUIC -i "$iface" -d "$item" -j RETURN
				done
				iptables -t mangle -A PM_QUIC -i "$iface" -p udp --dport 443 -j DROP
			done
			iptables -t mangle -I PREROUTING 1 -j PM_QUIC
		fi
	fi
	return 0
}

pm_ipt_down() {
	pm_ipt_chain_down nat PM_DNS
	pm_ipt_chain_down nat PM_REDIR
	pm_ipt_chain_down mangle PM_TPROXY
	pm_ipt_chain_down mangle PM_DNS
	pm_ipt_chain_down mangle PM_QUIC
	return 0
}

# ---------------- TPROXY 策略路由 ----------------

pm_route_up() {
	ip rule add fwmark "$PM_IP_MARK" table "$PM_IP_ROUTE_TABLE" 2>/dev/null
	ip route add local default dev lo table "$PM_IP_ROUTE_TABLE" 2>/dev/null
	if [ "$PM_ENABLE_IPV6" = 1 ]; then
		ip -6 rule add fwmark "$PM_IP_MARK" table "$PM_IP_ROUTE_TABLE" 2>/dev/null
		ip -6 route add local default dev lo table "$PM_IP_ROUTE_TABLE" 2>/dev/null
	fi
	return 0
}

pm_route_down() {
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

# ---------------- 对外入口 ----------------

pm_fw_backend_resolved() {
	case "$PM_FW_BACKEND" in
		nft) echo nft ;;
		iptables) echo iptables ;;
		*)
			if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
				echo nft
			elif command -v iptables >/dev/null 2>&1; then
				echo iptables
			else
				echo none
			fi
			;;
	esac
}

pm_fw_up() {
	# 客户端形态只生成配置，不接管任何转发流量
	if pm_is_client; then
		PM_FW_RESOLVED=none
		pm_log "客户端形态：不安装接管规则，仅提供 mixed 端口与配置文件"
		return 0
	fi

	PM_FW_RESOLVED=$(pm_fw_backend_resolved)
	pm_log "接管方式=$PM_FW_RESOLVED 形态=$PM_DEPLOY 内核=$PM_KERNEL 模式=$PM_MODE 端口=$PM_PROXY_PORT"

	if [ "$PM_FW_RESOLVED" = none ]; then
		pm_log "系统既没有 nft 也没有 iptables，无法安装接管规则" err
		return 1
	fi

	pm_need_tproxy_route && pm_route_up

	case "$PM_FW_RESOLVED" in
		nft) pm_nft_up || return 1 ;;
		iptables) pm_ipt_up || return 1 ;;
	esac
	return 0
}

pm_fw_down() {
	pm_nft_down
	pm_ipt_down
	pm_route_down
	rm -f "$PM_RUN_DIR/ferry-v4.nft" "$PM_RUN_DIR/ferry-v6.nft" 2>/dev/null
	return 0
}
