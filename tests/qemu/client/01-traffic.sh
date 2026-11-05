#!/bin/sh
# 客户端流量断言：expect=real（未接管）| fake（fake-ip 接管）。
# 用法：01-traffic.sh real|fake
set -u
EXPECT="${1:-fake}"
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# 让 curl 也走路由器 DNS（fake-ip 场景需要），nslookup 显式指定解析器
printf 'nameserver 203.0.113.1\n' > /etc/resolv.conf

IP=$(nslookup www.baidu.com 203.0.113.1 2>/dev/null | awk '/^Address/ {a=$NF} END {print a}')
# slirp 在宿主网络抖动时偶发超时（返回 000），给一次重试，避免把网络抖动记成功能失败
CODE=$(curl -sS -m 25 -o /dev/null -w '%{http_code}' http://www.baidu.com 2>>/tmp/curl.err)
[ "$CODE" = 200 ] || { sleep 2; CODE=$(curl -sS -m 25 -o /dev/null -w '%{http_code}' http://www.baidu.com 2>>/tmp/curl.err); }
BYTES=$(curl -sS -m 25 -o /tmp/t.bin -w '%{size_download}' http://www.baidu.com 2>>/tmp/curl.err)
[ "${BYTES:-0}" -gt 1000 ] || { sleep 2; BYTES=$(curl -sS -m 25 -o /tmp/t.bin -w '%{size_download}' http://www.baidu.com 2>>/tmp/curl.err); }
echo "dns_ip=$IP http_code=$CODE bytes=$BYTES expect=$EXPECT"
[ "$CODE" = 200 ] && [ "${BYTES:-0}" -gt 1000 ] || { echo "--- curl stderr ---"; tail -4 /tmp/curl.err 2>/dev/null; }

case "$EXPECT" in
fake)
	case "$IP" in 198.18.*) ok "DNS 返回 fake-ip（$IP）";; *) bad "未得到 fake-ip（$IP）";; esac
	;;
real)
	case "$IP" in 198.18.*) bad "仍返回 fake-ip（$IP）";; *) ok "DNS 走原始上游，返回真实 IP（$IP）";; esac
	;;
esac
[ "$CODE" = 200 ] && ok "HTTP 200" || bad "HTTP 状态码 $CODE"
[ "${BYTES:-0}" -gt 1000 ] && ok "响应体非空（${BYTES} 字节）" || bad "响应体过小（$BYTES）"
echo "=== TRAFFIC_DONE expect=$EXPECT PASS=$PASS FAIL=$FAIL ==="
