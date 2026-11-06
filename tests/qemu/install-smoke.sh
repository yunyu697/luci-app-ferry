#!/bin/bash
# 单机 QEMU 安装冒烟：官方 OpenWrt x86_64 镜像 + 真实 ipk/apk + 真实 mihomo 内核
#
#   bash tests/qemu/install-smoke.sh --release 24.10 --pkg dist/luci-app-ferry_1.0.0-r13_all.ipk \
#        --mihomo /path/mihomo-linux-amd64-v1.19.33.gz [--version 1.0.0-r13] \
#        [--work ~/ferry-qemu-work] [--port-base 2500] [--no-reboot] [--keep]
#
# 验证链路（全部在 guest 内真实执行）：
#   1) 官方镜像启动 → 预装目标 kmods → 安装 ipk(24.10/opkg) 或 apk(25.12/apk)
#   2) 文件/权限/版本元数据/keep.d 断言
#   3) 真实 mihomo 二进制 + redirect 模式拉起服务（进程/端口/nft/status.json）
#   4) WebUI：uhttpd + LuCI 静态视图 + 入口响应
#   5) 卸载：prerm 清理运行态、conffile 与用户数据保留；重装验证升级保留
#   6) 重启：服务自启、配置保留、WebUI 可访问（--no-reboot 可跳过）
#
# 纪律：headless（-display none），不弹窗口；只操作本脚本创建的 QEMU；
#       不接真实机场订阅；镜像固定版本 + SHA-256 校验。
#
# 依赖：Linux + qemu-system-x86_64、curl、gzip、python3、ssh/scp/ssh-keygen、e2fsck/resize2fs。
# 无 /dev/kvm 时自动退回 TCG（纯软件模拟，慢但可重复）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
QEMU="${QEMU_BIN:-$(command -v qemu-system-x86_64 || true)}"
WORK="${FERRY_QEMU_WORK:-$HOME/ferry-qemu-work}"
PORT_BASE="${PORT_BASE:-2500}"
RELEASE=""
PKG=""
MIHOMO="${MIHOMO_BIN:-}"
EXPECT_VER=""
REBOOT=1
KEEP=0
BOOT_TIMEOUT=300

while [ $# -gt 0 ]; do
	case "$1" in
		--release) RELEASE="$2"; shift 2 ;;
		--pkg) PKG="$2"; shift 2 ;;
		--mihomo) MIHOMO="$2"; shift 2 ;;
		--version) EXPECT_VER="$2"; shift 2 ;;
		--work) WORK="$2"; shift 2 ;;
		--port-base) PORT_BASE="$2"; shift 2 ;;
		--boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;;
		--no-reboot) REBOOT=0; shift ;;
		--keep) KEEP=1; shift ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

# prepare-image.sh 里的 e2fsck/resize2fs 在非 root 的 PATH 里可能不在
PATH="$PATH:/usr/sbin:/sbin"

case "$RELEASE" in
	24.10)
		REL="24.10.5"
		REL_FILE="openwrt-24.10.5-x86-64-generic-ext4-combined.img.gz"
		REL_SHA="5b854a7a2909a0b21887ba9be773b0964eb28fef81d6b8399d32a0f270a5d8ff"
		KIND=ipk
		;;
	25.12)
		REL="25.12.0"
		REL_FILE="openwrt-25.12.0-x86-64-generic-ext4-combined.img.gz"
		REL_SHA="7f33f26f89a7096aa549ec45aa80e07577a3e69c725772a5fa4b8c18df38aeaa"
		KIND=apk
		;;
	*)
		echo "用法：--release 24.10|25.12" >&2
		exit 2
		;;
esac

[ -f "$PKG" ] || { echo "missing/!exists --pkg" >&2; exit 2; }
case "$KIND:$PKG" in
	ipk:*.apk) echo "--pkg 与 --release 不匹配：24.10 需要 ipk" >&2; exit 2 ;;
	apk:*.ipk) echo "--pkg 与 --release 不匹配：25.12 需要 apk" >&2; exit 2 ;;
esac
[ -f "$MIHOMO" ] || { echo "missing --mihomo（amd64 内核 .gz）" >&2; exit 2; }
[ -x "$QEMU" ] || { echo "qemu-system-x86_64 不可用" >&2; exit 2; }
for t in curl gzip python3 ssh scp ssh-keygen sha256sum; do
	command -v "$t" >/dev/null 2>&1 || { echo "缺少依赖：$t" >&2; exit 2; }
done

if [ -z "$EXPECT_VER" ]; then
	V="$(sed -n 's/^PKG_VERSION:=//p' "$REPO/Makefile" | head -1)"
	R="$(sed -n 's/^PKG_RELEASE:=//p' "$REPO/Makefile" | head -1)"
	EXPECT_VER="${V}-r${R}"
fi

IMG="$WORK/images"
LOGS="$WORK/logs/$RELEASE"
RUN="$WORK/run/$RELEASE"
KEY="$WORK/id_ed25519"
SSHP=$((PORT_BASE + 1))
SER=$((PORT_BASE + 2))
URL="https://downloads.openwrt.org/releases/$REL/targets/x86/64/$REL_FILE"
KMODS_URL="https://downloads.openwrt.org/releases/$REL/targets/x86/64/kmods/"

mkdir -p "$IMG" "$LOGS" "$RUN" "$WORK/pkgs/$RELEASE"
rm -rf "$RUN"/*
: >"$LOGS/serial.log"
: >"$LOGS/guest.log"
: >"$LOGS/host.log"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOGS/host.log" >&2; }
fail() { log "FAILED: $*"; exit 1; }

# WSL/部分网络下 downloads.openwrt.org 的 TLS 握手会偶发失败，curl 自带 --retry 不覆盖握手错误，
# 这里统一做 3 次重试（成功即返回，stdout 就是响应内容）。
fetch_url() {
	local url="$1" out="$2" i=0
	while [ "$i" -lt 3 ]; do
		if [ -n "$out" ]; then
			curl -fsSL --http1.1 -o "$out" "$url" && return 0
		else
			curl -fsSL --http1.1 "$url" && return 0
		fi
		i=$((i + 1))
		sleep 2
	done
	return 1
}

port_free() {
	python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}
port_free "$SSHP" || fail "端口 $SSHP 被占用（用 --port-base 换一组）"
port_free "$SER" || fail "端口 $SER 被占用（用 --port-base 换一组）"

ACCEL=""
[ -w /dev/kvm ] && ACCEL="-enable-kvm"

# ---------------------------------------------------------------------------
# 镜像：下载 + SHA-256 校验 + 解压 + rootfs 扩容（ext4-combined，可 resize2fs）
# ---------------------------------------------------------------------------
GZ="$IMG/$REL_FILE"
if [ ! -f "$GZ" ]; then
	log "下载 $REL 镜像（一次性缓存）"
	curl -fsSL --retry 2 --http1.1 -o "$GZ.part" "$URL" || fetch_url "$URL" "$GZ.part" || fail "镜像下载失败：$URL"
	mv -f "$GZ.part" "$GZ"
fi
echo "$REL_SHA  $GZ" | sha256sum -c --status || fail "镜像 SHA-256 校验失败（期望 $REL_SHA）"
log "镜像校验通过：$REL"

BASE="$IMG/$REL-base.img"
if [ ! -f "$BASE" ]; then
	log "解压镜像"
	# 官方 .gz 尾部常带多余字节：gzip 只警告「trailing garbage ignored」并以 rc=2 退出。
	# 只要没有截断/损坏错误，就认为解压成功（再用大小下限兜底）。
	gzip -dc "$GZ" >"$BASE.part" 2>"$LOGS/gzip.err" || true
	if grep -qiE 'unexpected end|invalid compressed|corrupt|not in gzip' "$LOGS/gzip.err"; then
		rm -f "$BASE.part"
		fail "解压失败：$(head -2 "$LOGS/gzip.err" | tr '\n' ' ')"
	fi
	RAW=$(stat -c%s "$BASE.part" 2>/dev/null || echo 0)
	[ "$RAW" -ge 100000000 ] || { rm -f "$BASE.part"; fail "解压产物过小（$RAW bytes）"; }
	mv -f "$BASE.part" "$BASE"
fi
BIG="$IMG/$REL-big.img"
if [ ! -f "$BIG" ]; then
	log "扩容 rootfs 到 800MB"
	bash "$HERE/prepare-image.sh" "$BASE" "$BIG" 800 >/dev/null || fail "扩容失败"
fi

DISK="$RUN/disk.img"
log "准备本次运行磁盘副本"
cp -f --reflink=auto "$BIG" "$DISK" 2>/dev/null || cp -f "$BIG" "$DISK"

# ---------------------------------------------------------------------------
# QEMU 生命周期
# ---------------------------------------------------------------------------
QPID=""
cleanup() {
	[ -n "$QPID" ] && kill -9 "$QPID" 2>/dev/null
	QPID=""
}
on_exit() { [ "$KEEP" = 1 ] || cleanup; }
trap on_exit EXIT

start_vm() {
	# hostfwd 必须指向 guest 的 LAN 地址（192.168.1.1）；写成 "-:22" 会被转到 slirp 网关
	# 192.168.1.2，表现为 TCP 通但 SSH banner 超时（已实测踩过）。
	# shellcheck disable=SC2086
	"$QEMU" $ACCEL -m 1024 -smp 2 -display none \
		-serial "tcp:127.0.0.1:$SER,server=on,wait=off,nodelay" \
		-drive "file=$DISK,if=ide,format=raw" \
		-netdev "user,id=n1,net=192.168.1.0/24,host=192.168.1.2,dhcpstart=192.168.1.10,hostfwd=tcp:127.0.0.1:$SSHP-192.168.1.1:22" \
		-device e1000,netdev=n1 -no-shutdown -monitor none \
		>>"$LOGS/qemu.out" 2>&1 &
	QPID=$!
	sleep 1
	kill -0 "$QPID" 2>/dev/null || { tail -5 "$LOGS/qemu.out" >&2; fail "QEMU 启动失败"; }
}

wait_serial() {
	local i=0
	while [ "$i" -lt "$BOOT_TIMEOUT" ]; do
		if python3 "$HERE/serial_exec.py" "$SER" "$LOGS/serial.log" "echo READY" 30 >/dev/null 2>&1; then
			return 0
		fi
		sleep 5
		i=$((i + 5))
	done
	return 1
}

ssh_common=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o BatchMode=yes -o ConnectTimeout=8)
rsh() { ssh -p "$SSHP" -i "$KEY" "${ssh_common[@]}" root@127.0.0.1 "$@"; }
rcp() {
	scp -O -P "$SSHP" -i "$KEY" "${ssh_common[@]}" "$1" "root@127.0.0.1:$2" >/dev/null || return 1
}

wait_ssh() {
	local i=0
	while [ "$i" -lt "$BOOT_TIMEOUT" ]; do
		rsh "echo up" 2>/dev/null | grep -q up && return 0
		sleep 3
		i=$((i + 3))
	done
	return 1
}

inject_key() {
	local pub rest chunk
	pub=$(tr -d '\r\n' <"$KEY.pub")
	python3 "$HERE/serial_exec.py" "$SER" "$LOGS/serial.log" \
		"mkdir -p /root/.ssh; : > /root/.ssh/authorized_keys" 60 >/dev/null 2>&1
	rest="$pub"
	while [ -n "$rest" ]; do
		chunk=${rest:0:40}
		rest=${rest:40}
		python3 "$HERE/serial_exec.py" "$SER" "$LOGS/serial.log" \
			"printf '%s' '$chunk' >> /root/.ssh/authorized_keys" 60 >/dev/null 2>&1
	done
	python3 "$HERE/serial_exec.py" "$SER" "$LOGS/serial.log" \
		"chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys" 60 >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# kmods：官方 x86 feed 不带目标 kmods，按 guest 的 uname -r 精确抓取
# ---------------------------------------------------------------------------
fetch_kmods() {
	local kver dir p fn tmp
	kver=$(rsh "uname -r" 2>/dev/null | tr -d '\r')
	[ -n "$kver" ] || fail "无法从 guest 读取内核版本"
	log "guest kernel=$kver"
	tmp="$WORK/kmods-index-$RELEASE.html"
	fetch_url "$KMODS_URL" "$tmp" || true
	dir=$(grep -o 'href="[0-9][^"]*"' "$tmp" 2>/dev/null | sed 's/href="//; s/"//' | grep "^$kver-" | head -1)
	if [ -z "$dir" ]; then
		# releases 是固定版本，kmods 目录名也随之固定；列表页偶发不可达时用固定映射兜底
		case "$REL" in
			24.10.5) dir="6.6.119-1-484466e2719a743506c36b4bb2103582" ;;
			25.12.0) dir="6.12.71-1-dad96e0b324e75e311f44d061391d208" ;;
		esac
		log "WARN kmods 列表不可达，回退固定目录 $dir"
	fi
	case "$dir" in
		"$kver"-*) ;;
		*) fail "kmods 目录与 guest 内核不匹配（kver=$kver dir=$dir）" ;;
	esac
	mkdir -p "$WORK/pkgs/$RELEASE/$dir"
	[ -s "$tmp" ] || fetch_url "$KMODS_URL/$dir/" "$tmp" || fail "kmods 列表下载失败"
	for p in kmod-nft-core kmod-nft-nat kmod-nf-tproxy kmod-nft-tproxy kmod-tun; do
		fn=$(grep -o "href=\"${p}[-_][^\"]*\"" "$tmp" 2>/dev/null | sed 's/href="//; s/"//' | head -1)
		[ -n "$fn" ] || { log "WARN 未找到 $p"; continue; }
		# 逐个文件缓存（目录非空不代表齐全：依赖可能新增）
		if [ ! -s "$WORK/pkgs/$RELEASE/$dir/$fn" ]; then
			fetch_url "$KMODS_URL/$dir/$fn" "$WORK/pkgs/$RELEASE/$dir/$fn" ||
				log "WARN $p 下载失败"
		fi
	done
	KMOD_DIR="$WORK/pkgs/$RELEASE/$dir"
	log "kmods: $(ls "$KMOD_DIR" | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# 启动并准备
# ---------------------------------------------------------------------------
[ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -f "$KEY" >/dev/null

log "release=$REL kind=$KIND accel=${ACCEL:-tcg}"
start_vm
log "等待 guest 串口"
wait_serial || { tail -10 "$LOGS/qemu.out" >&2; fail "串口启动超时"; }
sleep 8
inject_key
wait_ssh || { inject_key; wait_ssh; } || fail "SSH 未就绪"
log "SSH 就绪"

fetch_kmods

log "上传包/内核/配置/测试脚本"
rcp "$PKG" "/tmp/ferry.$KIND" || fail "上传包失败"
rcp "$MIHOMO" /tmp/mihomo.gz || fail "上传内核失败"
rcp "$HERE/test-config.yaml" /tmp/test-config.yaml || fail "上传测试配置失败"
rcp "$HERE/guest/install-smoke.sh" /tmp/install-smoke.sh || fail "上传测试脚本失败"
rcp "$HERE/guest/install-smoke-boot.sh" /tmp/install-smoke-boot.sh || fail "上传重启测试脚本失败"
for f in "$KMOD_DIR"/*; do
	[ -f "$f" ] && rcp "$f" "/tmp/$(basename "$f")"
done

# ---------------------------------------------------------------------------
# 阶段一：安装 → 服务 → WebUI → 卸载/升级保留
# ---------------------------------------------------------------------------
log "阶段一：安装冒烟开始"
rsh "sh /tmp/install-smoke.sh '$KIND' '$EXPECT_VER' '$REL'" 2>&1 | tee -a "$LOGS/guest.log"
SUM1=$(grep -o 'INSTALL_SMOKE_DONE PASS=[0-9]* FAIL=[0-9]*' "$LOGS/guest.log" | tail -1)
[ -n "$SUM1" ] || fail "guest 未输出安装冒烟结果（脚本中断）"
echo "$SUM1" | tee -a "$LOGS/host.log"
P1=$(echo "$SUM1" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')
F1=$(echo "$SUM1" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p')

# ---------------------------------------------------------------------------
# 阶段二：重启持久化（可选）
# ---------------------------------------------------------------------------
SUM2=""
P2=0
F2=0
if [ "$REBOOT" = 1 ]; then
	log "阶段二：重启持久化"
	rsh "reboot" >/dev/null 2>&1 || true
	# QEMU 进程不退出（-no-shutdown），只是 guest 重启；串口/SSH 短暂不可用后自行恢复
	sleep 10
	wait_serial || fail "重启后串口未恢复"
	wait_ssh || { inject_key; wait_ssh; } || fail "重启后 SSH 未恢复"
	log "重启后 SSH 就绪"
	# /tmp 是 tmpfs，重启即清空：脚本需要重新上传
	rcp "$HERE/guest/install-smoke-boot.sh" /tmp/install-smoke-boot.sh || fail "重启后上传断言脚本失败"
	rsh "sh /tmp/install-smoke-boot.sh '$KIND'" 2>&1 | tee -a "$LOGS/guest.log"
	SUM2=$(grep -o 'BOOT_SMOKE_DONE PASS=[0-9]* FAIL=[0-9]*' "$LOGS/guest.log" | tail -1)
	if [ -n "$SUM2" ]; then
		echo "$SUM2" | tee -a "$LOGS/host.log"
		P2=$(echo "$SUM2" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')
		F2=$(echo "$SUM2" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p')
	else
		log "WARN 重启阶段无结果标记（脚本中断）"
		F2=1
	fi
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
SUM="$WORK/report"
mkdir -p "$SUM"
REPORT="$SUM/install-smoke-$RELEASE.md"
{
	echo "# Ferry QEMU 安装冒烟（$REL / $KIND）"
	echo
	echo "- 固件：OpenWrt $REL x86_64 ext4-combined（SHA-256 校验通过）"
	echo "- 加速：${ACCEL:-tcg（无可用 /dev/kvm）}"
	echo "- 包：$(basename "$PKG")，期望版本 $EXPECT_VER"
	echo "- 结果：安装阶段 PASS=$P1 FAIL=$F1；重启阶段 PASS=$P2 FAIL=$F2"
	echo "- 日志：$LOGS/guest.log / $LOGS/serial.log"
	echo
	echo "## 断言明细"
	grep -E '^PASS:|^FAIL:' "$LOGS/guest.log" 2>/dev/null
} >"$REPORT"
log "报告：$REPORT"

[ "${P1:-0}" -gt 0 ] && [ "${F1:-1}" = 0 ] && [ "${F2:-1}" = 0 ]
