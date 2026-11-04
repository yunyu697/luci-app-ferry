#!/bin/bash
# 配置生成的离线测试（mihomo YAML / sing-box JSON）
#
# 覆盖：
#   A. 仅订阅（names 为空、sub_url 非空）：不输出空的 proxies:
#   B. 订阅 + 本地节点
#   C. 仅本地节点
#   D. 既无节点也无订阅
#   E. sing-box 订阅 URL 不可达：降级为最小骨架
#   若设置 MIHOMO_TEST_BIN 指向真实 mihomo 二进制，额外用 `-t` 校验生成的 YAML。
#
# 运行：bash tests/test-generate.sh
# 输出：tests/out/test-generate.log

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tests/out"
CACHE="$ROOT/tests/.cache"
mkdir -p "$OUT" "$CACHE"
LOG="$OUT/test-generate.log"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); log "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); log "  FAIL  $*"; }

check() {
	if [ "$2" = "$3" ]; then
		pass "$1"
	else
		fail "$1"
		log "        期望=[$2]"
		log "        实际=[$3]"
		[ -f "${4:-}" ] && sed -n '1,80p' "$4" | tee -a "$LOG" >/dev/null
	fi
}

# 是否存在「只写着 proxies: 但没有内容」的行
has_bare_proxies() {
	if [ ! -f "$1" ]; then
		echo "no-file"
		return 0
	fi
	awk '
		{ lines[NR] = $0 }
		END {
			for (i = 1; i <= NR; i++)
				if (lines[i] ~ /^[[:space:]]*proxies:[[:space:]]*$/ &&
				    (i == NR || lines[i+1] ~ /^[[:space:]]*(use:|proxy-groups:|rule-providers:|rules:|$)/)) {
					print "yes"
					exit
				}
			print "no"
		}' "$1"
}

T="$CACHE/generate-test"
export PM_CONF_DIR="$T/etc/ferry"
export PM_RUN_DIR="$T/var/etc/ferry"
export PM_MIHOMO_DIR="$T/etc/mihomo"
export PM_SINGBOX_DIR="$T/etc/sing-box"
export PM_DNSMASQ_INIT="$T/no-such-dnsmasq"
export PM_DHCP_FILE="$T/no-such-dhcp"

mkdir -p "$T/bin"
# 让 pm_download 走会失败的 uclient-fetch，避免测试时真的联网
cat > "$T/bin/uclient-fetch" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$T/bin/uclient-fetch"
PATH="$T/bin:$PATH"
export PATH

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/ferry/common.sh"
# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/ferry/nodes.sh"
# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/ferry/rules.sh"
# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/ferry/generate.sh"

# common.sh 里这两个路径是硬编码的，测试中在 source 之后再覆盖
PM_MIHOMO_DIR="$T/etc/mihomo"
PM_SINGBOX_DIR="$T/etc/sing-box"

PM_ENABLED=1
PM_KERNEL=mihomo
PM_MODE=tproxy
PM_DEPLOY=router
PM_PROXY_PORT=7890
PM_MIXED_PORT=7891
PM_DNS_PORT=1053
PM_HIJACK_DNS=1
PM_ROUTER_DNS=1
PM_DNS_MODE=fake-ip
PM_ENABLE_IPV6=0
PM_BLOCK_QUIC=1
PM_TUN_STACK=system
PM_FW_BACKEND=nft
PM_LOG_LEVEL=info
PM_FINAL=proxy
PM_BYPASS_CIDR=''
PM_BYPASS_IP=''
PM_LAN_IFACE=''
PM_CONFIG_PATH=''
PM_RULE_MIRROR=github
PM_RULE_MIRROR_BACKUP=''
PM_RULE_UPDATE=0

reset_case() {
	rm -rf "$T/etc" "$T/var"
	mkdir -p "$PM_CONF_DIR" "$PM_RUN_DIR" "$PM_MIHOMO_DIR" "$PM_SINGBOX_DIR"
	: > "$PM_RULES_LST"
	: > "$PM_NODES_LST"
	PM_SUB_URL=''
	PM_KERNEL=mihomo
	PM_DEPLOY=router
}

fake_bin() {
	mkdir -p "$T/bin-real"
	cat > "$T/bin-real/kernel" <<'EOF'
#!/bin/sh
# 测试用内核桩：check 一律成功，实际校验由 MIHOMO_TEST_BIN 承担
exit 0
EOF
	chmod +x "$T/bin-real/kernel"
	PM_BIN_PATH="$T/bin-real/kernel"
}

write_node() {
	cat >> "$PM_NODES_LST" <<'EOF'
BEGIN
name=Node-A
type=ss
enabled=1
server=1.2.3.4
port=8388
cipher=aes-128-gcm
password=secret
END
EOF
}

run_prepare() {
	pm_prepare >/dev/null 2>&1
}

log "== 配置生成离线测试 =="
log "工作目录：$T"
fake_bin

# ---------- A：仅订阅 ----------
log ""
log "A. 仅订阅：不输出空的 proxies:，PROXY 组只靠 use:"
reset_case
PM_SUB_URL='https://example.com/sub'
run_prepare
cfg="$PM_MIHOMO_DIR/config.yaml"
check "生成了 mihomo 配置" "yes" "$([ -s "$cfg" ] && echo yes || echo no)"
check "没有空 proxies 行" "no" "$(has_bare_proxies "$cfg")"
check "有 proxy-providers" "yes" "$(grep -q '^proxy-providers:' "$cfg" && echo yes || echo no)"
check "PROXY 组使用 provider" "yes" "$(grep -q '^    use:' "$cfg" && echo yes || echo no)"
check "PROXY 组没有空 proxies 键" "no" "$(grep -q '^    proxies:' "$cfg" && echo yes || echo no)"

# ---------- B：订阅 + 本地节点 ----------
log ""
log "B. 订阅 + 本地节点：proxies 与 use 同时出现在 PROXY 组"
reset_case
PM_SUB_URL='https://example.com/sub'
write_node
run_prepare
cfg="$PM_MIHOMO_DIR/config.yaml"
check "顶层 proxies 存在" "yes" "$(grep -q '^proxies:' "$cfg" && echo yes || echo no)"
check "节点写入 proxies" "yes" "$(grep -q 'name: "Node-A"' "$cfg" && echo yes || echo no)"
check "PROXY 组含节点" "yes" "$(awk '/^  - name: PROXY/{f=1} f&&/^      - "Node-A"/{print "yes"; exit}' "$cfg")"
check "PROXY 组同时用 provider" "yes" "$(grep -q '^    use:' "$cfg" && echo yes || echo no)"
check "PROXY 组的 proxies 非空" "no" "$(has_bare_proxies "$cfg")"

# ---------- C：仅本地节点 ----------
log ""
log "C. 仅本地节点：有 proxies 与组内节点，没有 use"
reset_case
write_node
run_prepare
cfg="$PM_MIHOMO_DIR/config.yaml"
check "顶层 proxies 存在（C）" "yes" "$(grep -q '^proxies:' "$cfg" && echo yes || echo no)"
check "没有 provider 块" "no" "$(grep -q '^proxy-providers:' "$cfg" && echo yes || echo no)"
check "PROXY 组没有 use" "no" "$(grep -q '^    use:' "$cfg" && echo yes || echo no)"
check "PROXY 组含节点（C）" "yes" "$(awk '/^  - name: PROXY/{f=1} f&&/^      - "Node-A"/{print "yes"; exit}' "$cfg")"

# ---------- D：无节点无订阅 ----------
log ""
log "D. 无节点无订阅：不输出空的 proxies:，PROXY 组退化为 DIRECT"
reset_case
run_prepare
cfg="$PM_MIHOMO_DIR/config.yaml"
check "没有空 proxies 行（D）" "no" "$(has_bare_proxies "$cfg")"
check "PROXY 组只有 DIRECT" "yes" "$(grep -q '^      - DIRECT' "$cfg" && echo yes || echo no)"
check "没有 provider 块（D）" "no" "$(grep -q '^proxy-providers:' "$cfg" && echo yes || echo no)"

# ---------- E：sing-box 订阅不可达 ----------
log ""
log "E. sing-box 订阅 URL 不可达：降级生成最小骨架并告警"
reset_case
PM_KERNEL=singbox
PM_SUB_URL='http://127.0.0.1:1/sub'
run_prepare
cfg="$PM_SINGBOX_DIR/config.json"
check "生成了 sing-box 配置" "yes" "$([ -s "$cfg" ] && echo yes || echo no)"
check "JSON 可解析" "ok" "$(python3 -c "import json,sys; json.load(open(sys.argv[1])); print('ok')" "$cfg" 2>/dev/null)"
check "记录了下订阅失败的告警" "yes" "$(grep -qi '订阅' "$PM_RUN_DIR/warnings.txt" 2>/dev/null && echo yes || echo no)"

# ---------- F：真实 mihomo -t 校验（可选） ----------
log ""
if [ -n "${MIHOMO_TEST_BIN:-}" ] && [ -x "${MIHOMO_TEST_BIN:-}" ]; then
	log "F. 用真实 mihomo -t 校验生成的 YAML"
	reset_case
	PM_SUB_URL='https://example.com/sub'
	write_node
	run_prepare
	if "$MIHOMO_TEST_BIN" -t -d "$PM_MIHOMO_DIR" -f "$PM_MIHOMO_DIR/config.yaml" >> "$LOG" 2>&1; then
		pass "mihomo -t 订阅+本地节点"
	else
		fail "mihomo -t 订阅+本地节点"
	fi
	reset_case
	PM_SUB_URL='https://example.com/sub'
	run_prepare
	if "$MIHOMO_TEST_BIN" -t -d "$PM_MIHOMO_DIR" -f "$PM_MIHOMO_DIR/config.yaml" >> "$LOG" 2>&1; then
		pass "mihomo -t 仅订阅"
	else
		fail "mihomo -t 仅订阅"
	fi
else
	log "F. 跳过：未提供 MIHOMO_TEST_BIN（真实二进制校验见步骤 6）"
fi

# ---------- G：真实 sing-box check（可选） ----------
log ""
if [ -n "${SINGBOX_TEST_BIN:-}" ] && [ -x "${SINGBOX_TEST_BIN:-}" ]; then
	log "G. 用真实 sing-box check 校验生成的 JSON"
	PM_BIN_PATH="$SINGBOX_TEST_BIN"

	real_singbox_case() {
		run_prepare
		if "$SINGBOX_TEST_BIN" check -c "$PM_SINGBOX_DIR/config.json" -D "$PM_SINGBOX_DIR" >> "$LOG" 2>&1; then
			pass "sing-box check：$1"
		else
			fail "sing-box check：$1"
		fi
	}

	reset_case
	write_node
	PM_KERNEL=singbox
	real_singbox_case "tproxy + 本地节点"

	reset_case
	write_node
	PM_KERNEL=singbox
	PM_DEPLOY=client
	real_singbox_case "客户端形态（mixed）"

	reset_case
	PM_KERNEL=singbox
	PM_SUB_URL='http://127.0.0.1:1/sub'
	real_singbox_case "订阅不可达降级骨架"

	PM_DEPLOY=router
	PM_BIN_PATH="$T/bin-real/kernel"
else
	log "G. 跳过：未提供 SINGBOX_TEST_BIN（真实二进制校验见步骤 6）"
fi

log ""
log "== 结果：PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
