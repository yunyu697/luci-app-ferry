#!/usr/bin/env sh
# Ferry 双格式构建脚本（在 PC 上运行，需要对应的 OpenWRT/ImmortalWrt SDK）
#
# 用途：同一份源码分别喂给 ipk/opkg 模式与 apk 模式的 SDK，
#       产物按格式收集到 dist/ipk 或 dist/apk。
#
# 示例：
#   ./build.sh --sdk ~/sdk/24.10 --mode ipk
#   ./build.sh --sdk ~/sdk/main   --mode apk
#   ./build.sh --sdk ~/sdk/main   --mode auto   # 由 SDK 的 .config 判断
#
# 说明：
#   - 只做 buildroot 打包，不下载/内嵌 mihomo、sing-box 二进制；
#   - 包名、版本号的 apk 约束由 Makefile 保证（全小写、版本不含 '-'、
#     PKG_RELEASE 为纯数字），脚本只负责识别与收集；
#   - SDK 需要事先 `make defconfig` 并把 luci feed 装好（见 README）。

set -eu

SDK=
MODE=auto
TARGET=luci-app-ferry
OUTROOT=./dist
SRC=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEEP=false

usage() {
	cat <<'EOF'
用法: build.sh --sdk <SDK目录> [选项]

必选:
  --sdk <目录>     OpenWRT / ImmortalWrt SDK 根目录（含 rules.mk、include/）
可选:
  --mode <auto|ipk|apk>  默认 auto：从 SDK 的 .config 判断
  --target <包名>        默认 luci-app-ferry
  --out <目录>           产物根目录，默认 ./dist（内部再分 ipk/apk）
  --keep                 编译结束后保留 SDK 内的包源码副本
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--sdk) SDK="$2"; shift 2 ;;
		--mode) MODE="$2"; shift 2 ;;
		--target) TARGET="$2"; shift 2 ;;
		--out) OUTROOT="$2"; shift 2 ;;
		--keep) KEEP=true; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "未知参数: $1" >&2; usage; exit 2 ;;
	esac
done

[ -n "$SDK" ] || { echo "缺少 --sdk" >&2; usage; exit 2; }
[ -d "$SDK" ] || { echo "SDK 目录不存在: $SDK" >&2; exit 2; }
[ -f "$SDK/rules.mk" ] || { echo "不像 SDK：$SDK 下没有 rules.mk" >&2; exit 2; }
[ -f "$SRC/Makefile" ] || { echo "源码目录不正确：$SRC 下没有 Makefile" >&2; exit 2; }

# ---- 识别 SDK 的包格式 -----------------------------------------------------
# 主判据：.config 里的 CONFIG_USE_APK。老 SDK 没有该符号，等于 ipk。
detect_mode() {
	local cfg="$SDK/.config"
	if [ ! -f "$cfg" ]; then
		echo unknown
		return 0
	fi
	if grep -qE '^CONFIG_USE_APK=y' "$cfg"; then
		echo apk
		return 0
	fi
	# 兜底：某些分支用 CONFIG_APK / CONFIG_PACKAGE_APK 之类命名
	if grep -qE '^CONFIG_(USE_)?APK(=y|_ALWAYS=y)' "$cfg"; then
		echo apk
		return 0
	fi
	echo ipk
}

DETECTED=$(detect_mode)
if [ "$MODE" = auto ]; then
	MODE=$DETECTED
fi
if [ "$MODE" != apk ] && [ "$MODE" != ipk ]; then
	echo "无法从 $SDK/.config 判断包格式（可能是未 defconfig 的 SDK）" >&2
	echo "请显式指定 --mode ipk 或 --mode apk" >&2
	exit 2
fi
if [ "$DETECTED" != unknown ] && [ "$DETECTED" != "$MODE" ]; then
	echo "警告：SDK 看起来是 ${DETECTED} 模式，但你指定了 ${MODE}；产物将按 ${MODE} 收集。" >&2
fi

# ---- 把源码放进 SDK -----------------------------------------------------------
# buildroot 只认 $SDK/package/<name>，用复制而不是软链，避免 SDK 内相对路径失效。
DST="$SDK/package/$TARGET"
if [ -e "$DST" ]; then
	echo "SDK 内已有 ${DST}，先移除旧副本"
	rm -rf "$DST"
fi
mkdir -p "$DST"
cp -R "$SRC/Makefile" "$SRC/files" "$DST"/
[ -d "$SRC/scripts" ] && cp -R "$SRC/scripts" "$DST"/
[ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$DST"/

echo "源码已放入: $DST"
echo "SDK 模式: ${MODE}（检测值: ${DETECTED}）"

# ---- 编译 --------------------------------------------------------------------
# 只编译本包；V=s 保留完整错误，便于贴日志。
(
	cd "$SDK"
	make "package/$TARGET/compile" V=s
)

# ---- 收集产物 ----------------------------------------------------------------
OUT="$OUTROOT/$MODE"
mkdir -p "$OUT"
FOUND=0
# bin/packages/<arch>/<feed>/luci-app-ferry_*.ipk|apk
for f in "$SDK"/bin/packages/*/*/"$TARGET"_*."$MODE"; do
	[ -f "$f" ] || continue
	cp "$f" "$OUT/"
	FOUND=$((FOUND + 1))
done

if [ "$FOUND" -eq 0 ]; then
	echo "未在 $SDK/bin/packages 下找到 .$MODE 产物" >&2
	echo "可能原因：SDK 未启用 luci feed、包被依赖裁掉，或实际模式与 --mode 不一致。" >&2
	echo "可执行：grep -R \"$TARGET\" $SDK/bin/packages 排查。" >&2
	[ "$KEEP" = true ] || rm -rf "$DST"
	exit 1
fi

echo
echo "产物（${FOUND} 个）:"
if command -v sha256sum >/dev/null 2>&1; then
	for f in "$OUT"/*."$MODE"; do sha256sum "$f"; done
else
	for f in "$OUT"/*."$MODE"; do shasum -a 256 "$f"; done
fi

FIRST=$(ls "$OUT"/*."$MODE" | head -n 1)
echo
if [ "$MODE" = apk ]; then
	echo "安装（未加信任时）: apk add --allow-untrusted $FIRST"
	echo "安装（已注入公钥时）: apk add $FIRST"
else
	echo "安装: opkg install $FIRST"
fi

[ "$KEEP" = true ] || rm -rf "$DST"
