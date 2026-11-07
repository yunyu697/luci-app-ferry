#!/bin/sh
# Ferry 应用事务：快照 -> pending -> 倒计时 -> 确认 / 自动还原
# 以及「临时关闭代理」状态。
#
# 设计原则：
#   1. pending 状态写在 /etc/ferry（持久化 overlay），断电重启后仍可判断；
#   2. 看门狗只做一件事：读 pending/deadline，到点调用 pt_rollback；
#   3. 还原只针对本事务写入的内容：ferry UCI、ferry nft 表、fwmark 策略路由、
#      dnsmasq 上游（由 stop/start 的既有备份机制回到原生值）、内核配置缓存与运行状态；
#      用户自建 nft 表 / iptables 链 / 路由表一律不碰；
#   4. 单飞：rollback 通过 mkdir 原子锁串行化，看门狗与 boot/服务重启同时触发也只还原一次。

PM_TXN_DIR=${PM_TXN_DIR:-$PM_CONF_DIR/txn}
PM_TXN_PENDING=$PM_TXN_DIR/pending
PM_TXN_LOCK=$PM_TXN_DIR/lock
PM_TXN_HISTORY=$PM_TXN_DIR/history.log
# 最后一次“用户确认保留”的 UCI 基线。LuCI/uci commit 会先写配置再触发 reload，
# 因此事务开始时的快照已经是新配置；还原必须回到上一份已确认的基线。
PM_TXN_BASELINE=$PM_TXN_DIR/baseline.uci

PM_TMP_OFF_DIR=${PM_TMP_OFF_DIR:-$PM_CONF_DIR/tmp-off}
PM_TMP_OFF_MARKER=$PM_TMP_OFF_DIR/active
PM_TXN_INIT=${PM_TXN_INIT:-/etc/init.d/ferry}

# 看门狗等独立入口可能只 source 了 common+transaction，按需补 firewall
if ! command -v pm_fw_down >/dev/null 2>&1; then
	[ -f "${FERRY_LIB_DIR:-/usr/lib/ferry}/firewall.sh" ] && \
		. "${FERRY_LIB_DIR:-/usr/lib/ferry}/firewall.sh"
fi

pt_now() { date +%s; }

pt_log() {
	if command -v logger >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		logger -t ferry -p "daemon.${2:-info}" "$1" 2>/dev/null
	fi
	[ "$PM_TXN_QUIET" = 1 ] || echo "[ferry-txn] $1"
	return 0
}

# 倒计时长度：UCI 可配 30-180，默认 60
pt_timeout() {
	local t
	if [ -n "${PM_TXN_TIMEOUT:-}" ]; then
		t=$PM_TXN_TIMEOUT
	else
		t=$(uci -q get ferry.main.rollback_timeout 2>/dev/null)
	fi
	case "$t" in
		''|*[!0-9]*) t=60 ;;
	esac
	[ "$t" -lt 30 ] && t=30
	[ "$t" -gt 180 ] && t=180
	echo "$t"
}

pt_meta_get() {
	local key="$1" file="${2:-$PM_TXN_PENDING/meta}"
	[ -f "$file" ] || return 0
	sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1
}

pt_pending_exists() { [ -f "$PM_TXN_PENDING/meta" ]; }

pt_tmp_off_active() { [ -f "$PM_TMP_OFF_MARKER" ]; }

# ---------------------------------------------------------------------------
# 快照
# ---------------------------------------------------------------------------

pt_snapshot_to() {
	local dir="$1"
	mkdir -p "$dir" || return 1

	uci -q export ferry > "$dir/ferry.uci" 2>/dev/null
	uci -q show 'dhcp.@dnsmasq[0]' > "$dir/dhcp.dnsmasq" 2>/dev/null

	command -v nft >/dev/null 2>&1 && nft list tables > "$dir/nft.tables" 2>/dev/null
	if command -v nft >/dev/null 2>&1; then
		nft list table ip "$PM_NFT_TABLE" > "$dir/nft-ferry4.dump" 2>/dev/null
		nft list table ip6 "$PM_NFT_TABLE6" > "$dir/nft-ferry6.dump" 2>/dev/null
	fi

	command -v ip >/dev/null 2>&1 && ip rule show > "$dir/ip.rule" 2>/dev/null
	command -v ip >/dev/null 2>&1 && ip route show table "$PM_IP_ROUTE_TABLE" > "$dir/ip.route100" 2>/dev/null
	command -v ip >/dev/null 2>&1 && ip -6 rule show > "$dir/ip6.rule" 2>/dev/null
	command -v ip >/dev/null 2>&1 && ip -6 route show table "$PM_IP_ROUTE_TABLE" > "$dir/ip6.route100" 2>/dev/null

	# 内核运行状态与配置缓存（还原时先放回旧配置，再按旧 UCI 重新生成）
	local bin
	bin=$(pm_kernel_bin)
	if pgrep -f "$bin" >/dev/null 2>&1; then
		echo 1 > "$dir/proc.running"
	else
		echo 0 > "$dir/proc.running"
	fi
	printf '%s\n' "$bin" > "$dir/proc.bin"

	[ -f "$PM_MIHOMO_DIR/config.yaml" ] && cp "$PM_MIHOMO_DIR/config.yaml" "$dir/mihomo-config.yaml" 2>/dev/null
	[ -f "$PM_SINGBOX_DIR/config.json" ] && cp "$PM_SINGBOX_DIR/config.json" "$dir/singbox-config.json" 2>/dev/null

	# 管理口网段（证据用，不参与还原）
	echo "${PM_MGMT_CIDRS:-}" > "$dir/mgmt.cidrs"
	return 0
}

pt_meta_write() {
	local phase="$1" deadline="$2" reason="$3" dir="${4:-$PM_TXN_PENDING}"
	local id started timeout
	id=$(pt_meta_get id "$dir/meta")
	[ -n "$id" ] || id="$(pt_now)-$$"
	started=$(pt_meta_get started "$dir/meta")
	[ -n "$started" ] || started=$(pt_now)
	timeout=$(pt_meta_get timeout "$dir/meta")
	[ -n "$timeout" ] || timeout=$(pt_timeout)
	{
		echo "id=$id"
		echo "started=$started"
		echo "timeout=$timeout"
		echo "phase=$phase"
		echo "deadline=$deadline"
		echo "reason=$reason"
	} > "$dir/meta.tmp" && mv "$dir/meta.tmp" "$dir/meta"
	return 0
}

# 开始事务：若已有未确认事务，沿用它的基线（回滚目标始终是第一次应用之前）
pt_begin() {
	local reason="${1:-apply}" timeout
	mkdir -p "$PM_TXN_DIR" "$PM_TXN_PENDING" || return 1
	timeout=$(pt_timeout)

	if [ -s "$PM_TXN_PENDING/ferry.uci" ] && [ -f "$PM_TXN_PENDING/meta" ]; then
		pt_meta_write applying 0 "$reason"
		pt_log "沿用未确认事务的基线，重新应用（reason=$reason）"
		return 0
	fi

	pt_snapshot_to "$PM_TXN_PENDING" || return 1
	# started 由 pt_meta_write 生成
	rm -f "$PM_TXN_PENDING/meta"
	{
		echo "id=$(pt_now)-$$"
		echo "started=$(pt_now)"
		echo "timeout=$timeout"
		echo "phase=applying"
		echo "deadline=0"
		echo "reason=$reason"
	} > "$PM_TXN_PENDING/meta"
	pt_log "事务开始：已写入快照（timeout=${timeout}s，reason=$reason）"
	return 0
}

# 应用成功 -> 进入 pending，开始倒计时
pt_arm() {
	pt_pending_exists || return 1
	pt_meta_write pending "$(($(pt_now) + $(pt_timeout)))" "${1:-apply}"
	pt_log "已进入待确认状态，$(pt_timeout) 秒后自动回滚"
	return 0
}

pt_confirm() {
	local dir id
	if ! pt_pending_exists; then
		echo '{"ok":true,"pending":false}'
		return 0
	fi
	id=$(pt_meta_get id)
	dir="$PM_TXN_DIR/confirmed-$id"
	rm -rf "$dir"
	mv "$PM_TXN_PENDING" "$dir" 2>/dev/null || rm -rf "$PM_TXN_PENDING"
	# 用户确认后，当前 UCI 即新的已确认基线
	pt_save_baseline
	{
		echo "id=$id"
		echo "confirmed_at=$(pt_now)"
	} > "$PM_TXN_DIR/last-confirmed" 2>/dev/null
	pt_log "用户确认保留本次配置（事务 $id）"
	echo '{"ok":true,"pending":false}'
	return 0
}

# ---------------------------------------------------------------------------
# 还原
# ---------------------------------------------------------------------------

pt_claim() {
	mkdir -p "$PM_TXN_DIR" 2>/dev/null
	if mkdir "$PM_TXN_LOCK" 2>/dev/null; then
		pt_now > "$PM_TXN_LOCK/ts"
		return 0
	fi
	# 锁超过 60 秒视为崩溃残留（正常还原远低于这个时间）
	local ts now
	ts=$(cat "$PM_TXN_LOCK/ts" 2>/dev/null)
	# ts 可能还没落盘（刚 mkdir 成功的进程正在写）：用锁目录 mtime 兜底。
	# 这里不能把缺失的 ts 当 0，否则并发时第二个进程会把刚建立的新锁当残留抢走，
	# 导致同一事务被回滚两次（历史重复、UCI 反复还原）。
	case "$ts" in ''|*[!0-9]*)
		ts=$(stat -c %Y "$PM_TXN_LOCK" 2>/dev/null)
		case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
		;;
	esac
	now=$(pt_now)
	if [ $((now - ts)) -gt 60 ]; then
		rm -rf "$PM_TXN_LOCK"
		mkdir "$PM_TXN_LOCK" 2>/dev/null || return 1
		echo "$now" > "$PM_TXN_LOCK/ts"
		return 0
	fi
	return 1
}

pt_release() { rm -rf "$PM_TXN_LOCK"; }

pt_restore_uci() {
	local f
	f="$PM_TXN_BASELINE"
	[ -s "$f" ] || f="$PM_TXN_PENDING/ferry.uci"
	[ -s "$f" ] || return 0
	# 优先用 uci import（uci export 的格式）；老版本 uci 没有 import 时直接落盘
	if uci -q import ferry < "$f" 2>/dev/null; then
		:
	else
		sed '/^package /d' "$f" > /etc/config/ferry.tmp && mv /etc/config/ferry.tmp /etc/config/ferry
	fi
	uci -q commit ferry 2>/dev/null
	pt_log "已还原 ferry UCI 基线"
	return 0
}

# 保存“当前已确认配置”作为后续回滚基线
pt_save_baseline() {
	mkdir -p "$PM_TXN_DIR" 2>/dev/null
	uci export ferry > "$PM_TXN_BASELINE.tmp" 2>/dev/null && \
		mv "$PM_TXN_BASELINE.tmp" "$PM_TXN_BASELINE"
	return 0
}

pt_restore_config_cache() {
	local dir="$PM_TXN_PENDING"
	mkdir -p "$PM_MIHOMO_DIR" "$PM_SINGBOX_DIR"
	if [ -f "$dir/mihomo-config.yaml" ]; then
		cp "$dir/mihomo-config.yaml" "$PM_MIHOMO_DIR/config.yaml" 2>/dev/null
	fi
	if [ -f "$dir/singbox-config.json" ]; then
		cp "$dir/singbox-config.json" "$PM_SINGBOX_DIR/config.json" 2>/dev/null
	fi
	return 0
}

# 运行期清场：只清 ferry 自己的表和策略路由；dnsmasq 交回原生上游
pt_teardown() {
	pm_fw_down
	pm_dnsmasq_restore
	# 旧内核进程若仍由本事务启动，停掉（procd 实例由 init stop 负责）
	local bin
	bin=$(pm_kernel_bin)
	if [ -n "$bin" ] && pgrep -f "$bin" >/dev/null 2>&1; then
		pm_log "还原时仍有内核进程（$bin），交由 init 服务停止"
	fi
	return 0
}

pt_evidence() {
	local id out
	id=$(pt_meta_get id)
	[ -n "$id" ] || id=$(pt_now)
	out="$PM_TXN_DIR/evidence-$id.txt"
	{
		echo "== rollback at $(date -u '+%Y-%m-%dT%H:%M:%SZ') =="
		echo "-- nft tables --"
		nft list tables 2>/dev/null || true
		echo "-- ip rule --"
		ip rule show 2>/dev/null || true
		echo "-- ip route table $PM_IP_ROUTE_TABLE --"
		ip route show table "$PM_IP_ROUTE_TABLE" 2>/dev/null || true
		echo "-- dnsmasq server --"
		uci -q get "$PM_DNSMASQ_SECTION.server" 2>/dev/null || true
		echo "-- dnsmasq noresolv --"
		uci -q get "$PM_DNSMASQ_SECTION.noresolv" 2>/dev/null || true
		echo "-- kernel pid --"
		pgrep -f "$(pm_kernel_bin)" 2>/dev/null || echo none
	} > "$out" 2>&1
	pt_log "回滚证据已写入 $out"
}

# $1=reason  $2=full|instart|boot
pt_rollback() {
	local reason="${1:-timeout}" mode="${2:-full}" id

	pt_pending_exists || return 0

	pt_claim || {
		pt_log "另一个还原流程正在进行，跳过（$reason）" warning
		return 0
	}

	if ! pt_pending_exists; then
		pt_release
		return 0
	fi

	id=$(pt_meta_get id)
	pt_meta_write rollingback 0 "$reason"
	pt_log "开始自动还原（reason=$reason mode=$mode id=$id）"

	case "$mode" in
		instart|boot)
			# 正在 start_service / 开机流程内：直接清场 + 还原 UCI，
			# 之后由调用方继续按还原后的配置启动。
			pt_teardown
			pt_restore_config_cache
			pt_restore_uci
			;;
		*)
			local was_running
			was_running=$(cat "$PM_TXN_PENDING/proc.running" 2>/dev/null)
			[ -n "$was_running" ] || was_running=1
			PM_TXN_SKIP=1 "$PM_TXN_INIT" stop >/dev/null 2>&1 || pt_teardown
			pt_restore_config_cache
			pt_restore_uci
			# 只还原到“应用前是否在运行”的状态：原本停着就不要擅自拉起
			if [ "$was_running" = 1 ] && [ "$(uci -q get ferry.main.enabled 2>/dev/null)" = 1 ]; then
				PM_TXN_SKIP=1 "$PM_TXN_INIT" start >/dev/null 2>&1
			fi
			;;
	esac

	pt_evidence
	{
		echo "id=$id reason=$reason mode=$mode at=$(pt_now)"
	} >> "$PM_TXN_HISTORY" 2>/dev/null

	rm -rf "$PM_TXN_PENDING"
	pt_release
	pt_log "自动还原完成（reason=$reason）"
	return 0
}

# 看门狗单步检查；由 watchdog.sh 每秒调用
pt_check() {
	local phase deadline started now
	pt_pending_exists || return 0
	phase=$(pt_meta_get phase)
	deadline=$(pt_meta_get deadline)
	started=$(pt_meta_get started)
	now=$(pt_now)

	case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
	case "$started" in ''|*[!0-9]*) started=$now ;; esac

	if [ "$phase" = rollingback ]; then
		# 上一次还原被 SIGKILL/断电打断：锁新鲜则视为进行中，锁残留则重试
		pt_rollback "rollback-retry" full
		return 0
	fi

	if [ "$phase" = applying ]; then
		# 应用中途进程被杀/断电：超过 120 秒仍未 arm，按崩溃还原
		if [ $((now - started)) -ge 120 ]; then
			pt_rollback "apply-crash" full
		fi
		return 0
	fi

	if [ "$deadline" -gt 0 ] && [ "$now" -ge "$deadline" ]; then
		pt_rollback "timeout" full
	fi
	return 0
}

pt_status_json() {
	local pending=false phase='' left=0 timeout id started deadline off=false since=0
	if pt_pending_exists; then
		pending=true
		phase=$(pt_meta_get phase)
		id=$(pt_meta_get id)
		started=$(pt_meta_get started)
		deadline=$(pt_meta_get deadline)
		timeout=$(pt_meta_get timeout)
		case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
		case "$started" in ''|*[!0-9]*) started=0 ;; esac
		left=$((deadline - $(pt_now)))
		[ "$left" -lt 0 ] && left=0
	fi
	if pt_tmp_off_active; then
		off=true
		since=$(sed -n 's/^since=//p' "$PM_TMP_OFF_DIR/meta" 2>/dev/null | head -n 1)
		case "$since" in ''|*[!0-9]*) since=0 ;; esac
	fi
	printf '{"ok":true,"pending":%s,"phase":"%s","secondsleft":%s,"timeout":%s,"id":"%s","started":%s,"deadline":%s,"tmp_off":%s,"tmp_off_since":%s}\n' \
		"$pending" "$phase" "$left" "${timeout:-0}" "$id" "${started:-0}" "${deadline:-0}" "$off" "$since"
	return 0
}

# ---------------------------------------------------------------------------
# 临时关闭 / 恢复
# ---------------------------------------------------------------------------

pt_tmp_disable() {
	# 有未确认事务先按超时回滚，避免“关闭”后又被看门狗拉回
	pt_pending_exists && pt_rollback "before-disable" full

	mkdir -p "$PM_TMP_OFF_DIR" || return 1
	pt_snapshot_to "$PM_TMP_OFF_DIR" || return 1
	{
		echo "since=$(pt_now)"
		echo "kernel=${PM_KERNEL:-}"
		echo "deploy=${PM_DEPLOY:-}"
	} > "$PM_TMP_OFF_DIR/meta"
	: > "$PM_TMP_OFF_MARKER"

	PM_TXN_SKIP=1 "$PM_TXN_INIT" stop >/dev/null 2>&1 || {
		pt_teardown
	}

	{
		echo "== temporary off at $(date -u '+%Y-%m-%dT%H:%M:%SZ') =="
		# nft 快照刚在 pt_snapshot_to 里抓过，这里直接引用，避免同一操作里重复 nft list
		echo "nft tables:"; cat "$PM_TMP_OFF_DIR/nft.tables" 2>/dev/null || true
		echo "ferry table:"; cat "$PM_TMP_OFF_DIR/nft-ferry4.dump" 2>/dev/null || echo none
		echo "ferry6 table:"; cat "$PM_TMP_OFF_DIR/nft-ferry6.dump" 2>/dev/null || echo none
		echo "ip rule:"; ip rule show 2>/dev/null || true
		echo "ip route table $PM_IP_ROUTE_TABLE:"; ip route show table "$PM_IP_ROUTE_TABLE" 2>/dev/null || true
		echo "dnsmasq server:"; uci -q get "$PM_DNSMASQ_SECTION.server" 2>/dev/null || true
		echo "dnsmasq noresolv:"; uci -q get "$PM_DNSMASQ_SECTION.noresolv" 2>/dev/null || true
		echo "kernel pid:"; pgrep -f "$(pm_kernel_bin)" 2>/dev/null || echo none
	} > "$PM_TMP_OFF_DIR/evidence.txt" 2>&1

	pt_log "已临时关闭：内核已停、接管规则已撤、dnsmasq 已回到原生上游"
	echo '{"ok":true,"disabled":true}'
	return 0
}

pt_tmp_enable() {
	if ! pt_tmp_off_active; then
		echo '{"ok":true,"disabled":false}'
		return 0
	fi
	rm -f "$PM_TMP_OFF_MARKER"
	PM_TXN_SKIP=1 "$PM_TXN_INIT" start >/dev/null 2>&1
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		pt_log "恢复失败（rc=$rc），接管规则可能未完全就绪，请查看状态与日志" err
		echo "{\"ok\":false,\"disabled\":false,\"rc\":$rc}"
		return 1
	fi
	{
		echo "== temporary restore at $(date -u '+%Y-%m-%dT%H:%M:%SZ') =="
		echo "nft tables:"; nft list tables 2>/dev/null || true
		echo "ip rule:"; ip rule show 2>/dev/null || true
		echo "dnsmasq server:"; uci -q get "$PM_DNSMASQ_SECTION.server" 2>/dev/null || true
		echo "kernel pid:"; pgrep -f "$(pm_kernel_bin)" 2>/dev/null || echo none
	} > "$PM_TMP_OFF_DIR/restore-evidence.txt" 2>&1
	pt_log "已恢复关闭前的接管形态"
	echo '{"ok":true,"disabled":false}'
	return 0
}
