#!/usr/bin/env python3
"""Build the luci-app-ferry .ipk for opkg based OpenWrt (24.10 / Immortal 24.10).

    build_ipk.py <stage> <out.ipk> <version> [postinst]

Layout is the ipk v2 format used by opkg 2024.x:
    ./debian-binary, ./data.tar.gz, ./control.tar.gz (control, prerm, conffiles)
"""
import gzip
import io
import os
import sys
import tarfile

NAME = os.environ.get("IPK_NAME", "luci-app-ferry")
MAINTAINER = "yunyu697"
LICENSE = os.environ.get("IPK_LICENSE", "GPL-2.0-only")
DESC = os.environ.get(
    "IPK_DESC",
    "Ferry (dukou) transparent proxy gateway for OpenWrt (mihomo / sing-box)")
DEPENDS = os.environ.get("IPK_DEPENDS", "luci-base")

PRERM = os.environ.get("IPK_PRERM") or """#!/bin/sh
[ "$1" = "upgrade" ] && exit 0
[ -x /usr/lib/ferry/uninstall.sh ] && /usr/lib/ferry/uninstall.sh
exit 0
"""

CONFFILES = os.environ.get("IPK_CONFFILES", "/etc/config/ferry\n")

POSTINST = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ -x /etc/uci-defaults/50-ferry ] && /etc/uci-defaults/50-ferry
/etc/init.d/rpcd reload >/dev/null 2>&1 || killall -HUP rpcd 2>/dev/null
exit 0
"""


def pack(root, extra=None):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        entries = []
        if root:
            for base, dirs, files in os.walk(root):
                dirs.sort()
                files.sort()
                rel_base = os.path.relpath(base, root)
                for d in dirs:
                    entries.append((os.path.normpath(os.path.join(rel_base, d)),
                                    os.path.join(base, d), True))
                for f in files:
                    entries.append((os.path.normpath(os.path.join(rel_base, f)),
                                    os.path.join(base, f), False))
        entries.sort(key=lambda e: e[0])
        for rel, full, is_dir in entries:
            if rel == ".":
                continue
            info = tarfile.TarInfo("./" + rel.replace(os.sep, "/"))
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            if is_dir:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.size = 0
                tar.addfile(info)
            else:
                data = open(full, "rb").read()
                info.type = tarfile.REGTYPE
                info.mode = 0o755 if os.stat(full).st_mode & 0o111 else 0o644
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        for arcname, payload, mode in (extra or []):
            info = tarfile.TarInfo(arcname)
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mode = mode
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))
    return gzip.compress(raw.getvalue(), 9)


def control(size, version):
    lines = [
        "Package: %s" % NAME,
        "Version: %s" % version,
        "Depends: %s" % DEPENDS,
        "Architecture: all",
        "Section: luci",
        "Priority: optional",
        "Maintainer: %s" % MAINTAINER,
        "Source: %s" % NAME,
        "License: %s" % LICENSE,
        "Installed-Size: %d" % size,
        "Description: %s" % DESC,
    ]
    return ("\n".join(lines) + "\n").encode()


def ar_archive(members):
    """OpenWrt 24.10 的 opkg(2024-10-16) 只接受 tar.gz 包裹的 ipk 结构。"""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        for name, payload in members:
            info = tarfile.TarInfo("./" + name)
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mode = 0o644
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))
    return gzip.compress(raw.getvalue(), 9)


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: build_ipk.py <stage> <out.ipk> <version> [postinst]")
    stage, out, version = sys.argv[1], sys.argv[2], sys.argv[3]
    postinst = POSTINST
    if len(sys.argv) > 4 and os.path.exists(sys.argv[4]):
        postinst = open(sys.argv[4]).read()
    data = pack(stage)
    ctrl = pack(None, [("./control", control(len(data), version), 0o644),
                       ("./postinst", postinst.encode(), 0o755),
                       ("./prerm", PRERM.encode(), 0o755),
                       ("./conffiles", CONFFILES.encode(), 0o644)])
    blob = ar_archive([("debian-binary", b"2.0\n"),
                       ("data.tar.gz", data),
                       ("control.tar.gz", ctrl)])
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(blob)
    print("ipk -> %s (%d bytes)" % (out, os.path.getsize(out)))


if __name__ == "__main__":
    main()
