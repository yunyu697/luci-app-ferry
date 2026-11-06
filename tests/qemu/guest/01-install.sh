#!/bin/sh
# 路由器 guest：安装 ferry 包与测试依赖，铺好 direct 出站内核配置。
# 参数：ipk|apk（包类型）
set -u
KIND="${1:-ipk}"
PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

echo "== 包管理器 =="
PKG="/tmp/ferry.$KIND"
if [ "$KIND" = apk ]; then
	apk add --allow-untrusted "$PKG" >/tmp/apk-ferry.log 2>&1; RC=$?
	tail -5 /tmp/apk-ferry.log
	[ "$RC" = 0 ] && ok "apk add 安装成功" || bad "apk add 失败（rc=$RC）"
	command -v ip >/dev/null 2>&1 || apk add ip-full >/dev/null 2>&1
	# 离线 kmod：宿主按本 kernel 版本预下载（--allow-untrusted 的签名提示属预期，记入日志）
	if ls /tmp/kmod-*.apk >/dev/null 2>&1; then
		echo "-- 离线 kmods（签名不可信提示为预期行为）"
		apk add --allow-untrusted /tmp/kmod-*.apk >/tmp/apk-kmods.log 2>&1; RC=$?
		tail -12 /tmp/apk-kmods.log
		[ "$RC" = 0 ] && ok "离线 kmods 安装成功" || bad "离线 kmods 安装失败（rc=$RC）"
	fi
	if ! lsmod | grep -q nft_tproxy; then
		i=0
		while [ $i -lt 3 ]; do
			apk add kmod-nft-tproxy >/dev/null 2>&1 || apk add --allow-untrusted kmod-nft-tproxy >/dev/null 2>&1
			modprobe nf_tproxy >/dev/null 2>&1
			modprobe nft_tproxy >/dev/null 2>&1
			lsmod | grep -q nft_tproxy && break
			i=$((i+1)); sleep 5
		done
	fi
	KVER=$(uname -r)
	if lsmod | grep -q nft_tproxy; then
		ok "kmod-nft-tproxy 已加载（kver=$KVER）"
		VM=$(modinfo nft_tproxy 2>/dev/null | awk '/^vermagic/{print $2}')
		[ "$VM" = "$KVER" ] && ok "kmod vermagic 与内核一致（$VM）" || bad "kmod vermagic 不匹配（kmod=$VM kernel=$KVER）"
		modprobe nft_tproxy
		[ $? = 0 ] && ok "modprobe nft_tproxy 返回 0" || bad "modprobe nft_tproxy 非 0"
	else
		bad "kmod-nft-tproxy 未加载（tproxy 规则会整份加载失败，kver=$KVER）"
	fi
	ip rule list >/dev/null 2>&1 && ok "ip rule 可用" || bad "ip rule 不可用"
else
	# 优先用宿主预下载的 kmod（官方镜像默认 feeds 不含 kernel 专用 kmods 目录）
	if ls /tmp/kmod-*.ipk >/dev/null 2>&1; then
		for f in /tmp/kmod-*.ipk; do
			opkg install --force-depends "$f" 2>&1 | tail -2
		done
		modprobe nf_tproxy >/dev/null 2>&1
		modprobe nft_tproxy >/dev/null 2>&1
	fi
	# 回退路径：按本机 kernel 版本补 kmods feed 后再装（测试环境铺垫，不是产品行为）
	if ! lsmod | grep -q nft_tproxy; then
		KVER=$(opkg list-installed kernel 2>/dev/null | awk '{print $3}')
		if [ -n "$KVER" ]; then
			HASH=${KVER#*~}; HASH=${HASH%-r1}
			KREL=${KVER%%~*}
			KMODS="https://downloads.openwrt.org/releases/24.10.4/targets/x86/64/kmods/$KREL-1-$HASH"
			grep -q openwrt_kmods /etc/opkg/customfeeds.cfg 2>/dev/null || \
				echo "src/gz openwrt_kmods $KMODS" >> /etc/opkg/customfeeds.cfg
			i=0
			while [ $i -lt 3 ]; do
				opkg update >/dev/null 2>&1 && break
				i=$((i+1)); sleep 5
			done
			i=0
			while [ $i -lt 3 ]; do
				opkg install kmod-nft-tproxy 2>&1 | tail -3
				modprobe nft_tproxy >/dev/null 2>&1
				lsmod | grep -q nft_tproxy && break
				i=$((i+1)); sleep 5
			done
		fi
	fi
	lsmod | grep -q nft_tproxy && ok "kmod-nft-tproxy 已加载" || bad "kmod-nft-tproxy 未加载（tproxy 规则会整份加载失败）"
	ip rule list >/dev/null 2>&1 && ok "ip rule 可用" || bad "ip rule 不可用"
	opkg install "$PKG" 2>&1 | tail -5
	[ $? = 0 ] && ok "opkg install 安装成功" || bad "opkg install 失败"
fi

for f in /etc/init.d/ferry /etc/init.d/ferry-watchdog /usr/lib/ferry/transaction.sh \
	/usr/lib/ferry/watchdog.sh /usr/lib/ferry/kernel.sh /usr/bin/ferry-txnctl \
	/usr/bin/ferry-diag /usr/libexec/rpcd/luci-ferry-safety \
	/usr/libexec/rpcd/luci-ferry-kernel; do
	[ -x "$f" ] && ok "installed $f" || bad "missing $f"
done

# 内置版本/源清单必须随包安装（否则「下载不了内核」会复发）
if [ -s /usr/lib/ferry/kernels-builtin.tsv ]; then
	ok "installed /usr/lib/ferry/kernels-builtin.tsv"
	N=$(grep -vc '^#' /usr/lib/ferry/kernels-builtin.tsv)
	[ "$N" -ge 10 ] && ok "内置资产清单条目 $N 条" || bad "内置资产清单条目过少（$N）"
	grep -q '^# generated=' /usr/lib/ferry/kernels-builtin.tsv \
		&& ok "内置清单含生成日期" || bad "内置清单缺生成日期"
else
	bad "missing /usr/lib/ferry/kernels-builtin.tsv"
fi

# 包元数据版本必须与发布版本一致（r6 曾出现文件名 r6、control 仍是 r5）
if [ "$KIND" = ipk ]; then
	V=$(sed -n 's/^Version: //p' /usr/lib/opkg/info/luci-app-ferry.control 2>/dev/null)
else
	V=$(apk info -e luci-app-ferry 2>/dev/null | head -1)
fi
echo "installed_version=$V"
echo "$V" | grep -q '1\.0\.0-r7' && ok "包元数据版本 = 1.0.0-r7" || bad "包元数据版本异常（$V）"

command -v nft >/dev/null 2>&1 && ok "nft 可用" || bad "nft 缺失"
nft list tables >/dev/null 2>&1 && ok "nft 内核接口可用" || bad "nft 不可用"

# 测试内核：mihomo（direct 出站，无真实订阅）
cp /tmp/mihomo /usr/bin/mihomo
chmod 0755 /usr/bin/mihomo
[ -x /usr/bin/mihomo ] && ok "mihomo 已就位" || bad "mihomo 未就位"
/usr/bin/mihomo -v >/dev/null 2>&1 && ok "mihomo 可执行" || bad "mihomo 无法执行"
mkdir -p /etc/ferry
cp /tmp/test-config.yaml /etc/ferry/test-config.yaml
[ -s /etc/ferry/test-config.yaml ] && ok "测试配置已就位" || bad "测试配置缺失"

# dnsmasq “原生上游”基线：固定 223.5.5.5，便于关闭/回滚断言可重复
uci -q delete dhcp.@dnsmasq[0].server
uci -q add_list dhcp.@dnsmasq[0].server=223.5.5.5
uci -q set dhcp.@dnsmasq[0].noresolv=1
uci commit dhcp
/etc/init.d/dnsmasq restart >/dev/null 2>&1
sleep 2
[ "$(uci -q get dhcp.@dnsmasq[0].server)" = 223.5.5.5 ] \
	&& ok "dnsmasq 原生上游 = 223.5.5.5" || bad "dnsmasq 上游异常"

# ferry 基线配置（enabled 先置 1，后续脚本统一走 reload 事务）
uci set ferry.main.enabled='1'
uci set ferry.main.kernel='mihomo'
uci set ferry.main.bin_path='/usr/bin/mihomo'
uci set ferry.main.config_path='/etc/ferry/test-config.yaml'
uci set ferry.main.deploy='router'
uci set ferry.main.mode='tproxy'
# lan_iface 留空：由 pm_detect_lan_iface 从 network.lan.device 自动识别（测试拓扑为 eth1）
uci set ferry.main.rule_update='0'
uci set ferry.main.final_policy='direct'
uci set ferry.main.enable_ipv6='0'
uci set ferry.main.proxy_port='7890'
uci set ferry.main.rollback_timeout='60'
uci commit ferry
/etc/init.d/ferry-watchdog enable >/dev/null 2>&1
/etc/init.d/ferry-watchdog start 2>&1 | tail -3
sleep 2
pgrep -f /usr/lib/ferry/watchdog.sh >/dev/null 2>&1 \
	&& ok "看门狗进程已启动" || { bad "看门狗未启动"; logread | tail -5; }
echo "=== INSTALL_DONE PASS=$PASS FAIL=$FAIL ==="
