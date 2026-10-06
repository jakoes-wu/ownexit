# 更新日志

本项目的所有重要变更都记录在这里。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

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
