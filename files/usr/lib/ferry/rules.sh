#!/bin/sh
# 规则集分类、镜像源、本地缓存与双内核渲染

# 分类 -> MetaCubeX geosite 名称（多个用空格分隔）
pm_category_geo() {
	case "$1" in
		cn)        echo 'geolocation-cn' ;;
		ads)       echo 'category-ads-all' ;;
		streaming) echo 'netflix disney youtube' ;;
		ai)        echo 'openai anthropic google-gemini' ;;
		telegram)  echo 'telegram' ;;
		dev)       echo 'github gitlab stackexchange' ;;
		academic)  echo 'coursera edx khanacademy' ;;
		game)      echo 'category-games' ;;
		*)         echo '' ;;
	esac
}

pm_rules_init() {
	[ -f "$PM_RULES_LST" ] && return 0
	mkdir -p "$PM_CONF_DIR"
	{
		echo 'cn direct'
		echo 'ads reject'
		echo 'streaming proxy'
		echo 'ai proxy'
		echo 'telegram proxy'
		echo 'dev proxy'
		echo 'academic proxy'
		echo 'game proxy'
		echo 'custom proxy'
	} > "$PM_RULES_LST"
	return 0
}

pm_rule_target_ok() {
	case "$1" in
		proxy|direct|reject) return 0 ;;
	esac
	return 1
}

# 当前生效分类涉及的 geosite 名称（去重）
pm_active_geos() {
	local seen=' ' cat target geo
	pm_rules_init
	[ -f "$PM_RULES_LST" ] || return 0
	while read -r cat target rest; do
		[ -n "$cat" ] || continue
		pm_rule_target_ok "$target" || continue
		[ "$cat" = custom ] && continue
		for geo in $(pm_category_geo "$cat"); do
			case "$seen" in
				*" $geo "*) continue ;;
			esac
			seen="$seen$geo "
			echo "$geo"
		done
	done < "$PM_RULES_LST"
	return 0
}

pm_rule_cache_file() {
	if [ "$PM_KERNEL" = singbox ]; then
		echo "$PM_RULE_CACHE/sing-box/$1.srs"
	else
		echo "$PM_RULE_CACHE/mihomo/$1.yaml"
	fi
}

pm_rule_url() {
	local kind="$1" geo="$2" repo="MetaCubeX/meta-rules-dat" path base
	if [ "$PM_KERNEL" = singbox ]; then
		path="sing/geo/geosite/$geo.srs"
		base="https://cdn.jsdelivr.net/gh/$repo@sing/geo/geosite/$geo.srs"
	else
		path="meta/geo/geosite/$geo.yaml"
		base="https://cdn.jsdelivr.net/gh/$repo@meta/geo/geosite/$geo.yaml"
	fi

	case "$kind" in
		github)  echo "https://raw.githubusercontent.com/$repo/$path" ;;
		ghproxy) echo "https://ghproxy.net/https://raw.githubusercontent.com/$repo/$path" ;;
		jsdelivr) echo "$base" ;;
		custom)
			[ -n "$PM_RULE_MIRROR_CUSTOM" ] || return 0
			echo "${PM_RULE_MIRROR_CUSTOM%/}/$repo/$path"
			;;
	esac
	return 0
}

pm_rule_urls() {
	local geo="$1" url
	url=$(pm_rule_url "$PM_RULE_MIRROR" "$geo")
	[ -n "$url" ] && echo "$url"

	case "$PM_RULE_MIRROR_BACKUP" in
		'') ;;
		github|ghproxy|jsdelivr)
			url=$(pm_rule_url "$PM_RULE_MIRROR_BACKUP" "$geo")
			[ -n "$url" ] && echo "$url"
			;;
		*)
			# 备用源写成完整前缀：<base>/MetaCubeX/meta-rules-dat/<path>
			local path
			if [ "$PM_KERNEL" = singbox ]; then
				path="sing/geo/geosite/$geo.srs"
			else
				path="meta/geo/geosite/$geo.yaml"
			fi
			echo "${PM_RULE_MIRROR_BACKUP%/}/MetaCubeX/meta-rules-dat/$path"
			;;
	esac
	return 0
}

pm_rule_fresh() {
	local geo="$1" stamp="$PM_RULE_CACHE/.stamp-$geo" now age
	[ -f "$stamp" ] || return 1
	now=$(date +%s 2>/dev/null) || return 0
	age=$(cat "$stamp" 2>/dev/null)
	case "$age" in ''|*[!0-9]*) return 1 ;; esac
	[ $((now - age)) -lt 86400 ]
}

pm_rules_sync() {
	mkdir -p "$PM_RULE_CACHE/mihomo" "$PM_RULE_CACHE/sing-box"

	local status="$PM_RUN_DIR/rules-status.txt"
	local geo dst url ok stale='' skipped='' failed='' oklist=''
	: > "$status"

	for geo in $(pm_active_geos); do
		dst=$(pm_rule_cache_file "$geo")
		[ -n "$dst" ] || continue

		# 关闭更新时只做缓存存在性检查
		if [ "$PM_RULE_UPDATE" != 1 ]; then
			if [ -s "$dst" ]; then
				oklist="$oklist $geo"
			else
				skipped="$skipped $geo"
			fi
			continue
		fi

		if [ -s "$dst" ] && pm_rule_fresh "$geo"; then
			oklist="$oklist $geo"
			continue
		fi

		ok=0
		for url in $(pm_rule_urls "$geo"); do
			if pm_download "$url" "$dst"; then
				date +%s > "$PM_RULE_CACHE/.stamp-$geo" 2>/dev/null
				ok=1
				break
			fi
		done
		rm -f "$dst.tmp" 2>/dev/null

		if [ "$ok" = 1 ]; then
			oklist="$oklist $geo"
		elif [ -s "$dst" ]; then
			# 下载失败但有旧缓存：继续用缓存，标记过期（不中断后面的分类）
			stale="$stale $geo"
		else
			failed="$failed $geo"
		fi
	done

	# 逐分类状态：ok / stale / skipped / failed（供 status.json 与 Web 展示）
	{
		for geo in $oklist; do echo "$geo ok"; done
		for geo in $stale; do echo "$geo stale"; done
		for geo in $skipped; do echo "$geo skipped"; done
		for geo in $failed; do echo "$geo failed"; done
	} > "$status"

	[ -n "$stale" ] && pm_warn "规则集更新失败，继续使用本地缓存：$stale"
	[ -n "$failed" ] && pm_warn "以下分类下载失败且无本地缓存，已跳过：$failed"
	[ -n "$skipped" ] && pm_warn "规则自动更新已关闭且无本地缓存，已跳过：$skipped"
	return 0
}

# ---------------- 渲染：mihomo ----------------

pm_mihomo_target() {
	case "$1" in
		proxy)  echo PROXY ;;
		direct) echo DIRECT ;;
		reject) echo REJECT ;;
	esac
}

pm_mihomo_custom_rules() {
	local target="$1" t kind value
	t=$(pm_mihomo_target "$target")
	[ -f "$PM_CUSTOM_LST" ] || return 0
	while read -r kind value rest; do
		[ -n "$value" ] || continue
		case "$kind" in
			domain) echo "  - DOMAIN,$value,$t" ;;
			suffix) echo "  - DOMAIN-SUFFIX,$value,$t" ;;
			ip)     echo "  - IP-CIDR,$value,$t,no-resolve" ;;
			ip6)    echo "  - IP-CIDR6,$value,$t,no-resolve" ;;
		esac
	done < "$PM_CUSTOM_LST"
	return 0
}

# 输出 $PM_RUN_DIR/mihomo-providers.txt 与 mihomo-rules.txt
pm_mihomo_rules_render() {
	local providers="$PM_RUN_DIR/mihomo-providers.txt"
	local rules="$PM_RUN_DIR/mihomo-rules.txt"
	local seen=' ' cat target rest geo f tag

	: > "$providers"
	: > "$rules"
	pm_rules_init

	while read -r cat target rest; do
		[ -n "$cat" ] || continue
		pm_rule_target_ok "$target" || continue
		if [ "$cat" = custom ]; then
			pm_mihomo_custom_rules "$target" >> "$rules"
			continue
		fi
		for geo in $(pm_category_geo "$cat"); do
			case "$seen" in
				*" $geo "*) continue ;;
			esac
			seen="$seen$geo "
			f="$PM_RULE_CACHE/mihomo/$geo.yaml"
			if [ ! -s "$f" ]; then
				continue
			fi
			tag="rs-$geo"
			{
				printf '  %s:\n' "$tag"
				printf '    type: file\n'
				printf '    behavior: domain\n'
				printf '    format: yaml\n'
				printf '    path: %s\n' "$f"
			} >> "$providers"
			printf '  - RULE-SET,%s,%s\n' "$tag" "$(pm_mihomo_target "$target")" >> "$rules"
		done
	done < "$PM_RULES_LST"
	return 0
}

# ---------------- 渲染：sing-box ----------------

pm_sb_outbound_for() {
	case "$1" in
		proxy)  echo proxy ;;
		direct) echo direct ;;
		reject) echo reject ;;
	esac
}

pm_singbox_custom_rules() {
	local target="$1" t kind value rest
	[ -f "$PM_CUSTOM_LST" ] || return 0
	while read -r kind value rest; do
		[ -n "$value" ] || continue
		if [ "$target" = reject ]; then
			case "$kind" in
				domain) printf '{"domain":["%s"],"action":"reject"}\n' "$value" ;;
				suffix) printf '{"domain_suffix":["%s"],"action":"reject"}\n' "$value" ;;
				ip|ip6) printf '{"ip_cidr":["%s"],"action":"reject"}\n' "$value" ;;
			esac
		else
			t=$(pm_sb_outbound_for "$target")
			case "$kind" in
				domain) printf '{"domain":["%s"],"outbound":"%s"}\n' "$value" "$t" ;;
				suffix) printf '{"domain_suffix":["%s"],"outbound":"%s"}\n' "$value" "$t" ;;
				ip|ip6) printf '{"ip_cidr":["%s"],"outbound":"%s"}\n' "$value" "$t" ;;
			esac
		fi
	done < "$PM_CUSTOM_LST"
	return 0
}

# 输出 $PM_RUN_DIR/sb-rulesets.jsonl 与 sb-rules.jsonl
pm_singbox_rules_render() {
	local rulesets="$PM_RUN_DIR/sb-rulesets.jsonl"
	local rules="$PM_RUN_DIR/sb-rules.jsonl"
	local seen=' ' cat target rest geo f tag

	: > "$rulesets"
	: > "$rules"
	pm_rules_init

	while read -r cat target rest; do
		[ -n "$cat" ] || continue
		pm_rule_target_ok "$target" || continue
		if [ "$cat" = custom ]; then
			pm_singbox_custom_rules "$target" >> "$rules"
			continue
		fi
		for geo in $(pm_category_geo "$cat"); do
			case "$seen" in
				*" $geo "*) continue ;;
			esac
			seen="$seen$geo "
			f="$PM_RULE_CACHE/sing-box/$geo.srs"
			[ -s "$f" ] || continue
			tag="rs-$geo"
			printf '{"type":"local","tag":"%s","format":"binary","path":"%s"}\n' "$tag" "$f" >> "$rulesets"
			if [ "$target" = reject ]; then
				printf '{"rule_set":"%s","action":"reject"}\n' "$tag" >> "$rules"
			else
				printf '{"rule_set":"%s","outbound":"%s"}\n' "$tag" "$(pm_sb_outbound_for "$target")" >> "$rules"
			fi
		done
	done < "$PM_RULES_LST"
	return 0
}
