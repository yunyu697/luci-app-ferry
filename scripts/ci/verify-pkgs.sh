#!/usr/bin/env bash
# 校验 ipk/apk：包内文件与源码 files/ 一致（逐文件 diff/cmp）、数量一致、元数据版本一致
# 用法：scripts/ci/verify-pkgs.sh [dist_dir]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST="${1:-${DIST:-$REPO/dist}}"
# 解包前会 cd 到临时目录，这里必须先转成绝对路径（CI 传的是相对 dist）
[ -d "$DIST" ] || { echo "ERROR: dist 目录不存在：$DIST" >&2; exit 1; }
DIST="$(cd "$DIST" && pwd)"
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
# apk 额外带 /lib/apk/packages/* 元数据（conffiles/.list），不计入包内容
APK_COUNT="$(find "$WORK/apk-data" -type f \
	! -path "$WORK/apk-data/lib/apk/packages/luci-app-ferry.*" | wc -l | tr -d ' ')"
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
# apk 的 /lib/apk/packages 是 apk 专有元数据目录，比较内容前先剔除
mkdir -p "$WORK/apk-data-cmp"
cp -a "$WORK/apk-data/." "$WORK/apk-data-cmp/"
rm -rf "$WORK/apk-data-cmp/lib/apk"
diff -r "$WORK/ipk-data" "$WORK/apk-data-cmp" || {
	echo "ERROR: ipk 与 apk 内容不一致" >&2; exit 1;
}
echo "OK: ipk/apk 与 files/ 逐文件一致（$REPO_COUNT files）"

echo "=== apk 元数据（属主/权限/conffiles） ==="
"$APK_STATIC" adbdump "$APK" > "$WORK/adbdump.txt" 2>/dev/null || {
	echo "ERROR: adbdump 失败" >&2; exit 1;
}
# 1) 文件属主必须是 root:root（当前用户打包会写成 <builder>:<builder>）
if grep -qE '^ *user: ' "$WORK/adbdump.txt" && grep -E '^ *user: ' "$WORK/adbdump.txt" \
	| grep -qv 'user: root'; then
	echo "ERROR: apk 内文件属主不是 root（疑似泄漏构建用户名）" >&2
	grep -E '^ *user: ' "$WORK/adbdump.txt" | grep -v 'user: root' | sort -u | head -5 >&2
	exit 1
fi
if grep -qE '^ *group: ' "$WORK/adbdump.txt" && grep -E '^ *group: ' "$WORK/adbdump.txt" \
	| grep -qv 'group: root'; then
	echo "ERROR: apk 内文件属组不是 root" >&2; exit 1
fi
# 2) 不允许 0777（目录放宽权限会带来安全/一致性问题）
if grep -q 'mode: 0777' "$WORK/adbdump.txt"; then
	echo "ERROR: apk 内存在 0777 权限项" >&2
	grep -B2 'mode: 0777' "$WORK/adbdump.txt" | head -10 >&2
	exit 1
fi
# 3) conffiles 元数据必须存在且登记了配置路径
for f in conffiles conffiles_static list; do
	[ -f "$WORK/apk-data/lib/apk/packages/luci-app-ferry.$f" ] || {
		echo "ERROR: apk 缺少 /lib/apk/packages/luci-app-ferry.$f" >&2; exit 1;
	}
done
grep -qx '/etc/config/ferry' "$WORK/apk-data/lib/apk/packages/luci-app-ferry.conffiles" || {
	echo "ERROR: apk conffiles 未登记 /etc/config/ferry" >&2; exit 1;
}
echo "OK: apk 属主 root、无 0777、conffiles 已登记"

echo "=== 未打包进包的文件（应为空） ==="
( cd "$REPO" && find files -type f | sed 's|^files/||' | sort ) > "$WORK/repo-list"
( cd "$WORK/ipk-data" && find . -type f | sed 's|^\./||' | sort ) > "$WORK/ipk-list"
if diff -u "$WORK/repo-list" "$WORK/ipk-list"; then
	echo "OK: 文件清单一致"
else
	echo "ERROR: 文件清单不一致" >&2
	exit 1
fi
