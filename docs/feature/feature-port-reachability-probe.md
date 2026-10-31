# 换端口前先测本机能否连上：链式 / 直连 `change-port`

> **2026-10-30 注记**：已落地。链式探测在 `chain/setup_chain.sh` 的 `chport_probe_ports` / `chport_probe_stop`（约 :3645-3750），选端口段约 :8410-8451；直连在 `direct/setup_direct.sh` 的 `direct_probe_ports` / `direct_probe_stop`（约 :888-1005），change-port 选端口段约 :1046-1075；`tcp_probe` 实际放在 `server_port_in_use` 之后（约 :755），不在 §4 写的 `interface_is_tunnel` 之后，功能无差别。Docker 测试床（Ubuntu 22.04 与 20.04 / systemd 245）跑完 §8 全部用例并通过；真实线路未测。

## 1. 背景

- 链式 `change-port`（`docs/feature/feature-chain-relay-port.md`）选新端口时只看“中转上空闲”：不给 `--port` 时由 `choose_remote_port relay` 在 20000–59999 里随机取一个空闲端口（`chain/setup_chain.sh:3492-3513`，在 `change_port_chain` 的 `:8197` 调用）。那份方案把“自动判断哪个端口在用户当前网络下能通”列为非目标（同文 §2）。
- 2026-10-30 的实际处置（Grok 会话）：38.244 上直连（ads-lisa-90）与链 main（ads-lisa-90to136）各有一个端口回程被丢。它先在服务器上用 python3 临时监听 8 个随机候选端口（约 16 秒后自动退出），从本机逐个发起 TCP 连接，确认回程能通，再用 `chain --id main change-port --port <n>` 与 `ownexit direct up --proxy-port <n>` 换到验证过的端口，最后 `chain --id main rebaseline`；两条都恢复。
- 直连没有 `change-port` 子命令，换端口要写 `ownexit direct up --proxy-port <n>`，必须自己挑端口。改参数路径会保留 UUID、密钥、订阅端口与令牌（`direct/setup_direct.sh:755-794`；端口检查 `:771-772`），订阅地址不变。
- 直连的 `--port` / `-P` 已经表示 SSH 端口（`direct/setup_direct.sh:244-246`），新端口只能用已有的 `--proxy-port` 指定。
- 远端工具：
  - 直连服务器部署时就要求有 python3（`direct/setup_direct.sh:418-421`），并且会在 ufw 已启用时放行代理端口（`:1134-1139`）。
  - 链式中转的平台预检不要求 python3（必备命令清单在 `chain/setup_chain.sh:2253`，含 `systemd-run`、`ss`、`timeout`），但要求 ufw 未启用、iptables 没有规则（`:2294-2301`）。
- 本机侧已有：到某 IP 的出接口判定 `route_interface` / `interface_is_tunnel`（`chain/setup_chain.sh:576-589`，直连有同一实现 `direct/setup_direct.sh:344-354`），以及限时 TCP 探测 `tcp_probe`（`chain/setup_chain.sh:591-602`，直连没有）。

## 2. 目标 / 非目标

目标：

1. 新增 `ownexit direct change-port [--proxy-port <n>] [--no-probe]`：已部署的直连服务器只换代理端口；不给 `--proxy-port` 时自动挑一个端口。凭据、订阅端口与令牌不变，效果与 `direct up --proxy-port <n>` 相同。
2. 链式 `change-port` 与直连 `change-port` 在改服务器之前先做“回程探测”：服务器上临时监听候选端口，本机逐个 TCP 握手，只采用本机能连上的端口；指定了端口时只测这一个，连不上就拒绝，服务器零改动。
3. 探测做不了（本机经 TUN、服务器没有 python3、直连服务器 ufw 已启用、临时监听没起来）时打一行警告并按原方式继续；`--no-probe` 关闭探测。

非目标：

- `direct up --proxy-port` 不加探测，行为不变。
- 不探测 TCP 握手之后的阻断（握手成功、TLS 被重置这类），也不验证代理协议本身；链式 change-port 换完后的本机冒烟与 `full_verify` 照旧负责这部分。
- 不改防火墙、云安全组；不做“换端口失败自动再换”。
- 不处理同机直连 + 链换端口的顺序问题（先 `chain change-port`、再直连换端口、最后 `chain rebaseline`）：直连改端口后已有 `print_chain_hints`（`direct/setup_direct.sh:480-496`）提示 rebaseline，本方案只在 manual 里写清顺序。

## 3. 假设与约束

- 探测结论只代表“运行命令的这台电脑当前所在的网络”。手机等其它网络能不能连不保证；帮助与 manual 写明。
- TCP 握手只要服务器内核在该端口处于 listen 状态就会完成，不需要应用层应答；所以临时监听只需 bind + listen，accept 后立即关闭连接。
- 远端临时监听由 `systemd-run` 托管为临时 service，`RuntimeMaxSec=90` 到点由 systemd 杀掉，`--collect` 让它退出后不留单元。本机正常结束时主动 stop；SSH 中途断开、本机被 Ctrl+C 时靠 90 秒兜底。最低支持系统 Ubuntu 20.04（systemd 245），`--collect`（systemd 236 起）可用；20.04 上的实际行为未实测，§8 C1b 在 20.04 容器里跑一次。
- 只测 IPv4：链式中转监听 `0.0.0.0`（同文 §1），临时监听也绑 `0.0.0.0`；目标地址不是 IPv4 字面量时跳过探测。
- 候选端口 8 个，在 20000–59999 内随机，排除当前端口（直连另排除订阅端口）；被占用的端口由远端 bind 失败自然剔除。每个端口本机连接限时 3 秒。最坏耗时：启动等待 10 秒 + 9 次连接（8 个候选 + 当前端口对照）× 3 秒 = 37 秒，加两次 SSH，低于 90 秒兜底。
- 测试钩子 `OWNEXIT_TEST_PROBE_CANDIDATES`（空格分隔的端口列表）替代随机候选，`OWNEXIT_TEST_PROBE_STOP_AFTER=start`（远端临时监听启动后本机立即以 99 退出）只供测试，与其它 `OWNEXIT_TEST_` 钩子同一口径（`docs/reference/commands.md:349`）。

## 4. 涉及模块

| 区域 | 行号锚点（main c37c33d） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| chain 全局变量 | `chain/setup_chain.sh:98-99` 邻近 | 新增 | `CHPORT_NO_PROBE=0` |
| chain 帮助（英 / 中） | `:213`、`:252-255`、`:294`、`:335-336`、`:367`、`:398-400`、`:431`、`:468-469` | 修改 | 用法行加 `[--no-probe]`；说明“换前先测本机能否连上”；参数表加 `--no-probe`；示例加一行 |
| chain 参数解析 | `:873-881`（change-port 分支） | 修改 | 接受 `--no-probe`（只能给一次）；错误文案改为“只接受可选的 --port <n> 与 --no-probe” |
| chain 远端探测脚本 | `:3475` `write_port_check_script` 之后 | 新增 | `write_port_probe_script`（§5.1.1） |
| chain 探测流程 | `:3492` `choose_remote_port` 之后 | 新增 | `chport_probe_ports`（§5.1.2），设置 `PROBE_STATUS` / `PROBE_PORT` |
| chain change-port 选端口 | `:8180-8198` | 修改 | 指定端口：端口检查 free 之后探测该端口；随机：先探测，`PROBE_STATUS=skipped` 才回落 `choose_remote_port relay`；`already` 分支不探测（§5.1.3） |
| direct 全局变量 | `direct/setup_direct.sh:53` 邻近 | 新增 | `CHANGE_PORT=0`、`NO_PROBE=0` |
| direct 帮助（英 / 中） | `:79-84` 与 `:138-143` 示例段、`:86-92` 与对应中文维护段、`:110` / `:169` 参数段、`:118-120` 与 `:176-178` 互斥说明 | 修改 | 维护段加 `change-port`；参数段加 `--no-probe`；互斥说明加 change-port 的组合规则 |
| direct 参数解析 | `:240-277` 主循环 | 新增 | `change-port)`、`--no-probe)` 两个分支 |
| direct 组合校验 | `:282` 起（`SAW_UP` 校验之后） | 新增 | §5.1.4 的组合规则 |
| direct 本机工具 | `:354` `interface_is_tunnel` 之后 | 新增 | `tcp_probe`，与 `chain/setup_chain.sh:591-602` 同一实现 |
| direct 远端探测 | `:727` `server_port_in_use` 之后 | 新增 | `write_port_probe_script`（与链式同文；直连没有统一临时目录，函数内 `mktemp` 生成、返回前与 `die` 前删除）、`direct_probe_ports`、`direct_random_free_port` |
| direct 状态分支 | `:733-738`（`none`）、`:756-760`（`ownexit` 读完 `CUR_PORT` 后） | 修改 | `none` 时 change-port 退出 2；`ownexit` / `migrated_leftover` 时按 §5.1.5 定出 `WANT_PROXY_PORT`，之后走原改参数路径 |
| 文件参考 | `docs/reference/files.md:138`、`:175` 两行“内部（不属于公开接口）”；`files.en.md` 对应行 | 修改 | 各补“`ownexit-portprobe-<随机>.service`（change-port 探测用的瞬时单元，`systemd-run` 创建、不落盘，最长约 90 秒）” |
| 命令参考 | `docs/reference/commands.md:30-46`、`:50-62`、`:66`、`:68-74`；`:118-136`、`:159`、`:165-175`；`commands.en.md` 对应段 | 修改 | 见 §5.2 |
| 使用手册 | `docs/manual/direct.md:138`、`:155`（及 `direct.en.md` 对应行）换端口说明；`docs/manual/chain.md:72`、`:83`、`:87`（及 `.en`） | 修改 | 新命令、探测说明、同机直连 + 链换端口顺序 |
| README / chain README | `README.md:147`、`README.zh-CN.md` 对应句；`chain/README.md:260-271`（`:263`“随机选一个中转上空闲的端口”）、`chain/README.en.md` 对应段 | 修改 | 提一句 `--no-probe` 与直连 `change-port` |
| CHANGELOG | `CHANGELOG.md` 顶部 Unreleased | 新增 | Added 两条 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 远端探测脚本（链式与直连同文）

`write_port_probe_script <输出文件>` 写一段 bash，经 `bash -s -- <模式> <单元名> [端口…]` 投递：

- `start <单元> <p1…pn>`：
  1. `py="$(command -v python3)"`，没有就输出 `PROBE=nopython` 退出 0。
  2. `systemd-run --quiet --collect --unit="<单元>" --property=RuntimeMaxSec=90 "$py" -c "<监听代码>" <p1…pn>`，失败输出 `PROBE=startfail` 退出 0。
  3. 最多等 10 秒（每 0.5 秒一次）：取 `systemctl show -p MainPID --value <单元>`，用 `ss -H -ltnp` 找属于该 pid 的监听端口（与 `chain/setup_chain.sh:2811` 同一写法 `index($0, "pid=" pid ",")`）；所有候选都出现、或单元已不在运行就停。
  4. 单元已不在运行（python 启动即崩、提前退出）时输出 `PROBE=exited`；否则输出 `PROBE=ready`，每个属于该 pid 的端口输出一行 `LISTEN=<端口>`。以 pid 匹配，不以“端口在听”匹配，避免把别的程序占着的端口当成自己的。
- `stop <单元>`：`systemctl stop <单元> || true`、`systemctl reset-failed <单元> || true`（单元可能已被 `RuntimeMaxSec` 回收，stop 返回非 0 不算失败；脚本开着 `set -euo pipefail`，两条都必须带 `|| true`）；随后 `systemctl show -p ActiveState --value <单元>` 不是 `active` / `activating` 输出 `PROBE=stopped`，否则 `PROBE=stopfail`。
- 监听代码（作为 `python3 -c` 的单个参数传入，可含换行）：对每个参数尝试 `bind(('0.0.0.0', p))` + `listen(16)`，失败的跳过；然后 `select` 循环 accept 后立即 close。不读写任何文件。systemd 会展开 ExecStart 参数里的 `$变量` 与 `%` 说明符，监听代码与端口参数里不得出现 `$` 和 `%`（编码时在测试床实测一次）。

单元名 `ownexit-portprobe-<8 位十六进制>`，本机用 `openssl rand -hex 4` 生成，不与 `ownexit-chain-*`、`ownexit-direct*` 现有命名重叠（`chain/setup_chain.sh:2612-2618`、`direct/direct_remote.sh:43-45`）。

#### 5.1.2 本机探测流程（链式 `chport_probe_ports`，直连 `direct_probe_ports`）

入参：目标 IP、对照端口（服务器上当前确实在听的端口；为空时不做对照）、候选端口列表（指定端口时只有一个）。出参：全局 `PROBE_STATUS`（`ok` / `skipped`）、`PROBE_REACHABLE`（能连上的候选，按候选顺序、空格分隔）与 `PROBE_PORT`（`PROBE_REACHABLE` 的第一个）。函数本身不在命令替换里调用：`die` 在子 shell 里不会结束主进程，全局出参也带不回主 shell。函数内部的远端输出照现有写法用 `$(ssh_relay_stdin …)` / `$(vssh …)` 捕获（同 `chain/setup_chain.sh:8186`、`:3505`）。

1. `--no-probe` → `skipped`，日志 `[portprobe] skipped reason=no-probe`。
2. 目标不是 IPv4、取不到出接口 → `skipped`（WARN）。出接口是 TUN（`interface_is_tunnel`）→ `skipped`，WARN：“本机到 <IP> 经 TUN（<接口>），本机测出的结果不代表真实网络，跳过探测”。
3. 直连另判 ufw，取值方式与 `direct/setup_direct.sh:1135` 相同（`command -v ufw && ufw status | head -n 1 || echo none`）：已启用（含 `active` 且不含 `inactive`）→ `skipped`（`reason=ufw`），WARN 说明 ufw 会挡住临时端口；既不是 `none` 也不是 `inactive` 的其它输出 → `skipped`（`reason=ufw-unknown`）；这一次 SSH 返回 255 → `die`（退出 1），服务器未改动。
4. 候选：指定端口时就是它；否则取 `OWNEXIT_TEST_PROBE_CANDIDATES`，没有则用 `openssl rand -hex 2` 生成 8 个 20000–59999 内、互不相同、不等于当前端口（直连另排除 `SUB_PORT`）的端口。
5. SSH 执行 `start`：链式用 `ssh_relay_stdin`，直连用 `vssh`。
   - SSH 返回 255：链式 `die 3`，直连 `die`（退出 1）；文案说明“服务器上的临时监听最多 90 秒后自动退出，稍后重跑”。
   - 中断后 90 秒内带同一个端口重跑，端口检查会因上次的临时监听报“已被占用”；链式 `:8190` 与直连 `:772` 的“被占用”文案末尾各加一句“刚中断过 change-port 的，约 90 秒后再试”。
   - `PROBE=nopython` / `startfail` / `exited`，或 `ready` 但没有任何 `LISTEN=` → `skipped`（WARN，`reason=nopython|startfail|nolisten`），按原方式继续。指定端口的路径在探测前已由端口检查判为空闲，这里没有 LISTEN 只说明临时监听自身失败，不当成“端口被占用”。
   - SSH 返回码既不是 0 也不是 255，或输出里没有可识别的 `PROBE=` 行：链式 `die 3`、直连 `die`（退出 1），文案“探测结果无法识别，服务器未改端口；服务器上的临时监听最多 90 秒后自动退出；可加 --no-probe 跳过”。
   - `OWNEXIT_TEST_PROBE_STOP_AFTER=start` 时在这里 `exit 99`。
6. 有对照端口时本机先连它，再逐个连 `LISTEN=` 端口，`tcp_probe <IP> <端口> 3`。
7. SSH 执行 `stop`；SSH 失败或 `stopfail`：链式 `die 3`、直连 `die`，文案同第 5 步（服务器尚未改端口）。
8. 判定：
   - 能连上的候选非空 → `ok`，`PROBE_PORT` 取候选列表里第一个能连上的。若当前端口对照也能连上，WARN：“当前端口 <P> 本机就能连上，换端口不一定能解决问题”，继续。
   - 都连不上 → 拒绝，服务器零改动。链式 `die 3`，直连 `die`（退出 1）。文案按对照结果给方向：当前端口也连不上 → “本机到 <IP> 的这些端口都连不上，可能是本机网络或服务器的云防火墙 / 安全组拦截；换个网络再试，或确认安全组后加 --no-probe”；当前端口能连上 → “本机能连上当前端口 <P>，但候选端口都连不上；可能是服务器本机防火墙只放行了当前端口，也可能是这批候选被拦；重跑会换一批候选”。指定端口时文案改为“本机连不上 <IP>:<n>，换一个 --port（直连为 --proxy-port），或加 --no-probe 跳过”。

日志：`[portprobe] start host=<IP> unit=<单元> candidates=<列表>`、`[portprobe] listen=<列表>`、`[portprobe] current=<P> reachable=yes|no`、`[portprobe] result reachable=<k>/<n> chosen=<端口或 ->`、`[portprobe] stopped unit=<单元>`、`[portprobe] skipped reason=<no-probe|not-ipv4|no-route|tun|ufw|ufw-unknown|nopython|startfail|nolisten>`。链式用 `log_info` / `log_warn`（行形如 `[chain][change-port] INFO [portprobe] …`），直连用 `echo "[*] [portprobe] …"` / `echo "[!] [portprobe] …"`，文案都走 `L`。

#### 5.1.3 链式 change-port 接入（替换 `chain/setup_chain.sh:8180-8198`）

```text
if CHPORT_REQUESTED 非空:
    new_port = CHPORT_REQUESTED；等于 old_port → die 2（不变）
    if new_port != CHPORT_FILE_PORT:
        端口检查 free/used（不变）
        对照端口 = (CHPORT_INSPECT == fresh) ? old_port : CHPORT_FILE_PORT
        chport_probe_ports RELAY_HOST <对照端口> new_port   # skipped 时照旧继续
elif CHPORT_INSPECT == already:
    new_port = CHPORT_FILE_PORT                            # 续跑，不探测
else:
    chport_probe_ports RELAY_HOST old_port <随机候选>
    if PROBE_STATUS == ok:
        对 PROBE_PORT 再跑一次端口检查（write_port_check_script，与 choose_remote_port 同一口径）
        free → new_port = PROBE_PORT
        used → 按候选顺序取下一个能连上的候选，再跑端口检查；能连上的候选用完 → new_port = choose_remote_port relay（WARN）
    else:
        new_port = choose_remote_port relay（不变）
```

探测在 fresh 路径的 `remote_platform_preflight` 与 `probe_remote_resources yes` 之后（`:8172-8178`），在 `chport_apply`（`:8199`）之前；探测失败时远端只有一个已停掉的临时单元，没有改 socket 文件。续跑（`CHPORT_INSPECT=already`）时中转 socket 已移到文件里的端口，`old_port` 通常不再监听，所以对照端口改用 `CHPORT_FILE_PORT`。python 绑 `0.0.0.0` 成功不等于 `ss` 口径空闲（例如只有 IPv6 监听），所以随机路径对选中的端口再做一次端口检查。

参数解析 `:873-881` 增加：

```text
--no-probe) [[ CHPORT_NO_PROBE == 0 ]] || die 2 "--no-probe 只能给一次"; CHPORT_NO_PROBE=1; shift ;;
```

#### 5.1.4 直连参数与组合规则

- 主循环（`direct/setup_direct.sh:240-278`）加：`change-port) CHANGE_PORT=1; SAW_DEPLOY_ARG=1; shift ;;`、`--no-probe) NO_PROBE=1; SAW_DEPLOY_ARG=1; shift ;;`。`SAW_DEPLOY_ARG=1` 让 `change-port status` 这类混用按现有规则报错（`forward_to_subctl` `:224`）。
- 组合校验（`:282` 起追加，均 `die_usage`，退出 2）：
  - `change-port` 不能与 `up`、`rotate-keys`、`rotate-token`、`migrate`、`uninstall`、`add-device`、`remove-device`、`--sni`、`--sub-ttl` 同用；
  - `--no-probe` 只能与 `change-port` 同用。
- `--proxy-port` 的数字范围校验沿用 `:304-305`。

#### 5.1.5 直连 change-port 执行（`direct/setup_direct.sh:733-790`）

- `STATE=none`：`CHANGE_PORT=1` 时 `die_usage`“服务器上还没有部署：先运行 ownexit direct up”。与 add-device 相同，走到这里之前已做过幂等的 BBR 与基础工具检查（`:418-456`）。
- `STATE=ownexit|migrated_leftover`：在 `CUR_PORT` 读出之后、`NEW_PORT` 计算之前插入：
  - 给了 `--proxy-port`：等于 `CUR_PORT` → `die_usage`“就是当前端口”；等于 `SUB_PORT`、在服务器上已被占用 → 用 `:771-772` 同样的文案提前报错；然后 `direct_probe_ports HOST CUR_PORT WANT_PROXY_PORT`。
  - 没给：`direct_probe_ports HOST CUR_PORT <随机候选>`；`ok` 时按候选顺序取第一个能连上、且 `server_port_in_use` 判为空闲的候选作为 `WANT_PROXY_PORT`（能连上的都被占用时按 `skipped` 处理，WARN）；`skipped` 时 `WANT_PROXY_PORT="$(direct_random_free_port)"`（最多 20 次随机，每次 `server_port_in_use` 检查，排除 `CUR_PORT`、`SUB_PORT`；选不出 `die`）。
  - 选出的端口由原改参数路径 `:771-772` 再检查一次（订阅端口、占用）。
  - `server_port_in_use`（`:727-729`）把 SSH 失败当成“空闲”；这时紧接着的 `start_op` 同样走 SSH，会以退出 1 失败，结果不受影响，本方案不改它。
  - 之后完全走原改参数路径（`start_op reparam`，UUID 与密钥不变，`CHANGED_PARAMS=1`，结尾的订阅刷新提示与 `print_chain_hints` 不变）。
- `STATE` 为 233boy 旧版：沿用现有“需要 migrate”退出 2。

### 5.2 接口变更

新增（2.x 只增不减，`docs/reference/compatibility.md`）：

- `ownexit direct change-port`：子命令。可带 `--proxy-port <n>`、`--no-probe`、`--host` / `--user` / `--port`（SSH 目标，含义不变）、`--allow-tun`。
- `ownexit direct --no-probe`：参数，只能与 `change-port` 同用。
- `ownexit chain change-port --no-probe`：参数。
- 退出码不新增，只扩大现有码的含义：
  - 链式 3：`change-port` 本机连不上候选端口（或指定端口）、探测期间 SSH 不可达、探测结果无法识别、停止临时监听失败；远端未改端口。
  - 链式 2：不新增。指定端口被占用仍由现有端口检查报 2（探测之前）；探测时临时监听没起来按跳过处理，不报 2。
  - 直连 1：`change-port` 本机连不上候选端口（或指定端口）、探测期间 SSH 不可达、探测结果无法识别、停止临时监听失败。
  - 直连 2：`change-port` 用在未部署的服务器上、指定端口等于当前端口、组合非法。
- 链式 `port=changed …` 结果行不变；探测日志（`[portprobe] …`）是给人看的进度，不冻结。
- 测试钩子 `OWNEXIT_TEST_PROBE_CANDIDATES`、`OWNEXIT_TEST_PROBE_STOP_AFTER`：不属于公开接口。

`direct up --proxy-port` 的行为、输出、退出码不变。

**reference sibling 回补检查**（按「方案文档章节内容质量要求」§5）：

- Q1 涉及 reference 章节：`docs/reference/commands.md`（及 `.en`）§`ownexit direct` 的“子命令”“参数”“互斥规则”“退出码”，§`ownexit chain` 的“参数”“子命令”“退出码”；`docs/reference/files.md`（及 `.en`）§直连（服务器）与 §链式（服务器）末尾的“内部”说明。
- Q2 源码暴露面完整性：`scripts/check_interface.sh` 已自动比对 direct 子命令（`:146-149`）与参数表首列，编码后跑它核对；文档里 change-port 的现有描述（`:136`、`:159`、`:171`、`:174`）与源码一致；files.md 已收录同类瞬时单元 `ownexit-subscription-ttl.*`（`:131`），临时探测单元归入“内部”，不进首列自动比对。
- Q3 本方案是否回补：N/A——新增暴露面与文档化同步落地。
- Q4 placeholder 落地：N/A。

## 6. 备选方案与决策

- **远端临时监听用 systemd socket 单元（`systemd-run --socket-property=ListenStream=…`）代替 python3**：不依赖 python3，中转一定能用。否决理由：socket 激活在有连接时会拉起对应 service，需要额外设计这个 service 的行为与失败计数（连续触发会把 socket 打进 failed），兜底清理要另起定时器；python3 方案的生命周期只靠 `RuntimeMaxSec` 就能闭合。中转没有 python3 时降级为“跳过探测并警告”，不比现在差。
- **默认关闭、加 `--probe` 才探测**：否决。change-port 的主要用途就是“当前网络连不上”，默认探测能直接挡掉“换到另一个同样被拦的端口”；探测做不了时自动跳过，不会让命令变得不可用。
- **直连新端口参数叫 `--port`**：否决，`--port` 在直连已是 SSH 端口（`direct/setup_direct.sh:244-246`），改含义违反 2.x 冻结。
- **把 `direct up --proxy-port` 也接入探测**：否决，`up` 用于部署，新装与改 SNI 都走它；只在新子命令上加探测，`up` 行为不变。

## 7. 影响分析

正向：

1. 链式 change-port 增加两次 SSH 与最多约 37 秒的本机连接。只在 change-port 内调用，`deploy` / `up` 选中转端口的调用（`chain/setup_chain.sh:3539`）不受影响。
2. 探测期间中转上多一个临时 python3 进程与最多 8 个监听端口，最长 90 秒。
   - 本链：探测在 `chport_apply` 前结束并 stop，之后的 `full_verify` 看不到它。
   - 同一中转的其它链与既有 sing-box：中转基线的监听记录只取被保护的 co-host 进程 pid 名下的监听（`collect_relay_baseline` `chain/setup_chain.sh:2840` 的远端脚本 `:2809-2813`，`index($0, "pid=" pid ",")`），临时 python3 的监听不在其中，`verify_relay_baseline`（`:4778`）不会因探测误报。其它链的 socket 文件、端口都不涉及。
   - 当前端口对照会对本链 socket 发起一次连接，触发一次 socket 激活和一次到出口机的转发，无副作用。
3. 直连 change-port：探测期间服务器多一个临时 python3 进程；当前端口对照会对 sing-box Reality 端口发起一次空连接，sing-box 按无效握手处理。之后的改参数路径与 `direct up --proxy-port` 完全相同。
4. 退出码含义扩大（§5.2），旧调用方：`change-port` 以前选端口不会以 3 失败，现在本机连不上时会以 3 退出；脚本化调用若把 3 当“SSH 不可达”，提示文案已区分。

反向：

5. 链式 `ssh_relay_stdin` 走 `run_managed_external` 子进程登记；探测的两次 SSH 都在主 shell 同步执行，不与其它受控子进程并行，不改登记逻辑。本机 `tcp_probe` 是普通子进程，不登记。
6. 远端临时单元名前缀 `ownexit-portprobe-` 不匹配链式残留扫描（`ownexit-chain-restore-*` `:5607`）与直连 op 单元（`ownexit-direct-op`），不会被当成残留，也不会误删别的单元。
7. 本机 Ctrl+C / SSH 中断：链式现有 trap 不知道临时单元，靠 `RuntimeMaxSec=90` 与 `--collect` 自行消失；manual 写明“中断后约 90 秒内服务器上可能还有临时监听”。
8. macOS `/bin/bash` 3.2：新增代码不用关联数组、`coproc`、`${var,,}`，与现有约束一致（`chain/setup_chain.sh:2043`）。

部署形态：

9. 本机经 Clash TUN（链式 change-port 不做 TUN 自检）：探测跳过并警告，行为与现在相同。直连在 `tun_precheck`（`direct/setup_direct.sh:377`）就会拒绝，加 `--allow-tun` 后探测跳过。
10. 中转没有 python3：探测跳过并警告，行为与现在相同。直连服务器部署时已要求 python3，正常不会走到这条。
11. 云安全组按端口放行的服务器：所有候选都连不上，命令拒绝；提示里给出“确认安全组后加 --no-probe”。

## 8. 回归测试

L0 在本机（macOS）与一台 Linux 主机上跑，不需要服务器；L1 在 Linux 主机的 Docker 测试床（带 systemd 的 Ubuntu 22.04 容器作中转、出口、直连服务器，控制端容器加 `NET_ADMIN`），测试床同 `feature-chain-relay-port.md` §8。“本机回程被丢”在控制端容器上用 `iptables -A INPUT -s <服务器> -p tcp --sport <端口> -j DROP` 模拟（丢掉 SYN-ACK），用例结束删除。直连服务器下载官方包用 `OWNEXIT_TEST_RELEASE_BASE_URL` 指向测试床内的镜像。

| 编号 | 层级 | 操作 | 预期 |
| ---- | ---- | ---- | ---- |
| S1 | L0 | `scripts/check_interface.sh`、`check_i18n.sh`、`check_ui_lang.sh`、`check_public.sh`（先 `git add`）；`bash -n`（含 macOS `/bin/bash` 3.2）；`shellcheck -S warning chain/*.sh direct/*.sh scripts/*.sh` | 全部退出 0 |
| A1 | L0 | `direct change-port --sni x`、`direct change-port up`、`direct change-port rotate-keys`、`direct --no-probe up`、`direct change-port --proxy-port 0`、`direct change-port status` | 都退出 2，文案各自对应；不连服务器 |
| A2 | L0 | 链夹具（同上一方案 A1）：`change-port --no-probe --no-probe`、`change-port --foo` | 退出 2，文案含 `--no-probe` |
| A3 | L0 | `direct --help`、`chain --help`（中 / 英） | 含 `change-port` 与 `--no-probe` 说明 |
| C1 | L1 | 部署链 a，`change-port`（无阻断） | `[portprobe] result reachable=k/n` 且 k = n ≥ 1（n 为实际 LISTEN 个数），新端口在候选里；`port=changed … result=fresh`；中转 `systemctl list-units --all 'ownexit-portprobe-*'` 为空，`ss -H -ltnp` 无 python3 |
| C1b | L1 | 同 C1，中转换成 Ubuntu 20.04（systemd 245）的 systemd 容器 | 同 C1；另核 `RuntimeMaxSec` 生效：`OWNEXIT_TEST_PROBE_STOP_AFTER=start` 中断后约 90 秒内单元自动消失 |
| C2 | L1 | `OWNEXIT_TEST_PROBE_CANDIDATES="21001 45001"`，控制端丢 21001 的回包，`change-port` | 新端口 45001；日志 `reachable=1/2` |
| C3 | L1 | 同 C2，两个都丢 | 退出 3，文案含“都连不上”；中转 socket 文件哈希等于 state，state 不变；无临时单元残留 |
| C4 | L1 | 控制端丢 N 的回包，`change-port --port N`；再 `change-port --port N --no-probe` | 第一次退出 3，远端未改动；第二次跳过探测（`reason=no-probe`），换完后的本机冒烟失败退出 1（同上一方案 P7） |
| C5 | L1 | 中转临时把 python3 移出 PATH（用例后恢复），`change-port` | WARN `reason=nopython`，按原方式随机选端口成功 |
| C6 | L1 | 控制端 PATH 前置一个假 `ip`，输出 `… dev tun9 …`，`change-port` | WARN `reason=tun`，按原方式成功 |
| C7 | L1 | 同一中转上有链 b 与既有 sing-box；用 `OWNEXIT_TEST_PROBE_STOP_AFTER=start` 让 a 的临时监听留在中转上，90 秒内 `verify` 链 b 与链 a 的基线；之后 a 正常 `change-port`，再 `verify` b | 探测窗口内 b 的 verify 通过、a 的 `verify_relay_baseline` 通过；结束后 b 的进程号与端口不变 |
| C8 | L1 | `OWNEXIT_TEST_PROBE_CANDIDATES=<M>` + `OWNEXIT_TEST_PROBE_STOP_AFTER=start` 运行 `change-port`；立即 `change-port --port M` 重跑；等 100 秒后再 `change-port --port M` | 第一次退出 99；第二次退出 2，文案含“约 90 秒后再试”；中转上临时单元在 100 秒内消失、M 不再被 python3 监听；第三次成功，新端口为 M |
| C9 | L1 | 当前端口未阻断时 `change-port` | WARN“当前端口本机就能连上”，仍成功 |
| D1 | L1 | 直连部署后 `direct change-port` | 代理端口变化；`/etc/ownexit-direct/client.env` 除 PORT 外与改前一致；订阅地址不变；无临时单元残留 |
| D2 | L1 | `direct change-port --proxy-port <当前端口>`、`<订阅端口>`、`<服务器上 nc -l 占住的端口>` | 都退出 2，服务器配置不变 |
| D3 | L1 | 候选钩子 + 阻断同 C2 / C3 | 选到能连的端口；全阻断时退出 1，client.env 不变 |
| D4 | L1 | 服务器 `ufw enable`（放行 SSH），`direct change-port` | WARN `reason=ufw`，按原方式随机选端口，改参数成功且 ufw 放行了新端口 |
| D5 | L1 | 未部署的服务器 `direct change-port` | 退出 2，提示先 up |
| D6 | L1 | `direct up --proxy-port <n>` | 无 `[portprobe]` 日志，行为与改前相同 |
| D8 | L1 | 控制端 PATH 前置假 `ip`（输出 `… dev tun9 …`），`direct change-port --allow-tun` | 自检 WARN 经 TUN 继续；探测 WARN `reason=tun`，按原方式换端口成功 |
| C10 | L1 | 用 `OWNEXIT_TEST_CHPORT_STOP_AFTER=remote` 造出中断状态（socket 已移到 P、state 仍是旧端口），再 `change-port --port Q` | 对照端口为 P（日志 `current=P`）；`result=resumed`，新端口 Q |
| D7 | L1 | 直连服务器同时是链 a 的中转：`chain change-port` → `direct change-port` → `chain rebaseline` → `chain verify` | 直连结尾打出 rebaseline 提示；最终 verify 通过 |

真实服务器上的验证要换线路端口，需用户同意后再做，本方案不强制。

## 9. 日志 / 观测点

- 固定前缀 `[portprobe]`，各行见 §5.1.2；链式行形如 `[chain][change-port] INFO [portprobe] …`，直连行形如 `[*] [portprobe] …`，`grep -F '[portprobe]'` 两边通用。
- 远端可查：`systemctl list-units --all 'ownexit-portprobe-*'`、`ss -H -ltnp | grep python3`；`journalctl -u ownexit-portprobe-<id>` 只有启动 / 停止记录。
- 链式结果行仍是 `port=changed chain=<链> old=<端口> new=<端口> result=<fresh / resumed>`。
- 直连：`[*] 改参数：sni … port <旧> -> <新>（UUID 与密钥不变）`（`direct/setup_direct.sh:780`）。

## 10. 开放问题

1. 探测默认开启（本方案默认）还是默认关闭？
2. 中转没有 python3、直连服务器 ufw 已启用、本机经 TUN 时，跳过探测继续（本方案默认）还是直接拒绝？
3. 候选数量 8 个、单端口超时 3 秒（本方案默认）。
