# 内核管理（r3）进度

更新时间：2026-11-05（真机与打包已完成，待提交/发版）

## 已完成

- 后端：`files/usr/lib/ferry/kernel.sh`（下载/镜像/自定义 URL/本地导入/校验/架构/原子替换/版本管理/切换/回滚/卸载/配置生成 + `sing-box check` / `mihomo -t` 门禁/作业状态/镜像测速）
- rpcd：`files/usr/libexec/rpcd/luci-ferry-kernel`（正确协议：`$1=list|call`，`call` 时方法在 `$2`）
- UI：`files/www/luci-static/resources/view/ferry/kernel.js` + `ferry/kernels.js`；menu/ACL/UCI（`mirrors.json`）
- 生成器：`generate.sh` 按版本区间 A/B/C/D 选模板，`/var/etc/ferry/config-check-report.txt` 记录落位与校验结果
- 测试：`tests/test-kernel.sh`（离线 15 节 55 项 ALL PASS）；`tests/test-luci-contract.mjs`（12 模块 PASS）；其余 5 套离线全 PASS（合计 174 项）
- 真机（QEMU x86_64，真实上游二进制，日志在 `qemu/logs/owrt-full2.log`、`qemu/logs/imm-full.log`）：
  - OpenWrt 24.10.4（ipk）：全新装 mihomo 1.18.8 → 装 sb 1.8.14（不激活）→ 切 sb 1.8.14/1.10.7（A）/1.11.0（B）/1.14.4（D）→ 回滚 1.11.0 → 卸非当前 1.8.14 → 跨内核切回 mihomo 1.18.8 → 切 mihomo 1.19.33；每步 `check`/`-t` rc=0、进程 pid 存活
  - ImmortalWrt 25.12.0（apk）：mihomo 1.19.33 → sb 1.10.7 → 切回 1.19.33 → 切 1.18.8 → 回滚 1.19.33 → 卸非当前 → `apk del luci-app-ferry` 后 `/etc/ferry/kernels/mihomo/*` 完整保留
  - 真实镜像：`mirror_test ghproxy` ok（6s/876KB 取样）；经 ghproxy 真装 sing-box 1.14.4，74s，sha256 `8f7c5f06…a12057ca` 与官方一致
- 打包（`qemu/build-pkgs.sh`）：
  - `dist/luci-app-ferry_1.0.0-r3_all.ipk` 68412 B，sha256 `ec3b2ab1b9b3d1003d57018dfec9f19c94900d09b525c6d0374aaef3e69cfa6c`
  - `dist/luci-app-ferry-1.0.0-r3.apk` 68132 B，sha256 `33ca168a8d7582f3715a131fa25bd7d3209efed30b6ff24a807fc1780c39095d`
  - 两台真机安装新包成功；包内 `kernel.sh`/`generate.sh`/`common.sh`/`uninstall.sh`/rpcd/`kernels.js` 与仓库源码哈希逐项一致

## 本轮真机暴露并修复

1. 精简固件无 `timeout` → `generate.sh` 版本探测失效 → 误判「未适配版本」；改为 `pm_timeout` 退化（common.sh 提供）
2. 首次安装 `kernels/` 不存在 → `df -k` 失败导致 `free_kb=0`；改为向上找父目录
3. 非当前内核的 active 版本被误拦截卸载；改为仅拦当前 UCI 内核的 active，并在删除指针目标时清理 `active` 与失效 `/usr/bin` 链接
4. 镜像测速依赖 `timeout` 限流，会拖到 30s+ 超时；改为后台取样 6 秒终止
5. `uninstall.sh --purge` 在无内核版本库时留下空壳 `/etc/ferry`；改为无 `kernels/` 时清理空目录
6. 手工 ipk 外层为 tar.gz：实测 OpenWrt 24.10 的 opkg(2024-10-16) 会拒绝 ar 容器（Malformed package file），接受 tar.gz 包裹；已按可安装形式保留

## 未完成 / 下一步

1. 本仓库改动的提交（author/committer `yunyu697 <1869716+yunyu697@users.noreply.github.com>`）+ tag `v1.0.0-r3`
2. GitHub Release 附件（ipk/apk/SHA256SUMS）并逐项比对远端 digest
3. 后续独立任务（不与本内核提交混在一起）：GitHub Actions 真编译 CI、`KERNEL-ARCH-MATRIX.md` 架构矩阵

## 注意

- `qemu/vm.ps1`：单网卡 + `hostfwd` 到 slirp 默认 `10.0.2.15`，启动后需 guest 执行 `udhcpc -i br-lan`
- 镜像自带 busybox 无 `od`/`timeout`：本地复跑请直接使用源码版；QEMU 镜像内核缺 `nf_tables`，接管规则加载会报错（测试环境限制，非产品缺陷）
- 证据：`qemu/logs/`（serial、qemu、full-test 日志）；`qemu/dist/`（包）
