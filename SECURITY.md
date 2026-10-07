# Security policy / 安全策略

[English](#english) | [简体中文](#简体中文)

## English

### Supported versions

Only the latest release receives security fixes.

### Reporting a vulnerability

Please report privately through [GitHub Security Advisories](https://github.com/jakoes-wu/ownexit/security/advisories/new) rather than a public issue. Include the version, the operating systems of the control machine and the servers, and the steps to reproduce (mask IPs, UUIDs, node links and similar first). You will get a reply within a week.

### Security boundaries by design

- Real configuration, keys and state live only outside the repository on your computer (`~/.config/ownexit/`, `~/.local/state/ownexit/`, `~/.ssh/ownexit/`), with modes 600 / 700; the chain script refuses to read a configuration located inside the repository.
- The password is typed only once, when setting up key login (or passed in an environment variable); it is never written to disk or printed, and there is no `--password` command-line option.
- The direct subscription service is plain HTTP protected by a random path; turn it off with `ownexit direct sub stop` once every device has imported. If a subscription URL leaks, replace it with `ownexit direct rotate-token`; if node credentials leak, replace them with `ownexit direct rotate-keys` (direct) or `ownexit chain rotate-keys` (relay chain). New credentials are likewise generated only on the server.
- In a relay chain the relay only runs `systemd-socket-proxyd` for TCP forwarding and holds no keys; the Reality private key exists only in the exit's mode-600 configuration.
- The relay port of a chain has no authentication: anyone can reach the exit's Reality inbound through the relay (but cannot use it without credentials); block unknown sources with `ban`. By default the exit's Reality port admits only the relay (`EXIT_SOURCE_FILTER=managed`, an nftables table that starts and stops with the exit service).
- sing-box is installed from the pinned official release (the same for direct and chain: each server downloads it itself, and the SHA-256 of both the archive and the binary are hard-coded in the scripts; if the server download fails, your computer downloads and uploads it). The Reality private key is generated on the server and never leaves it. The only exception is the chain `migrate-exit` to another machine: the exit configuration (including the private key) is read from the old exit over SSH, passes only through your computer's process memory and pipes, and is written straight into a mode-600 file on the new exit — never to your disk, never in command-line arguments or logs; the copy on the old machine is deleted after the migration (except with `--abandon-cleanup`).

## 简体中文

### 支持的版本

只有最新版本会收到安全修复。

### 报告漏洞

请通过 [GitHub Security Advisories](https://github.com/jakoes-wu/ownexit/security/advisories/new) 私下报告，不要开公开 issue。请附上版本、控制端与服务器的系统，以及复现步骤（记得先遮盖 IP、UUID、节点链接等信息）。一周内会回复。

### 设计上的安全边界

- 真实配置、密钥和状态只存放在本机仓库外（`~/.config/ownexit/`、`~/.local/state/ownexit/`、`~/.ssh/ownexit/`），权限 600 / 700；链式脚本会拒绝读取位于仓库内的配置。
- 密码只在第一次配免密时交互输入（或经环境变量传入），不写盘、不打印，也没有 `--password` 命令行选项。
- 直连的订阅服务是明文 HTTP、靠随机路径保护，建议所有设备导入后用 `ownexit direct sub stop` 关闭；订阅地址泄露用 `ownexit direct rotate-token` 更换，节点凭据泄露用 `ownexit direct rotate-keys`（直连）或 `ownexit chain rotate-keys`（链式）更换，新凭据同样只在服务器上生成。
- 链式的中转机只运行 `systemd-socket-proxyd` 做 TCP 透传，不保存任何密钥；Reality 私钥只在出口机的 600 配置里。
- 链式的中转端口没有鉴权，任何人都能经中转连到出口机的 Reality 入站（但没有凭据无法使用）；发现陌生来源可用 `ban` 拉黑。出口机的 Reality 端口默认只放行中转机（`EXIT_SOURCE_FILTER=managed`，nftables 表随出口服务起停）。
- sing-box 由固定版本的官方发布包安装（直连与链式相同：每台服务器自行下载，归档与 binary 的 SHA256 都写死在脚本里核对；服务器下载失败时由本机下载后上传）。Reality 私钥在服务器上生成，不离开服务器。唯一例外是链式 `migrate-exit`（出口机换一台机器）：出口机配置（含私钥）经 SSH 从旧出口机读出，只在本机进程内存与管道里经过，直接写入新出口机的 600 文件，不写本机磁盘、不出现在命令行参数与日志里；迁移完成后旧机器上的副本会被删除（`--abandon-cleanup` 时除外）。
