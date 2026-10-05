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

拿到机器后先查一下 IP：浏览器访问 `https://ipinfo.io/<你的IP>` 看归属和类型，再用 Scamalytics 一类的工具看风险分，不满意尽早换。

**一台电脑**（macOS 已验证；Linux 未测试），装好：

- `git`、`ssh`、`curl`、`openssl`（macOS 自带）
- `expect`：第一次配免密时自动输入密码用，macOS 执行 `brew install expect`

## 3. 部署

```sh
pipx install ownexit
ownexit direct --host 203.0.113.7
```

SSH 端口不是 22 时加 `--port 2222`。本手册下文的命令按 git clone 的写法给出；用 pipx 安装时把 `./direct/setup_direct.sh` 换成 `ownexit direct`、`./direct/subctl` 换成 `ownexit subctl`，参数完全相同。

运行过程：

1. **配免密**：第一次会问一次 VPS 的 root 密码（不回显）。密码错了可以再输，最多 3 次；之后全程用专用密钥登录，密钥在 `~/.ssh/ownexit/`。
2. **检查系统并记住这台 VPS**：之后再运行 `setup_direct.sh` 或 `subctl` 不用再带 `--host`。
3. **开启 BBR**，然后**安装 sing-box**：这一步经 SSH 交互式运行第三方安装脚本 [233boy/sing-box](https://github.com/233boy/sing-box)，按提示回答：
   - 协议：按名称选 **VLESS-REALITY**（不要死记菜单编号）
   - 端口：直接回车（随机）
   - SNI：可以输入一个大众网站域名，或直接回车用默认
   - UUID：直接回车（自动生成）
   - 遇到没见过的菜单，按 Ctrl+C 退出，不要盲目回车
4. **生成订阅并验证**：脚本读取真实节点参数，在本地渲染三种订阅，上传到 VPS 并起一个只读订阅服务，然后逐项验证。

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
./direct/subctl status      # sing-box 和订阅服务的状态
./direct/subctl stop        # 所有设备导入后关掉订阅服务（推荐常态）
./direct/subctl start       # 给新设备导入前临时打开，用完再 stop
./direct/subctl             # 免密登录这台 VPS
./direct/setup_direct.sh --rotate-token   # 怀疑订阅链接泄露时换一个新地址
```

- 订阅服务是明文 HTTP 的公网端口，平时保持关闭，只在导入时临时打开。
- 换一台 VPS：对新机器运行 `setup_direct.sh --host <新IP>`，再到客户端更新订阅。记住了多台 VPS 时，`subctl` 和 `setup_direct.sh` 不带 `--host` 会列出可选目标并退出。
- 改节点参数（SNI、UUID、端口）要在 VPS 上用 `sb` 改完，再重新运行 `setup_direct.sh` 让订阅同步。正在通过这条隧道上网时改握手参数会把自己锁在外面：先切到别的网络，再改。
- 重要文件都在本机仓库外：密钥在 `~/.ssh/ownexit/`，目标配置在 `~/.config/ownexit/direct/`，订阅 TOKEN 在 `~/.local/state/ownexit/direct/`。

## 7. 常见问题

| 问题 | 可能原因 | 解决办法 |
| ---- | ---- | ---- |
| `reason=bad-password` | 密码错了 3 次 | 到服务商控制台核对或重置 root 密码 |
| `reason=password-disabled` | 服务器关闭了密码登录 | 在控制台开启密码登录，或手工把 `~/.ssh/ownexit/` 下对应的 `.pub` 内容加进 VPS 的 `~/.ssh/authorized_keys` |
| `reason=unreachable` | IP、SSH 端口不对，或安全组没放行 | 核对 IP 和端口；SSH 本身连不上时用服务商的网页终端（VNC）排查 |
| 公钥推送成功但免密仍失败 | 服务商模板把 sshd 的公钥认证关了 | `connect_to.sh` 会自动把 `PubkeyAuthentication no` 改回 `yes` 并重启 sshd（需 root）；仍失败就在网页终端里手工改 |
| 客户端能连上但上不了网 | 代理端口没放行，或 SNI 域名不通 | 检查服务商安全组；在 VPS 上运行 `sb` 看日志，必要时换 SNI 或端口 |
| 国内网站也走了代理 | 客户端的 GeoIP / GeoSite 数据库没下载完 | 在客户端设置里手动更新一次数据库 |
| 测试端口时“秒通”或结果互相矛盾 | 本机开着 TUN，所有连接被本地代理接管 | 关掉 TUN 再测 |
| SSH 时刷 `setlocale: LC_ALL: cannot change locale` | 本机把中文 locale 转发给了 VPS | 无害；本仓库脚本已强制发送 `C.UTF-8` |
| 节点能连但很慢 | BBR 未生效，或线路高峰拥堵 | 看 `setup_direct.sh` 输出里 BBR 是否为 `[+]`；观察高峰时段，必要时换线路 |

## 8. 安全须知

- 不要把真实 IP、密码写进任何会提交或分享的文件。本仓库的脚本没有“编辑脚本顶部填 IP”的用法，也没有 `--password` 选项。
- root 密码设复杂一些；配好免密后可以考虑在 VPS 上关闭密码登录（关之前确认免密可用，并保留服务商网页终端作为兜底）。
- sing-box 的安装由第三方脚本 233boy/sing-box 完成，只从它的官方仓库获取。
- 请遵守你所在地的法律法规和服务商条款。
