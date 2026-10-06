# ownexit

[English](README.md) | **简体中文**

[![Release](https://img.shields.io/github/v/release/jakoes-wu/ownexit)](https://github.com/jakoes-wu/ownexit/releases)
[![CI](https://github.com/jakoes-wu/ownexit/actions/workflows/ci.yml/badge.svg)](https://github.com/jakoes-wu/ownexit/actions/workflows/ci.yml)
[![PyPI](https://img.shields.io/pypi/v/ownexit)](https://pypi.org/project/ownexit/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![bash](https://img.shields.io/badge/bash-3.2%2B-blue)
![platform](https://img.shields.io/badge/control-macOS%20%7C%20Linux-lightgrey)

把你租的 VPS 变成自己专属的固定出口 IP：直连或经中转，在自己电脑上一条命令装好。

```sh
pipx install ownexit
ownexit direct --host 203.0.113.7   # 第一次会问一次 VPS 的 root 密码
```

跑完后，把终端打印的订阅链接粘贴到 Clash Verge 或 Shadowrocket，就能用了。

![ownexit 演示：给两个 IP 部署一条中转 + 出口链](https://raw.githubusercontent.com/jakoes-wu/ownexit/main/docs/assets/demo.gif)

<sub>演示中的 IP 是示例。</sub>

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

## 前置条件

**服务器**：直连 1 台、链式 2 台，系统为 Debian 12 或 Ubuntu 22.04，能用 root 密码 SSH 登录（只用一次）。没买过 VPS？照着手把手教程做：[docs/manual/vps.md](docs/manual/vps.md)，包括怎么选、怎么下单、装系统和防火墙。

**你的电脑**：

| | 直连 | 链式 |
| ---- | ---- | ---- |
| 操作系统 | macOS 或 Linux | macOS 或 Linux（WSL 按 Linux 算） |
| 必需 | Python 3.8+ 与 `pipx`、`ssh`、`curl`、`openssl`、`expect` | 同左 |
| 可选 | `qrencode`：在终端显示节点二维码时用 | `qrencode`：`ownexit multi render` 输出二维码时用 |

缺什么装什么：

```sh
# macOS（需要 Homebrew，https://brew.sh）；ssh、curl、openssl 系统自带
brew install pipx expect
pipx ensurepath            # 然后新开一个终端

# Debian / Ubuntu / WSL
sudo apt update
sudo apt install -y pipx expect openssh-client curl openssl
pipx ensurepath            # 然后新开一个终端
```

不支持 Windows 原生运行，请用 WSL。电脑上的代理开着 TUN 模式（Clash 等）时，部署期间先关掉，见[支持的平台](#支持的平台)。

## 安装

```sh
pipx install ownexit        # 或者：pip install --user ownexit
ownexit --help
```

`ownexit` 只是包内 bash 脚本的一层薄封装，所以也可以 git clone 后直接运行脚本，两者一一对应：

| `ownexit …` | 仓库里的脚本 |
| ---- | ---- |
| `ownexit direct` | `direct/setup_direct.sh` |
| `ownexit subctl` | `direct/subctl` |
| `ownexit connect` | `direct/connect_to.sh` |
| `ownexit chain` | `chain/setup_chain.sh` |
| `ownexit multi` | `chain/multi_chain_client.sh` |

```sh
# 需要 git
git clone https://github.com/jakoes-wu/ownexit && cd ownexit
./direct/setup_direct.sh --host 203.0.113.7
```

从 git clone 运行时，链式脚本还会拒绝放在仓库目录里的配置文件，防止真实 IP 和密钥被误提交。

## 快速上手：直连

1. **部署**

   ```sh
   ownexit direct --host 203.0.113.7          # SSH 端口不是 22 时加 --port 2222
   ```

   依次完成：配免密、检查系统、开启 BBR、由服务器自己下载固定版本的 sing-box 官方包并校验 SHA-256、在服务器上生成 Reality 密钥、生成订阅、上传并逐层验证，全程不用回答问题。想自己指定伪装域名或代理端口，加 `--sni <域名>` 或 `--proxy-port <端口>`；以后换参数也是带新值重跑一次（UUID 与密钥不变）。

2. **导入设备**：脚本最后打印四条链接。

   | 链接 | 给谁用 |
   | ---- | ---- |
   | `…/clash.yaml` | Clash Verge、mihomo、Clash Meta for Android |
   | `…/shadowrocket.txt` | iPhone Shadowrocket、v2rayN / v2rayNG |
   | `…/sing-box.json` | sing-box 官方客户端（SFI / SFA / SFM，1.12 及以上） |
   | `…/node.txt` | 明文 `vless://` 链接，给其它客户端 |

3. **检查并收尾**：在设备上打开 `https://ipinfo.io`，应当显示你 VPS 的 IP。然后关掉订阅服务，需要时再开：

   ```sh
   ownexit subctl stop
   ```

脚本会记住这台 VPS，之后不带参数也能用：`ownexit direct` 重新部署，`ownexit subctl status|start|stop|log|qr` 管理订阅服务、看日志、显示二维码，`ownexit direct --uninstall` 卸载，`ownexit direct --rotate-keys` 在服务器上更换 UUID、Reality 密钥和 short id（所有设备都要重新导入订阅）。

**以前用旧版装过（233boy 脚本）？** 运行一次 `ownexit direct --migrate`：沿用原有 UUID、密钥、端口和 SNI，换成本项目自己的服务，并删除 233boy 的文件（先打包备份）；客户端和订阅链接都不用动。

逐步说明见 [docs/manual/direct.md](docs/manual/direct.md)。

## 快速上手：链式

1. **给两个 IP**

   ```sh
   ownexit chain init --relay 203.0.113.10 --exit 203.0.113.20
   ```

   给两台机器配免密（各问一次密码），探测出口 IP 并请你确认，检查中转机上是否已有 sing-box，生成 `~/.config/ownexit/chains/main.env`。这一步不改动服务器。默认部署时还会在出口机加一条 nftables 规则，让它的 Reality 端口只接受中转机的连接（`--exit-source-filter managed`）；服务商安全组已经这样限制时用 `provider`，不想限制用 `none`。

2. **部署**

   ```sh
   ownexit chain --id main deploy
   ```

   两台服务器自己从 GitHub 下载固定版本的 sing-box（失败才由你的电脑上传），先部署出口机、再部署中转机，整个过程是一个事务，最后从三个层面验证出口 IP；任何一步失败都会自动清理，网络中途断开时再跑一次 `deploy` 或 `rollback` 就会收敛。

3. **导入**：节点链接在 `~/.local/state/ownexit/chains/main/client/node.txt`；也可以运行 `ownexit multi --chains main render` 生成二维码和 Clash 配置片段。

日常操作：`ownexit chain --id main status | verify | conns | rollback`。`ownexit chain --id main rotate-keys` 原地更换出口机的 UUID、Reality 密钥和 short id（中转、端口、部署不变，之后重新导入 `node.txt`）。中转机上同时跑着直连、并且你迁移、改参数或卸载了这台的直连时，之后运行一次 `ownexit chain --id main rebaseline`，让链重新登记它要保护的服务（直连脚本会提醒你）。中转机被墙了？用 `init --id backup …` 再部署一台中转，再用 `multi_chain_client.sh` 把两条链合在一起，客户端会自动切换。完整参考见 [chain/README.md](chain/README.md)，逐步说明见 [docs/manual/chain.md](docs/manual/chain.md)。

## 支持的平台

| | 直连 | 链式 |
| ---- | ---- | ---- |
| 控制端 | macOS（已测试）；Linux（已在 Ubuntu 22.04 测试）；不支持 Windows，可自行尝试 WSL | Apple 芯片的 Mac（已测试）、Intel Mac（未测试）、Linux amd64（已在 Ubuntu 20.04 测试）、Linux arm64 与 WSL（未测试） |
| 服务器系统 | Debian、Ubuntu（systemd 240 及以上） | 带 systemd 的 Linux；中转机需要 `systemd-socket-proxyd`；除本项目自己的表外没有 nftables 表，UFW 未启用 |
| 服务器 CPU | amd64（已在云服务器上测试）或 arm64（已在 Ubuntu 22.04 arm64 虚拟机上测试） | amd64（已在云服务器上测试）或 arm64（已在 Ubuntu 22.04 arm64 虚拟机上测试），两台须相同 |
| 客户端 | 已测试 Clash Verge、mihomo、Shadowrocket；另提供 sing-box 与 v2rayN 订阅；其它支持 VLESS-Reality 的客户端可用 `vless://` 导入 | 已测试 Clash Verge、mihomo、Shadowrocket；其它支持 VLESS-Reality 的客户端可用 `vless://` 导入 |

如果你的电脑开着代理的 TUN 模式（Clash 一类），部署途中到服务器的 SSH 可能被切断。运行链式命令时请关掉 TUN，或让中转机、出口机的 IP 走直连。

## 安全须知

- 真实 IP、密码和密钥都不会进入本仓库。没有“编辑脚本顶部填 IP”的用法，也没有 `--password` 选项。密码交互输入（非交互场景用环境变量 `OWNEXIT_SSH_PASSWORD`），不写盘。
- 密码输错最多可重试 3 次，每次只向服务器提交一次，不容易触发 fail2ban 一类的封禁。失败时最后一行是 `reason=bad-password`、`reason=password-disabled` 或 `reason=unreachable`。
- 直连的订阅服务是明文 HTTP、靠随机路径保护。平时用 `ownexit subctl stop` 关闭，只在导入时打开；链接泄露时用 `ownexit direct --rotate-token` 换一个；节点凭据泄露时用 `--rotate-keys` 换一套。
- 中转机只运行 `systemd-socket-proxyd`；Reality 私钥只存在于出口机权限 600 的文件里。默认情况下，出口机的 Reality 端口只接受中转机的连接（一张随出口服务起停的 nftables 表）。
- 直连和链式都由每台服务器下载固定版本的官方 sing-box 发布包，并校验归档和 binary 的 SHA-256；服务器访问不了 GitHub 时改由你的电脑下载后上传。Reality 私钥在服务器上生成，不离开服务器。

漏洞报告方式见 [SECURITY.md](SECURITY.md)。

## 常见问题

**能改 SSH 端口或用户吗？** 直连用 `--port`、`--user`；链式用 `--relay-port`、`--exit-port`，链式要求 root。

**我有好几台 VPS。** 用 `--host` 指定。不带 `--host` 时，`ownexit direct` 和 `ownexit subctl` 会列出记住的几台并退出。

**怎么撤销？** 链式：`ownexit chain --id main rollback`。直连：`ownexit direct --uninstall`（保留 SSH 免密与迁移备份）。

**文件都在哪？** 密钥：`~/.ssh/ownexit/`；配置：`~/.config/ownexit/`；状态和订阅：`~/.local/state/ownexit/`。

## 参与贡献

欢迎提 issue 和 PR，请先读 [CONTRIBUTING.md](CONTRIBUTING.md)。本项目遵循[贡献者公约](CODE_OF_CONDUCT.md)。

## 许可证

[MIT](LICENSE)。请遵守你所在地的法律法规和服务器提供商的条款。
