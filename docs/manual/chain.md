# 链式部署手册

[English](chain.en.md) | **简体中文**

出口机的 IP 被墙、或者你想让客户端的入口和出口分开时，用链式：客户端先连一台中转机，中转机只做 TCP 透传，流量最终从出口机出去。网站看到的仍是出口机的 IP；中转机上不放任何密钥。

命令和机制的完整说明见 [`chain/README.md`](../../chain/README.md)，本手册只讲一遍从零到能用的步骤。命令按 git clone 的写法给出；用 `pipx install ownexit` 安装时，把 `chain/setup_chain.sh` 换成 `ownexit chain`、`chain/multi_chain_client.sh` 换成 `ownexit multi`，参数完全相同。

## 1. 准备

| 需要 | 要求 |
| ---- | ---- |
| 控制端 | macOS 或 Linux（含 WSL）；`pipx install ownexit` 安装，或 `git clone` 本仓库 |
| 中转机 | Linux amd64 或 arm64（与出口机相同），root 能用密码 SSH 登录，已安装 `systemd-socket-proxyd`；选离客户端近、到出口机线路好的机器 |
| 出口机 | Linux amd64 或 arm64（与中转机相同），root 能用密码 SSH 登录，独享公网 IPv4 |
| 网络 | 出口机的安全组 / 防火墙允许中转机访问；两台机器的 nft 规则集为空、UFW 为 inactive |

“只允许中转机连出口机”默认由本项目负责：部署时在出口机加一张只放行中转机的 nft 表（`EXIT_SOURCE_FILTER=managed`），rollback 时删除。服务商已有安全组并限定只放行中转机时，可以用 `--exit-source-filter provider`；完全不想限制用 `none`（没有凭据仍无法使用）。

还没有服务器时，选购、下单、装系统和防火墙设置见 [VPS 选购与系统安装手册](vps.md)。

可选：中转机上已经在跑 sing-box 也没关系，脚本会识别并保护它。

## 2. 生成配置（只需要两个 IP）

```bash
chain/setup_chain.sh init --relay 203.0.113.10 --exit 203.0.113.20
```

依次发生：

1. 给中转机配免密：问一次中转机的 root 密码（不回显，输错最多可试 3 次）。
2. 给出口机配免密：问一次出口机的 root 密码。
3. 在出口机上探测公网 IP，打印出来请你确认（`y`）。
4. 检查中转机上有没有 sing-box，自动填好对应的配置项。
5. 生成 `~/.config/ownexit/chains/main.env`（权限 600），并打印下一步命令。出口机白名单默认填 `managed`（见第 1 节）。

SSH 端口不是 22 时加 `--relay-port` / `--exit-port`。想部署多条链，用 `--id` 给每条链起不同的名字。

`init` 只配免密和做只读探测，不修改任何远端配置。中途失败（比如密码错了）不会生成配置文件，修正后重跑即可；已经配好免密的机器会自动跳过。

## 3. 部署

第 2 节和本节可以合成一条命令：`chain/setup_chain.sh up --relay <中转 IP> --exit <出口 IP>`，它在没有配置时先做 init，然后 deploy，结束时打印节点二维码；中途断开再跑一次同样的命令即可。分步做的话：

```bash
chain/setup_chain.sh --id main preflight   # 可选：先只读检查一遍
chain/setup_chain.sh --id main deploy
```

部署命令开始前会检查本机到两台服务器的路由是否经过代理的 TUN（经过时 SSH 会在途中被切断）：经过就拒绝并给出处理办法，见[让指定 IP 不走 Clash Verge 的代理](clash-direct-ips.md)；确认要继续加 `--allow-tun`。

`deploy` 让两台服务器自己下载固定版本的 sing-box（校验 SHA256，失败才由本机上传），先部署出口机再部署中转机，最后从三个层面验证出口 IP。任何一步失败都会按事务清理，不留半套配置；网络中途断开时，再跑一次 `deploy` 或 `rollback` 都会按事务记录收敛。

成功后终端打印“下一步”块：节点二维码与 `vless://` 链接、应显示的出口 IP、出问题先跑 `ownexit doctor`。节点链接也在 `~/.local/state/ownexit/chains/main/client/node.txt`（含凭据，权限 600），随时可用 `chain/setup_chain.sh qr` 再看二维码（`--device <名字>` 看设备的）。本机只有一条链时，所有子命令都可以省略 `--id main`。

## 4. 导入客户端

- **Clash Verge / mihomo / 安卓**：把 `node.txt` 里的 `vless://` 链接作为节点导入；部署了多条链时，用下面第 6 节的聚合产物。
- **iPhone Shadowrocket**：`chain/multi_chain_client.sh --chains main render` 会为每条链生成一张二维码，扫码导入后删除二维码目录（图片里有明文凭据）。

连上之后访问 `https://ipinfo.io`，IP 应当等于出口机的 IP。

## 5. 日常操作

```bash
chain/setup_chain.sh --id main status     # 健康状态
chain/setup_chain.sh --id main verify     # 完整验证出口
chain/setup_chain.sh --id main conns      # 中转机上有哪些来源 IP 在连
chain/setup_chain.sh --id main ban 203.0.113.7    # 拉黑陌生来源
chain/setup_chain.sh --id main rotate-keys   # 更换全部设备的 UUID 与 Reality 密钥 / short id
chain/setup_chain.sh --id main add-device phone      # 新增一台设备（节点在状态目录 devices/node-phone.txt）
chain/setup_chain.sh --id main remove-device phone   # 吊销一台设备
chain/setup_chain.sh --id main rollback   # 拆除这条链，两台机器恢复到部署前
ownexit doctor --chain main --ip-check    # 诊断本机与这条链，并在出口机上体检出口 IP
```

中转端口没有鉴权，`conns` 里出现不认识的来源 IP 时先 `ban`。

`rotate-keys` 只换出口机上的凭据并重启出口机的 sing-box（中断 1-3 秒），中转、端口和部署都不变；换完所有客户端要重新导入，用了多链聚合的要重新 `render`。`add-device` / `remove-device` 给每台设备单独一个 UUID，吊销一台不影响其它设备；部署时的那套凭据就是 `default`。中途断开时重跑同一条命令收敛。

## 6. 中转机被墙了怎么办

再准备一台中转机，部署第二条链（共用同一台出口机）：

```bash
chain/setup_chain.sh init --id backup --relay 198.51.100.10 --exit 203.0.113.20
chain/setup_chain.sh --id backup deploy
chain/multi_chain_client.sh --chains main,backup render
```

`render` 生成的 `clash-snippet.yaml` 带一个 `fallback` 自动组（`Exit-Relay-auto`），合并进 Clash Verge 后，当前中转不可用时会自动切到下一条。确认新链可用后，可以 `rollback` 被墙的那条，并从 `--chains` 里去掉它。

## 7. 出口机变了

出口机换了 IP 或换了一台机器，都不要 rollback 再 deploy（那样会重新生成凭据，所有客户端都要重新导入）。入口统一是 `migrate-exit`：

```bash
chain/setup_chain.sh migrate-exit --to <新 IP>
```

它先判断新地址是不是同一台机器，再按现场处理：

- **换了机器，旧机器还能登录**：直接迁移。配置（含私钥）从旧机器原样搬到新机器，切中转，删掉旧机器上本链的服务与文件，客户端不用动。步骤与中断处理见 [`chain/README.md` 的“出口机换一台机器”](../../chain/README.md#出口机换一台机器)。
- **还是同一台机器、只是 IP 变了**（旧 IP 连不上也行）：自动识别，登记新 IP 的主机密钥、备份并改写配置，原地切换，输出 `migrate=rehosted`；SSH 端口要保持不变。细节见 [`chain/README.md` 的“出口机换 IP”](../../chain/README.md#出口机换-ip同一台机器)。
- **换了机器，旧机器已经登录不了**：私钥只在旧机器上，无法迁移，只能 rollback 后重新部署（客户端要重新导入）。

## 8. 常见问题

| 问题 | 解决办法 |
| ---- | ---- |
| `init` 报 `reason=bad-password` / `password-disabled` / `unreachable` | 分别是密码错、服务器关了密码登录、连不上；处理方法同[直连手册的常见问题](direct.md#7-常见问题) |
| `init` 报“没有可用的 ed25519 host key” | 检查该机器 sshd 的 `HostKey` 配置是否包含 ed25519 |
| `init` 报“中转机上的 sing-box 状态不完整” | 让既有 sing-box 完整运行（服务、配置、进程都在），或彻底移除，再重跑 |
| `init` 报“配置已存在” | 已经有同名的链；换一个 `--id`，或确认旧链不再需要（先 rollback）后删除旧配置文件 |
| `preflight` 报防火墙或 `sockets.target.wants` 问题 | 按报错里给出的命令处理；脚本不会替你改防火墙或创建 systemd 标准目录 |
| 本机开着 TUN、`status` / `verify` 输出 `[ssh-retry]` | 只读命令遇到 SSH 断开会自动重试最多 3 次；频繁出现时关闭 TUN 或让中转机、出口机的 IP 走直连（Clash Verge 的做法见 [让指定 IP 不走 Clash Verge 的代理](clash-direct-ips.md)；`ownexit doctor` 会指出哪些 IP 经过 TUN） |
| 操作中途 SSH 断开、`verify` 报 drift | 本机 TUN 可能接管了到中转机的 SSH；关闭 TUN（或按 [clash-direct-ips.md](clash-direct-ips.md) 让中转机、出口机的 IP 走直连）后重跑 |
| 报“配置目录身份或权限不安全” | 配置 / 状态目录的某一级上级目录可被同组或其他用户写入（如权限 775）；换到权限为 755 / 700 的目录下 |
| 报“中转机与出口机的 CPU 架构必须相同” | 两台机器一台 amd64、一台 arm64，暂不支持 |
| `status` 输出 `reason=exit-op-pending`，或 `verify` / `rollback` 报“有未完成的凭据或设备操作” | 上一次 `rotate-keys` / `add-device` / `remove-device` 没跑完，出口机上留着辅助文件；重跑中断的那条命令 |
| `verify` / `status` / `rollback` 报“角色声明预检失败”或“既有 sing-box 零回归基线发生变化”，且中转机上也跑着直连 | 直连刚迁移、改参数、新装或卸载过，运行 `chain/setup_chain.sh --id <名字> rebaseline` 重新登记（见 [`chain/README.md`](../../chain/README.md#中转机既有-sing-box-重新登记rebaseline)） |
