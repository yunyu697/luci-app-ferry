# Ferry 交接说明（HANDOFF）

面向“换一台机器接手”的会话：这里只记录当前状态、文件关系、决策与验证边界；安装命令不复制，统一见 README 第 4 节。

## 1. 一句话现状

功能（节点/规则/预设/部署/档案/双内核配置生成）已完成，并已完成 `proxymesh` → `ferry`（渡口）改名与首发：全仓库无旧名残留；静态检查、5 个离线测试全部通过；在自建 QEMU 实例上做了真机安装验证——OpenWrt 24.10.4（opkg）与 ImmortalWrt 25.12.0（apk）均完成“装包 → 服务启动 → 菜单文件就位 → 卸载（prerm/pre-deinstall 执行、dnsmasq 还原、nft 表清空、用户数据保留）→ 重启后 dnsmasq 接管仍成立”。产物 ipk/apk 通过 GitHub Release 分发，不入库。

## 2. 关键文件职责

| 文件 | 职责 | 改动会影响什么 |
| --- | --- | --- |
| `Makefile` | 包元数据、依赖、安装落位、`conffiles` | 依赖缺失会导致装不上；安装路径漏项会导致页面/服务不存在 |
| `files/etc/config/ferry` | UCI 默认值（开关、内核、模式、端口、部署、镜像源等） | 升级时作为 conffile 保留；改默认值只影响全新安装 |
| `files/etc/init.d/ferry` | procd 生命周期：start/stop/reload/status | 启动顺序是“先生成配置→起进程→等端口→装规则”；顺序改错会把局域网打进黑洞 |
| `files/etc/uci-defaults/50-ferry` | 首次初始化：建目录、enable 服务、清 LuCI 索引 | 不写 `nodes.json`/`profiles.json`，避免与前端写入竞态 |
| `files/usr/lib/ferry/common.sh` | UCI 读取、路径常量、日志/告警、status.json、旧配置迁移、dnsmasq 上下游改写、包管理器探测 | 所有脚本都依赖它；`pm_load` 的字段名与 README 5 节表格必须一致 |
| `files/usr/lib/ferry/nodes.sh` | 读 `nodes.lst`，分别渲染 mihomo `proxies` / sing-box `outbounds` | 改节点字段映射只影响生成结果；SSR 只给 mihomo，sing-box 跳过并告警 |
| `files/usr/lib/ferry/rules.sh` | 规则集下载/缓存、mihomo `rule-providers` 与 sing-box `rule_set` 渲染、`rules.lst` 消费 | 改镜像源/缓存逻辑影响启动时联网行为；渲染顺序即优先级 |
| `files/usr/lib/ferry/generate.sh` | 组装完整 mihomo YAML / sing-box JSON、自检、`pm_prepare` 总入口 | 部署形态（router/bypass/client）与模式（tproxy/tun/redirect）的差异都在这里落地 |
| `files/usr/lib/ferry/firewall.sh` | nftables 独立表、iptables 兼容链、TPROXY 策略路由、后端探测与回退 | 规则优先级、DNS redirect、QUIC 丢弃、清理顺序都在这；改动风险最高 |
| `files/usr/share/luci/menu.d/*.json`、`rpcd/acl.d/*.json` | 菜单与权限 | ACL 漏写会让页面读写失败；两代 LuCI 路径相同 |
| `files/www/.../view/ferry/*.js` | 6 个页面：基础设置、节点、规则、预设、部署、档案 | 表单字段必须与 UCI/JSON 字段对齐；老 LuCI 的 `ui.showModal` 已做降级 |
| `files/www/.../ferry/store.js` | JSON 源读写、profile 激活/回写 UCI、编译成平面文件、调用 reload | 是 LuCI 与 shell 的唯一桥；改编译格式必须同步改 nodes.sh/rules.sh |
| `files/www/.../ferry/links.js`、`preset-defs.js` | 分享链接解析、分类/预设定义 | 解析错误只影响导入；分类名必须与 rules.sh 的 `pm_category_geo` 对齐 |
| `scripts/fetch-kernel.sh` | PC 端下载/校验内核，默认 x86_64 | 只影响获取二进制，不影响包 |
| `scripts/build.sh` | 双格式构建：识别 SDK 模式、复制源码、compile、收集 `dist/ipk|apk` | 只影响构建产物，不参与设备运行 |
| `README.md` | 设计假设、编译/安装、字段、FAQ、验证边界 | 与代码不一致时以代码为准，但需回写文档 |

调用关系（shell 侧）：`init.d` 依次 source `common.sh → nodes.sh → rules.sh → generate.sh → firewall.sh`；`generate.sh` 调 nodes/rules 的输出函数，`init.d` 在进程就绪后调 `firewall.sh`。LuCI 侧：`store.js` 写 `nodes.json`/`profiles.json`，并编译出 `nodes.lst`/`rules.lst`/`custom.lst`；shell 只读这三个平面文件，不解析 JSON。

## 3. 设计决策与理由

1. **iptables 不设硬依赖**：apk 分支里 `iptables-mod-tproxy` 命名/可用性不稳定，硬依赖会导致装包失败。默认 `firewall_backend=auto`，nft 不可用时回退 iptables，两者都不可用则保持直连并告警。放弃方案：默认强制 iptables 或同时硬依赖两套。改哪里：`Makefile` 的 `DEPENDS`、`firewall.sh` 的 `pm_fw_backend_resolved`、README 3.3。
2. **旁路由只关 TUN 的 auto-route，不禁用 netfilter**：旁路由仍需处理“本机收到的转发流量”，全禁 netfilter 会让旁路由失效。放弃方案：bypass 一律不装规则。改哪里：`common.sh` 的 `pm_tun_autoroute`、`generate.sh` 里 `auto-route`/`auto_route` 的生成处。
3. **DNS 不在 OUTPUT 链劫持**：只劫持 LAN 入向 53（nft `nat prerouting` / iptables `PREROUTING`），路由器自身 DNS 走 dnsmasq 上游改写，避免影响路由器本机其他解析。放弃方案：在 OUTPUT 链重定向本机所有 53。改哪里：`firewall.sh` 的 DNS 链、`common.sh` 的 `pm_dnsmasq_apply/restore`。
4. **规则集只引用本地缓存，不在配置里写远程 URL**：启动不依赖联网，下载失败保留旧缓存。放弃方案：让内核直接拉远程 rule-provider。改哪里：`rules.sh` 的 `pm_rules_sync` 与渲染出的 provider/rule_set 路径；若要联网直拉，改 `pm_mihomo_rules_render`/`pm_singbox_rules_render`。
5. **规则优先级“靠前优先”（first-match）**：`rules.lst` 行序即优先级，自定义条目按在分类列表中的位置插入。放弃方案：按分类固定权重排序。改哪里：`store.js` 的 `rulesText` 与 `rules.sh` 的渲染循环；两处必须一起改。
6. **profile 激活态回写 UCI**：激活/保存档案时把标量字段写回 `ferry.main` 并 `uci.save()`，保证老 UCI 页面/命令行仍有效；规则页/部署页保存前先 `syncUci` 刷新快照。放弃方案：UCI 只存一个 profile id，其余全从 JSON 读。改哪里：`store.js` 的 `activate`/`saveActiveProfile`/`syncUci`。
7. **初始化只走 `uci-defaults`**：不依赖 postinst/prerm，ipk 与 apk 都能执行；安装当时不保证跑，所以 README 安装步骤显式执行一次。放弃方案：在 Makefile 里写 postinst 建目录。改哪里：`files/etc/uci-defaults/50-ferry`、`Makefile` 的 install 段。

## 4. 校验的真实边界

- **跑过的**：7 类节点 + 9 条分类 + 4 条自定义，配合真实规则缓存（16 个 geosite），8 组“内核 × 部署 × 模式”全部 PASS；mihomo `-t` / sing-box `check` 配置自检通过。
- **QEMU 真机实测**（x86_64，`-nographic`，qcow2 覆盖层，原镜像只读）：OpenWrt 24.10.4 opkg 装/卸载 37 项 PASS、重启自愈 12 项 PASS；ImmortalWrt 25.12.0 apk 28 项 + 21 项 PASS。覆盖服务启动、LuCI 菜单/ACL 文件就位、prerm/pre-deinstall 实际执行、dnsmasq 上游还原、nft 表清空、`/etc/ferry` 用户数据保留。
- **静态检查**：所有 shell `sh -n`；LuCI JS `node --check`；`menu.d`/`acl.d` JSON 解析；Makefile 安装清单与 `files/` 实际文件 20/20 对齐；伪造 `/etc/apk`、`/etc/opkg` 测包管理器探测；伪 SDK 跑 `build.sh` 验证 ipk/apk 识别与产物收集。
- **仍未验证**：TPROXY/TUN 的真实客户端转发（只用配置与规则断言，没有真实终端跑流量）、ARM/MIPS 架构、sing-box 路径端到端、真实手机/电视等设备接入、上游订阅在真实网络下的下载行为。

## 5. 换机接手步骤

1. 拷贝整个 `luci-app-ferry/` 目录即可；`dist/` 若存在是旧产物，可忽略或删除，不要当验证结果。
2. 准备 SDK：apk 模式一份（OpenWRT main/snapshot，`.config` 含 `CONFIG_USE_APK=y`）、ipk 模式一份（23.05 或 24.10）、ImmortalWrt 一份（23.05/24.10）。各自 `make defconfig` 并装好 luci feed。
3. 编译：
   - `./scripts/build.sh --sdk <SDK> --mode ipk`
   - `./scripts/build.sh --sdk <SDK> --mode apk`（或省略 `--mode` 让它从 `.config` 判断）
4. 产物位置：`dist/ipk/`、`dist/apk/`；SDK 内原始产物在 `bin/packages/<arch>/*/`。安装命令见 README 4.1–4.3。
5. 真机验证顺序：装包 → 执行 `50-ferry` → 启服务看 `/etc/init.d/ferry status`（含 `package_manager`）→ `nft list tables` 看规则 → 路由器本机 DNS → 单台 LAN 设备 → 全 LAN。

## 6. 已知坑

- **apk 约束**：包名必须全小写；`PKG_VERSION` 不能含 `-`；`PKG_RELEASE` 必须纯数字。改版本号时不要写 `1.0.0-beta`。
- **`uci-defaults` 不保证安装当时执行**：装完必须显式跑一次，否则目录/enable 可能要到下次开机才生效。
- **`dnsmasq` vs `dnsmasq-full`**：ImmortalWrt 常预装 full 版，本包不依赖 dnsmasq，找不到 `dhcp.@dnsmasq[0]` 就跳过上游改写。
- **规则缓存 24 小时**：`pm_rule_fresh` 用 86400 秒判断；首次无缓存且下载失败会判定网络不可用并跳过后续分类，只留告警。
- **sing-box 不支持 SSR**：SSR 节点只在 mihomo 出现；切 sing-box 时跳过并写 `status.json` 告警，不导致配置失败。
- **老 CPU 指令集**：x86_64 默认 `amd64` 需要 v3（AVX2）；老 CPU 或 Rosetta 环境用 `amd64-compatible`，否则内核直接拒绝启动。
- **架构与 `PKGARCH:=all` 无关**：包不含内核二进制，x86_64 固件必须配 x86_64 内核文件。

## 7. 待确认事项

| 事项 | 状态 | 当前默认行为 |
| --- | --- | --- |
| apk 分支 `kmod-nft-core/nat/tproxy` 等包名是否与 ipk 分支一致 | 待定 | 按同名硬依赖写；若实际缺失，改 `Makefile` 的 `DEPENDS` 为条件依赖/运行期检测 |
| 目标 x86_64 CPU 是否支持 v3 指令集 | 待定 | 默认下载 `amd64`；老 CPU 手动换 `amd64-compatible` |
| README 兼容性表用“理论可行（静态检查通过，未编译安装）”措辞 | 待定 | 保持该措辞，不写“应该可以” |
| 规则优先级方向（靠前优先 vs 靠后优先） | 已定 | 靠前优先，`rules.lst` 行序即优先级 |
| 旁路由是否要比“只关 auto-route”更保守（例如默认不装 netfilter） | 待定 | 保持现状：只关 TUN auto-route，netfilter 仍处理本机入向 |
| 自备配置/订阅/本地节点的优先级 | 已定 | `config_path` > `sub_url` > 由 `nodes.json` 生成 |
| 档案导出格式 | 已定 | 单个 profile 的 JSON 下载/导入；不导出二进制配置 |
| 节点延迟测试 | 待定（未实现） | 页面不显示延迟，仅保留节点结构；后续可在 LuCI 加探测，不影响生成 |
