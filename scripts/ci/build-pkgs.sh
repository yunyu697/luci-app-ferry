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

"$APK_STATIC" mkpkg \
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
