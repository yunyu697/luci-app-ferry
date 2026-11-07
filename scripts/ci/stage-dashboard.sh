#!/usr/bin/env bash
# staging 独立面板包：dashboard/files/ + 已打只读补丁的 zashboard 3.22.0
# 用法：scripts/ci/stage-dashboard.sh [stage_dir]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="${1:-${STAGE:-$REPO/.ci/stage-dashboard}}"
VENDOR="$REPO/dashboard/vendor/zashboard-3.22.0"

[ -d "$VENDOR" ] || { echo "ERROR: 缺少 vendor/zashboard-3.22.0" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$REPO/dashboard/files/." "$STAGE/"
mkdir -p "$STAGE/www/luci-static/ferry-dashboard"
cp -a "$VENDOR/." "$STAGE/www/luci-static/ferry-dashboard/"

# 可执行位
find "$STAGE/etc/init.d" "$STAGE/usr/bin" "$STAGE/usr/libexec/rpcd" -type f -exec chmod 0755 {} +
find "$STAGE/usr/lib/ferry" -type f -name '*.sh' -exec chmod 0755 {} +
# 其余普通文件 0644；zashboard 的 .js 也保持 0644（静态资源，无需可执行）
find "$STAGE" -type f \
	! -path "$STAGE/etc/init.d/*" ! -path "$STAGE/usr/bin/*" \
	! -path "$STAGE/usr/libexec/rpcd/*" ! -name '*.sh' -exec chmod 0644 {} +
find "$STAGE" -type d -exec chmod 0755 {} +

EPOCH="${SOURCE_DATE_EPOCH:-1600000000}"
find "$STAGE" -exec touch -h -d "@$EPOCH" {} +

DMODE=$(stat -c '%a' "$STAGE" 2>/dev/null || echo '?')
if [ "$DMODE" = "777" ]; then
	echo "WARN: $STAGE 所在文件系统不支持 chmod（模式显示 0777）。" >&2
	echo "WARN: 请把 STAGE 指到 Linux 文件系统（如 /tmp/ferry-stage-dashboard）再打包。" >&2
fi

FILE_COUNT=$(find "$STAGE" -type f | wc -l)
SIZE=$(du -sk "$STAGE" | awk '{print $1}')
echo "dashboard stage ready: $STAGE ($FILE_COUNT files, ${SIZE}KB)"
