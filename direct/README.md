# 直连：一台 VPS 当出口

```sh
./direct/setup_direct.sh --host 203.0.113.7   # 第一次会问一次 VPS 的 root 密码
```

一步一步的说明（选机器、导入客户端、验证、排查）见 [`docs/manual/direct.md`](../docs/manual/direct.md)。

## 脚本

| 脚本 | 作用 |
| ---- | ---- |
| `setup_direct.sh` | 部署入口：配免密 → 检查系统 → 开 BBR → 装 sing-box → 生成并上传订阅 → 验证 |
| `subctl` | 部署后的日常操作：`status` / `start` / `stop` 订阅服务、`log`、`qr`、`devices` 列出设备，或免密登录 VPS |
| `connect_to.sh` | 给一台 VPS 配专用 SSH 密钥；`setup_direct.sh` 和链式的 `init` 会自动调用它 |
| `sync_to_vps.sh` | 把本地渲染好的订阅目录上传到 VPS；由 `setup_direct.sh` 调用 |
| `doctor.sh` | 诊断：检查本机环境、已记住的直连 VPS 和链，`--ip-check` 体检出口 IP，`--scan-sni` 扫描可用的伪装域名（`ownexit doctor`） |
| `target_lib.sh` | 被 `setup_direct.sh` 和 `subctl` 共用的“记住目标 VPS”逻辑，不能单独运行 |

每个可执行脚本都支持 `-h` / `--help`。

## 目标从哪里来

`setup_direct.sh` 和 `subctl` 按这个顺序决定操作哪台 VPS：

1. 命令行的 `--host`（可加 `--port`，默认 22；`--user`，默认 root）。
2. 上次部署成功时记住的目标：`~/.config/ownexit/direct/<user>_<host>_<port>.env`，只有 `HOST`、`SSH_PORT`、`SSH_USER` 三个键，权限 600。只记住了一台时自动使用；记住了多台时列出来，请你用 `--host` 选。
3. 都没有时：`setup_direct.sh` 在终端里提问；`subctl` 提示先部署。不在终端里运行时，缺参数以退出码 2 结束。

## 密码

只在第一次配免密时需要，交互输入、不回显。输错可以重输，一共 3 次，每次只向服务器提交一次，避免触发封禁。非交互运行（比如脚本里调用）用环境变量 `OWNEXIT_SSH_PASSWORD` 传入，错了不重试。

登录失败时 `connect_to.sh` 以退出码 3 结束，最后一行是原因：

| 输出 | 含义 |
| ---- | ---- |
| `reason=bad-password` | 密码错误 |
| `reason=password-disabled` | 服务器关闭了密码登录 |
| `reason=unreachable` | 连不上：IP、端口或安全组的问题 |

## 本机与 VPS 上的文件

| 位置 | 内容 |
| ---- | ---- |
| `~/.ssh/ownexit/id_ed25519_<user>_<host>_<port>` | 每台 VPS 的专用密钥 |
| `~/.config/ownexit/direct/` | 记住的目标 VPS |
| `~/.local/state/ownexit/direct/<user>_<host>_<port>/` | `state.env`（订阅 `SUB_PORT` 与 `TOKEN`，权限 600）和本地渲染的订阅目录 |
| VPS 上 `/opt/ownexit-subscription/` | 订阅文件与订阅服务脚本 `subserver.py`；服务只响应 `/<TOKEN>/<文件名>` 与自适应 `/<TOKEN>/sub`，其它路径 404，不暴露 TOKEN（空 `index.html` 保留，已不承担防列目录） |
| VPS 上 `ownexit-subscription.service` | 只读订阅服务（以 `nobody` 运行的 `python3 subserver.py`；1.3.0 之前是 `python3 -m http.server`，重跑一次 `ownexit direct` 即切换） |
