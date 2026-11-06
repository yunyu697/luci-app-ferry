#!/usr/bin/env bash
# 校验 ipk/apk：包内文件与源码 files/ 一致（逐文件 diff/cmp）、数量一致、元数据版本一致
# 用法：scripts/ci/verify-pkgs.sh [dist_dir]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="${1:-${DIST:-$REPO/dist}}"
APK_STATIC="${APK_STATIC:-$REPO/.ci/tools/apk.static}"
META="$DIST/build-meta.txt"

[ -f "$META" ] || { echo "ERROR: 缺少 $META" >&2; exit 1; }
# shellcheck disable=SC1090
. "$META"
IPK="$DIST/$IPK"
APK="$DIST/$APK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== 解包 ipk ==="
mkdir -p "$WORK/ipk-outer" "$WORK/ipk-data"
tar -xzf "$IPK" -C "$WORK/ipk-outer"
tar -xzf "$WORK/ipk-outer/data.tar.gz" -C "$WORK/ipk-data"
mkdir -p "$WORK/ipk-control"
tar -xzf "$WORK/ipk-outer/control.tar.gz" -C "$WORK/ipk-control"

echo "=== 解包 apk ==="
mkdir -p "$WORK/apk-data"
( cd "$WORK/apk-data" && "$APK_STATIC" extract --allow-untrusted "$APK" >/dev/null )

echo "=== 元数据版本 ==="
IPK_VER="$(sed -n 's/^Version: //p' "$WORK/ipk-control/control")"
APK_VER="$("$APK_STATIC" adbdump "$APK" | sed -n 's/^  version: //p' | head -1)"
[ "$IPK_VER" = "$PKGVER" ] || { echo "ERROR: ipk Version=$IPK_VER != $PKGVER" >&2; exit 1; }
[ "$APK_VER" = "$PKGVER" ] || { echo "ERROR: apk version=$APK_VER != $PKGVER" >&2; exit 1; }
echo "ipk=$IPK_VER apk=$APK_VER (expected $PKGVER)"

echo "=== 文件数量 ==="
REPO_COUNT="$(find "$REPO/files" -type f | wc -l | tr -d ' ')"
IPK_COUNT="$(find "$WORK/ipk-data" -type f | wc -l | tr -d ' ')"
APK_COUNT="$(find "$WORK/apk-data" -type f | wc -l | tr -d ' ')"
echo "repo=$REPO_COUNT ipk=$IPK_COUNT apk=$APK_COUNT"
[ "$REPO_COUNT" = "$IPK_COUNT" ] || { echo "ERROR: ipk 文件数不一致" >&2; exit 1; }
[ "$REPO_COUNT" = "$APK_COUNT" ] || { echo "ERROR: apk 文件数不一致" >&2; exit 1; }

echo "=== 内容一致性（diff -r / cmp） ==="
# repo 不跟踪空目录；把随包空目录补进期望树后做完整 diff -r
mkdir -p "$WORK/repo-expected"
cp -a "$REPO/files/." "$WORK/repo-expected/"
mkdir -p "$WORK/repo-expected/etc/ferry/rules-cache/mihomo" \
	"$WORK/repo-expected/etc/ferry/rules-cache/sing-box"
diff -r "$WORK/repo-expected" "$WORK/ipk-data" || {
	echo "ERROR: ipk 内容与 files/ 不一致" >&2; exit 1;
}
diff -r "$WORK/ipk-data" "$WORK/apk-data" || {
	echo "ERROR: ipk 与 apk 内容不一致" >&2; exit 1;
}
echo "OK: ipk/apk 与 files/ 逐文件一致（$REPO_COUNT files）"

echo "=== 未打包进包的文件（应为空） ==="
( cd "$REPO" && find files -type f | sed 's|^files/||' | sort ) > "$WORK/repo-list"
( cd "$WORK/ipk-data" && find . -type f | sed 's|^\./||' | sort ) > "$WORK/ipk-list"
if diff -u "$WORK/repo-list" "$WORK/ipk-list"; then
	echo "OK: 文件清单一致"
else
	echo "ERROR: 文件清单不一致" >&2
	exit 1
fi
