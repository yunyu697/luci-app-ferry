#!/bin/bash
# 规则同步语义的离线测试（不联网，伪造 uclient-fetch）
#
# 覆盖：
#   A. 首个分类下载失败不阻断后续分类（failed + ok）
#   B. 下载失败但有旧缓存：用缓存并标 stale，整体状态 stale
#   C. 关闭规则更新：有缓存记为 ok，无缓存记为 skipped
#   D. config_path 自备配置：完全不同步规则（零下载），状态 self
#   E. status.json 是合法 JSON 且 rule_sync 结构完整
#
# 运行：bash tests/test-rules.sh
# 输出：tests/out/test-rules.log

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tests/out"
CACHE="$ROOT/tests/.cache"
mkdir -p "$OUT" "$CACHE"
LOG="$OUT/test-rules.log"
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
	fi
}

T="$CACHE/rules-test"
export PM_CONF_DIR="$T/etc/ferry"
export PM_RUN_DIR="$T/var/etc/ferry"
export PM_MIHOMO_DIR="$T/etc/mihomo"
export PM_SINGBOX_DIR="$T/etc/sing-box"
export PM_DNSMASQ_INIT="$T/no-such-dnsmasq"
export PM_DHCP_FILE="$T/no-such-dhcp"
export FETCH_LOG="$T/fetch.log"

mkdir -p "$T/bin" "$T/bin-real"
cat > "$T/bin/uclient-fetch" <<'EOF'
#!/bin/sh
# 假 uclient-fetch：记录每个 URL，按 FETCH_FAIL 子串决定失败
out=''
url=''
while [ $# -gt 0 ]; do
	case "$1" in
		-O) out="$2"; shift 2 ;;
		*)  url="$1"; shift ;;
	esac
done
printf '%s\n' "$url" >> "$FETCH_LOG"
case "$url" in
	*"${FETCH_FAIL:-__never__}"*) exit 1 ;;
esac
mkdir -p "$(dirname "$out")" 2>/dev/null
printf 'fake rule payload for %s\n' "$url" > "$out"
exit 0
EOF
chmod +x "$T/bin/uclient-fetch"

cat > "$T/bin-real/kernel" <<'EOF'
#!/bin/sh
# 测试用内核桩：配置自检一律通过
exit 0
EOF
chmod +x "$T/bin-real/kernel"

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
PM_RULE_UPDATE=1
PM_SUB_URL=''
PM_BIN_PATH="$T/bin-real/kernel"

reset_case() {
	rm -rf "$T/etc" "$T/var"
	mkdir -p "$PM_CONF_DIR" "$PM_RUN_DIR" "$PM_MIHOMO_DIR" "$PM_SINGBOX_DIR" \
		"$PM_RULE_CACHE/mihomo" "$PM_RULE_CACHE/sing-box"
	# 只保留两个分类，保证顺序与状态可预期
	printf 'cn direct\nads reject\n' > "$PM_RULES_LST"
	: > "$PM_NODES_LST"
	: > "$FETCH_LOG"
	PM_KERNEL=mihomo
	PM_SUB_URL=''
	PM_CONFIG_PATH=''
	PM_RULE_UPDATE=1
	unset FETCH_FAIL
}

run_prepare() { pm_prepare >/dev/null 2>&1; }

state_of() {
	awk -v g="$1" '$1==g{print $2}' "$PM_RUN_DIR/rules-status.txt" 2>/dev/null
}

status_json() { cat "$PM_STATUS_FILE" 2>/dev/null; }

json_rule_state() {
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rule_sync"]["state"])' \
		"$PM_STATUS_FILE" 2>/dev/null
}

json_rule_list() {
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["rule_sync"]; print(",".join(d[sys.argv[2]]))' \
		"$PM_STATUS_FILE" "$1" 2>/dev/null
}

log "== 规则同步离线测试 =="
log "工作目录：$T"

# ---------- A：首个分类失败不阻断 ----------
log ""
log "A. 首个分类（geolocation-cn）下载失败，后续分类（category-ads-all）仍然更新"
reset_case
export FETCH_FAIL='geolocation-cn'
run_prepare
check "cn 分类记为 failed" "failed" "$(state_of geolocation-cn)"
check "ads 分类记为 ok（未被阻断）" "ok" "$(state_of category-ads-all)"
check "后续分类缓存已落盘" "yes" "$([ -s "$PM_RULE_CACHE/mihomo/category-ads-all.yaml" ] && echo yes || echo no)"
check "失败分类无缓存" "no" "$([ -s "$PM_RULE_CACHE/mihomo/geolocation-cn.yaml" ] && echo yes || echo no)"
check "两次下载都尝试过" "2" "$(wc -l < "$FETCH_LOG" | tr -d ' ')"
check "告警提示无缓存已跳过" "yes" "$(grep -q '无本地缓存' "$PM_RUN_DIR/warnings.txt" 2>/dev/null && echo yes || echo no)"
check "status.json 整体状态 failed" "failed" "$(json_rule_state)"
check "status.json failed 列表" "geolocation-cn" "$(json_rule_list failed)"
check "status.json ok 列表" "category-ads-all" "$(json_rule_list ok)"

# ---------- B：失败但有缓存 -> stale ----------
log ""
log "B. 下载失败但有旧缓存：继续用缓存并标 stale，不中断其它分类"
reset_case
printf 'old-cached-geolocation-cn\n' > "$PM_RULE_CACHE/mihomo/geolocation-cn.yaml"
export FETCH_FAIL='geolocation-cn'
run_prepare
check "cn 分类记为 stale" "stale" "$(state_of geolocation-cn)"
check "stale 分类保留旧缓存内容" "old-cached-geolocation-cn" "$(cat "$PM_RULE_CACHE/mihomo/geolocation-cn.yaml" 2>/dev/null)"
check "ads 分类仍记为 ok" "ok" "$(state_of category-ads-all)"
check "告警提示继续使用本地缓存" "yes" "$(grep -q '继续使用本地缓存' "$PM_RUN_DIR/warnings.txt" 2>/dev/null && echo yes || echo no)"
check "status.json 整体状态 stale" "stale" "$(json_rule_state)"
check "status.json stale 列表" "geolocation-cn" "$(json_rule_list stale)"

# ---------- C：关闭更新 ----------
log ""
log "C. 关闭规则更新：有缓存 ok，无缓存 skipped，且不发起下载"
reset_case
printf 'cached\n' > "$PM_RULE_CACHE/mihomo/geolocation-cn.yaml"
PM_RULE_UPDATE=0
run_prepare
check "有缓存分类记为 ok" "ok" "$(state_of geolocation-cn)"
check "无缓存分类记为 skipped" "skipped" "$(state_of category-ads-all)"
check "没有发起任何下载" "0" "$(wc -l < "$FETCH_LOG" | tr -d ' ')"
check "status.json 整体状态 skipped" "skipped" "$(json_rule_state)"
check "status.json skipped 列表" "category-ads-all" "$(json_rule_list skipped)"

# ---------- D：自备配置不同步规则 ----------
log ""
log "D. config_path 自备配置：完全不发起规则下载，状态为 self"
reset_case
PM_CONFIG_PATH="$T/user-config.yaml"
printf 'mixed-port: 7890\n' > "$PM_CONFIG_PATH"
run_prepare
check "没有发起任何下载" "0" "$(wc -l < "$FETCH_LOG" | tr -d ' ')"
check "没有写 rules-status.txt" "no" "$([ -e "$PM_RUN_DIR/rules-status.txt" ] && echo yes || echo no)"
check "status.json 整体状态 self" "self" "$(json_rule_state)"
check "运行时配置指向自备文件" "yes" "$([ "$PM_RUNTIME_CONFIG" = "$PM_CONFIG_PATH" ] && echo yes || echo no)"

# ---------- E：status.json JSON 合法性 ----------
log ""
log "E. status.json 是合法 JSON，rule_sync 含四个数组"
reset_case
export FETCH_FAIL='geolocation-cn'
run_prepare
check "JSON 可解析" "ok" "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "$PM_STATUS_FILE" 2>/dev/null)"
check "rule_sync 字段齐全" "ok" "$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))["rule_sync"]
need = {"state", "ok", "stale", "skipped", "failed"}
print("ok" if need <= set(d) else "missing:" + ",".join(sorted(need - set(d))))
' "$PM_STATUS_FILE" 2>/dev/null)"
log "  status.json: $(status_json)"

log ""
log "== 结果：PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
