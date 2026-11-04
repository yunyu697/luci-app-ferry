#!/bin/bash
# 卸载/一键清理的离线测试
#
# 目的：断言 uninstall.sh 能做到「进程停掉（init stop 被调用）、规则表清空、
#       dnsmasq 恢复、运行期目录清掉、用户数据按 --purge 保留/删除」。
#
# 做法：伪造 uci / nft / iptables / ip / init 脚本，路径全部指向临时目录。
#
# 运行：bash tests/test-uninstall.sh   （输出同时写入 tests/out/test-uninstall.log）

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tests/out"
CACHE="$ROOT/tests/.cache"
mkdir -p "$OUT" "$CACHE"
LOG="$OUT/test-uninstall.log"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); log "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); log "  FAIL  $*"; }

check() {
	if [ "$2" = "$3" ]; then
		pass "$1"
	else
		fail "$1"
		log "        期望=[$2]"
		log "        实际=[$3]"
	fi
}

T="$CACHE/uninstall-test"
STATE="$T/state"
NFT_STATE="$T/nft-state"
IPT_STATE="$T/ipt-state"
IP_STATE="$T/ip-state"
PM_CONF_DIR="$T/etc/ferry"
PM_RUN_DIR="$T/var/etc/ferry"
PM_DHCP_FILE="$T/etc/config/dhcp"
PM_INIT_SCRIPT="$T/init.d/ferry"
PM_RC_DIR="$T/rc.d"
INIT_LOG="$T/init-calls.log"

# ---------- 伪造命令 ----------
make_fakes() {
	mkdir -p "$T/bin"

	cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
state=${FAKE_UCI_STATE:?}
[ "$1" = "-q" ] && shift
cmd=$1 key=$2
shift 2
case "$cmd" in
	get)
		case "$key" in
			"dhcp.@dnsmasq[0].server")
				[ -f "$state/section" ] || exit 1
				[ -f "$state/server" ] && cat "$state/server"
				exit 0 ;;
			"dhcp.@dnsmasq[0].noresolv")
				[ -f "$state/section" ] || exit 1
				[ -f "$state/noresolv" ] && cat "$state/noresolv"
				exit 0 ;;
			"dhcp.@dnsmasq[0]")
				[ -f "$state/section" ] && exit 0 || exit 1 ;;
		esac
		exit 1 ;;
	delete)
		case "$key" in
			"dhcp.@dnsmasq[0].server")   rm -f "$state/server" ;;
			"dhcp.@dnsmasq[0].noresolv") rm -f "$state/noresolv" ;;
			*) exit 1 ;;
		esac
		exit 0 ;;
	add_list)
		case "$key" in
			dhcp.@dnsmasq\[0\].server=*) printf '%s\n' "${key#*=}" >> "$state/server" ;;
			*) exit 1 ;;
		esac
		exit 0 ;;
	set)
		case "$key" in
			"dhcp.@dnsmasq[0].noresolv="*) printf '%s\n' "${key#*=}" > "$state/noresolv" ;;
			*) exit 1 ;;
		esac
		exit 0 ;;
	commit) exit 0 ;;
esac
exit 1
EOF

	cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
state=${FAKE_NFT_STATE:?}
mkdir -p "$state"
case "$1" in
	-f)
		fam=$(awk '/^[[:space:]]*table /{print $2; exit}' "$2")
		name=$(awk '/^[[:space:]]*table /{print $3; exit}' "$2")
		mkdir -p "$state/$fam"; : > "$state/$fam/$name"
		;;
	delete) rm -f "$state/$3/$4" ;;
esac
exit 0
EOF

	cat > "$T/bin/iptables" <<'EOF'
#!/bin/sh
state=${FAKE_IPT_STATE:?}
mkdir -p "$state"
echo "$*" >> "$state/log"
table=filter chain='' target='' op=''
prev=''
for a in "$@"; do
	case "$prev" in
		-t) table=$a ;;
		-A|-I|-D) op=$prev; chain=$a ;;
	esac
	prev=$a
done
prev=''
for a in "$@"; do
	[ "$prev" = "-j" ] && target=$a
	prev=$a
done
if [ -n "$op" ] && [ "$chain" = PREROUTING ] && [ -n "$target" ]; then
	jf="$state/jumps.$table"
	case "$op" in
		-A|-I) echo "$target" >> "$jf" ;;
		-D)
			[ -f "$jf" ] || exit 0
			awk -v t="$target" 'BEGIN{d=0} {if(!d && $0==t){d=1;next} print}' "$jf" > "$jf.tmp"
			mv "$jf.tmp" "$jf"
			;;
	esac
fi
exit 0
EOF

	cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
state=${FAKE_IP_STATE:?}
mkdir -p "$state"
fam=4
[ "$1" = "-6" ] && { fam=6; shift; }
kind=$1 action=$2
echo "$fam $kind $action $*" >> "$state/log"
shift 2
f="$state/$kind.$fam"
case "$action" in
	add) echo "$*" >> "$f" ;;
	del)
		[ -f "$f" ] || exit 0
		awk -v k="$*" 'BEGIN{d=0} {if(!d && $0==k){d=1;next} print}' "$f" > "$f.tmp"
		mv "$f.tmp" "$f"
		;;
esac
exit 0
EOF

	chmod +x "$T/bin/uci" "$T/bin/nft" "$T/bin/iptables" "$T/bin/ip"
}

fake_init() {
	mkdir -p "$(dirname "$PM_INIT_SCRIPT")"
	cat > "$PM_INIT_SCRIPT" <<EOF
#!/bin/sh
echo "\$1" >> "$INIT_LOG"
exit 0
EOF
	chmod +x "$PM_INIT_SCRIPT"
}

# 装好的运行环境：规则表/跳转/策略路由/运行期文件/dnsmasq 已被改写
seed_installed() {
	rm -rf "$STATE" "$NFT_STATE" "$IPT_STATE" "$IP_STATE" \
		"$PM_CONF_DIR" "$PM_RUN_DIR" "$(dirname "$PM_DHCP_FILE")" "$INIT_LOG"
	mkdir -p "$STATE" "$PM_CONF_DIR/dnsmasq-backup" "$PM_RUN_DIR" \
		"$(dirname "$PM_DHCP_FILE")" "$NFT_STATE/ip" "$NFT_STATE/ip6" "$IPT_STATE" "$IP_STATE" "$PM_RC_DIR"
	: > "$PM_DHCP_FILE"
	: > "$STATE/section"
	: > "$INIT_LOG"

	# dnsmasq 被改写，备份保存原始值
	printf '127.0.0.1#1053\n' > "$STATE/server"
	printf '1\n' > "$STATE/noresolv"
	printf '223.5.5.5\n' > "$PM_CONF_DIR/dnsmasq-backup/server"
	: > "$PM_CONF_DIR/dnsmasq-backup/noresolv"

	# 用户数据
	printf '{"nodes":[]}\n' > "$PM_CONF_DIR/nodes.json"
	mkdir -p "$PM_CONF_DIR/rules-cache/mihomo"

	# 残留规则
	: > "$NFT_STATE/ip/ferry"
	: > "$NFT_STATE/ip6/ferry6"
	: > "$PM_RUN_DIR/ferry-v4.nft"
	printf 'PM_DNS\n' > "$IPT_STATE/jumps.nat"
	printf 'PM_TPROXY\n' > "$IPT_STATE/jumps.mangle"
	printf 'fwmark 1 table 100\n' > "$IP_STATE/rule.4"
	printf 'local default dev lo table 100\n' > "$IP_STATE/route.4"
	: > "$PM_RC_DIR/S99ferry"
}

count_lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

# 运行 uninstall.sh；$1=lib 目录 $2...=参数
run_uninstall() {
	local lib="$1"; shift
	PM_CONF_DIR="$PM_CONF_DIR" PM_RUN_DIR="$PM_RUN_DIR" \
	PM_DHCP_FILE="$PM_DHCP_FILE" PM_INIT_SCRIPT="$PM_INIT_SCRIPT" \
	PM_RC_DIR="$PM_RC_DIR" PM_LIB_DIR="$lib" \
	PATH="$T/bin:$PATH" \
	FAKE_UCI_STATE="$STATE" FAKE_NFT_STATE="$NFT_STATE" \
	FAKE_IPT_STATE="$IPT_STATE" FAKE_IP_STATE="$IP_STATE" \
	sh "$ROOT/files/usr/lib/ferry/uninstall.sh" "$@" >> "$LOG" 2>&1
}

log "== 卸载/一键清理离线测试 =="
log "工作目录：$T"
make_fakes
fake_init

# ---------- 用例 A：包内脚本可用（prerm 正常路径） ----------
log ""
log "A. 正常卸载：init stop、规则清空、dnsmasq 还原、用户数据保留"
seed_installed
run_uninstall "$ROOT/files/usr/lib/ferry"
check "退出码为 0" "0" "$?"
check "调用了 init stop" "yes" "$(grep -q stop "$INIT_LOG" && echo yes || echo no)"
check "取消了开机自启" "yes" "$(grep -q disable "$INIT_LOG" && echo yes || echo no)"
check "nft IPv4 表清空" "0" "$(ls "$NFT_STATE/ip" 2>/dev/null | wc -l | tr -d ' ')"
check "nft IPv6 表清空" "0" "$(ls "$NFT_STATE/ip6" 2>/dev/null | wc -l | tr -d ' ')"
check "iptables nat 跳转清空" "0" "$(count_lines "$IPT_STATE/jumps.nat")"
check "iptables mangle 跳转清空" "0" "$(count_lines "$IPT_STATE/jumps.mangle")"
check "策略路由清空" "0" "$(( $(count_lines "$IP_STATE/rule.4") + $(count_lines "$IP_STATE/route.4") ))"
check "dnsmasq 恢复原始上游" "223.5.5.5" "$(cat "$STATE/server")"
check "noresolv 恢复为未设置" "no" "$([ -f "$STATE/noresolv" ] && echo yes || echo no)"
check "dnsmasq 备份已删除" "no" "$([ -f "$PM_CONF_DIR/dnsmasq-backup/server" ] && echo yes || echo no)"
check "运行期目录已删除" "no" "$([ -d "$PM_RUN_DIR" ] && echo yes || echo no)"
check "用户节点数据保留" "yes" "$([ -f "$PM_CONF_DIR/nodes.json" ] && echo yes || echo no)"
check "rc.d 自启链接已删除" "no" "$([ -f "$PM_RC_DIR/S99ferry" ] && echo yes || echo no)"

# ---------- 用例 B：包内脚本已被删除（兜底路径） ----------
log ""
log "B. 包文件已删（无 init 脚本、无库文件）：内置兜底仍能清干净"
seed_installed
rm -f "$PM_INIT_SCRIPT"
run_uninstall "$T/no-such-lib"
check "退出码为 0（B）" "0" "$?"
check "nft IPv4 表清空（B）" "0" "$(ls "$NFT_STATE/ip" 2>/dev/null | wc -l | tr -d ' ')"
check "iptables 跳转清空（B）" "0" "$(count_lines "$IPT_STATE/jumps.nat")"
check "策略路由清空（B）" "0" "$(( $(count_lines "$IP_STATE/rule.4") + $(count_lines "$IP_STATE/route.4") ))"
check "dnsmasq 恢复原始上游（B）" "223.5.5.5" "$(cat "$STATE/server")"
check "noresolv 恢复为未设置（B）" "no" "$([ -f "$STATE/noresolv" ] && echo yes || echo no)"
check "运行期目录已删除（B）" "no" "$([ -d "$PM_RUN_DIR" ] && echo yes || echo no)"

# ---------- 用例 C：--purge ----------
log ""
log "C. --purge 会删除用户数据，普通卸载不会"
seed_installed
run_uninstall "$ROOT/files/usr/lib/ferry"
check "普通卸载保留 /etc/ferry" "yes" "$([ -d "$PM_CONF_DIR" ] && echo yes || echo no)"
seed_installed
run_uninstall "$ROOT/files/usr/lib/ferry" --purge
check "--purge 删除 /etc/ferry" "no" "$([ -d "$PM_CONF_DIR" ] && echo yes || echo no)"

# ---------- 用例 D：未启用过的设备反复清理 ----------
log ""
log "D. 干净设备重复执行不报错、不改 dnsmasq"
rm -rf "$STATE" "$NFT_STATE" "$IPT_STATE" "$IP_STATE" "$PM_CONF_DIR" "$PM_RUN_DIR"
mkdir -p "$STATE" "$PM_CONF_DIR" "$NFT_STATE" "$IPT_STATE" "$IP_STATE"
: > "$STATE/section"
printf '223.5.5.5\n' > "$STATE/server"
run_uninstall "$ROOT/files/usr/lib/ferry"
check "幂等执行退出码为 0" "0" "$?"
check "没有备份时不动 dnsmasq" "223.5.5.5" "$(cat "$STATE/server")"
run_uninstall "$ROOT/files/usr/lib/ferry"
check "再次执行仍为 0" "0" "$?"

log ""
log "== 结果：PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
