# 链式操作的 SSH 连接复用（v2.4.0）

> 2026-10-31 注记：方向由用户选定（“把部署时同一台服务器的多次连接合成一条复用”，不选“只读步骤重试”）。设计评审 11 轮收敛、代码评审判定可合并。
>
> 2026-11-02 注记：已落地。源码位置（`chain/setup_chain.sh`）：`mux_control_with_timeout` `:2034-2066`，`close_mux_dir` `:2072-2117`，`reset_mux_connections` `:2122-2132`，重试前关连接的三处调用 `:2001`（`ssh_with_readonly_retry`）、`:2183`（主机指纹探测）、`:2686`（`remote_test_path`）。测试机测试床结果（§8）：
>
> - 通过：T1（deploy 握手数中转 110→2、出口机 53→3；status / verify / rollback 均降到每台 2 次，新旧两版全部 rc=0）、T3–T6、T7、T8（本机对真实线路 status / verify rc=0，无残留）、T9、T10、T11（`/bin/bash` 3.2 下无 `Terminated` 提示，单次控制命令约 3 秒返回，`close_mux_dir` 约 9 秒返回）、T12、T13、T14a、T15 两个方向。
> - T14b 不可达：做主机指纹探测时还没有中转复用连接，注入没有目标。
> - T14c、T14d 为行为记录，见 §7 正向 6。
> - T2（只记录）：控制端对中转新连接按 15% 概率回 RST，新版 deploy 8/10 成功（两次失败都在第一条连接、2–3 秒内中止），v2.3.1 为 0/10。

## 1. 背景

2026-10-11 在随身 WiFi 下部署链式线路：直连公网 SSH 在密钥交换阶段即被断开，经代理时有 7%–25% 的新连接在握手前被断开。deploy / up 的修改类步骤与部署期的只读预检都不重试（`ssh_with_readonly_retry` 只在 `READONLY_SSH_RETRY=1` 的只读命令里重试，`chain/setup_chain.sh:1926`，开启点 `:10171-10172`），6 次尝试全部在预检中止；换到 SSH 稳定的节点后才部署成功，ip223 还在最后的残留检查被断一次、靠重跑收敛。2026-10-30 重新部署另一条线路时，第一次 deploy 同样在“state 写入后的远端复核”断连（退出 4），重跑才收敛。

现状：每一次 `ssh_relay` / `ssh_exit` / `scp_*` 都新建一条 TCP 连接、重做一次密钥交换和认证（`chain/setup_chain.sh:1956-1978`）；访问出口机走 `ProxyJump chain-relay`（`:1888`），每次还要先对中转多做一次握手。生成的 SSH 配置（`render_ssh_config`，`:1875-1919`）没有任何连接复用设置。`setup_chain.sh` 里对两台服务器的 SSH / scp 调用点约 120 处，一次 deploy 实际发起的握手数由 §8 T1 实测记录。

## 2. 目标 / 非目标

目标：

1. 同一次操作内，对同一台服务器的 SSH / scp 复用一条已认证的连接（OpenSSH `ControlMaster`），后续调用不再重新握手，从而减少“握手中途被断”的机会。
2. 复用连接断开且复用进程已退出后，下一次调用自动重新建立，不需要用户干预（复用进程尚未察觉断线的窗口见 §7 正向 6）；操作结束（成功、失败、Ctrl-C）时关掉本次建立的复用连接，不留后台进程和插口文件。
3. 不削弱现有的安全闸门：主机指纹探测仍做一次真实握手，仍只认 ed25519、`StrictHostKeyChecking yes`。

非目标：

- 不加修改类步骤的重试，不改 `ssh_with_readonly_retry` 与主机指纹探测的重试条件、次数和间隔（用户未选该方向）；只在三处已有的 SSH 重试（`ssh_with_readonly_retry`、主机指纹探测、`remote_test_path`）等待之前加一步“关掉本次的复用连接”（§5.1 第 8 点，用户 2026-10-31 依 T14 实测选定）。
- 不改 `direct` 子命令（`direct/connect_to.sh`）和 `multi`（`chain/multi_chain_client.sh` 不发起 SSH）。
- 不改密钥初始化（`:10019`）这处独立的 ssh 调用。同机探测（`:7247-7250`）的配置是从受管配置整段复制来的，会继承复用设置，本方案在它的探测段里显式关闭复用（§5.1 第 2 点），不改它的其它行为。
- 不跨操作复用：每次命令建自己的复用连接，命令结束即关，不做常驻连接池。

## 3. 假设与约束

以下行为已在本机做最小复现（2026-10-31，本机 OpenSSH_10.3p1 → 测试机 OpenSSH_8.2p1，测试机自跳转模拟“经中转访问出口机”）：

| 编号 | 事实 | 复现结果 |
| ---- | ---- | ---- |
| A1 | `ControlMaster auto` + `ControlPersist` 时，`$(ssh ...)` 命令替换不会被后台复用进程挂住 | 首次 1 秒返回；第二次复用 0.17 秒 |
| A2 | `ProxyJump` 起的跳转子进程带上同一个 `-F` 配置，因此跳转本身也走中转的复用连接 | 进程表见 `ssh -F <cfg> -W [127.0.0.1]:22 j` |
| A3 | 复用进程被 `kill -9` 后插口文件残留，下一次 `ControlMaster auto` 的调用照常成功并建立新的复用进程 | rc=0，`-O check` 显示新 pid |
| A4 | 中转的复用进程退出时，经它跳转的出口机复用进程随之退出并删掉自己的插口 | 出口机插口消失 |
| A5 | 命令行 `-o ControlMaster=no -o ControlPath=none` 覆盖配置，做一次真实握手 | `-vv` 日志里 `Server host key` 恰 1 行 |
| A6 | 插口路径 ≥ 104 字节时 ssh 直接失败 | rc=255，`ControlPath too long (... >= 104 bytes)` |
| A7 | 配置里先出现的 `ControlMaster no` / `ControlPath none` 优先于后面 `Host *` 里的设置 | `ssh -G` 显示 `controlmaster false`、无 controlpath 行 |
| A8 | `ssh -O exit` 后复用进程退出、插口删除 | 进程表无残留 |
| A9 | 复用会话进行中复用进程被杀，客户端返回 255 | `ssh t 'sleep 20'` 第 2 秒杀复用进程，rc=255，耗时 3 秒 |
| A10 | 出口机复用进程第一次经跳转建立时，调用方的 stdout / stderr 是管道（`$(... 2>&1)`、`\| cat`）也不会等复用进程退出 | 两种写法都 0 秒返回，输出完整 |
| A11 | 中转没有复用进程时先连出口机，跳转子进程自己建立中转的复用进程 | 进程表出现中转、出口机两个 `[mux]` 进程和一个 `-W` 跳转进程 |
| A12 | macOS 上复用进程的进程标题改为 `ssh: <插口> [mux]` | 本机 `ps` 可见 |
| A13 | 出口机复用进程活着时，它的跳转通道占着中转复用进程，中转的 `ControlPersist` 计时要等出口机复用进程退出后才开始；最坏约 2 × 120 秒才全部退出 | 本机 10.3 → 测试机自跳转，`ControlPersist 5`：出口机插口约 6 秒消失，中转插口约 11 秒消失；8.2 由 T3 复核 |

约束与推论：

- 操作临时目录 `OP_TMP`（`chain/setup_chain.sh:1104`）在 macOS 上约 250 字节（`$TMPDIR` 本身 49 字节，再加两段 64 位哈希），放不下插口（A6）。插口目录必须另建在 `/tmp` 下的短路径，不用 `$TMPDIR`（用户可能设得很长）。ssh 建插口时会临时加 17 字节随机后缀，`/tmp/ownexit-mux.XXXXXX/`（24 字节）+ 角色与密钥标记（`r-` / `e-` 加 8 位十六进制再加 `-`，共 11 字节）+ `%C`（40 字节）+ 17 ≈ 92 字节，小于 104。
- Linux 控制端最低按 OpenSSH 8.2（Ubuntu 20.04）考虑。A1–A11 都是 10.3 客户端的结果，由 §8 T3 在 8.2 客户端上全部再核一次；A3 在 8.2 上若不成立，因每次操作都用新的插口目录，不受影响。
- 能连上插口就能以 root 在两台服务器上执行命令。插口目录为当前用户所有、权限 700，与私钥文件同一保护级别（拿得到插口的同一用户本来就读得到私钥），不新增暴露面。

## 4. 涉及模块

行号以 main 9758142 为基线。

| 区域 | 行号锚点 | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| 全局变量 | `chain/setup_chain.sh:160-161` 邻近 | 新增 | `MUX_DIR=''` |
| `init_operation_tmp` | `chain/setup_chain.sh:1097-1125` | 修改 | 扫除过期空插口目录；owner 文件落盘（`:1121-1122`）之后建 `MUX_DIR`，并在 `OP_TMP` 内另写 600 权限的 `mux-dir` 文件记录路径；owner 文件格式不动 |
| `cleanup_stale_operation_tmp` | `chain/setup_chain.sh:1331-1348` | 修改 | owner 校验通过后、`find ... -delete`（`:1345`）之前，读 `mux-dir` 文件并调用 `close_mux_dir` |
| `render_ssh_config` | `chain/setup_chain.sh:1875-1919` | 修改 | 两个 Host 块各加带角色与密钥标记的 `ControlPath`；`Host *` 加 `ControlMaster auto`、`ControlPersist 120`；直连配置的 `chain-direct-exit` 块加 `ControlMaster no` / `ControlPath none` |
| `check_ssh_effective_config` | `chain/setup_chain.sh:1980-1989` | 修改 | 追加核对 `controlmaster auto`、`controlpath` 前缀、`controlpersist 120` |
| `negotiated_hostkey_fingerprint` | `chain/setup_chain.sh:2012` | 修改 | 探测命令加 `-o ControlMaster=no -o ControlPath=none` |
| `migrate_probe_same_host` | `chain/setup_chain.sh:7236-7246` | 修改 | `chain-probe` 段加 `ControlMaster no` / `ControlPath none` |
| `migrate_probe_same_host` | `chain/setup_chain.sh:7227` | 修改 | `render_ssh_config` 后加 `|| die 1`（`if` 上下文里 `set -e` 不生效） |
| 新函数 `close_mux_dir` | `chain/setup_chain.sh:1978` 之后（`scp_exit` 后） | 新增 | 逐个插口 `-O exit`，再删插口目录 |
| 新函数 `reset_mux_connections` | `close_mux_dir` 之后 | 新增 | 只关本次 `MUX_DIR` 下的复用连接，不删目录 |
| `ssh_with_readonly_retry` | `chain/setup_chain.sh:1951-1952`（`[ssh-retry]` 日志与 `sleep`） | 修改 | 日志之前调用 `reset_mux_connections` |
| `negotiated_hostkey_fingerprint` | `chain/setup_chain.sh:2018-2019`（`[ssh-retry]` 日志与 `sleep`） | 修改 | 同上 |
| `remote_test_path` | `chain/setup_chain.sh:2520-2521`（“2 秒后重试一次”日志与 `sleep 2`） | 修改 | 同上 |
| `cleanup_operation_tmp` | `chain/setup_chain.sh:9854-9863` | 修改 | 删 `OP_TMP` 前调用 `close_mux_dir "${MUX_DIR}"` |
| `chain/README.md` / `README.en.md` | `chain/README.md:136`、`chain/README.en.md:138` 一段（隔离 SSH 配置说明） | 修改 | 补一句复用设置与插口目录 |
| `docs/reference/files.md` / `files.en.md` | `:44` 内部文件段 | 修改 | 补 `ownexit-chain.*` 与 `/tmp/ownexit-mux.*` |
| `CHANGELOG.md` | `## [Unreleased]` | 新增 | 中英各一条 |

## 5. 方案

### 5.1 实现要点

1. **插口目录**：`init_operation_tmp` 在 `mktemp` 建 `OP_TMP`（`:1104`）之后先做扫除；owner 文件落盘（`link`，`:1121`；`rm -f` 临时件，`:1122`）之后再建插口目录：
   - 先扫除过期空目录：`find /tmp/ -maxdepth 1 -name 'ownexit-mux.*' -type d -user "$(id -u)" -perm 700 -empty -mmin +1440 -exec rmdir {} \; 2>/dev/null || true`。只删属于当前用户、权限 700、已空、超过一天没改动的目录（`rmdir` 本身只删空目录）。路径写 `/tmp/`（带斜杠）：macOS 的 `/tmp` 是指向 `private/tmp` 的软链，`find /tmp` 不跟随命令行软链，扫不到内容。它兜住两种残留：在建插口目录与写好 `mux-dir` 文件之间被杀（过期清理找不到 `mux-dir`，不知道插口目录在哪）；旧版本过期清理只删 `OP_TMP`、不认识 `mux-dir` 文件。复用进程退出时会删自己的插口，所以这两种残留通常是空目录。
   - 再 `MUX_DIR="$(mktemp -d /tmp/ownexit-mux.XXXXXX)"`，`chmod 700`，核对属主为当前用户、不是符号链接（与 `:1390` 对 `OP_TMP` 的核对同一写法），不通过按现有 `init_operation_tmp` 失败处理（`return 1`）。
   - 插口目录路径写进 `${OP_TMP}/mux-dir`（`( umask 077; printf '%s\n' "${MUX_DIR}" > ... )`，600 权限、一行），不改 owner 文件：`operation_tmp_owner_matches` 要求 owner 的键列表与固定 7 个键逐行一致（`:1324`），新旧版本都靠它校验，加键会让新版自己的清理（`:9859`、`:1340`）和旧版的过期清理全部判失败，锁不释放、此后命令无法开始。建插口目录与写 `mux-dir` 放在 owner 落盘之后，是因为 `cleanup_incomplete_operation_tmp`（`:1366-1381`）处理“owner 还没落盘”的目录时，遇到 `.operation-owner.*.tmp` 以外的任何文件都拒绝清理（`:1372-1376`）；在建插口目录和写 `mux-dir` 之间被杀，留下的空插口目录由上一条扫除在一天后删掉。
2. **SSH 配置**：`render_ssh_config` 中：
   - `Host chain-relay` 块加 `ControlPath <MUX_DIR>/r-<中转密钥标记>-%C`，`Host chain-exit` 块加 `ControlPath <MUX_DIR>/e-<出口机密钥标记>-%C`。密钥标记取已校验过的 `RELAY_SSH_KEY_FINGERPRINT` / `EXIT_SSH_KEY_FINGERPRINT`（`parse_config` 时已与私钥核对，`:994-997`；迁移切换出口机时 `:8675`、`:8686` 两处随 `EXIT_SSH_KEY` 一起改；`:8815-8818`、`:8862`、`:8967-8969` 只改 `EXIT_SSH_KEY`，`:3271`、`:3334` 加载 state 时会用 state 里的值覆盖指纹变量。这几处之后要么不再生成 ssh 配置，要么出口机地址或端口同时变了、`%C` 本身就不同，所以不会出现“新私钥配旧插口”的混用；标记的含义是“生成配置那一刻指纹变量的值”，不保证与 `EXIT_SSH_KEY` 处处同步）做 SHA-256（`sha256_text`）后的前 8 位十六进制。`render_ssh_config` 在写任何文件之前先算出两个标记，任一指纹不匹配 `^SHA256:[A-Za-z0-9+/]+$` 或哈希失败就先 `log_warn "[ssh-mux] key-tag failed relay_fp_ok=<0|1> exit_fp_ok=<0|1>"`（脚本只有 `log_info` / `log_warn`，`:494-500`；随后的退出由调用方 `set -e` 或 `die` 负责）再 `return 1`，不写配置；11 处直接调用（`:5375`、`:5509`、`:6192`、`:6451`、`:6562`、`:6683`、`:7176`、`:7533`、`:8104`、`:8695`、`:8909`）在 `set -e` 下随之退出、日志里有原因，`:9730` 已在 `if !` 里处理；只有 `migrate_probe_same_host` 里的 `:7227` 处在 `if` 调用上下文（`:9484`、`:9499`）、`set -e` 不生效，改成 `render_ssh_config || die 1 ...`，避免拿旧配置探测、连不上后被当成“换了机器”（`:9492-9494`）；标记不放进 `printf` 参数里现算，避免失败被吞成空串的哈希。`%C` 是 OpenSSH 按本机名、目标主机、端口、用户算的哈希，不含所用私钥；加上密钥标记后，同一次操作里同一 host:port 换了私钥（迁移、换密钥）会得到新插口、重新认证，不会沿用旧私钥认证过的连接。
   - `Host *` 块末尾加 `ControlMaster auto`、`ControlPersist 120`。`ControlPersist 120`：最后一个会话结束 120 秒后复用进程自行退出（中转那条要等出口机复用进程先退出再计时，最坏约 240 秒，A13），给“异常退出、没走到清理”的情况兜底；一次操作中间空闲超过 120 秒（如下载 sing-box），下一次调用只是多一次握手。
   - `chain-direct-exit` 块（`:1909-1915`，`ProxyCommand none` 行之后）加 `ControlMaster no`、`ControlPath none`：这条只用来探一次直连管理端口，不该建复用进程（A7 保证它优先于复制进来的 `Host *`）。
   - `migrate_probe_same_host` 的 `chain-probe` 段（`:7236-7245`，`UpdateHostKeys no` 行之前）加 `ControlMaster no`、`ControlPath none`。该段是宽松校验（`StrictHostKeyChecking no`、`UserKnownHostsFile /dev/null`），并且配置从受管配置的 `Host chain-relay` 起整段复制（`:7246`），按本方案 `ControlPath` 只写在 `chain-relay` / `chain-exit` 两段，复制进来的 `Host *` 只带 `ControlMaster auto` 与 `ControlPersist`，`chain-probe` 本身没有插口路径、不会建复用连接（本机 OpenSSH 10.3 `ssh -G` 已核：无 `controlpath` 行）；仍显式关闭，是防止以后有人把 `ControlPath` 挪进 `Host *`，让这条宽松校验的连接被复用，T9 也以此为判据。关闭后，探测仍经中转的复用连接跳转（复制来的 `chain-relay` 段带着同一个 `ControlPath`），中转那一跳照旧严格校验。
3. **主机指纹探测**：`negotiated_hostkey_fingerprint`（`:2012`）的 ssh 命令加 `-o ControlMaster=no -o ControlPath=none`，保证每次探测都做真实握手、`-E` 日志里有本次协商的 `Server host key`（A5）。探测出口机时跳转子进程仍按配置走中转的复用连接（A2），不影响 `-E` 里只含目标会话日志的现有前提（`:2010-2011` 注释）。
4. **有效配置核对**：`check_ssh_effective_config` 追加 `grep -qx 'controlmaster auto'`、`grep -qx 'controlpersist 120'`，以及从 `ssh -G` 输出取 `controlpath` 行后用 `case` 做前缀匹配（`chain-relay` 应以 `controlpath ${MUX_DIR}/r-` 开头，`chain-exit` 以 `controlpath ${MUX_DIR}/e-` 开头；`%C` 已展开，不能整行匹配）。`ssh -G` 在 8.2 上的输出格式由 T3 确认。用户的全局 ssh 配置无法覆盖（`-F` 只读生成的配置），这一步只防本脚本自己写错。
5. **关闭复用进程**：新函数 `close_mux_dir <目录>`，操作结束清理和过期清理共用：
   - 参数为空或目录不存在直接返回 0；目录必须匹配 `^/tmp/ownexit-mux\.[A-Za-z0-9]{6}$`，属主为当前用户、权限 700、不是符号链接，否则 `log_warn` 后返回 0、不动它；
   - 对目录下每个插口文件（`-S` 判定）执行 `ssh -F /dev/null -o ControlPath=<插口> -O exit x 2>/dev/null || true`。按插口逐个关，不按别名关：同一次操作里 `EXIT_HOST` / 端口 / 私钥可能变过（migrate-exit 来回切换，`:8673`、`:8684`、`:8814-8818`、`:8967`），按当前别名算出的插口会漏掉旧的。`-F /dev/null` 避免读用户的 `~/.ssh/config`（其中的 `Match exec` 会被执行）。出口机插口（`e-` 开头）先关，再关中转（`r-` 开头）：出口机的跳转挂在中转的复用连接上；
   - 最多等 2 秒（10 × 0.2 秒）让插口消失；仍在的插口逐个 `ssh -F /dev/null -o ControlPath=<插口> -O check x`，只有返回 255（连不上插口：复用进程已异常死掉、只剩插口文件，A3）才 `rm -f` 该插口；因超时被下面的 `kill` 结束的（退出码 143 / 137）表示复用进程活着但卡住，保留插口、记 `[ssh-mux]` 警告。然后 `rmdir`。否则这种目录不空，第 1 点的空目录扫除永远删不掉；
   - `rmdir` 失败（插口仍在）时 `log_warn "[ssh-mux] 复用连接未能确认关闭 dir=..."`，返回 0，不影响锁释放：下一次操作用新的 `MUX_DIR`，不会连到这个旧插口；复用进程最迟约 240 秒（出口机 120 秒、随后中转 120 秒，A13）后自行退出并删插口，空目录由第 1 点的扫除删掉。
   `-O exit` 只经本机插口通信，不走网络，不放进 `run_managed_external`；但复用进程活着却不应答（被暂停、卡死）时它会卡住，所以每次 `-O exit` / `-O check` 都放后台、最多等 3 秒，超时就 `kill` 该客户端进程并按“未能确认关闭”记警告，不让收尾卡住、锁不释放。整个函数体放进 stderr 重定向到 `/dev/null` 的子 shell `( … ) 2>/dev/null`，子 shell 的退出码即返回值（非交互 bash 回收被信号结束的后台任务时会打一行 `Terminated` 提示；bash 3.2 把它打到 shell 自身的 stderr，只给 `kill` / `wait` 加 `2>/dev/null` 挡不住，T11 实测），`wait` 写成 `if wait "$pid" 2>/dev/null; then exit 0; else exit $?; fi`，不依赖调用方处在 `||` 语境（`:9941`、`:1763`、`:1407`）里 errexit 被关闭。
6. **调用点**：`cleanup_operation_tmp`（`:9854`）在 owner 校验通过后、`find ... -delete` 之前调用 `close_mux_dir "${MUX_DIR}"`。`cleanup_stale_operation_tmp`（`:1331`）在 owner 校验（`:1340`）与目录名核对（`:1344`）通过后、`find ... -delete`（`:1345`）之前：`mux-dir` 文件存在时先 `require_secure_user_file <文件> 600`，读第一行，交给 `close_mux_dir`（它自己核路径格式、属主、权限）；文件不存在（旧版写下的目录）或校验不过就跳过，照旧删 `OP_TMP`，不让清理失败。过期清理有两条路径：没有锁文件时，任何命令（含只读命令）在 `init_operation_tmp` 开头经 `cleanup_stale_operation_tmp_dirs`（`:1099`、`:1383-1408`）清理已无主的操作目录；有过期锁时只有修改类命令在恢复中清理（`:1763`），只读命令直接报 `status=stale_lock`（`:10189-10202`），`cleanup_stale_operation_tmp_dirs` 也因锁文件存在直接返回（`:1385-1387`）。
7. **超时与被杀**：`run_managed_external` 的看门狗杀的是登记的 ssh 客户端进程（`:1418-1420`），复用进程是它 fork 出的后台进程，不在登记表里，也不需要登记：它不执行远端命令，只承载连接；随操作清理关闭，最迟约 240 秒（出口机 120 秒、随后中转 120 秒，A13）后自行退出。远端命令在客户端被杀后的处理由 §8 T7 与现状对照。
8. **重试前关掉复用连接**（用户 2026-10-31 依 T14 选定）：网络静默中断（不回 RST、只是不通）时，复用进程要等保活 `ServerAliveInterval 15` × `ServerAliveCountMax 2` 才判断线，T14 实测约 45 秒；这期间的新调用都发给这条死连接，只读命令的三次尝试（T14 实测分别在注入后第 12、27、44 秒失败）全部落在窗口内，最终报 `unreachable`，而现状每次新建连接、重试能走新连接。处理：新函数 `reset_mux_connections` 对本次 `MUX_DIR` 下的插口按 `e-` 再 `r-` 的顺序各做一次 `mux_control_with_timeout <插口> exit`（每个最多 3 秒，与 `close_mux_dir` 同一写法），不删目录、不做 `-O check`、不打日志；`MUX_DIR` 为空或不是目录直接返回 0，总是返回 0。`ssh_with_readonly_retry`、`negotiated_hostkey_fingerprint` 与 `remote_test_path` 在决定重试后、重试日志之前调用它，下一次尝试按配置（`ControlMaster auto`）重新建立中转与出口机的复用连接。两台都关，不按 `role` 只关一台：出口机调用经中转复用连接跳转（A2），出口机这一跳失败时假死的可能是中转那条。代价只在失败重试时多一次中转、一次出口机握手；`remote_test_path` 的 2 秒重试不看 `READONLY_SSH_RETRY`，deploy 的碰撞检查（基线 `:2624` 起经 `require_remote_path_absent`）、migrate-exit 里都会走到；不加重置时这次重试在静默中断窗口内同样发给死连接、失去作用，故一并处理。除这三处外修改类步骤仍不重试，与现状一致。保活参数不改。

### 5.2 接口变更

无对外接口变更：命令、参数、退出码、`status=` 输出格式不变。新增的只有本机临时目录 `/tmp/ownexit-mux.XXXXXX/`（操作期间存在，结束即删）和操作临时目录里的 `mux-dir` 文件（内部文件，不属于公开接口；owner 文件格式不变）。

**reference sibling 回补检查**（按「方案文档章节内容质量要求」§5）：

- Q1 涉及 reference 章节：`docs/reference/files.md` 的“内部文件”一段（`:44`）。
- Q2 源码暴露面完整性：该段列的是状态目录下的内部文件；操作临时目录 `${TMPDIR:-/tmp}/ownexit-chain.*`（`chain/setup_chain.sh:1104`）在全文 grep 不到，属既有缺漏。
- Q3 本方案是否回补：是，同一处补上 `ownexit-chain.*` 与新增的 `ownexit-mux.*` 两类本机临时目录（见 §4 对应行）。
- Q4 placeholder 落地：N/A（已回补）。

## 6. 备选方案与决策

- **只读步骤对 rc 255 重试**：用户 2026-10-31 未选。改动小，但修改类步骤在握手中途被断仍会中止部署。
- **复用 + 首次握手重试**：可以进一步降低失败率，但等于同时做两个方向，超出本次选定的范围；本版实测后若首次握手仍是主要失败点，另立方案。
- **插口放 `OP_TMP` 内**：A6 证明 macOS 上路径超限，否决。

## 7. 影响分析

正向：

1. `render_ssh_config` 的产物被全部 `ssh_relay` / `ssh_exit` / `*_stdin` / `scp_*` 使用（`:1956-1978`），以及指纹探测（`:2012`）、直连探测（`:2050`），并被同机探测整段复制（`:7246`）。前者改为复用（`scp_*` 只复用已有的复用连接、自己不新建：scp 给内部 ssh 加了 `-oControlMaster=no`，T3 在 8.2 上核；scp 恰好是某台服务器的第一个调用时，那一次照旧单独握手）；指纹探测显式不复用；直连探测与同机探测的 `chain-probe` 段由配置关闭复用，同机探测经中转的那一跳仍复用中转连接、仍严格校验。
2. `ssh_with_readonly_retry`（`:1926`，重试判断 `:1944`），以及主机指纹探测与 `remote_test_path` 的重试：复用连接断开时客户端返回 255（A9），与现状同一返回码，重试条件不变；重试前 `reset_mux_connections` 关掉本次的复用连接（§5.1 第 8 点），重试时 `ControlMaster auto` 新建复用进程（A3）。关连接时没有别的调用在用它：脚本按顺序调用 SSH（反向 2），被关的只有刚失败那次留下的空闲复用进程；关掉中转那条会连带出口机复用进程退出（A4），下一次出口机调用照常重建（A11）。`-O exit` 每个最多 3 秒，两台合计最坏 6 秒，只发生在已经要等 3 / 6 秒的重试上。
3. `run_managed_external` 的 600 秒总超时（`:58`）：复用进程卡死（网络静默）时，`ServerAliveInterval 15` × `ServerAliveCountMax 2` 理论约 30 秒（T14 实测约 45 秒）后复用进程自断，客户端返回 255，与现状单连接的断线判定相同。
4. 操作结束清理（`cleanup_dispatcher`，`:9865` 起）：`restore_and_disarm_fail_closed_watchdog` 等收尾 SSH 在 `cleanup_operation_tmp` 之前执行，复用进程仍在，可继续复用；`close_mux_dir` 在最后执行。锁保留（`release_chain_lock=0`）、不走 `cleanup_operation_tmp` 时，复用进程空闲后自行退出（最坏约 240 秒，A13）；插口目录由下一次修改类命令在过期锁恢复时经 `cleanup_stale_operation_tmp` 删掉（只读命令遇到过期锁只报 `status=stale_lock`，不清理），漏网的空目录一天后由 §5.1 第 1 点的扫除删掉。
5. 迁移出口机（`:8673`、`:8684`、`:8814-8818`、`:8967` 来回切换 `EXIT_*`）：切换后重新生成配置，新旧出口机按 host、端口、密钥标记各有各的插口，互不混用；旧出口机的复用进程留到操作结束由 `close_mux_dir` 统一关闭。
6. **复用进程尚未察觉断线的窗口（行为变化）**：网络静默中断、或随身 WiFi 换了路径 / 本机地址时，复用进程要等保活（`ServerAliveInterval 15` × `ServerAliveCountMax 2`，`:1898-1899`）判定断线，T14 实测约 45 秒。只读命令：重试前先关掉复用连接（§5.1 第 8 点），重试新建连接，与现状一样能在网络恢复后成功。修改类步骤：`remote_test_path` 的碰撞检查有一次 2 秒重试，重试前同样先关复用连接（§5.1 第 8 点）；其余修改类调用不重试，卡在死连接上的那次调用返回 255、部署中止，与现状“修改类步骤断连即中止”相同；差别只在“网络 45 秒内已从另一条路径恢复”时，现状下一次调用新建连接可能成功，本方案下一次修改类调用仍会发给死连接，部署更早中止，重跑即收敛。保活间隔不改（缩短会让丢包网络下已建立的连接更容易被误判断开），T14 记录 deploy 下的表现。实测：T14c（deploy 中复用主进程在会话建立前被断）旧复用进程约 44 秒后退出，客户端自己改走新连接（不返回 255、没有触发 2 秒重试），deploy 返回 0，比正常多耗约 45 秒；T14d（deploy 中途静默断掉中转复用连接）两次复现都返回 3（经中转访问出口机的 SSH 核验失败），去掉注入后重新 deploy 返回 0。

反向：

1. 并发：每次操作有自己的 `MUX_DIR`，多条链同时操作（`multi` 或用户开两个终端）互不连到对方的插口。
2. 远端：sshd 默认 `MaxSessions 10` 限制每条连接的并发会话数；脚本按顺序调用 SSH，同时只有一个会话；出口机跳转是端口转发通道，不占会话数。仓库内的服务端加固配置不设 `MaxSessions`（`grep -rn MaxSessions` 无结果）。
3. 进程身份核对：锁与登记表核对的是脚本自身和登记的 ssh 客户端（`:1137-1180`），复用进程改了进程标题（`ssh: <插口> [mux]`），不会被误认成登记的客户端。
4. 旧版本并存：owner 文件格式不变，新旧版本的 `operation_tmp_owner_matches`（`:1324`）都能校验对方写下的目录。旧版写下的目录没有 `mux-dir`，新版过期清理跳过关闭、照旧删；新版写下的目录被旧版过期清理时，旧版的 `find ... -delete`（`:1345`）顺带删掉 `mux-dir`，插口目录残留（复用进程最迟约 240 秒后退出并删插口（A13）），剩下的空目录无凭据，新版下次运行时按一天阈值扫除。回归见 T15。

运行时：

- 进程：每次操作多出最多两个后台 ssh 进程（中转、出口机各一）和一个跳转转发进程，操作结束即退。
- 频率 / 时间：后续调用省去 TCP + 密钥交换 + 认证，A1 实测单次由约 1 秒降到 0.17 秒；部署总耗时变化由 T1 记录。
- 部署形态：控制端 macOS / Linux（含 WSL）都用 `/tmp`。WSL 与容器里 `/tmp` 可写是现有 `mktemp` 已依赖的前提。
- 收尾耗时：正常情况下 `-O exit` 立即返回，插口随即消失；最坏情况（复用进程全部卡住）每个插口 `-O exit`、`-O check` 各 3 秒，加 2 秒等待，migrate-exit 有 3～4 个插口时收尾最多约 20～26 秒。
- 本机看门狗、Clash TUN：连接数变少，走向不变（仍是同样的目标地址和端口）。

## 8. 回归测试

环境：测试机测试床（`oxtb-ctl` / `oxtb-relay` / `oxtb-exit` 三个容器，辅助函数沿用 v2.3.1 的 `lib.sh`），源码以快照传入；T8 用本机对真实线路做只读命令。

| 编号 | 内容 | 判据 |
| ---- | ---- | ---- |
| T1 | 新代码 deploy → status → verify → rollback 全流程；新旧代码各跑一次，统计中转与出口机容器 `journalctl -u ssh` 里本次时间段的 `Accepted publickey` 行数，以及中转容器 `iptables -I INPUT -p tcp --dport 22 --syn -j ACCEPT` 计数器的 SYN 数 | 全部 rc=0、status healthy；新代码握手数明显少于旧代码，两组数字写进注记 |
| T2 | 控制端容器 `iptables -I OUTPUT -d <中转> -p tcp --dport 22 --syn -m statistic --mode random --probability 0.15 -j REJECT --reject-with tcp-reset`（注入一律加在控制端：服务器上有任何规则，部署预检都会判防火墙规则集非空），新旧代码各 deploy 10 次（每次后在去掉规则的情况下 rollback） | 只记录、不作通过条件：两组成功次数，以及按成功 / 失败分组的每次 deploy SYN 数；确定性的握手数判据在 T1 |
| T3 | 用 `render_ssh_config` 实际生成的配置（含 `ClearAllForwardings yes`、`RemoteCommand none` 等加固项），在 OpenSSH 8.2 客户端上复核 A1–A11 与 A13，并确认 `ssh -G` 的 `controlmaster` / `controlpath` / `controlpersist` 输出格式；确认复用进程已存在时 `scp` 能复用它（本机 OpenSSH 10.3 的 scp 给 ssh 加 `-oControlMaster=no`，只用已有连接、不新建，8.2 待核）；先记录测试床控制端容器的 `ssh -V`，不是 8.2 就另起 `ubuntu:20.04` 容器装 `openssh-client` 来跑 | 与 §3 表一致；A3 不成立时确认每次操作新目录不受影响；`check_ssh_effective_config` 的匹配写法与实测输出一致 |
| T4 | deploy、verify、status、migrate-exit（换机与同机两条路径）各跑一次；deploy 另跑失败（`OWNEXIT_TEST_DEPLOY_STOP_AFTER` 中途停）与 Ctrl-C（发 INT）两种结束方式。每次结束后检查 | 运行期间记下本次 `MUX_DIR` 与 `OP_TMP`；结束后 `pgrep -f '<本次 OP_TMP>/ssh_config'` 为空、`pgrep -f '<本次 MUX_DIR>/'` 为空、本次 `MUX_DIR` 已删；无 `[ssh-mux]` 警告 |
| T5 | deploy 中途 `kill -9` 脚本；先轮询到 `active-child.env` 里登记的 PID 已退出（否则 `lock_is_live` 经 `child_is_live` 判锁仍存活，`:1568-1569`，status 报 `status=busy`），再跑 status，再跑 deploy | status 输出 `status=stale_lock`、rc 5；从登记 PID 退出起轮询，先等 `e-` 插口消失、再等 `r-` 插口消失，各自不超过 130 秒（合计约 240 秒，A13），上次的复用进程都已退出；随后的 deploy 在过期锁恢复中删掉上次的 `MUX_DIR`，并正常完成 |
| T6 | 指纹探测：deploy 日志与 state 里的两端指纹正确；把出口机 host key 换掉后 status | 指纹与容器 host key 一致；换 key 后与现状同样报错（rc 与 `reason=` 不变） |
| T7 | `OWNEXIT_TEST_CHAIN_SSH_TIMEOUT=5` 下跑 status：status 放后台跑，控制端容器里每 0.2 秒查一次，`/tmp/ownexit-mux.*/` 下出现 `r-` 开头的插口（中转复用连接已建好）后立即在控制端容器 `iptables -I INPUT -s <中转> -p tcp --sport 22 -j DROP` 让连接静默（不加在中转上，理由同 T2）（旧代码没有插口，改为等 1 秒后加规则）；新旧代码各跑一次 | 新旧代码的 rc、`status=` 行、是否出现 `[ssh-retry]` 一致（超时不重试）；去掉规则后无本次复用进程残留 |
| T8 | 本机（macOS，必须在看门狗新代码启动后的会话或用户自己的终端里）对一条真实线路跑 `status` 与 `verify` | rc 与现状一致；运行期间插口路径长度 < 104、`ps` 可见 `[mux]` 进程；结束后按 T4 的判据无残留 |
| T9 | `ssh -G -F <直连配置> chain-direct-exit`；migrate-exit 同机路径的探测配置：测试床在控制端 PATH 前放一个 `ssh` 包装脚本，参数里含 `chain-probe` 时先对 `-F` 指向的配置跑 `ssh -G ... chain-probe` 并把输出追加到证据文件；插口目录用 `ssh -G -F <该配置> chain-relay | awk '$1=="controlpath"{print $2}'` 取 `dirname` 后 `ls`（`MUX_DIR` 是脚本内未导出的变量，包装脚本读不到）；最后不用 `exec`，而是调用真 ssh、记下退出码，探测结束后再 `ls` 插口目录，最后以同一退出码退出（探测前列目录必然只有 `r-`、`e-`，证明不了探测有没有建插口）；包装脚本内部所有 ssh 调用（两次 `-G` 和最后那次）一律用真 ssh 的绝对路径，否则参数里含 `chain-probe` 的那次 `-G` 会再次进入包装脚本、无限递归（探测配置在函数返回前就被删，`:7253-7259`，同机路径也没有停止钩子，只能当场取） | 两者都是 `controlmaster false`、无 `controlpath` 行；包装脚本在探测结束后记下的插口目录列表里只有 `r-`、`e-` 开头的插口 |
| T10 | 测试床内 v2.3.1 的既有回归（change-port、migrate-exit、同机直连、TUN 检测分支） | 与 v2.3.1 结果一致 |
| T11 | `bash -n` 与 `/bin/bash -n`（3.2）解析；`OWNEXIT_LANG=en` 下 `[ssh-mux]` 警告为英文；`/bin/bash`（3.2）下用 `kill -STOP` 暂停一个复用进程后跑 `close_mux_dir`，确认单次控制命令约 3 秒超时返回（143）、`close_mux_dir` 约 9 秒返回（`-O exit`、`-O check` 各 3 秒加 2 秒等待）、插口保留并有 `[ssh-mux]` 警告、stderr 无 `Terminated` 行，之后 `kill -CONT` 恢复 | 通过 |
| T12 | 迁移密钥标记：同一次 migrate-exit 里新旧出口机各自的插口名 | 新旧出口机插口不同名；`close_mux_dir` 把两者都关掉 |
| T13 | 过期空目录扫除：手工建一个属主为本用户、700、空、`touch -t` 改到两天前的 `/tmp/ownexit-mux.AAAAAA`，以及一个一天内的、一个非空的 | Linux 测试床与 macOS 本机各做一次；下一次 status（或其它会走到 `init_operation_tmp` 的命令；`init` 在 `:10164` 前提前分派、不扫除）后只有两天前的空目录被删 |
| T14 | 模拟“旧连接已断、新连接可通”（只测新代码，旧代码没有常驻连接、这种注入对它没有目标）：status 放后台，轮询控制端 `MUX_DIR` 直到 `r-` 插口出现（同 T7 的触发方式），立即在控制端容器 `ss -tnp` 取中转复用进程的本地端口，在控制端容器 `iptables -I OUTPUT -p tcp --sport <该端口> -j DROP`，只丢这条连接的出站包（不加在中转上，理由同 T2） | 记录 rc、耗时和 `[ssh-retry]` 行。status：注入后第一次调用返回 255，`[ssh-retry]` 之后的重试新建连接成功，最终 `status=` 行与注入前相同（改动前实测：三次尝试都发给死连接，最终 `unreachable`）；执行证据：`[ssh-retry]` 只出现 1 次，最终成功时刻早于注入后约 40 秒（排除“旧复用进程被保活判断线后自行重建”），重试前后中转复用进程的 pid 或本地端口不同；记录触发的是哪一条重试（带“主机指纹探测”字样的是指纹探测那处），指纹探测那处另做一次在其阶段注入的变体，覆盖不到就在报告里写明。deploy 下同样注入一次，记录是否中止与耗时；另做一次在碰撞检查阶段注入的 deploy（控制端包装脚本看到 `test ! -e` 命令时注入），应命中“SSH 连接被断开，2 秒后重试一次”且该次重试成功、deploy 继续；报告写明每次 deploy 是否命中这条 |
| T15 | 新旧版本并存，两个方向各做一次（新版留目录、v2.3.1 清理；v2.3.1 留目录、新版清理）。status 一开始就加锁（`:10190`，`acquire_lock_file` 无论是否修改类都建锁文件，`:1731`），被 `kill -9` 后一定留下锁文件，所以分两条路径：(a) 过期锁恢复：一方 status 进行到 `r-` 插口出现后 `kill -9`，先轮询到 `active-child.env` 里登记的 PID 已退出（同 T5，否则 deploy 在 `:5497-5498` 报“正被其它操作占用”），另一方再跑一次修改类命令（测试床已部署的链上重跑 deploy），走 `acquire_lock_file` 的过期锁恢复（`:1763`）；(b) 无锁清理：同样 `kill -9` 后，先等被杀进程留下的 ssh 客户端退出，再手工移走锁文件，以及 `local_deployment_residue_absent`（`:4928` 起）列出的子进程 / 本地进程登记文件（`active-child.env`、`local-process.env` 及其临时件）——真实路径里这些由过期锁恢复清理（`:1758-1759`），只移锁会让 status 报 `reason=deployment-residue`（`:4993`、`:9810`、`:9819`）；这是人为构造“无锁、只剩过期目录”，非真实路径。之后另一方跑一次 status，走 `cleanup_stale_operation_tmp_dirs`（`:1099`、`:1383-1408`） | (a) 恢复成功、命令正常完成，过期 `OP_TMP` 被删；(b) status 的 `status=` 行与跑 T15 前的基线相同（测试床基线为 `status=healthy`），过期 `OP_TMP` 被删；新版留下的那一方向，插口目录约 240 秒内（A13）只剩空目录 |

## 9. 日志 / 观测点

- `[ssh-mux]` WARN：复用连接未能确认关闭，带 `dir=`。正常路径不打日志（每次操作都会建复用连接，打 INFO 只是噪音）。
- 判断是否在复用：操作期间本次 `MUX_DIR` 下有 `r-` / `e-` 开头的插口，`ssh -F /dev/null -o ControlPath=<插口> -O check x` 返回 0；`ps` 里可见 `ssh: /tmp/ownexit-mux.../<名字> [mux]` 进程（A12，仅作辅助）。
- 握手次数：服务端 `journalctl -u ssh | grep -c 'Accepted publickey'`（T1、T2 用）。
- 既有观测点不变：`[ssh-retry]`、`status=` 行、`MANAGED_LAST_TIMEOUT` 超时分类。

## 10. 开放问题

- 已决（2026-10-31）：T14 实测复用进程约 45 秒才察觉静默断线，只读重试全部失败。用户选“重试前先丢掉旧连接”（§5.1 第 8 点），保活间隔维持 `ServerAliveInterval 15` × `ServerAliveCountMax 2`。
