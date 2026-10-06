# v1.1.0：链式出口机跨机迁移（`migrate-exit`）

> **2026-10-06 注记**：已落地于 v1.1.0（`chain/setup_chain.sh` 的“出口机跨机迁移：migrate-exit”一节，`migrate_exit_chain` 为入口）。§8 在本机 Lima 三台 Ubuntu 22.04 arm64 虚拟机上实测：R1、M1–M13 通过（M1 另手工补测非中转来源拒绝侧与额外设备经中转出网）。与原期望的差异：迁移中途 `list-devices` 不被迁移闸门拦，但因配置与 state 不一致按其既有检查退出 2；M9 的“同机另一个 IP”在测试床上无法构造（中转只能到达另外两台虚拟机的内网地址），未实测，由准备阶段的主机指纹比对保证。

## 1. 背景

- 链式出口机换一台新机器，目前只能 rollback 旧链再 deploy 新链：中转端口、部署 ID、UUID、Reality 密钥全部重来，所有客户端（含 v0.7.0 的额外设备）都要重新导入。
- `rehost-exit`（`chain/setup_chain.sh:6265` 起）只处理“同一台机器换 IP”：要求主机指纹不变，不搬运配置。
- 客户端连的是中转机（`client/node.txt` 只依赖 RELAY_HOST / RELAY_PORT / UUID / 公钥 / short id / SNI，`:7164-7168`），只要新出口机沿用原配置，中转把转发目标切过去，客户端完全不用动。
- 用户 2026-10-06 选择：做跨机迁移；沿用原凭据（私钥从旧出口机经本机内存直接传到新出口机，不落本机磁盘）；迁移成功后自动清理旧出口机上本链的服务和文件。

## 2. 目标 / 非目标

目标：

1. 新增 `setup_chain.sh --id <链> migrate-exit --to <新出口机 IPv4> [--to-port <SSH 端口>]`：把出口机迁到另一台机器，UUID、Reality 密钥、short id、全部设备、中转地址与端口不变，客户端不重新导入。
2. 中途任何一步中断，重跑同一条命令都能收敛；迁移进行中 `status` 给出专门提示，其它修改类命令拒绝执行。
3. 迁移成功后自动清理旧出口机上本链的服务、配置（含私钥）、单元与白名单；旧机器暂时登录不了时保留待清理记录，重跑补做；旧机器永久失联时提供受支持的放弃出口。
4. 中转切换之前失败时提供 `--abort`：恢复原配置、清掉新机器上的半成品，链回到迁移前。

非目标：

- 旧出口机已经登录不了时的迁移（私钥只在旧机器上）：仍用 rollback + deploy，或迁移后 rotate-keys（文档写明）。
- 换中转机、迁移时改 SNI / EXIT_SOURCE_FILTER / 中转参数、直连部署的跨机迁移。
- 自动更新多链聚合：多链聚合要求各链 EXPECTED_EXIT_IPV4 相同（`chain/multi_chain_client.sh:494-496`）；共用一台出口机的多条链要逐条迁移，全部迁完后重新 `multi render`（文档写明）。

## 3. 假设与约束

- 旧出口机在“搬运配置”之前必须能经中转登录；其后旧机器失联只影响清理。
- 新出口机与中转同为 amd64 或 arm64；新出口机上不能已有本链（同一 CHAIN_ID）的文件或单元，可以有其它链共享的 `/opt/ownexit-chain/bin/` 二进制（`check_remote_shared_binary_or_absent exit` 核对）。
- 新出口机配免密与登记主机指纹沿用 `init_setup_host`（`:7636`）与 `init_record_ed25519_hostkey`（`:7664`）；非终端时需要 `OWNEXIT_SSH_PASSWORD`。迁移场景下的报错文字由本命令自己给出（不复用“重跑 init”的提示）。
- 出口 Reality 端口：沿用 state 的 `EXIT_REALITY_PORT`；新出口机上被占用时另选（`choose_remote_port exit` 的做法）。发布之前若记录的端口又被占用，允许重新选。
- 私钥传输：旧出口机侧 `sha256sum` 核对哈希后输出 base64 单行；本机只在 bash 变量中持有 base64 字符串；写入新出口机用 `ssh … 'base64 -d > <暂存路径>' < <(printf '%s\n' "$b64")`（进程替换是管道，不落临时文件），新出口机侧再核哈希。该调用不开启只读 SSH 重试（migrate-exit 不在只读名单内，stdin 不会被缓存到 OP_TMP）。私钥不出现在命令行参数与日志中。SECURITY.md 补一条例外说明。
- 本命令不走事务（同 rehost-exit / rotate-keys）。只复用不写 journal 的部件：各 `write_*_script`、`create_remote_stage`、`install_remote_binary`、`cleanup_remote_stage`、`smoke_from_relay`、`choose_remote_port`、`probe_mac_reality_rejection`、`probe_exit_tls`、`probe_exit_exit`、`remote_platform_preflight`、`check_remote_shared_binary_or_absent`、`write_rehost_remote_script`、`write_remove_chain_script`、`write_verify_removed_role_script`；不调用 `init_deploy_transaction_fields` / `prepare_exit_exit` / `install_exit_exit` / `activate_exit_exit`（它们会写 `transaction.env`，`:3211`、`:3613`、`:3663`、`:3667`、`:3680`）。
- 与 deploy 一样取全局锁（`acquire_global_lock`，因为要往新机器装共享二进制）与链锁。准备阶段配免密时可能停在输入密码处，期间其它链的 deploy 会等待全局锁（手册写明）。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main b6ae13d） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `chain/setup_chain.sh` `parse_args` | 552-608 | 修改 | 新子命令 `migrate-exit`；以 case 分支解析 `--to`、`--to-port`、`--abort`、`--abandon-cleanup` |
| `chain/setup_chain.sh` `main` 分派 | 7774 起 | 新增 | `migrate-exit) migrate_exit_chain ;;` |
| `chain/setup_chain.sh` `usage` | 155 起 | 修改 | 新子命令说明 |
| `chain/setup_chain.sh` `write_prepare_exit_script` | 3463-3580 | 修改 | 新增末位参数 `reuse`：为 `reuse` 且 stage 里已有 `<id>.exit.json` 时跳过生成密钥，只渲染 owner 与 unit 并输出三个哈希；deploy 调用处传 `-`，行为不变 |
| `chain/setup_chain.sh` 新函数组 `migrate_exit_*` | `status_chain`（7363）之前 | 新增 | §5.1 |
| `chain/setup_chain.sh` 迁移闸门 | `exit_op_prepare` `:7256` 取锁后（list-devices 跳过）、`rehost_exit_chain` `:6475`、`rebaseline_chain` `:6695`、`rollback_chain` `:5502`、`deploy_chain` `:4813` 取锁后 | 修改 | 迁移记录存在时拒绝并提示重跑 migrate-exit（rollback 退出 6、deploy 退出 4、其余退出 5，§5.1.5） |
| `chain/setup_chain.sh` `status_chain` | 7363 开头 | 修改 | 迁移记录存在时先输出 `status=drifted reason=exit-migration-pending next=rerun-interrupted-command`（§5.1.5） |
| `chain/setup_chain.sh` `local_deployment_residue_absent` | 4276 起 | 修改 | 候选加迁移记录的临时文件 `.migrate-exit.env.*.tmp` |
| `scripts/check_interface.sh` | 187 | 修改 | 其它命令输出行的提取正则加 `migrate` |
| `docs/reference/commands.md` | `## ownexit chain` | 修改 | 参数加 `--to` `--to-port` `--abort` `--abandon-cleanup`；子命令加 `migrate-exit`；status 取值加 `reason=exit-migration-pending`；`next=rerun-interrupted-command` 的含义补 migrate-exit；其它命令输出加 `migrate=done` 与 `migrate=aborted` |
| `docs/reference/files.md` | 链式（本机） | 修改 | 新增 `migrate-exit.env`；内部文件清单加它的临时文件 |
| `docs/reference/compatibility.md` | §1、§5、§6 | 修改 | 输出行清单加 `migrate=`；“升级前先收敛”加迁移记录 |
| `chain/README.md` / `docs/manual/chain.md` | “出口机换 IP”一节之后 / §7 之后 | 新增 | “出口机换一台机器”一节（含多链聚合与 provider 安全组提示） |
| `SECURITY.md` | 私钥说明 | 修改 | 迁移例外 |
| `CHANGELOG.md` / `src/ownexit/__init__.py` | | 修改 | 1.1.0 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 出口机上下文切换

新 helper `migrate_use_exit <old|new>`（直接在当前 shell 执行，不放进子 shell）：按内存中的 `OLD_*` / `NEW_*` 变量（准备阶段由 state 与 `--to` 探测结果赋值；重跑时由迁移记录还原）把 `EXIT_HOST`、`EXIT_SSH_PORT`、`EXIT_SSH_KEY`、`EXIT_HOSTKEY_FINGERPRINT`、`EXIT_REALITY_PORT`、`EXIT_OWNER_SHA256`、`EXIT_EXIT_SHA256`、`EXIT_SERVICE_SHA256`、`EXIT_ENABLE_LINK_TARGET` 设为旧或新出口机的值，然后调用 `render_ssh_config`。之后 `ssh_exit` / `ssh_exit_stdin` 就指向对应机器（都经中转机转接）。render_ssh_config 只写 OP_TMP 下的配置，active-child 登记的配置路径不变（`:1093`）；known_hosts 查找键与 `init_record_ed25519_hostkey` 写入的一致（`:7673`）。每次切换都写 `log_info "[migrate] exit context=<old|new>"`。

#### 5.1.2 迁移记录 `${CHAIN_STATE_DIR}/migrate-exit.env`

600，原子写入（同目录 `.migrate-exit.env.<操作ID>.tmp` + mv），每推进一步就更新：

| 键 | 含义 |
| ---- | ---- |
| `SCHEMA_VERSION` | 1 |
| `CHAIN_ID` | 本链名，读取时必须等于当前链 |
| `MIGRATE_ID` | 第一次运行生成的 128 位随机十六进制，作为暂存目录与 owner 临时文件的固定后缀 |
| `PHASE` | `recorded` → `config-rewritten` → `relay-switched` → `committed`（见 §5.1.4） |
| `OLD_EXIT_HOST` `OLD_EXIT_SSH_PORT` `OLD_EXIT_SSH_KEY` `OLD_EXIT_SSH_KEY_FINGERPRINT` `OLD_EXPECTED_EXIT_IPV4` `OLD_EXIT_HOSTKEY_FINGERPRINT` `OLD_EXIT_REALITY_PORT` `OLD_EXIT_OWNER_SHA256` `OLD_EXIT_EXIT_SHA256` `OLD_EXIT_SERVICE_SHA256` `OLD_EXIT_ENABLE_LINK_TARGET` `OLD_CONFIG_SHA256` | 旧出口机参数（来自 state 与改写前的配置） |
| `NEW_EXIT_HOST` `NEW_EXIT_SSH_PORT` `NEW_EXIT_SSH_KEY` `NEW_EXPECTED_EXIT_IPV4` `NEW_EXIT_HOSTKEY_FINGERPRINT` `NEW_EXIT_SSH_KEY_FINGERPRINT` `NEW_CONFIG_SHA256` | 新出口机参数与改写后的配置摘要 |
| `CONFIG_BACKUP` | 改写前的配置备份路径 |
| `NEW_EXIT_REALITY_PORT` | 选定的新端口 |
| `BINARY_STAGE_PATH` `BINARY_STAGE_OWNER_SHA256` `BINARY_STAGE_OWNER_TEMP_PATH` | 二进制暂存目录、stage-owner 哈希与 owner 临时文件前缀（创建前写入） |
| `CONFIG_STAGE_PATH` `CONFIG_STAGE_OWNER_SHA256` `CONFIG_STAGE_OWNER_TEMP_PATH` | 配置暂存目录、stage-owner 哈希与 owner 临时文件前缀（创建前写入） |
| `OLD_RELAY_TARGET` `NEW_RELAY_TARGET` | 中转 ExecStart 的旧 / 新目标（`<IP>:<端口>`，端口选定后写入） |
| `NEW_EXIT_EXIT_SHA256` `NEW_EXIT_OWNER_SHA256` `NEW_EXIT_SERVICE_SHA256` | 暂存完成后写入；发布与重跑按它们判定 |

暂存目录名用记录里的固定后缀（第一次运行的操作 ID），stage-owner 用 `render_owner_file` 渲染后立即把哈希写进记录，再 `create_remote_stage`。重跑时：暂存目录存在才用记录的路径与哈希调用 `cleanup_remote_stage`（目录不存在时它会退出 71）；owner 临时文件（`<前缀>.part` / `.ready`）按 deploy 恢复时 `safe_small_owner_temp`（`:5558`）的做法核对 CHAIN_ID 后删除；然后按需重建。暂存里只放 cleanup 白名单内的文件：stage-owner、`<id>.exit.json`、`<id>.owner.env`、unit。

#### 5.1.3 流程

```text
migrate-exit --to <新 IP> [--to-port N]
准备（没有迁移记录）：
  全局锁 + 链锁 → 依赖 → 拒绝未完成事务 / 未部署 → probe_state_file 必须 0
  → 旧链健康核验（旧上下文，顺序同 rollback 前置 `:5528-5534`）：render_ssh_config → probe_loaded_binding →
    remote_platform_preflight（同时给 SOCKET_PROXYD_PATH 赋值）→ ensure_local_assets_match_state → probe_remote_resources no；
    返回 33（出口机有未完成的凭据 / 设备操作）或其它非 0 都拒绝（退出 5，提示先 verify / 收敛）
  → 校验 --to：IPv4，不等于 RELAY_HOST、不等于当前 EXIT_HOST
  → init_setup_host 出口机 <新 IP> <端口>（配免密）→ 登记新机器 ed25519 主机指纹
  → 切到新上下文，经中转用 negotiated_hostkey_fingerprint chain-exit 取新机器指纹（同时验证中转到新机器可达）；
    等于旧指纹 → 是同一台机器，退出 2 并提示用 rehost-exit
  → 新机器上 remote_platform_preflight（架构与中转一致等）、check_remote_shared_binary_or_absent exit、
    本链路径与单元碰撞检查（/etc/ownexit-chain/<id>.*、ownexit-chain-exit-<id>.service）
  → 新机器上 curl -4 ipinfo.io/ip 取公网 IPv4（终端下要求确认）
  → 写迁移记录（PHASE=recorded）
  → 备份配置并改写 EXIT_HOST / EXIT_SSH_PORT / EXIT_SSH_KEY / EXPECTED_EXIT_IPV4 四行（同 rebaseline 改写配置的做法），
    PHASE=config-rewritten
执行（推导阶段为“执行中”，见 §5.1.4）：
  以记录的旧值重算配置摘要，probe_state_file 必须 0（其余键必须与 state 一致）
  → 中转绑定核验（中转主机指纹、密钥指纹）；新上下文主机指纹等于记录值
  → 新上下文 remote_platform_preflight（执行、清理、`--abort` 的每个进程开头都要做：EXIT_NFT_PATH、SOCKET_PROXYD_PATH 只由它赋值，
    `:2054`、`:2063`；`--abort` 删新机文件、清理阶段核新链之前都依赖它）
  → 清理记录里的旧暂存（如有）→ 新机器装固定二进制（install_remote_binary + cleanup_remote_stage）
  → 选端口（记录里有且未发布就再确认一次空闲）→ 写入记录
  → 已发布判定（§5.1.4 表）；未发布时：
      旧上下文：旧出口机 sha256sum exit.json 必须等于 OLD_EXIT_EXIT_SHA256，输出 base64
      新上下文：建配置暂存（stage-owner 哈希先入记录）→ 经 ssh_exit_stdin 执行 `umask 077; base64 -d > <暂存>/<id>.exit.json;
      chown root:root …; chmod 600 …`（stdin 为 `< <(printf '%s\n' "$b64")`；旧出口机侧用 `base64 -w0`）→ 新机器核哈希 → 端口变化时用
      apply_break_port 同款的精确匹配把 "listen_port": <旧端口>, 一行换成新端口（必须恰好 1 行）
      → write_prepare_exit_script … reuse：渲染 owner（新主机指纹、新配置摘要、原部署 ID）与 unit
        （managed 时 nft 白名单放行 detect_relay_source_ip 得到的中转出站源地址）→ 三个哈希写入记录
  → 发布（§5.1.4 表的“部分发布”规则；启用链接由 promote 用相对目标创建）→ 只做 daemon-reload 与 start（同 activate_exit_exit
    `:3671-3678`，不调用 systemctl enable），核验 active / enabled / 端口由固定二进制监听
  → 清理配置暂存
  → 切换前探针（失败则停下，提示 --abort 或修好后重跑）：probe_exit_tls、probe_exit_exit（出口 IP 等于新的 EXPECTED_EXIT_IPV4）、
    smoke_from_relay 新 IP 新端口、probe_mac_reality_rejection（非中转来源被拒）
  → 中转切换：write_rehost_remote_script（role=relay：owner 的 CONFIG_SHA256 旧→新；relay service ExecStart 目标
    OLD_RELAY_TARGET → NEW_RELAY_TARGET，运行中的 relay 若仍指向旧目标就重启）；它输出中转 owner 与 service 的当前哈希
    → PHASE=relay-switched
  → 提交前核验（推导阶段为“已切中转、未提交”时重跑也走这里）：再次执行 write_rehost_remote_script role=relay（已迁移形态按
    already 放行，同时核对漂移并取得当前哈希）→ 把输出的哈希赋给全局 RELAY_OWNER_SHA256 / RELAY_SERVICE_SHA256（同 rehost_relay
    `:6447-6448`；不赋值则按 state 旧哈希核验必然失败）→ 新上下文 probe_remote_resources yes → smoke_from_relay 127.0.0.1 RELAY_PORT
  → 提交 state（§5.1.6），PHASE=committed
清理（推导阶段为“待清理”）：
  先在新上下文 probe_remote_resources yes 通过（新链健康才拆旧机）
  → 切到旧上下文 → write_remove_chain_script 的 stop 与 remove（哈希用记录的旧值）→ verify_removed_chain_role
  → 兜底删除旧出口机上本链的 rotate 辅助文件（/etc/ownexit-chain/<id>.rotate.*）与本链暂存（另写远端脚本：只删 stage-owner
    中 CHAIN_ID 等于本链的 /etc/ownexit-chain/.stage-* 与 /opt/ownexit-chain/.stage-*；准备阶段已拒绝返回 33 的情况，这一步只是兜底）
  → 成功：删除迁移记录；SSH 不可达（255）：WARN 并保留记录；哈希不符等漂移：die 1（不静默跳过）
  → 切回新上下文
最后：ensure_local_assets_match_state → full_verify
  → 输出 migrate=done chain=<链> exit=<新 IP>:<端口> old_exit_cleanup=<done|pending>
```

`migrate-exit --abort`：先用中转现场检查（§5.1.4）确认中转为“未切换”（owner 与 service 都等于 state 值）、state 未提交，否则（含“部分切换”）拒绝（退出 2，中转已切换，只能继续完成）。允许时：清理记录里的暂存与 owner 临时文件；新上下文下用 write_remove_chain_script（stop 与 remove，哈希、端口、启用链接用记录的 NEW_* 值；部分发布时缺失的文件自动跳过，stop 的 ExecStopPost 删除 nft 表）与 verify_removed_chain_role 拆掉新机器上已发布的本链文件；配置已改写时恢复 `CONFIG_BACKUP`（PHASE=recorded 时配置未改、没有备份，跳过）；删除迁移记录；输出 `migrate=aborted chain=<链>`。

`migrate-exit --abandon-cleanup`（只在 PHASE=committed 时允许）：WARN “旧出口机上本链的配置（含私钥）未删除，请自行处理或销毁该机器”，删除迁移记录。

重跑时 `--to` / `--to-port` 必须与记录一致，不一致退出 2；`--abort` / `--abandon-cleanup` 不需要 `--to`。

#### 5.1.4 判定表

`PHASE` 只作为下限参考；实际阶段由现场推导，以覆盖“动作已完成、PHASE 还没写”的崩溃组合：

- 配置：四个出口键等于记录的 NEW_* → “新”；等于 OLD_* → “旧”；都不是 → “其它”。
- state：以当前配置 probe_state_file 返回 0 → “绑定当前配置”；配置为“新”时以 OLD 值重算摘要后返回 0 → “绑定旧配置”。
- 中转现场（只读远端检查，复用 rehost 脚本的 count / replace 逻辑但不写文件，owner 与 service 都核；rehost 脚本先改 owner 再改 service，`:6370-6375`）：owner 与 service 哈希都等于 state 的 RELAY_OWNER_SHA256 / RELAY_SERVICE_SHA256 → “未切换”；owner 的 CONFIG_SHA256 已是新摘要、service 仍等于 state 值 → “部分切换”；owner 与 service 都按 新→旧 反向替换后等于 state 值 → “已切换”；其余 → “漂移”。记录里还没有 NEW_RELAY_TARGET 时视为“未切换”。

| 迁移记录 | 配置 | state | 中转 | 推导阶段 | 动作 |
| ---- | ---- | ---- | ---- | ---- | ---- |
| 无 | — | 绑定当前配置 | — | 未开始 | 准备 |
| 有 | 旧 | 绑定当前配置 | 未切换 | 已记录、未改配置 | 改写配置后执行 |
| 有 | 新 | 绑定旧配置 | 未切换 | 执行中 | 执行 |
| 有 | 新 | 绑定旧配置 | 部分切换 | 中转切换中断 | 执行（重跑中转切换，owner 按 already 放行）；`--abort` 拒绝 |
| 有 | 新 | 绑定旧配置 | 已切换 | 已切中转、未提交 | 提交前核验 → 提交 |
| 有 | 新 | 绑定当前配置 | — | 待清理 | 清理 |
| 有 | 新 | 绑定旧配置 | 漂移 | 中转被外部改动 | 退出 1，不动 |
| 有 | 新 | 既不绑定当前也不绑定旧配置 | — | state 与记录对不上 | 退出 2，提示人工核对 |
| 有 | 其它 | — | — | 现场与记录对不上 | 退出 2，提示人工核对配置与 `CONFIG_BACKUP` |
| 有 | — | 没有 state | — | 记录无主 | 退出 5，提示人工确认后删除记录（不会自动处理） |

已发布判定（新上下文）：

| 新机器上的本链文件 | 判定 | 动作 |
| ---- | ---- | ---- |
| 全部不存在 | 未发布 | 走暂存与发布 |
| 存在的每个文件哈希都等于记录值（owner / exit.json / unit / 启用链接） | 部分或全部已发布 | 只补缺失的（从暂存补 link）。暂存只在发布与启动全部完成后才清理，所以“部分发布且暂存已不在”只可能是外部改动：退出 1，提示 `--abort` 后重新迁移 |
| 任一存在的文件哈希不等于记录值，或记录里还没有哈希 | 外部改动 | 退出 1，不覆盖 |

#### 5.1.5 闸门与 status

- 迁移记录存在时，`deploy`、`rollback`、`rehost-exit`、`rebaseline`、`rotate-keys`、`add-device`、`remove-device` 在取锁后立即拒绝：“链 <id> 正在迁移出口机，先重跑 migrate-exit（或 --abort / --abandon-cleanup）”。落点：`exit_op_prepare` 取锁后、state 核对之前（`:7256` 起；迁移中配置与 state 必然不一致，放在核对之后会先报退出 2 而看不到迁移提示），`COMMAND=list-devices` 时跳过（只读）；`rehost_exit_chain`（`:6475`）、`rebaseline_chain`（`:6695`）取锁后；`rollback_chain`（`:5502`）与 `deploy_chain`（`:4813`）取锁后、journal 恢复之前。退出码：rollback 用 6，deploy 用 4（锁之后的失败），其余用 5；commands.md 退出码表同步注明。`verify`、只读命令与 `conns` / `kick` / `ban` / `unban` / `banlist`（只动中转）不拦。
- `status_chain` 开头：迁移记录存在时输出 `status=drifted reason=exit-migration-pending next=rerun-interrupted-command`，退出 5（不论 PHASE）。

#### 5.1.6 state 提交字段

提交前在最后一次 `probe_state_file` 之后重新赋值（probe 会从旧 state 回填出口字段，`:2881-2900`）：

| 变化 | 字段 |
| ---- | ---- |
| 取新值 | `CONFIG_SHA256` `EXIT_HOST` `EXIT_SSH_PORT` `EXIT_SSH_KEY_PATH` `EXIT_SSH_KEY_FINGERPRINT` `EXIT_HOSTKEY_FINGERPRINT` `EXPECTED_EXIT_IPV4` `EXIT_REALITY_PORT` `EXIT_OWNER_SHA256` `EXIT_EXIT_SHA256` `EXIT_SERVICE_SHA256` `RELAY_OWNER_SHA256` `RELAY_SERVICE_SHA256` |
| 不变 | 其余全部字段（含 `DEPLOYMENT_ID` `CREATED_AT` `RELAY_PORT` `RELAY_SOCKET_SHA256` 两个 `*_ENABLE_LINK_*`、基线、凭据、`NODE_SHA256`、资产哈希） |

旧 state 归档到 `audit/migrated.<部署ID>.<操作ID>/state.env`。`EXIT_ENABLE_LINK_TARGET` 与 `EXIT_ENABLE_LINK_SHA256` 由 CHAIN_ID 决定，迁移前后相同。

#### 5.1.7 测试钩子

`OWNEXIT_TEST_MIGRATE_STOP_AFTER=record|config|binary|stage|publish|probes|relay|state` 在对应步骤后（含写 PHASE）退出 99；`relay-nophase` / `state-nophase` 在中转切换 / state 提交完成后、写 PHASE 之前退出 99（构造“动作已完成、PHASE 未写”）；`OWNEXIT_TEST_MIGRATE_STOP_AFTER=link1` 在发布的第一个 link 之后退出（构造部分发布）；`OWNEXIT_TEST_MIGRATE_SKIP_CLEANUP=1` 跳过清理（保留记录）。正常使用不要设置。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit chain` | 新增子命令 `migrate-exit` 与参数 `--to`、`--to-port`、`--abort`、`--abandon-cleanup` | 1.x 兼容新增 |
| 链式 status | 新增 `reason=exit-migration-pending` | 兼容新增 |
| 其它命令 | 迁移记录存在时修改类命令拒绝（rollback 退出 6、deploy 退出 4、其余退出 5；新增拒绝条件，只在使用新功能后出现） | 兼容 |
| 输出 | 新增 `migrate=done chain= exit= old_exit_cleanup=`、`migrate=aborted chain=` | 兼容新增 |
| 本机文件 | 新增 `chains/<id>/migrate-exit.env`（只在迁移中途存在） | 兼容新增 |
| 链配置 | 迁移时改写四个出口键，改写前备份 `<id>.env.bak.<时间>` | 键集合不变 |
| state.env | 字段集合不变，出口相关字段取新值 | 不变 |

**reference sibling 回补检查**（按 §"方案文档章节内容质量要求" §5）：
- Q1 涉及 reference 章节：`docs/reference/commands.md` §`ownexit chain`（参数、子命令、status 取值、其它命令输出、next 含义）；`docs/reference/files.md` §链式（本机）；`docs/reference/compatibility.md` §1、§5、§6。
- Q2 源码暴露面完整性：`scripts/check_interface.sh` 守护参数、子命令、status 取值、其它命令输出行（提取正则同步加 `migrate`）。
- Q3 本方案是否回补：是，新增暴露面与文档同步落地（§4 表）。
- Q4 placeholder 落地：N/A（已回补）。

## 6. 备选方案与决策

- 新出口机生成新凭据：所有设备要重新导入；用户选择沿用原凭据。
- 迁移走 deploy 的事务日志：要扩展 journal 键与恢复分派，改动 deploy / rollback 核心路径；否决，采用“可重入 + 最后提交”，中间状态放在迁移记录里。
- 私钥经本机临时文件中转，或用 here-string 写入：会落盘（bash 3.2 的 here-string 是临时文件）；否决，base64 + 进程替换管道。

## 7. 影响分析

- `write_prepare_exit_script` 新增末位参数：deploy 调用处传 `-`，生成密钥路径不变（§8 R1）。
- 七个修改类命令入口多一个闸门：迁移记录不存在时行为不变（§8 R2 用既有 rotate-keys / rollback 回归）。
- `status_chain` 开头多一个判断：记录不存在时输出不变。
- `local_deployment_residue_absent` 多一个候选模式：正常情况下不存在。
- 中转：迁移中 relay service 重启一次（在途连接断开，客户端自动重连）；socket、端口、黑名单、基线不变。
- 旧出口机：清理后本链的服务、配置（含私钥）、单元、nft 表、rotate 辅助文件都删除；共享目录与固定二进制保留。
- 新出口机：managed 时 nft 白名单放行中转到新机器的出站源地址；provider 时需要在新服务商安全组放行中转（文档写明，切换前的拒绝侧探针会发现配错）。
- 多链聚合：迁移后本链 EXPECTED_EXIT_IPV4 变化，与仍在旧出口机的链不同时 `multi verify/render` 退出 2，直到全部迁完（文档写明）。
- doctor：迁移中 C1 显示 `drifted reason=exit-migration-pending`。

## 8. 回归测试

本机临时 Lima 虚拟机：中转 R、旧出口机 A、新出口机 B（Ubuntu 22.04 arm64），测完删除 Lima。凡写“重跑”的用例不带测试变量。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| M1 | R→A 的链上加一台设备后 `migrate-exit --to B` | 退出 0，`migrate=done … old_exit_cleanup=done`；node.txt 与设备节点文件哈希不变；default 与设备经中转连通且出口为 B；A 上本链文件、单元、nft 表、rotate 辅助文件都不存在；status healthy；verify 通过 |
| M2 | B 上预先占用 A 的出口端口后迁移 | 自动另选端口；客户端照常连通；state 的 EXIT_REALITY_PORT 为新端口 |
| M3 | `STOP_AFTER=record / config / binary / stage / link1 / publish / probes / relay / state` 后重跑 | 都收敛为 M1 的结果；B 上无残留暂存；`record` 之后到清理完成之前 status 都输出 `reason=exit-migration-pending` |
| M4 | 迁移中途（`STOP_AFTER=publish`）分别运行 verify、rollback、rotate-keys、add-device、rehost-exit、status | rollback 退出 6，rotate-keys、add-device、rehost-exit 退出 5，均提示重跑 migrate-exit；status 为 exit-migration-pending；verify 失败（配置与 state 不一致）；之后重跑 migrate-exit 收敛 |
| M5 | `SKIP_CLEANUP=1` 迁移，再停掉 A 的 sshd 重跑，再恢复 A 重跑 | 第一次 `old_exit_cleanup=pending`；A 失联时重跑只 WARN；恢复后清理完成、记录删除 |
| M6 | 清理待做时 `--abandon-cleanup` | 记录删除、WARN 私钥残留；之后 rollback 等命令正常 |
| M7 | `STOP_AFTER=probes` 后 `--abort` | 配置恢复为旧值；B 上本链文件与暂存清空；status healthy、verify 通过（链仍在 A） |
| M8 | `STOP_AFTER=relay` 后 `--abort` | 退出 2（中转已切换），重跑 migrate-exit 收敛 |
| M8a | `STOP_AFTER=relay-nophase` 后 `--abort` | 退出 2（靠中转现场检查识别已切换），重跑 migrate-exit 收敛 |
| M8d | `STOP_AFTER=probes` 后手工把中转 owner 的 CONFIG_SHA256 改成新摘要，再 `--abort`；然后重跑 | `--abort` 退出 2（部分切换）；重跑完成迁移 |
| M8b | `STOP_AFTER=state-nophase` 后重跑 | 推导为待清理，清理完成；不会重复提交 |
| M8c | EXIT_SOURCE_FILTER=managed 的链，`STOP_AFTER=binary` 后重跑（新进程从执行阶段开始） | 成功；新机器 nft 白名单只放行中转出站源地址 |
| M9 | `--to` 为当前出口机 / 中转机 / 同机另一个 IP（指纹相同） | 退出 2，配置与 state 不变 |
| M10 | 迁移中途改用另一个 `--to` 重跑 | 退出 2 |
| M11 | B 上预先放一个本链同名的 exit.json（内容不同） | 准备阶段退出（碰撞），配置未改写 |
| M12 | A 上留有 rotate 中断的辅助文件时迁移 | 准备阶段拒绝（旧链有未完成操作） |
| M13 | 迁移后 rotate-keys、add-device、rollback | 都成功；rollback 后 B 上清理干净 |
| R1 | 新 deploy 一条链（回归 write_prepare_exit_script） | deploy、verify 通过 |
| R2 | 无迁移记录时 rotate-keys、status | 行为与 1.0.0 相同 |
| S1 | `scripts/check_interface.sh` 与 CI | 通过 |

架构不符（新机器 amd64）在本机只有 arm64 虚拟机，无法实测；由准备阶段调用的 `remote_platform_preflight` 既有逻辑保证（deploy 已覆盖），记为“未在本次实测”。

## 9. 日志 / 观测点

- `[chain][migrate-exit] INFO [migrate] phase=<prepare|execute|cleanup> …`、`[migrate] exit context=<old|new>`、每步完成 `[migrate] <步骤> done`；搬运配置只记录哈希前 12 位。
- 清理不可达 `WARN [migrate] old exit cleanup pending: ssh unreachable`；放弃清理 `WARN [migrate] old exit cleanup abandoned; private key remains on <旧 IP>`。
- 最终 `migrate-exit 通过；chain=<id> exit=<新 IP>:<端口> old_exit_cleanup=<done|pending> elapsed=<秒>s`。
