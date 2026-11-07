#!/usr/bin/env bash
# 构建 ipk + apk（主包 + 可选的 Dashboard 包），并生成 SHA256SUMS。
# 版本取自 Makefile 的 PKG_VERSION/PKG_RELEASE。
# 用法：scripts/ci/build-pkgs.sh [dist_dir]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="${1:-${DIST:-$REPO/dist}}"
STAGE="${STAGE:-$REPO/.ci/stage}"
STAGE_DASH="${STAGE_DASH:-$REPO/.ci/stage-dashboard}"
APK_STATIC="${APK_STATIC:-$REPO/.ci/tools/apk.static}"

VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$REPO/Makefile" | head -1)"
RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$REPO/Makefile" | head -1)"
if [ -z "$VERSION" ] || [ -z "$RELEASE" ]; then
	echo "ERROR: 无法从 Makefile 读取 PKG_VERSION/PKG_RELEASE" >&2
	exit 1
fi
PKGVER="${VERSION}-r${RELEASE}"
MAIN_IPK="luci-app-ferry_${PKGVER}_all.ipk"
MAIN_APK="luci-app-ferry-${PKGVER}.apk"
DASH_IPK="luci-app-ferry-dashboard_${PKGVER}_all.ipk"
DASH_APK="luci-app-ferry-dashboard-${PKGVER}.apk"

if [ ! -x "$APK_STATIC" ]; then
	echo "ERROR: 缺少 apk.static（$APK_STATIC）。先运行 scripts/ci/fetch-apk-tools.sh" >&2
	exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"
bash "$REPO/scripts/ci/stage.sh" "$STAGE"
bash "$REPO/scripts/ci/stage-dashboard.sh" "$STAGE_DASH"

# ---------------------------------------------------------------- ipk 主包
python3 "$REPO/scripts/ci/build_ipk.py" \
	"$STAGE" "$DIST/$MAIN_IPK" "$PKGVER" "$REPO/scripts/ci/post-install.sh"

# ---------------------------------------------------------------- ipk 面板包
IPK_NAME="luci-app-ferry-dashboard" \
IPK_DESC="Optional zashboard 3.22.0 dashboard for Ferry (LAN-only, read-only, pinned)" \
IPK_DEPENDS="luci-base, luci-app-ferry" \
IPK_LICENSE="GPL-2.0-only AND MIT" \
IPK_CONFFILES=$'/etc/config/ferry-dashboard\n' \
IPK_PRERM="$(cat "$REPO/scripts/ci/pre-deinstall-dashboard.sh")" \
python3 "$REPO/scripts/ci/build_ipk.py" \
	"$STAGE_DASH" "$DIST/$DASH_IPK" "$PKGVER" "$REPO/scripts/ci/post-install-dashboard.sh"

# ---------------------------------------------------------------------------
# apk 侧 conffiles 元数据（与 OpenWrt SDK 的 package-pack.mk 保持一致）：
# apk v3 不再把 conffiles 放在控制区，而是作为包内文件
#   /lib/apk/packages/<pkg>.conffiles        （路径清单）
#   /lib/apk/packages/<pkg>.conffiles_static （路径 + 包内原始 sha256）
# ---------------------------------------------------------------------------
EPOCH="${SOURCE_DATE_EPOCH:-1600000000}"

apk_meta() {
	local stage="$1" pkg="$2" conf="$3"
	local meta="$stage/lib/apk/packages"
	mkdir -p "$meta"
	printf '%s\n' "$conf" > "$meta/$pkg.conffiles"
	printf '%s %s\n' "$conf" "$(sha256sum "$stage$conf" | awk '{print $1}')" \
		> "$meta/$pkg.conffiles_static"
	printf '/lib/apk/packages/%s.conffiles\n' "$pkg" > "$meta/$pkg.list"
	printf '/lib/apk/packages/%s.conffiles_static\n' "$pkg" >> "$meta/$pkg.list"
	(
		cd "$stage"
		find . -type f,l -printf '/%P\n' | sort | grep -v "^/lib/apk/packages/$pkg\." \
			>> "$meta/$pkg.list"
	)
	# 确定性 mtime（新增的 apk 元数据文件也要归一）
	find "$meta" -exec touch -h -d "@$EPOCH" {} +
}

apk_meta "$STAGE" "luci-app-ferry" "/etc/config/ferry"
apk_meta "$STAGE_DASH" "luci-app-ferry-dashboard" "/etc/config/ferry-dashboard"

# apk 的 ADB 记录文件属主：直接用当前用户打包会写成 <builder>:<builder>
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
	sudo -n chown -R 0:0 "$STAGE" "$STAGE_DASH"
elif command -v unshare >/dev/null 2>&1 && unshare -r true 2>/dev/null; then
	PKG_RUN=(unshare -r)
else
	echo "WARN: 无 sudo/unshare，apk 内文件属主会沿用当前用户（verify 会失败）" >&2
fi
restore_owner() {
	if [ "$OWN_SHIFT" = sudo ]; then
		sudo -n chown -R "$(id -u):$(id -g)" "$STAGE" "$STAGE_DASH" 2>/dev/null || true
	fi
}
trap restore_owner EXIT

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
	-o "$DIST/$MAIN_APK"

run_apk_mkpkg \
	-I "name:luci-app-ferry-dashboard" \
	-I "version:$PKGVER" \
	-I "arch:noarch" \
	-I "license:GPL-2.0-only AND MIT" \
	-I "origin:luci-app-ferry" \
	-I "maintainer:yunyu697" \
	-I "url:https://github.com/yunyu697/luci-app-ferry" \
	-I "description:Optional zashboard 3.22.0 dashboard for Ferry (LAN-only, read-only, pinned)" \
	-I "depends:luci-base" \
	-I "depends:luci-app-ferry" \
	-s "pre-deinstall:$REPO/scripts/ci/pre-deinstall-dashboard.sh" \
	-s "post-install:$REPO/scripts/ci/post-install-dashboard.sh" \
	-F "$STAGE_DASH" \
	-o "$DIST/$DASH_APK"

(
	cd "$DIST"
	sha256sum "$MAIN_IPK" "$MAIN_APK" "$DASH_IPK" "$DASH_APK" > SHA256SUMS
)
printf '%s\n' "PKGVER=$PKGVER" "IPK=$MAIN_IPK" "APK=$MAIN_APK" \
	"DASH_IPK=$DASH_IPK" "DASH_APK=$DASH_APK" > "$DIST/build-meta.txt"

echo "--- dist ---"
ls -l "$DIST"
cat "$DIST/SHA256SUMS"
