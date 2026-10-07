# v1.2.0：少敲命令（省略 `--id`、`chain up`、`chain qr`、下一步提示、分层帮助、部署前自检）

> **2026-10-06 注记**：已落地于 v1.2.0。§8 在本机 Lima 三台 Ubuntu 22.04 arm64 虚拟机上实测：T1–T7、R1、R2、S1 通过（84 项检查中 78 项直接通过，6 项失败均为测试脚本或环境原因，复核后产品行为正确：R1 一条是脚本断言写反、list-devices 一条是 T2c 重部署后设备本就不存在、两条 T6 / R2 的“`--allow-tun` 后直连 D 的 user-v2 地址”确已越过自检进入 SSH，但本机到该地址经 TUN 不可达属环境、T7 英文一条是测试环境 `LC_ALL=zh_CN.UTF-8` 优先级高于 `LANG`，去掉 `LC_ALL` 后为英文——与 §3 规则一致）。T5b（TUN 排除生效后不带 `--allow-tun` 通过）需要在 Clash Verge 里重新激活订阅，未单独实测；正例由 T6 直连到物理桥接地址不带 `--allow-tun` 直接通过等价覆盖。

## 1. 背景

- 链式首次上手要 `chain init` → `chain --id main deploy` → 找 `node.txt` 或 `multi --chains main render` 三步，之后每条命令都要带 `--id main`。
- 直连与链式部署结束后，终端只打印链接或 `node.txt` 路径，没有把“导入哪一条、导完要关订阅、出问题跑 doctor”作为下一步明确告诉用户。
- `ownexit --help` 入口是英文（`src/ownexit/cli.py:28-48`），6 个脚本的 `--help` 是中文；`chain --help` 把 20 个子命令平铺（`chain/setup_chain.sh:186-222`）。
- 本机开着代理 TUN 时，到服务器的 SSH 会被切断；现在只在 deploy 中段的探针里 WARN（`chain/setup_chain.sh:4252-4267`），doctor 里也只是 WARN（`direct/doctor.sh:278-298`）。
- 用户 2026-10-06 拍板：`chain up` 对已有配置且地址一致时继续部署；`chain qr` 默认只显示 default，设备用 `--device`；帮助只改入口为中文默认 + 分组，脚本帮助只分组；部署前自检发现 TUN 默认阻止，`--allow-tun` 放行。

## 2. 目标 / 非目标

目标：

1. `ownexit chain <子命令>` 在本机只有一条链时可以省略 `--id`；新增 `chain up`（init + deploy + 二维码一步到位，可重跑）和 `chain qr [--device <名>]`。
2. 直连与链式部署结束统一打印“下一步”块；`ownexit --help` 中文默认、按语言切换、分组；`chain --help` 分组。
3. 直连部署、链式 `deploy` / `up` 之前自检到服务器的路由是否经 TUN，经 TUN 默认拒绝并给处理办法，`--allow-tun` 放行。

非目标：

- 不改任何既有命令名、参数名、退出码含义、文件格式（1.x 冻结）；`chain init --help` 仍按 commands.md 现有描述退出 2。
- TUN 自检不加到 `preflight`、`verify`（含 `--with-fail-closed`）、`status` 及其它命令。
- 不翻译 6 个脚本的帮助为英文；不做向导（v1.4.0）；不做自适应订阅地址与 pexpect（v1.3.0）；不改 `multi`、`subctl`、`connect`。

## 3. 假设与约束

- 省略 `--id` 的判定只看 `${XDG_CONFIG_HOME:-~/.config}/ownexit/chains/*.env` 的个数（`CONFIG_HOME` 用与 `--id` 分支 `:593`、`init_paths` `:769`、`init_chain` `:8743` 相同的 `xdg_or_default` 算法），不看 state 目录。
- `chain up` 复用 `init_chain`（`:8726-8800`）与 `deploy_chain`（`:4856-4921`）；`init_chain` 里 `[[ -t 0 ]]` 时确认出口 IP 的交互保留。
- `chain qr` 不连服务器、不改 state 与节点文件（取只读锁会像 `status` 一样写 `operation.lock`）。
- TUN 判定复用 `route_interface` / `interface_is_tunnel`（`chain/setup_chain.sh:365-377`；直连脚本从 `direct/doctor.sh:125-135` 复制同名函数）。只对 IPv4 字面量检查；取不到出接口按 doctor 口径（`direct/doctor.sh:293-297`）WARN 继续。
- 路由层检查的边界：规则模式下加了 DIRECT 规则但没有做 TUN 路由排除时，`route get` 仍显示 utun、SSH 却可用，自检会拒绝（见 `docs/manual/clash-direct-ips.md` §4）。这种情况加 `--allow-tun`，拒绝信息里写明。
- 帮助语言：`OWNEXIT_LANG` 为 `zh` / `en` 时强制；其它取值或未设时看 `LC_ALL` → `LC_MESSAGES` → `LANG` 第一个非空值是否以 `zh` 开头，是则中文，否则英文。
- 测试环境前提：本机 Clash Verge TUN 开启，`route -n get <A 的 user-v2 地址> | grep interface` 显示 `utun`、`route -n get <R 的 vzNAT 地址>` 显示 `bridge100`（2026-10-06 三台虚拟机运行中已核；虚拟机停机后 bridge100 消失，vzNAT 网段也会落进 TUN 大路由）；关掉 TUN 则 T5 不可达。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main 1ea5d88） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `chain/setup_chain.sh` 文件头注释 | 1-15 | 修改 | 补 `up` / `qr` / 省略 `--id` / `--allow-tun` 说明 |
| `chain/setup_chain.sh` `usage` | 159-268（“作用”段 186-222） | 修改 | 新用法行；“作用”按 常用 / 日常 / 维护 / 高级 分组 |
| `chain/setup_chain.sh` 全局变量 | `MIGRATE_TO_PORT_GIVEN=0`（`:85`）之后 | 新增 | `ALLOW_TUN=0` `QR_DEVICE=''` `UP_MODE=0` `INIT_RELAY_GIVEN=0` `INIT_EXIT_GIVEN=0` `INIT_RELAY_PORT_GIVEN=0` `INIT_EXIT_PORT_GIVEN=0` `INIT_SNI_GIVEN=0` `INIT_FILTER_GIVEN=0` `INIT_ID_GIVEN=0` |
| `chain/setup_chain.sh` `die` | 278-294 | 修改 | `deploy\|up)` 同一映射 |
| `chain/setup_chain.sh` `parse_init_args` | 547-568 | 修改 | 各参数置 `*_GIVEN=1`；新增 `--allow-tun) ALLOW_TUN=1`；`up` 下遇 `-h` / `--help` 打印 usage 退出 0 |
| `chain/setup_chain.sh` 新函数 `is_chain_subcommand` | `parse_args` 之前 | 新增 | 唯一的子命令词表（自己的 `case`）；`check_interface.sh` 新增比对它与 `parse_args` 主 `case` 一致 |
| `chain/setup_chain.sh` `parse_args` | 570-643 | 修改 | ① `up` 与 `init` 同路分派（`:575-580` 之后）；② 首参命中 `is_chain_subcommand` 时调 `resolve_single_chain_config`，`COMMAND="$1"; shift 1`，跳过 `:581-599`；③ 主 `case` 的 `deploy)` 接受 `--allow-tun)`；④ 新分支 `qr)` 接受 `--device)`（均写成 case 模式行） |
| `chain/setup_chain.sh` 新函数 `resolve_single_chain_config`、`tun_precheck`、`print_chain_next_steps`、`qr_chain`、`up_chain`、`init_runtime` | `status_chain` 之前 | 新增 | §5.1 |
| `chain/setup_chain.sh` 新函数 `deploy_test_stop` | `write_journal` 之前 | 新增 | §5.1.2 末 |
| `chain/setup_chain.sh` `deploy_chain` | 4862 `require_local_dependencies` 之后 | 修改 | `UP_MODE=0` 时调 `tun_precheck "${RELAY_HOST}" "${EXIT_HOST}"` |
| `chain/setup_chain.sh` `write_journal` | 2808-2821 末尾 | 修改 | 追加 `deploy_test_stop`（只在 `COMMAND` 为 deploy / up 时生效，rollback 事务不受影响） |
| `chain/setup_chain.sh` `init_chain` | 8726-8800；IP 校验 `:8737-8741` 之后、`init_setup_host` 之前；末行 `:8799` | 修改 | `UP_MODE=1` 时调 `tun_precheck`；`UP_MODE=1` 时不打印 `[chain][init] next=` 行 |
| `chain/setup_chain.sh` `main` | 8802-8886（init 之后到 `init_operation_tmp` 为 8811-8822） | 修改 | 8811-8822 抽成 `init_runtime`（纯搬移）；`up` 分派；`deploy)` / `up)` 返回后调 `print_chain_next_steps`；`qr` 分派 |
| `direct/setup_direct.sh` `usage` / 参数 `case` | 66-112 / 123-146 | 修改 | 新参数 `--allow-tun`；usage 补一行 |
| `direct/setup_direct.sh` §1 之前 | 199-201 之后、202 之前 | 新增 | `route_interface` / `interface_is_tunnel` / `tun_precheck` + 调用 |
| `direct/setup_direct.sh` 交付汇总 | heredoc 997-1023；二维码 1045-1051 | 修改 | heredoc 顶部加“下一步（最常用）”；二维码段上移到 heredoc 之后、设备订阅之前 |
| `src/ownexit/cli.py` `_usage` | 28-48 | 修改 | 中英两套文案，按 §3 规则选；分“常用 / 其它”；`COMMANDS` 字典行保持 `    "<name>": (` 形态（`check_interface.sh:131` 正则依赖） |
| `scripts/check_interface.sh` | 第 6 段 165-171（`echo init` 在 168） | 修改 | `echo init` 后加 `echo up`；新增一项：`is_chain_subcommand` 词表 = 主 `case` 分支词 |
| `docs/reference/commands.md` | `## ownexit chain`、`## ownexit direct`、环境变量节 | 修改 | 见 §5.2 |
| `README.md` / `README.zh-CN.md` | 快速上手：链式；支持的平台段 TUN 一句 | 修改 | 三步改为 `chain up`；日常命令去掉 `--id main`（保留“多链时用 --id”）；TUN 一句改为“自检会拒绝，`--allow-tun` 放行” |
| `docs/manual/chain.md`、`chain/README.md` | 部署 / 日常操作段 | 修改 | 同上 |
| `CHANGELOG.md` / `src/ownexit/__init__.py` | | 修改 | 1.2.0；TUN 自检作为“行为变化（`--allow-tun` 恢复旧行为）”单列 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 省略 `--id`（U1）

- `is_chain_subcommand <词>`：独立函数，内部一个 `case`，分支词 = `parse_args` 主 `case "${COMMAND}"` 的全部分支词（含新加 `qr`，不含 `init` / `up`）。`parse_args` 里保持唯一一个 `case "${COMMAND}" in`，保证 `check_interface.sh` 第 6 段提取不变。
- `parse_args`：在 `[[ "$#" -ge 3 ]]`（`:581`）之前加：`if is_chain_subcommand "$1"; then resolve_single_chain_config; COMMAND="$1"; shift 1; else <原 :581-599 原样> fi`，然后进入原主 `case`。
- `resolve_single_chain_config`：列 `${CONFIG_HOME}/ownexit/chains/*.env`；恰好 1 个 → `CONFIG_PATH` 设为它、`log_info "自动选用链 <id>（本机唯一）"`，返回 0；0 个返回 10；≥2 个在 stderr 列出各 id 后返回 11。子命令路径：10 → `die 2 '本机没有链配置；先运行 chain up --relay <IP> --exit <IP>（或 chain init）'`，11 → `die 2 '本机有多条链，请用 --id <名字> 指定'`。`up` 路径见 §5.1.2 步 1。
- 首参既不是子命令词也不是 `init` / `up` / `--config` / `--id` 时仍走原 `:595` 退出 2（CI 的 `--no-such-option` 反例不变），提示文字改为“首个参数必须是 init、up、--config、--id 或子命令名”。实现时首参用 `"${1:-}"` 取（`set -u`）。

#### 5.1.2 `chain up`（U2）

- 分派：`parse_args` 里 `up` 与 `init` 同路：`COMMAND=up; shift; parse_init_args "$@"`；`parse_init_args` 新增 `--allow-tun) ALLOW_TUN=1`（`init` 收到只置位、无效果），`COMMAND=up` 时遇 `-h` / `--help` 打印 usage 退出 0（`init --help` 仍退出 2，不动）。各参数置 `*_GIVEN=1`。
- `main`：`COMMAND == up` 时调 `up_chain`，流程：
  1. 定位配置：`--id` 显式给出 → 用它；未给且 `--relay` / `--exit` 都未给 → 调 `resolve_single_chain_config`：返回 0 复用唯一链；返回 10（0 条）→ `INIT_ID=main` 进入第 2 步，由 `init_chain` 的 `init_prompt_ipv4`（`:8653-8662`）在终端提问 IP、非终端退出 2；返回 11 → `die 2 '本机有多条链，请用 --id <名字> 指定'`；未给 `--id` 但给了 IP → `main`。
  2. 配置不存在 → `UP_MODE=1; init_chain`（init_chain 内按 §5.1.6 先自检再配免密；不打印 `[chain][init] next=` 行）。
  3. 配置存在 → `CONFIG_PATH=它; parse_config`（第 4 步 `init_runtime` 会再解析一次，`parse_config` 只读文件、幂等，重复无副作用）；只比较**显式给出**的项：`--relay`→`RELAY_HOST`、`--relay-port`→`RELAY_SSH_PORT`、`--exit`→`EXIT_HOST`、`--exit-port`→`EXIT_SSH_PORT`，任一不一致 → `die 2 "链 <id> 已有配置且地址不同（现有 中转=… 出口=…）；换一个 --id，或先 rollback 再删配置"`；显式给出的 `--sni` / `--exit-source-filter` 与配置不同 → `log_warn "已有配置的 <键>=<值>，忽略本次给的 <值>（deploy 后不可改）"`；之后对 `RELAY_HOST`、`EXIT_HOST` 调 `tun_precheck`。
  4. `init_runtime`（从 `main` `:8811-8822` 原样搬出：`parse_config`、`init_paths`、`OPERATION_ID` / `LOCK_OPERATION_ID`、三个 trap、`init_operation_tmp`），`main` 自己也改为调用它。
  5. `deploy_chain`（已部署时它本身就是幂等 no-op + full_verify；`UP_MODE=1` 时跳过它内部的 `tun_precheck`，避免重复）。
  6. 回到 `main` 的 `up)` 分支，调 `print_chain_next_steps`。
- `die` 映射 `deploy|up)`：init 阶段的 `die 2` 直通、`die 3` 被 `3|4) ;;` 保留，deploy 阶段其它码映射为 4——与 `deploy` 一致。日志前缀为 `[chain][up]`。
- 中断重跑：init 已写配置时按第 3 步进入；deploy 中断留有 `transaction.env` 时由 `deploy_chain` 现有恢复逻辑收敛。测试钩子 `OWNEXIT_TEST_DEPLOY_STOP_AFTER=<LAST_COMPLETED_STEP 取值>`：`deploy_test_stop` 放在 `write_journal`（`:2808-2821`）末尾，`COMMAND` 为 `deploy` / `up` 且 `LAST_COMPLETED_STEP` 等于该值时 `exit 99`，覆盖 deploy 事务的全部步骤（多数步骤的 `write_journal` 在被调用的 helper 里，如 `EXIT_ACTIVE` 在 `activate_exit_exit` `:3723`）；rollback 的事务写入不受影响（`OWNEXIT_TEST_` 前缀不冻结，`compatibility.md:37`）。

#### 5.1.3 `chain qr`（U3）

- `parse_args` 主 `case` 新分支 `qr)`：0 个参数，或 `--device) <名>`（名字校验同 `add-device`，不能是 default）。
- `qr_chain`：
  1. `acquire_chain_lock 0`：rc 10 → `die 5 '同一 chain 有活动锁（busy）；稍后重试'`；11 → `die 5 '存在 stale lock；先运行 verify 或其它 mutating 命令归档'`。
  2. `[[ -e "${STATE_FILE}" ]] || die 5 '链未部署；先运行 chain up（或 deploy）'`；`load_state_file`；`verify_local_artifacts || die 5 '本地节点文件与 state 不一致；运行 verify'`。
  3. 选文件：无 `--device` → `client/node.txt`（哈希已由上一步核对等于 `NODE_SHA256`）；有 → `devices/node-<名>.txt`，不存在 → `die 2 "没有设备 <名>；运行 chain list-devices 查看"`；两个文件都 `require_secure_user_file … 600`；设备节点行的 UUID 必须等于 `devices/devices.env` 中该名字的 UUID（弱保证：devices.env 不在 state 哈希内）。
  4. 有 `qrencode` → `qrencode -t ANSIUTF8 < 文件`（URI 走 stdin）；没有 → 打印 `node=<路径>`、URI 一行、“安装 qrencode（macOS: brew install qrencode）后可在终端显示二维码”。
- `die` 对 `qr` 无映射，退出码原样：2 参数 / 无设备，5 未部署 / 锁 / 不一致。

#### 5.1.4 下一步提示块（U4）

`print_chain_next_steps`：只在 `main` 的 `deploy)` 与 `up)` 分支里、`deploy_chain` 返回 0 之后调用一次（含幂等 no-op 路径）。数据来源：`EXPECTED_EXIT_IPV4`（`parse_config`）、`${CHAIN_STATE_DIR}/client/node.txt`（no-op 路径 `:4871` 已 `load_state_file` 并核过哈希）。stdout：

```text
==================== 下一步 ====================
1. 导入客户端：下面的二维码用 Shadowrocket / 安卓客户端扫；Clash Verge 等复制这一行链接：
   vless://…
   （更多设备：ownexit chain add-device <名字>；随时再看二维码：ownexit chain qr）
2. 在设备上打开 https://ipinfo.io，应显示 <EXPECTED_EXIT_IPV4>
3. 出问题先跑：ownexit doctor
<二维码（有 qrencode 时）>
================================================
```

直连交付汇总（`direct/setup_direct.sh:997-1023` heredoc）顶部插入“下一步（最常用）”四行：Clash 订阅 + Shadowrocket 订阅、`ipinfo.io` 应显示 `<VPS IP>`、**所有设备导入后运行 `ownexit subctl stop`**、`ownexit doctor`；原详细块保留其后；`:1045-1051` 二维码段上移到 heredoc 之后、设备订阅段之前（逻辑不变）。

#### 5.1.5 分层帮助（U7）

- `src/ownexit/cli.py` `_usage`：中 / 英两套文案，选择规则见 §3；分组 常用（`direct` `chain` `doctor`）/ 其它（`subctl` `multi` `connect`）；示例改为 `ownexit direct --host …`、`ownexit chain up --relay … --exit …`、`ownexit chain status`、`ownexit doctor --ip-check`。`COMMANDS` 字典结构不变。
- `chain/setup_chain.sh` `usage` “作用”段分四组，文字仍中文：常用 `up` `status` `qr` `verify`；日常 `add-device` `remove-device` `list-devices` `conns` `kick` `ban` `unban` `banlist`；维护 `rotate-keys` `rehost-exit` `migrate-exit` `rebaseline` `rollback`；高级 / 分步 `init` `preflight` `deploy`。
- CI 的 Help output 步骤（`--help` 退出 0、未知参数非 0）不变。

#### 5.1.6 部署前自检（U8）

`tun_precheck <IP>…`：对每个参数：不是 IPv4 字面量 → `log_warn '目标不是 IPv4，跳过 TUN 自检'`；`route_interface` 为空 → `log_warn '无法判定到 <IP> 的出接口，跳过 TUN 自检'`；命中 `interface_is_tunnel` 时：`ALLOW_TUN=1` → `log_warn`（文字同现有探针）继续；否则 `die 3`，信息：

```text
到 <IP> 的路由经过 TUN（<接口>），部署期间 SSH 会被代理切断。
处理办法：关闭代理的 TUN 模式；或让这些 IP 走物理网卡（Clash Verge 见 docs/manual/clash-direct-ips.md）。
已按手册加了直连规则且 SSH 正常，或确认要继续：加 --allow-tun。
```

调用点三处：`deploy_chain` `require_local_dependencies` 之后（`UP_MODE=0` 时）对 `RELAY_HOST`、`EXIT_HOST`；`up` 的两处在依赖检查之前运行，缺 `route` / `ip` 时取不到接口只 WARN；`init_chain` IP 校验之后、`init_setup_host` 之前（`UP_MODE=1` 时）与 `up_chain` 配置已存在分支；`direct/setup_direct.sh` §1 之前对 `HOST`（直连用其 `die`，退出 1）。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit chain` 子命令 | 新增 `up`（接受 init 全部参数 + `--allow-tun`；`-h/--help` 退出 0）、`qr [--device <名>]`；首参可直接是子命令（单链时） | 1.x 兼容新增 |
| `ownexit chain deploy` | 新增 `--allow-tun` | 新增 |
| `ownexit chain` 退出码 | `up`：init 阶段 2（参数 / 配置冲突 / 未确认出口 IP）、3（配免密、探测、TUN 自检失败）；deploy 阶段同 `deploy`（3 / 4）。`qr`：2 参数或无设备；5 未部署、锁忙 / 陈旧、节点文件与 state 不一致。`deploy` 新增退出 3 的情形：TUN 自检拒绝 | 新命令的码新增；`deploy` 新增拒绝条件，含义不变 |
| `ownexit direct` | 新增 `--allow-tun`；TUN 自检拒绝时退出 1（现有失败码） | 新增 |
| 输出 | `deploy` / `up` 成功后 stdout 新增“下一步”块与二维码；`qr` 输出二维码或 `node=<路径>` + URI；直连交付块顶部新增四行 | 人工核对表新增行，不冻结 |
| 环境变量 | `OWNEXIT_LANG=zh\|en` 只影响 `ownexit --help` 文案；其它取值回落到 locale 规则 | 新增 |
| 测试钩子 | `OWNEXIT_TEST_DEPLOY_STOP_AFTER` | 不冻结 |
| 文件 / state / 配置 | 无变化 | — |

commands.md 改动：§`ownexit chain` 参数表加 `--allow-tun`（deploy / up）、`--device`（qr）；子命令表加 `up`、`qr`；退出码表按上行补注；引言“`chain init --help` 以退出码 2 拒绝”保留并补“`chain up --help` 打印帮助退出 0”；其它输出（人工核对）表加 `qr` 与“下一步”块；§`ownexit direct` 参数表加 `--allow-tun`，退出码 1 补“TUN 自检拒绝”；环境变量节加 `OWNEXIT_LANG`。

**reference sibling 回补检查**：
- Q1 涉及 reference 章节：`docs/reference/commands.md` §`ownexit chain`（参数、子命令、退出码、其它输出）、§`ownexit direct`（参数、退出码）、§环境变量。
- Q2 源码暴露面完整性：`scripts/check_interface.sh` 自动比对参数与子命令；`up` 在主 `case` 之外分派，须追加 `echo up`；新增 `is_chain_subcommand` 词表一致性比对。
- Q3 本方案是否回补：是，新增暴露面与文档同步落地。
- Q4 placeholder：N/A。

## 6. 备选方案与决策

- `chain up` 做成两条命令串联：无法在一个进程里复用 deploy 的锁与事务恢复，否决。
- 省略 `--id` 时默认取 `main`：本机只有 `backup` 一条链时会报“没有配置”，不如按个数判定直观，否决。
- 帮助语言用 `--lang` 参数：参数是冻结面，环境变量更轻，采用 `OWNEXIT_LANG`。
- TUN 自检只 WARN：用户拍板为阻止 + `--allow-tun`。

## 7. 影响分析

- `parse_args` 新增首参分支：原首参 `init` / `--config` / `--id` 路径不变；首参是子命令词原来一律退出 2，现在按链数判定（0 / ≥2 仍退出 2，信息更具体）。→ T3、R1。
- `init_chain` 增加 `UP_MODE` 判断与 `*_GIVEN`：`init` 单独运行时 `UP_MODE=0`，输出与自检行为不变。→ R1。
- `main` 抽出 `init_runtime`：纯搬移，所有现有子命令经它初始化。→ R1 全量回归。
- `deploy_chain` 新增 `tun_precheck`：开 TUN 且未排除时从“中段 WARN 继续”变为“开头退出 3”；规则模式只加 DIRECT 规则的用户也会被拒（路由未变），需加 `--allow-tun` 或做 TUN 排除。CHANGELOG 单列为行为变化。→ T5。
- `write_journal` 末尾新增 `deploy_test_stop`：未设环境变量时是空操作；`COMMAND` 不是 deploy / up 时直接返回。→ R1、R2。
- 直连脚本新增同样检查（退出 1），`HOST` 为主机名时跳过。→ T6。
- `die` 映射 `deploy|up`：只影响新命令。
- `check_interface.sh` 加 `echo up` 与词表比对：不加则 CI 接口检查失败。
- 运行时：`qr` 不连网；`tun_precheck` 每个 IP 一次 `route get`，毫秒级；无新进程 / 端口。
- 多链聚合、设备、迁移等既有功能不受影响。

## 8. 回归测试

本机 Lima 三台 Ubuntu 22.04 arm64：R（中转，vzNAT 地址）、A（出口，user-v2 地址，本机到它经 utun）、D（直连，vzNAT 地址）。前提见 §3 末条，开测前重核一次 `route -n get`。测完删除 Lima。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| T1 | 从零 `chain up --relay R --exit A --allow-tun` | 退出 0；生成 main.env；status healthy；stdout 有“下一步”块与二维码；stderr 有 TUN WARN |
| T2 | 再跑同一条 | 退出 0（deploy 幂等 no-op + verify），不再问密码，“下一步”块仍打印 |
| T2a | 只敲 `chain up --allow-tun`（不带 IP） | 复用唯一链，退出 0 |
| T2b | `chain up --relay R --exit <另一 IP> --allow-tun` | 退出 2，配置与 state 不变；`--sni www.apple.com` 与配置不同 → WARN 忽略、退出 0 |
| T2c | `OWNEXIT_TEST_DEPLOY_STOP_AFTER=EXIT_ACTIVE chain up … --allow-tun` 后重跑 `up` | 第一次退出 99 且 `status=incomplete`；重跑后事务恢复、healthy |
| T2d | `chain up --relay R --exit <同网段一个不存在的地址> --allow-tun`（不可达） | init 阶段退出 3，无配置文件生成 |
| T3 | 单链：`chain status` / `verify` / `qr` 不带 `--id` | 等同带 `--id main`，stderr 有“自动选用链 main”；`init --id b …` 后 `chain status` 退出 2 并列出 main、b；删 b 后恢复；无配置时退出 2 提示 `chain up` |
| T4 | `chain qr`；`add-device phone` 后 `qr --device phone`；`qr --device nope`；`PATH` 去掉 qrencode 再 `qr`；rollback 后 `qr` | default 二维码；phone 二维码；退出 2；node 路径 + URI + 安装提示；退出 5 “链未部署” |
| T5 | `chain deploy`（不带 `--allow-tun`，到 A 经 utun） | 退出 3，信息含 `--allow-tun` 与手册路径；`chain deploy --allow-tun` 退出 0 |
| T5b | 临时把 A 的地址加进本机 Clash 的 TUN 排除（按 clash-direct-ips.md，先备份 Script.js，测后恢复），`route get` 显示物理网卡后 `chain deploy` 不带 `--allow-tun` | 退出 0 |
| T6 | 直连 D：`direct --host D` | 成功；交付块顶部“下一步”四行，二维码紧随其后；`subctl stop` 正常；`direct --host <D 的 user-v2 地址>`（经 utun）退出 1 并提示；`--allow-tun` 放行 |
| T7 | `LANG=zh_CN.UTF-8 ownexit --help`、`LANG=C ownexit --help`、`OWNEXIT_LANG=en`、`OWNEXIT_LANG=xx` | 中 / 英 / 强制英文 / 回落 locale；都退出 0；`chain --help` 四组分层；`chain up --help` 退出 0；`chain init --help` 仍退出 2 |
| R1 | 全部旧写法：`init`、`init --allow-tun`、`--id main deploy/status/verify/add-device/list-devices/rollback`、`multi --chains main render`、`chain --no-such-option` | 行为与 1.1.0 相同；`init` 末行 `[chain][init] next=` 仍打印；未知参数退出 2 |
| R2 | `chain --id main rollback` 后 D 的 `direct --uninstall` | 两端清空 |
| S1 | `bash -n`、`/bin/bash -n`、`shellcheck -S warning`、`scripts/check_interface.sh`、`scripts/check_public.sh`、CI | 通过 |

## 9. 日志 / 观测点

- `[chain][up] INFO [up] config=<new|existing> id=<id>`；`[chain][<cmd>] INFO 自动选用链 <id>（本机唯一）`；`[chain][deploy|up] ERROR 到 <IP> 的路由经过 TUN（<iface>）…`；`[chain][up] WARN 已有配置的 <键>=… 忽略本次给的 …`。
- `qr`：`ERROR 没有设备 <名>` / `链未部署` / `本地节点文件与 state 不一致`。
- 直连：`[!] 到 <IP> 的路由经过 TUN（<iface>）…` 后退出 1。
- 测试钩子命中：`WARN 测试钩子：deploy 在 <步骤> 之后停止`，退出 99。
