#!/bin/sh
[ "$1" = "upgrade" ] && exit 0
# 卸载回到原状：撤防火墙、删 secret、删本包 UCI、重启内核移除面板端点
[ -x /usr/bin/ferry-panel ] && /usr/bin/ferry-panel cleanup
[ -x /etc/init.d/ferry-panel ] && /etc/init.d/ferry-panel disable >/dev/null 2>&1
rm -f /etc/config/ferry-dashboard
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
exit 0
