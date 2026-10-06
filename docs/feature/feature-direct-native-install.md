# v0.4.0：直连原生安装、旧版迁移与卸载

> 2026-10-05 注记：方案已定、代码待落地。行号以 v0.3.3（`bda0803`）为基线。plan-review 共 5 轮加 1 次收尾核验（第 1 轮自审，其余由独立评审代理执行），高、中级问题已清零。

> 2026-10-05 落地注记：代码已落地，§8 阶段 A、B、C 全部通过（Lima Ubuntu 22.04 arm64 虚拟机；C9 待用户同意后对链 main 执行）。与本文的差异与补充：
> - 新增 OP=`repair`（复用时二进制缺失或服务未运行：重装二进制、拉起服务，不改配置文件），见 `direct/direct_remote.sh` 的 `op_repair`。
> - owner 迁移脚本另有远端码 180（owner 文件身份或权限异常），见 `chain/setup_chain.sh` 的 `rebaseline_owner_reason`。
> - 测试中修复：直连创建的本机目录改为 700（先直连后链式时链式拿不到锁，既有缺陷，新增用例 D21）；回滚步骤经 `enter_step` 写入 STEP（`PAUSE_AT=ROLLBACK` 钩子才生效）；链预检失败提示补 `rebaseline`；卸载后只列真实残留。
> - 实现位置：服务器端操作 `direct/direct_remote.sh`；本机入口 `direct/setup_direct.sh` 第 4、5 阶段；co-host 判定表 `chain/setup_chain.sh` 远端预检与 `relay_cohost_kind_via`；`rebaseline_chain` 及相关函数在 `status_chain` 之前。

## 1. 背景

直连部署（`direct/setup_direct.sh`）目前不自己安装 sing-box：

- 第 4 阶段经 SSH 交互运行第三方脚本 233boy（`direct/setup_direct.sh:229-252`），用户要在菜单里选 VLESS-REALITY；
- 第 5 阶段解析 233boy 的 `sb url` 输出拿节点参数（`direct/setup_direct.sh:254-267`）；
- 没有卸载命令（`README.md:173`），二维码只能在 VPS 上运行 `sb qr`（`direct/setup_direct.sh:492`）。

链式出口机已经有一套原生安装：服务器自己下载固定版本 sing-box 并校验 SHA-256（`chain/setup_chain.sh:3175-3294`），在服务器上生成 Reality 密钥（`chain/setup_chain.sh:3376-3380`），写专属配置与 systemd 单元（`chain/setup_chain.sh:3384-3462`）。

233boy 的安装布局（读自 233boy/sing-box 源码 `src/init.sh:77-88`、`install.sh:425-453`、`src/systemd.sh`、`src/core.sh:322-336`、`src/core.sh:1248-1256`）：

| 内容 | 位置 |
| ---- | ---- |
| sing-box 二进制 | `/etc/sing-box/bin/sing-box` |
| 全局配置 / 协议配置 | `/etc/sing-box/config.json`、`/etc/sing-box/conf/*.json` |
| Reality 配置文件名 | `VLESS-REALITY-<端口>.json` |
| 管理脚本 | `/etc/sing-box/sh/`，`/usr/local/bin/sb` 与 `/usr/local/bin/sing-box` 是指向它的软链 |
| systemd 单元 | `/lib/systemd/system/sing-box.service`，`ExecStart=/etc/sing-box/bin/sing-box run -c /etc/sing-box/config.json -C /etc/sing-box/conf` |
| 其它 | `/var/log/sing-box/`；`/root/.bashrc` 追加 `alias sb=/usr/local/bin/sing-box` 与 `alias sing-box=/usr/local/bin/sing-box` 两行 |

Reality 配置的 JSON 形态：`inbounds[0]` 为 `type=vless`、`listen="::"`、`listen_port`、`users[0].{uuid,flow="xtls-rprx-vision"}`、`tls.{server_name, reality.{handshake.{server,server_port=443}, private_key, short_id=[""]}}`；公钥存在 `outbounds[1].tag`，形如 `public_key_<公钥>`。带 `transport` 字段的是 HTTP/2 变体，没有 flow。

链式的“中转机已有 sing-box”保护写死了 233boy 的布局：

- 预检要求 `sing-box.service` 运行、`/etc/sing-box` 存在（`chain/setup_chain.sh:1909-1932`）；
- 零回归基线只采集 `sing-box.service`（`chain/setup_chain.sh:2254`、`chain/setup_chain.sh:2325-2351`）；
- `init` 自动识别只认它（`chain/setup_chain.sh:6730-6743`）。

已部署的链可能是 `RELAY_COHOSTS_SINGBOX=yes`，而它的中转机上同时跑着用 233boy 安装的直连：在这样的中转机上迁移直连，必须同时处理链的保护基线。

## 2. 目标 / 非目标

### 目标

1. **原生安装**：`ownexit direct` 不再调用 233boy，全程无交互（首次 root 密码除外）；服务器自己下载固定版本 sing-box 1.13.14 并校验 SHA-256，下载失败改由本机上传；amd64、arm64 都支持。重新运行可用 `--sni`、`--proxy-port` 修改参数，UUID 与密钥不变。
2. **旧版一次性迁移**：`ownexit direct --migrate` 把 233boy 安装换成 ownexit 的服务，沿用原有 UUID、Reality 密钥、端口、SNI、short id，客户端与订阅链接不用动；迁移后删除 233boy（先打包备份）。链式新增 `rebaseline` 命令，让与直连同机的链重新登记中转机 sing-box 基线，凭据不变。
3. **卸载与管理**：`ownexit direct --uninstall` 删除直连在服务器上的全部文件；`ownexit subctl log` 看服务日志、`ownexit subctl qr` 在终端显示节点二维码；部署结束时若本机有 `qrencode` 直接显示二维码。

### 非目标

- 不支持迁移 233boy 的其它协议（VMess、Trojan、HTTP/2 变体等）或多个配置并存的情况：检测到即拒绝迁移并说明。
- 不在服务器上提供改参数的命令；不改订阅格式（v0.5.0）；不加客户端侧握手校验。
- 链式其余行为不变；不支持 OpenRC / Alpine。

## 3. 假设与约束

- 服务器是 Debian / Ubuntu（沿用 `direct/setup_direct.sh:179-186`），有 systemd、`tar`、`sha256sum`、`curl` 或 `wget`、`python3`（订阅服务已依赖它）。
- systemd 版本 ≥ 240：5.1.2 用 `StandardOutput=append:` 把操作日志写进文件，该写法自 systemd 240 起支持（Debian 10 为 241、Ubuntu 20.04 为 245）。探测脚本读 `systemctl --version`，低于 240 退出 1。
- sing-box 版本与官方包哈希与链式相同：直连脚本内复制一份常量（版本号 + 两个 Linux 包的归档 / 二进制 SHA-256），CI 校验两处逐字一致，防止只改一边。
- 默认 SNI 与链式一致：`www.amazon.com`（`chain/setup_chain.sh:66`）。
- 以 root 运行（与现状一致）；服务单元保留 `CAP_NET_BIND_SERVICE`，因为迁移沿用的旧端口可能小于 1024（233boy 允许用户自选端口）。
- 迁移在服务器上校验公钥与私钥是否配对：服务器有 `openssl` 时用它从私钥算公钥比对；没有则跳过并提示。私钥不离开服务器。
- 测试用 OWNEXIT_TEST_ 前缀的环境变量（沿用 `chain/setup_chain.sh:42-43` 的做法），仅用于触发失败分支，正常使用不设置：`OWNEXIT_TEST_RELEASE_BASE_URL` 改写官方包下载地址（本机读取后作为参数传给远端下载脚本）；`OWNEXIT_TEST_DIRECT_FAIL_AT=<STEP>` 让 `op.sh` 在执行该步骤时按失败处理（用于回滚与失败收尾用例）；`OWNEXIT_TEST_DIRECT_PAUSE_AT=<STEP>` 让 `op.sh` 在写入该 `STEP` 之后、执行之前暂停 120 秒，供测试在暂停期间打断；这两个钩子只经 `systemd-run --setenv` 传给本次执行，不写入 `op.args`，恢复执行时不生效。`OWNEXIT_TEST_CHAIN_STOP_AFTER=owner|config|baseline` 让 `rebaseline` 在两端 owner 迁移后、改写配置后、或替换基线文件后以退出码 99 结束，用于中断恢复用例。
- 本机下载回退路径需要 SHA-256 工具：依次尝试 `shasum -a 256`（macOS）、`sha256sum`（Linux）、`openssl dgst -sha256`。
- CI 常量一致检查：从 `direct/setup_direct.sh` 与 `chain/setup_chain.sh` 各自 `grep -E "^readonly (SING_BOX_VERSION\|ARCHIVE_SHA256_LINUX_(AMD64\|ARM64)\|BINARY_SHA256_LINUX_(AMD64\|ARM64))="` 后 `diff`，不一致即失败。

## 4. 涉及模块

| 区域 | 行号锚点（v0.3.3） | 类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| 直连头部注释与常量 | `direct/setup_direct.sh:1-38` | 修改 | 前置条件去掉 233boy；新增 sing-box 版本、Linux 包哈希、远端路径常量，`DIRECT_SNI_DEFAULT` |
| 直连用法与参数 | `direct/setup_direct.sh:40-85` | 修改 | 新增 `--sni`、`--proxy-port`、`--migrate`、`--uninstall`；互斥校验 |
| 基础工具检查 | `direct/setup_direct.sh:188-196` | 修改 | `wget` 不再必需；检查 `curl`、`python3`、`tar`、`sha256sum` |
| 233boy 安装与 `sb url` | `direct/setup_direct.sh:229-271` | 替换 | 改为“探测服务器状态 → 新装 / 复用 / 改参数 / 迁移”，结果写入 `PROXY_*` |
| clash 渲染 flow 注释 | `direct/setup_direct.sh:339` | 修改 | 注释改为“flow 来自服务器 client.env” |
| 防火墙放行 | `direct/setup_direct.sh:424-432` | 不变 | 沿用 |
| 主机层验证 | `direct/setup_direct.sh:440-450` | 修改 | 服务名 `sing-box` 改为 `ownexit-direct`，提示改为 `subctl log` |
| 交付汇总 | `direct/setup_direct.sh:479-506` | 修改 | 二维码提示、旋转提示改写；同机链提示 `rebaseline` |
| 直连新函数 | `direct/setup_direct.sh:143` 之后追加 | 新增 | 远端探测、安装、改参数、迁移、卸载脚本与本地封装（见 5.1） |
| subctl | `direct/subctl:16-37`、`:55-58`、`:93-99` | 修改 | 新增 `log`、`qr`；`status` 显示 `ownexit-direct` 或旧版 233boy |
| connect_to 头注释 | `direct/connect_to.sh` | 不变 | — |
| 链式取值校验 | `chain/setup_chain.sh:636` | 修改 | `RELAY_COHOSTS_SINGBOX` 允许 `yes`、`no`、`ownexit-direct` |
| 链式远端预检 | `chain/setup_chain.sh:1909-1932` | 修改 | 按取值选择要保护的单元和配置目录 |
| 链式预检调用 | `chain/setup_chain.sh:1949` | 不变 | 已把取值传给远端脚本 |
| 链式基线采集 | `chain/setup_chain.sh:2200-2354` | 修改 | 单元名改为参数（`yes`→`sing-box.service`，`ownexit-direct`→`ownexit-direct.service`）；输出格式不变 |
| 链式参数解析 | `chain/setup_chain.sh:555-560` | 修改 | 命令表加入 `rebaseline` |
| 链式用法 | `chain/setup_chain.sh:143-224` | 修改 | 加入 `rebaseline` 说明 |
| 链式 init 识别 | `chain/setup_chain.sh:6730-6743` | 修改 | 先识别 `ownexit-direct`，再识别 233boy，两者并存时拒绝 |
| 链式 rebaseline | `chain/setup_chain.sh:6370` 之后追加 | 新增 | `load_state_for_rebaseline`、`probe_relay_cohost_kind`、`write_rebaseline_owner_script`、`rewrite_config_cohost`、`publish_rebaseline`、`rebaseline_chain` |
| 链式分发 | `chain/setup_chain.sh:6836-6838` 之后 | 新增 | `rebaseline) rebaseline_chain ;;` |
| 链式头部注释 | `chain/setup_chain.sh:3-12` | 修改 | 补 `rebaseline` 前置条件 |
| 链式示例配置 | `chain/chain.example.env:14` | 修改 | 注释说明三种取值 |
| CI | `.github/workflows/ci.yml` lint 任务 | 新增 | “sing-box 常量一致”检查 |
| 文档 | `README.md:106`、`:152`、`:163`、`:173`；`README.zh-CN.md` 同行；`SECURITY.md:18`；`chain/README.md:44`、`:70`、`:137`；`docs/manual/direct.md:54-58`、`:106-121`、`:131`、`:141`；`docs/manual/vps.md:125`、`docs/manual/vps.en.md:125`；`CHANGELOG.md` | 修改 | 去掉 233boy 安装说明，补迁移、卸载、`subctl log/qr`、`rebaseline` |
| 直连远端执行方式 | `direct/setup_direct.sh:143` 之后追加 | 新增 | 改动 sing-box 服务的操作由 `systemd-run` 临时单元执行（5.1.2）；订阅服务的启用（`:414-421`）保持前台执行不变（幂等、重跑即恢复，不影响代理） |
| 链式临时目录绑定 | `chain/setup_chain.sh:718-740`（`init_operation_tmp`）、`:6508`（`cleanup_operation_tmp`） | 修改 | 新增 `OPERATION_CONFIG_SHA256`，清理时用它比对（5.1.10） |
| 入口说明 | `src/ownexit/cli.py:20` | 修改 | subctl 一句话说明补 `log / qr` |
| 版本 | `src/ownexit/__init__.py:7` | 修改 | `0.4.0` |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 服务器上的布局（新）

| 内容 | 路径 | 属主 / 权限 |
| ---- | ---- | ---- |
| sing-box 二进制 | `/opt/ownexit-direct/bin/sing-box-1.13.14` | root:root 755 |
| sing-box 配置 | `/etc/ownexit-direct/config.json` | root:root 600 |
| 客户端参数 | `/etc/ownexit-direct/client.env` | root:root 600 |
| systemd 单元 | `/etc/systemd/system/ownexit-direct.service` | root:root 644 |
| 迁移备份 | `/var/backups/ownexit-direct/233boy-<时间戳>.tar.gz` | root:root 600 |
| 操作工作目录 | `/var/lib/ownexit-direct/`（`op.sh`、`op.args`、`op.log`、`txn.env`、`result.env`） | root:root 700 |

`client.env` 只含公开参数，每行 `KEY=VALUE`：`PORT`、`UUID`、`PUBLIC_KEY`、`SHORT_ID`、`SNI`、`FLOW`、`LISTEN`、`SOURCE`（`fresh` 或 `migrated`）。私钥只在 `config.json` 里。本机每次运行都从服务器读回 `client.env` 渲染订阅，服务器是参数的唯一权威源，本机状态丢了也能恢复。

本机由 `client.env` 得到 `PROXY_PORT/UUID/PBK/SID/SNI/FLOW`；`PROXY_SERVER` 取第 2 阶段读到的 `VPS_PUBLIC_IP`（`direct/setup_direct.sh:204`），读取失败时退回 `HOST` 并打印 `[!]`。节点链接按链式同款字段顺序生成（`chain/setup_chain.sh:4116`）：`vless://<UUID>@<server>:<port>?encryption=none&flow=<FLOW>&security=reality&sni=<SNI>&fp=chrome&pbk=<PBK>&sid=<SID>&type=tcp#ownexit-direct`（`FLOW` 为空时省略 `flow=`），替代原先“改写 233boy 链接备注名”的做法（`direct/setup_direct.sh:270-271`）。

`config.json` 与链式出口机同构（`chain/setup_chain.sh:3385-3412`），差别：`listen` 取 `LISTEN`（新装 `0.0.0.0`，迁移沿用旧值），tag 为 `direct-in`，`short_id` 取 `SHORT_ID`（迁移沿用 `""`）。

服务单元以链式出口机为模板（`chain/setup_chain.sh:3435-3457`），差别：没有 nft 行；`CapabilityBoundingSet=CAP_NET_BIND_SERVICE` 与 `AmbientCapabilities=CAP_NET_BIND_SERVICE`；`Description=ownexit direct`。

#### 5.1.2 服务器上的操作执行方式与中断恢复

所有会改动服务器的操作（新装、改参数、迁移、卸载、迁移残局清理）都不在 SSH 会话里前台执行（现状 `direct/setup_direct.sh:414` 的 `vssh "bash -s"` 前台执行在 SSH 断开时会随之终止），而是：

1. 本机把操作脚本与参数上传到 `/var/lib/ownexit-direct/`（root 700）：`op.sh`、`op.args`（只含业务参数，不含测试钩子）；记下 `op.log` 当前大小作为本次日志起点，删除旧的 `result.env`。
2. 用 `systemd-run --unit=ownexit-direct-op --collect --quiet -p StandardOutput=append:/var/lib/ownexit-direct/op.log -p StandardError=append:/var/lib/ownexit-direct/op.log [--setenv=OWNEXIT_TEST_...=...] bash /var/lib/ownexit-direct/op.sh` 启动后立即返回（不用 `--wait`），本机每 2 秒用 `systemctl show ownexit-direct-op -p ActiveState --value` 轮询，直到状态为 `inactive`、`failed` 或单元已不存在（不以 `is-active` 的退出码判断，`activating` 时它也返回非零），再读 `op.log` 起点之后的部分与 `result.env`（`RESULT=ok|fail`、`REASON=...`、操作输出的 `KEY=VALUE`）。临时单元由 systemd 托管，与启动它的 SSH 会话无关，SSH 断开、本机退出都不影响它继续执行。测试钩子只经本次 `--setenv` 传入，恢复执行时不会再次生效。`StandardOutput=append:` 作为 `systemd-run -p` 属性可用与否以 D1 实测为准。
3. 进度标记 `/var/lib/ownexit-direct/txn.env`（`OP=fresh|reparam|migrate|uninstall`、`STEP=<步骤名>`、`STARTED=<时间>`）。`STEP` 记的是**即将或正在执行的步骤**：进入每一步之前先原子写入（同目录临时文件 + `mv`），再执行该步；操作成功结束时删除。
4. 统一失败收尾：`op.sh` 用 `trap ... ERR`（配合 `set -eE`）捕获脚本内的非预期错误（命令失败、校验不通过、`FAIL_AT` 钩子），按 OP 与当前 `STEP` 撤销后删除 `txn.env`。**不捕获 TERM、KILL、EXIT**：进程被信号终止（含断电、`systemctl stop`）时 `txn.env` 保留，由下次运行恢复。`REASON` 取值：通用失败为 `<步骤名>-<原因>`（如 `UNIT-analyze`）；固定值 `download`、`rolled-back`、`clean-unhealthy`、`rollback-failed` 见各步骤。失败收尾函数开头先执行 `set +e; trap - ERR`，撤销命令逐条判断结果，不会递归触发 trap。撤销规则：
   - `fresh`：停服务、删除单元与 `/etc/ownexit-direct`（保留二进制），即 5.1.4 第 5 步的失败分支；
   - `reparam`：`STEP` 为 `WRITE` 时只删 `.new` 文件；之后的步骤执行 `ROLLBACK`；
   - `STEP=ROLLBACK` 时再出错不递归：删除 `txn.env`，`REASON=rollback-failed`，打印当前两个服务的状态与备份路径，交人工处理；
   - `migrate`：`STEP` 在 `SWITCH` 之前（`INSPECT`、`BINARY`、`CONFIG`、`BACKUP`）只删除本次新写的 ownexit-direct 单元、`/etc/ownexit-direct` 与 `BACKUP` 未写完的 tar 包，233boy 未被触碰；`SWITCH`、`CHECK` 中失败，以及 `CLEAN` 开头的健康核验与重启都失败时，执行 `ROLLBACK`（含其前置核验，5.1.6）；`CLEAN` 的健康核验已通过、之后删除 233boy 文件出错时不回滚：保留新服务，删除 `txn.env`，`REASON=CLEAN-<原因>`，下次带 `--migrate` 运行时按 `migrated_leftover` 继续清理；
   - `uninstall`：不撤销，保留 `txn.env`，下次运行继续卸载（卸载各步幂等，重跑即用户本来要做的事）。

   唯一例外是 `BINARY` 下载失败：按 5.1.4 第 2 步保留 `txn.env` 与暂存目录，交给本机上传后重入。
5. 本机重跑时：若 `ownexit-direct-op.service` 仍在运行，先等待它结束再读结果；若 `txn.env` 存在而单元已不在运行（服务器在操作中途重启、断电或进程被杀），先**以 `txn.env` 记录的 OP 与 `op.args` 重新执行同一操作**（每个步骤都可重入）。恢复结果为 `REASON=download` 时，与首次执行相同处理（本机从官方地址下载、上传到 `STAGE` 后以同一 OP 重入），以重入后的结果为恢复结果。恢复结果为成功，或失败但 `REASON=rolled-back`（服务器已回到可用的旧状态）时，继续处理本次请求的操作；其它失败原因则停止，打印原因，退出 1。

每个操作的步骤与可重入规则写在 5.1.4–5.1.7 各节。

#### 5.1.3 服务器状态探测

一次 SSH 运行只读探测脚本，输出 `ARCH=amd64|arm64` 与 `STATE=`。架构只认 `x86_64`→`amd64`、`aarch64`→`arm64`，其它退出 1。判定**按顺序**，命中即停：

| 顺序 | STATE | 判定 |
| ---- | ---- | ---- |
| 1 | `in_progress` | `/var/lib/ownexit-direct/txn.env` 存在 |
| 2 | `migrated_leftover` | ownexit-direct 已装（`ownexit-direct.service` 与 `/etc/ownexit-direct/client.env` 都在；本表所说“已装 / 装了一半 / 未装”只看 `ownexit-direct.service` 单元文件与 `/etc/ownexit-direct` 两个信号，`/opt/ownexit-direct`（新装失败时有意保留二进制）与不含 `txn.env` 的 `/var/lib/ownexit-direct` 不影响判定），233boy 文件（`/usr/local/bin/sb`、`/etc/sing-box`、`sing-box.service` 任一）还在，且 `sing-box.service` 非 active |
| 3 | `ownexit` | ownexit-direct 已装，且 233boy 文件全无、没有 `sing-box.service` |
| 4 | `legacy` | ownexit-direct 未装（单元、`/etc/ownexit-direct` 都不存在），233boy 布局完整：`/usr/local/bin/sb` 是指向 `/etc/sing-box/sh/` 的软链、`/etc/sing-box/conf/` 存在、`sing-box.service` loaded |
| 5 | `none` | 无 `ownexit-direct.service`、无 `/etc/ownexit-direct`、无 233boy 文件、无 `sing-box.service` |
| 6 | `conflict` | 其它全部组合：ownexit-direct 只装了一半（两个信号只有一个）且无 `txn.env`；ownexit-direct 与 active 的 `sing-box.service` 并存；有 `sing-box.service` 却不是 233boy 布局（如官方 deb 包）等。输出看到的文件清单 |

各操作对各 STATE 的处理：

| STATE | 不带参数 / `--sni` / `--proxy-port` | `--migrate` | `--uninstall` |
| ---- | ---- | ---- | ---- |
| `in_progress` | 先恢复上次操作（5.1.2 第 5 条），再按恢复后的 STATE 处理 | 同左 | 同左 |
| `migrated_leftover` | 警告“迁移未清理完，加 `--migrate` 继续”，按 `ownexit` 处理 | 只做迁移第 8 步清理（5.1.6） | 只卸载 ownexit-direct（5.1.7 的动作，不做健康核验、不动 233boy 残留），列出 233boy 残留文件与迁移备份路径，退出 0 |
| `ownexit` | 复用 / 改参数（5.1.5） | 视为已迁移：提示“已是新版”，按复用处理，退出 0 | 卸载（5.1.7） |
| `legacy` | 退出 2，提示加 `--migrate`（客户端不受影响），服务器不动 | 迁移（5.1.6） | 退出 1，提示先 `--migrate` 或用 233boy 自带卸载 |
| `none` | 新装（5.1.4） | 退出 2，提示“没有可迁移的旧版” | 删除残留的 `/opt/ownexit-direct`、`/opt/ownexit-subscription`、`/var/lib/ownexit-direct`（若有），清本机状态，退出 0 |
| `conflict` | 退出 1，列出文件，服务器不动 | 同左 | 先 `systemctl disable --now ownexit-direct`（若单元存在），再删除 5.1.1 所列的 ownexit 路径，**但保留 `/var/backups/ownexit-direct`**，不碰其它文件；之后重新探测，仍不是 `none` 时退出 1 并列出残留 |

#### 5.1.4 新装（STATE=none）

步骤（`txn.env` 的 `STEP` 依次为下列名称）：

1. `PORT`：`--proxy-port` 指定则校验 1-65535、未被监听、且不等于本机状态里的订阅端口 `SUB_PORT`；否则在 20000-59999 随机，最多 10 次，避开已监听端口与 `SUB_PORT`（与订阅端口选择 `direct/setup_direct.sh:296-304` 同法）。端口写入 `op.args`，重入时沿用。
2. `BINARY`：服务器在 `/opt/ownexit-direct/.stage-<随机>`（700）下载官方包并校验归档哈希（下载地址取本机传入的 `OWNEXIT_TEST_RELEASE_BASE_URL` 或官方地址）；失败（返回 1 下载失败、2 摘要不符）则 `op.sh` 保留暂存目录、删除其中半成品，以 `RESULT=fail REASON=download STAGE=<暂存目录>` 结束（`txn.env` 保留，`STEP=BINARY`），本机**固定从官方地址**下载、校验后 `scp` 到该暂存目录的 `archive.tar.gz`，再以同一 OP 重入。解压后校验二进制哈希与 `version` 输出，`mv` 到最终路径；已存在且哈希相同则复用。暂存目录用完删除。
3. `KEYS`：在服务器上生成 UUID、Reality 密钥对、16 位十六进制 short id（与 `chain/setup_chain.sh:3376-3382` 相同的命令与格式校验），写 `config.json` 与 `client.env`（`SOURCE=fresh`）；重入时若 `client.env` 已存在则沿用，不重新生成。
4. `UNIT`：`sing-box check` 与 `systemd-analyze verify` 通过后安装单元，`systemctl enable --now ownexit-direct`。
5. `CHECK`：等待最多 10 秒：服务 active 且端口在监听。失败则停服务、删除单元与 `/etc/ownexit-direct`（保留二进制），删除 `txn.env`，`RESULT=fail`。

#### 5.1.5 复用与改参数（STATE=ownexit）

- 读回 `client.env`；校验二进制哈希，丢失或不符时按 5.1.4 第 2 步重装二进制。
- 带 `--sni` 或 `--proxy-port` 且与现值不同（端口校验同 5.1.4 第 1 步）：OP=`reparam`，步骤：
  1. `WRITE`：写 `config.json.new` 与 `client.env.new`（UUID、密钥、short id、LISTEN 不变），`sing-box check -c config.json.new` 通过。重入时整步重做。端口校验只在首次发起时做一次，新端口写入 `op.args`；恢复执行时不再校验（新端口此时可能已被 ownexit-direct 自己占用）。
  2. `BACKUP`：把 `config.json`、`client.env` 复制为 `*.bak.<时间戳>`，两条备份路径写入 `txn.env`。重入时若 `txn.env` 已记录备份路径且文件存在则跳过，避免把新值当旧值再备份。
  3. `REPLACE`：`config.json.new` 存在则 `mv` 为 `config.json`，`client.env.new` 存在则 `mv` 为 `client.env`；两条各自判断，重入安全。
  4. `RESTART`：`systemctl restart ownexit-direct`。
  5. `CHECK`：10 秒内 active 且监听新端口则成功，删除两个 `.bak` 以外的临时文件与 `txn.env`；失败转 `ROLLBACK`。
  6. `ROLLBACK`（写入 `txn.env` 后执行）：用 `txn.env` 记录的两条备份覆盖回 `config.json`、`client.env`，删除残留 `.new`，`systemctl restart ownexit-direct`；10 秒内 active 则删除 `txn.env`，`RESULT=fail REASON=rolled-back`；否则按 5.1.2 第 4 条的 `rollback-failed` 处理。重入时继续执行本步。

  改了参数的客户端需要重新导入订阅，交付汇总里明确提示。
- 服务不在运行时 `systemctl enable --now` 拉起；10 秒内仍不 active 则退出 1，提示 `ownexit subctl log` 查看原因，不改动任何文件。

#### 5.1.6 迁移（STATE=legacy 且 `--migrate`）

1. `INSPECT`：校验可迁移：`sing-box.service` 处于 active（否则退出 1，提示先在 VPS 上用 `sb` 把旧服务恢复运行，避免迁移失败时无法回滚到可用状态）；`/etc/sing-box/conf/` 下恰好一个 `.json` 文件且文件名匹配 `VLESS-REALITY-*.json`；用 `python3` 读出 `inbounds[0]` 的 `type=vless`、无 `transport`、`flow=xtls-rprx-vision`、`listen`、`listen_port`、`users[0].uuid`、`tls.server_name`、`tls.reality.private_key`、`short_id`（取第一个）；`outbounds` 中以 `public_key_` 开头的 tag 取出公钥。服务器有 `openssl` 时用私钥算出公钥比对，不一致退出 1。任一不满足退出 1，打印原因，服务器不动。
2. `BINARY`：同 5.1.4 第 2 步。
3. `CONFIG`：用旧参数写 `config.json`、`client.env`（`SOURCE=migrated`），`sing-box check` 通过；单元文件写好但不启用。
4. `BACKUP`：`tar czf /var/backups/ownexit-direct/233boy-<时间戳>.tar.gz` 打包 `/etc/sing-box`、`/lib/systemd/system/sing-box.service`、`/usr/local/bin/sb`、`/usr/local/bin/sing-box`（软链本身）、`/root/.bashrc`，权限 600；路径写入 `txn.env`。
5. `SWITCH`：`systemctl stop sing-box` → `systemctl disable sing-box` → `systemctl enable --now ownexit-direct`。
6. `CHECK`：等待最多 10 秒，ownexit-direct active 且旧端口在监听。成功进入 `CLEAN`；失败进入 `ROLLBACK`。
7. `ROLLBACK`（先把 `STEP=ROLLBACK` 写入 `txn.env` 再执行）：**前置核验** 233boy 是否完整——`/lib/systemd/system/sing-box.service`、`/etc/sing-box/conf/` 下的 Reality 配置、`/etc/sing-box/bin/sing-box`、`/etc/sing-box/config.json` 都在。完整时：`systemctl disable --now ownexit-direct`（单元存在时）→ `systemctl enable --now sing-box` → 等待最多 10 秒旧服务 active 且旧端口监听；成功后**才**删除 ownexit-direct 单元与 `/etc/ownexit-direct`，删除 `txn.env`，`RESULT=fail REASON=rolled-back`；旧服务起不来时 `systemctl disable --now sing-box`、`systemctl enable --now ownexit-direct` 恢复新服务，删除 `txn.env`，`REASON=rollback-failed`。不完整时（`CLEAN` 已删掉一部分）：**不删除 ownexit-direct 的任何文件**（其中的 `config.json` 是服务器上唯一可直接使用的私钥配置），尝试 `systemctl enable --now ownexit-direct` 一次，删除 `txn.env`（避免锁死后续操作），`RESULT=fail REASON=clean-unhealthy`，打印备份包路径与“检查 `ownexit subctl log` 后重跑 `ownexit direct`”的提示，交人工处理。各命令幂等，重入时继续执行本步。
8. `CLEAN`：**先再次核验** ownexit-direct active 且端口监听；不满足时 `systemctl restart ownexit-direct` 后再等 10 秒，仍不满足则进入 `ROLLBACK`（此时 233boy 文件尚未删除，可回到旧服务）。然后删除 `/lib/systemd/system/sing-box.service`、`/etc/systemd/system/sing-box.service.d`（若有）并 `daemon-reload`；`/usr/local/bin/sb`、`/usr/local/bin/sing-box` 仅当是指向 `/etc/sing-box/sh/` 的软链时删除；删除 `/etc/sing-box`、`/var/log/sing-box`；`/root/.bashrc` 中逐字等于 `alias sb=/usr/local/bin/sing-box` 或 `alias sing-box=/usr/local/bin/sing-box` 的行删除（233boy `install.sh:424-425` 写入的两行）。`/etc/caddy`、`jq` 不动。

重入规则：`STEP` 在 `SWITCH` 之前中断，从当前步骤继续（未停旧服务，代理不中断）；在 `SWITCH` 或 `CHECK` 中断，若 ownexit-direct 单元与 `/etc/ownexit-direct/config.json` 都在则重新执行 `SWITCH`（各命令幂等）后进入 `CHECK`，否则直接进入 `ROLLBACK`；在 `ROLLBACK` 中断，继续 `ROLLBACK`；在 `CLEAN` 中断，从 `CLEAN` 开头的核验继续。STATE=`migrated_leftover` 时只执行第 8 步（含其开头的核验与失败回滚）。

迁移后本机订阅重新渲染：节点参数（UUID、端口、SNI、公钥、short id、flow）与旧安装相同，订阅 TOKEN 与端口沿用本机状态，订阅链接不变。`clash.yaml` 里只有 `server` 可能变化：v0.3.3 取 233boy 链接里的地址（`direct/setup_direct.sh:130`，233boy 先取 IPv4、失败才取 IPv6，见 233boy `src/core.sh:135-136`），新版取 `VPS_PUBLIC_IP`；两者相同时 `clash.yaml` 逐字不变。`node.txt` 与 `shadowrocket.txt` 参数相同、查询串字段顺序改为 5.1.1 的格式（233boy 原链接无 `sid`，233boy `src/core.sh:1446`）。

#### 5.1.7 卸载（`--uninstall`）

- STATE=`ownexit`：OP=`uninstall`，`systemctl disable --now ownexit-direct ownexit-subscription`；删除两个单元文件、`/etc/ownexit-direct`、`/opt/ownexit-direct`、`/opt/ownexit-subscription`；`daemon-reload`。UFW 处于 active 时删除本项目放行的两条规则（端口取自 `client.env` 与本机状态）。`op.sh` 不删 `/var/lib/ownexit-direct`（结果通道在其中）；本机读到 `RESULT=ok` 后，确认 `ownexit-direct-op` 不在运行，再用一次前台 SSH 删除该目录。中途断开时重跑：`txn.env` 在则恢复卸载；`txn.env` 已删而目录残留时探测为 `none`，按 `none` 的卸载处理删除残留。卸载是否成功**以下面的残留核验为准**。本机删除 `${XDG_STATE_HOME}/ownexit/direct/<safe_name>`。保留：SSH 密钥、记住的目标、BBR 设置、迁移备份（打印路径，提示其中含旧私钥）。
- 其它 STATE 见 5.1.3 的处理表。
- 卸载后用一次 SSH 核验：两个单元 `LoadState=not-found`、`/etc/ownexit-direct`、`/opt/ownexit-direct`、`/opt/ownexit-subscription`、`/var/lib/ownexit-direct` 不存在，否则退出 1 并列出残留。

#### 5.1.8 同机链提示

`setup_direct.sh` 读取 `${XDG_CONFIG_HOME:-~/.config}/ownexit/chains/*.env`（只按 `KEY=VALUE` 逐行解析，不 source），找出 `RELAY_HOST` 等于本次 `HOST` 的链。在**新装、迁移、改参数、卸载**成功后，对每条这样的链打印：`ownexit chain --id <id> rebaseline`，并说明：不执行时该链的 `verify`、`status`、`rollback` 都会在远端预检或基线比对处失败（这三者都先跑远端预检，`chain/setup_chain.sh:4513`、`:6437`、`:5393`），中转转发本身不受影响。新装也要提示：链若是 `RELAY_COHOSTS_SINGBOX=no`，预检要求中转机上没有任何 sing-box 进程（`chain/setup_chain.sh:1931`），新装的直连会让它失败。

#### 5.1.9 subctl

- `log [行数]`：`journalctl -u ownexit-direct -n <行数，默认 100> --no-pager`；服务器是旧版 233boy 时改看 `sing-box`。
- `qr`：读本机 `${XDG_STATE_HOME}/ownexit/direct/<safe_name>/ownexit-subscription/<TOKEN>/node.txt`，`qrencode -t ANSIUTF8` 输出；没有 `qrencode` 时退出 1 并提示安装命令；没有本地订阅时提示先运行 `ownexit direct`。
- `status`：显示 `ownexit-direct` 状态；检测到旧版 233boy 时显示“旧版（建议 ownexit direct --migrate）”。

`setup_direct.sh` 交付汇总：本机有 `qrencode` 时在末尾显示二维码，否则提示 `ownexit subctl qr`。

#### 5.1.10 链式 `rebaseline`

`RELAY_COHOSTS_SINGBOX` 取值扩展为三种。预检（`chain/setup_chain.sh:1909-1932`）、`init` 自动识别（`:6730-6743`）、`rebaseline` 第 4 步三处共用同一张判定表，信号为：U1 = `sing-box.service` 的 LoadState，U2 = `ownexit-direct.service` 的 LoadState，D1 = `/etc/sing-box` 是否存在，D2 = `/etc/ownexit-direct` 是否存在，P = 是否有可执行文件名为 `sing-box` 或 `sing-box-*` 的进程（`:1913-1919`）。

| 取值 | 判定条件 | 预检另需满足 | 基线采集的单元 |
| ---- | ---- | ---- | ---- |
| `yes` | U1=loaded、D1 存在、P=有；U2=not-found、D2 不存在 | 与现状相同：D1 是非软链目录且 group/other 不可写，`sing-box.service` active，MainPID 可执行文件安全（`:1922-1929`） | `sing-box.service` |
| `ownexit-direct` | U2=loaded、D2 存在、P=有；U1=not-found、D1 不存在 | D2 是非软链目录且 group/other 不可写，`ownexit-direct.service` active，MainPID 可执行文件安全 | `ownexit-direct.service` |
| `no` | U1、U2 都 not-found，D1、D2 都不存在，P=无 | 无 | 不采集（写 4 份 `none`，现状 `:2191-2198`） |

不满足任何一行即“状态不完整”：`init` 退出 3（现状 `:6741` 的报错扩充为列出 6 个信号），预检 fail，`rebaseline` 退出 3。`yes` 一行新增的“U2=not-found、D2 不存在”只在服务器上出现 ownexit-direct 时才会生效，v0.3.3 不会产生这种现场，已部署链不受影响。

基线采集脚本把单元名作为参数传入，命令与输出格式不变；`yes` 时远端输出只取决于 systemctl、/proc、ss 的结果，与 v0.3.3 逐字相同，比对用 `cmp`（`:4276`），已部署链升级后不误报。

**锁与临时目录的绑定（修正既有清理逻辑）**：进程的临时目录 owner 文件记录启动时的 `CONFIG_SHA256`（`:737`），退出清理 `cleanup_operation_tmp` 用当前全局 `CONFIG_SHA256` 比对（`:6508`、`:946`），不等则不删临时目录、也不释放链锁（`:6589-6599`）。`rebaseline` 是第一个在进程中途改变 `CONFIG_SHA256` 的命令，所以新增全局变量 `OPERATION_CONFIG_SHA256`：在 `init_operation_tmp`（`:718`）写 owner 文件时赋值为当时的 `CONFIG_SHA256`；`cleanup_operation_tmp` 改用它比对。其它命令该值与 `CONFIG_SHA256` 始终相等，行为不变。锁文件里的 `CONFIG_SHA256`（`:1329`）只供 stale 恢复读取（`:1359`），`release_lock_file` 只比对 `OPERATION_ID`（`:1395-1399`），无需改动。

`ownexit chain --id <id> rebaseline` 步骤（参照 `rehost_exit_chain`，`:6330-6370`）：

1. 取 chain lock；不得有未完成事务；必须已部署。
2. `load_state_for_rebaseline`：用当前配置校验 state（`probe_state_file`）。返回 0 记 `BINDING=current`；返回 12 时，把配置里的 `RELAY_COHOSTS_SINGBOX` 换成 state 记录的值重算摘要，等于 state 的 `CONFIG_SHA256` 则记 `BINDING=config-ahead`（配置里只有这一键与 state 不同：可能是上次 rebaseline 已改配置、未提交 state，也可能是用户手工改了这一键），并记下配置里的值 `CONFIG_COHOST` 及其摘要 `AHEAD_CONFIG_SHA256`；否则退出 2（不接受其它配置键的改动）。之后一律以 **state 记录的值**为“旧值”：`STATE_COHOST` = state 的 `RELAY_COHOSTS_SINGBOX`，`STATE_CONFIG_SHA256` = state 的 `CONFIG_SHA256`。
3. `render_ssh_config`、`probe_loaded_binding`（同 `:6349-6361`）。
4. `probe_relay_cohost_kind`：按上表判定现场取值 `LIVE_COHOST`，不完整退出 3。本命令**不调用** `remote_platform_preflight`（它按旧取值检查，迁移后必然失败）；co-host 的安全检查由第 5 步采集脚本（身份与权限检查，`:2207-2260`）与第 8 步按新取值运行的 `full_verify` 承担。
5. 把全局 `RELAY_COHOSTS_SINGBOX` 设为 `LIVE_COHOST`（采集脚本按它分支，`:2191`），在临时目录采集新基线并算出 4 个清单的 SHA-256 与 active / enabled。再以 `LIVE_COHOST` 重算 `CONFIG_SHA256`（`NEW_CONFIG_SHA256`，现场未变时等于 `STATE_CONFIG_SHA256`）。
6. owner 迁移（先于 noop 判定）：**无条件**对出口机与中转两端运行新增的远端脚本 `write_rebaseline_owner_script` 迁移 owner 文件（`/etc/ownexit-chain/<id>.owner.env`，root:root 600）。规则：
   - 把文件中唯一的 `CONFIG_SHA256=` 行替换为 `STATE_CONFIG_SHA256` 得到规范形态，规范形态的哈希必须等于 state 记录的 owner 哈希（`EXIT_OWNER_SHA256` / `RELAY_OWNER_SHA256`），否则视为外部改动，退出码 181；
   - 该行当前值必须属于“state 值，或把配置中 `RELAY_COHOSTS_SINGBOX` 分别设为 `yes` / `no` / `ownexit-direct` 算出的三个摘要”之一（覆盖任意次中断留下的中间值），否则退出码 182；规范形态的哈希核验已防住外部改动；
   - 当前值不等于 `NEW_CONFIG_SHA256` 时，同目录临时文件 + `mv` 原子替换该行；输出 `OWNER=changed|already` 与新哈希。中转的 service、socket 不动，也不重启。
   
   不复用 `write_rehost_remote_script`，因为它只接受“state 值或新值”两种形态（`:6198-6212`），处理不了 `config-ahead` 留下的中间值。
6a. **noop 判定**（比较对象一律是 state，不是本地基线文件）：`BINDING=current`、`LIVE_COHOST == STATE_COHOST`、两端 owner 脚本都输出 `already`、4 个 SHA-256 分别等于 state 的 `RELAY_BASELINE_*_SHA256`、active / enabled 等于 state 记录值，五条同时成立时输出 `rebaseline=noop`，退出 0（不创建审计目录）。
6b. 创建审计目录 `audit/rebaselined.<部署ID>.<操作ID>/`（碰撞即退出 1，第 7 步复用）。只要配置文件里的 `RELAY_COHOSTS_SINGBOX` 不等于 `LIVE_COHOST`（与 BINDING 无关），就把旧配置复制进审计目录，再原子改写配置中恰好一行。
7. `publish_rebaseline`：旧 state 与旧基线归档到第 6b 步建的审计目录；用新基线替换 `baseline/` 下 4 个文件；按新的基线摘要、取值、配置摘要、owner 摘要写 state（`render_state_payload` + `write_checksummed_file`）。
8. `ensure_local_assets_match_state`、`full_verify`。

中途断开时重跑同一条命令即可收敛，逐个中断点：

| 中断点 | 重跑时 |
| ---- | ---- |
| owner 迁移了一端或两端 | 第 2 步 `BINDING=current`，第 6 步 owner 脚本对已是新值的一端输出 `already` |
| 配置已改写、state 未提交 | 第 2 步识别为 `config-ahead`；第 6 步 owner 脚本接受中间值，配置与现场一致则不再改写 |
| 配置已改写后现场又变化（如 C6 中断后又新装直连） | `config-ahead` 且 `CONFIG_COHOST != LIVE_COHOST`：owner 从中间值迁到 `LIVE_COHOST` 的摘要（可能等于 state 值），配置改写为 `LIVE_COHOST` |
| owner 已迁到某中间值、配置未改，之后现场变化 | `BINDING=current`；owner 当前值属于三个合法取值的摘要之一，被迁到 `LIVE_COHOST` 的摘要 |
| baseline 已替换、state 未提交 | 第 6a 步与 state 比对，SHA-256 不等，不判 noop，第 7 步重新写入 |
| owner 已迁到中间值后现场又回到 state 取值（如 C10 中断后卸载直连） | 第 6 步 owner 脚本把中间值迁回 state 值并输出 `changed`，第 6a 步因此不判 noop，第 7 步重写 state（内容与原 state 等价） |
| state 已提交、`full_verify` 未完成 | 第 6a 步判 noop；用户再跑 `verify` 即可 |

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit direct`（`setup_direct.sh`） | 不再调用 233boy；新增 `--sni <域名>`、`--proxy-port <端口>`、`--migrate`、`--uninstall`；`--migrate`、`--uninstall`、`--rotate-token` 三者互斥 | 新服务器行为改变（无交互）；已用 233boy 部署的服务器不带 `--migrate` 时退出 2 并提示，服务器不动 |
| 退出码 | 沿用 0 / 1 / 2；新增“旧版待迁移”归入 2 | 兼容 |
| `ownexit subctl` | 新增 `log [行数]`、`qr` | 原子命令不变 |
| 服务器文件 | 新增 5.1.1 所列路径；迁移后删除 233boy 文件 | 迁移前打包备份 |
| 服务器临时单元 | 操作期间存在 `ownexit-direct-op.service`（`systemd-run --collect`，结束即回收） | 新增；要求 systemd ≥ 240 |
| 链式配置键 `RELAY_COHOSTS_SINGBOX` | 新增取值 `ownexit-direct` | 旧取值语义不变，旧状态无需迁移 |
| 链式命令 | 新增 `rebaseline`；退出码 0 成功或 noop、2 配置有其它改动、3 中转不可达或状态不完整、5 锁 / 状态 / 未完成事务、1 运行时失败 | 新增 |
| 链式审计目录 | 新增 `audit/rebaselined.<部署ID>.<操作ID>/` | 新增 |
| 测试钩子 | `OWNEXIT_TEST_DIRECT_FAIL_AT`、`OWNEXIT_TEST_DIRECT_PAUSE_AT`、`OWNEXIT_TEST_CHAIN_STOP_AFTER`（退出码 99） | 仅测试使用，不写入用户文档 |

本方案不涉及 `docs/reference/*`。

## 6. 备选方案与决策

| 备选 | 结论 | 理由 |
| ---- | ---- | ---- |
| 新服务沿用 `sing-box.service` 与 `/etc/sing-box`，链式无需改动 | 否决 | 与 233boy、官方 deb 包的同名单元冲突；卸载时难以判断哪些文件属于本项目 |
| 链式增加独立配置键记录被保护单元名 | 否决 | 状态文件键表固定（`chain/setup_chain.sh:2432`），加键要升级所有已部署链的 state；扩展现有取值即可表达 |
| 迁移时重新生成凭据 | 否决（用户已定） | 所有客户端要重新导入 |
| 直连 source 链式脚本复用下载函数 | 否决 | 链式脚本加载即执行 `main`，且下载函数依赖其事务与锁上下文；直连复制少量常量并由 CI 保证一致 |
| 迁移后保留 233boy 文件只停用 | 否决（用户已定“服务器上不再有 sb”） | 先打包备份兜底 |

## 7. 影响分析

**直连**

- 正向：`setup_direct.sh` 第 4、5 阶段被替换，第 6 阶段起的订阅渲染只换了 `PROXY_*` 的来源，渲染代码不变（`direct/setup_direct.sh:316-399`）；`sync_to_vps.sh` 调用不变（`:403-405`）。订阅服务 `ownexit-subscription` 不变。
- 反向：`subctl status` 原先查 `sing-box` 服务（`direct/subctl:95`），改为 `ownexit-direct`，旧版服务器另行提示；`connect_to.sh` 不变。
- 运行时：新装一次多出约 15 MB 下载（官方包），在服务器上完成；改参数会重启服务，在途连接断开、客户端自动重连；迁移切换期间代理中断约 1-3 秒（停旧服务到新服务监听）。
- 部署形态：服务器在国内访问 GitHub 失败时走本机上传；`openssl` 缺失时跳过公私钥配对校验；IPv6-only 机器不在支持范围（沿用现状）。
- 对外语义：迁移后节点参数等价（UUID、端口、SNI、公钥、short id、flow 相同），订阅链接不变；`clash.yaml` 的 `server` 取 `VPS_PUBLIC_IP`，与 233boy 原地址相同时逐字不变；`node.txt` / `shadowrocket.txt` 查询串顺序变化，客户端解析结果相同（5.1.6 末段）。新装节点 short id 从空变为 16 位十六进制（新节点，无兼容问题）。
- 中断：改动 sing-box 服务的操作由 systemd 临时单元执行，SSH 断开不中断操作；服务器重启打断操作时由 `txn.env` 在下次运行时恢复（5.1.2）。迁移只在 `SWITCH` 到 `CHECK` 之间（约 1-3 秒）中断代理。

**链式**

- 正向：预检、基线采集、init 识别三处按取值分支；`yes` 时远端执行的命令与输出逐字不变，已部署链（含 `main`）的基线比对不受影响。
- 反向：`verify`（`full_verify`）、`status`、`rollback` 都先跑远端预检、再比对基线（`chain/setup_chain.sh:4513-4518`、`:6437-6452`、`:5393-5396`）。同机的直连新装、迁移、改参数、卸载之后，链会在预检（co-host 声明与现场不符）或基线比对处失败，**`rollback` 也被挡住**，直到运行 `rebaseline`；中转转发本身不受影响（预检与基线只用于核验）。直连在这些操作的交付汇总里提示 `rebaseline`（5.1.8）。
- `rebaseline` 改写用户的配置文件一行：先归档，原子替换，只动该行。
- 运行时：`rebaseline` 不重启中转转发服务；两端只由 `write_rebaseline_owner_script` 改写 owner 文件中的一行，中转的 service / socket 不动。

**CI / 打包**：新增一条 lint 检查；`pyproject.toml` 不变（新文件都在已有包目录内）。

## 8. 回归测试

测试环境：本机临时 Lima（vz），Ubuntu 22.04 虚拟机 4 台：F（直连目标，后段改装 233boy 测失败路径）、L（233boy 旧版，同时当链的中转机）、E（链的出口机）、C（Linux 控制端）。网络与已知坑按 V9 的做法（vzNAT + user-v2，删 Lima 自建的空 nat 表，改网络后不再重启虚拟机）。除 D13 外均在本机（macOS）执行。凡执行 `rebaseline` 的用例，判据都额外包含：结束后 `status` 不输出 `stale_lock`，链的 `operation.lock` 与本次临时目录均已删除（H1 回归）。

**阶段 A：F 上的新装、改参数、中断与卸载（按顺序）**

| 编号 | 内容 | 判据 |
| ---- | ---- | ---- |
| D1 | F 新装 | 退出 0；`ownexit-direct` active；`client.env` 存在且 `SOURCE=fresh`；订阅拉取与本地逐字一致；日志含 `binary 来源=remote-download arch=`；`/var/lib/ownexit-direct/txn.env` 不存在 |
| D2 | F 重跑不带参数 | 退出 0；UUID / 公钥 / 端口与 D1 相同；服务未重启（`ActiveEnterTimestamp` 不变） |
| D3 | F `--sni www.microsoft.com` | 退出 0；SNI 变化，UUID / 公钥 / short id 不变；订阅更新 |
| D4 | F `--proxy-port <指定>` | 退出 0；端口变化并监听；再指定为本机状态里的 `SUB_PORT` 时退出 2 |
| D5 | 下载失败回退：在 F 上删除 `/opt/ownexit-direct/bin/` 下的二进制，`OWNEXIT_TEST_RELEASE_BASE_URL` 指向不存在地址后运行 | 退出 0；日志 `binary 来源=local-upload`（本机回退固定走官方地址） |
| D5b | 恢复时下载失败：F `--uninstall` 后，`OWNEXIT_TEST_RELEASE_BASE_URL` 指向不存在地址并 `OWNEXIT_TEST_DIRECT_PAUSE_AT=BINARY` 运行新装，暂停期间 `systemctl kill -s KILL ownexit-direct-op`；之后保持该下载地址、不带暂停钩子重跑 | 重跑先恢复，服务器下载失败后走本机上传，新装完成，退出 0；`txn.env` 不存在 |
| D12 | 本机有 `qrencode` 时 `subctl status`、`subctl log`、`subctl qr`；再把 `qrencode` 移出 PATH 运行 `subctl qr` | 前三个退出 0、`status` 显示 `ownexit-direct` active；最后一个退出 1 并提示安装命令 |
| D14 | SSH 断开不中断操作：`OWNEXIT_TEST_DIRECT_PAUSE_AT=CHECK` 运行 `--proxy-port <新值>`，在暂停期间杀掉本机 ssh 进程；之后不带钩子重跑 | 临时单元继续执行并成功；重跑退出 0，端口为新值，`txn.env` 不存在 |
| D15 | 服务器侧中断恢复：`OWNEXIT_TEST_DIRECT_PAUSE_AT=RESTART` 运行 `--sni www.apple.com`，暂停期间在 F 上 `systemctl kill -s KILL ownexit-direct-op`；之后不带钩子重跑 | 重跑先报 `STATE=in_progress OP=reparam STEP=RESTART`（暂停时已写入的步骤）并完成上次操作；退出 0；SNI 为新值；`config.json` 与 `client.env` 的 SNI 一致 |
| D11 | F `--uninstall` | 退出 0；残留核验全部通过；本机状态目录删除 |
| D19 | 失败收尾：F `--uninstall` 后 `OWNEXIT_TEST_DIRECT_FAIL_AT=UNIT ownexit direct`；之后不带钩子再运行 | 第一次退出 1，`REASON` 以 `UNIT-` 开头，单元与 `/etc/ownexit-direct` 已删、`txn.env` 不存在、探测为 `none`；第二次新装成功 |
| D16 | conflict 处理：F 先 `--uninstall`；在 F 上手工建 `/etc/ownexit-direct/config.json` 后运行 `ownexit direct`，再运行 `--uninstall` | 前者退出 1 并列出文件、服务器不变；后者退出 0，该目录已删除 |

**阶段 B：L 上的链与迁移（按顺序）**

| 编号 | 内容 | 判据 |
| ---- | ---- | ---- |
| C1 | L 装 233boy，用 v0.3.3 的 `setup_direct.sh` 部署一次直连并保存订阅三件作对照；L 当中转、E 当出口，`init` + `deploy` | `init` 自动填 `RELAY_COHOSTS_SINGBOX=yes`；`deploy`、`verify` 通过 |
| D6 | 新版 `ownexit direct` 不带 `--migrate` | 退出 2；`sing-box` 仍 active，233boy 文件未变 |
| D7 | `ownexit direct --migrate` | 退出 0；迁移前 `sb url` 解析出的 UUID / 端口 / SNI / 公钥 / short id 与 `client.env` 逐字段相同；订阅链接不变；`clash.yaml` 除 `server` 外逐行相同，`server` 等于 `VPS_PUBLIC_IP`（若与 C1 对照的 `server` 相同，则整份逐字相同）；233boy 文件（含 `.bashrc` 两行 alias）全部删除；备份存在且权限 600；交付汇总含 `rebaseline` 提示 |
| C2 | 链的 `verify`、`status`、`rollback` | 三者都失败于预检（co-host 不符）；`rollback` 未删除任何远端或本地文件 |
| D8 | `ownexit direct --migrate` 重跑 | 退出 0，提示“已是新版”，参数不变 |
| C3 | `chain rebaseline` | 退出 0；配置取值变为 `ownexit-direct`；凭据 / 端口 / `node.txt` 不变；`verify` 通过；审计目录存在 |
| C4 | `chain rebaseline` 重跑 | 输出 `rebaseline=noop`，退出 0 |
| C5 | L `ownexit direct --sni www.microsoft.com` → `verify` 失败于基线比对；`OWNEXIT_TEST_CHAIN_STOP_AFTER=baseline` 运行 `rebaseline`（替换基线后、写 state 前退出），再不带钩子重跑 | 第一次退出 99；重跑不判 noop，退出 0，取值仍为 `ownexit-direct`，`verify` 通过 |
| C6 | L `ownexit direct --uninstall`；`OWNEXIT_TEST_CHAIN_STOP_AFTER=config` 运行 `rebaseline`（改写配置后退出），再不带钩子重跑 | 第一次退出 99 且配置已是 `no`；重跑识别 `config-ahead`，退出 0；state 取值为 `no`；`verify` 通过 |
| C12 | owner 中间值回退：C6 之后（state 为 `no`）先在 L 上新装直连，`OWNEXIT_TEST_CHAIN_STOP_AFTER=owner` 运行 `rebaseline`（现场 `ownexit-direct`、state `no`），再在 L 上 `ownexit direct --uninstall` 使现场回到 `no`，然后运行 `rebaseline` | 第二次不判 noop，owner 迁回 state 值，退出 0；`verify` 通过；之后再新装直连继续 C10 |
| C10 | L `ownexit direct` 新装 → `verify` 失败于预检 → `rebaseline` | 新装交付汇总含 `rebaseline` 提示；`rebaseline` 退出 0，取值变为 `ownexit-direct`，`verify` 通过 |
| C11 | 手工改错配置：把链配置里的 `RELAY_COHOSTS_SINGBOX` 改成 `no`（现场为 `ownexit-direct`），运行 `rebaseline` | 识别 `config-ahead`；退出 0；配置被改回 `ownexit-direct`；owner 与 state 摘要一致；`verify` 通过 |
| C7 | 新链 `init --id c7 --relay L --exit E` | 自动填 `RELAY_COHOSTS_SINGBOX=ownexit-direct`；`deploy`、`verify`、`rollback` 通过；之后对链 `c7` 无残留 |

**阶段 C：F 上的迁移失败路径与 Linux 控制端（按顺序）**

| 编号 | 内容 | 判据 |
| ---- | ---- | ---- |
| D9 | F 装 233boy；`OWNEXIT_TEST_DIRECT_FAIL_AT=CHECK ownexit direct --migrate` | 退出 1，`REASON=rolled-back`；`sing-box` 恢复 active，233boy 文件仍在，ownexit-direct 单元与 `/etc/ownexit-direct` 已删，`txn.env` 不存在 |
| D10 | 在 F 上用 `sb add` 再加一个协议配置后 `--migrate`；之后删除该配置 | 退出 1，提示多个配置；服务器不变 |
| D17 | `OWNEXIT_TEST_DIRECT_PAUSE_AT=CHECK` 运行 `--migrate`，暂停期间 `systemctl kill -s KILL ownexit-direct-op`；之后不带钩子运行 `ownexit direct` | 第二次先恢复迁移（重新执行 `SWITCH` 后 `CHECK`）并完成清理；退出 0；判据同 D7（不含 C1 对照与 `rebaseline` 提示，F 不是链的中转） |
| D18 | 回滚中断恢复：F 先 `--uninstall` 再装 233boy；`OWNEXIT_TEST_DIRECT_FAIL_AT=CHECK OWNEXIT_TEST_DIRECT_PAUSE_AT=ROLLBACK` 运行 `--migrate`，暂停期间 `systemctl kill -s KILL ownexit-direct-op`；之后不带钩子运行 `ownexit direct --migrate` | 第二次先报 `STEP=ROLLBACK` 并完成回滚：`sing-box` active、ownexit-direct 单元与配置已删、`txn.env` 不存在；随后按 `legacy` 正常迁移并成功 |
| D20 | 半清理 + 新服务不健康：F 先 `--uninstall` 再装 233boy；`OWNEXIT_TEST_DIRECT_PAUSE_AT=CLEAN` 运行 `--migrate`，暂停期间手工删除 `/lib/systemd/system/sing-box.service`、`systemctl stop ownexit-direct` 并把 `/etc/ownexit-direct/config.json` 改为非法 JSON，再 `systemctl kill -s KILL ownexit-direct-op`；之后不带钩子运行 `ownexit direct` | 退出 1，`REASON=clean-unhealthy`；`/etc/ownexit-direct` 仍在；`txn.env` 不存在；再次运行不报 `in_progress` |
| D13 | Linux 控制端：F 先 `--uninstall`（D20 之后为 `migrated_leftover`，验证该状态下卸载退出 0 并列出 233boy 残留），按列出的清单手工删除残留后再装 233boy；在 C 上对 F 执行 `--migrate`、`--sni`、`--uninstall`、新装 | 各步判据分别同 D7（不含 C1 对照与 `rebaseline` 提示）、D3、D11、D1 |

**阶段 D：兼容与静态**

| 编号 | 内容 | 判据 |
| ---- | ---- | ---- |
| C9 | 已部署链兼容：用新版脚本对链 `main` 执行 `status` 与 `verify`（会登录用户在用的服务器，执行前征得用户同意） | `healthy`、`verify 通过`；只读，不改动服务器状态 |
| S1 | 静态 | `bash -n`、`shellcheck -S warning`、隐私扫描（含历史）、CI 全部任务通过，新增的常量一致检查通过；临时改动一个常量后该检查失败 |

## 9. 日志 / 观测点

- 直连：`[*]` / `[+]` / `[!]` 前缀沿用；关键行 `服务器状态：STATE=<值> ARCH=<值>`、`恢复上次未完成的操作：OP=<值> STEP=<值>`、`服务器操作 OP=<值> 结果=ok|fail reason=<值>`、`binary 来源=remote-download|local-upload arch=<值>`、`迁移：沿用 port=… sni=… uuid 前 8 位=…`、`迁移备份：<路径>`、`卸载残留核验通过`。
- 链式：`[chain][rebaseline] INFO kind <旧>-><新>`、`rebaseline=noop`、`rebaseline 通过；chain=<id> elapsed=<秒>s`；owner 迁移失败按远端码说明：181 owner 规范形态与 state 不符（外部改动）、182 owner 中的配置摘要不是 state 值或三种合法取值的摘要之一、255 SSH 不可达。
- 服务器：`/var/lib/ownexit-direct/op.log`（每次操作追加，含步骤名）、`txn.env`（是否有未完成操作）；`journalctl -u ownexit-direct`（即 `ownexit subctl log`）；`systemctl show ownexit-direct -p ActiveEnterTimestamp` 用于判断是否重启。
