# Ferry 内置 Dashboard 方案（zashboard 类面板）

> 状态：方案已落地为**独立可选包** `luci-app-ferry-dashboard`（1.0.0-r14），不并入主包。本文保留方案论证；正式的版本约束与升级复核清单见 §13。
> 标注约定：**【实测】** = 在 QEMU guest 里真实跑出来/真实浏览器点出来；**【推断】** = 由代码、文档或协议常识推导，未单独验证。

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| 两个内核能否共用同一个面板 | **能，但只有一个可行载体：zashboard 3.22.x（最后一个支持 sing-box 的版本）**。3.23.0 起官方移除了 sing-box 兼容【实测：官方文档 + 面板内弃用弹窗】 |
| 能否做到“不开额外浏览器” | 能：面板静态文件由 uhttpd 托管，LuCI 页面里用 iframe 内嵌。已用真实浏览器验证 iframe 可正常渲染【实测】 |
| 只读是否可配置 | **不行**。zashboard 3.22 的写操作 UI 集中在「设置 → 后端」，没有任何“只读”开关【实测】。只能打补丁或接受风险 |
| 推荐路线 | **路线 A（内嵌静态面板）的受限版**：固定 zashboard 3.22.0 + 只读补丁 + uhttpd 托管 + LAN-only API + secret。若不愿维护补丁，退到路线 B（只给入口），但会牺牲“不开额外浏览器” |
| 路线 C（ferry 归一化层） | 不推荐现在做：需要带 WebSocket 的独立守护进程，工作量大、收益主要是同源与严格只读，而面板本身仍要改 |

---

## 1. 实测环境与方法

- 平台：OpenWrt 24.10.5 x86_64，QEMU TCG，**512MB 内存 / 1 vCPU**（低配口径，无 KVM）。
- 内核：mihomo v1.19.31、v1.19.32、v1.19.33（内置清单里的全部 mihomo 版本）；sing-box v1.14.4（内置清单里唯一的 sing-box 版本）。
- 面板：zashboard **3.22.0**（`dist-no-fonts.zip`，MIT），解包后由 guest 的 uhttpd（:80）静态托管，Windows 侧经 QEMU hostfwd 访问。
- sing-box 侧配置：`experimental.clash_api.external_controller = 0.0.0.0:19090`、`secret = ferrytest`，含一个 `selector` 出站。
- mihomo 侧配置：`external-controller = 0.0.0.0:19090/19091`、`secret = ferrytest`、一个 select 组 `G`、一个 url-test 组、一个不可用节点 `n1`。
- 浏览器验证：真实 Chrome（经 IDE 浏览器自动化），分别以「独立页」「iframe 内嵌」两种形态打开。

---

## 2. 覆盖度矩阵（逐端点实测）

图例：✅ 完整可用；🟡 部分可用/语义不同；❌ 不可用。

| 端点 | mihomo 1.19.31 | 1.19.32 | 1.19.33 | sing-box 1.14.4 |
|---|---|---|---|---|
| `GET /version` | ✅ | ✅ | ✅ | 🟡 返回 `{"version":"1.14.4","premium":true}`，字段语义与 mihomo 不同 |
| `GET /proxies` | ✅ | ✅ | ✅ | 🟡 只映射出站：`GLOBAL` + 自定义 selector/direct/block；无 provider 节点 |
| `GET /proxies/{name}` | ✅ | ✅ | ✅ | ✅（名字大小写敏感，`direct` 而非 `DIRECT`） |
| `PUT /proxies/{group}` 切节点 | ✅ | ✅ | ✅（204） | ✅（204，实测 sel→block→direct） |
| `GET /proxies/{name}/delay` | ✅ 端点存在 | ✅ | ✅ | 🟡 端点存在，失败只回通用错误（无 history/延迟明细） |
| `WS /traffic` | ✅ 101 | ✅ | ✅ 101 | ✅ 101 |
| `WS /logs` | ✅ 101 | ✅ | ✅ 101 | ✅ 101 |
| `GET /connections` | ✅ | ✅ | ✅ | ✅ |
| `GET /configs` | ✅ 1.5KB | ✅ | ✅ | 🟡 仅 ~187B：无端口、无 tun、无 secret，字段大量缺失 |
| `PATCH/PUT /configs`（写配置） | ✅ 接受（空 body 400，结构化 body 可写入）【推断：接口存在且面板在用】 | ✅ | ✅ | ❌ 400 `Body invalid`【实测】 |
| `GET /providers/proxies` | ✅ | ✅ | ✅ | 🟡 返回 `{}`（sing-box 无 provider 概念） |
| `GET /rules`（含命中计数） | ✅ 含 `hitCount` | ✅ | ✅ | ❌ 返回 `null`（无规则命中测试） |
| `GET /memory` | ✅ | ✅ | ✅ | ✅ |
| `GET /dns/query` | 🟡 本次配置未启用 DNS → 500 | 🟡 | 🟡 | ✅ |
| `POST /restart` | ✅ 200 | ✅ | ✅ | ❌ 404 |
| `POST /upgrade`、`/upgrade/ui` | ✅【推断，面板存在该按钮】 | ✅ | ✅ | ❌ 404 |

**矩阵结论**

- mihomo 三个内置版本在 API 语义上没有可观察差异【实测】。
- sing-box 的特征是：**代理组/连接/流量/日志四项完整可用，配置/规则/provider/自检类端点缺失或语义不同**。
- 因此「完整可用」仅限于：看代理组、切节点、看连接、看实时流量、看日志。
  「规则命中测试」「provider 管理」「配置编辑/重载/重启/升级」在 sing-box 下不可用。

### 面板真实渲染验证【实测】

- zashboard 3.22.0 + mihomo 1.19.33：代理页显示组 `G`、`DIRECT`，无报错。
- zashboard 3.22.0 + sing-box 1.14.4：代理页显示 `sel`（SELECTOR）与 `direct`/`block`，可正常渲染；同时弹出「即将移除 sing-box 支持」的官方提示。
- 同一构建、同一页面，仅切换 API 端口即可在两个内核间切换，无需第二套面板。

---

## 3. 跨域（CORS）

真实浏览器场景不是“例外”而是默认：面板静态文件由 uhttpd（`:80`）提供，API 在 `:9090`，二者必然跨源；sing-box 没有 `external-ui`，静态面板只能外挂。

实测（带 `Origin` 的 GET + OPTIONS 预检，再用真实浏览器访问）：

| 项 | mihomo 1.19.33 | sing-box 1.14.4 |
|---|---|---|
| `Access-Control-Allow-Origin` | `*` | `*` |
| 预检 `Access-Control-Allow-Methods` | 回显请求方法（GET/PUT/PATCH 均可） | 回显请求方法 |
| 预检 `Allow-Headers` | 允许 `authorization, content-type` | 允许 |
| 真实浏览器跨源面板 | **通过** | **通过** |

注意：mihomo 的 CORS 行为由 `external-controller-cors` 控制（`allow-origins` 默认 `*`）。若收紧成白名单，必须把面板自身的 origin 写进去，否则面板会直接失效【推断：配置项语义来自官方文档，未做收紧实验】。
`Access-Control-Allow-Origin: *` 的实际风险：同一浏览器里任意网页都能向 `:9090` 发请求；有 secret 时只能拿到 401，无 secret 时可被任意网页读取流量与连接信息【实测响应头 + 推断攻击面】。

---

## 4. 统一端口与 secret 模型

- 两个内核都支持把 Clash API 绑到任意地址/端口，并支持 `secret`：
  - mihomo：`external-controller: <ip>:9090` + `secret: <token>`
  - sing-box：`experimental.clash_api.external_controller` + `experimental.clash_api.secret`
- **单内核运行**时“同一端口、同一 secret”成立：ferry 生成配置时写同一个 `9090`/同一 token，面板无需感知内核类型【实测：两者各自绑定 19090 均成功】。
- **两个内核同时运行**：同地址同端口必然冲突。实测在 mihomo 占用 `0.0.0.0:19090` 时启动 sing-box 同端口，进程直接绑定失败退出（EADDRINUSE）。ferry 的进程模型本来就是“只跑一个内核”，所以这不是问题；但**不要**为了“双内核热切换”同时起两个。
- 若确实要同时运行，只能让它们绑不同地址（如 mihomo `127.0.0.1:9090`、sing-box `192.168.1.1:9090`），面板再按当前内核选地址【推断，未实测双实例并行】。

### secret 生成与存储（建议，未实现）

- 首次启用面板时生成：`head -c 32 /dev/urandom | hexdump -e '16/1 "%02x"'`（busybox 可用），或 `tr -dc 'a-f0-9' </dev/urandom | head -c 32`。
- 存到 `/etc/ferry/controller.secret`，权限 `0600`；**写入生成后的 config.yaml**，不写进静态文件、不写进面板包。
- LuCI 只返回一个 URL，secret 放在 **hash 段**：`/zash/#/setup?hostname=<lan-ip>&port=9090&secret=<token>`。hash 不会进入 uhttpd access log / Referer【推断：浏览器行为标准】。
- 轮换：LuCI 提供“重置 secret”，改文件 + 重新生成配置 + 重载内核；面板需重新输入一次。
- 局限：zashboard 会把后端地址与 secret 存进浏览器 localStorage【推断：README 描述“保存后端”】；同一台电脑上的其他用户可读到。LAN 内单用户场景可接受，公用电脑需提示。

### 暴露面与防火墙

- 监听地址不要用 `0.0.0.0`：直接写 **LAN 地址**（如 `192.168.1.1:9090`），从绑定层就排除 WAN。
- 再加一层 fw4：只允许 `lan` 区域访问 9090，`wan` 拒绝。即使 UCI 被改成 `0.0.0.0` 也不至于裸奔【推断：需在 fw4 加 rule，未在本次实测中落地】。
- **9090 无 secret 的风险（实测基础）**：`/version` 无鉴权返回信息；带 secret 时无 token 一律 401。无 secret 时，LAN 内任何人（以及浏览器里任意网页，因为 ACAO=`*`）都能读连接、切节点、改配置、重启内核。
- **为什么 WebSocket 不能靠 uhttpd 反代**：uhttpd 是单线程静态/CGI/Lua 服务器，**没有通用反向代理能力**；BusyBox httpd 的 `P*` 代理也不支持 `Upgrade`。而面板的实时流量/日志/连接都走 WebSocket（实测 `/traffic`、`/logs` 均 101）。要让面板经同源代理工作，必须引入 nginx/haproxy 或自写支持 WS 的守护进程——这正是路线 C 的成本所在。
  因此：**面板直连 `:9090`（LAN-only + secret），不要试图经 uhttpd 反代**。

---

## 5. 双写冲突：LuCI 与面板都会改 config.yaml

### 实测事实

- zashboard 3.22.0 的「设置 → 后端」暴露了完整写操作 UI【实测，逐项点出】：
  - 内核运维：**更新配置、重载配置、重启核心、升级核心、更新 GEO、清空 DNS 缓存、清空 Fake IP**
  - 网络监听：Mixed/HTTP/Socks/Redir/TProxy 端口输入、Tun 开关、允许局域网开关（修改即写配置）
- 打包产物里也确实存在写接口调用：`PATCH /configs`、`PUT /configs`、`PUT /configs?reload=true`、`POST /restart`、`POST /upgrade`、`POST /upgrade/ui`、`PUT /providers/proxies/{name}`、`DELETE /connections`【实测：扫描 3.22.0 的 JS bundle】
- 唯一可用的隐藏参数只有 `disableUpgradeCore=1`、`disableTunMode=1`（隐藏“升级核心”和 Tun 开关）【实测：README】，**没有任何 read-only / 隐藏配置编辑的开关**。
- 结论：**靠配置约定做不到只读**。面板确实能改 `config.yaml`（mihomo 的 `PUT /configs` 会写内核工作目录里的配置文件），与 LuCI 的“生成配置 + 事务回滚”模型直接冲突。

### 技术层面的三种只读方案

| 方案 | 做法 | 代价 | 可行性 |
|---|---|---|---|
| A1 打补丁（推荐） | fork zashboard 3.22.0（MIT），构建时移除“设置→后端”的写操作区与端口输入；其余页面保留 | 需要一次源码级改动 + CI 构建；因上游已停止 sing-box 支持、版本被钉死，无需持续 rebase | 高【推断：改的是前端 UI，接口仍在但 UI 不可达；需要防绕过的话再加一层方法白名单】 |
| A2 网络层只读 | 面板前置一个只放行 `GET` + `PUT /proxies/{group}` 的代理 | 需要支持 WS 的代理进程（uhttpd 做不到），等于路线 C | 中，成本高 |
| A3 语义只读 | 把 `config.yaml` 视为“ferry 生成的临时产物”，面板写入不持久，LuCI 下次应用即覆盖 | 面板仍可 `PUT /configs` 指向别的文件、`POST /restart`，能造成运行态与 LuCI 状态不一致；**不安全** | 低 |

推荐 A1：只读由 UI 消失来保证，而不是靠文档。补丁必须同时屏蔽 `PUT/PATCH /configs`、`POST /restart`、`POST /upgrade*` 的入口；若要更强保证，再配合 A2 的方法白名单（但那时就需要独立守护进程）。

---

## 6. 三条路线对比

### 路线 A：内嵌静态面板（mihomo `external-ui` / 通用静态托管）

- 形态：面板文件随 ferry 安装；mihomo 可用 `external-ui` 直接由内核托管（同源，`:9090/ui`）；sing-box 无此能力，只能由 uhttpd 托管，API 仍直连 `:9090`（跨源）。
- **包体增量**【实测】：`dist-no-fonts.zip` 2.9MB，解包 5.6MB（16 个文件）；ferry 当前 ipk 114KB。若把面板打进 ipk（gzip 后约 1.5–2.9MB），安装体积增加约 5.6MB。
- 许可：zashboard **MIT**【实测：仓库 LICENSE】；打包义务 = 附版权声明与许可证全文，无源码开放义务。mihomo/sing-box 为 GPL-3.0，但 ferry 现在是“运行时下载内核”，不随包分发二进制，不触发额外源码义务；**不要把内核二进制打进 ipk，否则要履行 GPL 分发义务**。
- 升级耦合：面板与内核 API 版本耦合。面板钉死 3.22.0（因为 3.23+ 移除 sing-box），内核若升级到改动 API 的版本，面板可能失效；反之面板不能再升级。**这是长期维护成本的主要来源**。
- 体验：LuCI iframe 内嵌，切代理/看连接/看流量都在一个页面里【实测可渲染】；sing-box 下规则页/设置页部分空白或报错（见降级方案）。
- 只读：必须打补丁（见 §5）。

### 路线 B：只提供“一键启用”入口

- 形态：ferry 只做三件事：启用 `external-controller`、生成/注入 secret、在 LuCI 给出地址与二维码/链接；面板不打包。
- 包体增量：0；许可义务：0（不随包分发）。
- 升级耦合：面板与 ferry 完全解耦；用户自选面板与版本。
- 体验：**要另开浏览器/新标签**，且在线面板（board.zash.run.place）需要面板能访问路由器 API，等价于把 9090 暴露给浏览器所在网络；离线场景还得自己下载面板。不满足“不再需要额外面板/不另开浏览器”的核心目标。
- 只读：同样做不到；只是把风险交给用户。

### 路线 C：ferry 归一化层（面板只跟 ferry 说话）

- 形态：ferry 提供一个同源 HTTP+WS 服务：`/api/*` 归一化两个内核的语义，静态面板同源托管；写方法（配置/重启/升级）一律 404，只放行 `GET` 与 `PUT /proxies/{group}`；能力探测结果注入前端，隐藏不支持的页。
- 收益：同源（彻底消除 CORS 与 secret 进 URL 的问题）、严格只读（服务端强制，不靠 UI）、两个内核的差异被吸收、以后换面板也不用再改路由。
- 成本【推断】：需要一个支持 WebSocket 的守护进程（Go/C，不能用 uhttpd+Lua）；估 500–800 行核心逻辑 + 打包/开机/守护；额外常驻内存约 4–8MB、二进制约 1–1.5MB；规则/配置/provider 的语义映射需要逐字段对齐；工作量为“周”级而不是“天”级。
- 且：面板 UI 仍会渲染配置编辑入口（只是点了报错），所以**路线 C 也躲不掉打补丁**，收益只剩“同源 + 服务端只读 + 隐藏能力”。
- 结论：作为**兜底**保留，不建议第一版做。

### 取舍结论

| 维度 | A 内嵌面板 | B 仅入口 | C 归一化层 |
|---|---|---|---|
| 满足“不开额外浏览器” | ✅（iframe） | ❌ | ✅ |
| 两内核同一面板 | ✅（仅 zashboard 3.22） | ✅（用户自选，未必支持 sing-box） | ✅ |
| 包体增量 | +5.6MB 安装 / +1.5–2.9MB 包 | 0 | +1–1.5MB 二进制 + 守护进程 |
| 许可义务 | MIT 声明 | 无 | 自己代码 + MIT 声明 |
| 只读（技术强制） | 需打补丁；补丁后可保证 UI 不可达 | ❌ | ✅（服务端强制） |
| 升级耦合 | 高（面板钉死） | 无 | 中（归一化层要跟两个内核） |
| 维护成本 | 一次性补丁 + sing-box 已停更 | 最低 | 最高 |

**推荐：路线 A（受限版）**。理由：唯一同时满足两个核心目标的方案，且已用真实浏览器验证可用；代价是包体 +5.6MB、面板钉死 3.22.0、需要一次性只读补丁。
**备选：路线 B**，如果明确不接受包体/补丁维护；但要接受“要另开浏览器/自备面板”。
**路线 C：暂不做**，只有当后续要求“严格只读 + 未来自由换面板”时才值得投入。

---

## 7. 面板如何降级（不报错、不空白）

按能力探测结果做静态开关，而不是让页面自己撞墙：

1. **先探测能力**：`GET /version` → 判断 `version` 含 `sing-box` 或字段里没有 mihomo 的 `meta`；再探 `GET /rules`（`null` vs 数组）、`GET /providers/proxies`（`{}` vs 非空）、`GET /configs`（是否含 `port`/`tun`）。
2. **按结论写前端开关**（ferry 在返回面板 URL 时附带 `?cap=rules=0&config=0` 之类的参数，或由补丁版前端读一次探测结果缓存）：
   - sing-box：隐藏「规则」页命中测试列、隐藏「provider」入口、隐藏「设置→后端」的端口/Tun/升级区；
   - 延迟测试失败时提示“该内核仅返回通用错误”，不展示红色异常；
   - 配置页改为只读展示（或整页隐藏）。
3. **空状态**：面板入口未启用 / 内核未就绪 / API 401 时，LuCI 侧显示明确文案（“未启用外部控制”“secret 不匹配”“当前内核不支持该功能”），而不是把 iframe 指到一个会白屏的地址。
4. **不建议**在未打补丁的面板上直接连 sing-box 的后端设置页：实测其 `/configs` 字段大量缺失，端口/Tun 控件读不到值，操作大概率报错【实测：/configs 仅 187B；UI 行为为推断】。

---

## 8. 内核不匹配的空状态

- 当前内核是 sing-box 时：
  - 若生成配置里**没有** `experimental.clash_api`（历史配置/用户手改），面板入口必须显示“sing-box 未开启 Clash API”并给出一键补开的动作，而不是把面板指向 9090 后超时。
  - 若已开启但 `secret` 为空：拒绝启用面板（或强制生成 secret），因为 ACAO=`*` 时无 secret 等于对 LAN 全开【实测算据见 §3/§4】。
- 切换内核（mihomo↔sing-box）时：同一端口/同一 secret 可以复用，但面板需要重新探测能力并刷新 iframe（否则会保留上一内核的规则页/设置页 DOM）【推断：面板自身有后端切换逻辑，但未实测跨内核热切】。
- 内核正在安装/未启动：面板入口置灰，提示“内核未运行”，不要显示 API 连接错误。

---

## 9. 许可与打包义务

| 组件 | 许可证 | 打包义务 |
|---|---|---|
| zashboard 3.22.0 | **MIT**【实测：LICENSE 全文】 | 随包附 MIT 许可证全文 + 版权声明（`Copyright 2024 Zephyruso`）；可闭源分发 ferry，无 copyleft |
| mihomo | **GPL-3.0**【实测：pkg.go.dev 元数据】 | 若把二进制打进 ferry 包，必须提供对应源码/书面要约；**建议维持现状：运行时下载，不随包分发** |
| sing-box | GPL-3.0（以仓库 LICENSE 为准，需打包前复核）【推断：未取到全文】 | 同上，运行时下载可规避 |

其他注意：
- 面板的字体版（`dist.zip` 7.81MB）可能带第三方字体许可，**用 `dist-no-fonts` 或 `dist-cdn-fonts`**【推断：README 区分字体来源，未逐项核对字体许可】。
- 面板内“检查核心升级/自动升级”会从 GitHub 拉包，若打包必须去掉（同时避免不可控外联）。

---

## 10. 低端机开销预判

【实测，QEMU 512MB/1vCPU】
- 静态托管由 uhttpd 完成：**uhttpd RSS ≈ 1.6MB**（面板打开时），不新增常驻进程。
- 面板打开时，浏览器到 `:9090` 的 **ESTABLISHED 连接数：单标签约 12 条**；多个标签/多次打开时实测到 **29 条**（含 `/traffic`、`/logs`、`/connections` 的 WS 与轮询复连）。每条连接都会占 conntrack 表项与内核 socket 内存。
- flash 占用：**5.6MB**（解包）；若打进 ipk，包体 +约 1.5–2.9MB。

【推断】
- 浏览器侧：zashboard 首屏 JS/CSS 约 1.4MB（无字体版），Chrome 内存增量约 30–60MB；这是客户端成本，不在路由器上。
- 路由器侧 CPU：静态文件发送是 uhttpd 单线程 `sendfile` 级别，低端机可接受；真正的开销来自**多条 WS 长连 + 每秒流量推送**，以及 conntrack 表压力。若并发面板用户 >2，建议限制到 LAN 单用户使用。
- 不建议在 128MB 设备上引入路线 C（额外 4–8MB 常驻 + WS 转发）。

---

## 11. 实施前置决策（需要确认）

1. 是否接受 **包体 +5.6MB（ipk +约 1.5–2.9MB）** 与面板钉死 3.22.0？
2. 是否接受 **维护一次 zashboard 只读补丁**（MIT 允许；此后不再跟随上游升级）？
3. 是否接受 **面板直连 LAN `:9090`**（不能用 uhttpd 反代 WS），并要求 secret + 防火墙 LAN-only？
4. 是否现在就做路线 C（归一化层）？建议：**不做**。

确认后按路线 A 的受限版落地：内核生成配置注入 `external-controller`（LAN 地址）+ secret → fw4 仅 LAN 放行 → 安装 zashboard 3.22.0（打补丁）到 `/www/zash` → LuCI 增加“面板”入口（iframe + 打开新标签）→ 能力探测与空状态。

---

## 12. 本次未验证 / 仅推断的清单

- mihomo 1.19.31/1.19.32 的 `PUT /proxies/{group}`、`/upgrade`：只验证了端点存在与 1.19.33 的写操作，未逐版本做写测试。
- zashboard 补丁后的实际可用性：只确认了写 UI 的位置与接口，没有真的打补丁构建。
- sing-box 在“生成配置中开启 clash_api”的完整链路：r14 已实现（注入 `experimental.clash_api` 并通过 `sing-box check`），本清单保留原始记录。
- 双实例并行（两个内核同时监听不同地址）与面板切换：仅实测了同端口冲突。
- 25.12 / apk 侧的同等验证：本次只在 24.10.5 上做。
- 浏览器侧内存、并发多用户、长时间 WS 稳定性：未做长跑。

---

## 13. 版本钉死与升级复核（正式结论）

### 13.1 钉死 zashboard 3.22.0，禁止跟随上游升级

- 随包分发的面板**固定为 zashboard 3.22.0**（`dist-no-fonts.zip`，MIT），源码/bundle 放在 `dashboard/vendor/zashboard-3.22.0/`，打包脚本按该目录取文件；不存在“可选最新版”分支。
- 钉死的直接原因：**上游自 3.23.0 起移除 sing-box 支持**【实测：官方文档 + 面板内弃用弹窗】。ferry 的核心约束是“同一面板同时服务 mihomo 与 sing-box”，一旦跟随升级，sing-box 用户会直接失去面板。
- 第二个原因：只读补丁（`dashboard/patches/zashboard-3.22.0-readonly.patch`）是针对 3.22.0 的 bundle 做的，3.23+ 的构建产物结构变化会使补丁失效；跟随升级等于重做补丁并重新验证全部端点。
- 因此：**默认禁止升级，也不接受“先升到 3.23+ 再只修 mihomo”的做法**（那等于放弃 sing-box 面板能力，与 r14 的交付口径冲突）。
- 唯一允许升级的条件（必须同时满足）：
  1. 上游恢复 sing-box 支持，或明确放弃 sing-box 面板能力并经产品确认；
  2. 只读补丁在新版本上重建，且 §13.3 的验证全部通过。
- 版本号出现在三处，升级时必须同步：`dashboard/vendor/zashboard-3.22.0/`（目录名）、打包脚本里的 vendor 路径、本文件的钉死结论。

### 13.2 升级时必须重新核对的端点

面板的所有读写都落在下列端点；升级（或内核升级）后必须逐项复核，任何一项语义变化都要在能力探测里重新映射。

| 端点 | 面板用途 | 只读策略 | mihomo | sing-box |
|---|---|---|---|---|
| `GET /version` | 探测内核类型/版本、首屏连通性 | 放行 | 200 | 200（字段语义不同） |
| `GET /proxies` | 代理页、代理组列表 | 放行 | 200 | 200（仅出站） |
| `GET /proxies/{name}` | 代理详情 | 放行 | 200 | 200 |
| `PUT /proxies/{group}` | 切换节点 | **唯一放行的写方法** | 204 | 204 |
| `GET /proxies/{name}/delay` | 延迟测试 | 放行（失败只显示提示） | 200 | 部分失败/通用错误 |
| `WS /traffic` | 实时流量 | 放行 | 101 | 101 |
| `WS /logs` | 实时日志 | 放行 | 101 | 101 |
| `GET /connections` | 连接页 | 放行 | 200 | 200 |
| `GET /configs` | 设置页只读展示 | 放行 | 200 | 200（字段大量缺失） |
| `PATCH/PUT /configs` | 写配置/重载 | **403 拦截** | 被拦截 | 被拦截 |
| `GET /providers/proxies` | provider 页 | 放行（空则隐藏入口） | 200 | `{}` |
| `GET /rules` | 规则页 | 放行（`null` 则置灰） | 200 | `null` |
| `GET /memory` | 概览 | 放行 | 200 | 200 |
| `GET /dns/query` | DNS 查询 | 放行 | 视配置 | 200 |
| `POST /restart` | 重启内核 | **403 拦截** | 被拦截 | 404 |
| `POST /upgrade`、`/upgrade/ui` | 升级内核/面板 | **403 拦截** | 被拦截 | 404 |
| `PUT /providers/proxies/{name}` | 更新 provider | **403 拦截** | 被拦截 | 无此能力 |
| `DELETE /connections` | 清空连接 | **403 拦截** | 被拦截 | 无此能力 |

复核结论必须落到能力探测参数（`cap=rules/config/delay/restart/upgrade...`），并同步修改 LuCI 面板页的“置灰 + 说明”文案；只改前端不探测会导致升级后页面空白或报错。

### 13.3 复核方法（不依赖截图）

1. 用 `curl` 对每个端点断言状态码与关键字段（`/version` 带/不带 secret、`PUT /configs` 必须 403 于 shim 层、直连后端非 403 作为对照）。
2. 用真实浏览器做 DOM 断言：LuCI 页状态表、能力表文案、iframe 首屏元素数、只读横幅、只读 fetch 的 403、`/traffic` WS 可连、非只读 WS 立即关闭。
3. mihomo 与 sing-box 各跑一遍；sing-box 下还必须确认：`/rules` 为 `null` 时规则页不白屏、`/configs` 字段缺失时设置页只读展示、`POST /restart` 404 时不误报。
4. 通过标准：代理组可见、切节点成功、连接/流量/日志可用；除 `PUT /proxies/{group}` 外的写方法全部被 403；任何一项不满足即阻塞升级。

