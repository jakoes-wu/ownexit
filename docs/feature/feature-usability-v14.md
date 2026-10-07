# v1.4.0：零决策上手（向导、Homebrew 一行安装、订阅自动关闭、换出口机单一入口）

## 1. 背景

- 新用户第一次用要先弄懂“直连 / 链式”再选命令；`ownexit` 不带参数只打印帮助（`src/ownexit/cli.py:100-104`）。
- 安装要先装 pipx、`pipx ensurepath`、新开终端，再 `pipx install ownexit`；终端二维码还要另装 qrencode（`README.zh-CN.md:55-70`）。
- 直连订阅服务导入后要手动 `ownexit subctl stop`（`direct/setup_direct.sh:1075`）；忘了就一直开着明文 HTTP 端口。
- 出口机变化有两条命令：`rehost-exit`（同一台机器换 IP）与 `migrate-exit`（换机器），手册里并列（`docs/manual/chain.md:94-96`）。用户要先判断是哪种。
- 用户 2026-10-06 拍板：终端里只敲 `ownexit` 进向导；`--sub-ttl` 默认不自动关闭；Homebrew 安装顺带装 qrencode；homebrew-tap 仓库可直接用 gh 建。

## 2. 目标 / 非目标

目标：

1. `ownexit` 在终端里不带参数时进入向导：先问“在你这里能直接连上这台 VPS 吗”，据此走直连（问 1 个 IP）或链式（问中转、出口 2 个 IP），最后执行 `ownexit direct --host …` 或 `ownexit chain up --relay … --exit …`。
2. Homebrew 一行安装：新建公开仓库 `jakoes-wu/homebrew-tap`，配方 `ownexit` 依赖 Python 与 qrencode，装好后 `ownexit` 可直接用。
3. 直连订阅服务可选自动关闭：`ownexit direct --sub-ttl <时长>`、`ownexit subctl start --ttl <时长>`，到时在 VPS 上自动 `systemctl stop`；默认不变（不自动关闭）。
4. 换出口机只教一个入口：手册与帮助统一写“出口机变了 → `migrate-exit --to <新 IP>`”；同一台机器只换了 IP 时它会明确提示改用 `rehost-exit`（`migrate-exit` 两处报错，基线 `chain/setup_chain.sh:7886` / `:7914`，都改为指向 rehost-exit），文档把这一步写成决策提示而不是并列两条命令。

非目标：

- 不改 `rehost-exit` / `migrate-exit` 的行为与命令名（1.x 冻结；合并归 2.0）。
- 向导不覆盖设备管理、迁移等维护操作；非终端运行 `ownexit` 不带参数仍打印帮助。
- 不做 Homebrew 官方 core 收录；不做 Linuxbrew 专门适配（配方本身跨平台，Linux 未实测）。

## 3. 假设与约束

- 向导用 Python 标准库 `input()` 实现，在 `cli.py` 里；`sys.stdin.isatty() and sys.stdout.isatty()` 都为真才进向导。IP 校验按 `chain/setup_chain.sh` 的 `is_ipv4`（基线 746-762 行）移植（四段 0-255、无前导零；直连脚本自己只做宽松校验）；SSH 端口默认 22，向导里可回车跳过。向导结束用 `os.execve` 调对应脚本（与现有转发同一路径，`OWNEXIT_PYTHON` 照常注入）。测试钩子 `OWNEXIT_TEST_WIZARD_PRINT=1`：只把将要执行的参数打印到 stdout 并退出 0，不执行（`OWNEXIT_TEST_` 前缀不冻结）。
- 自动关闭用 VPS 上的 `systemd-run --collect --unit=ownexit-subscription-ttl --on-active=<秒> --timer-property=AccuracySec=1s --timer-property=RemainAfterElapse=no /bin/systemctl stop ownexit-subscription`（瞬时 timer，不落盘；`AccuracySec=1s` 让到点误差在秒级，`RemainAfterElapse=no` + `--collect` 让触发后单元被卸载、不挡下一次同名 `systemd-run`，与 chain 的 fail-closed watchdog 写法一致）。VPS 重启后计时器消失、订阅服务按 enabled 重新起来并一直开着——这一点写进手册。单元名 `ownexit-subscription-ttl` 自本版起冻结（`files.md` 登记）。每次 start / 部署先 `systemctl stop ownexit-subscription-ttl.timer` 清掉旧计时；`subctl stop` 也一并清。时长格式 `<正整数>[smh]`，范围 60 秒到 24 小时。
- Homebrew 配方：`Language::Python::Virtualenv`，`depends_on "python@3.14"`（2026-10-06 `brew info python3` 核实为 Homebrew 当前默认 Python；以后默认版本变了随之更新）、`depends_on "qrencode"`；resources 用 `brew update-python-resources` 生成（pexpect、ptyprocess，以及构建后端若需要的 setuptools / flit-core 等），不手抄；`url` 指向 PyPI 上 `ownexit-<版本>.tar.gz`。所以 tap 在 1.4.0 上 PyPI 之后再创建 / 更新配方；上 PyPI 之前先用本地 `python -m build` 出的 sdist（`file://` url）在本机试装一次，配方问题不拖到发版后才发现。`test do` 跑 `ownexit --version` 与 `ownexit direct --help`。
- 测试床：本机 Lima 一台 Ubuntu 22.04 arm64（直连 D）测 `--sub-ttl`；向导用本机 pexpect 驱动终端测；Homebrew 在本机 macOS 实装实测（装后卸载，恢复原状）。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main 4f61b31） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `src/ownexit/cli.py` `main` | 102-104（无参数分支） | 修改 | 无参数且 stdin / stdout 都是终端 → `_wizard()`；否则照旧打印帮助 |
| `src/ownexit/cli.py` 新函数 `_wizard`、`_is_ipv4`、`_ask`、`_ask_port` 与文案 `_WIZARD` | `_usage`（84-97）之后 | 新增 | §5.1.1 |
| `src/ownexit/cli.py` `_TEXT` | 帮助文案 | 修改 | 中英文帮助加一行“只敲 ownexit 进入向导” |
| `direct/setup_direct.sh` 参数 `case` | 129-150 | 修改 | 新参数 `--sub-ttl` / `--sub-ttl=*`；格式校验；与 `--uninstall` 互斥 |
| `direct/setup_direct.sh` `usage` | 69-118 | 修改 | 补 `--sub-ttl` 说明与示例 |
| `direct/setup_direct.sh` 卸载分支 | 554 `LEFTOVER_STATE` 之后、`start_op uninstall` 之前 | 修改 | 远端清掉计时器 |
| `direct/setup_direct.sh` 启用订阅服务 | 987 远端 heredoc `systemctl restart '${SUB_SERVICE}'` 之后 | 修改 | 先停旧计时器；给了 `--sub-ttl` 时 `systemd-run` 一个计时器 |
| `direct/setup_direct.sh` 交付块 | 1075 下一步第 3 条、1094 后续步骤第 4 条、1098 新设备一条 | 修改 | 按是否设了时长改文字（§5.1.2） |
| `direct/target_lib.sh` | 文件末尾追加 | 新增 | `parse_ttl`、`ttl_remote_cmd` |
| `direct/subctl` 参数解析 | 54-70 | 修改 | 新参数 `--ttl` / `--ttl=*`（只对 `start` 有效） |
| `direct/subctl` `start` / `stop` | 108-114 | 修改 | start 先停旧计时器，带 `--ttl` 时起计时器并提示关闭时刻；stop 一并停计时器 |
| `direct/subctl` `status` | 116-127 远端 heredoc | 修改 | 计时器在跑时多打一行“自动关闭剩余时间” |
| `direct/subctl` `usage` | 18-43 | 修改 | `start [--ttl <时长>]` 与示例 |
| `docs/reference/commands.md` | `## ownexit（入口）`（含第 18 行入口退出码：加向导的 130 / 1）、`## ownexit direct` 参数表、`## ownexit subctl` 参数表、环境变量节说明 | 修改 | 入口加“终端里不带参数进向导”；direct 加 `--sub-ttl`；subctl 加 `--ttl` |
| `docs/reference/files.md` | 直连（服务器）表 | 修改 | 加 `ownexit-subscription-ttl.timer`（瞬时单元，只在设了时长时存在） |
| `README.md` / `README.zh-CN.md` | 安装节、前置条件节 | 修改 | 安装首推 `brew install jakoes-wu/tap/ownexit`（macOS），pipx 作为通用方式；加“只敲 ownexit 进向导”；直连收尾加 `--sub-ttl` 一句 |
| `docs/manual/chain.md` | 94-96（§7） | 修改 | 改成“出口机变了”单一入口：`migrate-exit --to`，同机换 IP 时按提示用 `rehost-exit` |
| `chain/README.md` | 104-110 命令示例、257-280 两节开头 | 修改 | 同上口径；两节保留，开头加一句先用 migrate-exit |
| `chain/setup_chain.sh` `usage` | 228 “维护”组 `rehost-exit` 之前（`rotate-keys` 之后） | 修改 | 加一行“出口机变了，先用 migrate-exit；同一台机器只换了 IP 时它会提示改用 rehost-exit” |
| `chain/setup_chain.sh` `migrate-exit` | 7886、7914 | 修改 | 报错文字指向 rehost-exit（§5.1.4），退出码不变 |
| `docs/manual/direct.md` | 订阅服务 / 日常维护段 | 修改 | 加 `--sub-ttl` / `subctl start --ttl` |
| `CHANGELOG.md` / `src/ownexit/__init__.py` | | 修改 | 1.4.0 |
| 仓库 `jakoes-wu/homebrew-tap` | 新仓库 | 新增 | `Formula/ownexit.rb`、`README.md`（MIT） |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 向导（`cli.py`）

```text
ownexit 向导（随时 Ctrl+C 退出）

在你这里能直接连上这台 VPS 吗？（大多数海外 VPS 在国内连不上或很慢，就选 2）
  1) 能 —— 直连，1 台 VPS
  2) 不能 —— 链式，前面加一台中转机，共 2 台
请选择 [1/2]:
```

- 选 1：问 `VPS 的公网 IPv4:`、`SSH 端口 [22]:` → 参数 `direct --host <IP> [--port N]`。
- 选 2：问中转机 IPv4 与端口、出口机 IPv4 与端口 → 参数 `chain up --relay <IP> --exit <IP> [--relay-port N] [--exit-port N]`；两个 IP 相同时重问。
- 输入非法重问；Ctrl+C 打印“已取消”退出 130；输入结束（Ctrl+D / EOF）打印“已取消”退出 1。
- 直连只问 IPv4：`direct --host` 本身接受 IPv6 / 域名，需要时直接敲命令；向导面向首次使用者，只覆盖最常见的形态。
- 选 2 时最终执行 `chain up`：若已存在部署 ID `main`，由 `chain up` 自己按现有规则报错 / 提示（向导不预判）。
- 执行前打印一行“即将运行：ownexit <参数>”；`main` 里 `args = _wizard()` 之后不另起分支，直接落入原有的子命令查找与 `execve` 转发（`OWNEXIT_PYTHON` 照常注入）。`OWNEXIT_TEST_WIZARD_PRINT=1` 时只打印参数列表（每个参数一行）并退出 0。
- 文案按 `_lang()` 中英两套。

#### 5.1.2 订阅自动关闭

- 时长解析（直连与 subctl 共用同一段 bash，放在 `direct/target_lib.sh`，两个脚本已 source 它）：`parse_ttl <值>` → 秒数；`^([1-9][0-9]{0,5})([smh]?)$`（最多 6 位数字，防整数溢出；无单位按分钟），换算后须在 60–86400，否则 `die_usage`。
- 远端命令（直连在启用订阅服务的 heredoc 里，subctl 的 start 里）：

  ```text
  systemctl stop ownexit-subscription-ttl.timer 2>/dev/null || true
  systemctl reset-failed ownexit-subscription-ttl.timer ownexit-subscription-ttl.service 2>/dev/null || true
  systemd-run --quiet --collect --unit=ownexit-subscription-ttl --on-active=<秒> \
    --timer-property=AccuracySec=1s --timer-property=RemainAfterElapse=no \
    /bin/systemctl stop ownexit-subscription   # 仅在给了时长时
  ```

  `subctl stop` 执行前两行再 `systemctl stop ownexit-subscription`。
- subctl status：取 `systemctl list-timers ownexit-subscription-ttl.timer --no-legend` 的“剩余时间”列（如 `29min left`），非空时多打一行 `订阅服务自动关闭 : <剩余时间>`。不用 `NextElapseUSecRealtime`：`--on-active` 是单调时钟计时器，该属性为 0。
- 卸载（`direct --uninstall`）：在 `start_op uninstall` 之前远端先执行上面前两行，清掉计时器，避免卸载后它到点去停已不存在的服务留下失败单元。
- 交付块：“下一步”第 3 条（基线 1075，原文“所有设备导入后关掉订阅服务：ownexit subctl stop（以后加设备先 start 再 stop）”）与“后续人工步骤”第 4 条（基线 1094）共用变量 `SUB_CLOSE_HINT`，随是否设了时长变化——设了时长：“订阅服务将在 <时长> 后自动关闭，到时请先导入完”；没设：两处统一用 1.3.0“后续人工步骤”第 4 条的文字“所有设备都导入后，关掉订阅服务缩小暴露面：ownexit subctl stop”。新设备一条统一为“ownexit subctl start --ttl 30m（到时自动关闭），或先 start、导入后再 stop”。

#### 5.1.3 Homebrew tap

- 1.4.0 上 PyPI 后：`gh repo create jakoes-wu/homebrew-tap --public --description "Homebrew formulae for ownexit"`；提交 `Formula/ownexit.rb`：

  示例；资源与 Python 版本以 §3 中 `brew update-python-resources` 生成的结果和 `brew info` 核实的版本为准：

  ```text
  class Ownexit < Formula
    include Language::Python::Virtualenv
    desc "Turn a VPS you rent into your own fixed exit IP"
    homepage "https://github.com/jakoes-wu/ownexit"
    url "<PyPI ownexit-1.4.0.tar.gz>"; sha256 "<…>"
    license "MIT"
    depends_on "python@3.14"
    depends_on "qrencode"
    resource "ptyprocess" do url/sha256 end
    resource "pexpect" do url/sha256 end
    def install; virtualenv_install_with_resources; end
    test do
      assert_match version.to_s, shell_output("#{bin}/ownexit --version")
      system bin/"ownexit", "direct", "--help"
    end
  end
  ```

- 实测前记录 `brew list --formula` 与 `brew list --cask` 到工作目录，全程 `HOMEBREW_NO_AUTO_UPDATE=1`；结束后对比，新装的依赖（含 qrencode、python@3.x）全部卸载，恢复到记录状态。
- 本机实测：`brew install jakoes-wu/tap/ownexit` → `ownexit --version`、`ownexit doctor --local-only` 认出 pexpect、`brew test ownexit`、`brew audit --strict jakoes-wu/tap/ownexit`（只看错误）→ `brew uninstall ownexit && brew untap jakoes-wu/tap`。qrencode 若是本次新装的，一并卸载，恢复原状。
- 本机已有的 pipx 版 ownexit 与 brew 版二者的 `ownexit` 会争 PATH：实测时用 `$(brew --prefix)/bin/ownexit` 绝对路径调用，不动 pipx 版。

#### 5.1.4 换出口机单一入口（文档 + 帮助文字）

手册 `chain.md` §7 改为：

```text
## 7. 出口机变了

出口机换了 IP 或换了一台机器，都不要 rollback 再 deploy。入口统一是 migrate-exit --to <新 IP>，它按现场告诉你下一步：
- 换了机器，旧机器还能登录：直接迁移，客户端不用动。
- 还是同一台机器、只是 IP 变了（旧 IP 多半已连不上；若旧 IP 仍能登录，它会先为新 IP 配免密、要输一次 root 密码，再比较指纹给出提示）：提示改用 rehost-exit（先改 EXIT_HOST / EXPECTED_EXIT_IPV4、补 known_hosts 的 ed25519 条目）。rehost-exit 不需要旧 IP 可达。
- 换了机器，旧机器已登录不了：私钥只在旧机器上，只能 rollback + deploy。
```

同机换 IP 时 `migrate-exit` 有两条路径到达提示，都要指向 `rehost-exit`：

- 旧 IP 已失效（最常见）：在登录旧出口机这一步就失败（基线 `chain/setup_chain.sh:7886`，退出 3）。基线文字只说“改用 rollback + deploy”，会把同机换 IP 的用户引去重建凭据；改为先说“若还是同一台机器、只是 IP 变了：改用 rehost-exit（含前置步骤）”，再说“确实换了机器且旧机器登录不了：rollback + deploy”。
- 旧 IP 仍可登录：走到新旧主机指纹比较（基线 `:7914`，退出 2），文字补上 rehost-exit 的前置步骤（改配置、补 known_hosts）。
- `--to` 等于当前 `EXIT_HOST`（基线 `:7877`）文字不变。

退出码不变，只改提示文字（报错文字不在冻结范围）。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit`（入口） | 终端里不带参数进入向导；非终端仍打印帮助 | 新增行为（原无参数输出不在冻结表内，`commands.md` 入口表只列 `-h / --help / help`） |
| `ownexit direct` | 新增 `--sub-ttl <时长>` | 新增 |
| `ownexit subctl` | 新增 `--ttl <时长>`（只对 start） | 新增 |
| 服务器单元 | 新增瞬时单元 `ownexit-subscription-ttl.timer/.service`（只在设了时长时存在） | 新增 |
| 环境变量 | `OWNEXIT_TEST_WIZARD_PRINT`（测试钩子，不冻结） | — |
| 外部仓库 | `jakoes-wu/homebrew-tap` | 新增 |

**reference sibling 回补检查**：
- Q1 涉及 reference 章节：`commands.md` §ownexit（入口）、§ownexit direct 参数、§ownexit subctl 参数；`files.md` §直连（服务器）。
- Q2 源码暴露面完整性：`check_interface.sh` 第 2 段比对 direct / subctl 长参数（新增 `--sub-ttl`、`--ttl` 必须进表）；入口行为与服务器单元人工核。
- Q3 本方案是否回补：是，同步落地。
- Q4 placeholder：N/A。

## 6. 备选方案与决策

- 向导做成独立子命令 `ownexit setup`：用户选了“只敲 ownexit”。
- 自动关闭用 VPS 上的 cron / at：要依赖额外软件；`systemd-run` 直连已在用（基线 `direct/setup_direct.sh:437` 用它跑部署事务），`--timer-property` 写法与 chain watchdog（基线 `chain/setup_chain.sh:5068`，预检 `:2087`）相同；直连预检不额外检查该选项——支持矩阵（Ubuntu 22.04+ / Debian 12+）的 systemd 都支持，万一不支持，`systemd-run` 报错使部署失败并显示原因，不会静默不关。
- `--sub-ttl` 默认 30 分钟：用户选默认不变。
- 合并 `rehost-exit` 到 `migrate-exit`：改语义，归 2.0；本版只统一文档入口。

## 7. 影响分析

- 入口无参数行为：只在交互终端变化；CI 与脚本调用（非终端）不变。`ownexit` 被管道调用时 stdin 非终端 → 照旧打印帮助。→ T1–T3。
- `--sub-ttl` 未给时：远端多执行两条 `stop` / `reset-failed`，对不存在的单元无副作用（`|| true`）；行为与 1.3.0 相同。→ T5、R1。
- `subctl stop` 多停一个 timer：不存在时无副作用。→ T6。
- `target_lib.sh` 新增 `parse_ttl`：只新增函数，两个调用方 source 后才用。
- Homebrew 版与 pipx 版并存：两者装的是同一份 PyPI 包，状态与配置目录相同（XDG），互不冲突；PATH 谁在前用谁。README 写明二选一。
- 文档入口统一：不改命令行为，`rehost-exit` 仍可直接用；`migrate-exit` 两处报错只改文字。→ R2、R3。
- 卸载多一次远端调用清计时器：失败忽略（`|| true`），不影响卸载事务。→ T10。
- VPS 重启：计时器丢失，订阅服务按 enabled 起来并一直开着（与 1.3.0 相同），手册写明。

## 8. 回归测试

本机 Lima 一台 Ubuntu 22.04 arm64（直连 D）。测完删除 Lima、卸载本次新装的 brew 包与 tap。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| T1 | pexpect 驱动终端运行 `OWNEXIT_TEST_WIZARD_PRINT=1 ownexit`，选 1，输入 `203.0.113.7`、回车 | 打印参数 `direct --host 203.0.113.7`，退出 0 |
| T2 | 同上选 2，中转 `203.0.113.10` 端口 `2222`，出口 `203.0.113.20` 回车；中途先输一个非法 IP 与一个和中转相同的出口 IP | 非法与相同均重问；最终参数 `chain up --relay 203.0.113.10 --exit 203.0.113.20 --relay-port 2222` |
| T3 | `ownexit < /dev/null`、`ownexit | cat` | 打印帮助、退出 0，不进向导；`LANG=C` 时英文 |
| T4 | 向导 Ctrl+C；向导 Ctrl+D | 打印“已取消”，分别退出 130、1 |
| T5 | `direct --host D --sub-ttl 2m` | 部署成功，交付块显示 2m 后自动关闭；`subctl status` 显示剩余时间；约 2 分钟后订阅端口不可达、代理服务仍 active |
| T6 | `subctl start --ttl 1m` → `subctl stop`；`start --ttl 1m` → 直接 `start`（不先 stop） | stop 后计时器不存在；不带 ttl 的 start 取消旧计时，90 秒后仍可达 |
| T6b | T5 触发后再 `subctl start --ttl 1m` | 同名单元可复用（无“unit already exists”），计时器存在 |
| T6c | 设了计时器后不带 `--sub-ttl` 重新部署 | 重部署后计时器不存在 |
| T7 | `--sub-ttl 30`（无单位=30 分钟）、`--sub-ttl 10s`、`--sub-ttl 25h`、`--sub-ttl abc`、`--sub-ttl 1m --uninstall` | 第 1 个接受且计时器约 30 分钟；后 4 个退出 2，报错文字分别含“1 分钟到 24 小时”“格式不对”“不能与” |
| T8 | `subctl --ttl 5m status` | 退出 2（`--ttl` 只对 start） |
| T9 | Homebrew：建 tap、`brew install jakoes-wu/tap/ownexit`、`brew test`、`$(brew --prefix)/bin/ownexit --version`、`doctor --local-only` 认出 pexpect 与 qrencode | 全部通过；随后卸载恢复 |
| R1 | 不带 `--sub-ttl` 的 `direct --host D`、`subctl start/stop/status` | 与 1.3.0 行为相同，无计时器 |
| R2 | `chain --help`、`docs/manual/chain.md` §7 | 文字为单一入口口径 |
| R3 | `bash -n` 后 grep `chain/setup_chain.sh` 两处 migrate-exit 报错 | 都含 rehost-exit；退出码 3 / 2 不变 |
| T10 | 设了计时器后 `direct --uninstall` | 卸载成功；计时器与其失败单元都不存在 |
| S1 | `bash -n`、`/bin/bash -n`、`shellcheck -S warning`、`check_interface.sh`、`check_public.sh`、CI | 通过 |

## 9. 日志 / 观测点

- 向导：`即将运行：ownexit <参数>`；取消时 `已取消`。
- 直连：`[+] 订阅服务将在 <时长> 后自动关闭`；subctl start：`[+] 已启动 ownexit-subscription，<时长> 后自动关闭`；status：`订阅服务自动关闭 : <剩余时间>`（list-timers 的 `… left`）。
- 服务器：`systemctl list-timers ownexit-subscription-ttl.timer`。
