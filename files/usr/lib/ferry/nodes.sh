#!/bin/sh
# nodes.lst（LuCI 编译产物）-> mihomo proxies / sing-box outbounds
#
# nodes.lst 由 LuCI 写入：每条节点是一个 BEGIN/END 块，块内 KEY=VALUE。
# 所有字符串值已由前端做好双引号转义，这里直接放进 "..." 里即可。

pm_node_reset() {
	NODE_NAME='' NODE_TYPE='' NODE_ENABLED='' NODE_SERVER='' NODE_PORT=''
	NODE_UUID='' NODE_PASSWORD='' NODE_CIPHER='' NODE_ALTER_ID='' NODE_SCY='' NODE_FLOW=''
	NODE_NETWORK='' NODE_PATH='' NODE_HOST='' NODE_SERVICE=''
	NODE_TLS='' NODE_SNI='' NODE_ALPN='' NODE_FP='' NODE_PBK='' NODE_SID='' NODE_INSECURE=''
	NODE_PLUGIN='' NODE_PLUGIN_OPTS=''
	NODE_SSR_PROTOCOL='' NODE_SSR_OBFS='' NODE_SSR_PROTOCOL_PARAM='' NODE_SSR_OBFS_PARAM=''
	NODE_HY_OBFS='' NODE_HY_OBFS_PASSWORD='' NODE_HY_UP='' NODE_HY_DOWN=''
	NODE_TUIC_CC='' NODE_TUIC_UDP=''
}

# 每个启用节点调用一次 $1
pm_nodes_each() {
	local cb="$1" f="$PM_NODES_LST" line key value
	[ -f "$f" ] || return 0
	pm_node_reset
	while IFS= read -r line; do
		case "$line" in
			BEGIN)
				pm_node_reset
				;;
			END)
				[ "$NODE_ENABLED" = 1 ] || continue
				[ -n "$NODE_TYPE" ] || continue
				[ -n "$NODE_SERVER" ] || continue
				"$cb" || return 1
				;;
			*=*)
				key=${line%%=*}
				value=${line#*=}
				case "$key" in
					name) NODE_NAME="$value" ;;
					type) NODE_TYPE="$value" ;;
					enabled) NODE_ENABLED="$value" ;;
					server) NODE_SERVER="$value" ;;
					port) NODE_PORT="$value" ;;
					uuid) NODE_UUID="$value" ;;
					password) NODE_PASSWORD="$value" ;;
					cipher) NODE_CIPHER="$value" ;;
					alter_id) NODE_ALTER_ID="$value" ;;
					scy) NODE_SCY="$value" ;;
					flow) NODE_FLOW="$value" ;;
					network) NODE_NETWORK="$value" ;;
					path) NODE_PATH="$value" ;;
					host) NODE_HOST="$value" ;;
					service_name) NODE_SERVICE="$value" ;;
					tls) NODE_TLS="$value" ;;
					sni) NODE_SNI="$value" ;;
					alpn) NODE_ALPN="$value" ;;
					fingerprint) NODE_FP="$value" ;;
					public_key) NODE_PBK="$value" ;;
					short_id) NODE_SID="$value" ;;
					insecure) NODE_INSECURE="$value" ;;
					plugin) NODE_PLUGIN="$value" ;;
					plugin_opts) NODE_PLUGIN_OPTS="$value" ;;
					ssr_protocol) NODE_SSR_PROTOCOL="$value" ;;
					ssr_obfs) NODE_SSR_OBFS="$value" ;;
					ssr_protocol_param) NODE_SSR_PROTOCOL_PARAM="$value" ;;
					ssr_obfs_param) NODE_SSR_OBFS_PARAM="$value" ;;
					hy_obfs) NODE_HY_OBFS="$value" ;;
					hy_obfs_password) NODE_HY_OBFS_PASSWORD="$value" ;;
					hy_up) NODE_HY_UP="$value" ;;
					hy_down) NODE_HY_DOWN="$value" ;;
					tuic_cc) NODE_TUIC_CC="$value" ;;
					tuic_udp) NODE_TUIC_UDP="$value" ;;
				esac
				;;
		esac
	done < "$f"
	return 0
}

# ---------------- mihomo ----------------

pm_kv() { printf '    %s\n' "$1"; }

# $1 = SNI 字段名（vmess/vless 用 servername，trojan/hysteria2/tuic 用 sni）
# $2 = 是否输出 tls: true（只有 vmess/vless 需要）
# $3 = 是否输出 client-fingerprint（uTLS，仅 vmess/vless/trojan 支持）
pm_mihomo_tls() {
	local sni_key="$1" emit_tls="$2" utls="$3"
	[ "$NODE_TLS" = 1 ] || return 0
	[ "$emit_tls" = 1 ] && pm_kv "tls: true"
	[ -n "$NODE_SNI" ] && pm_kv "$sni_key: \"$NODE_SNI\""
	[ "$utls" = 1 ] && [ -n "$NODE_FP" ] && pm_kv "client-fingerprint: \"$NODE_FP\""
	if [ -n "$NODE_PBK" ]; then
		pm_kv "reality-opts:"
		pm_kv "  public-key: \"$NODE_PBK\""
		[ -n "$NODE_SID" ] && pm_kv "  short-id: \"$NODE_SID\""
	fi
	if [ -n "$NODE_ALPN" ]; then
		pm_kv "alpn:"
		local a
		for a in $(printf '%s' "$NODE_ALPN" | tr ',' ' '); do
			[ -n "$a" ] && pm_kv "  - \"$a\""
		done
	fi
	[ "$NODE_INSECURE" = 1 ] && pm_kv "skip-cert-verify: true"
	return 0
}

pm_mihomo_transport() {
	case "$NODE_NETWORK" in
		ws)
			pm_kv "network: ws"
			pm_kv "ws-opts:"
			pm_kv "  path: \"${NODE_PATH:-/}\""
			[ -n "$NODE_HOST" ] && pm_kv "  headers:" && pm_kv "    Host: \"$NODE_HOST\""
			;;
		grpc)
			pm_kv "network: grpc"
			if [ -n "$NODE_SERVICE" ]; then
				pm_kv "grpc-opts:"
				pm_kv "  grpc-service-name: \"$NODE_SERVICE\""
			fi
			;;
	esac
	return 0
}

pm_mihomo_ss_plugin() {
	local p="$NODE_PLUGIN" opts="$NODE_PLUGIN_OPTS" o mode='' host='' path='' tls=''
	case "$p" in
		obfs-local|obfs|simple-obfs) p=obfs ;;
		v2ray-plugin) p=v2ray-plugin ;;
		*) pm_warn "mihomo 未实现该 SS 插件，已忽略：$p"; return 0 ;;
	esac
	pm_kv "plugin: $p"
	for o in $(printf '%s' "$opts" | tr ';' ' '); do
		case "$o" in
			obfs=*) mode=${o#obfs=} ;;
			obfs-host=*) host=${o#obfs-host=} ;;
			mode=*) mode=${o#mode=} ;;
			host=*) host=${o#host=} ;;
			path=*) path=${o#path=} ;;
			tls) tls=1 ;;
			tls=*) tls=${o#tls=} ;;
		esac
	done
	[ -n "$mode$host$path$tls" ] || return 0
	pm_kv "plugin-opts:"
	[ -n "$mode" ] && pm_kv "  mode: $mode"
	[ -n "$host" ] && pm_kv "  host: \"$host\""
	[ -n "$path" ] && pm_kv "  path: \"$path\""
	if [ "$tls" = 1 ] || [ "$tls" = true ]; then
		pm_kv "  tls: true"
	fi
	return 0
}

pm_mihomo_node() {
	printf '  - name: "%s"\n' "$NODE_NAME"
	pm_kv "type: $NODE_TYPE"
	pm_kv "server: \"$NODE_SERVER\""
	pm_kv "port: $NODE_PORT"
	pm_kv "udp: true"

	case "$NODE_TYPE" in
		vmess)
			pm_kv "uuid: \"$NODE_UUID\""
			pm_kv "alterId: ${NODE_ALTER_ID:-0}"
			pm_kv "cipher: ${NODE_SCY:-auto}"
			pm_mihomo_tls servername 1 1
			pm_mihomo_transport
			;;
		vless)
			pm_kv "uuid: \"$NODE_UUID\""
			[ -n "$NODE_FLOW" ] && pm_kv "flow: \"$NODE_FLOW\""
			pm_mihomo_tls servername 1 1
			pm_mihomo_transport
			;;
		ss)
			pm_kv "cipher: \"$NODE_CIPHER\""
			pm_kv "password: \"$NODE_PASSWORD\""
			[ -n "$NODE_PLUGIN" ] && pm_mihomo_ss_plugin
			;;
		ssr)
			pm_kv "cipher: \"$NODE_CIPHER\""
			pm_kv "password: \"$NODE_PASSWORD\""
			pm_kv "obfs: \"${NODE_SSR_OBFS:-plain}\""
			pm_kv "protocol: \"${NODE_SSR_PROTOCOL:-origin}\""
			[ -n "$NODE_SSR_OBFS_PARAM" ] && pm_kv "obfs-param: \"$NODE_SSR_OBFS_PARAM\""
			[ -n "$NODE_SSR_PROTOCOL_PARAM" ] && pm_kv "protocol-param: \"$NODE_SSR_PROTOCOL_PARAM\""
			;;
		trojan)
			pm_kv "password: \"$NODE_PASSWORD\""
			NODE_TLS=1
			pm_mihomo_tls sni 0 1
			pm_mihomo_transport
			;;
		hysteria2)
			pm_kv "password: \"$NODE_PASSWORD\""
			NODE_TLS=1
			pm_mihomo_tls sni 0 0
			[ -n "$NODE_HY_OBFS" ] && pm_kv "obfs: \"$NODE_HY_OBFS\""
			[ -n "$NODE_HY_OBFS_PASSWORD" ] && pm_kv "obfs-password: \"$NODE_HY_OBFS_PASSWORD\""
			[ -n "$NODE_HY_UP" ] && pm_kv "up: \"$NODE_HY_UP\""
			[ -n "$NODE_HY_DOWN" ] && pm_kv "down: \"$NODE_HY_DOWN\""
			;;
		tuic)
			pm_kv "uuid: \"$NODE_UUID\""
			pm_kv "password: \"$NODE_PASSWORD\""
			NODE_TLS=1
			pm_mihomo_tls sni 0 0
			[ -n "$NODE_TUIC_CC" ] && pm_kv "congestion-controller: \"$NODE_TUIC_CC\""
			[ -n "$NODE_TUIC_UDP" ] && pm_kv "udp-relay-mode: \"$NODE_TUIC_UDP\""
			;;
		*)
			pm_warn "mihomo 不支持的节点类型：$NODE_TYPE"
			;;
	esac
	return 0
}

pm_mihomo_collect() {
	pm_mihomo_node >> "$PM_RUN_DIR/mihomo-proxies.txt"
	printf '%s\n' "$NODE_NAME" >> "$PM_RUN_DIR/mihomo-names.txt"
	return 0
}

pm_mihomo_nodes() {
	: > "$PM_RUN_DIR/mihomo-proxies.txt"
	: > "$PM_RUN_DIR/mihomo-names.txt"
	pm_nodes_each pm_mihomo_collect
	return 0
}

# ---------------- sing-box ----------------

pm_sb_transport() {
	SB_TRANSPORT=''
	case "$NODE_NETWORK" in
		ws)
			SB_TRANSPORT=",\"transport\":{\"type\":\"ws\",\"path\":\"${NODE_PATH:-/}\""
			[ -n "$NODE_HOST" ] && SB_TRANSPORT="$SB_TRANSPORT,\"headers\":{\"Host\":\"$NODE_HOST\"}"
			SB_TRANSPORT="$SB_TRANSPORT}"
			;;
		grpc)
			if [ -n "$NODE_SERVICE" ]; then
				SB_TRANSPORT=",\"transport\":{\"type\":\"grpc\",\"service_name\":\"$NODE_SERVICE\"}"
			fi
			;;
	esac
	return 0
}

pm_sb_tls() {
	SB_TLS=''
	[ "$NODE_TLS" = 1 ] || return 0
	SB_TLS=",\"tls\":{\"enabled\":true"
	[ -n "$NODE_SNI" ] && SB_TLS="$SB_TLS,\"server_name\":\"$NODE_SNI\""
	[ "$NODE_INSECURE" = 1 ] && SB_TLS="$SB_TLS,\"insecure\":true"
	if [ -n "$NODE_ALPN" ]; then
		local a alist=''
		for a in $(printf '%s' "$NODE_ALPN" | tr ',' ' '); do
			[ -n "$a" ] || continue
			[ -n "$alist" ] && alist="$alist,"
			alist="$alist\"$a\""
		done
		[ -n "$alist" ] && SB_TLS="$SB_TLS,\"alpn\":[$alist]"
	fi
	[ -n "$NODE_FP" ] && SB_TLS="$SB_TLS,\"utls\":{\"enabled\":true,\"fingerprint\":\"$NODE_FP\"}"
	if [ -n "$NODE_PBK" ]; then
		SB_TLS="$SB_TLS,\"reality\":{\"enabled\":true,\"public_key\":\"$NODE_PBK\""
		[ -n "$NODE_SID" ] && SB_TLS="$SB_TLS,\"short_id\":\"$NODE_SID\""
		SB_TLS="$SB_TLS}"
	fi
	SB_TLS="$SB_TLS}"
	return 0
}

pm_singbox_node() {
	local out=''

	case "$NODE_TYPE" in
		ssr)
			pm_warn "sing-box 内核不生成 SSR 节点（已不再支持）：$NODE_NAME"
			return 0
			;;
		ss)
			out="{\"type\":\"shadowsocks\",\"tag\":\"$NODE_NAME\",\"server\":\"$NODE_SERVER\",\"server_port\":$NODE_PORT,\"method\":\"$NODE_CIPHER\",\"password\":\"$NODE_PASSWORD\""
			[ -n "$NODE_PLUGIN" ] && out="$out,\"plugin\":\"$NODE_PLUGIN\""
			[ -n "$NODE_PLUGIN_OPTS" ] && out="$out,\"plugin_opts\":\"$NODE_PLUGIN_OPTS\""
			;;
		vmess)
			out="{\"type\":\"vmess\",\"tag\":\"$NODE_NAME\",\"server\":\"$NODE_SERVER\",\"server_port\":$NODE_PORT,\"uuid\":\"$NODE_UUID\",\"security\":\"${NODE_SCY:-auto}\",\"alter_id\":${NODE_ALTER_ID:-0}"
			pm_sb_tls
			pm_sb_transport
			out="$out$SB_TLS$SB_TRANSPORT"
			;;
		vless)
			out="{\"type\":\"vless\",\"tag\":\"$NODE_NAME\",\"server\":\"$NODE_SERVER\",\"server_port\":$NODE_PORT,\"uuid\":\"$NODE_UUID\""
			[ -n "$NODE_FLOW" ] && out="$out,\"flow\":\"$NODE_FLOW\""
			pm_sb_tls
			pm_sb_transport
			out="$out$SB_TLS$SB_TRANSPORT"
			;;
		trojan)
			NODE_TLS=1
			pm_sb_tls
			pm_sb_transport
			out="{\"type\":\"trojan\",\"tag\":\"$NODE_NAME\",\"server\":\"$NODE_SERVER\",\"server_port\":$NODE_PORT,\"password\":\"$NODE_PASSWORD\"$SB_TLS$SB_TRANSPORT"
			;;
		hysteria2)
			NODE_TLS=1
			pm_sb_tls
			out="{\"type\":\"hysteria2\",\"tag\":\"$NODE_NAME\",\"server\":\"$NODE_SERVER\",\"server_port\":$NODE_PORT,\"password\":\"$NODE_PASSWORD\""
			if [ -n "$NODE_HY_OBFS" ]; then
				out="$out,\"obfs\":{\"type\":\"$NODE_HY_OBFS\""
				[ -n "$NODE_HY_OBFS_PASSWORD" ] && out="$out,\"password\":\"$NODE_HY_OBFS_PASSWORD\""
				out="$out}"
			fi
			out="$out$SB_TLS"
			;;
		tuic)
			NODE_TLS=1
			pm_sb_tls
			out="{\"type\":\"tuic\",\"tag\":\"$NODE_NAME\",\"server\":\"$NODE_SERVER\",\"server_port\":$NODE_PORT,\"uuid\":\"$NODE_UUID\",\"password\":\"$NODE_PASSWORD\""
			[ -n "$NODE_TUIC_CC" ] && out="$out,\"congestion_control\":\"$NODE_TUIC_CC\""
			[ -n "$NODE_TUIC_UDP" ] && out="$out,\"udp_relay_mode\":\"$NODE_TUIC_UDP\""
			out="$out$SB_TLS"
			;;
		*)
			pm_warn "sing-box 不支持的节点类型：$NODE_TYPE"
			return 0
			;;
	esac

	out="$out}"
	printf '%s\n' "$out" >> "$PM_RUN_DIR/sb-outbounds.jsonl"
	printf '%s\n' "$NODE_NAME" >> "$PM_RUN_DIR/sb-tags.txt"
	return 0
}

pm_singbox_nodes() {
	: > "$PM_RUN_DIR/sb-outbounds.jsonl"
	: > "$PM_RUN_DIR/sb-tags.txt"
	pm_nodes_each pm_singbox_node
	return 0
}
