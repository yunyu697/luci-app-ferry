#!/bin/sh
# 独立面板包 luci-app-ferry-dashboard 的后端逻辑。
#
# 设计边界：
#   - 面板状态只存 /etc/config/ferry-dashboard（本包 conffile），卸载本包即整份删除；
#   - secret 只存 /etc/ferry/panel.secret（0600），不进 UCI、不进 www 静态文件；
#   - 监听地址只允许 LAN 接口上的 IPv4 地址，拒绝 0.0.0.0；
#   - 防火墙只放行 LAN 接口 + LAN 网段，其余（含 WAN）对该端口明确 drop；
#   - 同一时刻只允许一个内核进程占用该端口；检测到两个内核同时运行则拒绝启用。

. /usr/lib/ferry/common.sh

PANEL_VERSION=1.0.0-r14
PANEL_STATE_DIR=/var/run/ferry-panel
PANEL_APPLY_MARK=$PANEL_STATE_DIR/apply.since
PANEL_APPLY_LOG=/tmp/ferry-panel-apply.log
PANEL_WWW=/luci-static/ferry-dashboard/index.html

panel_secret_new() {
	mkdir -p /etc/ferry 2>/dev/null
	umask 077
	if command -v md5sum >/dev/null 2>&1; then
		head -c 32 /dev/urandom | md5sum | cut -d' ' -f1 > "$PM_PANEL_SECRET_FILE"
	else
		tr -dc 'a-f0-9' </dev/urandom | head -c 32 > "$PM_PANEL_SECRET_FILE"
	fi
	[ -s "$PM_PANEL_SECRET_FILE" ] || return 1
	chmod 600 "$PM_PANEL_SECRET_FILE" 2>/dev/null
	pm_panel_secret >/dev/null
}

panel_secret_clear() {
	rm -f "$PM_PANEL_SECRET_FILE"
}

# 当前正在运行的内核进程：0/1
panel_pidof() {
	local name="$1"
	if command -v pidof >/dev/null 2>&1; then
		pidof "$name" >/dev/null 2>&1
	else
		ps -w 2>/dev/null | grep -v grep | grep -q "$name"
	fi
}

panel_conflict_both() {
	panel_pidof mihomo && panel_pidof sing-box
}

panel_running_current() {
	case "${PM_KERNEL:-mihomo}" in
		singbox) panel_pidof sing-box ;;
		*) panel_pidof mihomo ;;
	esac
}

# LAN-only nft/iptables 规则。nft 用独立表，摔不进 fw4 的规则重建流程。
panel_fw_up() {
	local cidrs='' c lan="${PM_LAN_IFACE:-br-lan}" port="${PM_PANEL_PORT:-9090}"

	[ "${PM_PANEL_WANT:-0}" = 1 ] || return 0
	for c in ${PM_MGMT_CIDRS:-}; do
		case "$c" in
			*:*) ;;
			*) cidrs="$cidrs $c" ;;
		esac
	done
	if [ -z "$cidrs" ] && [ -n "${PM_PANEL_BIND:-}" ]; then
		cidrs=" ${PM_PANEL_BIND}/32"
	fi
	[ -n "$cidrs" ] || return 1

	if command -v nft >/dev/null 2>&1; then
		panel_fw_down
		{
			echo "table ip ferry_panel {"
			echo "  chain input {"
			echo "    type filter hook input priority -20; policy accept;"
			for c in $cidrs; do
				echo "    iifname \"$lan\" ip saddr $c tcp dport $port accept"
			done
			echo "    iifname \"lo\" tcp dport $port accept"
			echo "    tcp dport $port drop"
			echo "  }"
			echo "}"
		} | nft -f - >/dev/null 2>&1
		[ $? -eq 0 ] && return 0
	fi

	if command -v iptables >/dev/null 2>&1; then
		panel_fw_down
		iptables -N FERRY_PANEL 2>/dev/null
		iptables -C INPUT -j FERRY_PANEL 2>/dev/null || iptables -I INPUT 1 -j FERRY_PANEL
		for c in $cidrs; do
			iptables -A FERRY_PANEL -p tcp --dport "$port" -i "$lan" -s "$c" -j ACCEPT
		done
		iptables -A FERRY_PANEL -p tcp --dport "$port" -i lo -j ACCEPT
		iptables -A FERRY_PANEL -p tcp --dport "$port" -j DROP
		return 0
	fi

	return 1
}

panel_fw_down() {
	nft list table ip ferry_panel >/dev/null 2>&1 && nft delete table ip ferry_panel >/dev/null 2>&1
	if command -v iptables >/dev/null 2>&1; then
		iptables -D INPUT -j FERRY_PANEL 2>/dev/null
		iptables -F FERRY_PANEL 2>/dev/null
		iptables -X FERRY_PANEL 2>/dev/null
	fi
	return 0
}

panel_apply_bg() {
	[ "$(uci -q get ferry.main.enabled 2>/dev/null)" = 1 ] || return 0
	[ -x /etc/init.d/ferry ] || return 0
	[ -e "$PANEL_APPLY_MARK" ] && return 0
	mkdir -p "$PANEL_STATE_DIR"
	date +%s > "$PANEL_APPLY_MARK"
	(
		setsid sh -c "PM_TXN_SKIP=1 /etc/init.d/ferry reload >$PANEL_APPLY_LOG 2>&1; rm -f $PANEL_APPLY_MARK" \
			</dev/null >/dev/null 2>&1 &
	)
	return 0
}

panel_applying() {
	local since now
	[ -e "$PANEL_APPLY_MARK" ] || return 1
	since=$(cat "$PANEL_APPLY_MARK" 2>/dev/null)
	now=$(date +%s)
	[ -n "$since" ] || return 1
	[ $((now - since)) -lt 180 ]
}

panel_enable() {
	# pm_load 只负责载入 PM_LAN_IFACE；panel 未启用时它不会算 bind（那是启用后的运行态），
	# 所以启用流程必须自己求一次 bind，不能依赖 PM_PANEL_BIND。
	pm_load
	local bind port
	bind=$(pm_panel_bind) || bind=''
	port=$(pm_panel_port)

	if [ -z "$bind" ]; then
		echo '{"ok":false,"error":"找不到 LAN 接口的 IPv4 地址；请先在「网络」里给 LAN 配地址，或用 uci 设置 ferry-dashboard.main.bind"}'
		return 1
	fi
	case "$bind" in
		0.0.0.0|'*')
			echo '{"ok":false,"error":"绑定地址不能是 0.0.0.0"}'
			return 1
			;;
	esac
	if panel_conflict_both; then
		echo '{"ok":false,"error":"mihomo 与 sing-box 同时在运行，端口会被两个内核争抢（EADDRINUSE）。请先停掉不用的那个内核，再启用面板"}'
		return 1
	fi

	[ -s "$PM_PANEL_SECRET_FILE" ] || panel_secret_new || {
		echo '{"ok":false,"error":"secret 生成失败（/dev/urandom 或 md5sum 不可用）"}'
		return 1
	}

	# 面板的 UCI 配置单独成文件；conffile 在卸载时由 prerm 显式删除
	[ -f /etc/config/ferry-dashboard ] || touch /etc/config/ferry-dashboard
	uci -q get ferry-dashboard.main >/dev/null 2>&1 || uci -q set ferry-dashboard.main=dashboard
	uci -q set ferry-dashboard.main.enabled=1
	uci -q set ferry-dashboard.main.port="$port"
	uci -q commit ferry-dashboard || {
		echo '{"ok":false,"error":"写入 /etc/config/ferry-dashboard 失败"}'
		return 1
	}

	pm_load
	panel_fw_up || {
		echo '{"ok":false,"error":"防火墙规则安装失败（nft/iptables 均不可用或参数无效）"}'
		return 1
	}
	panel_apply_bg
	echo '{"ok":true}'
	return 0
}

panel_disable() {
	pm_load
	if [ -f /etc/config/ferry-dashboard ]; then
		uci -q set ferry-dashboard.main.enabled=0
		uci -q commit ferry-dashboard
	fi
	panel_fw_down
	panel_secret_clear
	pm_load
	panel_apply_bg
	return 0
}

# 卸载时把面板注入从「两个内核」的生成配置里都抹掉。
# reload 只重生成当前内核的配置，另一个内核的旧文件会残留 external-controller /
# clash_api；若之后切到那个内核并沿用旧配置，就相当于没装面板包却仍暴露端点。
# 只按本次 secret 精确匹配并删除注入块，避免误伤用户自备配置或订阅配置。
panel_strip_injected() {
	local sec="$1" mi="$PM_MIHOMO_DIR/config.yaml" sb="$PM_SINGBOX_DIR/config.json"
	[ -n "$sec" ] || return 0
	# 自备配置不归 ferry 修改
	if [ -n "${PM_CONFIG_PATH:-}" ]; then
		case "$PM_CONFIG_PATH" in
			"$mi"|"$sb") return 0 ;;
		esac
	fi
	if [ -s "$mi" ] && grep -q "secret: \"$sec\"" "$mi" 2>/dev/null; then
		sed -e "/^external-controller: /d" -e "/^secret: \"$sec\"\$/d" "$mi" > "$mi.tmp" && mv "$mi.tmp" "$mi"
	fi
	if [ -s "$sb" ] && grep -q "\\\"$sec\\\"" "$sb" 2>/dev/null; then
		awk -v sec="$sec" '
			function flush() {
				if (inexp && inclash && buf ~ sec) { inexp = 0; inclash = 0; buf = ""; return }
				printf "%s", buf
				inexp = 0; inclash = 0; buf = ""
			}
			BEGIN { inexp = 0; inclash = 0; buf = "" }
			{
				if (!inexp && $0 ~ /^  "experimental": \{$/) { inexp = 1; inclash = 0; buf = $0 ORS; next }
				if (inexp) {
					buf = buf $0 ORS
					if ($0 ~ /"clash_api": \{/) inclash = 1
					if ($0 ~ /^  \},$/) { flush(); next }
					next
				}
				print
			}
			END { if (inexp) { if (!(inclash && buf ~ sec)) printf "%s", buf } }
		' "$sb" > "$sb.tmp" && mv "$sb.tmp" "$sb"
	fi
	return 0
}

# 端口是否仍有监听（netstat 第 4 列形如 192.168.1.1:9090）
panel_port_busy() {
	netstat -ltn 2>/dev/null | awk -v pat=":$1\$" '$4 ~ pat { f=1 } END { exit(f ? 0 : 1) }'
}

# 卸载面板包时的清理：禁用 + 删 UCI + 删 secret + 撤防火墙 + 触发一次内核重启，
# 让 external-controller / experimental.clash_api 从生成的配置里消失、端口释放。
panel_cleanup() {
	local sec='' port='' i=0
	sec=$(pm_panel_secret) || sec=''
	port=$(pm_panel_port)
	panel_disable
	panel_fw_down
	panel_strip_injected "$sec"
	rm -f /etc/config/ferry-dashboard
	rm -rf "$PANEL_STATE_DIR"
	# opkg/apk 只删文件不删空目录，这里把本包独占目录一并移除
	rm -rf /www/luci-static/ferry-dashboard /usr/share/licenses/luci-app-ferry-dashboard
	rm -f "$PANEL_APPLY_LOG"
	rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
	# 等内核真正重启完成（最多 20 秒）：apply 标记消失只代表 reload 脚本返回，
	# procd 真正 spawn 新实例还在其后，所以还要等端口释放，否则卸载返回时 9090 仍可能在监听
	while [ -e "$PANEL_APPLY_MARK" ] && [ "$i" -lt 20 ]; do
		sleep 1
		i=$((i + 1))
	done
	i=0
	while [ "$i" -lt 20 ] && panel_port_busy "$port"; do
		sleep 1
		i=$((i + 1))
	done
	return 0
}

panel_caps_json() {
	case "${PM_KERNEL:-mihomo}" in
		singbox)
			echo '{"kernel":"singbox","rules":"unavailable","config":"unavailable","delay_detail":"unavailable","restart":"unavailable","upgrade":"unavailable","proxy_switch":"available","note":"sing-box 的 Clash API 不提供 /rules、/configs 详情、逐节点延迟明细与 /restart、/upgrade；这些入口已在面板里隐藏或置灰"}'
			;;
		*)
			echo '{"kernel":"mihomo","rules":"available","config":"readonly","delay_detail":"available","restart":"unavailable","upgrade":"unavailable","proxy_switch":"available","note":"mihomo 支持规则与配置读取；写配置、重载、重启、升级由 ferry 负责，面板内已禁用"}'
			;;
	esac
}

panel_status_json() {
	local sec='' injected=0 reason='' mode='generated' cfg='' pid=0 out=''
	local en kt bind port

	pm_load
	en=${PM_PANEL_WANT:-0}
	kt=${PM_KERNEL:-mihomo}
	bind=${PM_PANEL_BIND:-}
	port=${PM_PANEL_PORT:-9090}

	sec=$(pm_panel_secret) || sec=''
	cfg=$(uci -q get ferry.main.config_path 2>/dev/null)
	if [ -n "$cfg" ] && [ -f "$cfg" ]; then
		mode=self
	elif [ "$kt" = singbox ]; then
		cfg=$PM_SINGBOX_DIR/config.json
		[ -n "$(uci -q get ferry.main.sub_url 2>/dev/null)" ] && mode=subscription
	else
		cfg=$PM_MIHOMO_DIR/config.yaml
	fi

	if [ -s "$cfg" ]; then
		case "$kt" in
			sinbox|singbox) grep -q '"clash_api"' "$cfg" 2>/dev/null && injected=1 ;;
			*) grep -q 'external-controller' "$cfg" 2>/dev/null && injected=1 ;;
		esac
	fi

	if [ "$en" != 1 ]; then
		reason=disabled
	elif [ -z "$sec" ]; then
		reason=no_secret
	elif [ -z "$bind" ]; then
		reason=no_bind
	elif [ "$mode" = self ]; then
		reason=self_config
	elif [ "$mode" = subscription ] && [ "$injected" != 1 ]; then
		reason=sub_config
	elif [ "$injected" = 1 ]; then
		reason=ready
	else
		reason=not_injected
	fi

	panel_running_current && pid=1
	out=$(printf '"enabled":%s,"injected":%s,"port":%s,"bind":"%s","secret":"%s","kernel":"%s","type":"%s","mode":"%s","reason":"%s","running":%s,"service_enabled":%s,"applying":%s,"conflict":{"mihomo":%s,"singbox":%s,"both":%s},"caps":%s,"panel_base":"%s","version":"%s"' \
		"$en" "$injected" "$port" "$(pm_json_esc "$bind")" "$(pm_json_esc "$sec")" \
		"$kt" "$( [ "$kt" = singbox ] && echo singbox || echo clash )" \
		"$mode" "$reason" "$pid" \
		"$( [ "$(uci -q get ferry.main.enabled 2>/dev/null)" = 1 ] && echo true || echo false )" \
		"$( panel_applying && echo true || echo false )" \
		"$( panel_pidof mihomo && echo true || echo false )" \
		"$( panel_pidof sing-box && echo true || echo false )" \
		"$( panel_conflict_both && echo true || echo false )" \
		"$(panel_caps_json)" "$PANEL_WWW" "$PANEL_VERSION")

	printf '{"ok":true,%s}\n' "$out"
}

panel_rotate() {
	panel_secret_new || {
		echo '{"ok":false,"error":"secret 生成失败"}'
		return 1
	}
	pm_load
	panel_apply_bg
	echo '{"ok":true}'
}

case "$1" in
	enable) panel_enable ;;
	disable) panel_disable ;;
	rotate) panel_rotate ;;
	apply) panel_apply_bg; echo '{"ok":true}' ;;
	status) panel_status_json ;;
	cleanup) panel_cleanup ;;
	fw-up) pm_load; panel_fw_up && echo '{"ok":true}' ;;
	fw-down) panel_fw_down; echo '{"ok":true}' ;;
	boot)
	pm_load
	if [ "${PM_PANEL_WANT:-0}" = 1 ]; then
		# 开机：secret 必须在内核启动前就位，否则生成阶段不会注入
		[ -s "$PM_PANEL_SECRET_FILE" ] || panel_secret_new
		panel_fw_up
	else
		# 自愈：UCI 里已禁用、但运行时配置仍留着旧的 external-controller / clash_api
		# （例如用户直接删了 /etc/config/ferry-dashboard）。重新生成一次，把注入行和旧 secret 清掉。
		case "${PM_KERNEL:-mihomo}" in
			singbox) f=$PM_SINGBOX_DIR/config.json; pat='"clash_api"' ;;
			*) f=$PM_MIHOMO_DIR/config.yaml; pat='external-controller' ;;
		esac
		[ -s "$f" ] && grep -q "$pat" "$f" 2>/dev/null && panel_apply_bg
	fi
	;;
	*) echo '{"ok":false,"error":"usage: ferry-panel enable|disable|rotate|apply|status|cleanup|boot"}' ;;
esac
