#!/bin/bash
# LuCI ferry 反例 DOM 断言（可重复执行，CI/本地均可）
#
# 覆盖 r6 修复的核心行为：
#   1) 移除 /etc/config/ferry -> 页面出现「配置读取失败」提示 + 「重试」按钮
#   2) 真实失败下表单骨架仍然渲染（标题 / input / select）
#   3) 无未捕获异常、无 `factory yields invalid constructor`
#   4) 还原配置后点「重试」-> 提示消失、表单恢复填充
#
# 全部判定使用 DOM 文本/选择器与控制台异常，不使用截图。
# 需要：qemu-system-x86_64、qemu-img、python3、node、headless Chromium/Chrome。
#
# 常用环境变量：
#   IMG         OpenWrt x86_64 镜像（必填）
#   PKG         luci-app-ferry ipk（默认 dist/luci-app-ferry_1.0.0-r6_all.ipk）
#   QEMUIMG     qemu-img 路径（默认 qemu-img）
#   CHROME_BIN  浏览器路径（默认 google-chrome）
#   NODE_BIN    node 路径（默认 node）
#   WORK        临时目录（默认 /tmp/ferry-dom）
#   CDP_PORT    Chromium 调试端口（默认 9333）
#
# 退出码：断言全通过 0，否则 1（失败不会被吞掉）。
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=${WORK:-/tmp/ferry-dom}
PKG=${PKG:-$REPO/dist/luci-app-ferry_1.0.0-r6_all.ipk}
QEMUIMG=${QEMUIMG:-qemu-img}
CHROME_BIN=${CHROME_BIN:-google-chrome}
NODE_BIN=${NODE_BIN:-node}
SER=${SER:-2601}; SSHP=${SSHP:-2602}; WEB=${WEB:-8091}; HTTP=${HTTP:-8899}
CDP_PORT=${CDP_PORT:-9333}
IMG=${IMG:?需要设置 IMG 指向 OpenWrt x86_64 镜像}

mkdir -p "$WORK/logs"
OVL=$WORK/router.qcow2
LOG=$WORK/logs/serial.log
READY=$WORK/ready.flag
RESTORED=$WORK/restored.flag
OUT=$WORK/luci-dom.json
rm -f "$OVL" "$LOG" "$READY" "$RESTORED" "$OUT"
"$QEMUIMG" create -f qcow2 -F raw -b "$IMG" "$OVL" >/dev/null || exit 1

cleanup() {
	for p in "${QPID:-}" "${CPID:-}" "${HPID:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
}
trap cleanup EXIT

# 包服务（slirp 网关 10.0.2.2 可访问）
( cd "$(dirname "$PKG")" && nohup python3 -m http.server "$HTTP" --bind 0.0.0.0 >/dev/null 2>&1 & echo $! > "$WORK/httpd.pid" )
HPID=$(cat "$WORK/httpd.pid" 2>/dev/null)

qemu-system-x86_64 -m 1024 -smp 2 -display none \
	-serial "tcp:127.0.0.1:$SER,server=on,wait=off,nodelay" \
	-drive "file=$OVL,if=ide,format=qcow2" \
	-netdev "user,id=n1,net=192.168.1.0/24,hostfwd=tcp:127.0.0.1:$SSHP-192.168.1.1:22,hostfwd=tcp:127.0.0.1:$WEB-192.168.1.1:80" \
	-device e1000,netdev=n1 \
	-netdev "user,id=n2" \
	-device e1000,netdev=n2 \
	-no-shutdown -monitor none >> "$WORK/logs/qemu.out" 2>&1 &
QPID=$!

ser() { python3 "$HERE/qemu/serial_exec.py" "$SER" "$LOG" "$1" "${2:-60}" >/dev/null 2>&1; }
touch "$LOG"
ser "echo READY" 200 || { echo "SERIAL_UNREACHABLE"; exit 1; }
sleep 15
ser "printf 'ferrytest\nferrytest\n' | passwd root" 60
ser "uclient-fetch -O /tmp/ferry.ipk http://10.0.2.2:$HTTP/$(basename "$PKG") && opkg install /tmp/ferry.ipk >/tmp/opkg.log 2>&1; echo OPKG_RC=\$?" 240
ser "cp -f /etc/config/ferry /tmp/ferry.bak 2>/dev/null; rm -f /etc/config/ferry; /etc/init.d/uhttpd restart; /etc/init.d/rpcd reload; echo NEG_READY" 120

# headless 浏览器
UD=$WORK/chrome-profile
if [[ "$CHROME_BIN" == *.exe ]]; then UD=$(wslpath -w "$UD" 2>/dev/null || echo "$UD"); fi
"$CHROME_BIN" --headless=new --disable-gpu --no-first-run \
	--remote-debugging-port="$CDP_PORT" --user-data-dir="$UD" about:blank >/dev/null 2>&1 &
CPID=$!
sleep 4

SCRIPT=$HERE/luci-dom-assert.mjs
if [[ "$NODE_BIN" == *.exe ]]; then
	SCRIPT=$(wslpath -w "$SCRIPT")
	NODE_READY=$(wslpath -w "$READY"); NODE_RESTORED=$(wslpath -w "$RESTORED"); NODE_OUT=$(wslpath -w "$OUT")
else
	NODE_READY=$READY; NODE_RESTORED=$RESTORED; NODE_OUT=$OUT
fi

"$NODE_BIN" "$SCRIPT" negative "http://127.0.0.1:$WEB" root ferrytest \
	"$NODE_READY" "$NODE_RESTORED" "$NODE_OUT" &
NPID=$!

# 等脚本请求还原 -> 串口还原配置 -> 放行
for _ in $(seq 1 240); do [ -f "$READY" ] && break; sleep 1; done
if [ -f "$READY" ]; then
	ser "cp -f /tmp/ferry.bak /etc/config/ferry; uci show ferry 2>&1 | head -1; echo RESTORED_END" 60
	touch "$RESTORED"
fi

wait "$NPID"; RC=$?
echo "LUCI_DOM_RC=$RC"
# 安全还原（若上面没还原成功）
ser "cp -f /tmp/ferry.bak /etc/config/ferry 2>/dev/null; echo SAFE_RESTORE" 45

if [ "$RC" -ne 0 ]; then
	echo "RESULT: FAIL"
	python3 - "$OUT" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for r in d.get("results", []):
    if not r.get("ok"):
        print("FAIL_ASSERT:", r.get("name"), r.get("detail", ""))
PY
	exit 1
fi
echo "RESULT: PASS"
exit 0
