#!/bin/sh
# Ferry 事务看门狗：每秒检查 pending 的 deadline，到点自动还原。
#
# 为什么可靠：
#   - 由 procd（PID 1）作为独立 instance 托管，进程被杀后 5 秒内自动拉起；
#   - 不依赖 LuCI / SSH 是否存在，浏览器关掉、SSH 断开都不影响；
#   - pending 状态在 /etc/ferry（持久化 overlay），断电重启后由
#     start_service 的 boot 检查兜底；
#   - 即使本脚本和 procd 都异常，下一次 `/etc/init.d/ferry start` 也会检测 pending。

FERRY_LIB_DIR=${FERRY_LIB_DIR:-/usr/lib/ferry}
. "$FERRY_LIB_DIR/common.sh"
. "$FERRY_LIB_DIR/firewall.sh"
. "$FERRY_LIB_DIR/transaction.sh"

if ! pm_load >/dev/null 2>&1; then
	pm_log "看门狗无法读取配置，仍按文件中的 pending 状态运行" warning
fi

while :; do
	pt_check
	sleep 1
done
