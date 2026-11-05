#!/bin/bash
# 离线回归：内核管理（下载/校验/安装/切换/回滚/卸载 + 失败路径）
# 运行环境：WSL/Linux + bash + python3 + curl/wget + tar/gzip + sha256sum
# 下载源：本机 127.0.0.1 的 python3 http.server（mock 官方 Release），二进制用真实 sing-box/mihomo 包
# 不依赖外网；不触碰宿主生产环境

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/files/usr/lib/ferry"
KSRC='/mnt/d/Users/Tyler Zhang/Documents/Trae-CN/temp_20261104_07/qemu/kernels'
T=$(mktemp -d /tmp/ferry-kernel-test.XXXXXX) || exit 1
PORT=18080
FAILED=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=$((FAILED + 1)); }
note() { echo "  - $*"; }

cleanup() {
	[ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null
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
m = re.match(r'^@\.mirrors\[@\.name="([^"]+)"\]\.prefix$', expr or '')
if m:
    for it in obj.get('mirrors', []):
        if it.get('name') == m.group(1):
            print(it.get('prefix', ''))
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

echo "===== 1. 全新安装 sing-box 1.8.14（下载+SHA256+激活） ====="
PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.8.14 PMK_OP_URLS="$URL/sing-box-1.8.14-linux-amd64.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.8.14-linux-amd64.tar.gz")" PMK_OP_ACTIVATE=1 \
PMK_OP_RESTART=1 PMK_OP_EXPECT_VERSION=1.8.14 PMK_OP_MIRROR=github \
	run_op install
if job_ok; then pass "安装+激活 1.8.14 成功"; else fail "安装 1.8.14 失败：$(job_code) $(job_msg)"; fi
note "job: $(cat "$PMK_JOB" 2>/dev/null)"
[ -x "$PMK_STORE/singbox/v1.8.14/sing-box" ] && pass "版本库落位 store/singbox/v1.8.14/sing-box" \
	|| fail "版本库缺失"
[ -L "$PMK_BIN_DIR/sing-box" ] && pass "启用指针 $PMK_BIN_DIR/sing-box -> $(readlink "$PMK_BIN_DIR/sing-box")" \
	|| fail "未建立 /usr/bin 启用链接"
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

echo "===== 6. 跨内核切换到 mihomo 1.18.8（停服务→替换→重生成→启动） ====="
PMK_OP_KERNEL=mihomo PMK_OP_VERSION=v1.18.8 PMK_OP_URLS="$URL/mihomo-linux-amd64-v1.18.8.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/mihomo-linux-amd64-v1.18.8.gz")" PMK_OP_ACTIVATE=1 \
PMK_OP_EXPECT_VERSION=1.18.8 \
	run_op install
job_ok && pass "mihomo 1.18.8 安装并启用成功" || fail "mihomo 安装失败：$(job_code) $(job_msg)"
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
[ ! -d "$PMK_STORE/singbox/vfake-arm" ] && pass "架构不符未落位" || fail "架构不符仍落位"

echo "===== 11. 磁盘空间不足 ====="
FAKE_DF=1 PMK_OP_KERNEL=singbox PMK_OP_VERSION=v1.12.0 PMK_OP_URLS="$URL/sing-box-1.12.0-linux-amd64.tar.gz" \
PMK_OP_SHA256="$(sha_of "$T/www/sing-box-1.12.0-linux-amd64.tar.gz")" PMK_OP_ACTIVATE=1 run_op install
if ! job_ok && [ "$(job_code)" = ERR_DISK_FULL ]; then pass "磁盘不足被拦截（ERR_DISK_FULL）"; else
	fail "磁盘检查未拦截：$(job_code) $(job_msg)"
fi

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
  "mirrors": [
    { "name": "github", "label": "GitHub 官方", "prefix": "", "enabled": true, "official": true },
    { "name": "ghproxy", "label": "ghproxy 加速", "prefix": "https://ghproxy.net/", "enabled": false, "official": false },
    { "name": "insecure", "label": "非 HTTPS", "prefix": "http://evil.example/", "enabled": false, "official": false }
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

echo
if [ "$FAILED" -eq 0 ]; then
	echo "RESULT: ALL PASS（离线回归，mock 下载源 + 真实 sing-box/mihomo 二进制）"
	exit 0
fi
echo "RESULT: $FAILED 项失败"
exit 1
