include $(TOPDIR)/rules.mk

# ---------------------------------------------------------------------------
# 双包管理器兼容说明（ipk/opkg 与 apk）
#
# 1. 本文件不写死包头格式：OpenWrt 23.05/24.10 与 ImmortalWrt 走 opkg/ipk，
#    OpenWrt main（及其 apk 分支）走 apk。两种 buildroot 都由
#    include $(INCLUDE_DIR)/package.mk 生成对应格式，这里不需要分支。
# 2. apk 对包名有约束：必须是全小写、只含 [a-z0-9.+_-]，且不能以数字开头。
#    PKG_NAME 已全小写，不要为了“好看”改成 luci-app-Ferry 之类。
# 3. apk 的版本号语法为 <ver>-r<release>；PKG_VERSION 里不要再出现 '-'，
#    否则会被当成 revision 分隔符导致解析异常（例如不要写 1.0.0-beta）。
#    PKG_RELEASE 必须是纯数字整数，apk 会把它拼成 -r1。
# 4. PKGARCH:=all 只表示“包内容与 CPU 架构无关”（脚本/JS/UCI），
#    并不代表内置内核二进制与架构无关——本包不内置内核。
# ---------------------------------------------------------------------------

PKG_NAME:=luci-app-ferry
PKG_VERSION:=1.0.0
PKG_RELEASE:=14

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=yunyu697

include $(INCLUDE_DIR)/package.mk

# 依赖在三种目标上的情况：
#   luci-base / rpcd / nftables / kmod-nft-core / kmod-nft-nat /
#   kmod-nft-tproxy / kmod-tun / ip-full / uclient-fetch / ca-bundle
#   -> OpenWRT apk 分支、OpenWRT opkg 分支、ImmortalWrt 23.05/24.10 均存在同名包。
#   iptables 兼容栈（iptables-mod-tproxy / iptables-mod-extra / kmod-ipt-*）
#   -> 各分支命名不一致（apk 分支可能只有 iptables-legacy / iptables-nft，
#      且 xt_TPROXY 是否随包提供取决于固件），因此不设硬依赖；
#      由 firewall_backend=auto 在运行期检测，缺模块时自动回退到 nft 或直连。
define Package/luci-app-ferry
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI app: Ferry transparent proxy gateway (mihomo / sing-box)
  PKGARCH:=all
  DEPENDS:=+luci-base +rpcd \
	+nftables +kmod-nft-core +kmod-nft-nat +kmod-nft-tproxy \
	+kmod-tun +ip-full +uclient-fetch +ca-bundle
endef

# 说明（与 CI 预编译产物的差异）：
#   - 上面是「在 buildroot/SDK 里构建」时的完整依赖声明，按分支分别成立。
#   - CI 直接产出的 ipk/apk 只声明 luci-base：25.12 x86 的 targets feed 实测
#     没有发布 kmod-nf-tproxy，而 kmod-nft-tproxy 依赖它；把 kmod-nft-tproxy
#     写成硬依赖会让 25.12 上「整个包安装失败」，代价远大于收益。
#   - 缺失模块由 firewall_backend=auto 在运行期检测并回退/提示，安装不再被阻断。

define Package/luci-app-ferry/description
  Ferry 把 mihomo 或 sing-box 内核配置成路由器上的透明代理网关：
  LuCI 里选择内核/模式/端口/订阅，保存即自动生成内核配置、安装 nftables
  （可选 iptables）接管规则并托管内核进程。默认使用 TPROXY 模式。
  同一时间只运行一个内核。
endef

# iptables 兼容栈刻意不做硬依赖：
#   - opkg/ipk 分支（23.05/24.10、ImmortalWrt）通常是 iptables + iptables-mod-tproxy
#     + iptables-mod-extra + kmod-ipt-core + kmod-ipt-nat；
#   - apk 分支（main）里 iptables 被拆成 iptables-legacy / iptables-nft，
#     iptables-mod-tproxy 的可用性和 xt_TPROXY 是否随包提供取决于固件。
# 需要 iptables 后端的用户按自己固件分支手动安装；缺依赖时
# firewall_backend=auto 在运行期回退到 nftables，不会导致安装失败。
#
# 初始化：uci-defaults 只在首次开机执行，运行时安装不会跑它。
# 因此用 postinst 立即执行一次（幂等），保证安装完就能 enable 服务、ACL 立即可用；
# 首次开机仍会由 /etc/uci-defaults/50-ferry 兜底。
# 卸载清理依赖 prerm（见下方 Package/luci-app-ferry/prerm）。

define Package/luci-app-ferry/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# 1) LuCI 索引缓存：升级后旧索引可能让新模块解析失败（不清会话目录，不会被登出）
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
# 2) 旧版本遗留文件：按随包清单删除，不猜路径
for f in $$(grep -v '^#' /usr/lib/ferry/legacy-files.txt 2>/dev/null); do
	[ -e "$$f" ] && rm -rf "$$f"
done
# 3) 权限自愈（历史升级可能丢可执行位，rpcd 会因此 500）
chmod 0755 /usr/lib/ferry/*.sh /usr/libexec/rpcd/luci-ferry-kernel /usr/bin/ferry-* 2>/dev/null
chmod 0644 /usr/lib/ferry/kernels-builtin.tsv 2>/dev/null
# 4) 旧版 mirrors.json（无 "version": 2）迁移：旧后端会在迁移分支里无限递归，
#    新后端已修；这里主动跑一次，让升级后的第一次页面请求不再踩旧状态
[ -s /usr/lib/ferry/kernel.sh ] && sh /usr/lib/ferry/kernel.sh init-state >/dev/null 2>&1
[ -s /usr/lib/ferry/kernels-builtin.tsv ] || logger -t ferry "WARN 内置版本清单缺失：/usr/lib/ferry/kernels-builtin.tsv"
# 5) 初始化（幂等）
[ -x /etc/uci-defaults/50-ferry ] && /etc/uci-defaults/50-ferry
# 6) 重新注册 rpcd 方法表/ACL。reload(HUP) 先做，避免直接 restart 打断
#    正在执行的本次安装请求；随后后台 restart + uhttpd 重启确保彻底刷新
/etc/init.d/rpcd reload >/dev/null 2>&1 || killall -HUP rpcd 2>/dev/null
( sleep 5; /etc/init.d/rpcd restart >/dev/null 2>&1; \
  [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1 ) >/dev/null 2>&1 &
logger -t ferry "luci-app-ferry postinst: upgrade state healed, rpcd reloaded" 2>/dev/null
exit 0
endef


define Package/luci-app-ferry/conffiles
/etc/config/ferry
endef

define Package/luci-app-ferry/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ferry $(1)/etc/config/ferry

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ferry $(1)/etc/init.d/ferry
	$(INSTALL_BIN) ./files/etc/init.d/ferry-watchdog $(1)/etc/init.d/ferry-watchdog

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/50-ferry $(1)/etc/uci-defaults/50-ferry

	$(INSTALL_DIR) $(1)/usr/lib/ferry
	$(INSTALL_BIN) ./files/usr/lib/ferry/common.sh $(1)/usr/lib/ferry/common.sh
	$(INSTALL_BIN) ./files/usr/lib/ferry/nodes.sh $(1)/usr/lib/ferry/nodes.sh
	$(INSTALL_BIN) ./files/usr/lib/ferry/rules.sh $(1)/usr/lib/ferry/rules.sh
	$(INSTALL_BIN) ./files/usr/lib/ferry/generate.sh $(1)/usr/lib/ferry/generate.sh
	$(INSTALL_BIN) ./files/usr/lib/ferry/firewall.sh $(1)/usr/lib/ferry/firewall.sh
	$(INSTALL_BIN) ./files/usr/lib/ferry/uninstall.sh $(1)/usr/lib/ferry/uninstall.sh
	$(INSTALL_BIN) ./files/usr/lib/ferry/kernel.sh $(1)/usr/lib/ferry/kernel.sh
	# 内置版本清单（含官方 SHA-256/大小）：离线也能列出可下载版本
	$(INSTALL_DATA) ./files/usr/lib/ferry/kernels-builtin.tsv $(1)/usr/lib/ferry/kernels-builtin.tsv
	$(INSTALL_DATA) ./files/usr/lib/ferry/legacy-files.txt $(1)/usr/lib/ferry/legacy-files.txt
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/ferry $(1)/lib/upgrade/keep.d/ferry
	$(INSTALL_BIN) ./files/usr/lib/ferry/transaction.sh $(1)/usr/lib/ferry/transaction.sh
	$(INSTALL_BIN) ./files/usr/lib/ferry/watchdog.sh $(1)/usr/lib/ferry/watchdog.sh

	# 事务/诊断 CLI
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/ferry-txnctl $(1)/usr/bin/ferry-txnctl
	$(INSTALL_BIN) ./files/usr/bin/ferry-diag $(1)/usr/bin/ferry-diag
	$(INSTALL_BIN) ./files/usr/bin/ferry-sysupgrade $(1)/usr/bin/ferry-sysupgrade
	$(INSTALL_BIN) ./files/usr/bin/ferry-kernel-diag $(1)/usr/bin/ferry-kernel-diag

	# 升级后首次启动自愈钩子（同时被 keep.d 保留）
	$(INSTALL_BIN) ./files/etc/uci-defaults/60-ferry-selfheal $(1)/etc/uci-defaults/60-ferry-selfheal

	# rpcd 后端（内核管理 / 事务与诊断）
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/luci-ferry-kernel $(1)/usr/libexec/rpcd/luci-ferry-kernel
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/luci-ferry-safety $(1)/usr/libexec/rpcd/luci-ferry-safety
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/luci-ferry-upgrade $(1)/usr/libexec/rpcd/luci-ferry-upgrade

	# 节点/profile 持久化目录（节点与 profile 不入 UCI）
	$(INSTALL_DIR) $(1)/etc/ferry/rules-cache/mihomo
	$(INSTALL_DIR) $(1)/etc/ferry/rules-cache/sing-box

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-ferry.json \
		$(1)/usr/share/luci/menu.d/luci-app-ferry.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-ferry.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-ferry.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ferry
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/main.js \
		$(1)/www/luci-static/resources/view/ferry/main.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/nodes.js \
		$(1)/www/luci-static/resources/view/ferry/nodes.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/rules.js \
		$(1)/www/luci-static/resources/view/ferry/rules.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/presets.js \
		$(1)/www/luci-static/resources/view/ferry/presets.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/deploy.js \
		$(1)/www/luci-static/resources/view/ferry/deploy.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/profiles.js \
		$(1)/www/luci-static/resources/view/ferry/profiles.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/kernel.js \
		$(1)/www/luci-static/resources/view/ferry/kernel.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/safety.js \
		$(1)/www/luci-static/resources/view/ferry/safety.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/ferry/upgrade.js \
		$(1)/www/luci-static/resources/view/ferry/upgrade.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/ferry
	$(INSTALL_DATA) ./files/www/luci-static/resources/ferry/links.js \
		$(1)/www/luci-static/resources/ferry/links.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/ferry/preset-defs.js \
		$(1)/www/luci-static/resources/ferry/preset-defs.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/ferry/store.js \
		$(1)/www/luci-static/resources/ferry/store.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/ferry/kernels.js \
		$(1)/www/luci-static/resources/ferry/kernels.js
endef

# 卸载清理。
# 包管理器脚本机制（已核对，见 README 4.7）：
#   - opkg/ipk：Package/prerm -> CONTROL/prerm，卸载前执行；升级时也会执行，
#     且第一个参数为 "upgrade"（此时不应停服务/清规则）。
#   - apk/OpenWrt main：include/package-pack.mk 把 Package/prerm 打包成
#     pre-deinstall 脚本，apk del 时先执行它（升级走 pre/post-upgrade，不会触发）。
# 脚本幂等，且始终 exit 0，避免清理失败阻断卸载。
define Package/luci-app-ferry/prerm
#!/bin/sh
[ "$1" = "upgrade" ] && exit 0
[ -x /usr/lib/ferry/uninstall.sh ] && /usr/lib/ferry/uninstall.sh
exit 0
endef

$(eval $(call BuildPackage,luci-app-ferry))

# ===========================================================================
# 可选独立包：内嵌 zashboard 3.22.0 面板（约 5.5 MB 解包后）
#
# 刻意与主包分开：16 MB flash 的设备只装主包，不装这 5.5 MB 静态资源。
# zashboard 版本锁死 3.22.0：3.23.0 起上游移除 sing-box 支持。
# vendor/ 里的静态文件 = 上游 dist-no-fonts.zip（SHA-256 见
# dashboard/patches/zashboard-3.22.0-readonly.patch 的文件头）+ 该 patch。
# ===========================================================================
define Package/luci-app-ferry-dashboard
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Optional dashboard (zashboard 3.22.0, read-only) for Ferry
  PKGARCH:=all
  DEPENDS:=+luci-app-ferry +luci-base
endef

define Package/luci-app-ferry-dashboard/description
  为 Ferry 提供内嵌的 zashboard 3.22.0 面板（只读补丁，版本锁死）：
  mihomo 与 sing-box 共用同一个面板入口。监听地址只绑 LAN IPv4，
  secret 随机生成并注入两个内核的配置，防火墙只放行 LAN。
  独立安装：不装本包时主包不产生任何面板端点。
endef

define Package/luci-app-ferry-dashboard/conffiles
/etc/config/ferry-dashboard
endef

define Package/luci-app-ferry-dashboard/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
chmod 0755 /usr/lib/ferry/panel.sh /usr/bin/ferry-panel /usr/libexec/rpcd/luci-ferry-panel 2>/dev/null
chmod 0644 /usr/share/luci/menu.d/luci-app-ferry-dashboard.json /usr/share/rpcd/acl.d/luci-app-ferry-dashboard.json 2>/dev/null
# 开机顺序：ferry-panel(98) 先于 ferry(99)，保证 secret 在生成配置前就位
[ -x /etc/init.d/ferry-panel ] && /etc/init.d/ferry-panel enable >/dev/null 2>&1
# 已启用时重新装一次 LAN-only 防火墙（升级/重启 fw4 后可能被清掉）
[ "$$(uci -q get ferry-dashboard.main.enabled)" = 1 ] && /usr/bin/ferry-panel boot >/dev/null 2>&1
/etc/init.d/rpcd reload >/dev/null 2>&1 || killall -HUP rpcd 2>/dev/null
( sleep 4; /etc/init.d/rpcd restart >/dev/null 2>&1 ) >/dev/null 2>&1 &
logger -t ferry-panel "luci-app-ferry-dashboard postinst: installed/enabled" 2>/dev/null
exit 0
endef

define Package/luci-app-ferry-dashboard/prerm
#!/bin/sh
[ "$$1" = "upgrade" ] && exit 0
# 卸载必须回到原状：停面板规则、删 secret、删本包 UCI，并重启内核让
# external-controller / clash_api 从生成配置里消失（端口释放）
[ -x /usr/bin/ferry-panel ] && /usr/bin/ferry-panel cleanup
[ -x /etc/init.d/ferry-panel ] && /etc/init.d/ferry-panel disable >/dev/null 2>&1
rm -f /etc/config/ferry-dashboard
exit 0
endef

define Package/luci-app-ferry-dashboard/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./dashboard/files/etc/config/ferry-dashboard $(1)/etc/config/ferry-dashboard

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./dashboard/files/etc/init.d/ferry-panel $(1)/etc/init.d/ferry-panel

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./dashboard/files/usr/bin/ferry-panel $(1)/usr/bin/ferry-panel

	$(INSTALL_DIR) $(1)/usr/lib/ferry
	$(INSTALL_BIN) ./dashboard/files/usr/lib/ferry/panel.sh $(1)/usr/lib/ferry/panel.sh

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./dashboard/files/usr/libexec/rpcd/luci-ferry-panel $(1)/usr/libexec/rpcd/luci-ferry-panel

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./dashboard/files/usr/share/luci/menu.d/luci-app-ferry-dashboard.json \
		$(1)/usr/share/luci/menu.d/luci-app-ferry-dashboard.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./dashboard/files/usr/share/rpcd/acl.d/luci-app-ferry-dashboard.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-ferry-dashboard.json
	$(INSTALL_DIR) $(1)/usr/share/licenses/luci-app-ferry-dashboard
	$(INSTALL_DATA) ./dashboard/files/usr/share/licenses/luci-app-ferry-dashboard/LICENSE.zashboard \
		$(1)/usr/share/licenses/luci-app-ferry-dashboard/LICENSE.zashboard

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ferry
	$(INSTALL_DATA) ./dashboard/files/www/luci-static/resources/view/ferry/dashboard.js \
		$(1)/www/luci-static/resources/view/ferry/dashboard.js

	# zashboard 3.22.0（已打只读补丁）+ 我们的只读 shim
	$(INSTALL_DIR) $(1)/www/luci-static/ferry-dashboard
	$(CP) ./dashboard/vendor/zashboard-3.22.0/. $(1)/www/luci-static/ferry-dashboard/
	$(CP) ./dashboard/files/www/luci-static/ferry-dashboard/. $(1)/www/luci-static/ferry-dashboard/
endef

$(eval $(call BuildPackage,luci-app-ferry-dashboard))
