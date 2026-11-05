#!/bin/sh
# ferry 内核管理：版本库、下载校验、原子替换、切换与回滚
#
# 数据落位：
#   $PMK_STORE/<kernel>/<tag>/{<bin>,meta}   已安装版本（持久化，重启保留）
#   $PMK_STORE/<kernel>/active -> <tag>      当前启用版本
#   $PMK_STORE/<kernel>/previous -> <tag>    回滚目标（上一版本）
#   /usr/bin/<bin> -> $PMK_STORE/.../<bin>   实际运行路径（符号链接，原子替换）
#   $PMK_STORE/mirrors.json                  可编辑镜像源列表
#
# 所有会改变运行态的操作都走 job：写 $PMK_JOB，由 rpcd 侧轮询进度。

PMK_STORE=${PMK_STORE:-/etc/ferry/kernels}
PMK_RUN=${PMK_RUN:-/var/etc/ferry}
PMK_BIN_DIR=${PMK_BIN_DIR:-/usr/bin}
PMK_LIB_DIR=${PMK_LIB_DIR:-/usr/lib/ferry}
PMK_UCI=${PMK_UCI:-uci}
PMK_SERVICE=${PMK_SERVICE:-/etc/init.d/ferry}
PMK_MIRRORS=${PMK_MIRRORS:-$PMK_STORE/mirrors.json}
PMK_JOB=${PMK_JOB:-$PMK_RUN/kernel-job.json}
PMK_LOCK=${PMK_LOCK:-$PMK_RUN/kernel.lock}
PMK_STAGE=${PMK_STAGE:-$PMK_STORE/.stage}
PMK_JAIL=${PMK_JAIL:-/tmp/kernel-jail}
PMK_CFG_MIHOMO=${PMK_CFG_MIHOMO:-/etc/mihomo/config.yaml}
PMK_CFG_SINGBOX=${PMK_CFG_SINGBOX:-/etc/sing-box/config.json}

# 后台任务子进程（sh $PMK_LIB_DIR/kernel.sh run）需要继承这些路径；
# 默认值不变，仅在离线测试时用环境变量覆盖
export PMK_STORE PMK_RUN PMK_BIN_DIR PMK_LIB_DIR PMK_UCI PMK_SERVICE PMK_MIRRORS \
	PMK_JOB PMK_LOCK PMK_STAGE PMK_JAIL PMK_CFG_MIHOMO PMK_CFG_SINGBOX
export PM_BIN_DIR="$PMK_BIN_DIR" PM_RUN_DIR="$PMK_RUN"

pmk_log() { logger -t ferry-kernel -- "$*" 2>/dev/null; echo "$*" >&2; }

pmk_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '; }

pmk_norm_kernel() {
	case "$1" in
		mihomo) echo mihomo ;;
		singbox|sing-box) echo singbox ;;
		*) return 1 ;;
	esac
}

pmk_bin_name() {
	case "$(pmk_norm_kernel "$1")" in
		mihomo) echo mihomo ;;
		singbox) echo sing-box ;;
	esac
}

pmk_uci_kernel() {
	case "$(pmk_norm_kernel "$1")" in
		mihomo) echo mihomo ;;
		singbox) echo singbox ;;
	esac
}

pmk_host_arch() {
	case "$(uname -m)" in
		x86_64|amd64) echo amd64 ;;
		aarch64|arm64) echo arm64 ;;
		armv7l|armv7) echo armv7 ;;
		armv6l|armv6) echo armv6 ;;
		mips64el) echo mips64le ;;
		mipsel|mipsle) echo mipsle ;;
		mips) echo mips ;;
		i386|i486|i586|i686) echo 386 ;;
		riscv64) echo riscv64 ;;
		*) echo unknown ;;
	esac
}

pmk_arch_family() {
	case "$1" in
		amd64|386) echo x86 ;;
		arm64) echo arm64 ;;
		armv6|armv7) echo arm ;;
		mips|mipsle) echo mips ;;
		mips64le) echo mips64 ;;
		riscv64) echo riscv64 ;;
		*) echo unknown ;;
	esac
}

pmk_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# 精简固件不一定有 timeout（busybox 未编译该 applet），退化为直接执行
pmk_to() {
	local s=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$s" "$@"
	else
		"$@"
	fi
}

pmk_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		openssl dgst -sha256 "$1" | sed 's/.*= *//'
	fi
}

# ELF e_machine（offset 18，2 字节）
# 注意：精简固件可能没有 od/hexdump，改用 dd + cmp 按字节比较（busybox 均有）
pmk_elf_arch() {
	local d="$PMK_RUN/elf-mach.bin" e="$PMK_RUN/elf-mach.exp" pair name esc
	[ -f "$1" ] || { echo unknown; return 1; }
	mkdir -p "$PMK_RUN"
	dd if="$1" bs=1 skip=18 count=2 2>/dev/null > "$d"
	for pair in 'amd64:\076\000' 'arm64:\267\000' 'arm:\050\000' '386:\003\000' 'riscv64:\363\000' 'mips:\010\000'; do
		name=${pair%%:*}; esc=${pair#*:}
		printf "$esc" > "$e"
		if cmp -s "$d" "$e"; then echo "$name"; return 0; fi
	done
	echo unknown
}

# 需要 glibc 解释器的二进制在 musl 固件上无法执行
pmk_elf_libc() {
	if grep -aq 'ld-linux' "$1" 2>/dev/null; then echo glibc; else echo static; fi
}

pmk_detect_version() { # bin -> semver（不带 v）
	local out
	case "$(basename "$1")" in
		mihomo)
			# mihomo 只支持 -v；绝不能执行 `mihomo version`——那会被当成“无子命令启动”，
			# 按默认配置起代理进程
			out=$(pmk_to 8 "$1" -v 2>&1)
			;;
		*)
			out=$(pmk_to 8 "$1" --version 2>&1)
			case "$out" in
				*[0-9].[0-9]*) ;;
				*) out=$(pmk_to 8 "$1" version 2>&1) ;;
			esac
			;;
	esac
	printf '%s' "$out" | grep -o -E 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^v//'
}

pmk_semver_major() { printf '%s' "$1" | cut -d. -f1; }
pmk_semver_minor() { printf '%s' "$1" | cut -d. -f2; }

pmk_links() { # kernel -> active/previous 解析
	local d="$PMK_STORE/$1"
	[ -d "$d" ] || return 0
	[ -L "$d/active" ] && basename "$(readlink "$d/active")"
}

pmk_previous() {
	local d="$PMK_STORE/$1"
	[ -L "$d/previous" ] || return 0
	basename "$(readlink "$d/previous")"
}

pmk_spin_lock() {
	mkdir -p "$PMK_RUN"
	if mkdir "$PMK_LOCK" 2>/dev/null; then
		echo $$ > "$PMK_LOCK/pid"
		return 0
	fi
	local pid
	pid=$(cat "$PMK_LOCK/pid" 2>/dev/null)
	if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
		rm -rf "$PMK_LOCK"
		mkdir "$PMK_LOCK" 2>/dev/null && echo $$ > "$PMK_LOCK/pid" && return 0
	fi
	return 1
}

pmk_unlock() { rm -rf "$PMK_LOCK"; }

pmk_job_set() { # phase message bytes done ok code version
	PMK_JOB_PHASE=$1 PMK_JOB_MSG=$2
	printf '{"id":"%s","op":"%s","kernel":"%s","version":"%s","phase":"%s","message":"%s","bytes":%s,"done":%s,"ok":%s,"code":"%s","started":"%s","updated":"%s"}\n' \
		"$(pmk_esc "$PMK_JOB_ID")" "$(pmk_esc "$PMK_JOB_OP")" "$(pmk_esc "$PMK_JOB_KERNEL")" \
		"$(pmk_esc "${7:-$PMK_JOB_VERSION}")" "$(pmk_esc "$1")" "$(pmk_esc "$2")" "${3:-0}" "${4:-false}" \
		"${5:-null}" "$(pmk_esc "$6")" "$PMK_JOB_START" "$(date -u +%H:%M:%S)" > "$PMK_JOB.tmp" 2>/dev/null &&
		mv "$PMK_JOB.tmp" "$PMK_JOB"
}

pmk_job_fail() {
	pmk_job_set failed "$2" "${3:-0}" true false "$1"
	pmk_log "内核任务失败 ${1}: $2"
	pmk_unlock
	echo "rc=1 code=$1 msg=$2"
	exit 1
}

pmk_job_ok() {
	pmk_job_set done "$1" "${2:-0}" true true ""
	pmk_unlock
	echo "rc=0"
}

pmk_job_clear() { rm -f "$PMK_JOB"; }

pmk_free_kb() {
	local p kb
	p=$1
	# df 对不存在的路径会报错，向上找到已存在的父目录再测（首次安装时目录还没建）
	while [ ! -d "$p" ] && [ "$p" != / ] && [ "$p" != . ]; do p=$(dirname "$p"); done
	kb=$(df -k "$p" 2>/dev/null | awk 'NR==2{print $4}')
	echo "${kb:-0}"
}

# ---------- 镜像源 ----------

pmk_mirrors_init() {
	mkdir -p "$PMK_STORE"
	[ -f "$PMK_MIRRORS" ] || cat > "$PMK_MIRRORS" <<'EOF'
{
  "mirrors": [
    { "name": "github", "label": "GitHub 官方", "prefix": "", "enabled": true, "official": true },
    { "name": "ghproxy", "label": "ghproxy 加速", "prefix": "https://ghproxy.net/", "enabled": false, "official": false },
    { "name": "custom", "label": "自定义反代", "prefix": "", "enabled": false, "official": false }
  ]
}
EOF
	return 0
}

pmk_mirror_prefix() { # name -> prefix
	pmk_mirrors_init
	[ "$1" = github ] && { echo ''; return 0; }
	jsonfilter -i "$PMK_MIRRORS" -e "@.mirrors[@.name=\"$1\"].prefix" 2>/dev/null
}

pmk_source_url() { # url mirror
	local url="$1" mirror="$2" prefix
	[ "$mirror" = github ] && { echo "$url"; return 0; }
	prefix=$(pmk_mirror_prefix "$mirror")
	if [ -z "$prefix" ]; then
		pmk_log "镜像 $mirror 未配置前缀，改用官方源"
		echo "$url"
		return 0
	fi
	case "$prefix" in
		https://*) ;;
		*) pmk_log "镜像前缀不是 https，拒绝使用：$prefix"; echo "$url"; return 0 ;;
	esac
	case "$prefix" in
		*/) ;;
		*) prefix="$prefix/" ;;
	esac
	echo "${prefix}${url}"
}

# ---------- 网络 ----------

pmk_fetch_cmd() {
	if command -v uclient-fetch >/dev/null 2>&1; then echo uclient-fetch
	elif command -v wget >/dev/null 2>&1; then echo wget
	elif command -v curl >/dev/null 2>&1; then echo curl
	else echo ''; fi
}

pmk_fetch() { # url out
	local cmd
	cmd=$(pmk_fetch_cmd)
	[ -n "$cmd" ] || return 127
	case "$cmd" in
		uclient-fetch) uclient-fetch -q -T 120 -O "$2" "$1" >/dev/null 2>&1 ;;
		wget) wget -q -T 120 -O "$2" "$1" >/dev/null 2>&1 ;;
		curl) curl -fsSL --max-time 120 -o "$2" "$1" >/dev/null 2>&1 ;;
	esac
}

pmk_http_json() { # url out
	case "$1" in
		http://127.0.0.1:*|http://localhost:*|https://*) ;;
		*) return 3 ;;
	esac
	pmk_fetch "$1" "$2"
}

pmk_download() { # url out
	local pid bytes rc
	pmk_job_set download "开始下载：$1" 0 false null ""
	pmk_fetch "$1" "$2" &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		bytes=$(pmk_size "$2" 2>/dev/null)
		pmk_job_set download "已下载 ${bytes:-0} 字节" "${bytes:-0}" false null ""
		sleep 1
	done
	wait "$pid"
	rc=$?
	bytes=$(pmk_size "$2" 2>/dev/null)
	pmk_job_set download "下载完成：${bytes:-0} 字节" "${bytes:-0}" false null ""
	return "$rc"
}

# ---------- 版本清单 ----------

pmk_repo() {
	case "$1" in
		mihomo) echo MetaCubeX/mihomo ;;
		singbox) echo SagerNet/sing-box ;;
	esac
}

pmk_asset_terms() { # kernel -> 候选子串（优先顺序）
	local arch
	arch=$(pmk_host_arch)
	case "$1" in
		mihomo)
			case "$arch" in
				amd64) echo 'linux-amd64-' ;;
				arm64) echo 'linux-arm64-' ;;
				armv7) echo 'linux-armv7-' ;;
				armv6) echo 'linux-armv6-' ;;
				mips) echo 'linux-mips-softfloat-' ; echo 'linux-mips-hardfloat-' ;;
				mipsle) echo 'linux-mipsle-softfloat-' ; echo 'linux-mipsle-hardfloat-' ;;
				386) echo 'linux-386-' ;;
				riscv64) echo 'linux-riscv64-' ;;
			esac
			;;
		singbox)
			case "$arch" in
				amd64) echo 'linux-amd64' ;;
				arm64) echo 'linux-arm64' ;;
				armv7) echo 'linux-armv7' ;;
				armv6) echo 'linux-armv6' ;;
				mips) echo 'linux-mips' ;;
				mipsle) echo 'linux-mipsle' ;;
				386) echo 'linux-386' ;;
				riscv64) echo 'linux-riscv64' ;;
			esac
			;;
	esac
}

pmk_asset_rank() { # kernel url -> 优先级（越小越好），不匹配输出空
	local kernel="$1" url="$2" name
	name=$(basename "$url")
	case "$name" in
		*.sig|*.sha256|*.sha512|*.txt|*checksums*|*.asc) return 0 ;;
	esac
	case "$kernel" in
		mihomo)
			case "$name" in
				# amd64 默认包要求 x86-64-v3（AVX2），多数路由器/虚拟机只有 v1；
				# 优先 compatible 构建，避免“装完却跑不起来”
				*-compatible-*) echo 8 ;;
				*-go1*) echo 20 ;;
				*-linux-*.gz) echo 30 ;;
			esac
			;;
		singbox)
			case "$name" in
				*-musl.tar.gz) echo 10 ;;
				*linux*.tar.gz) case "$name" in *-glibc*) echo 30 ;; *) echo 20 ;; esac ;;
				*linux*.gz|*linux*.zip) echo 40 ;;
			esac
			;;
	esac
}

pmk_releases_json() { # kernel out
	local repo url
	repo=$(pmk_repo "$1")
	url="https://api.github.com/repos/$repo/releases?per_page=30"
	pmk_fetch "$url" "$2"
}

pmk_api_versions() {
	local kernel arch repo tmp urls tag pre rank best bestrank name out sep
	kernel=$(pmk_norm_kernel "$(pmk_arg kernel)") || echo '{"ok":false,"error":"unknown kernel"}'
	arch=$(pmk_host_arch)
	tmp="$PMK_RUN/releases.json"
	mkdir -p "$PMK_RUN"
	repo=$(pmk_repo "$kernel")

	if ! pmk_releases_json "$kernel" "$tmp" || [ ! -s "$tmp" ]; then
		echo "{\"ok\":false,\"error\":\"无法获取版本清单（需要能访问 api.github.com，或改用自定义 URL/本地导入）\",\"arch\":\"$arch\",\"repo\":\"$repo\"}"
		return 0
	fi

	urls="$PMK_RUN/urls.txt"
	grep -o '"browser_download_url":"[^"]*"' "$tmp" | sed 's/^"browser_download_url":"//; s/"$//' > "$urls"

	# 每个 release 的 tag + prerelease：按 prerelease 字段切块
	tr -d '\n' < "$tmp" | awk '{gsub(/,"prerelease":/,"\n\"prerelease\":")}1' > "$PMK_RUN/presplit.txt"

	out='['; sep=''
	while IFS= read -r chunk; do
		tag=$(printf '%s' "$chunk" | grep -o '"tag_name":"[^"]*"' | tail -1 | cut -d'"' -f4)
		[ -n "$tag" ] || continue
		case "$chunk" in
			*'"prerelease":true'*) pre=true ;;
			*) pre=false ;;
		esac
		[ "$(pmk_arg prerelease)" = 1 ] || [ "$pre" = false ] || continue
		best=''; bestrank=99
		while IFS= read -r u; do
			case "$u" in
				*/download/"$tag"/*) ;;
				*) continue ;;
			esac
			rank=$(pmk_asset_rank "$kernel" "$u" | head -1)
			[ -n "$rank" ] || continue
			if [ "$rank" -lt "$bestrank" ]; then
				bestrank=$rank; best=$u
			fi
		done < "$urls"
		[ -n "$best" ] || continue
		name=$(basename "$best")
		out="$out$sep{\"version\":\"$(pmk_esc "$tag")\",\"prerelease\":$pre,\"asset\":\"$(pmk_esc "$name")\",\"url\":\"$(pmk_esc "$best")\"}"
		sep=','
	done < "$PMK_RUN/presplit.txt"

	out="$out]"
	echo "{\"ok\":true,\"kernel\":\"$kernel\",\"arch\":\"$arch\",\"repo\":\"$repo\",\"versions\":$out}"
}

pmk_api_mirrors() {
	pmk_mirrors_init
	if jsonfilter -i "$PMK_MIRRORS" -t '@' >/dev/null 2>&1; then
		echo "{\"ok\":true,\"mirrors\":$(cat "$PMK_MIRRORS")}"
	else
		echo '{"ok":false,"error":"mirrors.json 语法无效"}'
	fi
}

pmk_api_mirror_set() {
	local raw
	raw=$(pmk_arg json)
	mkdir -p "$PMK_STORE"
	printf '%s' "$raw" > "$PMK_MIRRORS.tmp"
	if jsonfilter -i "$PMK_MIRRORS.tmp" -t '@' >/dev/null 2>&1; then
		mv "$PMK_MIRRORS.tmp" "$PMK_MIRRORS"
		echo '{"ok":true}'
	else
		rm -f "$PMK_MIRRORS.tmp"
		echo '{"ok":false,"error":"JSON 语法无效，未保存"}'
	fi
}

# 手动检测镜像是否可用（不做自动轮询）：下载最新 release 首字节，计时
pmk_api_mirror_test() {
	local name url prefix start end rc size tmp
	name=$(pmk_arg name)
	mkdir -p "$PMK_RUN"
	tmp="$PMK_RUN/mirror-test.bin"
	url="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo-linux-amd64-v1.19.33.gz"
	url=$(pmk_source_url "$url" "$name")
	start=$(date +%s)
	# 手动取样：只跑 6 秒就断开，避免整包下载（固件没有 timeout 时也不能卡死）
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$tmp" "$url" >/dev/null 2>&1 &
		local fp=$! i=0
		while [ $i -lt 6 ] && kill -0 "$fp" 2>/dev/null; do
			sleep 1
			i=$((i + 1))
		done
		kill "$fp" 2>/dev/null
		wait "$fp" 2>/dev/null
		if [ -s "$tmp" ]; then rc=0; else rc=4; fi
	else
		rc=127
	fi
	end=$(date +%s)
	size=$(pmk_size "$tmp" 2>/dev/null)
	rm -f "$tmp"
	if [ "$rc" = 0 ]; then
		echo "{\"ok\":true,\"name\":\"$(pmk_esc "$name")\",\"url\":\"$(pmk_esc "$url")\",\"elapsed\":$((end - start)),\"bytes\":${size:-0}}"
	else
		echo "{\"ok\":false,\"name\":\"$(pmk_esc "$name")\",\"url\":\"$(pmk_esc "$url")\",\"elapsed\":$((end - start)),\"rc\":$rc}"
	fi
}

# ---------- 状态 ----------

pmk_meta_json() { # kernel tag
	local meta="$PMK_STORE/$1/$2/meta" bin
	[ -s "$meta" ] || { echo 'null'; return 0; }
	local v sha size arch libc verif src inst active prev
	v=$(sed -n 's/^version=//p' "$meta")
	sha=$(sed -n 's/^sha256=//p' "$meta")
	size=$(sed -n 's/^size=//p' "$meta")
	arch=$(sed -n 's/^arch=//p' "$meta")
	libc=$(sed -n 's/^libc=//p' "$meta")
	verif=$(sed -n 's/^verified=//p' "$meta")
	src=$(sed -n 's/^source=//p' "$meta")
	inst=$(sed -n 's/^installed=//p' "$meta")
	active=false; prev=false
	[ -L "$PMK_STORE/$1/active" ] && [ "$(basename "$(readlink "$PMK_STORE/$1/active")")" = "$2" ] && active=true
	[ -L "$PMK_STORE/$1/previous" ] && [ "$(basename "$(readlink "$PMK_STORE/$1/previous")")" = "$2" ] && prev=true
	bin=$(pmk_bin_name "$1")
	echo "{\"kernel\":\"$1\",\"tag\":\"$2\",\"version\":\"$(pmk_esc "$v")\",\"sha256\":\"$sha\",\"size\":${size:-0},\"arch\":\"$arch\",\"libc\":\"$libc\",\"verified\":\"$verif\",\"source\":\"$(pmk_esc "$src")\",\"installed\":\"$(pmk_esc "$inst")\",\"active\":$active,\"previous\":$prev,\"dir\":\"$PMK_STORE/$1/$2\",\"bin\":\"$PMK_STORE/$1/$2/$bin\"}"
}

pmk_installed_json() {
	local k d t sep='' out=''
	for k in mihomo singbox; do
		d="$PMK_STORE/$k"
		[ -d "$d" ] || continue
		for t in "$d"/*; do
			[ -d "$t" ] || continue
			case "$t" in */.stage*) continue ;; esac
			[ -s "$t/meta" ] || continue
			out="$out$sep$(pmk_meta_json "$k" "$(basename "$t")")"
			sep=','
		done
	done
	echo "[$out]"
}

pmk_api_status() {
	local arch kcur kk bin kernelpath cfg_path compat okj job out tag
	local aver asha asize aarch alibc amatch sbbucket ccheck
	arch=$(pmk_host_arch)
	kcur=$($PMK_UCI -q get ferry.main.kernel 2>/dev/null)
	[ -n "$kcur" ] || kcur=mihomo
	kk=$(pmk_norm_kernel "$kcur")
	bin=$(pmk_bin_name "$kcur")
	kernelpath="$PMK_BIN_DIR/$bin"
	cfg_path=$($PMK_UCI -q get ferry.main.config_path 2>/dev/null)
	[ -n "$cfg_path" ] || cfg_path="$(pmk_default_config "$kcur")"
	compat=true
	if [ -n "$cfg_path" ] && [ -f "$cfg_path" ]; then
		case "$kcur" in
			singbox) case "$cfg_path" in *.json) ;; *) compat=false ;; esac ;;
			mihomo) case "$cfg_path" in *.yaml|*.yml) ;; *) compat=false ;; esac ;;
		esac
	fi
	okj=$(pmk_kernel_running "$kcur" && echo true || echo false)
	job=$(cat "$PMK_JOB" 2>/dev/null)
	[ -n "$job" ] || job='null'

	tag=$(pmk_links "$kk")
	aver=''; asha=''; asize=0; aarch=''; alibc=''
	if [ -n "$tag" ] && [ -s "$PMK_STORE/$kk/$tag/meta" ]; then
		aver=$(sed -n 's/^version=//p' "$PMK_STORE/$kk/$tag/meta")
		asha=$(sed -n 's/^sha256=//p' "$PMK_STORE/$kk/$tag/meta")
		asize=$(sed -n 's/^size=//p' "$PMK_STORE/$kk/$tag/meta")
		aarch=$(sed -n 's/^arch=//p' "$PMK_STORE/$kk/$tag/meta")
		alibc=$(sed -n 's/^libc=//p' "$PMK_STORE/$kk/$tag/meta")
	fi
	amatch=false
	[ -n "$aarch" ] && [ "$(pmk_arch_family "$aarch")" = "$(pmk_arch_family "$arch")" ] && amatch=true
	sbbucket=''
	[ "$kk" = singbox ] && sbbucket=$(pmk_sb_bucket)
	ccheck=''
	[ -s "$PMK_RUN/config-check-report.txt" ] && ccheck=$(tail -c 1200 "$PMK_RUN/config-check-report.txt" | tail -n 24)

	out=$(cat <<EOF
{"ok":true,"arch":"$arch","uci_kernel":"$kcur","uci_kernel_norm":"$kk","running":$okj,"bin_path":"$(pmk_esc "$kernelpath")","bin_exists":$([ -x "$kernelpath" ] && echo true || echo false),"config_path":"$(pmk_esc "$cfg_path")","config_compatible":$compat,"free_kb":$(pmk_free_kb "$PMK_STORE" 2>/dev/null || echo 0),"active":"$(pmk_esc "$tag")","previous":"$(pmk_esc "$(pmk_previous "$kk")")","active_version":"$(pmk_esc "$aver")","active_sha256":"$asha","active_size":${asize:-0},"active_arch":"$(pmk_esc "$aarch")","active_libc":"$(pmk_esc "$alibc")","arch_match":$amatch,"sb_bucket":"$(pmk_esc "$sbbucket")","config_check":"$(pmk_esc "$ccheck")","installed":$(pmk_installed_json),"job":$job}
EOF
)
	echo "$out"
}

# 内核二进制当前所属的 sing-box 配置区间（与 generate.sh 的 pm_sb_bucket 同一套边界）
pmk_bucket_from_version() {
	local v="$1" maj min rest
	case "$v" in
		''|*[!0-9.]*) echo unknown; return 0 ;;
	esac
	maj=${v%%.*}
	rest=${v#*.}
	min=${rest%%.*}
	if [ "$maj" -lt 1 ] || { [ "$maj" = 1 ] && [ "$min" -lt 8 ]; }; then
		echo unsupported; return 0
	fi
	if [ "$maj" -gt 1 ] || [ "$min" -ge 14 ]; then
		echo D
	elif [ "$min" -ge 12 ]; then
		echo C
	elif [ "$min" -eq 11 ]; then
		echo B
	else
		echo A
	fi
}

pmk_sb_bucket() { pmk_bucket_from_version "$(pmk_bin_version singbox)"; }

pmk_default_config() {
	case "$(pmk_norm_kernel "$1")" in
		mihomo) echo "$PMK_CFG_MIHOMO" ;;
		singbox) echo "$PMK_CFG_SINGBOX" ;;
	esac
}

pmk_kernel_running() { # kernel（按实际进程判断，init.d status 在“未启用”时也返回 0）
	local k bin
	k=$(pmk_norm_kernel "${1:-}")
	[ -n "$k" ] || k=$(pmk_uci_kernel "$($PMK_UCI -q get ferry.main.kernel 2>/dev/null)")
	bin=$(pmk_bin_name "$k")
	if command -v pidof >/dev/null 2>&1; then
		pidof "$bin" >/dev/null 2>&1
	else
		ps w 2>/dev/null | grep -v grep | grep -q "$bin"
	fi
}

pmk_service_stop() {
	[ -x "$PMK_SERVICE" ] && "$PMK_SERVICE" stop >/dev/null 2>&1
}

pmk_service_start() {
	[ -x "$PMK_SERVICE" ] && "$PMK_SERVICE" start >/dev/null 2>&1
}

# ---------- 配置生成 / 自检 ----------

pmk_bin_version() { pmk_detect_version "$PMK_BIN_DIR/$(pmk_bin_name "$(pmk_norm_kernel "$1")")"; }

pmk_generate_config() { # 生成配置并做内核自检；rc=0 表示通过，输出留在 /var/etc/ferry/config-check.txt
	local k cfg rc
	k=$(pmk_norm_kernel "$1")
	cfg=$(pmk_default_config "$k")
	mkdir -p "$PMK_RUN"
	(
		. "$PMK_LIB_DIR/common.sh" 2>/dev/null
		pm_load 2>/dev/null || exit 1
		# 生成配置依赖节点与规则渲染（与 init.d/ferry 的加载顺序一致）
		. "$PMK_LIB_DIR/nodes.sh" 2>/dev/null
		. "$PMK_LIB_DIR/rules.sh" 2>/dev/null
		. "$PMK_LIB_DIR/generate.sh" 2>/dev/null
		[ "$PM_KERNEL" = "$(pmk_uci_kernel "$k")" ] || exit 2
		if [ "$k" = singbox ]; then
			pm_gen_singbox >/dev/null 2>&1 || exit 1
			pm_singbox_check "$cfg"
		else
			pm_gen_mihomo >/dev/null 2>&1 || exit 1
			pm_mihomo_check "$cfg"
		fi
	) >"$PMK_RUN/config-check.txt" 2>&1
	rc=$?
	{
		echo "kernel=$k"
		echo "config=$cfg"
		echo "rc=$rc"
		echo "checked=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "output:"
		cat "$PMK_RUN/config-check.txt" 2>/dev/null
	} > "$PMK_RUN/config-check-report.txt"
	return "$rc"
}

pmk_config_check_output() {
	local k bin cfg
	k=$(pmk_norm_kernel "$1")
	bin="$PMK_BIN_DIR/$(pmk_bin_name "$k")"
	cfg=$(pmk_default_config "$k")
	[ -x "$bin" ] || { echo "内核不可执行：$bin"; return 0; }
	if [ "$k" = singbox ]; then
		pmk_to 30 "$bin" check -c "$cfg" -D "$(dirname "$cfg")" 2>&1 | tail -12
	else
		pmk_to 30 "$bin" -t -d "$(dirname "$cfg")" -f "$cfg" 2>&1 | tail -12
	fi
}

# ---------- 原子替换 ----------

pmk_link_atomic() { # target link
	ln -sfn "$1" "$2.tmp.$$" || return 1
	# mv 默认会把“指向目录的符号链接”当目录，从而把临时链接挪进去而不是替换；
	# 优先用 -T（GNU/busybox 均支持），不支持时先删旧链接再改名
	mv -fT "$2.tmp.$$" "$2" 2>/dev/null || {
		rm -f "$2"
		mv -f "$2.tmp.$$" "$2"
	}
}

pmk_adopt_external() { # kernel tag-override
	local k bin path ver dir tag
	k=$(pmk_norm_kernel "$1")
	bin=$(pmk_bin_name "$k")
	path="$PMK_BIN_DIR/$bin"
	[ -f "$path" ] && [ ! -L "$path" ] || return 0
	ver=$(pmk_detect_version "$path")
	tag=${2:-}
	[ -n "$tag" ] || tag=$(printf 'external-%s' "$(date +%Y%m%d%H%M%S)")
	dir="$PMK_STORE/$k/$tag"
	# 同 tag 目录里已有二进制时绝不覆盖（否则会把已安装版本顶掉），改存独立 tag
	if [ -e "$dir/$bin" ]; then
		tag=$(printf 'external-%s' "$(date +%Y%m%d%H%M%S)")
		dir="$PMK_STORE/$k/$tag"
	fi
	mkdir -p "$dir" || return 1
	mv "$path" "$dir/$bin" || return 1
	chmod 0755 "$dir/$bin"
	{
		echo "version=${ver:-unknown}"
		echo "sha256=$(pmk_sha256 "$dir/$bin")"
		echo "size=$(pmk_size "$dir/$bin")"
		echo "arch=$(pmk_elf_arch "$dir/$bin")"
		echo "libc=$(pmk_elf_libc "$dir/$bin")"
		echo "verified=self"
		echo "source=adopted"
		echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "$dir/meta"
	pmk_log "已接管现有内核 ${path} -> ${dir}（版本 ${ver:-unknown}）"
}

pmk_activate() { # kernel tag restart force
	local k tag restart force bin old_tag was_running rc
	k=$(pmk_norm_kernel "$1"); tag=$2; restart=${3:-1}; force=${4:-0}
	bin=$(pmk_bin_name "$k")
	[ -d "$PMK_STORE/$k/$tag" ] || pmk_job_fail ERR_NOT_INSTALLED "版本未安装：$k/$tag"

	if [ -n "$($PMK_UCI -q get ferry.main.bin_path 2>/dev/null)" ]; then
		pmk_job_fail ERR_CUSTOM_BIN_PATH "检测到 ferry.main.bin_path 已设置，内核管理不会覆盖自定义路径；请先清空该选项" 0 "$tag"
	fi

	local cur_kernel cur_cfg
	cur_kernel=$(pmk_uci_kernel "$($PMK_UCI -q get ferry.main.kernel 2>/dev/null)")
	cur_cfg=$($PMK_UCI -q get ferry.main.config_path 2>/dev/null)
	if [ "$cur_kernel" != "$k" ] && [ -n "$cur_cfg" ]; then
		case "$k" in
			singbox) case "$cur_cfg" in *.json) ;; *) [ "$force" = 1 ] || pmk_job_fail ERR_CONFIG_INCOMPATIBLE "自备配置 $cur_cfg 不是 sing-box JSON；切换内核需要--force 确认" 0 "$tag" ;; esac ;;
			mihomo) case "$cur_cfg" in *.yaml|*.yml) ;; *) [ "$force" = 1 ] || pmk_job_fail ERR_CONFIG_INCOMPATIBLE "自备配置 $cur_cfg 不是 mihomo YAML；切换内核需要 --force 确认" 0 "$tag" ;; esac ;;
		esac
	fi

	was_running=false
	pmk_kernel_running "$cur_kernel" && was_running=true
	local prev_of_target active_of_cur
	prev_of_target=$(pmk_links "$k")
	active_of_cur=$(pmk_links "$cur_kernel")
	[ "$cur_kernel" = "$k" ] && active_of_cur="$prev_of_target"

	pmk_job_set switch "停止服务" 0 false null "" "$tag"
	pmk_service_stop

	pmk_job_set switch "接管现有二进制/原子替换" 0 false null "" "$tag"
	pmk_adopt_external "$k" "$prev_of_target" || pmk_job_fail ERR_ADOPT "接管现有内核失败" 0 "$tag"
	pmk_link_atomic "$PMK_STORE/$k/$tag/$bin" "$PMK_BIN_DIR/$bin" || {
		# 同一内核换版本时把链接指回旧版本，再按原状态恢复服务
		if [ "$cur_kernel" = "$k" ] && [ -n "$active_of_cur" ] && [ -d "$PMK_STORE/$k/$active_of_cur" ]; then
			pmk_link_atomic "$PMK_STORE/$k/$active_of_cur/$bin" "$PMK_BIN_DIR/$bin"
		fi
		[ "$was_running" = true ] && pmk_service_start
		pmk_job_fail ERR_LINK "原子替换失败（$PMK_BIN_DIR/$bin）" 0 "$tag"
	}
	[ -n "$prev_of_target" ] && [ "$prev_of_target" != "$tag" ] && \
		pmk_link_atomic "$PMK_STORE/$k/$prev_of_target" "$PMK_STORE/$k/previous"
	pmk_link_atomic "$PMK_STORE/$k/$tag" "$PMK_STORE/$k/active"

	$PMK_UCI -q set ferry.main.kernel="$(pmk_uci_kernel "$k")" && $PMK_UCI -q commit ferry

	pmk_job_set switch "生成配置并自检" 0 false null "" "$tag"
	if [ "$restart" = 1 ] || [ "$was_running" = true ]; then
		if ! pmk_generate_config "$k"; then
			local out
			out=$(pmk_config_check_output "$k")
			pmk_rollback_internal "$cur_kernel" "$active_of_cur" "$was_running"
			pmk_job_fail ERR_CONFIG_CHECK "新内核配置自检未通过，已回滚：$out" 0 "$tag"
		fi
		pmk_job_set switch "启动服务" 0 false null "" "$tag"
		pmk_service_start
		sleep 3
		if ! pmk_kernel_running "$k"; then
			out=$(pmk_config_check_output "$k")
			pmk_rollback_internal "$cur_kernel" "$active_of_cur" "$was_running"
			pmk_job_fail ERR_START "新内核启动失败，已回滚：$out" 0 "$tag"
		fi
	fi
	pmk_job_ok "已启用 $k $tag" 0
}

pmk_rollback_internal() { # old_kernel old_tag was_running
	local ok=$1 otag=$2 wr=$3 bin
	pmk_service_stop
	bin=$(pmk_bin_name "$ok")
	if [ -n "$otag" ] && [ -d "$PMK_STORE/$ok/$otag" ]; then
		pmk_link_atomic "$PMK_STORE/$ok/$otag/$bin" "$PMK_BIN_DIR/$bin"
	fi
	$PMK_UCI -q set ferry.main.kernel="$(pmk_uci_kernel "$ok")"
	$PMK_UCI -q commit ferry
	pmk_generate_config "$ok" >/dev/null 2>&1
	[ "$wr" = true ] && pmk_service_start
}

# ---------- 安装 ----------

pmk_extract() { # src k dstbin -> 解出二进制到 dstbin
	# 不能按扩展名判断：下载临时文件统一叫 download.bin，必须按内容嗅探。
	# 精简固件可能没有 od，改用 gzip -t 判断是否为 gzip 流（tar.gz 或单文件 .gz）
	local f
	if gzip -t "$1" >/dev/null 2>&1; then
		# 先按 tar.gz 解包（tar -tzf 对“全零内容”会误判为空归档，不能用来判断）
		tar -xzf "$1" -C "$PMK_JAIL" 2>/dev/null
		f=$(find "$PMK_JAIL" -type f -name "$2" 2>/dev/null | head -1)
		[ -n "$f" ] || f=$(find "$PMK_JAIL" -type f -perm -u+x 2>/dev/null | head -1)
		if [ -n "$f" ]; then
			cp "$f" "$3" || return 1
		else
			# 不是 tar：仓库里的 .gz 是单文件压缩的二进制
			gzip -dc "$1" > "$3" 2>/dev/null || return 1
		fi
	else
		cp "$1" "$3" || return 1
	fi
	chmod 0755 "$3"
	return 0
}

pmk_url_allowed() {
	case "$1" in
		https://*) return 0 ;;
		http://127.0.0.1:*|http://localhost:*) return 0 ;;
		*) return 1 ;;
	esac
}

pmk_install_staged() { # kernel tag srcbin sha version verified source
	local k=$1 tag=$2 src=$3 sha=$4 ver=$5 verified=$6 source=$7 dir
	dir="$PMK_STORE/$k/$tag"
	mkdir -p "$dir" || return 1
	mv -f "$src" "$dir/$(pmk_bin_name "$k")" || return 1
	chmod 0755 "$dir/$(pmk_bin_name "$k")"
	{
		echo "version=${ver}"
		echo "sha256=${sha}"
		echo "size=$(pmk_size "$dir/$(pmk_bin_name "$k")")"
		echo "arch=$(pmk_elf_arch "$dir/$(pmk_bin_name "$k")")"
		echo "libc=$(pmk_elf_libc "$dir/$(pmk_bin_name "$k")")"
		echo "verified=${verified}"
		echo "source=${source}"
		echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "$dir/meta"
	return 0
}

pmk_run_install() { # 参数已通过环境/变量传入
	local k tag candidates cand url out src url_used start end elapsed expected verified ver arch_host fam_bin fam_host outbytes sha mirror_used
	k=$PMK_OP_KERNEL
	tag=$PMK_OP_VERSION
	elapsed=0
	mirror_used=github
	case "$tag" in
		*[!A-Za-z0-9._-]*|'') pmk_job_fail ERR_TAG "非法版本名：$tag" 0 ;;
	esac
	out="$PMK_RUN/download.bin"
	mkdir -p "$PMK_RUN" "$PMK_STORE" "$PMK_JAIL"
	rm -rf "$PMK_JAIL"; mkdir -p "$PMK_JAIL"; rm -f "$out"

	# 磁盘：至少要能放下压缩包 + 解压后二进制
	if [ "$(pmk_free_kb "$PMK_STORE" 2>/dev/null || echo 0)" -lt 8192 ]; then
		pmk_job_fail ERR_DISK_FULL "磁盘可用空间不足 8MB（$PMK_STORE）" 0 "$tag"
	fi

	if [ "$PMK_OP_LOCAL" = 1 ]; then
		pmk_job_set download "本地导入：$PMK_OP_URLS" 0 false null "" "$tag"
		cp "$PMK_OP_URLS" "$out" || pmk_job_fail ERR_LOCAL "读取本地文件失败：$PMK_OP_URLS" 0 "$tag"
		url_used="local:$PMK_OP_URLS"
	else
		pmk_job_set download "准备下载源" 0 false null "" "$tag"
		candidates="$PMK_OP_URLS"
		url_used=''
		for cand in $candidates; do
			url=$(pmk_source_url "$cand" "$PMK_OP_MIRROR")
			if ! pmk_url_allowed "$url"; then
				pmk_log "拒绝非 HTTPS 源（仅允许 https:// 或本机回环 http）：$url"
				continue
			fi
			start=$(date +%s)
			if pmk_download "$url" "$out" && [ -s "$out" ]; then
				end=$(date +%s); elapsed=$((end - start))
				url_used="$url"
				mirror_used=$PMK_OP_MIRROR
				pmk_log "下载成功：$url（镜像 $mirror_used）用时 ${elapsed}s 大小 $(pmk_size "$out") 字节"
				break
			fi
			pmk_log "下载失败，尝试下一个候选：$url"
			rm -f "$out"
		done
		[ -n "$url_used" ] || pmk_job_fail ERR_NETWORK "所有候选源都下载失败（检查网络/镜像/URL，或改用本地导入）" 0 "$tag"
	fi

	outbytes=$(pmk_size "$out")

	pmk_job_set verify "校验 SHA-256（源 ${url_used}，用时 ${elapsed}s）" "$outbytes" false null "" "$tag"
	expected=$PMK_OP_SHA256
	verified=sha256
	if [ -z "$expected" ]; then
		# 侧车文件 <url>.sha256（部分镜像/发布页提供）
		if pmk_fetch "$url_used.sha256" "$out.sha256" 2>/dev/null && [ -s "$out.sha256" ]; then
			expected=$(awk '{print $1}' "$out.sha256" | head -1)
			pmk_log "使用侧车校验值：$expected"
		fi
	fi
	if [ -z "$expected" ]; then
		if [ "$PMK_OP_ALLOW_UNVERIFIED" != 1 ]; then
			rm -f "$out"
			pmk_job_fail ERR_UNVERIFIED "官方未提供 checksum，需显式确认「未校验安装」后才能继续" "$outbytes" "$tag"
		fi
		verified=unverified
	else
		if ! pmk_sha256 "$out" | grep -qx "$expected"; then
			rm -f "$out"
			pmk_job_fail ERR_SHA_MISMATCH "SHA-256 不匹配（期望 $expected，实际 $(pmk_sha256 "$out")）" "$outbytes" "$tag"
		fi
		verified=sha256
	fi
	sha=$(pmk_sha256 "$out")

	pmk_job_set extract "解压并检查架构" "$outbytes" false null "" "$tag"
	if ! pmk_extract "$out" "$(pmk_bin_name "$k")" "$PMK_JAIL/$(pmk_bin_name "$k")"; then
		pmk_job_fail ERR_EXTRACT "解压/识别二进制失败（包内没有可执行文件？）" "$outbytes" "$tag"
	fi
	arch_host=$(pmk_host_arch)
	fam_host=$(pmk_arch_family "$arch_host")
	fam_bin=$(pmk_arch_family "$(pmk_elf_arch "$PMK_JAIL/$(pmk_bin_name "$k")")")
	if [ "$fam_bin" = unknown ] || [ "$fam_bin" != "$fam_host" ]; then
		pmk_job_fail ERR_ARCH "二进制架构不匹配：本机 $arch_host，包内 $(pmk_elf_arch "$PMK_JAIL/$(pmk_bin_name "$k")")" "$outbytes" "$tag"
	fi
	if [ "$(pmk_elf_libc "$PMK_JAIL/$(pmk_bin_name "$k")")" = glibc ]; then
		pmk_job_fail ERR_LIBC "二进制依赖 glibc，本固件为 musl（无法执行）" "$outbytes" "$tag"
	fi

	pmk_job_set version "读取二进制版本" "$outbytes" false null "" "$tag"
	ver=$(pmk_detect_version "$PMK_JAIL/$(pmk_bin_name "$k")")
	if [ -z "$ver" ]; then
		pmk_job_fail ERR_EXEC "二进制无法执行（架构/依赖不匹配？）" "$outbytes" "$tag"
	fi
	if [ -n "$PMK_OP_EXPECT_VERSION" ]; then
		case "$PMK_OP_EXPECT_VERSION" in
			v*) exp="${PMK_OP_EXPECT_VERSION#v}" ;;
			*) exp="$PMK_OP_EXPECT_VERSION" ;;
		esac
		[ "$ver" = "$exp" ] || pmk_job_fail ERR_VERSION_MISMATCH "版本不符：期望 $exp，实际 $ver" "$outbytes" "$tag"
	fi

	pmk_job_set install "落位到 $PMK_STORE/$k/$tag" "$outbytes" false null "" "$tag"
	pmk_install_staged "$k" "$tag" "$PMK_JAIL/$(pmk_bin_name "$k")" "$sha" "$ver" "$verified" "$url_used" || {
		pmk_job_fail ERR_INSTALL "落位失败（磁盘空间？）" "$outbytes" "$tag"
	}

	rm -f "$out" "$out.sha256"
	PMK_JOB_VERSION="$tag"

	if [ "$PMK_OP_ACTIVATE" = 1 ]; then
		pmk_activate "$k" "$tag" "${PMK_OP_RESTART:-1}" "${PMK_OP_FORCE:-0}"
		return $?
	fi
	pmk_job_ok "已安装 $k $tag（未启用；源 $mirror_used，用时 ${elapsed}s）" "$outbytes"
}

pmk_run_switch() { # 不传版本时切到该内核当前 active 版本（用于 mihomo/sing-box 一键互切）
	local k tag
	k=$(pmk_norm_kernel "$PMK_OP_KERNEL")
	tag=$PMK_OP_VERSION
	[ -n "$tag" ] || tag=$(pmk_links "$k")
	[ -n "$tag" ] || pmk_job_fail ERR_NOT_INSTALLED "$k 还没有已安装的版本，请先在内核页下载安装" 0
	PMK_OP_VERSION=$tag
	pmk_activate "$k" "$tag" "${PMK_OP_RESTART:-1}" "${PMK_OP_FORCE:-0}"
}

pmk_run_rollback() {
	local k prev
	k=$PMK_OP_KERNEL
	prev=$(pmk_previous "$k")
	[ -n "$prev" ] || pmk_job_fail ERR_NO_PREVIOUS "没有可回滚的上一版本" 0
	pmk_activate "$k" "$prev" "${PMK_OP_RESTART:-1}" 1
}

# ---------- 切换前预览 ----------

pmk_json_str() { # 保留换行（输出为 \n 转义），用于配置文件摘录
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s%s", sep, $0; sep="\\n"}'
}

pmk_api_preview() { # kernel version -> 当前配置摘录 + 目标格式/区间差异
	local k tag ver cur_k cur_cfg cur_cfg_uci excerpt cur_fmt target_fmt regen fc bucket
	k=$(pmk_norm_kernel "$(pmk_arg kernel)")
	[ -n "$k" ] || { echo '{"ok":false,"error":"unknown kernel"}'; return 0; }
	tag=$(pmk_arg version)
	cur_k=$(pmk_uci_kernel "$($PMK_UCI -q get ferry.main.kernel 2>/dev/null)")
	cur_cfg_uci=$($PMK_UCI -q get ferry.main.config_path 2>/dev/null)
	cur_cfg=$cur_cfg_uci
	[ -n "$cur_cfg" ] || cur_cfg=$(pmk_default_config "$cur_k")

	excerpt=''
	if [ -f "$cur_cfg" ]; then
		excerpt=$(head -c 1500 "$cur_cfg" 2>/dev/null)
	fi

	case "$cur_k" in singbox) cur_fmt=json ;; *) cur_fmt=yaml ;; esac
	case "$k" in singbox) target_fmt=json ;; *) target_fmt=yaml ;; esac
	regen=true
	[ -n "$cur_cfg_uci" ] && regen=false
	fc=false
	[ "$cur_fmt" = "$target_fmt" ] || fc=true

	bucket=''
	if [ "$k" = singbox ]; then
		ver=''
		[ -n "$tag" ] && [ -s "$PMK_STORE/$k/$tag/meta" ] && \
			ver=$(sed -n 's/^version=//p' "$PMK_STORE/$k/$tag/meta")
		[ -n "$ver" ] || ver=$(pmk_bin_version singbox)
		bucket=$(pmk_bucket_from_version "$ver")
	fi

	echo "{\"ok\":true,\"kernel\":\"$k\",\"version\":\"$(pmk_esc "$tag")\",\"current_kernel\":\"$cur_k\",\"current_config\":\"$(pmk_esc "$cur_cfg")\",\"current_format\":\"$cur_fmt\",\"target_format\":\"$target_fmt\",\"format_change\":$fc,\"regenerate\":$regen,\"sb_bucket\":\"$(pmk_esc "$bucket")\",\"excerpt\":\"$(pmk_json_str "$excerpt")\"}"
}

# ---------- 卸载 ----------

pmk_api_remove() {
	local k tag act prev cur bin
	k=$(pmk_norm_kernel "$(pmk_arg kernel)") || echo '{"ok":false,"error":"unknown kernel"}'
	tag=$(pmk_arg version)
	case "$tag" in *[!A-Za-z0-9._-]*|'') echo '{"ok":false,"error":"非法版本名"}'; return 0 ;; esac
	[ -d "$PMK_STORE/$k/$tag" ] || { echo '{"ok":false,"error":"版本未安装"}'; return 0; }
	act=$(pmk_links "$k"); prev=$(pmk_previous "$k")
	cur=$(pmk_uci_kernel "$($PMK_UCI -q get ferry.main.kernel 2>/dev/null)")
	# 只有“当前内核的启用版本”不能删；非当前内核的版本即便是指针目标也可以删
	if [ "$cur" = "$k" ] && [ "$act" = "$tag" ]; then
		echo '{"ok":false,"error":"不能卸载当前启用的版本，请先切换到其他版本"}'; return 0
	fi
	rm -rf "$PMK_STORE/$k/$tag"
	if [ "$prev" = "$tag" ]; then rm -f "$PMK_STORE/$k/previous"; fi
	# 删的是该内核的 active 指针目标时，同步清掉 active 指针与失效的 /usr/bin 链接
	if [ "$act" = "$tag" ]; then
		rm -f "$PMK_STORE/$k/active"
		bin=$(pmk_bin_name "$k")
		[ -L "$PMK_BIN_DIR/$bin" ] && rm -f "$PMK_BIN_DIR/$bin"
	fi
	echo '{"ok":true}'
}

# ---------- API 入口 ----------

PMK_ARGS=''
pmk_arg() { # key
	case "$PMK_ARGS" in
		'') return 0 ;;
	esac
	if command -v jsonfilter >/dev/null 2>&1; then
		printf '%s' "$PMK_ARGS" | jsonfilter -e "@.$1" 2>/dev/null
		return 0
	fi
	printf '%s' "$PMK_ARGS" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1
	printf '%s' "$PMK_ARGS" | sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p" | head -1
}

pmk_start_job() { # op -> 启动后台任务
	local op="$1" k
	PMK_OP_KERNEL=$(pmk_norm_kernel "$(pmk_arg kernel)") || { echo '{"ok":false,"error":"unknown kernel"}'; return 0; }
	k=$PMK_OP_KERNEL
	PMK_OP_VERSION=$(pmk_arg version)
	PMK_OP_SHA256=$(pmk_arg sha256 | tr 'A-F' 'a-f')
	PMK_OP_ALLOW_UNVERIFIED=$(pmk_arg allow_unverified)
	PMK_OP_ACTIVATE=$(pmk_arg activate)
	PMK_OP_RESTART=$(pmk_arg restart)
	PMK_OP_FORCE=$(pmk_arg force)
	PMK_OP_MIRROR=$(pmk_arg mirror)
	[ -n "$PMK_OP_MIRROR" ] || PMK_OP_MIRROR=github
	PMK_OP_URLS=$(pmk_arg urls)
	PMK_OP_FILE=$(pmk_arg file)
	PMK_OP_EXPECT_VERSION=$(pmk_arg expect_version)

	case "$op" in
		install)
			[ -n "$PMK_OP_URLS" ] || { echo '{"ok":false,"error":"缺少下载地址"}'; return 0; }
			[ -n "$PMK_OP_VERSION" ] || { echo '{"ok":false,"error":"缺少版本"}'; return 0; }
			;;
		install-local)
			case "$PMK_OP_FILE" in
				/*) ;;
				*) echo '{"ok":false,"error":"本地路径必须是绝对路径"}'; return 0 ;;
			esac
			[ -f "$PMK_OP_FILE" ] || { echo '{"ok":false,"error":"本地文件不存在"}'; return 0; }
			PMK_OP_URLS="$PMK_OP_FILE"
			PMK_OP_LOCAL=1
			[ -n "$PMK_OP_VERSION" ] || PMK_OP_VERSION=$(basename "$PMK_OP_FILE" | sed 's/\.[^.]*$//' | sed 's/\.tar$//')
			;;
		switch|rollback)
			;;
		*)
			[ -n "$PMK_OP_VERSION" ] || { echo '{"ok":false,"error":"缺少版本"}'; return 0; }
			;;
	esac

	if ! pmk_spin_lock; then
		echo '{"ok":false,"error":"已有内核任务在执行，请等待完成"}'
		return 0
	fi

	PMK_JOB_ID=$(date +%s)-$$ 
	PMK_JOB_OP=$op
	PMK_JOB_KERNEL=$k
	PMK_JOB_VERSION=$PMK_OP_VERSION
	PMK_JOB_START=$(date -u +%H:%M:%S)
	pmk_job_set queued "任务已排队" 0 false null "" "$PMK_JOB_VERSION"

	(
		PMK_JOB_ID=$PMK_JOB_ID PMK_JOB_OP=$PMK_JOB_OP PMK_JOB_KERNEL=$PMK_JOB_KERNEL \
		PMK_JOB_VERSION=$PMK_JOB_VERSION PMK_JOB_START=$PMK_JOB_START \
		PMK_OP_KERNEL=$PMK_OP_KERNEL PMK_OP_VERSION=$PMK_OP_VERSION \
		PMK_OP_SHA256=$PMK_OP_SHA256 PMK_OP_ALLOW_UNVERIFIED=$PMK_OP_ALLOW_UNVERIFIED \
		PMK_OP_ACTIVATE=$PMK_OP_ACTIVATE PMK_OP_RESTART=$PMK_OP_RESTART \
		PMK_OP_FORCE=$PMK_OP_FORCE PMK_OP_MIRROR=$PMK_OP_MIRROR \
		PMK_OP_URLS=$PMK_OP_URLS PMK_OP_FILE=$PMK_OP_FILE \
		PMK_OP_LOCAL=$PMK_OP_LOCAL \
		PMK_OP_EXPECT_VERSION=$PMK_OP_EXPECT_VERSION \
		sh "$PMK_LIB_DIR/kernel.sh" run "$op"
	) >/dev/null 2>&1 &

	echo "{\"ok\":true,\"job\":\"$PMK_JOB_ID\"}"
}

pmk_api_job() {
	local job
	job=$(cat "$PMK_JOB" 2>/dev/null)
	[ -n "$job" ] || job='null'
	echo "{\"ok\":true,\"job\":$job}"
}

# CLI
case "${1:-}" in
	status) pmk_api_status ;;
	versions) pmk_api_versions ;;
	mirrors) pmk_api_mirrors ;;
	mirror-set) PMK_ARGS=$(cat); pmk_api_mirror_set ;;
	mirror-test) PMK_ARGS=$(cat); pmk_api_mirror_test ;;
	preview) PMK_ARGS=$(cat); pmk_api_preview ;;
	remove) PMK_ARGS=$(cat); pmk_api_remove ;;
	start) PMK_ARGS=$(cat); pmk_start_job "$(pmk_arg op)" ;;
	job) pmk_api_job ;;
	run)
		op=$2
		case "$op" in
			install|install-local) pmk_run_install ;;
			switch) pmk_run_switch ;;
			rollback) pmk_run_rollback ;;
			*) pmk_job_fail ERR_OP "未知操作：$op" 0 ;;
		esac
		;;
esac
