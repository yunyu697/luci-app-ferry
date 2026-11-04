#!/usr/bin/env sh
# Ferry 内核二进制获取脚本（在 PC 上运行，不在路由器上运行）
#
# 主线平台：x86_64（软路由 / 虚拟机 / 多数云主机）。以下是 x86_64 的等价关系：
#   mihomo   -> mihomo-linux-amd64-v<ver>.gz          （解压即 ELF，纯静态）
#   sing-box -> sing-box-<ver>-linux-amd64-musl.tar.gz（musl 静态，x86_64 通用）
# 注意：x86_64 的 Go 静态二进制不依赖路由器 libc（musl/glibc 均可），
#       但依赖内核特性（TUN 需要 kmod-tun，TPROXY 需要 kmod-nft-tproxy）。
#
# 用法：
#   ./fetch-kernel.sh --kernel mihomo  --version 1.19.33
#   ./fetch-kernel.sh --kernel singbox --version 1.14.4 --out ./kernels
#   ./fetch-kernel.sh --kernel mihomo  --arch aarch64 --version 1.19.33   # 次要架构
#
# 可选：--sha256 <64位十六进制> 手工指定校验值（GitHub release 未提供校验文件）
#       --out <目录> 输出目录，默认 ./kernels

set -eu

KERNEL=mihomo
ARCH=x86_64          # 默认主线架构；其它架构需要显式 --arch
VERSION=
OUT=./kernels
EXPECTED_SHA=

usage() {
	cat <<'EOF'
用法: fetch-kernel.sh --kernel <mihomo|singbox> --version <版本> [--arch <架构>] [选项]

必选:
  --kernel    mihomo 或 singbox
  --version   版本号，不带 v 前缀（例如 1.19.33 / 1.14.4）

可选:
  --arch      默认 x86_64（主线）；其它为次要路径：
              aarch64 | armv7 | armv6 | mips | mipsle | mips64 | mips64le
  --out       输出目录，默认 ./kernels
  --sha256    期望的 SHA256，提供后会做严格校验

x86_64 资源对应：
  mihomo   -> mihomo-linux-amd64-v<ver>.gz
  sing-box -> sing-box-<ver>-linux-amd64-musl.tar.gz
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--kernel) KERNEL="$2"; shift 2 ;;
		--arch) ARCH="$2"; shift 2 ;;
		--version) VERSION="$2"; shift 2 ;;
		--out) OUT="$2"; shift 2 ;;
		--sha256) EXPECTED_SHA="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "未知参数: $1" >&2; usage; exit 2 ;;
	esac
done

[ -n "$VERSION" ] || { echo "缺少 --version（脚本不自动取最新版，请固定版本）" >&2; usage; exit 2; }

case "$KERNEL" in
mihomo)
	case "$ARCH" in
		x86_64) ASSET=amd64 ;;
		aarch64) ASSET=arm64 ;;
		armv7) ASSET=armv7 ;;
		armv6) ASSET=armv6 ;;
		mips) ASSET=mips-softfloat ;;
		mipsle) ASSET=mipsle-softfloat ;;
		mips64) ASSET=mips64 ;;
		mips64le) ASSET=mips64le ;;
		*) echo "mihomo 不支持的架构: $ARCH" >&2; exit 2 ;;
	esac
	URL="https://github.com/MetaCubeX/mihomo/releases/download/v${VERSION}/mihomo-linux-${ASSET}-v${VERSION}.gz"
	NAME=mihomo
	;;
singbox)
	case "$ARCH" in
		x86_64) ASSET=amd64-musl ;;
		aarch64) ASSET=arm64-musl ;;
		armv7) ASSET=armv7-musl ;;
		armv6) ASSET=armv6 ;;
		mips) ASSET=mips-softfloat ;;
		mipsle) ASSET=mipsle-softfloat ;;
		mips64) ASSET=mips64-softfloat ;;
		mips64le) ASSET=mips64le-softfloat ;;
		*) echo "sing-box 不支持的架构: $ARCH" >&2; exit 2 ;;
	esac
	URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ASSET}.tar.gz"
	NAME=sing-box
	;;
*)
	echo "未知内核: $KERNEL" >&2
	exit 2
	;;
esac

mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "目标架构: $ARCH  (资源: ${ASSET})"
echo "下载: $URL"
if command -v curl >/dev/null 2>&1; then
	curl -fL --max-time 300 -o "$TMP/pkg" "$URL"
elif command -v wget >/dev/null 2>&1; then
	wget -O "$TMP/pkg" "$URL"
else
	echo "需要 curl 或 wget" >&2
	exit 1
fi

# 解包
case "$KERNEL" in
mihomo)
	gzip -dc "$TMP/pkg" > "$TMP/$NAME"
	;;
singbox)
	mkdir -p "$TMP/x"
	tar -xzf "$TMP/pkg" -C "$TMP/x"
	BIN=$(find "$TMP/x" -type f -name "$NAME" | head -n 1)
	[ -n "$BIN" ] || { echo "压缩包中未找到 $NAME" >&2; exit 1; }
	cp "$BIN" "$TMP/$NAME"
	;;
esac

chmod +x "$TMP/$NAME"

# 校验
if command -v sha256sum >/dev/null 2>&1; then
	ACTUAL=$(sha256sum "$TMP/$NAME" | awk '{print $1}')
else
	ACTUAL=$(shasum -a 256 "$TMP/$NAME" | awk '{print $1}')
fi
echo "SHA256: $ACTUAL"

if [ -n "$EXPECTED_SHA" ]; then
	if [ "$(echo "$ACTUAL" | tr 'A-Z' 'a-z')" != "$(echo "$EXPECTED_SHA" | tr 'A-Z' 'a-z')" ]; then
		echo "SHA256 校验失败：期望 $EXPECTED_SHA" >&2
		exit 1
	fi
	echo "SHA256 校验通过"
fi

mv "$TMP/$NAME" "$OUT/$NAME"
echo "已输出: $OUT/$NAME  (架构: $ARCH)"
echo
echo "上传到路由器："
echo "  scp $OUT/$NAME root@192.168.1.1:/tmp/$NAME"
echo "  ssh root@192.168.1.1 'mv /tmp/$NAME /usr/bin/$NAME && chmod 755 /usr/bin/$NAME'"
echo
echo "注意："
echo "  - x86_64 二进制是 Go 静态链接，不挑 musl/glibc；但要与固件架构一致（amd64）。"
echo "  - 路由器需要与二进制匹配的内核特性（TUN 需要 kmod-tun，TPROXY 需要 kmod-nft-tproxy）。"
echo "  - 非 x86_64 架构属次要路径，需自行确认固件架构与内核版本。"
