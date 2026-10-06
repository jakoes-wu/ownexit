# 直连部署手册

把一台境外 VPS 变成你自己的固定出口：客户端直接连 VPS，网站看到的是这台 VPS 的 IP。整个过程在你自己的电脑上运行，不需要登录服务器敲命令。

## 1. 它是怎么工作的

```text
你的设备（Clash Verge / mihomo / Shadowrocket / 安卓客户端）
   │  VLESS-Reality：外观像正常的 HTTPS 访问
   ▼
你的 VPS（sing-box）
   │  以这台 VPS 的 IP 发起请求
   ▼
目标网站
```

| 角色 | 是什么 | 你要做的 |
| ---- | ---- | ---- |
| 服务端 | 你租的 VPS，运行 sing-box | 用 `setup_direct.sh` 装一次，长期运行 |
| 客户端 | 各设备上的代理应用 | 粘贴订阅链接，选节点，连接 |
| 分流规则 | 决定哪些流量走出口 | 默认国内直连、其余走出口，可在客户端切成全局 |

## 2. 准备

**一台 VPS**，选购时只看这几点：

- 系统选 **Debian 12** 或 **Ubuntu 22.04 LTS**（脚本只支持 Debian / Ubuntu）。
- 有一个**独享的公网 IPv4**，能用 root 密码 SSH 登录。
- 地区和线路按你的使用需求选；对大陆访问延迟敏感时优先考虑面向大陆优化的线路。
- 先月付试用，确认 IP 质量和线路稳定后再考虑长期。

从选购、下单到装系统的完整步骤见 [VPS 选购与系统安装手册](vps.md)。

拿到机器后先查一下 IP：浏览器访问 `https://ipinfo.io/<你的IP>` 看归属和类型，再用 Scamalytics 一类的工具看风险分，不满意尽早换。

**一台电脑**（macOS 已验证；Linux 已在 Ubuntu 22.04 验证），装好：

- `git`、`ssh`、`curl`、`openssl`（macOS 自带）
- `expect`：第一次配免密时自动输入密码用，macOS 执行 `brew install expect`，Debian / Ubuntu 执行 `sudo apt install expect`
- `qrencode`（可选）：在终端显示节点二维码用，macOS 执行 `brew install qrencode`

## 3. 部署

```sh
pipx install ownexit
ownexit direct --host 203.0.113.7
```

SSH 端口不是 22 时加 `--port 2222`。本手册下文的命令按 git clone 的写法给出；用 pipx 安装时把 `./direct/setup_direct.sh` 换成 `ownexit direct`、`./direct/subctl` 换成 `ownexit subctl`，参数完全相同。

运行过程：

1. **配免密**：第一次会问一次 VPS 的 root 密码（不回显）。密码错了可以再输，最多 3 次；之后全程用专用密钥登录，密钥在 `~/.ssh/ownexit/`。
2. **检查系统并记住这台 VPS**：之后再运行 `setup_direct.sh` 或 `subctl` 不用再带 `--host`。
3. **开启 BBR**，然后**安装 sing-box**：VPS 自己从 GitHub 下载固定版本的 sing-box 官方包并校验 SHA-256（VPS 访问不了 GitHub 时由你的电脑下载后上传），在 VPS 上生成 Reality 密钥、UUID 和 short id，写好 `ownexit-direct` 服务并启动。全程不用回答问题。伪装域名默认 `www.amazon.com`、代理端口默认在 20000～59999 随机，想自己指定加 `--sni <域名>`、`--proxy-port <端口>`。
   这一步由 VPS 上的一个 systemd 临时任务执行：中途网络断开不影响它，VPS 断电重启后再运行一次本命令会从中断处接着做完。
4. **生成订阅并验证**：从 VPS 读回节点参数，在本地渲染三种订阅，上传到 VPS 并起一个只读订阅服务，然后逐项验证。本机装了 `qrencode` 时，最后还会在终端显示节点二维码。

结束时打印三条订阅链接：

| 链接 | 给谁用 |
| ---- | ---- |
| `.../clash.yaml` | Clash Verge、mihomo、Clash Meta for Android |
| `.../shadowrocket.txt` | iPhone Shadowrocket |
| `.../node.txt` | 明文 `vless://` 节点链接，给其它客户端手工导入或备份 |

## 4. 导入客户端

**Clash Verge（macOS / Windows / Linux）**

1. 从 GitHub 的 `clash-verge-rev/clash-verge-rev` Releases 下载对应系统的安装包（Apple 芯片选 arm64 / aarch64）。macOS 首次打开被拦截时，到“系统设置 → 隐私与安全性”点“仍要打开”。
2. 「订阅」页粘贴 Clash 订阅链接 → 导入 → 点击订阅卡片选中它。
3. 「代理」页的 `PROXY` 组选 `ownexit-direct`。
4. 「设置」页打开系统代理（想让终端命令也走代理就开 Tun 模式），模式选「规则」。

**iPhone Shadowrocket**：右上角 `+` → 类型选 Subscribe → 粘贴 Shadowrocket 订阅链接 → 保存并更新 → 选节点 → 连接，首次连接允许添加 VPN 配置。

**安卓**：安装 Clash Meta for Android 或 sing-box 官方应用，新建配置时选“从 URL 导入”，粘贴 Clash 订阅链接；只支持节点链接的客户端就用 `node.txt` 里的 `vless://` 链接。

**命令行 mihomo**：

```sh
mkdir -p ~/.config/mihomo
curl -L '<Clash 订阅链接>' -o ~/.config/mihomo/config.yaml
mihomo -d ~/.config/mihomo
curl -x http://127.0.0.1:7890 https://ipinfo.io   # 另开终端验证
```

**默认分流规则**：国内域名和 IP 直连，其余全部走 `PROXY` 组。想让所有流量都走出口，在客户端把模式切到「全局」。

## 5. 验证出口

连上之后浏览器访问 `https://ipinfo.io`，显示的 IP 应当等于你的 VPS IP。

`setup_direct.sh` 自己已经验证过的部分：

| 层 | 检查内容 |
| ---- | ---- |
| VPS 主机 | sing-box 服务运行中，代理端口在监听 |
| 订阅服务 | 订阅服务运行中，端口在监听 |
| 订阅内容 | 从本机拉取的 `clash.yaml` 与本地渲染结果逐字节一致；根路径返回空内容，不暴露订阅地址 |

客户端侧的出口需要你在设备上确认。

## 6. 日常维护

```sh
./direct/subctl status      # 代理服务和订阅服务的状态
./direct/subctl log         # 代理服务最近 100 行日志（log 300 看 300 行）
./direct/subctl qr          # 在终端显示节点二维码（需要 qrencode）
./direct/subctl stop        # 所有设备导入后关掉订阅服务（推荐常态）
./direct/subctl start       # 给新设备导入前临时打开，用完再 stop
./direct/subctl             # 免密登录这台 VPS
./direct/setup_direct.sh --rotate-token   # 怀疑订阅链接泄露时换一个新地址
./direct/setup_direct.sh --uninstall      # 卸载 VPS 上的代理服务和订阅服务
```

- 订阅服务是明文 HTTP 的公网端口，平时保持关闭，只在导入时临时打开。
- 换一台 VPS：对新机器运行 `setup_direct.sh --host <新IP>`，再到客户端更新订阅。记住了多台 VPS 时，`subctl` 和 `setup_direct.sh` 不带 `--host` 会列出可选目标并退出。
- 改伪装域名或代理端口：`setup_direct.sh --sni <域名>` 或 `--proxy-port <端口>`，UUID 和密钥不变，改完客户端要重新拉一次订阅。正在通过这条隧道上网时改握手参数会把自己锁在外面：先切到别的网络，再改。
- 卸载：`setup_direct.sh --uninstall` 删除 VPS 上的 `ownexit-direct` 服务、订阅服务和相关目录；保留 SSH 免密、记住的目标、BBR 设置和迁移备份。
- 这台 VPS 同时是链式部署的中转机时，直连新装、迁移、改参数、卸载之后，按脚本提示运行 `ownexit chain --id <名字> rebaseline`。
- 重要文件都在本机仓库外：密钥在 `~/.ssh/ownexit/`，目标配置在 `~/.config/ownexit/direct/`，订阅 TOKEN 在 `~/.local/state/ownexit/direct/`。

## 7. 常见问题

| 问题 | 可能原因 | 解决办法 |
| ---- | ---- | ---- |
| `reason=bad-password` | 密码错了 3 次 | 到服务商控制台核对或重置 root 密码 |
| `reason=password-disabled` | 服务器关闭了密码登录 | 在控制台开启密码登录，或手工把 `~/.ssh/ownexit/` 下对应的 `.pub` 内容加进 VPS 的 `~/.ssh/authorized_keys` |
| `reason=unreachable` | IP、SSH 端口不对，或安全组没放行 | 核对 IP 和端口；SSH 本身连不上时用服务商的网页终端（VNC）排查 |
| 公钥推送成功但免密仍失败 | 服务商模板把 sshd 的公钥认证关了 | `connect_to.sh` 会自动把 `PubkeyAuthentication no` 改回 `yes` 并重启 sshd（需 root）；仍失败就在网页终端里手工改 |
| 客户端能连上但上不了网 | 代理端口没放行，或 SNI 域名不通 | 检查服务商安全组；运行 `subctl log` 看日志，必要时用 `--sni` / `--proxy-port` 换 SNI 或端口 |
| 提示“服务器上是用 233boy 脚本装的旧版”（退出码 2） | 这台 VPS 是用旧版 ownexit（233boy 脚本）部署的 | 运行 `setup_direct.sh --migrate`，见第 9 节 |
| 提示“上次未完成的操作恢复失败” | 迁移等操作中途 VPS 断电，恢复时新服务也起不来 | 按提示看 `subctl log`；迁移备份在 `/var/backups/ownexit-direct/` |
| 国内网站也走了代理 | 客户端的 GeoIP / GeoSite 数据库没下载完 | 在客户端设置里手动更新一次数据库 |
| 测试端口时“秒通”或结果互相矛盾 | 本机开着 TUN，所有连接被本地代理接管 | 关掉 TUN 再测 |
| SSH 时刷 `setlocale: LC_ALL: cannot change locale` | 本机把中文 locale 转发给了 VPS | 无害；本仓库脚本已强制发送 `C.UTF-8` |
| 节点能连但很慢 | BBR 未生效，或线路高峰拥堵 | 看 `setup_direct.sh` 输出里 BBR 是否为 `[+]`；观察高峰时段，必要时换线路 |

## 8. 安全须知

- 不要把真实 IP、密码写进任何会提交或分享的文件。本仓库的脚本没有“编辑脚本顶部填 IP”的用法，也没有 `--password` 选项。
- root 密码设复杂一些；配好免密后可以考虑在 VPS 上关闭密码登录（关之前确认免密可用，并保留服务商网页终端作为兜底）。
- sing-box 由 VPS 下载固定版本的官方发布包安装，归档和二进制的 SHA-256 都写死在脚本里核对；Reality 私钥在 VPS 上生成，不离开 VPS。
- 请遵守你所在地的法律法规和服务商条款。

## 9. 从旧版（233boy）迁移

ownexit 0.3 及更早的版本用第三方脚本 233boy/sing-box 安装 sing-box。新版检测到这种安装时会停下来（退出码 2），服务器不做任何改动。运行一次：

```sh
./direct/setup_direct.sh --migrate
```

它会：

1. 检查旧安装能否迁移：233boy 只装了一个 VLESS-REALITY 节点、旧服务在运行。装了多个协议时拒绝迁移并说明原因。
2. 沿用原有的 UUID、Reality 密钥、端口、SNI 和 short id，写好 `ownexit-direct` 服务。
3. 把 233boy 的文件打包备份到 `/var/backups/ownexit-direct/233boy-<时间>.tar.gz`（含旧私钥，确认无需回退后可自行删除）。
4. 停掉旧服务、启动新服务（代理中断约 1～3 秒）；新服务起不来就自动回到旧服务。
5. 确认新服务正常后删除 233boy 的文件（含 `sb` 命令和 `.bashrc` 里的两行 alias）。

客户端和订阅链接都不用动。迁移后原来用 `sb` 做的事改用 `subctl log`、`subctl qr`、`setup_direct.sh --sni / --proxy-port`。

