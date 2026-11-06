#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
# 1) LuCI 索引缓存（不清会话目录，不会被登出）
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
# 2) 旧版本遗留文件：按随包清单删除，不猜路径
for f in $(grep -v '^#' /usr/lib/ferry/legacy-files.txt 2>/dev/null); do
	[ -e "$f" ] && rm -rf "$f"
done
# 3) 权限自愈（历史升级可能丢可执行位，rpcd 会因此 500）
chmod 0755 /usr/lib/ferry/*.sh /usr/libexec/rpcd/luci-ferry-kernel /usr/bin/ferry-* 2>/dev/null
chmod 0644 /usr/lib/ferry/kernels-builtin.tsv 2>/dev/null
# 4) 旧版 mirrors.json（无 "version": 2）迁移：旧后端会在迁移分支里无限递归
[ -s /usr/lib/ferry/kernel.sh ] && sh /usr/lib/ferry/kernel.sh init-state >/dev/null 2>&1
[ -s /usr/lib/ferry/kernels-builtin.tsv ] || logger -t ferry "WARN 内置版本清单缺失"
# 5) 初始化（幂等）
[ -x /etc/uci-defaults/50-ferry ] && /etc/uci-defaults/50-ferry
# 6) rpcd 方法表/ACL 刷新：先 reload，后台再 restart，避免打断本次安装请求
/etc/init.d/rpcd reload >/dev/null 2>&1 || killall -HUP rpcd 2>/dev/null
( sleep 5; /etc/init.d/rpcd restart >/dev/null 2>&1; \
  [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1 ) >/dev/null 2>&1 &
logger -t ferry "luci-app-ferry postinst: upgrade state healed, rpcd reloaded" 2>/dev/null
exit 0
