#!/usr/bin/env bash
# 构建 ipk + apk，并生成 SHA256SUMS。版本取自 Makefile 的 PKG_VERSION/PKG_RELEASE。
# 用法：scripts/ci/build-pkgs.sh [dist_dir]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="${1:-${DIST:-$REPO/dist}}"
STAGE="${STAGE:-$REPO/.ci/stage}"
APK_STATIC="${APK_STATIC:-$REPO/.ci/tools/apk.static}"

VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$REPO/Makefile" | head -1)"
RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$REPO/Makefile" | head -1)"
if [ -z "$VERSION" ] || [ -z "$RELEASE" ]; then
	echo "ERROR: 无法从 Makefile 读取 PKG_VERSION/PKG_RELEASE" >&2
	exit 1
fi
PKGVER="${VERSION}-r${RELEASE}"
IPK="luci-app-ferry_${PKGVER}_all.ipk"
APK="luci-app-ferry-${PKGVER}.apk"

if [ ! -x "$APK_STATIC" ]; then
	echo "ERROR: 缺少 apk.static（$APK_STATIC）。先运行 scripts/ci/fetch-apk-tools.sh" >&2
	exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"
bash "$REPO/scripts/ci/stage.sh" "$STAGE"

python3 "$REPO/scripts/ci/build_ipk.py" \
	"$STAGE" "$DIST/$IPK" "$PKGVER" "$REPO/scripts/ci/post-install.sh"

# ---------------------------------------------------------------------------
# apk 侧 conffiles 元数据（与 OpenWrt SDK 的 package-pack.mk 保持一致）：
# apk v3 不再把 conffiles 放在控制区，而是作为包内文件
#   /lib/apk/packages/<pkg>.conffiles        （路径清单）
#   /lib/apk/packages/<pkg>.conffiles_static （路径 + 包内原始 sha256）
# 缺这两份文件时 apk 不知道 /etc/config/ferry 是配置文件，删除/升级都可能覆盖用户配置。
# ---------------------------------------------------------------------------
APK_META="$STAGE/lib/apk/packages"
mkdir -p "$APK_META"
printf '/etc/config/ferry\n' > "$APK_META/luci-app-ferry.conffiles"
printf '/etc/config/ferry %s\n' \
	"$(sha256sum "$STAGE/etc/config/ferry" | awk '{print $1}')" \
	> "$APK_META/luci-app-ferry.conffiles_static"
printf '/lib/apk/packages/luci-app-ferry.conffiles\n' > "$APK_META/luci-app-ferry.list"
printf '/lib/apk/packages/luci-app-ferry.conffiles_static\n' >> "$APK_META/luci-app-ferry.list"
(
	cd "$STAGE"
	find . -type f,l -printf '/%P\n' | sort | grep -v '^/lib/apk/packages/luci-app-ferry\.' \
		>> "$APK_META/luci-app-ferry.list"
)

# 确定性 mtime（新增的 apk 元数据文件也要归一）
EPOCH="${SOURCE_DATE_EPOCH:-1600000000}"
find "$APK_META" -exec touch -h -d "@$EPOCH" {} +

# apk 的 ADB 记录文件属主：直接用当前用户打包会写成 <builder>:<builder>
# （实测 r12 的 ADB 里是 tyler:tyler，安装到设备后属主非 root）。
# apk.static 是静态二进制，LD_PRELOAD 型 fakeroot 对它无效，因此按以下顺序取根属主：
#   1) 已是 root：直接打包
#   2) 有 sudo：把 stage 临时 chown 到 root:root，打包后改回
#   3) 有可用的 unshare -r：user namespace 把当前用户映射成 uid 0
#   4) 都没有：警告（产物属主会是构建者，verify-pkgs.sh 会因此失败）
PKG_RUN=()
OWN_SHIFT=""
if [ "$(id -u)" = 0 ]; then
	:
elif sudo -n true 2>/dev/null; then
	OWN_SHIFT=sudo
	sudo -n chown -R 0:0 "$STAGE"
elif command -v unshare >/dev/null 2>&1 && unshare -r true 2>/dev/null; then
	PKG_RUN=(unshare -r)
else
	echo "WARN: 无 sudo/unshare，apk 内文件属主会沿用当前用户（verify 会失败）" >&2
fi
restore_owner() {
	if [ "$OWN_SHIFT" = sudo ]; then
		sudo -n chown -R "$(id -u):$(id -g)" "$STAGE" 2>/dev/null || true
	fi
}
trap restore_owner EXIT

# 注意：depends 只声明 luci-base（硬依赖）。kmod-nft-tproxy / kmod-tun / ip-full 等
# 属于「按模式需要」的依赖，且 25.12 x86 targets feed 未发布 kmod-nf-tproxy，
# 声明成硬依赖会让 25.12 整体安装失败；运行期由 firewall_backend=auto 检测并提示。
run_apk_mkpkg() {
	"${PKG_RUN[@]}" "$APK_STATIC" mkpkg "$@"
}
run_apk_mkpkg \
	-I "name:luci-app-ferry" \
	-I "version:$PKGVER" \
	-I "arch:noarch" \
	-I "license:GPL-2.0-only" \
	-I "origin:luci-app-ferry" \
	-I "maintainer:yunyu697" \
	-I "url:https://github.com/yunyu697/luci-app-ferry" \
	-I "description:Ferry (dukou) transparent proxy gateway (mihomo / sing-box)" \
	-I "depends:luci-base" \
	-s "pre-deinstall:$REPO/scripts/ci/pre-deinstall.sh" \
	-s "post-install:$REPO/scripts/ci/post-install.sh" \
	-F "$STAGE" \
	-o "$DIST/$APK"

(
	cd "$DIST"
	sha256sum "$IPK" "$APK" > SHA256SUMS
)
printf '%s\n' "PKGVER=$PKGVER" "IPK=$IPK" "APK=$APK" > "$DIST/build-meta.txt"

echo "--- dist ---"
ls -l "$DIST"
cat "$DIST/SHA256SUMS"
