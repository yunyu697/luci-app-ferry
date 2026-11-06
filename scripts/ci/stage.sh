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

# 目录权限：git/Windows 检出的目录模式不可靠（曾出现 0777），统一 0755
find "$STAGE" -type d -exec chmod 0755 {} +

# 确定性 mtime：出包结果不应随检出时间变化（apk 的 ADB 会记录 mtime）
EPOCH="${SOURCE_DATE_EPOCH:-1600000000}"
find "$STAGE" -exec touch -h -d "@$EPOCH" {} +

# WSL 的 /mnt/*（9p/drvfs）不支持 chmod，目录会固定显示 0777，打出来的 apk 权限不可信。
DMODE=$(stat -c '%a' "$STAGE" 2>/dev/null || echo '?')
if [ "$DMODE" = "777" ]; then
	echo "WARN: $STAGE 所在文件系统不支持 chmod（模式显示 0777）。" >&2
	echo "WARN: 请把 STAGE 指到 Linux 文件系统（如 /tmp/ferry-stage）再打包。" >&2
fi

FILE_COUNT=$(find "$STAGE" -type f | wc -l)
echo "stage ready: $STAGE ($FILE_COUNT files)"
echo "--- modes ---"
find "$STAGE" -type f -perm -u+x | sed "s|$STAGE/||" | sort
