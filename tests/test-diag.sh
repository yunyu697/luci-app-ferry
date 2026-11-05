#!/bin/bash
# 诊断包内容与脱敏断言（离线）
#
# 造一份包含订阅 URL、节点密码、UUID、token、证书私钥的假数据，
# 生成 ferry-diag 包后解包 grep，断言原始凭据不出现、host 仍保留。

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tests/out"
CACHE="$ROOT/tests/.cache"
mkdir -p "$OUT" "$CACHE"
LOG="$OUT/test-diag.log"
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
check_file() { [ -e "$2" ] && pass "$1" || fail "$1（缺少 $2）"; }
contains() { grep -q -- "$2" "$3" 2>/dev/null && pass "$1" || fail "$1（$3 中未找到 $2）"; }
not_contains() { ! grep -q -- "$2" "$3" 2>/dev/null && pass "$1" || fail "$1（$3 中仍含 $2）"; }

T="$CACHE/diag-test"
rm -rf "$T"
mkdir -p "$T/bin" "$T/etc/ferry" "$T/etc/mihomo" "$T/etc/sing-box" "$T/etc/config" "$T/out" "$T/txn" "$T/fakebin"

export PATH="$T/bin:$PATH"
export PM_CONF_DIR="$T/etc/ferry"
export PM_RUN_DIR="$T/var/etc/ferry"
export PM_MIHOMO_DIR="$T/etc/mihomo"
export PM_SINGBOX_DIR="$T/etc/sing-box"
export PM_DHCP_FILE="$T/etc/config/dhcp"
export PM_FUNCTIONS_SH="$T/functions.sh"
export PM_KERNEL=mihomo
export PM_ENABLED=1
export PM_MODE=tproxy
export PM_DEPLOY=nft
export PM_LAN_IFACE=br-lan
export PM_LAN_IFACES=br-lan
export PM_MGMT_CIDRS='192.168.1.0/24'
export PM_BIN_PATH="$T/fakebin/mihomo"
export PM_TXN_DIR="$T/txn"
export PM_TMP_OFF_DIR="$T/tmp-off"
export PM_DNSMASQ_SECTION='dhcp.@dnsmasq[0]'
export PM_DNS_PORT=1053
export PM_TXN_QUIET=1
export FERRY_LIB_DIR="$ROOT/files/usr/lib/ferry"
export PM_TXNCTL="$ROOT/files/usr/bin/ferry-txnctl"
export FAKE_UCI_STATE="$T/state-uci"

. "$ROOT/files/usr/lib/ferry/common.sh"

cat > "$T/functions.sh" <<'EOF'
config_load() { :; }
config_get() { :; }
config_foreach() { :; }
EOF

# 假 uci：返回带订阅 URL 的 ferry 配置
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1" in
	export)
		if [ "$2" = ferry ]; then cat <<'CFG'
package ferry

config main 'main'
	option enabled '1'
	option sub_url 'https://user:secret@sub.example.com/api/v1/client/subscribe?token=TOKEN_ABC_123&flag=ss'
	option rollback_timeout '60'
CFG
			exit 0
		fi
		exit 1 ;;
	show)
		case "$2" in
			'dhcp.@dnsmasq[0]')
				echo "dhcp.@dnsmasq[0].server='127.0.0.1#1053'"
				echo "dhcp.@dnsmasq[0].noresolv='1'" ;;
			network)
				echo "network.lan.device='br-lan'"
				echo "network.lan.ipaddr='192.168.1.1'" ;;
			*) exit 1 ;;
		esac ;;
	get)
		case "$2" in
			'dhcp.@dnsmasq[0].server') echo '127.0.0.1#1053' ;;
			'dhcp.@dnsmasq[0].noresolv') echo 1 ;;
			network.lan.device) echo br-lan ;;
			*) exit 1 ;;
		esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/uci"

cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
case "$1" in
	list) [ "$2" = tables ] && { echo "table ip ferry"; login="x"; exit 0; }; echo "table ip ferry { chain tproxy_prerouting { } }"; exit 0 ;;
	*) exit 0 ;;
esac
EOF
chmod +x "$T/bin/nft"

cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
echo "0:	from all lookup local"
echo "1:	from all fwmark 0x1 lookup 100"
EOF
chmod +x "$T/bin/ip"

cat > "$T/bin/iptables" <<'EOF'
#!/bin/sh
echo "Chain PM_TPROXY (1 references)"
EOF
chmod +x "$T/bin/iptables"

cat > "$T/bin/logread" <<'EOF'
#!/bin/sh
cat <<'L'
daemon.info ferry: apply ok
daemon.info ferry: sub https://node.example.org/secret/path?token=TOKEN_ABC_123
L
EOF
chmod +x "$T/bin/logread"

cat > "$T/bin/nslookup" <<'EOF'
#!/bin/sh
echo "Server:		127.0.0.1"
echo "Address:	127.0.0.1#1053"
echo "Name:	example.com"
echo "Address:	93.184.216.34"
EOF
chmod +x "$T/bin/nslookup"

cat > "$T/bin/ping" <<'EOF'
#!/bin/sh
echo "2 packets transmitted, 2 received, 0% packet loss"
EOF
chmod +x "$T/bin/ping"

cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
echo "http_code=200"
EOF
chmod +x "$T/bin/curl"

cat > "$T/fakebin/mihomo" <<'EOF'
#!/bin/sh
case "$1" in
	-v) echo "Mihomo Meta v1.19.0" ;;
	-t) echo "configuration file test is successful"; exit 0 ;;
	*) echo ok ;;
esac
EOF
chmod +x "$T/fakebin/mihomo"

# 假数据：订阅节点与内核配置（含真实“凭据”字面量，测试用）
cat > "$PM_CONF_DIR/profiles.json" <<'J'
{"profiles":[{"id":"p1","name":"airport","nodes":[
 {"type":"ss","server":"node.example.org","port":8388,"password":"PASSWORD_SECRET_9x","cipher":"aes-256-gcm"},
 {"type":"vmess","server":"vm.example.com","port":443,"uuid":"UUID_SECRET_7a1b","alterId":0,"token":"TOKEN_ABC_123"}
]}]}
J
cat > "$PM_CONF_DIR/nodes.json" <<'J'
{"nodes":[{"name":"n1","password":"PASSWORD_SECRET_9x","uuid":"UUID_SECRET_7a1b"}]}
J
echo p1 > "$PM_CONF_DIR/active"
cat > "$PM_MIHOMO_DIR/config.yaml" <<'Y'
mixed-port: 7890
proxies:
  - name: n1
    type: ss
    server: node.example.org
    password: PASSWORD_SECRET_9x
    uuid: UUID_SECRET_7a1b
    private_key: KEY_MATERIAL_ZZZ
Y
cat > "$PM_MIHOMO_DIR/cert.key" <<'K'
-----BEGIN RSA PRIVATE KEY-----
MIIBOgIBAAJBAK_PRIVATE_BODY_1234567890
-----END RSA PRIVATE KEY-----
K
cat > "$PM_SINGBOX_DIR/config.json" <<'J'
{"outbounds":[{"type":"shadowsocks","password":"PASSWORD_SECRET_9x","uuid":"UUID_SECRET_7a1b"}]}
J

# 事务状态与历史
mkdir -p "$PM_TXN_DIR"
echo "id=1 phase=pending" > "$PM_TXN_DIR/t1.meta"
echo "== evidence ==" > "$PM_TXN_DIR/evidence-1.txt"
echo 'sub_url https://sub.example.com/api?token=TOKEN_ABC_123' >> "$PM_TXN_DIR/evidence-1.txt"

# ===========================================================================
log "== 1. 生成诊断包 =="
DIAG="$ROOT/files/usr/bin/ferry-diag"
chmod +x "$DIAG" 2>/dev/null
bash "$DIAG" --out "$T/out" > "$T/diag.out" 2>&1
rc=$?
cat "$T/diag.out" | tee -a "$LOG"
check "ferry-diag 退出码 0" 0 "$rc"
ARCHIVE=$(sed -n 's/^archive=//p' "$T/diag.out" | head -n 1)
check_file "生成 tar.gz" "$ARCHIVE"
SIZE=$(sed -n 's/^size=//p' "$T/diag.out" | head -n 1)
SHA=$(sed -n 's/^sha256=//p' "$T/diag.out" | head -n 1)
echo "        archive=$ARCHIVE size=$SIZE sha256=$SHA"

log "== 2. 解包并核对内容清单 =="
EX="$T/extract"
mkdir -p "$EX"
tar -xzf "$ARCHIVE" -C "$EX"
BUNDLE=$(find "$EX" -mindepth 1 -maxdepth 1 -type d | head -n 1)
check_file "单一顶层目录" "$BUNDLE"
for f in manifest.txt system.txt uci-ferry.txt uci-dnsmasq.txt nft-ruleset.txt ip-routing.txt iptables.txt \
         kernel-check.txt logs.txt network.txt capability.txt transaction.txt \
         profiles.redacted.json nodes.redacted.json config-mihomo.redacted.yaml config-singbox.redacted.json \
         certs.redacted.txt; do
	check_file "包含 $f" "$BUNDLE/$f"
done
contains "manifest 列出文件" 'uci-ferry.txt' "$BUNDLE/manifest.txt"

log "== 3. 脱敏断言：原始凭据不得出现 =="
ALL="$T/all.txt"
cat "$BUNDLE"/* > "$ALL" 2>/dev/null
not_contains "订阅 token 未泄漏" 'TOKEN_ABC_123' "$ALL"
not_contains "节点密码未泄漏" 'PASSWORD_SECRET_9x' "$ALL"
not_contains "节点 UUID 未泄漏" 'UUID_SECRET_7a1b' "$ALL"
not_contains "私钥字段值未泄漏" 'KEY_MATERIAL_ZZZ' "$ALL"
not_contains "PEM 私钥正文未泄漏" 'MIIBOgIBAAJBAK_PRIVATE_BODY' "$ALL"
not_contains "订阅 URL 路径未泄漏" '/api/v1/client/subscribe' "$ALL"
not_contains "订阅 URL query 未泄漏" 'flag=ss' "$ALL"

log "== 4. 脱敏后仍保留可诊断信息 =="
contains "订阅 host 保留（uci）" 'sub.example.com' "$BUNDLE/uci-ferry.txt"
contains "订阅 URL 形态保留 scheme+host+/***" 'https://sub.example.com/***' "$BUNDLE/uci-ferry.txt"
contains "节点 server 主机保留" 'node.example.org' "$BUNDLE/profiles.redacted.json"
contains "密码字段名保留、值打码" '"password":"***"' "$BUNDLE/profiles.redacted.json"
contains "UUID 字段名保留、值打码" '"uuid":"***"' "$BUNDLE/profiles.redacted.json"
contains "PEM 被替换标记" 'REDACTED PRIVATE KEY' "$BUNDLE/certs.redacted.txt"
contains "nft ruleset 已采集" 'table ip ferry' "$BUNDLE/nft-ruleset.txt"
contains "策略路由已采集" 'fwmark' "$BUNDLE/ip-routing.txt"
contains "内核版本已采集" 'Mihomo Meta' "$BUNDLE/kernel-check.txt"
contains "内核自检结果已采集" 'successful' "$BUNDLE/kernel-check.txt"
contains "日志尾部已采集" 'apply ok' "$BUNDLE/logs.txt"
contains "DNS 结果已采集" '93.184.216.34' "$BUNDLE/network.txt"
contains "HTTP 结果已采集" 'http_code=200' "$BUNDLE/network.txt"
contains "能力探测已采集" 'TPROXY' "$BUNDLE/capability.txt"
contains "事务状态已采集" 'pending' "$BUNDLE/transaction.txt"

log "== 5. --json 与 --base64 输出 =="
bash "$DIAG" --json --out "$T/out" > "$T/diag.json" 2>/dev/null
contains "JSON ok=true" '"ok":true' "$T/diag.json"
contains "JSON 含 path" '"path"' "$T/diag.json"
JPATH=$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p' "$T/diag.json" | head -n 1)
JSHA=$(sed -n 's/.*"sha256":"\([a-f0-9]*\)".*/\1/p' "$T/diag.json" | head -n 1)
check_file "JSON 路径存在" "$JPATH"
check "JSON sha256 与文件一致" "$JSHA" "$(sha256sum "$JPATH" | awk '{print $1}')"
bash "$DIAG" --base64 --out "$T/out" > "$T/diag.b64" 2>/dev/null
base64 -d < "$T/diag.b64" > "$T/decoded.tar.gz" 2>/dev/null
tar -tzf "$T/decoded.tar.gz" 2>/dev/null | grep -q 'manifest.txt' && pass "base64 解码后是完整 tar.gz" || fail "base64 解码失败"
contains "tar 顶层目录命名" 'ferry-diag-' "$T/diag.out"

log ""
log "================ 结果 ================"
log "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then log "ALL PASS"; exit 0; fi
exit 1
