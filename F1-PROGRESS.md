# F1 实施进度（r4 地基）

> 规则：本文件每完成一小节就更新，记录已完成 / 进行中文件 / 下一步 / 已知问题。
> F1 只做地基，不提前做 F2/F3。

## F1 范围

1. 应用配置回滚保护（pending + 倒计时 + 自动还原 + 管理口永久 bypass + 三条崩溃路径）
2. 临时关闭代理开关（DNS 完整回到 dnsmasq 原生上游）
3. 诊断包 `ferry-diag`（单 tar.gz + 脱敏断言）
4. 真机流量验收脚本（自建 QEMU，headless）

## 当前状态

- [x] 阅读现有 apply 链路：LuCI 保存 -> uci commit -> procd reload trigger -> `/etc/init.d/ferry reload`；profile/部署页用 `store.js` 直接调 `reload`；内核页用 `start`（不经过 reload）。
- [x] 确定注入点：`reload_service()` 统一进入事务；`start_service()` 负责 boot/服务重启时检测未确认事务。
- [x] 事务核心 `transaction.sh`（快照 / pending / arm / confirm / 单飞锁回滚 / 历史 / 证据 / 临时关闭）
- [x] 看门狗 `watchdog.sh` + `/etc/init.d/ferry-watchdog`（procd 独立 instance、respawn）
- [x] 管理口 bypass（nft 独立 mgmt4/mgmt6 set + iptables RETURN，规则顺序在 bypass/TPROXY 之前）
- [x] 临时关闭 / 恢复（tmp-off 快照 + marker + stop/start + 证据）
- [x] `ferry-diag` + 脱敏（URL/JSON/UCI/YAML/PEM；离线断言全通过）
- [x] LuCI 安全页（倒计时 / 确认 / 回滚 / 临时关闭 / 诊断包下载）
- [x] rpcd 后端 `luci-ferry-safety` + ACL
- [x] 单元与离线测试：
  - `tests/test-transaction.sh` PASS=49 FAIL=0（快照、arm/confirm、超时还原、apply-crash、无控制面看门狗、启动检测、并发单飞、临时关闭/恢复、status JSON）
  - `tests/test-mgmt-bypass.sh` PASS=21 FAIL=0（LAN v4/v6 识别、ip 缺失 UCI 回退、nft set 与链顺序、iptables RETURN）
  - `tests/test-diag.sh` PASS=49 FAIL=0（包内容清单、凭据 grep 断言、host 保留、PEM 标记、JSON/base64）
- [x] QEMU smoke（OpenWrt 24.10.4 x86_64 + ipk，headless `-display none`，串口落盘）：**PASS=78 FAIL=0**
  - 安装 17/0（含 kmod-nft-tproxy 加载）；基线 7/0（TPROXY 7890、dnsmasq 127.0.0.1#1053、rule 1、内核 up）
  - 客户端 fake-ip：DNS `198.18.0.4` + HTTP 200（2381 字节，mihomo DIRECT）；不接管对照：真实 IP + HTTP 200
  - 临时关闭 5/0（nft 表 0 / 内核 down / DNS 223.5.5.5）→ 恢复 5/0（7890 / 1053 / 内核 up / rule 1）
  - 诊断包 24/0：20 个文件，原始凭据 grep 零命中、订阅 host 保留、PEM 私钥打码
- [x] QEMU full（超时回滚 + 三条崩溃路径 + 临时关闭/恢复 + 诊断包）— **PASS=112 FAIL=0**（headless，21:30–21:39）
  - ① 超时回滚 6/0：apply 7892 → 60s 不确认 → 自动还原 nft 7890 / dnsmasq 1053 / ip rule 1 / 内核 up / UCI 7890 / history `reason=timeout`
  - ②-B 杀看门狗 7/0：pending 中停看门狗 + `kill -9` → `ferry restart` → `reason=startup-detect`，procd 1s 内重新拉起看门狗
  - ②-C 硬断电 6/0：`kill -9` 两台 QEMU → 重启 → 启动检测清除 pending、还原基线、`startup-detect` 计 2 次
  - ③ 临时关闭 5/0（内核停、ferry 表撤、DNS 223.5.5.5、noresolv=1）→ 不接管对照真实 IP + HTTP 200 → 恢复 5/0（7890/1053/up/rule1）
  - ④ 诊断包 24/0：20 个文件、`RAW_CRED_LEAK=NO`、订阅 host 保留、PEM 私钥打码
  - 证据：`D:\ferry-qemu-work\report\summary.md`、`run-full-6.out`、`serial-router.log`、`serial-client.log`
- [x] 全量过程中暴露并修复的两个真实缺陷（随 r4 发布）：
  - `dnsmasq-backup` 是一次性备份（还原即删）；崩溃点落在“已消费未补采”时，apply 会把自身值当原始值 → 0 字节备份 → 临时关闭时 DNS 半关。
    修：新增只读 `/etc/ferry/dnsmasq-native`（还原只读不删）；0 字节备份视为缺失（`-f`→`-s`）；
    采集到空上游时不覆盖非空记录；卸载时清理该目录。
  - 硬断电会丢页缓存（备份/记录变 0 字节）→ 采集后、改 dnsmasq 之前 `sync` 落盘。
- [ ] ImmortalWrt 25.12 + apk 冒烟（未跑，apk 分支 kmod 处理待验证）
- [ ] r4 构建收尾、Commit、Tag、Release（未做）
- [x] 真机发现并修复：
  - `start_service` 在事务内部 stop/start 时会把自己的 pending 当成崩溃残留 → 用 `PM_TXN_SKIP` 跳过检测
  - uci commit 先于 reload，事务快照已是新配置 → 引入 `baseline.uci`（最近一次确认保留的基线）作为回滚源
  - 回滚只在“应用前内核在运行”时拉起服务，避免把原本停着的服务擅自启动
  - dnsmasq reload 与旧实例抢 DHCP socket 导致崩溃循环 → 恢复/接管改为 stop-等待-启动的硬重启

### r4 一致性复核（通过）

- ipk 31 个文件 / apk 31 个文件；`diff -r` 内容 **NO_DIFF**；与当前源码逐文件 `cmp` **ALL_MATCH**。
- ipk：83605 字节，sha256 `4507eeeae6c5ada157b638d5ae268910b0c8b273da245fe304eef7dcd0b65da6`
- apk：83485 字节，sha256 `83a34f6bf6626e62bb240378a0b2b45f9a4ae8f0beec06b1911b684a069fc139`

### r4 发布状态（已发出）

- commit：`47758ab F1：配置回滚保护、临时关闭、诊断包与真机验收（v1.0.0-r4）`
- 远端 main 已更新到 `47758ab`（`git push` 被服务端 `fatal error in commit_refs_rules` 拒绝，
  改用 GitHub API PATCH ref 完成；探测分支已删除）
- tag：`v1.0.0-r4`（注释标签，远端 object `b3e9a89` → commit `47758ab`）
- Release：**已发布（Latest）** https://github.com/yunyu697/luci-app-ferry/releases/tag/v1.0.0-r4
  附件：ipk / apk / SHA256SUMS，远端 digest 与本地一致。
- 过程异常：`gh release create` 首次返回 HTTP 502、重试 HTTP 500，但已生成草稿 Release；
  `gh release upload` 成功；`gh release edit --draft=false` 返回 HTTP 502，但最终状态确认为
  `isDraft=false`（已发布）。

## 下一步（按顺序）

1. **ImmortalWrt 25.12.2 + apk 冒烟（收尾）**：仅剩 tproxy kmod 一个根因。用官方 `kmods/<kver>/`
   离线取 `kmod-nft-tproxy.apk`，push 到 guest，`apk add --allow-untrusted` 后重跑
   `--firmware imm --suite smoke`（当前 `PASS=70 FAIL=8`，其余断言全绿）。
2. **r4 包与源码一致性复核**：若第 1 步之后有任何代码改动，重建 ipk/apk 并重记 size/SHA-256；
   否则沿用已构建的 r4 包（ipk 83605 / apk 83485）。
3. **r4 发布**：commit → tag `v1.0.0-r4` → GitHub Release（附件 ipk/apk/SHA256SUMS，比对远端 digest）。
   注意：本机与 WSL 均没有 `gh`，需用 GitHub API（token）或手工网页上传。
4. **F1 最终中文报告**：判定 → 实现要点（看门狗）→ 真机证据 → 包/哈希/Release → 未验证项与 F2/F3 计划。

## 本轮对账结论（只读核对，2026-11-05）

| 交付 | 状态 | 证据 / 缺口 |
|---|---|---|
| ① 回滚保护 + 看门狗 | **已完成（真机全绿）** | full `PASS=112 FAIL=0`：超时回滚 6/0、杀看门狗 7/0、硬断电 6/0；单测 49/0 |
| ② 临时关闭 / 恢复 | **已完成（真机全绿）** | tmp-off 5/0（DNS 223.5.5.5、noresolv=1）+ 不接管对照 + tmp-on 5/0 |
| ③ 诊断包 `ferry-diag` | **已完成（真机全绿）** | diag 24/0：20 文件、`RAW_CRED_LEAK=NO`、host 保留、PEM 打码；离线单测 49/0 |
| ④ 真机验收脚本 | **已跑通（OpenWrt 分支）** | `run-acceptance.sh` 跑通 smoke 78/0 与 full 112/0；**apk/ImmortalWrt 分支未验证** |

### 本轮进展（ImmortalWrt apk 冒烟）

- 发现并修复 imm 镜像地址失效：`releases/25.12/` 不存在（404），实际发布目录为 `25.12.0/25.12.1/25.12.2`，
  已改为 `25.12.2`（镜像 URL HEAD 返回 200）。
- 发现并修复镜像缓存串用：`prepare-image.sh` 的产物名不含固件前缀，`--firmware imm` 会复用 owrt 的
  `base-router-big.img`（实际用 OpenWrt 镜像跑 apk）。已改为 `$FW-base-$name[-big].img`。
- 发现并修复 `prepare-image.sh` 分区表更新失效（**imm 镜像无法启动的根因**）：
  更新 MBR 时判断用了 `e[1]`（起始扇区高位）而非 `e[4]`（分区类型），imm 的 rootfs 起始 66560 恰好使
  `e[1]==0`，分区大小未改写 → 根分区仍是 300MB、ext4 已 resize 到 800MB →
  `EXT4-fs (sda2): bad geometry: block count 204800 exceeds size of device` → `Kernel panic - not syncing: VFS: Unable to mount root fs`。
  改为 `e[4]` 后离线验证：`p1 count` 由 614400 正确变为 819200（400MB 目标）。
- `01-install.sh` 的 apk 分支此前完全不处理 tproxy kmod：补上 `apk add kmod-nft-tproxy` +
  `modprobe` 重试，并加 `lsmod` 断言（与 owrt 分支一致）。
- **状态：未完成。** 修复后尚未重跑 `--firmware imm --suite smoke`；
  首次尝试（`run-imm-2.out`）卡在串口等 root shell，证据见 `logs/serial-router.log` 的 panic 段。
- 修复 MBR 后 imm 首次正常启动（`run-imm-6.out`），又暴露两个 imm 环境适配问题：
  - ImmortalWrt 25.12.2 的 `/etc/config` 里没有 `network` 段，`uci set network.wan.device` 报
    `uci: Invalid argument` → WAN 不存在、eth0 拿不到 slirp 地址。修：bootstrap 前先 `uci set network.wan=interface`。
  - ImmortalWrt 默认 `dropbear.main.Interface='lan'`，lan 被改到 eth1 后 SSH 只绑 203.0.113.1，
    slirp 管理面连不进来（`Connection closed`）。修：bootstrap 中删除该 Interface 并重启 dropbear。
  - `rrun()` 不转发参数，`01-install.sh` 永远按 ipk 跑（apk 分支从未真正执行）。修：`rrun` 支持 `$*`。
  - `run-imm-6.out` 结果：PASS=32 FAIL=46（上述三个问题导致，非产品代码缺陷）。
- **`run-imm-8`：PASS=80 FAIL=3**（离线 kmod 生效）：
  - `kmod-nft-tproxy` 从官方 `kmods/6.12.103-1-0413601b1c3f0490e17f340fe09229ea/` 取 4 个 apk
    （`kmod-nft-tproxy`、`kmod-nf-tproxy`、`kmod-nft-core`、`kmod-nf-conncount`），
    断言 `lsmod | grep nft_tproxy`、`modprobe nft_tproxy` rc=0、`nft ruleset 含 tproxy_prerouting` 均通过；
    tproxy/DNS/fake-ip/tmp-off/tmp-on 全部恢复通过（TRAFFIC fake 3/0、TMPOFF 5/0、TMPON 5/0、BASELINE 8/0）。
  - 剩余 3 项均为**测试脚本自身问题**，非产品缺陷：
    1. `kmod vermagic` 解析取错字段（`awk '{print $3}'` 取到 `SMP`）→ 改 `$2`；
    2. 新增 TCP 探测用 baidu 依赖 DNS，改直连 `http://223.5.5.5/`（ICMP 断言保留）；
    3. fake-ip 阶段偶发 `bytes=0`，给响应体抓取加一次重试。
- **`run-imm-11`：PASS=83 FAIL=0 —— imm (ImmortalWrt 25.12.2 + apk) smoke 全绿。**
  `ROUTER_NET 6/0`（含保留的 ICMP 断言 + 新增 TCP 探测）、`CLIENT_NET 6/0`、`INSTALL 20/0`
  （离线 kmod 4 件套、`lsmod`、`modprobe` rc=0、vermagic 一致）、`BASELINE 8/0`（含 `nft ruleset` tproxy 链）、
  `TRAFFIC fake 3/0`、`TMPOFF 5/0`、`TRAFFIC real 3/0`、`TMPON 5/0`、`TRAFFIC fake(恢复) 3/0`、`DIAG 24/0`。
- **`run-imm-full-1`：PASS=117 FAIL=0 —— imm (ImmortalWrt 25.12.2 + apk) full 全绿。**
  分套件：`ROUTER_NET 6/0`、`CLIENT_NET 6/0`、`INSTALL 20/0`、`BASELINE 8/0`、
  `TRAFFIC fake 3/0`、`ROLLBACK_ASSERT 6/0`、`CRASH_B 7/0`、`CRASH_C 6/0`、
  `TMPOFF 5/0`、`TRAFFIC real 3/0`、`TMPON 5/0`、`TRAFFIC fake(恢复) 3/0`、`DIAG 24/0`。
  证据：`D:\ferry-qemu-work\run-imm-full-1.out`、`D:\ferry-qemu-work\report\summary.md`。

### 门禁 1（imm full）结论：**通过**（PASS=117 / FAIL=0，无 FAIL 断言行）

### 门禁 2（`ferry.preset-defs` TypeError）证据

- 修复提交：`bd0d20a 修复：LuCI 模块 factory 必须返回 constructor（v1.0.0-r2）`
- 源码：`files/www/luci-static/resources/ferry/preset-defs.js` 末尾为 `return baseclass.extend({...})`（合规 constructor）
- 离线契约测试：`tests/test-luci-contract.mjs` → `RESULT: PASS (12 个模块通过 LuCI 类加载器契约)`
- 浏览器实机证据（**已取得**）：headless ImmortalWrt 25.12.2 + `luci-app-ferry-1.0.0-r4.apk`（实机 `apk add` 安装成功），
  浏览器登录 `http://127.0.0.1:8091/cgi-bin/luci`（root），打开 `admin/services/ferry` 与
  `admin/services/ferry/presets`：页面正常渲染预设卡片与保存/复位按钮；
  Console 仅 2 条消息：`RPCError: RPC call to uci/get failed`、`net::ERR_ABORTED .../cgi-bin/luci`，
  **未出现 `TypeError: factory yields invalid constructor`**。
- 门禁 2 结论：**通过**（源码为合规 constructor + 12/12 契约测试 + 真机浏览器无该 TypeError）。

### `run-imm-8`/`9`/`10` 的失败性质（全部为测试脚本自身，非产品缺陷）
- run-8：vermagic 解析取错字段（`$3` 得到 `SMP`）；TCP 探测依赖 DNS；fake-ip 阶段偶发 `bytes=0` 无重试。
- run-9：上述重试改动引入的时序问题导致三段流量全空（curl 无输出），属 slirp 抖动。
- run-10：`nc` 探测退出码不可靠 → 改为 `uclient-fetch` 取报文非空判定（ICMP 断言始终保留）。
- 三次均未降低/删除任何真实功能断言，也未把失败标为 skip。

### `run-imm-7`：PASS=70 FAIL=8 的唯一根因（已解决）
8 个失败全部源自 **`kmod-nft-tproxy` 装不上**：ImmortalWrt 默认 packages 镜像
（mirrors.vsean.net）返回 `wget: exited with error 4` / `unexpected end of file`，
`apk add kmod-nft-tproxy` 失败 → tproxy 规则整份不加载 → TPROXY/DNS/fake-ip/tmp-on 连锁失败
（`未得到 fake-ip` 是直接证据）。已改为宿主从官方
`kmods/6.12.103-1-0413601b1c3f0490e17f340fe09229ea/` 离线取 4 个 apk 推进 guest，
`apk add --allow-untrusted` 安装（签名提示按要求记录进日志），run-imm-8 起 tproxy 全部通过。

## 关键设计说明

### 回滚基线（为什么不是“事务开始的快照”）
LuCI 保存与 `uci commit` 发生在 reload 触发之前，所以事务开始时的 UCI 快照已经是“新配置”。
因此每次用户点“确认保留”（或正常启动且无 pending）时，把当前 `uci export ferry` 落盘为
`/etc/ferry/txn/baseline.uci`；回滚时优先还原该基线，其次才退回事务快照。这保证超时后回到
“上一次确认过的配置”，且只动 ferry 自己的 UCI、nft 表与 fwmark 路由。

### 看门狗实现
- `/etc/init.d/ferry-watchdog`（`USE_PROCD=1`）以独立 instance 运行 `/usr/lib/ferry/watchdog.sh`，
  `respawn 3600 5 5`；不依赖 LuCI / SSH，浏览器关闭或 SSH 断开不影响。
- pending 状态持久化在 `/etc/ferry/txn/pending/meta`（overlay 闪存），断电不丢。
- watchdog 被杀：procd 5 秒内 respawn；若连 procd 一起停掉，`/etc/init.d/ferry restart`
  或下次 boot 的 `start_service` 会检测 pending 并 `startup-detect` 还原。
- 断电：boot 后 procd 启动 ferry，`start_service` 先检测 pending → `instart` 还原（teardown + UCI 基线 + 继续启动）。
- 单飞锁 `pending.lock`（mkdir 原子 + ts 时间戳，>60s 视为崩溃残留可抢占），避免 watchdog 与 boot 双回滚。

## 已知问题 / 风险

- **`kmod-nft-tproxy` 是硬前提**：缺 `nft_tproxy.ko` 时 `nft -f` 对 tproxy 表达式返回 ENOENT
  （报错位置会误导到 `table ip ferry {` 首行），整份规则不加载 → DNS 也不接管。
  验收脚本已改为显式 `opkg install kmod-nft-tproxy ip-full` + `lsmod` 断言 + `modprobe` 兜底。
- 串口控制台有 ~80 列折行：长命令（>80 字符）会被折断导致 `uci: Invalid argument`；
  验收脚本改为逐条短命令下发（`ser_cmd`）。
- 测试拓扑把 eth0 改成 wan 后，fw4 的 wan zone `input=REJECT` 会挡掉 slirp 进来的 SSH；
  验收脚本在 router 上加一条仅放行 `src=wan proto=tcp dest_port=22` 的测试规则。
- `uci commit` 在 rootfs 满时会截断配置；事务快照必须放在 `/etc/ferry`（持久化 overlay）。
- 应用期间 stop 会先恢复 dnsmasq 原生上游并删除备份，回滚后必须重新 start 以重新接管，避免留下半关状态。
- QEMU 的 socket LAN 不支持断线重连：断电重启用例需要同时重启 router 与 client 两台虚机。
- 验收脚本依赖 WSL 内的 Linux QEMU（`-enable-kvm`、`-display none`）；`qemu-img` 在部分 WSL 里缺失，
  需 `QEMUIMG_BIN=/tmp/qu/root/usr/bin/qemu-img`（`apt-get download qemu-utils` + `dpkg -x`）或自行安装 qemu-utils。

## r5 发布（v1.0.0-r5，已发布）

### 加固内容（UCI 读取失败不再让页面整体失败）

- `ferry/store.js`：新增 `isInterruption(err)` 与 `loadConfig()`。
  - 中断判定：`name === 'AbortError'` 或消息含 `ERR_ABORTED|aborted|cancelled|canceled|Failed to fetch`；
  - 真实失败：先等 600ms 重试一次 `uci.load('ferry')`，仍失败才返回 `{ok:false,interrupted:false}`；
  - `loadConfig()` 永不 reject，调用方不再需要自行 catch。
- `view/ferry/main.js`：`load()` 改为 `store.loadConfig()`；真实失败时渲染顶部提示
  （「配置读取失败，已用空白状态启动，可点重试」）+ 重试按钮（`location.reload()`），表单骨架照常渲染；
  导航中断（`interrupted:true`）不弹提示。
- `view/ferry/deploy.js`、`view/ferry/rules.js`：`uci.load('ferry')` 统一改为 `store.loadConfig()`。
- `view/ferry/presets.js`：按要求不改（其 `load()` 已有 `.catch` 回退）。
- `store.js` 内部 `uci.load` 仍保留在写操作（activate/saveActiveProfile/setActiveNodes）路径中：
  写前必须成功读到 UCI，失败应抛给已有 action 错误处理，故不吞异常。

### 回归

- `tests/test-diag.sh`（原有的 49/0 套）：**PASS=49 FAIL=0**。
- `tests/test-luci-contract.mjs`：**PASS (12 个模块通过 LuCI 类加载器契约)**。
- 其余 shell 套件：dnsmasq 24/2、firewall 16/5、generate 20/0、rules 26/0、uninstall 26/0、
  transaction 48/1、kernel 2 项失败（镜像下载 ERR_NETWORK）、mgmt-bypass 21/0。
  失败项均为 nft/网络/并发时序类环境问题，与本次纯 JS 改动无关（改动文件 `node --check` 全部通过）。
- shellcheck：本机未安装（`NOT_INSTALLED`），未执行。

### 发布结果（2026-11-06）

- 提交：`8db3483`（`main` 已推送，`bd000c7..8db3483` fast-forward，未改写历史）
- 标签：注释标签 `v1.0.0-r5` → `8db3483`
- Release：<https://github.com/yunyu697/luci-app-ferry/releases/tag/v1.0.0-r5>
  - `isDraft=false`，`Latest`；附件 3 个，远端 digest 与本地一致
- 包（由 `8db3483` 源码在 WSL 内重建，31 文件，`diff -r` NO_DIFF，与源码逐文件 `cmp` ALL_MATCH）：
  - `luci-app-ferry_1.0.0-r5_all.ipk`：84256 字节，
    sha256 `438404b1b00ed173ea4380e3c979b7a8154b440cd0e88e3e896d13d43228a373`
  - `luci-app-ferry-1.0.0-r5.apk`：84126 字节，
    sha256 `d27fbd034e70f023ea1c39b0d9a71fab41ebf2f7dac7939de5d6ec15a571407a`
  - 与上一轮报告的 r5 候选包哈希不同：ipk 大小一致但 gzip 头内嵌构建时间；apk 由 `mkpkg` 写入
    会话/文件时间戳，字节数也有 4 字节差异。内容与 `8db3483` 源码一致（`cmp` ALL_MATCH），
    差异属打包环境时间戳，不是内容变更。
- 回归（本轮实测）：`tests/test-diag.sh` **PASS=49 FAIL=0**；LuCI 模块契约 **12/12**
- QEMU smoke（OpenWrt 24.10.4 x86_64，headless，`--suite smoke`）：首跑 **PASS=78 FAIL=2**，复跑 **PASS=80 FAIL=0**
  - 首跑 2 个失败均在安装前网络预检：`00-router-net.sh` 的 WAN TCP 探测（`Failed to send request: Operation not permitted`）、
    `client-00-client-net.sh` 的客户端出网 ping；同一次运行中 ferry 安装/服务/DNS/TPROXY/流量/临时关闭/诊断包断言全部通过。
  - 同提交、同包复跑一次为 **PASS=80 FAIL=0**（`run-r5-smoke-4.out`），确认是 QEMU slirp 环境抖动，不是产品缺陷。
- LuCI 主页面 DOM 断言（无头浏览器 CDP，仅文本/DOM/控制台，无截图；详见下节）：
  - 正例 **PASS**；反例「提示 + 重试」**PASS**，但「表单骨架保留」**FAIL**（发现 r5 真实缺陷，定位到 `main.js:201-202`）。

- 事实：未使用 OpenWrt 官方 SDK / buildroot（自建 staging + `build_ipk.py` + `apk mkpkg`）；OpenWrt 侧未签名。

### LuCI 主页面 DOM 断言（2026-11-06 补测，无截图）

环境与登录方式：
- QEMU 内启动 OpenWrt 24.10.4（x86_64），双网卡：eth0=`net=192.168.1.0/24`（LAN，hostfwd 22/80），eth1=默认 slirp（WAN，DHCP 10.0.2.15）。
- guest 侧**不使用 SSH**：全部经串口控制台（`tests/qemu/serial_exec.py`）完成——设置 root 密码、
  `uclient-fetch` 从宿主机 `10.0.2.2:8899` 取包、`opkg install`（`OPKG_RC=0`）、重启 uhttpd/rpcd。
- 浏览器侧：宿主机 headless Chromium（`--headless=new --remote-debugging-port=9333`），
  在 LuCI 登录表单填写 `root`/`ferrytest` 提交获得会话，再打开
  `http://127.0.0.1:8091/cgi-bin/luci/admin/services/ferry`。

正例结果（PASS）：页面标题「Ferry 透明代理网关」、章节「基础设置」、18 个 input / 8 个 select，
关键字「启用 / 代理内核 / 运行模式 / 部署形态」齐全；无「配置读取失败」提示；
`Runtime.exceptionThrown`=0，console error/warning=0，log error=0；未出现 `factory yields invalid constructor`。

反例结果（部分 PASS / 核心断言 FAIL）：
- 触发方式：移除 `/etc/config/ferry`（`uci.load('ferry')` 真实失败）。也试过写入语法错误配置，现象相同。
- 通过项：出现「配置读取失败，已用空白状态启动，可点重试。」与「重试」按钮。
- 失败项：表单骨架**没有**保留。`#maincontent` 文本仅 104 字符，表单区域输出 `[object Promise]`，
  无标题、无任何 select/input（侧栏与主题的 Save 按钮仍在）；并产生 2 条未捕获异常：
  `RPCError: RPC call to uci/get failed with ubus code 4: Resource not found`。
- 缺陷定位：`files/www/luci-static/resources/view/ferry/main.js:201-202`

```js
var node = m.render();
return notice ? E('div', {}, [ notice, node ]) : node;
```

  `m.render()` 返回 Promise；正常分支直接返回（LuCI 会 await），失败分支把 Promise 塞进 `E()`，
  于是渲染成 `[object Promise]` 且表单丢失。修复方向（r6 待办，本轮未改生产代码）：
  `return node.then(function(n){ return E('div', {}, [ notice, n ]); });`
- 配置还原：`cp /tmp/ferry.bak /etc/config/ferry` 后复测正例 PASS，页面恢复正常。


