# v0.6.0：`ownexit doctor` 诊断、出口 IP 体检、只读命令的 SSH 重试

> **2026-10-05 注记**：已落地并通过 §8 回归（本机 + Lima Ubuntu 22.04 arm64 虚拟机：T1-T11、T6a/T6b，R0（N=1/2/3）、R0b、R0c、R1、R3、R4；P1 / S1 以 CI 为准）。实现锚点：`direct/doctor.sh`（新文件）；`chain/setup_chain.sh` 的 `ssh_with_readonly_retry`（位于 `ssh_relay` 之前）、`negotiated_hostkey_fingerprint` 的重试循环、`run_managed_external` 的 `MANAGED_LAST_TIMEOUT`、`smoke_from_relay` 的 `local READONLY_SSH_RETRY=0`、`main` 里的开启条件、`OWNEXIT_TEST_CHAIN_SSH_TIMEOUT`。用户 2026-10-05 决定保留体检的 Claude 一项（本地禁用词表相应收窄为开发工具痕迹词）。

## 1. 背景

- 现在出问题时只能逐个跑 `subctl status`、`chain status`，本机侧的常见坑没有统一入口：本机代理 TUN 接管了到服务器的 SSH、shell 里设了 `http_proxy` 导致本机 curl 访问 VPS 失败、本机状态目录权限过宽（v0.4.0 修过的链式加锁失败）、密钥缺失。
- 本机开着代理 TUN 时，链式命令的 SSH 偶发被断开（返回 255），命令直接以退出码 3 或 5 结束（`chain/README.md` “出口机换 IP”一节末尾的注意事项）。现有代码只有 `remote_test_path` 对 255 重试一次（`chain/setup_chain.sh:2066-2085`）。
- 出口 IP 能不能用 AI 服务、流媒体，目前只能用户自己逐个打开网站试。
- 用户已确认的版本计划：v0.6.0 = 候选 14（`ownexit doctor`）+ 候选 11（TUN 下部署不稳：doctor 预警 + 只读 SSH 调用重试）+ 候选 6（出口 IP 体检：IP 归属与类型、AI 服务 ChatGPT / Claude / Gemini、流媒体 Netflix / YouTube / Disney+、常用网站连通性）。

## 2. 目标 / 非目标

目标：

1. 新增 `ownexit doctor`：检查本机环境、已记住的直连 VPS、已配置的链，逐项给出 OK / WARN / FAIL 与处理建议；不修改服务器配置与本机配置。
2. `ownexit doctor --ip-check`：在每台出口服务器上做出口 IP 体检，输出归属与类型、三项 AI 服务、三项流媒体、常用网站连通性。
3. 链式只读命令（`status`、不带 `--with-fail-closed` 的 `verify`、`conns`、`banlist`）的 SSH 连接层失败（255，且不是控制端 600 秒超时）时自动重试，修改类命令不重试。

非目标：

- 不自动修复任何问题（doctor 只给建议）。
- 修改类命令（deploy / rollback / rotate-keys / rehost-exit / rebaseline / ban 等）与 preflight 不加重试：重放一个已部分执行的操作没有幂等证据。
- verify 里的中转 smoke（`smoke_from_relay`）不重试（见 §5.1.4）。
- IP 体检不保证与各服务的最终判定一致（服务方随时改规则），不做定时监控，不检测 IP 黑名单 / 欺诈分。
- 不改动直连脚本的 SSH 调用。

## 3. 假设与约束

- doctor 放在 `direct/doctor.sh`（git 模式 100755）：沿用 `direct/*.sh` 的打包规则（`pyproject.toml` 的 `"ownexit.direct" = ["*.sh", ...]`）与 CI 的语法 / shellcheck / bash 3.2 通配，不新增包目录。pip 安装后 `ownexit/direct/` 与 `ownexit/chain/` 同在包目录下（`pyproject.toml` 的 `package-dir` 映射），`../chain/setup_chain.sh` 的相对路径成立；调用一律用 `bash <路径>`（pip 不保留可执行位，同 `cli.py`）。
- doctor 只用 bash 3.2 语法（不用关联数组、`mapfile`、`${var,,}`）；本机依赖 bash、ssh、awk、sed、grep，macOS 再用 route，Linux 再用 ip；不依赖 python3 与 jq。
- doctor 读直连目标时 `source` 同目录的 `target_lib.sh`，复用 `read_target_file` 与 `target_safe_name`，目录规则沿用其 `${XDG_CONFIG_HOME:-${HOME}/.config}`；读链配置时目录规则沿用链式的 `xdg_or_default`（`chain/setup_chain.sh:502-511`：XDG 变量不是绝对路径时回落默认值），doctor 内复制该函数并注明来源。链配置按行 `awk -F=` 取键，不 source。
- IP 体检在出口服务器上执行（检测的是服务器出口 IP，与客户端走什么网络无关），服务器侧只用 curl（直连与链式部署时都已要求）；所有请求强制 IPv4（`curl -4`，与直连 / 链式出口的 `prefer_ipv4` 以及链式出口仲裁的 `wget --inet4-only`（`chain/setup_chain.sh:2042`）一致）。
- 各服务判定依据（§5.1.3 表）来自对公开接口的观察：“可用”一侧已在美国家用宽带 IP 上实测得到对应返回；“不可用”一侧的标记没有不支持地区的机器可实测，认不出的返回一律显示“无法判断”。
- 链式重试的“只读”以命令为单位：远端不写持久文件。`status` / `verify` 的中转核验脚本可能执行一次 `systemctl start` 拉起 socket 激活的 relay service（`chain/setup_chain.sh:4484-4487`），属于幂等动作；远端预检脚本只在 `/tmp` 用 mktemp 并自行删除。
- doctor 的 SSH 一律隔离用户配置：`-F /dev/null -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=8`（ProxyCommand 里的那层 ssh 同样），保证不写 known_hosts、不受用户 `~/.ssh/config` 影响。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main 089a2ab） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `direct/doctor.sh` | 新文件（`git update-index --chmod=+x`） | 新增 | doctor 全部逻辑，含远端只读检查与 IP 体检脚本（heredoc） |
| `src/ownexit/cli.py` `COMMANDS` | 18-24 | 修改 | 新增 `"doctor": (direct/doctor.sh, …)` |
| `src/ownexit/cli.py` `_usage` 示例 | 39-44 | 修改 | 加 `ownexit doctor` 示例 |
| `chain/setup_chain.sh` 全局变量 | 69（`WITH_FAIL_CLOSED=0`）邻近 | 新增 | `READONLY_SSH_RETRY=0`、`MANAGED_LAST_TIMEOUT=0` |
| `chain/setup_chain.sh` `MANAGED_CHILD_TIMEOUT_SECONDS` | 49 | 修改 | 允许测试变量 `OWNEXIT_TEST_CHAIN_SSH_TIMEOUT`（正整数）覆盖默认 600；仅供 R0c |
| `chain/setup_chain.sh` `run_managed_external` | 1053 函数开头；1172-1176 超时分支 | 修改 | 开头置 `MANAGED_LAST_TIMEOUT=0`，超时分支置 1（其余逻辑与返回值不变） |
| `chain/setup_chain.sh` 新函数 `ssh_with_readonly_retry` | 1550 之前 | 新增 | 重试逻辑（§5.1.4） |
| `chain/setup_chain.sh` `ssh_relay` / `ssh_exit` / `ssh_relay_stdin` / `ssh_exit_stdin` | 1550-1564 | 修改 | 改为调用 `ssh_with_readonly_retry` |
| `chain/setup_chain.sh` `negotiated_hostkey_fingerprint` | 1591-1619 | 修改 | 只读重试开启时，对 `run_managed_external` 调用做同样的重试；每次尝试前删除并以 noclobber 重建 debug 文件 |
| `chain/setup_chain.sh` `smoke_from_relay` | 3893 函数开头 | 修改 | `local READONLY_SSH_RETRY=0`（smoke 不重试） |
| `chain/setup_chain.sh` `main` | 7470（`init_operation_tmp`）之后 | 新增 | `status` / `conns` / `banlist`、以及 `WITH_FAIL_CLOSED=0` 的 `verify` 置 `READONLY_SSH_RETRY=1` |
| `.github/workflows/ci.yml` | 40-41、66 | 修改 | help 冒烟加 `direct/doctor.sh`，包安装冒烟加 `doctor` |
| 文档 | README 两份、`direct/README.md` 脚本表（14-17）、`docs/manual/direct.md` §6/§7、`docs/manual/chain.md` §5/§8、`chain/README.md` 命令与注意事项、`CHANGELOG.md`、`src/ownexit/__init__.py` | 修改 | 新命令、重试行为、版本 0.6.0 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 命令行

```text
ownexit doctor [--host <ip> [--port <n>] [--user <u>]] [--chain <id>] [--ip-check] [--local-only] [-h|--help]
```

- 不带目标参数：本机检查 + 直连目标目录下全部 `*.env` + 链配置目录下全部 `*.env`。
- `--host`：只查这一台直连 VPS（端口、用户默认 22 / root，与 `subctl` 相同）；`--chain <id>`：只查这一条链；两者可同时给。
- `--ip-check`：对选中的每台出口服务器追加 IP 体检（直连 = VPS 本身，链式 = 出口机）。
- `--local-only`：只做本机检查，不连任何服务器（与 `--ip-check`、`--host`、`--chain` 互斥）。
- 退出码：0 没有 FAIL（可以有 WARN）；1 至少一项 FAIL；2 参数错误。

输出：每项一行 `[OK] / [WARN] / [FAIL] <分组> <项目>：<说明>`，WARN / FAIL 后另起一行 `      建议：<可执行的处理办法>`；最后一行 `doctor: ok=<n> warn=<n> fail=<n>`。

#### 5.1.2 检查项

本机（总是执行）：

| 编号 | 项目 | 判定 |
| ---- | ---- | ---- |
| L1 | 系统与 bash | 打印 `uname -sm` 与 bash 版本；bash < 3.2 为 FAIL |
| L2 | 必需命令 | 直连：ssh、scp、ssh-keygen、curl、openssl、base64，缺任一 FAIL；expect 缺失 WARN（只影响首次配免密）；qrencode 缺失 WARN（只影响二维码）。有链时再查链式依赖：两平台都要 tar、awk、mkfifo；macOS 要 nc 与 route，Linux 要 ip 与 timeout（与 `chain/setup_chain.sh:1645-1649` 的 `tcp_probe` 及 `route_interface` 一致），缺任一 FAIL；`ssh -E /dev/null -V` 不支持（链式主机指纹探测依赖 `-E`，`:1656`）为 FAIL。链式完整依赖清单在 `:1653`，L2 只查常见项，缺其它命令时由 C1 带出 status 的 ERROR 行 |
| L3 | 代理环境变量 | `http_proxy` / `https_proxy` / `all_proxy`（含大写）任一非空为 WARN，建议把 VPS / 中转 IP 加进 `no_proxy` 或在运行前 `unset` |
| L4 | 本机目录权限 | 按链式的实际要求：`${STATE_HOME}/ownexit`（shared lock 所在，`:723`、`:1352`）、`${CONFIG_HOME}/ownexit/chains` 与每个 `${STATE_HOME}/ownexit/chains/<id>`（`:455-460`）存在而权限不是 700 为 FAIL；`${CONFIG_HOME}/ownexit` 被 group / other 可写为 FAIL（`:440-451` 的祖先检查），是 755 等不可写但可读的权限为 WARN；`~/.ssh/ownexit` 被 group / other 可写为 WARN |
| L5 | TUN 路由 | 对每个目标 IP（直连 HOST、链的 RELAY_HOST 与 EXIT_HOST）取本机出接口（复制 `chain/setup_chain.sh:330-343` 的 `route_interface` / `interface_is_tunnel` 并注明来源）；是 TUN 为 WARN，建议关闭 TUN 或让该 IP 走直连 |

直连 VPS（每台，`--local-only` 时跳过）：

| 编号 | 项目 | 判定 |
| ---- | ---- | ---- |
| D1 | 密钥 | `~/.ssh/ownexit/id_ed25519_<safe_name>` 存在、属于当前用户、group / other 无权限（同 `chain/setup_chain.sh:428-436` 的私钥判据），否则 FAIL（建议重跑 `ownexit direct --host …` 配免密） |
| D2 | SSH | `ssh -n -i <key> -p <port>` 加 §3 的隔离选项执行 `true`。成功 OK；失败时按以下顺序匹配 stderr（主机指纹变化时两种文案同时出现，必须先匹配前者）：含 `REMOTE HOST IDENTIFICATION HAS CHANGED` 为 FAIL“主机指纹与记录不符”；含 `Host key verification failed` 为 FAIL“known_hosts 没有这台机器的记录”；含 `Permission denied` 为 FAIL“免密失效”；其它为 FAIL“连不上”，附 stderr 最后一行。D2 失败时跳过 D3-D5 |
| D3 | 直连服务 | 远端只读脚本输出 `KIND`、`ACTIVE`、`PORT`、`LISTENING`。`KIND` 判据照搬 `direct/subctl:121-125`：`/etc/systemd/system/ownexit-direct.service` 存在为 ownexit，否则 `/usr/local/bin/sb` 是软链为 legacy，否则 none。`PORT` 只用 `awk -F= '$1=="PORT"'` 从 `/etc/ownexit-direct/client.env` 取（不整份读出，文件里有 UUID）。判定：ownexit 且 active 且端口监听 OK；ownexit 其它情况 FAIL（建议 `ownexit subctl log`）；legacy 且 active 为 WARN（建议 `--migrate`），legacy 未运行为 FAIL；none 为 FAIL（建议 `ownexit direct`） |
| D4 | 订阅服务 | active 为 WARN（建议平时 `ownexit subctl stop`），否则 OK |
| D5 | BBR | `sysctl -n net.ipv4.tcp_congestion_control` 为 bbr 是 OK，否则 WARN（重跑 `ownexit direct` 会开启） |

远端只读脚本经 `ssh … 'bash -s' < 脚本` 投递，脚本内命令都带 `< /dev/null`。

链（每条，`--local-only` 时跳过）：

| 编号 | 项目 | 判定 |
| ---- | ---- | ---- |
| C1 | 状态 | 运行 `bash <包目录>/chain/setup_chain.sh --id <id> status < /dev/null`，分别收 stdout、stderr 与退出码。stdout 最后一行以 `status=` 开头时：`status=deployed health=healthy` 为 OK；`status=not_deployed` 为 WARN；其它为 FAIL，建议原样转述其中的 `next=`。stdout 没有 `status=` 行时（配置错误、依赖缺失、锁不安全，`die` 只写 stderr）为 FAIL，附退出码与 stderr 最后一条 `ERROR` 行 |

C1 的副作用（如实写进帮助与文档）：`status` 取该链的排他操作锁（`chain/setup_chain.sh:1347-1367`），运行期间（约 10-30 秒）同一条链的 deploy / verify 等会得到 busy；它会在 `${TMPDIR:-/tmp}` 建临时操作目录（`:734`，结束即删），并在本机状态目录写 operation.lock 与 active-child.env（结束即删）；可能在中转机执行一次幂等的 `systemctl start`。doctor 不改服务器配置、不改本机配置与状态文件。

#### 5.1.3 出口 IP 体检

在出口服务器上执行一个只读 bash 脚本（doctor 内 heredoc，经 `bash -s` 投递）；链式经中转登录出口机，known_hosts 查找键与链式自身一致（`HostName=EXIT_HOST`，`chain/setup_chain.sh:1512-1516`）：

```text
ssh -F /dev/null -i <EXIT_SSH_KEY> -p <EXIT_SSH_PORT> \
    -o ProxyCommand="ssh -F /dev/null -i <RELAY_SSH_KEY> -p <RELAY_SSH_PORT> -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -W %h:%p root@<RELAY_HOST>" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=8 root@<EXIT_HOST> 'bash -s'
```

脚本里每个请求都是 `curl -4 -sS -m 12 -A '<桌面浏览器 UA>' … < /dev/null`，输出 `KEY=VALUE` 行，本机渲染成中文。判定优先级：请求失败（curl 非 0 或 HTTP 码 000）一律先判“无法判断（请求失败）”，其余按下表：

| 项目 | 请求 | 判定 |
| ---- | ---- | ---- |
| 出口 IP 与归属 | `http://ip-api.com/json/?fields=status,country,countryCode,city,isp,org,as,hosting,proxy,mobile,query` | 用 sed 取字段；`hosting=true` 显示“机房 IP”，`mobile=true` 显示“移动网络”，都为 false 显示“非机房（家用或商用宽带）”；`proxy=true` 追加“被标记为代理”；`status` 不是 success 为“无法判断” |
| ChatGPT | `https://chatgpt.com/cdn-cgi/trace` 取 `loc=`；`https://api.openai.com/compliance/cookie_requirements` | 后者含 `unsupported_country` 为“不可用”，含 `cookie_consent_required` 为“可用”，其它“无法判断”；附地区 `loc` |
| Claude | `POST https://api.anthropic.com/v1/messages`（`content-type: application/json`，空 JSON，无密钥） | HTTP 401 且含 `authentication_error` 为“可用”；HTTP 403 为“不可用”；其它“无法判断” |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/models?key=invalid` | 含 `API key not valid` 为“可用”；含 `User location is not supported` 为“不可用”；其它“无法判断” |
| Netflix | `https://www.netflix.com/title/81280792`（自制剧）、`https://www.netflix.com/title/70143836`（授权剧） | 两个都 200 为“完整解锁”；只有自制剧 200 为“仅自制剧”；两个都是 403 或 404 为“不可用”；其它“无法判断” |
| YouTube Premium | `https://www.youtube.com/premium`（`Accept-Language: en`） | 含 `Premium is not available in your country` 为“不可用”；含 `ad-free` 为“可用”；其它“无法判断” |
| Disney+ | `https://www.disneyplus.com/`（不跟随跳转） | 跳转地址含 `unavailable` 为“不可用”；HTTP 200 为“可访问（未验证内容库）”；其它“无法判断” |
| 常用网站 | google.com、youtube.com、github.com、wikipedia.org、x.com、telegram.org 的 `https://` 首页 | HTTP 码 2xx / 3xx 为“通”，附 `time_total`；其它为“不通” |

体检结果不计入 OK / WARN / FAIL 汇总（它描述的是 IP 属性，不是部署故障）；整段打印在对应服务器的检查之后，标题注明“结果仅供参考，以服务方实际为准”。SSH 失败时该段显示“未执行（SSH 失败）”。每台服务器 15 个请求，单个最多 12 秒。

#### 5.1.4 链式只读命令的 SSH 重试

`run_managed_external`（`chain/setup_chain.sh:1053`）：函数开头置 `MANAGED_LAST_TIMEOUT=0`；1172-1176 的超时分支（返回 255 之前）置 `MANAGED_LAST_TIMEOUT=1`。返回值与其余逻辑不变。

新函数（插入 `:1550` 之前）：

```bash
# 只读命令（READONLY_SSH_RETRY=1）下，SSH 返回 255 且不是控制端 600 秒超时时重试，最多 3 次，间隔 3 / 6 秒。
# 255 也可能是认证失败或主机指纹不符，这种情况会白等 9 秒后照样失败，可以接受。
# 每次尝试的 stdout 先写临时文件，只把最后一次的输出交给调用方，避免失败那次的半截输出混进结果；
# 经 stdin 投递脚本的调用先把 stdin 缓存成文件，每次尝试都从头读。非 255 或超时直接返回，不重试。
ssh_with_readonly_retry() { ... }
```

- 参数：`<role> <stdin|nostdin> <ssh 参数...>`；`READONLY_SSH_RETRY` 不为 1 时与现在完全一样（直接 `run_managed_external ssh ssh …`，stdin / stdout 不经临时文件）。
- 缓存与输出文件放在 `${OP_TMP}`（文件名带尝试序号，进程退出时随 OP_TMP 整体清理）。
- 每次重试 `log_warn "[ssh-retry] role=<relay|exit> attempt=<n>/3 rc=255，<秒> 秒后重试（只读命令）"`。
- `negotiated_hostkey_fingerprint`（`:1591-1619`）：开启只读重试时，`run_managed_external … -vv -E "${debug_file}" …` 同样最多尝试 3 次（条件同上）；每次尝试前 `rm -f` 并以 noclobber 重建 debug 文件（`-E` 是追加写，残留前一次的 `Server host key` 行会让后面的 `count != 1` 判定失败）。
- `smoke_from_relay`（`:3893`）开头 `local READONLY_SSH_RETRY=0`：远端 smoke 在中转机临时起 sing-box 监听固定端口，前一次被断开的那次可能仍占着端口，重试会以非 255 失败并误报“Reality smoke 失败”；它保持原样不重试。
- `remote_test_path` 自带的一次重试保留（只在 preflight / deploy 路径上被调用，这些命令不开启只读重试，不会叠加）。
- `main`（`:7470` 之后）：`case "${COMMAND}" in status|conns|banlist) READONLY_SSH_RETRY=1 ;; verify) [[ "${WITH_FAIL_CLOSED}" == 1 ]] || READONLY_SSH_RETRY=1 ;; esac`。
- 已知限制：`probe_exit_tls`（`:2024`）与 nft 回读（`:4525`）的调用带 `2>&1`，这两处的 `[ssh-retry]` 行会被并进被捕获的输出、不显示在终端；重试本身照常生效。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit doctor` / `direct/doctor.sh` | 新增命令及其参数、退出码 0/1/2 | 新增 |
| 链式 `status` / `verify` / `conns` / `banlist` | SSH 255（非超时）时最多重试 3 次，stderr 多出 `[ssh-retry]` WARN 行 | 输出格式与退出码不变；只是不再因单次断开而失败 |
| 其它链式命令 | 无 | 不变 |

不涉及 `docs/reference/*`，无需 sibling 回补检查。

## 6. 备选方案与决策

- 重试放在 `run_managed_external` 内部：它还被 scp 与修改类路径共用，判断“是否只读”要在更深处传递；否决，放在 ssh 封装与主机指纹探测处、按命令开启。
- IP 体检在本机执行（经客户端代理）：结果取决于本机代理软件和规则，测的不一定是出口 IP；否决，在服务器上直接请求。
- 用第三方体检脚本：要在服务器上下载执行外部脚本，与“不引入第三方程序”冲突；否决，内置最小判定。
- doctor 不调用 `status`、自己实现链的检查：要复制主机指纹、资源哈希等大量逻辑；否决，接受 `status` 取锁的副作用并写进文档。

## 7. 影响分析

正向：

- `ssh_relay` / `ssh_exit` / `ssh_relay_stdin` / `ssh_exit_stdin` 与 `negotiated_hostkey_fingerprint` 是 status / verify / conns / banlist 路径上全部的 SSH 调用（另有 `probe_ssh_and_fingerprints` 的直连探针 `:1634` 只在 preflight / deploy 路径）。`READONLY_SSH_RETRY=0` 时新逻辑直接走原来的 `run_managed_external`，修改类命令的行为、输出与时序不变（§8 R3、R4）。
- 只读命令路径上的调用点（status / verify / conns / banlist 共 20 余处）都是 `x="$(…)"` 捕获、`>/dev/null` 或只看退出码，`*_stdin` 都是 `< "${script}"` 从文件读入；输出改为“尝试结束后一次性交给调用方”不影响它们（§8 R1、R2）。scp 不在这四条命令的路径上。
- `run_managed_external` 多写一个全局变量，不改变返回值；所有调用方行为不变。
- `status` 的 `systemctl start` 在重试时可能执行两次，对已 active 的单元无副作用。
- `cli.py` 多一个子命令：`ownexit --help` 列表多一行，其它子命令不变（§8 P1）。

反向：

- doctor 的 C1 调用 `status`：取同一条链的排他锁，doctor 运行期间同一条链的其它命令得到 busy（§8 T10）；反过来别的命令正在运行时，C1 显示 `status=busy` 为 FAIL 并给出 `next=retry-status`。
- doctor 的直连检查与 IP 体检不写 known_hosts、不受用户 `~/.ssh/config` 影响（§3 的隔离选项）。
- 直连脚本、subctl、多链聚合不受影响。

运行时：

- doctor 每台直连 VPS 约 3 次 SSH；每条链一次 `status`（约 10-30 秒；开启重试后每个 SSH 调用最多多 9 秒，最坏按调用数累加）。IP 体检每台服务器 15 个请求，最坏约 3 分钟。
- 重试只在非超时的 255 时发生，每个 SSH 调用最多多等 9 秒；控制端 600 秒超时不重试。

## 8. 回归测试

确定性用例在本机执行（假 ssh），集成用例在本机临时 Lima 虚拟机上执行（直连 1 台、链式中转与出口各 1 台），测完删除 Lima。凡写“重跑”的用例不带测试变量。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| T1 | `ownexit doctor --local-only` | 输出 L1-L5；汇总行存在；退出码与汇总一致 |
| T2 | 设置 `http_proxy` 后 `--local-only` | L3 为 WARN 并给出建议 |
| T3 | 把隔离 XDG 的 `${STATE_HOME}/ownexit` 改成 755 后 `--local-only`；再把 `${CONFIG_HOME}/ownexit` 改成 755 | 前者 L4 FAIL、退出码 1；后者 L4 WARN |
| T4 | 已部署直连 + 链，`ownexit doctor` | D1-D5 与 C1 输出；直连订阅服务开着时 D4 为 WARN，`subctl stop` 后为 OK |
| T5 | 停掉直连服务后 `doctor --host <ip>` | D3 为 FAIL 并建议 `subctl log`；退出码 1 |
| T6a | known_hosts 里这台 VPS 的条目换成另一台机器的指纹 | D2 FAIL“主机指纹与记录不符” |
| T6b | 删掉这台 VPS 的 known_hosts 条目 | D2 FAIL“known_hosts 没有这台机器的记录”；known_hosts 未被写入 |
| T7 | `doctor --ip-check` | 直连 VPS 与链出口机各有一段体检输出，每项都是表中定义的取值之一；不计入汇总 |
| T8 | 链 init 后未 deploy 时 doctor | C1 为 WARN（not_deployed） |
| T9 | 参数错误（`--local-only --ip-check`、未知参数）与 `--help` | 退出码 2 / 0 |
| T10 | 链 `verify` 运行中同时跑 `doctor --chain <id>` | C1 为 FAIL，转述 `next=retry-status`；verify 不受影响 |
| T11 | 链配置文件改坏（删一个必需键）后 doctor | C1 为 FAIL，附退出码 2 与 stderr 的 ERROR 行 |
| R0 | 确定性：PATH 前置假 `ssh`（前 N 次返回 255、之后转调真 ssh），对已部署链跑 `status` 与 `verify`，N=1、2 | stderr 的 `[ssh-retry]` 行数等于 N，命令最终成功；N=3 时命令失败且 `[ssh-retry]` 为 2 行（共 3 次尝试） |
| R0b | 确定性：假 ssh 对 `-vv -E` 调用（主机指纹探测）返回 255 一次 | `status` 成功，`[ssh-retry]` 1 行 |
| R0c | 确定性：把 `MANAGED_CHILD_TIMEOUT_SECONDS` 调小，假 ssh 睡眠超过它 | 超时后不重试（无 `[ssh-retry]`），按原逻辑报不可达 |
| R1 | 集成：链 `verify` 期间在中转机上 `ss -K` 断开本机的 SSH 一次 | 断开命中只读调用时出现 `[ssh-retry]` 且最终通过；命中 smoke 时按原逻辑失败（smoke 不重试） |
| R3 | 修改类命令（`rotate-keys`）配合 R0 的假 ssh（N=1） | 不重试：按原有逻辑失败（退出码 1 或 3），不出现 `[ssh-retry]`；重跑收敛 |
| R4 | 无断开时 `verify` / `status` | 输出与 v0.5.0 相同，无 `[ssh-retry]` 行 |
| P1 | CI 包安装冒烟 | `ownexit doctor --help` 退出 0；`ownexit --help` 列出 doctor |
| S1 | CI | lint、shellcheck、help 冒烟、隐私扫描通过 |

假 ssh 约定（R0 / R0b / R0c / R3 共用，放在测试目录，PATH 前置）：只有参数里含 `-F <…>/ssh_config` 且不含 `-W` 的调用才计数，并按计数在前 N 次返回 255；其余调用（`require_local_dependencies` 的 `ssh -E /dev/null -G …` 能力检查 `:1656`、ProxyJump 拉起的内层 ssh 等）一律 `exec /usr/bin/ssh "$@"` 绝对路径转调真 ssh，避免递归与计数被打乱。R0c 的假 ssh 用不 exec 的 `sleep` 子进程睡眠（保留假 ssh 自身命令行，`child_is_live` 才认得出它，看门狗才会走超时 → 255 那条路，`:789-811`）。

R0c 需要把 600 秒超时改小：`MANAGED_CHILD_TIMEOUT_SECONDS=600`（`:49`，普通全局变量）编码时改为允许测试变量 `OWNEXIT_TEST_CHAIN_SSH_TIMEOUT`（正整数）覆盖，正常使用不设置。

## 9. 日志 / 观测点

- doctor：每项一行 `[OK] / [WARN] / [FAIL]`，末行 `doctor: ok=<n> warn=<n> fail=<n>`；IP 体检段标题 `== 出口 IP 体检：<服务器> ==`。
- 链式重试：stderr `[chain][<命令>] WARN [ssh-retry] role=<relay|exit> attempt=<n>/3 rc=255，<秒> 秒后重试（只读命令）`；最终失败时沿用原有 die 信息。
