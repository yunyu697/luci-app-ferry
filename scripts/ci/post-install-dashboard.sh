#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
chmod 0755 /usr/lib/ferry/panel.sh /usr/bin/ferry-panel /usr/libexec/rpcd/luci-ferry-panel 2>/dev/null
chmod 0644 /usr/share/luci/menu.d/luci-app-ferry-dashboard.json \
	/usr/share/rpcd/acl.d/luci-app-ferry-dashboard.json 2>/dev/null
[ -x /etc/init.d/ferry-panel ] && /etc/init.d/ferry-panel enable >/dev/null 2>&1
[ "$(uci -q get ferry-dashboard.main.enabled)" = 1 ] && /usr/bin/ferry-panel boot >/dev/null 2>&1
/etc/init.d/rpcd reload >/dev/null 2>&1 || killall -HUP rpcd 2>/dev/null
( sleep 4; /etc/init.d/uhttpd restart >/dev/null 2>&1 ) >/dev/null 2>&1 &
logger -t ferry-panel "luci-app-ferry-dashboard postinst: installed/enabled" 2>/dev/null
exit 0
