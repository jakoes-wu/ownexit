# ownexit

[English](README.md) | **简体中文**

[![CI](https://github.com/jakoes-wu/ownexit/actions/workflows/ci.yml/badge.svg)](https://github.com/jakoes-wu/ownexit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![bash](https://img.shields.io/badge/bash-3.2%2B-blue)
![macOS](https://img.shields.io/badge/control-macOS-lightgrey)

把你租的 VPS 变成自己专属的固定出口 IP：直连或经中转，在自己电脑上一条命令装好。

```sh
git clone https://github.com/jakoes-wu/ownexit && cd ownexit
./direct/setup_direct.sh --host 203.0.113.7   # 第一次会问一次 VPS 的 root 密码
```

跑完后，把终端打印的订阅链接粘贴到 Clash Verge 或 Shadowrocket，就能用了。

- **一条命令**：在自己电脑上运行，不用登录服务器敲命令。
- **固定出口**：流量从你自己的 VPS 出去，IP 不和陌生人共用。
- **被墙也能用**：出口机 IP 被墙时，前面加一台中转机，出口 IP 和客户端配置都不变。
- **可撤销**：链式部署能把两台机器恢复到部署前；中转机上不放任何密钥。

## 怎么工作

**直连**：设备直接连你的 VPS。

```text
手机 / 电脑 ──VLESS-Reality──▶ 你的 VPS（sing-box）──▶ 网站看到的是你 VPS 的 IP
```

**链式**：在你所在的地方连不上 VPS 时使用。中转机只转发 TCP 字节，看不到你的流量，也不保存任何密钥。

```text
手机 / 电脑 ──VLESS-Reality──▶ 中转机（systemd-socket-proxyd）──▶ 出口机（sing-box）──▶ 网站看到的是出口机的 IP
```

所有操作都在你的电脑上运行，经 SSH 操作服务器。配置、密钥和状态都留在你电脑上、本仓库之外。

## 准备

| | 直连 | 链式 |
| ---- | ---- | ---- |
| 你的电脑 | macOS（Linux 未测试） | macOS 或 Linux（WSL 按 Linux 算） |
| 服务器 | 1 台 Debian / Ubuntu VPS | 2 台 Linux，同为 amd64 或同为 arm64（中转机 + 出口机） |
| 登录方式 | root 密码 SSH，只用一次 | 同左，每台各一次 |
| 本机工具 | `git`、`ssh`、`curl`、`openssl`、`expect`（`brew install expect`） | 同左 |

第一次运行会问每台服务器的 root 密码（不回显），之后全程使用 `~/.ssh/ownexit/` 下的专用密钥。

## 快速上手：直连

1. **部署**

   ```sh
   ./direct/setup_direct.sh --host 203.0.113.7          # SSH 端口不是 22 时加 --port 2222
   ```

   依次完成：配免密、检查系统、开启 BBR、安装 sing-box（经 SSH 交互运行第三方安装脚本 [233boy/sing-box](https://github.com/233boy/sing-box)，协议选 **VLESS-REALITY**，其余直接回车）、生成订阅、上传并逐层验证。

2. **导入设备**：脚本最后打印三条链接。

   | 链接 | 给谁用 |
   | ---- | ---- |
   | `…/clash.yaml` | Clash Verge、mihomo、Clash Meta for Android |
   | `…/shadowrocket.txt` | iPhone Shadowrocket |
   | `…/node.txt` | 明文 `vless://` 链接，给其它客户端 |

3. **检查并收尾**：在设备上打开 `https://ipinfo.io`，应当显示你 VPS 的 IP。然后关掉订阅服务，需要时再开：

   ```sh
   ./direct/subctl stop
   ```

脚本会记住这台 VPS，之后不带参数也能用：`./direct/setup_direct.sh` 重新部署，`./direct/subctl status|start|stop` 管理订阅服务。逐步说明见 [docs/manual/direct.md](docs/manual/direct.md)。

## 快速上手：链式

1. **给两个 IP**

   ```sh
   chain/setup_chain.sh init --relay 203.0.113.10 --exit 203.0.113.20
   ```

   给两台机器配免密（各问一次密码），探测出口 IP 并请你确认，检查中转机上是否已有 sing-box，生成 `~/.config/ownexit/chains/main.env`。这一步不改动服务器。默认部署时还会在出口机加一条 nftables 规则，让它的 Reality 端口只接受中转机的连接（`--exit-source-filter managed`）；服务商安全组已经这样限制时用 `provider`，不想限制用 `none`。

2. **部署**

   ```sh
   chain/setup_chain.sh --id main deploy
   ```

   两台服务器自己从 GitHub 下载固定版本的 sing-box（失败才由你的电脑上传），先部署出口机、再部署中转机，整个过程是一个事务，最后从三个层面验证出口 IP；任何一步失败都会自动清理，网络中途断开时再跑一次 `deploy` 或 `rollback` 就会收敛。

3. **导入**：节点链接在 `~/.local/state/ownexit/chains/main/client/node.txt`；也可以运行 `chain/multi_chain_client.sh --chains main render` 生成二维码和 Clash 配置片段。

日常操作：`chain/setup_chain.sh --id main status | verify | conns | rollback`。中转机被墙了？用 `init --id backup …` 再部署一台中转，再用 `multi_chain_client.sh` 把两条链合在一起，客户端会自动切换。完整参考见 [chain/README.md](chain/README.md)，逐步说明见 [docs/manual/chain.md](docs/manual/chain.md)。

## 支持的平台

| | 直连 | 链式 |
| ---- | ---- | ---- |
| 控制端 | macOS（已测试）；Linux（未测试）；不支持 Windows，可自行尝试 WSL | Apple 芯片的 Mac（已测试）、Intel Mac（未测试）、Linux amd64（已在 Ubuntu 20.04 测试）、Linux arm64 与 WSL（未测试） |
| 服务器系统 | Debian、Ubuntu | 带 systemd 的 Linux；中转机需要 `systemd-socket-proxyd`；除本项目自己的表外没有 nftables 表，UFW 未启用 |
| 服务器 CPU | 取决于 233boy/sing-box（amd64、arm64） | amd64（已测试）或 arm64（未测试），两台须相同 |
| 客户端 | 已测试 Clash Verge、mihomo、Shadowrocket；其它支持 VLESS-Reality 的客户端可用 `vless://` 导入 | 同左 |

如果你的电脑开着代理的 TUN 模式（Clash 一类），部署途中到服务器的 SSH 可能被切断。运行链式命令时请关掉 TUN，或让中转机、出口机的 IP 走直连。

## 安全须知

- 真实 IP、密码和密钥都不会进入本仓库。没有“编辑脚本顶部填 IP”的用法，也没有 `--password` 选项。密码交互输入（非交互场景用环境变量 `OWNEXIT_SSH_PASSWORD`），不写盘。
- 密码输错最多可重试 3 次，每次只向服务器提交一次，不容易触发 fail2ban 一类的封禁。失败时最后一行是 `reason=bad-password`、`reason=password-disabled` 或 `reason=unreachable`。
- 直连的订阅服务是明文 HTTP、靠随机路径保护。平时用 `subctl stop` 关闭，只在导入时打开；链接泄露时用 `setup_direct.sh --rotate-token` 换一个。
- 中转机只运行 `systemd-socket-proxyd`；Reality 私钥只存在于出口机权限 600 的文件里。默认情况下，出口机的 Reality 端口只接受中转机的连接（一张随出口服务起停的 nftables 表）。
- 直连通过第三方脚本 233boy/sing-box 安装 sing-box；链式由每台服务器下载固定版本的官方 sing-box 发布包，并校验归档和 binary 的 SHA-256。

漏洞报告方式见 [SECURITY.md](SECURITY.md)。

## 常见问题

**能改 SSH 端口或用户吗？** 直连用 `--port`、`--user`；链式用 `--relay-port`、`--exit-port`，链式要求 root。

**我有好几台 VPS。** 用 `--host` 指定。不带 `--host` 时，`setup_direct.sh` 和 `subctl` 会列出记住的几台并退出。

**怎么撤销？** 链式：`chain/setup_chain.sh --id main rollback`。直连（0.1.0 还没有卸载命令）：在 VPS 上执行 `systemctl disable --now ownexit-subscription`，删除 `/opt/ownexit-subscription` 和 `/etc/systemd/system/ownexit-subscription.service`，再用安装脚本自带的 `sb` 工具卸载 sing-box。

**文件都在哪？** 密钥：`~/.ssh/ownexit/`；配置：`~/.config/ownexit/`；状态和订阅：`~/.local/state/ownexit/`。

## 参与贡献

欢迎提 issue 和 PR，请先读 [CONTRIBUTING.md](CONTRIBUTING.md)。本项目遵循[贡献者公约](CODE_OF_CONDUCT.md)。

## 许可证

[MIT](LICENSE)。请遵守你所在地的法律法规和服务器提供商的条款。
