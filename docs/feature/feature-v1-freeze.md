# v1.0.0：冻结命令行、配置与状态文件格式

> **2026-10-06 注记**：已落地。§8 T1-T8 通过（检查脚本 18 项全过，bash 3.2 通过；反向 T2-T5 在仓库副本上都正确报错；T7 由独立评审对照源码逐项核对三份参考文档，无事实错误；T8 用 `pipx run build` 打包，版本 1.0.0、含 Production/Stable 分类、wheel 与 sdist 均不含 `scripts/`）。S1 以 CI 为准。

## 1. 背景

- v0.1.0 到 v0.7.0 期间命令、配置和状态文件持续变化（例如链式 status 的提示词在 v0.5.0、v0.7.0 各改过一次）。用户 2026-10-05 决定做 v1.0.0：承诺 1.x 内这些接口不被破坏。
- 用户 2026-10-06 对冻结前的不一致项全部选择“保持现状”：直连用参数、链式用子命令；直连设备节点名 `ownexit-direct-<名字>`、链式 `Exit-via-Relay-<链>_<名字>`；`RELAY_COHOSTS_SINGBOX=yes` 表示 233boy；PyPI 开发状态标为 Production/Stable。
- 现状：接口说明分散在 README 两份、`chain/README.md`、`docs/manual/*.md` 与各脚本 `--help`，没有逐项清单；CI 不检查接口是否被改动。

## 2. 目标 / 非目标

目标：

1. 新增 `docs/reference/` 三份参考文档：`commands.md`（命令、参数、退出码、机器可读输出、环境变量）、`files.md`（本机与服务器文件、键、路径、格式）、`compatibility.md`（版本与兼容承诺、升级规则、内部接口清单）。
2. 新增 `scripts/check_interface.sh` 并接入 CI（lint 与 bash32 两个 job）：对 §5.1.2 列出的“脚本守护”项，从源码提取集合与参考文档比对，不一致时失败。
3. 发布 1.0.0：版本号、PyPI 分类 `Development Status :: 5 - Production/Stable`、README 两份写明稳定性承诺、CHANGELOG。

非目标：

- 不改任何命令、参数、输出、文件格式与运行行为。
- 不冻结 `--help` 全文、日志文字（§5.1.3 定义“日志”）、远端辅助脚本的退出码与临时文件。
- 不冻结内部接口（`compatibility.md` 逐项列出）：`direct/direct_remote.sh`、`direct/sync_to_vps.sh`、`direct/target_lib.sh`；链式 `transaction.env`、`baseline/`、`audit/`、`operation.lock`、`shared.lock`、`active-child.env`、`local-process.env`；链 `state.env` 的具体键集合（列为“参考”，冻结的是 SCHEMA_VERSION 语义，见 §3）；`/opt/ownexit-*/bin/` 内部布局；测试钩子 `OWNEXIT_TEST_*`。

## 3. 假设与约束（兼容承诺的核心定义，写入 compatibility.md）

- 冻结：1.x 内只做向后兼容的新增——新命令、新参数、新输出键、新的 `reason=` / `next=` / `result=` 取值、新可选配置键；不删除、不改名、不改变已有项的含义。不兼容改动只在 2.0，并提供迁移。解析方应把未知的新取值当作“需要人工查看”。
- 废弃：要移除的项在至少一个次版本里继续可用，并在输出中提示替代写法，最早在下一个主版本移除。
- 升级：1.y 必须能读取 1.x 写下的全部持久文件（含内部文件，如 `state.env`、`transaction.env`、`baseline/`、设备文件）并继续管理已有部署；不保证降级。有未完成事务（`transaction.env` 存在）或出口机辅助文件未清理（status 为 `status=drifted reason=exit-op-pending`）时先收敛再升级。
- sing-box 版本：链 `state.env` 绑定 `SING_BOX_VERSION`（`chain/setup_chain.sh:2878`），远端二进制路径带版本号（`:47`）。1.x 内升级 sing-box 属于兼容变更的前提是同一版本提供已有部署的原地迁移（不换凭据、不需要 rollback）；做不到就只能放到 2.0。本版本不改代码，只写进承诺。
- 链 `state.env`：冻结 `SCHEMA_VERSION=1` 的语义与“新版本能读旧 schema”的承诺；键表在 files.md 中列为参考，由检查脚本防止静默变化，不鼓励外部程序直接读取。
- 渲染出的客户端配置（clash.yaml、sing-box.json 等）：冻结文件名、节点名、组名 `PROXY`、自动组名 `Exit-Relay-auto`、单行 vless URI 的 node.txt 格式与“可被对应客户端导入”；文件内其余字段可兼容演进。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main 2c9d929） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `docs/reference/commands.md` | 新文件 | 新增 | §5.1.1 |
| `docs/reference/files.md` | 新文件 | 新增 | §5.1.1 |
| `docs/reference/compatibility.md` | 新文件 | 新增 | §3 的承诺、内部接口清单、输出通道定义（§5.1.3）、脚本守护 / 人工核对清单 |
| `scripts/check_interface.sh` | 新文件（100755） | 新增 | §5.1.2；支持 `--root <目录>`（默认脚本所在仓库根）与 `-h/--help` |
| `.github/workflows/ci.yml` | 16-44、69-77 | 修改 | lint 新增步骤 `Interface freeze`；help 冒烟列表加该脚本；bash32 job 加一步 `/bin/bash scripts/check_interface.sh` |
| `pyproject.toml` | classifiers（约 14-24） | 修改 | 加 `Development Status :: 5 - Production/Stable` |
| `src/ownexit/__init__.py` | 7 | 修改 | 版本 1.0.0 |
| `README.md` / `README.zh-CN.md` | “Supported platforms / 支持的平台”一节之后 | 新增 | “Stability / 稳定性”小节，链接参考文档（README.md 用完整 URL） |
| `CHANGELOG.md` | `[Unreleased]` 之后 | 新增 | 1.0.0 条目 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 参考文档结构

`commands.md`，每个子命令一节，节标题固定为 `## ownexit <子命令>`（入口为 `## ownexit（入口）`，检查脚本排除它）。每节内固定的 H3 小节（有则写）：`### 参数`、`### 子命令`、`### 退出码`、`### 输出`。“参数”表首列是一个反引号包裹的长参数（短参数写第二列）；`-h` / `--help` 在文首统一说明、不进表（链式只在单独使用 `--help` 时显示帮助，`chain init --help` 会以退出码 2 拒绝）。

| 节 | 内容 |
| ---- | ---- |
| `ownexit（入口）` | `-h` / `--help` / `help`、`-V` / `--version`；未知命令退出 2、包内脚本缺失退出 1（`src/ownexit/cli.py:55-66`） |
| `ownexit direct` | 参数 `--host` `--user` `--port` `--sni` `--proxy-port` `--migrate` `--uninstall` `--rotate-token` `--rotate-keys` `--add-device` `--remove-device`；互斥规则；退出码 0/1/2 |
| `ownexit subctl` | 参数 `--host` `--port` `--user`；子命令 login / start / stop / status / log / qr / devices；退出码 0/1/2 |
| `ownexit connect` | 参数 `--host` `--user` `--port` `--setup-only`；退出码 0/1/2/3（`direct/connect_to.sh:20,52-55`）；输出：失败时 stderr 最后一行 `reason=bad-password|password-disabled|unreachable` |
| `ownexit chain` | 参数（`init` 用）`--relay` `--exit` `--id` `--relay-port` `--exit-port` `--sni` `--exit-source-filter`，（全局）`--id` `--config`，（verify 用）`--with-fail-closed`；子命令 init / preflight / deploy / verify / status / rollback / conns / kick / ban / unban / banlist / rehost-exit / rebaseline / rotate-keys / add-device / remove-device / list-devices；退出码表；输出：status 行（`status=` `health=` `role=` `reason=` `next=` 的取值集合，`deployment=` `operation=` `step=` 只冻结键名）、各命令输出行（下表） |
| `ownexit multi` | 参数 `--chains` `--name` `--group` `--test-url` `--interval` `--qr-out` `--no-open` `--no-qr`；子命令 verify / render；退出码 0/1/2/5；输出：`[multi-chain-client] verify chain= addr= result= endpoints= elapsed=`（result ∈ ok / skipped / timeout / blocked / mismatch / error）、`[multi-chain-client] render nodes= / clash_snippet= / qr_dir=` |
| `ownexit doctor` | 参数 `--host` `--port` `--user` `--chain` `--ip-check` `--scan-sni` `--sni-candidates` `--local-only`；退出码 0/1/2；输出行前缀 `[OK]` / `[WARN]` / `[FAIL]` 与末行 `doctor: ok= warn= fail=`（检查项文字不冻结） |
| 环境变量 | `OWNEXIT_SSH_PASSWORD`（connect、direct 首次配免密、chain init 经子进程继承）；`XDG_CONFIG_HOME` / `XDG_STATE_HOME` / `XDG_CACHE_HOME`（链式与 doctor：非绝对路径时回落默认值；直连：按原值使用）；`~/.ssh/ownexit/` 不受 XDG 影响；`TMPDIR`（multi 二维码默认目录）；`OWNEXIT_TEST_*` 不是公开接口 |

链式其它命令的输出行。`#### 其它命令输出` 表（参与脚本检查）首列只放行首“键=值”或首词，整行格式写第二列；冻结行首键与取值，其余键只冻结键名：

| 首列（检查用） | 整行格式 | 来源 |
| ---- | ---- | ---- |
| `rotate=done` | `rotate=done chain= result=` | `rotate_keys_chain` |
| `device=added` | `device=added chain= name= node= result=` | `device_op_chain` |
| `device=removed` | `device=removed chain= name= result=` | `device_op_chain` |
| `rehost=noop` | `rehost=noop chain= next=run-verify` | `rehost_exit_chain` |
| `rebaseline=noop` | `rebaseline=noop chain= kind=` | `rebaseline_chain` |
| `banlist=consistent` | `banlist=consistent entries=` | `relay_banlist` |
| `banlist=inconsistent` | `banlist=inconsistent next=run-ban-or-unban` | `relay_banlist` |
| `kicked` | `kicked ip= destroyed=` | `relay_kick` |
| `banned` | `banned entry= entries= destroyed=` | `relay_ban` |
| `already-covered` | `already-covered entry= by=` | `relay_ban` |
| `unbanned` | `unbanned entry= entries=` | `relay_unban` |

另一张 `#### 其它输出（人工核对）` 表不参与脚本检查：list-devices 的 `device=<名字> node=<路径>`（缺文件时 node 以 `missing` 开头，只冻结这个前缀）、conns 表头 `ip conns idle_min_s idle_max_s banned` 与末行 `proxyd_fd= established= peers= port=`、`[chain][init] next=<脚本> --id <名> deploy`。

`files.md`：

| 分组 | 内容 |
| ---- | ---- |
| 本机目录 | `~/.config/ownexit/`、`~/.local/state/ownexit/`、`~/.cache/ownexit/`（XDG 规则见 commands.md）、`~/.ssh/ownexit/` 与密钥名 `id_ed25519_<用户>_<地址>_<端口>` |
| 直连本机 | `direct/<safe_name>.env`（HOST / SSH_PORT / SSH_USER）；`direct/<safe_name>/state.env`（SUB_PORT / TOKEN）；`direct/<safe_name>/devices.env`（`名字=TOKEN`，`!` 开头为待删除）；订阅暂存 `direct/<safe_name>/ownexit-subscription/<TOKEN>/`（`subctl qr` 读其中 node.txt） |
| 链式本机 | `chains/<id>.env` 的 13 个键与取值（`RELAY_COHOSTS_SINGBOX` ∈ yes（233boy）/ ownexit-direct / no，`EXIT_SOURCE_FILTER` ∈ managed / provider / none）；`chains/<id>/state.env`（SCHEMA_VERSION 语义冻结，键表为参考）；`client/node.txt`（单行 vless URI，片段 `#Exit-via-Relay-<id>`）；`devices/devices.env` 与 `devices/node-<名字>.txt`；`blacklist.txt`；多链聚合产物 `multi-chain-client/<名>/{nodes.txt,clash-snippet.yaml,qr-<n>-<节点名>.png}` |
| 直连服务器 | `/etc/ownexit-direct/{config.json,client.env,devices.env}`（client.env 8 个键）；`ownexit-direct.service`；`ownexit-subscription.service`；`/opt/ownexit-subscription/`；订阅路径 `http://<IP>:<端口>/<TOKEN>/` 下的文件（下表）与根路径空 `index.html`；迁移备份 `/var/backups/ownexit-direct/` |
| 链式服务器 | `/etc/ownexit-chain/<id>.{owner.env,exit.json}`；`ownexit-chain-exit-<id>.service`；`ownexit-chain-relay-<id>.{socket,service}` 与黑名单 drop-in `50-ownexit-chain-blacklist.conf`；nft 表 `inet ownexit_<id 中的 - 换成 _>` |
| 节点名与组名 | `ownexit-direct`、`ownexit-direct-<名字>`、`Exit-via-Relay-<链>`、`Exit-via-Relay-<链>_<名字>`、组 `PROXY`、自动组 `Exit-Relay-auto` |

#### 5.1.2 `scripts/check_interface.sh`

bash 3.2 可用，只用 awk / grep / sed / sort / comm。每项比较“源码提取集合”与“文档提取集合”，不等时打印两边差异；末行 `interface: ok=<n> fail=<n>`，有 fail 时退出 1。`--root` 指定仓库根（负向测试在副本上运行）。

脚本守护项：

| 检查项 | 源码提取（锚点） | 文档提取 |
| ---- | ---- | ---- |
| 子命令 | `src/ownexit/cli.py` 的 `COMMANDS` 字典里 `"<名>": (` 的键 | commands.md 中 `## ownexit <名>` 标题（排除 `（入口）`） |
| direct 参数 | `direct/setup_direct.sh` 从 `^while [[ $# -gt 0 ]]` 到其后第一个 `^done` 之间，`case` 分支模式里的 `--名字`（拆分 `|`，去掉 `=*`，排除 `--help`） | `## ownexit direct` 下 `### 参数` 表首列 |
| connect 参数 | `direct/connect_to.sh` 同上 | `## ownexit connect` |
| subctl 参数 / 子命令 | `direct/subctl` 同一循环：`--名字` 为参数；不以 `-` 开头、非 `*` 且非 `help` 的分支词为子命令 | `## ownexit subctl` 的 `### 参数` / `### 子命令` |
| doctor 参数 | `direct/doctor.sh` 同上 | `## ownexit doctor` |
| multi 参数 / 子命令 | `chain/multi_chain_client.sh` 的 `parse_args()` 函数体内循环（同规则） | `## ownexit multi` |
| chain 参数 | `chain/setup_chain.sh` 的 `parse_init_args()` 与 `parse_args()` 函数体内 `case` 分支的 `--名字`，加上 `parse_args()` 内字面量 `'--with-fail-closed'` | `## ownexit chain` 的 `### 参数` |
| chain 子命令 | `parse_args()` 函数体内 `case "${COMMAND}" in` 到 `esac` 之间的分支词（排除 `*`），加上 `init` | `## ownexit chain` 的 `### 子命令` |
| chain status 取值 | `status_chain()` 函数体内 printf 字面值，与 `main()` 函数体内以 `status=` 开头的 printf 字面值，取其中 `status=` `health=` `role=` `reason=` `next=` 的值（丢弃含 `%` 的），加上 `probe_state_file()` 内 `STATE_PROBE_REASON='…'` 的非空取值（并入 reason） | `## ownexit chain` 下 `#### status 取值` 表首列（形如 `` `next=run-verify` ``） |
| chain 其它输出行 | `setup_chain.sh` 中 printf 字面值以 `rotate=` `device=` `rehost=` `rebaseline=` `banlist=` `kicked ` `banned ` `already-covered ` `unbanned ` 开头的行首“键=值”或首词（丢弃含 `%` 的值） | `#### 其它命令输出` 表首列 |
| connect reason | `direct/connect_to.sh` 中 `die_login <词>` 的词 | `## ownexit connect` 下 `#### reason 取值` |
| 链配置键 | `chain/chain.example.env` 的键，且与 `set_config_value()` 的 case 分支键相等 | files.md `### 链配置键` 表首列 |
| 链 state 键（参考） | `state_key_list()` 函数内 `<<'STATE_KEYS'` 与结束符 `STATE_KEYS` 之间 `^[A-Z0-9_]+$` 的行（不含结束符本身） | files.md `### 链 state.env 键（参考）` 表首列 |
| 直连 client.env 键 | `direct/direct_remote.sh` 的 `render_client_env()` 中 printf 格式串里 `KEY=` | files.md `### 直连 client.env 键` |
| 订阅文件名 | `direct/setup_direct.sh` 全文件中 `"${RENDER_DIR}/<名>"` 的文件名 | files.md `### 订阅文件` 表首列（不含根路径 `index.html`，它写在 `${STAGING}/` 下，单独在正文说明） |

人工核对项（T7 由独立评审对照源码逐项核对）：各命令退出码、服务器路径与单元名、nft 表名、节点名与组名、multi 输出与产物、doctor 输出格式、conns 输出、环境变量、本机目录与 XDG 规则、渲染文件内容约定。

#### 5.1.3 输出通道（写入 compatibility.md）

- 链式：stdout 上 commands.md 列出的行冻结；stderr 上 `[chain][<命令>] INFO/WARN/ERROR …` 是日志，不冻结。`[chain][init] next=…` 走 stdout，冻结。
- connect：失败时 stderr 最后一行 `reason=…` 冻结（setup_direct 与 chain init 依赖它），其余 stderr 为日志。
- multi：stdout 上带 `[multi-chain-client]` 前缀的 verify / render 行冻结，其余为日志。
- direct / subctl：`[*] / [+] / [!]` 开头的行是给人看的进度，不冻结；冻结的是退出码与生成的订阅。
- doctor：冻结行前缀与末行格式，检查项文字不冻结。

### 5.2 接口变更

无接口变更（只新增文档与检查脚本、版本号与 PyPI 分类）。

**reference sibling 回补检查**：N/A——新增暴露面与文档化同步落地；本方案新建的 `docs/reference/` 覆盖现有暴露面，其中 §5.1.2 “脚本守护项”由检查脚本保证源码与文档一致，“人工核对项”由 T7 核对。

## 6. 备选方案与决策

- 用 `--help` 快照做兼容检查：帮助文字常改，误报多；否决。
- 只写文档不加检查：以后改代码容易漏改文档；否决。
- 冻结前统一命令形态 / 节点名 / 配置取值：用户选择保持现状；不做。
- 把 `state.env` 键作为外部可依赖接口冻结：鼓励外部依赖内部细节；否决，列为参考并由检查脚本防止静默变化。

## 7. 影响分析

- 运行时行为不变：不修改任何被执行的脚本逻辑。检查脚本不打包进 PyPI（`pyproject.toml:36-45` 只打包 `ownexit`、`ownexit.direct`、`ownexit.chain`，无 MANIFEST.in）。
- CI 多两个步骤（lint 与 bash32）：以后改动脚本守护项时必须同步参考文档，否则 CI 失败。
- `check_public.sh` 会扫描新文档：示例 IP 只用 192.0.2.x / 198.51.100.x / 203.0.113.x，IP 与中文之间留空格（v0.7.0 遇到的扫描器边角问题）。
- PyPI 页面显示 Production/Stable 与 1.0.0；README 多一小节。

## 8. 回归测试

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| T1 | 在当前代码上运行 `scripts/check_interface.sh` | 退出 0，每项 `[ok]` |
| T2 | 把仓库复制到 scratchpad，给副本 `setup_direct.sh` 加一个 `--fake-opt)` 分支，`--root <副本>` 运行 | 退出 1，指出 direct 多了 `--fake-opt` |
| T3 | 副本里从 commands.md 删掉一个 `next=` 取值 | 退出 1，指出文档缺该取值 |
| T4 | 副本里给 `chain.example.env` 加一个键 | 退出 1，指出 files.md 缺该键（且与 set_config_value 不等） |
| T5 | 副本里给 `parse_args` 加一个子命令分支 | 退出 1 |
| T6 | `--help` 退出 0；未知参数非 0；`/bin/bash` 运行结果同 T1 | 符合 |
| T7 | 独立评审对照源码逐项核对三份参考文档（重点为人工核对项） | 无事实错误 |
| T8 | `python -m build --outdir <scratchpad>`，检查 wheel 与 sdist 元数据 | 版本 1.0.0、含 Production/Stable、wheel 不含 `scripts/` |
| S1 | CI | lint（含 Interface freeze）、bash32（含检查脚本）、package、README links 通过 |

## 9. 日志 / 观测点

- 检查脚本每项一行 `[ok] <检查项>` 或 `[FAIL] <检查项>：源码有、文档没有：… / 文档有、源码没有：…`，末行 `interface: ok=<n> fail=<n>`。
