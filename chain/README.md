# 链式代理：中转机 + 出口机

客户端连接中转机的 TCP 端口，中转机用 `systemd-socket-proxyd` 把字节原样转发到出口机，VLESS-Reality 只在出口机终止。出口机的 IP 被墙时，换一台中转机即可，出口 IP 和客户端凭据都不变。

```text
电脑 / 手机
  │ VLESS-Reality
  ▼
中转机
  │ systemd-socket-proxyd，纯 TCP 字节转发（不解密、不存密钥）
  ▼
出口机
  │ sing-box VLESS-Reality + direct
  ▼
目标网站看到出口机的 IP
```

## 快速上手

在本仓库根目录运行：

```bash
# 1. 只问两个 IP：给两台机器配免密（各问一次 root 密码），探测出口 IP 与中转现状，生成配置
chain/setup_chain.sh init --relay 203.0.113.10 --exit 203.0.113.20

# 2. 部署（先只读预检、再按“出口机 → 中转机”顺序事务部署，最后完整验证）
chain/setup_chain.sh --id main deploy

# 3. 客户端节点链接在这里（含凭据，权限 600）：
cat ~/.local/state/ownexit/chains/main/client/node.txt
```

想先看看能不能部署、不改动远端：`chain/setup_chain.sh --id main preflight`。

`init` 生成的配置写在 `~/.config/ownexit/chains/<名字>.env`（默认名字 `main`），之后 `deploy`、`verify`、`rollback` 等只读这个文件，不接受主机参数覆盖：部署状态绑定了配置文件的哈希，改了配置会和状态对不上。要部署第二条链，用 `init --id <新名字>`。

## 前置条件

1. 控制端是 macOS（Apple 芯片 / Intel，系统自带 `/bin/bash` 3.2 即可）或 Linux（amd64 / arm64，含 WSL）；必须在本仓库的 git 工作区里运行（`git` 用来确认真实配置不在仓库内）。配置与状态目录的每一级上级目录都不能被同组或其他用户写入，否则会被安全检查拒绝。
2. 两台 Linux 服务器，同为 amd64 或同为 arm64（不支持两端架构不同），root 能用密码 SSH 登录（只在 `init` 时用一次）。
3. 出口机的云厂商安全组 / 防火墙允许中转机访问；脚本不调用任何云厂商 API。“只允许中转机连出口机的 Reality 端口”有三种做法，由 `EXIT_SOURCE_FILTER` 决定：默认 `managed`，部署时由本项目在出口机加一张只放行中转机出站地址的 nft 表；`provider`，由服务商在机器外的安全组负责；`none`，不限制（没有凭据仍无法使用）。`managed` 与 `provider` 部署时都会严格检查本机直连连不上。
4. 两台机器除本项目的 `table inet ownexit_*` 白名单表外没有任何 nft 表；装了 UFW 的话须为 inactive；legacy iptables 不得有活动规则。
5. 中转机已安装 `systemd-socket-proxyd`；两端具备 `preflight` 列出的系统工具。全新机器还要确认 `/etc/systemd/system/sockets.target.wants` 存在（root:root 755），缺失时 `preflight` 会给出创建命令，脚本不代建 systemd 标准目录。
6. 中转机上已经在跑 sing-box 也可以：`init` 会自动识别并填 `RELAY_COHOSTS_SINGBOX=yes`，部署时保护既有 sing-box 不受影响；状态不完整（只有配置没有进程之类）时 `init` 会拒绝。

## 安全边界

- 两端 SSH 用户固定为 `root`，要求免密 key 和已受信任的 ed25519 host key（`init` 会配好）。脚本生成隔离的 SSH config，不继承用户自己的 ProxyCommand、端口转发或远端命令；出口机的管理连接经中转机 `ProxyJump`。
- host-key 指纹取自各自 SSH 会话的 `ssh -vv -E` 日志，不读取远端的公钥文件，也不会把 ProxyJump 的中转指纹当成出口机指纹。
- 脚本不修改防火墙、云厂商安全组和既有 sing-box 配置。
- 本链专属的远端路径一旦已存在即拒绝覆盖；固定版本的共享 binary 只在 owner、mode、版本、哈希完全一致时复用。
- Reality 私钥只存在于出口机权限 600 的配置里；日志不打印 UUID、密钥、short id 或完整节点链接。
- 只验收 TCP + `socks5h`，不承诺 UDP、QUIC/HTTP3、ICMP 或客户端 DNS 零泄漏。

## 配置（手工编辑属于进阶用法）

`init` 生成的文件格式与 `chain/chain.example.env` 相同。解析器不执行 shell，只接受空行、井号注释和严格的 `KEY=VALUE`，必须且只能包含下面 13 个键：

| 键 | 说明 | `init` 怎么得到 |
| ---- | ---- | ---- |
| `CHAIN_ID` | `[a-z0-9][a-z0-9-]{0,31}`，对应本地状态目录和远端 unit 名 | `--id`，默认 `main` |
| `RELAY_HOST` / `RELAY_SSH_PORT` | 中转机 IPv4 与 SSH 端口 | `--relay`、`--relay-port`（默认 22） |
| `RELAY_SSH_USER` | 固定为 `root` | 固定 |
| `RELAY_SSH_KEY` | 本机上中转机私钥的绝对路径 | `~/.ssh/ownexit/id_ed25519_root_<ip>_<端口>` |
| `EXIT_HOST` / `EXIT_SSH_PORT` | 出口机 IPv4 与 SSH 端口 | `--exit`、`--exit-port`（默认 22） |
| `EXIT_SSH_USER` | 固定为 `root` | 固定 |
| `EXIT_SSH_KEY` | 本机上出口机私钥的绝对路径，不会复制到中转机 | 同上规则 |
| `EXPECTED_EXIT_IPV4` | 出口验证时唯一允许返回的 IPv4 | 在出口机上探测，终端里请你确认 |
| `REALITY_SERVER_NAME` | Reality 伪装域名（ASCII FQDN），没有自动 fallback | `--sni`，默认 `www.amazon.com` |
| `RELAY_COHOSTS_SINGBOX` | `yes` 保护中转机上既有的 sing-box；`no` 要求中转机上没有 sing-box | 登录中转机自动识别 |
| `EXIT_SOURCE_FILTER` | `managed`：本项目在出口机加 nft 白名单；`provider`：服务商安全组只放行中转来源；两者部署 / verify 时本机能直连出口机 Reality 端口即失败。`none`：不限制，能直连只记 WARN | `--exit-source-filter`，默认 `managed` |

配置文件必须由当前用户拥有、权限 600、不是符号链接，并且位于 git 工作区之外；私钥要求 group / other 没有任何权限。

## 命令

```bash
chain/setup_chain.sh init --relay <ip> --exit <ip> [--id <名字>] [--relay-port N] [--exit-port N] [--sni <域名>] [--exit-source-filter managed|provider|none]
chain/setup_chain.sh --id main preflight
chain/setup_chain.sh --id main deploy
chain/setup_chain.sh --id main verify
chain/setup_chain.sh --id main verify --with-fail-closed
chain/setup_chain.sh --id main status
chain/setup_chain.sh --id main rollback

# 中转连接治理（链已 deploy 后可用）
chain/setup_chain.sh --id main conns              # 各来源 IP 的连接数 / 空闲秒数 / 是否拉黑，以及 proxyd fd 用量
chain/setup_chain.sh --id main kick 203.0.113.7   # 用 ss -K 断开该来源的已建连接
chain/setup_chain.sh --id main ban 203.0.113.7    # 加入黑名单并立即生效（顺带 kick）
chain/setup_chain.sh --id main ban 198.51.100.0/24
chain/setup_chain.sh --id main unban 203.0.113.7
chain/setup_chain.sh --id main banlist            # 对照本地黑名单与中转两个 unit 的 IPAddressDeny 回读值

# 出口机同一台机器换了公网 IP（先改配置里的 EXIT_HOST / EXPECTED_EXIT_IPV4）
chain/setup_chain.sh --id main rehost-exit
```

`--id <名字>` 是 `--config ~/.config/ownexit/chains/<名字>.env` 的简写，两者二选一。

黑名单写在中转机两个专属 unit 的受管 drop-in（`<unit>.d/50-ownexit-chain-blacklist.conf`，内容是 `IPAddressDeny=`，由 systemd cgroup BPF 生效，不是防火墙），`daemon-reload` 后立即生效，不重启服务、不影响其它来源。本地权威副本是 `${XDG_STATE_HOME:-~/.local/state}/ownexit/chains/<id>/blacklist.txt`；`verify` / `status` 只放行这一个 drop-in，并要求远端 `IPAddressDeny` 回读值与本地列表逐字一致，列表为空时远端必须没有 drop-in。`kick` 依赖中转内核支持 `ss -K`，`ban` 依赖 cgroup v2，两者在 Debian 12 / systemd 252 上实测过。中转端口是无鉴权的四层转发，`conns` 里出现陌生来源时先 `ban`，再考虑 rollback 后换端口重新部署。

`preflight` 只在操作临时目录准备资产，不写持久 cache、远端 unit 或权威状态。`deploy` 取得锁后会重新执行全部检查，不复用之前 preflight 的结果。

`verify --with-fail-closed` 会短暂停止本链的中转 socket，确认新连接拿不到任何有效出口 IP，再恢复 socket 并重跑完整的出口验证。远端 90 秒的 timer 是控制进程崩溃时的第二道恢复保险。

隔离 SSH 配置固定 `ConnectTimeout=12`、`ServerAliveInterval=15`、`ServerAliveCountMax=2`；持锁后的每个 SSH / scp 另有控制端 600 秒总超时，超时按“远端不可达”分类。`status` 通常只读，但在状态、身份、平台、基线和残留都通过后，如果 socket active 而 relay service inactive，会执行一次 `systemctl start` 并复查；它不会写远端文件。

## 状态与退出码

`status` 输出以下状态之一：

| 状态 | 含义 | 退出码 |
| ---- | ---- | ---- |
| `deployed/healthy` | 状态、两端资源、进程、监听与既有服务基线一致 | 0 |
| `not_deployed` | 没有活动状态、事务、专属资源或本链的暂存目录 | 0 |
| `busy` | 同一条链有身份有效的活动锁 | 5 |
| `stale_lock` | 锁身份已失效；下一条修改类命令会归档 | 5 |
| `incomplete` | 存在待恢复的 deploy / rollback 事务 | 5 |
| `unreachable` | 至少一台远端无法经受控 SSH 探针核证 | 5 |
| `orphaned` | 没有状态，但存在专属对象或本链的暂存目录 | 5 |
| `drifted` | 有状态，但哈希、权限、unit、监听或基线不一致 | 5 |

不健康时输出会带脱敏的 `reason`（适用时）和 `next=<安全动作>`；`unreachable` 还会给出 `role=relay|exit`，例如 `status=unreachable role=exit reason=hostkey-probe next=retry-status`。

退出码：参数错误返回 2；预检 / 检查失败返回 3（`init` 配免密或探测失败也是 3）；路径碰撞返回 4；状态或 verify 不健康返回 5；rollback 预校验失败返回 6。

## 验证模型

部署与 `verify` 分三层验证，不能互相替代：

1. 出口机到 Reality 伪装站点的 TLS 1.3 / 证书探针。
2. 中转机上临时起一个 sing-box 直连出口机，证明放行、SNI、凭据和出口机直连出口都正常。
3. 中转机经 relay 的完整链路，以及本机用 Darwin 版 sing-box 连接公网 relay。

出口请求固定用 `api.ipify.org`、`icanhazip.com`、`ifconfig.me/ip`：至少两个成功，且所有有效响应都必须等于 `EXPECTED_EXIT_IPV4`；没有 direct fallback。

当 `RELAY_COHOSTS_SINGBOX=yes` 时，零回归基线以正在运行的 `sing-box.service` 的 MainPID 为准：解析 `/proc/<pid>/cmdline` 的 `-c/-C` 和 `/proc/<pid>/cwd` 得到实际配置，记录 cmdline、cwd、ExecStart、unit 与 drop-in、可执行文件元数据和该进程的监听端口；不假定配置一定在 `/etc/sing-box`。`no` 时写四份 `none` 占位。

## 本机上的文件

| 路径 | 内容 |
| ---- | ---- |
| `${XDG_CONFIG_HOME:-$HOME/.config}/ownexit/chains/<id>.env` | 本链配置（`init` 生成或手工编写） |
| `${XDG_STATE_HOME:-$HOME/.local/state}/ownexit/chains/<id>/state.env` | 带内嵌校验和的权威部署状态 |
| `.../transaction.env` | 事务日志；存在即表示有未完成的事务 |
| `.../baseline/` | 中转机既有 sing-box 的四份只读基线，或 `none` 占位 |
| `.../client/node.txt` | 唯一持久的客户端产物，权限 600 |
| `.../audit/` | 完整的 deploy / rollback 与过期锁审计记录 |
| `${XDG_CACHE_HOME:-$HOME/.cache}/ownexit/chains/<id>/downloads/` | 可删除、可重新下载的固定版本官方资产 |
| `${XDG_STATE_HOME:-$HOME/.local/state}/ownexit/multi-chain-client/<name>/` | `multi_chain_client.sh render` 的多链聚合产物，与 `chains/<id>/` 互不重叠 |
| `~/.ssh/ownexit/` | `init`（经 `direct/connect_to.sh`）为每台机器生成的专用密钥 |

## 远端下载与本机验证

- 远端的固定版本 sing-box 由服务器自己从 GitHub 下载并核对 SHA256（4 个平台包的归档与 binary 哈希写死在脚本顶部）；远端下载失败才在本机下载后上传。日志里 `binary 来源=remote-download|local-upload` 说明走了哪条路。
- 本机只准备本机平台的官方包，用来做“本机层出口 smoke”。本机平台没有官方包、或缓存缺失且下载失败时，跳过这一层并 WARN，不影响部署；`multi_chain_client.sh verify` 则必须有本机包。
- 状态文件沿用 v0.1.0 的字段，v0.1.0 部署的链可以直接用新版本管理。

## 远端资源

中转机专属资源：

```text
/etc/ownexit-chain/<id>.owner.env
/etc/systemd/system/ownexit-chain-relay-<id>.socket
/etc/systemd/system/ownexit-chain-relay-<id>.service
/etc/systemd/system/sockets.target.wants/ownexit-chain-relay-<id>.socket
# 仅黑名单非空时存在（ban 的产物，rollback 一并删除）：
/etc/systemd/system/ownexit-chain-relay-<id>.socket.d/50-ownexit-chain-blacklist.conf
/etc/systemd/system/ownexit-chain-relay-<id>.service.d/50-ownexit-chain-blacklist.conf
```

出口机专属资源（`managed` 时还有一张随 `ownexit-chain-exit-<id>.service` 起停的 nft 表 `table inet ownexit_<id，- 换成 _>`，规则写在该 unit 的 `ExecStartPre` / `ExecStopPost` 里）：

```text
/etc/ownexit-chain/<id>.owner.env
/etc/ownexit-chain/<id>.exit.json
/etc/systemd/system/ownexit-chain-exit-<id>.service
/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-<id>.service
```

两端共享、rollback 后预期保留：

```text
/etc/ownexit-chain
/opt/ownexit-chain
/opt/ownexit-chain/bin
/opt/ownexit-chain/bin/sing-box-1.13.14
```

官方 Linux 包里的 `libcronet.so` 只用于核对压缩包布局，不会发布到共享目录。

## 回滚与故障恢复

`rollback` 在停止服务之前，先核验全部 owner、哈希、符号链接、systemd 加载路径、本地产物、主机与密钥指纹和既有 sing-box 基线。通过后按“中转机 → 出口机”顺序拆除专属资源；停止后只接受 `inactive` / `failed` 明确终态，service 必须 `MainPID=0`，删除后还要复核 `LoadState=not-found`、没有 fragment 和 drop-in、没有监听。状态、基线、节点和最终事务全部归档为带 `COMPLETE` 标记的 `audit/rolledback.*` 之后，才删除活动状态。

控制端被 `kill -9` 或断电时，下一条修改类命令会读取 `transaction.env`：只有全量验证完成、且状态与远端一致时才补齐提交；其它 deploy 逆序清理，rollback 从最后完成的步骤继续。共享目录和固定 binary 不在单条链的回滚清单里。

换一台中转机时，用新的 `--id` 跑 `init` 再部署，确认新链可用后再 rollback 旧链。

## 出口机换 IP（同一台机器）

服务商给出口机换了公网 IP、机器本身没换（ed25519 主机指纹不变）时，用 `rehost-exit` 原地迁移，不要 rollback 加 deploy：rollback 要连旧 IP，deploy 会重新生成凭据，所有客户端都得重新导入。

```bash
# 1. 配置里把 EXIT_HOST（出口 IP 也变了就连同 EXPECTED_EXIT_IPV4）改成新值，其余键不动
# 2. known_hosts 补新 IP 的 ed25519 条目（同一台机器，主机公钥不变）；补完先核对指纹
grep '^<旧IP> ssh-ed25519 ' ~/.ssh/known_hosts | sed 's/^<旧IP> /<新IP> /' >> ~/.ssh/known_hosts
ssh-keygen -F <新IP> | tail -1 | ssh-keygen -lf -
# 3. 迁移（共用这台出口机的每条链各跑一次）
chain/setup_chain.sh --id main rehost-exit
```

只允许配置里 `EXIT_HOST` / `EXPECTED_EXIT_IPV4` 两个键与状态不同，其余键不一致退出 2。经中转机登录新 IP 后，协商到的主机指纹必须等于状态里记录的值，否则退出 3（说明换成了另一台机器）。迁移顺序：出口机 owner → 中转机 owner 与 relay service 的 `ExecStart` 目标（改完 `daemon-reload`；正在运行的 relay 若仍指向旧目标就重启一次，在途连接会断开，客户端自动重连）→ 本地状态（旧状态归档到 `audit/rehosted.<部署ID>.<操作ID>/state.env`）→ 自动跑与 `verify` 相同的完整核验。UUID、Reality 密钥、端口和 `client/node.txt` 都不变，客户端不用重新导入。

这个命令不走事务：每个远端步骤都用“整文件哈希守门 + 单行替换”，同时接受旧形态和已迁移形态，中途失败直接重跑同一条命令即可收敛；状态已经绑定新配置时输出 `rehost=noop` 并返回 0。退出码：0 成功或 noop；2 参数错误或其它配置键不一致；3 新 IP 不可达、缺 known_hosts 条目或不是同一台机器；5 锁、状态损坏、有未完成事务或收尾 verify 失败；1 远端迁移或本地提交失败（信息里带远端码 171–177 及含义）。

注意：本机开着 Clash 一类的 TUN 模式时，发往中转机的 SSH 也可能被代理接管，部署过程中任何一次 SSH 断开都会让命令以退出码 3 停下（只读阶段）或留下待恢复的事务（之后由下一条 deploy / rollback 按事务记录收敛）。relay 重启或客户端在链之间切换的瞬间，控制端 SSH 会被切断，收尾 verify 可能报 drift 或残留。此时状态已经提交，直接再跑一次 `verify` 即可；想避免的话，执行前关闭 TUN，或让中转机 IP 走直连。

## 多链客户端聚合（`multi_chain_client.sh`）

中转机的 IP 最容易被墙。可以给每台中转机各部署一条链（各自的 `--id`，共用同一台出口机），再用 `multi_chain_client.sh` 把各链的 `node.txt` 聚合成客户端产物：Clash Verge / mihomo 用 `fallback` 自动组在链之间自动切换，iPhone 逐链扫码后手动切换。脚本只读本机的 `chains/<id>.env` 与 `chains/<id>/client/node.txt`，不连中转机和出口机，也不改链的状态。

```bash
# 逐链从本机做真实 Reality 握手 + 出口三端点仲裁；本机 TUN 开着时对应链标 skipped（全部 skipped 退出 5）
chain/multi_chain_client.sh --chains main,backup verify
# 聚合产物：nodes.txt（每链一行 vless）、clash-snippet.yaml（proxies + fallback 自动组，供 Clash Verge 手工合并）、
# 每链一张二维码（iPhone Shadowrocket，扫完删除目录）
chain/multi_chain_client.sh --chains main,backup render
chain/multi_chain_client.sh --chains main,backup render --group url-test --no-qr
```

`--chains` 的顺序就是自动组的优先级；`--name` 决定产物目录 `${XDG_STATE_HOME:-~/.local/state}/ownexit/multi-chain-client/<name>/`（默认 `all`）。节点名是各链自己的 `Exit-via-Relay-<id>`（合并进 Clash Verge 前先删掉同名的旧单节点），自动组名是 `Exit-Relay-auto`。各链的 `EXPECTED_EXIT_IPV4` 必须相同。退出码：0 成功；2 参数 / 配置 / `node.txt` 校验错误或出口 IP 跨链不一致；5 `verify` 有链不健康或全部 skipped；1 运行时失败。

某台中转机换 IP 或被墙后：用新 `--id` 部署一条新链，把它加进 `--chains`，旧链 rollback 后从列表去掉，重新 `render` 并导入。
