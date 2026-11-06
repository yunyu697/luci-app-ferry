#!/bin/bash
# 接管规则（nft / iptables / 策略路由）的自愈与清理离线测试
#
# 目的：验证服务异常退出（崩溃/重启）后残留的表、链、ip rule，
#       在下一次 pm_fw_up 时会被先清理再重建，pm_fw_down 能彻底清空。
#
# 做法：伪造 nft / iptables / ip 命令，用临时目录记录它们看到的状态。
#
# 运行：bash tests/test-firewall.sh   （输出同时写入 tests/out/test-firewall.log）

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tests/out"
CACHE="$ROOT/tests/.cache"
mkdir -p "$OUT" "$CACHE"
LOG="$OUT/test-firewall.log"
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

T="$CACHE/firewall-test"
PM_RUN_DIR="$T/var/etc/ferry"
NFT_STATE="$T/nft-state"
IPT_STATE="$T/ipt-state"
IP_STATE="$T/ip-state"

# ---------- 伪造 nft ----------
fake_nft() {
	mkdir -p "$T/bin"
	cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
state=${FAKE_NFT_STATE:?}
mkdir -p "$state"
case "$1" in
	-f)
		fam=$(awk '/^[[:space:]]*table /{print $2; exit}' "$2")
		name=$(awk '/^[[:space:]]*table /{print $3; exit}' "$2")
		mkdir -p "$state/$fam"
		: > "$state/$fam/$name"
		echo "load $fam $name" >> "$state/log"
		exit 0
		;;
	delete)
		# delete table <fam> <name>
		rm -f "$state/$3/$4"
		echo "delete $3 $4" >> "$state/log"
		exit 0
		;;
	list)
		for f in "$state"/*/*; do
			[ -f "$f" ] || continue
			fam=$(basename "$(dirname "$f")")
			name=$(basename "$f")
			echo "table $fam $name"
		done
		exit 0
		;;
esac
exit 1
EOF
	chmod +x "$T/bin/nft"
}

# ---------- 伪造 iptables（只跟踪 PREROUTING 跳转与链存在性） ----------
fake_iptables() {
	mkdir -p "$T/bin"
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
	chmod +x "$T/bin/iptables"
}

# ---------- 伪造 ip（策略路由） ----------
fake_ip() {
	mkdir -p "$T/bin"
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
	chmod +x "$T/bin/ip"
}

reset_case() {
	rm -rf "$PM_RUN_DIR" "$NFT_STATE" "$IPT_STATE" "$IP_STATE"
	mkdir -p "$PM_RUN_DIR" "$NFT_STATE" "$IPT_STATE" "$IP_STATE"
}

count_lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

log "== nft / iptables / 策略路由离线测试 =="
log "工作目录：$T"
fake_nft
fake_iptables
fake_ip
PATH="$T/bin:$PATH"
export PATH FAKE_NFT_STATE="$NFT_STATE" FAKE_IPT_STATE="$IPT_STATE" FAKE_IP_STATE="$IP_STATE"

# 离线环境（CI 容器/虚拟机）通常没加载 tproxy 相关内核模块；用伪造的模块列表验证
# 接管逻辑本身，模块缺失路径由真机覆盖，不能因此让用例静默跳过。
PM_MODULES_FILE="$T/proc-modules"
printf 'nft_tproxy 16384 0 - Live 0x0000000000000000\nxt_TPROXY 20480 0 - Live 0x0000000000000000\n' > "$PM_MODULES_FILE"
export PM_MODULES_FILE

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/ferry/common.sh"
# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/ferry/firewall.sh"

PM_ENABLED=1
PM_DEPLOY=router
PM_KERNEL=mihomo
PM_MODE=tproxy
PM_PROXY_PORT=7890
PM_DNS_PORT=1053
PM_LAN_IFACES="br-lan"
PM_MGMT_CIDRS=''
PM_BYPASS_CIDR=''
PM_BYPASS_IP=''
PM_ENABLE_IPV6=1
PM_BLOCK_QUIC=1
PM_HIJACK_DNS=1
PM_ROUTER_DNS=1
PM_FW_BACKEND=nft

# ---------- 用例 A：nft 后端 ----------
log ""
log "A. nft：崩溃残留的表在下次启动时被清理并重建"
reset_case
mkdir -p "$NFT_STATE/ip" "$NFT_STATE/ip6"
: > "$NFT_STATE/ip/ferry"
: > "$NFT_STATE/ip6/ferry6"
pm_fw_up
check "启动后 IPv4 表存在且只有一张" "1" "$(ls "$NFT_STATE/ip" 2>/dev/null | wc -l | tr -d ' ')"
check "IPv6 表按 enable_ipv6 建立" "1" "$(ls "$NFT_STATE/ip6" 2>/dev/null | wc -l | tr -d ' ')"
check "加载前先删除残留表" "yes" \
	"$(grep -q '^delete ip ferry$' "$NFT_STATE/log" && echo yes || echo no)"
check "nft 规则文件已生成" "yes" "$([ -f "$PM_RUN_DIR/ferry-v4.nft" ] && echo yes || echo no)"
check "nft 文件含 tproxy 链" "yes" "$(grep -q 'tproxy_prerouting' "$PM_RUN_DIR/ferry-v4.nft" && echo yes || echo no)"

pm_fw_up
check "重复 up 不会产生多余表" "1" "$(ls "$NFT_STATE/ip" | wc -l | tr -d ' ')"

pm_fw_down
check "down 后 IPv4 表清空" "0" "$(ls "$NFT_STATE/ip" 2>/dev/null | wc -l | tr -d ' ')"
check "down 后 IPv6 表清空" "0" "$(ls "$NFT_STATE/ip6" 2>/dev/null | wc -l | tr -d ' ')"
check "down 后生成文件被删除" "no" "$([ -f "$PM_RUN_DIR/ferry-v4.nft" ] && echo yes || echo no)"
check "down 后策略路由清空（v4）" "0" "$(count_lines "$IP_STATE/rule.4")"
check "down 后策略路由清空（v6）" "0" "$(count_lines "$IP_STATE/rule.6")"
check "down 后本地路由清空（v4）" "0" "$(count_lines "$IP_STATE/route.4")"

# ---------- 用例 B：iptables 后端 ----------
log ""
log "B. iptables：崩溃残留的 PREROUTING 跳转先被清掉，重复 up 不叠加"
reset_case
PM_FW_BACKEND=iptables
printf 'PM_DNS\n' > "$IPT_STATE/jumps.nat"
: > "$IPT_STATE/chain.nat.PM_DNS"
printf 'PM_TPROXY\n' > "$IPT_STATE/jumps.mangle"
: > "$IPT_STATE/chain.mangle.PM_TPROXY"

pm_fw_up
check "nat PREROUTING 跳转唯一" "1" "$(count_lines "$IPT_STATE/jumps.nat")"
check "mangle PREROUTING 跳转唯一" "1" "$(count_lines "$IPT_STATE/jumps.mangle")"

pm_fw_up
check "重复 up 后 nat 跳转仍唯一" "1" "$(count_lines "$IPT_STATE/jumps.nat")"
check "重复 up 后 mangle 跳转仍唯一" "1" "$(count_lines "$IPT_STATE/jumps.mangle")"

pm_fw_down
check "down 后 nat 跳转清空" "0" "$(count_lines "$IPT_STATE/jumps.nat")"
check "down 后 mangle 跳转清空" "0" "$(count_lines "$IPT_STATE/jumps.mangle")"
check "down 后策略路由清空" "0" "$(( $(count_lines "$IP_STATE/rule.4") + $(count_lines "$IP_STATE/route.4") ))"

# ---------- 用例 C：客户端形态不装规则 ----------
log ""
log "C. 客户端形态：不安装任何接管规则"
reset_case
PM_DEPLOY=client
PM_FW_BACKEND=nft
pm_fw_up
check "客户端形态没有 nft 表" "0" "$(ls "$NFT_STATE/ip" 2>/dev/null | wc -l | tr -d ' ')"
check "客户端形态没有策略路由" "0" "$(count_lines "$IP_STATE/rule.4")"

log ""
log "== 结果：PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
