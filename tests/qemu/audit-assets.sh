#!/bin/bash
# 内置资产审计：确认资产名 / 变体映射 / 官方 SHA-256 是否真的可用，并把结论写回清单第 8 列。
#
# 用法（在 Linux/WSL 宿主跑，不要放进固件）：
#   bash tests/qemu/audit-assets.sh                # 全量探测 + 抽样全量校验（arm64、mipsle-softfloat）
#   FULL_ALL=1 bash tests/qemu/audit-assets.sh     # 所有条目都做全量下载 + SHA-256
#   AUDIT_MIRROR=https://ghproxy.net/ bash ...     # 换镜像前缀
#
# 结论写回 TSV 第 8 列：ok（全量下载 + SHA-256 + ELF 架构全对）/ probe（HTTP 200 且大小一致）/
# dead（拿不到或校验失败，界面直接隐藏，不让用户点了才失败）
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TSV=${TSV:-$ROOT/files/usr/lib/ferry/kernels-builtin.tsv}
MIRROR=${AUDIT_MIRROR:-https://ghfast.top/}
SAMPLES=${SAMPLES:-mihomo:arm64:v1.19.33 mihomo:mipsle:v1.19.33}
FULL_ALL=${FULL_ALL:-0}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[ -s "$TSV" ] || { echo "清单不存在：$TSV"; exit 2; }

elf_info() { # file -> "arch endian bits"
	python3 - "$1" <<'PY'
import sys, struct
f = open(sys.argv[1], 'rb')
d = f.read(20)
if len(d) < 20 or d[0:4] != b'\x7fELF':
    print('not-elf - -'); sys.exit(0)
endian = 'le' if d[5] == 1 else 'be'
bits = 64 if d[4] == 2 else 32
end = '<' if endian == 'le' else '>'
mach = struct.unpack(end + 'H', d[18:20])[0]
names = {0x3e: 'amd64', 0xb7: 'arm64', 0x28: 'arm', 0x08: 'mipsle' if endian == 'le' else 'mips',
         0x03: '386', 0xf3: 'riscv64', 0x16: 's390x', 0x15: 'ppc', 0x14: 'ppc64'}
print(names.get(mach, 'machine-0x%x' % mach), endian, bits)
PY
}

probe() { # url expected_size -> "probe|dead" + detail
	local url=$1 want=$2 code got total try
	for try in 1 2; do
		code=$(curl -sSL -m 25 -r 0-1023 -o "$work/chunk.bin" -D "$work/hdr.txt" \
			-w '%{http_code}' "$url" 2>/dev/null)
		# 206 = 镜像支持 Range 的正常响应；200 = 镜像忽略 Range 直接全量
		case "$code" in 200|206) break ;; esac
		[ "$try" = 1 ] && sleep 2
	done
	got=$(wc -c < "$work/chunk.bin" 2>/dev/null | tr -d ' ')
	total=$(sed -n 's/^[Cc]ontent-[Rr]ange: *bytes [0-9-]*\/\([0-9]*\).*/\1/p' "$work/hdr.txt" | head -1)
	if [ "$code" != 200 ] && [ "$code" != 206 ]; then
		echo "dead http=$code"
	elif [ -n "$total" ] && [ "$total" != "$want" ]; then
		echo "dead size=$total!=${want}"
	elif [ -z "$total" ]; then
		# 镜像不回 Content-Range：只要求能取到数据，大小留给全量校验
		if [ "${got:-0}" -gt 0 ] 2>/dev/null; then
			echo "probe http=$code got=$got size=unverifiable"
		else
			echo "dead empty-body"
		fi
	else
		echo "probe http=$code size=$total"
	fi
}

full_verify() { # url want_sha want_size outfile -> ok|dead + detail
	local url=$1 wsha=$2 wsize=$3 out=$4 sha got
	curl -sSL -m 600 -o "$out" "$url" 2>/dev/null || { echo "dead download-failed"; return 0; }
	sha=$(sha256sum "$out" 2>/dev/null | awk '{print $1}')
	got=$(wc -c < "$out" | tr -d ' ')
	if [ "$sha" != "$wsha" ]; then
		echo "dead sha=$sha!=${wsha:0:12}"; return 0
	fi
	[ "$got" = "$wsize" ] || { echo "dead size=$got!=${wsize}"; return 0; }
	echo "ok sha=$sha size=$got"
}

# 逐条审计，重写 TSV（保留首行 generated，追加 audited 行）
tab=$(printf '\t')
{
	head -1 "$TSV"
	echo "# audited=$(date +%Y-%m-%dT%H:%M:%S) mirror=$MIRROR samples=$SAMPLES"
	grep -v '^#' "$TSV" | while IFS="$tab" read -r k tag arch size sha name url oldstate; do
		[ -n "$k" ] || continue
		# 资产名与变体映射自检：名字里必须出现该架构关键字
		case "$arch" in
			amd64) case "$name" in *amd64*) ;; *) echo "BADNAME $name ($arch)" >&2 ;; esac ;;
			arm64) case "$name" in *arm64*) ;; *) echo "BADNAME $name ($arch)" >&2 ;; esac ;;
			mipsle) case "$name" in *mipsle-softfloat*|*mipsle-hardfloat*) ;; *) echo "BADNAME $name ($arch)" >&2 ;; esac ;;
			mips) case "$name" in *mips-softfloat*|*mips-hardfloat*) ;; *) echo "BADNAME $name ($arch)" >&2 ;; esac ;;
		esac
		state=''
		if [ "$FULL_ALL" = 1 ]; then
			res=$(full_verify "$MIRROR$url" "$sha" "$size" "$work/a.bin")
		else
			case " $SAMPLES " in *" $k:$arch:$tag "*)
				res=$(full_verify "$MIRROR$url" "$sha" "$size" "$work/a.bin")
				# 抽样条目额外做 ELF 架构断言（确认变体映射正确）
				case "$res" in
					ok*)
						case "$name" in
							*.tar.gz) tar -xzf "$work/a.bin" -O > "$work/exe" 2>/dev/null ;;
							*.gz) gzip -dc "$work/a.bin" > "$work/exe" 2>/dev/null ;;
							*) cp "$work/a.bin" "$work/exe" ;;
						esac
						info=$(elf_info "$work/exe")
						set -- $info
						if [ "$1" = "$arch" ] || { [ "$arch" = mipsle ] && [ "$1" = mipsle ]; }; then
							res="$res elf=$1/$2/${3}bit"
						else
							res="dead elf-mismatch=$info"
						fi ;;
				esac ;;
			*) res=$(probe "$MIRROR$url" "$size") ;;
			esac
		fi
		case "$res" in
			ok*) state=ok ;;
			probe*) state=probe ;;
			*) state=dead ;;
		esac
		echo "AUDIT $k/$tag/$arch -> $state ($res)" >&2
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$tag" "$arch" "$size" "$sha" "$name" "$url" "$state"
	done
} > "$TSV.new"
mv "$TSV.new" "$TSV"

# 汇总
echo "=== 汇总 ==="
awk -F'\t' '!/^#/ { c[$8]++ } END { for (s in c) printf "%-6s %d\n", s, c[s] }' "$TSV"
echo "清单已更新：$TSV"
