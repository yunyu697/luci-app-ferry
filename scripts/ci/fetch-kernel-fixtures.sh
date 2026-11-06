#!/usr/bin/env bash
# 下载 tests/test-kernel.sh 需要的真实内核归档（仅测试夹具，不是产品下载路径）。
# GitHub API 对这些 release 资产不返回 digest，这里做归档完整性校验并打印实际 SHA-256，
# 功能正确性由 test-kernel.sh 的安装/自检断言兜底。
# 用法：scripts/ci/fetch-kernel-fixtures.sh [dest_dir]
set -euo pipefail

DEST="${1:-${KSRC:-$PWD/.ci/kernels}}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# name|url
FIXTURES="
sing-box-1.8.14-linux-amd64.tar.gz|https://github.com/SagerNet/sing-box/releases/download/v1.8.14/sing-box-1.8.14-linux-amd64.tar.gz
sing-box-1.10.7-linux-amd64.tar.gz|https://github.com/SagerNet/sing-box/releases/download/v1.10.7/sing-box-1.10.7-linux-amd64.tar.gz
sing-box-1.11.0-linux-amd64.tar.gz|https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz
sing-box-1.12.0-linux-amd64.tar.gz|https://github.com/SagerNet/sing-box/releases/download/v1.12.0/sing-box-1.12.0-linux-amd64.tar.gz
sing-box-1.14.4-linux-amd64-musl.tar.gz|https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64-musl.tar.gz
mihomo-linux-amd64-v1.18.8.gz|https://github.com/MetaCubeX/mihomo/releases/download/v1.18.8/mihomo-linux-amd64-v1.18.8.gz
"

echo "$FIXTURES" | while IFS='|' read -r name url; do
	[ -n "$name" ] || continue
	out="$DEST/$name"
	if [ -f "$out" ]; then
		echo "cached: $name"
	else
		echo "download: $name"
		curl -fL --retry 5 --retry-all-errors --retry-delay 3 -o "$out.part" "$url"
		mv "$out.part" "$out"
	fi
	case "$name" in
		*.tar.gz) tar -tzf "$out" >/dev/null ;;
		*.gz) gzip -t "$out" ;;
	esac
	echo "sha256 $name: $(sha256sum "$out" | awk '{print $1}')"
done

echo "--- fixtures ---"
ls -l "$DEST"
