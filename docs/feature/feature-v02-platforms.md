# v0.2.0：远端下载、跨平台控制端、arm64 与出口机白名单

> 2026-10-04 注记：方案已定，代码待落地。行号以 v0.1.0（`7d15d13`）为基线。
>
> 2026-10-05 注记：代码已落地并完成实测，结果与实施中的偏离见 §11。

## 1. 背景

v0.1.0 的链式脚本有四处限制：

1. **资产都从本机下载**：`prepare_verified_assets()`（`chain/setup_chain.sh:1612-1631`）在本机从 GitHub 下载 Linux 与 Darwin 两个官方包，再由 `install_remote_binary()`（`:3012-3037`）把 Linux 包 scp 到远端。控制端在国内时，本机访问 GitHub 常常卡住。
2. **控制端只支持 Apple 芯片的 Mac**：`require_local_dependencies()`（`:1528`）硬性检查 `Darwin arm64`；本机路由判断用 `route -n get`（`:3761`、`:3801`），端口探测用 `nc -G`（`:3447`、`:3776`、`:3807`），都是 macOS 专用写法。`multi_chain_client.sh` 同样（`:334`、`:553-561`）。
3. **远端只支持 amd64**：远端预检 `:1668` 只放行 `x86_64`；安装脚本写死 `linux-amd64` 目录（`:2990-2991`）。
4. **普通 VPS 当出口机时，Reality 端口对所有来源开放**：v0.1.0 用 `EXIT_SOURCE_FILTER=none` 把拒绝侧检查降为 WARN（`probe_mac_reality_rejection()`，`:3799-3815`），但没有办法真正只放行中转机。

另有一处稳健性问题：碰撞核证 `remote_path_absent()` 遇到一次 SSH 断开（rc=255）就判“不可达”退出 3，本机开着 TUN 时经常发生。

## 2. 目标 / 非目标

### 目标

1. 远端自己从 GitHub 下载固定版本的 sing-box 并校验 SHA256，失败时退回“本机下载、上传”；本机拿不到官方包时跳过本机侧出口验证，不再阻塞部署。
2. 控制端支持 macOS（Apple 芯片 / Intel）、Linux（amd64 / arm64，含 WSL）；远端支持 amd64 与 arm64。
3. 新增 `EXIT_SOURCE_FILTER=managed`：部署时在出口机加一张只放行中转机来源的 nft 表，`init` 默认 `managed`。
4. 碰撞核证对 SSH 断开重试一次。

### 非目标

- 不改状态文件和事务记录的字段名、不升级 `SCHEMA_VERSION`：v0.1.0 部署的链必须能被 v0.2.0 直接读取和管理。
- 不支持中转机与出口机架构不同（一条链两端必须同为 amd64 或同为 arm64）。
- 不支持 Windows 原生控制端（WSL 按 Linux 处理）。
- 不改直连（`direct/`）的功能；直连在 Linux 控制端上本来就没有 macOS 专用写法，只更新文档的支持矩阵。

## 3. 假设与约束

- 4 个官方包的归档与解压后 binary 的 SHA256 已用两种工具计算、并与 GitHub 发布页公布的摘要核对一致；linux-arm64 包与 linux-amd64 包一样带 `libcronet.so`。

  | 包 | 归档 SHA256 | binary SHA256 |
  | ---- | ---- | ---- |
  | linux-amd64 | `f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697` | `68aeab83cc4ab2659a5b92232261a20746ccdafc3b3d1e19b2d63247eec3bbf7` |
  | linux-arm64 | `4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e` | `85f570b96754cd7c354d28e50f66e9340b374e06b5d77ec9e15e8d04f0c87a25` |
  | darwin-amd64 | `5245d645e847f90bb708da74bc020ae078c28489690756419685c04f56b4e3bb` | `9e550c4cc3bdb8a6f3525bbaaf97624f517d1e37e0d5c76a439988483a5b27a6` |
  | darwin-arm64 | `73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab` | `813d8effd02a19572a8d75aef29fc073101404ca535b2496be86f21827c7684d` |

- 远端已经要求有 `curl`（中转机）或 `wget`（出口机）（预检 `:1702-1708`）和 `nft`（`:1683` 的 `common` 列表），所以远端下载与 nft 白名单不新增依赖。
- 出口机 sing-box 的 unit 是加固过的（`CapabilityBoundingSet=` 为空、`ProtectSystem=strict`，`write_prepare_exit_script()` `:3167-3176`），nft 命令必须用 `+` 前缀以完整权限运行。

## 4. 涉及模块

| 区域 | 行号锚点（v0.1.0） | 类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| 版本常量 | `chain/setup_chain.sh:21-25` | 修改 | 4 个包的归档与 binary 哈希常量；`LINUX_*` / `DARWIN_*` 从只读常量改为按平台选取的变量 |
| 本机平台 | 新增，邻近 `:224 sha256_text()` | 新增 | `local_platform()`、`route_interface()`、`interface_is_tunnel()`、`tcp_probe()` |
| 本机依赖 | `:1525-1537` | 修改 | 去掉 `Darwin arm64` 硬限制；按平台检查 `route`/`nc`（macOS）或 `ip`/`timeout`（Linux） |
| 本机资产 | `:1550-1631` | 修改 | 本机包可选（下载限时 120 秒，失败记为 `NONE`）；远端包只在回退时才在本机准备 |
| 远端预检 | `:1668`、`:1708-1710`、`:1800-1818` | 修改 | 放行 `aarch64`；输出 `REMOTE_ARCH`；两端架构必须一致；nft 只允许名为 `ownexit_*` 的表 |
| 碰撞核证 | `remote_path_absent()` | 修改 | rc=255 时重试一次 |
| 远端安装 | `:2967-3037` | 修改 | 先在远端下载归档，失败再本机上传；安装脚本按架构取目录 |
| 出口机 unit | `:3093-3192` | 修改 | `managed` 时加 `ExecStartPre=+nft ...` / `ExecStopPost=+nft delete table ...` |
| 中转出口 IP | 新增，邻近 `prepare_exit_exit()` `:3197` | 新增 | 在中转机上 `ip route get <出口机>` 取源地址，作为白名单放行的来源 |
| 本机验证 | `:3447`、`:3759-3815` | 修改 | 用跨平台辅助函数；没有本机包时跳过 smoke 并 WARN；`managed` 与 `provider` 一样是硬门槛 |
| 状态读取 | `:2562-2563`、`:2602`、`:2695`、`:4195-4199`、`:4262-4277` | 修改 | 按状态里的归档哈希反推远端架构与本机平台；`DARWIN_*` 允许 `NONE` |
| 配置 | `validate_config_values()`、`init` | 修改 | `EXIT_SOURCE_FILTER` 增加 `managed`；`init` 默认 `managed` |
| 多链聚合 | `chain/multi_chain_client.sh:24-25`、`:127-135`、`:334`、`:540-575`、`:600-610` | 修改 | 同样去掉平台限制，本机包按平台选取，路由与端口探测用跨平台写法 |
| 文档 | `README.md`、`README.zh-CN.md`、`chain/README.md`、`docs/manual/chain.md`、`CHANGELOG.md`、`chain/chain.example.env` | 修改 | 支持矩阵、`managed`、远端下载 |

## 5. 方案

### 5.1 实现要点

**5.1.1 平台选取**

- 本机平台 `local_platform()`：`uname -s`/`uname -m` 映射为 `darwin-arm64`、`darwin-amd64`、`linux-amd64`、`linux-arm64`，其它输出空串（视为没有本机包）。
- 远端架构：远端预检脚本输出 `REMOTE_ARCH=amd64|arm64`（`x86_64`→amd64，`aarch64`→arm64，其它 fail）。`probe_remote_platform_preflight()` 读取两端结果，不一致以退出码 3 拒绝（“中转机与出口机架构必须相同”）。
- `LINUX_ARCHIVE` / `LINUX_ARCHIVE_SHA256` / `LINUX_BINARY_SHA256` 由远端架构决定；`DARWIN_ARCHIVE` / `DARWIN_ARCHIVE_SHA256` / `DARWIN_BINARY_SHA256` 由本机平台决定（变量名沿用，语义变为“本机验证用的包”，在声明处注释写清）。

**5.1.2 远端下载与回退**

`install_remote_binary()` 改为：

1. 在远端暂存目录里执行下载：`curl -fsSL --proto '=https' --tlsv1.2 --max-time 300 -o <stage>/archive.tar.gz <url>`，没有 curl 时用 `wget -q -T 300 -O`；
2. 远端下载失败（或随后安装脚本报归档哈希不符 55）时，才在本机用 `verified_archive_path deploy` 准备该架构的归档并 scp 上传，然后重跑安装脚本；
3. 安装脚本（`write_install_binary_script()`）增加第 7 个参数“架构”，用 `sing-box-$version-linux-$arch/` 目录；其余校验（归档哈希、binary 哈希、`libcronet.so` 不得发布到共享目录、版本号）不变。

日志：`[chain][deploy] INFO <role> binary 来源=remote-download|local-upload`。

**5.1.3 本机包可选**

`prepare_verified_assets()` 只准备本机包：本机平台为空、缓存没有且限时 120 秒下载失败时，`DARWIN_ARCHIVE_SHA256` / `DARWIN_BINARY_SHA256` 记为 `NONE`，并打 WARN“没有本机平台的官方包，跳过本机侧出口验证”。远端包的 binary 哈希直接取 §3 常量，不再需要本机解压 Linux 包。

`smoke_from_mac()`（函数名不改）在 `DARWIN_BINARY_SHA256=NONE` 时 WARN 并返回；`probe_mac_reality_rejection()` 不依赖本机 binary，照常执行。

**5.1.4 状态兼容**

字段名不变。读取状态与事务记录时（`:2562-2563` 等）：

- `LINUX_ARCHIVE_SHA256` 必须是 amd64 或 arm64 两个常量之一，据此设定远端架构及其 binary 哈希，并要求 `LINUX_BINARY_SHA256` 与之配套；
- `DARWIN_ARCHIVE_SHA256` 必须是 4 个本机包常量之一或 `NONE`；`DARWIN_BINARY_SHA256` 与之配套；
- verify / status 重新计算资产时（`:4195-4199`、`:4262-4277`），本机平台的包与状态记录不一致（换了控制端平台）时不报 drift，改为 WARN 并跳过本机 smoke；远端哈希仍必须一致。

v0.1.0 写下的状态（linux-amd64 + darwin-arm64）满足上述规则，可以直接读。

**5.1.5 跨平台辅助函数**

| 函数 | macOS | Linux |
| ---- | ---- | ---- |
| `route_interface <ip>` | `route -n get` 取 `interface:` | `ip route get` 取 `dev` |
| `interface_is_tunnel <dev>` | `utun*` | `/sys/class/net/<dev>/tun_flags` 存在，或名字匹配 `tun*`、`utun*`、`wg*` |
| `tcp_probe <host> <port> <秒>` | `nc -4 -n -z -G <秒>` | `timeout <秒> bash -c '</dev/tcp/<host>/<port>'` |

`smoke_from_mac()`、`probe_mac_reality_rejection()`、`choose_local_port()` 及 `multi_chain_client.sh` 的对应位置全部改用这三个函数；日志里的“Mac”改为“本机”。

**5.1.6 出口机 nft 白名单（`EXIT_SOURCE_FILTER=managed`）**

- 部署时在 `prepare_exit_exit()` 之前，先在中转机上执行 `ip route get <EXIT_HOST>` 取 `src`，作为放行来源（中转机有多个 IP 时以实际出站地址为准）；取不到合法 IPv4 时退出 1。
- 出口机 unit 在 `managed` 时追加（`<T>` 为 `ownexit_<CHAIN_ID 中 - 换成 _>`，`<nft>` 为远端预检得到的 nft 绝对路径）：

  ```text
  ExecStartPre=-+<nft> delete table inet <T>
  ExecStartPre=+<nft> "add table inet <T>; add chain inet <T> input { type filter hook input priority -10; policy accept; }; add rule inet <T> input tcp dport <端口> ip saddr != <中转源地址> drop"
  ExecStopPost=-+<nft> delete table inet <T>
  ```

  规则与 sing-box 进程同生共死：服务启动时建表，停止（含 rollback）时删表；重启机器后随服务自动恢复。只拦 Reality 端口，不影响 SSH 和其它服务。
- 远端预检的 nft 检查改为：`nft list tables` 中除 `table inet ownexit_*` 外不得有其它表（同一台出口机上可以有多条链各自的表）。
- `managed` 与 `provider` 一样，本机能直连出口机 Reality 端口即硬失败；verify 额外在出口机上确认 `nft list table inet <T>` 存在。
- unit 内容进入 `EXIT_SERVICE_SHA256`，现有的 drift 检查自然覆盖规则被改动的情况。

**5.1.7 碰撞核证重试**

`remote_path_absent()` 中两处 `ssh_* test` 若返回 255，`sleep 2` 后重试一次，仍为 255 才返回 2。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `EXIT_SOURCE_FILTER` | 新增取值 `managed` | v0.1.0 的 `provider` / `none` 照旧有效 |
| `init --exit-source-filter` | 默认值从 `none` 改为 `managed` | 已有配置文件不受影响 |
| 控制端平台 | 新增 Intel Mac、Linux amd64 / arm64（含 WSL） | — |
| 远端架构 | 新增 arm64（两端须一致） | — |
| 状态 / 事务记录 | 字段不变；`DARWIN_*` 可取 `NONE`，取值集合扩大 | v0.1.0 写下的状态可直接读取 |
| 出口机远端资源 | `managed` 时多一张 nft 表 `inet ownexit_<id>`，随 exit service 起停 | — |
| 日志 | 新增 binary 来源、跳过本机验证、nft 白名单相关行 | — |

本方案不涉及 `docs/reference/*`。

## 6. 备选方案与决策

| 备选 | 结论 | 理由 |
| ---- | ---- | ---- |
| 状态字段改名（`LOCAL_*`、按主机分开的 binary 哈希）并升级 `SCHEMA_VERSION` | 否决 | 要写 v1→v2 迁移，且所有读写状态的路径都要改；在用的链会受影响 |
| nft 规则写成单独的 `/etc/ownexit-chain/<id>.nft` 文件 | 否决 | 新增一个专属远端文件，要同步改碰撞、发布、verify、rollback 四处清单；放进 unit 只需改 unit 生成一处 |
| 用 systemd `IPAddressAllow=` 限制出口机 service | 否决 | 它同时限制出站，出口机就连不上目标网站了 |
| 允许两端架构不同 | 推迟 | 需要按主机记录 binary 哈希，即状态字段改名 |

## 7. 影响分析

**正向推**

- 远端下载 → `install_remote_binary()` 的两个调用点（deploy 的中转、出口两处，`:4411`、`:4418`）；回退路径与 v0.1.0 行为相同。
- 平台变量化 → 所有读 `LINUX_*` / `DARWIN_*` 的位置：状态写入（`:2425-2428`）、状态读取与校验（`:2562-2573`、`:2602`、`:2635-2636`、`:2694-2695`）、verify / rollback 的资产复核（`:4195-4199`、`:4262-4277`）、远端 verify 脚本参数（`:4171`、`:4178`、`:4247-4249`）。
- `managed` → 出口机 unit 内容与哈希变化；`probe_mac_reality_rejection()` 的两个调用点（`:4215`、`:4429`）；远端预检的 nft 检查影响所有调用预检的命令（`:1810`、`:5250`、`:6126`）。

**反向推**

- 同一台出口机上已有 v0.1.0 部署的链（`none`，没有 nft 表）：新预检只放行 `ownexit_*` 表，不影响它；新链加了 `ownexit_<新id>` 表后，旧链的 status / verify 预检依然通过。
- 白名单只拦本链的 Reality 端口，同机其它链的端口、SSH、其它服务不受影响。
- 中转机共存的 sing-box：中转侧逻辑除碰撞重试外不变。

**运行时**

- 远端下载约 24 MB；回退时与 v0.1.0 相同。
- nft 规则只匹配一个 TCP 端口，开销可忽略。

**部署形态**

- 中转机出站源地址与 `RELAY_HOST` 不同（多 IP、NAT）：白名单按实际源地址放行；源地址部署后变化时，中转侧 smoke 会失败并报出来。
- 控制端在 Linux 上开着 TUN（如 mihomo）：`interface_is_tunnel()` 识别后跳过本机验证与拒绝侧检查，与 macOS 的 utun 处理一致；`managed` 的硬门槛在这种情况下同样被跳过并 WARN，需在不经 TUN 的环境里再跑一次 verify 才算验证。

## 8. 回归测试

| 编号 | 内容 | 环境 | 判据 |
| ---- | ---- | ---- | ---- |
| V1 | 静态 | 本机、CI | `bash -n`、`/bin/bash -n`、`shellcheck -S warning` 零告警；隐私扫描通过 |
| V2 | v0.1.0 状态兼容 | 本机 | 用 v0.2.0 对现有链 `main` 跑 `status`、`verify`，结果为 healthy，远端不被改动 |
| V3 | 远端下载 | 本机 → 中转 + 出口 | 新链 `v2test` deploy 日志两端都是 `来源=remote-download` |
| V4 | 回退上传 | 本机 → 中转 + 出口 | 临时把下载地址指向不存在的路径（测试用环境变量 `OWNEXIT_TEST_RELEASE_BASE_URL`，仅测试使用），两端走 `local-upload` 并成功 |
| V5 | managed 白名单 | 本机（关 TUN） | deploy 成功；出口机存在 `table inet ownexit_v2test`；本机直连出口机 Reality 端口失败（硬门槛通过）；中转经链出口为出口机 IP |
| V6 | managed rollback | 本机 | rollback 后出口机 nft 表消失，`main` 的状态仍为 healthy |
| V7 | Linux 控制端 | Linux 测试机（Ubuntu 20.04） | 在测试机上 `init`（另一个 id）→ `preflight` → `deploy` → `verify` → `rollback` 全部成功；本机侧 smoke 使用 linux-amd64 包；`multi_chain_client.sh verify` 通过 |
| V8 | 本机包不可得 | 本机 | 清空本机包缓存并让下载失败时，deploy 仍成功，日志有“跳过本机侧出口验证” |
| V9 | 架构不一致 | 静态 | 预检两端 `REMOTE_ARCH` 不同时以退出码 3 拒绝（用替换函数构造） |
| V10 | 碰撞重试 | 本机开 TUN | 开着 TUN 连续 deploy / rollback 两轮，不再因单次 SSH 断开退出 |
| V11 | 已部署的链不受影响 | 全程 | 在用链的客户端出口始终为出口机 IP；中转原有 sing-box 主进程不变 |

arm64 远端、Intel Mac、WSL 无实机，标为未实测。

## 9. 日志 / 观测点

- `[chain][deploy] INFO <relay|exit> binary 来源=remote-download|local-upload`
- `[chain][<cmd>] WARN 没有本机平台（<平台>）的官方包，跳过本机侧出口验证`
- `[chain][deploy] INFO 出口机白名单放行来源=<IP>（EXIT_SOURCE_FILTER=managed）`
- `[chain][<cmd>] INFO 出口机 Reality 端口的本机直连拒绝侧通过`
- 远端：`nft list table inet ownexit_<id>`；`systemctl cat ownexit-chain-exit-<id>.service`

## 11. 实施记录（2026-10-05）

### 11.1 测试结果

| 编号 | 结果 | 说明 |
| ---- | ---- | ---- |
| V1 | 通过 | 语法、`/bin/bash` 3.2、shellcheck 零告警，隐私扫描通过 |
| V2 | 通过 | v0.2.0 对 v0.1.0 部署的链执行 status / verify，healthy |
| V3 | 通过 | 两端 `binary 来源=remote-download` |
| V4 | 通过 | 下载地址 404 时两端改为 `local-upload` |
| V5 | 通过 | 出口机出现 `table inet ownexit_<id>`，规则只放行中转机出站地址；关闭本机 TUN 后拒绝侧硬门槛通过，verify 通过 |
| V6 | 通过 | rollback 后 nft 表消失，其它链仍 healthy |
| V7 | 通过 | Ubuntu 20.04 控制端完成 init → preflight → deploy → status → verify（含 linux-amd64 本机 smoke）→ 多链 verify → rollback |
| V8 | 通过 | 本机包缺失时跳过本机层 smoke，部署继续；该轮最后 verify 因 SSH 超时中断，随后 rollback 按事务记录恢复干净 |
| V9 | 未实测 | 无 arm64 机器，按代码评审覆盖 |
| V10 | 未达成 | 本机开着 TUN 时，SSH 断开可能发生在任何一次调用上（平台预检、部署步骤），只给碰撞核证加重试不能根治；对含修改动作的调用盲目重试不安全，因此不扩大重试范围，文档改为建议关闭 TUN 或让两台服务器的 IP 走直连 |
| V11 | 通过 | 全程在用链的客户端出口不变 |

### 11.2 实施中发现并修复的问题

| 问题 | 根因 | 修复 |
| ---- | ---- | ---- |
| Linux 控制端 `init` 报“没有可用的 ed25519 host key” | OpenSSH 8.2 首次连接优先 ECDSA，known_hosts 只记 ECDSA；随后强制 ed25519 被当成主机身份变化拒绝，不会自动补记 | `init_record_ed25519_hostkey()`：经已用已知主机密钥验证过的会话读取 `/etc/ssh/ssh_host_ed25519_key.pub` 补记，再验证一次 |
| 独立评审：arm64 远端部署与恢复必然失败 | 安装脚本按架构解压到 `extracted/sing-box-<版本>-linux-arm64/`，但暂存目录清理白名单（deploy 侧与事务恢复侧两处）只列了 `linux-amd64` 路径 | 两处白名单逐项补齐 `linux-arm64` 的 4 个路径；已用官方 linux-arm64 包清单逐项对照。arm64 仍无实机验证（V9） |
| 配置目录位于 775 的上级目录下时被拒绝 | 既有安全检查（上级目录不得被同组 / 其他用户写入），属设计行为 | 不改代码；`chain/README.md` 与手册写明要求 |

### 11.3 与方案的偏离

| 项 | 方案 | 实际 | 理由 |
| ---- | ---- | ---- | ---- |
| SSH 重试范围 | 碰撞核证重试一次 | 同方案，但 V10 未达成 | 见 11.1 V10 |
| 远端下载命令 | 中转 curl / 出口 wget | 远端脚本按 `command -v` 先 curl 后 wget | 两端预检已保证各有其一，写法更简单 |

