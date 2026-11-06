#!/usr/bin/env bash
# 把 files/ 树 staging 成出包目录（与 Makefile 安装清单一致：files/ 即安装内容）
# 用法：scripts/ci/stage.sh [stage_dir]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${1:-${STAGE:-$REPO/.ci/stage}}"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$REPO/files/." "$STAGE/"

# 保留运行时需要的空目录（git 不跟踪空目录）
mkdir -p "$STAGE/etc/ferry/rules-cache/mihomo" "$STAGE/etc/ferry/rules-cache/sing-box"

# 可执行位：Windows 检出或历史打包可能丢位，这里按路径显式设置
find "$STAGE/etc/init.d" "$STAGE/etc/uci-defaults" "$STAGE/usr/bin" \
	"$STAGE/usr/libexec/rpcd" -type f -exec chmod 0755 {} +
find "$STAGE/usr/lib/ferry" -type f -name '*.sh' -exec chmod 0755 {} +
find "$STAGE" -type f \
	! -path "$STAGE/etc/init.d/*" ! -path "$STAGE/etc/uci-defaults/*" \
	! -path "$STAGE/usr/bin/*" ! -path "$STAGE/usr/libexec/rpcd/*" \
	! -name '*.sh' -exec chmod 0644 {} +

FILE_COUNT=$(find "$STAGE" -type f | wc -l)
echo "stage ready: $STAGE ($FILE_COUNT files)"
echo "--- modes ---"
find "$STAGE" -type f -perm -u+x | sed "s|$STAGE/||" | sort
