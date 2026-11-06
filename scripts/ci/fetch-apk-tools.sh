#!/usr/bin/env bash
# 下载静态 apk-tools（Alpine v3.23），用于在 Ubuntu 上生成/解包 OpenWrt 25.12 的 .apk
# 用法：scripts/ci/fetch-apk-tools.sh [dest_dir]
set -euo pipefail

DEST="${1:-${APK_TOOLS_DIR:-.ci/tools}}"
BRANCH="${ALPINE_BRANCH:-v3.23}"
ARCH="${ALPINE_ARCH:-x86_64}"
BASE="https://dl-cdn.alpinelinux.org/alpine/${BRANCH}/main/${ARCH}"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
if [ -x "$DEST/apk.static" ]; then
	echo "apk.static already present: $("$DEST/apk.static" --version 2>/dev/null | tail -1)"
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
	"$BASE/APKINDEX.tar.gz" -o "$TMP/APKINDEX.tar.gz"
tar -xzf "$TMP/APKINDEX.tar.gz" -C "$TMP" APKINDEX
VER="$(awk -v RS='' '/P:apk-tools-static/' "$TMP/APKINDEX" | sed -n 's/^V://p' | head -1)"
if [ -z "$VER" ]; then
	echo "ERROR: 无法从 APKINDEX 解析 apk-tools-static 版本（$BASE/APKINDEX.tar.gz）" >&2
	exit 1
fi

APK="apk-tools-static-${VER}.apk"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "$BASE/$APK" -o "$TMP/$APK"
mkdir -p "$TMP/x"
tar -xzf "$TMP/$APK" -C "$TMP/x"
BIN="$(find "$TMP/x" -type f \( -name apk.static -o -path '*/sbin/apk' \) | head -1)"
if [ -z "$BIN" ]; then
	echo "ERROR: $APK 中未找到 apk.static" >&2
	exit 1
fi
install -m 0755 "$BIN" "$DEST/apk.static"
"$DEST/apk.static" --version
echo "apk-tools -> $DEST/apk.static (Alpine $BRANCH, $APK)"
