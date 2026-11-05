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
PKG_RELEASE:=5

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
[ -x /etc/uci-defaults/50-ferry ] && /etc/uci-defaults/50-ferry
/etc/init.d/rpcd reload >/dev/null 2>&1 || killall -HUP rpcd 2>/dev/null
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
	$(INSTALL_BIN) ./files/usr/lib/ferry/transaction.sh $(1)/usr/lib/ferry/transaction.sh
	$(INSTALL_BIN) ./files/usr/lib/ferry/watchdog.sh $(1)/usr/lib/ferry/watchdog.sh

	# 事务/诊断 CLI
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/ferry-txnctl $(1)/usr/bin/ferry-txnctl
	$(INSTALL_BIN) ./files/usr/bin/ferry-diag $(1)/usr/bin/ferry-diag

	# rpcd 后端（内核管理 / 事务与诊断）
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/luci-ferry-kernel $(1)/usr/libexec/rpcd/luci-ferry-kernel
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/luci-ferry-safety $(1)/usr/libexec/rpcd/luci-ferry-safety

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
