# v2.0.0：移除 1.5.0 废弃的旧写法

## 1. 背景

1.5.0 把直连改成子命令、把 `ownexit subctl` 并入 `ownexit direct`、让 `chain migrate-exit` 自动处理同一台出口机换 IP，同时把下列写法标为废弃（`docs/reference/compatibility.md` §3a）：

- `ownexit direct --rotate-keys` / `--rotate-token` / `--add-device <名>`（含 `--add-device=<名>`）/ `--remove-device <名>`（含 `=` 形式）/ `--migrate` / `--uninstall`：`direct/setup_direct.sh:248-257` 照常执行并经 `deprecated()`（`:204-205`）在 stderr 提示新写法（`:276`）。
- `ownexit subctl <start|stop|status|log|qr|devices|login>`：`src/ownexit/cli.py:24` 照常转发到 `direct/subctl`；`direct/subctl:133-140` 在没有 `OWNEXIT_VIA_DIRECT=1` 时打废弃提示。`ownexit direct` 的日常操作本身由 `setup_direct.sh:216-231` 的 `forward_to_subctl` 带 `OWNEXIT_VIA_DIRECT=1` 转给 `direct/subctl` 实现。
- `ownexit chain rehost-exit`：`chain/setup_chain.sh:9470-9472` 打废弃提示后执行 `rehost_exit_chain`（`:6771-6782`）；同机切换主体 `rehost_exit_body`（`:6787` 起）同时被 migrate-exit 的同机分支使用（`:6954`、`:8752`、`:8773`）。

兼容规则（compatibility.md §3）：删除参数 / 子命令只能在主版本做，且至少在一个次版本里废弃过——1.5.0、1.6.0、1.7.0 三个次版本都保留了它们。用户 2026-10-06 决定：1.7.0 之后发 2.0.0 删除这些写法，被调用时退出 2 并给出新写法。

## 2. 目标 / 非目标

目标：

1. 上述三类旧写法被调用时退出 2，stderr 一行说明“已在 2.0 移除”并给出对应新写法（两种语言，沿用 1.7.0 的 `L`）。
2. 参考文档、手册、README、帮助去掉“已废弃仍可用”的描述；兼容承诺改写为 2.x，并列出 2.0 移除项与替代写法。
3. 已有部署升级到 2.0.0 无需任何操作：本机与服务器上的所有持久文件、机器可读输出、其余命令与参数不变。

非目标：

- 不删 `direct/subctl` 文件：它仍是 `ownexit direct` 日常操作的实现。
- 不改 `rehost_exit_body` 等 migrate-exit 共用的内部函数，不改 `rehost=noop` 输出行。
- 不改任何其它接口（不借主版本顺带改名、改格式）。

## 3. 假设与约束

- `OWNEXIT_VIA_DIRECT` 是 `setup_direct.sh` 与 `direct/subctl` 之间的内部标记，2.0 起写进 compatibility.md §4“不承诺的内容”；设了它直接运行 `direct/subctl` 等同经 `ownexit direct` 进入，不视为公开用法。
- 移除提示不冻结（属日志文字）；冻结的是退出码 2。
- 打包：`pyproject.toml:47` 的 package-data 继续带上 `subctl`（仍被 direct 调用）。

## 4. 涉及模块

| 区域 | 锚点（基线 main 6cf9a18） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `direct/setup_direct.sh` | `deprecated()` 与 `DEPRECATED_MSGS`（201-205）；主循环 248-257；打印处 276；usage 两份中的“已废弃写法”段（中 179-181 附近、英 123-126 附近） | 修改 | 六个旧参数分支改为调用新的 `removed_flag`（退出 2）；删除 `deprecated()`、`DEPRECATED_MSGS` 与打印；usage 改为“2.0 已移除”说明 |
| `direct/subctl` | source `target_lib.sh`（96）之后、主循环（约 103）之前；132-140 废弃提示与注释；usage 两份 | 修改 | 未设 `OWNEXIT_VIA_DIRECT=1` 时在解析参数之前退出 2 并给出新写法；删 133-140；usage 改为 `ownexit direct` 日常操作的写法，不再写“已废弃” |
| `src/ownexit/cli.py` | `COMMANDS`（23-30）、`_GROUPS` 上方注释（32）、`main` 的命令查找（约 245-252） | 修改 | `COMMANDS` 删 `subctl`；新增 `_REMOVED = {"subctl": <脚本路径>}`：入口仍把 `subctl` 转给 `direct/subctl`（不带内部标记），由脚本按语言打印移除提示并退出 2；不在帮助里出现 |
| `chain/setup_chain.sh` | 头部注释 11-14；usage 中英两份的 rehost-exit 行（201、254-256、348、389-390）；`is_chain_subcommand`（768）；`parse_args` 开头（773）与 817 的分支；`rehost_exit_chain`（6771-6782）；分派 9470-9472；6543、6784、7229、7813 注释 | 修改 / 删除 | `parse_args` 开头识别 `rehost-exit`（`$1`，或 `--config/--id` 之后的 `$3`）即退出 2 并给出 `migrate-exit --to <新 IP>`；从两处词表与分派删去 `rehost-exit`；删除只剩它一个调用方的 `rehost_exit_chain`；注释改为只提 migrate-exit |
| `scripts/check_interface.sh` | 头注释 10；第 2 项 pair 列表（139）；第 3 项（146-149） | 修改 / 删除 | 去掉 subctl 的参数与子命令比对（`ownexit subctl` 节随之删除）；项数 23 → 21 |
| `.github/workflows/ci.yml` | lint 的 Help output（47-62）、package 的 Install and run（83） | 修改 | 两处循环（47-53 的 --help / 未知参数、55-61 的 en/zh 帮助检查）都去掉 `direct/subctl`，54 行注释“7 个入口脚本”改为 6 个；其后补一条 `direct/setup_direct.sh status --help` 的 en/zh 检查（subctl usage 经它显示，退出 0）；新增“已移除写法退出 2”断言（direct 六参数之一、`direct/subctl status`、chain rehost-exit）；26 行注释“1.x 冻结”改为 2.x；package 的子命令循环（83）去掉 `subctl`，断言 `ownexit subctl status` 退出 2 |
| `docs/reference/commands.md` / `.en.md` | direct 节（24-75）、`## ownexit subctl` 节（80 起）、chain 子命令表 rehost-exit 行（190）、退出码 5 行（207）、`rehost=noop` 行（272） | 修改 / 删除 | direct 子命令表去掉“同 --xxx / 同 subctl”括注；参数表六行改为“2.0 已移除：退出 2，提示改用 `<子命令>`”（参数仍被脚本识别，第 2 项比对需要这些行）；日常操作的退出码写进 direct 节；删除 subctl 节；chain 删 rehost-exit 行与退出码说明中的它；`rehost=noop` 只列 migrate-exit；233boy 旧版行的 `--migrate` 改为 `migrate` |
| `docs/reference/compatibility.md` / `.en.md` | 标题、§1-§3、§3a、§4（46-47 行）、§5（57 行） | 修改 | 承诺改写为 2.x；§3a 改为“2.0 移除的写法”表（旧写法、替代写法、退出码 2）；§4 内部脚本清单加入 `direct/subctl`、内部变量加入 `OWNEXIT_VIA_DIRECT`，46 行“直连与 subctl 的 `[*]`…行”改为“直连的”；§5 写明 2.x 读取 1.x 写下的全部持久文件、升级无需重新部署，并补“1.x 中断的 rehost-exit：升级前重跑它，或升级后用 `migrate-exit --to <配置中的 EXIT_HOST>` 续上” |
| `docs/reference/files.md` / `.en.md` | 133 行 | 修改 | “`--migrate` 前”改为“`migrate` 前” |
| `docs/manual/direct.md` / `.en.md` | 136 行（英文版对应行） | 修改 | 旧写法说明改为“2.0 起已移除，调用时退出 2 并提示新写法” |
| `chain/README.md` / `.en.md` | 266 行（英文版对应行） | 修改 | 删除 rehost-exit 旧写法一句，改为“2.0 已移除，用 migrate-exit” |
| `direct/README.md` / `.en.md` | 16-30 | 修改 | `subctl` 一行改为“`ownexit direct` 日常操作的实现，不能直接运行” |
| `README.md` / `README.zh-CN.md` | 安装节对照表的 subctl 行（中 92、英对应行）；130 行“旧写法…1.x 里照常可用”一句；163 行稳定性一节 | 修改 / 删除 | 删去 subctl 行与 130 行的旧写法一句；163 行按 §5.1.5 改为 2.x 承诺 |
| `chain/README.md` / `.en.md` | 284 行（英文 286 行）迁移进行中拒绝执行的命令清单 | 修改 | 清单里删去 `rehost-exit` |
| `docs/reference/` 全部 6 份与 README 两份中的 “1.x” 字样 | 全集由 `grep -n '1\.x\|1\.y' docs/reference/*.md README.md README.zh-CN.md` 枚举（基线 32 处，含 commands / files 标题“（1.x 冻结）”、files.md 44 / 64 / 68 行、compatibility 全文） | 修改 | 按 §5.1.5 统一改写 |
| `docs/reference/compatibility.md` / `.en.md` §6 | 62 行（英文对应行） | 修改 | check_interface 比对清单里删去 subctl（“direct / connect / doctor / multi / chain 的长参数；direct / multi / chain 的子命令”） |
| 注释：`direct/setup_direct.sh` 17、39、45、461、658、997；`direct/direct_remote.sh` 122；`scripts/check_interface.sh` 2-3、10 | 各行 | 修改 | 注释里的旧参数改为子命令写法（如“迁移（migrate）”）；check_interface 头注释的“1.x 接口冻结”改为 2.x、子命令清单删 subctl |
| `CHANGELOG.md` / `src/ownexit/__init__.py` | | 修改 | 2.0.0，Removed 一节写清每个旧写法的替代写法与“升级无需操作” |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 direct 六个旧参数

主循环里六个分支（含 `--add-device=*`、`--remove-device=*`）改为调用 `removed_flag "<旧参数>" "<新写法>"`：

```text
removed_flag() { die_usage "$(L "$1 已在 2.0 移除，改用：ownexit direct $2" "$1 was removed in 2.0; use: ownexit direct $2")"; }
```

- 退出码 2：复用现有的参数错误函数 `die_usage`（定义在 `direct/target_lib.sh:15`，`setup_direct.sh:219`、`:272` 等处同用，退出 2；`direct/subctl` 也 source 了它）；`die` 固定退出 1，不用它。
- `--add-device` / `--remove-device`：`$# ≥ 2` 且 `$2` 不以 `-` 开头时视为给了名字，新写法带上它（`add-device phone`）；`=` 形式取等号后的值（为空同“没给”）；没给时写 `add-device <名>`。不校验名字合法性——直接报移除。
- 在主循环里遇到即退出，先于互斥校验，保证不管和什么参数组合都得到同一条提示。

#### 5.1.2 subctl 直接调用

`direct/subctl` 在 source `target_lib.sh`（`:96`）之后、主循环（约 103 行）之前插入（提示用 `die_usage`，退出 2，它要等 `target_lib.sh` source 之后才有）：

```text
if OWNEXIT_VIA_DIRECT != 1:
  在参数里找第一个 login|start|stop|status|log|qr|devices|help|-h|--help（找不到 = login）
  start/stop → "sub start" / "sub stop"；help/-h/--help → "--help"；其余同名
  stderr: "[!] ownexit subctl 已在 2.0 移除，改用：ownexit direct <新写法>"，exit 2
```

提示只给子命令的新写法，不带用户原来写的 `--host` 等参数（与 1.x 废弃提示一致，有意为之：用户把旧参数照搬到新写法即可）。删除原 132-140 的废弃提示与注释。

`cli.py` 不再把 `subctl` 列为命令，但对 `ownexit subctl …` 仍执行 `direct/subctl`，由脚本统一给出提示，避免两处文案：

- 新增单行字典 `_REMOVED = {"subctl": os.path.join("direct", "subctl")}`，值不加括号——`check_interface.sh:134` 第 1 项按 `^    "<name>": \(` 提取 COMMANDS，带括号的四空格缩进写法会被误抽。
- 转发 `_REMOVED` 里的命令时 `env.pop("OWNEXIT_VIA_DIRECT", None)`，避免用户环境里残留的内部标记让旧入口照常执行。

#### 5.1.3 chain rehost-exit

`parse_args` 最开头：`"${1:-}" == rehost-exit`，或 `$1` 为 `--config` / `--id` 且 `"${3:-}" == rehost-exit` 时（`set -u` 下必须带 `:-`，`--config <p>` 只有两个参数时 `$3` 未绑定），设 `COMMAND=rehost-exit`（日志前缀需要）后：

```text
die 2 "$(L "rehost-exit 已在 2.0 移除：改用 migrate-exit --to <新 IP>（同一台机器会自动识别，不必手改配置）" "rehost-exit was removed in 2.0; use migrate-exit --to <new IP> (the same machine is detected automatically; no need to edit the configuration)")"
```

放在配置解析之前，所以没有配置、有多条链时也给同一条提示。`die 2` 的退出码不会被按命令改写（`setup_chain.sh:469`），且 `parse_args` 在 `init_runtime` 与各 trap 之前执行（`:9403`）。

1.x 里中断的 `rehost-exit`（配置已改成新 IP、state 仍是旧 IP）在 2.0 下用 `migrate-exit --to <配置里的 EXIT_HOST>` 续上：`setup_chain.sh:8765-8775`（`rc==12` 且 `EXIT_HOST==MIGRATE_TO`）走同机续跑分支，已切换完成时 `:8749-8753` 输出 `rehost=noop`。compatibility.md §5“升级前先收敛未完成的操作”与 CHANGELOG 写明这一点。

#### 5.1.4 帮助

- direct usage 的“已废弃写法”段改为“2.0 已移除（调用时退出 2 并提示新写法）”，列出旧写法 → 新写法对照。
- chain usage 删 rehost-exit 两行。
- subctl usage（经 `ownexit direct status --help` 等显示）改写为 `ownexit direct` 的日常操作说明。

#### 5.1.5 文档里的 “1.x” 改写规则

- “1.x 冻结 / 1.x 内只增不减” → “2.x 冻结 / 2.x 内只增不减”；compatibility.md 开头说明 1.x 的承诺到 1.7.0 为止，2.0 只移除 §3a 所列写法。
- “1.y 能读 1.x 写下的…” → “2.x 能读 1.x 与 2.x 写下的…”（持久文件格式没有变化）。
- “不兼容改动只在 2.0 做” → “只在 3.0 做”；README 稳定性一节同改。
- 历史事实（如“1.5.0 起”“从 1.0.0 起”）保留；代码注释里描述历史行为的 1.x 表述（如 `chain/setup_chain.sh:755`“init --help 按 1.x 已冻结的描述仍退出 2”）保留不改。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit direct --rotate-keys` / `--rotate-token` / `--add-device` / `--remove-device` / `--migrate` / `--uninstall` | 删除（识别后退出 2） | 不兼容，主版本；替代写法 1.5.0 起可用 |
| `ownexit subctl` 及直接运行 `direct/subctl` | 删除（退出 2） | 同上 |
| `ownexit chain rehost-exit` | 删除（退出 2） | 同上 |
| `OWNEXIT_VIA_DIRECT` | 写明为内部标记 | 不承诺 |
| 其余命令、参数、退出码、机器可读输出、文件 | 不变 | 兼容 |

**reference sibling 回补检查**（按 §"方案文档章节内容质量要求" §5）：

- Q1 涉及 reference 章节：`docs/reference/commands.md` §`ownexit direct`（参数、子命令、退出码）、§`ownexit subctl`（整节删除）、§`ownexit chain` 子命令表与退出码、机器可读输出 `rehost=noop` 行；`compatibility.md` §3a、§4、§5；`files.md` 233boy 备份行。英文版同节。
- Q2 源码暴露面完整性：`scripts/check_interface.sh` 现 23 项全过（1.7.0 发版时实测），参数、子命令、status 取值、键与文件名由它机读比对；本次改动后它仍须全过（项数 21）。
- Q3 本方案是否回补：N/A——本次是删除暴露面，删除与文档同步落地。
- Q4 placeholder 落地：N/A。

## 6. 备选方案与决策

- 旧参数直接删掉、落到“未知参数”报错：提示里没有新写法，用户要自己查；用户已决定“报错并给出新写法”，否决。
- 删除 `direct/subctl`、把日常操作搬进 `setup_direct.sh`：改动大，属重构，且无功能收益；否决。
- `cli.py` 自己打印 subctl 移除提示：要在 Python 里再写一份中英文案与新写法映射，与脚本重复；否决，改为转给脚本。

## 7. 影响分析

- **正向**：
  - `removed_flag` 只在六个旧参数分支调用，其余分支不变；删除 `deprecated()` 后 `DEPRECATED_MSGS` 无其它读者（`setup_direct.sh` 内只在 204-205、276 出现）。
  - `forward_to_subctl` 仍带 `OWNEXIT_VIA_DIRECT=1`（`:231`），所以 `ownexit direct sub|status|log|qr|devices|login` 行为不变，包括 `ownexit direct status --help` 显示 subctl usage。
  - `doctor.sh` 不调用 subctl（只在 353 行注释里提到），不受影响；`target_lib.sh` 的注释提到 subctl，行为不变。
  - `rehost_exit_chain` 只有 9472 一个调用方，删除安全；`rehost_exit_body` 保留，migrate-exit 的同机分支（6954、8752、8773）不受影响，`rehost=noop` 输出仍由它打印。
  - `is_chain_subcommand` 去掉 `rehost-exit` 后，`chain rehost-exit` 已在 `parse_args` 开头被拦下，不会走到“首个参数必须是…”的通用报错。
- **反向**：
  - 有没有别的脚本或文档链路调用旧写法？v1.5.0 起各脚本给出的“下一步”提示都是新写法（1.7.0 已全部翻译核过）；本方案按 §4 用无截断 grep 全集核对仓库内所有旧写法引用（`docs/feature/` 与 CHANGELOG 是历史记录，不改）。
  - 用户自己的脚本、别名、文档里写着旧写法：升级后退出 2 并告诉新写法——这是本次的预期不兼容点，CHANGELOG 与 compatibility.md 写明。
  - Homebrew / pipx 用户：`ownexit subctl` 退出 2；`ownexit --help` 本来就不列 subctl（1.5.0 起）。
- **运行时**：只在参数解析阶段多一次判断，无新进程、无网络、无文件读写。
- **部署形态**：服务器上的文件、单元、订阅不变；已部署的直连与链升级后照常 `status` / `verify` / 日常操作。
- **对外语义**：退出码 2 的含义（参数错误）不变，只是覆盖了这几个旧写法。

## 8. 回归测试

本机 Lima 三台 Ubuntu 22.04 arm64（中转 R、出口 E、直连 D，1.7.0 测试留下的虚拟机）。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| R1 | 六个旧参数各单独调用一次，另各与 `--host x`、`up` 组合一次；`--add-device phone`、`--add-device=phone`、`--add-device`（无名）、`--add-device --host x` | 全部退出 2；stderr 含“已在 2.0 移除”与对应新写法（带名字时带上名字）；中英两种语言各一轮 |
| R2 | `ownexit subctl`、`ownexit subctl status`、`ownexit subctl start --ttl 30m`、`ownexit subctl --help`、`OWNEXIT_VIA_DIRECT=1 ownexit subctl status`；`bash direct/subctl stop` | 全部退出 2，新写法分别为 `login` / `status` / `sub start` / `--help` / `status` / `sub stop` |
| R3 | `chain rehost-exit`（本机 0 条链）、`chain --id main rehost-exit`、`chain --config <路径> rehost-exit` | 退出 2，提示 migrate-exit；不读取配置 |
| R4 | 1.7.0 部署的直连 D 上：`ownexit direct status`、`sub start --ttl 5m`、`sub stop`、`log 5`、`devices`、`rotate-token`、`add-device phone`、`remove-device phone`、`status --help` | 与 1.7.0 行为相同，退出 0（`status --help` 显示日常操作帮助） |
| R5 | 链 R→E 先用 1.7.0（main 6cf9a18 的脚本）部署，再用 2.0 跑 `status`、`verify`、`rotate-keys`、`migrate-exit --to <同机新地址>` | `status=deployed health=healthy`；`rotate=done`；`migrate=rehosted`；同机切换主体不受删除 `rehost_exit_chain` 影响 |
| R5b | 在同一条 1.7.0 部署的链上模拟 1.x 中断的 rehost-exit：给出口机再加一个地址，按旧写法手改配置的 EXIT_HOST / EXPECTED_EXIT_IPV4 并补 known_hosts，不跑 rehost-exit；然后 `migrate-exit --to <该新地址>` | `migrate=rehosted`（或已完成时 `rehost=noop`），随后 `status` healthy |
| R6 | `ownexit --help`、`ownexit direct --help`、`ownexit chain --help` 中英 | 不再出现“已废弃仍可用”；direct 帮助列出 2.0 移除对照 |
| R7 | 由 1.7.0 写下的本机配置 / 状态与服务器文件，用 2.0.0 管理（直连由 R4、链式由 R5 / R5b 覆盖：两者都是 1.7.0 部署、2.0 管理） | 不需要重新部署或重新导入 |
| S1 | `bash -n` / `/bin/bash -n` / shellcheck、`check_interface.sh`（21 项）、`check_i18n.sh`、`check_ui_lang.sh`、`check_public.sh`、CI | 通过 |
| S2 | 仓库内旧写法全集复核：`grep -rnE -- '--rotate-keys|--rotate-token|--add-device|--remove-device|--migrate\b|--uninstall|subctl|rehost-exit'`（排除 `docs/feature/`、CHANGELOG 历史条目），不接截断 | 剩余命中只有：移除处理代码与其提示、参考文档“2.0 已移除”说明、subctl 作为内部实现的描述（含其文件路径出现在 CI / CONTRIBUTING 的 `bash -n`、shellcheck 清单与 pyproject package-data 里）；§4 已列的注释都已改写 |

## 9. 日志 / 观测点

全部写成 `L "中文" "English"`（`scripts/check_ui_lang.sh` 检查），退出 2：

- direct：`[!] <旧参数> 已在 2.0 移除，改用：ownexit direct <新写法>` / `[!] <old flag> was removed in 2.0; use: ownexit direct <new form>`。
- subctl：`[!] ownexit subctl 已在 2.0 移除，改用：ownexit direct <新写法>` / `[!] ownexit subctl was removed in 2.0; use: ownexit direct <new form>`。
- chain：`[chain][rehost-exit] ERROR rehost-exit 已在 2.0 移除：改用 migrate-exit --to <新 IP>…` / `[chain][rehost-exit] ERROR rehost-exit was removed in 2.0; use migrate-exit --to <new IP> …`。
