# 命令参考（1.x 冻结）

[English](commands.en.md) | **简体中文**

本文件逐项列出 `ownexit` 各子命令的参数、子命令、退出码与机器可读输出。1.x 内这些项只增不减、含义不变，兼容规则见 [compatibility.md](compatibility.md)。表格中带反引号的首列由 `scripts/check_interface.sh` 与源码自动比对。

所有子命令单独使用 `-h` / `--help` 时打印帮助并退出 0（帮助文字不冻结）；链式只在单独使用 `--help` 时显示帮助，`chain init --help` 以退出码 2 拒绝；`chain up --help` 打印帮助并退出 0。`git clone` 用法下各子命令对应的脚本见每节标题下的说明，参数与 `ownexit <子命令>` 完全相同。

## ownexit（入口）

脚本：`src/ownexit/cli.py`。把子命令原样转发给包内脚本。

| 写法 | 作用 |
| ---- | ---- |
| `ownexit -h` / `ownexit --help` / `ownexit help` | 打印子命令列表，退出 0 |
| `ownexit`（不带参数） | 标准输入与输出都是终端时进入向导：先选语言（`OWNEXIT_LANG` 为 zh / en 时跳过），再问直连还是链式、IP 与 SSH 端口，然后转给 `direct` 或 `chain up` 执行；取消时退出 130（Ctrl+C）或 1（输入结束）。非终端时打印子命令列表，退出 0 |
| `ownexit -V` / `ownexit --version` | 打印 `ownexit <版本>`，退出 0 |
| `ownexit <子命令> …` | 转发给对应脚本，退出码即脚本的退出码 |

入口自身的退出码：未知子命令 2；包内脚本缺失或找不到 bash 1；向导被 Ctrl+C 取消 130、输入结束（Ctrl+D）1。向导的提示文字不冻结。

## ownexit direct

脚本：`direct/setup_direct.sh`。部署 / 复用 / 改参数 / 迁移 / 卸载直连出口，并生成订阅；日常操作（原 `ownexit subctl`）也从这里进入。

### 子命令

子命令可以写在参数前后任意位置。不带子命令等同 `up`。

| 子命令 | 作用 |
| ---- | ---- |
| `up` | 部署 / 复用（可带 `--host` `--sni` `--proxy-port` `--sub-ttl` `--allow-tun`）；不能与下面的维护子命令同用 |
| `rotate-keys` | 重新生成全部设备的 UUID 与 Reality 密钥 / short id（同 `--rotate-keys`） |
| `rotate-token` | 重新生成订阅 TOKEN 与端口（同 `--rotate-token`） |
| `add-device` | 新增一台设备，跟设备名（同 `--add-device`） |
| `remove-device` | 吊销一台设备，跟设备名（同 `--remove-device`） |
| `migrate` | 把 233boy 旧版迁移为 ownexit-direct（同 `--migrate`） |
| `uninstall` | 卸载直连服务与订阅服务（同 `--uninstall`） |
| `sub` | 跟 `start [--ttl <时长>]` 或 `stop`：开关订阅服务（同 subctl 的 start / stop） |
| `status` | 查看代理服务与订阅服务状态（同 subctl status） |
| `log` | 查看代理服务日志，可跟行数（同 subctl log） |
| `qr` | 终端显示 default 设备的节点二维码（同 subctl qr） |
| `devices` | 只读列出设备与订阅地址（同 subctl devices） |
| `login` | 免密登录 VPS（同 subctl login） |

`sub` / `status` / `log` / `qr` / `devices` / `login` 是日常操作：整体交给 `direct/subctl` 执行，退出码即 subctl 的退出码（见下方 ownexit subctl 一节）；它们之前只能出现 `--host` / `--user` / `--port`，出现 `up`、维护子命令或部署参数时退出 2；它们之后的参数原样交给 subctl 校验。

### 参数

| 长参数 | 短参数 | 含义 |
| ---- | ---- | ---- |
| `--host` | | VPS 地址；不给时用唯一记住的目标，没有则交互提问（非终端时退出 2） |
| `--user` | `-u` | SSH 用户，默认 root |
| `--port` | `-P` | SSH 端口，默认 22 |
| `--sni` | | Reality 伪装域名（新装默认 www.amazon.com） |
| `--proxy-port` | | 代理端口（新装默认 20000-59999 随机） |
| `--sub-ttl` | | 订阅服务启动后多久自动关闭（`<正整数>[s/m/h]`，不带单位按分钟，1 分钟到 24 小时）；不给则不自动关闭 |
| `--migrate` | | 已废弃，用 `migrate` 子命令（仍可用，stderr 提示新写法） |
| `--uninstall` | | 已废弃，用 `uninstall` 子命令 |
| `--rotate-token` | | 已废弃，用 `rotate-token` 子命令 |
| `--rotate-keys` | | 已废弃，用 `rotate-keys` 子命令 |
| `--add-device` | | 已废弃，用 `add-device` 子命令（设备名 `[a-z0-9][a-z0-9-]{0,31}`，不能是 default） |
| `--remove-device` | | 已废弃，用 `remove-device` 子命令 |
| `--allow-tun` | | 本机到 VPS 的路由经代理 TUN 时默认拒绝部署（退出 1），加它只警告继续 |

互斥规则（子命令与对应旧参数等同）：`migrate`、`uninstall`、`rotate-token` 三者互斥；`rotate-keys` 不能与 `migrate` / `uninstall` 同用；`add-device` 与 `remove-device` 互斥，且不能与 `migrate` / `uninstall` 同用；`--sni` / `--proxy-port` / `--sub-ttl` 不能与 `uninstall` 同用；`up` 不能与维护子命令同用。

### 退出码

| 码 | 含义 |
| ---- | ---- |
| 0 | 全部通过 |
| 1 | 部署失败或有验证项未通过；部署前自检发现到 VPS 的路由经 TUN 且未加 `--allow-tun` |
| 2 | 参数错误、缺参数（非终端运行时）、服务器是 233boy 旧版需要 `--migrate`、设备操作被拒（已存在 / 不存在 / 超过上限） |

### 输出

`[*]` / `[+]` / `[!]` 开头的行是给人看的进度，不冻结。冻结的是退出码与生成的订阅（路径与文件见 [files.md](files.md)）。

## ownexit subctl

脚本：`direct/subctl`。直连部署后的日常操作。**已废弃**（仍可用，最早 2.0 移除）：改用 `ownexit direct` 的子命令（start / stop → `sub start` / `sub stop`，其余同名）。直接调用时 stderr 打一行废弃提示；经 `ownexit direct` 转来时不打。

### 参数

| 长参数 | 短参数 | 含义 |
| ---- | ---- | ---- |
| `--host` | | 目标 VPS；不给时用唯一记住的目标 |
| `--port` | | SSH 端口，默认 22 |
| `--user` | | SSH 用户，默认 root |
| `--ttl` | | 只配合 `start`：订阅服务多久后自动关闭（格式同 direct 的 `--sub-ttl`） |

### 子命令

| 子命令 | 作用 |
| ---- | ---- |
| `login` | 免密登录 VPS（默认） |
| `start` | 启动订阅服务（可加 `--ttl`；会先取消上一次的自动关闭计时） |
| `stop` | 停止订阅服务 |
| `status` | 查看代理服务与订阅服务状态 |
| `log` | 查看代理服务日志，可跟行数（默认 100） |
| `qr` | 在终端显示 default 设备的节点二维码（读本机订阅，需要 qrencode） |
| `devices` | 只读列出 VPS 上的设备与本机记录的订阅地址 |

另有 `help`（同 `-h` / `--help`）。

### 退出码

| 码 | 含义 |
| ---- | ---- |
| 0 | 成功 |
| 1 | 远端操作失败或缺少密钥 |
| 2 | 参数错误或无法确定目标 |

## ownexit connect

脚本：`direct/connect_to.sh`。给一台服务器配专用 SSH 密钥（`ownexit direct` 与 `ownexit chain init` 会自动调用）。1.5.0 起不在 `ownexit --help` 里列出，命令照常可用。

### 参数

| 长参数 | 短参数 | 含义 |
| ---- | ---- | ---- |
| `--host` | | 服务器地址 |
| `--user` | `-u` | SSH 用户，默认 root |
| `--port` | `-P` | SSH 端口，默认 22 |
| `--setup-only` | | 只配置和验证免密，不进入交互式 SSH |

### 退出码

| 码 | 含义 |
| ---- | ---- |
| 0 | 成功 |
| 1 | 其它失败 |
| 2 | 参数错误，或非终端运行且没有 `OWNEXIT_SSH_PASSWORD` |
| 3 | 登录失败，stderr 最后一行为 `reason=<取值>` |

### 输出

退出码 3 时 stderr 最后一行冻结（`ownexit direct` 与 `ownexit chain init` 解析它）。

#### reason 取值

| 取值 | 含义 |
| ---- | ---- |
| `reason=bad-password` | 密码错误 |
| `reason=password-disabled` | 服务器关闭了密码登录 |
| `reason=unreachable` | 连不上（IP / 端口 / 安全组） |

## ownexit chain

脚本：`chain/setup_chain.sh`。中转 + 出口链。除 `init` / `up` 外都要用 `--id <名字>` 或 `--config <绝对路径>` 指定配置（二选一），写在子命令之前；本机只有一条链配置时可以省略（没有配置或有多条时退出 2 并提示）。

### 参数

| 长参数 | 适用 | 含义 |
| ---- | ---- | ---- |
| `--id` | 全局 / init | 链名 `[a-z0-9][a-z0-9-]{0,31}`；全局时等价于 `--config <配置目录>/ownexit/chains/<名字>.env`，init 时默认 main |
| `--config` | 全局 | 配置文件绝对路径 |
| `--relay` | init | 中转机 IPv4（不给则交互提问） |
| `--exit` | init | 出口机 IPv4（不给则交互提问） |
| `--relay-port` | init | 中转机 SSH 端口，默认 22 |
| `--exit-port` | init | 出口机 SSH 端口，默认 22 |
| `--sni` | init | Reality 伪装域名，默认 www.amazon.com |
| `--exit-source-filter` | init | managed（默认）/ provider / none |
| `--with-fail-closed` | verify | 额外验证中转停止时出口不泄露 |
| `--allow-tun` | deploy / up（init 接受但无效） | 本机到服务器的路由经代理 TUN 时默认拒绝（退出 3），加它只警告继续 |
| `--device` | qr | 显示该设备的节点二维码；不带时显示 default |
| `--to` | migrate-exit | 新出口机 IPv4；与 `--abort`、`--abandon-cleanup` 互斥 |
| `--to-port` | migrate-exit | 新出口机 SSH 端口，默认 22；只能与 `--to` 同用 |
| `--abort` | migrate-exit | 中转切换之前放弃迁移，恢复原配置 |
| `--abandon-cleanup` | migrate-exit | 迁移已提交、旧出口机永久失联时放弃清理 |

### 子命令

| 子命令 | 作用 |
| ---- | ---- |
| `init` | 配免密、探测出口 IP 与中转现状，生成链配置 |
| `up` | init（没有配置时）+ deploy + 打印二维码与下一步；接受 init 的全部参数和 `--allow-tun`；可重跑，已有配置且显式给出的地址 / 端口一致时继续，不一致退出 2；不带 IP 且本机只有一条链时复用它 |
| `qr` | 显示 default 节点二维码（`--device <名字>` 显示设备的）；只读本机节点文件，不连服务器 |
| `preflight` | 只读预检 |
| `deploy` | 事务部署 |
| `verify` | 完整验证（可加 `--with-fail-closed`） |
| `status` | 健康状态（机器可读输出见下） |
| `rollback` | 事务拆除 |
| `conns` | 中转端口上各来源 IP 的连接 |
| `kick` | 断开某来源的已建连接（跟一个 IPv4） |
| `ban` | 拉黑来源（跟 IPv4 或 CIDR） |
| `unban` | 解除拉黑（跟 IPv4 或 CIDR） |
| `banlist` | 对照本地与中转的黑名单 |
| `rehost-exit` | 已废弃（仍可用，stderr 提示）：出口机同机换 IP 后原地迁移，要先手改配置；改用 `migrate-exit` |
| `rebaseline` | 重新登记中转机上的既有 sing-box |
| `rotate-keys` | 更换全部设备的 UUID 与 Reality 密钥 / short id |
| `add-device` | 新增一台设备（跟设备名） |
| `remove-device` | 吊销一台设备（跟设备名） |
| `list-devices` | 只读列出设备 |
| `migrate-exit` | 出口机换了 IP 或换了机器，凭据与客户端不变（跟 `--to` / `--abort` / `--abandon-cleanup`）；新地址是同一台机器时自动原地切换（SSH 端口须不变，否则退出 2），旧 IP 不必可达 |

### 退出码

| 码 | 含义 |
| ---- | ---- |
| 0 | 成功，或 `status` 为 deployed / not_deployed |
| 1 | 运行时失败（远端操作、本地提交等） |
| 2 | 参数错误、配置与 state 不一致、设备操作被拒；省略 `--id` 时没有配置或有多条；`up` 已有配置但地址不同；`qr` 没有这台设备 |
| 3 | 预检 / 检查失败、远端不可达或主机指纹不符（`preflight` 的失败一律为 3；`init` / `up` 配免密或探测失败也是 3）；`deploy` / `up` 部署前自检发现路由经 TUN 且未加 `--allow-tun` |
| 4 | `deploy` / `up` 的部署阶段失败（远端不可达仍为 3；迁移进行中被拒也是 4）；`migrate-exit` 发现新出口机上已有本链文件 |
| 5 | `status` 不健康（busy / stale_lock / incomplete / unreachable / orphaned / drifted）、`verify` 失败；`qr` 链未部署、锁忙 / 陈旧、节点文件与 state 不一致；其它命令的锁、state 损坏、未完成事务或收尾 verify 失败；出口机迁移进行中时 rehost-exit / rebaseline / rotate-keys / add-device / remove-device 被拒 |
| 6 | `rollback` 预校验或执行失败（含出口机迁移进行中被拒） |

### 输出

stdout 上的下列行冻结；stderr 上 `[chain][<子命令>] INFO / WARN / ERROR …` 是日志，不冻结。

`status` 输出一行，形如 `status=<状态> [health=…] [role=…] [reason=…] [next=…] [deployment=…] [operation=… step=…]`。下表列出 `status` / `health` / `role` / `reason` / `next` 冻结的取值；`deployment=`（部署 ID 前 12 位）、`operation=`、`step=` 只冻结键名。新增取值属兼容变更，解析方应把未知取值当作“需要人工查看”。

#### status 取值

| 取值 | 含义 |
| ---- | ---- |
| `status=deployed` | 已部署且健康（同时输出 `health=healthy deployment=…`） |
| `status=not_deployed` | 没有活动状态与专属资源 |
| `status=busy` | 同一条链有活动锁 |
| `status=stale_lock` | 锁身份已失效 |
| `status=incomplete` | 有待恢复的事务（同时输出 `operation=` `step=`） |
| `status=unreachable` | 至少一台远端无法核证（同时输出 `role=`） |
| `status=orphaned` | 没有状态，但存在专属对象或暂存目录 |
| `status=drifted` | 有状态，但哈希、权限、unit、监听或基线不一致 |
| `health=healthy` | 健康 |
| `role=relay` | 问题出在中转机 |
| `role=exit` | 问题出在出口机 |
| `reason=transaction-corrupt` | 事务文件损坏 |
| `reason=local-ssh-config-render` | 本机隔离 SSH 配置生成失败 |
| `reason=local-stage-temp-or-artifact-present` | 无状态但本机有暂存或产物 |
| `reason=resource-absence-probe` | 核证专属资源不存在时远端不可达 |
| `reason=deterministic-resource-or-owned-stage-present` | 无状态但远端有本链专属资源或暂存 |
| `reason=state-corrupt` | state.env 损坏 |
| `reason=state-config-binding` | state 与当前配置（或 sing-box 版本）不一致 |
| `reason=state-value-format` | state 字段格式错误 |
| `reason=hostkey-probe` | 主机指纹探测时不可达 |
| `reason=ssh-key-or-hostkey-binding` | SSH 密钥或主机指纹与 state 不符 |
| `reason=binding-probe` | 绑定核验异常 |
| `reason=platform-preflight` | 平台预检失败或不可达 |
| `reason=local-artifacts` | 本机产物与 state 不符 |
| `reason=baseline` | 中转机既有 sing-box 基线变化或不可达 |
| `reason=residue-probe` | 残留检查时不可达 |
| `reason=deployment-residue` | 有部署残留 |
| `reason=resource-probe` | 资源核验时不可达 |
| `reason=exit-op-pending` | 出口机有未完成的凭据或设备操作 |
| `reason=exit-migration-pending` | 出口机迁移进行中（本机有迁移记录） |
| `reason=remote-resource-unit-process-or-listener` | 远端文件、unit、进程或监听不一致 |
| `next=run-mutating-command` | 运行修改类命令（deploy / rollback）让事务收敛或归档旧锁 |
| `next=inspect-transaction` | 人工检查事务文件 |
| `next=check-config` | 检查配置 |
| `next=inspect-local-state` | 人工检查本机状态目录 |
| `next=retry-status` | 稍后重试 status |
| `next=inspect-orphan` | 人工检查孤儿资源 |
| `next=inspect-state` | 人工检查 state.env |
| `next=inspect-binding` | 人工检查密钥 / 主机指纹 |
| `next=inspect-platform` | 人工检查远端平台 |
| `next=inspect-baseline` | 检查中转机既有 sing-box（必要时 rebaseline） |
| `next=inspect-residue` | 人工检查残留 |
| `next=rerun-interrupted-command` | 重跑中断的 rotate-keys / add-device / remove-device / migrate-exit（迁移也可 `--abort` / `--abandon-cleanup`） |
| `next=run-verify` | 运行 verify 查看详情 |

#### 其它命令输出

| 行首 | 整行格式 | 命令 |
| ---- | ---- | ---- |
| `rotate=done` | `rotate=done chain=<链> result=<fresh / resumed / already / resumed-after-commit>` | rotate-keys |
| `device=added` | `device=added chain=<链> name=<名字> node=<路径> result=<…>` | add-device |
| `device=removed` | `device=removed chain=<链> name=<名字> result=<…>` | remove-device |
| `rehost=noop` | `rehost=noop chain=<链> next=run-verify` | rehost-exit、migrate-exit（同机切换已完成、无需再迁时） |
| `rebaseline=noop` | `rebaseline=noop chain=<链> kind=<yes / ownexit-direct / no>` | rebaseline（无需重新登记时） |
| `banlist=consistent` | `banlist=consistent entries=<数量>` | banlist |
| `banlist=inconsistent` | `banlist=inconsistent next=run-ban-or-unban` | banlist |
| `kicked` | `kicked ip=<IP> destroyed=<数量>` | kick |
| `banned` | `banned entry=<条目> entries=<数量> destroyed=<数量>` | ban |
| `already-covered` | `already-covered entry=<条目> by=<已有条目>` | ban（已被覆盖时） |
| `unbanned` | `unbanned entry=<条目> entries=<数量>` | unban |
| `migrate=done` | `migrate=done chain=<链> exit=<新出口机 IP>:<端口> old_exit_cleanup=<done / pending>` | migrate-exit |
| `migrate=aborted` | `migrate=aborted chain=<链>` | migrate-exit --abort |
| `migrate=rehosted` | `migrate=rehosted chain=<链> exit=<新出口机 IP>:<端口>` | migrate-exit（新地址是同一台出口机，原地切换完成） |

行首的键与取值冻结；其余键只冻结键名，键的顺序不承诺。

#### 其它输出（人工核对）

| 命令 | 输出 |
| ---- | ---- |
| list-devices | 每台设备一行 `device=<名字> node=<路径>`；本机缺节点文件时 node 以 `missing` 开头（其后提示文字不冻结） |
| conns | 表头 `ip conns idle_min_s idle_max_s banned`，每个来源一行，末行 `proxyd_fd=<已用>/<上限> established=<数量> peers=<数量> port=<端口>` |
| banlist | `banlist=` 行之前的 `local:` / `socket:` / `service:` 三行回读 |
| init | 成功时最后一行 `[chain][init] next=<脚本名> --id <链> deploy`（stdout） |
| deploy / up | 成功后（含已部署的幂等 no-op）stdout 打印“下一步”块：`vless://` 节点链接、应显示的出口 IP、`ownexit doctor`，有 qrencode 时附终端二维码 |
| qr | 有 qrencode 时输出终端二维码；没有时输出 `node=<路径>`、节点链接一行与安装提示 |

## ownexit multi

脚本：`chain/multi_chain_client.sh`。把多条链聚合成一组客户端产物；只读本机链产物，不连服务器。

### 参数

| 长参数 | 短参数 | 含义 |
| ---- | ---- | ---- |
| `--chains` | | 逗号分隔的链名，顺序即自动组优先级（必需） |
| `--name` | | 产物目录名，默认 all |
| `--group` | | 自动组类型：fallback（默认）/ url-test |
| `--test-url` | | 自动组健康检查地址，默认 https://www.gstatic.com/generate_204 |
| `--interval` | | 自动组健康检查间隔（秒），默认 300 |
| `--qr-out` | | 二维码输出目录（必须不存在）；默认在 `${TMPDIR:-/tmp}` 下新建 |
| `--no-open` | | 不自动打开二维码目录 |
| `--no-qr` | | 不生成二维码 |

### 子命令

| 子命令 | 作用 |
| ---- | ---- |
| `verify` | 逐链从本机做真实 Reality 握手与出口仲裁 |
| `render` | 生成聚合产物（产物文件见 files.md） |

### 退出码

| 码 | 含义 |
| ---- | ---- |
| 0 | 成功 |
| 1 | 运行时失败（本机依赖缺失、渲染） |
| 2 | 参数 / 配置 / node.txt 校验错误，或各链 EXPECTED_EXIT_IPV4 不一致 |
| 5 | verify 有链不健康，或全部 skipped |

### 输出

stdout 上带 `[multi-chain-client]` 前缀的下列行冻结（其余为日志）：

| 行 | 说明 |
| ---- | ---- |
| `[multi-chain-client] verify chain=<链> addr=<中转地址> result=<结果> endpoints=<n>/3 elapsed=<秒>s` | result ∈ ok / skipped / timeout / blocked / mismatch / error |
| `[multi-chain-client] render nodes=<路径>` | 节点列表文件 |
| `[multi-chain-client] render clash_snippet=<路径>` | Clash 片段文件 |
| `[multi-chain-client] render qr_dir=<路径>` | 二维码目录（生成二维码时） |

## ownexit doctor

脚本：`direct/doctor.sh`。只读诊断本机、直连 VPS 与链，可选出口 IP 体检与伪装域名扫描。

### 参数

| 长参数 | 短参数 | 含义 |
| ---- | ---- | ---- |
| `--host` | | 只检查这一台直连 VPS |
| `--port` | | 配合 `--host`：SSH 端口，默认 22 |
| `--user` | | 配合 `--host`：SSH 用户，默认 root |
| `--chain` | | 只检查这一条链（可与 `--host` 同用） |
| `--ip-check` | | 另在出口服务器上做出口 IP 体检 |
| `--scan-sni` | | 另在出口服务器上扫描伪装域名 |
| `--sni-candidates` | | 配合 `--scan-sni`：逗号分隔的候选域名（最多 30 个） |
| `--local-only` | | 只检查本机（不能与 `--host` / `--chain` / `--ip-check` / `--scan-sni` 同用） |

### 退出码

| 码 | 含义 |
| ---- | ---- |
| 0 | 没有 FAIL（可以有 WARN） |
| 1 | 至少一项 FAIL |
| 2 | 参数错误 |

### 输出

每个检查项一行，以 `[OK]` / `[WARN]` / `[FAIL]` 开头；末行 `doctor: ok=<n> warn=<n> fail=<n>`。这两种格式冻结，检查项文字、体检与扫描段落的内容不冻结。

## 环境变量

| 变量 | 作用 |
| ---- | ---- |
| `OWNEXIT_SSH_PASSWORD` | 非交互配免密时提供 root 密码；`ownexit connect`、`ownexit direct` 首次部署、`ownexit chain init` 都会用到（经子进程继承） |
| `XDG_CONFIG_HOME` / `XDG_STATE_HOME` / `XDG_CACHE_HOME` | 改变配置、状态、缓存目录。链式与 doctor：值不是绝对路径时忽略、回落默认值；直连：按原值使用 |
| `TMPDIR` | `ownexit multi render` 二维码的默认输出目录 |
| `OWNEXIT_PYTHON` | 首次配免密时用来自动输入密码的 Python 解释器（需能 `import pexpect`）。`ownexit` 入口自动设为它自己的解释器（已设置时不覆盖）；直接运行脚本时可自己设置，未设置则依次尝试 `python3` 与系统 `expect` |
| `OWNEXIT_LANG` | 决定入口帮助与向导的语言：`zh` / `en` 时强制该语言，向导也不再问语言；未设或其它值时按 `LC_ALL` → `LC_MESSAGES` → `LANG` 是否以 `zh` 开头选择帮助语言，向导照常先问语言（回车默认取这个判断结果）。从 1.7.0 起也决定脚本的帮助、进度与报错（含服务器端 `[vps]` 日志行）的语言；向导里选的语言会传给脚本。机器可读输出（`status=`、`reason=`、`health=` 等冻结的键与值）两种语言相同 |

`~/.ssh/ownexit/`（专用密钥）不受 XDG 影响。以 `OWNEXIT_TEST_` 开头的变量是测试钩子，不属于公开接口，正常使用不要设置。
