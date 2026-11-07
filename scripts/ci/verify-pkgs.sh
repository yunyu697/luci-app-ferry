#!/usr/bin/env bash
# 校验 ipk/apk：主包 + 可选面板包（luci-app-ferry-dashboard）
# 每个包都断言：包内文件与源码树逐文件一致（diff -r）、数量一致、元数据版本一致、
# apk 属主 root、无 0777、conffiles 登记正确；面板包另断言依赖 luci-app-ferry。
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
[ -n "${IPK:-}" ] || { echo "ERROR: build-meta.txt 缺少 IPK" >&2; exit 1; }
[ -n "${APK:-}" ] || { echo "ERROR: build-meta.txt 缺少 APK" >&2; exit 1; }
[ -n "${DASH_IPK:-}" ] || { echo "ERROR: build-meta.txt 缺少 DASH_IPK" >&2; exit 1; }
[ -n "${DASH_APK:-}" ] || { echo "ERROR: build-meta.txt 缺少 DASH_APK" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }

# 期望树：源码 files/ 树（主包）或 dashboard/files + vendor（面板包）
# repo 不跟踪空目录，主包随包空目录需要手工补进期望树。
prepare_expected() {
	local label="$1"
	mkdir -p "$WORK/exp-$label"
	case "$label" in
		main)
			cp -a "$REPO/files/." "$WORK/exp-$label/"
			mkdir -p "$WORK/exp-$label/etc/ferry/rules-cache/mihomo" \
				"$WORK/exp-$label/etc/ferry/rules-cache/sing-box"
			;;
		dash)
			cp -a "$REPO/dashboard/files/." "$WORK/exp-$label/"
			mkdir -p "$WORK/exp-$label/www/luci-static/ferry-dashboard"
			cp -a "$REPO/dashboard/vendor/zashboard-3.22.0/." \
				"$WORK/exp-$label/www/luci-static/ferry-dashboard/"
			;;
		*) fail "未知期望树 $label" ;;
	esac
}

# 参数：label ipk 文件名 apk 文件名 conffile 包名 依赖关键字
verify_one() {
	local label="$1" ipk_name="$2" apk_name="$3" conffile="$4" pkg="$5" dep="$6"
	local ipk="$DIST/$ipk_name" apk="$DIST/$apk_name"
	[ -f "$ipk" ] || fail "缺少 $ipk"
	[ -f "$apk" ] || fail "缺少 $apk"

	echo "=== [$label] 解包 ipk/apk ==="
	mkdir -p "$WORK/$label-ipk-outer" "$WORK/$label-ipk-data" "$WORK/$label-ipk-control"
	tar -xzf "$ipk" -C "$WORK/$label-ipk-outer"
	tar -xzf "$WORK/$label-ipk-outer/data.tar.gz" -C "$WORK/$label-ipk-data"
	tar -xzf "$WORK/$label-ipk-outer/control.tar.gz" -C "$WORK/$label-ipk-control"
	mkdir -p "$WORK/$label-apk-data"
	( cd "$WORK/$label-apk-data" && "$APK_STATIC" extract --allow-untrusted "$apk" >/dev/null )

	echo "=== [$label] 元数据版本/依赖 ==="
	local ipk_ver apk_ver
	"$APK_STATIC" adbdump "$apk" > "$WORK/$label-adbdump.txt" 2>/dev/null ||
		fail "[$label] adbdump 失败"
	ipk_ver="$(sed -n 's/^Version: //p' "$WORK/$label-ipk-control/control")"
	apk_ver="$(sed -n 's/^  version: //p' "$WORK/$label-adbdump.txt" | head -1)"
	[ "$ipk_ver" = "$PKGVER" ] || fail "[$label] ipk Version=$ipk_ver != $PKGVER"
	[ "$apk_ver" = "$PKGVER" ] || fail "[$label] apk version=$apk_ver != $PKGVER"
	echo "[$label] ipk=$ipk_ver apk=$apk_ver (expected $PKGVER)"
	if [ -n "$dep" ]; then
		grep -q "^Depends: .*$dep" "$WORK/$label-ipk-control/control" ||
			fail "[$label] ipk Depends 未包含 $dep"
		grep -q -F -- "- $dep" "$WORK/$label-adbdump.txt" ||
			fail "[$label] apk depends 未包含 $dep"
	fi

	echo "=== [$label] 文件数量 ==="
	local exp_count ipk_count apk_count
	exp_count="$(find "$WORK/exp-$label" -type f | wc -l | tr -d ' ')"
	ipk_count="$(find "$WORK/$label-ipk-data" -type f | wc -l | tr -d ' ')"
	# apk 额外带 /lib/apk/packages/* 元数据（conffiles/.list），不计入包内容
	apk_count="$(find "$WORK/$label-apk-data" -type f \
		! -path "$WORK/$label-apk-data/lib/apk/packages/$pkg.*" | wc -l | tr -d ' ')"
	echo "[$label] repo=$exp_count ipk=$ipk_count apk=$apk_count"
	[ "$exp_count" = "$ipk_count" ] || fail "[$label] ipk 文件数不一致"
	[ "$exp_count" = "$apk_count" ] || fail "[$label] apk 文件数不一致"

	echo "=== [$label] 内容一致性（diff -r） ==="
	diff -r "$WORK/exp-$label" "$WORK/$label-ipk-data" ||
		fail "[$label] ipk 内容与源码树不一致"
	# apk 的 /lib/apk/packages 是 apk 专有元数据目录，比较内容前先剔除
	cp -a "$WORK/$label-apk-data" "$WORK/$label-apk-cmp"
	rm -rf "$WORK/$label-apk-cmp/lib/apk"
	# 面板包解包后会留下空的 /lib（apk 元数据容器），比较前清掉
	[ -d "$WORK/$label-apk-cmp/lib" ] && rmdir "$WORK/$label-apk-cmp/lib" 2>/dev/null || true
	diff -r "$WORK/$label-ipk-data" "$WORK/$label-apk-cmp" ||
		fail "[$label] ipk 与 apk 内容不一致"
	echo "[$label] OK: ipk/apk 与源码树逐文件一致（$exp_count files）"

	echo "=== [$label] apk 元数据（属主/权限/conffiles） ==="
	[ -s "$WORK/$label-adbdump.txt" ] || fail "[$label] adbdump 结果缺失"
	# 1) 文件属主/属组必须是 root（当前用户打包会写成 <builder>:<builder>）
	if grep -qE '^ *user: ' "$WORK/$label-adbdump.txt" &&
		grep -E '^ *user: ' "$WORK/$label-adbdump.txt" | grep -qv 'user: root'; then
		fail "[$label] apk 内文件属主不是 root（疑似泄漏构建用户名）"
	fi
	if grep -qE '^ *group: ' "$WORK/$label-adbdump.txt" &&
		grep -E '^ *group: ' "$WORK/$label-adbdump.txt" | grep -qv 'group: root'; then
		fail "[$label] apk 内文件属组不是 root"
	fi
	# 2) 不允许 0777（目录放宽权限会带来安全/一致性问题）
	if grep -q 'mode: 0777' "$WORK/$label-adbdump.txt"; then
		fail "[$label] apk 内存在 0777 权限项"
	fi
	# 3) conffiles 元数据必须存在且登记了本包配置路径
	local f
	for f in conffiles conffiles_static list; do
		[ -f "$WORK/$label-apk-data/lib/apk/packages/$pkg.$f" ] ||
			fail "[$label] apk 缺少 /lib/apk/packages/$pkg.$f"
	done
	grep -qx "$conffile" "$WORK/$label-apk-data/lib/apk/packages/$pkg.conffiles" ||
		fail "[$label] apk conffiles 未登记 $conffile"
	echo "[$label] OK: apk 属主 root、无 0777、conffiles 已登记 $conffile"

	echo "=== [$label] 未打包进包的文件（应为空） ==="
	( cd "$WORK/exp-$label" && find . -type f | sed 's|^\./||' | sort ) > "$WORK/$label-list-exp"
	( cd "$WORK/$label-ipk-data" && find . -type f | sed 's|^\./||' | sort ) > "$WORK/$label-list-ipk"
	if diff -u "$WORK/$label-list-exp" "$WORK/$label-list-ipk"; then
		echo "[$label] OK: 文件清单一致"
	else
		fail "[$label] 文件清单不一致"
	fi
}

prepare_expected main
prepare_expected dash

verify_one main "$IPK" "$APK" "/etc/config/ferry" "luci-app-ferry" ""
verify_one dash "$DASH_IPK" "$DASH_APK" "/etc/config/ferry-dashboard" \
	"luci-app-ferry-dashboard" "luci-app-ferry"

echo "OK: 主包与面板包均校验通过"
