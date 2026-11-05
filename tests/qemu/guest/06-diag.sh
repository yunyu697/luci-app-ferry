#!/bin/sh
# 证据④：诊断包内容清单 + 脱敏断言。
set -u
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# 植入已知凭据（假数据），用于 grep 断言
cat > /etc/ferry/nodes.json <<'EOF'
{"proxy":[{"name":"qemu-test","type":"ss","server":"1.2.3.4","port":8388,"password":"RAW_PASSWORD_123","uuid":"RAW_UUID_456"}]}
EOF
mkdir -p /etc/mihomo
printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'RAW_PRIVATE_KEY_BODY' '-----END OPENSSH PRIVATE KEY-----' \
	> /etc/mihomo/test.key
uci set ferry.main.token='RAW_TOKEN_UCI'
uci set ferry.main.sub_url='https://sub.example.com/path?token=RAW_TOKEN_789'
uci commit ferry

OUT=$(/usr/bin/ferry-diag 2>&1)
echo "$OUT"
ARCH=$(printf '%s\n' "$OUT" | sed -n 's/^archive=//p')
[ -s "$ARCH" ] && ok "生成单个 tar.gz（$ARCH）" || bad "未生成 tar.gz"
LIST=$(tar -tzf "$ARCH" 2>/dev/null | sed 's|^[^/]*/||' | sort)
echo "--- bundle files ---"
echo "$LIST"
N=$(echo "$LIST" | grep -c .)
echo "files=$N"
for f in system.txt uci-ferry.txt uci-dnsmasq.txt nft-ruleset.txt nft-ferry.txt ip-routing.txt \
	iptables.txt kernel-check.txt config-mihomo.redacted.yaml certs.redacted.txt logs.txt \
	network.txt capability.txt transaction.txt manifest.txt nodes.redacted.json profiles.redacted.json; do
	echo "$LIST" | grep -qx "$f" && ok "包含 $f" || bad "缺少 $f"
done
TMP=$(mktemp -d)
tar -xzf "$ARCH" -C "$TMP"
ROOT=$(find "$TMP" -maxdepth 1 -type d -name 'ferry-diag-*' | head -1)
LEAK=0
for v in RAW_PASSWORD_123 RAW_UUID_456 RAW_URL_PASS RAW_TOKEN_789 RAW_TOKEN_UCI RAW_PRIVATE_KEY_BODY; do
	if grep -l "$v" "$ROOT"/* 2>/dev/null | grep -q .; then
		echo "LEAK: $v"
		LEAK=1
	fi
done
[ "$LEAK" = 0 ] && ok "原始凭据 grep 无命中（RAW_CRED_LEAK=NO）" || bad "诊断包泄漏原始凭据"
grep -q "https://sub.example.com/***" "$ROOT/uci-ferry.txt" 2>/dev/null \
	&& ok "订阅 URL 保留 host、路径/query 打码" || bad "URL 脱敏形态不符合预期"
grep -q "token '***'" "$ROOT/uci-ferry.txt" 2>/dev/null \
	&& ok "UCI token 已打码" || bad "UCI token 未打码"
grep -q '"password":"***"' "$ROOT/nodes.redacted.json" 2>/dev/null \
	&& ok "nodes.json password 已打码" || bad "nodes.json password 未打码"
grep -q '[REDACTED PRIVATE KEY]' "$ROOT/certs.redacted.txt" 2>/dev/null \
	&& ok "证书私钥整段替换为 [REDACTED PRIVATE KEY]" || bad "私钥未替换"
[ "$(grep -c 'RAW_' "$ROOT/manifest.txt" 2>/dev/null)" = 0 ] && ok "manifest 无原始凭据" || bad "manifest 泄漏"
rm -rf "$TMP"

# 还原测试用的假凭据
uci -q delete ferry.main.token
uci -q delete ferry.main.sub_url
uci commit ferry
echo "ARCHIVE=$ARCH"
echo "=== DIAG_DONE PASS=$PASS FAIL=$FAIL ==="
