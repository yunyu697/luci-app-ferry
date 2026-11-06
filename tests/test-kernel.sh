#!/bin/bash
# 离线回归：内核管理（下载/校验/安装/切换/回滚/卸载 + 失败路径）
# 运行环境：WSL/Linux + bash + python3 + curl/wget + tar/gzip + sha256sum
# 下载源：本机 127.0.0.1 的 python3 http.server（mock 官方 Release），二进制用真实 sing-box/mihomo 包
# 不依赖外网；不触碰宿主生产环境

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/files/usr/lib/ferry"
KSRC="${KSRC:-/mnt/d/Users/Tyler Zhang/Documents/Trae-CN/temp_20261104_07/qemu/kernels}"
# 夹具目录不能放 /tmp、/var（内核目录在内存盘会被拒装，这是 r8 的保护逻辑）
TEST_ROOT=${FERRY_TEST_ROOT:-${HOME:-/home/$(id -un)}}
mkdir -p "$TEST_ROOT" 2>/dev/null
T=$(mktemp -d "$TEST_ROOT/ferry-kernel-test.XXXXXX") || exit 1
PORT=18080
FAILED=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=$((FAILED + 1)); }
note() { echo "  - $*"; }

cleanup() {
	[ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null
	[ -n "${MIRROR_PID:-}" ] && kill "$MIRROR_PID" 2>/dev/null
	# mock 服务会拉起真实内核进程，退出时一并清理
	[ -f "${T:-}/svc.state" ] && kill "$(cat "$T/svc.state")" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT

# ---------- 夹具 ----------
mkdir -p "$T"/{store,run,bin,jail,etc/mihomo,etc/sing-box,etc/ferry,uci-state,fake,www}

cat > "$T/fake/uci" <<'EOF'
#!/bin/sh
D=$(dirname "$0")/../uci-state
[ "$1" = "-q" ] && shift
cmd=$1; shift
case "$cmd" in
	get) [ -f "$D/$1" ] && cat "$D/$1" ;;
	set) k=${1%%=*}; v=${1#*=}; mkdir -p "$D"; printf '%s' "$v" > "$D/$k" ;;
	commit) : ;;
esac
exit 0
EOF

cat > "$T/fake/initd-ferry" <<'EOF'
#!/bin/sh
# 与真机一致：pmk_kernel_running 按进程名判断，所以 mock 服务必须真正拉起内核进程
case "$1" in
	start|restart)
		echo "$1" >> "$SRV_LOG"
		k=$(cat "$PM_TEST_UCI_STATE/ferry.main.kernel" 2>/dev/null)
		case "$k" in
			singbox) "$PMK_BIN_DIR/sing-box" run -c "$PM_SINGBOX_DIR/config.json" -D "$PM_SINGBOX_DIR" \
				>/dev/null 2>&1 & ;;
			*) "$PMK_BIN_DIR/mihomo" -d "$PM_MIHOMO_DIR" >/dev/null 2>&1 & ;;
		esac
		echo $! > "$SRV_STATE" ;;
	stop)
		echo stop >> "$SRV_LOG"
		[ -f "$SRV_STATE" ] && kill "$(cat "$SRV_STATE")" 2>/dev/null
		rm -f "$SRV_STATE" ;;
	status) [ -f "$SRV_STATE" ] && kill -0 "$(cat "$SRV_STATE")" 2>/dev/null ;;
esac
exit 0
EOF

cat > "$T/fake/df" <<'EOF'
#!/bin/sh
if [ "${FAKE_DF:-0}" = 1 ]; then
	echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
	echo "fake 1024 1024 100 100% /"
	exit 0
fi
# 模拟外置存储：$FAKE_DF_EXT 前缀的路径单独一个分区（设备名 extdev）
if [ -n "${FAKE_DF_EXT:-}" ]; then
	_p=''
	for _a in "$@"; do case "$_a" in -*) ;; *) _p=$_a ;; esac; done
	case "$_p" in
		"$FAKE_DF_EXT"*)
			echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
			echo "extdev 2000000 100000 1900000 5% $FAKE_DF_EXT"
			exit 0 ;;
	esac
fi
exec /usr/bin/df "$@"
EOF

# 最小 jsonfilter 替身（OpenWrt 上用真实 jsonfilter；WSL 无此工具）
cat > "$T/fake/jsonfilter" <<'EOF'
#!/usr/bin/env python3
import sys, json, re
args = sys.argv[1:]
data = sys.stdin.read()
expr = None
test = False
i = 0
while i < len(args):
    a = args[i]
    if a == '-i':
        with open(args[i + 1]) as fh:
            data = fh.read()
        i += 2
    elif a == '-t':
        test = True
        i += 1
    elif a == '-e':
        expr = args[i + 1]
        i += 2
    else:
        i += 1
try:
    obj = json.loads(data)
except Exception:
    sys.exit(1 if test else 3)
if test:
    sys.exit(0)
m = re.match(r'^@\.mirrors\[@\.name="([^"]+)"\]\.([A-Za-z_][A-Za-z0-9_]*)$', expr or '')
if m:
    for it in obj.get('mirrors', []):
        if it.get('name') == m.group(1):
            if m.group(2) not in it:
                sys.exit(6)
            v = it.get(m.group(2))
            print(v if not isinstance(v, bool) else str(v).lower())
            sys.exit(0)
    sys.exit(6)
m = re.match(r'^@\.([A-Za-z_][A-Za-z0-9_]*)$', expr or '')
if m:
    v = obj.get(m.group(1))
    if v is None:
        sys.exit(6)
    print(v if not isinstance(v, bool) else str(v).lower())
    sys.exit(0)
sys.exit(6)
EOF

# OpenWrt /lib/functions.sh 的 config_* 替身（WSL 无该文件）；直接读 uci-state，
# 与 fake uci 保持同一份状态，保证 pm_load 读到的 kernel 与 uci 设置一致
cat > "$T/fake/functions.sh" <<'EOF'
#!/bin/sh
# 仅实现 pm_load 用到的三个函数；section 忽略（本工具只有 main）
_pm_test_val() {
	[ -n "${PM_TEST_UCI_STATE:-}" ] || return 1
	[ -f "$PM_TEST_UCI_STATE/ferry.main.$1" ] || return 1
	cat "$PM_TEST_UCI_STATE/ferry.main.$1"
}
config_load() { :; }
config_get() {
	local v
	v=$(_pm_test_val "$3") || v=${4-}
	eval "$1=\$v"
}
config_get_bool() {
	local v
	v=$(_pm_test_val "$3") || v=${4-0}
	case "$v" in 1|on|true|yes|enabled) v=1 ;; *) v=0 ;; esac
	eval "$1=\$v"
}
EOF

chmod +x "$T/fake/uci" "$T/fake/initd-ferry" "$T/fake/df" "$T/fake/jsonfilter"
printf '%s' 'mihomo' > "$T/uci-state/ferry.main.kernel"
printf '%s' '1' > "$T/uci-state/ferry.main.enabled"
printf '%s' '0' > "$T/uci-state/ferry.main.rule_update"

export PMK_STORE="$T/store" PMK_RUN="$T/run" PMK_BIN_DIR="$T/bin" PMK_LIB_DIR="$SRC"
export PMK_CUR="$T/bin" PMK_SYS_BIN_DIR="$T/sysbin" PMK_BUILTIN="$SRC/kernels-builtin.tsv"
export PMK_UCI="$T/fake/uci" PMK_SERVICE="$T/fake/initd-ferry"
export PMK_MIRRORS="$T/store/mirrors.json" PMK_JOB="$T/run/kernel-job.json"
export PMK_LOCK="$T/run/kernel.lock" PMK_STAGE="$T/store/.stage" PMK_JAIL="$T/jail"
export PMK_CFG_MIHOMO="$T/etc/mihomo/config.yaml" PMK_CFG_SINGBOX="$T/etc/sing-box/config.json"
export PM_SINGBOX_DIR="$T/etc/sing-box" PM_MIHOMO_DIR="$T/etc/mihomo"
export PM_CONF_DIR="$T/etc/ferry" PM_RUN_DIR="$T/run"
export SRV_STATE="$T/svc.state" SRV_LOG="$T/svc.log"
export PM_FUNCTIONS_SH="$T/fake/functions.sh" PM_TEST_UCI_STATE="$T/uci-state"
export PATH="$T/fake:$PATH"

# ---------- mock 下载源 ----------
cp "$KSRC/sing-box-1.8.14-linux-amd64.tar.gz" "$T/www/" || { echo "缺少 1.8.14 包"; exit 1; }
cp "$KSRC/sing-box-1.10.7-linux-amd64.tar.gz" "$T/www/" || { echo "缺少 1.10.7 包"; exit 1; }
cp "$KSRC/sing-box-1.11.0-linux-amd64.tar.gz" "$T/www/" || { echo "缺少 1.11.0 包"; exit 1; }
cp "$KSRC/sing-box-1.12.0-linux-amd64.tar.gz" "$T/www/" || { echo "缺少 1.12.0 包"; exit 1; }
cp "$KSRC/sing-box-1.14.4-linux-amd64-musl.tar.gz" "$T/www/" || { echo "缺少 1.14.4 包"; exit 1; }
cp "$KSRC/mihomo-linux-amd64-v1.18.8.gz" "$T/www/" || { echo "缺少 mihomo 1.18.8 包"; exit 1; }

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
HTTP_PID=$!
for i in $(seq 1 40); do
	curl -sf -o /dev/null "http://127.0.0.1:$PORT/sing-box-1.8.14-linux-amd64.tar.gz" && break
	sleep 0.2
done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/sing-box-1.8.14-linux-amd64.tar.gz" \
	|| { echo "mock 下载源未就绪"; exit 1; }
pass "mock 下载源就绪 http://127.0.0.1:$PORT（本机，非外网）"

sha_of() { sha256sum "$1" | cut -d' ' -f1; }
URL="http://127.0.0.1:$PORT"

job_is() { grep -q "\"$1\":$2" "$PMK_JOB" 2>/dev/null; }
job_ok() { job_is ok true; }
job_code() { sed -n 's/.*"code":"\([^"]*\)".*/\1/p' "$PMK_JOB" 2>/dev/null; }
job_msg() { sed -n 's/.*"message":"\([^"]*\)".*/\1/p' "$PMK_JOB" 2>/dev/null; }

run_op() { # op
	local op=$1
	sh "$SRC/kernel.sh" run "$op" >/dev/null 2>&1
}

cfg_sb() { echo "$PMK_CFG_SINGBOX"; }
cfg_mh() { echo "$PMK_CFG_MIHOMO"; }

echo "===== 1. 安装 sing-box 1.8.14（目标内核未运行：只落位+写该内核指针，不动运行态） ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.8.14 PMK_OP_URLS="$URL/sing-box-1.8.14-linux-amd64.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.8.14-linux-amd64.tar.gz")" PMK_OP_ACTIVATE=1 \
PMK_OP_RESTART=1 PMK_OP_EXPECT_VERSION=1.8.14 PMK_OP_MIRROR=github \
	run_op install
if job_ok; then pass "安装 1.8.14 成功（当前运行核仍是 mihomo）"; else fail "安装 1.8.14 失败：$(job_code) $(job_msg)"; fi
note "job: $(cat "$PMK_JOB" 2>/dev/null)"
[ -x "$PMK_STORE/singbox/v1.8.14/sing-box" ] && pass "版本库落位 store/singbox/v1.8.14/sing-box" \
	|| fail "版本库缺失"
[ "$(basename "$(readlink "$PMK_STORE/singbox/active" 2>/dev/null)")" = v1.8.14 ] \
	&& pass "单内核指针 singbox/active=v1.8.14" || fail "singbox/active 未写入"
[ "$(cat "$T/uci-state/ferry.main.kernel")" = mihomo ] && pass "运行内核未被改动（uci 仍 mihomo）" \
	|| fail "安装非运行内核却改了运行内核"
[ ! -e "$PMK_BIN_DIR/sing-box" ] && pass "current 运行指针未被动（无 /usr/bin/sing-box 链接）" \
	|| fail "安装非运行内核却改了 current 指针"
[ ! -f "$SRV_STATE" ] && pass "服务未被重启（fake init.d 未启动）" || fail "安装非运行内核却重启了服务"

echo "===== 1b. 显式切换到 sing-box v1.8.14（这一步才动 current 指针 + 重启服务） ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.8.14 PMK_OP_RESTART=1 run_op switch
job_ok && pass "切换 sing-box 1.8.14 成功" || fail "切换失败：$(job_code) $(job_msg)"
[ -L "$PMK_BIN_DIR/sing-box" ] && pass "启用指针 $PMK_BIN_DIR/sing-box -> $(readlink "$PMK_BIN_DIR/sing-box")" \
	|| fail "未建立 current 启用链接"
[ "$(cat "$T/uci-state/ferry.main.kernel")" = singbox ] && pass "uci ferry.main.kernel=singbox" \
	|| fail "uci 未更新"
[ -f "$SRV_STATE" ] && pass "服务已启动（fake init.d）" || fail "服务未启动"
[ -s "$(cfg_sb)" ] && pass "配置已生成 $(cfg_sb)" || fail "配置未生成"
if grep -q '"outbound":"dns-out"' "$(cfg_sb)" && grep -Eq '"address": ?"223.5.5.5"' "$(cfg_sb)"; then
	pass "1.8.14 使用区间 A 模板（address DNS + dns-out 出站）"
else
	fail "区间 A 模板字段不符"
fi
grep -q 'rc=0' "$PMK_RUN/config-check-report.txt" && pass "sing-box check rc=0（报告 $PMK_RUN/config-check-report.txt）" \
	|| fail "sing-box check 未通过：$(cat "$PMK_RUN/config-check.txt" 2>/dev/null | head -5)"

echo "===== 2. 安装 1.11.0（不激活） ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.11.0 PMK_OP_URLS="$URL/sing-box-1.11.0-linux-amd64.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.11.0-linux-amd64.tar.gz")" PMK_OP_ACTIVATE=0 \
PMK_OP_EXPECT_VERSION=1.11.0 PMK_OP_MIRROR=github \
	run_op install
job_ok && pass "安装 1.11.0（不启用）成功" || fail "安装 1.11.0 失败：$(job_code) $(job_msg)"
[ "$(basename "$(readlink "$PMK_STORE/singbox/active")")" = v1.8.14 ] && pass "active 仍为 v1.8.14" \
	|| fail "active 被意外改变"

echo "===== 3. 切换 v1.8.14 -> v1.11.0 ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.11.0 PMK_OP_RESTART=1 \
	run_op switch
job_ok && pass "切换成功" || fail "切换失败：$(job_code) $(job_msg)"
[ "$(basename "$(readlink "$PMK_STORE/singbox/active")")" = v1.11.0 ] && pass "active=v1.11.0" || fail "active 未切换"
[ "$(basename "$(readlink "$PMK_STORE/singbox/previous")")" = v1.8.14 ] && pass "previous=v1.8.14（保留上一版本）" \
	|| fail "previous 未记录"
grep -q '"action":"hijack-dns"' "$(cfg_sb)" && pass "1.11.0 使用区间 B 模板（action hijack-dns）" \
	|| fail "区间 B 模板字段不符"
grep -q 'rc=0' "$PMK_RUN/config-check-report.txt" && pass "切换后 sing-box check rc=0" \
	|| fail "切换后 check 未通过：$(cat "$PMK_RUN/config-check.txt" 2>/dev/null | head -5)"
note "job: $(cat "$PMK_JOB")"

echo "===== 4. 回滚 -> v1.8.14 ====="
PMK_OP_KERNEL=singbox PMK_OP_RESTART=1 run_op rollback
job_ok && pass "回滚成功" || fail "回滚失败：$(job_code) $(job_msg)"
[ "$(basename "$(readlink "$PMK_STORE/singbox/active")")" = v1.8.14 ] && pass "active 回到 v1.8.14" || fail "回滚未生效"
grep -q '"outbound":"dns-out"' "$(cfg_sb)" && pass "回滚后配置按 1.8.14 区间 A 重新生成" \
	|| fail "回滚后配置未按旧内核重新生成"

echo "===== 5. 安装 1.14.4 并切换（区间 D） ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.14.4 PMK_OP_URLS="$URL/sing-box-1.14.4-linux-amd64-musl.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.14.4-linux-amd64-musl.tar.gz")" PMK_OP_ACTIVATE=1 \
PMK_OP_EXPECT_VERSION=1.14.4 \
	run_op install
job_ok && pass "安装并启用 1.14.4 成功" || fail "1.14.4 安装失败：$(job_code) $(job_msg)"
if grep -Eq '"type": ?"udp"' "$(cfg_sb)" && grep -Eq '"server": ?"223.5.5.5"' "$(cfg_sb)" \
	&& grep -q 'default_domain_resolver' "$(cfg_sb)"; then
	pass "1.14.4 使用区间 D 模板（type/server DNS + default_domain_resolver）"
else
	fail "区间 D 模板字段不符"
fi
grep -q 'rc=0' "$PMK_RUN/config-check-report.txt" && pass "1.14.4 check rc=0" \
	|| fail "1.14.4 check 未通过：$(cat "$PMK_RUN/config-check.txt" 2>/dev/null | head -5)"

echo "===== 6. 运行 sing-box 时安装 mihomo 1.18.8（只更新 mihomo 指针，不动流量） ====="
pid_before=$(cat "$SRV_STATE" 2>/dev/null)
stop_before=$(grep -c stop "$SRV_LOG" 2>/dev/null || echo 0)
PMK_OP_KERNEL=mihomo PMK_OP_VERSION=v1.18.8 PMK_OP_URLS="$URL/mihomo-linux-amd64-v1.18.8.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/mihomo-linux-amd64-v1.18.8.gz")" PMK_OP_ACTIVATE=1 \
PMK_OP_EXPECT_VERSION=1.18.8 \
	run_op install
job_ok && pass "mihomo 1.18.8 安装成功" || fail "mihomo 安装失败：$(job_code) $(job_msg)"
[ "$(cat "$T/uci-state/ferry.main.kernel")" = singbox ] && pass "运行内核仍是 sing-box（未被安装动作切走）" \
	|| fail "安装 mihomo 却改了运行内核"
[ -L "$PMK_STORE/mihomo/active" ] && pass "mihomo/active 指针已写入（切到它后才生效）" || fail "mihomo active 指针缺失"
[ ! -e "$PMK_BIN_DIR/mihomo" ] && pass "current 指针未被动（无 /usr/bin/mihomo 链接）" || fail "current 指针被改动"
[ "$(cat "$SRV_STATE" 2>/dev/null)" = "$pid_before" ] && pass "服务进程 PID 未变（$pid_before，未重启）" \
	|| fail "服务被重启（PID $pid_before -> $(cat "$SRV_STATE" 2>/dev/null)）"
[ "$(grep -c stop "$SRV_LOG" 2>/dev/null || echo 0)" = "$stop_before" ] && pass "服务日志无新增 stop（未中断流量）" \
	|| fail "安装 mihomo 期间服务被停止"
[ ! -s "$(cfg_mh)" ] && pass "未生成 mihomo 配置（未启用就不动生效配置）" || fail "安装非运行内核却改了生效配置"

echo "===== 6b. 显式切换到 mihomo 1.18.8（停服务→替换→重生成→启动） ====="
PMK_OP_KERNEL=mihomo PMK_OP_VERSION=v1.18.8 PMK_OP_RESTART=1 run_op switch
job_ok && pass "切换到 mihomo 1.18.8 成功" || fail "切换失败：$(job_code) $(job_msg)"
[ "$(cat "$T/uci-state/ferry.main.kernel")" = mihomo ] && pass "uci ferry.main.kernel=mihomo" || fail "uci 未切换"
[ -L "$PMK_BIN_DIR/mihomo" ] && pass "启用指针 $PMK_BIN_DIR/mihomo" || fail "mihomo 链接缺失"
[ -s "$(cfg_mh)" ] && pass "YAML 配置已生成 $(cfg_mh)" || fail "mihomo 配置未生成"
grep -q 'rc=0' "$PMK_RUN/config-check-report.txt" && pass "mihomo -t rc=0（二进制自检门禁）" \
	|| fail "mihomo -t 未通过：$(cat "$PMK_RUN/config-check.txt" 2>/dev/null | head -5)"
[ -L "$PMK_STORE/singbox/active" ] && pass "sing-box 版本库与 active 指针保留（跨内核不丢）" \
	|| fail "跨内核切换丢失 sing-box 指针"

echo "===== 7. 卸载非当前版本 v1.11.0 ====="
out=$(printf '{"kernel":"singbox","version":"v1.11.0"}' | sh "$SRC/kernel.sh" remove)
echo "$out" | grep -q '"ok":true' && pass "卸载 v1.11.0 成功" || fail "卸载失败：$out"
[ ! -d "$PMK_STORE/singbox/v1.11.0" ] && pass "v1.11.0 目录已删除" || fail "目录仍存在"
[ -d "$PMK_STORE/singbox/v1.8.14" ] && pass "其他版本目录保留" || fail "误删其他版本"
out=$(printf '{"kernel":"singbox","version":"v1.14.4"}' | sh "$SRC/kernel.sh" remove)
echo "$out" | grep -q '"ok":true' && pass "非当前内核的 active 版本可卸载" \
	|| fail "非当前内核版本被误拦截：$out"
[ ! -L "$PMK_STORE/singbox/active" ] && pass "删除指针目标后 active 指针已清理" || fail "active 指针残留"
[ ! -L "$PMK_BIN_DIR/sing-box" ] && pass "失效的 /usr/bin/sing-box 链接已清理" || fail "失效链接残留"
out=$(printf '{"kernel":"mihomo","version":"v1.18.8"}' | sh "$SRC/kernel.sh" remove)
echo "$out" | grep -q '"ok":true' && fail "不应允许卸载当前内核的 active 版本" || pass "拒绝卸载当前内核 active 版本"

echo "===== 8. 校验失败不落位 ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.12.0 PMK_OP_URLS="$URL/sing-box-1.12.0-linux-amd64.tar.gz" \
PMK_OP_SHA256=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
PMK_OP_ACTIVATE=1 run_op install
if ! job_ok && [ "$(job_code)" = ERR_SHA_MISMATCH ]; then pass "SHA-256 不匹配被拒绝（ERR_SHA_MISMATCH）"; else
	fail "校验失败未按预期拒绝：$(job_code) $(job_msg)"
fi
[ ! -d "$PMK_STORE/singbox/v1.12.0" ] && pass "校验失败未落位" || fail "校验失败仍落位"

echo "===== 9. 未校验安装需显式确认 ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v9.9.9 PMK_OP_URLS="$URL/sing-box-1.12.0-linux-amd64.tar.gz" \
PMK_OP_ACTIVATE=1 run_op install
if ! job_ok && [ "$(job_code)" = ERR_UNVERIFIED ]; then pass "缺少 checksum 时要求显式确认（ERR_UNVERIFIED）"; else
	fail "未校验安装未拦截：$(job_code) $(job_msg)"
fi
[ ! -d "$PMK_STORE/singbox/v9.9.9" ] && pass "未确认时未落位" || fail "未确认仍落位"

echo "===== 10. 架构不匹配 ====="
python3 - "$T/fake-arm64" <<'PY'
import sys
b = bytearray(64)
b[18] = 0xb7  # e_machine = EM_AARCH64
b[19] = 0x00
open(sys.argv[1], 'wb').write(bytes(b))
PY
gzip -c "$T/fake-arm64" > "$T/www/fake-arm64.gz"
PMK_OP_KERNEL=singbox PMK_OP_VERSION=vfake-arm PMK_OP_URLS="$URL/fake-arm64.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/fake-arm64.gz")" PMK_OP_ACTIVATE=1 run_op install
if ! job_ok && [ "$(job_code)" = ERR_ARCH ]; then pass "架构不匹配被拒绝（ERR_ARCH）"; else
	fail "架构检查未拦截：$(job_code) $(job_msg)"
fi
job_msg | grep -q '可用变体' && pass "架构错误提示包含本机可用变体（$(job_msg)）" || fail "架构错误提示太含糊：$(job_msg)"
job_msg | grep -q 'amd64' && pass "架构错误提示包含本机架构" || fail "架构错误提示缺少本机架构"
[ ! -d "$PMK_STORE/singbox/vfake-arm" ] && pass "架构不符未落位" || fail "架构不符仍落位"

echo "===== 11. 磁盘空间不足 ====="
FAKE_DF=1 PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.12.0 PMK_OP_URLS="$URL/sing-box-1.12.0-linux-amd64.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.12.0-linux-amd64.tar.gz")" PMK_OP_SIZE=22893972 PMK_OP_ACTIVATE=1 run_op install
if ! job_ok && [ "$(job_code)" = ERR_DISK_FULL ]; then pass "磁盘不足被拦截（ERR_DISK_FULL）"; else
	fail "磁盘检查未拦截：$(job_code) $(job_msg)"
fi
job_msg | grep -q '空间不足' && job_msg | grep -q '可用' \
	&& pass "空间错误给出可用/所需（$(job_msg)）" || fail "空间错误信息不可读：$(job_msg)"

echo "===== 12. 后台任务路径（start + job 轮询） ====="
printf '{"op":"install","kernel":"singbox","version":"v1.10.7","urls":"%s/sing-box-1.10.7-linux-amd64.tar.gz","sha256":"%s","activate":0,"expect_version":"1.10.7"}' \
	"$URL" "$(sha_of "$T/www/sing-box-1.10.7-linux-amd64.tar.gz")" > "$T/args.json"
cat "$T/args.json" | sh "$SRC/kernel.sh" start | grep -q '"ok":true' \
	&& pass "start 受理任务" || fail "start 未受理"
n=0
while [ $n -lt 100 ]; do
	grep -q '"done":true' "$PMK_JOB" 2>/dev/null && break
	sleep 0.2; n=$((n + 1))
done
job_is done true && pass "后台任务完成（$(job_msg)）" || fail "后台任务超时/未完成"
[ -x "$PMK_STORE/singbox/v1.10.7/sing-box" ] && pass "后台任务产物落位 v1.10.7" || fail "后台任务未落位"

echo "===== 13. 镜像前缀与校验策略（单元） ====="
cat > "$PMK_MIRRORS" <<'EOF'
{
  "version": 2,
  "mirrors": [
    { "name": "github", "label": "GitHub 官方", "prefix": "", "enabled": true, "official": true, "kind": "official" },
    { "name": "ghproxy", "label": "ghproxy 加速", "prefix": "https://ghproxy.net/", "enabled": false, "official": false, "kind": "prefix" },
    { "name": "insecure", "label": "非 HTTPS", "prefix": "http://evil.example/", "enabled": false, "official": false, "kind": "prefix" }
  ]
}
EOF
out=$(sh -c '. "$0"; pmk_source_url "https://github.com/a/b/releases/download/v1/x.gz" ghproxy' "$SRC/kernel.sh")
case "$out" in
	https://ghproxy.net/https://github.com/*) pass "镜像仅做 URL 前缀替换：$out" ;;
	*) fail "镜像前缀替换异常：$out" ;;
esac
out=$(sh -c '. "$0"; pmk_source_url "https://github.com/a/b/releases/download/v1/x.gz" insecure' "$SRC/kernel.sh")
case "$out" in
	https://github.com/*) pass "非 HTTPS 镜像回落官方源（HTTPS 强制）：$out" ;;
	*) fail "非 HTTPS 镜像未被拒绝：$out" ;;
esac

echo "===== 14. 状态接口 ====="
out=$(sh "$SRC/kernel.sh" status)
echo "$out" | grep -q "\"arch\":\"amd64\"" && pass "status.arch=amd64" || fail "status.arch 异常"
echo "$out" | grep -q '"active":"v1.18.8"' && pass "status.active=v1.18.8" || fail "status.active 异常"
echo "$out" | grep -q '"sb_bucket":""' && pass "mihomo 生效时 sb_bucket 为空（不误报）" || fail "sb_bucket 异常"
echo "$out" | grep -q '"config_check"' && pass "status 含 config_check（可核对服务实际配置与自检结果）" || fail "config_check 缺失"
echo "$out" | grep -q '"arch_match":true' && pass "status.arch_match=true" || fail "arch_match 异常"

echo "===== 15. 卸载脚本保留内核文件 ====="
mkdir -p "$PM_CONF_DIR/kernels/singbox/v1.8.14"
echo dummy > "$PM_CONF_DIR/kernels/singbox/v1.8.14/sing-box"
echo '{"nodes":[]}' > "$PM_CONF_DIR/nodes.json"
out=$(sh "$SRC/uninstall.sh" --purge 2>&1)
[ -f "$PM_CONF_DIR/kernels/singbox/v1.8.14/sing-box" ] && pass "--purge 保留内核版本库" || fail "--purge 误删内核"
[ ! -f "$PM_CONF_DIR/nodes.json" ] && pass "--purge 删除节点数据（显式选择）" || fail "--purge 未清理用户数据"
out=$(sh "$SRC/uninstall.sh" --purge-kernels 2>&1)
[ ! -d "$PM_CONF_DIR/kernels" ] && pass "--purge-kernels 显式删除内核版本库" || fail "--purge-kernels 未删除"
note "uninstall 输出：$(echo "$out" | tr '\n' ' ' | head -c 200)"

echo "===== 16. 内置源清单（官方 + ≥2 加速镜像，默认启用） ====="
rm -f "$PMK_MIRRORS"
out=$(sh "$SRC/kernel.sh" mirrors)
echo "$out" | grep -q '"ok":true' && pass "mirrors 接口可用" || fail "mirrors 异常：$out"
if echo "$out" | grep -q '"name": "ghfast"' && echo "$out" | grep -q '"name": "ghproxy"' \
	&& echo "$out" | grep -q '"name": "jsdelivr"'; then
	pass "内置清单含 ghfast.top / ghproxy.net / jsDelivr 三类镜像"
else
	fail "内置镜像缺失：$out"
fi
echo "$out" | grep -q '"selected":"auto"' && pass "默认源为 auto（按序回退）" || fail "默认源不是 auto：$out"
out=$(sh -c '. "$0"; pmk_source_chain auto' "$SRC/kernel.sh")
[ "$out" = "github ghfast ghproxy" ] && pass "默认回退顺序：$out" || fail "回退顺序异常：$out"
out=$(sh -c '. "$0"; pmk_source_url "https://github.com/a/b/releases/download/v1/x.gz" jsdelivr' "$SRC/kernel.sh")
case "$out" in
	https://cdn.jsdelivr.net/gh/a/b@v1/x.gz) pass "jsDelivr 映射 GitHub 资产：$out" ;;
	*) fail "jsDelivr 映射异常：$out" ;;
esac
out=$(sh -c '. "$0"; pmk_source_url "https://example.com/x.gz" jsdelivr' "$SRC/kernel.sh")
[ -z "$out" ] && pass "jsDelivr 对非 GitHub URL 明确跳过（不伪装官方源）" || fail "jsDelivr 错误映射：$out"

echo "===== 17. 镜像失败自动回退并在任务里标注（反例） ====="
cat > "$PMK_MIRRORS" <<'EOF'
{ "version": 2, "mirrors": [
  { "name": "github", "label": "GitHub 官方", "prefix": "", "enabled": true, "official": true, "kind": "official" },
  { "name": "ghfast", "label": "坏镜像", "prefix": "https://127.0.0.1:19999/", "enabled": true, "official": false, "kind": "prefix" }
] }
EOF
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.12.0 PMK_OP_URLS="$URL/sing-box-1.12.0-linux-amd64.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.12.0-linux-amd64.tar.gz")" PMK_OP_MIRROR=ghfast PMK_OP_ACTIVATE=0 run_op install
job_ok && pass "首选镜像不可用时自动回退并安装成功" || fail "回退后仍失败：$(job_msg)"
grep -q '"source":"github"' "$PMK_JOB" && pass "任务记录实际源=github（回退后）" || fail "未记录实际源：$(cat "$PMK_JOB")"
grep -q '"fallback":true' "$PMK_JOB" && pass "任务标注已回退（fallback=true）" || fail "未标注回退"
[ -x "$PMK_STORE/singbox/v1.12.0/sing-box" ] && pass "回退下载的文件通过校验并落位" || fail "回退产物未落位"
rm -f "$PMK_MIRRORS"

echo "===== 18. 镜像给错/旧文件被 SHA-256 拦住（反例） ====="
mkdir -p "$T/www-mirror"
cp "$T/www/sing-box-1.10.7-linux-amd64.tar.gz" "$T/www-mirror/sing-box-1.12.0-linux-amd64.tar.gz"
python3 -m http.server 18081 --bind 127.0.0.1 --directory "$T/www-mirror" >/dev/null 2>&1 &
MIRROR_PID=$!
for i in $(seq 1 20); do
	curl -s -o /dev/null "http://127.0.0.1:18081/sing-box-1.12.0-linux-amd64.tar.gz" && break
	sleep 0.3
done
rm -rf "$PMK_STORE/mihomo/.probe" "$PMK_STORE/singbox/v1.13.0"
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.13.0 PMK_OP_URLS="http://127.0.0.1:18081/sing-box-1.12.0-linux-amd64.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.12.0-linux-amd64.tar.gz")" PMK_OP_ACTIVATE=1 run_op install
if ! job_ok && [ "$(job_code)" = ERR_SHA_MISMATCH ]; then pass "镜像旧文件被 SHA-256 拦截（ERR_SHA_MISMATCH）"; else
	fail "错误文件未被拦截：$(job_code) $(job_msg)"
fi
job_msg | grep -q '期望' && job_msg | grep -q '实际' && pass "校验失败给出期望/实际摘要" || fail "校验失败信息不全：$(job_msg)"
[ ! -d "$PMK_STORE/singbox/v1.13.0" ] && pass "校验失败未落位（旧版本保留可回退）" || fail "校验失败仍落位"
kill "$MIRROR_PID" 2>/dev/null

echo "===== 19. 安装路径在插件目录 + 不覆盖系统内核（反例） ====="
mkdir -p "$PMK_SYS_BIN_DIR"
cp "$PMK_STORE/mihomo/v1.18.8/mihomo" "$PMK_SYS_BIN_DIR/mihomo"
sys_sha=$(sha_of "$PMK_SYS_BIN_DIR/mihomo")
PMK_OP_KERNEL=mihomo PMK_OP_VERSION=v1.18.8 PMK_OP_URLS="$URL/mihomo-linux-amd64-v1.18.8.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/mihomo-linux-amd64-v1.18.8.gz")" PMK_OP_ACTIVATE=1 PMK_OP_RESTART=0 run_op install
link="$PMK_BIN_DIR/mihomo"
[ -L "$link" ] && pass "current 指针是符号链接：$link" || fail "current 指针缺失"
case "$(readlink "$link")" in
	"$PMK_STORE"/*) pass "指针指向插件目录内版本：$(readlink "$link")" ;;
	*) fail "指针指向异常：$(readlink "$link")" ;;
esac
[ "$(sha_of "$PMK_SYS_BIN_DIR/mihomo")" = "$sys_sha" ] && pass "系统自带二进制未被覆盖（sha 不变）" || fail "系统二进制被改写"
[ -f "$PMK_STORE/mihomo/v1.18.8/mihomo" ] && pass "内核按「内核名/版本」分层存放" || fail "分层目录缺失"
out=$(sh -c '. "$0"; export PM_KERNEL=mihomo PM_KERNEL_DIR="'"$PMK_BIN_DIR"'" PM_BIN_DIR=/usr/bin; pm_kernel_bin' "$SRC/common.sh")
[ "$out" = "$PMK_BIN_DIR/mihomo" ] && pass "服务取二进制优先插件目录：$out" || fail "服务仍依赖 /usr/bin：$out"

echo "===== 20. 内置版本清单（离线可用、带官方 SHA-256/大小） ====="
out=$(printf '{"kernel":"mihomo"}' | sh "$SRC/kernel.sh" versions)
echo "$out" | grep -q '"ok":true' && pass "内置版本清单可用（离线）" || fail "内置清单不可用：$out"
echo "$out" | grep -q '"list":"builtin"' && pass "清单来源标注 builtin" || fail "清单来源未标注"
n=$(echo "$out" | grep -o '"sha256":"[0-9a-f]\{64\}"' | wc -l)
[ "$n" -ge 3 ] && pass "清单含官方 SHA-256 的条目 $n 条" || fail "SHA-256 条目过少：$n"
echo "$out" | grep -q '"size":[1-9]' && pass "清单含资产大小（用于下载前空间检查）" || fail "清单缺少 size"

echo "===== 21. sysupgrade 保留：keep.d 登记 ====="
keepd="$REPO/files/lib/upgrade/keep.d/ferry"
# r9 起 keep.d 收敛为有序清单，内核目录由父目录 /etc/ferry 递归覆盖（外置时不会打包多份）
if [ -s "$keepd" ] && grep -qE '^/etc/ferry(/kernels)?$' "$keepd"; then
	pass "随包 keep.d 登记内核目录（含父目录覆盖）：$(grep -v '^#' "$keepd" | tail -1)"
else
	fail "keep.d 缺失或未登记 /etc/ferry/kernels 或 /etc/ferry"
fi
grep -q 'keep.d/ferry' "$REPO/Makefile" && pass "Makefile 安装 keep.d" || fail "Makefile 未安装 keep.d"
PMK_KEEP_D="$T/keepd-none" sh -c '. "$0"; pmk_api_status' "$SRC/kernel.sh" | grep -q '"keepd_installed":false' \
	&& pass "未装 keep.d 时状态标注 false（提示升级会丢内核）" || fail "keepd_installed 状态异常"
echo '/etc/ferry/kernels' > "$T/keepd"
PMK_KEEP_D="$T/keepd" sh -c '. "$0"; pmk_api_status' "$SRC/kernel.sh" | grep -q '"keepd_installed":true' \
	&& pass "已装 keep.d 时状态标注 true" || fail "keepd 检测失败"
out=$(PMK_KEEP_D="$T/keepd" sh -c '. "$0"; pmk_api_status' "$SRC/kernel.sh")
echo "$out" | grep -q '"store_persist":"rootfs"' && pass "默认目录判为 rootfs（overlay，需 keep.d）" || fail "默认目录持久性判定错误：$out"

echo "===== 22. 外置存储与内存盘判定（反例） ====="
mkdir -p "$T/extstore"
PMK_STORE="$T/extstore" FAKE_DF_EXT="$T/extstore" sh -c '. "$0"; pmk_store_persist; pmk_store_device' "$SRC/kernel.sh" > "$T/ext.out"
[ "$(head -1 "$T/ext.out")" = external ] && pass "独立分区判为 external（升级不影响）" || fail "外置判定错误：$(cat "$T/ext.out")"
[ "$(tail -1 "$T/ext.out")" = extdev ] && pass "外置分区设备名正确：$(tail -1 "$T/ext.out")" || fail "分区识别错误"
out=$(PMK_STORE=/tmp/ferry-k sh -c '. "$0"; pmk_store_persist' "$SRC/kernel.sh")
[ "$out" = volatile ] && pass "内存盘判为 volatile（重启即丢）" || fail "内存盘判定错误：$out"
PMK_STORE=/tmp/ferry-k PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.12.0 \
PMK_OP_URLS="$URL/sing-box-1.12.0-linux-amd64.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.12.0-linux-amd64.tar.gz")" run_op install
if ! job_ok && [ "$(job_code)" = ERR_STORE ]; then pass "内核目录在内存盘时拒装（ERR_STORE）"; else
	fail "内存盘未拒装：$(job_code) $(job_msg)"
fi
[ ! -d /tmp/ferry-k/singbox ] && pass "内存盘未落位" || fail "内存盘仍落位"
out=$(printf '{"dir":"/tmp/ferry-k"}' | sh "$SRC/kernel.sh" store-set)
echo "$out" | grep -q '"ok":false' && pass "store-set 拒绝 /tmp：$out" || fail "store-set 未拒绝内存盘"

echo "===== 23. 资产状态：不可用条目隐藏（反例） ====="
cp "$PMK_BUILTIN" "$T/builtin-state.tsv"
awk -F'\t' -v OFS='\t' '/^#/{print;next}
	$1=="mihomo" && $2=="v1.19.33" && $3=="amd64" && NF>=7 {$8="dead"; print; next}
	NF>=7 && NF<8 {$8="probe"} {print}' "$T/builtin-state.tsv" > "$T/builtin-state.new"
mv "$T/builtin-state.new" "$T/builtin-state.tsv"
out=$(PMK_BUILTIN="$T/builtin-state.tsv" printf '{"kernel":"mihomo"}' | PMK_BUILTIN="$T/builtin-state.tsv" sh "$SRC/kernel.sh" versions)
echo "$out" | grep -q '"unavailable":2' && pass "status 汇总隐藏的不可用资产数=2" || fail "unavailable 计数错误：$out"
echo "$out" | grep -q '"version":"v1.19.33","prerelease"' && fail "dead 条目仍出现在列表中" || pass "dead 条目已从可选列表隐藏"
echo "$out" | grep -q '"state":"probe"' && pass "未全量校验条目标注 probe（可用）" || fail "probe 状态缺失"
out=$(PMK_BUILTIN="$T/builtin-state.tsv" sh -c '. "$0"; pmk_builtin_first_url mihomo amd64' "$SRC/kernel.sh")
case "$out" in *mihomo-linux-amd64-v1.19.33*) fail "首个可用 URL 取到了 dead 条目：$out" ;; *) pass "首个可用 URL 跳过 dead 条目" ;; esac

echo "===== 24. 变体映射与资产名一致 ====="
out=$(sh -c '. "$0"; pmk_builtin_records mihomo arm64' "$SRC/kernel.sh")
case "$out" in *mihomo-linux-arm64-v*) pass "arm64 映射到 mihomo-linux-arm64 资产" ;; *) fail "arm64 资产名映射错误" ;; esac
out=$(sh -c '. "$0"; pmk_builtin_records mihomo mipsle' "$SRC/kernel.sh")
case "$out" in *mipsle-softfloat*) pass "mipsle 映射到 mipsle-softfloat 资产（软浮点）" ;; *) fail "mipsle 资产名映射错误" ;; esac
out=$(sh -c '. "$0"; pmk_variants mihomo' "$SRC/kernel.sh")
case "$out" in *amd64*) pass "本机变体列表正确：$out" ;; *) fail "变体列表缺项：$out" ;; esac

echo "===== 25. 旧版 mirrors.json（覆盖安装路径）迁移不挂起 ====="
# r6 及更早写的 mirrors.json 没有 "version": 2；r7–r9 的迁移分支
# init→pmk_mirror_get→init 无限递归，ubus 调用永不返回（页面永远“加载中”）。
cat > "$PMK_MIRRORS" <<'EOF2'
{
  "mirrors": [
    { "name": "github", "label": "GitHub 官方", "prefix": "", "enabled": true, "official": true },
    { "name": "custom", "label": "自定义反代", "prefix": "https://my.example/", "enabled": true, "official": false }
  ]
}
EOF2
t0=$(date +%s)
out=$(timeout 8 sh "$SRC/kernel.sh" mirrors 2>/dev/null); rc=$?
t1=$(date +%s)
if [ "$rc" -eq 0 ] && [ $((t1 - t0)) -lt 8 ]; then
	pass "旧格式迁移 $((t1 - t0))s 内返回（rc=0，不再递归挂起）"
else
	fail "旧格式迁移超时/失败 rc=$rc（递归回归）"
fi
echo "$out" | grep -q '"ok":true' && pass "迁移后 mirrors ok:true" || fail "迁移后 mirrors 非 ok：$out"
grep -q '"version": 2' "$PMK_MIRRORS" && pass "迁移后写入 version:2" || fail "迁移后未写 version:2"
grep -q 'my.example' "$PMK_MIRRORS" && pass "旧自定义前缀被保留" || fail "旧自定义前缀丢失"

echo "===== 26. 损坏 mirrors.json（反例）：不挂起、返回合法 JSON、留备份 ====="
printf '%s' '{"mirrors": [, broken' > "$PMK_MIRRORS"
t0=$(date +%s)
out=$(timeout 8 sh "$SRC/kernel.sh" mirrors 2>/dev/null); rc=$?
t1=$(date +%s)
if [ "$rc" -eq 0 ] && [ $((t1 - t0)) -lt 8 ]; then
	pass "坏 JSON 下 $((t1 - t0))s 内返回"
else
	fail "坏 JSON 下超时/失败 rc=$rc"
fi
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
	&& pass "坏 JSON 下输出仍是合法 JSON（前端 RPC 不会 reject）" || fail "输出不是合法 JSON：$out"
echo "$out" | grep -q '"ok":' && pass "输出带 ok 字段" || fail "输出缺 ok 字段"
[ -f "$PMK_MIRRORS.broken" ] && pass "坏文件已备份为 mirrors.json.broken" || fail "坏文件未备份"
rm -f "$PMK_MIRRORS"

echo "===== 27. 断网可用性：版本清单与镜像源都不依赖网络 ====="
out=$(printf '{"kernel":"mihomo","prerelease":0}' | sh "$SRC/kernel.sh" versions 2>/dev/null)
c=$(echo "$out" | grep -o '"asset"' | wc -l)
[ "${c:-0}" -ge 1 ] && pass "离线版本清单非空（mihomo $c 条，来自内置 TSV）" \
	|| fail "离线版本清单为空：$out"
echo "$out" | grep -q '"list":"builtin"' && pass "清单来源标注为 builtin" || note "未标注 list=builtin"
rm -f "$PMK_MIRRORS"
out=$(sh "$SRC/kernel.sh" mirrors 2>/dev/null)
n=$(echo "$out" | grep -c '"name"')
[ "$n" -ge 3 ] && pass "默认镜像源非空（$n 条）" || fail "默认镜像源为空：$out"
echo "$out" | grep -q '"chain"' && pass "镜像源返回 chain 字段" || fail "缺 chain 字段"

echo "===== 28. 前端：5s 超时 + 错误态 + 版本不依赖镜像（静态断言） ====="
VJS="$REPO/files/www/luci-static/resources/view/ferry/kernel.js"
grep -q 'function rpcTimeout' "$VJS" && pass "存在 rpcTimeout 保护" || fail "缺 rpcTimeout"
grep -q ', 5000,' "$VJS" && pass "所有请求 5s 上限" || fail "未见 5000ms 上限"
grep -q 'if (!state.mirrors)' "$VJS" && fail "版本加载仍被镜像源阻塞（回归）" \
	|| pass "版本清单不再依赖镜像源"
grep -q 'state.mirrorsErr' "$VJS" && pass "镜像源错误态存在" || fail "缺镜像源错误态"
grep -q 'state.versionsErr' "$VJS" && pass "版本清单错误态存在" || fail "缺版本错误态"
grep -q "button('重试'" "$VJS" && pass "错误态带重试按钮" || fail "错误态缺重试按钮"
grep -q 'state.pollErrs' "$VJS" && pass "job 轮询失败会停止并报错" || fail "job 轮询失败仍空转"

echo "===== 29. rpcd 入口：watchdog + 缺失后端也返回合法 JSON ====="
RPCD="$REPO/files/usr/libexec/rpcd/luci-ferry-kernel"
sh -n "$RPCD" 2>/dev/null && pass "rpcd 脚本语法通过" || fail "rpcd 脚本语法错误"
grep -q 'PMK_RPC_TIMEOUT' "$RPCD" && pass "rpcd 带后端超时保护" || fail "缺后端超时保护"
grep -q 'sh "$K"' "$RPCD" && pass "后端用 sh 显式执行（丢可执行位也能跑）" || fail "未显式 sh 执行"
grep -q 'unknown method' "$RPCD" && pass "未知方法有明确错误" || fail "未知方法无错误态"
out=$(printf '{}' | sh "$RPCD" call versions 2>/dev/null)
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is False and d.get("error")' 2>/dev/null \
	&& pass "后端缺失时返回 {ok:false,error}（不是空列表/挂起）" || fail "后端缺失时输出不合契约：$out"

echo "===== 30. 诊断入口与升级清理清单 ====="
DIAG="$REPO/files/usr/bin/ferry-kernel-diag"
[ -f "$DIAG" ] && pass "ferry-kernel-diag 随包存在" || fail "缺 ferry-kernel-diag"
sh -n "$DIAG" 2>/dev/null && pass "诊断脚本语法通过" || fail "诊断脚本语法错误"
for k in 'uclient-fetch' 'ca_cert' 'kernel_dir' 'manifest_' 'job_message' 'ubus_versions'; do
	grep -q "$k" "$DIAG" && pass "诊断包含 $k" || fail "诊断缺 $k"
done
[ -f "$REPO/files/usr/lib/ferry/legacy-files.txt" ] && pass "旧文件清单随包存在" || fail "缺旧文件清单"
grep -q 'legacy-files.txt' "$REPO/Makefile" && pass "postinst 按清单删除旧文件" || fail "postinst 未引用清单"
grep -q 'luci-indexcache' "$REPO/Makefile" && pass "postinst 清 LuCI 索引缓存" || fail "postinst 未清索引缓存"
grep -q 'init-state' "$REPO/Makefile" && pass "postinst 主动迁移 mirrors.json" || fail "postinst 未迁移旧状态"

echo "===== 31. ACL 覆盖 + 前端 404/未知方法/超时反例 ====="
ACL="$REPO/files/usr/share/rpcd/acl.d/luci-app-ferry.json"
for m in source_set store_set mirror_set versions mirrors; do
	grep -q "\"$m\"" "$ACL" && pass "ACL 声明 $m" || fail "ACL 未声明 $m（LuCI 会话调用会被拒）"
done
grep -q 'acl_missing=' "$DIAG" && pass "诊断会检查 ACL 漏声明的方法" || fail "诊断未检查 ACL 覆盖"
NODEBIN=''
command -v node >/dev/null 2>&1 && NODEBIN=node
if [ -z "$NODEBIN" ] && command -v node.exe >/dev/null 2>&1; then
	NODEBIN=node.exe
fi
if [ -n "$NODEBIN" ]; then
	JSE="$REPO/tests/test-kernel-ui-errors.mjs"
	[ "$NODEBIN" = node.exe ] && JSE=$(wslpath -w "$JSE" 2>/dev/null || echo "$JSE")
	out=$("$NODEBIN" "$JSE" 2>&1); rc=$?
	echo "$out" | sed 's/^/  /'
	[ "$rc" -eq 0 ] && pass "前端三种反例（超时/未知方法/404）都落到错误态" || fail "前端反例未通过"
else
	fail "无 node，无法运行前端反例断言"
fi

echo "===== 32. mirror-set 保存前端载荷（无 version 字段）后不触发迁移 ====="
# 前端只提交 { mirrors: [...] }；busybox sed 不支持 0,/re/，r10 改用 awk 补 version:2。
rm -f "$PMK_MIRRORS"
RAW='{"mirrors":[{"name":"github","label":"GitHub 官方","prefix":"","enabled":true,"official":true},{"name":"ghfast","label":"ghfast","prefix":"https://ghfast.top/","enabled":false,"official":false}]}'
ESC=$(printf '%s' "$RAW" | sed 's/\\/\\\\/g; s/"/\\"/g')
out=$(printf '{"json":"%s"}' "$ESC" | sh "$SRC/kernel.sh" mirror-set 2>/dev/null)
echo "$out" | grep -q '"ok":true' && pass "mirror-set 保存成功" || fail "mirror-set 失败：$out"
grep -q '"version": 2' "$PMK_MIRRORS" 2>/dev/null && pass "保存时补回 version:2" || fail "保存后仍是 v1（注入失效，下次读取会迁移重置）"
out=$(sh "$SRC/kernel.sh" mirrors 2>/dev/null)
if [ "$(echo "$out" | sed -n 's/.*"chain":"\([^"]*\)".*/\1/p')" = "github" ]; then
	pass "只启用 github 时 chain=github（保存结果未被迁移重置）"
else
	fail "chain 被迁移重置：$out"
fi
echo "$out" | grep -q '"name": *"ghfast"' && pass "保存的两条镜像仍在" || fail "镜像条目被迁移覆盖"
rm -f "$PMK_MIRRORS"

echo "===== 33. 任务进度字段（阶段/总字节/百分比/速度/HTTP/产物） ====="
JOBF="$T/prog.json"
prog_job() { # total bytes phase
	rm -f "$JOBF"
	PMK_JOB="$JOBF" PMK_JOB_ID=pj PMK_JOB_OP=install PMK_JOB_KERNEL=singbox \
	PMK_JOB_VERSION=v1.2.3 PMK_JOB_START=x PMK_JOB_START_TS=$(( $(date +%s) - 3 )) \
	PMK_JOB_TOTAL="$1" PMK_JOB_DEST=/x/v1.2.3 PMK_JOB_SIZE=1234 \
	sh -c '. "$0"; pmk_job_set "$3" "msg" "$2" "$4" "$5" ""' "$SRC/kernel.sh" "$1" "$2" "${3}" >/dev/null 2>&1
}
prog_job 1000 400 download false null
out=$(cat "$JOBF" 2>/dev/null)
echo "$out" | grep -q '"stage":2' && pass "下载阶段 stage=2" || fail "下载阶段索引错误：$out"
echo "$out" | grep -q '"percent":40' && pass "下载进度按字节计算（400/1000=40%）" || fail "百分比错误：$out"
echo "$out" | grep -q '"total":1000' && pass "任务带总字节 total" || fail "缺 total：$out"
echo "$out" | grep -q '"stages":8' && pass "阶段总数 stages=8" || fail "缺 stages：$out"
echo "$out" | grep -q '"dest":"/x/v1.2.3"' && pass "任务带落位目录 dest" || fail "缺 dest：$out"
echo "$out" | grep -q '"size":1234' && pass "任务带产物大小 size" || fail "缺 size：$out"
echo "$out" | grep -q '"elapsed":3' && pass "任务带耗时 elapsed" || fail "缺 elapsed：$out"
echo "$out" | grep -q '"updated_ts":' && pass "任务带 updated_ts（前端判断 20s 无更新）" || fail "缺 updated_ts"
prog_job 1000 1000 verify false null
out=$(cat "$JOBF")
echo "$out" | grep -q '"stage":3' && pass "校验阶段 stage=3" || fail "校验阶段索引错误：$out"
prog_job 1000 1000 install false null
out=$(cat "$JOBF")
echo "$out" | grep -q '"stage":5' && pass "落位阶段 stage=5" || fail "落位阶段索引错误：$out"
prog_job 1000 1000 switch false null
out=$(cat "$JOBF")
echo "$out" | grep -q '"stage":6' && pass "切换指针阶段 stage=6" || fail "切换阶段索引错误：$out"
prog_job 1000 1000 done true true
out=$(cat "$JOBF")
echo "$out" | grep -q '"stage":7' && echo "$out" | grep -q '"percent":100' && pass "完成阶段 stage=7 / 100%" \
	|| fail "完成阶段错误：$out"
# 失败保留失败发生时的阶段（下载失败不应退回“排队”）
rm -f "$JOBF"
PMK_JOB="$JOBF" PMK_JOB_ID=pj PMK_JOB_OP=install PMK_JOB_KERNEL=singbox PMK_JOB_VERSION=v1.2.3 \
PMK_JOB_START=x PMK_JOB_START_TS=$(date +%s) PMK_JOB_TOTAL=1000 \
	sh -c '. "$0"; pmk_job_set download "d" 400 false null ""; pmk_job_fail ERR_NETWORK "boom" 400' "$SRC/kernel.sh" >/dev/null 2>&1
out=$(cat "$JOBF")
echo "$out" | grep -q '"phase":"failed"' && echo "$out" | grep -q '"stage":2' && echo "$out" | grep -q '"percent":40' \
	&& pass "失败停留下载阶段（stage=2，40%，不回初始态）" || fail "失败阶段/百分比丢失：$out"

echo "===== 34. 慢速下载的进度采样（≥3 点、百分比单调、速度/当前源） ====="
cat > "$T/slow_server.py" <<'PY'
import http.server, os, sys, time
root, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = os.path.join(root, os.path.basename(self.path))
        if not os.path.isfile(p):
            self.send_response(404); self.send_header('Content-Length','0'); self.end_headers(); return
        data = open(p, 'rb').read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        step = max(1, len(data) // 24)
        for i in range(0, len(data), step):
            self.wfile.write(data[i:i+step]); self.wfile.flush(); time.sleep(0.25)
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
python3 "$T/slow_server.py" "$T/www" 18082 >/dev/null 2>&1 &
SLOW_PID=$!
for i in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:18082/mihomo-linux-amd64-v1.18.8.gz" && break; sleep 0.2; done
F="$T/www/mihomo-linux-amd64-v1.18.8.gz"
SZ=$(wc -c < "$F" | tr -d ' ')
printf '{"op":"install","kernel":"mihomo","version":"vslowtest","urls":"http://127.0.0.1:18082/mihomo-linux-amd64-v1.18.8.gz","sha256":"%s","activate":0,"size":%s,"mirror":"github"}' \
	"$(sha_of "$F")" "$SZ" > "$T/args-slow.json"
cat "$T/args-slow.json" | sh "$SRC/kernel.sh" start >/dev/null 2>&1
samples=0; lastpct=-1; mono=1; speeds=0; srcseen=0; n=0
while :; do
	n=$((n + 1))
	[ "$n" -gt 400 ] && break
	[ -f "$PMK_JOB" ] || { sleep 0.3; continue; }
	pct=$(sed -n 's/.*"percent":\([0-9]*\).*/\1/p' "$PMK_JOB" | tail -1)
	bytes=$(sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' "$PMK_JOB" | tail -1)
	spd=$(sed -n 's/.*"speed":\([0-9]*\).*/\1/p' "$PMK_JOB" | tail -1)
	src=$(sed -n 's/.*"source":"\([^"]*\)".*/\1/p' "$PMK_JOB" | tail -1)
	[ -n "$pct" ] && [ "$pct" -gt 0 ] && samples=$((samples + 1))
	[ -n "$pct" ] && [ "$pct" -lt "$lastpct" ] && mono=0
	[ -n "$pct" ] && lastpct=$pct
	[ -n "$spd" ] && [ "$spd" -gt 0 ] && speeds=$((speeds + 1))
	[ -n "$src" ] && srcseen=1
	grep -q '"done":true' "$PMK_JOB" 2>/dev/null && break
	sleep 0.2
done
kill "$SLOW_PID" 2>/dev/null
[ "$samples" -ge 3 ] && pass "下载进度采样 $samples 点（含字节与百分比）" || fail "进度采样不足：$samples 点"
[ "$mono" = 1 ] && pass "进度百分比单调不减（最终 $lastpct%）" || fail "百分出现回退"
[ "$speeds" -ge 1 ] && pass "有速度采样（$speeds 次 speed>0）" || fail "未见速度字段非零"
[ "$srcseen" = 1 ] && pass "任务带当前下载源 source" || fail "缺 source 字段"
job_ok && pass "慢速下载最终安装成功" || fail "慢速下载失败：$(job_code) $(job_msg)"
echo "$(cat "$PMK_JOB")" | grep -q '"source":"github"' && pass "完成后 source=github" || fail "完成后 source 缺失"
echo "$(cat "$PMK_JOB")" | grep -q '"stage":7' && pass "完成后 stage=7" || fail "完成后阶段异常"
echo "$(cat "$PMK_JOB")" | grep -q '"http_code":"200"' && pass "成功后记录 HTTP 200" || fail "未记录 HTTP 码"
rm -rf "$PMK_STORE/mihomo/vslowtest"

echo "===== 35. 坏源 / 断网：失败阶段与 HTTP 原因（不假装完成） ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=vnohttp PMK_OP_URLS="$URL/no-such-asset.tar.gz" \
PMK_OP_MIRROR=github PMK_OP_ACTIVATE=0 run_op install
if ! job_ok && [ "$(job_code)" = ERR_NETWORK ]; then pass "坏源返回 ERR_NETWORK（未假装完成）"; else
	fail "坏源未按预期失败：$(job_code) $(job_msg)"
fi
echo "$(cat "$PMK_JOB")" | grep -q '"http_code":"4[0-9][0-9]"' && pass "失败记录 HTTP 4xx（$(sed -n 's/.*"http_code":"\([^"]*\)".*/\1/p' "$PMK_JOB")）" || fail "未记录 HTTP 状态码：$(cat "$PMK_JOB")"
echo "$(cat "$PMK_JOB")" | grep -q '"stage":2' && pass "失败停在下载阶段 stage=2" || fail "失败阶段丢失"
jmsg=$(job_msg)
case "$jmsg" in *HTTP\ 4*|*404*|*403*) pass "失败原因含 HTTP 码（$jmsg）" ;; *) fail "失败原因不含 HTTP 码：$jmsg" ;; esac
[ ! -d "$PMK_STORE/singbox/vnohttp" ] && pass "失败未落位" || fail "失败仍落位"
PMK_OP_KERNEL=singbox PMK_OP_VERSION=voffline PMK_OP_URLS="https://127.0.0.1:1/x.gz" \
PMK_OP_MIRROR=github PMK_OP_ACTIVATE=0 run_op install
if ! job_ok && [ "$(job_code)" = ERR_NETWORK ]; then pass "断网/不可达返回 ERR_NETWORK"; else
	fail "不可达未按预期失败：$(job_code) $(job_msg)"
fi
jmsg=$(job_msg)
case "$jmsg" in *refused*|*不可达*|*timeout*|*timed\ out*|*失败*) pass "不可达给出网络类原因（$jmsg）" ;; *) fail "不可达原因不够具体：$jmsg" ;; esac

echo "===== 36. 版本清单按内核过滤 + 返回可用内核列表（离线） ====="
out=$(printf '{"kernel":"mihomo"}' | sh "$SRC/kernel.sh" versions)
echo "$out" | grep -q '"kernels":"mihomo,singbox"' && pass "versions 返回可用内核列表（$out 中的 kernels）" \
	|| fail "缺 kernels 列表：$out"
out=$(printf '{"kernel":"singbox"}' | sh "$SRC/kernel.sh" versions)
mh=$(printf '{"kernel":"mihomo"}' | sh "$SRC/kernel.sh" versions | grep -o '"url"' | wc -l)
sb=$(echo "$out" | grep -o '"url"' | wc -l)
[ "$sb" -ge 1 ] && pass "sing-box 清单非空（$sb 条）" || fail "sing-box 清单为空"
[ "$mh" -ge 1 ] && pass "mihomo 清单非空（$mh 条，与 sing-box 独立）" || fail "mihomo 清单为空"
echo "$out" | grep -q 'sing-box-1.14.4-linux-amd64' && pass "sing-box 清单条目为 sing-box 资产" || fail "sing-box 清单条目异常"
if echo "$out" | grep -q 'mihomo-linux'; then fail "sing-box 清单混入 mihomo 版本"; else pass "sing-box 清单不含 mihomo 资产（切换不串味）"; fi

echo "===== 37. 前端：管理内核与运行内核分离、进度阶段、状态未知（静态断言） ====="
grep -q '管理内核' "$VJS" && pass "存在「管理内核」选择器" || fail "缺管理内核选择器"
grep -q '即将安装到' "$VJS" && pass "顶部显示「即将安装到」" || fail "缺安装目标摘要"
grep -q 'manageKernel' "$VJS" && pass "管理内核用独立状态 manageKernel" || fail "管理内核状态缺失"
grep -q 'kernel: state.manageKernel' "$VJS" && pass "安装参数用 manageKernel（不与运行内核耦合）" || fail "安装参数仍用 selKernel"
grep -q '不会改动正在运行的内核' "$VJS" && pass "明确文案：切换管理内核不改运行内核" || fail "缺运行时隔离文案"
grep -q '准备中…' "$VJS" && pass "点击后立刻「准备中…」" || fail "缺即时反馈文案"
grep -q 'installBtn.disabled = true' "$VJS" && pass "进行中按钮禁用" || fail "按钮未禁用"
grep -q '状态未知' "$VJS" && pass "轮询异常有「状态未知」态" || fail "缺状态未知态"
grep -q '20000' "$VJS" && pass "20s 无更新判定" || fail "缺 20s 无更新判定"
grep -q 'poll.add(state.pollFn, 1)' "$VJS" && pass "job 轮询 1s 一次" || fail "轮询间隔不是 1s"
grep -q "var want = state.manageKernel" "$VJS" && pass "清单请求绑定当前管理内核（防串味）" || fail "清单请求未绑定内核"
for st in '排队' '预检' '校验 SHA-256' '解压/识别' '落位' '切换指针' '完成'; do
	grep -q "$st" "$VJS" && pass "阶段条含「$st」" || fail "阶段条缺「$st」"
done
grep -q '失败会停在具体阶段' "$VJS" && pass "说明失败停留在具体阶段" || fail "缺失败阶段说明"

echo
if [ "$FAILED" -eq 0 ]; then
	echo "RESULT: ALL PASS（离线回归，mock 下载源 + 真实 sing-box/mihomo 二进制）"
	exit 0
fi
echo "RESULT: $FAILED 项失败"
exit 1
