#!/bin/bash
# 离线回归：升级快照 / 逐字段比对 / 一键恢复 / keep.d / 首启自愈（opkg 与 apk 两种路径）
# 不依赖外网，不触碰宿主生产环境；用 fake uci/opkg/apk/init.d 隔离。

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI="$REPO/files/usr/bin/ferry-sysupgrade"
TEST_ROOT=${FERRY_TEST_ROOT:-${HOME:-/home/$(id -un)}}
mkdir -p "$TEST_ROOT" 2>/dev/null
T=$(mktemp -d "$TEST_ROOT/ferry-upgrade-test.XXXXXX") || exit 1
FAILED=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=$((FAILED + 1)); }
note() { echo "  - $*"; }
check() { # desc, condition-cmd
	shift
	if "$@"; then pass "$1"; else fail "$1"; fi
}

cleanup() { rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$T"/{fake,etc/ferry,etc/config,etc/uci-defaults,lib/upgrade/keep.d,bin,etc/ferry/kernels/mihomo/v1.19.33,status}
CFG="$T/etc/config/ferry"
CONF="$T/etc/ferry"
KEEP="$T/lib/upgrade/keep.d/ferry"
STATE="$T/status"

# ---------- fake uci ----------
cat > "$T/fake/uci" <<'EOF'
#!/bin/sh
T=${FAKE_UCI_ROOT:?}
STATE=$T/status/keys
[ "$1" = "-q" ] && shift
cmd=$1; shift
case "$cmd" in
	get)
		[ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1
		;;
	set)
		k=${1%%=*}; v=${1#*=}
		[ -f "$STATE" ] || : > "$STATE"
		grep -v "^$k=" "$STATE" > "$STATE.tmp" 2>/dev/null
		printf '%s=%s\n' "$k" "$v" >> "$STATE.tmp"
		mv "$STATE.tmp" "$STATE"
		;;
	commit) : ;;
	show)
		[ -f "$STATE" ] && sed -e "s/^\(.*\)=\(.*\)$/\1='\2'/" "$STATE"
		;;
	export)
		echo "config ferry 'main'"
		[ -f "$STATE" ] && sed -n 's/^ferry\.main\.\([^=]*\)=\(.*\)$/\toption \1 '"'"'\2'"'"'/p' "$STATE"
		;;
	import)
		cat > "$T/status/imported"
		: > "$T/status/keys.new"
		echo "config ferry 'main'" > "$FAKE_CFG"
		while IFS= read -r l; do
			l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//')
			case "$l" in
				option*)
					set -- $l
					k=$2; v=$(printf '%s' "$3" | tr -d "'")
					printf 'ferry.main.%s=%s\n' "$k" "$v" >> "$T/status/keys.new"
					printf '\toption %s %s\n' "$k" "'$v'" >> "$FAKE_CFG"
					;;
			esac
		done < "$T/status/imported"
		mv "$T/status/keys.new" "$T/status/keys"
		;;
esac
exit 0
EOF
chmod 755 "$T/fake/uci"

# ---------- fake opkg / apk ----------
write_opkg() {
	cat > "$T/fake/opkg" <<'EOF'
#!/bin/sh
T=${FAKE_UCI_ROOT:?}
case "$1" in
	list-installed)
		[ -f "$T/status/installed" ] && echo "luci-app-ferry - 1.0.0-r9"
		;;
	files)
		cat "$T/status/pkgfiles" 2>/dev/null
		;;
	install)
		[ "$1" = "install" ] && shift
		case "${1:-}" in --force-depends) shift ;; esac
		echo "opkg install $1" >> "$T/status/actions"
		touch "$T/status/installed"
		;;
	remove)
		echo "opkg remove $1" >> "$T/status/actions"
		rm -f "$T/status/installed"
		rm -f "$T/etc/config/ferry"
		;;
esac
exit 0
EOF
	chmod 755 "$T/fake/opkg"
	rm -f "$T/fake/apk"
}

write_apk() {
	cat > "$T/fake/apk" <<'EOF'
#!/bin/sh
T=${FAKE_UCI_ROOT:?}
case "$1" in
	info)
		case "$2" in
			-e) [ -f "$T/status/installed" ] && exit 0 || exit 1 ;;
			-L) cat "$T/status/pkgfiles" 2>/dev/null ;;
		esac
		;;
	add)
		shift
		[ "${1:-}" = "--allow-untrusted" ] && shift
		echo "apk add $1" >> "$T/status/actions"
		touch "$T/status/installed"
		;;
	del)
		echo "apk del $1" >> "$T/status/actions"
		rm -f "$T/status/installed" "$T/etc/config/ferry"
		;;
esac
exit 0
EOF
	chmod 755 "$T/fake/apk"
	rm -f "$T/fake/opkg"
}

# ---------- fake init.d ----------
mkdir -p "$T/etc/init.d"
cat > "$T/etc/init.d/ferry" <<'EOF'
#!/bin/sh
T=${FAKE_UCI_ROOT:?}
echo "$1" >> "$T/status/actions"
exit 0
EOF
chmod 755 "$T/etc/init.d/ferry"

# ---------- 夹具数据 ----------
cat > "$CFG" <<'EOF'
config ferry 'main'
	option enabled '1'
	option deploy 'router'
	option kernel 'mihomo'
	option mode 'tproxy'
	option proxy_port '7890'
	option mixed_port '7891'
	option dns_port '1053'
	option sub_url 'https://example.com/sub'
EOF
cat > "$CONF/nodes.lst" <<'EOF'
BEGIN
node-a
END
BEGIN
node-b
END
EOF
cat > "$CONF/rules.lst" <<'EOF'
cn
ads
telegram
EOF
cat > "$CONF/nodes.json" <<'EOF'
{"nodes":[{"name":"node-a"},{"name":"node-b"}]}
EOF
cat > "$CONF/profiles.json" <<'EOF'
{"version":1,"active":"default","profiles":[{"id":"default"},{"id":"work"}]}
EOF
printf 'version=1.19.33\nsha256=deadbeef\n' > "$CONF/kernels/mihomo/v1.19.33/meta"
ln -s v1.19.33 "$CONF/kernels/mihomo/active"

# 关键 UCI 状态
cat > "$STATE/keys" <<'EOF'
ferry.main.enabled=1
ferry.main.deploy=router
ferry.main.kernel=mihomo
ferry.main.mode=tproxy
ferry.main.proxy_port=7890
ferry.main.mixed_port=7891
ferry.main.dns_port=1053
ferry.main.sub_url=https://example.com/sub
ferry.main.kernel_dir=
EOF

# ---------- 运行封装 ----------
export FAKE_UCI_ROOT="$T"
export FAKE_CFG="$CFG"
export FERRY_ROOT="$T"
export FERRY_LIB="$T/nonexistent.sh"
export FERRY_CFG_FILE="$CFG"
export FERRY_CONF_DIR="$CONF"
export FERRY_SNAP_DIR="$CONF/snapshot"
export FERRY_OFFLINE_DIR="$CONF/offline"
export FERRY_KEEP_D="$KEEP"
export FERRY_UCI_DEFAULTS_DIR="$T/etc/uci-defaults"
export FERRY_LOG_FILE="$CONF/selfheal.log"
export PATH="$T/fake:/usr/bin:/bin:/usr/sbin:/sbin"

run() { "$CLI" "$@" 2>&1; }

# 包文件清单（payload 使用）
cat > "$STATE/pkgfiles" <<EOF
/etc/config/ferry
/etc/init.d/ferry
/etc/uci-defaults/60-ferry-selfheal
/usr/lib/ferry/common.sh
/usr/bin/ferry-sysupgrade
/usr/share/rpcd/acl.d/luci-app-ferry.json
EOF
mkdir -p "$T/usr/lib/ferry" "$T/usr/bin" "$T/usr/share/rpcd/acl.d"
cp "$REPO/files/usr/lib/ferry/common.sh" "$T/usr/lib/ferry/common.sh"
cp "$CLI" "$T/usr/bin/ferry-sysupgrade"
cp "$REPO/files/usr/share/rpcd/acl.d/luci-app-ferry.json" "$T/usr/share/rpcd/acl.d/luci-app-ferry.json"
chmod 755 "$T/usr/bin/ferry-sysupgrade"

# ---------- 1. snapshot ----------
out=$(run snapshot)
echo "$out" | head -3 >/dev/null
[ -f "$CONF/snapshot/uci.txt" ] && pass "snapshot 生成 uci.txt" || fail "snapshot 缺少 uci.txt"
[ -f "$CONF/snapshot/meta" ] && pass "snapshot 生成 meta" || fail "snapshot 缺少 meta"
[ -f "$CONF/snapshot/kernels.tsv" ] && pass "snapshot 生成内核清单" || fail "snapshot 缺少 kernels.tsv"
grep -q 'nodes=2' "$CONF/snapshot/meta" && pass "snapshot 节点计数=2" || fail "snapshot 节点计数错误"
grep -q 'rules=3' "$CONF/snapshot/meta" && pass "snapshot 规则计数=3" || fail "snapshot 规则计数错误"
grep -q 'mihomo' "$CONF/snapshot/kernels.tsv" && pass "snapshot 内核清单含 mihomo" || fail "内核清单不含 mihomo"
echo "$out" | grep -q 'SNAP-CHECK OK' && pass "snapshot 自检 OK" || fail "snapshot 自检失败"

# ---------- 2. verify 未变 ----------
out=$(run verify)
echo "$out" | grep -q 'VERIFY RESULT: .* 0 FAIL' && pass "verify 未变更 0 FAIL" || { fail "verify 未变更有 FAIL"; note "$out"; }
echo "$out" | grep -q 'PASS ferry.main.proxy_port' && pass "verify 逐字段 PASS proxy_port" || fail "verify 缺少 proxy_port 字段 PASS"

# ---------- 3. 篡改后 verify ----------
sed -i 's/^ferry.main.proxy_port=7890/ferry.main.proxy_port=9999/' "$STATE/keys"
rm -f "$CONF/nodes.json"
out=$(run verify)
rc=$?
[ "$rc" -ne 0 ] && pass "verify 检测到差异返回非 0" || fail "verify 差异仍返回 0"
echo "$out" | grep -q 'FAIL ferry.main.proxy_port' && pass "verify 报出 proxy_port 字段差异" || fail "verify 未报 proxy_port"
echo "$out" | grep -q 'FAIL file:nodes.json' && pass "verify 报出 nodes.json 差异" || fail "verify 未报 nodes.json"

# ---------- 4. restore ----------
run restore >/dev/null
out=$(run verify)
echo "$out" | grep -q 'VERIFY RESULT: .* 0 FAIL' && pass "restore 后逐字段一致" || { fail "restore 后仍有差异"; note "$out"; }
[ -f "$CONF/nodes.json" ] && pass "restore 恢复 nodes.json" || fail "restore 未恢复 nodes.json"
[ "$(sed -n 's/^ferry.main.proxy_port=//p' "$STATE/keys")" = 7890 ] && pass "restore 恢复 proxy_port" || fail "restore 未恢复 proxy_port"

# ---------- 5. prep (opkg) ----------
write_opkg
out=$(run prep)
echo "$out" | grep -q 'PREP OK' && pass "prep 完成" || { fail "prep 失败"; note "$out"; }
[ -f "$KEEP" ] && pass "prep 写入 keep.d" || fail "prep 未写 keep.d"
grep -qx '/etc/config/ferry' "$KEEP" && pass "keep.d 含配置" || fail "keep.d 未含配置"
grep -qx '/etc/ferry' "$KEEP" && pass "keep.d 含 /etc/ferry（内核+快照+离线）" || fail "keep.d 未含 /etc/ferry"
grep -qx '/etc/uci-defaults/60-ferry-selfheal' "$KEEP" && pass "keep.d 含自愈钩子" || fail "keep.d 未含自愈钩子"
[ -s "$CONF/offline/payload.tar.gz" ] && pass "prep 生成离线安装包" || fail "prep 未生成离线包"
[ -x "$CONF/offline/install-payload.sh" ] && pass "prep 生成离线安装脚本" || fail "prep 未生成安装脚本"
[ -x "$CONF/offline/selfheal.sh" ] && pass "prep 生成自愈脚本" || fail "prep 未生成自愈脚本"
[ -x "$T/etc/uci-defaults/60-ferry-selfheal" ] && pass "prep 安装 uci-defaults 钩子" || fail "prep 未装 uci-defaults 钩子"

# 离线包不含用户配置（避免覆盖被 keep.d 保留的配置）
tar -tzf "$CONF/offline/payload.tar.gz" | grep -q '^etc/config/ferry$' && fail "离线包误含 /etc/config/ferry" || pass "离线包不含用户配置"

grep -q 'tar -xzf "$DIR/payload.tar.gz" -C "${ROOT:-/}"' "$CONF/offline/install-payload.sh" \
	&& pass "安装脚本在真实根目录可解包（-C 默认为 /）" || fail "安装脚本写死 -C 空值"

# ---------- 6. selfheal：包已安装 -> 跳过安装 ----------
touch "$STATE/installed"
: > "$STATE/actions"
run selfheal >/dev/null
grep -q 'already installed (opkg)' "$CONF/selfheal.log" && pass "selfheal 已安装时跳过" || fail "selfheal 未跳过已安装"
grep -q 'opkg install' "$STATE/actions" && fail "selfheal 已安装仍执行安装" || pass "selfheal 已安装未重复安装"

# ---------- 7. selfheal：包缺失 + 有 ipk -> opkg 离线安装 ----------
rm -f "$STATE/installed"
echo dummy > "$CONF/offline/luci-app-ferry.ipk"
out=$(run remove)
out=$(run selfheal)
grep -q 'pm-install opkg' "$CONF/selfheal.log" && pass "selfheal(opkg) 走包管理器离线安装" || { fail "selfheal(opkg) 未走 opkg"; note "$(cat "$CONF/selfheal.log")"; }
grep -q 'opkg install' "$STATE/actions" && pass "selfheal(opkg) 调用了 opkg install" || fail "selfheal(opkg) 未调用 opkg install"
[ -f "$STATE/installed" ] && pass "selfheal(opkg) 安装后包状态已存在" || fail "selfheal(opkg) 安装状态未更新"

# ---------- 8. selfheal：包缺失 + 无包文件 -> payload 兜底 ----------
rm -f "$STATE/installed" "$CONF/offline"/*.ipk "$CONF/offline"/*.apk "$T/etc/config/ferry"
run selfheal >/dev/null
grep -q 'payload-install ok=2' "$CONF/selfheal.log" && pass "selfheal 无包文件时 payload 兜底" || { fail "payload 兜底失败"; note "$(cat "$CONF/selfheal.log")"; }
[ -f "$CONF/.installed-payload" ] && pass "payload 兜底后写入已安装标记" || fail "payload 兜底未写标记"
[ -f "$T/etc/config/ferry" ] && pass "payload 后配置存在（快照恢复）" || fail "payload 后配置丢失"
: > "$CONF/selfheal.log"
run selfheal >/dev/null
grep -q 'already installed (opkg)' "$CONF/selfheal.log" && pass "payload 兜底后再次启动跳过重装" || fail "payload 兜底后重复安装"

# ---------- 9. remove 保护配置 ----------
touch "$STATE/installed"
write_opkg
run remove >/dev/null
[ ! -f "$STATE/installed" ] && pass "remove 卸载了 ferry 包" || fail "remove 未卸载"
[ -s "$T/etc/config/ferry" ] && pass "remove 后配置被快照补回" || fail "remove 后配置丢失"
[ -d "$CONF" ] && pass "remove 后 /etc/ferry 保留" || fail "remove 后 /etc/ferry 丢失"

# ---------- 10. apk 路径 ----------
write_apk
rm -f "$STATE/installed" "$T/etc/config/ferry"
echo dummy > "$CONF/offline/luci-app-ferry.apk"
out=$(run selfheal)
grep -q 'pm-install apk' "$CONF/selfheal.log" && pass "selfheal(apk) 走 apk 安装" || { fail "selfheal(apk) 未走 apk"; note "$(cat "$CONF/selfheal.log")"; }
grep -q 'apk add' "$STATE/actions" && pass "selfheal(apk) 调用 apk add" || fail "selfheal(apk) 未调用 apk add"

# ---------- 11. status ----------
write_opkg
run snapshot >/dev/null
out=$(run status)
echo "$out" | grep -q 'package_manager: opkg' && pass "status 识别 opkg" || fail "status 未识别 opkg"
echo "$out" | grep -q 'selfheal hook: present' && pass "status 显示自愈钩子" || fail "status 未显示钩子"

echo
if [ "$FAILED" -eq 0 ]; then
	echo "RESULT: ALL PASS"
else
	echo "RESULT: $FAILED FAIL"
fi
exit "$FAILED"
