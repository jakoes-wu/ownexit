# 链式只换中转端口：`change-port`

> **2026-10-30 注记**：代码已落地。远端脚本 `write_chport_remote_script`（`chain/setup_chain.sh:7905`）、设备节点核对 `chport_check_devices`（`:8013`）、`chport_inspect`（`:8056`）、`chport_apply`（`:8080`）、`chport_publish_nodes`（`:8115`）、`commit_chport_state`（`:8139`）、主流程 `change_port_chain`（`:8157`）。代码评审 1 轮，无阻塞 / 高 / 中级问题；3 条低级问题已修。§8 的 S1、A1、A2（L0）以及 P1–P7、R1–R5、B1、N1、X1、X2（L1，Ubuntu 22.04 systemd 容器测试床）全部通过。F1（真机）通过：在真实中转机上对链 ip190 运行 `change-port`，端口 31630→34246（`result=fresh`，98 秒，命令自带核验通过）；本机把 Clash 节点端口改为 34246 后，用户在中国电信网络下实测连通，Clash 内核 delay 159 ms。该次运行本机路由经 TUN，非中转来源拒绝侧未验证，留待不经 TUN 的环境补跑 `verify`。

## 1. 背景

- 链式部署时，中转机对外端口 `RELAY_PORT` 在 deploy 里由 `choose_remote_port relay` 随机选取（`chain/setup_chain.sh:3507`，范围 20000–59999，`:3460-3481`），写进中转 socket unit 的 `ListenStream=0.0.0.0:<端口>`（`:4063`）、本机 `state.env`（`:3037`）和客户端节点链接（`render_node_artifact` `:4576-4583`、`render_device_node` `:7656-7665`）。
- 现有子命令（`is_chain_subcommand` `:771-776`）里没有一条只改 `RELAY_PORT` 的。要换端口只能 rollback + deploy，UUID、Reality 密钥、short id、全部设备节点都会换新，每个客户端都得重新导入。
- 2026-10-29 实测：本机经中国电信 SIM 上网时，中转机上有三个端口回程被拦（中转机上只见本机来源的 SYN-RECV），同机其它端口正常；临时在同一中转机开新端口、沿用同一套凭据，旧端口 3/3 超时、新端口 3/3 通。只要换中转端口、凭据不动，就能恢复。
- 直连模式已有同类能力：`direct up --proxy-port <n>` 换端口时沿用订阅端口与令牌（`direct/setup_direct.sh:620-640`）。

## 2. 目标 / 非目标

目标：

1. 新增链式子命令 `change-port [--port <n>]`：只把中转对外端口换成新值，UUID、Reality 密钥、short id、设备表、出口机、中转转发目标都不变。
2. 换完把本机 `client/node.txt` 与 `devices/node-<名字>.txt` 改成新端口，提交 state，并跑与 rotate-keys 相同的完整核验（`full_verify` `:4985-4999`）。
3. 只要 state 已提交为新端口，无论收尾核验成败，都明确告诉用户：哪条链、旧端口、新端口、要改哪些客户端节点。

非目标：

- 客户端无感（本机小网页服务供 Clash 订阅）：本期不做，下一期另行评估。mihomo 实测拒绝 `-d` 目录外的文件型 provider 路径，http provider 不支持 `file://`，服务模式内核目录 root 所有、不可写，所以“本机写文件、Clash 读文件”这条路不可行。
- 不改 `multi_chain_client.sh`：它只读 node.txt（`chain/multi_chain_client.sh:8-17`），换端口后由用户重新 `render`。
- 不自动判断“哪个端口在用户当前网络下能通”：命令只负责换端口和核验，换完仍不通就再换一次。
- 不改出口机 Reality 端口（`EXIT_REALITY_PORT`）：客户端不直接连它。
- 不改 `status` 的 `next=` 取值：半途中断时 `status` 仍报通用的 drifted，由 manual 排查表说明怎么收敛。

## 3. 假设与约束

- 中转机的云安全组不按端口放行。deploy 选随机端口时已经依赖这一点（`:325` 帮助文本：脚本不改防火墙与安全组）。
- 前置检查分两层：
  - 本机层与 rotate-keys 相同（`exit_op_prepare` `:7751-7788`）：锁、迁移闸门、无 `transaction.env`、`probe_state_file` 返回 0、主机密钥绑定（经中转连到出口机，所以出口机必须可达）。`exit_op_prepare` 本身不核远端健康。
  - 远端层由本命令另加：首次换（inspect=fresh）在改任何远端文件之前先跑 `remote_platform_preflight`（它给 `SOCKET_PROXYD_PATH` 赋值，`:2354`；初值为空 `:172`，不先跑则后续参数错位必然失败），再跑 `probe_remote_resources yes`（`:4928`），与 `full_verify` 的顺序相同（`:4986-4990`）；中转、出口机任一处漂移或出口机有未收尾的凭据操作（rc 33）就退出 5，远端零改动。退出码沿用两者各自的处理：`remote_platform_preflight` 失败（含不可达）自己 `die 3`（`:2375-2396`），`probe_remote_resources` 非 0（含不可达 21/22）退出 5（同 `:4991-4992`）。注意：中转 verify 脚本带 `allow_start`，本链 service 若为 inactive 会被顺带 `systemctl start`，但不改任何文件。续跑（inspect=already）时 socket 哈希必然不等于 state，这一步跳过，由收尾的 `full_verify` 兜底。
- 不新增 state 键：`RELAY_PORT`、`RELAY_SOCKET_SHA256`、`NODE_SHA256` 都是已有键，`SCHEMA_VERSION` 保持 1（`docs/reference/compatibility.md:55`）。
- `RELAY_PORT` 不在配置文件里，所以不影响 `CONFIG_SHA256`。中转 owner 文件只含 `CONFIG_SHA256` 等字段，不含端口（`render_owner_file` `:3413-3427`），不用改。
- `--port` 的取值：1–65535，不等于 state 里的当前端口，且在中转上未被监听（复用 `write_port_check_script` `:3443-3457`）。不给 `--port` 时用 `choose_remote_port relay` 随机选。

## 4. 涉及模块

| 区域 | 行号锚点（main 当前状态） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| 全局变量 | `chain/setup_chain.sh:93-97` 邻近 | 新增 | `CHPORT_REQUESTED=''`（`--port` 的值） |
| `usage` 英文 | `:207-211`、`:242-258`、`:320-322` 邻近 | 修改 | 加用法行、子命令说明、`--port` 说明、示例 |
| `usage` 中文 | `:352-358`、`:380-391`、`:445-447` 邻近 | 修改 | 同上 |
| `is_chain_subcommand` | `:773` | 修改 | 词表加 `change-port` |
| `parse_args` 子命令 case | `:828-889` | 新增分支 | `change-port)`：只接受可选的 `--port <n>` |
| 远端脚本与本机流程 | `list_devices_chain`（`:7842-7859`）之后、`# ---------- 出口机跨机迁移` 注释（`:7861`）之前 | 新增 | `write_chport_remote_script`、`chport_remote_reason`、`chport_check_devices`、`chport_inspect`、`chport_apply`、`chport_publish_nodes`、`commit_chport_state`、`chport_test_stop`、`change_port_chain` |
| `main` 分派 | `:9553-9562` 邻近 | 新增分支 | `change-port) change_port_chain ;;` |
| `docs/reference/commands.md` | 子命令表 `:150-161`、退出码 2 一行 `:169`、退出码 5 一行 `:172`、`#### 其它命令输出` `:230-240`、参数表 | 修改 | 加子命令、`--port` 参数、输出行 `port=changed`；退出码 2 加“change-port 指定端口等于当前端口，或新端口已被占用”；退出码 5 的“迁移进行中被拒”名单加 change-port，并写入 change-port 自己的 5：远端 drift、设备节点不一致、远端健康预检失败 |
| `docs/reference/commands.en.md` | 对应位置 `:152-163`、`:171`、`:174`、`:233-242` | 修改 | 同上（英文） |
| `docs/reference/compatibility.md`、`.en.md` | `:57` | 修改 | “升级前先收敛未完成的操作”加一句：change-port 中断的先重跑 change-port |
| `docs/manual/chain.md`、`chain.en.md` | 日常操作代码块（中文 `:71-75`）、说明段（`:80`）、§6“中转机被墙了怎么办”（`:82-92`）、故障排查表（`:134` 邻近） | 修改 | 加用法行与说明；§6 加一句“只有个别端口不通时先试 change-port”；排查表加一行“change-port 中断后 status 报 drifted → 重跑 change-port” |
| `scripts/check_interface.sh` | `:195` | 修改 | 输出行前缀的正则加 `port` |
| `chain/README.md`、`chain/README.en.md` | rotate-keys 一节（中文 `:238` 起）之后 | 新增小节 | 用法、何时用、换完要做什么、中断怎么收敛 |
| `README.zh-CN.md`、`README.md` | 日常操作一段（中文 `:147`） | 修改 | 加一句 `change-port` |
| `CHANGELOG.md` | `## [Unreleased]`（`:7`） | 新增 | Added 一条 |

`docs/reference/files.md` 不改：没有新增文件或 state 键；审计目录 `audit/` 本就列为内部文件（`files.md:44`）。

## 5. 方案

### 5.1 实现要点

**总流程**（`change_port_chain`），第 1–6 步失败时远端零改动：

1. `exit_op_prepare`（`:7751`）。
2. 清本机残留：与 `exit_op_chain` 相同的口径（`:7796-7801`），删 `.node.txt.rotate.*.tmp` 与 `devices/.*.tmp`。本命令的本机临时文件用同样的命名，所以 verify 的残留检查（`:4651-4652`）和 rollback 的清理（`:5752-5760`）都能覆盖到，不用加新规则。
3. `chport_check_devices`（设备节点核对，见下文“设备节点”），不通过就退出 5。
4. `chport_inspect`：远端脚本 inspect 模式，只读，返回：
   - `STATE=fresh`：socket 文件哈希等于 state 的 `RELAY_SOCKET_SHA256`；
   - `STATE=already PORT=<P>`：哈希不等，文件里恰好一行 `ListenStream=0.0.0.0:<P>`（P 不等于 state 端口），把这一行换回 state 端口后哈希等于 state 值。说明上次已把文件改到 P、在提交 state 之前中断；
   - 其它情况按 231–233 退出（drift）。
5. 远端健康预检：inspect=fresh 时先 `remote_platform_preflight`（失败退出 3），再 `probe_remote_resources yes`，非 0 退出 5（rc 33 用 rotate-keys 相同的文案，`:4991`）；already 时跳过。
6. 定新端口 N：
   - 给了 `--port Q`：核 Q 不等于 state 端口（否则退出 2）；Q 等于 P 时直接用；否则核 Q 在中转上空闲（被占退出 2）；
   - 没给 `--port`：fresh 时 `choose_remote_port relay`；already 时用 P。
   - 中转上的端口检查（`write_port_check_script`）输出既不是 `free` 也不是 `used`，或 SSH 返回 255：退出 3。这条针对给了 `--port` 时的单次检查；随机选端口时 `choose_remote_port` 不区分 SSH 失败，失败都按“不空闲”重试，用尽后以“选不出端口”退出 3（`:3460-3481`）。
   - already 状态下也允许 `--port Q`（Q≠P），用来处理 P 绑不上（被别的程序抢占、restart 失败）的情况：apply 把 P 那一行换成 Q。
7. `chport_apply`：远端脚本 apply 模式，见下文“远端脚本”。
8. `chport_test_stop remote`（测试钩子，见 §8 末）。
9. `chport_publish_nodes`：本机节点文件改成 N（见下文“设备节点”）。
10. `chport_test_stop nodes`。
11. `commit_chport_state`：审计前缀 `port-changed`，旧 state 归档后写新 state，`RELAY_PORT`、`RELAY_SOCKET_SHA256`、`NODE_SHA256` 用新值，其余字段原样。结构照抄 `commit_rehost_state`（`:6810-6829`）。不复用 `commit_exit_op_state`，因为它会用 `ROTATE_NEW_EXIT_SHA256` 覆盖 `EXIT_EXIT_SHA256`（`:7732`）。
12. 提交后立刻打客户端提示（`log_warn`，不等核验）：链名、旧端口、新端口；节点 `Exit-via-Relay-<链>` 及各设备节点 `Exit-via-Relay-<链>_<名字>` 的端口要改成新值，或重新导入 `client/node.txt` / `devices/`；用了多链聚合的要重新 `render`。这样即使下一步核验失败退出非 0，用户也拿到了新端口。
13. `ensure_local_assets_match_state`（`:4971`）→ `full_verify`（`:4985`）。核验里有中转本机冒烟 `smoke_from_relay 127.0.0.1 <新端口>`（`:4981`）和本机经新端口连出口的冒烟（`smoke_from_mac`）。
14. 结果行：`printf 'port=changed chain=%s old=%s new=%s result=%s\n'`，result 取 `fresh`（本次 inspect=fresh）/ `resumed`（inspect=already）。只在核验通过后输出；核验失败时只有第 12 步的提示。

**远端脚本**（`write_chport_remote_script`，一个 heredoc，`set -euo pipefail`、`LC_ALL=C`，两种模式）。`migrate_file` 在 `REHOST_REMOTE` heredoc 内部（`:6694-6716`），无法调用，这里照抄其结构并改为针对 socket 的整行比较：

- 参数：`mode`（inspect / apply）、`chain_id`、`state_hash`、`state_port`；apply 另加 `cur_port`（文件当前端口：fresh 时等于 state_port，already 时为 P）、`new_port`、`test_stop`（`file` 或 `-`）。
- 文件：`/etc/systemd/system/ownexit-chain-relay-<id>.socket`，要求普通文件、root:root 644（否则 231）。
- 行匹配：inspect 不知道 P，按正则 `^ListenStream=0\.0\.0\.0:[1-9][0-9]{0,4}$` 计数并抽出端口，恰好 1 行（否则 232）；apply 已知 `cur_port`，用整行等于 `ListenStream=0.0.0.0:<cur_port>` 的 awk 字符串比较，计数必须为 1（否则 232）。
- 守门：把文件中 `cur_port` 那一行换回 `state_port` 后的哈希必须等于 `state_hash`（`cur_port` 等于 `state_port` 时即文件哈希本身），否则 233。
- apply 改文件：`cur_port` 不等于 `new_port` 时，先核 `new_port` 空闲（否则 234），再写同目录临时文件 `.ownexit-chain-relay-<id>.socket.chport.$$.tmp`、chown root:root、chmod 644、`mv -f` 原子替换。脚本开头照 rehost 设 `tmp_in_flight` + `trap ... EXIT` 清理（`:6671-6674` 同款），保证任何退出路径都不留临时文件。
- 测试钩子：`test_stop` 为 `file` 时，在 `mv` 之后、`daemon-reload` 之前 `exit 99`。
- 生效：`systemctl daemon-reload` → `systemctl stop <service>` → `systemctl restart <socket> || exit 235`。显式先停 service：`Accept=no` 时监听 fd 由 proxyd 持有，不停的话旧端口会被它继续监听；本链现有连接会断开一次。
- 回读：socket `is-active` 为 active（否则 235）；`new_port` 在监听（与 `:4912` 同一个 awk 后缀匹配，否则 236）；`state_port` 不再监听（否则 237）。
- 回读通过后 `systemctl start <service> || exit 235`，并核 service `is-active` 为 active（否则 235）。前面为放开旧端口停了 service，这里把它拉起来，否则收尾核验早退时 service 一直停着，rollback 的预检（`probe_remote_resources no`，`:5890`）会因中转 verify 脚本的 170（`:4914-4919`）判 drift。
- 幂等：文件已是 `new_port` 形态时跳过改文件，照常 daemon-reload → stop service → restart socket → 回读 → start service。
- 输出：`SOCKET=changed|already`、`SOCKET_SHA256=<新哈希>`。

远端码到本机退出码的映射（`chport_remote_reason` 给文案，照 `rehost_remote_reason` `:6757`）：

| 远端码 | 含义 | 本机退出码 |
| ---- | ---- | ---- |
| 231 | socket 文件身份或权限异常（要求 root:root 644、非链接） | 5 |
| 232 | `ListenStream=0.0.0.0:<端口>` 不是恰好 1 行 | 5 |
| 233 | 与 state 哈希不符，也不是已改形态（drift） | 5 |
| 234 | 新端口已被别的程序监听 | 2（给了 `--port` 时提示换一个；没给时说明是随机选的端口刚被占，直接重跑会重新随机选） |
| 235 | restart 失败、socket 不是 active，或 service 拉不起来 | 1（提示重跑；仍不行就加 `--port` 换一个） |
| 236 | 新端口未监听 | 1（同上） |
| 237 | 旧端口仍在监听 | 1（提示重跑） |
| 99 | 测试钩子（只在设置了钩子时） | 原样以 99 退出，同 `exit_op_apply` `:7620-7623` |
| 255 | SSH 不可达或会话中断 | 3 |
| 其它非 0 | 未预期的远端失败 | 1 |

**设备节点**：

- `chport_check_devices`（第 3 步）：以本机 `devices/devices.env`（`name=uuid`，由 `publish_exit_op_artifacts` 写，`:7697-7701`）为准。要求 `devices/` 下的 `node-*.txt` 文件集合与 `devices.env` 的名字集合一致；每个文件与“用 `devices.env` 的 UUID、以 state 端口渲染（`render_device_node`）”的结果逐字节相同，或只有 `@<中转>:<端口>?` 里的端口不同、其余逐字节相同（`@<RELAY_HOST>:` 在文件中只出现一次，端口部分限定为纯数字）（上次在第 9 步中断留下的形态；此时还不知道 P，所以只要求“仅端口不同”）。不一致退出 5，文案：本机设备节点文件与 devices.env 不一致，远端未改动；对该设备重跑 `add-device` / `remove-device`，或检查文件是否被手动改过。没有 `devices/` 目录时跳过。
- `chport_publish_nodes`（第 9 步）：
  - `client/node.txt`：设 `RELAY_PORT=N` 后 `render_node_artifact` 写 `${CHAIN_STATE_DIR}/.node.txt.rotate.${OPERATION_ID}.tmp`，`mv` 到 `client/node.txt`，重算 `NODE_SHA256`（同 `publish_exit_op_artifacts` `:7674-7680`）。
  - 设备节点：按 `devices.env` 的 UUID 以 N 渲染到 `devices/.node-<名字>.txt.${OPERATION_ID}.tmp`，`mv` 替换。

**中断后如何收敛**（不写本机意图文件，新端口以中转上的 socket 文件为准）：

| 中断点 | 当时状态 | 重跑时 |
| ---- | ---- | ---- |
| apply 改文件之前 | 远端、本机都是旧的 | inspect=fresh，重新预检、选端口 |
| 改完文件，restart、回读或 service 拉起之前 | 远端文件是 P，state 是旧的，service 可能停着 | inspect=already P，apply 补 stop service → restart → 回读 → start service；P 绑不上时加 `--port Q` 改到 Q |
| 节点文件改了一部分 | 远端是 P，节点新旧混杂，state 是旧的 | 同上；设备核对允许“仅端口不同” |
| state 已提交，`full_verify` 之前或失败 | 全部是新端口 | 端口已换完，提示已打出；`verify` 可单独复核。再跑 `change-port` 会再换一个新端口，这正是“新端口在当前网络也不通”时要做的 |

### 5.2 接口变更

- 新增子命令 `change-port`，可选参数 `--port <n>`（`ownexit chain change-port`、`setup_chain.sh --id <链> change-port [--port <n>]`）。只有一条链时可以省略 `--id`，因为加进了 `is_chain_subcommand`。
- 新增输出行 `port=changed chain=<链> old=<端口> new=<端口> result=<fresh / resumed>`。
- 退出码沿用现有含义，不新增：2 参数错误、指定端口被占用、配置与 state 不一致（`exit_op_prepare` rc 12，`:7769`）；3 SSH 不可达、选不出端口、平台预检失败（含收尾核验中的平台预检 / TLS / 出口直连探测，`:4986-4989`）；5 锁 / 迁移进行中 / 未完成事务 / drift / 设备节点不一致 / 远端健康预检失败或不可达 / 收尾核验失败；1 远端生效失败，以及收尾核验中的本机冒烟失败（`smoke_from_mac` `:4513-4554`、`smoke_from_relay` `:4321`、`:4326-4327`、`probe_mac_reality_rejection` `:4559-4569` 用 `die 1`）。收尾核验失败因此为 5、1 或 3。
- state.env 字段集合与 `SCHEMA_VERSION` 不变。旧版本脚本读新 state 没有问题（只是值变了）。
- 审计目录新增前缀 `audit/port-changed.<部署ID>.<操作ID>/`（内部文件）。
- 向后兼容：纯新增，不改任何已有命令的行为。

**reference sibling 回补检查**（按 §“方案文档章节内容质量要求” §5）：

- Q1 涉及 reference 章节：`docs/reference/commands.md`（及 `.en.md`）的 `ownexit chain` 子命令表、参数表、退出码表、`#### 其它命令输出`；`docs/reference/compatibility.md`（及 `.en.md`）的“升级前先收敛未完成的操作”。
- Q2 源码暴露面完整性：`scripts/check_interface.sh` 第 5、6、6b、8 节（`:150-198`）已经把参数、子命令、`is_chain_subcommand`、输出行前缀与文档表逐项比对，CI 通过即一致；本次改动后再跑一次该脚本核对。
- Q3 本方案是否回补：N/A——新增暴露面与文档化同步落地（含退出码 2 一行新增的 change-port 场景，见 §4 commands.md 行）。
- Q4 placeholder 落地：N/A。

## 6. 备选方案与决策

| 方案 | 否决理由 |
| ---- | ---- |
| rollback + deploy | 凭据全换，所有客户端要重新导入 |
| 本机写意图文件记新端口（仿 `migrate-exit.env`） | 远端 socket 文件本身就能唯一推出新端口（反向替换后核哈希），多一个文件就多一种不一致和清理路径 |
| 新端口与旧端口同时监听一段时间再关旧端口 | 要改 socket 单元结构（两条 `ListenStream`），verify / rollback / conns / kick / ban 都按单端口写，改动面大；本命令的用途是旧端口已经不通，没有平滑过渡的需要 |
| 设备节点从出口机重新读设备表来渲染 | 多一次远端读取；本机 `devices.env` 已有 name=uuid，由同一流程写出，足以重渲染 |

## 7. 影响分析

正向（改了什么、谁在用）：

- 中转 socket 单元：只改 `ListenStream` 一行。drop-in 黑名单（`RELAY_BLACKLIST_DROPIN` `:110`，写在 `.socket.d/` 目录，`:6508-6511`）不在主文件里，哈希不受影响；restart 后 `IPAddressDeny` 照样生效，`full_verify` 的 `probe_remote_resources` 用 `check_managed_dropin`（`:4850`）回读核对。
- service 单元、owner 文件、出口机：都不动。中转转发目标仍是 `EXIT_HOST:EXIT_REALITY_PORT`。出口机 nft 白名单按来源地址（中转 IP）放行，与中转对外端口无关。
- 同一中转机上的其它链、既有 sing-box：各链是独立的单元；只重启本链的 socket 与 service。新端口事先核过空闲；但核空闲到 restart 之间有竞争——同一中转上两条链同时 change-port 或与另一条链的 deploy 并发（各持各的链锁，`:7753`），可能选中同一端口。前一条已 restart 完时，后者在 apply 核空闲处 234 退出 2，远端零改动，直接重跑即可；两条都过了核空闲时，后者 restart 失败报 235、退出 1，此时它的远端文件已是该端口，不带参数重跑仍判 already 并再次 235，必须加 `--port` 换一个端口收敛。不会损坏另一条链。
- 本机：`client/node.txt`、`devices/node-*.txt`、state.env 改值。`qr` 读 node.txt，自动跟随；`multi` 读 node.txt，要用户重新 `render`（提示里写明）。
- state 提交后，使用 `RELAY_PORT` 的其它命令（`conns` `:6388`、`kick` `:6440`、rollback `:5484-5567`、fail-closed `:5296-5300`、冒烟 `:4981` / `:5222` / `:8665`）都自然用新端口。

反向（半途状态下其它命令的实际行为，即远端已改到 P、state 仍是旧端口）：

- `status` / `verify`：socket 哈希不符（`:4882` 的 exit 158），报 drifted / 退出 5。
- `rollback`：预检 `probe_remote_resources no` 不过，退出 6（`:5890-5892`）。要先重跑 change-port 收敛。
- `conns` / `kick` / `ban` / `unban`：走 `require_deployed_for_control`（`:6339`），不核 socket 哈希，按旧端口执行——`conns` 显示 0 连接、`kick` 踢不到；`ban` 写 drop-in 不受端口影响，仍有效。不会造成损坏，收敛后恢复正常。
- `rotate-keys` / `add-device` / `remove-device`：不预检中转，会照常改出口机、按 state 旧端口渲染节点并提交，最后在 `full_verify` 因 socket 哈希不符退出 5。它们不改 `RELAY_SOCKET_SHA256`，并会按新设备表重写 `devices.env` 与节点文件，之后重跑 change-port 仍按“already P”收敛（§8 R5 覆盖）。
- `migrate-exit`（跨机）：准备阶段跑 `remote_platform_preflight` + `probe_remote_resources no`（`migrate_prepare` `:8250-8253`），socket 哈希不符即退出 5，不会开始迁移。
- 同机迁移（rehost）与 `rebaseline`：不读写中转 socket 文件、不改 `RELAY_SOCKET_SHA256`，会照常提交，最后在 `full_verify`（`:6864`、`:7273`）因 socket 哈希不符退出 5；之后重跑 change-port 仍按“already P”收敛。
- 锁：用同一把 chain 锁（`acquire_chain_lock 1`），与上述修改类命令互斥；迁移记录存在时被 `migrate_gate` 拦下。

运行时：

- 中断时长：restart socket 到新端口监听约 1 秒内；本链现有连接全部断开一次，客户端改端口前本链不可用。这正是用户要换端口的前提（旧端口已不通）。
- SSH 次数：inspect 1 次、平台预检 `remote_platform_preflight` 1 次、远端健康预检（同 verify 的远端部分）、选端口 1–N 次（与 deploy 相同）、apply 1 次，再加 `full_verify` 现有的次数。
- 没有新进程、没有新的常驻文件。

部署形态：

- 带黑名单 drop-in 的链：见上，restart 后回读核对。
- 服务商安全组按端口放行的中转：新端口会不通，`full_verify` 的本机冒烟失败、退出 1（控制端有本机平台官方包、到中转的路由不经 TUN 时才做本机冒烟，`:4514-4523`；否则跳过本机冒烟）。这时 state 已提交为新端口，第 12 步的提示已经打出；用户可以去放行，或再跑一次 `change-port --port <已放行的端口>`。

## 8. 回归测试

L0 不需要服务器；L1 在 Linux 测试机上用带 systemd 的容器搭中转、出口与控制端（与 `feature-exit-bind-ip.md` §8 相同的测试床）。

| 编号 | 层级 | 操作 | 预期 |
| ---- | ---- | ---- | ---- |
| S1 | L0 | `scripts/check_interface.sh`、`check_i18n.sh`、`check_ui_lang.sh`、`check_public.sh`；`bash -n`（含 macOS `/bin/bash` 3.2）；`shellcheck -S warning chain/*.sh scripts/*.sh` | 全部退出 0 |
| A1 | L0 | 夹具：临时配置目录里只放一份合法的链配置（未部署）。运行 `change-port --port`（缺值）、`--port 0`、`--port 70000`、`--port abc`、`change-port --foo` | 都退出 2，stderr 是 change-port 分支自己的文案；没有配置或有多条链时，参数解析之前先报 `resolve_single_chain_config`（`:8888`）的通用文案，不在本用例内 |
| A2 | L0 | 同 A1 的夹具，运行 `setup_chain.sh change-port`（不带 `--id`、`--config`） | 解析到该链并进入命令，因“chain 尚未部署”退出 5；不报“首个参数必须是…”（`:822`） |
| P1 | L1 | 部署链 a，`change-port`（不带参数） | 输出 `port=changed ... result=fresh`，新端口在 20000–59999；中转 socket 文件只有 `ListenStream` 一行不同；state 的 `RELAY_PORT`、`RELAY_SOCKET_SHA256`、`NODE_SHA256` 变化，`VLESS_UUID`、公钥、short id、`EXIT_*` 不变；`status` healthy、`verify` 通过；控制端按新 node.txt 起客户端能访问出口 |
| P2 | L1 | `change-port --port <指定空闲端口>` | 新端口等于指定值；其余同 P1 |
| P3 | L1 | `--port <当前端口>`；`--port 22`（中转 SSH 在听） | 都退出 2；中转 socket 文件哈希仍等于 state，本机文件不变 |
| P4 | L1 | 链 a 有设备 x、y 时 `change-port` | `devices/node-x.txt`、`node-y.txt` 端口变为新值，其余字节不变；用 x 的节点能连通 |
| P5 | L1 | 手改 `devices/node-x.txt` 的 short id 后 `change-port`；另做一次删掉 `node-y.txt` 后 `change-port` | 都退出 5，提示设备节点不一致；中转 socket 文件哈希仍等于 state，state 不变 |
| P6 | L1 | 手改中转 service 文件（加一行注释）后 `change-port` | 远端健康预检退出 5；socket 文件哈希仍等于 state |
| P7 | L1 | 前提：控制端有本机平台官方包、到中转的路由不经 TUN。`change-port --port <N>` 前，在控制端用防火墙丢弃去往中转 N 端口的出站 | 退出 1（本机冒烟失败）；stderr 含新端口 N 和要改的节点名；state 的 `RELAY_PORT` 已是 N |
| R1 | L1 | `OWNEXIT_TEST_CHPORT_STOP_AFTER=file` 运行（远端 mv 之后、daemon-reload 之前退出 99） | 退出 99；`status` 报 drifted；不带参数重跑输出 `result=resumed`，新端口等于中断前的 P；`verify` 通过 |
| R2 | L1 | 钩子 `nodes`（本机节点文件写完、state 提交之前退出 99） | 重跑 `result=resumed`，端口仍是 P；verify 通过 |
| R3 | L1 | R1 的中断状态下，在中转上用 `nc -l` 占住 P，再不带参数重跑；然后带 `--port Q` 重跑 | 第一次退出 1（235 或 236），提示加 `--port`；第二次 `result=resumed`，新端口为 Q，socket 文件只有一行 `ListenStream=0.0.0.0:Q`，verify 通过 |
| R4 | L1 | R1 的中断状态下 rollback | 退出 6（远端 drift）；重跑 change-port 收敛后 rollback 正常 |
| R5 | L1 | R1 的中断状态下 `rotate-keys`，再重跑 `change-port` | rotate-keys 最后退出 5；重跑 change-port `result=resumed` 收敛，verify 通过，节点里是新凭据 + 新端口 |
| B1 | L1 | 链 a 先 `ban 198.51.100.0/24`，再 `change-port` | 成功；`banlist=consistent`；`systemctl show <socket> -p IPAddressDeny` 仍含该网段 |
| N1 | L1 | 同一中转上另有链 b 与既有 sing-box，对 a `change-port` | b 的 socket / service 进程号与端口不变、`verify` 通过；`verify` a 时 `verify_relay_baseline` 通过 |
| X1 | L1 | 链 a 有迁移记录（`migrate-exit` 中途）时 `change-port` | 退出 5，迁移闸门提示 |
| X2 | L1 | 另一终端持有 a 的锁时 `change-port` | 退出 5，busy 提示 |
| F1 | L3 | 真实中转机上对一条在中国电信网络下被拦端口的链运行 `change-port`，本机在该网络下改 Clash 节点端口 | 新端口可连通，出口 IP 等于 `EXPECTED_EXIT_IPV4`（以 Clash 内核 delay 与出口 IP 查询为准） |

测试钩子 `OWNEXIT_TEST_CHPORT_STOP_AFTER`，只供测试：

- `file`：本机把它作为 apply 的 `test_stop` 参数传给远端，远端在 `mv` 之后 `exit 99`，本机见 99 原样退出（同 `exit_op_apply` `:7620-7623`）。
- `remote` / `nodes`：本机侧 `chport_test_stop`，写法同 `rotate_test_stop`（`:7296-7301`）。

## 9. 日志 / 观测点

- 固定前缀 `[chport]`：
  - `[chport] start chain=<链> old=<端口> requested=<端口或 ->`；
  - `[chport] inspect=fresh|already port=<P>`；
  - `[chport] socket=changed|already new=<端口>`；
  - `[chport] node files published`；
  - `[chport] state committed audit=<路径>`；
  - 提交后的客户端提示（`log_warn`，含新旧端口与节点名）。
- 结果行：`port=changed chain=<链> old=<端口> new=<端口> result=<fresh / resumed>`。
- 失败：`die` 文案带远端退出码原因（`chport_remote_reason`），state 提交前的失败附“重跑 change-port 收敛”。
- 远端可查：`systemctl cat ownexit-chain-relay-<链>.socket` 的 `ListenStream`，`ss -H -ltn` 是否有新端口。
- 本机可查：`state.env` 的 `RELAY_PORT`，`client/node.txt` 中 `@<中转>:<端口>`，`audit/port-changed.*` 里的旧 state。
