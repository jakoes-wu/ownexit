# v1.5.0：命令统一（直连改子命令、subctl 并入 direct、migrate-exit 自动处理同机换 IP）

## 1. 背景

- 直连与链式两套写法：链式维护操作是子命令（`ownexit chain rotate-keys`），直连是参数（`ownexit direct --rotate-keys`）；直连部署后的日常操作又在另一个子命令 `ownexit subctl` 里。
- 出口机换 IP 有两条命令：`migrate-exit`（换机器）与 `rehost-exit`（同机换 IP，要先手改配置与 known_hosts）。1.4.0 只统一了文档入口，`migrate-exit` 遇到同一台机器仍然报错让人改用 `rehost-exit`。
- `ownexit connect` 由 `direct` / `chain init` 自动调用，用户基本不需要直接用，但列在入口帮助里。
- `docs/reference/compatibility.md` §3：删除或改名属不兼容变更，要先废弃（至少一个次版本继续可用、输出里提示替代写法），最早在下一个主版本移除。
- 用户 2026-10-06 拍板：版本 1.5.0，只加新写法，旧写法照常可用并提示替代写法（删除留给以后的 2.0）；直连全面改子命令（形态见 §5.1.1）；`migrate-exit` 遇同一台机器自动处理，`rehost-exit` 保留为废弃别名。

## 2. 目标 / 非目标

目标：

1. 直连全部操作用子命令：`ownexit direct up | rotate-keys | rotate-token | add-device <名> | remove-device <名> | migrate | uninstall | sub start [--ttl] | sub stop | status | log [行数] | qr | devices | login`。`ownexit direct --host <IP>`（不带子命令）照旧等同 `up`，不提示废弃。
2. 旧写法（`direct --rotate-keys` 等 6 个动作参数、`ownexit subctl …`、`chain rehost-exit`）照常可用，每次使用在 stderr 打一行“已废弃（仍可用），改用：…”；退出码与行为不变。
3. `chain migrate-exit --to <新 IP>` 发现新地址是同一台出口机（ed25519 主机指纹与 state 相同）时，自动登记新 IP 的主机密钥、备份并改写配置里的 `EXIT_HOST` / `EXPECTED_EXIT_IPV4`，再执行原 `rehost-exit` 的原地切换；旧 IP 是否可达都能完成，中断后重跑同一条命令续上。

另：入口帮助不再列出 `connect`、`subctl`（命令照常可用，参考文档保留）；所有提示文字、手册、README 改用新写法。

非目标：

- 不删除任何旧写法、不改任何退出码含义（属 2.0）。
- 不改 `chain` 的其它子命令，不给 `direct` 加 `chain` 才有的功能（如 `verify`）。
- 不改 `rehost-exit` 本身的行为（只加废弃提示、报错文字去掉命令名）；不改跨机器迁移的流程。
- 不回改 `docs/feature/` 下的历史方案文档，不改代码注释里对旧写法的提及。

## 3. 假设与约束

- `direct` 的子命令词可以出现在参数前后任意位置（与 `chain --id main rotate-keys` 一致）；子命令词只取 §5.1.1 列出的这些，IP / 域名不会与它们重名。
- 日常操作子命令（`sub` / `status` / `log` / `qr` / `devices` / `login`）整体转给 `direct/subctl` 执行（`exec bash subctl …`），不在 `setup_direct.sh` 里重写；转发时设环境变量 `OWNEXIT_VIA_DIRECT=1`，让 subctl 不打废弃提示（内部变量，不进参考文档的环境变量表，不冻结）。日常操作词之后的参数原样交给 subctl，由 subctl 校验与报错（如 `direct status -h` 显示 subctl 的帮助、`direct status --sni x` 由 subctl 报未知参数）。
- 废弃提示写 stderr，不改 stdout，不影响机器可读输出。直连与 subctl 用 `[!] … 已废弃（仍可用），改用：…`；链式沿用 `log_warn`（`chain/setup_chain.sh:306`），输出形如 `[chain][rehost-exit] WARN [deprecated] …`。
- 用户本机可能只有 macOS 自带的 bash 3.2（入口用 `shutil.which("bash")`）：`set -u` 下展开空数组 `"${a[@]}"` 报 unbound variable。新代码不展开可能为空的数组；必须展开时写 `${a[@]+"${a[@]}"}`（`direct/doctor.sh:289` 已有此写法）。废弃提示用字符串累积。
- 同机判据沿用 `rehost-exit` 的：新地址的 ed25519 主机指纹等于 state 里的 `EXIT_HOSTKEY_FINGERPRINT`。探测经中转、用当前出口机私钥、临时 ssh 配置（目标段 `StrictHostKeyChecking no`、`UserKnownHostsFile /dev/null`），在**同一条会话**里取全部数据：`ssh -vv -E <日志>` 记下这条会话协商到的主机指纹，远端命令一次输出主机公钥与 `curl -4 ipinfo.io/ip` 的结果。只有日志里的指纹等于 state 值时才采用这次的输出（指纹是公钥摘要，伪造不了）；公钥还要再用 `ssh-keygen -lf <文件> -E sha256` 复核摘要相同，才写进 `~/.ssh/known_hosts`。
- `rehost-exit` 只迁移 `EXIT_HOST` / `EXPECTED_EXIT_IPV4` 两个键（`load_state_for_rehost`，`chain/setup_chain.sh:6404-6435`），所以同机路径要求 SSH 端口不变：探测端口取 `--to-port`（给了时）否则当前 `EXIT_SSH_PORT`；判定为同一台、但给了 `--to-port` 且与 `EXIT_SSH_PORT` 不同时退出 2。
- 测试床：本机 Lima 2.2.1 三台 Ubuntu 22.04 arm64（中转 R、出口 E、直连 D），各有 vzNAT（192.168.64.x，本机可达）与 `user-v2`（192.168.104.x）两块网卡。vzNAT 下虚拟机彼此不通，链只能经 user-v2 走：中转用 vzNAT 地址部署；出口机先用 vzNAT 地址 init，部署前把配置里的 `EXIT_HOST` 改成 E 的 user-v2 地址并给它复制 known_hosts 的 ed25519 条目（此时还没有 state，用的是原有做法）。同机换 IP 用给 E 的 user-v2 网卡（eth0）加第二个静态地址（同网段、DHCP 地址池以外的静态地址）模拟，已实测中转可经新地址 SSH 到 E。局限：所有地址出网都是同一个家庭公网 IP，区分不出出口 IP 是否测对；测试期间不能重启虚拟机（Lima 重启会重新生成主机密钥）；本机到 104.x 走 TUN 且实际不通（TCP 被 TUN 接住、读不到 SSH 握手），所以 verify 的“非中转来源拒绝侧”检查会跳过，跨机迁移也没法在本测试床完整跑通（C1 只验到进入跨机路径）。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main a11e19f） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `direct/setup_direct.sh` `usage` | 72-121 | 修改 | 改为子命令形态；末尾列“已废弃写法（仍可用）” |
| `direct/setup_direct.sh` 主参数循环 | 133-158 | 修改 | 新增子命令分支（§5.1.1）；6 个动作参数分支追加废弃提示 |
| `direct/setup_direct.sh` 互斥检查与报错文字 | 161-174 | 修改 | 报错改用子命令名；检查前打印废弃提示 |
| `direct/setup_direct.sh` 用户可见提示 | 514、534、564、570、610、627、661、662、676、684、697、1031、1087、1121-1123、1130 | 修改 | 改成新写法（注释里的旧写法不改） |
| `direct/subctl` 参数解析之后 | 87 `--ttl` 校验之后、92 `resolve_target` 之前 | 新增 | 没有 `OWNEXIT_VIA_DIRECT=1` 时打印废弃提示 |
| `direct/subctl` `usage` 与提示 | 17-46、91、104、108、128、141 | 修改 | usage 顶部注明已废弃；提示改用新写法（141 在远端 status 脚本里） |
| `direct/doctor.sh` | 549、554、560、564 | 修改 | 建议命令改用 `ownexit direct log / migrate / status / sub stop` |
| `chain/setup_chain.sh` `load_state_for_rehost` | 6424 | 修改 | 报错文字去掉命令名（同机切换也会走到） |
| `chain/setup_chain.sh` `rehost_exit_chain` | 6613-6654 | 修改 | 拆成取锁 + `rehost_exit_body`（6624 报错文字去掉命令名） |
| `chain/setup_chain.sh` 新函数 | `rehost_exit_chain` 之后（6654 后） | 新增 | `migrate_same_host_port_check`、`migrate_probe_same_host`、`migrate_register_hostkey`、`migrate_rehost_same_host`（§5.1.3） |
| `chain/setup_chain.sh` `migrate_exit_chain` | 8440-8444 无迁移记录分支 | 修改 | 校验 `--to`，再按 §5.1.3 第 2 步分支 |
| `chain/setup_chain.sh` `migrate_prepare` | 7876-7878、7886-7889、7917 | 修改 | `--to` 两项校验移出（7876-7877）；删“--to 就是当前出口机”（7878）；两处报错改为指向重跑本命令 |
| `chain/setup_chain.sh` `exit_op_prepare` | 7416 | 修改 | 提示里 `rehost-exit` 改为 `migrate-exit` |
| `chain/setup_chain.sh` `main` 分派 | 9137-9139 `rehost-exit)` | 修改 | 先 `log_warn` 废弃提示 |
| `chain/setup_chain.sh` `usage` 与头注释 | 11-12、195、228-229、289 | 修改 | rehost-exit 标“已废弃”，示例改用 migrate-exit |
| `src/ownexit/cli.py` | 32 `_GROUPS`、`_TEXT` 的 subctl / connect 项、171 向导参数 | 修改 | 帮助去掉 connect、subctl；向导转 `direct up --host` |
| `scripts/check_interface.sh` | 头注释 9-11、第 3 项之后 | 新增 | 第 3b 项：direct 子命令（主参数循环分支词）对照 commands.md；头注释清单补一句 |
| `docs/reference/commands.md` | §ownexit direct、§ownexit subctl、§ownexit connect、§ownexit chain 子命令表与“其它命令输出” | 修改 | 新增 direct “### 子命令”表（首列只写裸词，`doc_table` 取到第一个反引号为止，`check_interface.sh:107`）；标注废弃项；`rehost=noop` 行的命令列补 migrate-exit；新增 `migrate=rehosted` 行 |
| `docs/reference/compatibility.md` | §3 之后、§6 检查清单 | 新增 / 修改 | “已废弃项”一节（旧写法、替代写法、最早移除版本 2.0）；§6 清单补“direct 子命令” |
| `docs/reference/files.md` | 提到 subctl 处 | 修改 | 改用新写法 |
| `README.md` / `README.zh-CN.md` / `direct/README.md` / `chain/README.md` / `docs/manual/direct.md` / `docs/manual/chain.md` / `CONTRIBUTING.md` / `SECURITY.md` | 旧写法出现处 | 修改 | 改用新写法；chain/README 与手册的“出口机换 IP”改为 migrate-exit 自动处理 |
| `CHANGELOG.md` / `src/ownexit/__init__.py` | | 修改 | 1.5.0（写明 migrate-exit 两种原退出 2 的情形现在成功） |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 直连子命令（`setup_direct.sh`）

主参数循环新增分支（插入位置：`direct/setup_direct.sh:155` `--allow-tun)` 之后）：

```text
up)                     记下“出现过 up”
rotate-keys)            ROTATE_KEYS=1
rotate-token)           ROTATE_TOKEN=1
migrate)                DO_MIGRATE=1
uninstall)              DO_UNINSTALL=1
add-device)             WANT_ADD_DEVICE=<下一个参数>（缺则 die_usage）
remove-device)          WANT_REMOVE_DEVICE=<下一个参数>
sub|status|log|qr|devices|login)   转给 subctl（见下）
```

- 多个动作子命令可同时给（如 `rotate-keys rotate-token`），互斥规则与旧参数完全相同；报错文字改为子命令名（如“migrate、uninstall、rotate-token 只能选一个”）。`up` 不能与动作子命令 / 动作参数同用（`die_usage "up 只用于部署，不能与 rotate-keys 等同用"`），可以与 `--host` / `--sni` 等部署参数同用。
- 旧的 6 个动作参数分支（`--migrate` `--uninstall` `--rotate-token` `--rotate-keys` `--add-device` `--remove-device`，含 `=` 形式）照常赋值，并把一行 `[!] <旧写法> 已废弃（仍可用），改用：ownexit direct <新写法>` 追加到字符串 `DEPRECATED_MSGS`；互斥检查之前 `[[ -z "${DEPRECATED_MSGS}" ]] || printf '%s' "${DEPRECATED_MSGS}" >&2`。
- 转给 subctl：遇到日常操作词时，若此前已出现 `up`、任何动作子命令 / 动作参数、或 `--sni` `--proxy-port` `--sub-ttl` `--allow-tun` → `die_usage "<词> 是日常操作，不能与部署 / 维护参数同用"`。否则组装 subctl 参数（数组至少含子命令，非空）：已出现的 `--host` / `--user`（含 `-u`）/ `--port`（含 `-P`）换成 subctl 的长参数，接子命令，再接其后剩余参数（剩余参数里的 `-u` / `-P` 同样换成长参数）：
  - `sub start …` → `start …`；`sub stop …` → `stop …`；`sub` 后缺词或不是 start / stop → `die_usage "sub 后面跟 start 或 stop"`（`direct sub -h` 也落到这里）。
  - `status` / `log [行数]` / `qr` / `devices` / `login` → 同名。
  - 然后 `OWNEXIT_VIA_DIRECT=1 exec bash "${SCRIPT_DIR}/subctl" "${SUBCTL_ARGS[@]}"`。退出码即 subctl 的退出码。
- 子命令分支用 `case` 的普通分支写在主参数循环里，`check_interface.sh` 的 `sub_words` 就能取到；主参数循环内不再嵌套以小写词为分支的 `case`（转发时的剩余参数处理用 `if` / `[[ ]]`）。
- `usage` 改成子命令形态（示例全部用新写法），末尾一段“已废弃写法（仍可用）”。

#### 5.1.2 subctl 与其它提示

- `direct/subctl` 解析完参数后（插入位置：`direct/subctl:87` 之后、`:92` `resolve_target` 之前）：`OWNEXIT_VIA_DIRECT` 不为 1 时 stderr 打印 `[!] ownexit subctl 已废弃（仍可用），改用：ownexit direct <对应写法>`（start → `sub start`，stop → `sub stop`，其余同名，默认 login → `login`）。`help` / `-h` 在解析循环里已退出，不打。
- subctl 的 `TARGET_NO_PROMPT_HINT`（91）与 104、108、128、141 的提示改为 `ownexit direct up --host <ip>` / `ownexit direct migrate` 等新写法。
- `doctor.sh` 四处建议命令、`setup_direct.sh` 的用户可见提示（§4 所列行）、`cli.py` 帮助与向导全部改用新写法。

#### 5.1.3 migrate-exit 自动处理同机换 IP（`chain/setup_chain.sh`）

1. **拆分 `rehost_exit_chain`**（6613-6654）：取锁与 `migrate_gate` 留在原函数；从“journal 不存在”检查（6624）到末尾移入新函数 `rehost_exit_body`（自带 `local rc`），逻辑不变。noop 时它打印 `rehost=noop …` 并返回 0，不打印“通过”日志（与现状相同）。6424、6624 报错文字与 6653 的“rehost-exit 通过”日志去掉命令名（改为“同机切换只迁移这两个键”“存在 incomplete transaction，拒绝同机切换”“同机切换通过”）。
2. **`migrate_exit_chain` 无迁移记录且 `MIGRATE_MODE=run`**（替换 8440-8444 中 `migrate_prepare` 的调用）：
   - 先做从 `migrate_prepare` 移出的两项校验：`is_ipv4 "${MIGRATE_TO}"`、`--to` 不是 `RELAY_HOST`，不通过 `die 2`（在任何 ssh 之前，避免未校验的值写进 ssh 配置）。
   - `probe_state_file`：
     - **rc=0、配置 `EXIT_HOST` 等于 `--to`**（已切换完成）：`migrate_same_host_port_check`；`rehost_exit_body`（输出 `rehost=noop`）；`return 0`。
     - **rc=0、`--to` 是别的地址**：`migrate_probe_same_host`。返回 0（同一台）→ `migrate_rehost_same_host`，`return 0`。返回 1（不同机器）或 2（连不上）→ 分别记 `[migrate] 新地址 <IP> 的主机指纹与当前出口机不同（换了机器），按跨机迁移处理` / `[migrate] 经中转连不上新地址 <IP>（取不到主机指纹），按跨机迁移处理`，照旧 `migrate_prepare`。
     - **rc=12、配置 `EXIT_HOST` 等于 `--to`**（上次同机切换在改写配置后中断，或用户按旧做法手改了配置）：`migrate_same_host_port_check`；`load_state_for_rehost`（核实只有两个键不同，并加载 state 的 `EXIT_HOSTKEY_FINGERPRINT` 等字段；其它键也变了则按它原有逻辑 `die 2`）；`known_hosts` 里没有 `--to` 的正确 ed25519 条目时 `migrate_probe_same_host`，必须返回 0（否则 `die 3 "新地址 <IP> 经中转连不上或不是同一台出口机，配置未回滚：改回 EXIT_HOST 或换对地址后重跑"`），再 `migrate_register_hostkey`；`rehost_exit_body`；打印 `migrate=rehosted …`；`return 0`。
     - **rc=12、`EXIT_HOST` 不等于 `--to`**，以及其它 rc：照旧 `migrate_prepare`（它报“配置与 state 不一致”或 state 校验失败）。
3. **`migrate_same_host_port_check`**：`MIGRATE_TO_PORT_GIVEN=1` 且 `MIGRATE_TO_PORT` ≠ `EXIT_SSH_PORT` → `die 2 "新地址 <IP> 是同一台出口机，SSH 端口要保持 <原端口>（同机切换只改地址）"`。
4. **`migrate_probe_same_host`**（新函数，不复用 `negotiated_hostkey_fingerprint`：后者要求命令成功，1790 行 rc≠0 即返回 1）：
   - 端口 = `--to-port`（给了时）否则 `EXIT_SSH_PORT`。先 `render_ssh_config`。
   - 临时文件（配置、`-E` 日志、输出）名带 `${LOCK_OPERATION_ID}`（同 1768 行写法），先确认不存在再建。写临时配置 `${OP_TMP}/ssh-probe-same-host.${LOCK_OPERATION_ID}.conf`（600）：**先**写 `Host chain-probe` 段（`HostName <--to>`、`User root`、`Port <端口>`、`IdentityFile ${EXIT_SSH_KEY}`、`ProxyJump chain-relay`、`StrictHostKeyChecking no`、`UserKnownHostsFile /dev/null`、`GlobalKnownHostsFile /dev/null`、`UpdateHostKeys no`），**再**接 `sed -n '/^Host chain-relay/,$p' "${SSH_CONFIG}"`（中转段与 `Host *` 加固段原样保留；ssh 配置先匹配者生效，所以目标段的宽松项不会被 `Host *` 覆盖，中转仍严格校验）。
   - 一次会话：`run_managed_external ssh ssh -vv -E <日志> -n -F <临时配置> chain-probe 'cat /etc/ssh/ssh_host_ed25519_key.pub; echo ---ownexit---; curl -4 -fsS -m 15 ipinfo.io/ip || true' > <输出>`，不看退出码。
   - 从日志按 1797-1801 同样的规则取 `Server host key: ssh-ed25519 SHA256:…`（恰好一行，去掉行尾 `\r`）；取不到返回 2；不等于 `EXIT_HOSTKEY_FINGERPRINT` 返回 1。
   - 相等时：分隔行之前的 `ssh-ed25519 <base64>` 写临时文件，`ssh-keygen -lf <文件> -E sha256` 的摘要必须相等，否则 `die 3`；保存到 `MIGRATE_PROBE_PUB`；分隔行之后的内容去空白存 `MIGRATE_PROBE_EXIT_IP`（可为空）；返回 0。临时文件用完删除。
   - 新地址不可达时约等 `ConnectTimeout 12` 加经中转转接的时间（十几到二十几秒）。
5. **`migrate_register_hostkey`**：条目名 = 端口 22 时 `<IP>`，否则 `[<IP>]:<端口>`。`ssh-keygen -F <条目> -f ~/.ssh/known_hosts` 的输出里**只看 `ssh-ed25519` 行**（其它类型忽略：OpenSSH 会顺手记 rsa / ecdsa，见 8940 注释），逐行把类型与密钥写临时文件算 `-E sha256` 摘要：有等于期望指纹的 → 不追加；有 ed25519 行但都不等 → `die 3 "known_hosts 里 <条目> 的 ed25519 主机密钥与该出口机不符，请人工核对"`；没有 ed25519 行 → 追加 `<条目> ssh-ed25519 <base64>`（写法同 `init_record_ed25519_hostkey` 8954-8966），记 `[migrate] 已登记 <条目> 的 ed25519 主机密钥`。不用 here-string（仓库惯例，8081）。
6. **`migrate_rehost_same_host`**（rc=0 同机路径）：
   - 记 `[migrate] 新地址 <IP> 与当前出口机是同一台（指纹 <指纹>），原地切换`；`migrate_same_host_port_check`。
   - `MIGRATE_PROBE_EXIT_IP` 不是 IPv4 → `die 3 "无法在出口机上取得新的公网 IPv4（需要 curl 能访问 ipinfo.io）"`；终端里 `[y/N]` 确认（同 7932-7935），不确认 `die 2`（配置与 known_hosts 未改动）。
   - `migrate_register_hostkey`。
   - 备份配置为 `${CONFIG_PATH}.bak.<时间戳>`（`noclobber`、600），`EXIT_HOST=` / `EXPECTED_EXIT_IPV4=` 两行各须恰好 1 行（否则 `die 2`），替换为新值，临时文件 + `mv -f` 原子替换（写法同 `migrate_rewrite_config` 7808-7843）；更新全局 `EXIT_HOST` / `EXPECTED_EXIT_IPV4`，重算 `CONFIG_SHA256="$(normalized_config | sha256_text)"`。记 `[migrate] same-host config rewritten backup=<路径>`。
   - `rehost_exit_body`；`printf 'migrate=rehosted chain=%s exit=%s:%s\n' "${CHAIN_ID}" "${EXIT_HOST}" "${EXIT_REALITY_PORT}"`（字面量写法，供 `check_interface.sh` 第 8 项提取）。
   - 失败边界：配置改写之前失败，配置与 state 都没改（known_hosts 可能已追加正确条目，无害）；改写之后失败（中转 / 出口机步骤或 verify），重跑 `migrate-exit --to <同一 IP>` 命中第 2 步 rc=12 分支续跑。
7. `migrate_prepare` 里 7886-7889 的旧出口机不可达报错改为：“经中转访问旧出口机失败，新地址 <IP> 也不是同一台出口机（或经中转连不上）。若新旧是同一台：确认中转能 SSH 到新地址后重跑本命令；若确实换了机器而旧机器登录不了：私钥只在旧机器上，只能 rollback + deploy”。7917 的同指纹报错改为“新出口机 <IP> 与当前出口机是同一台机器：重跑 migrate-exit --to <IP>（不带 --to-port 或保持原 SSH 端口）即可原地切换”。退出码不变。
8. `main` 的 `rehost-exit)` 分支先 `log_warn "[deprecated] rehost-exit 已废弃（仍可用）：改用 migrate-exit --to <新 IP>，同一台机器会自动识别，不必手改配置"`。`exit_op_prepare` 7416 的提示改为“换出口 IP 用 migrate-exit”。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit direct` 子命令 | 新增 `up` `rotate-keys` `rotate-token` `add-device` `remove-device` `migrate` `uninstall` `sub` `status` `log` `qr` `devices` `login` | 新增 |
| `ownexit direct` 参数 `--migrate` `--uninstall` `--rotate-token` `--rotate-keys` `--add-device` `--remove-device` | 废弃：照常可用，stderr 提示新写法 | 兼容；最早 2.0 移除 |
| `ownexit subctl` | 废弃：照常可用，stderr 提示新写法 | 兼容；最早 2.0 移除 |
| `ownexit chain rehost-exit` | 废弃：照常可用，stderr 提示改用 migrate-exit | 兼容；最早 2.0 移除 |
| `ownexit chain migrate-exit` | 新地址是同一台出口机时原地切换并输出 `migrate=rehosted chain=<链> exit=<新 IP>:<端口>`（原为退出 2）；已切换完成时输出 `rehost=noop chain=<链> next=run-verify`、退出 0（原 `--to` 等于当前出口机时退出 2） | 新增输出取值（compatibility.md §2 允许）；退出码 2 的含义不变，两种原失败情形改为成功属修正缺陷，CHANGELOG 写明 |
| `ownexit` 入口帮助 | 不再列出 `connect`、`subctl` | 帮助文字不冻结 |
| 环境变量 | `OWNEXIT_VIA_DIRECT`（内部，不冻结） | — |

**reference sibling 回补检查**：

- Q1 涉及 reference 章节：`commands.md` §ownexit direct（新增“### 子命令”表）、§ownexit subctl、§ownexit connect（注明不在入口帮助列出）、§ownexit chain 子命令表（rehost-exit 标废弃、migrate-exit 说明）与 §其它命令输出（`rehost=noop` 命令列、新增 `migrate=rehosted`）；`compatibility.md` 新增已废弃项一节、§6 清单；`files.md` 中 subctl 引用。
- Q2 源码暴露面完整性：`check_interface.sh` 第 1、2、3、6、8 项覆盖入口子命令、各参数、subctl / chain 子命令与 migrate= 输出；direct 子命令此前没有检查项，本方案新增第 3b 项。
- Q3 本方案是否回补：是，同步落地。
- Q4 placeholder：N/A。

## 6. 备选方案与决策

- 直接在 1.5.0 删除旧写法：违反 compatibility.md §3，用户选了只废弃。
- 日常操作在 `setup_direct.sh` 里重写而不转给 subctl：重复实现、两处维护，转发零行为差异。
- 同机判据改用“旧 IP 不可达就当同机”：不可靠（旧机器也可能只是宕机）；指纹判据已经由 `rehost-exit` 验证过。
- 同机路径先登记 known_hosts、再用严格配置分几次连接取公钥与出口 IP：多一次连接且要处理中间态；一次会话同时拿到指纹与输出更简单，可信度相同。
- 同机路径也走跨机迁移的迁移记录机制：跨机记录要求新机器配新密钥（要输密码）、搬配置、清理旧机器，同一台机器的情形全都不需要；`rehost_exit_body` 自身已可重跑收敛，续跑靠“配置已改、state 未改”加 known_hosts 补登记即可。

## 7. 影响分析

- `direct` 不带子命令的现有用法（`direct`、`direct --host …`、`--sni` / `--proxy-port` / `--sub-ttl` / `--allow-tun`）：主循环只新增分支，不改既有分支的赋值，行为不变。→ R1。
- 6 个动作参数：赋值不变，只多一行 stderr。解析 stdout 的调用方不受影响。→ R2。
- bash 3.2：新代码不展开空数组。→ D1 用 `/bin/bash` 跑。
- 互斥报错文字改名：报错文字不冻结；退出码仍为 2。→ D3。
- `subctl` 直接调用：行为不变，多一行 stderr；经 `direct` 转发时没有这一行。→ D4、D5。
- 转发路径：`exec` 替换进程，退出码、交互终端（login）直接属于 subctl。→ D4、D5。
- `check_interface.sh` 新增第 3b 项：要求 commands.md 的 direct 子命令表与主循环分支词一致；主循环里不能再出现别的小写词 `case` 分支。→ S1。
- `rehost_exit_chain` 拆分：只移动代码块，取锁、gate、输出不变；两处报错文字去掉命令名。→ C6、C6b。
- `migrate_exit_chain` 无记录分支：`--to` 校验前移（同样的检查与退出码）；rc=0 时多一次经中转的 ssh 探测（可达时约 1-2 秒，不可达时十几到二十几秒）；跨机路径在探测判为不同 / 连不上后照旧进入 `migrate_prepare`。→ C1、C9、C10。
- 同机路径写本机 `~/.ssh/known_hosts`（只追加 ed25519 条目）与链配置（先备份）。已有不符的 ed25519 条目时拒绝，不覆盖；只有 rsa / ecdsa 条目时照常追加。→ C2、C8、C11、C12。
- 原先 `migrate-exit --to <当前出口机>` 退出 2、同指纹退出 2 的两种情形现在会成功；CHANGELOG 写明。→ C5、C2。
- `doctor` 的建议命令文字变化：输出格式不冻结。→ D6。
- 入口帮助去掉 connect / subctl：`ownexit connect` / `ownexit subctl` 照常转发（COMMANDS 表不变）。→ T1、D5。

## 8. 回归测试

本机 Lima 三台（见 §3 测试床）：中转 R、出口 E、直连 D。直连用例在 D 上跑（vzNAT 地址），链式用例 R→E（E 用 user-v2 地址）。测完删除 Lima、测试密钥（含 C10 跨机路径为那个无人地址生成的 `~/.ssh/ownexit/id_ed25519_root_<地址>_22`）与 known_hosts 测试条目。下表 E2…E7 是给 E 的 user-v2 网卡加的第二地址（同网段、DHCP 地址池以外，加完先在 R 上确认 `nc -z <地址> 22`）。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| D1 | `/bin/bash direct/setup_direct.sh up --host D`；`direct up`（记住的目标）；`direct --host D` | 都部署 / 复用成功，退出 0，无废弃提示 |
| R1 | `direct --sni www.apple.com`、`direct --proxy-port <新端口>`、`direct --sub-ttl 5m`、`direct --allow-tun`（不带子命令） | 退出 0，效果与 1.4.0 相同，无废弃提示 |
| D2 | `direct rotate-token`、`direct rotate-keys`、`direct add-device phone`、`direct remove-device phone`、`direct rotate-keys rotate-token` | 退出 0，效果与旧参数相同（TOKEN / UUID 变化、设备订阅出现 / 删除），stderr 无废弃提示 |
| R2 | `direct --rotate-token`、`direct --add-device=pad`、`direct --remove-device pad` | 退出 0，stderr 各有一行“已废弃（仍可用），改用：ownexit direct …” |
| D3 | `direct migrate uninstall`、`direct add-device`（缺名）、`direct sub`、`direct sub foo`、`direct uninstall --sub-ttl 5m`、`direct --sni a.com status`、`direct rotate-keys status`、`direct up status`、`direct up rotate-keys` | 均退出 2；报错文字用子命令名 |
| D3b | `direct status --sni a.com` | 退出 2，报错来自 subctl（未知参数） |
| D4 | `direct sub start --ttl 2m`、`direct status`、`direct log 20`、`direct devices`、`direct qr`（有 qrencode）、`direct sub stop`、`direct --host D -P 22 status` | 退出 0，与对应 subctl 输出相同，stderr 无废弃提示；status 显示自动关闭剩余时间 |
| D5 | `ownexit subctl status`、`ownexit subctl stop`；`direct login < /dev/null` | subctl 两条退出 0 且 stderr 有废弃提示；login 退出 0 |
| D6 | 订阅服务开着时跑 `doctor`；`direct --help`、`subctl --help` | doctor 建议命令为新写法；direct 帮助为子命令形态，subctl 帮助注明已废弃 |
| D7 | `direct uninstall` | 卸载成功，计时器与服务清零 |
| C1 | 链 R→E 部署后，`migrate-exit --to <D 的 user-v2 地址>`（终端外运行，设 `OWNEXIT_SSH_PASSWORD`） | 日志为“主机指纹与当前出口机不同（换了机器），按跨机迁移处理”，进入跨机路径；测试床里本机到 user-v2 地址不通，在给新机器配免密处退出 3，配置、state 未改、没有迁移记录（跨机迁移本身的流程本版未改，1.1.0 已实测） |
| C2 | E 加 E2（旧地址仍在），`migrate-exit --to E2` | `migrate=rehosted chain=… exit=E2:…`，退出 0；配置备份存在、EXIT_HOST=E2；known_hosts 有 E2 的 ed25519 条目；`status` healthy、`verify` 通过 |
| C3 | E 加 E3、删掉 E2（旧地址不可达），`migrate-exit --to E3` | 同 C2 判据 |
| C4 | E 加 E4；手改配置 EXIT_HOST=E4（不补 known_hosts），`migrate-exit --to E4` | rc=12 续跑分支：`migrate=rehosted`，known_hosts 补了 E4 |
| C5 | 再跑一次 `migrate-exit --to E4` | 输出 `rehost=noop`，退出 0 |
| C6 | E 加 E5，按旧做法改配置 + 补 known_hosts，`rehost-exit` | 成功；stderr 有 `[deprecated] rehost-exit 已废弃` |
| C6b | 再跑一次 `rehost-exit` | 输出 `rehost=noop`，没有“rehost-exit 通过”日志 |
| C7 | E 的 sshd 增加监听 2222，E 加 E6，`migrate-exit --to E6 --to-port 2222` | 退出 2，提示端口要保持原值；配置与 state 未改 |
| C8 | known_hosts 预先写一条与 E 不符的 E7 ed25519 条目，`migrate-exit --to E7` | 退出 3，known_hosts 与配置都未改 |
| C9 | `migrate-exit --to <中转 IP>`、`migrate-exit --to abc` | 退出 2，没有发起 ssh 探测 |
| C10 | `migrate-exit --to <user-v2 网段内无人使用的地址>` | 日志为“经中转连不上新地址”，进入跨机路径后在配免密处退出 3；配置、state、known_hosts 都未改 |
| C11 | known_hosts 已有 E8 的 rsa 条目（无 ed25519），`migrate-exit --to E8` | 成功（`migrate=rehosted`），追加了 E8 的 ed25519 条目 |
| C12 | 先给 E 加 E9，并在 known_hosts 预写正确的 E9 ed25519 条目，再 `migrate-exit --to E9` | 成功，E9 的 ed25519 条目只有一行（未重复追加） |
| C13 | 在伪终端里 `migrate-exit --to E10`，确认出口 IP 时回答 n | 退出 2，配置未改 |
| C14 | 手改配置 EXIT_HOST=E11 且同时改了 `REALITY_SERVER_NAME`，`migrate-exit --to E11` | 退出 2（只允许两个键不同） |
| T1 | `ownexit --help`；向导选 1（`OWNEXIT_TEST_WIZARD_PRINT=1`） | 帮助不列 connect / subctl；向导参数为 `direct up --host …` |
| S1 | `bash -n`、`/bin/bash -n`、`shellcheck -S warning`、`check_interface.sh`（含新第 3b 项）、`check_public.sh`、CI | 通过 |

## 9. 日志 / 观测点

- 直连 / subctl 废弃提示：stderr `[!] <旧写法> 已废弃（仍可用），改用：ownexit direct <新写法>`。
- rehost-exit：`[chain][rehost-exit] WARN [deprecated] rehost-exit 已废弃（仍可用）…`。
- migrate-exit 同机路径：`[migrate] 新地址 <IP> 与当前出口机是同一台（指纹 …），原地切换`、`[migrate] 已登记 <条目> 的 ed25519 主机密钥`、`[migrate] same-host config rewritten backup=<路径>`、原 `[rehost] start …` 日志、stdout `migrate=rehosted …`。
- 跨机回退：`[migrate] 新地址 <IP> 的主机指纹与当前出口机不同（换了机器），按跨机迁移处理` 或 `[migrate] 经中转连不上新地址 <IP>（取不到主机指纹），按跨机迁移处理`。
