#!/usr/bin/env bash
# 校验 tag 与 Makefile PKG_VERSION/PKG_RELEASE 一致（apk pkgver 由同一版本派生）
# 用法：scripts/ci/check-version.sh v1.0.0-r12
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${1:?用法: check-version.sh <tag>}"

VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$REPO/Makefile" | head -1)"
RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$REPO/Makefile" | head -1)"
[ -n "$VERSION" ] && [ -n "$RELEASE" ] || {
	echo "ERROR: 无法从 Makefile 读取 PKG_VERSION/PKG_RELEASE" >&2
	exit 1
}
EXPECTED="v${VERSION}-r${RELEASE}"
APK_PKGVER="${VERSION}-r${RELEASE}"

echo "tag:        $TAG"
echo "Makefile:   PKG_VERSION=$VERSION PKG_RELEASE=$RELEASE"
echo "expected:   $EXPECTED"
echo "apk pkgver: $APK_PKGVER"

if [ "$TAG" != "$EXPECTED" ]; then
	echo "ERROR: tag ($TAG) 与 Makefile ($EXPECTED) 不一致" >&2
	exit 1
fi
case "$TAG" in
	v[0-9]*.[0-9]*.[0-9]*-r[0-9]*) ;;
	*)
		echo "ERROR: tag 格式不是 vX.Y.Z-rN：$TAG" >&2
		exit 1
		;;
esac

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "version=$VERSION"
		echo "release=$RELEASE"
		echo "pkgver=$APK_PKGVER"
	} >> "$GITHUB_OUTPUT"
fi
