#!/bin/bash
# 应用事务 / 回滚 / 临时关闭 的离线测试
#
# 做法：伪造 uci / nft / iptables / ip / pgrep / logger / init 脚本，
#       在临时目录里模拟“应用前基线 -> 应用 -> 超时/崩溃 -> 还原”。
#
# 运行：bash tests/test-transaction.sh（输出同时写入 tests/out/test-transaction.log）

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tests/out"
CACHE="$ROOT/tests/.cache"
mkdir -p "$OUT" "$CACHE"
LOG="$OUT/test-transaction.log"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); log "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); log "  FAIL  $*"; }
check() {
	if [ "$2" = "$3" ]; then pass "$1"; else
		fail "$1"; log "        期望=[$2]"; log "        实际=[$3]"
	fi
}
check_file() { if [ -e "$2" ]; then pass "$1"; else fail "$1（缺少 $2）"; fi }
check_no_file() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1（不应存在 $2）"; fi }
contains() { if grep -q -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1（$3 中未找到 $2）"; fi }
not_contains() { if ! grep -q -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1（$3 中仍含 $2）"; fi }

T="$CACHE/txn-test"
rm -rf "$T"
mkdir -p "$T/bin" "$T/etc/ferry" "$T/var/etc/ferry" "$T/etc/mihomo" "$T/etc/sing-box" "$T/etc/config"

export PATH="$T/bin:$PATH"
export PM_CONF_DIR="$T/etc/ferry"
export PM_RUN_DIR="$T/var/etc/ferry"
export PM_MIHOMO_DIR="$T/etc/mihomo"
export PM_SINGBOX_DIR="$T/etc/sing-box"
export PM_DHCP_FILE="$T/etc/config/dhcp"
export PM_DNSMASQ_INIT="$T/fake-dnsmasq-init"
export PM_FUNCTIONS_SH="$T/functions.sh"
export PM_KERNEL=mihomo
export PM_ENABLED=1
export PM_MODE=tproxy
export PM_DEPLOY=nft
export PM_LAN_IFACE=br-lan
export PM_LAN_IFACES=br-lan
export PM_MGMT_CIDRS='192.168.1.0/24 192.168.1.1/32'
export PM_TXN_INIT="$T/fake-init"
export PM_TXN_QUIET=1
export FAKE_UCI_STATE="$T/state/uci"
export FAKE_NFT_STATE="$T/state/nft"
export FAKE_IP_STATE="$T/state/ip"
export FAKE_INIT_LOG="$T/state/init.log"
export FAKE_PROC_RUNNING="$T/state/kernel.running"
export FERRY_LIB_DIR="$ROOT/files/usr/lib/ferry"

. "$ROOT/files/usr/lib/ferry/common.sh"
. "$ROOT/files/usr/lib/ferry/transaction.sh"

# ---------- 伪造命令 --------------------------------------------------------
cat > "$T/functions.sh" <<'EOF'
config_load() { :; }
config_get() { :; }
config_foreach() { :; }
EOF

cat > "$T/fake-init" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_INIT_LOG"
case "$1" in
	stop)
		. "$FERRY_LIB_DIR/common.sh"
		. "$FERRY_LIB_DIR/firewall.sh"
		pm_fw_down
		pm_dnsmasq_restore
		;;
esac
exit 0
EOF
chmod +x "$T/fake-init"

cat > "$T/fake-dnsmasq-init" <<'EOF'
#!/bin/sh
echo "dnsmasq $*" >> "$FAKE_INIT_LOG"
EOF
chmod +x "$T/fake-dnsmasq-init"

cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
EOF
chmod +x "$T/bin/logger"

cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
# 由 $FAKE_PROC_RUNNING 控制“内核是否在运行”，供还原运行状态断言使用
[ -f "${FAKE_PROC_RUNNING:-/nonexistent}" ] && exit 0
exit 1
EOF
chmod +x "$T/bin/pgrep"

cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
S=${FAKE_UCI_STATE:?}
mkdir -p "$S"
F="$S/ferry.conf"
[ -f "$F" ] || : > "$F"
[ -f "$S/dhcp_server" ] || : > "$S/dhcp_server"
[ -f "$S/dhcp_noresolv" ] || echo 0 > "$S/dhcp_noresolv"
[ "$1" = "-q" ] && shift
cmd=$1; shift
case "$cmd" in
	export)
		[ "$1" = ferry ] && { cat "$F"; exit 0; }
		exit 1 ;;
	show)
		[ "$1" = 'dhcp.@dnsmasq[0]' ] || exit 1
		while IFS= read -r l; do
			[ -n "$l" ] && echo "dhcp.@dnsmasq[0].server='$l'"
		done < "$S/dhcp_server"
		echo "dhcp.@dnsmasq[0].noresolv='$(cat "$S/dhcp_noresolv")'"
		exit 0 ;;
	get)
		case "$1" in
			ferry.main.rollback_timeout)
				sed -n "s/^[[:space:]]*option rollback_timeout '\(.*\)'/\1/p" "$F" | head -n 1 ;;
			ferry.main.enabled)
				sed -n "s/^[[:space:]]*option enabled '\(.*\)'/\1/p" "$F" | head -n 1 ;;
			network.lan.device) echo br-lan ;;
			'dhcp.@dnsmasq[0]') echo ok ;;
			'dhcp.@dnsmasq[0].server') [ -s "$S/dhcp_server" ] && cat "$S/dhcp_server" || exit 1 ;;
			'dhcp.@dnsmasq[0].noresolv') cat "$S/dhcp_noresolv" ;;
			*) exit 1 ;;
		esac
		exit 0 ;;
	import)
		cat > "$F"
		echo "import ferry" >> "$S/log"
		exit 0 ;;
	delete)
		case "$1" in
			'dhcp.@dnsmasq[0].server') : > "$S/dhcp_server" ;;
			'dhcp.@dnsmasq[0].noresolv') : > "$S/dhcp_noresolv" ;;
		esac
		exit 0 ;;
	add_list)
		case "$1" in
			'dhcp.@dnsmasq[0].server='*) echo "${1#*=}" >> "$S/dhcp_server" ;;
			'dhcp.@dnsmasq[0].noresolv='*) echo "${1#*=}" > "$S/dhcp_noresolv" ;;
		esac
		exit 0 ;;
	set)
		case "$1" in
			'dhcp.@dnsmasq[0].noresolv='*) echo "${1#*=}" > "$S/dhcp_noresolv" ;;
		esac
		exit 0 ;;
	commit)
		echo "commit $*" >> "$S/log"
		exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/bin/uci"

cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
S=${FAKE_NFT_STATE:?}
mkdir -p "$S"
case "$1" in
	list)
		if [ "$2" = tables ]; then
			for f in "$S"/*/*; do
				[ -f "$f" ] || continue
				echo "table $(basename "$(dirname "$f")") $(basename "$f")"
			done
			exit 0
		fi
		if [ "$2" = table ]; then
			f="$S/$3/$4"
			[ -f "$f" ] || exit 1
			cat "$f"
			exit 0
		fi
		exit 1 ;;
	delete)
		rm -f "$S/$3/$4"
		echo "delete $3 $4" >> "$S/log"
		exit 0 ;;
	-f)
		fam=$(awk '/^[[:space:]]*table /{print $2; exit}' "$2")
		name=$(awk '/^[[:space:]]*table /{print $3; exit}' "$2")
		mkdir -p "$S/$fam"
		cp "$2" "$S/$fam/$name"
		exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/bin/nft"

cat > "$T/bin/iptables" <<'EOF'
#!/bin/sh
S=${FAKE_IP_STATE:?}
mkdir -p "$S"
echo "iptables $*" >> "$S/log"
exit 0
EOF
chmod +x "$T/bin/iptables"

cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
S=${FAKE_IP_STATE:?}
mkdir -p "$S"
[ -f "$S/rule" ] || echo '1:	from all fwmark 0x1 lookup 100' > "$S/rule"
[ -f "$S/route" ] || echo 'local default dev lo scope host' > "$S/route"
[ -f "$S/rule6" ] || : > "$S/rule6"
[ -f "$S/route6" ] || : > "$S/route6"
fam4=1
[ "$1" = "-6" ] && { fam4=0; shift; }
[ "$1" = "-4" ] && shift
[ "$1" = "-o" ] && shift
cmd=$1; shift
case "$cmd" in
	rule)
		sub=$1; shift
		case "$sub" in
			show) [ "$fam4" = 1 ] && cat "$S/rule" || cat "$S/rule6" ;;
			del|add)
				line="$*"
				if [ "$fam4" = 1 ]; then f="$S/rule"; else f="$S/rule6"; fi
				if [ "$sub" = del ]; then
					grep -v "fwmark" "$f" > "$f.new" 2>/dev/null || : > "$f.new"
					mv "$f.new" "$f"
					echo "rule del $line" >> "$S/log"
				else
					echo "$line" >> "$f"
				fi
				;;
		esac ;;
	route)
		sub=$1; shift
		[ "$1" = show ] && {
			[ "$fam4" = 1 ] && cat "$S/route" || cat "$S/route6"
			exit 0
		}
		echo "route $sub $*" >> "$S/log" ;;
	addr)
		if [ "$1" = show ]; then
			if [ "$fam4" = 1 ]; then
				echo "2: br-lan    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan"
			else
				echo "2: br-lan    inet6 2001:db8::1/64 scope global"
			fi
		else
			exit 1
		fi ;;
esac
exit 0
EOF
chmod +x "$T/bin/ip"

# ---------- 基线数据 --------------------------------------------------------
U="$T/state/uci"
mkdir -p "$U" "$T/state/nft/ip"
cat > "$U/ferry.conf" <<'EOF'
package ferry

config main 'main'
	option enabled '1'
	option rollback_timeout '60'
	option baseline_marker 'old'
EOF
echo '127.0.0.1#1053' > "$U/dhcp_server"
echo '1' > "$U/dhcp_noresolv"
mkdir -p "$PM_CONF_DIR/dnsmasq-backup"
echo '223.5.5.5' > "$PM_CONF_DIR/dnsmasq-backup/server"
echo '1' > "$PM_CONF_DIR/dnsmasq-backup/noresolv"
: > "$T/etc/config/dhcp"
: > "$FAKE_INIT_LOG"

simulate_apply() {
	# 模拟应用成功后的现场：新 UCI、新 nft 表、fwmark 策略路由
	cat > "$U/ferry.conf" <<'EOF'
package ferry

config main 'main'
	option enabled '1'
	option rollback_timeout '60'
	option baseline_marker 'new'
EOF
	mkdir -p "$T/state/nft/ip"
	echo 'table ip ferry { chain tproxy_prerouting { } }' > "$T/state/nft/ip/ferry"
	echo '127.0.0.1#1053' > "$U/dhcp_server"
	: > "$FAKE_INIT_LOG"
}

restore_baseline() {
	# 每个场景前回到“应用前”的干净基线
	rm -rf "$PM_TXN_DIR" "$PM_TMP_OFF_DIR"
	rm -rf "$T/state/nft"; mkdir -p "$T/state/nft"
	mkdir -p "$T/state/ip"
	# 基线：服务处于运行状态（回滚应恢复到“运行中”）
	: > "$FAKE_PROC_RUNNING"
	: > "$T/state/ip/rule"; : > "$T/state/ip/route"
	cat > "$U/ferry.conf" <<'EOF'
package ferry

config main 'main'
	option enabled '1'
	option rollback_timeout '60'
	option baseline_marker 'old'
EOF
	echo '127.0.0.1#1053' > "$U/dhcp_server"
	echo '1' > "$U/dhcp_noresolv"
	mkdir -p "$PM_CONF_DIR/dnsmasq-backup"
	echo '223.5.5.5' > "$PM_CONF_DIR/dnsmasq-backup/server"
	echo '1' > "$PM_CONF_DIR/dnsmasq-backup/noresolv"
	: > "$FAKE_INIT_LOG"
	# 生产路径里，基线是在上一次“确认保留”后落盘的
	pt_save_baseline >/dev/null 2>&1 || true
}

# ===========================================================================
log "== 1. 快照与 pending 状态 =="
restore_baseline
pt_begin apply
check_file "快照 ferry.uci 已写入" "$PM_TXN_PENDING/ferry.uci"
check_file "快照 nft.tables 已写入" "$PM_TXN_PENDING/nft.tables"
check "phase=applying" applying "$(pt_meta_get phase)"
check "未确认时 pending 存在" true "$(pt_pending_exists && echo true || echo false)"
check "timeout 读取 UCI（60）" 60 "$(pt_meta_get timeout)"

log "== 2. 正常应用 -> arm -> confirm =="
simulate_apply
: > "$T/state/ip/rule"; echo '1:	from all fwmark 0x1 lookup 100' > "$T/state/ip/rule"
pt_arm apply
left=$(pt_meta_get deadline)
now=$(pt_now)
check "deadline 约为 now+60" true "$([ $((left - now)) -ge 58 ] && [ $((left - now)) -le 61 ] && echo true || echo false)"
pt_confirm >/dev/null
check "确认后 pending 清除" false "$(pt_pending_exists && echo true || echo false)"
check_file "确认记录 last-confirmed" "$PM_TXN_DIR/last-confirmed"
pt_check
check "确认后看门狗不再回滚" 0 "$(cat "$PM_TXN_HISTORY" 2>/dev/null | wc -l | tr -d ' ')"
check "确认后新配置仍在" new "$(sed -n "s/.*baseline_marker '\(.*\)'.*/\1/p" "$U/ferry.conf")"

log "== 3. 超时自动还原（nft / ip rule / dnsmasq / UCI） =="
restore_baseline
pt_begin apply
simulate_apply
: > "$T/state/ip/rule"; echo '1:	from all fwmark 0x1 lookup 100' > "$T/state/ip/rule"
mkdir -p "$T/state/nft/ip"; echo 'table ip ferry { }' > "$T/state/nft/ip/ferry"
pt_arm apply
# 把 deadline 拨到过去，模拟 60 秒到期
sed -i "s/^deadline=.*/deadline=$(( $(pt_now) - 1 ))/" "$PM_TXN_PENDING/meta"
pt_check
check "超时后 pending 清除" false "$(pt_pending_exists && echo true || echo false)"
check "UCI 还原到基线" old "$(sed -n "s/.*baseline_marker '\(.*\)'.*/\1/p" "$U/ferry.conf")"
check_no_file "ferry nft 表被删除" "$T/state/nft/ip/ferry"
not_contains "fwmark 策略路由已撤销" "fwmark" "$T/state/ip/rule"
contains "dnsmasq 回到原生上游" "223.5.5.5" "$U/dhcp_server"
not_contains "dnsmasq 不再指向本机内核" "127.0.0.1" "$U/dhcp_server"
contains "回滚后执行了 init stop/start" "stop" "$FAKE_INIT_LOG"
contains "回滚后执行了 init start" "start" "$FAKE_INIT_LOG"
check_file "回滚证据文件" "$(ls "$PM_TXN_DIR"/evidence-*.txt 2>/dev/null | head -n 1)"
check_file "历史记录" "$PM_TXN_HISTORY"
contains "历史原因=timeout" "reason=timeout" "$PM_TXN_HISTORY"

log "== 4. 崩溃路径 A：应用中途被杀（phase=applying 超 120s） =="
restore_baseline
pt_begin apply
simulate_apply
mkdir -p "$T/state/nft/ip"; echo 'table ip ferry { }' > "$T/state/nft/ip/ferry"
sed -i "s/^started=.*/started=$(( $(pt_now) - 200 ))/" "$PM_TXN_PENDING/meta"
pt_check
check "apply-crash 自动还原" false "$(pt_pending_exists && echo true || echo false)"
check "UCI 还原到基线" old "$(sed -n "s/.*baseline_marker '\(.*\)'.*/\1/p" "$U/ferry.conf")"
check_no_file "apply-crash 后 ferry 表删除" "$T/state/nft/ip/ferry"
contains "历史原因=apply-crash" "reason=apply-crash" "$PM_TXN_HISTORY"

log "== 5. 崩溃路径 B：无控制面（浏览器/SSH 关闭）由看门狗回滚 =="
restore_baseline
pt_begin apply
simulate_apply
pt_arm apply
mkdir -p "$T/state/nft/ip"; echo 'table ip ferry { }' > "$T/state/nft/ip/ferry"
# 把 deadline 拨到过去后独立启动看门狗；没有 LuCI/SSH，只有 procd 会拉起的这个进程
sed -i "s/^deadline=.*/deadline=$(( $(pt_now) - 1 ))/" "$PM_TXN_PENDING/meta"
"$ROOT/files/usr/lib/ferry/watchdog.sh" >/dev/null 2>&1 &
WD=$!
i=0
while [ "$i" -lt 20 ] && pt_pending_exists; do
	sleep 1
	i=$((i + 1))
done
kill -9 "$WD" 2>/dev/null
wait "$WD" 2>/dev/null
check "独立看门狗完成回滚" false "$(pt_pending_exists && echo true || echo false)"
check "看门狗回滚后 UCI=基线" old "$(sed -n "s/.*baseline_marker '\(.*\)'.*/\1/p" "$U/ferry.conf")"
check_no_file "看门狗回滚后 ferry 表删除" "$T/state/nft/ip/ferry"

log "== 6. 崩溃路径 C：看门狗被杀 / 重启 -> 服务启动检测 pending =="
restore_baseline
pt_begin apply
simulate_apply
pt_arm apply
sed -i "s/^deadline=.*/deadline=$(( $(pt_now) - 1 ))/" "$PM_TXN_PENDING/meta"
# 模拟下一次开机/服务重启的启动分支：init 的 start_service 检测到 pending
pt_rollback "startup-detect" instart
check "启动检测还原成功" false "$(pt_pending_exists && echo true || echo false)"
check "启动检测后 UCI=基线" old "$(sed -n "s/.*baseline_marker '\(.*\)'.*/\1/p" "$U/ferry.conf")"
contains "历史原因=startup-detect" "reason=startup-detect" "$PM_TXN_HISTORY"
contains "init 启动分支包含 pending 检测" 'pt_rollback "startup-detect" instart' "$ROOT/files/etc/init.d/ferry"
contains "看门狗由 procd 托管并 respawn" 'procd_set_param respawn' "$ROOT/files/etc/init.d/ferry-watchdog"
contains "看门狗开机自启" 'ferry-watchdog enable' "$ROOT/files/etc/uci-defaults/50-ferry"

log "== 7. 并发回滚只执行一次 =="
restore_baseline
pt_begin apply
simulate_apply
mkdir -p "$T/state/nft/ip"; echo 'table ip ferry { }' > "$T/state/nft/ip/ferry"
pt_arm apply
sed -i "s/^deadline=.*/deadline=$(( $(pt_now) - 1 ))/" "$PM_TXN_PENDING/meta"
pt_rollback "concurrent-a" full >/dev/null 2>&1 &
A=$!
pt_rollback "concurrent-b" full >/dev/null 2>&1 &
B=$!
wait "$A" "$B"
check "并发回滚后 pending 清除" false "$(pt_pending_exists && echo true || echo false)"
check "历史只增加一条并发回滚" 1 "$(grep -c 'reason=concurrent' "$PM_TXN_HISTORY" 2>/dev/null | tr -d ' ')"
check_no_file "并发回滚后 ferry 表删除" "$T/state/nft/ip/ferry"

log "== 8. 临时关闭 -> 恢复 =="
restore_baseline
mkdir -p "$T/state/nft/ip"; echo 'table ip ferry { }' > "$T/state/nft/ip/ferry"
echo '127.0.0.1#1053' > "$U/dhcp_server"
pt_tmp_disable >/dev/null
check "临时关闭标记存在" true "$(pt_tmp_off_active && echo true || echo false)"
check_no_file "关闭后 ferry nft 表删除" "$T/state/nft/ip/ferry"
not_contains "关闭后 fwmark 规则撤销" "fwmark" "$T/state/ip/rule"
contains "关闭后 dnsmasq=原生上游" "223.5.5.5" "$U/dhcp_server"
not_contains "关闭后不再指向内核" "127.0.0.1" "$U/dhcp_server"
check_file "关闭证据文件" "$PM_TMP_OFF_DIR/evidence.txt"
contains "关闭时执行 init stop" "stop" "$FAKE_INIT_LOG"
pt_tmp_enable >/dev/null
check "恢复后临时标记清除" false "$(pt_tmp_off_active && echo true || echo false)"
contains "恢复时执行 init start" "start" "$FAKE_INIT_LOG"
check_file "恢复证据文件" "$PM_TMP_OFF_DIR/restore-evidence.txt"

log "== 9. 状态 JSON =="
restore_baseline
pt_begin apply
pt_arm apply
json=$(pt_status_json)
echo "        $json"
echo "$json" | grep -q '"pending":true' && pass "状态含 pending:true" || fail "状态 JSON pending 字段"
echo "$json" | grep -q '"secondsleft"' && pass "状态含倒计时" || fail "状态 JSON 倒计时字段"

# ===========================================================================
log ""
log "================ 结果 ================"
log "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	log "ALL PASS"
	exit 0
fi
exit 1
