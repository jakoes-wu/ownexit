# 更新日志

本项目的所有重要变更都记录在这里。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.2.0] - 2026-10-06

### 新增

- 链式 `chain up --relay <IP> --exit <IP>`：一条命令完成 init、deploy 并打印节点二维码与下一步；可重跑，已有配置且地址一致时直接继续，不带 IP 且本机只有一条链时复用它。
- 链式子命令在本机只有一条链时可以省略 `--id`（`ownexit chain status`）；没有配置或有多条时退出 2 并提示。
- 链式 `chain qr [--device <名字>]`：在终端显示节点二维码，只读本机文件。
- 直连与链式部署成功后打印“下一步”块（导入哪条链接、应显示的出口 IP、`subctl stop`、`doctor`），二维码紧随其后。
- `ownexit --help` 按系统语言输出中文或英文（`OWNEXIT_LANG=zh|en` 可强制），并分“常用 / 其它”两组；`chain --help` 的子命令按常用 / 日常 / 维护 / 高级分组。

### 变更

- **部署前自检（行为变化）**：`ownexit direct`、`chain deploy` / `chain up` 开始前检查本机到服务器的路由是否经过代理 TUN；经过时不再只是警告，而是拒绝（链式退出 3，直连退出 1）并给出处理办法。一直在 TUN 下部署的用户需要关闭 TUN、按 `docs/manual/clash-direct-ips.md` 让服务器 IP 走物理网卡，或加 `--allow-tun` 恢复旧行为。

## [1.1.0] - 2026-10-06

### 新增

- 链式 `migrate-exit --to <新出口机 IPv4> [--to-port <n>]`：出口机换一台机器。旧出口机的配置（含 Reality 私钥）经本机内存搬到新机器，UUID、密钥、short id、全部设备、中转地址与端口都不变，客户端不用重新导入；中转转发目标切过去后自动删除旧出口机上本链的服务与文件。中途中断重跑同一条命令即可收敛；中转切换前可用 `--abort` 放弃，旧机器永久失联时可用 `--abandon-cleanup` 放弃清理。
- 链式 `status` 新增 `reason=exit-migration-pending`；新增输出行 `migrate=done` / `migrate=aborted`；新增本机文件 `chains/<id>/migrate-exit.env`（迁移进行中才存在）。

### 变更

- 出口机迁移进行中时，deploy、rollback、rehost-exit、rebaseline、rotate-keys、add-device、remove-device 拒绝执行并提示先完成迁移。没有迁移记录时行为与 1.0.0 相同。

## [1.0.0] - 2026-10-06

### 新增

- 接口冻结：命令行、配置键、本机与服务器文件格式在 1.x 内只增不减，已有部署升级后无需重新部署或重新导入客户端；不兼容改动只在 2.0 并提供迁移。规则见 `docs/reference/compatibility.md`。
- 参考文档 `docs/reference/commands.md`（命令、参数、退出码、机器可读输出、环境变量）与 `docs/reference/files.md`（文件、键、路径、节点名）。
- `scripts/check_interface.sh`：CI 自动比对源码与参考文档里的参数、子命令、status 取值、配置 / 状态键、订阅文件名，不一致时失败。

### 变更

- PyPI 分类标为 Development Status :: 5 - Production/Stable。
- 本版本不改变任何命令、输出与文件格式。

## [0.7.0] - 2026-10-05

### 新增

- 多设备（直连与链式）：每台设备一个独立 UUID，可单独吊销，其它设备不受影响。直连 `--add-device` / `--remove-device`（每台设备有自己的订阅地址）与 `subctl devices`；链式 `add-device` / `remove-device` / `list-devices`（每台设备一个节点文件）。现有的那套凭据就是 `default`，订阅地址与 `node.txt` 不变。
- `ownexit doctor --scan-sni`：在出口服务器上对候选伪装域名逐个做真实 Reality 握手（本机回环），按可用与握手耗时排序；可用 `--sni-candidates` 指定候选。

### 变更

- 凭据轮换（直连 `--rotate-keys`、链式 `rotate-keys`）同时重新生成全部设备的 UUID。
- 链式 `status` 在出口机有未完成的凭据或设备操作时输出 `reason=exit-op-pending next=rerun-interrupted-command`（原为 `reason=rotate-pending next=run-rotate-keys`）。
- 新部署的链与改过参数的直连，服务器配置的 users 项带 `name` 字段。

## [0.6.0] - 2026-10-05

### 新增

- `ownexit doctor`：检查本机（依赖命令、代理环境变量、目录权限、到服务器的路由是否经过代理 TUN）、每台记住的直连 VPS（密钥、SSH、服务、订阅、BBR）与每条链（运行 `status`），逐项输出 OK / WARN / FAIL 和处理办法。
- `ownexit doctor --ip-check`：在出口服务器上体检出口 IP：归属与类型、ChatGPT / Claude / Gemini、Netflix / YouTube Premium / Disney+、常用网站连通性（仅供参考）。

### 变更

- 链式只读命令（`status`、不带 `--with-fail-closed` 的 `verify`、`conns`、`banlist`）遇到 SSH 连接层失败（255，非控制端超时）时自动重试最多 3 次，减少本机开着 TUN 时的偶发失败；修改类命令不重试。

## [0.5.0] - 2026-10-05

### 新增

- 直连订阅新增 `sing-box.json`：sing-box 官方客户端（SFI / SFA / SFM，1.12 及以上）可直接导入的完整配置；v2rayN / v2rayNG 使用已有的 base64 订阅（交付信息与手册写明）。
- 直连 `--rotate-keys`：在服务器上重新生成 UUID、Reality 密钥对与 short id，端口、SNI、订阅地址不变；失败自动恢复原配置，中途断开重跑不会换两次。
- 链式 `rotate-keys`：原地更换出口机的 UUID、Reality 密钥对与 short id，中转、端口、部署 ID 不变，更新 `node.txt` 后自动跑完整 verify；中途断开重跑同一条命令收敛。辅助文件未清理时 `status` 输出 `reason=rotate-pending next=run-rotate-keys`，`verify` / `rollback` 拒绝执行。

### 修复

- 直连恢复上次中断的改参数操作后，没有提示重新导入订阅与同机链的 `rebaseline`。
- 直连帮助里改伪装域名的示例 `--sni www.microsoft.com` 实测不可用（客户端 Reality 握手被服务器判为无效），改为实测可用的 `www.apple.com`，并在帮助与手册中提示换域名后先实测。

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
