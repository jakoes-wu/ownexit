# Changelog / 更新日志

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). From 1.6.0 each entry is in English and Chinese; earlier entries are Chinese only.

本项目的所有重要变更都记录在这里。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。1.6.0 起每个条目中英双语，此前的条目只有中文。

## [Unreleased]

## [2.3.1] - 2026-10-30

### Fixed / 修复

- Chains whose relay also runs an existing sing-box or a direct install no longer report a false "existing sing-box baseline changed" (deploy finishing with exit 4, `status` showing `reason=baseline`). The baseline used to include the service's start time and process id, which change after a restart or `systemctl daemon-reload`, and `ss` padding that changes when another program with a longer name starts listening. Only the command line and the listeners themselves are compared now.
- 中转上同时有既有 sing-box 或同机直连的链，不再误报“中转既有 sing-box 零回归基线发生变化”（部署收尾退出 4、`status` 报 `reason=baseline`）。原来的基线带上了服务的启动时间和进程号（重启或 `systemctl daemon-reload` 后会变），以及 `ss` 为对齐补的空格（别的长名字程序开始监听时会变）；现在只比较启动命令和监听本身。
- The Reality smoke test on the relay (run by deploy, verify, change-port and migrate-exit) no longer fails at random under load: it now waits up to 5 seconds for the test client to start instead of checking once right after launching it.
- 中转上的 Reality smoke 测试（deploy、verify、change-port、migrate-exit 都会跑）不再在负载下偶发失败：改为最多等 5 秒让测试客户端起来，而不是刚启动就只看一次。
- When a system update replaced `systemd-socket-proxyd` on the relay while the relay service kept running the old copy, `status` reported a vague `reason=remote-resource-unit-process-or-listener`. It now reports `status=drifted role=relay reason=relay-process-stale next=restart-relay-service`, and status / verify print which service to restart.
- 系统更新替换了中转上的 `systemd-socket-proxyd`、relay service 还在跑旧进程时，`status` 原来只报笼统的 `reason=remote-resource-unit-process-or-listener`；现在报 `status=drifted role=relay reason=relay-process-stale next=restart-relay-service`，status / verify 会提示要重启哪个服务。
- CI: the package job runs on `ubuntu-24.04`, because `ubuntu-latest` (26.04) has no Python 3.8 build.
- CI：package 任务改在 `ubuntu-24.04` 上跑，因为 `ubuntu-latest`（26.04）没有 Python 3.8 的构建。

### Upgrading / 升级

- Nothing to do. Baselines saved by earlier versions are still compared correctly, except that their ExecStart line is skipped. Running `ownexit chain --id <name> rebaseline` once rewrites them in the new format, which compares the ExecStart command line again; after that, going back to 2.3.0 needs another `rebaseline` with 2.3.0.
- 无需任何操作。旧版本保存的基线照常正确比对，只是不比 ExecStart 这一行。运行一次 `ownexit chain --id <名> rebaseline` 会改存为新格式，重新比对 ExecStart 的启动命令；之后如果降级回 2.3.0，要用 2.3.0 再 `rebaseline` 一次。

## [2.3.0] - 2026-10-30

### Added / 新增

- `ownexit direct change-port [--proxy-port <n>] [--no-probe]`: changes only the proxy port of the direct exit (random when no port is given); the UUID, keys and subscription URL stay the same. It changes the port the same way as `direct up --proxy-port` (which keeps working as before, without the reachability test below), and adds the random choice and that test.
- `ownexit direct change-port [--proxy-port <n>] [--no-probe]`：只换直连的代理端口（不给端口时随机选），UUID、密钥与订阅地址不变。改端口的方式与 `direct up --proxy-port` 相同，另外多了随机选端口和下面的试连；`direct up --proxy-port` 照旧可用，不做试连。
- `chain change-port` and `direct change-port` first test the new port from this machine: they listen briefly on candidate ports on the server (a transient `ownexit-portprobe-*` unit that exits within 90 seconds), try a TCP handshake from this machine and only use a reachable port. If none is reachable they stop with the server untouched (chain exit 3, direct exit 1). The step is skipped with a warning when this machine reaches the server through a TUN, the server has no python3, or (direct) ufw is enabled; `--no-probe` turns it off.
- `chain change-port` 与 `direct change-port` 换之前先从本机试连新端口：在服务器上临时监听候选端口（瞬时单元 `ownexit-portprobe-*`，90 秒内自动退出），从本机测 TCP 握手，只用能连上的端口；都连不上时停下、服务器不动（链式退出 3，直连退出 1）。本机经 TUN、服务器没有 python3、（直连）ufw 已启用时打一行警告并跳过这一步；`--no-probe` 关闭。

### Upgrading / 升级

- Nothing to do. Existing chains, direct installs and state files are read as before. `chain change-port` now runs the reachability test by default; add `--no-probe` for the previous behaviour.
- 无需任何操作。现有链、直连部署与 state 文件照常读取。`chain change-port` 现在默认先试连，要沿用之前的做法加 `--no-probe`。

## [2.2.0] - 2026-10-30

### Added / 新增

- `ownexit chain change-port [--port <n>]`: moves only the relay's public port of a chain to a new one (random free port in 20000-59999, or the given one). UUIDs, the Reality key, short id, devices and the exit stay the same; the local node files and state are updated and a full verify runs at the end. It prints which client nodes need the new port as soon as the state is committed. Rerun it to converge after an interruption.
- `ownexit chain change-port [--port <n>]`：只把一条链的中转对外端口换成新端口（在 20000-59999 里随机选空闲端口，或用指定端口）。UUID、Reality 密钥、short id、设备、出口机都不变；更新本机节点文件与 state，最后跑一遍完整 verify。state 一提交就提示哪些客户端节点要改成新端口。中途断开时重跑收敛。

### Upgrading / 升级

- Nothing to do. Existing chains, configurations and state files are read as before; `change-port` only acts when you run it.
- 无需任何操作。现有链、配置与 state 文件照常读取；`change-port` 只在你运行它时才起作用。

## [2.1.0] - 2026-10-11

### Added / 新增

- Several exit IPs on one exit: `ownexit chain init` / `up` take `--exit-bind <IPv4>` (configuration key `EXIT_BIND_IPV4`, optional), so that a chain's outbound connections on the exit leave from one of the exit's own addresses. Deploy one chain per address to get nodes with different exit IPs; they can share a relay. The exit checks of `preflight` / `deploy` / `verify` and `ownexit doctor --ip-check` start from the bound address, and a bound address that is no longer configured on the exit is reported explicitly (exit 3 from `preflight` / `deploy` / `up`, exit 5 from `verify`).
- 一台出口机多个出口 IP：`ownexit chain init` / `up` 新增 `--exit-bind <IPv4>`（配置键 `EXIT_BIND_IPV4`，可选），让一条链在出口机上的出站连接从出口机自己的某个地址发起。每个地址部署一条链，就得到出口 IP 不同的节点，中转机可以共用。`preflight` / `deploy` / `verify` 的出口仲裁与 `ownexit doctor --ip-check` 都从绑定地址发起；绑定地址不在出口机网卡上时明确指出（`preflight` / `deploy` / `up` 退出 3，`verify` 退出 5）。
- `ownexit multi`: `--mixed-exits` combines chains with different exit IPs (each verified against its own exit IP; verify lines end with `exit=<IP>`), and `--group select` renders a manual group named `Exit-Relay-select`. With `--mixed-exits` only the manual group is allowed, because an automatic group would change the exit IP without you noticing.
- `ownexit multi`：`--mixed-exits` 聚合出口 IP 不同的链（逐链按自己的出口 IP 核验，verify 行末多 `exit=<IP>`）；`--group select` 生成手动选择组 `Exit-Relay-select`。`--mixed-exits` 时只允许手动选择组，自动组会在不知情时换掉出口 IP。

### Changed / 变更

- `ownexit chain migrate-exit`: a chain that sets `EXIT_BIND_IPV4` can still be switched in place when the same exit gets a new SSH address (the bound address must still be configured there); moving such a chain to another machine is refused with exit 2.
- `ownexit chain migrate-exit`：设置了 `EXIT_BIND_IPV4` 的链，同一台出口机换 SSH 地址时照常原地切换（绑定地址须仍在网卡上）；迁到另一台机器以退出 2 拒绝。

### Upgrading / 升级

- Nothing to do. Chains without `EXIT_BIND_IPV4` behave exactly as before: the configuration digest, the exit's sing-box configuration and every command are unchanged. A configuration that has the new key cannot be read by versions before 2.1.0 (they refuse it as an unknown key).
- 无需任何操作。没有 `EXIT_BIND_IPV4` 的链行为与之前完全相同：配置摘要、出口机的 sing-box 配置和各命令都没有变。带这个新键的配置不能被 2.1.0 之前的版本读取（会以“未知配置键”拒绝）。

## [2.0.0] - 2026-10-07

### Removed / 移除

The spellings deprecated in 1.5.0 (they kept working, with a hint, through 1.5.0, 1.6.0 and 1.7.0) are removed. Calling one now exits 2 and prints the replacement on stderr:

1.5.0 废弃的旧写法（1.5.0、1.6.0、1.7.0 都照常可用并提示新写法）在本版移除。调用时退出 2，并在 stderr 给出替代写法：

- `ownexit direct --rotate-keys` / `--rotate-token` / `--add-device <name>` / `--remove-device <name>` / `--migrate` / `--uninstall` → `ownexit direct rotate-keys` / `rotate-token` / `add-device <name>` / `remove-device <name>` / `migrate` / `uninstall`
- `ownexit subctl start` / `stop` / `status` / `log` / `qr` / `devices` / `login` (and running `direct/subctl` directly) → `ownexit direct sub start` / `sub stop` / `status` / `log` / `qr` / `devices` / `login`. `direct/subctl` stays as the internal implementation of these operations. / `direct/subctl` 保留，作为这些操作的内部实现。
- `ownexit chain rehost-exit` → `ownexit chain migrate-exit --to <new IP>` (the same machine is detected automatically). / （同一台机器会自动识别。）

### Upgrading / 升级

- Nothing to do: local configuration, state, subscriptions, server files and every other command, option, exit code and machine-readable output are unchanged, so deployments made with 1.x keep working without redeploying or re-importing clients. Update your own scripts or aliases that still use the spellings above.
- 无需任何操作：本机配置、状态、订阅、服务器上的文件，以及其余命令、参数、退出码和机器可读输出都没有变，1.x 部署的直连与链升级后照常管理，不用重新部署、客户端不用重新导入。自己的脚本或别名里如果还写着上述旧写法，改成新写法即可。
- A `rehost-exit` interrupted under 1.x (configuration already on the new IP, state still on the old one): rerun it with 1.x before upgrading, or after upgrading run `ownexit chain migrate-exit --to <EXIT_HOST from the configuration>` to finish it.
- 1.x 里中断的 `rehost-exit`（配置已改成新 IP、state 还是旧 IP）：升级前用 1.x 重跑它，或升级后运行 `ownexit chain migrate-exit --to <配置中的 EXIT_HOST>` 续上。

### Changed / 变更

- The compatibility promise now covers 2.x (`docs/reference/compatibility.md`): the reference documents are frozen for 2.x, and 2.x reads every file 1.x wrote. `direct/subctl` and the `OWNEXIT_VIA_DIRECT` marker are listed as internal.
- 兼容承诺改为 2.x（`docs/reference/compatibility.md`）：参考文档按 2.x 冻结，2.x 能读取 1.x 写下的全部文件；`direct/subctl` 与内部标记 `OWNEXIT_VIA_DIRECT` 列为内部内容。

## [1.7.0] - 2026-10-07

### Added / 新增

- The scripts now speak English as well as Chinese: `--help`, progress, warnings, errors, the "next steps" summary, the server-side `[vps]` log lines of direct, the relay chain's remote preflight messages and doctor's camouflage-domain scan. The language follows the entry point's rule: `OWNEXIT_LANG=zh|en` wins; otherwise Chinese when `LC_ALL` / `LC_MESSAGES` / `LANG` starts with `zh`, English otherwise. The language picked in the guided setup is passed on to the scripts, so the English setup note "the scripts print in Chinese for now" is gone.
- 脚本输出中英双语：`--help`、进度、警告、报错、“下一步”汇总、直连的服务器端 `[vps]` 日志、链式远端预检的报错、doctor 的伪装域名扫描都有英文。语言规则与入口相同：`OWNEXIT_LANG=zh|en` 优先；否则 `LC_ALL` / `LC_MESSAGES` / `LANG` 以 `zh` 开头为中文，其余英文。向导里选的语言会传给脚本，英文向导里“脚本输出目前是中文”的提示随之删除。
- Generated comments follow the language too: the header of a chain configuration written by `chain init` and of `clash-snippet.yaml` written by `multi render`.
- 生成文件里的注释也跟随语言：`chain init` 写的链配置头部、`multi render` 写的 `clash-snippet.yaml` 头部。
- `scripts/check_ui_lang.sh` (run in CI) fails when a Chinese message in the scripts has no English twin, or when the two texts have different `%`, `${` or `$(` placeholders.
- 新增 `scripts/check_ui_lang.sh`（接入 CI）：脚本里有中文提示没写英文，或两种语言的 `%`、`${`、`$(` 个数不同时报错。

### Changed / 变更

- Chinese-speaking users whose system language is not Chinese now see English output; set `OWNEXIT_LANG=zh` to switch back. Machine-readable output (`status=`, `reason=`, `health=`, `rotate=`, `migrate=` and the other frozen keys and values) is identical in both languages; the `INFO` / `WARN` / `ERROR` level words are not translated.
- 系统语言不是中文的中文用户，现在看到的是英文输出；设 `OWNEXIT_LANG=zh` 即可改回。机器可读输出（`status=`、`reason=`、`health=`、`rotate=`、`migrate=` 等冻结的键与值）两种语言完全相同；`INFO` / `WARN` / `ERROR` 级别词不翻译。
- English documentation quotes the scripts' English messages instead of Chinese originals with a gloss.
- 英文文档引用报错时改用脚本的英文原文，不再附中文原文加释义。

## [1.6.0] - 2026-10-06

### Added / 新增

- The guided setup (`ownexit` with no arguments in a terminal) now asks for the language first (中文 / English); Enter keeps the language detected from your locale, and setting `OWNEXIT_LANG=zh|en` skips the question. In English it also notes that the setup scripts' progress output is currently in Chinese.
- 向导（在终端里只敲 `ownexit`）第一步先选语言（中文 / English）；回车沿用按系统语言判断的结果，设 `OWNEXIT_LANG=zh|en` 可跳过这一步。选 English 时会提示部署脚本的进度输出目前是中文。
- English editions of the user-facing documentation: the direct, relay chain and Clash direct-IP guides, the three reference documents, and the `chain/` and `direct/` READMEs (`*.en.md`); `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md` and the issue / pull request templates are now bilingual. The English README links to the English editions.
- 面向用户的文档有了英文版：直连、链式、Clash 直连 IP 三篇手册，三篇参考文档，以及 `chain/`、`direct/` 的 README（`*.en.md`）；`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md` 与 issue / PR 模板改为中英双语。英文 README 改链英文版。
- Checks that keep the two languages in step: `scripts/check_interface.sh` now also compares the table first columns of the Chinese and English reference documents, and the new `scripts/check_i18n.sh` checks that document pairs exist, link to each other, and that English pages neither link back to Chinese editions nor use broken anchors. Both run in CI.
- 防止中英两版走样的检查：`scripts/check_interface.sh` 增加中英参考文档表格首列比对；新增 `scripts/check_i18n.sh` 检查成对文档存在、互相链接，英文页不链回中文版、锚点有效。两者都接入 CI。

### Changed / 变更

- `OWNEXIT_LANG` is documented as controlling both the entry point's help and the guided setup (previously described as affecting the help only).
- 参考文档里 `OWNEXIT_LANG` 的说明改为“决定入口帮助与向导的语言”（原写只影响帮助）。

## [1.5.0] - 2026-10-06

### 新增

- 直连改用子命令，与链式一致：`ownexit direct up`（部署；不带子命令仍等同 up）、`rotate-keys`、`rotate-token`、`add-device <名>`、`remove-device <名>`、`migrate`、`uninstall`，以及原 `ownexit subctl` 的日常操作 `sub start [--ttl]` / `sub stop` / `status` / `log` / `qr` / `devices` / `login`。
- `ownexit chain migrate-exit --to <新 IP>` 能自动处理“同一台出口机换了 IP”：经中转确认主机指纹相同后，自己登记新 IP 的主机密钥、备份并改写配置，原地切换，输出 `migrate=rehosted`；旧 IP 连不上也可以，中断后重跑同一条命令续上。

### 变更

- `migrate-exit` 以前在两种情形退出 2，现在会成功：`--to` 就是当前出口机（已切换完成，输出 `rehost=noop`）；新地址与当前出口机是同一台（原地切换）。
- `ownexit --help` 不再列出 `subctl`、`connect`（两者照常可用）；向导部署直连时执行 `ownexit direct up`。
- 所有提示文字、帮助、README 与手册改用新写法。

### 废弃

- `ownexit direct --rotate-keys` / `--rotate-token` / `--add-device` / `--remove-device` / `--migrate` / `--uninstall`、`ownexit subctl …`、`ownexit chain rehost-exit`：照常可用，使用时在 stderr 提示新写法，最早在 2.0 移除（见 docs/reference/compatibility.md “已废弃项”）。

## [1.4.0] - 2026-10-06

### 新增

- 向导：在终端里只敲 `ownexit`（不带参数），先问“在你这里能直接连上这台 VPS 吗”，再问 IP 与 SSH 端口，然后自动执行 `ownexit direct` 或 `ownexit chain up`。脚本、管道里不带参数仍打印帮助。
- Homebrew 一行安装：`brew install jakoes-wu/tap/ownexit`（macOS），连同 qrencode 一起装好。
- 直连订阅服务可选自动关闭：`ownexit direct --sub-ttl 30m`、`ownexit subctl start --ttl 30m`，到时在 VPS 上自动停掉订阅服务；不给则与之前一样一直开着。`subctl status` 显示离自动关闭还剩多久，`subctl stop` 一并取消计时。

### 变更

- 手册与帮助把“出口机变了”统一为先运行 `migrate-exit`；同一台机器只换了 IP 时（包括旧 IP 已经连不上），它的提示现在指向 `rehost-exit`，并写清楚之前要改哪些配置。

## [1.3.0] - 2026-10-06

### 新增

- 直连自适应订阅地址 `http://<VPS>:<订阅端口>/<TOKEN>/sub`（default 与每台设备都有）：按客户端 User-Agent 返回 Clash 配置、sing-box 配置或 base64 节点列表，认不出的客户端返回节点列表；部署结束只推荐这一条，原来四条按格式固定的地址照旧可用。已部署的直连升级后重跑一次 `ownexit direct` 即可启用。
- 首次配免密改用 Python 包 pexpect 自动输入密码（pipx / pip 安装时自动带上），本机不再需要另装 `expect`；没有 pexpect 时仍可用系统 `expect`。新增环境变量 `OWNEXIT_PYTHON`（入口自动设置）。

### 变更

- 直连订阅服务由 `python3 -m http.server` 换成随包分发的 `subserver.py`（服务名、端口、目录、文件名不变）：只响应订阅路径，根目录与其它路径返回 404，不再把带 TOKEN 的请求路径写进系统日志。
- 新增 Python 依赖 `pexpect`（含 `ptyprocess`）；离线安装需一并准备。

## [1.2.0] - 2026-10-06

### 新增

- 链式 `chain up --relay <IP> --exit <IP>`：一条命令完成 init、deploy 并打印节点二维码与下一步；可重跑，已有配置且地址一致时直接继续，不带 IP 且本机只有一条链时复用它。
- 链式子命令在本机只有一条链时可以省略 `--id`（`ownexit chain status`）；没有配置或有多条时退出 2 并提示。
- 链式 `chain qr [--device <名字>]`：在终端显示节点二维码，只读本机文件。
- 直连与链式部署成功后打印“下一步”块（导入哪条链接、应显示的出口 IP、`subctl stop`、`doctor`），二维码紧随其后。
- `ownexit --help` 按系统语言输出中文或英文（`OWNEXIT_LANG=zh|en` 可强制），并分“常用 / 其它”两组；`chain --help` 的子命令按常用 / 日常 / 维护 / 高级分组。

### 变更

- **部署前自检（行为变化）**：`ownexit direct`、`chain deploy` / `chain up` 开始前检查本机到服务器的路由是否经过代理 TUN；经过时不再只是警告，而是拒绝（链式退出 3，直连退出 1）并给出处理办法。一直在 TUN 下部署的用户需要关闭 TUN、按 `docs/manual/clash-direct-ips.md` 让服务器 IP 走物理网卡，或加 `--allow-tun` 恢复旧行为。

## [1.1.0] - 2026-10-06

### 新增

- 链式 `migrate-exit --to <新出口机 IPv4> [--to-port <n>]`：出口机换一台机器。旧出口机的配置（含 Reality 私钥）经本机内存搬到新机器，UUID、密钥、short id、全部设备、中转地址与端口都不变，客户端不用重新导入；中转转发目标切过去后自动删除旧出口机上本链的服务与文件。中途中断重跑同一条命令即可收敛；中转切换前可用 `--abort` 放弃，旧机器永久失联时可用 `--abandon-cleanup` 放弃清理。
- 链式 `status` 新增 `reason=exit-migration-pending`；新增输出行 `migrate=done` / `migrate=aborted`；新增本机文件 `chains/<id>/migrate-exit.env`（迁移进行中才存在）。

### 变更

- 出口机迁移进行中时，deploy、rollback、rehost-exit、rebaseline、rotate-keys、add-device、remove-device 拒绝执行并提示先完成迁移。没有迁移记录时行为与 1.0.0 相同。

## [1.0.0] - 2026-10-06

### 新增

- 接口冻结：命令行、配置键、本机与服务器文件格式在 1.x 内只增不减，已有部署升级后无需重新部署或重新导入客户端；不兼容改动只在 2.0 并提供迁移。规则见 `docs/reference/compatibility.md`。
- 参考文档 `docs/reference/commands.md`（命令、参数、退出码、机器可读输出、环境变量）与 `docs/reference/files.md`（文件、键、路径、节点名）。
- `scripts/check_interface.sh`：CI 自动比对源码与参考文档里的参数、子命令、status 取值、配置 / 状态键、订阅文件名，不一致时失败。

### 变更

- PyPI 分类标为 Development Status :: 5 - Production/Stable。
- 本版本不改变任何命令、输出与文件格式。

## [0.7.0] - 2026-10-05

### 新增

- 多设备（直连与链式）：每台设备一个独立 UUID，可单独吊销，其它设备不受影响。直连 `--add-device` / `--remove-device`（每台设备有自己的订阅地址）与 `subctl devices`；链式 `add-device` / `remove-device` / `list-devices`（每台设备一个节点文件）。现有的那套凭据就是 `default`，订阅地址与 `node.txt` 不变。
- `ownexit doctor --scan-sni`：在出口服务器上对候选伪装域名逐个做真实 Reality 握手（本机回环），按可用与握手耗时排序；可用 `--sni-candidates` 指定候选。

### 变更

- 凭据轮换（直连 `--rotate-keys`、链式 `rotate-keys`）同时重新生成全部设备的 UUID。
- 链式 `status` 在出口机有未完成的凭据或设备操作时输出 `reason=exit-op-pending next=rerun-interrupted-command`（原为 `reason=rotate-pending next=run-rotate-keys`）。
- 新部署的链与改过参数的直连，服务器配置的 users 项带 `name` 字段。

## [0.6.0] - 2026-10-05

### 新增

- `ownexit doctor`：检查本机（依赖命令、代理环境变量、目录权限、到服务器的路由是否经过代理 TUN）、每台记住的直连 VPS（密钥、SSH、服务、订阅、BBR）与每条链（运行 `status`），逐项输出 OK / WARN / FAIL 和处理办法。
- `ownexit doctor --ip-check`：在出口服务器上体检出口 IP：归属与类型、ChatGPT / Claude / Gemini、Netflix / YouTube Premium / Disney+、常用网站连通性（仅供参考）。

### 变更

- 链式只读命令（`status`、不带 `--with-fail-closed` 的 `verify`、`conns`、`banlist`）遇到 SSH 连接层失败（255，非控制端超时）时自动重试最多 3 次，减少本机开着 TUN 时的偶发失败；修改类命令不重试。

## [0.5.0] - 2026-10-05

### 新增

- 直连订阅新增 `sing-box.json`：sing-box 官方客户端（SFI / SFA / SFM，1.12 及以上）可直接导入的完整配置；v2rayN / v2rayNG 使用已有的 base64 订阅（交付信息与手册写明）。
- 直连 `--rotate-keys`：在服务器上重新生成 UUID、Reality 密钥对与 short id，端口、SNI、订阅地址不变；失败自动恢复原配置，中途断开重跑不会换两次。
- 链式 `rotate-keys`：原地更换出口机的 UUID、Reality 密钥对与 short id，中转、端口、部署 ID 不变，更新 `node.txt` 后自动跑完整 verify；中途断开重跑同一条命令收敛。辅助文件未清理时 `status` 输出 `reason=rotate-pending next=run-rotate-keys`，`verify` / `rollback` 拒绝执行。

### 修复

- 直连恢复上次中断的改参数操作后，没有提示重新导入订阅与同机链的 `rebaseline`。
- 直连帮助里改伪装域名的示例 `--sni www.microsoft.com` 实测不可用（客户端 Reality 握手被服务器判为无效），改为实测可用的 `www.apple.com`，并在帮助与手册中提示换域名后先实测。

## [0.4.0] - 2026-10-05

### 新增

- 直连改为原生安装：不再调用第三方脚本 233boy，VPS 自己下载固定版本的 sing-box 官方包并校验 SHA-256（下载失败时由本机下载上传），在 VPS 上生成 Reality 密钥，全程无交互；新增 `--sni`、`--proxy-port`，重跑即可改参数（UUID 与密钥不变）。
- 直连一次性迁移 `--migrate`：把 233boy 安装换成 ownexit 的 `ownexit-direct` 服务，沿用原有 UUID、密钥、端口、SNI、short id，客户端与订阅链接不用动；迁移前打包备份，新服务起不来自动回到旧服务。
- 直连卸载 `--uninstall`；`subctl log` 看服务日志、`subctl qr` 在终端显示节点二维码，部署结束时本机有 `qrencode` 直接显示二维码。
- 直连改动服务器的操作由 VPS 上的 systemd 临时任务执行：SSH 断开不影响，VPS 断电重启后再运行一次即从中断处恢复。
- 链式新增 `rebaseline`：中转机上的直连迁移 / 改参数 / 新装 / 卸载后，重新登记要保护的既有 sing-box；`RELAY_COHOSTS_SINGBOX` 新增取值 `ownexit-direct`，`init` 自动识别。
- 直连已在 Linux 控制端（Ubuntu 22.04）验证。

### 修复

- 同一台电脑先用直连、后用链式时，链式报“无法安全取得 shared global lock”：直连创建的 `~/.local/state/ownexit` 等目录权限为 755，现在改为 700，并收紧旧版留下的目录。
- 链式进程清理临时目录时改用进程启动时的配置摘要比对，避免改写配置的命令（`rebaseline`）结束后留下锁。

## [0.3.3] - 2026-10-05

### 变更

- 文档：链式部署的 arm64 服务器已在 Ubuntu 22.04 arm64 虚拟机上完成 init → deploy → verify → rollback 全流程测试，README 与 VPS 手册中的“arm64 未测试”改为注明测试环境；尚未在 arm64 云服务器上测试。

## [0.3.2] - 2026-10-05

### 修复

- PyPI 项目页上 README 里的文档、许可证等链接是相对路径，点开会 404；`README.md` 改为完整链接，CI 新增检查防止再写进相对链接。

## [0.3.1] - 2026-10-05

### 新增

- README 在“安装”前加入“前置条件”：服务器要求，以及 macOS、Debian / Ubuntu / WSL 上安装 `pipx`、`expect` 等依赖的命令。
- 新增 VPS 选购与系统安装手册（中文 `docs/manual/vps.md`、英文 `docs/manual/vps.en.md`）：怎么选、怎么下单、装或重装系统、防火墙与安全组、只给密钥登录时怎么办。

### 修复

- 用 pipx / pip 安装后，没有装 `git` 的电脑上运行 `ownexit chain` / `ownexit multi` 会报“本机缺少依赖：git”而退出；现在只有从 git clone 运行时才需要 `git`。

## [0.3.0] - 2026-10-05

### 新增

- 发布到 PyPI：`pipx install ownexit` 后得到单一命令 `ownexit`，子命令 `direct` / `subctl` / `connect` / `chain` / `multi` 与仓库里的脚本一一对应，参数原样转发。
- README 加入 PyPI 徽章与演示动画（`scripts/make-assets.py` 生成，回放真实输出，IP 为示例）。
- 发布工作流 `pypi.yml`（GitHub release 时经 PyPI Trusted Publishing 上传）；CI 新增打包安装检查。

### 变更

- 链式脚本的“配置不得位于仓库工作区内”检查只在 git clone 形态下执行；pip 安装的副本不在任何仓库里，跳过该检查。
- 脚本之间改用 `bash <脚本>` 互相调用，不依赖文件的可执行位。

## [0.2.0] - 2026-10-05

### 新增

- 链式：服务器自己从 GitHub 下载固定版本 sing-box 并校验 SHA256，失败才由本机下载上传；本机拿不到本机平台的官方包时跳过本机层出口验证，不再阻塞部署。
- 链式：控制端支持 Intel Mac 与 Linux（amd64 / arm64，含 WSL）；中转机与出口机支持 arm64（两端须同架构）。
- 链式：`EXIT_SOURCE_FILTER=managed`（`init` 默认）：部署时在出口机加一张只放行中转机出站地址的 nft 表，随出口服务起停，rollback 删除；部署与 verify 时严格检查。

### 修复

- `init`：较旧的 OpenSSH（如 Ubuntu 20.04 的 8.2）首次连接只记下 ECDSA 主机密钥，之后强制 ed25519 被当成主机身份变化而失败；现在经已验证的会话补记 ed25519 主机密钥。
- 碰撞核证遇到一次 SSH 断开（rc=255）时重试一次。

### 变更

- 远端预检允许出口机存在本项目的 `table inet ownexit_*` 白名单表。

## [0.1.0] - 2026-10-04

### 新增

- 直连：`direct/setup_direct.sh --host <ip>` 一条命令把一台 Debian / Ubuntu VPS 部署成固定出口（VLESS-Reality，sing-box 由 233boy/sing-box 安装），生成 Clash、Shadowrocket 订阅和 `vless://` 节点链接，并逐层验证。
- 直连：第一次部署时自动配好免密；成功后记住这台 VPS，之后 `setup_direct.sh`、`subctl` 不带参数也能用。
- 直连：`direct/subctl` 开关订阅服务（`start` / `stop` / `status`）或免密登录 VPS。
- 链式：`chain/setup_chain.sh init --relay <ip> --exit <ip>` 只问两个 IP，自动配免密、探测出口 IP 与中转现状并生成配置；`--id <名字>` 作为 `--config` 的简写；新增配置键 `EXIT_SOURCE_FILTER=provider|none`，普通 VPS 无外部白名单时（`none`，默认）出口机拒绝侧检查只记 WARN。
- 链式：`preflight` / `deploy` / `verify` / `status` / `rollback` 事务化部署与拆除，中转机只做 TCP 透传、不放密钥；`conns` / `kick` / `ban` / `unban` / `banlist` 管理中转连接；`rehost-exit` 在出口机同机换 IP 时原地迁移。
- 链式：`chain/multi_chain_client.sh` 把多条链聚合成带 `fallback` 自动组的客户端配置和逐链二维码。
- 密码只交互输入（或经环境变量 `OWNEXIT_SSH_PASSWORD`），每次只向服务器提交一次，交互最多 3 次；登录失败区分 `bad-password` / `password-disabled` / `unreachable`。
