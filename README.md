# luci-app-ferry（渡口）

一个 OpenWRT 的 LuCI 应用 + 后台服务，把 **mihomo**（Clash Meta）或 **sing-box** 作为路由器上的透明代理网关：装完包 → 在 LuCI 里填订阅/配置 → 打开开关 → 局域网设备自动走代理，全程不需要手工敲 iptables/nft 规则。

- 两种内核二选一运行（同一时间只跑一个），插件负责生成/适配各自的配置文件。
- 运行方式支持 **TPROXY**（默认，TCP+UDP）、**TUN**、**REDIRECT**（仅 TCP）。
- 接管规则优先 **nftables**（OpenWRT 22.03+ 默认），也提供 **iptables** 兼容路径。
- 规则放在独立 table / 自定义 chain 中，停止或切换时一键清理。
- 面板是**独立可选包** `luci-app-ferry-dashboard`（内嵌只读面板，zashboard 3.22.0 版本锁死）：不装它，主包不监听任何额外端口；装了才多出 9090 的 LAN-only 端点（见 1.1 与 7.8）。

> 已通过离线测试与 QEMU 真机验证（OpenWrt 24.10 / opkg、ImmortalWrt 25.12 / apk 的安装、启动、菜单、卸载、重启自愈；r14 另验证了双包安装、面板启用、只读拦截、sing-box 能力降级与面板卸载计时）；TPROXY 真实转发、ARM 架构、真实手机访问仍未验证，分层清单见第 9 节。

---

## 1. 包结构

```
luci-app-ferry/
├── Makefile                              # feed 风格 OpenWRT 包（rules.mk + package.mk）
├── README.md
├── files/
│   ├── etc/
│   │   ├── config/ferry              # UCI 配置（conffile，升级不覆盖）
│   │   ├── init.d/ferry              # procd 服务脚本
│   │   └── uci-defaults/50-ferry     # 首次安装初始化目录
│   ├── usr/
│   │   ├── lib/ferry/
│   │   │   ├── common.sh                 # 配置读取、日志、status、迁移、dnsmasq 衔接
│   │   │   ├── nodes.sh                  # nodes.lst -> mihomo proxies / sing-box outbounds
│   │   │   ├── rules.sh                  # 分类规则、镜像源、本地缓存、双内核渲染
│   │   │   ├── generate.sh               # mihomo YAML / sing-box JSON 生成
│   │   │   ├── firewall.sh               # nftables / iptables 规则、TPROXY 策略路由
│   │   │   └── uninstall.sh              # 卸载/一键清理（prerm 与手工调用共用）
│   │   └── share/
│   │       ├── luci/menu.d/luci-app-ferry.json
│   │       └── rpcd/acl.d/luci-app-ferry.json
│   └── www/luci-static/resources/
│       ├── ferry/
│       │   ├── links.js                  # 分享链接解析（统一节点结构）
│       │   ├── preset-defs.js            # 分类/预设定义（前端）
│       │   └── store.js                  # nodes.json/profiles.json 读写、编译、激活
│       └── view/ferry/
│           ├── main.js                   # 基础设置（UCI 表单）
│           ├── nodes.js                  # 节点管理
│           ├── rules.js                  # 分流规则
│           ├── presets.js                # 场景预设
│           ├── deploy.js                 # 部署形态
│           └── profiles.js               # 配置档案
├── dashboard/                            # 可选面板包的源码（不编进主包）
│   ├── files/                            # 面板 UCI/服务/命令/前端/rpcd/菜单/ACL
│   ├── patches/zashboard-3.22.0-readonly.patch   # 只读补丁（可复核）
│   └── vendor/zashboard-3.22.0/          # 上游静态资源（版本锁死）
└── scripts/
    ├── fetch-kernel.sh                   # PC 端下载/校验内核二进制（默认 x86_64）
    ├── build.sh                          # 双格式构建（ipk/apk，按 SDK 自动识别）
    └── ci/                               # 双包构建与校验（build-pkgs.sh、stage*.sh、verify-pkgs.sh）
```

安装到设备后的关键路径：

| 内容 | 设备路径 |
| --- | --- |
| UCI 配置 | `/etc/config/ferry` |
| 服务脚本 | `/etc/init.d/ferry` |
| 运行库 | `/usr/lib/ferry/*.sh` |
| 节点库（JSON，与 UCI 分离） | `/etc/ferry/nodes.json` |
| 配置档案（JSON） | `/etc/ferry/profiles.json` |
| 编译产物（shell 直接读取） | `/etc/ferry/nodes.lst`、`rules.lst`、`custom.lst` |
| 生成结果与告警 | `/etc/ferry/status.json` |
| 规则集缓存 | `/etc/ferry/rules-cache/{mihomo,sing-box}/` |
| LuCI 菜单 | `/usr/share/luci/menu.d/luci-app-ferry.json` |
| LuCI 页面 | `/www/luci-static/resources/view/ferry/*.js` |
| mihomo 配置 | `/etc/mihomo/config.yaml`（自动生成） |
| sing-box 配置 | `/etc/sing-box/config.json`（自动生成或下载） |
| 运行期临时文件 | `/var/etc/ferry/`（nft 规则文件、生成中间产物） |
| dnsmasq 上游备份 | `/etc/ferry/dnsmasq-backup/`（持久化，重启后仍可恢复原始上游） |
| 面板 UCI（仅面板包） | `/etc/config/ferry-dashboard`（conffile） |
| 面板命令与运行库（仅面板包） | `/usr/bin/ferry-panel`、`/usr/lib/ferry/panel.sh`、`/usr/libexec/rpcd/luci-ferry-panel` |
| 面板 secret（仅面板包） | `/etc/ferry/panel.secret`（0600，仅注入内核配置，不落 www 静态文件） |
| 面板静态资源（仅面板包） | `/www/luci-static/ferry-dashboard/`（zashboard 3.22.0 + 只读 shim） |

### 1.1 双包结构（r14 起）

主包与面板包分开编译、分开安装，`dashboard/` 只由面板包引用，主包的 `install` 段不包含其中任何文件。

| 包 | 内容 | 依赖 | r14 资产大小 |
| --- | --- | --- | --- |
| `luci-app-ferry`（主包） | 服务/生成器/规则/内核管理 + 6 个 LuCI 页面 | 见 3.3（`luci-base`、`rpcd`、nftables 相关等） | ipk 119,098 B / apk 119,190 B |
| `luci-app-ferry-dashboard`（可选面板包） | 面板后端（`panel.sh`/`ferry-panel`/rpcd）+ zashboard 3.22.0 + 只读 shim + 1 个「面板」页 | `+luci-app-ferry +luci-base` | ipk 2,932,511 B / apk 2,931,951 B |

- 顺序：**先装主包，再装面板包**；卸载时**先卸面板包，再卸主包**（卸主包不会执行面板包的 prerm，会留下失效的面板 UCI/静态文件）。
- 面板包未安装时：主包不会创建 `/etc/ferry/panel.secret`、不加载 `ip ferry_panel` 表、不监听 9090，也没有「面板」菜单项。

LuCI 入口：**服务（Services） → Ferry**，即 `admin/services/ferry`。主包提供 6 个页面；装面板包后多一个「面板」页（共 7 个）：

| 页面 | 作用 |
| --- | --- |
| Ferry（基础设置） | 内核、模式、端口、DNS、订阅、绕过 |
| 节点管理 | 分享链接批量导入、手工增删改、启用/禁用、排序、重命名 |
| 分流规则 | 分类目标策略、顺序、自定义域名/网段、规则镜像源 |
| 场景预设 | 7 个一键预设 |
| 部署形态 | 主路由 / 旁路由 / 客户端，接入说明与配置下载 |
| 配置档案 | 多套配置的增删改、复制、导入导出、激活切换 |
| 面板（仅面板包） | 面板启用/禁用/轮换密钥、监听地址与 secret 状态、能力探测表、新窗口或页内 iframe 打开 |

---

## 2. 设计假设

实现时做了以下取舍，不需要用户额外配置即可工作；如与你的环境不符可再调整：

1. **默认 TPROXY + mihomo + 7890 端口 + 1053 DNS 端口。** TPROXY 能同时接管 TCP/UDP，且不需要创建虚拟网卡，是路由器网关场景的首选。
2. **只接管 LAN 转发流量**，不接管路由器自身出口流量（除 DNS 之外）。路由器自身走代理请让应用显式使用 `mixed_port`。
3. **DNS 由内核统一处理**：
   - mihomo：使用内置 `dns.listen`（默认 `dns_port`），局域网 53 和路由器 dnsmasq 上游都指向它。
   - sing-box 非 TUN：生成一个 `"type":"direct"` 的 `dns-in` inbound，监听 `dns_port`；它同时接收局域网 53 的 REDIRECT 和路由器 dnsmasq 发到 `127.0.0.1#dns_port` 的查询。
   - sing-box TUN：没有单独监听端口，由 tun 的 `auto_route` 接管流量，配置里的 `{"protocol":"dns","action":"hijack-dns"}` 把 DNS 交给 sing-box DNS 模块。
   - 因此两种内核在 TPROXY/redirect/TUN 下都能做到「局域网 DNS + 路由器自身 DNS」走内核，而不是只劫持客户端、路由器自己直连。
4. **默认不改动 dnsmasq 的监听地址**，只改上游；LAN 客户端仍然可以正常使用路由器的 53 端口。
5. **订阅格式**：mihomo 走 `proxy-providers`（要求 Clash/mihomo 格式 YAML）；sing-box 没有等价的远程 outbound provider 机制，订阅 URL 必须直接返回完整的 sing-box JSON 配置，格式转换请在外部（如 subconverter）完成。
6. **内核二进制不随包下发**，由用户安装/放置；插件只负责检查、生成配置和托管进程（见第 6 节）。
7. **TPROXY 使用 fwmark=1 + 路由表 100**（`ip rule` + `local default dev lo`），这是 Linux TPROXY 的标准做法；如你的设备已被 mwan3 等工具占用该表，可改 `PM_IP_MARK`/`PM_IP_ROUTE_TABLE`。
8. **IPv6 默认开启**：nftables 后端同时下发 `ip` / `ip6` 两张表；开启 IPv6 时，内核 DNS / sing-box inbound 监听 `[::]`，同时接受 IPv4（依赖内核 `bindv6only=0`，OpenWRT 默认如此）。iptables 后端只处理 IPv4；TUN 模式生成的是 IPv4 tun 地址，IPv6 全局接管以 TPROXY/redirect 为准。
9. **生成的 sing-box 骨架面向 1.12+**（使用新版 DNS server 格式、`route.default_domain_resolver`、`action: hijack-dns`）。如果你在 1.10/1.11 上使用，请用 `config_path` 指定自己适配好的完整配置，插件只负责拉起进程和接管流量。
10. **节点与档案不进 UCI**：节点列表和 profile 存 JSON（`/etc/ferry/*.json`），避免 UCI 里塞长 base64/特殊字符；UCI 只保留「当前生效的标量运行参数」。前端同时把 JSON 编译成 `nodes.lst` / `rules.lst` / `custom.lst` 三个平面文件，shell 侧只做字符串拼接，不依赖 `jq`/`jsonfilter`。
11. **profile 与 UCI 是「快照 + 回写」关系**：激活或保存 profile 时把标量字段回写 UCI 并 `uci.save()`，因此老的 UCI 页面/命令行设置仍然有效；在规则页/部署页保存前会先用当前 UCI 刷新快照，避免把基础设置页刚改过的值回退。节点/规则/预设只从 JSON 走。
12. **分流规则语义是 first-match**：`rules.lst` 的行序即优先级，越靠前越优先，命中即停；「自定义域名/网段」按它在分类列表中的位置插入，不做额外排序。
13. **sing-box 不支持 SSR**：SSR 节点只会出现在 mihomo 的 `proxies` 里；切到 sing-box 时跳过该节点并在 `status.json` 记一条告警，不会导致配置失败。
14. **镜像源用「主源 + 备用源 + 本地缓存」三级回退**：所有规则集下载失败时保留旧缓存；无缓存则跳过该分类并告警。内核配置里只引用本地文件，不依赖启动时联网（`rule_update=1` 时才会尝试更新）。
15. **旁路由不改本机转发链**：`deploy=bypass` 时 TUN 的 `auto_route` 固定为 `false`，nft/iptables 仍只处理「本机收到的报文」，不额外插入上游 LAN 劫持；dnsmasq 上游是否改写仍由 `router_dns` 决定（旁路由通常保持开启）。`deploy=client` 时完全不加载 netfilter 规则，只保留 mixed 端口。
16. **面板独立可选包，不塞进主包**：`luci-app-ferry-dashboard` 的 `DEPENDS:=+luci-app-ferry +luci-base`，主包不反向依赖它；16 MB flash 的设备只装主包即可。
17. **面板版本锁死 zashboard 3.22.0**：上游 3.23.0 起移除 sing-box 支持，跟随升级会让只读补丁与 sing-box 端点失效，因此禁止跟随升级；确需升级时必须重新核对面板用到的端点（`/version`、`/proxies`、`PUT /proxies/{group}`、`/configs`、`/rules`、`/restart`、`/upgrade`、WS `/traffic`、`/logs` 等），清单见 `docs/dashboard-proposal.md` §13。只读约束由 `dashboard/patches/zashboard-3.22.0-readonly.patch` + 运行期 shim `ferry-readonly.js` 双重保证：`fetch`/`WebSocket` 只放行 GET 与 `PUT /proxies/{group}`，其余写方法（如 `PUT /configs`）在浏览器侧返回 403。
18. **面板只绑 LAN，secret 随机且 0600**：监听地址取 LAN 接口的 IPv4 地址（不是 `0.0.0.0`），可用 `ferry-dashboard.main.bind` 手工指定；secret 由 `/dev/urandom` 生成 32 位 hex（无 `md5sum` 时走兜底路径），存 `/etc/ferry/panel.secret` 且权限 0600，只注入内核配置，不进 UCI、不落 www 静态文件。防火墙用独立表 `ip ferry_panel`，只放行 LAN 接口/LAN 网段与 `lo`，其余来源对该端口明确 drop。
19. **同一端口只允许一个内核**：mihomo 与 sing-box 同时监听面板端口必然 `EADDRINUSE`，所以同一时刻只允许一个内核运行；面板状态里的 `conflict.both` 会提示「两个内核同时在运行」。
20. **卸载面板包回到原状**：停面板规则 → 从两个内核的生成配置里剥离注入（mihomo `external-controller`/`secret`、sing-box `experimental.clash_api`）→ 删 secret/UCI/静态资源/licenses → 重启内核释放端口；`opkg remove` 返回时端口已释放（见 4.7 与 9.3）。

### 2.1 轮询与资源代价（r14）

r14 为降低空闲开销调慢了三处轮询，代价一并列出，避免误判为「页面卡住」：

| 调整 | 位置 | 代价 |
| --- | --- | --- |
| 安全页空闲轮询 1 s → 10 s（有 pending 时仍 1 s） | `view/ferry/safety.js` | 别的标签页/SSH 新建的 pending 在本页最晚 10 秒出现（本页自身保存会整页刷新，不受影响） |
| 安装/升级进度轮询 1 s → 2 s | `view/ferry/kernel.js` | 进度刷新变粗（最长 2 秒一跳）；任务仍按后端真实状态推进 |
| 进度轮询加 30 分钟上限 | `view/ferry/kernel.js` | 超过 30 分钟的任务会停止自动刷新，需要手动刷新页面才继续看进度（后端任务本身继续执行） |

---

## 3. 编译

同一份源码要能在 **opkg/ipk** 与 **apk** 两种 buildroot 下编出包。区别只发生在 `package.mk` 的打包阶段，`Makefile` 本身不需要分支。

### 3.1 一键构建（推荐）：`scripts/build.sh`

```sh
# opkg/ipk：OpenWRT 23.05 / 24.10、ImmortalWrt 23.05 / 24.10
./scripts/build.sh --sdk ~/sdk/openwrt-24.10 --mode ipk

# apk：OpenWRT main / snapshot（.config 里 CONFIG_USE_APK=y）
./scripts/build.sh --sdk ~/sdk/openwrt-main --mode apk
# 不带 --mode 时，脚本从 $SDK/.config 的 CONFIG_USE_APK 自动识别
```

脚本流程：把源码复制到 `$SDK/package/luci-app-ferry` → `make package/luci-app-ferry/compile V=s` → 从 `bin/packages/*/*/` 收集 `.ipk` 或 `.apk` → 落到 `dist/ipk/` 或 `dist/apk/`，并打印 sha256 与对应安装命令。SDK 需先 `make defconfig`，并确认 luci feed 已 `./scripts/feeds install -a`。

### 3.2 手工编译（feed 方式）

```sh
mkdir -p feeds/ferry
cp -r luci-app-ferry feeds/ferry/
echo "src-link ferry $(pwd)/feeds/ferry" >> feeds.conf
./scripts/feeds update -a && ./scripts/feeds install luci-app-ferry
make package/luci-app-ferry/compile V=s
```

- opkg 分支产物：`bin/packages/<arch>/luci/luci-app-ferry_1.0.0-r14_all.ipk`
- apk 分支产物：同名源码编出 `.apk`，版本串为 `1.0.0-r14`（`PKG_RELEASE` 被 apk 拼成 `-r2`）

### 3.3 依赖与各分支包名

`Makefile` 里声明的依赖：

```
+luci-base +rpcd
+nftables +kmod-nft-core +kmod-nft-nat +kmod-nft-tproxy
+kmod-tun +ip-full +uclient-fetch +ca-bundle
```

| 作用 | OpenWRT apk 分支 | OpenWRT 23.05/24.10、ImmortalWrt | 备注 |
| --- | --- | --- | --- |
| LuCI 基础 | `luci-base` | `luci-base` | 同名 |
| rpcd 权限 | `rpcd` | `rpcd` | 同名 |
| nftables | `nftables` | `nftables` | 同名 |
| nft 内核模块 | `kmod-nft-core`、`kmod-nft-nat`、`kmod-nft-tproxy` | 同名 | 均为硬依赖；apk feed 中未逐项在线核对 |
| TUN | `kmod-tun` | `kmod-tun` | 同名 |
| 策略路由 | `ip-full` | `ip-full` | 同名，会替换 `ip-tiny` |
| 下载 | `uclient-fetch` + `ca-bundle` | 同名 | 同名 |
| iptables 兼容栈 | 常见只有 `iptables-nft` / `iptables-legacy`，`iptables-mod-tproxy` 不保证存在 | `iptables`、`iptables-mod-tproxy`、`iptables-mod-extra`、`kmod-ipt-core`、`kmod-ipt-nat` | **不做硬依赖**；缺模块时运行期回退 nft |

`PKGARCH:=all` 只代表**包内容**（shell/JS/UCI）与 CPU 架构无关，不代表内置内核二进制与架构无关——本包不内置内核。

> **TPROXY 内核模块**：`kmod-nft-tproxy` 在部分固件（如官方 x86_64）不在默认 feeds 里，
> 而在 `.../targets/x86/64/kmods/<kernel-version>/` 目录下。缺模块时 `ferry` 会拒绝安装
> 接管规则并保持局域网直连，日志明确报「缺少内核模块 kmod-nft-tproxy」。手工补装：
>
> ```sh
> echo "src/gz openwrt_kmods https://downloads.openwrt.org/releases/<ver>/targets/x86/64/kmods/<6.x.y-1-hash>" \
>   >> /etc/opkg/customfeeds.cfg
> opkg update && opkg install kmod-nft-tproxy
> ```

### 3.4 apk 的命名约束（已写进 Makefile 注释）

- `PKG_NAME` 必须全小写、只含 `[a-z0-9.+_-]`，所以是 `luci-app-ferry`。
- `PKG_VERSION` 不能含 `-`（`1.0.0-beta` 会被当成 revision 分隔符），保持 `1.0.0`。
- `PKG_RELEASE` 必须是纯数字，apk 会拼成 `-r1`。

### 3.5 双包构建与产物校验（`scripts/ci/`）

不走 SDK 时，CI/本地可以用这一组脚本直接产出并校验四个包：

| 脚本 | 作用 |
| --- | --- |
| `ci/build-pkgs.sh` | 构建主包 + 面板包的 ipk/apk，产物落到 `$DIST`，并写 `build-meta.txt`（`IPK`/`APK`/`DASH_IPK`/`DASH_APK`） |
| `ci/stage.sh`、`ci/stage-dashboard.sh` | 生成两个包的期望安装树（用于逐文件比对） |
| `ci/verify-pkgs.sh [dist_dir]` | **同时校验两个包**：版本与依赖、文件数量、包内文件与源码树 `diff -r` 全等、apk 属主 `root`、无 0777、conffiles 登记、文件清单；面板包额外断言依赖 `luci-app-ferry` |
| `ci/post-install-dashboard.sh`、`ci/pre-deinstall-dashboard.sh` | QEMU 里安装/卸载面板包时的辅助脚本 |

r14 实测：主包 39 个文件、面板包 51 个文件（面板后端 10 + zashboard vendor 41），双格式四包全部通过。

---


## 4. 安装

以 **x86_64 固件**（软路由、虚拟机、多数云主机）为主线；包名以实际产物为准：ipk 是 `luci-app-ferry_1.0.0-r14_all.ipk`，apk 是 `luci-app-ferry-1.0.0-r14.apk`（以 `ls dist/apk` 为准）。三条分支的命令都是“上传 → 装包 → 跑一次 uci-defaults → 打开开关”。

### 4.1 OpenWRT apk 分支（main / snapshot）

```sh
# PC 端
scp dist/apk/luci-app-ferry-*.apk root@192.168.1.1:/tmp/

# 路由器
apk add --allow-untrusted /tmp/luci-app-ferry-*.apk
# 已把公钥放进 /etc/apk/keys 后可以去掉 --allow-untrusted
sh /etc/uci-defaults/50-ferry
uci set ferry.main.enabled='1'
uci commit ferry
/etc/init.d/ferry restart
```

### 4.2 OpenWRT opkg 分支（23.05 / 24.10）

```sh
# PC 端
scp dist/ipk/luci-app-ferry_1.0.0-r14_all.ipk root@192.168.1.1:/tmp/

# 路由器
opkg update
opkg install /tmp/luci-app-ferry_1.0.0-r14_all.ipk
sh /etc/uci-defaults/50-ferry
uci set ferry.main.enabled='1'
uci commit ferry
/etc/init.d/ferry restart
```

### 4.3 ImmortalWrt（23.05 / 24.10）

包格式仍是 ipk，命令与 4.2 完全一致：

```sh
scp dist/ipk/luci-app-ferry_1.0.0-r14_all.ipk root@192.168.1.1:/tmp/
opkg update
opkg install /tmp/luci-app-ferry_1.0.0-r14_all.ipk
sh /etc/uci-defaults/50-ferry
uci set ferry.main.enabled='1' && uci commit ferry
/etc/init.d/ferry restart
```

差异集中在固件侧（见 4.5 与第 9 节）：ImmortalWrt 通常预装 `dnsmasq-full`（与 `dnsmasq` 互斥，勿重复装）；LuCI 23.05 的控件比 24.10 少，页面已做降级；`nftables` 是默认后端。

### 4.3.1 可选：安装面板包（`luci-app-ferry-dashboard`）

面板是独立包，装完还需要显式启用（默认 `enabled=0`，装包本身不会注入内核配置）：

```sh
# opkg 分支
opkg install /tmp/luci-app-ferry-dashboard_1.0.0-r14_all.ipk
/usr/bin/ferry-panel enable        # 生成 secret、注入内核、重启一次内核
/usr/bin/ferry-panel status        # enabled/injected/running/reason=ready

# apk 分支
apk add --allow-untrusted /tmp/luci-app-ferry-dashboard-1.0.0-r14.apk
/usr/bin/ferry-panel enable
```

也可以在 LuCI「服务 → Ferry → 面板」里点「启用面板」，效果相同。启用后仅在 LAN 地址监听 `9090`（可用 `uci set ferry-dashboard.main.port` / `.bind` 调整），不要把它暴露到 WAN。

### 4.4 apk 签名

apk 默认校验签名。本地包有两条路：

```sh
# 路径 A：一次性放行（最省事，推荐自用）
apk add --allow-untrusted /tmp/luci-app-ferry-*.apk

# 路径 B：注入公钥后正常安装
# PC 上生成密钥（密钥名决定 /etc/apk/keys 下的文件名）
openssl genrsa -out ferry.rsa 2048
openssl rsa -in ferry.rsa -pubout -out ferry.rsa.pub
# 在 Alpine 容器里用 abuild-sign 签名包（需 abuild 工具链）
abuild-sign -k ferry.rsa luci-app-ferry-*.apk
scp ferry.rsa.pub root@192.168.1.1:/etc/apk/keys/
apk add /tmp/luci-app-ferry-*.apk
```

官方 SDK 编出的包只有在 SDK 配置了签名密钥时才带可信签名；未配置时按路径 A 安装。路径 B 的公钥命名与 `abuild-sign` 细节需在真机确认。

### 4.5 兼容性表

“理论可行”= Makefile/依赖/落位已做静态核对，但未在对应 SDK 实际编译或真机安装；“已验证”= 有真实产物/真机结果；“未验证”= 缺少核对依据。

| 固件分支 | 包格式 | 预期状态 |
| --- | --- | --- |
| OpenWRT main / snapshot（`CONFIG_USE_APK=y`） | apk | 部分验证（ImmortalWrt 25.12.0 / apk-tools 3.0.5 上完成装/卸/重启） |
| OpenWRT 24.10.x | ipk | 已验证（QEMU 真机：OpenWrt 24.10.4 x86_64） |
| OpenWRT 23.05.x | ipk | 理论可行（固件/包管理器机制同上，未单独跑） |
| ImmortalWrt 24.10 | ipk | 理论可行（未单独跑；25.12 的 apk 分支已验证） |
| ImmortalWrt 25.12 | apk | 已验证（QEMU 真机：25.12.0 x86_64，apk-tools 3.0.5） |
| 任一分支的 TPROXY/TUN 实际接管 | — | 未验证（需真实客户端流量） |

> `uci-defaults` 在安装后不保证立即执行（通常随下一次开机）。上面的 `sh /etc/uci-defaults/50-ferry` 是显式兜底：建目录、`enable` 服务、清 LuCI 索引；脚本本身不写 `nodes.json`/`profiles.json`，不会覆盖已有配置。

### 4.6 ImmortalWrt 差异化处理清单

| 差异点 | 影响 | 代码/文档处理 |
| --- | --- | --- |
| `dnsmasq` vs `dnsmasq-full` | ImmortalWrt 常预装 `dnsmasq-full`，与 `dnsmasq` 互斥；硬装会冲突 | 不声明 dnsmasq 依赖；`pm_dnsmasq_apply` 只检查 `/etc/config/dhcp` 和 `dhcp.@dnsmasq[0]`，找不到就跳过，不改上游 |
| LuCI 23.05 vs 24.10 | 老版本缺少部分 `ui.*` API，页面可能整页报错 | `ui.addNotification` 全部先判类型；`ui.showModal` 在节点/档案页包了 `openModal` 降级为内联区块；`form.DynamicList` 两边都有 |
| 默认防火墙后端 | ImmortalWrt 23.05/24.10 默认 `firewall4` + nftables；部分老配置仍用 iptables | `firewall_backend=auto` 先探测 nft 表和 `nft` 命令，失败再试 iptables，两者都不可用时保持直连并告警 |
| rpcd ACL 路径 | `/usr/share/rpcd/acl.d/*.json` 两代相同 | 沿用该路径；ACL 只声明 `uci`/`file`/`ubus service reload`，不依赖新 schema |
| `uci-defaults` 机制 | 与 OpenWRT 相同：首次开机执行，安装当时不一定执行 | 初始化不依赖 postinst；卸载清理依赖 prerm（见 4.7）。README 安装步骤显式执行一次 `50-ferry` |
| 内核版本 | 23.05 为 5.15，24.10 为 6.6；`kmod-*` 必须与固件内核匹配 | 依赖由 opkg 自动匹配；`kmod-nft-tproxy` 缺失时 nft TPROXY 规则加载失败 → 回退 iptables 或改用 `redirect`/客户端形态 |
| mihomo/sing-box 版本 | 旧固件可能配了不兼容的新内核配置 | 生成面向 mihomo 1.19 / sing-box 1.12+；失败点在内核 `-t`/`check` 或启动即退出，绕过方式：LuCI 填 `config_path` 自备配置，或 `bin_path` 指向自备二进制 |
| 软件包命名 | `iptables-mod-tproxy` 等在部分分支不存在 | 不做硬依赖；用户显式选 iptables 后端时自行安装，缺包不影响本包安装 |

### 4.7 卸载与清理

卸载不是“删包”就完事：本包在运行期改写了 dnsmasq 上游、装了 nftables/iptables 规则与 TPROXY 策略路由、并由 procd 托管内核进程。只删包不清理会留下：dnsmasq 仍指向 `127.0.0.1#1053`（内核已被停掉 → DNS 不通）、残留规则表、残留策略路由。

#### 包管理器脚本机制（已核对，非推测）

| 包管理器 | Makefile 字段 | 包内脚本名 | 执行时机 |
| --- | --- | --- | --- |
| opkg / ipk（23.05、24.10、ImmortalWrt） | `Package/prerm`、`Package/postrm` | `CONTROL/prerm`、`CONTROL/postrm` | 卸载前 / 卸载后；**升级时 prerm 也会执行，第一个参数是 `upgrade`** |
| apk（OpenWrt main / snapshot） | `Package/prerm`、`Package/postrm` | `pre-deinstall`、`post-deinstall` | `apk del` 之前 / 之后；升级走 `pre-upgrade`/`post-upgrade`，**不会**触发 deinstall 脚本 |

核对依据：

- OpenWrt main 的 `include/package-pack.mk` 把 `Package/prerm` 的脚本内容写成包内脚本，并在 `APK_SCRIPTS` 里登记为 `pre-deinstall`（`Package/postrm` 登记为 `post-deinstall`）。来源：[package-pack.mk](https://git.openwrt.org/openwrt/openwrt/plain/include/package-pack.mk)
- Alpine 的 `APKBUILD` 文档说明 `$pkgname.pre-deinstall` 在卸载前执行，脚本失败会让 `apk` 拒绝卸载；`$pkgname.post-deinstall` 在卸载后执行。来源：[APKBUILD Reference](https://wiki.alpinelinux.org/wiki/APKBUILD_Reference)
- apk 会把已安装包的脚本集中放在 `/lib/apk/db/scripts.tar`，OpenWrt 相关提交确认该机制在 apk 分支上有效。来源：[openwrt 提交](https://lists.infradead.org/pipermail/lede-commits/2025-November/028032.html)

因此 `Makefile` 里写的是 `Package/luci-app-ferry/prerm`，脚本对 opkg 的 `upgrade` 参数直接退出（升级不该停服务），其余情况调用 `/usr/lib/ferry/uninstall.sh`。

> 已在 ImmortalWrt 25.12.0 的 QEMU 真机上实测：`apk del luci-app-ferry` 确实执行 `pre-deinstall`（在包内 uninstall.sh 插入标记文件后卸载，标记被写出），且服务退出、nft 表清空、dnsmasq 上游还原。

#### 卸载步骤

```sh
# apk 分支
apk del luci-app-ferry

# opkg 分支
opkg remove luci-app-ferry
```

prerm 会调用 `/usr/lib/ferry/uninstall.sh`，它按顺序做四件事：

1. `stop` + `disable` 服务（procd 停掉内核进程，取消开机自启）；
2. 清 nftables 表（`ip/ip6 ferry`）与 iptables 链（`PM_DNS`/`PM_REDIR`/`PM_TPROXY`/`PM_QUIC`）；
3. 清 TPROXY 的 `ip rule` / `ip route`（v4 与 v6）；
4. 用持久化备份还原 dnsmasq 上游。

全过程幂等，并且总是 `exit 0`：清理失败不会把包卡在“无法卸载”的状态。

#### 面板包（可选）的卸载

顺序是**先卸面板包，再卸主包**：`opkg remove luci-app-ferry-dashboard`（apk 分支 `apk del luci-app-ferry-dashboard`）。面板包的 prerm 会调用 `/usr/bin/ferry-panel cleanup`，依次：

1. 删 `ip ferry_panel` 表、停 `ferry-panel` 服务；
2. 从两个内核的生成配置里剥离注入（mihomo 删 `external-controller`/`secret`，sing-box 删 `experimental.clash_api` 整块）；
3. 删 `/etc/config/ferry-dashboard`、`/etc/ferry/panel.secret`、面板状态目录、`/www/luci-static/ferry-dashboard/`、`/usr/share/licenses/luci-app-ferry-dashboard/`，清 LuCI 索引缓存；
4. 等 apply 标记消失，再等面板端口真正释放（每次最多 20 秒）。

实测（OpenWrt 24.10.5 / QEMU，mihomo 内核，`/proc/uptime` 计时）：`opkg remove` 返回 0，耗时 **5.46 s**；**返回瞬间 9090 已无监听**（+1 s、+31 s 复核仍为 0）。随后主包的异步 reload 会把 mihomo 重新拉起，但配置里已没有 `external-controller`，端口保持释放。

| 卸载后面板相关内容 | 结果 |
| --- | --- |
| `ferry-dashboard` UCI、`/etc/ferry/panel.secret` | 删除 |
| `/www/luci-static/ferry-dashboard/`、licenses、`/usr/lib/ferry/panel.sh`、`/usr/bin/ferry-panel` | 随包删除 |
| `ip ferry_panel` 表、rc.d 中的 `K11ferry-panel`/`S98ferry-panel` | 清理/撤销 |
| 两内核配置中的面板注入 | 0 处（mihomo 与 sing-box 都还原为不含面板端点的生成结果） |
| 主包的 `ferry`/`ferry6` 表、dnsmasq 上游、节点/profile | 不受影响，保持原状 |

> 卸载时 opkg 可能打印 `file_sha256sum_alloc: Failed to open file /etc/config/ferry-dashboard` / `Not deleting modified conffile`：这是 prerm 已主动删掉该 conffile 导致的噪声，卸载结果正常。

#### 包已删 / 脚本没跑时的兜底

```sh
sh /usr/lib/ferry/uninstall.sh            # 保留节点/profile
sh /usr/lib/ferry/uninstall.sh --purge    # 连同用户数据一起删
```

脚本不依赖包内其它文件：包文件还在时复用 `common.sh`/`firewall.sh`（与启动路径同一套清理逻辑）；包文件已不在时退回内置的最小清理实现，手工执行仍有效。

#### 卸载后哪些数据保留

| 内容 | 普通卸载 | `--purge` |
| --- | --- | --- |
| `/etc/ferry/nodes.json`、`profiles.json`、`active` | 保留 | 删除 |
| `/etc/ferry/rules-cache/`、`status.json`、`dnsmasq-backup/` | 保留（下次安装时若 dnsmasq 已是干净配置会自动刷新备份） | 删除 |
| `/etc/config/ferry` | 保留（conffile，由包管理器处理） | 保留 |
| `/etc/mihomo/config.yaml`、`/etc/sing-box/config.json` | 保留（可能是用户自备配置，脚本不删） | 保留 |
| `/var/etc/ferry/` | 删除 | 删除 |

### 4.8 升级系统（sysupgrade / attended sysupgrade）与 ferry

ferry 不在 OpenWrt 官方源里，这会影响两种升级路径。下面结论全部来自 headless QEMU 实测
（24.10.4 x86_64、25.12.0 x86_64），不是推断。

#### 两种路径的真实行为（实测）

| 路径 | 24.10.4（opkg + owut） | 25.12.0（apk-tools 3.0.2 + owut） |
| --- | --- | --- |
| attended sysupgrade（ASU，LuCI「保留配置重建」同源） | HTTP 500，`Error: Impossible package selection: missing (luci-app-ferry)` | 同一条 500，错误文本一致 |
| 错误来源 | **服务端包索引**找不到 `luci-app-ferry`（不是本地依赖校验，也不是签名问题） | 同左 |
| 普通 `sysupgrade` 刷下载好的镜像 | 能正常完成；未登记 keep.d 时 ferry 的包文件和 `/etc/config/ferry` 全部丢失 | 同左（`apk` 分支同样按白名单备份） |

- 24.10.4 **没有** `auc`（该分支 ASU 客户端是 `owut`，`opkg install owut` 还会被签名检查拦住）；
  用户原假设的「24.10 = apk 时代」不成立，apk 从 25.x 才开始（本报告按实测纠正）。
- ASU 请求体带 `repositories` / `repository_keys` / `repositories_mode: replace`，说明 **API 层支持
  自定义源与公钥**；但公共服务器 `sysupgrade.openwrt.org` 不接受我们的自签名 feed 参与构建
  （没有公共可达的签名 feed 可做端到端验证）。因此**不能**指望 ASU 直接构建出带 ferry 的镜像。
- 结论：ASU 路径必须「先移除 ferry 再升级」，升级完成后由首启自愈自动装回；普通 sysupgrade
  路径同样走这套。

#### 刷机前要做什么（一条命令）

```sh
ferry-sysupgrade prep            # 等价于：snapshot + 写 keep.d + 打包离线安装件
ferry-sysupgrade verify          # 升级前自检：快照字段逐项可读
```

`prep` 依次做四件事：

1. 导出配置快照到 `/etc/ferry/snapshot`（节点、规则、profile、源、端口、内核清单、订阅相关 UCI 字段）；
2. 写 `/lib/upgrade/keep.d/ferry`（**有序清单**，顺序决定备份顺序，截断时先丢后面的）：

   ```
   /etc/uci-defaults/60-ferry-selfheal   # 首启自愈钩子（最先，最重要）
   /etc/ferry/offline                    # 安装包本体 + payload + install-payload.sh
   /etc/ferry/snapshot                   # 配置快照
   /etc/config/ferry                     # UCI 配置
   /etc/ferry                            # 其余数据（含 kernels/，放最后）
   ```

3. 把安装包（`.ipk` / `.apk`，自动从 `/tmp`、`/root` 找）与 `payload.tar.gz` 落到
   `/etc/ferry/offline`，并生成不依赖网络的 `install-payload.sh`；
4. 预检备份体积：x86 上备份包写在**分区 1 `/boot`（约 15.7 MB）**，超出会被截断 →
   直接打印 `PREP WARN 备份压缩后约 N KB，超过 /boot 可用 M KB`。

`prep` 打印的 `PREP WARN` 必须处理：把 `kernel_dir` 改到外置盘（见 6.3），再重新 `prep`。

#### 升级后会发生什么

1. 新固件首启执行 `/etc/uci-defaults/60-ferry-selfheal`；
2. 检测包是否已安装：已装 → 直接跳过；未装 → 从 `/etc/ferry/offline` **离线**安装
   （`opkg install` / `opkg install --force-depends`、`apk add --allow-untrusted`，
   都没有时用 `payload.tar.gz` + `install-payload.sh` 兜底，不访问网络与官方源）；
3. 按 `/etc/config/ferry` 的 `kernel_dir` 恢复内核目录：外置盘缺失挂载时，按 `/etc/config/fstab`
   直接 `mount -t $fstype $device $target`（不依赖新固件是否带 `block-mount`）；
4. 从快照恢复配置并 `enable` + `start` 服务；
5. 自愈脚本执行完自动删除，避免每次开机重跑（下次 `prep` 会重建）。

升级后核对：

```sh
ferry-sysupgrade verify          # 逐字段比对，输出 PASS/FAIL/WARN 计数
ferry-sysupgrade verify --json   # {"ok":true,"pass":35,"fail":0,"warn":0,"total":35}
ferry-sysupgrade restore         # 需要一键恢复时（幂等）
```

LuCI 侧同一入口在「服务 → Ferry → 升级与恢复」页（`status` / 快照导出 / 一键恢复）。

#### 不要让 ferry 卡住系统升级

- 本包**从不改写** `/etc/opkg/*.conf` 或 `/etc/apk/repositories`：安装 ferry 不会把官方源换成自建源，
  因此不会出现「源被改掉 → `opkg update` / `apk update` 失败 → 系统升级卡住」。
- 依赖不硬绑：`kmod-nft-tproxy` 等只在运行期按需检测，缺包不影响安装，也不阻塞包管理器事务。
- 升级前想彻底移除而不丢数据：

  ```sh
  ferry-sysupgrade remove      # 卸载包（保留 /etc/config/ferry 与 kernel_dir 数据）
  opkg remove luci-app-ferry   # 等价的纯包管理器操作；prerm 会 stop/清规则，但不删配置
  ```

  卸载脚本只清运行期副作用（服务、nft 表、策略路由、dnsmasq 上游），`/etc/config/ferry`、
  `/etc/ferry/nodes.json`、profiles、快照、外置内核目录都保留。

#### x86 的硬限制（实测）

- `/lib/upgrade/platform.sh` 的 `platform_copy_config()` 把备份写到分区 1 `/boot`（15.7 MB）；
- 62 MB mihomo 内核参与备份时：先 `tar: unexpected end of file`，恢复出的 mihomo 只有
  `25,308,160 / 62,079,102` 字节，且 snapshot/offline/selfheal 钩子全部丢失；
- 所以 x86 上**内置内核目录无法在 sysupgrade 中保留**，必须把 `kernel_dir` 指到外置分区
  （`external`，独立分区，升级不需要 keep.d）。

---

## 5. LuCI 配置与 UCI 字段

页面：`服务 → Ferry`。保存并应用后，LuCI 会提交 UCI 并触发 `/etc/init.d/ferry reload`（`procd_add_reload_trigger "ferry"`），实现「保存即生效」。

| UCI 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `0` | 总开关；关闭时停止内核并清理规则 |
| `kernel` | `mihomo` | `mihomo` / `singbox` |
| `mode` | `tproxy` | `tproxy` / `tun` / `redirect` |
| `proxy_port` | `7890` | 透明代理端口（tproxy-port / redir-port / inbound 端口） |
| `mixed_port` | `7891` | HTTP+SOCKS5 混合端口，`0` 关闭 |
| `dns_port` | `1053` | 内核 DNS 监听端口 |
| `hijack_dns` | `1` | 是否劫持局域网 53 |
| `router_dns` | `1` | 是否改写 dnsmasq 上游（仅 mihomo） |
| `dns_mode` | `fake-ip` | mihomo DNS 增强模式 |
| `sub_url` | 空 | 订阅 URL（格式见设计假设） |
| `config_path` | 空 | 自备配置文件路径，优先级最高；放在 `/etc/ferry/config/` 或 `/etc/mihomo/`、`/etc/sing-box/` 下时 LuCI 可直接预览（见 5.6） |
| `bin_path` | 空 | 内核二进制路径，留空自动探测 |
| `log_level` | `info` | `silent/error/warning/info/debug` |
| `lan_iface` | 空 | 局域网接口，留空从 `network.lan` 推断 |
| `bypass_cidr` | `192.168.0.0/16` | 绕过网段（list，可多条） |
| `bypass_ip` | 空 | 绕过目标 IP（list，可多条） |
| `enable_ipv6` | `1` | nftables 后端是否接管 IPv6 |
| `block_quic` | `1` | redirect 模式丢弃转发 UDP/443 |
| `tun_stack` | `system` | mihomo TUN 协议栈 |
| `firewall_backend` | `auto` | `auto` / `nft` / `iptables` |
| `deploy` | `router` | `router` / `bypass` / `client`，见 5.4 |
| `final_policy` | `proxy` | 规则全部未命中时：`proxy` / `direct` |
| `rule_mirror` | `github` | 规则集主源：`github` / `ghproxy` / `jsdelivr` / `custom` |
| `rule_mirror_custom` | 空 | 主源为 `custom` 时的前缀，例如 `https://mirror.example.com/` |
| `rule_mirror_backup` | `ghproxy` | 备用源：`github` / `ghproxy` / `jsdelivr` / 完整前缀 |
| `rule_update` | `1` | 启动时是否更新规则集缓存（`0` 只用本地缓存） |
| `profile` | `default` | 当前激活的配置档案 id（由 LuCI 维护） |

命令行示例：

```sh
uci set ferry.main.kernel='singbox'
uci set ferry.main.mode='tun'
uci set ferry.main.sub_url='https://example.com/sing-box.json'
uci commit ferry
/etc/init.d/ferry reload
```

### 5.1 节点管理（nodes.json / nodes.lst）

节点持久化在 `/etc/ferry/nodes.json`，与 UCI 完全分离：

```json
{
  "version": 1,
  "nodes": [
    {
      "id": "n1", "type": "vless", "name": "HK-01", "enabled": true,
      "server": "hk.example.com", "port": 443,
      "uuid": "....", "flow": "xtls-rprx-vision",
      "network": "grpc", "serviceName": "gsvc",
      "tls": true, "sni": "hk.example.com",
      "fingerprint": "chrome", "publicKey": "...", "shortId": "1a2b",
      "insecure": false, "alpn": [ "h2" ]
    }
  ]
}
```

保存节点时，LuCI 同时把节点编译成 `/etc/ferry/nodes.lst`（每个节点一个 `BEGIN`/`END` 块，`KEY=VALUE`，值已做双引号转义）。shell 侧只按 `BEGIN/END` 读取并跳过 `enabled!=1`，不解析 JSON：

```
BEGIN
name=HK-01
type=vless
enabled=1
server=hk.example.com
port=443
uuid=...
...
END
```

分享链接支持范围：

| 协议 | 支持内容 | 备注 |
| --- | --- | --- |
| `vmess://` | base64 JSON，`net=tcp/ws/grpc`、`tls`、`sni`、`alpn`、`aid`、`scy` | `grpc` 的 `path` 作为 serviceName |
| `vless://` | `reality`（pbk/sid/fp）、`ws`、`grpc`、`flow`、`alpn` | 常见参数：`security`、`type`、`path`、`host`、`serviceName` |
| `ss://` | SIP002（`base64(method:password)@host:port`）、旧式整体 base64、`plugin`/`plugin-opts` | 插件支持 `obfs-local`/`simple-obfs`/`v2ray-plugin` |
| `ssr://` | 整体 base64，`protocol`/`obfs`/`protoparam`/`obfsparam`/`remarks` | 仅 mihomo 输出；sing-box 会跳过并告警 |
| `trojan://` | `ws`/`grpc`、`sni`、`alpn`、`allowInsecure` | TLS 隐含开启 |
| `hysteria2://` / `hy2://` | `sni`、`insecure`、`obfs`/`obfs-password` | 不支持端口跳跃（`mport`） |
| `tuic://` | `uuid:password`、`sni`、`alpn`、`congestion_control`、`udp_relay_mode` | — |

解析结果先落到统一内部结构（`id/type/name/enabled/server/port/uuid/password/cipher/network/tls/sni/...`），再由 `nodes.sh` 映射为两种内核对字段。二者差异是重点：

| 能力 | mihomo（`proxies`） | sing-box（`outbounds`） |
| --- | --- | --- |
| VMess | `type: vmess`、`uuid`、`alterId`、`cipher`、`tls`、`servername` | `"type":"vmess"`、`uuid`、`alter_id`、`security`、`tls.server_name` |
| VLESS | `type: vless`、`uuid`、`flow`、`tls`、`servername`、`reality-opts{public-key,short-id}` | `"type":"vless"`、`uuid`、`flow`、`tls.server_name`、`tls.reality{public_key,short_id}`；不支持 `tls.insecure` 之外的旧写法 |
| Trojan | `type: trojan`、`password`、`sni`、`client-fingerprint` | `"type":"trojan"`、`password`、`tls.server_name` |
| Hysteria2 | `type: hysteria2`、`password`、`sni`、`obfs`/`obfs-password`、`up`/`down` | `"type":"hysteria2"`、`password`、`tls.server_name`、`obfs{type,password}`、可选 `up_mbps`/`down_mbps` |
| TUIC | `type: tuic`、`uuid`、`password`、`sni`、`congestion-controller`、`udp-relay-mode` | `"type":"tuic"`、`uuid`、`password`、`tls.server_name`、`congestion_control`、`udp_relay_mode` |
| 传输层 | `network: ws` + `ws-opts{path,headers.Host}`；`network: grpc` + `grpc-opts.grpc-service-name` | `transport:{type:"ws",path,headers:{Host}}`；`transport:{type:"grpc",service_name}` |
| SSR | 原生支持 | 不支持（跳过 + 告警） |

注意：mihomo 的 `vmess/vless` 用 `servername`，`trojan/hysteria2/tuic` 用 `sni`；`client-fingerprint` 只对 `vmess/vless/trojan` 输出，避免把 uTLS 指纹误当证书指纹。

节点列表支持启用/禁用、上移下移、编辑、删除；删除/排序/启停都会立即触发重新编译并 reload。延迟测试未内置（可后续在节点表增加按钮调用内核 API），但节点结构已保留 `id/name`，可直接对接。

### 5.2 分流规则与镜像

规则编译产物 `/etc/ferry/rules.lst`，每行 `<分类> <目标策略>`：

```
cn direct
ads reject
streaming proxy
ai proxy
telegram proxy
dev proxy
academic proxy
game proxy
custom proxy
```

- 行序即优先级（first-match），LuCI 里的「上移/下移」直接改这个顺序。
- 目标策略只有 `proxy | direct | reject`；`proxy` 指向节点组（mihomo 的 `PROXY`、sing-box 的 `selector proxy`）。
- `custom` 分类不映射 geosite，而是读取 `/etc/ferry/custom.lst` 的自定义条目：

```
domain www.example.com      # 精确域名
suffix test.example.org     # 后缀匹配
ip 10.1.0.0/16
ip6 2001:db8::/32
```

分类到规则集（MetaCubeX/meta-rules-dat）的映射：

| 分类 | geosite 名称 |
| --- | --- |
| 国内/直连 | `geolocation-cn` |
| 广告与追踪 | `category-ads-all` |
| 流媒体 | `netflix`、`disney`、`youtube` |
| AI | `openai`、`anthropic`、`google-gemini` |
| Telegram | `telegram` |
| GitHub/开发者 | `github`、`gitlab`、`stackexchange` |
| 学术 | `coursera`、`edx`、`khanacademy` |
| 游戏 | `category-games` |

（`category-academic` / `scholar` 在 MetaCubeX 仓库中不存在，因此学术类改用上面三个可用的 geosite。）

生成差异：

- mihomo：`rule-providers`（`type: file`、`behavior: domain`、`format: yaml`、`path` 本地缓存）+ `rules` 中的 `RULE-SET,rs-<geo>,PROXY|DIRECT|REJECT`。
- sing-box：`route.rule_set`（`{"type":"local","format":"binary","path":...}`，即 `.srs`）+ `route.rules` 中的 `{"rule_set":"rs-<geo>","outbound":"proxy|direct"}` 或 `{"rule_set":...,"action":"reject"}`。

镜像与回退：

| `rule_mirror` | URL 形态 |
| --- | --- |
| `github` | `https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/<meta|sing>/geo/geosite/<geo>.<yaml|srs>` |
| `ghproxy` | `https://ghproxy.net/https://raw.githubusercontent.com/...` |
| `jsdelivr` | `https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@<meta|sing>/geo/geosite/<geo>.<ext>` |
| `custom` | `<rule_mirror_custom>/MetaCubeX/meta-rules-dat/<path>` |

`rule_mirror_backup` 支持同样四个值，也允许填完整前缀（`https://xxx/`）。拉取顺序：主源 → 备用源 → 本地缓存；缓存文件位于 `/etc/ferry/rules-cache/{mihomo,sing-box}/<geo>.<ext>`，24 小时内不重复下载。全部失败时：有缓存则继续用缓存并写告警；无缓存则跳过该分类并写告警，内核仍能启动（不会因规则源失败而起不来）。

逐分类互不影响：某个分类失败只影响它自己，后面的分类继续尝试（不会中断整轮同步），结果写入 `/var/etc/ferry/rules-status.txt`，每行 `<geo> <state>`，`state` 取值：

| state | 含义 |
| --- | --- |
| `ok` | 缓存命中或下载成功 |
| `stale` | 下载失败，沿用旧缓存（下次启动会重试） |
| `skipped` | `rule_update=0` 且无缓存，未尝试下载 |
| `failed` | 下载失败且无缓存，该分类的规则未生效 |

用 `config_path` 指定自备配置时，插件不生成配置、**也不同步规则**（`state=self`），因此不会为了用不到的规则集去联网或等待下载超时。


### 5.3 场景预设

| 预设 | 建议模式/形态 | 默认策略 | 特点 |
| --- | --- | --- | --- |
| 日常省流 `daily` | tproxy / router | proxy | 国内与游戏直连，其余代理 |
| 全局代理 `global` | tproxy / router | proxy | 除广告外全部代理 |
| 流媒体优先 `streaming` | tproxy / router | proxy | 流媒体+AI 代理，开发者/学术/游戏直连 |
| AI 优先 `ai` | tproxy / router | proxy | AI+开发者+学术代理，其余直连 |
| 游戏低延迟 `gaming` | tproxy / router | direct | 游戏平台走代理，其余直连（保留 UDP） |
| 仅白名单 `whitelist` | tproxy / router | direct | 默认直连，仅流媒体/AI/开发者/Telegram 代理 |
| 旁路由 `bypass` | tproxy / bypass | proxy | 日常省流规则 + 旁路由形态 |

应用预设只改当前档案的 `rules`、`mode`、`deploy`、`final_policy`、`preset` 字段，**不会改动 `nodes` 数组**，因此已导入节点不会被覆盖；应用后仍可在规则页继续微调。

### 5.4 三种部署形态的实际差异

| 维度 | 主路由 `router` | 旁路由 `bypass` | 客户端 `client` |
| --- | --- | --- | --- |
| 生成的 mihomo 配置 | 按 `mode` 生成 `tproxy-port`/`redir-port`/`tun`；`auto-route: true` | 同左，但 TUN 的 `auto-route: false` | 强制 `mixed` 形态：不生成 tproxy/redir/tun，只保留 `mixed-port` |
| 生成的 sing-box 配置 | 按 `mode` 生成 `tproxy`/`redirect`/`tun` inbound + `dns-in`/`mixed-in` | 同左，`tun.auto_route=false` | 只有 `mixed-in`，无 `dns-in` |
| netfilter 规则 | 完整加载（DNS 劫持 + TPROXY/REDIRECT/QUIC） | 完整加载，但只作用于「本机收到的报文」 | **完全不加载**（`pm_fw_up` 直接返回，status 显示 `firewall: skipped`） |
| dnsmasq 上游 | `router_dns=1` 时改写 | 同左（旁路由通常需要） | 不改写 |
| init 脚本行为 | 等端口就绪 → 装规则 → 改 DNS | 同左（不发 LAN 劫持的额外链） | 等 mixed 端口 → 跳过规则 → 直接写 status |
| 适用场景 | 出口网关 | 上游主路由把网关/DNS 指过来 | 只想要配置文件 |

**旁路由接入步骤**：

1. 主路由 DHCP 的「网关」与「DNS」都填旁路由 LAN IP（两者必须一致）。
2. 关闭旁路由的 DHCP（或使用主路由 DHCP），避免冲突。
3. 上游主路由防火墙放行到旁路由的转发；关闭上游的 DNS 劫持/DoH。
4. 推荐 TPROXY；若用 TUN，`auto-route` 已固定为 `false`，不会抢主路由转发。

**客户端使用步骤**：把「部署形态」页下载的 YAML/JSON 导入客户端，或局域网设备手工把 HTTP/SOCKS5 代理指到 `<本机IP>:<mixed_port>`。

### 5.5 配置档案（profile）的存储与切换

`/etc/ferry/profiles.json`：

```json
{
  "version": 1,
  "active": "default",
  "profiles": [
    { "id": "default", "name": "默认", "deploy": "router", "kernel": "mihomo",
      "mode": "tproxy", "preset": "daily", "final_policy": "proxy",
      "nodes": ["n1", "n2"], "rules": [ ... ], "custom_domains": [], "custom_cidrs": [] }
  ]
}
```

- 每个档案包含：部署形态、内核、运行模式、节点集合（引用全局 nodes.json 的 id）、规则序列、自定义域名/网段、预设 id、以及 UCI 标量字段快照。
- 激活：写 `profiles.json.active` + UCI `profile`，把标量字段回写 UCI，编译节点/规则并 `reload`；重启后 `pm_load` 优先读 UCI `profile`，因此激活项保持。
- 不变式：任何时刻只有一个 `active`；`removeProfile` 拒绝删除激活项（页面按钮也会置灰），并保证至少保留一个档案。
- 新建/复制/导入都只追加新档案，不覆盖已有档案；导入会把 `profile_nodes` 合并回全局节点库并重建 id 映射。
- 节点页保存的是「全量节点 id」，写入当前激活档案，不写 UCI。
- 旧配置迁移：首次启动时若 `profiles.json` 不存在，`common.sh` 用当前 UCI 生成 `default` 档案并写 `active`；绝不覆盖已有文件，也不影响服务启动。

### 5.6 生成状态与告警

每次 `pm_prepare` 结束都会写 `/etc/ferry/status.json`，LuCI 的节点/规则/部署页会读取并展示：

```json
{ "profile": "default", "deploy": "router", "kernel": "mihomo", "mode": "tproxy",
  "enabled": 1, "nodes": 7, "rules": 9, "updated": "2026-11-04T10:30:32Z",
  "warnings": [ "以下分类下载失败且无本地缓存，已跳过： geolocation-cn openai" ],
  "rule_sync": { "state": "failed",
                 "ok": [], "stale": [ "geolocation-cn" ], "skipped": [], "failed": [ "openai" ] } }
```

`rule_sync.state` 是整体状态（优先级 `failed` > `stale` > `skipped` > `ok`）：
`self` = 用 `config_path` 自备配置，未同步规则；其余四个值与上面的逐分类状态一一对应。各数组列出该状态的 geosite 名称。

部署页「当前生成的配置」预览走 rpcd 的 `file read`，受 ACL 限制。`config_path` 指向以下位置时可直接预览，其它路径仍会被内核使用、但预览为空（需要预览就把文件放到这些目录）：

- `/etc/ferry/config/`（任意子路径）
- `/etc/mihomo/*.yaml`、`/etc/mihomo/*.yml`
- `/etc/sing-box/*.json`

（ACL 里的文件路径条目按 `fnmatch` 匹配：`rpcd` 的 `file.c` 把路径作为 object、权限作为 function 交给 `session.c` 的 `rpc_session_acl_allowed`，后者用 `fnmatch` 比较，所以这三条通配是有效的。）



---

## 6. 内核二进制

插件**不内置**内核二进制（体积大、架构多、更新频繁）。两种做法：

### 6.1 做法 A：用户自行放置（最简单，x86_64 主线）

把对应架构的二进制放到 `/usr/bin/mihomo` 或 `/usr/bin/sing-box` 并 `chmod 755`，再在 LuCI 里留空 `bin_path`。
`scripts/fetch-kernel.sh` 默认就是 x86_64，`--arch` 可省略：

```sh
./scripts/fetch-kernel.sh --kernel mihomo  --version 1.19.33 --out ./kernels
./scripts/fetch-kernel.sh --kernel singbox --version 1.14.4  --out ./kernels
# 手工校验（GitHub release 未提供校验文件，可自行记录/核对）
./scripts/fetch-kernel.sh --kernel mihomo --version 1.19.33 --sha256 <期望值>
```

x86_64 对应关系（脚本内置）：

| 设备架构 | mihomo 资源名 | sing-box 资源名 |
| --- | --- | --- |
| **x86_64（主线）** | `amd64` | `amd64-musl` |
| aarch64（次要） | `arm64` | `arm64-musl` |
| armv7（次要） | `armv7` | `armv7-musl` |
| armv6（次要） | `armv6` | `armv6` |
| mips / mipsle（次要） | `mips-softfloat` / `mipsle-softfloat` | 同左 |
| mips64 / mips64le（次要） | `mips64` / `mips64le` | `mips64-softfloat` / `mips64le-softfloat` |

注意事项：

- x86_64 的 mihomo/sing-box 都是 Go 静态二进制，**不依赖 musl/glibc**；sing-box 仍建议选 `amd64-musl` 变体。
- x86_64 默认 `amd64` 资源要求 v3 指令集（AVX2，Haswell 以后）；更老的 x86 CPU 用 release 里的 `amd64-compatible` 变体。Rosetta 环境下也必须用 compatible 变体。
- **mips 设备浮点差异很大**：MT7621 等是 softfloat，若误装 hardfloat 会 `Illegal instruction`；不确定时先用 `mipsle-softfloat`。
- 二进制架构不匹配时表现为“启动即退出 + procd 反复重启”，用 `logread` 可看到 `Exec format error`。
- 固件架构与 `PKGARCH:=all` 无关：包本身不含二进制，内核文件必须自己按设备架构放置；x86_64 固件只能配 x86_64 内核。

### 6.2 做法 B：做成独立二进制包（示例）

在 feed 里新增 `mihomo-bin/Makefile`，按架构选择不同的 `PKG_SOURCE_URL`（OpenWRT 的 `PKG_SOURCE` 支持 `@ARCH` 条件，但跨架构二进制更常见的写法是按 `CONFIG_TARGET_ARCH_PACKAGES` 分支，或为常用架构各建一个包）：

```makefile
include $(TOPDIR)/rules.mk

PKG_NAME:=mihomo-bin
PKG_VERSION:=1.19.33
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/mihomo-bin
  SECTION:=net
  CATEGORY:=Network
  TITLE:=mihomo core binary
  PKGARCH:=$(ARCH)      # 二进制与架构绑定，不能是 all
endef

# 以 x86_64 为例（主线）；其它架构换成对应资源名，且必须与固件架构一致
PKG_SOURCE_URL:=https://github.com/MetaCubeX/mihomo/releases/download/v$(PKG_VERSION)
PKG_SOURCE:=mihomo-linux-amd64-v$(PKG_VERSION).gz
PKG_HASH:=<发布页/自建镜像提供的 sha256>

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	gzip -dc $(DL_DIR)/$(PKG_SOURCE) > $(PKG_BUILD_DIR)/mihomo
	chmod 755 $(PKG_BUILD_DIR)/mihomo
endef

define Package/mihomo-bin/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mihomo $(1)/usr/bin/mihomo
endef

$(eval $(call BuildPackage,mihomo-bin))
```

然后把 `luci-app-ferry` 的 `DEPENDS` 加上 `+mihomo-bin`（sing-box 同理，但需要先解包 tar.gz）。

### 6.3 内核管理（LuCI「内核」页签，1.0.0-r3 起）

除「用户自行放置」与「独立二进制包」之外，插件新增内核管理页签，负责**下载/导入 → 校验 → 原子替换 → 切换/回滚 → 卸载**。仍然**不内置任何内核二进制**：二进制由用户从上游获取，插件只做校验、落位与切换。

**数据目录**

| 路径 | 作用 |
| --- | --- |
| `/etc/ferry/kernels/<mihomo\|singbox>/<tag>/<bin>` | 已安装版本（持久化，重启保留） |
| `/etc/ferry/kernels/<kernel>/active` → `<tag>` | 当前启用版本 |
| `/etc/ferry/kernels/<kernel>/previous` → `<tag>` | 回滚目标（上一版本） |
| `/usr/bin/mihomo`、`/usr/bin/sing-box` | 指向 `active` 的符号链接（运行路径不变） |
| `/etc/ferry/kernels/mirrors.json` | 可编辑镜像列表（名称 / 示例 URL / 是否可用） |
| `/var/etc/ferry/kernel-job.json` | 作业进度（phase/message/bytes/done/ok/code） |
| `/var/etc/ferry/config-check-report.txt` | 最近一次配置自检的落盘结果（含内核原始输出） |

**下载与校验**

- 源可选：官方 GitHub（默认）/ 已启用镜像 / 自定义 URL；页面显示**实际使用的源**与耗时。
- 换源**不放宽校验**：无论走哪个源，最终文件都必须匹配用户在页面上填写的**官方 SHA-256**（上游 release 未提供校验文件，故由用户粘贴官方发布页/上游 README 中给出的摘要）。
- 仅允许 `https://`（本机回环 `http://127.0.0.1` 仅供离线测试）；不做自动测速轮询，镜像测速需手动点一次（1MB 取样）。
- 校验失败**不落位**：下载到临时目录，校验通过后才解压、`chmod 0755`、再在同一文件系统内 `rename` 进版本目录。
- 支持本地导入（离线场景），同样必须提供 SHA-256。
- 默认不启用任何第三方镜像；`mirrors.json` 里镜像初始为「未启用」，需用户自行打开。

**切换与回滚**

一键 mihomo ↔ sing-box，或同内核多版本切换。切换前 `preview` 会返回目标内核、版本、架构匹配、配置格式差异（`format_change`）与是否需要重新生成，UI 必须显式确认后才执行。执行顺序：

```
停服务 → 原子替换 /usr/bin/<bin> → 写 active/previous 指针 + UCI kernel
        → 按目标内核版本重新生成配置 → 内核自身 check → 启动服务 → 校验进程存活
```

任一步失败（`ERR_CONFIG_CHECK` / `ERR_START` / `ERR_LINK` …）自动回滚原内核 + 原配置 + 原运行状态，并把失败原因与内核原始输出回显到页面。回滚（`rollback`）只需把 `previous` 指回并重走同一流程；卸载只允许删**非当前**版本，且只删 `kernels/` 下的版本目录，不动 `/etc/config/ferry` 与用户节点的其他文件；升级/卸载插件本身也不会删除 `/etc/ferry/kernels`（见 4.7）。

**sing-box 配置版本矩阵**

生成器读取实际二进制的 `sing-box version` 选择模板，不按用户手填的版本号猜：

| 区间 | 版本范围 | 关键差异 |
| --- | --- | --- |
| A | 1.8.x – 1.10.x | 无 `route.actions`；DNS 劫持/拦截依赖特殊出站 `{"type":"block"}` 与 `{"type":"dns"}`；无 `default_domain_resolver`；TUN 用 `inet4_address` |
| B | 1.11.x | 引入 `route` 规则 `action`；`block`/`dns` 出站开始弃用；TUN 仍用 `inet4_address` |
| C | 1.12.x – 1.13.x | `block`/`dns` 出站已移除（check 报错）；可用 `default_domain_resolver`；`rule_set` 走 `type: remote` + `format` |
| D | ≥ 1.14.x | DNS servers 用 `type` + `server`；TUN 用 `address`（`inet4_address` 弃用）；更严格的字段校验 |

不在矩阵内（<1.8.0 或无法解析版本）时**明确提示「未适配版本」并拒绝生成配置**，不会静默套用旧模板；失败时保留上一条已验证配置。

生成后必须通过内核自身门禁：sing-box `sing-box check -c <cfg> -D <cfg 目录>`，mihomo `mihomo -t -d <dir> -f <cfg>`；输出原样写入 `config-check-report.txt`，不通过不落位、不重启。

### 6.4 覆盖安装（升级）后的自愈与一键诊断（1.0.0-r10 起）

r5–r9 的覆盖安装有一个致命组合：旧版 `/etc/ferry/kernels/mirrors.json`（r6 及更早写的格式，没有 `"version": 2`）会触发后端迁移分支的**无限递归**（`pmk_mirrors_init → pmk_mirror_get → pmk_mirrors_init`），ubus 调用永不返回；前端 `loadMirrors` 当时没有 `catch`，`loadVersions` 又被 `!state.mirrors` 门控，于是界面永久停在「内置清单加载中」，镜像源与版本清单同时为空，点「刷新源列表」也没有任何反应。全新安装没有旧文件，所以同一份 r9 表现为正常。

r10 起，安装/升级会做以下自愈（`postinst`）：

| 动作 | 说明 |
| --- | --- |
| 清 LuCI 索引缓存 | `rm -rf /tmp/luci-indexcache*`，避免旧菜单/模块索引残留 |
| 按清单删旧文件 | `/usr/lib/ferry/legacy-files.txt` 逐条删除（不猜路径；当前版本无被删文件，清单为空） |
| 权限自愈 | `chmod` 后端脚本、rpcd 入口与 `kernels-builtin.tsv`（历史升级丢可执行位会让 rpcd 直接失败） |
| 迁移旧 mirrors.json | `kernel.sh init-state` 把 v1 就地升级为 v2，并保留自定义前缀 |
| 刷新 rpcd | 先 `reload`，5 秒后后台 `restart rpcd` + `restart uhttpd`，不阻塞本次安装 |
| 内置清单校验 | 缺失时写系统日志 `WARN 内置版本清单缺失` |

前端同时加了硬性保护：**所有后端调用 5 秒超时**，超时/未知方法/404 都会把原文写进错误态并给「重试」按钮，任何路径都不会停在「加载中」；版本清单只读包内置 `kernels-builtin.tsv`，与镜像源、网络状态完全解耦。

保存镜像列表也不再写回 v1：busybox `sed` 不支持 GNU 的 `0,/re/` 地址，r10 改用 `awk` 补 `"version": 2`，避免「保存一次 → 下次读取触发迁移 → 用户勾选被重置」。

**一键诊断**（随包安装，断网现场可用 `--no-net`）：

```sh
ferry-kernel-diag            # 全量：环境/空间/依赖/清单/镜像/可达性/最近 job/rpcd 冒烟
ferry-kernel-diag --no-net   # 跳过网络探测
```

输出包含：包版本、架构、`kernel_dir` 与挂载/剩余空间、`uclient-fetch`/wget/curl/CA 状态与 HTTPS 探测 rc、内置 TSV 行数与生成日期、各内核可用条数、镜像 `selected`/`chain`、**ACL 漏声明的方法**（`acl_missing`）、每个源的可达性与 HTTP 码/耗时、最近一次 job 的 `phase/code/message` 原文。整段贴回即可定位「列表空」还是「下载失败」。

**许可证**

mihomo（GPL-3.0）与 sing-box（GPL-3.0）均为独立上游项目；插件仅下载**用户指定 URL** 的文件并在本地校验，不打包、不再分发其二进制，因此本插件自身仍为 **GPL-2.0**（见 `LICENSE`）。页面对此有明确提示，用户需自行确认上游许可证与当地法规。

---

## 7. 关键实现

### 7.1 进程管理（procd）

`/etc/init.d/ferry` 使用 `USE_PROCD=1`：

- `start_service`：读 UCI → `pm_prepare`（生成/校验配置）→ `procd_open_instance` 启动内核 → **等待端口就绪**（最多 20 秒）→ 安装接管规则 → 改写 dnsmasq 上游。
- 崩溃自动重启：`procd_set_param respawn 3600 5 5`（1 小时内最多 5 次，超时 5 秒后重试）。
- `stop_service`：先清理接管规则、恢复 dnsmasq 上游，再由 rc.common 结束 procd 实例，保证退出时不留规则。
- `reload_service`：stop + start（LuCI 保存后自动触发）。
- `status_service`：输出进程、规则、dnsmasq 改写状态。

启动顺序上的取舍：**先起进程、确认监听成功后再装规则**。如果配置错误或二进制缺失，接管规则不会被安装，局域网保持直连，避免把全屋网络“黑洞”。

### 7.2 接管规则（nftables）

独立表 `ip ferry` / `ip6 ferry6`，不碰 fw4 的 `inet fw4`：

```
table ip ferry {
  set bypass4 { type ipv4_addr; flags interval; auto-merge;
                elements = { 127/8, 10/8, 172.16/12, 192.168/16, 169.254/16,
                             100.64/10, 224/4, 240/4, <用户 bypass> } }
  set lanif { type ifname; elements = { "br-lan" } }

  # DNS 劫持：nat/prerouting，优先级 -110，先于 redirect/TPROXY
  chain dns_prerouting {
    type nat hook prerouting priority -110; policy accept;
    ip daddr @bypass4 return     # 访问内网 DNS（NAS/AD）时直连，不劫持
    iifname @lanif udp dport 53 redirect to :1053
    iifname @lanif tcp dport 53 redirect to :1053
  }

  # TPROXY：filter/prerouting，优先级 -150（早于 nat）
  chain tproxy_prerouting {
    type filter hook prerouting priority -150; policy accept;
    iifname != @lanif return      # 只处理来自局域网接口
    ip daddr @bypass4 return      # 内网/保留地址/目标自身直连
    udp dport 53 return           # 53 交给 dns_prerouting 处理
    tcp dport 53 return
    meta l4proto tcp meta mark set 1 tproxy to :7890
    meta l4proto udp meta mark set 1 tproxy to :7890
  }
}
```

要点：

- **优先级顺序**：mangle(-150) 先于 nat dstnat(-110)，所以 tproxy 链里必须先对 53 端口 `return`，否则 DNS 会被 tproxy 抢走，走不到 DNS 劫持链。
- **绕行目标自身**：内置保留网段 + 用户 `bypass_cidr` / `bypass_ip`，`ip daddr @bypass4 return`，避免把“局域网访问路由器/内网设备”也代理掉。
- **TPROXY 策略路由**：`ip rule add fwmark 1 table 100` + `ip route add local default dev lo table 100`（IPv6 同理），停止时删除；无此路由时 TPROXY 报文无法投递到本机。
- **redirect 模式**：nat 链 `priority -100`，仅 TCP；`block_quic=1` 时额外丢弃转发 UDP/443，避免 QUIC 绕过。
- **清理**：`nft delete table ip ferry` / `ip6 ferry6` 即可一键恢复，不会残留。

### 7.3 iptables 兼容路径

- `nat/PREROUTING`：自定义链 `PM_DNS`（DNS REDIRECT）、`PM_REDIR`（REDIRECT 模式）。`PM_DNS` 插在首位，`PM_REDIR` 追加在它后面，保证 TCP 53 先命中 DNS 链。
- `mangle/PREROUTING`：`PM_TPROXY`（TPROXY + `--tproxy-mark 1/1`）、`PM_QUIC`（DROP QUIC）。
- 所有链在开头按 `-d` 匹配 bypass 网段并 `RETURN`，内网 DNS/QUIC 不会被误伤。
- 跳转规则插在 PREROUTING 首位，停止时先删跳转、再 flush、再删链。
- 注意：iptables 后端只处理 IPv4；`enable_ipv6` 在该路径下不生效。

### 7.4 DNS 衔接矩阵

| 内核 / 模式 | LAN 53 | 路由器自身 DNS | 说明 |
| --- | --- | --- | --- |
| mihomo / 任意模式 | nat redirect → `dns_port` | dnsmasq 上游改为 `127.0.0.1#dns_port` | 内核自带 DNS + fake-ip，无泄漏 |
| sing-box / TUN | tun 内 DNS 劫持 | 同样由 tun 接管（dnsmasq 上游不改） | 生成配置带 `{"protocol":"dns","action":"hijack-dns"}` 路由规则 |
| sing-box / TPROXY | nat redirect → `dns_port` 的 `direct` inbound | dnsmasq 上游改为 `127.0.0.1#dns_port` | 53 在 tproxy 链里 `return`，交给 DNS 链 |
| sing-box / REDIRECT | nat redirect（TCP+UDP）→ `dns_port` 的 `direct` inbound | dnsmasq 上游改为 `127.0.0.1#dns_port` | `dns-in` 同时接收 REDIRECT 和本机查询 |

防泄漏/防环路要点：

- 劫持规则只匹配 `iifname @lanif`，**路由器自身发起的查询来自 output 链，不会被再次劫持**。
- mihomo 的 DNS 上游查询由内核自己发出（路由器本机流量），不会命中 prerouting，因此不会形成环路。
- dnsmasq 上游指向 `127.0.0.1#1053` 后，`noresolv=1` 同时生效，避免继续使用 `resolv.conf` 里的公共 DNS。

### 7.5 事务与回滚保护（1.0.0-r4 起）

**应用即进入待确认态**。`ferry reload`（LuCI 保存 / CLI）内部顺序：

```
pt_begin（快照 + meta） → stop → start（PM_TXN_SKIP=1，避免自检误判）
→ pt_arm（pending，deadline=now+rollback_timeout） → 等待确认
```

- 倒计时默认 **60s**，`ferry.main.rollback_timeout` 可设 **30–180**。
- LuCI「安全」页每秒轮询 `/usr/libexec/rpcd/luci-ferry-safety status`，显示剩余时间；
  **确认保留** → `pt_confirm`（pending 移入 `confirmed-<id>`，并刷新 `baseline.uci`）；
  **立即回滚** → `pt_rollback manual`。
- 超时 → 逐项还原：dnsmasq 原生上游、`table ip/ip6 ferry`、`ip rule`（fwmark 1 → table 100
  及其 `local default dev lo`）、本次事务写过的 UCI 键、内核进程（按应用前是否运行决定）。
  **只动 ferry 自己拥有的对象**：用户自建 nft 表/链、非 ferry 的 ip rule、第三方服务不受影响。
- 回滚源是 `/etc/ferry/txn/baseline.uci`（最近一次“确认保留”的 ferry 配置全量导出）。
  原因：uci commit 先于 reload，pending 快照里已是新值，直接回快照等于没回滚。
- 并发保护：`/etc/ferry/txn/lock`（`mkdir` 原子 + 时间戳，超时可抢占），LuCI 与 CLI 同时操作
  不会触发双重回滚。
- 审计：`history.log` 每次记录 `reason`（`timeout` / `manual` / `apply-failed` / `startup-detect` /
  `before-disable`），并把回滚前后状态写入 `evidence-<id>.txt`。

**看门狗（独立 procd 服务）**

`/etc/init.d/ferry-watchdog` 不依附主服务，运行 `/usr/lib/ferry/watchdog.sh`，
`respawn 3600 5 5`，脚本每秒调用 `pt_check`（到点即 `pt_rollback timeout`）。

为什么在 OpenWrt 上可靠：

1. **不依赖控制面**：没有浏览器/SSH 会话也照常计时，因为计时进程由 procd 守护。
2. **被杀可自愈**：procd 在 5s 后拉起；若被反复杀，主服务重启/开机时 `start_service`
   检测到 pending 未确认 → `startup-detect` 回滚后再启动。
3. **断电可恢复**：pending 的 `meta`、快照和 `baseline.uci` 都在 `/etc/ferry`（overlay 持久化），
   重启后仍然存在；`/etc/init.d/ferry start` 先检测并回滚，业务不会带着未确认配置上线。
4. `PM_TXN_SKIP=1` 只在事务自身的 stop/start 内部生效，避免把自己的 pending 当成崩溃残留。

三条崩溃路径的 QEMU 真机用例见 §9.3。

### 7.6 临时关闭代理

- `ferry-txnctl disable`（LuCI「安全」页同按钮）：先把未确认事务按超时回滚，避免关闭后被看门狗
  拉回；然后把当前形态快照到 `/etc/ferry/tmp-off/`（含 `meta`/`evidence.txt`），再
  **停内核 → 撤 nft/iptables 接管 → dnsmasq 完整回原生上游**（`server` 与 `noresolv` 一起还原）。
- 语义是“完整关闭”，不允许半关：DNS 若仍指向 `127.0.0.1#1053` 而内核已停，解析会超时，
  比不关闭更难排查。
- `ferry-txnctl enable`：删标记后按同一 UCI 配置重新 `start`，并写 `restore-evidence.txt`
  供与关闭前对比；失败时返回非 0 且状态里 `disabled=false` 但服务未就绪，需查日志。
- 断言（QEMU，真实流量）：关闭后 `dnsmasq server=223.5.5.5`、`nft` ferry 表为 0、客户端解析
  真实 IP 且 HTTP 200；恢复后 `7890` / `127.0.0.1#1053` 回归、客户端重新拿到 fake-ip。

### 7.7 诊断包（`ferry-diag`）

入口：LuCI「安全」页按钮 + CLI `ferry-diag`（可选 `--out DIR`），产出单个 `tar.gz`。

内容（20 项）：`system.txt`（固件/内核/包版本）、`capability.txt`（nft/iptables/模块探测）、
`uci-ferry.txt` / `uci-dnsmasq.txt` / `uci-network-lan.txt`、`nft-ruleset.txt` + `nft-ferry.txt`、
`ip-routing.txt`、`iptables.txt`、`kernel-check.txt`（`sing-box check` / `mihomo -t` 结果）、
`network.txt`（dig/ping/curl）、`logs.txt`（最近日志尾部）、`transaction.txt`（pending/history）、
`config-mihomo.redacted.yaml`、`config-singbox.redacted.json`、`nodes.redacted.json`、
`profiles.redacted.json`、`certs.redacted.txt`、`manifest.txt`（文件清单 + SHA-256）。

脱敏规则：

| 类型 | 处理 |
| --- | --- |
| 订阅 URL | 保留 scheme+host，路径与 query 变 `/***`（`https://sub.example.com/***`） |
| JSON/UCI/YAML 敏感键（`password`/`uuid`/`token`/`secret`/`auth`/`psk`…） | 值替换为 `***` |
| PEM 私钥块 | 整段替换为 `[REDACTED PRIVATE KEY]` |

测试断言：对生成包内所有文本 `grep` 植入的原始凭据，必须零命中（`tests/test-diag.sh` PASS=49，
QEMU 内 PASS=24/0）。

### 7.8 面板实现（可选包）

| 组成 | 作用 |
| --- | --- |
| `usr/lib/ferry/panel.sh` | secret 生成、bind/port 计算、注入、`ip ferry_panel` 防火墙、`panel_apply_bg`、`panel_cleanup` |
| `usr/bin/ferry-panel` | CLI：`enable` / `disable` / `rotate` / `apply` / `cleanup` / `boot` / `status` |
| `usr/libexec/rpcd/luci-ferry-panel` | rpcd 后端：status / enable / disable / rotate / apply |
| `view/ferry/dashboard.js` | LuCI「面板」页：状态表、能力探测表、启用/禁用/轮换、新窗口或 iframe |
| `www/luci-static/ferry-dashboard/` | zashboard 3.22.0（已打只读补丁）+ 运行期 shim `ferry-readonly.js` |

**注入**：`generate.sh` 在生成配置时读取面板状态——mihomo 追加 `external-controller: <bind>:<port>` 与 `secret: "<secret>"`；sing-box 追加 `experimental.clash_api`（`external-controller` + `secret`）。`config_path` 自备配置与 sing-box 订阅配置不会被改写，面板分别给出 `self_config` / `sub_config` 原因提示。

**启用流程**：`enabled=1` → 生成 32 位 hex secret（0600）→ 取 LAN IPv4 作为 bind → 下发 `ip ferry_panel`（LAN 网段 + `lo` accept，其余 `tcp dport <port>` 明确 drop）→ `panel_apply_bg` 以 `PM_TXN_SKIP=1 /etc/init.d/ferry reload` 异步重启内核（标记 `/var/run/ferry-panel/apply.since`，日志 `/tmp/ferry-panel-apply.log`）。页面轮询 `status`，`applying=true` 期间显示「约 5–30 秒」。禁用与轮换 key 走同一套流程。

**只读边界**：`ferry-readonly.js` 同时接管 `fetch`、`XMLHttpRequest` 与 `WebSocket`——GET/HEAD/OPTIONS 全放行；写方法只放行 `PUT /proxies/{group}`（切换节点）；其余方法返回 403；WS 只放行 `/traffic`、`/logs`、`/memory`、`/connections`。shim 不改 zashboard 资源，失败/回退时删 `index.html` 里一行 `<script>` 即可。

**能力探测**（`caps` 字段随当前内核变化，页面按「可用 / 只读 / 不可用」着色，sing-box 下不可用项置灰并给出说明）：

| 能力 | mihomo | sing-box |
| --- | --- | --- |
| 规则页（`/rules`） | available | unavailable（隐藏入口） |
| 配置页（`/configs`） | readonly | unavailable |
| 延迟明细 | available | unavailable（探测返回通用错误） |
| 重启 / 升级内核 | unavailable（由 ferry 内核页负责） | unavailable |
| 切换节点（`PUT /proxies/{group}`） | available | available |

`status` 里可看 `enabled`/`injected`/`bind`/`port`/`secret`/`kernel`/`type`/`mode`/`reason`/`running`/`service_enabled`/`applying`/`conflict`/`caps`；`reason` 取值含 `ready`、`disabled`、`no_secret`、`no_bind`、`self_config`、`sub_config`、`not_injected`；`conflict.both` 表示两个内核同时在跑（同端口会 `EADDRINUSE`）。

---

## 8. 常见问题（FAQ）

**Q1：局域网能上网但 DNS 解析失败 / DNS 泄漏怎么排查？**

1. `nft list table ip ferry` 确认 `dns_prerouting` 链存在且 `redirect to :1053` 正确。
2. `netstat -lnup | grep 1053` 确认内核 DNS 正在监听。
3. 从 LAN 机器 `dig @8.8.8.8 example.com`，若超时说明劫持没生效；若能解析但结果来自直连，检查 dnsmasq 是否仍在使用旧上游（`uci show dhcp | grep server`）。
4. sing-box 非 TUN 模式会生成 `dns-in`（`"type":"direct"`）监听 `dns_port`；用 `netstat -lnup | grep 1053` / `netstat -lntp | grep 1053` 确认它存在。TUN 模式没有该监听是正常的。

**Q2：开启后路由器自身无法上网？**

- 本插件默认不接管路由器自身出口流量（只接管 LAN 转发 + DNS 上游）。若仍无法上网：
  1. 检查是否启用了 TUN 模式且 `kmod-tun` 未安装；
  2. 检查 `/etc/resolv.conf`/dnsmasq 是否被指向了未监听的端口；
  3. `ps | grep mihomo` 确认进程在；`logread -e ferry` 看是否有配置错误；
  4. 直接 `opkg remove` 或 `uci set ferry.main.enabled=0 && /etc/init.d/ferry stop` 恢复。

**Q3：TUN 与 TPROXY 怎么选？**

- **TPROXY**：不建虚拟网卡、开销小，TCP/UDP 都能接管；对内核模块（`kmod-nft-tproxy`）有依赖，个别老内核/精简固件不支持。
- **TUN**：兼容性最好（很多教程/固件都验证过），路由器自身流量也会被接管；需要 `kmod-tun`，且与 fw4/其他 VPN 的共存需要多调试。
- 家用网关首选 TPROXY；遇到 TPROXY 不通、或想“路由器自己也走代理”，改 TUN。

**Q4：OpenWRT 22.03 / 23.05 / 24.10 有差异吗？**

- 22.03+ 默认使用 **nftables (fw4)**，本插件的 nft 路径可用；22.03 仍然可以用 iptables 后端（需自行安装 iptables 包）。
- 23.05 与 24.10 的 nftables/kmod 包名一致（`kmod-nft-tproxy`、`kmod-nft-nat`、`kmod-tun`），无额外差异；24.10 内核 6.6，nft NAT 统一支持 IPv4/IPv6。
- 极老版本（21.02 及以前，iptables/fw3）请把 `firewall_backend` 设为 `iptables`，并安装 iptables 相关包。
- `ip-full` 会替换 `ip-tiny`：如果固件里其他组件依赖 busybox 版 `ip`，请确认后再装。

**Q5：订阅填了但节点没生效？**

- mihomo：订阅必须是 **Clash/mihomo YAML**（`proxy-providers` 只认这种格式），base64/v2ray 订阅请先转换。
- sing-box：订阅 URL 必须直接返回 **sing-box JSON**，且其中的 inbound 端口要与插件的 `proxy_port` / `dns_port` 对齐；否则请用 `config_path` 指定已适配好的配置。
- 首次启动需要联网下载订阅，`logread -e ferry` 可看到下载失败原因。

**Q6：怎么彻底卸载/恢复？**

```sh
/etc/init.d/ferry stop
/etc/init.d/ferry disable
opkg remove luci-app-ferry
# 确认规则已清理
nft list tables | grep ferry
iptables -t nat -S | grep PM_
```

**Q7：sing-box 用哪个版本？**

插件生成的骨架按 **1.12+** 的新格式编写（新版 DNS server、`default_domain_resolver`、`hijack-dns` action）。1.10/1.11 请把 `config_path` 指向自己适配好的完整 JSON，插件只负责识别、拉起和接管；不要混用旧格式的骨架。

**Q8：开启 IPv6 后 DNS 解析异常？**

插件在 `enable_ipv6=1` 时把内核 DNS / inbound 监听在 `[::]`，需要内核 `net.ipv6.bindv6only=0`（OpenWRT 默认值）。如果固件把它设为 `1`，IPv4 的 `127.0.0.1#1053` 就连不上：此时把 `enable_ipv6` 设为 `0`，或手动把 mihomo `dns.listen` 改回 `0.0.0.0:1053`。iptables 后端不处理 IPv6，也建议关闭该选项。

---

## 9. 验证情况

分层说明：真机实测（QEMU）→ 静态/离线 → 仍未验证。

### 9.1 真机实测（自建 QEMU，x86_64，原镜像只读 + qcow2 覆盖层）

| 固件 | 包格式 | 场景 | 结果 |
| --- | --- | --- | --- |
| OpenWrt 24.10.4（kernel 6.6.110） | ipk / opkg | 安装 → 服务启动 → 菜单/ACL 文件就位 → 服务运行中卸载 | 37 项断言全 PASS |
| OpenWrt 24.10.4 | ipk | 启用服务 → 重启 → 停用 | 12 项 PASS（重启后 dnsmasq 接管仍成立，停用后上游还原） |
| ImmortalWrt 25.12.0（kernel 6.12.87，apk-tools 3.0.5） | apk | `apk add --allow-untrusted` → 服务启动 → 菜单 → `apk del` | 28 项 PASS |
| ImmortalWrt 25.12.0 | apk | 重启自愈 + 卸载断言 | 21 项 PASS（pre-deinstall 标记文件被写出） |
| OpenWrt 24.10.4 | ipk | 内核管理：全新安装 mihomo 1.18.8 → 切 sing-box 1.8.14/1.10.7/1.11.0/1.14.4 → 回滚 → 卸非当前版本 → 跨内核切回 mihomo → 切 mihomo 1.19.33 | 12 节 PASS（见下方明细） |
| ImmortalWrt 25.12.0 | apk | 内核管理：全新安装 mihomo 1.19.33 → 切 sing-box 1.10.7 → 切 mihomo 1.18.8 → 回滚 1.19.33 → 卸非当前版本 → `apk del` 保留内核文件 | 6 节 PASS |
| OpenWrt 24.10.5 | ipk | 面板包：安装 → 启用 → mihomo 下页面渲染与只读拦截 | 27 项 DOM 断言全 PASS |
| OpenWrt 24.10.5 | ipk | 切 sing-box 后面板能力探测、置灰与隐藏 | 21 项 DOM 断言全 PASS |
| OpenWrt 24.10.5 | ipk | 主包 RESTORE：冻结包 `--force-reinstall` + 逐文件 md5 | 38/38 OK，FAILED 0 |
| OpenWrt 24.10.5 | ipk | 面板包完整卸载计时（`/proc/uptime`） | 5.46 s；返回瞬间 9090 已释放 |

### 9.1.1 内核管理真机明细（QEMU x86_64，真实上游二进制）

两台虚拟机均在**全新状态**开始（`/etc/ferry/kernels` 为空、无 `/usr/bin/mihomo`），内核包通过「本地导入」或「ghproxy 镜像下载」进入，SHA-256 全部按官方值校验。

| 步骤 | 结果（OpenWrt 24.10.4） |
| --- | --- |
| 安装 mihomo 1.18.8 compatible（activate） | `ok=true`，`active=1.18.8`，`arch_match=true`，`mihomo -t` rc=0，进程 pid 存活 |
| 安装 sing-box 1.8.14（不启用） | `ok=true`，`active` 仍为 mihomo 1.18.8（不误切换） |
| 切到 sing-box 1.8.14 | `ok=true`，`sb_bucket=A`，`sing-box check` rc=0，进程 pid 存活 |
| 切到 sing-box 1.10.7 | `ok=true`，`sb_bucket=A`，check rc=0 |
| 切到 sing-box 1.11.0 | `ok=true`，`sb_bucket=B`，check rc=0 |
| 切到 sing-box 1.14.4（musl 静态包） | `ok=true`，`sb_bucket=D`，check rc=0 |
| 回滚 sing-box | `ok=true`，回到上一版本 1.11.0（`active=1.11.0`，bucket=B） |
| 卸非当前版本 1.8.14 | `ok=true`，目录只剩 1.10.7/1.11.0/1.14.4 + `active` |
| 跨内核切回 mihomo 1.18.8 | `ok=true`，`mihomo -t` rc=0，pid 存活；sing-box 进程退出 |
| 安装并切到 mihomo 1.19.33 compatible | `ok=true`，`active=1.19.33`，check rc=0 |
| 镜像测速（ghproxy，手动 6 秒取样） | `ok=true，elapsed=6s，bytes≈876KB` |
| 镜像真实换源安装 sing-box 1.14.4 | `ok=true，源=ghproxy，74s`，落位 `sha256=8f7c5f06…a12057ca`（与官方一致） |

ImmortalWrt 25.12.0（apk）同一脚本的 `imm` 模式全流程 PASS：mihomo 1.19.33 → sing-box 1.10.7（bucket=A，check rc=0）→ 切回 mihomo 1.19.33 → 切 1.18.8 → 回滚 1.19.33 → 卸非当前版本 → `apk del luci-app-ferry` 后 `/etc/ferry/kernels/mihomo/{1.18.8,1.19.33,active,previous}` 完整保留。

**测试环境差异（不是产品缺陷）**：两台 VM 使用 QEMU 精简内核，缺少 `nf_tables` 模块，`nft` 加载接管规则会报 `did you mean table 'fw4'`，因此「流量接管」类断言在这两台 VM 上不成立；内核进程、配置生成与 `check` 门禁均正常。另：镜像自带的 busybox 缺少 `od` 与 `timeout`，这暴露了两个真实兼容性问题（见下方「本轮修复」），已修入源码并在两台 VM 复验。

**本轮真机暴露并修复的问题**：
- `generate.sh` 在版本探测/自检里直接调用 `timeout`，精简固件没有该命令 → `sing-box` 版本解析为空 → 生成器误判「未适配版本」，切换全部失败。已改为 `pm_timeout` 退化实现（无 `timeout` 时直接执行）。
- 首次安装时 `/etc/ferry/kernels` 尚不存在，`df -k` 失败导致状态页显示 `free_kb=0`、并可能误报空间不足。已改为向上找到已存在父目录再测。
- 非当前内核的版本仍被「不能卸载当前启用的版本」拦截（因为该内核的 `active` 指针还指向它）。已改为仅拦截**当前 UCI 内核**的启用版本，并在删除该指针目标时同步清理 `active` 指针与 `/usr/bin` 链接。
- 镜像测速原先依赖 `timeout` 限制整包下载，未限时环境下会拖到 30s+ 导致 ubus 调用超时。已改为后台取样 6 秒后终止。


断言覆盖：procd 服务启动/停止与进程退出、菜单与 ACL JSON 就位并可被 `jsonfilter` 解析、prerm/pre-deinstall 实际执行（在包内 `uninstall.sh` 插入标记文件后卸载，标记被写出）、nft 表与 iptables 兼容链清空、TPROXY 策略路由删除、dnsmasq 上游恢复到原始值、`/etc/ferry` 与 `/etc/config/ferry` 按预期保留。

### 9.1.2 覆盖安装（升级）矩阵（r10，QEMU x86_64 / OpenWrt 24.10.4）

| 路径 | 旧状态构造 | 结果 |
| --- | --- | --- |
| r9 + v1 `mirrors.json`（用户故障现场） | r9 安装后写入无 `"version": 2` 的镜像文件 | **复现**：`kernel.sh mirrors` 6 秒不返回（递归进程 301 个）→ 前端永久「加载中」 |
| r9 → r10 | 同上，直接覆盖安装 | PASS：版本清单 6 条、`list=builtin`、ubus mirrors ok、镜像 5 条、`mirrors.json` 已是 v2、自定义前缀 `my.example` 保留 |
| r6 → r10 | r6 真实写入 v1 | PASS：6 条 / 5 条 / v2 |
| r7 → r10 | — | PASS：6 条 / 5 条 / v2 |
| r8 → r10 | — | PASS：6 条 / 5 条 / v2 |
| r9 → r10（v2 数据） | — | PASS：6 条 / 5 条 / v2 |
| r10 → r10 重装 ×2 | 同版本重装（对应「r9→r9」在 r10 下的对照） | PASS：6 条 / 3 条 / v2 / 下载地址可取 |
| 全新 r10（对照） | 无旧文件 | PASS：6 条 / 5 条 / v2 |

断网与最坏情况（同一 VM，`MATRIX_FAIL=0`）：

| 场景 | 用户看到 | 系统日志/job |
| --- | --- | --- |
| GitHub 不可达 + DNS REFUSED（`uclient-fetch` rc=4，0 字节） | 版本清单仍 6 条、镜像 5 条、`chain=github ghfast ghproxy` | job `failed / ERR_NETWORK`，message「所有候选源都下载失败（已尝试：github ghfast ghproxy）；请检查网络/DNS/证书，或改用本地导入」 |
| 只启用 github 单源 | `selected=auto`、`chain=github` | 保存后 `mirrors.json` 仍是 v2（不再被迁移重置） |
| `/etc/ferry` 空间不足（tmpfs 256k） | 明确提示需要多少空间 | job `ERR_DISK_FULL`，message「空间不足：/mnt/tiny/kernels 可用 0 MB，需要至少 138 MB…」 |
| 无 `ca-bundle` / 无 `libustream` | 依赖段标红 + HTTPS 探测 rc≠0 | 下载失败落 `ERR_NETWORK`，不会显示「暂无版本」 |

**r10 命中并修复的真实缺陷**：① 旧 mirrors.json 迁移无限递归（列表空/永久加载中的根因）；② rpcd ACL 漏声明 `source_set`/`store_set`（LuCI 会话调用被拒）；③ 前端无 `catch`/被 `!state.mirrors` 门控（任一 RPC 失败即永久加载中）；④ busybox `sed` 不支持 `0,/re/` 导致镜像保存写回 v1、下次读取触发迁移重置用户勾选；⑤ `ferry-kernel-diag` 的 `generated=` 双前缀与 ACL 覆盖自检缺失。

### 9.2 静态检查

- 所有 shell 脚本 `sh -n` 通过（init.d、common.sh、nodes.sh、rules.sh、generate.sh、firewall.sh、uci-defaults、`scripts/build.sh`、`scripts/fetch-kernel.sh`）。
- 全部 LuCI 视图与模块（`main.js`、`nodes.js`、`rules.js`、`presets.js`、`deploy.js`、`profiles.js`、`links.js`、`preset-defs.js`、`store.js`）通过 `node --check`；`menu.d` / `acl.d` 通过 JSON 解析。
- `Makefile` 静态校验：`PKG_NAME` 全小写、`PKG_VERSION` 不含 `-`、`PKG_RELEASE` 为整数、两处 `include` 齐备、`PKGARCH:=all`、`conffiles` 声明。
- 伪造 `/etc/apk`、`/etc/opkg` 与对应的 `apk`/`opkg` 命令，验证 `pm_pkgmgr`、`pm_pkg_installed`、`pm_pkg_install_hint`：apk 分支输出 `apk` / `apk info -e` / `apk add --allow-untrusted`，opkg 分支输出 `opkg` / `opkg list-installed` / `opkg install`；空目录返回 `none`。
- 伪造 SDK 测 `scripts/build.sh`：`CONFIG_USE_APK=y` 识别为 apk 并收集 `.apk`，缺省识别为 ipk 并收集 `.ipk`，产物落到 `dist/apk` / `dist/ipk`。
- 依赖包名只做了“与已知 feed 命名对照”的静态核对；**没有** feeds 索引可查，apk 分支的 `kmod-nft-*` 等未在线确认。

**离线回归**

`tests/` 下 6 个脚本在当前源码上重跑，合计 264 项断言全 PASS：`test-dnsmasq.sh` 26、`test-firewall.sh` 21、`test-uninstall.sh` 26、`test-rules.sh` 26、`test-generate.sh` 20、`test-kernel.sh` 145（32 节，含 r10 新增的升级迁移、断网、ACL、前端 404/未知方法/超时反例、镜像保存不写回 v1）。

其中 `test-kernel.sh` 用本机 `http.server` 充当**下载源（mock，非外网）**，配合真实 `sing-box` / `mihomo` 二进制覆盖：全新安装与激活、安装不激活、同内核切换、回滚、跨内核切换、卸载非当前版本（含 active 指针清理）、SHA-256 不匹配不落位、缺校验需显式确认、架构不匹配拒绝、未适配版本拒绝、版本矩阵 A/B/C/D 模板字段、`sing-box check` / `mihomo -t` 门禁、作业进度写入。**mock 与真机分开标注**：这一套属于离线 mock；真机结果见 9.1.1。

**LuCI 类加载器契约（`tests/test-luci-contract.mjs`）**

`node tests/test-luci-contract.mjs` 用最小化的 `Class.extend` / `isSubclass` 模拟 LuCI 的 `L.require()`：把每个 `resources/ferry/*.js` 与 `view/ferry/*.js` 当 factory 求值，断言返回的是 constructor（不是普通对象/Promise），再实例化并断言对外 API 可调用（如 `presets.buildRules('daily')` 返回 9 条、`links.parse('ss://…')` 返回 1 个节点）。同时静态拦截直接使用 `form.Select` 的写法（24.10.4 起已并入 `form.ListValue`）。这一层是 `node --check` 覆盖不到的“语义契约”盲区。

**配置生成与内核自检（x86_64 二进制）**

节点样本：7 类 mock 节点（vmess ws+tls、vless reality+grpc、ss+obfs、ssr、trojan ws、hysteria2 obfs、tuic）、9 条分类规则、4 条自定义条目，配合真实规则缓存（MetaCubeX `meta` `.yaml` 与 `sing` `.srs`，16 个 geosite）。下表 8 组最初用 mihomo 1.19.0 / sing-box 1.14.4 的 **x86_64** 二进制（darwin-amd64-compatible + Rosetta 2）跑自检；随后在 QEMU（Linux x86_64）换成 mihomo `linux-amd64-compatible` 复跑 `-t`，同样通过。

| # | 内核（x86_64） | 部署形态 | 模式 | 校验命令 | 结果 |
| --- | --- | --- | --- | --- | --- |
| 1 | mihomo 1.19.0 amd64-compatible | 主路由 | TPROXY | `mihomo -t -d ... -f config.yaml` | PASS |
| 2 | mihomo 1.19.0 amd64-compatible | 主路由 | TUN | 同上 | PASS |
| 3 | mihomo 1.19.0 amd64-compatible | 旁路由 | TPROXY | 同上 | PASS |
| 4 | mihomo 1.19.0 amd64-compatible | 客户端 | —（mixed） | 同上 | PASS |
| 5 | sing-box 1.14.4 amd64 | 主路由 | TPROXY | `sing-box check -c config.json -D ...` | PASS |
| 6 | sing-box 1.14.4 amd64 | 主路由 | TUN | 同上 | PASS |
| 7 | sing-box 1.14.4 amd64 | 旁路由 | TPROXY | 同上 | PASS |
| 8 | sing-box 1.14.4 amd64 | 客户端 | —（mixed） | 同上 | PASS |

- 上一轮同一套配置用 arm64 内核也全部 PASS；本次已按要求改用 x86_64 二进制重跑，结果以上表为准。
- 额外用 `tun + bypass` 复核：mihomo `auto-route: false`、sing-box `auto_route: false`，均通过内核自检。
- 形态差异确认：客户端 mihomo 只有 `mixed-port`、sing-box 只有 `mixed-in`；主路由 TPROXY 生成 `tproxy-port` / `tproxy-in` + `dns-in`。
- sing-box 侧 SSR 被跳过并写入 `status.json` 告警（`nodes=7`，代理 outbound 6 个）。
- mihomo `proxies` 逐字段核对：`servername`（vmess/vless）与 `sni`（trojan/hysteria2/tuic）分开，`reality-opts`、`ws-opts.headers.Host`、`grpc-opts.grpc-service-name`、SS `plugin-opts`、SSR `protocol/obfs` 均符合预期。

**仍未验证（别当成已验证）**

- TPROXY/TUN 的**真实客户端流量转发**：QEMU 里只断言了规则、策略路由、进程与配置，没有真实终端跑流量。
- ARM/MIPS 等非 x86_64 架构；本包本身 `Architecture: all`，但内核二进制需自行匹配架构，未实测。
- sing-box 路径已在 QEMU 上实际切换并启动（1.8.14 / 1.10.7 / 1.11.0 / 1.14.4 各自 `check` 通过、进程存活），但**真实终端流量**仍未验证。
- 真实手机/电视/游戏机等终端接入；旁路由真实拓扑连通性；ferry 自己的节点页没有延迟测试（面板在 mihomo 下可看逐节点延迟）。
- 上游订阅与规则集在真实网络下的下载行为（离线测试用本地缓存）。
- apk 签名/信任链：发布包未签名，必须 `--allow-untrusted`。
- LuCI 在 23.05 的具体渲染、`ui.showModal` 回调、`fs.exec` 提权行为。
- 面板包只在 OpenWrt 24.10.5 + ipk 上实测；apk 分支与 ImmortalWrt 未单独跑面板。
- 面板的真实 LAN 客户端访问（手机/电视/WLAN）未实测：验证是通过宿主侧 SSH 隧道访问 `192.168.1.1:9090` 完成的。

### 9.3 面板与双包验证明细（r14）

| 项 | 方法 | 结果 |
| --- | --- | --- |
| mihomo 下页面与只读 | headless Chrome + DOM 断言（不依赖截图） | 27/27 PASS：登录、状态表、「面板」页 iframe 首屏、能力表、`GET /version` 200、`PUT /proxies/{group}` 放行、`PUT /configs` 403、未打补丁页面对照非 403 |
| sing-box 下能力降级 | 同上，切内核后复跑 | 21/21 PASS：内核识别为 sing-box、四项能力置灰、横幅提示、规则页入口隐藏且不白屏、只读 403 仍生效 |
| 监听与密钥 | guest 内 `netstat`/`ls` | 仅 `192.168.1.1:9090`（mihomo）或同地址（sing-box）；secret 0600、32 位 hex，仅出现在内核配置里 |
| 双包校验 | `scripts/ci/verify-pkgs.sh` | 主包 39 文件、面板包 51 文件；ipk/apk 四包内容均与源码树逐文件全等 |
| 主包 RESTORE | 冻结包 `opkg install --force-reinstall` + `md5sum -c` | 返回 0，38/38 OK |
| 面板卸载 | 冻结面板包 + `ferry-panel enable` → 计时 `opkg remove` | 5.46 s，`REMOVE_RC=0`，返回瞬间 9090 无监听 |
| 卸载后还原 | 卸载后快照 | UCI/secret/静态目录/licenses/`ip ferry_panel` 全无；两内核注入 0 处；主包 `ferry`/`ferry6` 表与 dnsmasq 上游不变 |

---


## 10. 排障命令

```sh
/etc/init.d/ferry status
logread -e ferry | tail -n 50
nft list table ip ferry
nft list table ip6 ferry6
iptables -t nat -S PM_DNS; iptables -t mangle -S PM_TPROXY
ip rule show; ip route show table 100
netstat -lntup | grep -E '7890|7891|1053'
uci show ferry
ps w | grep -E 'mihomo|sing-box'
```

---

## 许可证

GPL-2.0（GNU General Public License v2.0），全文见 [LICENSE](LICENSE)。

