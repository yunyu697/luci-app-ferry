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

## r6：修复反例缺陷 + 回归断言（v1.0.0-r6，2026-11-06）

### 根因（两处）

1. `view/ferry/main.js`：`form.Map.render()` 返回 Promise，r5 失败分支把它放进 `E('div', {}, [notice, node])`，
   渲染成 `[object Promise]`，表单丢失；`form.Map` 渲染期的 `uci.get` 在配置缺失时抛 `RPCError`（ubus code 4）。
2. `ferry/store.js`：LuCI `uci.load()` 的 `loadPackage()` 会把**失败的 Promise 缓存**进 `uci.loaded`，
   同页面「重试」永远拿到同一个 reject——必须 `uci.unload('ferry')` 才能重新读盘。

### 修复

- `main.js`：`render()` 改为容器化 `paint(state)`；真实失败分支不再走 `form.Map`，
  改渲染静态骨架（标题「Ferry 透明代理网关」+「启用」select +「代理内核」input），
  同时渲染提示与「重试」按钮；重试回调真正调用 `self.load()`，成功后 `paint(ok)` 重建完整表单。
  导航中断（`AbortError` / `ERR_ABORTED` 等）仍不弹提示。
- `store.js`：新增 `loadOnce()`（`uci.unload('ferry')` → `uci.load('ferry')`），首次失败后的 600ms 重试也走它。
- `deploy.js` / `rules.js` 静态检查：`render()` 返回普通 `E()` 节点，无 Promise 入 DOM 写法，未改。
- `Makefile`：`PKG_RELEASE` 5 → 6。

### 回归断言（可重复执行，非截图）

`tests/luci-dom-negative.sh` + `tests/luci-dom-assert.mjs`：串口驱动 guest（备份并移除 `/etc/config/ferry`）
+ 宿主机 headless Chromium（CDP），断言 DOM 文本/选择器与 `Runtime.exceptionThrown`；失败非零退出。
实测：**ASSERT PASS=14 FAIL=0**（`RESULT: PASS`）

- 移除配置后：提示 ✓ / 重试按钮 ✓ / 骨架（标题 + `inputs=2` + `selects=1`）✓ /
  未捕获异常 `count=0` ✓ / 无 `factory yields invalid constructor` ✓
- 还原配置后点重试：提示消失 ✓ / 完整表单 `inputs=18 selects=8` ✓ / 首个 select `value=mihomo` ✓ /
  重试过程异常 `count=0` ✓
- 首轮实测 13/14（「重试后提示消失」FAIL，表单停在骨架）→ 由此定位 `uci.load` 失败缓存问题 → 修复后 14/14。

### 出包与门禁

- ipk：`luci-app-ferry_1.0.0-r6_all.ipk`，84,826 B，`ecb974f9e104d92269e19bb0fb09c2dd2d266300c8c9e8af54f1407f421e4c16`
- apk：`luci-app-ferry-1.0.0-r6.apk`，84,707 B，`5781782b5d443803b15bfe28f154eb9cd0b40bda5db3b51e74571b0b0ccb8a46`
- 一致性：ipk / apk 各 31 文件 `diff -r` **NO_DIFF**；与源码逐文件 `cmp` **ALL_MATCH**。
- smoke（OpenWrt 24.10.4 x86_64 headless QEMU）：首跑 **PASS=79 FAIL=1**（仅 `00-router-net.sh` WAN TCP 探测，
  环境类 `Failed to send request: Operation not permitted`），复跑 **PASS=80 FAIL=0**。
- r5 Release 已追加「勘误（2026-11-06）」，说明 r5 的「保留表单骨架」在真实失败时不成立，指向 r6。

## r7：内核管理下载修复 + 插件专属内核目录（v1.0.0-r7，2026-11-06）

### 「下载不了内核」的真实原因（实测定位）

1. **代码缺陷（主因）**：`kernel.sh` 的 CLI `versions` 分支没有读取 stdin，而 `PMK_ARGS` 又被
   `PMK_ARGS=''` 清空，rpcd 传入的 `kernel` 参数丢失，接口恒定返回
   `{"ok":false,"error":"unknown kernel"}` —— 界面拿不到版本列表，下载入口等于不存在。
   （QEMU guest 内用 r6 包实测复现：`kernel.sh versions` → unknown kernel。）
2. **只有官方源**：`mirrors` 清单默认仅启用 GitHub 官方源；本次在受限网络实测官方资产
   `302 → 连接重置`（curl code=000，16s 失败），没有镜像就没有可用路径。
3. **临时目录与空间检查错位**：下载临时文件写 `/var/etc/ferry`（tmpfs），空间预检却查 flash。
4. **落位到 `/usr/bin`**：会覆盖系统已有的 mihomo / sing-box / xray，且插件升级/卸载易误删。

### 修复

- 内置源清单 `files/usr/lib/ferry/kernels-builtin.tsv`（34 条资产记录，官方 SHA-256 + 大小）：
  官方 `github` / `ghfast.top` / `ghproxy.net` 默认启用 + jsDelivr（仅仓库内文件，默认关闭）+ custom。
  `auto` 模式按序回退，任务与界面标注「已回退到 X 源」；**校验基准始终是官方 SHA-256**，
  镜像侧车 `.sha256` 永不采信，镜像给错/给旧文件会被 `ERR_SHA_MISMATCH` 拦住。
- 插件专属目录：`/etc/ferry/kernels/<内核>/<版本>/<二进制>` + `<内核>/active`、`previous` 指针
  + `kernels/current` 运行指针；启动从插件目录取二进制，不依赖 PATH；`common.sh` 的
  `pm_kernel_bin()` 优先 current 指针。升级不丢内核；卸载默认保留并提示，`--purge-kernels` 才删。
- 下载保护：按目标大小 ×6 + 8 MB 预检空间（报错含可用/所需 MB）；临时文件 → SHA-256 →
  权限 → 目录级原子替换，失败回滚保留旧版本。
- 架构与变体：amd64 / arm64 / armv7 / armv6 / mipsle / mips / 386 / riscv64，含 ELF 大小端判定；
  架构不符直接列出本机可用变体；glibc 依赖的资产拒装。
- 界面（`kernel.js`）：架构、版本列表（大小 + 官方 SHA-256，打开页面自动加载内置清单）、
  当前源、进度、可读失败原因、重试（沿用上次参数）、已装版本与路径；新增二进制来源/内核目录/
  current 指针/系统内核/可用空间。
- `build_ipk.py`：`VERSION` 从 `1.0.0-r5` 修正为 `1.0.0-r7`（此前 r6 的包文件名是 r6、
  control 里仍写 r5，属发布元数据缺陷）。`Makefile` `PKG_RELEASE` 6 → 7，
  `kernels-builtin.tsv` 进入安装清单。

### 验证（后台执行）

- 离线回归 `tests/test-kernel.sh` 20 组：**PASS=80 FAIL=0**（新增 16–20 共 5 组 22 条断言：
  内置源清单、自动回退与 fallback 标注、镜像旧文件被 SHA-256 拦截、插件目录且不覆盖系统内核、
  离线版本清单）。反例覆盖：校验失败不落位、架构不匹配、空间不足、镜像旧文件、回退。
- **真实网络端到端**（WSL 宿主，非 mock）：`ghfast.top` 15s 下载 22,893,972 B →
  官方 SHA-256 `386508bf…22b6` 校验通过 → 落位 `store/mihomo/v1.19.33/`（62,079,102 B）→
  current 指针 → `mihomo -v` 输出 `Mihomo Meta v1.19.33 linux amd64`，`rc=0`，
  job `source=ghfast fallback=false`。
- 源可用性实测（同一资产）：`ghfast.top` 200（15s 全量）；`ghproxy.net` 200 可下载但 25s 仅 5.8 MB；
  官方 GitHub `302` 后连接重置；jsDelivr 默认关闭（仅能映射仓库内文件）。
- smoke（OpenWrt 24.10.4 x86_64 headless QEMU，`--suite smoke`）：3 次 **78/2、79/1、85/1**，
  唯一 FAIL 恒为 `00-router-net.sh` 的 WAN TCP 探测（`uclient-fetch` →
  `Failed to send request: Operation not permitted`，WSL+slirp 环境类，与 r5/r6 同源）；
  安装段扩到 23 条断言并全绿（含 `kernels-builtin.tsv` 34 条、包元数据版本 = 1.0.0-r7）。

### 出包与门禁

- ipk：`luci-app-ferry_1.0.0-r7_all.ipk`，91,981 B，`d5e188b94f3fd9cd84bd086cfdb55409757b0f755a0c439f7ed91ceabc2286c1`
- apk：`luci-app-ferry-1.0.0-r7.apk`，91,856 B，`410eb30d912e1c2666128b936f2bdde9081f0e0eb62355517849a91b878c4102`
- 一致性：ipk / apk 各 32 文件 `diff -r` **NO_DIFF**；与源码逐文件 `cmp` **ALL_MATCH**。
- ipk control：`Version: 1.0.0-r7`；apk adbdump：`version: 1.0.0-r7`（与发布版本一致）。

## r8：内核目录持久化 + 内置资产可用性审计（v1.0.0-r8，2026-11-06）

### 结论 1：`/etc/ferry/kernels` 不会被子升级保留（实测，不是推断）

- 机制：OpenWrt sysupgrade 是**白名单**备份，只备份 `/etc/sysupgrade.conf` 与
  `/lib/upgrade/keep.d/*` 里列出的路径（目录会被 `find` 递归展开成文件），overlay 上其余文件
  在升级时全部丢弃；不存在「整个 `/etc` 自动保留」。
- guest 实测（OpenWrt 24.10.4 x86_64，headless QEMU，SSH 2223）：
  - 建 `/etc/ferry/kernels/probe/bin` 后 `sysupgrade -l` 共 **28** 条，`/etc/ferry/kernels` 命中 **0**；
    同一镜像里已存在的 `/etc/config/ferry` 命中也是 **0**（直接证明不是 `/etc` 整体保留）。
  - 写入 `/lib/upgrade/keep.d/ferry`（内容 `/etc/ferry/kernels`）后共 **29** 条、命中 **1**，
    且展开为具体文件 `/etc/ferry/kernels/probe/bin`。
  - 反例（本次踩到并固化）：把 keep.d 文件**原地改名**为 `ferry.off` 仍会被 `keep.d/*` 通配读到
    （without=1）；必须移出该目录才等价于「未登记」。smoke 首轮唯一的 FAIL 就是这条测试脚本缺陷，
    改为移到 `/tmp` 后 `without=0 with=1`。
- 方案（两条同时落地）：
  1. 随包安装 `/lib/upgrade/keep.d/ferry`（Makefile 安装；包内实测存在）；
  2. 新增 UCI `ferry.main.kernel_dir`（空 = 默认 `/etc/ferry/kernels`），可指到外置存储；
     `store-set` RPC 校验：必须是绝对路径、拒绝 `/tmp` `/var` `/run` 内存盘、外置父目录必须存在且可写。
- 持久性分级（`status` 暴露 `kernel_dir_cfg` / `store_persist` / `store_device` /
  `keepd_installed` / `store_backup_kb`）：
  - `rootfs`（与 `/` 同设备）→ 依赖 keep.d，界面黄色警告并显示「备份体积」；
  - `external`（独立分区）→ 升级不影响，无需 keep.d；
  - `volatile`（`/tmp` `/var` `/run`）→ 安装前直接 `ERR_STORE` 拒装。

### 结论 2：overlay 装不下解包内核，必须支持外置（实测数字）

- `df -k /`（已装 ferry 的真实值）：`/dev/root 100,692 KB 总 / 87,048 KB 已用 / 11,516 KB 可用（88%）`
  → 总量 ≈ 98.3 MiB，可用 ≈ **11.2 MiB**。
- mihomo v1.19.33 amd64：压缩 22,893,972 B（21.8 MiB），解包 **62,079,102 B（59.2 MiB）**。
  11.2 MiB 可用装不下 59.2 MiB，预检（目标大小 ×6 + 8 MB）会先报 `ERR_DISK_FULL`。
- 因此：空间不足提示补上「改到外置存储（如 `/mnt/sda1/ferry-kernels`）」与 overlay 说明；
  同时提示 keep.d 备份会把几十 MB 内核打进升级包，外置目录则完全不需要进备份。

### 结论 3：34 条内置资产全部实测可达，2 条做了全量校验

- 新增 `tests/qemu/audit-assets.sh`：抽样条目全量下载 + SHA-256 + 解压 + ELF 架构断言；
  其余条目 HTTP Range 探测（接受 200/206，`Content-Range` 总长必须等于清单 `size`）；失败标 `dead`。
- 实测（`AUDIT_MIRROR=https://ghfast.top/`，清单落款 `# audited=2026-11-06T10:12:35`）：
  - `ok` **2**：mihomo v1.19.33 arm64（20,824,326 B，SHA `ba408b31…6187`，ELF arm64/LE/64bit）、
    mihomo v1.19.33 mipsle（资产名 `mihomo-linux-mipsle-softfloat-v1.19.33.gz`，20,397,891 B，
    SHA `ad6b3837…71c4`，ELF mipsle/LE/32bit）；
  - `probe` **32**：全部 HTTP 206 且 `Content-Range` 总长与清单一致；
  - `dead` **0**：本次没有不可用条目；若出现会标记 `dead` 并从界面版本列表隐藏，
    同时 `versions` 返回 `unavailable` 计数，界面提示「已隐藏 N 条源上不可用的资产」。
- 清单第 8 列 `state`：`pmk_builtin_records` 默认过滤 `dead`，`pmk_builtin_first_url` 跳过 `dead`；
  反例断言覆盖「dead 隐藏 + 首个可用 URL 不取 dead 条目 + unavailable 计数 = 2」。
- 变体映射断言：arm64 → `mihomo-linux-arm64`；mipsle → `mipsle-softfloat`（软浮点命名差异）。

### 验证（后台执行）

- 离线 `tests/test-kernel.sh` 24 组：**PASS=98 FAIL=0**（新增 21–24：keep.d 登记与安装、
  external/volatile 判定与 `ERR_STORE` 拒装、dead 隐藏、变体映射）。
- 真实网络 E2E（WSL 宿主，非 mock）：arm64 与 mipsle-softfloat 两个变体全量下载 → SHA-256
  通过 → ELF 架构正确；在 amd64 宿主上安装被 `ERR_ARCH` 拦截且**未落位**；
  amd64 安装 13s 成功，`mihomo -v` `rc=0`。
- smoke（OpenWrt 24.10.4 x86_64 headless QEMU，`--suite smoke`）：两轮 **88/1**；
  首轮唯一 FAIL 为 keep.d 改名反例（脚本缺陷，已修），安装段 25/1；
  次轮安装段 **26/0**（含 `without=0 with=1`、keep.d 随包安装、34 条清单、版本 1.0.0-r8），
  唯一 FAIL 为 `client 无法出网`（WSL slirp 环境类，与 r5/r6/r7 同源）。

### 出包与门禁

- ipk：`luci-app-ferry_1.0.0-r8_all.ipk`，95,161 B，`258420786e49199aa7c90eb0fd3aaab5122403dcf526f7d9a632be6df4ed0f1b`
- apk：`luci-app-ferry-1.0.0-r8.apk`，95,017 B，`af141ff07e3d439e60900a42dd64f4ac822a275e43e139af6f7080bc38fc0558`
- 一致性：ipk / apk 各 **33** 文件 `diff -r` **NO_DIFF**；与源码逐文件 `cmp` **ALL_MATCH**。
- ipk control：`Version: 1.0.0-r8`；apk 由 `mkpkg -I version:1.0.0-r8` 生成（同一 VERSION）。




## r9：升级不阻塞 + 升级后自动装回 + 配置零丢失（v1.0.0-r9，2026-11-06）

### 结论 1：两条升级路径的实测行为（headless QEMU，不是推断）

- attended sysupgrade（ASU 公共 API `https://sysupgrade.openwrt.org/api/v1/build`）：
  - 24.10.4（opkg，客户端 `owut`，**该分支没有 auc**）：装了 `luci-app-ferry` 时
    HTTP **500**，正文 `Error: Impossible package selection: missing (luci-app-ferry)`。
  - 25.12.0（apk-tools 3.0.2，客户端 `owut`）：同一条 500，文本一致。
  - 错误来自**服务端包索引找不到包**；基线包（不含 ferry）同一 API 返回 202 并构建成功，
    证明不是本地依赖校验、也不是签名问题。
  - 请求体里 `repositories` / `repository_keys` / `repositories_mode: replace` 均被接受，说明
    API 层**支持**自定义源与公钥；但公共服务器不会拉取我们的自签名 feed（没有公共可达的签名
    feed 可做端到端），因此**ASU 无法直接构建带 ferry 的镜像**这一条要如实保留。
- 普通 `sysupgrade` 刷镜像：能正常完成；未登记 keep.d 时 ferry 包文件与 `/etc/config/ferry`
  **全部丢失**，只保留官方默认保留项（网络配置等）。

### 结论 2：x86 的备份位置与截断（延续 r8）

- `platform_copy_config()` 把备份写到分区 1 `/boot`（15.7 MB）。62 MB mihomo 参与备份时被截断，
  解包 `tar: unexpected end of file`，mihomo 只恢复 25,308,160/62,079,102 字节，
  snapshot/offline/selfheal 钩子全部丢失。→ 内置内核目录在 x86 上不可保留，必须外置；
  `prep` 增加 `preflight_backup_size()` 预警（实测 20 MB dummy → `PREP WARN ... 超过 /boot 可用 9952KB`）。

### 实现

- `ferry-sysupgrade` 子命令：`status / snapshot / verify [--json] / restore [--auto] / prep [--pkg F] / remove / selfheal`。
- keep.d 改为**有序 5 条**（顺序即备份顺序，截断先丢后面的）：
  `/etc/uci-defaults/60-ferry-selfheal` → `/etc/ferry/offline` → `/etc/ferry/snapshot`
  → `/etc/config/ferry` → `/etc/ferry`（内核目录由父目录递归覆盖，外置时不打包多份）。
  仓库静态 `files/lib/upgrade/keep.d/ferry` 已同步，避免装回后覆盖回旧清单。
- 离线安装：优先包管理器（`opkg install` / `--force-depends`；`apk add --allow-untrusted`），
  无包文件时 `payload.tar.gz` + `install-payload.sh` 兜底并写 `/etc/ferry/.installed-payload`。
- 首启自愈 `60-ferry-selfheal`：区分 opkg/apk；未装则离线装回；按 `fstab` 直接
  `mount -t $fstype $device $target` 恢复外置内核目录（不依赖新固件是否有 `block-mount`）；
  从快照恢复并 enable+start；执行后自删，下次 `prep` 重建。
- 快照逐项：UCI 全量 + 节点/规则/profile 计数与校验和 + 内核清单（sha256）+ 端口/订阅字段；
  `verify` 升级前后逐字段比对，`--json` 输出计数。LuCI 新增「升级与恢复」页。

### 发现并修复（r8 遗留，阻断性）

- `view/ferry/kernel.js` 两处括号缺失（第 147、574 行）→ 整个内核页 JS 语法错误无法加载；
  已修复，`node --check` 全量通过，`test-luci-contract.mjs` **PASS（12 个模块）**。

### 验证（后台执行，全部用最终包）

- 离线回归：`test-sysupgrade.sh` **ALL PASS**；`test-kernel.sh` **ALL PASS**（keep.d 断言更新为
  接受父目录覆盖）；`test-generate` 20/0、`test-rules` 26/0、`test-diag` 49/0、
  `test-mgmt-bypass` 21/0、`test-transaction` 49/0、`test-uninstall` 26/0。
  `test-firewall` 16/5、`test-dnsmasq` 24/2 为 **r8 基线同样存在的既有失败**（已在 r8 worktree 复跑确认，
  与 r9 改动无关）。
- 同发行版真实升级（24.10.4 → 24.10.4，x86_64，外置 `/dev/sdb -> /mnt/kernels`）：
  装 r9 → 配置（节点 2/规则 3/profile 2/端口 7890/7891/1053/订阅 URL）→ snapshot 35 项
  → prep（keep.d 5 条、offline ipk+payload、hook）→ verify 35/35 → `sysupgrade` 刷 `owrt2410.img.gz`
  → 首启 `pm-install opkg ... ok=1` + `kernel-dir mounted /dev/sdb -> /mnt/kernels` + `RESTORE OK`
  → **verify 35/35 PASS, 0 FAIL, 0 WARN**，`procs=1`，7891/1053 监听，`package: installed`。
- 跨包管理器真实升级（24.10.4 opkg → 25.12.0 apk-tools 3.0.2）：
  首启 `pm-install apk ... ok=1`、自动挂载外置盘、`RESTORE OK`；`apk info -e luci-app-ferry` 已登记；
  **verify 35/35 PASS**；`procs=1`；7891/1053 监听；内核 sha256 `817f50b3…b620f` 与升级前一致。
- 一致性：ipk / apk 各 **37** 文件 `diff -r` **NO_DIFF**；与源码 `cmp` **ALL_MATCH**。

### 出包

- ipk：`luci-app-ferry_1.0.0-r9_all.ipk`，103,370 B，`0d7ab5aca5ee807b4903ae17fa63d8ebccbc8985e2e87c2567cd8611eaace481`
- apk：`luci-app-ferry-1.0.0-r9.apk`，103,390 B，`ac49edeb09654b9e7d90cc485224d4d3561453849d79c53562fbacc35e003ada`

### 仍未做到

- ASU 公共服务器不接受自签名 feed 参与构建（无公共可达签名 feed），跨版本「保留包重建」仍需
  先 `ferry-sysupgrade remove`，升级后自愈自动装回；无法宣称 ASU 一步到位。
- 23.05 环境未覆盖（无该镜像；23.05 也是 opkg，按 24.10 的 opkg 路径实现，未实测）。
- x86 上内核目录必须外置；内置大内核在 `sysupgrade` 中无法保留（`/boot` 16 MB 硬限制）。
