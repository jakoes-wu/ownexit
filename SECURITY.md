# 安全策略

## 支持的版本

只有最新版本会收到安全修复。

## 报告漏洞

请通过 [GitHub Security Advisories](https://github.com/jakoes-wu/ownexit/security/advisories/new) 私下报告，不要开公开 issue。请附上版本、控制端与服务器的系统，以及复现步骤（记得先遮盖 IP、UUID、节点链接等信息）。一周内会回复。

## 设计上的安全边界

- 真实配置、密钥和状态只存放在本机仓库外（`~/.config/ownexit/`、`~/.local/state/ownexit/`、`~/.ssh/ownexit/`），权限 600 / 700；链式脚本会拒绝读取位于仓库内的配置。
- 密码只在第一次配免密时交互输入（或经环境变量传入），不写盘、不打印，也没有 `--password` 命令行选项。
- 直连的订阅服务是明文 HTTP、靠随机路径保护，建议所有设备导入后用 `direct/subctl stop` 关闭；订阅地址泄露用 `--rotate-token` 更换，节点凭据泄露用 `--rotate-keys`（直连）或 `rotate-keys`（链式）更换，新凭据同样只在服务器上生成。
- 链式的中转机只运行 `systemd-socket-proxyd` 做 TCP 透传，不保存任何密钥；Reality 私钥只在出口机的 600 配置里。
- 链式的中转端口没有鉴权，任何人都能经中转连到出口机的 Reality 入站（但没有凭据无法使用）；发现陌生来源可用 `ban` 拉黑。出口机的 Reality 端口默认只放行中转机（`EXIT_SOURCE_FILTER=managed`，nftables 表随出口服务起停）。
- sing-box 由固定版本的官方发布包安装（直连与链式相同：每台服务器自行下载，归档与 binary 的 SHA256 都写死在脚本里核对；服务器下载失败时由本机下载后上传）。Reality 私钥在服务器上生成，不离开服务器。
