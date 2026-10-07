# 文件参考（1.x 冻结）

本文件列出 ownexit 在本机与服务器上读写的文件、键与路径。1.x 内这些路径、键与格式只增不减、含义不变；标为“参考”或“内部”的不属于公开接口，兼容规则见 [compatibility.md](compatibility.md)。表格中带反引号的首列由 `scripts/check_interface.sh` 与源码自动比对。

## 本机目录

| 目录 | 默认 | 说明 |
| ---- | ---- | ---- |
| 配置目录 | `~/.config/ownexit/` | 受 `XDG_CONFIG_HOME` 影响 |
| 状态目录 | `~/.local/state/ownexit/` | 受 `XDG_STATE_HOME` 影响；`ownexit/` 这一级必须是 700（链式在这里放全局锁） |
| 缓存目录 | `~/.cache/ownexit/` | 受 `XDG_CACHE_HOME` 影响；可删除，按需重新下载 |
| 密钥目录 | `~/.ssh/ownexit/` | 不受 XDG 影响；每台服务器一把 `id_ed25519_<safe_name>`（及 `.pub`） |

`safe_name` = `<用户>_<地址>_<端口>`，其中不属于字母、数字、`_` `.` `@` `-` 的字符替换为 `_`。XDG 变量的取值规则见 [commands.md](commands.md#环境变量)。

## 直连（本机）

| 路径（相对配置 / 状态目录） | 内容 |
| ---- | ---- |
| `direct/<safe_name>.env`（配置目录） | 记住的目标；只允许 `HOST` / `SSH_PORT` / `SSH_USER` 三个键 |
| `direct/<safe_name>/state.env`（状态目录） | 订阅参数：`SUB_PORT`、`TOKEN`（32 位十六进制） |
| `direct/<safe_name>/devices.env`（状态目录） | 每台额外设备的订阅 TOKEN，每行 `名字=TOKEN`；以 `!` 开头的行是待在 VPS 上删除的旧 TOKEN |
| `direct/<safe_name>/ownexit-subscription/<TOKEN>/`（状态目录） | 本机渲染的订阅（同步到 VPS 的副本）；`ownexit subctl qr` 读其中 default 的 `node.txt` |

## 链式（本机）

| 路径 | 内容 |
| ---- | ---- |
| `<配置目录>/chains/<id>.env` | 链配置，键见下表“链配置键” |
| `<状态目录>/chains/<id>/state.env` | 权威部署状态，带内嵌校验和；键表见“链 state.env 键（参考）” |
| `<状态目录>/chains/<id>/client/node.txt` | default 设备的节点：单行 vless URI，片段为 `#Exit-via-Relay-<id>` |
| `<状态目录>/chains/<id>/devices/devices.env` | 额外设备表，每行 `名字=UUID`（不含 default）；是出口机配置的本机缓存 |
| `<状态目录>/chains/<id>/devices/node-<名字>.txt` | 额外设备的节点：单行 vless URI，片段为 `#Exit-via-Relay-<id>_<名字>` |
| `<状态目录>/chains/<id>/blacklist.txt` | 中转黑名单的本地权威副本 |
| `<状态目录>/chains/<id>/migrate-exit.env` | 出口机迁移记录（1.1.0 起），只在 `migrate-exit` 进行中或旧出口机待清理时存在；KEY=VALUE、600，空值写 `-`；存在时 status 输出 `reason=exit-migration-pending` |
| `<配置目录>/chains/<id>.env.bak.<时间>` | `migrate-exit` 改写配置前的备份（600，迁移后不自动删除） |
| `<状态目录>/multi-chain-client/<名>/nodes.txt` | `ownexit multi render`：每链一行 vless URI |
| `<状态目录>/multi-chain-client/<名>/clash-snippet.yaml` | `ownexit multi render`：proxies 与自动组片段 |
| `${TMPDIR:-/tmp}/multi-chain-client-qr.*/qr-<n>-<节点名>.png` | `ownexit multi render` 的二维码（`--qr-out` 可指定目录；含明文凭据，扫完即删） |
| `<缓存目录>/chains/<id>/downloads/` | 固定版本 sing-box 官方包缓存 |

内部文件（不属于公开接口，但 1.y 必须能读 1.x 写下的版本）：`<状态目录>/chains/<id>/` 下的 `transaction.env`、`baseline/`、`audit/`、`operation.lock`、`active-child.env`、`local-process.env`、各类以 `.` 开头的临时文件（含 `.migrate-exit.env.*.tmp`），`<状态目录>/` 下的 `shared.lock`。

### 链配置键

| 键 | 取值 / 含义 |
| ---- | ---- |
| `CHAIN_ID` | 链名，`[a-z0-9][a-z0-9-]{0,31}`，与文件名一致 |
| `RELAY_HOST` | 中转机 IPv4 |
| `RELAY_SSH_PORT` | 中转机 SSH 端口 |
| `RELAY_SSH_USER` | 中转机 SSH 用户（必须是 root） |
| `RELAY_SSH_KEY` | 中转机私钥绝对路径 |
| `EXIT_HOST` | 出口机 IPv4（中转机经它登录出口机） |
| `EXIT_SSH_PORT` | 出口机 SSH 端口 |
| `EXIT_SSH_USER` | 出口机 SSH 用户（必须是 root） |
| `EXIT_SSH_KEY` | 出口机私钥绝对路径 |
| `EXPECTED_EXIT_IPV4` | 期望的出口公网 IPv4 |
| `REALITY_SERVER_NAME` | Reality 伪装域名（ASCII FQDN） |
| `RELAY_COHOSTS_SINGBOX` | 中转机上的既有 sing-box：`yes`（233boy 安装）/ `ownexit-direct`（ownexit 直连）/ `no`（没有） |
| `EXIT_SOURCE_FILTER` | 出口机 Reality 端口如何只放行中转：`managed`（本项目加 nft 白名单）/ `provider`（服务商安全组负责）/ `none` |

配置必须且只能包含这 13 个键；1.x 内新增的键必须是可选的（缺省时行为与之前相同）。

### 链 state.env 键（参考）

`state.env` 由 ownexit 写入并带内嵌校验和，外部程序不要直接读取或修改。冻结的是 `SCHEMA_VERSION=1` 的语义与“1.y 能读 1.x 写下的 state”的承诺；下面的键表只供参考，由检查脚本防止它被静默改变。

| 键 |
| ---- |
| `SCHEMA_VERSION` |
| `STATUS` |
| `CHAIN_ID` |
| `DEPLOYMENT_ID` |
| `CONFIG_SHA256` |
| `RELAY_HOST` |
| `RELAY_SSH_PORT` |
| `RELAY_SSH_USER` |
| `RELAY_HOSTKEY_FINGERPRINT` |
| `RELAY_SSH_KEY_PATH` |
| `RELAY_SSH_KEY_FINGERPRINT` |
| `EXIT_HOST` |
| `EXIT_SSH_PORT` |
| `EXIT_SSH_USER` |
| `EXIT_HOSTKEY_FINGERPRINT` |
| `EXIT_SSH_KEY_PATH` |
| `EXIT_SSH_KEY_FINGERPRINT` |
| `EXPECTED_EXIT_IPV4` |
| `REALITY_SERVER_NAME` |
| `RELAY_COHOSTS_SINGBOX` |
| `RELAY_PORT` |
| `EXIT_REALITY_PORT` |
| `SING_BOX_VERSION` |
| `LINUX_ARCHIVE_SHA256` |
| `LINUX_BINARY_SHA256` |
| `DARWIN_ARCHIVE_SHA256` |
| `DARWIN_BINARY_SHA256` |
| `VLESS_UUID` |
| `REALITY_PUBLIC_KEY` |
| `REALITY_SHORT_ID` |
| `RELAY_OWNER_SHA256` |
| `RELAY_SOCKET_SHA256` |
| `RELAY_SERVICE_SHA256` |
| `RELAY_ENABLE_LINK_TARGET` |
| `RELAY_ENABLE_LINK_SHA256` |
| `EXIT_OWNER_SHA256` |
| `EXIT_EXIT_SHA256` |
| `EXIT_SERVICE_SHA256` |
| `EXIT_ENABLE_LINK_TARGET` |
| `EXIT_ENABLE_LINK_SHA256` |
| `RELAY_BASELINE_CONFIG_MANIFEST_SHA256` |
| `RELAY_BASELINE_LISTEN_SHA256` |
| `RELAY_BASELINE_BINARY_MANIFEST_SHA256` |
| `RELAY_BASELINE_UNIT_MANIFEST_SHA256` |
| `RELAY_BASELINE_SERVICE_ACTIVE` |
| `RELAY_BASELINE_SERVICE_ENABLED` |
| `NODE_SHA256` |
| `CREATED_AT` |
| `PAYLOAD_SHA256` |

## 直连（服务器）

| 路径 | 内容 |
| ---- | ---- |
| `/etc/ownexit-direct/config.json` | sing-box 服务端配置（root 600，含私钥）；users 每项 `{ "name": …, "uuid": …, "flow": … }`，第一项是 default |
| `/etc/ownexit-direct/client.env` | 公开的客户端参数（root 600，无私钥），键见下表“直连 client.env 键”；本机每次从这里读回参数渲染订阅 |
| `/etc/ownexit-direct/devices.env` | 额外设备表，每行 `名字=UUID`（不含 default）；没有额外设备时不存在 |
| `/etc/systemd/system/ownexit-direct.service` | 代理服务 |
| `ownexit-subscription-ttl.timer` / `.service` | 订阅服务自动关闭的瞬时单元（`systemd-run` 创建、不落盘），只在用了 `--sub-ttl` / `subctl start --ttl` 时存在，到时 `systemctl stop ownexit-subscription`；VPS 重启后消失 |
| `/etc/systemd/system/ownexit-subscription.service` | 订阅服务（`python3 /opt/ownexit-subscription/subserver.py`，以 nobody 运行；1.3.0 之前是 `python3 -m http.server`，重跑一次 `ownexit direct` 即切换） |
| `/opt/ownexit-subscription/` | 订阅目录：每个 TOKEN 一个子目录（文件见“订阅文件”）、订阅服务脚本 `subserver.py`、一个空 `index.html`（1.3.0 起服务脚本只响应白名单路径，根目录与其它路径一律 404；index.html 保留但不再承担防目录列表） |
| `/var/backups/ownexit-direct/233boy-<时间>.tar.gz` | `--migrate` 前的 233boy 备份（含旧私钥，任何操作都不会删除） |

订阅地址：`http://<VPS 地址>:<SUB_PORT>/<TOKEN>/<文件名>`。default 设备用 `state.env` 的 TOKEN，额外设备各用自己的 TOKEN。1.3.0 起另有自适应地址 `http://<VPS 地址>:<SUB_PORT>/<TOKEN>/sub`（不是文件）：User-Agent 含 clash / mihomo / stash / verge 返回 `clash.yaml`，含 sing-box / singbox 或以 sfa/、sfi/、sfm/ 开头返回 `sing-box.json`，其余返回 `shadowrocket.txt`。其它路径一律 404。

内部（不属于公开接口）：`/opt/ownexit-direct/bin/` 下的二进制布局、`/var/lib/ownexit-direct/` 下的操作工作目录。

### 直连 client.env 键

| 键 | 含义 |
| ---- | ---- |
| `PORT` | 代理端口 |
| `UUID` | default 设备的 UUID |
| `PUBLIC_KEY` | Reality 公钥 |
| `SHORT_ID` | Reality short id（迁移来的节点可能为空） |
| `SNI` | Reality 伪装域名 |
| `FLOW` | VLESS flow（通常为 xtls-rprx-vision，可能为空） |
| `LISTEN` | 服务端监听地址 |
| `SOURCE` | 参数来源：fresh（新装）/ migrated（从 233boy 迁移） |

### 订阅文件

| 文件 | 给谁用 |
| ---- | ---- |
| `clash.yaml` | Clash Verge / mihomo / Clash Meta for Android：完整可加载配置，组名 `PROXY` |
| `shadowrocket.txt` | Shadowrocket、v2rayN / v2rayNG：base64 编码的 vless 链接列表 |
| `sing-box.json` | sing-box 官方客户端（1.12 及以上）：完整配置 |
| `node.txt` | 明文单行 vless URI |

文件名、节点名、组名与“可被对应客户端导入”冻结；文件里的其余字段可以兼容演进。

## 链式（服务器）

| 机器 | 路径 / 名称 | 内容 |
| ---- | ---- | ---- |
| 中转机、出口机 | `/etc/ownexit-chain/<id>.owner.env` | 本链的归属记录 |
| 出口机 | `/etc/ownexit-chain/<id>.exit.json` | sing-box 服务端配置（root 600，含私钥）；users 一行，每项 `{ "name": …, "uuid": …, "flow": "xtls-rprx-vision" }`，第一项是 default（v0.6.0 及更早部署的唯一一项没有 name） |
| 出口机 | `ownexit-chain-exit-<id>.service` | 出口服务 |
| 出口机 | nft 表 `inet ownexit_<id 中的 - 换成 _>` | `EXIT_SOURCE_FILTER=managed` 时随出口服务起停的白名单 |
| 中转机 | `ownexit-chain-relay-<id>.socket` / `ownexit-chain-relay-<id>.service` | systemd-socket-proxyd 透传 |
| 中转机 | `<上述 unit>.d/50-ownexit-chain-blacklist.conf` | 黑名单 drop-in（`IPAddressDeny=`） |

内部（不属于公开接口）：`/opt/ownexit-chain/bin/` 下的二进制布局、`/etc/ownexit-chain/` 下以 `<id>.rotate.` 开头的辅助文件与 `.stage-*` 暂存目录。

## 节点名与组名

| 名称 | 来源 |
| ---- | ---- |
| `ownexit-direct` | 直连 default 设备 |
| `ownexit-direct-<名字>` | 直连额外设备 |
| `Exit-via-Relay-<id>` | 链式 default 设备 |
| `Exit-via-Relay-<id>_<名字>` | 链式额外设备 |
| `PROXY` | 直连 clash.yaml 的选择组 |
| `Exit-Relay-auto` | `ownexit multi render` 的自动组 |
