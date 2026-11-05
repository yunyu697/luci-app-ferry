#!/bin/bash
# 准备可写的 OpenWrt/ImmortalWrt x86_64 原始镜像：解压 + 扩容 rootfs 分区。
#
# 用法：prepare-image.sh <src.img|src.img.gz> <dst.img> <rootfs-MB>
#
# OpenWrt x86_64 combined-ext4 镜像默认根分区很小（24.10 约 100MB），
# 装不下 mihomo 内核（60MB+），所以验收前把第二个分区扩到 rootfs-MB。
# 只做本地镜像文件操作，不接触任何真实设备。
set -eu
SRC="$1"
DST="$2"
MB="${3:-800}"

if [ ! -f "$SRC" ]; then
	echo "missing source image: $SRC" >&2
	exit 1
fi

if [ "${SRC##*.}" = "gz" ]; then
	if [ ! -f "${SRC%.gz}" ] || [ "${SRC%.gz}" -ot "$SRC" ]; then
		gzip -dc "$SRC" > "${SRC%.gz}"
	fi
	SRC="${SRC%.gz}"
fi

cp -f "$SRC" "$DST"

python3 - "$DST" "$MB" <<'PY'
import struct, subprocess, sys
path, mb = sys.argv[1], int(sys.argv[2])
with open(path, "r+b") as f:
    f.seek(446)
    parts = []
    for i in range(4):
        e = f.read(16)
        if len(e) != 16:
            break
        status, ptype = e[0], e[4]
        start, count = struct.unpack("<II", e[8:16])
        parts.append((status, ptype, start, count))
roots = [p for p in parts if p[1] != 0]
if not roots:
    sys.exit("no partition found")
status, ptype, start, count = roots[-1]           # 最后一个分区即 rootfs
want = (mb * 1024 * 1024) // 512
print("rootfs p%d start=%d sectors current=%.0fMB target=%dMB"
      % (len(roots), start, count * 512 / 1048576, mb))
if count >= want:
    print("already large enough")
    sys.exit(0)

tmp = "/tmp/ferry-rootfs-%d.img" % start
with open(path, "rb") as f:
    f.seek(start * 512)
    remain = count * 512
    with open(tmp, "wb") as o:
        while remain > 0:
            chunk = f.read(min(remain, 1 << 20))
            if not chunk:
                break
            o.write(chunk)
            remain -= len(chunk)
subprocess.run(["e2fsck", "-f", "-y", tmp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["resize2fs", tmp, "%dM" % mb], check=True, stdout=subprocess.DEVNULL)
with open(tmp, "rb") as f, open(path, "r+b") as o:
    o.seek(start * 512)
    while True:
        chunk = f.read(1 << 20)
        if not chunk:
            break
        o.write(chunk)
with open(path, "r+b") as f:
    f.seek(446)
    for i in range(4):
        e = bytearray(f.read(16))
        if len(e) != 16:
            break
        if e[4] != 0 and i == len(roots) - 1:
            e[12:16] = struct.pack("<I", want)
            f.seek(446 + i * 16)
            f.write(e)
            break
subprocess.run(["rm", "-f", tmp])
print("expanded to %dMB" % mb)
PY

echo "image ready: $DST"
