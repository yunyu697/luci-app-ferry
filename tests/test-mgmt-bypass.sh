#!/bin/bash
# 管理口永久 bypass 的离线断言
#
# 验证：
#   1. LAN 网段与路由器自身地址进入独立的 mgmt 集合；
#   2. tproxy / redirect / quic 链里 mgmt RETURN 排在 TPROXY/redirect 之前；
#   3. 不会把“外网 443”整体放过（只有 daddr 属于管理网段才 return）；
#   4. iptables 路径同样先插 mgmt RETURN；
#   5. ip 命令缺失时退回 UCI 的 ipaddr/netmask。
#
# 运行：bash tests/test-mgmt-bypass.sh

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tests/out"
CACHE="$ROOT/tests/.cache"
mkdir -p "$OUT" "$CACHE"
LOG="$OUT/test-mgmt-bypass.log"
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
contains() { if grep -q -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1（$3 中未找到 $2）"; fi }
not_contains() { if ! grep -q -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1（$3 中不应出现 $2）"; fi }

T="$CACHE/mgmt-test"
rm -rf "$T"
mkdir -p "$T/bin" "$T/run" "$T/state"

export PATH="$T/bin:$PATH"
export PM_RUN_DIR="$T/run"
export PM_FUNCTIONS_SH="$T/functions.sh"
export PM_LAN_IFACE=br-lan
export PM_LAN_IFACES=br-lan
export PM_NFT_TABLE=ferry
export PM_NFT_TABLE6=ferry6
export PM_IP_MARK=1
export PM_IP_ROUTE_TABLE=100
export PM_MODE=tproxy
export PM_DEPLOY=tproxy
export PM_ENABLE_IPV6=1
export PM_BLOCK_QUIC=1
export PM_DNS_PORT=1053
export PM_HIJACK_DNS=1
export PM_PROXY_PORT=7890
export PM_FW_BACKEND=nft
export PM_BYPASS_CIDR=''
export PM_BYPASS_IP=''
export FAKE_IPT_LOG="$T/state/ipt.log"
export FAKE_IP_OUT="$T/state/ip.out"

cat > "$T/functions.sh" <<'EOF'
config_load() { :; }
config_get() { :; }
config_foreach() { :; }
EOF

# ip 命令：输出 LAN IPv4/IPv6
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
if [ -f "$FAKE_IP_OUT" ] && [ -s "$FAKE_IP_OUT" ]; then
	cat "$FAKE_IP_OUT"
	exit 0
fi
fam4=1
[ "$1" = "-6" ] && { fam4=0; shift; }
[ "$1" = "-4" ] && shift
[ "$1" = "-o" ] && shift
[ "$1" = "addr" ] && [ "$2" = "show" ] || exit 1
if [ "$fam4" = 1 ]; then
	echo "2: br-lan    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan"
else
	echo "2: br-lan    inet6 2001:db8:1::1/64 scope global"
fi
EOF
chmod +x "$T/bin/ip"

cat > "$T/bin/iptables" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_IPT_LOG"
EOF
chmod +x "$T/bin/iptables"

cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
EOF
chmod +x "$T/bin/logger"

cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/nft"

. "$ROOT/files/usr/lib/ferry/common.sh"
. "$ROOT/files/usr/lib/ferry/firewall.sh"

# ===========================================================================
log "== 1. LAN 网段识别（IPv4 + IPv6） =="
cidrs=$(pm_mgmt_cidrs)
echo "        $cidrs"
case " $cidrs " in *" 192.168.1.0/24 "*) pass "IPv4 网段识别为 192.168.1.0/24" ;; *) fail "IPv4 网段识别失败：$cidrs" ;; esac
case " $cidrs " in *" 2001:db8:1::1/64 "*) pass "IPv6 网段保留地址/前缀" ;; *) fail "IPv6 网段识别失败：$cidrs" ;; esac

log "== 2. ip 缺失时退回 UCI ipaddr/netmask =="
mv "$T/bin/ip" "$T/bin/ip.off"
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1:$2" in
	get:network.lan.ipaddr) echo 10.8.0.1 ;;
	get:network.lan.netmask) echo 255.255.0.0 ;;
	get:network.lan.device) echo br-lan ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$T/bin/uci"
cidrs=$(pm_mgmt_cidrs)
echo "        $cidrs"
case " $cidrs " in *" 10.8.0.0/16 "*) pass "UCI 回退得到 10.8.0.0/16" ;; *) fail "UCI 回退失败：$cidrs" ;; esac
rm -f "$T/bin/uci"
mv "$T/bin/ip.off" "$T/bin/ip"

log "== 3. nft IPv4：mgmt 集合 + 规则顺序 =="
export PM_MGMT_CIDRS=$(pm_mgmt_cidrs)
f4="$PM_RUN_DIR/ferry-v4.nft"
pm_nft_build ip ferry "$f4"
check_file() { [ -e "$2" ] && pass "$1" || fail "$1（缺少 $2）"; }
check_file "生成 IPv4 nft 文件" "$f4"
contains "mgmt4 集合存在" 'set mgmt4' "$f4"
contains "mgmt4 含 LAN 网段" '192.168.1.0/24' "$f4"
contains "tproxy 链 mgmt RETURN" 'ip daddr @mgmt4 return' "$f4"
contains "redirect 链 mgmt RETURN" 'ip daddr @mgmt4 return' "$f4"

mg_line=$(grep -n '@mgmt4 return' "$f4" | head -n 1 | cut -d: -f1)
by_line=$(grep -n '@bypass4 return' "$f4" | head -n 1 | cut -d: -f1)
tproxy_line=$(grep -n 'tproxy to' "$f4" | head -n 1 | cut -d: -f1)
if [ -n "$mg_line" ] && [ -n "$by_line" ] && [ "$mg_line" -lt "$by_line" ]; then
	pass "mgmt RETURN 排在 bypass RETURN 之前（$mg_line < $by_line）"
else
	fail "mgmt RETURN 顺序错误（mgmt=$mg_line bypass=$by_line）"
fi
if [ -n "$mg_line" ] && [ -n "$tproxy_line" ] && [ "$mg_line" -lt "$tproxy_line" ]; then
	pass "mgmt RETURN 排在 TPROXY 动作之前（$mg_line < $tproxy_line）"
else
	fail "mgmt RETURN 未排在 TPROXY 之前（mgmt=$mg_line tproxy=$tproxy_line）"
fi
not_contains "没有整体放过外网 443" 'tcp dport 443 return' "$f4"
not_contains "没有整体放过外网 80" 'tcp dport 80 return' "$f4"
contains "用户 bypass 仍然保留" '192.168.0.0/16' "$f4"

log "== 4. nft IPv6：mgmt6 集合 + 规则 =="
f6="$PM_RUN_DIR/ferry-v6.nft"
pm_nft_build ip6 ferry6 "$f6"
check_file "生成 IPv6 nft 文件" "$f6"
contains "mgmt6 集合存在" 'set mgmt6' "$f6"
contains "mgmt6 含 IPv6 网段" '2001:db8:1::1/64' "$f6"
contains "IPv6 tproxy 链 mgmt RETURN" 'ip6 daddr @mgmt6 return' "$f6"

log "== 5. 无管理网段时不生成 mgmt 集合（避免空集合加载失败） =="
PM_MGMT_CIDRS=''
pm_nft_build ip ferry "$T/empty.nft"
not_contains "空管理网段不生成 mgmt4" 'set mgmt4' "$T/empty.nft"

log "== 6. iptables 路径：mgmt RETURN 先插入 =="
PM_MGMT_CIDRS='192.168.1.0/24 2001:db8:1::1/64'
: > "$FAKE_IPT_LOG"
pm_ipt_mgmt_rules mangle PM_TPROXY
contains "iptables 写入 IPv4 mgmt RETURN" '-d 192.168.1.0/24 -j RETURN' "$FAKE_IPT_LOG"
not_contains "iptables 不处理 IPv6 地址" '2001:db8:1::1/64' "$FAKE_IPT_LOG"

log "== 7. 断言：管理口请求不会进入 TPROXY 判定 =="
# tproxy 链第一层是 iif 判断，第二层就是 mgmt RETURN；只有非管理网段才继续
awk '
	/chain tproxy_prerouting/ { incl = 1; next }
	incl && /iifname != @lanif return/ { next }
	incl && /@mgmt4 return/ { mgmt = NR }
	incl && /@bypass4 return/ { bypass = NR }
	incl && /tproxy to/ { tp = NR }
	END {
		if (mgmt && bypass && tp && mgmt < bypass && mgmt < tp) exit 0
		exit 1
	}' "$f4" && pass "tproxy 链顺序：iif -> mgmt -> bypass -> tproxy" || fail "tproxy 链顺序不符合管理口 bypass"

# ===========================================================================
log ""
log "================ 结果 ================"
log "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then log "ALL PASS"; exit 0; fi
exit 1
