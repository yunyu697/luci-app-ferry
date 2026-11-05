#!/bin/bash
# F1 真机流量验收（可重复执行，headless QEMU，串口落盘）
#
#   bash tests/qemu/run-acceptance.sh --pkg <ipk|apk> --mihomo <mihomo 二进制>
#        [--firmware owrt|imm] [--suite full|smoke]
#        [--router-image <raw .img>] [--client-image <raw .img>]
#        [--work /mnt/d/ferry-qemu-work] [--port-base 2300] [--keep]
#
# 流程：自建 2 台 QEMU（router = slirp WAN + socket LAN；client = socket LAN）
#   -> 安装包 + direct 出站内核 -> 基线 apply/confirm -> 局域网客户端 fake-ip DNS
#   -> TPROXY 命中 -> HTTP 200 -> 不接管 vs 接管对照 -> 回滚/崩溃/临时关闭/诊断包
#
# 纪律：-display none，不开窗口；只操作本脚本创建的 QEMU；不接真实机场订阅。
# 依赖（WSL）：qemu（Windows 版）、qemu-img、python3、ssh/scp、curl、e2fsprogs。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
QEMU="${QEMU_BIN:-$(command -v qemu-system-x86_64 || true)}"
QEMUIMG="${QEMUIMG_BIN:-$(command -v qemu-img || true)}"
ACCEL=""
[ -w /dev/kvm ] && ACCEL="-enable-kvm"
WORK="${FERRY_QEMU_WORK:-/mnt/d/ferry-qemu-work}"
PKG=""
MIHOMO=""
FW=owrt
SUITE=full
RIMAGE=""
CIMAGE=""
BASE=2300
KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--pkg) PKG="$2"; shift 2 ;;
		--mihomo) MIHOMO="$2"; shift 2 ;;
		--firmware) FW="$2"; shift 2 ;;
		--suite) SUITE="$2"; shift 2 ;;
		--router-image) RIMAGE="$2"; shift 2 ;;
		--client-image) CIMAGE="$2"; shift 2 ;;
		--work) WORK="$2"; shift 2 ;;
		--port-base) BASE="$2"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

[ -n "$PKG" ] && [ -f "$PKG" ] || { echo "missing --pkg" >&2; exit 2; }
[ -n "$MIHOMO" ] && [ -f "$MIHOMO" ] || { echo "missing --mihomo" >&2; exit 2; }
[ -x "$QEMU" ] || { echo "qemu not found: $QEMU" >&2; exit 2; }
[ -x "$QEMUIMG" ] || { echo "qemu-img not found: $QEMUIMG" >&2; exit 2; }
case "$PKG" in *.apk) KIND=apk; FW=${FW:-imm} ;; *) KIND=ipk ;; esac
[ "$KIND" = apk ] && FW=imm

IMG="$WORK/images"
LOGS="$WORK/logs"
RUN="$WORK/run"
KEY="$WORK/id_ed25519"
R_SSH=$((BASE + 1)); R_SER=$((BASE + 101))
C_SSH=$((BASE + 3)); C_SER=$((BASE + 103))
LAN=$((BASE + 201))
mkdir -p "$IMG" "$LOGS" "$RUN"
rm -rf "$RUN"/*
rm -f "$LOGS"/*.log "$LOGS"/*.out
: > "$LOGS/serial-router.log"; : > "$LOGS/serial-client.log"; : > "$LOGS/driver.log"

log() { printf '\033[1m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOGS/driver.log" >&2; }

# 端口预检（全部在同一个 WSL/Linux 命名空间内）
port_busy() { ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$1$"; }
for p in "$R_SSH" "$R_SER" "$C_SSH" "$C_SER" "$LAN"; do
	if port_busy "$p"; then
		echo "端口 $p 已被占用：请先停止旧的测试 QEMU（或用 --port-base 换一组端口）" >&2
		exit 2
	fi
done

# ---------------------------------------------------------------------------
# 镜像：下载（缺失时）+ 扩容 rootfs，原镜像只读，测试用 qcow2 覆盖层
# ---------------------------------------------------------------------------
image_url() {
	case "$FW" in
		owrt) echo "https://downloads.openwrt.org/releases/24.10.4/targets/x86/64/openwrt-24.10.4-x86-64-generic-ext4-combined.img.gz" ;;
		imm)  echo "https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/immortalwrt-25.12.2-x86-64-generic-ext4-combined.img.gz" ;;
	esac
}

ensure_image() { # $1=raw 或空, $2=name；返回扩容后的原镜像路径
	local raw="$1" name="$2" base big
	if [ -z "$raw" ]; then
		if [ ! -f "$IMG/$FW-$name.img.gz" ] && [ ! -f "$IMG/$FW-$name.img" ]; then
			log "下载 $FW 镜像（一次性，缓存到 $IMG/$FW-$name.img.gz）"
			curl -fL --retry 2 -o "$IMG/$FW-$name.img.gz" "$(image_url)" || { echo "image download failed" >&2; exit 1; }
		fi
		raw="$IMG/$FW-$name.img.gz"
	fi
	# 注意：解压/扩容产物按固件名隔离，避免 owrt 与 imm 复用同一缓存
	base="$IMG/$FW-base-$name.img"
	big="$IMG/$FW-base-$name-big.img"
	[ -f "$base" ] || {
		case "$raw" in
			*.gz) gzip -dc "$raw" > "$base" ;;
			*) cp -f "$raw" "$base" ;;
		esac
	}
	[ -f "$big" ] || bash "$HERE/prepare-image.sh" "$base" "$big" 800 >/dev/null || exit 1
	echo "$big"
}

if [ -n "$RIMAGE" ]; then RIMAGE="$(ensure_image "$RIMAGE" router)"; else RIMAGE="$(ensure_image "" router)"; fi
[ -f "$RIMAGE" ] || { echo "router image missing: $RIMAGE" >&2; exit 1; }
if [ -n "$CIMAGE" ]; then CIMAGE="$(ensure_image "$CIMAGE" client)"; else CIMAGE="$RIMAGE"; fi
[ -f "$CIMAGE" ] || { echo "client image missing: $CIMAGE" >&2; exit 1; }

for pair in "router:$RIMAGE" "client:$CIMAGE"; do
	n="${pair%%:*}"; src="${pair#*:}"
	rm -f "$IMG/$n-run.qcow2"
	"$QEMUIMG" create -f qcow2 -F raw -b "$src" "$IMG/$n-run.qcow2" >/dev/null || exit 1
done

# ---------------------------------------------------------------------------
# 宿主机预下载 TPROXY 内核模块（官方 x86_64 feeds 不含 .../kmods/<kver>/）
# ---------------------------------------------------------------------------
ensure_kmods() {
	[ "$FW" = owrt ] || return 0
	local base="https://downloads.openwrt.org/releases/24.10.4/targets/x86/64/kmods"
	mkdir -p "$WORK/pkgs"
	local kdir fn p
	kdir=$(curl -fsSL "$base/" 2>/dev/null | grep -o '6\.[0-9][0-9.]*-1-[0-9a-f]*' | head -1)
	[ -n "$kdir" ] || { log "kmods 目录解析失败，guest 将回退 feed 安装"; return 0; }
	if [ ! -f "$WORK/pkgs/Packages" ]; then
		curl -fsSL "$base/$kdir/Packages.gz" -o "$WORK/pkgs/Packages.gz" 2>/dev/null || return 0
		gunzip -f "$WORK/pkgs/Packages.gz" >/dev/null 2>&1
	fi
	for p in kmod-nft-tproxy kmod-nf-tproxy; do
		[ -s "$WORK/pkgs/$p.ipk" ] && continue
		fn=$(awk -v p="$p" '$1=="Package:"{cur=$2} cur==p && $1=="Filename:"{print $2}' "$WORK/pkgs/Packages")
		[ -n "$fn" ] && curl -fsSL "$base/$kdir/$fn" -o "$WORK/pkgs/$p.ipk" 2>/dev/null
	done
	log "kmods 缓存: $(ls "$WORK/pkgs"/*.ipk 2>/dev/null | wc -l)/2"
}

ensure_kmods

# ---------------------------------------------------------------------------
# QEMU 生命周期
# ---------------------------------------------------------------------------
start_vm() { # name serial ssh img lanmode
	local name=$1 ser=$2 sshp=$3 img=$4 lanmode=$5
	"$QEMU" $ACCEL -m 1024 -smp 2 -display none \
		-serial "tcp:127.0.0.1:$ser,server=on,wait=off,nodelay" \
		-drive "file=$img,if=ide,format=qcow2" \
		-netdev "user,id=n1,hostfwd=tcp:127.0.0.1:$sshp-:22" \
		-device e1000,netdev=n1 \
		-netdev "socket,id=lan,$lanmode=127.0.0.1:$LAN" \
		-device e1000,netdev=lan \
		-no-shutdown -monitor none \
		>>"$LOGS/qemu-$name.out" 2>&1 &
	echo $! > "$RUN/$name.pid"
	sleep 1
	kill -0 "$(cat "$RUN/$name.pid")" 2>/dev/null || {
		echo "$name QEMU 启动失败：" >&2
		tail -5 "$LOGS/qemu-$name.out" >&2
		exit 1
	}
	[ "$lanmode" = listen ] && sleep 2
}

stop_vm() { # name
	local f="$RUN/$1.pid"
	[ -f "$f" ] || return 0
	local p; p=$(cat "$f")
	kill -9 "$p" 2>/dev/null
	sleep 1
	rm -f "$f"
}

cleanup() { stop_vm client; stop_vm router; }
trap '[ "$KEEP" = 1 ] || cleanup' EXIT

wait_serial() { # port log timeout
	local n=0
	while [ $n -lt 3 ]; do
		python3 "$HERE/serial_exec.py" "$1" "$2" "echo READY" "${3:-150}" >/dev/null 2>&1 && return 0
		n=$((n + 1)); sleep 5
	done
	return 1
}

wait_ssh() { # timeout port
	local i=0
	while [ $i -lt "${1:-150}" ]; do
		ssh -p "$2" -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			-o BatchMode=yes -o ConnectTimeout=3 root@127.0.0.1 "echo up" 2>/dev/null | grep -q up && return 0
		sleep 2; i=$((i + 2))
	done
	return 1
}

rsh() { ssh -p "$R_SSH" -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o BatchMode=yes -o ConnectTimeout=8 root@127.0.0.1 "$@"; }
csh() { ssh -p "$C_SSH" -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o BatchMode=yes -o ConnectTimeout=8 root@127.0.0.1 "$@"; }
rcp() { scp -O -P "$R_SSH" -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o BatchMode=yes "$1" "root@127.0.0.1:$2" >/dev/null; }
ccp() { scp -O -P "$C_SSH" -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o BatchMode=yes "$1" "root@127.0.0.1:$2" >/dev/null; }

rrun() { # local-script [args]
	local s n; s="$1"; n=$(basename "$1"); shift
	rcp "$s" "/tmp/$n"
	rsh "sh /tmp/$n $*" 2>&1 | tee -a "$LOGS/$n.log"
}
crun() { # local-script [args]
	local n s; s="$1"; n=$(basename "$1"); shift
	ccp "$s" "/tmp/$n"
	csh "sh /tmp/$n $*" 2>&1 | tee -a "$LOGS/client-$n.log"
}

# QEMU slirp 的 hostfwd 需要 guest 有地址；x86 镜像默认 lan=br-lan(eth0)、wan=eth1。
# 测试拓扑固定为：
#   router  eth0=WAN（slirp DHCP，管理/出网）、eth1=LAN 203.0.113.1（socket 虚拟链路）
#   client  br-lan/eth0=管理（slirp DHCP）、eth1=LAN 203.0.113.2
# 串口控制台有 ~80 列换行问题，长命令会被折断；逐条短命令下发。
ser_cmd() { # serial log cmd...
	local ser="$1" log="$2" c
	shift 2
	for c in "$@"; do
		python3 "$HERE/serial_exec.py" "$ser" "$log" "$c" 60 >/dev/null 2>&1
	done
}

bootstrap_net() { # role(router|client) serial log
	local role="$1" ser="$2" log="$3" i=0
	if [ "$role" = router ]; then
		ser_cmd "$ser" "$log" \
			"uci -q delete 'network.@device[0]'" \
			"uci set network.lan.device='eth1'" \
			"uci set network.lan.proto='static'" \
			"uci set network.lan.ipaddr='203.0.113.1'" \
			"uci set network.lan.netmask='255.255.255.0'" \
			"uci -q delete network.lan.ip6assign" \
			"uci set network.wan=interface" \
			"uci set network.wan.device='eth0'" \
			"uci set network.wan.proto='dhcp'" \
			"uci set firewall.allow_test_ssh=rule" \
			"uci set firewall.allow_test_ssh.name='AllowTestSSH'" \
			"uci set firewall.allow_test_ssh.src='wan'" \
			"uci set firewall.allow_test_ssh.proto='tcp'" \
			"uci set firewall.allow_test_ssh.dest_port='22'" \
			"uci set firewall.allow_test_ssh.target='ACCEPT'"
	else
		ser_cmd "$ser" "$log" \
			"uci set network.lan.proto='dhcp'" \
			"uci -q delete network.lan.ipaddr" \
			"uci -q delete network.lan.netmask" \
			"uci -q delete network.lan.gateway" \
			"uci -q delete network.wan" \
			"uci -q delete network.wan6" \
			"uci set network.lan2=interface" \
			"uci set network.lan2.device='eth1'" \
			"uci set network.lan2.proto='static'" \
			"uci set network.lan2.ipaddr='203.0.113.2'" \
			"uci set network.lan2.netmask='255.255.255.0'"
	fi
	ser_cmd "$ser" "$log" \
		"uci commit network" \
		"uci commit firewall" \
		"uci -q delete dropbear.@dropbear[0].Interface" \
		"uci commit dropbear" \
		"/etc/init.d/dropbear restart" \
		"/etc/init.d/network restart" \
		"/etc/init.d/firewall restart"
	# 管理面必须继续走 slirp：两台的 eth0 侧都要拿到 10.0.2.x
	while [ $i -lt 40 ]; do
		python3 "$HERE/serial_exec.py" "$ser" "$log" "ip -4 -o addr show" 20 >/dev/null 2>&1
		tail -60 "$log" | grep -q 'inet 10\.0\.2' && return 0
		sleep 2; i=$((i + 2))
	done
	return 1
}

inject_key() { # serial port
	local pub rest chunk
	pub=$(tr -d '\r\n' < "$KEY.pub")
	python3 "$HERE/serial_exec.py" "$1" "$2" \
		"mkdir -p /root/.ssh; : > /root/.ssh/authorized_keys" 60 >/dev/null 2>&1
	rest="$pub"
	while [ -n "$rest" ]; do
		chunk=${rest:0:40}
		rest=${rest:40}
		python3 "$HERE/serial_exec.py" "$1" "$2" \
			"printf '%s' '$chunk' >> /root/.ssh/authorized_keys" 60 >/dev/null 2>&1
	done
	python3 "$HERE/serial_exec.py" "$1" "$2" \
		"chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys; wc -c < /root/.ssh/authorized_keys" 60 >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------
[ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -f "$KEY" >/dev/null
log "router image: $RIMAGE"
log "client image: $CIMAGE"
log "package: $PKG ($KIND)"
start_vm router "$R_SER" "$R_SSH" "$IMG/router-run.qcow2" listen
start_vm client "$C_SER" "$C_SSH" "$IMG/client-run.qcow2" connect

log "等待串口进入 root shell"
wait_serial "$R_SER" "$LOGS/serial-router.log" 180 || {
	tail -5 "$LOGS/qemu-router.out" >&2; echo "router serial timeout" >&2; exit 1; }
wait_serial "$C_SER" "$LOGS/serial-client.log" 180 || {
	tail -5 "$LOGS/qemu-client.out" >&2; echo "client serial timeout" >&2; exit 1; }
# 等 init 把控制台完全交还给登录 shell，避免命令在控制台切换时丢失
sleep 10
bootstrap_net router "$R_SER" "$LOGS/serial-router.log" || { echo "router network bootstrap failed" >&2; exit 1; }
bootstrap_net client "$C_SER" "$LOGS/serial-client.log" || { echo "client network bootstrap failed" >&2; exit 1; }
inject_key "$R_SER" "$LOGS/serial-router.log"
inject_key "$C_SER" "$LOGS/serial-client.log"
wait_ssh 120 "$R_SSH" || { inject_key "$R_SER" "$LOGS/serial-router.log"; wait_ssh 120 "$R_SSH"; } || {
	echo "router ssh timeout" >&2; exit 1; }
wait_ssh 120 "$C_SSH" || { inject_key "$C_SER" "$LOGS/serial-client.log"; wait_ssh 120 "$C_SSH"; } || {
	echo "client ssh timeout" >&2; exit 1; }
log "SSH 就绪"

# ---------------------------------------------------------------------------
# 准备与安装
# ---------------------------------------------------------------------------
log "路由器网络准备"
rrun "$HERE/guest/00-router-net.sh"
log "客户端网络准备"
crun "$HERE/client/00-client-net.sh" "$KIND"

log "上传包 / 内核 / 测试配置"
if [ "$KIND" = apk ]; then
	rcp "$PKG" /tmp/ferry.apk
else
	rcp "$PKG" /tmp/ferry.ipk
fi
rcp "$MIHOMO" /tmp/mihomo
rcp "$HERE/test-config.yaml" /tmp/test-config.yaml
for f in "$WORK"/pkgs/kmod-*.ipk; do
	[ -s "$f" ] && rcp "$f" "/tmp/$(basename "$f")"
done
for f in "$WORK"/pkgs/imm-kmods/*.apk; do
	[ -s "$f" ] && rcp "$f" "/tmp/$(basename "$f")"
done
log "安装与配置"
rrun "$HERE/guest/01-install.sh" "$KIND"
log "建立已确认基线"
rrun "$HERE/guest/02-baseline.sh"

tr_fake() { log "客户端流量：接管形态（fake-ip）"; crun "$HERE/client/01-traffic.sh" fake; }
tr_real() { log "客户端流量：不接管形态（原始 DNS）"; crun "$HERE/client/01-traffic.sh" real; }
tr_fake

if [ "$SUITE" = full ]; then
	log "证据①：apply 后不确认，等待 60s 超时回滚（断开控制面）"
	rrun "$HERE/guest/03-apply-pending.sh"
	sleep 70
	rrun "$HERE/guest/03-assert-rollback.sh"
	tr_fake

	log "证据②-B：杀掉看门狗 + 服务重启检测"
	rrun "$HERE/guest/04-crash-b.sh"
	tr_fake

	log "证据②-C：硬断电重启（kill -9 QEMU）"
	rrun "$HERE/guest/03-apply-pending.sh"
	# socket LAN 不会自动重连：两台 QEMU 都重启，保持 eth1 链路
	stop_vm client
	stop_vm router
	sleep 2
	start_vm router "$R_SER" "$R_SSH" "$IMG/router-run.qcow2" listen
	start_vm client "$C_SER" "$C_SSH" "$IMG/client-run.qcow2" connect
	wait_serial "$R_SER" "$LOGS/serial-router.log" 180 || { echo "router reboot serial timeout"; exit 1; }
	wait_serial "$C_SER" "$LOGS/serial-client.log" 180 || { echo "client reboot serial timeout"; exit 1; }
	wait_ssh 240 "$R_SSH" || { echo "router reboot ssh timeout"; exit 1; }
	wait_ssh 240 "$C_SSH" || { echo "client reboot ssh timeout"; exit 1; }
	sleep 8
	# 断电重启后客户端默认路由（运行时 ip route）会丢失，重跑网络脚本再断言
	crun "$HERE/client/00-client-net.sh" "$KIND"
	rrun "$HERE/guest/07-assert-crash-c.sh"
	tr_fake
fi

log "证据③：临时关闭 -> 客户端走原始上游 -> 恢复 -> 客户端恢复 fake-ip"
rrun "$HERE/guest/05-tmpctl-off.sh"
tr_real
rrun "$HERE/guest/05-tmpctl-on.sh"
tr_fake

log "证据④：诊断包 + 脱敏断言"
rrun "$HERE/guest/06-diag.sh"

# ---------------------------------------------------------------------------
# PASS/FAIL 汇总
# ---------------------------------------------------------------------------
SUM="$WORK/report"
mkdir -p "$SUM"
ALL="$LOGS/driver.log"
for f in "$LOGS"/*.log; do
	[ "$f" = "$ALL" ] && continue
	cat "$f" >> "$ALL"
done
P=$(grep -c '^PASS:' "$ALL" 2>/dev/null || echo 0)
F=$(grep -c '^FAIL:' "$ALL" 2>/dev/null || echo 0)
{
	echo "# Ferry F1 QEMU 验收报告"
	echo
	echo "- 固件：$FW"
	echo "- 包：$(basename "$PKG") ($KIND)"
	echo "- 结果：PASS=$P FAIL=$F"
	echo "- 串口：$LOGS/serial-router.log / $LOGS/serial-client.log"
	echo
	echo "## 断言明细"
	grep -E '^PASS:|^FAIL:' "$ALL" 2>/dev/null
} > "$SUM/summary.md"
cp "$LOGS/serial-router.log" "$SUM/serial-router.log" 2>/dev/null
cp "$LOGS/serial-client.log" "$SUM/serial-client.log" 2>/dev/null

log "PASS=$P FAIL=$F"
log "报告：$SUM/summary.md"
[ "$P" -gt 0 ] && [ "$F" = 0 ]
