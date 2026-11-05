#!/usr/bin/env python3
"""在宿主侧通过 QEMU 串口执行一条命令，并等待命令结束标记。

用法：serial_exec.py <tcp-port> <logfile> <command> [timeout]

- 等待 guest 出现 root shell 提示符（OpenWrt 串口默认自动登录 root）
- 命令末尾追加 `; echo __CMD_DONE__`，看到标记即返回
- 输出写入 logfile（追加），stdout 只打印状态行，便于驱动脚本判断
"""
import re
import socket
import sys
import time

port = int(sys.argv[1])
out_path = sys.argv[2]
cmd = sys.argv[3]
timeout = int(sys.argv[4]) if len(sys.argv) > 4 else 90
MARK = "__CMD_DONE__"

s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(0.2)
log = open(out_path, "ab", buffering=0)
buf = b""
sent = False
done = False
last_enter = time.time()
start = time.time()

while time.time() - start < timeout:
    try:
        d = s.recv(4096)
        if d:
            buf += d
            log.write(d)
    except socket.timeout:
        pass
    except ConnectionResetError:
        break
    tail = buf[-600:]
    if not sent and re.search(rb"root@\S+:[^#\n]*#", tail):
        s.sendall((cmd + "; M=__C''MD_DONE__; echo $M\n").encode())
        sent = True
        last_enter = time.time()
    elif not sent and time.time() - last_enter > 3:
        s.sendall(b"\r")
        last_enter = time.time()
    if sent and MARK.encode() in tail:
        done = True
        time.sleep(0.3)
        break

s.close()
log.close()
print("SENT=%s DONE=%s" % ("yes" if sent else "no", "yes" if done else "no"))
sys.exit(0 if (sent and done) else 2)
