#!/bin/sh
# Ferry 配置生成：mihomo(YAML) / sing-box(JSON)
# 每次启动重新生成；用户自备配置请用 UCI 选项 config_path 指定。

pm_log_level_mihomo() {
	case "$PM_LOG_LEVEL" in
		silent|error|warning|info|debug) echo "$PM_LOG_LEVEL" ;;
		*) echo info ;;
	esac
}

pm_log_level_singbox() {
	case "$PM_LOG_LEVEL" in
		debug|info) echo "$PM_LOG_LEVEL" ;;
		error|silent) echo error ;;
		*) echo warn ;;
	esac
}

# 内置必须直连的保留网段（IPv4）
pm_builtin_bypass4() {
	echo '127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10,224.0.0.0/4,240.0.0.0/4'
}

pm_cidr() {
	case "$1" in
		*/*) echo "$1" ;;
		*:*) echo "$1/128" ;;
		*) echo "$1/32" ;;
	esac
}

pm_download() {
	local url="$1" dst="$2" tmp="$2.tmp"

	mkdir -p "$(dirname "$dst")"
	rm -f "$tmp"

	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -T 15 -O "$tmp" "$url" >/dev/null 2>&1
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL --max-time 120 -o "$tmp" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 15 -O "$tmp" "$url"
	else
		pm_log "缺少下载工具（uclient-fetch / curl / wget）" err
		rm -f "$tmp"
		return 1
	fi

	if [ ! -s "$tmp" ]; then
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$dst"
	return 0
}

pm_singbox_check() {
	local cfg="$1" bin
	bin=$(pm_kernel_bin)
	[ -x "$bin" ] || return 0
	"$bin" check -c "$cfg" -D "$PM_SINGBOX_DIR" >/dev/null 2>&1
}

pm_mihomo_check() {
	local cfg="$1" bin
	bin=$(pm_kernel_bin)
	[ -x "$bin" ] || return 0
	"$bin" -t -d "$PM_MIHOMO_DIR" -f "$cfg" >/dev/null 2>&1
}

# 把「一行一个 JSON」的文件拼成数组元素
pm_jsonl_join() {
	local file="$1" first=1 line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if [ "$first" = 1 ]; then
			printf '    %s' "$line"
			first=0
		else
			printf ',\n    %s' "$line"
		fi
	done < "$file"
	return 0
}

pm_bypass_rule_lines() {
	local cidr
	for cidr in $(pm_builtin_bypass4 | tr ',' ' ') $PM_BYPASS_CIDR $PM_BYPASS_IP; do
		[ -n "$cidr" ] || continue
		case "$cidr" in
			*:*) continue ;;
		esac
		cidr=$(pm_cidr "$cidr")
		printf '  - IP-CIDR,%s,DIRECT,no-resolve\n' "$cidr"
	done
	return 0
}

# ---------------- mihomo ----------------

pm_gen_mihomo() {
	local dir="$PM_MIHOMO_DIR"
	local cfg="$dir/config.yaml"
	local lvl stack mix_port eff_mode tun_block='' redir_line=''
	local dns_listen='0.0.0.0' sub_block='' group_use='' names='' name_line
	local provider_file="$PM_RUN_DIR/mihomo-providers.txt"
	local rules_file="$PM_RUN_DIR/mihomo-rules.txt"

	lvl=$(pm_log_level_mihomo)
	stack="$PM_TUN_STACK"
	mix_port="$PM_MIXED_PORT"
	eff_mode="$PM_MODE"
	pm_is_client && eff_mode=mixed
	if [ "$eff_mode" = mixed ] && [ "$mix_port" = 0 ]; then
		mix_port=7891
	fi
	if [ "$PM_ENABLE_IPV6" = 1 ]; then
		dns_listen='[::]'
	fi

	case "$eff_mode" in
		tproxy)
			redir_line="tproxy-port: $PM_PROXY_PORT"
			;;
		redirect)
			redir_line="redir-port: $PM_PROXY_PORT"
			;;
		tun)
			tun_block="tun:
  enable: true
  stack: $stack
  auto-route: $(pm_tun_autoroute)
  auto-detect-interface: true
  strict-route: false
  mtu: 1500
  dns-hijack:
    - any:53
    - tcp://any:53"
			;;
	esac

	if [ -n "$PM_SUB_URL" ]; then
		sub_block="proxy-providers:
  subscription:
    type: http
    url: \"$PM_SUB_URL\"
    interval: 3600
    path: ./providers/subscription.yaml
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300"
	fi

	pm_mihomo_nodes
	pm_mihomo_rules_render
	mkdir -p "$dir/providers"

	names=''
	while IFS= read -r name_line; do
		[ -n "$name_line" ] || continue
		names="$names      - \"$name_line\"
"
	done < "$PM_RUN_DIR/mihomo-names.txt"
	if [ -n "$PM_SUB_URL" ]; then
		group_use="    use:
      - subscription"
	fi
	if [ -z "$names" ] && [ -z "$PM_SUB_URL" ]; then
		names="      - DIRECT
"
		pm_warn "没有可用节点：mihomo 生成的 PROXY 组只有 DIRECT，流量不会经过代理"
	fi

	{
		echo "# 由 luci-app-ferry 自动生成，请勿手工修改（会在每次启动时覆盖）"
		echo "# 自定义配置请使用 UCI 选项 config_path 指定文件"
		echo "log-level: $lvl"
		echo "mode: rule"
		echo "allow-lan: true"
		echo "bind-address: '*'"
		echo "ipv6: $( [ "$PM_ENABLE_IPV6" = 1 ] && echo true || echo false )"
		echo "unified-delay: true"
		echo "tcp-concurrent: true"
		echo "find-process-mode: 'off'"
		echo "profile:"
		echo "  store-selected: true"
		echo "  store-fake-ip: true"
		if [ "$mix_port" != 0 ]; then
			echo "mixed-port: $mix_port"
		fi
		[ -n "$redir_line" ] && echo "$redir_line"
		echo "sniffer:"
		echo "  enable: true"
		echo "  parse-pure-ip: true"
		echo "  sniff:"
		echo "    TLS:"
		echo "      ports: [443, 8443]"
		echo "    HTTP:"
		echo "      ports: [80, 8080]"
		echo "dns:"
		echo "  enable: true"
		echo "  listen: \"$dns_listen:$PM_DNS_PORT\""
		echo "  ipv6: $( [ "$PM_ENABLE_IPV6" = 1 ] && echo true || echo false )"
		echo "  enhanced-mode: ${PM_DNS_MODE:-fake-ip}"
		echo "  fake-ip-range: 198.18.0.1/16"
		echo "  fake-ip-filter:"
		echo "    - '*.lan'"
		echo "    - '*.local'"
		echo "    - 'localhost'"
		echo "  nameserver:"
		echo "    - 223.5.5.5"
		echo "    - 119.29.29.29"
		[ -n "$tun_block" ] && echo "$tun_block"
		[ -n "$sub_block" ] && echo "$sub_block"
		if [ -s "$PM_RUN_DIR/mihomo-proxies.txt" ]; then
			echo "proxies:"
			cat "$PM_RUN_DIR/mihomo-proxies.txt"
		fi
		echo "proxy-groups:"
		echo "  - name: PROXY"
		echo "    type: select"
		# 仅有订阅时没有本地节点：不输出空的 proxies:（provider 组只靠 use:）
		[ -n "$names" ] && printf '    proxies:\n%s' "$names"
		[ -n "$group_use" ] && echo "$group_use"
		if [ -s "$provider_file" ]; then
			echo "rule-providers:"
			cat "$provider_file"
		fi
		echo "rules:"
		pm_bypass_rule_lines
		if [ -s "$rules_file" ]; then
			cat "$rules_file"
		fi
		if [ "$PM_FINAL" = direct ]; then
			echo "  - MATCH,DIRECT"
		else
			echo "  - MATCH,PROXY"
		fi
	} > "$cfg.tmp"
	mv "$cfg.tmp" "$cfg"

	if pm_mihomo_check "$cfg"; then
		pm_log "已生成 mihomo 配置：$cfg"
	else
		pm_warn "mihomo 配置自检未通过：${cfg}（请查看内核日志）"
	fi
	return 0
}

# ---------------- sing-box ----------------

pm_sb_inbounds_build() {
	local f="$PM_RUN_DIR/sb-inbounds.jsonl" eff_mode="$PM_MODE" listen='0.0.0.0' mix="$PM_MIXED_PORT"

	pm_is_client && eff_mode=mixed
	[ "$PM_ENABLE_IPV6" = 1 ] && listen='::'
	if [ "$eff_mode" = mixed ] && [ "$mix" = 0 ]; then
		mix=7891
	fi

	: > "$f"
	case "$eff_mode" in
		tproxy)
			printf '{"type":"tproxy","tag":"tproxy-in","listen":"%s","listen_port":%s}\n' "$listen" "$PM_PROXY_PORT" >> "$f"
			if pm_kernel_has_dns; then
				printf '{"type":"direct","tag":"dns-in","listen":"%s","listen_port":%s}\n' "$listen" "$PM_DNS_PORT" >> "$f"
			fi
			;;
		redirect)
			printf '{"type":"redirect","tag":"redirect-in","listen":"%s","listen_port":%s}\n' "$listen" "$PM_PROXY_PORT" >> "$f"
			if pm_kernel_has_dns; then
				printf '{"type":"direct","tag":"dns-in","listen":"%s","listen_port":%s}\n' "$listen" "$PM_DNS_PORT" >> "$f"
			fi
			;;
		tun)
			printf '{"type":"tun","tag":"tun-in","address":["172.19.0.1/30"],"mtu":1500,"auto_route":%s,"strict_route":false,"stack":"mixed","auto_redirect":false}\n' "$(pm_tun_autoroute)" >> "$f"
			;;
	esac
	if [ "$mix" != 0 ]; then
		printf '{"type":"mixed","tag":"mixed-in","listen":"%s","listen_port":%s}\n' "$listen" "$mix" >> "$f"
	fi
	[ -s "$f" ] || pm_warn "没有生成任何 inbound，sing-box 无法启动"
	return 0
}

pm_sb_selector() {
	local tags="$PM_RUN_DIR/sb-tags.txt" out='' t first='' default='direct'
	if [ -s "$tags" ]; then
		while IFS= read -r t; do
			[ -n "$t" ] || continue
			[ -n "$first" ] || { first=1; default="$t"; }
			[ -n "$out" ] && out="$out,"
			out="$out\"$t\""
		done < "$tags"
	fi
	[ -n "$out" ] && out="$out,\"direct\""
	[ -n "$out" ] || out='"direct"'
	printf '{"type":"selector","tag":"proxy","outbounds":[%s],"default":"%s"}\n' "$out" "$default"
	return 0
}

pm_gen_singbox() {
	local dir="$PM_SINGBOX_DIR"
	local cfg="$dir/config.json"
	local lvl
	lvl=$(pm_log_level_singbox)
	mkdir -p "$dir"

	pm_singbox_nodes
	pm_singbox_rules_render
	pm_sb_inbounds_build

	{
		echo '{"type":"direct","tag":"direct"}'
		cat "$PM_RUN_DIR/sb-outbounds.jsonl"
		pm_sb_selector
	} > "$PM_RUN_DIR/sb-outbounds-all.jsonl"

	{
		echo '{"protocol":"dns","action":"hijack-dns"}'
		echo '{"ip_is_private":true,"outbound":"direct"}'
		local cidr
		for cidr in $PM_BYPASS_CIDR $PM_BYPASS_IP; do
			[ -n "$cidr" ] || continue
			cidr=$(pm_cidr "$cidr")
			printf '{"ip_cidr":["%s"],"outbound":"direct"}\n' "$cidr"
		done
		cat "$PM_RUN_DIR/sb-rules.jsonl"
	} > "$PM_RUN_DIR/sb-rules-all.jsonl"

	if [ -z "$PM_SUB_URL" ] && [ ! -s "$PM_RUN_DIR/sb-tags.txt" ]; then
		pm_warn "没有可用节点：sing-box 生成的出站只有 direct，流量不会经过代理"
	fi

	{
		echo "{"
		echo "  \"log\": { \"level\": \"$lvl\", \"timestamp\": true },"
		echo "  \"dns\": {"
		echo "    \"servers\": ["
		echo "      { \"tag\": \"dns-direct\", \"type\": \"udp\", \"server\": \"223.5.5.5\" },"
		echo "      { \"tag\": \"dns-cn\", \"type\": \"udp\", \"server\": \"119.29.29.29\" }"
		echo "    ],"
		echo "    \"final\": \"dns-direct\","
		echo "    \"strategy\": \"prefer_ipv4\""
		echo "  },"
		echo "  \"inbounds\": ["
		pm_jsonl_join "$PM_RUN_DIR/sb-inbounds.jsonl"
		echo ""
		echo "  ],"
		echo "  \"outbounds\": ["
		pm_jsonl_join "$PM_RUN_DIR/sb-outbounds-all.jsonl"
		echo ""
		echo "  ],"
		echo "  \"route\": {"
		echo "    \"auto_detect_interface\": true,"
		echo "    \"default_domain_resolver\": \"dns-direct\","
		if [ -s "$PM_RUN_DIR/sb-rulesets.jsonl" ]; then
			echo "    \"rule_set\": ["
			pm_jsonl_join "$PM_RUN_DIR/sb-rulesets.jsonl"
			echo ""
			echo "    ],"
		fi
		echo "    \"final\": \"$([ "$PM_FINAL" = direct ] && echo direct || echo proxy)\","
		echo "    \"rules\": ["
		pm_jsonl_join "$PM_RUN_DIR/sb-rules-all.jsonl"
		echo ""
		echo "    ]"
		echo "  }"
		echo "}"
	} > "$cfg.tmp"
	mv "$cfg.tmp" "$cfg"

	if pm_singbox_check "$cfg"; then
		pm_log "已生成 sing-box 配置：$cfg"
	else
		pm_warn "sing-box 配置自检未通过：${cfg}（请查看内核日志）"
	fi
	return 0
}

# ---------------- 入口 ----------------

pm_prepare() {
	local bin
	mkdir -p "$PM_RUN_DIR" "$PM_MIHOMO_DIR/providers" "$PM_SINGBOX_DIR" \
		"$PM_CONF_DIR" "$PM_RULE_CACHE/mihomo" "$PM_RULE_CACHE/sing-box"
	rm -f "$PM_RUN_DIR/warnings.txt" "$PM_RUN_DIR/rules-status.txt"
	PM_RUNTIME_CONFIG=''
	PM_RULE_SYNC_MODE=''

	bin=$(pm_kernel_bin)
	if [ ! -x "$bin" ]; then
		pm_warn "内核二进制不存在或不可执行：${bin}（请安装 mihomo/sing-box 或设置 bin_path）"
		pm_status_write
		return 1
	fi

	# 自备配置时不生成配置、也不同步规则：先判断再决定要不要联网，
	# 否则每个规则源最长 15 秒超时会白白叠加在启动耗时上
	if [ -n "$PM_CONFIG_PATH" ] && [ -f "$PM_CONFIG_PATH" ]; then
		PM_RUNTIME_CONFIG="$PM_CONFIG_PATH"
		PM_RULE_SYNC_MODE=self
		if [ "$PM_KERNEL" = singbox ]; then
			pm_singbox_check "$PM_CONFIG_PATH" || pm_warn "自备 sing-box 配置自检未通过：$PM_CONFIG_PATH"
		else
			pm_mihomo_check "$PM_CONFIG_PATH" || pm_warn "自备 mihomo 配置自检未通过：$PM_CONFIG_PATH"
		fi
		pm_log "使用用户自备配置：$PM_CONFIG_PATH（跳过规则同步）"
		pm_status_write
		return 0
	fi

	pm_rules_sync

	if [ "$PM_KERNEL" = singbox ]; then
		if [ -n "$PM_SUB_URL" ]; then
			local dst="$PM_SINGBOX_DIR/config.json"
			local new="$PM_SINGBOX_DIR/config.json.new"
			# 先下载到 .new 并校验，通过后才替换缓存，避免坏订阅覆盖上次可用配置
			if pm_download "$PM_SUB_URL" "$new" && pm_singbox_check "$new"; then
				mv "$new" "$dst"
				PM_RUNTIME_CONFIG="$dst"
				pm_log "已下载并校验 sing-box 订阅配置：$dst"
				pm_status_write
				return 0
			fi
			rm -f "$new" "$new.tmp"
			pm_warn "sing-box 订阅下载/校验失败，尝试使用上次缓存的配置"
			if [ -s "$dst" ] && pm_singbox_check "$dst"; then
				PM_RUNTIME_CONFIG="$dst"
				pm_status_write
				return 0
			fi
			pm_warn "没有可用的 sing-box 配置，改为生成最小骨架"
		fi
		pm_gen_singbox
		PM_RUNTIME_CONFIG="$PM_SINGBOX_DIR/config.json"
		pm_status_write
		return 0
	fi

	pm_gen_mihomo
	PM_RUNTIME_CONFIG="$PM_MIHOMO_DIR/config.yaml"
	pm_status_write
	return 0
}
