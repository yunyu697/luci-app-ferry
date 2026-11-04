#!/bin/bash
# dnsmasq 上游备份/恢复的可重复离线测试
#
# 目的：验证 /var/etc（tmpfs）被清空（模拟重启）之后，
#       pm_dnsmasq_apply / pm_dnsmasq_restore 不会把本工具改写的值当成“原始上游”。
#
# 做法：伪造 uci（状态目录实现 get/delete/add_list/set/commit）与 dnsmasq init 脚本，
#       把 PM_CONF_DIR / PM_RUN_DIR / PM_DHCP_FILE / PM_DNSMASQ_INIT 指向临时目录。
#
# 运行：bash tests/test-dnsmasq.sh   （输出同时写入 tests/out/test-dnsmasq.log）

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tests/out"
CACHE="$ROOT/tests/.cache"
mkdir -p "$OUT" "$CACHE"
LOG="$OUT/test-dnsmasq.log"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); log "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); log "  FAIL  $*"; }

# 断言：描述 / 期望 / 实际
check() {
	if [ "$2" = "$3" ]; then
		pass "$1"
	else
		fail "$1"
		log "        期望=[$2]"
		log "        实际=[$3]"
	fi
}

# 断言文件内容（多行，末尾换行忽略）
check_file() {
	local desc="$1" want="$2" file="$3" got
	if [ -f "$file" ]; then got=$(cat "$file"); else got='<文件不存在>'; fi
	check "$desc" "$want" "$got"
}

T="$CACHE/dnsmasq-test"
STATE="$T/state"
PM_CONF_DIR="$T/etc/ferry"
PM_RUN_DIR="$T/var/etc/ferry"
PM_DHCP_FILE="$T/etc/config/dhcp"
PM_DNSMASQ_INIT="$T/init.d/dnsmasq"
RELOAD_LOG="$T/dnsmasq-reload.log"

# ---------- 伪造 uci ----------
fake_uci() {
	mkdir -p "$T/bin"
	cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
# 测试用最小 uci：只支持 dhcp.@dnsmasq[0] 的 server / noresolv
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
			dhcp.@dnsmasq\[0\].server=*)
				printf '%s\n' "${key#*=}" >> "$state/server" ;;
			*) exit 1 ;;
		esac
		exit 0 ;;
	set)
		case "$key" in
			"dhcp.@dnsmasq[0].noresolv="*) printf '%s\n' "${key#*=}" > "$state/noresolv" ;;
			*) exit 1 ;;
		esac
		exit 0 ;;
	show)
		case "$key" in
			"dhcp.@dnsmasq[0].server")
				[ -f "$state/section" ] || exit 1
				if [ -f "$state/server" ]; then
					while IFS= read -r line; do
						printf "dhcp.@dnsmasq[0].server='%s'\n" "$line"
					done < "$state/server"
				fi
				exit 0 ;;
			"dhcp.@dnsmasq[0].noresolv")
				[ -f "$state/section" ] || exit 1
				[ -f "$state/noresolv" ] && printf "dhcp.@dnsmasq[0].noresolv='%s'\n" "$(cat "$state/noresolv")"
				exit 0 ;;
		esac
		exit 1 ;;
	commit)
		exit 0 ;;
esac
exit 1
EOF
	chmod +x "$T/bin/uci"
}

fake_init() {
	mkdir -p "$(dirname "$PM_DNSMASQ_INIT")"
	cat > "$PM_DNSMASQ_INIT" <<EOF
#!/bin/sh
echo "\$1" >> "$RELOAD_LOG"
EOF
	chmod +x "$PM_DNSMASQ_INIT"
}

reset_case() {
	rm -rf "$STATE" "$PM_CONF_DIR" "$PM_RUN_DIR" "$(dirname "$PM_DHCP_FILE")" "$RELOAD_LOG"
	mkdir -p "$STATE" "$PM_CONF_DIR" "$PM_RUN_DIR" "$(dirname "$PM_DHCP_FILE")"
	: > "$PM_DHCP_FILE"
	: > "$STATE/section"
	: > "$RELOAD_LOG"
}

# 模拟重启：/var 是 tmpfs，重启后内容清空
reboot_sim() { rm -rf "$PM_RUN_DIR"; }

set_server() {
	if [ $# -eq 0 ]; then rm -f "$STATE/server"; else printf '%s\n' "$@" > "$STATE/server"; fi
}
current_server() { [ -f "$STATE/server" ] && cat "$STATE/server"; }
current_noresolv() { if [ -f "$STATE/noresolv" ]; then cat "$STATE/noresolv"; else echo '<未设置>'; fi; }

BAK="$PM_CONF_DIR/dnsmasq-backup"

# ---------- 初始化 ----------
log "== dnsmasq 备份/恢复离线测试 =="
log "工作目录：$T"
fake_uci
fake_init
PATH="$T/bin:$PATH"
export PATH FAKE_UCI_STATE="$STATE"

# 加载被测代码
# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/ferry/common.sh"

PM_ENABLED=1
PM_DEPLOY=router
PM_KERNEL=mihomo
PM_MODE=tproxy
PM_ROUTER_DNS=1
PM_DNS_PORT=1053
PM_PROXY_PORT=7890

# ---------- 用例 A：原有上游 → 启用 → 重启 → 停用 ----------
log ""
log "A. 原始上游 223.5.5.5 / 8.8.8.8，启用后模拟重启再停用"
reset_case
set_server 223.5.5.5 8.8.8.8
pm_dnsmasq_apply
check "启用后上游指向内核" "127.0.0.1#1053" "$(current_server)"
check "启用后 noresolv=1" "1" "$(current_noresolv)"
check "备份记录了原始两个上游" "223.5.5.5
8.8.8.8" "$(cat "$BAK/server")"
check "备份目录在持久化目录下" "yes" "$([ "$BAK" = "$PM_CONF_DIR/dnsmasq-backup" ] && echo yes || echo no)"

reboot_sim
pm_dnsmasq_apply
check "重启后备份未被自身值污染" "223.5.5.5
8.8.8.8" "$(cat "$BAK/server")"

pm_dnsmasq_restore
check "停用后恢复真正的原始上游" "223.5.5.5
8.8.8.8" "$(current_server)"
check "停用后 noresolv 被删除" "<未设置>" "$(current_noresolv)"
check "恢复成功后删除 server 备份" "<文件不存在>" "$(cat "$BAK/server" 2>/dev/null || echo '<文件不存在>')"

# ---------- 用例 B：原本没有上游 ----------
log ""
log "B. 原本没有 server，启用 → 重启 → 停用"
reset_case
set_server
pm_dnsmasq_apply
check "启用后上游指向内核（B）" "127.0.0.1#1053" "$(current_server)"
check "空原始值也留下备份标记" "" "$(cat "$BAK/server" 2>/dev/null)"
reboot_sim
pm_dnsmasq_apply
check "重启后备份仍为空（未记录自身值）" "" "$(cat "$BAK/server" 2>/dev/null)"
pm_dnsmasq_restore
check "停用后上游为空（B）" "" "$(current_server)"
check "停用后 noresolv 被删除（B）" "<未设置>" "$(current_noresolv)"

# ---------- 用例 C：备份文件损坏 ----------
log ""
log "C. 备份内容无法识别：只告警，不覆盖现有配置"
reset_case
set_server 127.0.0.1#1053
mkdir -p "$BAK"
printf 'not a valid server line\n\x01\x02binary\n' > "$BAK/server"
: > "$BAK/noresolv"
pm_dnsmasq_restore
check "损坏备份不改动现有上游" "127.0.0.1#1053" "$(current_server)"
check "损坏备份保留待人工检查" "yes" "$([ -f "$BAK/server" ] && echo yes || echo no)"

# ---------- 用例 D：旧版 /var 备份迁移 ----------
log ""
log "D. 旧版本 /var 备份迁移到持久化目录"
reset_case
set_server 127.0.0.1#1053
mkdir -p "$PM_RUN_DIR"
printf '223.5.5.5\n' > "$PM_RUN_DIR/dnsmasq.server.bak"
printf '0\n' > "$PM_RUN_DIR/dnsmasq.noresolv.bak"
pm_dnsmasq_apply
check "旧备份已迁移" "223.5.5.5" "$(cat "$BAK/server" 2>/dev/null)"
check "旧 noresolv 已迁移" "0" "$(cat "$BAK/noresolv" 2>/dev/null)"
check "旧 /var 备份已清理" "no" "$([ -f "$PM_RUN_DIR/dnsmasq.server.bak" ] && echo yes || echo no)"
reboot_sim
pm_dnsmasq_apply
pm_dnsmasq_restore
check "迁移后停用恢复原始上游" "223.5.5.5" "$(current_server)"
check "迁移后停用恢复 noresolv=0" "0" "$(current_noresolv)"

# ---------- 用例 E：备份只含自身值（旧缺陷产物） ----------
log ""
log "E. 备份里只有本工具写入值：停用时应还原为空而不是写回 127.0.0.1#1053"
reset_case
set_server 127.0.0.1#1053
mkdir -p "$BAK"
printf '127.0.0.1#1053\n' > "$BAK/server"
pm_dnsmasq_restore
check "自身值被过滤，上游清空" "" "$(current_server)"
check "noresolv 恢复为未设置" "<未设置>" "$(current_noresolv)"

# ---------- 用例 F：启用期间用户手工改过 dnsmasq ----------
log ""
log "F. 启用期间用户手工把上游改回干净值：下次启用以用户值为新的原始值"
reset_case
set_server 223.5.5.5
pm_dnsmasq_apply
set_server 1.1.1.1
pm_dnsmasq_apply
check "干净配置刷新备份" "1.1.1.1" "$(cat "$BAK/server" 2>/dev/null)"
pm_dnsmasq_restore
check "停用恢复到用户手工设置的值" "1.1.1.1" "$(current_server)"

# ---------- 用例 G：并发/重复 start 幂等 ----------
log ""
log "G. 连续两次 enable 不改变备份"
reset_case
set_server 223.5.5.5
pm_dnsmasq_apply
pm_dnsmasq_apply
check "重复启用备份仍为原始值" "223.5.5.5" "$(cat "$BAK/server" 2>/dev/null)"
check "dnsmasq reload 被调用" "yes" "$([ -s "$RELOAD_LOG" ] && echo yes || echo no)"

log ""
log "== 结果：PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
