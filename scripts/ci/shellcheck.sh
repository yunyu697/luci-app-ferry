#!/usr/bin/env bash
# 对仓库内所有 shell 脚本跑 shellcheck；error 级直接失败（不吞掉退出码）
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

shellcheck --version

mapfile -t files < <(
	git ls-files | while IFS= read -r f; do
		[ -f "$f" ] || continue
		first="$(head -n 1 "$f" 2>/dev/null || true)"
		case "$f" in
			*.sh) echo "$f" ;;
			*)
				case "$first" in
					'#!'*sh*|'#!'*bash*) echo "$f" ;;
				esac
				;;
		esac
	done
)

echo "shell files: ${#files[@]}"
shellcheck --severity=error --format=gcc "${files[@]}"
echo "shellcheck OK (error severity)"
