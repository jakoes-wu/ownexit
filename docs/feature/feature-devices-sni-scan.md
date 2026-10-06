# v0.7.0：多设备（每设备一个 UUID、可单独吊销）与 Reality 伪装域名扫描

> **2026-10-05 注记**：已落地并通过 §8 回归（Lima Ubuntu 22.04 arm64 虚拟机：直连 D1-D11、链式 C1-C11、扫描 S1-S4；X1 以 CI 为准）。D9 / C3 先用 0.6.0 正式版部署旧形态再用新代码操作；S1 实测 15 个候选里只有 www.microsoft.com 不可用（它同样支持 TLS 1.3 + X25519）。D10 的同机链 rebaseline 提示需要直连 VPS 同时是中转机，本次测试环境不具备，只验证了设备表删除。实现锚点：`direct/direct_remote.sh` 的 `render_users` / `build_devices_new` / `BACKUP_DEVICES`；`direct/setup_direct.sh` 的 `render_subscription_dir` 与设备 TOKEN 文件；`direct/subctl devices`；`chain/setup_chain.sh` 的“出口机凭据与设备操作”函数组（`write_rotate_remote_script` 至 `list_devices_chain`）；`direct/doctor.sh` 的 `SCAN_PROBE` / `render_scan`。

## 1. 背景

- 现在一台直连 VPS、一条链都只有一个 UUID：直连的 `config.json` 只有一个 user（`direct/direct_remote.sh:241-275` 的 `render_config`），链式出口机配置只有一行 users（`chain/setup_chain.sh:3494`）。所有设备共用同一份凭据和同一个订阅地址，某台设备丢失或停用时只能整体换凭据（v0.5.0 的 `--rotate-keys` / `rotate-keys`），所有设备都要重新导入。
- 伪装域名（SNI）能否用于 Reality 只能靠试：v0.5.0 回归实测 `www.microsoft.com` 支持 TLS 1.3 却不能当伪装域名；2026-10-05 在本机回环（sing-box 1.13.14 服务端 + 客户端都在 127.0.0.1 ）复现：amazon / apple 握手成功返回 204，microsoft 失败且服务端记 `REALITY: processed invalid connection`。
- 用户已确认的版本计划：v0.7.0 = 候选 8（多设备：每设备一个 UUID 可单独吊销，直连与链式都支持）+ 候选 7（Reality 目标站扫描：内置候选清单，在出口机上检查，不引入第三方程序）。

## 2. 目标 / 非目标

目标：

1. 直连与链式都能新增、吊销、列出设备：每台设备一个独立 UUID；吊销后该设备立即连不上，其它设备不受影响。直连每台设备有自己的订阅地址，链式每台设备有自己的节点文件。
2. 现有部署零迁移：现有的唯一 UUID 就是名为 `default` 的设备，现有订阅地址与 `client/node.txt` 不变。
3. `ownexit doctor --scan-sni`：在出口服务器上对候选域名逐个做真实 Reality 握手测试（本机回环已证实能区分 microsoft），按可用与握手耗时排序输出。

非目标：

- 不改多链聚合（`multi_chain_client.sh`）：它只聚合各链的 `default` 设备（`client/node.txt`）。
- 不提供设备级的流量统计、限速、到期时间；`full_verify` 只对 default 做 smoke，额外设备的节点由服务器配置哈希间接守护，不逐台 smoke。
- 扫描只给建议，不自动改 SNI；链式改 SNI 仍是 rollback + deploy（会删除全部设备，扫描提示里写明）。
- 不改 `subctl qr`（仍显示 `default` 设备的二维码）。

## 3. 假设与约束

- 设备名：`^[a-z0-9][a-z0-9-]{0,31}$`，`default` 保留（指现有 UUID，不能新增或吊销）；每台服务器 / 每条链最多 32 台设备（含 default）。
- 设备清单的唯一权威是服务器上的生效配置：直连是 `/etc/ownexit-direct/devices.env`（root 600，每行 `名字=UUID`，不含 default）与 `config.json` 一起由 reparam 事务维护；链式是出口机配置里的 users 行（单行 JSON 数组，每项 `{ "name": "<名字>", "uuid": "<UUID>", "flow": "xtls-rprx-vision" }`；旧部署没有 name 字段的唯一一项视为 default）。本机文件只是缓存，每次设备操作 / 轮换后用服务器输出整体覆盖。
- UUID 一律在服务器上用固定 sing-box 的 `generate uuid` 生成（与 deploy / 新装一致），本机不需要 uuidgen。
- sing-box 1.13.14 接受多个带 `name` 字段的 user（2026-10-05 用本机缓存的官方包 `sing-box check` 实测通过）。
- 凭据轮换（直连 `--rotate-keys`、链式 `rotate-keys`）改为同时重新生成全部设备的 UUID（含 default），Reality 密钥对与 short id 照旧重新生成；所有设备都要重新导入（与 v0.5.0 的提示一致）。
- 扫描在出口服务器上执行，依赖固定 sing-box（路径规则见 §5.1.4）、curl、openssl；任一缺失时该服务器的扫描整体显示“无法判定（缺少 <命令>）”，不输出可用 / 不可用。openssl 的 `-tls1_3`、`-groups` 需要 1.1.1 及以上（Debian 10 / Ubuntu 20.04 起满足，按 OpenSSL 手册推断，未在旧发行版实测）；只用退出码判定，不解析协商组输出行（1.1.1 与 3.x 格式不同）。
- 版本混用：用 v0.6.0 及更早的本机脚本操作有设备的直连 VPS 时，旧 `op.sh` 的 reparam 会只渲染 default，设备被静默丢弃；用旧链式脚本对新形态 users 行做 rotate-keys 会以 192 拒绝（安全）。文档写明“有设备后请保持本机为 0.7.0 及以上”。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main 9bda260） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `direct/direct_remote.sh` `render_config` | 241-275 | 修改 | 新增第 9 个参数“设备文件路径”（可空）；users = default + 设备文件各行，单行数组，每项带 name |
| `direct/direct_remote.sh` `op_fresh` / `op_migrate` 调用点 | 388、659 | 修改 | 第 9 个参数传空串 |
| `direct/direct_remote.sh` `op_reparam` WRITE / BACKUP / REPLACE | 440-505 | 修改 | 新增 op.args 键 `DEVICE_ADD` / `DEVICE_REMOVE`；生成 `devices.env.new`；ROTATE=1 时为每台设备换 UUID；备份 / 替换纳入 devices.env（§5.1.1） |
| `direct/direct_remote.sh` `reparam_rollback` | 423-438 | 修改 | 按 `BACKUP_DEVICES` 恢复或删除 devices.env；删除 `devices.env.new` |
| `direct/direct_remote.sh` `on_err` WRITE 分支 | 776-778 | 修改 | 同时删除 `devices.env.new` |
| `direct/direct_remote.sh` `probe` | 99-134 | 修改 | 输出 `DEVICES=<名字,…>`；in_progress 时另输出 `TXN_DEVICE_ADD` / `TXN_DEVICE_REMOVE` |
| `direct/setup_direct.sh` 参数与用法 | 60-140 | 修改 | 新增 `--add-device <名字>`、`--remove-device <名字>`；互斥规则 |
| `direct/setup_direct.sh` in_progress 恢复 | 446-460 | 修改 | 恢复的 reparam 结果 ok 时，按 `TXN_DEVICE_ADD` / `TXN_DEVICE_REMOVE` 记下已完成的设备操作，本次相同操作跳过 |
| `direct/setup_direct.sh` 复用分支 | 517-560 邻近 | 修改 | 设备操作并入 `start_op reparam`（与 SNI / 端口 / ROTATE 同一次） |
| `direct/setup_direct.sh` 读回 / 渲染 / 同步 / 清理 / 汇总 | 594-900 | 修改 | 读回 devices.env；本机设备 TOKEN 文件；逐设备渲染；只删本机记录过的吊销设备与旧 TOKEN 目录；汇总按设备列出 |
| `direct/setup_direct.sh` `print_chain_hints` 触发 | 885-890 | 修改 | 设备操作也触发，文案“设备变动” |
| `direct/subctl` | 子命令分派 | 新增 | `devices`：只读列出 VPS 上的设备名与本机记录的各设备订阅地址 |
| `chain/setup_chain.sh` `write_rotate_remote_script` | 6779-6960 | 修改 | 通用化为“出口机凭据操作”：`apply <操作>`，操作为 `rotate` / `add:<名字>` / `remove:<名字>`；远端从 live users 行解析设备、推导新配置；`rotate.env` 记录 `MODE`、目标设备全表；判定表加“上次操作不同”（§5.1.2） |
| `chain/setup_chain.sh` `rotate_exit_apply` / `publish_rotated_node` / `commit_rotate_state` / `rotate_keys_chain` | 6962-7100 | 修改 | 解析远端输出的设备全表；写全部节点文件与本机 devices.env；`resumed-after-commit` 比对含设备 |
| `chain/setup_chain.sh` 新函数 `device_op_chain` 与 `list_devices_chain` | `status_chain`（7102）之前 | 新增 | `add-device` / `remove-device` / `list-devices` |
| `chain/setup_chain.sh` `write_prepare_exit_script` | 3494 | 修改 | deploy 模板 users 项加 `"name": "default"` |
| `chain/setup_chain.sh` `remove_active_local_artifacts` | 5368 邻近 | 修改 | 删除 `devices/` 下的 `devices.env`、`node-*.txt`、`.*.tmp`（逐个校验身份），再 `rmdir devices` |
| `chain/setup_chain.sh` `configured_local_resources_absent` | 5821 | 修改 | 候选加 `${CHAIN_STATE_DIR}/devices` 目录 |
| `chain/setup_chain.sh` `local_deployment_residue_absent` | 4276 | 修改 | 候选只加 `${CHAIN_STATE_DIR}/devices/.*.tmp`（设备目录本身不是残留） |
| `chain/setup_chain.sh` 未完成提示 | 4438、4578、4625、5511、6765、7214 | 修改 | 文案改为“出口机上有未完成的凭据或设备操作，重跑中断的那条命令（rotate-keys / add-device / remove-device）”；status 输出改为 `reason=exit-op-pending next=rerun-interrupted-command` |
| `chain/setup_chain.sh` `parse_args` / `main` / `usage` | 545、主分派、155 | 修改 | 新子命令；`list-devices` 加入只读重试名单 |
| `chain/setup_chain.sh` `rotate_remote_reason` | 6962 邻近 | 修改 | 新增 199（另一操作未完成，带 PENDING_MODE）、201 设备已存在、202 超过上限、203 设备不存在、204 不能吊销 default；本机对 201-204 以退出码 2 结束 |
| `direct/doctor.sh` | 参数、新增扫描段 | 修改 | `--scan-sni`、`--sni-candidates`；远端扫描脚本（§5.1.4） |
| `.github/workflows/ci.yml` | 无 | 无 | 不变（doctor 不写死 sing-box 版本，按路径规则查找） |
| 文档 / 版本 | README 两份、`docs/manual/direct.md`、`docs/manual/chain.md`、`chain/README.md`、`direct/README.md`、`CHANGELOG.md`、`src/ownexit/__init__.py` | 修改 | 新命令与行为、轮换语义、版本混用提醒、0.7.0 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 直连多设备

服务器端：

- `render_config` 第 9 个参数为设备文件路径（空串或文件不存在 = 无额外设备）。users 数组第一项 `{ "name": "default", "uuid": "<参数 uuid>", "flow": "<flow>" }`，其后按设备文件逐行追加，整段写在一行。
- `op_reparam` WRITE 步，在现有逻辑之后：
  - 以 `devices.env`（不存在视为空）为基础生成 `devices.env.new`：`DEVICE_ADD=<名字>` 时名字已存在 `CAUSE=device-exists`、已达 31 台额外设备 `CAUSE=device-limit`，否则追加 `名字=<新 UUID>`；`DEVICE_REMOVE=<名字>` 时不存在 `CAUSE=device-missing`，否则删去该行；`ROTATE=1` 时每台设备换新 UUID；三者都没有时原样复制。
  - 用 `devices.env.new` 渲染 `config.json.new`。
- BACKUP 步：先写 `BACKUP_DEVICES`（devices.env 存在时为备份文件路径，不存在时为 `none`），再写现有的 `BACKUP_CONFIG` / `BACKUP_CLIENT`（`BACKUP_CONFIG` 仍是“备份已完成”的标记，所以 `BACKUP_DEVICES` 必须先写）。
- REPLACE 步：`devices.env.new` 存在时，内容为空则删除 `devices.env` 与 `.new`，否则 `mv`。
- `reparam_rollback`：`BACKUP_DEVICES` 为备份路径时恢复它；为 `none` 时删除 devices.env；为空（v0.6.0 留下的未完成操作没有这个键）时不碰 devices.env；最后删除 `devices.env.new`。`on_err` 的 WRITE 分支同样删除 `devices.env.new`。
- `probe`：输出 `DEVICES=<逗号分隔的名字>`；in_progress 时另输出 `TXN_DEVICE_ADD` / `TXN_DEVICE_REMOVE`（读 op.args，无则空）。

本机端（`setup_direct.sh`）：

- 新参数 `--add-device <名字>`、`--remove-device <名字>`：两者互斥；与 `--migrate`、`--uninstall` 互斥；可与 `--sni` / `--proxy-port` / `--rotate-keys` / `--rotate-token` 同用（设备与参数变化在同一次 reparam 完成）。只在 STATE=ownexit / migrated_leftover 时允许；none 时退出 2 提示先部署，legacy 时提示先迁移。名字非法或为 `default` 时退出 2。
- in_progress 恢复：恢复的 reparam 结果 ok 时，若 `TXN_DEVICE_ADD` 等于本次 `--add-device`（或 `TXN_DEVICE_REMOVE` 等于本次 `--remove-device`），视为已完成、本次不再提交该设备操作（与 v0.5.0 的 `ROTATED` 同理，按项目分别判断）；恢复以 rolled-back 结束时照常执行。
- 本机设备 TOKEN 文件 `${STATE_DIR}/devices.env`（600，每行 `名字=TOKEN`），default 的 TOKEN 仍在 `state.env`。读回服务器 devices.env 后对齐：服务器有、本机没有的设备补生成 TOKEN；本机有、服务器没有的设备记为“已吊销”（其 TOKEN 进入待删除集合），在 VPS 上删除对应目录成功之后才从本机文件删除（同步中断时下次仍能找到待删除的 TOKEN）。`--rotate-token` 时 default 与所有设备的 TOKEN 都重新生成，旧的全部进入待删除集合。
- 渲染：default 照旧渲染到 `<TOKEN>/`；每台设备渲染到 `<设备 TOKEN>/`，四份文件与 default 结构相同，UUID 与节点名（`ownexit-direct-<名字>`）不同。
- 同步后清理：只删除待删除集合里的 TOKEN 目录（格式校验 32 位十六进制），不删除本机没有记录的目录（多控制端或本机状态丢失时不误删别处生成的订阅；代价是本机丢失状态后，旧的设备订阅目录要用户自己清理，文档写明）。
- 汇总：default 的四条链接照旧；每台设备另列一组；`--add-device` 时提示“只把这一组发给新设备”；`--remove-device` 时提示“该设备已失效”。
- 设备操作后 `CHANGED_PARAMS` 不置 1（其它设备不必重新导入），另置 `CHANGED_DEVICES=1`；恢复的未完成操作若是纯设备操作（无 SNI / 端口 / ROTATE 变化，按 op.args 判断），同样只置 `CHANGED_DEVICES`，不置 `CHANGED_PARAMS_RECOVERED`；触发 `print_chain_hints`（同机链的基线包含 `/etc/ownexit-direct`，需要 rebaseline），文案为“直连设备有变动”。

`subctl devices`（只读）：SSH 读 VPS 上 devices.env 的名字（只取名字，不取 UUID），与本机 `${STATE_DIR}/devices.env` 对照，列出每台设备与其订阅地址；服务器有而本机没有 TOKEN 的设备提示“重跑 ownexit direct 生成订阅”。

#### 5.1.2 链式多设备与凭据操作

出口机配置 users 行（单行）：`"users": [{ "name": "default", "uuid": "<VLESS_UUID>", "flow": "xtls-rprx-vision" }, { "name": "<名字>", "uuid": "<UUID>", "flow": "xtls-rprx-vision" }],`。deploy 模板（`:3494`）改为带 `"name": "default"` 的单项形式。

远端脚本（由 `write_rotate_remote_script` 通用化）`apply <操作>`，操作为 `rotate`、`add:<名字>`、`remove:<名字>`。执行顺序：先按第 5 步的判定表分流；第 1-4 步（解析、推导与 201-204 校验、生成待切换配置、写 rotate.env）只在“全新”分支执行；`already` / `resumed` / `resumed-after-commit` 一律输出 rotate.env 里的全表（否则 add 在切换后中断、重跑时 live 已含新设备，会被 201 误拒）。v0.5.0 遗留的 rotate.env 没有 `MODE` 与 `DEVICE_*`：视为 `MODE=rotate`，以其 `VLESS_UUID` 作为唯一的 `DEVICE_default`。

1. 从 live 配置取 users 行（去掉前导空白后以 `"users": [` 起首、恰好 1 行，否则 192），用 awk 解析出 `名字 UUID` 列表；没有 name 字段的唯一一项视为 default。
2. 按操作推导目标设备表：`add` 名字已存在 `exit 201`、达上限 `exit 202`；`remove` 不存在 `exit 203`、名字是 default `exit 204`；`rotate` 为每台设备（含 default）生成新 UUID，并生成新密钥对与 short id。
3. 生成待切换配置：整行替换 users；rotate 时另替换 private_key 与 short_id 两行（与 v0.5.0 相同的逐行替换）。
4. `rotate.env` 记录 `MODE=<操作>`、`NEW_SHA256`、`DEVICE_<名字>=<UUID>`（目标全表，含 default）、rotate 时另记 `REALITY_PUBLIC_KEY` / `REALITY_SHORT_ID`。
5. 判定表在 v0.5.0 基础上加一列 MODE：

| 现场 | 判定 | 动作 |
| ---- | ---- | ---- |
| live = state，env 存在，env.NEW = live，env.MODE = 本次操作 | 上次同一操作已提交、未清理 | `RESULT=resumed-after-commit`，输出 env 全表，不再生成 |
| live = state，env 存在，env.NEW = live，env.MODE ≠ 本次操作 | 上次另一操作已完成、未清理 | 删除辅助文件后按“全新”处理本次操作 |
| live = state，env 存在且 pending 完整，env.MODE = 本次操作 | 上次在切换前中断 | 复用并切换（`resumed`） |
| live = state，env 存在且 pending 完整，env.MODE ≠ 本次操作 | 上次另一操作未完成 | 输出 `PENDING_MODE=<操作>`，`exit 199`，不动文件 |
| live = state，其它 | 全新 | 删除残缺辅助文件，生成并切换（`fresh`） |
| live ≠ state，env.NEW = live，env.MODE = 本次操作 | 已切换、本地未提交 | 重启并核验（`already`） |
| live ≠ state，env.NEW = live，env.MODE ≠ 本次操作 | 另一操作已切换、本地未提交 | 输出 `PENDING_MODE`，`exit 199` |
| live ≠ state，其它 | 外部改动 | `exit 193` |

6. 成功输出：`RESULT`、`MODE`、`EXIT_EXIT_SHA256`、全部 `DEVICE_<名字>=<UUID>`、rotate 时 `REALITY_PUBLIC_KEY` / `REALITY_SHORT_ID`。

本机侧（rotate-keys、add-device、remove-device 共用）：

```text
取锁 → 依赖 → 拒绝未完成事务 / 未部署 → probe_state_file 必须 0（12 退出 2）→ render_ssh_config
→ probe_loaded_binding（映射同 rehost-exit）
→ 清理本机 ${CHAIN_STATE_DIR}/.node.txt.rotate.*.tmp 与 ${CHAIN_STATE_DIR}/devices/.*.tmp（逐个校验 600）
→ 远端 apply <操作>（199 时 die 1 “出口机上有未完成的 <PENDING_MODE 对应的命令>，先重跑它”）
→ 用输出覆盖本机：VLESS_UUID = DEVICE_default；rotate 时更新公钥与 short id；
  写 client/node.txt（default，临时文件仍为 ${CHAIN_STATE_DIR}/.node.txt.rotate.<操作ID>.tmp，不放进 client/）、
  devices/node-<名字>.txt 与 devices/devices.env（不含 default，临时文件为 devices/.<文件>.<操作ID>.tmp）；
  不在全表里的 node-*.txt 删除；都经临时文件 + mv
→ 提交 state（resumed-after-commit 时只核对输出与 state 一致，不提交）；audit 目录名 rotated.* 或 devices.*
→ 远端 cleanup → full_verify
```

- 本机文件写入在 state 提交之前，中断后重跑时远端走 `already` 或 `resumed-after-commit`，输出相同全表，本机重写结果相同，收敛。
- 本机 devices.env 丢失或损坏不会影响服务器：远端从 live users 行推导，本机文件在下一次任何设备操作或 rotate-keys 时被重建。`list-devices` 读出口机 users 行的名字（只读 SSH，见下）与本机节点文件对照，缺文件时提示“运行 rotate-keys 或任一设备命令可重建”。
- 节点名：default 仍是 `Exit-via-Relay-<链>`；其它设备为 `Exit-via-Relay-<链>_<名字>`（`_` 不在链名与设备名的字符集里，避免与带连字符的链名重名；不用 `@`，部分客户端按最后一个 `@` 拆用户信息）。

`list-devices`：加入 `main` 的 `READONLY_SSH_RETRY` 名单（与 status 相同）；取锁 → `ssh_exit` 用 awk 只读出 users 行里的名字 → 与本机 `devices/` 对照输出 `device=<名字> node=<路径|missing>`。

提示文案：verify 出口机脚本的 150、`probe_remote_resources` 的 33 保持不变；full_verify / rollback 的 die 信息与 status 输出改为“出口机上有未完成的凭据或设备操作”，status 为 `status=drifted reason=exit-op-pending next=rerun-interrupted-command`（替换 v0.5.0 的 `reason=rotate-pending next=run-rotate-keys`，CHANGELOG 记为变更）。

rollback：`remove_active_local_artifacts` 在删除 `client/` 之后处理 `devices/`：逐个 `require_secure_user_file 600` 后删除 `devices.env`、`node-*.txt`、`.*.tmp`，然后 `rmdir devices`。

#### 5.1.3 共用规则

- 设备数上限 32（含 default）。
- 吊销即时生效：服务器配置重启后旧 UUID 被拒；所有设备的在途连接随重启断开一次。

#### 5.1.4 Reality 伪装域名扫描（`doctor --scan-sni`）

命令行：`--scan-sni` 是与 `--ip-check` 同类的附加项（可同用），与 `--local-only` 互斥；`--sni-candidates a.com,b.com` 只能与 `--scan-sni` 同用（否则退出 2），每个都必须是 ASCII FQDN，最多 30 个。

出口服务器上的 sing-box 路径：直连取 `systemctl show ownexit-direct -p ExecStart --value` 输出（形如 `{ path=/opt/…/sing-box-1.13.14 ; argv[]=… }`）中 `path=` 之后到第一个空格或分号之前的部分；链式为 `/opt/ownexit-chain/bin/sing-box-*` 中唯一的一个（多于一个取文件名排序最后一个）。直连是 233boy 旧版或未安装、链式没有该文件时，该服务器的扫描显示“跳过（没有本项目安装的 sing-box）”。

远端脚本（经 `bash -s` 投递；所有命令 `< /dev/null`，输出重定向到临时目录）：

1. 先探测 curl、openssl、sing-box；缺任一输出 `SCAN_ERROR=缺少 <命令>` 后退出 0。
2. `work="$(mktemp -d)"`；`trap` 覆盖 `EXIT HUP INT TERM`：kill 记录的子进程并删除 `$work`。
3. 对每个域名：
   - `timeout 12 openssl s_client -connect <域名>:443 -servername <域名> -tls1_3 -groups X25519 -alpn h2 < /dev/null`：退出码 0 记 `tls13=yes`，输出含 `ALPN protocol: h2` 记 `h2=yes`；
   - 选两个空闲端口（20000-59999 随机，`ss -Hltn` 确认未监听，最多试 10 次）；用 `generate reality-keypair` / `generate uuid` 生成一次性凭据；写服务端（只监听 127.0.0.1 ，handshake 指向该域名）与客户端（mixed 监听 127.0.0.1 ）配置；
   - `timeout 20 <sing-box> run -c …` 各起一个（后台、`< /dev/null`、输出到临时目录），等 1 秒；
   - `curl -4 -sS -m 12 -o /dev/null -w '%{http_code} %{time_total}' -x socks5h://127.0.0.1:<客户端端口> https://www.gstatic.com/generate_204`：204 记可用，否则不可用；
   - kill 两个进程并 wait，输出 `SNI=<域名>|<yes/no>|<tls13>|<h2>|<秒>`。
4. 结束时 trap 清理。

内置候选（15 个）：www.amazon.com、www.apple.com、www.microsoft.com、www.cloudflare.com、www.nvidia.com、www.tesla.com、www.samsung.com、www.oracle.com、www.intel.com、www.amd.com、www.yahoo.com、www.bing.com、dl.google.com、gateway.icloud.com、swdist.apple.com。每个域名最坏约 45 秒（openssl 12 + curl 12 + 进程），15 个最坏约 11 分钟，通常 1-2 分钟；开始前打印预计耗时。

本机渲染：先列可用的（按握手耗时升序），再列不可用的；当前 SNI（直连读 client.env 的 SNI，链式读配置的 REALITY_SERVER_NAME）行尾标“（当前）”。末尾提示：直连 `ownexit direct --sni <域名>`；链式改 SNI 需 rollback 后改配置再 deploy，会删除全部设备、所有客户端重新导入。扫描结果不计入 OK / WARN / FAIL 汇总。doctor 文件头补一句：扫描会在服务器 `/tmp` 下临时建目录并临时运行只监听 127.0.0.1 的 sing-box，结束即删。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit direct` | 新增 `--add-device` / `--remove-device` | 新增；不加时行为不变 |
| `ownexit subctl` | 新增 `devices` | 新增 |
| 直连订阅目录 | 每台额外设备一个 `<TOKEN>/` 目录；`--rotate-token` 同时换掉设备 TOKEN | default 的 TOKEN 与路径不变 |
| 直连服务器文件 | 新增 `/etc/ownexit-direct/devices.env`；`config.json` users 项多出 `name` 字段（下一次 reparam 时） | 迁移检测读的是 233boy 的配置，不受影响 |
| `direct_remote.sh` op.args / probe / txn | 新增 `DEVICE_ADD` / `DEVICE_REMOVE`；probe 新增 `DEVICES`、`TXN_DEVICE_ADD` / `TXN_DEVICE_REMOVE`；txn 新增 `BACKUP_DEVICES` | 旧操作没有这些键时按无设备操作、不碰 devices.env |
| `ownexit chain` | 新增 `add-device` / `remove-device` / `list-devices` | 新增 |
| 链式本机文件 | 新增 `${CHAIN_STATE_DIR}/devices/` | `client/node.txt` 与审计不变 |
| 链式出口机配置 | users 行带 `name` 字段、可多项；新部署即为此形态 | 旧部署首次执行设备命令或 rotate-keys 时改写 |
| 链式远端辅助文件 `rotate.env` | 新增 `MODE` 与设备全表 | 只在命令中途存在 |
| 链式 status | `reason=rotate-pending next=run-rotate-keys` 改为 `reason=exit-op-pending next=rerun-interrupted-command` | 0.x 内的变更，CHANGELOG 注明 |
| 凭据轮换语义 | 同时轮换全部设备 UUID | 与“所有设备重新导入”一致 |
| `ownexit doctor` | 新增 `--scan-sni`、`--sni-candidates` | 新增 |

不涉及 `docs/reference/*`，无需 sibling 回补检查。

## 6. 备选方案与决策

- 所有设备共用一个订阅地址、订阅里列出全部 UUID：被吊销的设备仍可重新拉订阅拿到别人的 UUID；否决。
- 链式由本机设备文件决定 users 行（“目标列表”实现）：本机文件丢失或与远端不一致时会静默吊销其它设备，且中断后本机与远端各说各话；否决，改为远端按操作从 live users 行推导、本机以远端输出为准。
- 链式把设备写进 `state.env` 新键：旧版本严格校验键集合会拒绝读取；否决。
- 设备操作使用与 rotate-keys 不同的辅助文件名：verify / rollback / status 的未完成检查要再加一套；否决，共用 `<id>.rotate.*` 并在 env 里记录 MODE。
- 扫描只看 TLS 1.3 / X25519：microsoft 反例证明不充分；否决，以本机回环 Reality 握手为准（已实测可区分）。

## 7. 影响分析

正向：

- `render_config` 的全部调用点（:388、:475、:659）都传第 9 个参数；新装与迁移传空串，生成的 users 只多一个 `"name": "default"` 字段；迁移的“参数沿用”承诺不变。
- 直连已部署的服务器只在下一次 reparam（设备操作、改参数、轮换）时 users 增加 name 字段；复用（不改参数）不重写配置。
- 链式 deploy 模板 users 行加 `name` 字段：新部署的出口机配置哈希与旧版本不同，属于新部署；已部署的链 verify 只比对 state 记录的哈希，不受影响。
- 链式远端脚本通用化后，rotate-keys 的判定表多一列 MODE；v0.5.0 留下的旧 `rotate.env`（没有 MODE）视为 `MODE=rotate`。
- `local_deployment_residue_absent` 只加 `devices/.*.tmp`：有设备时 status / full_verify 不会误报残留（§8 C1、C8）。
- `remove_active_local_artifacts` 多处理 `devices/`：调用方为 rollback 第 6 步与 `cleanup_incomplete_deploy`；deploy 中途失败时 `devices/` 不存在，跳过。
- status 的 reason / next 文案变化：doctor 的 C1 只转述 `next=`，不依赖具体值。

反向：

- 多链聚合只读 `client/node.txt`（default 设备），不受影响。
- 同机直连做设备操作会让链的中转基线（含 `/etc/ownexit-direct`，`chain/setup_chain.sh:1995`）漂移，需要 rebaseline；直连在设备操作后打印提示（§8 D10）。
- `subctl qr` 仍读 default 的 `node.txt`。

运行时：

- 每增加一台设备，配置多约 90 字节；设备操作重启一次服务（中断 1-3 秒）。
- 扫描临时进程只监听 127.0.0.1 ，正式服务与 managed nft 规则（只匹配正式 Reality 端口，`chain/setup_chain.sh:3591`）不受影响。

## 8. 回归测试

在本机临时 Lima 虚拟机上执行（直连 1 台、链式中转与出口各 1 台），测完删除 Lima；凡写“重跑”的用例不带测试变量；连通性测试把节点地址改为虚拟机内网地址。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| D1 | 新装直连 | users 只有 default（带 name）；订阅结构与 v0.6.0 相同 |
| D2 | `--add-device phone`、`--add-device laptop` | 服务器 devices.env 两行；VPS 多两个 TOKEN 目录；三套凭据都能连通 |
| D3 | `--remove-device phone` | phone 连不上、其 TOKEN 目录被删；default 与 laptop 可用 |
| D4 | `subctl devices` | 列出 default、laptop 及订阅地址；服务器文件哈希不变 |
| D5 | 重名、`default`、不存在的名字、非法名字、none 状态下 add | 退出非 0，服务器配置不变 |
| D6 | 有设备时 `--rotate-keys` | 全部 UUID 变化，旧 UUID 连不上，新订阅可用 |
| D7 | `--add-device x` 在 RESTART 步中断后带同一参数重跑 | 恢复后跳过重复操作，只加一台，退出 0 |
| D8 | 设备操作在 CHECK 步注入失败 | rolled-back，devices.env 与配置回到操作前 |
| D9 | v0.6.0 部署的直连（无 name 字段）上加设备 | 成功，default 凭据不变 |
| D10 | 吊销最后一台设备 | devices.env 被删除；同机链提示 rebaseline 的文案为“设备变动” |
| D11 | `--rotate-token` 有设备时 | 所有 TOKEN 都变，旧目录全部删除 |
| C1 | 链 `add-device phone` | users 两项；`devices/node-phone.txt` 存在且可用；verify 通过；status healthy |
| C2 | `remove-device phone` | 该 UUID 连不上；节点文件删除；verify 通过 |
| C3 | v0.6.0 形态（无 name）的链上 `add-device` 与 `rotate-keys` | 都成功 |
| C4 | 有设备时 `rotate-keys` | 全部 UUID 与密钥变化；所有节点文件更新；verify 通过 |
| C5 | `add-device` 在远端切换后中断（STOP_AFTER=swap）、在本机写完文件后中断（STOP_AFTER=node）、在 state 提交后中断（STOP_AFTER=state），分别重跑 | 分别 `already`、`already`、`resumed-after-commit`；只加一台；verify 通过 |
| C6 | `add-device` 在切换前中断（STOP_AFTER=stage）后改跑 `rotate-keys` | 退出 1，提示先重跑 add-device；出口机不变 |
| C7 | `rotate-keys` 在切换前中断后改跑 `add-device` | 同上，提示先重跑 rotate-keys |
| C8 | 有设备时 rollback | `devices/` 被删除；status not_deployed；再 deploy 通过 |
| C9 | 删掉本机 `devices/devices.env` 后 `add-device z` | 成功，出口机上原有设备都保留，本机文件被重建 |
| C10 | `list-devices`；保留名 / 不存在 / 重名 / 非法名字 | 列表正确（缺节点文件时提示）；错误时退出 2 且远端不变 |
| C11 | 辅助文件存在时 status | `reason=exit-op-pending next=rerun-interrupted-command` |
| S1 | `doctor --scan-sni --host <VPS>` | 输出 15 个域名；amazon / apple 可用、microsoft 不可用；无残留进程与临时目录 |
| S2 | `doctor --scan-sni --chain <链> --sni-candidates www.amazon.com,www.microsoft.com` | 经中转在出口机执行，结果同上 |
| S3 | 非法候选、`--sni-candidates` 不带 `--scan-sni`、`--scan-sni --local-only` | 退出 2 |
| S4 | 出口机临时把 curl 改名后扫描 | 显示“无法判定（缺少 curl）” |
| X1 | CI | lint、shellcheck、help 冒烟、隐私扫描通过 |

测试钩子：链式沿用 `OWNEXIT_TEST_ROTATE_STOP_AFTER`（对设备命令同样生效）与 `OWNEXIT_TEST_ROTATE_BREAK_PORT`；直连沿用 `OWNEXIT_TEST_DIRECT_FAIL_AT` / `PAUSE_AT`。

## 9. 日志 / 观测点

- 直连：`[*] 改参数：… 设备=新增 <名字> / 吊销 <名字>`；服务器日志 `[vps]` 中的 `DEVICE_ADD=` / `DEVICE_REMOVE=`；结果行 `OP=reparam 结果=…`。
- 链式：`[chain][add-device] INFO [exit-op] mode=add:<名字> exit=<fresh|resumed|already|resumed-after-commit> devices=<n>`、`[exit-op] state committed audit=<路径>`、最后 `add-device 通过；chain=<id> device=<名字>`；199 时 die 信息带 `PENDING_MODE`。
- 扫描：每个域名一行 `<域名>  可用 / 不可用  TLS1.3+X25519=yes/no  h2=yes/no  握手 <秒> s`，当前 SNI 行尾标“（当前）”。
