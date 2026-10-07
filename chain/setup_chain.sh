#!/usr/bin/env bash
# 出口机 + 中转主机独立链路的部署、验证、状态查询与回滚入口。
# 前置：
#   - 控制端：macOS（Apple 芯片 / Intel，系统 /bin/bash 3.2 即可）或 Linux（amd64 / arm64，含 WSL）。
#   - 两台 Linux 主机（同为 amd64 或同为 arm64）均已配置 root 免密 SSH，ed25519 host key 已进入 known_hosts（init 会配好）。
#   - 出口机安全组已允许中转主机访问；配置文件权限为 600，git clone 使用时还须位于仓库工作区外（pip 安装时没有工作区，不检查）。
#   - 两台远端的依赖、防火墙与既有 sing-box 状态须通过 preflight；脚本不会自动安装软件包或改防火墙。
#   - 连接治理命令（conns/kick/ban/unban/banlist）要求链已 deploy；kick 依赖中转内核支持 ss -K，
#     ban 依赖中转 cgroup v2 + systemd IPAddressDeny=（BPF），二者实测于 Debian 12 / systemd 252。
#   - rebaseline 要求链已 deploy；只允许配置里 RELAY_COHOSTS_SINGBOX 一键与 state 不同（由它自己改写）。
#   - rehost-exit 要求链已 deploy、config 已改好新 EXIT_HOST / EXPECTED_EXIT_IPV4、known_hosts 已有新 IP 的
#     ed25519 条目，且新 IP 与 state 的主机指纹一致（同一台出口机）。
#   - migrate-exit 要求链已 deploy 且健康、旧出口机仍可经中转登录；新出口机由本命令配免密（非终端时需要
#     OWNEXIT_SSH_PASSWORD），且与中转同架构、没有本链的文件。
#   - up = init + deploy + 二维码，一条命令从零到可用，可重跑；本机只有一条链时所有子命令都可以省略 --id。
#   - deploy / up 以及直连部署前会自检本机到服务器的路由是否经代理 TUN：经 TUN 默认拒绝（退出 3），--allow-tun 放行。
# 调用方：由维护者在本仓库或任意目录直接执行；不应被 source。

set -euo pipefail

umask 077
export LC_ALL=C

# shellcheck disable=SC2034  # 只写不读的历史变量；迁移不改动事务代码，保留原样
readonly SCRIPT_VERSION='1'
readonly SING_BOX_VERSION='1.13.14'
# 4 个官方包的归档与解压后 binary 的 SHA256，均已与 GitHub 发布页公布的摘要核对。
# 远端 binary 的期望哈希直接取这里的常量，所以远端可以自己下载，本机不必再准备 Linux 包。
readonly ARCHIVE_SHA256_LINUX_AMD64='f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697'
readonly BINARY_SHA256_LINUX_AMD64='68aeab83cc4ab2659a5b92232261a20746ccdafc3b3d1e19b2d63247eec3bbf7'
readonly ARCHIVE_SHA256_LINUX_ARM64='4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e'
readonly BINARY_SHA256_LINUX_ARM64='85f570b96754cd7c354d28e50f66e9340b374e06b5d77ec9e15e8d04f0c87a25'
readonly ARCHIVE_SHA256_DARWIN_AMD64='5245d645e847f90bb708da74bc020ae078c28489690756419685c04f56b4e3bb'
readonly BINARY_SHA256_DARWIN_AMD64='9e550c4cc3bdb8a6f3525bbaaf97624f517d1e37e0d5c76a439988483a5b27a6'
readonly ARCHIVE_SHA256_DARWIN_ARM64='73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab'
readonly BINARY_SHA256_DARWIN_ARM64='813d8effd02a19572a8d75aef29fc073101404ca535b2496be86f21827c7684d'
# 状态 / 事务记录的字段名沿用 v0.1.0（不升级格式，已部署的链可直接读取），但语义按平台而定：
#   LINUX_*  = 两台远端共用架构（amd64 或 arm64，两端必须一致）的官方包；
#   DARWIN_* = 本机做出口 smoke 用的官方包（任意本机平台）；本机拿不到包时两个哈希记为 NONE。
# 默认值对应 v0.1.0 唯一支持的组合，真正的取值由 select_remote_arch / select_local_platform 决定。
REMOTE_ARCH='amd64'
LINUX_ARCHIVE='sing-box-1.13.14-linux-amd64.tar.gz'
LINUX_ARCHIVE_SHA256="${ARCHIVE_SHA256_LINUX_AMD64}"
LOCAL_PLATFORM=''
DARWIN_ARCHIVE='sing-box-1.13.14-darwin-arm64.tar.gz'
DARWIN_ARCHIVE_SHA256="${ARCHIVE_SHA256_DARWIN_ARM64}"
# 仅供测试回退上传路径（设计文档 V4）：把下载地址指向不存在的位置，正常使用不要设置。
RELEASE_BASE_URL="${OWNEXIT_TEST_RELEASE_BASE_URL:-https://github.com/SagerNet/sing-box/releases/download/v1.13.14}"
readonly RELEASE_BASE_URL
readonly REMOTE_BASE='/opt/ownexit-chain'
readonly REMOTE_BIN='/opt/ownexit-chain/bin/sing-box-1.13.14'
readonly REMOTE_CONFIG_DIR='/etc/ownexit-chain'
# 持锁后每个 SSH / scp 的控制端总超时（秒）。OWNEXIT_TEST_CHAIN_SSH_TIMEOUT 只供测试“超时不重试”时调小，正常使用不要设置。
MANAGED_CHILD_TIMEOUT_SECONDS=600
if [[ "${OWNEXIT_TEST_CHAIN_SSH_TIMEOUT:-}" =~ ^[1-9][0-9]*$ ]]; then
  MANAGED_CHILD_TIMEOUT_SECONDS="${OWNEXIT_TEST_CHAIN_SSH_TIMEOUT}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT=''

COMMAND='bootstrap'
CONFIG_PATH=''
# 远端架构是否已由状态文件锁定；锁定后现场架构必须一致（probe_remote_platform_preflight）。
REMOTE_ARCH_LOCKED=0
# 出口机 nft 的绝对路径，由远端预检取得；EXIT_SOURCE_FILTER=managed 时写进出口机 unit。
EXIT_NFT_PATH=''
# init 子命令的输入；只在 COMMAND=init 时使用。
INIT_RELAY=''
INIT_EXIT=''
INIT_ID='main'
INIT_RELAY_PORT='22'
INIT_EXIT_PORT='22'
INIT_SNI='www.amazon.com'
INIT_EXIT_SOURCE_FILTER='managed'
WITH_FAIL_CLOSED=0
# 只读命令（status、不带 --with-fail-closed 的 verify、conns、banlist）置 1：SSH 连接层失败时重试
# （docs/feature/feature-doctor-ipcheck.md §5.1.4）。修改类命令保持 0，重放部分执行的修改没有幂等证据。
READONLY_SSH_RETRY=0
# 最近一次 run_managed_external 是否因控制端总超时被终止（超时同样返回 255，但不应重试）。
MANAGED_LAST_TIMEOUT=0
# kick/ban/unban 的目标；ban/unban 经 normalize_ip_entry 规范化为 a.b.c.d/N 后才落黑名单。
TARGET_IP=''
BLACKLIST_FILE=''
# migrate-exit 是否显式给了 --to-port（只用于参数互斥校验）。
MIGRATE_TO_PORT_GIVEN=0
# 部署前 TUN 自检：到服务器的路由经代理 TUN 时默认拒绝；--allow-tun 置 1 后只 WARN 继续。
ALLOW_TUN=0
# qr 子命令要显示的设备名；空 = default（client/node.txt）。
QR_DEVICE=''
# up 子命令进行中：init_chain 不打印“next=deploy”提示并在配免密前做 TUN 自检，deploy_chain 不再重复自检。
UP_MODE=0
# init / up 的参数是否显式给出：up 对已有配置只比较显式给出的项，未给的以配置为准（否则只敲 chain up 就会被判“地址不同”）。
INIT_RELAY_GIVEN=0
INIT_EXIT_GIVEN=0
INIT_RELAY_PORT_GIVEN=0
INIT_EXIT_PORT_GIVEN=0
INIT_SNI_GIVEN=0
INIT_FILTER_GIVEN=0
INIT_ID_GIVEN=0
# 中转受管 drop-in 文件名；verify/rollback 只放行这一个文件，其余 drop-in 一律判 drifted。
readonly RELAY_BLACKLIST_DROPIN='50-ownexit-chain-blacklist.conf'
CONFIG_SHA256=''
# 进程启动时的配置摘要：临时目录 owner 与之绑定；rebaseline 会在进程中途改变 CONFIG_SHA256，清理时必须用这个值比对。
OPERATION_CONFIG_SHA256=''
CHAIN_ID=''
RELAY_HOST=''
RELAY_SSH_PORT=''
RELAY_SSH_USER=''
RELAY_SSH_KEY=''
EXIT_HOST=''
EXIT_SSH_PORT=''
EXIT_SSH_USER=''
EXIT_SSH_KEY=''
EXPECTED_EXIT_IPV4=''
REALITY_SERVER_NAME=''
RELAY_COHOSTS_SINGBOX=''
# 出口机 Reality 端口如何限定只允许中转来源：
#   managed：本项目在出口机加一张只放行中转源地址的 nft 表（随 exit service 起停，见 write_prepare_exit_script），硬门槛；
#   provider：服务商在机器外的安全组 / 控制台白名单负责，硬门槛；
#   none：不限制，本机能连上只记 WARN（没有凭据仍无法使用）。
# preflight 要求出口机除 ownexit_* 白名单表外没有任何防火墙规则，所以不要为通过检查去手工加别的规则。
EXIT_SOURCE_FILTER=''

CONFIG_HOME=''
STATE_HOME=''
CACHE_HOME=''
CHAIN_CONFIG_DIR=''
CHAIN_STATE_DIR=''
CHAIN_CACHE_DIR=''
STATE_FILE=''
JOURNAL_FILE=''
CHAIN_LOCK=''
GLOBAL_LOCK=''
ACTIVE_CHILD_FILE=''
LOCAL_PROCESS_FILE=''
OP_TMP=''
SSH_CONFIG=''
SSH_DIRECT_CONFIG=''
OPERATION_ID=''
LOCK_OPERATION_ID=''
DEPLOYMENT_ID=''
LOCK_CHAIN_HELD=0
LOCK_GLOBAL_HELD=0
WATCHDOG_ARMED=0
WATCHDOG_UNIT=''
CLEANUP_RUNNING=0
# shellcheck disable=SC2034  # 只写不读的历史变量；迁移不改动事务代码，保留原样
DISPATCH_SIGNAL=''
STARTED_AT=0

LINUX_ARCHIVE_PATH=''
DARWIN_ARCHIVE_PATH=''
DARWIN_BINARY_PATH=''
LINUX_BINARY_SHA256=''
DARWIN_BINARY_SHA256=''
RELAY_HOSTKEY_FINGERPRINT=''
EXIT_HOSTKEY_FINGERPRINT=''
RELAY_SSH_KEY_FINGERPRINT=''
EXIT_SSH_KEY_FINGERPRINT=''
SOCKET_PROXYD_PATH=''
SYSTEMCTL_PATH=''

TEMP_PID=''
TEMP_PID_CONFIG=''
TEMP_PID_START=''
# shellcheck disable=SC2034  # 只写不读的历史变量；迁移不改动事务代码，保留原样
ACTIVE_CHILD_PID='' ACTIVE_CHILD_START=''
ACTIVE_CHILD_GATE=''
ACTIVE_CHILD_REGISTRY_SAFE=1
LOCAL_PROCESS_GATE=''
STATE_PROBE_REASON=''

usage() {
  cat <<EOF
用法:
  $(basename "${SCRIPT_PATH}") init [--relay <ipv4>] [--exit <ipv4>] [--id <名字>] [--relay-port <n>] [--exit-port <n>] [--sni <域名>]
                    [--exit-source-filter managed|provider|none]
  $(basename "${SCRIPT_PATH}") up [--relay <ipv4>] [--exit <ipv4>] [--id <名字>] [init 的其它参数] [--allow-tun]
  $(basename "${SCRIPT_PATH}") --id <名字> <子命令>          # 等价于 --config ~/.config/ownexit/chains/<名字>.env
  $(basename "${SCRIPT_PATH}") <子命令> [参数]              # 本机只有一条链时可以省略 --id
  $(basename "${SCRIPT_PATH}") --config <绝对路径> preflight
  $(basename "${SCRIPT_PATH}") --config <绝对路径> deploy [--allow-tun]
  $(basename "${SCRIPT_PATH}") --config <绝对路径> qr [--device <名字>]
  $(basename "${SCRIPT_PATH}") --config <绝对路径> verify
  $(basename "${SCRIPT_PATH}") --config <绝对路径> verify --with-fail-closed
  $(basename "${SCRIPT_PATH}") --config <绝对路径> status
  $(basename "${SCRIPT_PATH}") --config <绝对路径> rollback
  $(basename "${SCRIPT_PATH}") --config <绝对路径> conns
  $(basename "${SCRIPT_PATH}") --config <绝对路径> kick <ipv4>
  $(basename "${SCRIPT_PATH}") --config <绝对路径> ban <ipv4|ipv4/prefix>
  $(basename "${SCRIPT_PATH}") --config <绝对路径> unban <ipv4|ipv4/prefix>
  $(basename "${SCRIPT_PATH}") --config <绝对路径> banlist
  $(basename "${SCRIPT_PATH}") --config <绝对路径> rehost-exit
  $(basename "${SCRIPT_PATH}") --config <绝对路径> rebaseline
  $(basename "${SCRIPT_PATH}") --config <绝对路径> rotate-keys
  $(basename "${SCRIPT_PATH}") --config <绝对路径> add-device <名字>
  $(basename "${SCRIPT_PATH}") --config <绝对路径> remove-device <名字>
  $(basename "${SCRIPT_PATH}") --config <绝对路径> list-devices
  $(basename "${SCRIPT_PATH}") --config <绝对路径> migrate-exit --to <ipv4> [--to-port <n>]
  $(basename "${SCRIPT_PATH}") --config <绝对路径> migrate-exit --abort
  $(basename "${SCRIPT_PATH}") --config <绝对路径> migrate-exit --abandon-cleanup
  $(basename "${SCRIPT_PATH}") -h | --help

作用（按常用程度分组）:
 常用
  up         一条命令从零到可用：没有配置就先 init（配免密、探测出口 IP），然后 deploy，最后打印节点二维码与下一步。
             可重跑：已有配置且地址一致时直接继续 / 核验；不带 IP 且本机只有一条链时复用它。
  status     返回 healthy/not_deployed/busy/stale_lock/incomplete/unreachable/orphaned/drifted。
  verify     按 state 核验资源、既有服务基线和三层真实代理出口。
  qr         显示 default 节点的二维码（--device <名字> 显示某台设备的）；只读本机节点文件，不连服务器。
 日常
  add-device   新增一台设备（独立 UUID），节点文件在 <状态目录>/devices/node-<名字>.txt；其它设备不受影响。
               设备名 [a-z0-9][a-z0-9-]{0,31}，default 保留，每条链最多 32 台（含 default）。
  remove-device 吊销一台设备，它立即连不上；其它设备不受影响。两者中途失败都可重跑同一条命令收敛。
  list-devices 只读列出出口机上的设备与本机节点文件路径。
  conns      只读列出中转端口上各来源 IP 的连接数、空闲秒数、是否在黑名单，以及 proxyd fd 用量。
  kick       用 ss -K 销毁指定来源 IP 在中转端口上的全部已建连接（客户端会自动重连）。
  ban        把 IP/网段加入持久黑名单：本地 blacklist.txt + 中转受管 drop-in（IPAddressDeny=），
             daemon-reload 后立即生效并顺带 kick；重复 ban 幂等。
  unban      从黑名单移除；列表为空时删除中转 drop-in，恢复"无 drop-in"契约。
  banlist    只读对照本地黑名单与中转两个 unit 的 IPAddressDeny 回读值，不一致返回 5。
 维护
  rotate-keys  在出口机上重新生成全部设备的 UUID 与 Reality 密钥 / short id，重启出口机 sing-box，更新节点文件
               与 state，最后自动完整 verify；中转、端口、部署 ID 不变。所有客户端都要重新导入
               （多链聚合需重新 render）。中途失败直接重跑同一条命令收敛。
  rehost-exit  出口机同机换 IP：先在 config 改 EXIT_HOST / EXPECTED_EXIT_IPV4，再原地迁移
             中转转发目标与两端 owner、本地 state，最后自动完整 verify。要求新 IP 的主机指纹与 state
             一致（同一台机）；UUID、密钥、端口、客户端订阅都不变；中途失败可重跑，已迁移时输出 noop。
  migrate-exit 把出口机迁到另一台机器：给新机器配免密（第一次问一次 root 密码），沿用原配置（UUID、密钥、
               全部设备）在新机器上起服务，中转转发目标切过去，提交 state 后自动清理旧出口机上本链的服务与文件，
               最后完整 verify。客户端不用重新导入。旧出口机必须还能登录（私钥只在它上面）。中途失败重跑同一条
               命令收敛；中转切换前可用 --abort 放弃；旧机器永久失联时用 --abandon-cleanup 放弃清理。
               多条链共用同一台出口机时逐条迁移，全部迁完后重新 multi render。
  rebaseline   中转机上的既有 sing-box 合法变化后（233boy 迁移为 ownexit-direct、直连改参数 / 新装 / 卸载），
               按现场重新判定 RELAY_COHOSTS_SINGBOX 并重新登记基线；凭据、端口、node.txt 不变
  rollback   先全量预校验，再按中转 -> 出口机顺序事务拆除专属资源。
 高级 / 分步
  init       只问两个 IP：给中转机和出口机配免密（第一次各问一次 root 密码），探测出口 IP 与中转现状，
             生成 ~/.config/ownexit/chains/<名字>.env（默认名字 main）。不修改远端，已存在同名配置时拒绝。
  preflight  只读核验本机、两台远端、官方资产、出口与碰撞条件。
  deploy     持锁重跑全部 gate，按出口机出口 -> 中转入口顺序事务部署。
参数:
  --config <路径>       仓库外 600 regular file，格式见 chain.example.env（init 会自动生成）。
  --id <名字>           --config 的简写，与 --config 二选一。
  init 的参数：--relay / --exit 两台机器的 IPv4（不给则交互提问）；--id 配置名，默认 main；
                --relay-port / --exit-port SSH 端口，默认 22；--sni Reality 伪装域名，默认 www.amazon.com；
                --exit-source-filter 出口机 Reality 端口如何只放行中转：managed（默认，本项目加 nft 白名单）、
                provider（服务商安全组负责）、none（不限制）；managed / provider 时部署严格检查。
  --with-fail-closed    仅可跟在 verify 后；会短暂停止本 chain 并验证新连接失败。
  --allow-tun           deploy / up：本机到服务器的路由经代理 TUN 时默认拒绝（退出 3，部署途中 SSH 会被切断），
                        加它只警告继续。已按 docs/manual/clash-direct-ips.md 让这些 IP 走物理网卡时不需要。
  --device <名字>       qr：显示该设备的节点二维码；不带时显示 default。
  --to <ipv4>           migrate-exit 的新出口机地址；--to-port 新出口机 SSH 端口，默认 22。
  --abort               migrate-exit 在中转切换之前放弃迁移：拆掉新机器上的半成品，恢复原配置。
  --abandon-cleanup     migrate-exit 提交后旧出口机永久失联时放弃清理（本链配置含私钥会留在旧机器上）。
  <ipv4>                kick 只接受点分 IPv4；ban/unban 另接受 CIDR，且主机位必须为 0（如 198.51.100.0/24）。
  -h, --help            显示本帮助并返回 0，不读取配置、不连接远端。

前置:
  控制端 macOS 或 Linux（含 WSL），Bash 3.2+；两端 Linux 同为 amd64 或 arm64；root 免密 SSH；known_hosts 中已有 ed25519 host key（init 会配好这两项）；
  出口机的安全组允许中转来源（provider 时还必须拒绝其它来源）；出口机除 ownexit_* 白名单表外没有防火墙规则；远端防火墙为空且所需命令已安装。
  连接治理命令要求链已 deploy 且无 incomplete transaction；kick 依赖中转内核 ss -K，
  ban 依赖中转 cgroup v2 + systemd IPAddressDeny=（cgroup BPF，非防火墙）。

典型用法:
  $(basename "${SCRIPT_PATH}") up --relay 203.0.113.10 --exit 203.0.113.20      # 一步到位
  $(basename "${SCRIPT_PATH}") status                                             # 只有一条链时不用 --id
  $(basename "${SCRIPT_PATH}") qr --device phone
  $(basename "${SCRIPT_PATH}") init --relay 203.0.113.10 --exit 203.0.113.20     # 分步：先生成配置
  $(basename "${SCRIPT_PATH}") --id main deploy
  $(basename "${SCRIPT_PATH}") --id main status
  $(basename "${SCRIPT_PATH}") --id main rollback
  # 手工写配置（进阶）：
  cp chain.example.env ~/.config/ownexit/chains/demo.env
  chmod 600 ~/.config/ownexit/chains/demo.env
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" preflight
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" deploy
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" verify --with-fail-closed
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" rollback
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" conns
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" kick 203.0.113.7
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" ban 203.0.113.7
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" ban 198.51.100.0/24
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" unban 203.0.113.7
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" banlist
  $(basename "${SCRIPT_PATH}") --config "${HOME}/.config/ownexit/chains/demo.env" rehost-exit
  $(basename "${SCRIPT_PATH}") --id main migrate-exit --to 203.0.113.30
  $(basename "${SCRIPT_PATH}") --id main migrate-exit --to 203.0.113.30 --to-port 2222
  $(basename "${SCRIPT_PATH}") --id main migrate-exit --abort

安全边界:
  脚本不修改防火墙、云厂商安全组、现有 sing-box 配置。
  黑名单只落在中转两个专属 unit 的受管 drop-in（50-ownexit-chain-blacklist.conf），
  rollback 会一并删除；verify/status 只放行这一个 drop-in，其余 drop-in 仍判 drifted。
  确定性专属路径发生碰撞即拒绝；共享目录和固定 binary 只在完全一致时复用。
EOF
}

log_info() {
  printf '[chain][%s] INFO %s\n' "${COMMAND}" "$*" >&2
}

log_warn() {
  printf '[chain][%s] WARN %s\n' "${COMMAND}" "$*" >&2
}

die() {
  local code
  code="$1"
  shift
  if [[ "${code}" != 2 ]]; then
    case "${COMMAND}" in
      preflight) code=3 ;;
      deploy|up)
        case "${code}" in 3|4) ;; *) code=4 ;; esac
        ;;
      verify|status) code=5 ;;
      rollback) code=6 ;;
    esac
  fi
  printf '[chain][%s] ERROR %s\n' "${COMMAND}" "$*" >&2
  exit "${code}"
}

now_rfc3339() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

elapsed_seconds() {
  local now
  now="$(date '+%s')"
  printf '%s\n' "$((now - STARTED_AT))"
}

random_hex_128() {
  openssl rand -hex 16
}

# 远端架构 → LINUX_* 三个值。amd64 / arm64 以外的取值直接失败，调用方据此拒绝部署。
select_remote_arch() {
  case "$1" in
    amd64) LINUX_ARCHIVE_SHA256="${ARCHIVE_SHA256_LINUX_AMD64}"; LINUX_BINARY_SHA256="${BINARY_SHA256_LINUX_AMD64}" ;;
    arm64) LINUX_ARCHIVE_SHA256="${ARCHIVE_SHA256_LINUX_ARM64}"; LINUX_BINARY_SHA256="${BINARY_SHA256_LINUX_ARM64}" ;;
    *) return 1 ;;
  esac
  REMOTE_ARCH="$1"
  LINUX_ARCHIVE="sing-box-${SING_BOX_VERSION}-linux-$1.tar.gz"
}

# 本机平台（darwin-arm64 / darwin-amd64 / linux-amd64 / linux-arm64），其它平台输出空串：没有对应官方包，本机 smoke 跳过。
local_platform() {
  local os arch
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) return 0 ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) return 0 ;; esac
  printf '%s-%s\n' "${os}" "${arch}"
}

# 本机平台 → DARWIN_ARCHIVE / DARWIN_ARCHIVE_SHA256（变量名沿用 v0.1.0，见文件头说明）。
select_local_platform() {
  LOCAL_PLATFORM="$(local_platform)"
  case "${LOCAL_PLATFORM}" in
    darwin-arm64) DARWIN_ARCHIVE_SHA256="${ARCHIVE_SHA256_DARWIN_ARM64}" ;;
    darwin-amd64) DARWIN_ARCHIVE_SHA256="${ARCHIVE_SHA256_DARWIN_AMD64}" ;;
    linux-amd64) DARWIN_ARCHIVE_SHA256="${ARCHIVE_SHA256_LINUX_AMD64}" ;;
    linux-arm64) DARWIN_ARCHIVE_SHA256="${ARCHIVE_SHA256_LINUX_ARM64}" ;;
    *) DARWIN_ARCHIVE_SHA256='NONE'; return 0 ;;
  esac
  DARWIN_ARCHIVE="sing-box-${SING_BOX_VERSION}-${LOCAL_PLATFORM}.tar.gz"
}

# 归档哈希 → 本机平台名；用于从状态文件反推部署时的本机平台。未知哈希返回 1。
platform_of_archive_sha256() {
  case "$1" in
    "${ARCHIVE_SHA256_DARWIN_ARM64}") printf 'darwin-arm64\n' ;;
    "${ARCHIVE_SHA256_DARWIN_AMD64}") printf 'darwin-amd64\n' ;;
    "${ARCHIVE_SHA256_LINUX_AMD64}") printf 'linux-amd64\n' ;;
    "${ARCHIVE_SHA256_LINUX_ARM64}") printf 'linux-arm64\n' ;;
    *) return 1 ;;
  esac
}

# 平台名 → 解压后 binary 的期望哈希。
binary_sha256_of_platform() {
  case "$1" in
    darwin-arm64) printf '%s\n' "${BINARY_SHA256_DARWIN_ARM64}" ;;
    darwin-amd64) printf '%s\n' "${BINARY_SHA256_DARWIN_AMD64}" ;;
    linux-amd64) printf '%s\n' "${BINARY_SHA256_LINUX_AMD64}" ;;
    linux-arm64) printf '%s\n' "${BINARY_SHA256_LINUX_ARM64}" ;;
    *) return 1 ;;
  esac
}

# 本机到某个 IP 的出接口名。macOS 用 route，Linux 用 ip route；取不到输出空串。
route_interface() {
  if [[ "$(uname -s)" == Darwin ]]; then
    route -n get "$1" 2>/dev/null | awk '/interface:/{print $2; exit}'
  else
    ip route get "$1" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
  fi
}

# 出接口是否是代理软件的 TUN 设备。走 TUN 时本机发出的连接会被代理接管，本机侧的验证不再代表真实网络。
interface_is_tunnel() {
  case "$1" in utun*|tun*|wg*) return 0 ;; esac
  [[ "$(uname -s)" == Linux && -e "/sys/class/net/$1/tun_flags" ]]
}

# 限时 TCP 连通性探测：能建立连接返回 0。macOS 的 nc 用 -G 控制连接超时，Linux 各发行版 nc 行为不一，改用 bash 的 /dev/tcp。
tcp_probe() {
  local host port seconds
  host="$1"
  port="$2"
  seconds="$3"
  if [[ "$(uname -s)" == Darwin ]]; then
    nc -4 -n -z -G "${seconds}" "${host}" "${port}" >/dev/null 2>&1
  else
    timeout "${seconds}" bash -c 'exec 3<>"/dev/tcp/$0/$1"' "${host}" "${port}" >/dev/null 2>&1
  fi
}

sha256_file() {
  local file
  file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    openssl dgst -sha256 "${file}" | awk '{print $NF}'
  fi
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

stat_uid() {
  if [[ "$(uname -s)" == 'Darwin' ]]; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

stat_mode() {
  if [[ "$(uname -s)" == 'Darwin' ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

stat_inode() {
  if [[ "$(uname -s)" == 'Darwin' ]]; then
    stat -f '%d:%i' "$1"
  else
    stat -c '%d:%i' "$1"
  fi
}

stat_size() {
  if [[ "$(uname -s)" == 'Darwin' ]]; then
    stat -f '%z' "$1"
  else
    stat -c '%s' "$1"
  fi
}

resolve_regular_path() {
  local input dir base
  input="$1"
  [[ "${input}" == /* ]] || return 1
  [[ ! -L "${input}" && -f "${input}" ]] || return 1
  dir="$(cd "$(dirname "${input}")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "${input}")"
  printf '%s/%s\n' "${dir}" "${base}"
}

require_secure_user_file() {
  local file exact_mode uid mode
  file="$1"
  exact_mode="$2"
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  uid="$(stat_uid "${file}")" || return 1
  mode="$(stat_mode "${file}")" || return 1
  [[ "${uid}" == "$(id -u)" && "${mode}" == "${exact_mode}" ]]
}

require_private_key_file() {
  local file uid mode
  file="$1"
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  uid="$(stat_uid "${file}")" || return 1
  mode="$(stat_mode "${file}")" || return 1
  [[ "${uid}" == "$(id -u)" ]] || return 1
  (( (8#${mode} & 8#077) == 0 ))
}

# 本地持久目录逐级创建；已有父级只允许 root/当前用户拥有且不可被 group/other 写。
# 不能用 mkdir -p 后再 chmod，因为预置 symlink 会让 chmod 落到攻击者选择的目标。
private_path_ancestors_safe() {
  local current uid mode
  current="$1"
  [[ "${current}" == /* ]] || return 1
  while :; do
    [[ -d "${current}" && ! -L "${current}" ]] || return 1
    uid="$(stat_uid "${current}")" || return 1
    mode="$(stat_mode "${current}")" || return 1
    [[ "${uid}" == 0 || "${uid}" == "$(id -u)" ]] || return 1
    (( (8#${mode} & 8#022) == 0 )) || return 1
    [[ "${current}" == / ]] && break
    current="$(dirname "${current}")"
  done
}

ensure_private_dir() {
  local target current missing uid mode path
  target="$1"
  [[ "${target}" == /* ]] || return 1
  if [[ -e "${target}" || -L "${target}" ]]; then
    [[ -d "${target}" && ! -L "${target}" ]] || return 1
    [[ "$(stat_uid "${target}")" == "$(id -u)" && "$(stat_mode "${target}")" == 700 ]] || return 1
    private_path_ancestors_safe "${target}"
    return
  fi
  missing=''
  current="${target}"
  while [[ ! -e "${current}" && ! -L "${current}" ]]; do
    if [[ -z "${missing}" ]]; then
      missing="${current}"
    else
      missing="${current}
${missing}"
    fi
    current="$(dirname "${current}")"
  done
  while :; do
    [[ -d "${current}" && ! -L "${current}" ]] || return 1
    uid="$(stat_uid "${current}")" || return 1
    mode="$(stat_mode "${current}")" || return 1
    [[ "${uid}" == 0 || "${uid}" == "$(id -u)" ]] || return 1
    (( (8#${mode} & 8#022) == 0 )) || return 1
    [[ "${current}" == / ]] && break
    current="$(dirname "${current}")"
  done
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if ! mkdir "${path}" 2>/dev/null; then
      [[ -d "${path}" && ! -L "${path}" && "$(stat_uid "${path}")" == "$(id -u)" && "$(stat_mode "${path}")" == 700 ]] || return 1
    fi
  done <<EOF
${missing}
EOF
  [[ -d "${target}" && ! -L "${target}" && "$(stat_uid "${target}")" == "$(id -u)" && "$(stat_mode "${target}")" == 700 ]] || return 1
  private_path_ancestors_safe "${target}"
}

private_dir_is_safe() {
  [[ -d "$1" && ! -L "$1" && "$(stat_uid "$1")" == "$(id -u)" && "$(stat_mode "$1")" == 700 ]] || return 1
  private_path_ancestors_safe "$1"
}

xdg_or_default() {
  local value fallback
  value="$1"
  fallback="$2"
  if [[ -n "${value}" && "${value}" == /* ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${fallback}"
  fi
}

parse_init_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --relay) [[ "$#" -ge 2 ]] || die 2 '--relay 需要 IPv4'; INIT_RELAY="$2"; INIT_RELAY_GIVEN=1; shift 2 ;;
      --exit) [[ "$#" -ge 2 ]] || die 2 '--exit 需要 IPv4'; INIT_EXIT="$2"; INIT_EXIT_GIVEN=1; shift 2 ;;
      --id) [[ "$#" -ge 2 ]] || die 2 '--id 需要名字'; INIT_ID="$2"; INIT_ID_GIVEN=1; shift 2 ;;
      --relay-port)
        [[ "$#" -ge 2 && "$2" =~ ^[1-9][0-9]{0,4}$ ]] && (( $2 <= 65535 )) || die 2 '--relay-port 必须是 1-65535'
        INIT_RELAY_PORT="$2"; INIT_RELAY_PORT_GIVEN=1; shift 2 ;;
      --exit-port)
        [[ "$#" -ge 2 && "$2" =~ ^[1-9][0-9]{0,4}$ ]] && (( $2 <= 65535 )) || die 2 '--exit-port 必须是 1-65535'
        INIT_EXIT_PORT="$2"; INIT_EXIT_PORT_GIVEN=1; shift 2 ;;
      --exit-source-filter)
        [[ "$#" -ge 2 && ( "$2" == managed || "$2" == provider || "$2" == none ) ]] || die 2 '--exit-source-filter 只能是 managed、provider 或 none'
        INIT_EXIT_SOURCE_FILTER="$2"; INIT_FILTER_GIVEN=1; shift 2 ;;
      --sni)
        [[ "$#" -ge 2 && "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || die 2 '--sni 必须是 ASCII 域名'
        INIT_SNI="$2"; INIT_SNI_GIVEN=1; shift 2 ;;
      # init 收到 --allow-tun 只置位、没有效果（init 不做 TUN 自检）；up 用它放行部署前自检。
      --allow-tun) ALLOW_TUN=1; shift ;;
      -h|--help)
        # init --help 按 1.x 已冻结的描述仍退出 2；up 是新命令，打印帮助退出 0。
        [[ "${COMMAND}" == up ]] || die 2 "${COMMAND} 不认识的参数：$1"
        usage
        exit 0 ;;
      *) die 2 "${COMMAND} 不认识的参数：$1" ;;
    esac
  done
}

# parse_args 主 case 之外唯一的子命令词表（不含 init / up，它们在配置解析之前分派）。
# scripts/check_interface.sh 会比对这里的词与 parse_args 主 case 的分支词一致；加子命令时两处都要改。
is_chain_subcommand() {
  case "${1:-}" in
    preflight|deploy|status|rollback|conns|banlist|rehost-exit|rebaseline|rotate-keys|list-devices|add-device|remove-device|verify|migrate-exit|kick|ban|unban|qr) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  if [[ "$#" -eq 1 && ( "$1" == '-h' || "$1" == '--help' ) ]]; then
    usage
    exit 0
  fi
  if [[ "${1:-}" == init || "${1:-}" == up ]]; then
    COMMAND="$1"
    shift
    parse_init_args "$@"
    return 0
  fi
  if is_chain_subcommand "${1:-}"; then
    # 省略 --id：本机只有一条链时自动选用它（0 条 / 多条都退出 2，提示下一步）。
    local rc
    if resolve_single_chain_config; then rc=0; else rc="$?"; fi
    case "${rc}" in
      0) ;;
      10) die 2 '本机没有链配置；先运行 chain up --relay <IP> --exit <IP>（或 chain init）' ;;
      *) die 2 '本机有多条链，请用 --id <名字> 指定' ;;
    esac
    COMMAND="$1"
    shift 1
  else
    [[ "$#" -ge 3 ]] || {
      usage >&2
      die 2 '参数不足；请用 --help 查看完整用法'
    }
    case "$1" in
      --config)
        [[ -n "$2" ]] || die 2 '--config 需要绝对路径'
        CONFIG_PATH="$2"
        ;;
      --id)
        # --id 只是 --config <XDG 配置目录>/ownexit/chains/<id>.env 的简写，之后走完全相同的配置校验。
        [[ "$2" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die 2 '--id 只允许 [a-z0-9][a-z0-9-]{0,31}'
        CONFIG_PATH="$(xdg_or_default "${XDG_CONFIG_HOME:-}" "${HOME}/.config")/ownexit/chains/$2.env"
        ;;
      *) die 2 '首个参数必须是 init、up、--config、--id 或子命令名' ;;
    esac
    [[ "$3" != --config && "$3" != --id ]] || die 2 '--config 与 --id 只能二选一'
    COMMAND="$3"
    shift 3
  fi
  case "${COMMAND}" in
    preflight|status|rollback|conns|banlist|rehost-exit|rebaseline|rotate-keys|list-devices)
      [[ "$#" -eq 0 ]] || die 2 "${COMMAND} 不接受额外参数"
      ;;
    deploy)
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --allow-tun) ALLOW_TUN=1; shift ;;
          *) die 2 'deploy 只接受可选的 --allow-tun' ;;
        esac
      done
      ;;
    qr)
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --device)
            [[ "$#" -ge 2 && "$2" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die 2 '--device 需要设备名 [a-z0-9][a-z0-9-]{0,31}'
            [[ "$2" != default ]] || die 2 'default 就是不带 --device 时显示的节点'
            QR_DEVICE="$2"; shift 2 ;;
          *) die 2 'qr 只接受可选的 --device <名字>' ;;
        esac
      done
      ;;
    add-device|remove-device)
      [[ "$#" -eq 1 ]] || die 2 "${COMMAND} 需要且只需要一个设备名"
      [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die 2 '设备名只允许 [a-z0-9][a-z0-9-]{0,31}'
      [[ "$1" != default ]] || die 2 'default 指部署时的那套凭据，不能新增或吊销；要整体换凭据用 rotate-keys'
      DEVICE_NAME="$1"
      ;;
    verify)
      if [[ "$#" -eq 1 && "$1" == '--with-fail-closed' ]]; then
        WITH_FAIL_CLOSED=1
      elif [[ "$#" -ne 0 ]]; then
        die 2 'verify 只接受可选的 --with-fail-closed'
      fi
      ;;
    migrate-exit)
      # 三种用法互斥：--to <IPv4> [--to-port N]（开始或重跑）、--abort、--abandon-cleanup。
      MIGRATE_TO_PORT=22
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --to) [[ "$#" -ge 2 && -z "${MIGRATE_MODE}" ]] || die 2 '--to 需要 IPv4，且不能与 --abort / --abandon-cleanup 同用'; MIGRATE_MODE=run; MIGRATE_TO="$2"; shift 2 ;;
          --to-port)
            [[ "$#" -ge 2 && "$2" =~ ^[1-9][0-9]{0,4}$ ]] && (( $2 <= 65535 )) || die 2 '--to-port 必须是 1-65535'
            MIGRATE_TO_PORT="$2"; MIGRATE_TO_PORT_GIVEN=1; shift 2 ;;
          --abort) [[ -z "${MIGRATE_MODE}" ]] || die 2 '--abort 不能与 --to / --abandon-cleanup 同用'; MIGRATE_MODE=abort; shift ;;
          --abandon-cleanup) [[ -z "${MIGRATE_MODE}" ]] || die 2 '--abandon-cleanup 不能与 --to / --abort 同用'; MIGRATE_MODE=abandon; shift ;;
          *) die 2 "migrate-exit 不认识的参数：$1" ;;
        esac
      done
      [[ -n "${MIGRATE_MODE}" ]] || die 2 'migrate-exit 需要 --to <IPv4>（或 --abort / --abandon-cleanup）'
      [[ "${MIGRATE_MODE}" == run || "${MIGRATE_TO_PORT_GIVEN}" == 0 ]] || die 2 '--to-port 只能与 --to 同用'
      ;;
    kick|ban|unban)
      # 目标 IP 在这里只做形态校验；规范化（补 /32、主机位清零校验）在 normalize_ip_entry 内完成。
      [[ "$#" -eq 1 && -n "$1" ]] || die 2 "${COMMAND} 需要且只需要一个 IPv4 参数"
      TARGET_IP="$1"
      ;;
    *)
      die 2 "未知命令：${COMMAND}"
      ;;
  esac
}

set_config_value() {
  local key value
  key="$1"
  value="$2"
  case "${key}" in
    CHAIN_ID) CHAIN_ID="${value}" ;;
    RELAY_HOST) RELAY_HOST="${value}" ;;
    RELAY_SSH_PORT) RELAY_SSH_PORT="${value}" ;;
    RELAY_SSH_USER) RELAY_SSH_USER="${value}" ;;
    RELAY_SSH_KEY) RELAY_SSH_KEY="${value}" ;;
    EXIT_HOST) EXIT_HOST="${value}" ;;
    EXIT_SSH_PORT) EXIT_SSH_PORT="${value}" ;;
    EXIT_SSH_USER) EXIT_SSH_USER="${value}" ;;
    EXIT_SSH_KEY) EXIT_SSH_KEY="${value}" ;;
    EXPECTED_EXIT_IPV4) EXPECTED_EXIT_IPV4="${value}" ;;
    REALITY_SERVER_NAME) REALITY_SERVER_NAME="${value}" ;;
    RELAY_COHOSTS_SINGBOX) RELAY_COHOSTS_SINGBOX="${value}" ;;
    EXIT_SOURCE_FILTER) EXIT_SOURCE_FILTER="${value}" ;;
    *) return 1 ;;
  esac
}

is_ipv4() {
  local value oldifs a b c d extra octet
  value="$1"
  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  oldifs="${IFS}"
  IFS=.
  read -r a b c d extra <<EOF
${value}
EOF
  IFS="${oldifs}"
  [[ -z "${extra:-}" ]] || return 1
  for octet in "${a}" "${b}" "${c}" "${d}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
    [[ "${octet}" == 0 || "${octet}" != 0* ]] || return 1
    (( 10#${octet} <= 255 )) || return 1
  done
}

validate_config_values() {
  [[ "${CHAIN_ID}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die 2 'CHAIN_ID 格式错误'
  is_ipv4 "${RELAY_HOST}" || die 2 'RELAY_HOST 必须是 IPv4 字面量'
  is_ipv4 "${EXIT_HOST}" || die 2 'EXIT_HOST 必须是 IPv4 字面量'
  [[ "${RELAY_HOST}" != "${EXIT_HOST}" ]] || die 2 '中转与出口机必须是两台不同 IPv4 主机'
  is_ipv4 "${EXPECTED_EXIT_IPV4}" || die 2 'EXPECTED_EXIT_IPV4 必须是 IPv4 字面量'
  [[ "${RELAY_SSH_PORT}" =~ ^[1-9][0-9]*$ && "${#RELAY_SSH_PORT}" -le 5 ]] && (( RELAY_SSH_PORT >= 1 && RELAY_SSH_PORT <= 65535 )) || die 2 'RELAY_SSH_PORT 范围错误'
  [[ "${EXIT_SSH_PORT}" =~ ^[1-9][0-9]*$ && "${#EXIT_SSH_PORT}" -le 5 ]] && (( EXIT_SSH_PORT >= 1 && EXIT_SSH_PORT <= 65535 )) || die 2 'EXIT_SSH_PORT 范围错误'
  [[ "${RELAY_SSH_USER}" == 'root' && "${EXIT_SSH_USER}" == 'root' ]] || die 2 '两端 SSH 用户必须固定为 root'
  [[ "${RELAY_SSH_KEY}" =~ ^/[A-Za-z0-9._/@+,=:~-]+$ ]] || die 2 'RELAY_SSH_KEY 不是允许字符集内的绝对路径'
  [[ "${EXIT_SSH_KEY}" =~ ^/[A-Za-z0-9._/@+,=:~-]+$ ]] || die 2 'EXIT_SSH_KEY 不是允许字符集内的绝对路径'
  require_private_key_file "${RELAY_SSH_KEY}" || die 2 'RELAY_SSH_KEY 必须是当前用户拥有、非 symlink 且 group/other 无权限的 regular file'
  require_private_key_file "${EXIT_SSH_KEY}" || die 2 'EXIT_SSH_KEY 必须是当前用户拥有、非 symlink 且 group/other 无权限的 regular file'
  RELAY_SSH_KEY_FINGERPRINT="$(fingerprint_private_key "${RELAY_SSH_KEY}")" || die 2 '无法读取 RELAY_SSH_KEY 公钥指纹'
  EXIT_SSH_KEY_FINGERPRINT="$(fingerprint_private_key "${EXIT_SSH_KEY}")" || die 2 '无法读取 EXIT_SSH_KEY 公钥指纹'
  [[ "${RELAY_SSH_KEY_FINGERPRINT}" == SHA256:* && "${EXIT_SSH_KEY_FINGERPRINT}" == SHA256:* ]] || die 2 'SSH 私钥指纹格式错误'
  [[ "${RELAY_SSH_KEY_FINGERPRINT}" != "${EXIT_SSH_KEY_FINGERPRINT}" ]] || die 2 '中转与出口机必须使用两把不同公钥指纹的私钥'
  [[ "${REALITY_SERVER_NAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || die 2 'REALITY_SERVER_NAME 必须是 ASCII FQDN'
  [[ "${RELAY_COHOSTS_SINGBOX}" == 'yes' || "${RELAY_COHOSTS_SINGBOX}" == 'no' || "${RELAY_COHOSTS_SINGBOX}" == 'ownexit-direct' ]] || die 2 'RELAY_COHOSTS_SINGBOX 只能是 yes、no 或 ownexit-direct'
  [[ "${EXIT_SOURCE_FILTER}" == 'managed' || "${EXIT_SOURCE_FILTER}" == 'provider' || "${EXIT_SOURCE_FILTER}" == 'none' ]] || die 2 'EXIT_SOURCE_FILTER 只能是 managed、provider 或 none'
}

normalized_config() {
  printf 'CHAIN_ID=%s\n' "${CHAIN_ID}"
  printf 'RELAY_HOST=%s\n' "${RELAY_HOST}"
  printf 'RELAY_SSH_PORT=%s\n' "${RELAY_SSH_PORT}"
  printf 'RELAY_SSH_USER=%s\n' "${RELAY_SSH_USER}"
  printf 'RELAY_SSH_KEY=%s\n' "${RELAY_SSH_KEY}"
  printf 'EXIT_HOST=%s\n' "${EXIT_HOST}"
  printf 'EXIT_SSH_PORT=%s\n' "${EXIT_SSH_PORT}"
  printf 'EXIT_SSH_USER=%s\n' "${EXIT_SSH_USER}"
  printf 'EXIT_SSH_KEY=%s\n' "${EXIT_SSH_KEY}"
  printf 'EXPECTED_EXIT_IPV4=%s\n' "${EXPECTED_EXIT_IPV4}"
  printf 'REALITY_SERVER_NAME=%s\n' "${REALITY_SERVER_NAME}"
  printf 'RELAY_COHOSTS_SINGBOX=%s\n' "${RELAY_COHOSTS_SINGBOX}"
  printf 'EXIT_SOURCE_FILTER=%s\n' "${EXIT_SOURCE_FILTER}"
}

parse_config() {
  local resolved line key value seen count
  resolved="$(resolve_regular_path "${CONFIG_PATH}")" || die 2 '配置必须是可解析的绝对 regular file，且不能是 symlink'
  CONFIG_PATH="${resolved}"
  require_secure_user_file "${CONFIG_PATH}" 600 || die 2 '配置必须由当前用户拥有且 mode 精确为 600'
  if [[ -n "${REPO_ROOT}" ]]; then
    case "${CONFIG_PATH}" in
      "${REPO_ROOT}"|"${REPO_ROOT}"/*) die 2 '真实配置必须位于 Git worktree 外' ;;
    esac
  fi
  seen=''
  count=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" != *$'\r'* ]] || die 2 '配置含 CR 控制字符'
    case "${line}" in
      '') continue ;;
      \#*) continue ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        [[ "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]] || die 2 '配置键格式错误'
        [[ -n "${value}" ]] || die 2 "配置值不能为空：${key}"
        if printf '%s' "${value}" | grep -q '[[:cntrl:][:space:]]'; then
          die 2 "配置值包含空白或控制字符：${key}"
        fi
        case "
${seen}
" in
          *"
${key}
"*) die 2 "配置键重复：${key}" ;;
        esac
        set_config_value "${key}" "${value}" || die 2 "未知配置键：${key}"
        seen="${seen}
${key}"
        count="$((count + 1))"
        ;;
      *) die 2 '配置只允许空行、井号注释和 KEY=VALUE' ;;
    esac
  done < "${CONFIG_PATH}"
  [[ "${count}" -eq 13 ]] || die 2 '配置必须且只能包含 chain.example.env 的 13 个键'
  validate_config_values
  CONFIG_SHA256="$(normalized_config | sha256_text)"
}

init_paths() {
  CONFIG_HOME="$(xdg_or_default "${XDG_CONFIG_HOME:-}" "${HOME}/.config")"
  STATE_HOME="$(xdg_or_default "${XDG_STATE_HOME:-}" "${HOME}/.local/state")"
  CACHE_HOME="$(xdg_or_default "${XDG_CACHE_HOME:-}" "${HOME}/.cache")"
  CHAIN_CONFIG_DIR="${CONFIG_HOME}/ownexit/chains"
  CHAIN_STATE_DIR="${STATE_HOME}/ownexit/chains/${CHAIN_ID}"
  CHAIN_CACHE_DIR="${CACHE_HOME}/ownexit/chains/${CHAIN_ID}/downloads"
  STATE_FILE="${CHAIN_STATE_DIR}/state.env"
  JOURNAL_FILE="${CHAIN_STATE_DIR}/transaction.env"
  CHAIN_LOCK="${CHAIN_STATE_DIR}/operation.lock"
  GLOBAL_LOCK="${STATE_HOME}/ownexit/shared.lock"
  ACTIVE_CHILD_FILE="${CHAIN_STATE_DIR}/active-child.env"
  LOCAL_PROCESS_FILE="${CHAIN_STATE_DIR}/local-process.env"
  # 黑名单权威副本；中转 drop-in 只是它的渲染结果，verify 以它为准核远端 IPAddressDeny 回读值。
  BLACKLIST_FILE="${CHAIN_STATE_DIR}/blacklist.txt"
}

init_operation_tmp() {
  local owner owner_temp start start_hash command_hash
  cleanup_stale_operation_tmp_dirs || return 1
  start="$(process_start_token "$$")"
  command_hash="$(process_command_hash "$$")"
  [[ -n "${start}" && "${command_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  start_hash="$(printf '%s' "${start}" | sha256_text)"
  OP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ownexit-chain.${CHAIN_ID}.${LOCK_OPERATION_ID}.$$.${start_hash}.${command_hash}.XXXXXX")"
  chmod 700 "${OP_TMP}"
  owner="${OP_TMP}/operation-owner.env"
  owner_temp="${OP_TMP}/.operation-owner.${LOCK_OPERATION_ID}.tmp"
  ( set -o noclobber; : > "${owner_temp}" ) 2>/dev/null || return 1
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'CHAIN_ID=%s\n' "${CHAIN_ID}"
    printf 'OPERATION_ID=%s\n' "${OPERATION_ID}"
    printf 'PID=%s\n' "$$"
    printf 'PROCESS_START=%s\n' "${start}"
    printf 'PROCESS_COMMAND_SHA256=%s\n' "${command_hash}"
    printf 'CONFIG_SHA256=%s\n' "${CONFIG_SHA256}"
  } > "${owner_temp}"
  OPERATION_CONFIG_SHA256="${CONFIG_SHA256}"
  chmod 600 "${owner_temp}"
  sync
  link "${owner_temp}" "${owner}" || return 1
  rm -f "${owner_temp}"
  SSH_CONFIG="${OP_TMP}/ssh_config"
  SSH_DIRECT_CONFIG="${OP_TMP}/ssh_direct_config"
}

kv_get() {
  local file key
  file="$1"
  key="$2"
  awk -F= -v wanted="${key}" '$1 == wanted { sub(/^[^=]*=/, ""); print; found=1 } END { if (!found) exit 1 }' "${file}"
}

process_start_token() {
  local pid
  pid="$1"
  ps -p "${pid}" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]][[:space:]]*/_/g'
}

process_command_hash() {
  local pid command_line
  pid="$1"
  command_line="$(ps -p "${pid}" -o command= 2>/dev/null)" || return 1
  [[ -n "${command_line}" ]] || return 1
  printf '%s' "${command_line}" | sha256_text
}

process_is_running_identity() {
  local pid expected_start current_start state
  pid="$1"
  expected_start="$2"
  current_start="$(process_start_token "${pid}" || true)"
  [[ -n "${expected_start}" && "${current_start}" == "${expected_start}" ]] || return 1
  state="$(ps -p "${pid}" -o stat= 2>/dev/null | sed 's/^[[:space:]]*//')"
  [[ -n "${state}" && "${state}" != Z* ]]
}

child_is_live() {
  local file expected_operation pid expected_start expected_command current_command kind op_tmp ssh_config_path command_line
  file="$1"
  expected_operation="$2"
  require_secure_user_file "${file}" 600 || return 1
  [[ "$(awk -F= '{print $1}' "${file}")" == "$(printf '%s\n' SCHEMA_VERSION OPERATION_ID PID PROCESS_START PROCESS_COMMAND_SHA256 KIND SSH_CONFIG_PATH OP_TMP_PATH)" ]] || return 1
  [[ "$(kv_get "${file}" SCHEMA_VERSION)" == 1 && "$(kv_get "${file}" OPERATION_ID)" == "${expected_operation}" ]] || return 1
  [[ "$(kv_get "${file}" KIND)" == ssh || "$(kv_get "${file}" KIND)" == scp ]] || return 1
  pid="$(kv_get "${file}" PID)"
  expected_start="$(kv_get "${file}" PROCESS_START)"
  expected_command="$(kv_get "${file}" PROCESS_COMMAND_SHA256)"
  kind="$(kv_get "${file}" KIND)"
  ssh_config_path="$(kv_get "${file}" SSH_CONFIG_PATH)"
  op_tmp="$(kv_get "${file}" OP_TMP_PATH)"
  [[ "${pid}" =~ ^[1-9][0-9]*$ && -n "${expected_start}" && "${expected_command}" =~ ^[0-9a-f]{64}$ && "${op_tmp}" == /* ]] || return 1
  [[ "${ssh_config_path}" == "${op_tmp}/ssh_config" || "${ssh_config_path}" == "${op_tmp}/ssh_direct_config" ]] || return 1
  process_is_running_identity "${pid}" "${expected_start}" || return 1
  current_command="$(process_command_hash "${pid}" 2>/dev/null || true)"
  [[ "${current_command}" == "${expected_command}" ]] && return 0
  command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
  case "${command_line}" in
    *"${kind}"*"-F ${ssh_config_path}"*) return 0 ;;
    *) return 1 ;;
  esac
}

active_child_metadata_matches() {
  local file expected_operation expected_pid
  file="$1"
  expected_operation="$2"
  expected_pid="${3:-}"
  require_secure_user_file "${file}" 600 || return 1
  [[ "$(awk -F= '{print $1}' "${file}")" == "$(printf '%s\n' SCHEMA_VERSION OPERATION_ID PID PROCESS_START PROCESS_COMMAND_SHA256 KIND SSH_CONFIG_PATH OP_TMP_PATH)" ]] || return 1
  [[ "$(kv_get "${file}" SCHEMA_VERSION)" == 1 && "$(kv_get "${file}" OPERATION_ID)" == "${expected_operation}" ]] || return 1
  [[ "$(kv_get "${file}" PID)" =~ ^[1-9][0-9]*$ && -n "$(kv_get "${file}" PROCESS_START)" ]] || return 1
  [[ "$(kv_get "${file}" PROCESS_COMMAND_SHA256)" =~ ^[0-9a-f]{64}$ && "$(kv_get "${file}" OP_TMP_PATH)" == /* ]] || return 1
  case "$(kv_get "${file}" SSH_CONFIG_PATH)" in
    "$(kv_get "${file}" OP_TMP_PATH)"/ssh_config|"$(kv_get "${file}" OP_TMP_PATH)"/ssh_direct_config) ;;
    *) return 1 ;;
  esac
  [[ "$(kv_get "${file}" KIND)" == ssh || "$(kv_get "${file}" KIND)" == scp ]] || return 1
  [[ -z "${expected_pid}" || "$(kv_get "${file}" PID)" == "${expected_pid}" ]]
}

publish_active_child() {
  local pid kind ssh_config_path start command_hash temp
  pid="$1"
  kind="$2"
  ssh_config_path="$3"
  start="$(process_start_token "${pid}")"
  command_hash="$(process_command_hash "${pid}")"
  [[ -n "${start}" && "${command_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ ! -e "${ACTIVE_CHILD_FILE}" && ! -L "${ACTIVE_CHILD_FILE}" ]] || return 1
  temp="${CHAIN_STATE_DIR}/.active-child.${LOCK_OPERATION_ID}.tmp"
  ( set -o noclobber; : > "${temp}" ) 2>/dev/null || return 1
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'OPERATION_ID=%s\n' "${LOCK_OPERATION_ID}"
    printf 'PID=%s\n' "${pid}"
    printf 'PROCESS_START=%s\n' "${start}"
    printf 'PROCESS_COMMAND_SHA256=%s\n' "${command_hash}"
    printf 'KIND=%s\n' "${kind}"
    printf 'SSH_CONFIG_PATH=%s\n' "${ssh_config_path}"
    printf 'OP_TMP_PATH=%s\n' "${OP_TMP}"
  } > "${temp}" || return 1
  chmod 600 "${temp}" || return 1
  sync
  link "${temp}" "${ACTIVE_CHILD_FILE}" || return 1
  rm -f "${temp}" || return 1
  ACTIVE_CHILD_PID="${pid}"
  ACTIVE_CHILD_START="${start}"
}

clear_active_child() {
  local pid temp
  pid="$1"
  if [[ -e "${ACTIVE_CHILD_FILE}" || -L "${ACTIVE_CHILD_FILE}" ]]; then
    active_child_metadata_matches "${ACTIVE_CHILD_FILE}" "${LOCK_OPERATION_ID}" "${pid}" || return 1
    child_is_live "${ACTIVE_CHILD_FILE}" "${LOCK_OPERATION_ID}" && return 1
    rm -f "${ACTIVE_CHILD_FILE}"
  fi
  temp="${CHAIN_STATE_DIR}/.active-child.${LOCK_OPERATION_ID}.tmp"
  if [[ -e "${temp}" || -L "${temp}" ]]; then
    require_secure_user_file "${temp}" 600 || return 1
    rm -f "${temp}"
  fi
  # shellcheck disable=SC2034  # 只写不读的历史变量；迁移不改动事务代码，保留原样
  ACTIVE_CHILD_PID='' ACTIVE_CHILD_START=''
}

cleanup_stale_active_child() {
  local operation_id child_file temp parent
  operation_id="$1"
  child_file="$2"
  [[ "${operation_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "${child_file}" == "${STATE_HOME}/ownexit/chains/"*/active-child.env ]] || return 1
  parent="$(dirname "${child_file}")"
  private_dir_is_safe "${parent}" || return 1
  if [[ -e "${child_file}" || -L "${child_file}" ]]; then
    active_child_metadata_matches "${child_file}" "${operation_id}" || return 1
    # 精确命令身份仍匹配才是父进程遗留的真实 child；同秒 PID reuse 不得制造永久 busy。
    child_is_live "${child_file}" "${operation_id}" && return 1
    rm -f "${child_file}"
  fi
  temp="${parent}/.active-child.${operation_id}.tmp"
  if [[ -e "${temp}" || -L "${temp}" ]]; then
    require_secure_user_file "${temp}" 600 || return 1
    [[ "$(stat_size "${temp}")" -le 1024 ]] || return 1
    rm -f "${temp}"
  fi
}

cleanup_stale_local_process() {
  local operation_id process_file parent pid expected_start temp attempt identity_rc
  operation_id="$1"
  process_file="$2"
  [[ "${operation_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "${process_file}" == "${STATE_HOME}/ownexit/chains/"*/local-process.env ]] || return 1
  parent="$(dirname "${process_file}")"
  private_dir_is_safe "${parent}" || return 1
  if [[ -e "${process_file}" || -L "${process_file}" ]]; then
    local_process_metadata_matches "${process_file}" "${operation_id}" || return 1
    pid="$(kv_get "${process_file}" PID)"
    expected_start="$(kv_get "${process_file}" PROCESS_START)"
    if local_process_identity_status "${process_file}" "${operation_id}"; then
      identity_rc=0
    else
      identity_rc="$?"
    fi
    if [[ "${identity_rc}" -eq 0 ]]; then
      kill "${pid}" 2>/dev/null || true
      attempt=0
      while (( attempt < 50 )) && process_is_running_identity "${pid}" "${expected_start}"; do
        sleep 0.1
        attempt="$((attempt + 1))"
      done
      if process_is_running_identity "${pid}" "${expected_start}"; then
        kill -9 "${pid}" 2>/dev/null || true
        attempt=0
        while (( attempt < 50 )) && process_is_running_identity "${pid}" "${expected_start}"; do
          sleep 0.1
          attempt="$((attempt + 1))"
        done
      fi
      process_is_running_identity "${pid}" "${expected_start}" && return 1
    elif [[ "${identity_rc}" -ne 1 ]]; then
      return 1
    fi
    rm -f "${process_file}"
  fi
  temp="${parent}/.local-process.${operation_id}.tmp"
  if [[ -e "${temp}" || -L "${temp}" ]]; then
    require_secure_user_file "${temp}" 600 || return 1
    [[ "$(stat_size "${temp}")" -le 2048 ]] || return 1
    rm -f "${temp}"
  fi
}

operation_tmp_owner_matches() {
  local directory operation_id config_hash owner
  directory="$1"
  operation_id="$2"
  config_hash="$3"
  [[ -d "${directory}" && ! -L "${directory}" && "$(stat_uid "${directory}")" == "$(id -u)" && "$(stat_mode "${directory}")" == 700 ]] || return 1
  owner="${directory}/operation-owner.env"
  require_secure_user_file "${owner}" 600 || return 1
  [[ "$(awk -F= '{print $1}' "${owner}")" == "$(printf '%s\n' SCHEMA_VERSION CHAIN_ID OPERATION_ID PID PROCESS_START PROCESS_COMMAND_SHA256 CONFIG_SHA256)" ]] || return 1
  [[ "$(kv_get "${owner}" SCHEMA_VERSION)" == 1 ]] || return 1
  [[ "$(kv_get "${owner}" OPERATION_ID)" == "${operation_id}" && "$(kv_get "${owner}" CONFIG_SHA256)" == "${config_hash}" ]] || return 1
  [[ "$(kv_get "${owner}" CHAIN_ID)" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || return 1
  [[ "$(kv_get "${owner}" PROCESS_COMMAND_SHA256)" =~ ^[0-9a-f]{64}$ ]] || return 1
}

cleanup_stale_operation_tmp() {
  local operation_id config_hash directory owner chain_id base item
  operation_id="$1"
  config_hash="$2"
  directory="$3"
  [[ "${operation_id}" =~ ^[0-9a-f]{32}$ && "${config_hash}" =~ ^[0-9a-f]{64}$ && "${directory}" == /* ]] || return 1
  if [[ ! -e "${directory}" && ! -L "${directory}" ]]; then
    return 0
  fi
  operation_tmp_owner_matches "${directory}" "${operation_id}" "${config_hash}" || return 1
  owner="${directory}/operation-owner.env"
  chain_id="$(kv_get "${owner}" CHAIN_ID)"
  base="$(basename "${directory}")"
  [[ "${base}" == ownexit-chain."${chain_id}".* ]] || return 1
  find "${directory}" -depth -mindepth 1 ! -path "${owner}" -delete || return 1
  rm -f "${owner}"
  rmdir "${directory}"
}

incomplete_operation_tmp_creator_live() {
  local directory base prefix chain_id operation_id pid start_hash expected_command nonce extra current_start current_start_hash current_command
  directory="$1"
  base="$(basename "${directory}")"
  IFS=. read -r prefix chain_id operation_id pid start_hash expected_command nonce extra <<EOF
${base}
EOF
  [[ "${prefix}" == ownexit-chain && "${chain_id}" == "${CHAIN_ID}" && "${operation_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "${pid}" =~ ^[1-9][0-9]*$ && "${start_hash}" =~ ^[0-9a-f]{64}$ && "${expected_command}" =~ ^[0-9a-f]{64}$ && -n "${nonce}" && -z "${extra}" ]] || return 1
  current_start="$(process_start_token "${pid}" || true)"
  process_is_running_identity "${pid}" "${current_start}" || return 1
  current_start_hash="$(printf '%s' "${current_start}" | sha256_text)"
  current_command="$(process_command_hash "${pid}" 2>/dev/null || true)"
  [[ "${current_start_hash}" == "${start_hash}" && "${current_command}" == "${expected_command}" ]]
}

cleanup_incomplete_operation_tmp() {
  local directory item base
  directory="$1"
  incomplete_operation_tmp_creator_live "${directory}" && return 1
  [[ -d "${directory}" && ! -L "${directory}" && "$(stat_uid "${directory}")" == "$(id -u)" && "$(stat_mode "${directory}")" == 700 ]] || return 1
  [[ ! -e "${directory}/operation-owner.env" && ! -L "${directory}/operation-owner.env" ]] || return 1
  while IFS= read -r item; do
    base="$(basename "${item}")"
    [[ "${base}" =~ ^\.operation-owner\.[0-9a-f]{32}\.tmp$ ]] || return 1
    require_secure_user_file "${item}" 600 || return 1
    [[ "$(stat_size "${item}")" -le 2048 ]] || return 1
  done < <(find "${directory}" -mindepth 1 -maxdepth 1 -print)
  find "${directory}" -mindepth 1 -maxdepth 1 -type f -name '.operation-owner.*.tmp' -delete || return 1
  [[ -z "$(find "${directory}" -mindepth 1 -print -quit)" ]] || return 1
  rmdir "${directory}"
}

cleanup_stale_operation_tmp_dirs() {
  local directory owner operation_id config_hash pid expected_start expected_command current_start current_command
  if [[ -e "${CHAIN_LOCK}" || -L "${CHAIN_LOCK}" || -e "${GLOBAL_LOCK}" || -L "${GLOBAL_LOCK}" ]]; then
    return 0
  fi
  for directory in "${TMPDIR:-/tmp}"/ownexit-chain."${CHAIN_ID}".*; do
    [[ -e "${directory}" || -L "${directory}" ]] || continue
    [[ -d "${directory}" && ! -L "${directory}" && "$(stat_uid "${directory}")" == "$(id -u)" && "$(stat_mode "${directory}")" == 700 ]] || continue
    owner="${directory}/operation-owner.env"
    if ! require_secure_user_file "${owner}" 600; then
      cleanup_incomplete_operation_tmp "${directory}" || continue
      continue
    fi
    operation_id="$(kv_get "${owner}" OPERATION_ID 2>/dev/null || true)"
    config_hash="$(kv_get "${owner}" CONFIG_SHA256 2>/dev/null || true)"
    pid="$(kv_get "${owner}" PID 2>/dev/null || true)"
    expected_start="$(kv_get "${owner}" PROCESS_START 2>/dev/null || true)"
    expected_command="$(kv_get "${owner}" PROCESS_COMMAND_SHA256 2>/dev/null || true)"
    [[ "${operation_id}" =~ ^[0-9a-f]{32}$ && "${config_hash}" =~ ^[0-9a-f]{64}$ && "${pid}" =~ ^[1-9][0-9]*$ ]] || continue
    current_start="$(process_start_token "${pid}" || true)"
    current_command="$(process_command_hash "${pid}" 2>/dev/null || true)"
    if process_is_running_identity "${pid}" "${expected_start}" && [[ "${current_command}" == "${expected_command}" ]]; then
      continue
    fi
    cleanup_stale_operation_tmp "${operation_id}" "${config_hash}" "${directory}" || return 1
  done
}

watchdog_terminate_recorded_child() {
  local file operation_id pid expected_start
  file="$1"
  operation_id="$2"
  child_is_live "${file}" "${operation_id}" || return 0
  pid="$(kv_get "${file}" PID)"
  expected_start="$(kv_get "${file}" PROCESS_START)"
  # watchdog 与 SSH/scp 是兄弟进程；PID/start/命令身份已由 child_is_live 闭合后才可发信号。
  terminate_pid_with_start "${pid}" "${expected_start}"
}

run_managed_external() {
  local kind gate pid child_start rc token argument expect_config managed_config watchdog_fifo watchdog_pid watchdog_rc timeout_marker timeout_triggered
  kind="$1"
  shift
  MANAGED_LAST_TIMEOUT=0
  if [[ "${LOCK_CHAIN_HELD}" != 1 ]]; then
    "$@"
    return
  fi
  managed_config=''
  expect_config=0
  for argument in "$@"; do
    if [[ "${expect_config}" == 1 ]]; then
      managed_config="${argument}"
      expect_config=0
      continue
    fi
    [[ "${argument}" == -F ]] && expect_config=1
  done
  [[ "${managed_config}" == "${OP_TMP}/ssh_config" || "${managed_config}" == "${OP_TMP}/ssh_direct_config" ]] || return 1
  gate="${OP_TMP}/child-gate.${LOCK_OPERATION_ID}"
  [[ ! -e "${gate}" && ! -L "${gate}" ]] || return 1
  mkfifo -m 600 "${gate}" || return 1
  # 后台异步子 shell 在无 job control 时 stdin 会被 bash 默认重定向到 /dev/null，
  # 会吞掉调用方 `< script` 投递给远端 `bash -s` 的脚本。fork 前把调用方 stdin 存到 fd 3，
  # 子 shell 内以 `<&3` 显式接回给 exec 的 ssh/scp，父进程 fork 后立即关闭自己那份 fd 3。
  exec 3<&0
  (
    exec 9<>"${gate}"
    IFS= read -r -t 10 token <&9 || exit 124
    exec 9>&-
    [[ "${token}" == go ]] || exit 125
    exec "$@" <&3 3<&-
  ) &
  pid="$!"
  exec 3<&-
  child_start="$(process_start_token "${pid}")"
  ACTIVE_CHILD_GATE="${gate}"
  if [[ -z "${child_start}" ]]; then
    ACTIVE_CHILD_REGISTRY_SAFE=0
    return 1
  fi
  if ! publish_active_child "${pid}" "${kind}" "${managed_config}"; then
    terminate_pid_with_start "${pid}" "${child_start}" || true
    rm -f "${gate}"
    ACTIVE_CHILD_GATE=''
    if ! cleanup_stale_active_child "${LOCK_OPERATION_ID}" "${ACTIVE_CHILD_FILE}"; then
      ACTIVE_CHILD_REGISTRY_SAFE=0
    fi
    return 1
  fi
  watchdog_fifo="${OP_TMP}/child-watchdog.${LOCK_OPERATION_ID}"
  timeout_marker="${OP_TMP}/child-timeout.${LOCK_OPERATION_ID}"
  [[ ! -e "${timeout_marker}" && ! -L "${timeout_marker}" ]] || {
    terminate_active_child || ACTIVE_CHILD_REGISTRY_SAFE=0
    return 1
  }
  [[ ! -e "${watchdog_fifo}" && ! -L "${watchdog_fifo}" ]] || {
    terminate_active_child || ACTIVE_CHILD_REGISTRY_SAFE=0
    return 1
  }
  mkfifo -m 600 "${watchdog_fifo}" || {
    terminate_active_child || ACTIVE_CHILD_REGISTRY_SAFE=0
    return 1
  }
  if ! exec 8<>"${watchdog_fifo}"; then
    terminate_active_child || ACTIVE_CHILD_REGISTRY_SAFE=0
    rm -f "${watchdog_fifo}"
    return 1
  fi
  (
    set +e
    exec 7<>"${watchdog_fifo}"
    if IFS= read -r -t "${MANAGED_CHILD_TIMEOUT_SECONDS}" token <&7; then
      exit 0
    fi
    # marker 先于 kill 发布；父进程据此区分“远端命令自身退出 137/143”和“本地 watchdog 超时终止”。
    ( set -o noclobber; printf 'TIMEOUT\n' > "${timeout_marker}" ) 2>/dev/null || exit 126
    chmod 600 "${timeout_marker}" || exit 126
    watchdog_terminate_recorded_child "${ACTIVE_CHILD_FILE}" "${LOCK_OPERATION_ID}" || exit 126
    # 统一把受控命令超时映射成 SSH 的不可达返回码；不能把 watchdog 的 TERM/KILL 状态误判为 drift。
    exit 124
  ) &
  watchdog_pid="$!"
  if ! printf 'go\n' > "${gate}"; then
    printf 'cancel\n' >&8 || true
    exec 8>&-
    wait "${watchdog_pid}" 2>/dev/null || true
    rm -f "${watchdog_fifo}"
    terminate_active_child || ACTIVE_CHILD_REGISTRY_SAFE=0
    rm -f "${gate}"
    ACTIVE_CHILD_GATE=''
    return 1
  fi
  if wait "${pid}"; then
    rc=0
  else
    rc="$?"
  fi
  printf 'cancel\n' >&8 || true
  exec 8>&-
  if wait "${watchdog_pid}" 2>/dev/null; then
    watchdog_rc=0
  else
    watchdog_rc="$?"
  fi
  timeout_triggered=0
  if [[ -e "${timeout_marker}" || -L "${timeout_marker}" ]]; then
    if require_secure_user_file "${timeout_marker}" 600 && [[ "$(cat "${timeout_marker}" 2>/dev/null || true)" == TIMEOUT ]]; then
      timeout_triggered=1
      rm -f "${timeout_marker}" || return 1
    else
      ACTIVE_CHILD_REGISTRY_SAFE=0
      return 1
    fi
  fi
  rm -f "${watchdog_fifo}"
  rm -f "${gate}"
  ACTIVE_CHILD_GATE=''
  clear_active_child "${pid}" || return 1
  if [[ "${timeout_triggered}" == 1 ]]; then
    [[ "${watchdog_rc}" -eq 124 ]] || return 1
    MANAGED_LAST_TIMEOUT=1
    rc=255
  else
    [[ "${watchdog_rc}" -eq 0 ]] || return 1
  fi
  return "${rc}"
}

lock_is_live() {
  local file pid path expected_start current_start expected_command current_command child_file operation_id
  file="$1"
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  pid="$(kv_get "${file}" PID 2>/dev/null || true)"
  path="$(kv_get "${file}" SCRIPT_PATH 2>/dev/null || true)"
  expected_start="$(kv_get "${file}" PROCESS_START 2>/dev/null || true)"
  expected_command="$(kv_get "${file}" PROCESS_COMMAND_SHA256 2>/dev/null || true)"
  child_file="$(kv_get "${file}" CHILD_STATE_FILE 2>/dev/null || true)"
  operation_id="$(kv_get "${file}" OPERATION_ID 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ && -n "${path}" && -n "${expected_start}" && "${expected_command}" =~ ^[0-9a-f]{64}$ && "${operation_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  current_start="$(process_start_token "${pid}" || true)"
  current_command="$(process_command_hash "${pid}" 2>/dev/null || true)"
  if process_is_running_identity "${pid}" "${expected_start}" && [[ "${current_command}" == "${expected_command}" ]]; then
    return 0
  fi
  [[ "${child_file}" == /* ]] || return 1
  child_is_live "${child_file}" "${operation_id}"
}

cleanup_local_stage_owner_temp() {
  local operation_id owner_temp
  operation_id="$1"
  [[ "${operation_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  owner_temp="${CHAIN_STATE_DIR}/.stage-owner.${operation_id}.tmp"
  if [[ ! -e "${owner_temp}" && ! -L "${owner_temp}" ]]; then
    return 0
  fi
  [[ -f "${owner_temp}" && ! -L "${owner_temp}" ]] || return 1
  [[ "$(stat_uid "${owner_temp}")" == "$(id -u)" && "$(stat_mode "${owner_temp}")" == 600 ]] || return 1
  [[ "$(stat_size "${owner_temp}")" -le 1024 ]] || return 1
  rm -f "${owner_temp}"
}

cleanup_one_control_temp() {
  local temp final temp_hash
  temp="$1"
  final="$2"
  if [[ ! -e "${temp}" && ! -L "${temp}" ]]; then
    return 0
  fi
  require_secure_user_file "${temp}" 600 || return 1
  [[ "$(stat_size "${temp}")" -le 262144 ]] || return 1
  temp_hash="$(sha256_file "${temp}")" || return 1
  [[ "${temp_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  if [[ -n "${final}" && ( -e "${final}" || -L "${final}" ) ]]; then
    require_secure_user_file "${final}" 600 || return 1
    if [[ "$(stat_inode "${temp}")" == "$(stat_inode "${final}")" ]]; then
      [[ "${temp_hash}" == "$(sha256_file "${final}")" ]] || return 1
    fi
  fi
  rm -f "${temp}" || return 1
}

# 状态提交 temp 名绑定控制进程锁；退出或 stale-lock 回收时逐个核验后清除，避免秘密残留 hardlink。
cleanup_control_temps_by_lock_id() {
  local operation_id candidate audit_dir audit_leaf base final_name has_candidate
  operation_id="$1"
  [[ "${operation_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  cleanup_one_control_temp "${CHAIN_STATE_DIR}/.state.env.${operation_id}.tmp" "${STATE_FILE}" || return 1
  cleanup_one_control_temp "${CHAIN_STATE_DIR}/.transaction.env.${operation_id}.tmp" "${JOURNAL_FILE}" || return 1
  cleanup_local_stage_owner_temp "${operation_id}" || return 1
  audit_dir="${CHAIN_STATE_DIR}/audit"
  if [[ ! -e "${audit_dir}" && ! -L "${audit_dir}" ]]; then
    return 0
  fi
  private_dir_is_safe "${audit_dir}" || return 1
  for audit_leaf in "${audit_dir}"/deployed.*.* "${audit_dir}"/rolledback.*.*; do
    [[ -e "${audit_leaf}" || -L "${audit_leaf}" ]] || continue
    base="$(basename "${audit_leaf}")"
    has_candidate=0
    for final_name in COMPLETE transaction.env; do
      candidate="${audit_leaf}/.${final_name}.${operation_id}.tmp"
      [[ -e "${candidate}" || -L "${candidate}" ]] && has_candidate=1
    done
    [[ "${has_candidate}" == 1 ]] || continue
    private_dir_is_safe "${audit_leaf}" || return 1
    [[ "${base}" =~ ^(deployed|rolledback)\.[0-9a-f]{32}\.[0-9a-f]{32}$ ]] || return 1
    for final_name in COMPLETE transaction.env; do
      candidate="${audit_leaf}/.${final_name}.${operation_id}.tmp"
      cleanup_one_control_temp "${candidate}" "${audit_leaf}/${final_name}" || return 1
    done
  done
}

cleanup_cache_temps_by_lock_id() {
  local operation_id archive candidate
  operation_id="$1"
  [[ "${operation_id}" =~ ^[0-9a-f]{32}$ ]] || return 1
  if [[ ! -e "${CHAIN_CACHE_DIR}" && ! -L "${CHAIN_CACHE_DIR}" ]]; then
    return 0
  fi
  # deploy 从不向不安全 cache 目录写 temp；目录本身异常不应阻塞无关 rollback 的锁释放。
  private_dir_is_safe "${CHAIN_CACHE_DIR}" || return 0
  for archive in "${LINUX_ARCHIVE}" "${DARWIN_ARCHIVE}"; do
    candidate="${CHAIN_CACHE_DIR}/.${archive}.${operation_id}.tmp"
    if [[ -e "${candidate}" || -L "${candidate}" ]]; then
      require_secure_user_file "${candidate}" 600 || return 1
      sha256_file "${candidate}" >/dev/null || return 1
      rm -f "${candidate}"
    fi
  done
}

cleanup_stale_local_stage() {
  local stale_id stale_config stage owner item relative keys expected_keys
  stale_id="$1"
  stale_config="$2"
  [[ "${stale_id}" =~ ^[0-9a-f]{32}$ && "${stale_config}" =~ ^[0-9a-f]{64}$ ]] || return 1
  cleanup_control_temps_by_lock_id "${stale_id}" || return 1
  cleanup_cache_temps_by_lock_id "${stale_id}" || return 1
  stage="${CHAIN_STATE_DIR}/.stage-local-${stale_id}"
  if [[ ! -e "${stage}" && ! -L "${stage}" ]]; then
    return 0
  fi
  [[ -d "${stage}" && ! -L "${stage}" && "$(stat_uid "${stage}")" == "$(id -u)" && "$(stat_mode "${stage}")" == 700 ]] || return 1
  owner="${stage}/stage-owner.env"
  if [[ -e "${owner}" || -L "${owner}" ]]; then
    require_secure_user_file "${owner}" 600 || return 1
    keys="$(awk -F= '{print $1}' "${owner}")"
    expected_keys="$(printf '%s\n' SCHEMA_VERSION CHAIN_ID DEPLOYMENT_ID OPERATION_ID CONFIG_SHA256)"
    [[ "${keys}" == "${expected_keys}" ]] || return 1
    [[ "$(kv_get "${owner}" SCHEMA_VERSION)" == 1 ]] || return 1
    [[ "$(kv_get "${owner}" CHAIN_ID)" == "${CHAIN_ID}" ]] || return 1
    [[ "$(kv_get "${owner}" OPERATION_ID)" == "${stale_id}" ]] || return 1
    [[ "$(kv_get "${owner}" CONFIG_SHA256)" == "${stale_config}" ]] || return 1
    [[ "$(kv_get "${owner}" DEPLOYMENT_ID)" =~ ^[0-9a-f]{32}$ ]] || return 1
  else
    [[ -z "$(find "${stage}" -mindepth 1 -print -quit)" ]] || return 1
  fi
  while IFS= read -r item; do
    relative="${item#${stage}/}"
    case "${relative}" in
      stage-owner.env|baseline|baseline/relay-config-manifest.txt|baseline/relay-unit-manifest.txt|baseline/relay-binary-manifest.txt|baseline/relay-listeners.txt|client|client/node.txt) ;;
      *) return 1 ;;
    esac
  done < <(find "${stage}" -mindepth 1 -print)
  find "${stage}" -depth -mindepth 1 -delete
  rmdir "${stage}"
}

write_lock_temp() {
  local target temp start command_hash
  target="$1"
  temp="$2"
  start="$(process_start_token "$$")"
  [[ -n "${start}" ]] || return 1
  command_hash="$(process_command_hash "$$")"
  [[ "${command_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'OPERATION_ID=%s\n' "${LOCK_OPERATION_ID}"
    printf 'PID=%s\n' "$$"
    printf 'SCRIPT_PATH=%s\n' "${SCRIPT_PATH}"
    printf 'PROCESS_START=%s\n' "${start}"
    printf 'PROCESS_COMMAND_SHA256=%s\n' "${command_hash}"
    printf 'CHILD_STATE_FILE=%s\n' "${ACTIVE_CHILD_FILE}"
    printf 'LOCAL_PROCESS_STATE_FILE=%s\n' "${LOCAL_PROCESS_FILE}"
    printf 'OP_TMP_PATH=%s\n' "${OP_TMP}"
    printf 'CONFIG_SHA256=%s\n' "${CONFIG_SHA256}"
  } > "${temp}"
  chmod 600 "${temp}"
  [[ "$(stat_mode "${temp}")" == 600 ]]
  sync
}

acquire_lock_file() {
  local target kind mutating parent temp stale_id stale_config audit_dir archive stale_temp stale_child stale_local_process stale_op_tmp
  target="$1"
  kind="$2"
  mutating="$3"
  parent="$(dirname "${target}")"
  ensure_private_dir "${parent}" || return 12
  temp="${parent}/.lock.${LOCK_OPERATION_ID}.${kind}.tmp"
  ( set -o noclobber; : > "${temp}" ) 2>/dev/null || return 12
  write_lock_temp "${target}" "${temp}" || {
    rm -f "${temp}"
    return 12
  }
  if link "${temp}" "${target}" 2>/dev/null; then
    rm -f "${temp}"
    return 0
  fi
  rm -f "${temp}"
  if lock_is_live "${target}"; then
    return 10
  fi
  [[ "${mutating}" == 1 ]] || return 11
  stale_id="$(kv_get "${target}" OPERATION_ID 2>/dev/null || printf 'unknown')"
  stale_config="$(kv_get "${target}" CONFIG_SHA256 2>/dev/null || printf 'unknown')"
  stale_child="$(kv_get "${target}" CHILD_STATE_FILE 2>/dev/null || true)"
  stale_local_process="$(kv_get "${target}" LOCAL_PROCESS_STATE_FILE 2>/dev/null || true)"
  stale_op_tmp="$(kv_get "${target}" OP_TMP_PATH 2>/dev/null || true)"
  audit_dir="${parent}/audit"
  if [[ "${kind}" == global ]]; then
    audit_dir="${STATE_HOME}/ownexit/audit"
  fi
  ensure_private_dir "${audit_dir}" || return 12
  archive="${audit_dir}/operation.lock.stale.${stale_id}"
  if [[ ! -e "${archive}" && ! -L "${archive}" ]]; then
    link "${target}" "${archive}" 2>/dev/null || return 12
  else
    [[ -f "${archive}" && ! -L "${archive}" ]] || return 12
  fi
  # 归档成功后若控制进程断电，下一次只接受同一 inode 续做，不能覆盖同名审计记录。
  [[ "$(stat_inode "${target}")" == "$(stat_inode "${archive}")" ]] || return 12
  cleanup_stale_active_child "${stale_id}" "${stale_child}" || return 12
  cleanup_stale_local_process "${stale_id}" "${stale_local_process}" || return 12
  if [[ "${kind}" == chain ]]; then
    cleanup_stale_local_stage "${stale_id}" "${stale_config}" || return 12
  fi
  cleanup_stale_operation_tmp "${stale_id}" "${stale_config}" "${stale_op_tmp}" || return 12
  stale_temp="${parent}/.lock.${stale_id}.${kind}.tmp"
  if [[ -e "${stale_temp}" || -L "${stale_temp}" ]]; then
    [[ -f "${stale_temp}" && ! -L "${stale_temp}" && "$(stat_inode "${stale_temp}")" == "$(stat_inode "${archive}")" ]] || return 12
    rm -f "${stale_temp}"
  fi
  rm -f "${target}"
  acquire_lock_file "${target}" "${kind}" "${mutating}"
}

release_lock_file() {
  local target expected inode_before kind temp
  target="$1"
  [[ -f "${target}" && ! -L "${target}" ]] || return 0
  expected="$(kv_get "${target}" OPERATION_ID 2>/dev/null || true)"
  [[ "${expected}" == "${LOCK_OPERATION_ID}" ]] || {
    log_warn "不释放身份已变化的锁：${target}"
    return 1
  }
  inode_before="$(stat_inode "${target}")"
  [[ -n "${inode_before}" ]]
  [[ "$(kv_get "${target}" OPERATION_ID 2>/dev/null || true)" == "${LOCK_OPERATION_ID}" && "$(stat_inode "${target}")" == "${inode_before}" ]] || return 1
  [[ ! -e "${ACTIVE_CHILD_FILE}" && ! -L "${ACTIVE_CHILD_FILE}" ]] || return 1
  [[ ! -e "${CHAIN_STATE_DIR}/.active-child.${LOCK_OPERATION_ID}.tmp" && ! -L "${CHAIN_STATE_DIR}/.active-child.${LOCK_OPERATION_ID}.tmp" ]] || return 1
  [[ ! -e "${LOCAL_PROCESS_FILE}" && ! -L "${LOCAL_PROCESS_FILE}" ]] || return 1
  [[ ! -e "${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp" && ! -L "${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp" ]] || return 1
  case "$(basename "${target}")" in
    operation.lock) kind=chain ;;
    shared.lock) kind=global ;;
    *) return 1 ;;
  esac
  temp="$(dirname "${target}")/.lock.${LOCK_OPERATION_ID}.${kind}.tmp"
  if [[ -e "${temp}" || -L "${temp}" ]]; then
    [[ -f "${temp}" && ! -L "${temp}" && "$(stat_inode "${temp}")" == "${inode_before}" ]] || return 1
    rm -f "${temp}"
  fi
  rm -f "${target}"
}

terminate_active_child() {
  local pid expected_start attempt
  if [[ ! -e "${ACTIVE_CHILD_FILE}" && ! -L "${ACTIVE_CHILD_FILE}" ]]; then
    return 0
  fi
  active_child_metadata_matches "${ACTIVE_CHILD_FILE}" "${LOCK_OPERATION_ID}" || return 1
  pid="$(kv_get "${ACTIVE_CHILD_FILE}" PID)"
  expected_start="$(kv_get "${ACTIVE_CHILD_FILE}" PROCESS_START)"
  if process_is_running_identity "${pid}" "${expected_start}"; then
    # PID/start 仍在但命令身份不匹配时可能是同秒 PID reuse；宁可保留锁，也不能误杀无关进程。
    child_is_live "${ACTIVE_CHILD_FILE}" "${LOCK_OPERATION_ID}" || return 1
    kill "${pid}" 2>/dev/null || true
    attempt=0
    while (( attempt < 50 )) && process_is_running_identity "${pid}" "${expected_start}"; do
      sleep 0.1
      attempt="$((attempt + 1))"
    done
    if process_is_running_identity "${pid}" "${expected_start}"; then
      kill -9 "${pid}" 2>/dev/null || true
      attempt=0
      while (( attempt < 50 )) && process_is_running_identity "${pid}" "${expected_start}"; do
        sleep 0.1
        attempt="$((attempt + 1))"
      done
    fi
    process_is_running_identity "${pid}" "${expected_start}" && return 1
    wait "${pid}" 2>/dev/null || true
  fi
  clear_active_child "${pid}"
}

acquire_chain_lock() {
  local mutating rc
  mutating="$1"
  if acquire_lock_file "${CHAIN_LOCK}" chain "${mutating}"; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) LOCK_CHAIN_HELD=1 ;;
    10) return 10 ;;
    11) return 11 ;;
    *) die 1 '无法安全取得 chain lock' ;;
  esac
}

acquire_global_lock() {
  local rc
  if acquire_lock_file "${GLOBAL_LOCK}" global 1; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || die 1 '无法安全取得 shared global lock'
  LOCK_GLOBAL_HELD=1
}

test_exact_link_primitive() {
  local dir src target
  dir="${OP_TMP}/link-test"
  mkdir "${dir}"
  src="${dir}/source"
  target="${dir}/target"
  printf 'sentinel\n' > "${src}"
  mkdir "${dir}/container"
  ln -s "${dir}/container" "${target}"
  if link "${src}" "${target}" 2>/dev/null; then
    return 1
  fi
  [[ ! -e "${dir}/container/source" ]]
}

render_ssh_config() {
  {
    printf 'Host chain-relay\n'
    printf '    HostName %s\n' "${RELAY_HOST}"
    printf '    User root\n'
    printf '    Port %s\n' "${RELAY_SSH_PORT}"
    printf '    IdentityFile %s\n' "${RELAY_SSH_KEY}"
    printf '    ProxyCommand none\n\n'
    printf 'Host chain-exit\n'
    printf '    HostName %s\n' "${EXIT_HOST}"
    printf '    User root\n'
    printf '    Port %s\n' "${EXIT_SSH_PORT}"
    printf '    IdentityFile %s\n' "${EXIT_SSH_KEY}"
    printf '    ProxyJump chain-relay\n\n'
    printf 'Host *\n'
    printf '    IdentitiesOnly yes\n'
    printf '    BatchMode yes\n'
    printf '    StrictHostKeyChecking yes\n'
    printf '    UpdateHostKeys no\n'
    printf '    HostKeyAlgorithms ssh-ed25519\n'
    printf '    UserKnownHostsFile ~/.ssh/known_hosts\n'
    printf '    GlobalKnownHostsFile /etc/ssh/ssh_known_hosts\n'
    printf '    ConnectTimeout 12\n'
    printf '    ServerAliveInterval 15\n'
    printf '    ServerAliveCountMax 2\n'
    printf '    ForwardAgent no\n'
    printf '    ForwardX11 no\n'
    printf '    ClearAllForwardings yes\n'
    printf '    RequestTTY no\n'
    printf '    RemoteCommand none\n'
    printf '    PermitLocalCommand no\n'
  } > "${SSH_CONFIG}"
  chmod 600 "${SSH_CONFIG}"
  {
    printf 'Host chain-direct-exit\n'
    printf '    HostName %s\n' "${EXIT_HOST}"
    printf '    User root\n'
    printf '    Port %s\n' "${EXIT_SSH_PORT}"
    printf '    IdentityFile %s\n' "${EXIT_SSH_KEY}"
    printf '    ProxyJump none\n'
    printf '    ProxyCommand none\n'
    sed -n '/^Host \*/,$p' "${SSH_CONFIG}"
  } > "${SSH_DIRECT_CONFIG}"
  chmod 600 "${SSH_DIRECT_CONFIG}"
}

# 只读命令（READONLY_SSH_RETRY=1）下，SSH 返回 255 且不是控制端总超时（MANAGED_LAST_TIMEOUT=0）时重试，
# 最多 3 次，间隔 3 / 6 秒。255 也可能是认证失败或主机指纹不符，这种情况白等 9 秒后照样失败，可以接受。
# 每次尝试的 stdout 先写临时文件，只把最后一次的输出交给调用方，避免失败那次的半截输出混进被捕获的结果；
# 经 stdin 投递脚本的调用先把 stdin 缓存成文件，每次尝试都从头读。非 255 或超时直接返回，不重试。
# 参数：<role 用于日志> <stdin|nostdin> <run_managed_external 的完整参数...>。
ssh_with_readonly_retry() {
  local role stdin_mode stdin_file out_file attempt rc delay
  role="$1"
  stdin_mode="$2"
  shift 2
  if [[ "${READONLY_SSH_RETRY}" != 1 ]]; then
    run_managed_external "$@"
    return
  fi
  stdin_file="${OP_TMP}/ssh-retry-stdin.$$.${RANDOM}"
  if [[ "${stdin_mode}" == stdin ]]; then
    cat > "${stdin_file}" || return 1
  else
    : > "${stdin_file}" || return 1
  fi
  for attempt in 1 2 3; do
    out_file="${OP_TMP}/ssh-retry-out.$$.${RANDOM}.${attempt}"
    if run_managed_external "$@" < "${stdin_file}" > "${out_file}"; then rc=0; else rc="$?"; fi
    if [[ "${rc}" -ne 255 || "${MANAGED_LAST_TIMEOUT}" == 1 || "${attempt}" -eq 3 ]]; then
      cat "${out_file}"
      rm -f "${out_file}" "${stdin_file}"
      return "${rc}"
    fi
    rm -f "${out_file}"
    delay=$(( attempt * 3 ))
    log_warn "[ssh-retry] role=${role} attempt=${attempt}/3 rc=255，${delay} 秒后重试（只读命令）"
    sleep "${delay}"
  done
}

ssh_relay() {
  ssh_with_readonly_retry relay nostdin ssh ssh -n -F "${SSH_CONFIG}" chain-relay "$@"
}

ssh_exit() {
  ssh_with_readonly_retry exit nostdin ssh ssh -n -F "${SSH_CONFIG}" chain-exit "$@"
}

ssh_relay_stdin() {
  ssh_with_readonly_retry relay stdin ssh ssh -F "${SSH_CONFIG}" chain-relay "$@"
}

ssh_exit_stdin() {
  ssh_with_readonly_retry exit stdin ssh ssh -F "${SSH_CONFIG}" chain-exit "$@"
}

scp_relay() {
  run_managed_external scp scp -q -F "${SSH_CONFIG}" "$@"
}

scp_exit() {
  run_managed_external scp scp -q -F "${SSH_CONFIG}" "$@"
}

check_ssh_effective_config() {
  local alias output
  alias="$1"
  output="$(ssh -G -F "${SSH_CONFIG}" "${alias}" 2>/dev/null)"
  printf '%s\n' "${output}" | grep -qx 'updatehostkeys false' || return 1
  printf '%s\n' "${output}" | grep -qx 'hostkeyalgorithms ssh-ed25519' || return 1
  printf '%s\n' "${output}" | grep -qx 'batchmode yes' || return 1
  printf '%s\n' "${output}" | grep -qx 'stricthostkeychecking true' || return 1
  printf '%s\n' "${output}" | grep -qx 'serveraliveinterval 15' || return 1
  printf '%s\n' "${output}" | grep -qx 'serveralivecountmax 2' || return 1
}

fingerprint_private_key() {
  # ssh-keygen 可直接从私钥公开段取指纹，不读取私密材料，也不会为加密私钥交互询问口令。
  ssh-keygen -lf "$1" -E sha256 | awk '{print $2}'
}

negotiated_hostkey_fingerprint() {
  local alias debug_file fingerprint rc attempt max_attempts
  alias="$1"
  debug_file="${OP_TMP}/ssh-target-debug.${alias}.${LOCK_OPERATION_ID}"
  [[ ! -e "${debug_file}" && ! -L "${debug_file}" ]] || return 1
  # 只读命令下与 ssh_with_readonly_retry 同一重试条件（255 且非超时）。
  max_attempts=1
  [[ "${READONLY_SSH_RETRY}" != 1 ]] || max_attempts=3
  for attempt in 1 2 3; do
    # -E 是追加写：每次尝试前必须重建空文件，否则前一次残留的 `Server host key` 行会让下面 count != 1 判定失败。
    rm -f "${debug_file}" || return 1
    ( set -o noclobber; : > "${debug_file}" ) 2>/dev/null || return 1
    chmod 600 "${debug_file}" || return 1
    # ProxyJump 子进程会继承 verbose 等级，但不会继承外层 ssh 的 LogFile；因此 -E 文件只含目标会话日志，
    # 避免从合并 stderr 的第一条 `Server host key` 误取中转机指纹。
    if run_managed_external ssh ssh -vv -E "${debug_file}" -n -F "${SSH_CONFIG}" "${alias}" true >/dev/null 2>&1; then
      rc=0
    else
      rc="$?"
    fi
    [[ "${rc}" -eq 255 && "${MANAGED_LAST_TIMEOUT}" != 1 && "${attempt}" -lt "${max_attempts}" ]] || break
    log_warn "[ssh-retry] role=${alias#chain-} attempt=${attempt}/3 rc=255，$(( attempt * 3 )) 秒后重试（只读命令，主机指纹探测）"
    sleep "$(( attempt * 3 ))"
  done
  if [[ "${rc}" -ne 0 ]] || ! require_secure_user_file "${debug_file}" 600; then
    rm -f "${debug_file}" || true
    return 1
  fi
  fingerprint="$(awk '$2 == "Server" && $3 == "host" && $4 == "key:" && $5 == "ssh-ed25519" && $6 ~ /^SHA256:/ {fingerprint=$6; count++} END {if (count != 1) exit 1; print fingerprint}' "${debug_file}")" || {
    rm -f "${debug_file}" || true
    return 1
  }
  rm -f "${debug_file}" || return 1
  # ssh -vv 调试行可能以 CRLF 结尾，awk 按空白切字段不会剥掉行尾 \r，会把 \r 并进 $6；
  # 必须清掉，否则写进 state/journal 后触发校验正则（不含 \r）失败、并使指纹比对含隐藏字符。
  fingerprint="${fingerprint%$'\r'}"
  [[ "${fingerprint}" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || return 1
  printf '%s\n' "${fingerprint}"
}

probe_ssh_and_fingerprints() {
  local relay_fp exit_fp
  check_ssh_effective_config chain-relay || die 3 '中转 SSH 隔离配置未按预期生效'
  check_ssh_effective_config chain-exit || die 3 '出口机 SSH 隔离配置未按预期生效'
  ssh_relay true >/dev/null || die 3 '中转 root 免密 SSH 或 ed25519 host key 核验失败'
  ssh_exit true >/dev/null || die 3 '经中转访问出口机的 root 免密 SSH 或 host key 核验失败'
  relay_fp="$(negotiated_hostkey_fingerprint chain-relay)"
  exit_fp="$(negotiated_hostkey_fingerprint chain-exit)"
  [[ "${relay_fp}" == SHA256:* && "${exit_fp}" == SHA256:* ]] || die 3 '无法取得两端 ed25519 host-key 指纹'
  RELAY_HOSTKEY_FINGERPRINT="${relay_fp}"
  EXIT_HOSTKEY_FINGERPRINT="${exit_fp}"
  [[ "$(fingerprint_private_key "${RELAY_SSH_KEY}")" == "${RELAY_SSH_KEY_FINGERPRINT}" ]] || die 3 '中转 SSH key 指纹在 preflight 前发生变化'
  [[ "$(fingerprint_private_key "${EXIT_SSH_KEY}")" == "${EXIT_SSH_KEY_FINGERPRINT}" ]] || die 3 '出口机 SSH key 指纹在 preflight 前发生变化'
  if run_managed_external ssh ssh -n -F "${SSH_DIRECT_CONFIG}" chain-direct-exit true >/dev/null 2>&1; then
    log_info '本机到出口机管理端口的隔离直连探针成功（仅作管理通道证据）'
  else
    log_warn '本机到出口机管理端口的隔离直连探针失败；经中转管理通道已通过'
  fi
}

require_local_dependencies() {
  local command_name platform_commands
  [[ "${BASH_VERSINFO[0]}" -gt 3 || ( "${BASH_VERSINFO[0]}" -eq 3 && "${BASH_VERSINFO[1]}" -ge 2 ) ]] || die 3 '需要 Bash 3.2 或以上'
  # 控制端支持 macOS 与 Linux（含 WSL）；路由与端口探测在两边用不同命令（见 route_interface / tcp_probe）。
  case "$(uname -s)" in
    Darwin) platform_commands='route nc' ;;
    Linux) platform_commands='ip timeout' ;;
    *) die 3 "控制端只支持 macOS 与 Linux（当前：$(uname -s)）" ;;
  esac
  bash -n "${SCRIPT_PATH}" || die 3 '当前 PATH 中的 bash 无法解析脚本'
  /bin/bash -n "${SCRIPT_PATH}" || die 3 '/bin/bash 无法解析脚本'
  # git 不在这份清单里：只有 git clone 形态需要它，由 init_repo_root 按安装形态自行检查；pip 安装的副本没有 git 也能运行。
  for command_name in ssh scp ssh-keygen curl openssl tar ps mktemp mkfifo stat readlink link ln sync awk sed grep sort tr head tail cmp find chmod mkdir rmdir rm cp mv cut cat date sleep uname kill dirname basename id ${platform_commands}; do
    command -v "${command_name}" >/dev/null 2>&1 || die 3 "本机缺少依赖：${command_name}"
  done
  ssh -E /dev/null -G -F /dev/null localhost >/dev/null 2>&1 || die 3 '本机 OpenSSH 不支持独立 LogFile（-E）能力'
  command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 || die 3 '本机缺少 SHA-256 工具'
  test_exact_link_primitive || die 3 '本机 link 不满足 exact-target no-replace 语义'
}

init_repo_root() {
  # CONFIG_PATH 的“不得位于 worktree 内”是秘密防泄漏闸门。按安装形态区分：
  #   - 脚本上一级有 .git（git clone 或 worktree）：git 不可用或仓库身份不明时必须先失败，不能跳过闸门；
  #   - 没有 .git（pip 安装的副本）：本来就不存在可泄漏的仓库，REPO_ROOT 置空，所有“位于仓库内”判断随之跳过。
  if [[ ! -e "${SCRIPT_DIR}/../.git" && ! -L "${SCRIPT_DIR}/../.git" ]]; then
    REPO_ROOT=''
    return 0
  fi
  command -v git >/dev/null 2>&1 || die 3 '本机缺少 bootstrap 依赖：git'
  REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)" || die 3 '无法确定脚本所属 Git worktree'
  [[ -n "${REPO_ROOT}" && -d "${REPO_ROOT}" && ! -L "${REPO_ROOT}" ]] || die 3 '脚本所属 Git worktree 身份异常'
}

archive_url() {
  printf '%s/%s\n' "${RELEASE_BASE_URL}" "$1"
}

# 下载一个官方包到 temp_path 并核对摘要。optional=optional 时失败只返回 1（本机验证用的包拿不到就跳过 smoke），
# 否则按 v0.1.0 的行为以退出码 3 终止。限时 600 秒，避免国内直连 GitHub 时无限挂住。
download_official_archive() {
  local archive expected temp_path optional
  archive="$1"
  expected="$2"
  temp_path="$3"
  optional="$4"
  if ! curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 --max-time 600 "$(archive_url "${archive}")" -o "${temp_path}"; then
    rm -f "${temp_path}"
    [[ "${optional}" == optional ]] && return 1
    die 3 "下载官方资产失败：${archive}"
  fi
  if [[ "$(sha256_file "${temp_path}")" != "${expected}" ]]; then
    rm -f "${temp_path}"
    [[ "${optional}" == optional ]] && return 1
    die 3 "官方资产摘要不符：${archive}"
  fi
}

verified_archive_path() {
  local mode archive expected cache_path temp_path actual cache_safe optional
  mode="$1"
  archive="$2"
  expected="$3"
  optional="${4:-required}"
  cache_path="${CHAIN_CACHE_DIR}/${archive}"
  cache_safe=1
  if [[ -e "${CHAIN_CACHE_DIR}" || -L "${CHAIN_CACHE_DIR}" ]]; then
    private_dir_is_safe "${CHAIN_CACHE_DIR}" || cache_safe=0
  fi
  if [[ "${cache_safe}" == 0 ]]; then
    [[ "${mode}" != deploy ]] || die 1 "cache 目录身份或权限不安全：${CHAIN_CACHE_DIR}"
    temp_path="${OP_TMP}/${archive}"
    download_official_archive "${archive}" "${expected}" "${temp_path}" "${optional}" || return 1
    printf '%s\n' "${temp_path}"
    return 0
  fi
  if [[ -f "${cache_path}" && ! -L "${cache_path}" ]] && require_secure_user_file "${cache_path}" 600; then
    actual="$(sha256_file "${cache_path}")"
    if [[ "${actual}" == "${expected}" ]]; then
      printf '%s\n' "${cache_path}"
      return 0
    fi
    if [[ "${mode}" == deploy ]]; then
      local corrupt
      corrupt="${cache_path}.corrupt.${actual}.${OPERATION_ID}"
      link "${cache_path}" "${corrupt}" || die 1 '无法排他归档损坏的 cache'
      rm -f "${cache_path}"
    fi
  elif [[ -e "${cache_path}" ]]; then
    [[ "${mode}" == deploy ]] || {
      temp_path="${OP_TMP}/${archive}"
      download_official_archive "${archive}" "${expected}" "${temp_path}" "${optional}" || return 1
      printf '%s\n' "${temp_path}"
      return 0
    }
    die 1 "cache 路径不是当前用户拥有的 600 regular file：${cache_path}"
  fi
  temp_path="${OP_TMP}/${archive}"
  download_official_archive "${archive}" "${expected}" "${temp_path}" "${optional}" || return 1
  if [[ "${mode}" == deploy ]]; then
    local cache_temp
    ensure_private_dir "${CHAIN_CACHE_DIR}" || die 1 'cache 目录身份或权限不安全'
    cache_temp="${CHAIN_CACHE_DIR}/.${archive}.${LOCK_OPERATION_ID}.tmp"
    ( set -o noclobber; : > "${cache_temp}" ) 2>/dev/null || die 1 '无法排他创建 cache 临时文件'
    cp "${temp_path}" "${cache_temp}" || die 1 '无法写入 cache 临时文件'
    chmod 600 "${cache_temp}"
    [[ "$(sha256_file "${cache_temp}")" == "${expected}" ]] || die 1 'cache 发布前摘要复核失败'
    sync
    if ! link "${cache_temp}" "${cache_path}" 2>/dev/null; then
      [[ -f "${cache_path}" && ! -L "${cache_path}" && "$(sha256_file "${cache_path}")" == "${expected}" ]] || die 1 'cache no-replace 发布发生冲突'
    fi
    rm -f "${cache_temp}"
    printf '%s\n' "${cache_path}"
  else
    printf '%s\n' "${temp_path}"
  fi
}

# 只准备本机做出口 smoke 用的官方包（远端包的期望哈希取常量，远端自行下载，见 install_remote_binary）。
# 本机平台没有官方包、或缓存缺失且下载失败时，DARWIN_* 记为 NONE，smoke_from_mac 跳过；这不是部署门槛。
prepare_verified_assets() {
  local mode extract_root version_output expected_binary
  mode="$1"
  DARWIN_ARCHIVE_PATH=''
  DARWIN_BINARY_PATH=''
  select_local_platform
  if [[ "${DARWIN_ARCHIVE_SHA256}" == NONE ]]; then
    DARWIN_BINARY_SHA256='NONE'
    log_warn "没有本机平台（$(uname -s) $(uname -m)）的官方包，跳过本机侧出口验证"
    return 0
  fi
  if ! DARWIN_ARCHIVE_PATH="$(verified_archive_path "${mode}" "${DARWIN_ARCHIVE}" "${DARWIN_ARCHIVE_SHA256}" optional)"; then
    DARWIN_ARCHIVE_PATH=''
    DARWIN_ARCHIVE_SHA256='NONE'
    DARWIN_BINARY_SHA256='NONE'
    log_warn "没有本机平台（${LOCAL_PLATFORM}）的官方包（缓存缺失且下载失败），跳过本机侧出口验证"
    return 0
  fi
  extract_root="${OP_TMP}/assets"
  mkdir "${extract_root}"
  tar -xzf "${DARWIN_ARCHIVE_PATH}" -C "${extract_root}"
  DARWIN_BINARY_PATH="${extract_root}/sing-box-${SING_BOX_VERSION}-${LOCAL_PLATFORM}/sing-box"
  [[ -f "${DARWIN_BINARY_PATH}" && ! -L "${DARWIN_BINARY_PATH}" ]] || die 3 "本机平台官方包布局异常：${LOCAL_PLATFORM}"
  chmod 700 "${DARWIN_BINARY_PATH}"
  DARWIN_BINARY_SHA256="$(sha256_file "${DARWIN_BINARY_PATH}")"
  expected_binary="$(binary_sha256_of_platform "${LOCAL_PLATFORM}")"
  [[ "${DARWIN_BINARY_SHA256}" == "${expected_binary}" ]] || die 3 "本机平台 binary 摘要不符：${LOCAL_PLATFORM}"
  version_output="$("${DARWIN_BINARY_PATH}" version | awk '/^sing-box version / {print $3; exit}')"
  [[ "${version_output}" == "${SING_BOX_VERSION}" ]] || die 3 '本机 binary 版本不符'
}

write_remote_preflight_script() {
  local output
  output="$1"
  cat > "${output}" <<'REMOTE_PREFLIGHT'
#!/usr/bin/env bash
# 该脚本只在远端临时执行，核验平台、工具能力、防火墙和既有 sing-box 声明。
set -euo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

role="$1"
cohosts="$2"
tmp="$(mktemp -d /tmp/ownexit-chain-preflight.XXXXXX)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'preflight:%s\n' "$1" >&2
  exit 1
}

supports_option() {
  local executable expected help_output
  executable="$1"
  expected="$2"
  # `grep -q` 会在命中后提前关管道；配合 pipefail 时生产者可能因 SIGPIPE 被误判失败。
  # 先完整收集 help，既保留命令自身失败语义，也让能力判断不受 SSH/调度时序影响。
  help_output="$("$executable" --help 2>&1)" || return 1
  [[ "$help_output" == *"$expected"* ]]
}

[[ "$(id -u)" == 0 ]] || fail '必须以 root 执行'
[[ "$(uname -s)" == Linux ]] || fail '只支持 Linux'
case "$(uname -m)" in
  x86_64) remote_arch=amd64 ;;
  aarch64|arm64) remote_arch=arm64 ;;
  *) fail "只支持 amd64 / arm64（当前：$(uname -m)）" ;;
esac
for parent in / /opt /etc /etc/systemd /etc/systemd/system; do
  [[ -d "$parent" && ! -L "$parent" && "$(stat -c %u "$parent")" == 0 ]] || fail "系统父目录不安全:$parent"
  parent_mode="$(stat -c %a "$parent")"
  (( (8#$parent_mode & 8#022) == 0 )) || fail "系统父目录可被 group/other 写:$parent"
done
[[ "$(stat -c %d /etc)" == "$(stat -c %d /etc/systemd/system)" ]] || fail '配置与 systemd unit 目标不在同一文件系统'
if [[ "$role" == relay ]]; then
  wants_dir=/etc/systemd/system/sockets.target.wants
else
  wants_dir=/etc/systemd/system/multi-user.target.wants
fi
# 全新机（从未 enable 过 socket unit）没有 sockets.target.wants 是常态；脚本按设计不代建 systemd 标准目录，
# 但"不存在"必须与"存在却不安全"分开报，并告诉用户怎么建（fix-preflight-wants-dir.md）。
[[ -e "$wants_dir" || -L "$wants_dir" ]] || fail "systemd wants 目录不存在:$wants_dir（请以 root 执行 mkdir -m 755 $wants_dir 后重跑；脚本不代建 systemd 标准目录）"
[[ -d "$wants_dir" && ! -L "$wants_dir" && "$(stat -c %u "$wants_dir")" == 0 ]] || fail "systemd wants 目录不安全:$wants_dir"
wants_mode="$(stat -c %a "$wants_dir")"
(( (8#$wants_mode & 8#022) == 0 )) || fail "systemd wants 目录可被 group/other 写:$wants_dir"

common='bash ssh-keygen openssl sha256sum systemctl systemd-analyze systemd-run ss tar nft timeout find stat readlink link ln sync base64 awk sed grep sort tr head tail cmp chmod chown mkdir rmdir rm cp mv cut cat date sleep uname kill dirname basename id mktemp env'
for command_name in $common; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令:$command_name"
done
trusted_executable() {
  local candidate resolved mode
  candidate="$1"
  resolved="$(readlink -f "$candidate")"
  [[ "$resolved" == /* && -f "$resolved" && ! -L "$resolved" && -x "$resolved" ]] || fail "不安全的可执行文件:$candidate"
  [[ "$(stat -c %u:%g "$resolved")" == 0:0 ]] || fail "可执行文件非 root:root:$resolved"
  mode="$(stat -c %a "$resolved")"
  (( (8#$mode & 8#022) == 0 )) || fail "可执行文件可被 group/other 写:$resolved"
  printf '%s\n' "$resolved"
}
systemctl_path="$(trusted_executable "$(command -v systemctl)")"
if [[ "$role" == relay ]]; then
  for command_name in curl getent; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令:$command_name"
  done
else
  command -v wget >/dev/null 2>&1 || fail '缺少命令:wget'
fi

supports_option tar '--no-same-owner' || fail 'tar 不支持 --no-same-owner'
supports_option tar '--no-same-permissions' || fail 'tar 不支持 --no-same-permissions'
supports_option ln '--no-target-directory' || fail 'ln 不支持 --no-target-directory'

printf 'sentinel\n' > "$tmp/source"
mkdir "$tmp/container"
ln -s "$tmp/container" "$tmp/target"
if link "$tmp/source" "$tmp/target" 2>/dev/null; then
  fail 'link 覆盖或跟随了 exact target'
fi
[[ ! -e "$tmp/container/source" ]] || fail 'link 把 target directory 当作容器'

# 除本项目自己管理的出口机白名单表（table inet ownexit_*，见 EXIT_SOURCE_FILTER=managed）外不得有任何 nft 表；
# 同一台出口机上可以有多条链各自的白名单表。
timeout --signal=TERM --kill-after=2s 10s nft list tables > "$tmp/nft" || fail 'nft 规则无法核证'
if grep -v '^table inet ownexit_[a-z0-9_]*$' "$tmp/nft" | grep -q '[^[:space:]]'; then
  fail 'nft 规则集非空（除 ownexit_* 白名单表外）'
fi
if command -v ufw >/dev/null 2>&1; then
  timeout --signal=TERM --kill-after=2s 10s ufw status > "$tmp/ufw" || fail 'ufw 状态无法核证'
  grep -q '^Status: inactive$' "$tmp/ufw" || fail 'ufw 处于活动状态'
fi
if command -v iptables-save >/dev/null 2>&1; then
  timeout --signal=TERM --kill-after=2s 10s iptables-save > "$tmp/iptables" || fail 'iptables 状态无法核证'
  ! grep -q '^-A ' "$tmp/iptables" || fail 'iptables 存在规则'
  ! awk '$1 == "-P" && $3 != "ACCEPT" { bad=1 } END { exit bad ? 0 : 1 }' "$tmp/iptables" || fail 'iptables 内建链 policy 非 ACCEPT'
elif [[ -s /proc/net/ip_tables_names ]]; then
  fail '缺少 iptables-save 但 legacy table 存在'
fi

systemd-analyze unit-paths >/dev/null || fail 'systemd unit load path 无法读取'
supports_option systemd-run '--timer-property' || fail 'systemd-run 不支持 --timer-property'

if [[ "$role" == relay ]]; then
  proxyd="$(command -v systemd-socket-proxyd 2>/dev/null || true)"
  if [[ -z "$proxyd" ]]; then
    for candidate in /usr/lib/systemd/systemd-socket-proxyd /lib/systemd/systemd-socket-proxyd; do
      if [[ -x "$candidate" && ! -L "$candidate" ]]; then
        proxyd="$candidate"
        break
      fi
    done
  fi
  [[ -n "$proxyd" ]] || fail '缺少安全的 systemd-socket-proxyd'
  proxyd="$(trusted_executable "$proxyd")"
  supports_option "$proxyd" '--connections-max' || fail 'systemd-socket-proxyd 不支持 --connections-max'

  # co-host 判定表（docs/feature/feature-direct-native-install.md §5.1.10）：预检、init、rebaseline 共用同一组信号。
  # U1/D1 = 233boy 的 sing-box.service 与 /etc/sing-box；U2/D2 = ownexit 直连的 ownexit-direct.service 与 /etc/ownexit-direct；
  # P = 是否有可执行文件名为 sing-box / sing-box-* 的进程。三种取值互斥，现场与声明不符即失败。
  load_state="$(systemctl show sing-box.service -p LoadState --value 2>/dev/null || true)"
  direct_load_state="$(systemctl show ownexit-direct.service -p LoadState --value 2>/dev/null || true)"
  config_seen=no
  [[ -e /etc/sing-box || -L /etc/sing-box ]] && config_seen=yes
  direct_config_seen=no
  [[ -e /etc/ownexit-direct || -L /etc/ownexit-direct ]] && direct_config_seen=yes
  process_seen=no
  for proc_exe in /proc/[0-9]*/exe; do
    resolved="$(readlink -f "$proc_exe" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || continue
    case "$(basename "$resolved")" in
      sing-box|sing-box-*) process_seen=yes; break ;;
    esac
  done
  case "$cohosts" in
    yes) cohost_unit=sing-box.service; cohost_dir=/etc/sing-box ;;
    ownexit-direct) cohost_unit=ownexit-direct.service; cohost_dir=/etc/ownexit-direct ;;
    *) cohost_unit=''; cohost_dir='' ;;
  esac
  if [[ "$cohosts" == yes ]]; then
    [[ "$load_state" == loaded && "$config_seen" == yes && "$process_seen" == yes ]] || fail '声明 co-host，但既有 sing-box 配置、进程或 unit 缺失'
    [[ "$direct_load_state" == not-found && "$direct_config_seen" == no ]] || fail '声明 233boy co-host，但中转机上还有 ownexit-direct；运行 rebaseline 重新登记'
  elif [[ "$cohosts" == ownexit-direct ]]; then
    [[ "$direct_load_state" == loaded && "$direct_config_seen" == yes && "$process_seen" == yes ]] || fail '声明 ownexit-direct co-host，但其配置、进程或 unit 缺失'
    [[ "$load_state" == not-found && "$config_seen" == no ]] || fail '声明 ownexit-direct co-host，但中转机上还有 233boy 的 sing-box；运行 rebaseline 重新登记'
  else
    [[ "$load_state" == not-found && "$config_seen" == no && "$process_seen" == no && "$direct_load_state" == not-found && "$direct_config_seen" == no ]] || fail '声明全新中转，但发现既有 sing-box / ownexit-direct 的配置、进程或 unit；运行 rebaseline 重新登记'
  fi
  if [[ -n "$cohost_unit" ]]; then
    [[ -d "$cohost_dir" && ! -L "$cohost_dir" ]] || fail "既有 $cohost_dir 目录身份不安全"
    config_mode="$(stat -c %a "$cohost_dir")"
    (( (8#$config_mode & 8#022) == 0 )) || fail "既有 $cohost_dir 可被 group/other 写"
    [[ "$(systemctl is-active "$cohost_unit" 2>/dev/null || true)" == active ]] || fail "既有 $cohost_unit 非 active"
    pid="$(systemctl show "$cohost_unit" -p MainPID --value)"
    [[ "$pid" =~ ^[1-9][0-9]*$ && -d "/proc/$pid" ]] || fail "既有 $cohost_unit MainPID 无效"
    exe="$(readlink -f "/proc/$pid/exe")"
    [[ -f "$exe" && ! -L "$exe" ]] || fail "既有 $cohost_unit executable 不安全"
  fi
  printf 'SOCKET_PROXYD_PATH=%s\n' "$proxyd"
  printf 'SYSTEMCTL_PATH=%s\n' "$systemctl_path"
fi
printf 'REMOTE_ARCH=%s\n' "$remote_arch"
printf 'NFT_PATH=%s\n' "$(trusted_executable "$(command -v nft)")"
printf 'REMOTE_PREFLIGHT=ok\n'
REMOTE_PREFLIGHT
  chmod 600 "${output}"
}

# 两端平台预检。除 v0.1.0 的检查外，还取回两端架构（必须一致）与出口机 nft 的绝对路径。
# 架构已由状态文件锁定（REMOTE_ARCH_LOCKED=1，见状态读取）时，现场架构必须与之相同，否则返回 34。
probe_remote_platform_preflight() {
  local script output rc relay_arch exit_arch
  script="${OP_TMP}/remote-preflight.sh"
  write_remote_preflight_script "${script}" || return 30
  if output="$(ssh_relay_stdin bash -s -- relay "${RELAY_COHOSTS_SINGBOX}" < "${script}")"; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || { [[ "${rc}" -eq 255 ]] && return 21; return 31; }
  SOCKET_PROXYD_PATH="$(printf '%s\n' "${output}" | awk -F= '$1 == "SOCKET_PROXYD_PATH" {print $2}')"
  SYSTEMCTL_PATH="$(printf '%s\n' "${output}" | awk -F= '$1 == "SYSTEMCTL_PATH" {print $2}')"
  [[ "${SOCKET_PROXYD_PATH}" == /* && "${SYSTEMCTL_PATH}" == /* ]] || return 32
  relay_arch="$(printf '%s\n' "${output}" | awk -F= '$1 == "REMOTE_ARCH" {print $2}')"
  if output="$(ssh_exit_stdin bash -s -- exit no < "${script}")"; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || { [[ "${rc}" -eq 255 ]] && return 22; return 33; }
  exit_arch="$(printf '%s\n' "${output}" | awk -F= '$1 == "REMOTE_ARCH" {print $2}')"
  EXIT_NFT_PATH="$(printf '%s\n' "${output}" | awk -F= '$1 == "NFT_PATH" {print $2}')"
  [[ "${EXIT_NFT_PATH}" == /* ]] || return 33
  [[ -n "${relay_arch}" && "${relay_arch}" == "${exit_arch}" ]] || return 34
  if [[ "${REMOTE_ARCH_LOCKED}" == 1 ]]; then
    [[ "${relay_arch}" == "${REMOTE_ARCH}" ]] || return 34
  else
    select_remote_arch "${relay_arch}" || return 34
  fi
}

remote_platform_preflight() {
  local rc
  if probe_remote_platform_preflight; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) return 0 ;;
    21) die 3 '中转平台预检 SSH 不可达' ;;
    22) die 3 '出口机平台预检 SSH 不可达' ;;
    31) die 3 '中转依赖、防火墙或角色声明预检失败；若中转机上的直连刚迁移、改参数、新装或卸载过，运行 rebaseline 重新登记' ;;
    32) die 3 '中转能力探针没有返回安全绝对路径' ;;
    33) die 3 '出口机依赖或防火墙预检失败' ;;
    34) die 3 '中转机与出口机的 CPU 架构必须相同（都为 amd64 或都为 arm64），且与已部署状态一致' ;;
    *) die 3 '远端平台预检脚本生成或执行异常' ;;
  esac
}

probe_exit_tls() {
  ssh_exit env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin timeout --signal=TERM --kill-after=2s 20s openssl s_client -connect "${REALITY_SERVER_NAME}:443" -servername "${REALITY_SERVER_NAME}" -tls1_3 -verify_return_error -verify_hostname "${REALITY_SERVER_NAME}" </dev/null >/dev/null 2>&1 || die 3 '出口机到 Reality handshake server 的 TLS 1.3/证书前置探针失败'
}

write_exit_probe_script() {
  local output
  output="$1"
  cat > "${output}" <<'EXIT_PROBE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
expected="$1"
tmp="$(mktemp -d /tmp/ownexit-chain-exit.XXXXXX)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
success=0
for endpoint in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
  result="$(
    env -i HOME="$tmp" PATH=/usr/sbin:/usr/bin:/sbin:/bin wget --no-config --no-proxy --inet4-only --timeout=15 -qO- "$endpoint" 2>/dev/null | tr -d '[:space:]' || true
  )"
  if [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    [[ "$result" == "$expected" ]] || exit 21
    success=$((success + 1))
  fi
done
(( success >= 2 )) || exit 22
printf 'EXIT_BASELINE=ok\n'
EXIT_PROBE
  chmod 600 "${output}"
}

probe_exit_exit() {
  local script
  script="${OP_TMP}/exit-probe.sh"
  write_exit_probe_script "${script}"
  ssh_exit_stdin bash -s -- "${EXPECTED_EXIT_IPV4}" < "${script}" >/dev/null || die 3 '出口机直连出口未通过 2-of-3 严格仲裁'
}

# 返回 0=远端确无该路径；1=远端存在（碰撞）；2=SSH 不可达（rc 255），没核成。
# 调用方必须区分 1 与 2：把不可达当碰撞会让 SSH 抖动误报成退出码 4 的"路径碰撞"（fix-collision-unreachable.md）。
# remote_test_path <role> <-e|-L> <path>：远端 `test ! <flag> <path>`。
# 远端路径是否不存在（既不是文件也不是符号链接）。SSH 返回 255 表示连接层失败而不是“路径存在”：
# 本机开着 TUN 等情况下 SSH 偶尔被断开，重试一次；仍失败才返回 2（不可达），由调用方报退出码 3。
remote_test_path() {
  local role flag path rc attempt
  role="$1"
  flag="$2"
  path="$3"
  for attempt in 1 2; do
    if [[ "${role}" == relay ]]; then
      if ssh_relay test ! "${flag}" "${path}"; then rc=0; else rc="$?"; fi
    else
      if ssh_exit test ! "${flag}" "${path}"; then rc=0; else rc="$?"; fi
    fi
    [[ "${rc}" -eq 255 && "${attempt}" -eq 1 ]] || break
    log_warn "${role} SSH 连接被断开，2 秒后重试一次（检查 ${path}）"
    sleep 2
  done
  return "${rc}"
}

remote_path_absent() {
  local role path rc
  role="$1"
  path="$2"
  if remote_test_path "${role}" -e "${path}"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -ne 255 ]] || return 2
  [[ "${rc}" -eq 0 ]] || return 1
  if remote_test_path "${role}" -L "${path}"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -ne 255 ]] || return 2
  [[ "${rc}" -eq 0 ]]
}

role_label() {
  if [[ "$1" == relay ]]; then printf '中转\n'; else printf '出口机\n'; fi
}

# 碰撞核证的统一分派：不可达退出 3（与 configured_resources_absent 的口径一致），真实碰撞才退出 4。
# 按仓库约定用 if 而不是 `func || die`，避免 set -e 在条件上下文失效时吞掉返回码差异。
require_remote_path_absent() {
  local role path message rc
  role="$1"
  path="$2"
  message="$3"
  if remote_path_absent "${role}" "${path}"; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) return 0 ;;
    2) die 3 "碰撞核证期间$(role_label "${role}")不可达：${path}" ;;
    *) die 4 "${message}" ;;
  esac
}

require_remote_unit_absent() {
  local role unit message rc
  role="$1"
  unit="$2"
  message="$3"
  if remote_unit_absent "${role}" "${unit}"; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) return 0 ;;
    2) die 3 "碰撞核证期间$(role_label "${role}")不可达或 systemd unit-paths 不可读：${unit}" ;;
    *) die 4 "${message}" ;;
  esac
}

remote_unit_absent() {
  local role unit script
  role="$1"
  unit="$2"
  script="${OP_TMP}/unit-absent.sh"
  cat > "${script}" <<'UNIT_ABSENT'
#!/usr/bin/env bash
set -euo pipefail
umask 077
unit="$1"
paths_file="$(mktemp /tmp/ownexit-unit-paths.XXXXXX)"
trap 'rm -f "$paths_file"' EXIT
systemd-analyze unit-paths > "$paths_file" || exit 20
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  [[ ! -e "$path/$unit" && ! -L "$path/$unit" && ! -e "$path/$unit.d" && ! -L "$path/$unit.d" ]] || exit 10
done < "$paths_file"
load="$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)"
fragment="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null || true)"
dropins="$(systemctl show "$unit" -p DropInPaths --value 2>/dev/null || true)"
[[ "$load" == not-found && -z "$fragment" && -z "$dropins" ]] || exit 10
UNIT_ABSENT
  chmod 600 "${script}"
  local rc
  if [[ "${role}" == relay ]]; then
    if ssh_relay_stdin bash -s -- "${unit}" < "${script}"; then rc=0; else rc="$?"; fi
  else
    if ssh_exit_stdin bash -s -- "${unit}" < "${script}"; then rc=0; else rc="$?"; fi
  fi
  case "${rc}" in
    0) return 0 ;;
    20|255) return 2 ;;
    *) return 1 ;;
  esac
}

check_initial_collisions() {
  local relay_owner relay_socket relay_service relay_link exit_owner exit_exit exit_service exit_link rc
  configured_local_resources_absent || die 4 '无 active state，但发现当前 chain 的本地 staging、临时提交或活动产物'
  if configured_resources_absent; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    21) die 3 '初始资源核证期间中转不可达' ;;
    22) die 3 '初始资源核证期间出口机不可达' ;;
    *) die 4 '无 active state，但发现确定性资源或当前 chain/config 的 owned staging' ;;
  esac
  relay_owner="${REMOTE_CONFIG_DIR}/${CHAIN_ID}.owner.env"
  relay_socket="/etc/systemd/system/ownexit-chain-relay-${CHAIN_ID}.socket"
  relay_service="/etc/systemd/system/ownexit-chain-relay-${CHAIN_ID}.service"
  relay_link="/etc/systemd/system/sockets.target.wants/ownexit-chain-relay-${CHAIN_ID}.socket"
  exit_owner="${REMOTE_CONFIG_DIR}/${CHAIN_ID}.owner.env"
  exit_exit="${REMOTE_CONFIG_DIR}/${CHAIN_ID}.exit.json"
  exit_service="/etc/systemd/system/ownexit-chain-exit-${CHAIN_ID}.service"
  exit_link="/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-${CHAIN_ID}.service"
  require_remote_path_absent relay "${relay_owner}" "中转专属 owner 路径碰撞：${relay_owner}"
  require_remote_path_absent relay "${relay_socket}" "中转 socket unit 路径碰撞：${relay_socket}"
  require_remote_path_absent relay "${relay_service}" "中转 service unit 路径碰撞：${relay_service}"
  require_remote_path_absent relay "${relay_link}" "中转 enablement 路径碰撞：${relay_link}"
  require_remote_unit_absent relay "ownexit-chain-relay-${CHAIN_ID}.socket" 'systemd load path 中存在同名中转 socket'
  require_remote_unit_absent relay "ownexit-chain-relay-${CHAIN_ID}.service" 'systemd load path 中存在同名中转 service'
  require_remote_path_absent exit "${exit_owner}" "出口机专属 owner 路径碰撞：${exit_owner}"
  require_remote_path_absent exit "${exit_exit}" "出口机 config 路径碰撞：${exit_exit}"
  require_remote_path_absent exit "${exit_service}" "出口机 service unit 路径碰撞：${exit_service}"
  require_remote_path_absent exit "${exit_link}" "出口机 enablement 路径碰撞：${exit_link}"
  require_remote_unit_absent exit "ownexit-chain-exit-${CHAIN_ID}.service" 'systemd load path 中存在同名出口机 service'
}

snapshot_operation_state() {
  local path
  for path in "${CHAIN_LOCK}" "${JOURNAL_FILE}"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      if [[ -f "${path}" && ! -L "${path}" ]]; then
        printf '%s|%s|%s|%s\n' "${path}" "$(stat_inode "${path}")" "$(stat_mode "${path}")" "$(sha256_file "${path}")"
      else
        printf '%s|unsafe\n' "${path}"
      fi
    else
      printf '%s|absent\n' "${path}"
    fi
  done
}

# RELAY_COHOSTS_SINGBOX 取值 → 被保护的既有单元（docs/feature/feature-direct-native-install.md §5.1.10）。
cohost_unit_of() {
  case "$1" in
    yes) printf 'sing-box.service' ;;
    ownexit-direct) printf 'ownexit-direct.service' ;;
    *) return 1 ;;
  esac
}

probe_collect_relay_baseline() {
  local destination script output active enabled rc
  destination="$1"
  if [[ ! -e "${destination}" && ! -L "${destination}" ]]; then
    mkdir "${destination}"
  fi
  [[ -d "${destination}" && ! -L "${destination}" && "$(stat_uid "${destination}")" == "$(id -u)" ]] || return 30
  chmod 700 "${destination}"
  if [[ "${RELAY_COHOSTS_SINGBOX}" == no ]]; then
    for output in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
      printf 'none\n' > "${destination}/${output}"
      chmod 600 "${destination}/${output}"
    done
    RELAY_BASELINE_SERVICE_ACTIVE='none'
    RELAY_BASELINE_SERVICE_ENABLED='none'
    return 0
  fi
  script="${OP_TMP}/collect-baseline.sh"
  cat > "${script}" <<'COLLECT_BASELINE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
# 被保护的既有单元由本机按 RELAY_COHOSTS_SINGBOX 传入（yes→sing-box.service，ownexit-direct→ownexit-direct.service）；
# 输出只取决于 systemctl、/proc、ss 的结果，yes 时与旧版逐字相同，已部署链的基线不会误报漂移。
unit="$1"

metadata() {
  local path type hash mode
  path="$1"
  [[ ! -L "$path" ]] || exit 31
  if [[ -f "$path" ]]; then
    type=file
    hash="$(sha256sum "$path" | awk '{print $1}')"
  elif [[ -d "$path" ]]; then
    type=directory
    hash=-
  else
    exit 32
  fi
  mode="$(stat -c %a "$path")"
  (( (8#$mode & 8#022) == 0 )) || exit 35
  printf '%s|%s|%s|%s|%s|%s\n' "$path" "$type" "$(stat -c %u "$path")" "$(stat -c %g "$path")" "$mode" "$hash"
}

secure_path_ancestors() {
  local current mode
  current="$1"
  while :; do
    [[ ! -L "$current" ]] || return 1
    mode="$(stat -c %a "$current")" || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ "$current" == / ]] && break
    current="$(dirname "$current")"
  done
}

normalize_runtime_path() {
  local raw cwd candidate resolved
  raw="$1"
  cwd="$2"
  [[ -n "$raw" && "$raw" != stdin && "$raw" != *'|'* && "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  if [[ "$raw" == /* ]]; then
    candidate="$raw"
  else
    candidate="$cwd/$raw"
  fi
  secure_path_ancestors "$candidate" || return 1
  resolved="$(readlink -f -- "$candidate")" || return 1
  [[ "$resolved" == /* ]] || return 1
  secure_path_ancestors "$resolved" || return 1
  printf '%s\n' "$resolved"
}

pid="$(systemctl show "$unit" -p MainPID --value)"
[[ "$pid" =~ ^[1-9][0-9]*$ && -d "/proc/$pid" ]] || exit 33
exe="$(readlink -f "/proc/$pid/exe")"
[[ -f "$exe" && ! -L "$exe" ]] || exit 34
cwd="$(readlink -f "/proc/$pid/cwd")"
[[ -d "$cwd" && "$cwd" == /* && "$cwd" != *'|'* && "$cwd" != *$'\n'* && "$cwd" != *$'\r'* ]] || exit 37
secure_path_ancestors "$cwd" || exit 38

# 以存活 MainPID 的 argv/cwd 为权威源确定实际读取的配置；仅扫描固定目录会漏掉 unit
# 改指到其它配置的漂移。sing-box 1.13.14 未显式传 -c/-C 时读取 cwd/config.json。
config_files=()
config_directories=()
pending=''
while IFS= read -r -d '' argument; do
  if [[ -n "$pending" ]]; then
    if [[ "$pending" == file ]]; then
      config_files+=("$argument")
    else
      config_directories+=("$argument")
    fi
    pending=''
    continue
  fi
  case "$argument" in
    -c|--config) pending=file ;;
    -C|--config-directory) pending=directory ;;
    -c=*|--config=*) config_files+=("${argument#*=}") ;;
    -C=*|--config-directory=*) config_directories+=("${argument#*=}") ;;
    -c?*) config_files+=("${argument#-c}") ;;
    -C?*) config_directories+=("${argument#-C}") ;;
  esac
done < "/proc/$pid/cmdline"
[[ -z "$pending" ]] || exit 39
if (( ${#config_files[@]} == 0 && ${#config_directories[@]} == 0 )); then
  config_files+=(config.json)
fi

resolved_config_files=()
for item in "${config_files[@]}"; do
  resolved="$(normalize_runtime_path "$item" "$cwd")" || exit 40
  [[ -f "$resolved" && ! -L "$resolved" ]] || exit 41
  resolved_config_files+=("$resolved")
done
resolved_config_directories=()
for item in "${config_directories[@]}"; do
  resolved="$(normalize_runtime_path "$item" "$cwd")" || exit 42
  [[ -d "$resolved" && ! -L "$resolved" ]] || exit 43
  [[ -z "$(find "$resolved" -maxdepth 1 -type l -name '*.json' -print -quit)" ]] || exit 44
  resolved_config_directories+=("$resolved")
done

printf '%s\n' '__CONFIG__'
{
  for item in "${resolved_config_files[@]}"; do
    printf 'RUNTIME_CONFIG_FILE=%s\n' "$item"
    metadata "$item"
  done
  for item in "${resolved_config_directories[@]}"; do
    printf 'RUNTIME_CONFIG_DIRECTORY=%s\n' "$item"
    metadata "$item"
    find "$item" -maxdepth 1 -type f -name '*.json' -print | sort | while IFS= read -r config_item; do
      secure_path_ancestors "$config_item" || exit 45
      metadata "$config_item"
    done
  done
} | sort -u

printf '%s\n' '__UNIT__'
{
  printf 'MAINPID_CMDLINE_SHA256=%s\n' "$(sha256sum "/proc/$pid/cmdline" | awk '{print $1}')"
  printf 'MAINPID_CWD=%s\n' "$cwd"
  printf 'EXECSTART_SHA256=%s\n' "$(systemctl show "$unit" -p ExecStart --value | sha256sum | awk '{print $1}')"
  fragment="$(systemctl show "$unit" -p FragmentPath --value)"
  [[ -n "$fragment" ]] && metadata "$fragment"
  systemctl show "$unit" -p DropInPaths --value | tr ' ' '\n' | sed '/^$/d' | while IFS= read -r item; do metadata "$item"; done
} | sort

printf '%s\n' '__BINARY__'
current="$exe"
while :; do
  metadata "$current"
  [[ "$current" == / ]] && break
  current="$(dirname "$current")"
done
uid="$(stat -c %u "$exe")"
gid="$(stat -c %g "$exe")"
if getent passwd "$uid" >/dev/null; then uid_map=yes; else uid_map=no; fi
if getent group "$gid" >/dev/null; then gid_map=yes; else gid_map=no; fi
printf 'UID_MAPPED=%s\nGID_MAPPED=%s\n' "$uid_map" "$gid_map"

printf '%s\n' '__LISTENERS__'
{
  ss -H -ltnup 2>/dev/null | awk -v pid="$pid" 'index($0, "pid=" pid ",") {print}' \
    | sed -E 's/pid=[0-9]+,//g; s/fd=[0-9]+//g; s/ino:[0-9]+//g; s/[[:space:]][[:space:]]*/ /g'
} | sort
printf '%s\n' '__STATUS__'
printf 'ACTIVE=%s\n' "$(systemctl is-active "$unit")"
printf 'ENABLED=%s\n' "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
COLLECT_BASELINE
  chmod 600 "${script}"
  if output="$(ssh_relay_stdin bash -s -- "$(cohost_unit_of "${RELAY_COHOSTS_SINGBOX}")" < "${script}")"; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || { [[ "${rc}" -eq 255 ]] && return 21; return 31; }
  printf '%s\n' "${output}" | awk '/^__CONFIG__$/ {on=1; next} /^__UNIT__$/ {on=0} on' > "${destination}/relay-config-manifest.txt"
  printf '%s\n' "${output}" | awk '/^__UNIT__$/ {on=1; next} /^__BINARY__$/ {on=0} on' > "${destination}/relay-unit-manifest.txt"
  printf '%s\n' "${output}" | awk '/^__BINARY__$/ {on=1; next} /^__LISTENERS__$/ {on=0} on' > "${destination}/relay-binary-manifest.txt"
  printf '%s\n' "${output}" | awk '/^__LISTENERS__$/ {on=1; next} /^__STATUS__$/ {on=0} on' > "${destination}/relay-listeners.txt"
  active="$(printf '%s\n' "${output}" | awk -F= '$1 == "ACTIVE" {print $2}')"
  enabled="$(printf '%s\n' "${output}" | awk -F= '$1 == "ENABLED" {print $2}')"
  [[ "${active}" == active && -n "${enabled}" ]] || return 32
  RELAY_BASELINE_SERVICE_ACTIVE="${active}"
  RELAY_BASELINE_SERVICE_ENABLED="${enabled}"
  for output in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
    [[ -s "${destination}/${output}" ]] || return 33
    chmod 600 "${destination}/${output}"
  done
}

collect_relay_baseline() {
  local rc
  if probe_collect_relay_baseline "$1"; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) return 0 ;;
    21) die 3 '既有 sing-box 零回归基线采集时中转 SSH 不可达' ;;
    31) die 3 '既有 sing-box 实际运行配置、unit、binary 或 listener 基线采集失败' ;;
    *) die 3 '既有 sing-box 零回归基线不完整或本地暂存异常' ;;
  esac
}

RELAY_PORT='ABSENT'
EXIT_REALITY_PORT='ABSENT'
VLESS_UUID='ABSENT'
REALITY_PUBLIC_KEY='ABSENT'
REALITY_SHORT_ID='ABSENT'
RELAY_OWNER_SHA256='ABSENT'
RELAY_SOCKET_SHA256='ABSENT'
RELAY_SERVICE_SHA256='ABSENT'
RELAY_ENABLE_LINK_TARGET='../ownexit-chain-relay-placeholder.socket'
RELAY_ENABLE_LINK_SHA256='ABSENT'
EXIT_OWNER_SHA256='ABSENT'
EXIT_EXIT_SHA256='ABSENT'
EXIT_SERVICE_SHA256='ABSENT'
EXIT_ENABLE_LINK_TARGET='../ownexit-chain-exit-placeholder.service'
EXIT_ENABLE_LINK_SHA256='ABSENT'
RELAY_BASELINE_CONFIG_MANIFEST_SHA256='ABSENT'
RELAY_BASELINE_LISTEN_SHA256='ABSENT'
RELAY_BASELINE_BINARY_MANIFEST_SHA256='ABSENT'
RELAY_BASELINE_UNIT_MANIFEST_SHA256='ABSENT'
RELAY_BASELINE_SERVICE_ACTIVE='ABSENT'
RELAY_BASELINE_SERVICE_ENABLED='ABSENT'
NODE_SHA256='ABSENT'
CREATED_AT=''
UPDATED_AT=''
LAST_COMPLETED_STEP='PREPARED'
JOURNAL_OPERATION='deploy'
TARGET_STATE='deployed'
LOCAL_STAGE_PATH='ABSENT'
LOCAL_STAGE_OWNER_SHA256='ABSENT'
RELAY_STAGE_PATH='ABSENT'
EXIT_STAGE_PATH='ABSENT'
RELAY_BINARY_STAGE_PATH='ABSENT'
EXIT_BINARY_STAGE_PATH='ABSENT'
RELAY_STAGE_OWNER_TEMP_PATH='ABSENT'
EXIT_STAGE_OWNER_TEMP_PATH='ABSENT'
RELAY_BINARY_STAGE_OWNER_TEMP_PATH='ABSENT'
EXIT_BINARY_STAGE_OWNER_TEMP_PATH='ABSENT'
RELAY_STAGE_OWNER_SHA256='ABSENT'
EXIT_STAGE_OWNER_SHA256='ABSENT'
RELAY_BINARY_STAGE_OWNER_SHA256='ABSENT'
EXIT_BINARY_STAGE_OWNER_SHA256='ABSENT'

state_key_list() {
  cat <<'STATE_KEYS'
SCHEMA_VERSION
STATUS
CHAIN_ID
DEPLOYMENT_ID
CONFIG_SHA256
RELAY_HOST
RELAY_SSH_PORT
RELAY_SSH_USER
RELAY_HOSTKEY_FINGERPRINT
RELAY_SSH_KEY_PATH
RELAY_SSH_KEY_FINGERPRINT
EXIT_HOST
EXIT_SSH_PORT
EXIT_SSH_USER
EXIT_HOSTKEY_FINGERPRINT
EXIT_SSH_KEY_PATH
EXIT_SSH_KEY_FINGERPRINT
EXPECTED_EXIT_IPV4
REALITY_SERVER_NAME
RELAY_COHOSTS_SINGBOX
RELAY_PORT
EXIT_REALITY_PORT
SING_BOX_VERSION
LINUX_ARCHIVE_SHA256
LINUX_BINARY_SHA256
DARWIN_ARCHIVE_SHA256
DARWIN_BINARY_SHA256
VLESS_UUID
REALITY_PUBLIC_KEY
REALITY_SHORT_ID
RELAY_OWNER_SHA256
RELAY_SOCKET_SHA256
RELAY_SERVICE_SHA256
RELAY_ENABLE_LINK_TARGET
RELAY_ENABLE_LINK_SHA256
EXIT_OWNER_SHA256
EXIT_EXIT_SHA256
EXIT_SERVICE_SHA256
EXIT_ENABLE_LINK_TARGET
EXIT_ENABLE_LINK_SHA256
RELAY_BASELINE_CONFIG_MANIFEST_SHA256
RELAY_BASELINE_LISTEN_SHA256
RELAY_BASELINE_BINARY_MANIFEST_SHA256
RELAY_BASELINE_UNIT_MANIFEST_SHA256
RELAY_BASELINE_SERVICE_ACTIVE
RELAY_BASELINE_SERVICE_ENABLED
NODE_SHA256
CREATED_AT
PAYLOAD_SHA256
STATE_KEYS
}

journal_key_list() {
  cat <<'JOURNAL_KEYS'
SCHEMA_VERSION
STATUS
OPERATION
OPERATION_ID
TARGET_STATE
LAST_COMPLETED_STEP
CHAIN_ID
DEPLOYMENT_ID
CONFIG_SHA256
RELAY_HOST
RELAY_SSH_PORT
RELAY_SSH_USER
RELAY_HOSTKEY_FINGERPRINT
RELAY_SSH_KEY_PATH
RELAY_SSH_KEY_FINGERPRINT
EXIT_HOST
EXIT_SSH_PORT
EXIT_SSH_USER
EXIT_HOSTKEY_FINGERPRINT
EXIT_SSH_KEY_PATH
EXIT_SSH_KEY_FINGERPRINT
EXPECTED_EXIT_IPV4
REALITY_SERVER_NAME
RELAY_COHOSTS_SINGBOX
RELAY_PORT
EXIT_REALITY_PORT
SING_BOX_VERSION
LINUX_ARCHIVE_SHA256
LINUX_BINARY_SHA256
DARWIN_ARCHIVE_SHA256
DARWIN_BINARY_SHA256
VLESS_UUID
REALITY_PUBLIC_KEY
REALITY_SHORT_ID
RELAY_OWNER_SHA256
RELAY_SOCKET_SHA256
RELAY_SERVICE_SHA256
RELAY_ENABLE_LINK_TARGET
RELAY_ENABLE_LINK_SHA256
EXIT_OWNER_SHA256
EXIT_EXIT_SHA256
EXIT_SERVICE_SHA256
EXIT_ENABLE_LINK_TARGET
EXIT_ENABLE_LINK_SHA256
RELAY_BASELINE_CONFIG_MANIFEST_SHA256
RELAY_BASELINE_LISTEN_SHA256
RELAY_BASELINE_BINARY_MANIFEST_SHA256
RELAY_BASELINE_UNIT_MANIFEST_SHA256
RELAY_BASELINE_SERVICE_ACTIVE
RELAY_BASELINE_SERVICE_ENABLED
NODE_SHA256
LOCAL_STAGE_PATH
LOCAL_STAGE_OWNER_SHA256
RELAY_STAGE_PATH
EXIT_STAGE_PATH
RELAY_BINARY_STAGE_PATH
EXIT_BINARY_STAGE_PATH
RELAY_STAGE_OWNER_TEMP_PATH
EXIT_STAGE_OWNER_TEMP_PATH
RELAY_BINARY_STAGE_OWNER_TEMP_PATH
EXIT_BINARY_STAGE_OWNER_TEMP_PATH
RELAY_STAGE_OWNER_SHA256
EXIT_STAGE_OWNER_SHA256
RELAY_BINARY_STAGE_OWNER_SHA256
EXIT_BINARY_STAGE_OWNER_SHA256
UPDATED_AT
PAYLOAD_SHA256
JOURNAL_KEYS
}

validate_checksum_env() {
  local file schema expected_keys actual_keys last_key expected_hash payload_file actual_hash
  file="$1"
  schema="$2"
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  require_secure_user_file "${file}" 600 || return 1
  if [[ "${schema}" == state ]]; then
    expected_keys="$(state_key_list)"
  else
    expected_keys="$(journal_key_list)"
  fi
  actual_keys="$(awk -F= 'NF >= 2 {print $1}' "${file}")"
  [[ "${actual_keys}" == "${expected_keys}" ]] || return 1
  # 注意：必须用带引号的 [[ -z "$(...)" ]]。未加引号的 [[ ! $(...) ]] 在命令替换为空时
  # 会塌缩成 [[ ! ]]（缺操作数），在 set -euo pipefail 下求值失败，导致每次校验误判损坏。
  [[ -z "$(grep -nEv '^[A-Z][A-Z0-9_]*=[A-Za-z0-9._/@+,=:~-]+$' "${file}" || true)" ]] || return 1
  last_key="$(tail -n 1 "${file}" | cut -d= -f1)"
  [[ "${last_key}" == PAYLOAD_SHA256 ]] || return 1
  expected_hash="$(tail -n 1 "${file}" | cut -d= -f2-)"
  [[ "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  payload_file="${OP_TMP}/payload-check.$$.tmp"
  sed '$d' "${file}" > "${payload_file}"
  actual_hash="$(sha256_file "${payload_file}")"
  rm -f "${payload_file}"
  [[ "${actual_hash}" == "${expected_hash}" ]]
}

emit_common_state_fields() {
  printf 'CHAIN_ID=%s\n' "${CHAIN_ID}"
  printf 'DEPLOYMENT_ID=%s\n' "${DEPLOYMENT_ID}"
  printf 'CONFIG_SHA256=%s\n' "${CONFIG_SHA256}"
  printf 'RELAY_HOST=%s\n' "${RELAY_HOST}"
  printf 'RELAY_SSH_PORT=%s\n' "${RELAY_SSH_PORT}"
  printf 'RELAY_SSH_USER=%s\n' "${RELAY_SSH_USER}"
  printf 'RELAY_HOSTKEY_FINGERPRINT=%s\n' "${RELAY_HOSTKEY_FINGERPRINT}"
  printf 'RELAY_SSH_KEY_PATH=%s\n' "${RELAY_SSH_KEY}"
  printf 'RELAY_SSH_KEY_FINGERPRINT=%s\n' "${RELAY_SSH_KEY_FINGERPRINT}"
  printf 'EXIT_HOST=%s\n' "${EXIT_HOST}"
  printf 'EXIT_SSH_PORT=%s\n' "${EXIT_SSH_PORT}"
  printf 'EXIT_SSH_USER=%s\n' "${EXIT_SSH_USER}"
  printf 'EXIT_HOSTKEY_FINGERPRINT=%s\n' "${EXIT_HOSTKEY_FINGERPRINT}"
  printf 'EXIT_SSH_KEY_PATH=%s\n' "${EXIT_SSH_KEY}"
  printf 'EXIT_SSH_KEY_FINGERPRINT=%s\n' "${EXIT_SSH_KEY_FINGERPRINT}"
  printf 'EXPECTED_EXIT_IPV4=%s\n' "${EXPECTED_EXIT_IPV4}"
  printf 'REALITY_SERVER_NAME=%s\n' "${REALITY_SERVER_NAME}"
  printf 'RELAY_COHOSTS_SINGBOX=%s\n' "${RELAY_COHOSTS_SINGBOX}"
  printf 'RELAY_PORT=%s\n' "${RELAY_PORT}"
  printf 'EXIT_REALITY_PORT=%s\n' "${EXIT_REALITY_PORT}"
  printf 'SING_BOX_VERSION=%s\n' "${SING_BOX_VERSION}"
  printf 'LINUX_ARCHIVE_SHA256=%s\n' "${LINUX_ARCHIVE_SHA256}"
  printf 'LINUX_BINARY_SHA256=%s\n' "${LINUX_BINARY_SHA256}"
  printf 'DARWIN_ARCHIVE_SHA256=%s\n' "${DARWIN_ARCHIVE_SHA256}"
  printf 'DARWIN_BINARY_SHA256=%s\n' "${DARWIN_BINARY_SHA256}"
  printf 'VLESS_UUID=%s\n' "${VLESS_UUID}"
  printf 'REALITY_PUBLIC_KEY=%s\n' "${REALITY_PUBLIC_KEY}"
  printf 'REALITY_SHORT_ID=%s\n' "${REALITY_SHORT_ID}"
  printf 'RELAY_OWNER_SHA256=%s\n' "${RELAY_OWNER_SHA256}"
  printf 'RELAY_SOCKET_SHA256=%s\n' "${RELAY_SOCKET_SHA256}"
  printf 'RELAY_SERVICE_SHA256=%s\n' "${RELAY_SERVICE_SHA256}"
  printf 'RELAY_ENABLE_LINK_TARGET=%s\n' "${RELAY_ENABLE_LINK_TARGET}"
  printf 'RELAY_ENABLE_LINK_SHA256=%s\n' "${RELAY_ENABLE_LINK_SHA256}"
  printf 'EXIT_OWNER_SHA256=%s\n' "${EXIT_OWNER_SHA256}"
  printf 'EXIT_EXIT_SHA256=%s\n' "${EXIT_EXIT_SHA256}"
  printf 'EXIT_SERVICE_SHA256=%s\n' "${EXIT_SERVICE_SHA256}"
  printf 'EXIT_ENABLE_LINK_TARGET=%s\n' "${EXIT_ENABLE_LINK_TARGET}"
  printf 'EXIT_ENABLE_LINK_SHA256=%s\n' "${EXIT_ENABLE_LINK_SHA256}"
  printf 'RELAY_BASELINE_CONFIG_MANIFEST_SHA256=%s\n' "${RELAY_BASELINE_CONFIG_MANIFEST_SHA256}"
  printf 'RELAY_BASELINE_LISTEN_SHA256=%s\n' "${RELAY_BASELINE_LISTEN_SHA256}"
  printf 'RELAY_BASELINE_BINARY_MANIFEST_SHA256=%s\n' "${RELAY_BASELINE_BINARY_MANIFEST_SHA256}"
  printf 'RELAY_BASELINE_UNIT_MANIFEST_SHA256=%s\n' "${RELAY_BASELINE_UNIT_MANIFEST_SHA256}"
  printf 'RELAY_BASELINE_SERVICE_ACTIVE=%s\n' "${RELAY_BASELINE_SERVICE_ACTIVE}"
  printf 'RELAY_BASELINE_SERVICE_ENABLED=%s\n' "${RELAY_BASELINE_SERVICE_ENABLED}"
  printf 'NODE_SHA256=%s\n' "${NODE_SHA256}"
}

write_checksummed_file() {
  local final mode payload temp hash parent
  final="$1"
  mode="$2"
  payload="$3"
  parent="$(dirname "${final}")"
  ensure_private_dir "${parent}" || die 1 "状态父目录身份或权限不安全：${parent}"
  # 事务 OPERATION_ID 会跨进程恢复；临时提交名必须绑定当前控制进程，避免断电残留把恢复永久卡住。
  temp="${parent}/.$(basename "${final}").${LOCK_OPERATION_ID}.tmp"
  ( set -o noclobber; : > "${temp}" ) 2>/dev/null || die 1 "无法排他创建状态临时文件：${final}"
  cp "${payload}" "${temp}" || die 1 "无法写入状态临时文件：${final}"
  hash="$(sha256_file "${temp}")" || die 1 "无法计算状态 payload 摘要：${final}"
  printf 'PAYLOAD_SHA256=%s\n' "${hash}" >> "${temp}" || die 1 "无法写入状态 checksum：${final}"
  chmod 600 "${temp}" || die 1 "无法设置状态临时文件权限：${final}"
  sync || die 1 "状态临时文件持久化失败：${final}"
  if [[ "${mode}" == new ]]; then
    link "${temp}" "${final}" || die 1 "状态 no-replace 发布冲突：${final}"
    rm -f "${temp}" || die 1 "状态发布后临时文件删除失败：${final}"
  else
    [[ -f "${final}" && ! -L "${final}" ]] || die 1 "拒绝替换非本方案状态：${final}"
    mv -f "${temp}" "${final}" || die 1 "状态原子替换失败：${final}"
  fi
  sync || die 1 "状态提交持久化失败：${final}"
}

render_state_payload() {
  local output
  output="$1"
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'STATUS=deployed\n'
    emit_common_state_fields
    printf 'CREATED_AT=%s\n' "${CREATED_AT}"
  } > "${output}"
}

render_journal_payload() {
  local output
  output="$1"
  UPDATED_AT="$(now_rfc3339)"
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'STATUS=active\n'
    printf 'OPERATION=%s\n' "${JOURNAL_OPERATION}"
    printf 'OPERATION_ID=%s\n' "${OPERATION_ID}"
    printf 'TARGET_STATE=%s\n' "${TARGET_STATE}"
    printf 'LAST_COMPLETED_STEP=%s\n' "${LAST_COMPLETED_STEP}"
    emit_common_state_fields
    printf 'LOCAL_STAGE_PATH=%s\n' "${LOCAL_STAGE_PATH}"
    printf 'LOCAL_STAGE_OWNER_SHA256=%s\n' "${LOCAL_STAGE_OWNER_SHA256}"
    printf 'RELAY_STAGE_PATH=%s\n' "${RELAY_STAGE_PATH}"
    printf 'EXIT_STAGE_PATH=%s\n' "${EXIT_STAGE_PATH}"
    printf 'RELAY_BINARY_STAGE_PATH=%s\n' "${RELAY_BINARY_STAGE_PATH}"
    printf 'EXIT_BINARY_STAGE_PATH=%s\n' "${EXIT_BINARY_STAGE_PATH}"
    printf 'RELAY_STAGE_OWNER_TEMP_PATH=%s\n' "${RELAY_STAGE_OWNER_TEMP_PATH}"
    printf 'EXIT_STAGE_OWNER_TEMP_PATH=%s\n' "${EXIT_STAGE_OWNER_TEMP_PATH}"
    printf 'RELAY_BINARY_STAGE_OWNER_TEMP_PATH=%s\n' "${RELAY_BINARY_STAGE_OWNER_TEMP_PATH}"
    printf 'EXIT_BINARY_STAGE_OWNER_TEMP_PATH=%s\n' "${EXIT_BINARY_STAGE_OWNER_TEMP_PATH}"
    printf 'RELAY_STAGE_OWNER_SHA256=%s\n' "${RELAY_STAGE_OWNER_SHA256}"
    printf 'EXIT_STAGE_OWNER_SHA256=%s\n' "${EXIT_STAGE_OWNER_SHA256}"
    printf 'RELAY_BINARY_STAGE_OWNER_SHA256=%s\n' "${RELAY_BINARY_STAGE_OWNER_SHA256}"
    printf 'EXIT_BINARY_STAGE_OWNER_SHA256=%s\n' "${EXIT_BINARY_STAGE_OWNER_SHA256}"
    printf 'UPDATED_AT=%s\n' "${UPDATED_AT}"
  } > "${output}"
}

# 测试钩子：deploy / up 在指定事务步骤写入之后以退出码 99 结束，用于中断恢复用例；正常使用不要设置。
# 只对 deploy / up 生效：rollback 事务也走 write_journal，不能被同一个变量误停。
deploy_test_stop() {
  [[ "${COMMAND}" == deploy || "${COMMAND}" == up ]] || return 0
  [[ -n "${OWNEXIT_TEST_DEPLOY_STOP_AFTER:-}" && "${OWNEXIT_TEST_DEPLOY_STOP_AFTER}" == "${LAST_COMPLETED_STEP}" ]] || return 0
  log_warn "测试钩子：deploy 在 ${LAST_COMPLETED_STEP} 之后停止"
  exit 99
}

write_journal() {
  local payload mode
  payload="${OP_TMP}/journal-payload"
  render_journal_payload "${payload}" || die 1 'transaction payload 生成失败'
  if [[ -e "${JOURNAL_FILE}" || -L "${JOURNAL_FILE}" ]]; then
    validate_checksum_env "${JOURNAL_FILE}" journal || die 1 '活动 transaction 损坏，拒绝替换'
    mode=replace
  else
    mode=new
  fi
  write_checksummed_file "${JOURNAL_FILE}" "${mode}" "${payload}" || die 1 'transaction 提交失败'
  validate_checksum_env "${JOURNAL_FILE}" journal || die 1 'transaction 写入后校验失败'
  deploy_test_stop
}

write_active_state() {
  local payload
  payload="${OP_TMP}/state-payload"
  CREATED_AT="$(now_rfc3339)"
  render_state_payload "${payload}" || die 1 'active state payload 生成失败'
  [[ ! -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 1 'active state 已存在，拒绝覆盖'
  write_checksummed_file "${STATE_FILE}" new "${payload}" || die 1 'active state 提交失败'
  validate_checksum_env "${STATE_FILE}" state || die 1 'active state 写入后校验失败'
}

# 采纳状态 / 事务记录里的资产哈希：远端归档哈希决定远端架构（并锁定，现场预检必须一致），
# 本机归档哈希只要是 4 个本机包之一或 NONE 即可。binary 哈希必须与归档配套。v0.1.0 写下的
# linux-amd64 + darwin-arm64 组合天然满足，所以旧状态无需迁移。不合法返回 1。
adopt_recorded_assets() {
  local linux_archive linux_binary darwin_archive darwin_binary platform
  linux_archive="$1"
  linux_binary="$2"
  darwin_archive="$3"
  darwin_binary="$4"
  case "${linux_archive}" in
    "${ARCHIVE_SHA256_LINUX_AMD64}") select_remote_arch amd64 ;;
    "${ARCHIVE_SHA256_LINUX_ARM64}") select_remote_arch arm64 ;;
    *) return 1 ;;
  esac
  [[ "${linux_binary}" == "${LINUX_BINARY_SHA256}" ]] || return 1
  REMOTE_ARCH_LOCKED=1
  if [[ "${darwin_archive}" == NONE ]]; then
    [[ "${darwin_binary}" == NONE ]] || return 1
  else
    platform="$(platform_of_archive_sha256 "${darwin_archive}")" || return 1
    [[ "${darwin_binary}" == "$(binary_sha256_of_platform "${platform}")" ]] || return 1
  fi
  DARWIN_ARCHIVE_SHA256="${darwin_archive}"
  DARWIN_BINARY_SHA256="${darwin_binary}"
}

probe_state_file() {
  local file value
  file="$1"
  STATE_PROBE_REASON='state-corrupt'
  validate_checksum_env "${file}" state || return 10
  [[ "$(kv_get "${file}" SCHEMA_VERSION)" == 1 && "$(kv_get "${file}" STATUS)" == deployed ]] || return 11
  STATE_PROBE_REASON='state-config-binding'
  [[ "$(kv_get "${file}" CHAIN_ID)" == "${CHAIN_ID}" ]] || return 12
  [[ "$(kv_get "${file}" CONFIG_SHA256)" == "${CONFIG_SHA256}" ]] || return 12
  [[ "$(kv_get "${file}" RELAY_HOST)" == "${RELAY_HOST}" ]] || return 12
  [[ "$(kv_get "${file}" RELAY_SSH_PORT)" == "${RELAY_SSH_PORT}" ]] || return 12
  [[ "$(kv_get "${file}" RELAY_SSH_USER)" == "${RELAY_SSH_USER}" ]] || return 12
  [[ "$(kv_get "${file}" RELAY_SSH_KEY_PATH)" == "${RELAY_SSH_KEY}" ]] || return 12
  [[ "$(kv_get "${file}" EXIT_HOST)" == "${EXIT_HOST}" ]] || return 12
  [[ "$(kv_get "${file}" EXIT_SSH_PORT)" == "${EXIT_SSH_PORT}" ]] || return 12
  [[ "$(kv_get "${file}" EXIT_SSH_USER)" == "${EXIT_SSH_USER}" ]] || return 12
  [[ "$(kv_get "${file}" EXIT_SSH_KEY_PATH)" == "${EXIT_SSH_KEY}" ]] || return 12
  [[ "$(kv_get "${file}" EXPECTED_EXIT_IPV4)" == "${EXPECTED_EXIT_IPV4}" ]] || return 12
  [[ "$(kv_get "${file}" REALITY_SERVER_NAME)" == "${REALITY_SERVER_NAME}" ]] || return 12
  [[ "$(kv_get "${file}" RELAY_COHOSTS_SINGBOX)" == "${RELAY_COHOSTS_SINGBOX}" ]] || return 12
  [[ "$(kv_get "${file}" SING_BOX_VERSION)" == "${SING_BOX_VERSION}" ]] || return 12
  adopt_recorded_assets "$(kv_get "${file}" LINUX_ARCHIVE_SHA256)" "$(kv_get "${file}" LINUX_BINARY_SHA256)" "$(kv_get "${file}" DARWIN_ARCHIVE_SHA256)" "$(kv_get "${file}" DARWIN_BINARY_SHA256)" || return 12

  DEPLOYMENT_ID="$(kv_get "${file}" DEPLOYMENT_ID)"
  RELAY_HOSTKEY_FINGERPRINT="$(kv_get "${file}" RELAY_HOSTKEY_FINGERPRINT)"
  RELAY_SSH_KEY_FINGERPRINT="$(kv_get "${file}" RELAY_SSH_KEY_FINGERPRINT)"
  EXIT_HOSTKEY_FINGERPRINT="$(kv_get "${file}" EXIT_HOSTKEY_FINGERPRINT)"
  EXIT_SSH_KEY_FINGERPRINT="$(kv_get "${file}" EXIT_SSH_KEY_FINGERPRINT)"
  RELAY_PORT="$(kv_get "${file}" RELAY_PORT)"
  EXIT_REALITY_PORT="$(kv_get "${file}" EXIT_REALITY_PORT)"
  LINUX_BINARY_SHA256="$(kv_get "${file}" LINUX_BINARY_SHA256)"
  DARWIN_BINARY_SHA256="$(kv_get "${file}" DARWIN_BINARY_SHA256)"
  VLESS_UUID="$(kv_get "${file}" VLESS_UUID)"
  REALITY_PUBLIC_KEY="$(kv_get "${file}" REALITY_PUBLIC_KEY)"
  REALITY_SHORT_ID="$(kv_get "${file}" REALITY_SHORT_ID)"
  RELAY_OWNER_SHA256="$(kv_get "${file}" RELAY_OWNER_SHA256)"
  RELAY_SOCKET_SHA256="$(kv_get "${file}" RELAY_SOCKET_SHA256)"
  RELAY_SERVICE_SHA256="$(kv_get "${file}" RELAY_SERVICE_SHA256)"
  RELAY_ENABLE_LINK_TARGET="$(kv_get "${file}" RELAY_ENABLE_LINK_TARGET)"
  RELAY_ENABLE_LINK_SHA256="$(kv_get "${file}" RELAY_ENABLE_LINK_SHA256)"
  EXIT_OWNER_SHA256="$(kv_get "${file}" EXIT_OWNER_SHA256)"
  EXIT_EXIT_SHA256="$(kv_get "${file}" EXIT_EXIT_SHA256)"
  EXIT_SERVICE_SHA256="$(kv_get "${file}" EXIT_SERVICE_SHA256)"
  EXIT_ENABLE_LINK_TARGET="$(kv_get "${file}" EXIT_ENABLE_LINK_TARGET)"
  EXIT_ENABLE_LINK_SHA256="$(kv_get "${file}" EXIT_ENABLE_LINK_SHA256)"
  RELAY_BASELINE_CONFIG_MANIFEST_SHA256="$(kv_get "${file}" RELAY_BASELINE_CONFIG_MANIFEST_SHA256)"
  RELAY_BASELINE_LISTEN_SHA256="$(kv_get "${file}" RELAY_BASELINE_LISTEN_SHA256)"
  RELAY_BASELINE_BINARY_MANIFEST_SHA256="$(kv_get "${file}" RELAY_BASELINE_BINARY_MANIFEST_SHA256)"
  RELAY_BASELINE_UNIT_MANIFEST_SHA256="$(kv_get "${file}" RELAY_BASELINE_UNIT_MANIFEST_SHA256)"
  RELAY_BASELINE_SERVICE_ACTIVE="$(kv_get "${file}" RELAY_BASELINE_SERVICE_ACTIVE)"
  RELAY_BASELINE_SERVICE_ENABLED="$(kv_get "${file}" RELAY_BASELINE_SERVICE_ENABLED)"
  NODE_SHA256="$(kv_get "${file}" NODE_SHA256)"
  CREATED_AT="$(kv_get "${file}" CREATED_AT)"

  STATE_PROBE_REASON='state-value-format'
  [[ "${DEPLOYMENT_ID}" =~ ^[0-9a-f]{32}$ ]] || return 13
  [[ "${RELAY_PORT}" =~ ^[1-9][0-9]*$ && "${EXIT_REALITY_PORT}" =~ ^[1-9][0-9]*$ ]] || return 13
  (( RELAY_PORT >= 1 && RELAY_PORT <= 65535 && EXIT_REALITY_PORT >= 1 && EXIT_REALITY_PORT <= 65535 )) || return 13
  [[ "${VLESS_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 13
  [[ "${REALITY_PUBLIC_KEY}" =~ ^[A-Za-z0-9_-]+$ && "${REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || return 13
  for value in "${LINUX_BINARY_SHA256}" "${RELAY_OWNER_SHA256}" "${RELAY_SOCKET_SHA256}" "${RELAY_SERVICE_SHA256}" "${RELAY_ENABLE_LINK_SHA256}" "${EXIT_OWNER_SHA256}" "${EXIT_EXIT_SHA256}" "${EXIT_SERVICE_SHA256}" "${EXIT_ENABLE_LINK_SHA256}" "${RELAY_BASELINE_CONFIG_MANIFEST_SHA256}" "${RELAY_BASELINE_LISTEN_SHA256}" "${RELAY_BASELINE_BINARY_MANIFEST_SHA256}" "${RELAY_BASELINE_UNIT_MANIFEST_SHA256}" "${NODE_SHA256}"; do
    [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || return 13
  done
  STATE_PROBE_REASON=''
}

load_state_file() {
  local rc
  if probe_state_file "$1"; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || die 5 "state.env 校验失败：${STATE_PROBE_REASON}"
}

load_journal_file() {
  local file value key expected
  file="$1"
  validate_checksum_env "${file}" journal || die 5 'transaction.env schema、权限或 checksum 损坏'
  [[ "$(kv_get "${file}" SCHEMA_VERSION)" == 1 && "$(kv_get "${file}" STATUS)" == active ]] || die 5 'transaction 版本或状态错误'
  [[ "$(kv_get "${file}" CHAIN_ID)" == "${CHAIN_ID}" && "$(kv_get "${file}" CONFIG_SHA256)" == "${CONFIG_SHA256}" ]] || die 5 'transaction 与当前 chain/config 不绑定'
  JOURNAL_OPERATION="$(kv_get "${file}" OPERATION)"
  OPERATION_ID="$(kv_get "${file}" OPERATION_ID)"
  TARGET_STATE="$(kv_get "${file}" TARGET_STATE)"
  LAST_COMPLETED_STEP="$(kv_get "${file}" LAST_COMPLETED_STEP)"
  DEPLOYMENT_ID="$(kv_get "${file}" DEPLOYMENT_ID)"
  RELAY_HOSTKEY_FINGERPRINT="$(kv_get "${file}" RELAY_HOSTKEY_FINGERPRINT)"
  RELAY_SSH_KEY_FINGERPRINT="$(kv_get "${file}" RELAY_SSH_KEY_FINGERPRINT)"
  EXIT_HOSTKEY_FINGERPRINT="$(kv_get "${file}" EXIT_HOSTKEY_FINGERPRINT)"
  EXIT_SSH_KEY_FINGERPRINT="$(kv_get "${file}" EXIT_SSH_KEY_FINGERPRINT)"
  RELAY_PORT="$(kv_get "${file}" RELAY_PORT)"
  EXIT_REALITY_PORT="$(kv_get "${file}" EXIT_REALITY_PORT)"
  LINUX_BINARY_SHA256="$(kv_get "${file}" LINUX_BINARY_SHA256)"
  DARWIN_BINARY_SHA256="$(kv_get "${file}" DARWIN_BINARY_SHA256)"
  VLESS_UUID="$(kv_get "${file}" VLESS_UUID)"
  REALITY_PUBLIC_KEY="$(kv_get "${file}" REALITY_PUBLIC_KEY)"
  REALITY_SHORT_ID="$(kv_get "${file}" REALITY_SHORT_ID)"
  RELAY_OWNER_SHA256="$(kv_get "${file}" RELAY_OWNER_SHA256)"
  RELAY_SOCKET_SHA256="$(kv_get "${file}" RELAY_SOCKET_SHA256)"
  RELAY_SERVICE_SHA256="$(kv_get "${file}" RELAY_SERVICE_SHA256)"
  RELAY_ENABLE_LINK_TARGET="$(kv_get "${file}" RELAY_ENABLE_LINK_TARGET)"
  RELAY_ENABLE_LINK_SHA256="$(kv_get "${file}" RELAY_ENABLE_LINK_SHA256)"
  EXIT_OWNER_SHA256="$(kv_get "${file}" EXIT_OWNER_SHA256)"
  EXIT_EXIT_SHA256="$(kv_get "${file}" EXIT_EXIT_SHA256)"
  EXIT_SERVICE_SHA256="$(kv_get "${file}" EXIT_SERVICE_SHA256)"
  EXIT_ENABLE_LINK_TARGET="$(kv_get "${file}" EXIT_ENABLE_LINK_TARGET)"
  EXIT_ENABLE_LINK_SHA256="$(kv_get "${file}" EXIT_ENABLE_LINK_SHA256)"
  RELAY_BASELINE_CONFIG_MANIFEST_SHA256="$(kv_get "${file}" RELAY_BASELINE_CONFIG_MANIFEST_SHA256)"
  RELAY_BASELINE_LISTEN_SHA256="$(kv_get "${file}" RELAY_BASELINE_LISTEN_SHA256)"
  RELAY_BASELINE_BINARY_MANIFEST_SHA256="$(kv_get "${file}" RELAY_BASELINE_BINARY_MANIFEST_SHA256)"
  RELAY_BASELINE_UNIT_MANIFEST_SHA256="$(kv_get "${file}" RELAY_BASELINE_UNIT_MANIFEST_SHA256)"
  RELAY_BASELINE_SERVICE_ACTIVE="$(kv_get "${file}" RELAY_BASELINE_SERVICE_ACTIVE)"
  RELAY_BASELINE_SERVICE_ENABLED="$(kv_get "${file}" RELAY_BASELINE_SERVICE_ENABLED)"
  NODE_SHA256="$(kv_get "${file}" NODE_SHA256)"
  LOCAL_STAGE_PATH="$(kv_get "${file}" LOCAL_STAGE_PATH)"
  LOCAL_STAGE_OWNER_SHA256="$(kv_get "${file}" LOCAL_STAGE_OWNER_SHA256)"
  RELAY_STAGE_PATH="$(kv_get "${file}" RELAY_STAGE_PATH)"
  EXIT_STAGE_PATH="$(kv_get "${file}" EXIT_STAGE_PATH)"
  RELAY_BINARY_STAGE_PATH="$(kv_get "${file}" RELAY_BINARY_STAGE_PATH)"
  EXIT_BINARY_STAGE_PATH="$(kv_get "${file}" EXIT_BINARY_STAGE_PATH)"
  RELAY_STAGE_OWNER_TEMP_PATH="$(kv_get "${file}" RELAY_STAGE_OWNER_TEMP_PATH)"
  EXIT_STAGE_OWNER_TEMP_PATH="$(kv_get "${file}" EXIT_STAGE_OWNER_TEMP_PATH)"
  RELAY_BINARY_STAGE_OWNER_TEMP_PATH="$(kv_get "${file}" RELAY_BINARY_STAGE_OWNER_TEMP_PATH)"
  EXIT_BINARY_STAGE_OWNER_TEMP_PATH="$(kv_get "${file}" EXIT_BINARY_STAGE_OWNER_TEMP_PATH)"
  RELAY_STAGE_OWNER_SHA256="$(kv_get "${file}" RELAY_STAGE_OWNER_SHA256)"
  EXIT_STAGE_OWNER_SHA256="$(kv_get "${file}" EXIT_STAGE_OWNER_SHA256)"
  RELAY_BINARY_STAGE_OWNER_SHA256="$(kv_get "${file}" RELAY_BINARY_STAGE_OWNER_SHA256)"
  EXIT_BINARY_STAGE_OWNER_SHA256="$(kv_get "${file}" EXIT_BINARY_STAGE_OWNER_SHA256)"
  for key in RELAY_HOST RELAY_SSH_PORT RELAY_SSH_USER RELAY_SSH_KEY_PATH EXIT_HOST EXIT_SSH_PORT EXIT_SSH_USER EXIT_SSH_KEY_PATH EXPECTED_EXIT_IPV4 REALITY_SERVER_NAME RELAY_COHOSTS_SINGBOX; do
    case "${key}" in
      RELAY_HOST) expected="${RELAY_HOST}" ;;
      RELAY_SSH_PORT) expected="${RELAY_SSH_PORT}" ;;
      RELAY_SSH_USER) expected="${RELAY_SSH_USER}" ;;
      RELAY_SSH_KEY_PATH) expected="${RELAY_SSH_KEY}" ;;
      EXIT_HOST) expected="${EXIT_HOST}" ;;
      EXIT_SSH_PORT) expected="${EXIT_SSH_PORT}" ;;
      EXIT_SSH_USER) expected="${EXIT_SSH_USER}" ;;
      EXIT_SSH_KEY_PATH) expected="${EXIT_SSH_KEY}" ;;
      EXPECTED_EXIT_IPV4) expected="${EXPECTED_EXIT_IPV4}" ;;
      REALITY_SERVER_NAME) expected="${REALITY_SERVER_NAME}" ;;
      RELAY_COHOSTS_SINGBOX) expected="${RELAY_COHOSTS_SINGBOX}" ;;
    esac
    [[ "$(kv_get "${file}" "${key}")" == "${expected}" ]] || die 5 "transaction ${key} 与当前配置不一致"
  done
  [[ "${OPERATION_ID}" =~ ^[0-9a-f]{32}$ && "${DEPLOYMENT_ID}" =~ ^[0-9a-f]{32}$ ]] || die 5 'transaction id 格式错误'
  [[ "${RELAY_PORT}" =~ ^[1-9][0-9]*$ && "${EXIT_REALITY_PORT}" =~ ^[1-9][0-9]*$ ]] || die 5 'transaction 端口格式错误'
  (( RELAY_PORT <= 65535 && EXIT_REALITY_PORT <= 65535 )) || die 5 'transaction 端口范围错误'
  case "${JOURNAL_OPERATION}:${TARGET_STATE}" in
    deploy:deployed|rollback:not_deployed) ;;
    *) die 5 'transaction operation/target 组合错误' ;;
  esac
  [[ "$(kv_get "${file}" SING_BOX_VERSION)" == "${SING_BOX_VERSION}" ]] || die 5 'transaction 固定资产版本错误'
  adopt_recorded_assets "$(kv_get "${file}" LINUX_ARCHIVE_SHA256)" "$(kv_get "${file}" LINUX_BINARY_SHA256)" "$(kv_get "${file}" DARWIN_ARCHIVE_SHA256)" "$(kv_get "${file}" DARWIN_BINARY_SHA256)" || die 5 'transaction 固定资产摘要错误'
  for value in "${LINUX_BINARY_SHA256}" "${RELAY_ENABLE_LINK_SHA256}" "${EXIT_ENABLE_LINK_SHA256}" "${RELAY_BASELINE_CONFIG_MANIFEST_SHA256}" "${RELAY_BASELINE_LISTEN_SHA256}" "${RELAY_BASELINE_BINARY_MANIFEST_SHA256}" "${RELAY_BASELINE_UNIT_MANIFEST_SHA256}"; do
    [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || die 5 'transaction 固定资源 hash 格式错误'
  done
  for value in "${RELAY_OWNER_SHA256}" "${RELAY_SOCKET_SHA256}" "${RELAY_SERVICE_SHA256}" "${EXIT_OWNER_SHA256}" "${EXIT_EXIT_SHA256}" "${EXIT_SERVICE_SHA256}" "${NODE_SHA256}"; do
    [[ "${value}" == ABSENT || "${value}" =~ ^[0-9a-f]{64}$ ]] || die 5 'transaction 可选资源 hash 格式错误'
  done
  [[ "$(kv_get "${file}" RELAY_ENABLE_LINK_TARGET)" == "../ownexit-chain-relay-${CHAIN_ID}.socket" ]] || die 5 'transaction 中转 enablement target 错误'
  [[ "$(kv_get "${file}" EXIT_ENABLE_LINK_TARGET)" == "../ownexit-chain-exit-${CHAIN_ID}.service" ]] || die 5 'transaction 出口机 enablement target 错误'
  [[ "${VLESS_UUID}" == ABSENT || "${VLESS_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 5 'transaction UUID 格式错误'
  [[ "${REALITY_PUBLIC_KEY}" == ABSENT || "${REALITY_PUBLIC_KEY}" =~ ^[A-Za-z0-9_-]+$ ]] || die 5 'transaction Reality public key 格式错误'
  [[ "${REALITY_SHORT_ID}" == ABSENT || "${REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || die 5 'transaction Reality short id 格式错误'
  if [[ "${JOURNAL_OPERATION}" == deploy ]]; then
    case "${LAST_COMPLETED_STEP}" in
      PREPARED|RELAY_BINARY_READY|RELAY_BINARY_STAGE_CLEANED|EXIT_BINARY_READY|EXIT_BINARY_STAGE_CLEANED|EXIT_STAGED|EXIT_INSTALLED|EXIT_STAGE_CLEANED|EXIT_ACTIVE|EXIT_REALITY_SMOKE_OK|RELAY_STAGED|RELAY_INSTALLED|RELAY_STAGE_CLEANED|RELAY_ACTIVE|LOCAL_ARTIFACTS_READY|FULL_VERIFY_OK|STATE_WRITTEN|COMMITTED) ;;
      *) die 5 'deploy transaction step 不在允许枚举中' ;;
    esac
    [[ "${LOCAL_STAGE_PATH}" == "${CHAIN_STATE_DIR}/.stage-local-${OPERATION_ID}" ]] || die 5 'transaction local stage path 不匹配'
    [[ "${RELAY_STAGE_PATH}" == "/etc/ownexit-chain/.stage-relay-${DEPLOYMENT_ID}" ]] || die 5 'transaction relay stage path 不匹配'
    [[ "${EXIT_STAGE_PATH}" == "/etc/ownexit-chain/.stage-exit-${DEPLOYMENT_ID}" ]] || die 5 'transaction 出口机 stage path 不匹配'
    [[ "${RELAY_BINARY_STAGE_PATH}" == "/opt/ownexit-chain/.stage-binary-${DEPLOYMENT_ID}" && "${EXIT_BINARY_STAGE_PATH}" == "/opt/ownexit-chain/.stage-binary-${DEPLOYMENT_ID}" ]] || die 5 'transaction binary stage path 不匹配'
    [[ "${RELAY_STAGE_OWNER_TEMP_PATH}" == "/etc/ownexit-chain/.owner-relay-${DEPLOYMENT_ID}" && "${EXIT_STAGE_OWNER_TEMP_PATH}" == "/etc/ownexit-chain/.owner-exit-${DEPLOYMENT_ID}" ]] || die 5 'transaction config owner temp path 不匹配'
    [[ "${RELAY_BINARY_STAGE_OWNER_TEMP_PATH}" == "/opt/ownexit-chain/.owner-relay-binary-${DEPLOYMENT_ID}" && "${EXIT_BINARY_STAGE_OWNER_TEMP_PATH}" == "/opt/ownexit-chain/.owner-exit-binary-${DEPLOYMENT_ID}" ]] || die 5 'transaction binary owner temp path 不匹配'
    for value in "${LOCAL_STAGE_OWNER_SHA256}" "${RELAY_STAGE_OWNER_SHA256}" "${EXIT_STAGE_OWNER_SHA256}" "${RELAY_BINARY_STAGE_OWNER_SHA256}" "${EXIT_BINARY_STAGE_OWNER_SHA256}"; do
      [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || die 5 'deploy transaction stage owner hash 格式错误'
    done
  else
    case "${LAST_COMPLETED_STEP}" in
      ROLLBACK_PREPARED|RELAY_STOPPED|RELAY_FILES_REMOVED|EXIT_STOPPED|EXIT_FILES_REMOVED|LOCAL_ARTIFACTS_ARCHIVED|ROLLBACK_COMMITTED) ;;
      *) die 5 'rollback transaction step 不在允许枚举中' ;;
    esac
    [[ "${LOCAL_STAGE_PATH}" == ABSENT && "${RELAY_STAGE_PATH}" == ABSENT && "${EXIT_STAGE_PATH}" == ABSENT && "${RELAY_BINARY_STAGE_PATH}" == ABSENT && "${EXIT_BINARY_STAGE_PATH}" == ABSENT ]] || die 5 'rollback transaction 不得携带 deploy stage path'
    [[ "${LOCAL_STAGE_OWNER_SHA256}" == ABSENT && "${RELAY_STAGE_OWNER_TEMP_PATH}" == ABSENT && "${EXIT_STAGE_OWNER_TEMP_PATH}" == ABSENT && "${RELAY_BINARY_STAGE_OWNER_TEMP_PATH}" == ABSENT && "${EXIT_BINARY_STAGE_OWNER_TEMP_PATH}" == ABSENT ]] || die 5 'rollback transaction 不得携带 deploy owner temp'
    [[ "${RELAY_STAGE_OWNER_SHA256}" == ABSENT && "${EXIT_STAGE_OWNER_SHA256}" == ABSENT && "${RELAY_BINARY_STAGE_OWNER_SHA256}" == ABSENT && "${EXIT_BINARY_STAGE_OWNER_SHA256}" == ABSENT ]] || die 5 'rollback transaction 不得携带 deploy stage owner hash'
  fi
}

probe_loaded_binding() {
  local current_relay_key current_exit_key remote_relay remote_exit
  current_relay_key="$(fingerprint_private_key "${RELAY_SSH_KEY}")" || return 11
  current_exit_key="$(fingerprint_private_key "${EXIT_SSH_KEY}")" || return 12
  [[ "${current_relay_key}" == "${RELAY_SSH_KEY_FINGERPRINT}" ]] || return 11
  [[ "${current_exit_key}" == "${EXIT_SSH_KEY_FINGERPRINT}" ]] || return 12
  remote_relay="$(negotiated_hostkey_fingerprint chain-relay)" || return 21
  remote_exit="$(negotiated_hostkey_fingerprint chain-exit)" || return 22
  [[ "${remote_relay}" == "${RELAY_HOSTKEY_FINGERPRINT}" ]] || return 31
  [[ "${remote_exit}" == "${EXIT_HOSTKEY_FINGERPRINT}" ]] || return 32
}

verify_loaded_binding() {
  local rc
  if probe_loaded_binding; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) return 0 ;;
    11) die 5 '中转 SSH key 指纹漂移' ;;
    12) die 5 '出口机 SSH key 指纹漂移' ;;
    21) die 5 '中转实际协商 host-key 探针不可达' ;;
    22) die 5 '出口机实际协商 host-key 探针不可达' ;;
    31) die 5 '中转实际协商 host-key 指纹漂移' ;;
    32) die 5 '出口机实际协商 host-key 指纹漂移' ;;
    *) die 5 '主机/密钥绑定核验异常' ;;
  esac
}

render_owner_file() {
  local output role hostkey
  output="$1"
  role="$2"
  hostkey="$3"
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'CHAIN_ID=%s\n' "${CHAIN_ID}"
    printf 'DEPLOYMENT_ID=%s\n' "${DEPLOYMENT_ID}"
    printf 'ROLE=%s\n' "${role}"
    printf 'CONFIG_SHA256=%s\n' "${CONFIG_SHA256}"
    printf 'HOSTKEY_FINGERPRINT=%s\n' "${hostkey}"
    printf 'CREATED_AT=%s\n' "$(now_rfc3339)"
  } > "${output}"
  chmod 600 "${output}"
}

render_local_stage_owner() {
  local output
  output="$1"
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'CHAIN_ID=%s\n' "${CHAIN_ID}"
    printf 'DEPLOYMENT_ID=%s\n' "${DEPLOYMENT_ID}"
    printf 'OPERATION_ID=%s\n' "${OPERATION_ID}"
    printf 'CONFIG_SHA256=%s\n' "${CONFIG_SHA256}"
  } > "${output}"
  chmod 600 "${output}"
}

write_port_check_script() {
  local output
  output="$1"
  cat > "${output}" <<'PORT_CHECK'
#!/usr/bin/env bash
set -euo pipefail
umask 077
port="$1"
if ss -H -ltn | awk -v suffix=":$port" 'substr($4, length($4)-length(suffix)+1) == suffix {found=1} END {exit found ? 0 : 1}'; then
  printf 'used\n'
else
  printf 'free\n'
fi
PORT_CHECK
  chmod 600 "${output}"
}

choose_remote_port() {
  local role attempt hex candidate state script
  role="$1"
  attempt=0
  script="${OP_TMP}/port-check.sh"
  write_port_check_script "${script}"
  while (( attempt < 200 )); do
    hex="$(openssl rand -hex 2)"
    candidate="$((20000 + (16#${hex} % 40000)))"
    if [[ "${role}" == relay ]]; then
      state="$(ssh_relay_stdin bash -s -- "${candidate}" < "${script}")"
    else
      state="$(ssh_exit_stdin bash -s -- "${candidate}" < "${script}")"
    fi
    if [[ "${state}" == free ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    attempt="$((attempt + 1))"
  done
  return 1
}

create_local_stage() {
  local owner owner_temp baseline
  LOCAL_STAGE_PATH="${CHAIN_STATE_DIR}/.stage-local-${OPERATION_ID}"
  [[ ! -e "${LOCAL_STAGE_PATH}" && ! -L "${LOCAL_STAGE_PATH}" ]] || die 4 '本地 staging 路径碰撞'
  ensure_private_dir "${CHAIN_STATE_DIR}" || die 1 'chain state 目录身份或权限不安全'
  mkdir "${LOCAL_STAGE_PATH}"
  chmod 700 "${LOCAL_STAGE_PATH}"
  owner="${LOCAL_STAGE_PATH}/stage-owner.env"
  owner_temp="${CHAIN_STATE_DIR}/.stage-owner.${LOCK_OPERATION_ID}.tmp"
  ( set -o noclobber; render_local_stage_owner "${owner_temp}" ) || die 1 '本地 staging owner 临时文件碰撞'
  link "${owner_temp}" "${owner}" || die 1 '本地 staging owner no-replace 发布失败'
  rm -f "${owner_temp}"
  LOCAL_STAGE_OWNER_SHA256="$(sha256_file "${owner}")"
  baseline="${LOCAL_STAGE_PATH}/baseline"
  collect_relay_baseline "${baseline}"
  RELAY_BASELINE_CONFIG_MANIFEST_SHA256="$(sha256_file "${baseline}/relay-config-manifest.txt")"
  RELAY_BASELINE_UNIT_MANIFEST_SHA256="$(sha256_file "${baseline}/relay-unit-manifest.txt")"
  RELAY_BASELINE_BINARY_MANIFEST_SHA256="$(sha256_file "${baseline}/relay-binary-manifest.txt")"
  RELAY_BASELINE_LISTEN_SHA256="$(sha256_file "${baseline}/relay-listeners.txt")"
}

init_deploy_transaction_fields() {
  local owner_dir
  DEPLOYMENT_ID="$(random_hex_128)"
  RELAY_PORT="$(choose_remote_port relay)" || die 3 '无法在中转选择候选端口'
  EXIT_REALITY_PORT="$(choose_remote_port exit)" || die 3 '无法在出口机选择候选端口'
  RELAY_ENABLE_LINK_TARGET="../ownexit-chain-relay-${CHAIN_ID}.socket"
  EXIT_ENABLE_LINK_TARGET="../ownexit-chain-exit-${CHAIN_ID}.service"
  RELAY_ENABLE_LINK_SHA256="$(printf '%s' "${RELAY_ENABLE_LINK_TARGET}" | sha256_text)"
  EXIT_ENABLE_LINK_SHA256="$(printf '%s' "${EXIT_ENABLE_LINK_TARGET}" | sha256_text)"
  RELAY_BINARY_STAGE_PATH="${REMOTE_BASE}/.stage-binary-${DEPLOYMENT_ID}"
  EXIT_BINARY_STAGE_PATH="${REMOTE_BASE}/.stage-binary-${DEPLOYMENT_ID}"
  RELAY_STAGE_PATH="${REMOTE_CONFIG_DIR}/.stage-relay-${DEPLOYMENT_ID}"
  EXIT_STAGE_PATH="${REMOTE_CONFIG_DIR}/.stage-exit-${DEPLOYMENT_ID}"
  RELAY_BINARY_STAGE_OWNER_TEMP_PATH="${REMOTE_BASE}/.owner-relay-binary-${DEPLOYMENT_ID}"
  EXIT_BINARY_STAGE_OWNER_TEMP_PATH="${REMOTE_BASE}/.owner-exit-binary-${DEPLOYMENT_ID}"
  RELAY_STAGE_OWNER_TEMP_PATH="${REMOTE_CONFIG_DIR}/.owner-relay-${DEPLOYMENT_ID}"
  EXIT_STAGE_OWNER_TEMP_PATH="${REMOTE_CONFIG_DIR}/.owner-exit-${DEPLOYMENT_ID}"
  owner_dir="${OP_TMP}/owners"
  mkdir "${owner_dir}"
  render_owner_file "${owner_dir}/relay-binary.env" relay-binary-stage "${RELAY_HOSTKEY_FINGERPRINT}"
  render_owner_file "${owner_dir}/exit-binary.env" exit-binary-stage "${EXIT_HOSTKEY_FINGERPRINT}"
  render_owner_file "${owner_dir}/relay-stage.env" relay-stage "${RELAY_HOSTKEY_FINGERPRINT}"
  render_owner_file "${owner_dir}/exit-stage.env" exit-stage "${EXIT_HOSTKEY_FINGERPRINT}"
  RELAY_BINARY_STAGE_OWNER_SHA256="$(sha256_file "${owner_dir}/relay-binary.env")"
  EXIT_BINARY_STAGE_OWNER_SHA256="$(sha256_file "${owner_dir}/exit-binary.env")"
  RELAY_STAGE_OWNER_SHA256="$(sha256_file "${owner_dir}/relay-stage.env")"
  EXIT_STAGE_OWNER_SHA256="$(sha256_file "${owner_dir}/exit-stage.env")"
  require_remote_path_absent relay "${RELAY_BINARY_STAGE_PATH}" '中转 binary staging 路径碰撞'
  require_remote_path_absent exit "${EXIT_BINARY_STAGE_PATH}" '出口机 binary staging 路径碰撞'
  require_remote_path_absent relay "${RELAY_STAGE_PATH}" '中转 unit staging 路径碰撞'
  require_remote_path_absent exit "${EXIT_STAGE_PATH}" '出口机 config staging 路径碰撞'
  for suffix in .part .ready; do
    require_remote_path_absent relay "${RELAY_BINARY_STAGE_OWNER_TEMP_PATH}${suffix}" '中转 binary owner temp 碰撞'
    require_remote_path_absent exit "${EXIT_BINARY_STAGE_OWNER_TEMP_PATH}${suffix}" '出口机 binary owner temp 碰撞'
    require_remote_path_absent relay "${RELAY_STAGE_OWNER_TEMP_PATH}${suffix}" '中转 unit owner temp 碰撞'
    require_remote_path_absent exit "${EXIT_STAGE_OWNER_TEMP_PATH}${suffix}" '出口机 config owner temp 碰撞'
  done
  create_local_stage
  LAST_COMPLETED_STEP='PREPARED'
  JOURNAL_OPERATION='deploy'
  TARGET_STATE='deployed'
  write_journal
}

write_create_stage_script() {
  local output
  output="$1"
  cat > "${output}" <<'CREATE_STAGE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
stage="$1"
owner_base="$2"
owner_b64="$3"
owner_hash="$4"

ensure_dir() {
  local path
  path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -d "$path" && ! -L "$path" && "$(stat -c %u:%g:%a "$path")" == 0:0:755 ]] || exit 41
  else
    mkdir "$path"
    chown root:root "$path"
    chmod 755 "$path"
  fi
}

case "$stage" in
  /opt/ownexit-chain/.stage-*|/etc/ownexit-chain/.stage-*) ;;
  *) exit 42 ;;
esac
ensure_dir /opt/ownexit-chain
ensure_dir /opt/ownexit-chain/bin
ensure_dir /etc/ownexit-chain
[[ ! -e "$stage" && ! -L "$stage" ]] || exit 43
part="${owner_base}.part"
ready="${owner_base}.ready"
[[ ! -e "$part" && ! -L "$part" && ! -e "$ready" && ! -L "$ready" ]] || exit 44
( set -o noclobber; printf '%s' "$owner_b64" | base64 -d > "$part" )
chown root:root "$part"
chmod 600 "$part"
[[ "$(sha256sum "$part" | awk '{print $1}')" == "$owner_hash" ]] || exit 45
link "$part" "$ready"
rm -f "$part"
mkdir "$stage"
chown root:root "$stage"
chmod 700 "$stage"
link "$ready" "$stage/stage-owner.env"
rm -f "$ready"
[[ "$(stat -c %u:%g:%a "$stage/stage-owner.env")" == 0:0:600 ]] || exit 46
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$owner_hash" ]] || exit 47
CREATE_STAGE
  chmod 600 "${output}"
}

create_remote_stage() {
  local role path owner_base owner_file owner_hash script b64
  role="$1"
  path="$2"
  owner_base="$3"
  owner_file="$4"
  owner_hash="$5"
  script="${OP_TMP}/create-stage.sh"
  write_create_stage_script "${script}"
  b64="$(openssl base64 -A -in "${owner_file}")"
  if [[ "${role}" == relay ]]; then
    ssh_relay_stdin bash -s -- "${path}" "${owner_base}" "${b64}" "${owner_hash}" < "${script}"
  else
    ssh_exit_stdin bash -s -- "${path}" "${owner_base}" "${b64}" "${owner_hash}" < "${script}"
  fi
}

write_install_binary_script() {
  local output
  output="$1"
  cat > "${output}" <<'INSTALL_BINARY'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
stage="$1"
owner_hash="$2"
archive_hash="$3"
binary_hash="$4"
version="$5"
final="$6"
arch="$7"
[[ "$arch" == amd64 || "$arch" == arm64 ]] || exit 62
[[ -d "$stage" && ! -L "$stage" && "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 51
[[ -f "$stage/stage-owner.env" && ! -L "$stage/stage-owner.env" ]] || exit 52
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$owner_hash" ]] || exit 53
[[ -f "$stage/archive.tar.gz" && ! -L "$stage/archive.tar.gz" ]] || exit 54
[[ "$(sha256sum "$stage/archive.tar.gz" | awk '{print $1}')" == "$archive_hash" ]] || exit 55
mkdir "$stage/extracted"
chmod 700 "$stage/extracted"
tar --no-same-owner --no-same-permissions -xzf "$stage/archive.tar.gz" -C "$stage/extracted"
candidate="$stage/extracted/sing-box-$version-linux-$arch/sing-box"
cronet="$stage/extracted/sing-box-$version-linux-$arch/libcronet.so"
[[ -f "$candidate" && ! -L "$candidate" && -f "$cronet" && ! -L "$cronet" ]] || exit 56
chown root:root "$candidate"
chmod 755 "$candidate"
[[ "$(sha256sum "$candidate" | awk '{print $1}')" == "$binary_hash" ]] || exit 57
if [[ -e "$final" || -L "$final" ]]; then
  [[ -f "$final" && ! -L "$final" && "$(stat -c %u:%g:%a "$final")" == 0:0:755 ]] || exit 58
  [[ "$(sha256sum "$final" | awk '{print $1}')" == "$binary_hash" ]] || exit 59
  result=reused
else
  link "$candidate" "$final"
  result=created
fi
[[ ! -e "$(dirname "$final")/libcronet.so" && ! -L "$(dirname "$final")/libcronet.so" ]] || exit 60
cd /
actual="$(env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH= LD_PRELOAD= "$final" version | awk '/^sing-box version / {print $3; exit}')"
[[ "$actual" == "$version" ]] || exit 61
printf 'BINARY_RESULT=%s\n' "$result"
INSTALL_BINARY
  chmod 600 "${output}"
}

# 远端在自己的暂存目录里下载官方包并核对归档 SHA256；成功输出 nothing、返回 0。
# 返回 1 = 下载失败（网络、GitHub 不可达），2 = 摘要不符；两种情况都已删除半成品，调用方改为本机上传。
write_remote_download_script() {
  local output
  output="$1"
  cat > "${output}" <<'REMOTE_DOWNLOAD'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
stage="$1"
url="$2"
expected="$3"
[[ -d "$stage" && ! -L "$stage" && "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 3
dst="$stage/archive.tar.gz"
[[ ! -e "$dst" && ! -L "$dst" ]] || exit 3
if command -v curl >/dev/null 2>&1; then
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 --max-time 300 -o "$dst" "$url" || { rm -f "$dst"; exit 1; }
elif command -v wget >/dev/null 2>&1; then
  wget --quiet --https-only --timeout=60 --tries=2 -O "$dst" "$url" || { rm -f "$dst"; exit 1; }
else
  exit 1
fi
[[ -f "$dst" && ! -L "$dst" && "$(sha256sum "$dst" | awk '{print $1}')" == "$expected" ]] || { rm -f "$dst"; exit 2; }
chown root:root "$dst"
chmod 600 "$dst"
REMOTE_DOWNLOAD
  chmod 600 "${output}"
}

# 把固定版本 binary 装到远端（或复用已有的同哈希 binary）。归档优先由远端自己下载（控制端在国内时本机访问 GitHub
# 常卡住）；远端下载失败才在本机准备同架构的归档并 scp 上传。两条路径之后的校验完全相同（归档哈希、binary 哈希、版本）。
install_remote_binary() {
  local role stage owner_hash owner_file owner_base script output download_script rc source
  role="$1"
  stage="$2"
  owner_hash="$3"
  owner_file="$4"
  owner_base="$5"
  create_remote_stage "${role}" "${stage}" "${owner_base}" "${owner_file}" "${owner_hash}" || die 1 "${role} binary staging 创建失败"
  download_script="${OP_TMP}/remote-download.sh"
  write_remote_download_script "${download_script}"
  if [[ "${role}" == relay ]]; then
    if ssh_relay_stdin bash -s -- "${stage}" "$(archive_url "${LINUX_ARCHIVE}")" "${LINUX_ARCHIVE_SHA256}" < "${download_script}"; then rc=0; else rc="$?"; fi
  else
    if ssh_exit_stdin bash -s -- "${stage}" "$(archive_url "${LINUX_ARCHIVE}")" "${LINUX_ARCHIVE_SHA256}" < "${download_script}"; then rc=0; else rc="$?"; fi
  fi
  if [[ "${rc}" -eq 0 ]]; then
    source=remote-download
  else
    log_warn "${role} 远端下载官方包失败（rc=${rc}），改为本机下载后上传"
    [[ -n "${LINUX_ARCHIVE_PATH}" ]] || LINUX_ARCHIVE_PATH="$(verified_archive_path deploy "${LINUX_ARCHIVE}" "${LINUX_ARCHIVE_SHA256}")"
    if [[ "${role}" == relay ]]; then
      scp_relay "${LINUX_ARCHIVE_PATH}" "chain-relay:${stage}/archive.tar.gz" || die 1 'Linux archive 上传中转失败'
      ssh_relay chown root:root "${stage}/archive.tar.gz"
      ssh_relay chmod 600 "${stage}/archive.tar.gz"
    else
      scp_exit "${LINUX_ARCHIVE_PATH}" "chain-exit:${stage}/archive.tar.gz" || die 1 'Linux archive 上传出口机失败'
      ssh_exit chown root:root "${stage}/archive.tar.gz"
      ssh_exit chmod 600 "${stage}/archive.tar.gz"
    fi
    source=local-upload
  fi
  log_info "${role} binary 来源=${source} arch=${REMOTE_ARCH}"
  script="${OP_TMP}/install-binary.sh"
  write_install_binary_script "${script}"
  if [[ "${role}" == relay ]]; then
    output="$(ssh_relay_stdin bash -s -- "${stage}" "${owner_hash}" "${LINUX_ARCHIVE_SHA256}" "${LINUX_BINARY_SHA256}" "${SING_BOX_VERSION}" "${REMOTE_BIN}" "${REMOTE_ARCH}" < "${script}")" || die 1 '中转固定 binary 安装/复用验证失败'
  else
    output="$(ssh_exit_stdin bash -s -- "${stage}" "${owner_hash}" "${LINUX_ARCHIVE_SHA256}" "${LINUX_BINARY_SHA256}" "${SING_BOX_VERSION}" "${REMOTE_BIN}" "${REMOTE_ARCH}" < "${script}")" || die 1 '出口机固定 binary 安装/复用验证失败'
  fi
  printf '%s\n' "${output}" | grep -Eq '^BINARY_RESULT=(created|reused)$' || die 1 '远端 binary 安装结果不完整'
}

cleanup_remote_stage() {
  local role stage owner_hash script
  role="$1"
  stage="$2"
  owner_hash="$3"
  script="${OP_TMP}/cleanup-stage.sh"
  cat > "${script}" <<'CLEAN_STAGE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
stage="$1"
owner_hash="$2"
chain_id="$3"
[[ -d "$stage" && ! -L "$stage" && "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 71
[[ -f "$stage/stage-owner.env" && ! -L "$stage/stage-owner.env" ]] || exit 72
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$owner_hash" ]] || exit 73
case "$stage" in
  /opt/ownexit-chain/.stage-*|/etc/ownexit-chain/.stage-*) ;;
  *) exit 74 ;;
esac
while IFS= read -r item; do
  relative="${item#$stage/}"
  case "$stage:$relative" in
    /opt/ownexit-chain/.stage-binary-*:stage-owner.env|\
    /opt/ownexit-chain/.stage-binary-*:archive.tar.gz|\
    /opt/ownexit-chain/.stage-binary-*:extracted|\
    /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-amd64|\
    /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-amd64/LICENSE|\
    /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-amd64/libcronet.so|\
    /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-amd64/sing-box|\
    /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-arm64|\
    /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-arm64/LICENSE|\
    /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-arm64/libcronet.so|\
    /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-arm64/sing-box) ;;
    /etc/ownexit-chain/.stage-relay-*:"$chain_id.owner.env"|\
    /etc/ownexit-chain/.stage-relay-*:"ownexit-chain-relay-$chain_id.socket"|\
    /etc/ownexit-chain/.stage-relay-*:"ownexit-chain-relay-$chain_id.service"|\
    /etc/ownexit-chain/.stage-relay-*:stage-owner.env) ;;
    /etc/ownexit-chain/.stage-exit-*:"$chain_id.owner.env"|\
    /etc/ownexit-chain/.stage-exit-*:"$chain_id.exit.json"|\
    /etc/ownexit-chain/.stage-exit-*:"ownexit-chain-exit-$chain_id.service"|\
    /etc/ownexit-chain/.stage-exit-*:stage-owner.env) ;;
    *) exit 75 ;;
  esac
done < <(find "$stage" -mindepth 1 -print)
# owner 是恢复时的删除授权，必须最后删除；中途断电时下一进程仍能核验剩余业务文件。
find "$stage" -depth -mindepth 1 ! -path "$stage/stage-owner.env" -delete
rm -f "$stage/stage-owner.env"
rmdir "$stage"
CLEAN_STAGE
  chmod 600 "${script}"
  if [[ "${role}" == relay ]]; then
    ssh_relay_stdin bash -s -- "${stage}" "${owner_hash}" "${CHAIN_ID}" < "${script}"
  else
    ssh_exit_stdin bash -s -- "${stage}" "${owner_hash}" "${CHAIN_ID}" < "${script}"
  fi
}

write_prepare_exit_script() {
  local output
  output="$1"
  cat > "${output}" <<'PREPARE_EXIT'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
stage="$1"
stage_owner_hash="$2"
binary="$3"
chain_id="$4"
port="$5"
server_name="$6"
owner_b64="$7"
source_filter="$8"
nft_path="$9"
relay_source="${10}"
# reuse：migrate-exit 已把旧出口机的 exit.json 搬进暂存，跳过生成密钥与渲染配置，只渲染 owner 与 unit；
# deploy 传 -，行为不变。
reuse="${11:--}"
[[ -d "$stage" && ! -L "$stage" && "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 81
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$stage_owner_hash" ]] || exit 82
[[ -f "$binary" && ! -L "$binary" && "$(stat -c %u:%g:%a "$binary")" == 0:0:755 ]] || exit 83
config="$stage/$chain_id.exit.json"
if [[ "$reuse" == reuse ]]; then
  [[ -f "$config" && ! -L "$config" && "$(stat -c %u:%g:%a "$config")" == 0:0:600 ]] || exit 88
else
set +x
keypair="$("$binary" generate reality-keypair)"
private_key="$(printf '%s\n' "$keypair" | awk -F': ' '$1 == "PrivateKey" {print $2}')"
public_key="$(printf '%s\n' "$keypair" | awk -F': ' '$1 == "PublicKey" {print $2}')"
uuid="$("$binary" generate uuid)"
short_id="$("$binary" generate rand --hex 8)"
[[ "$private_key" =~ ^[A-Za-z0-9_-]+$ && "$public_key" =~ ^[A-Za-z0-9_-]+$ ]] || exit 84
[[ "$uuid" =~ ^[0-9a-f-]{36}$ && "$short_id" =~ ^[0-9a-f]{16}$ ]] || exit 85

cat > "$config" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [{ "type": "local", "tag": "local-dns" }],
    "final": "local-dns",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [{
    "type": "vless",
    "tag": "exit-in",
    "listen": "0.0.0.0",
    "listen_port": $port,
    "users": [{ "name": "default", "uuid": "$uuid", "flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true,
      "server_name": "$server_name",
      "reality": {
        "enabled": true,
        "handshake": { "server": "$server_name", "server_port": 443 },
        "private_key": "$private_key",
        "short_id": ["$short_id"]
      }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "default_domain_resolver": "local-dns", "final": "direct" }
}
EOF
chown root:root "$config"
chmod 600 "$config"
fi

owner="$stage/$chain_id.owner.env"
printf '%s' "$owner_b64" | base64 -d > "$owner"
chown root:root "$owner"
chmod 600 "$owner"

# EXIT_SOURCE_FILTER=managed：Reality 端口只放行中转机的出站源地址。规则随 service 起停（+ 前缀以完整权限运行，
# 不受下方 CapabilityBoundingSet / ProtectSystem 限制）：启动前先删再建，停止后删除，重启机器后随服务自动恢复。
filter_lines=''
if [[ "$source_filter" == managed ]]; then
  [[ "$nft_path" == /* && -x "$nft_path" ]] || exit 86
  [[ "$relay_source" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 87
  table="ownexit_${chain_id//-/_}"
  filter_lines="ExecStartPre=-+$nft_path delete table inet $table
ExecStartPre=+$nft_path \"add table inet $table; add chain inet $table input { type filter hook input priority -10; policy accept; }; add rule inet $table input tcp dport $port ip saddr != $relay_source drop\"
ExecStopPost=-+$nft_path delete table inet $table
"
fi
unit="$stage/ownexit-chain-exit-$chain_id.service"
cat > "$unit" <<EOF
[Unit]
Description=ownexit chain exit ($chain_id)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
UMask=0077
${filter_lines}ExecStartPre=$binary check -c /etc/ownexit-chain/$chain_id.exit.json
ExecStart=$binary run -c /etc/ownexit-chain/$chain_id.exit.json
Restart=on-failure
RestartSec=3s
NoNewPrivileges=yes
CapabilityBoundingSet=
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF
chown root:root "$unit"
chmod 644 "$unit"
cd /
env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH= LD_PRELOAD= "$binary" check -c "$config" >/dev/null
systemd-analyze verify "$unit" >/dev/null
if [[ "$reuse" != reuse ]]; then
  printf 'VLESS_UUID=%s\n' "$uuid"
  printf 'REALITY_PUBLIC_KEY=%s\n' "$public_key"
  printf 'REALITY_SHORT_ID=%s\n' "$short_id"
fi
printf 'EXIT_OWNER_SHA256=%s\n' "$(sha256sum "$owner" | awk '{print $1}')"
printf 'EXIT_EXIT_SHA256=%s\n' "$(sha256sum "$config" | awk '{print $1}')"
printf 'EXIT_SERVICE_SHA256=%s\n' "$(sha256sum "$unit" | awk '{print $1}')"
PREPARE_EXIT
  chmod 600 "${output}"
}

# 中转机连向出口机时实际使用的源地址（中转有多个 IP 或在 NAT 后时与 RELAY_HOST 不同），managed 白名单按它放行。
detect_relay_source_ip() {
  local route source
  route="$(ssh_relay ip -4 route get "${EXIT_HOST}")" || die 1 '无法在中转机上查询到出口机的路由'
  source="$(printf '%s\n' "${route}" | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  is_ipv4 "${source}" || die 1 '中转机到出口机的出站源地址不是 IPv4'
  printf '%s\n' "${source}"
}

prepare_exit_exit() {
  local owner_file owner_b64 script output relay_source
  owner_file="${OP_TMP}/exit-owner.env"
  render_owner_file "${owner_file}" exit "${EXIT_HOSTKEY_FINGERPRINT}"
  owner_b64="$(openssl base64 -A -in "${owner_file}")"
  create_remote_stage exit "${EXIT_STAGE_PATH}" "${EXIT_STAGE_OWNER_TEMP_PATH}" "${OP_TMP}/owners/exit-stage.env" "${EXIT_STAGE_OWNER_SHA256}" || die 1 '出口机 config staging 创建失败'
  relay_source='-'
  if [[ "${EXIT_SOURCE_FILTER}" == managed ]]; then
    relay_source="$(detect_relay_source_ip)"
    [[ "${EXIT_NFT_PATH}" == /* ]] || die 1 '没有取得出口机 nft 路径，无法配置 managed 白名单'
    log_info "出口机白名单放行来源=${relay_source}（EXIT_SOURCE_FILTER=managed）"
  fi
  script="${OP_TMP}/prepare-exit.sh"
  write_prepare_exit_script "${script}"
  output="$(ssh_exit_stdin bash -s -- "${EXIT_STAGE_PATH}" "${EXIT_STAGE_OWNER_SHA256}" "${REMOTE_BIN}" "${CHAIN_ID}" "${EXIT_REALITY_PORT}" "${REALITY_SERVER_NAME}" "${owner_b64}" "${EXIT_SOURCE_FILTER}" "${EXIT_NFT_PATH:--}" "${relay_source}" - < "${script}")" || die 1 '出口机 Reality config/unit staging 失败'
  VLESS_UUID="$(printf '%s\n' "${output}" | awk -F= '$1 == "VLESS_UUID" {print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "${output}" | awk -F= '$1 == "REALITY_PUBLIC_KEY" {print $2}')"
  REALITY_SHORT_ID="$(printf '%s\n' "${output}" | awk -F= '$1 == "REALITY_SHORT_ID" {print $2}')"
  EXIT_OWNER_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "EXIT_OWNER_SHA256" {print $2}')"
  EXIT_EXIT_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "EXIT_EXIT_SHA256" {print $2}')"
  EXIT_SERVICE_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "EXIT_SERVICE_SHA256" {print $2}')"
  [[ "${VLESS_UUID}" =~ ^[0-9a-f-]{36}$ && "${REALITY_PUBLIC_KEY}" =~ ^[A-Za-z0-9_-]+$ && "${REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || die 1 '出口机未返回完整客户端参数'
  [[ "${EXIT_OWNER_SHA256}" =~ ^[0-9a-f]{64}$ && "${EXIT_EXIT_SHA256}" =~ ^[0-9a-f]{64}$ && "${EXIT_SERVICE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die 1 '出口机 staging hash 不完整'
  LAST_COMPLETED_STEP='EXIT_STAGED'
  write_journal
}

write_promote_exit_script() {
  local output
  output="$1"
  cat > "${output}" <<'PROMOTE_EXIT'
#!/usr/bin/env bash
set -euo pipefail
umask 077
stage="$1"
stage_owner_hash="$2"
chain_id="$3"
owner_hash="$4"
config_hash="$5"
unit_hash="$6"
link_target="$7"
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$stage_owner_hash" ]] || exit 91
owner_src="$stage/$chain_id.owner.env"
config_src="$stage/$chain_id.exit.json"
unit_src="$stage/ownexit-chain-exit-$chain_id.service"
[[ "$(sha256sum "$owner_src" | awk '{print $1}')" == "$owner_hash" ]] || exit 92
[[ "$(sha256sum "$config_src" | awk '{print $1}')" == "$config_hash" ]] || exit 93
[[ "$(sha256sum "$unit_src" | awk '{print $1}')" == "$unit_hash" ]] || exit 94
owner_dst="/etc/ownexit-chain/$chain_id.owner.env"
config_dst="/etc/ownexit-chain/$chain_id.exit.json"
unit_dst="/etc/systemd/system/ownexit-chain-exit-$chain_id.service"
link_dst="/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-$chain_id.service"
wants="$(dirname "$link_dst")"
[[ -d "$wants" && ! -L "$wants" && "$(stat -c %u "$wants")" == 0 ]] || exit 95
mode="$(stat -c %a "$wants")"
(( (8#$mode & 8#022) == 0 )) || exit 96
for path in "$owner_dst" "$config_dst" "$unit_dst" "$link_dst"; do
  [[ ! -e "$path" && ! -L "$path" ]] || exit 97
done
link "$owner_src" "$owner_dst"
link "$config_src" "$config_dst"
link "$unit_src" "$unit_dst"
ln --symbolic --no-target-directory "$link_target" "$link_dst"
[[ "$(readlink "$link_dst")" == "$link_target" ]] || exit 98
PROMOTE_EXIT
  chmod 600 "${output}"
}

install_exit_exit() {
  local script
  script="${OP_TMP}/promote-exit.sh"
  write_promote_exit_script "${script}"
  ssh_exit_stdin bash -s -- "${EXIT_STAGE_PATH}" "${EXIT_STAGE_OWNER_SHA256}" "${CHAIN_ID}" "${EXIT_OWNER_SHA256}" "${EXIT_EXIT_SHA256}" "${EXIT_SERVICE_SHA256}" "${EXIT_ENABLE_LINK_TARGET}" < "${script}" || die 1 '出口机专属资源 no-replace 发布失败'
  LAST_COMPLETED_STEP='EXIT_INSTALLED'
  write_journal
  cleanup_remote_stage exit "${EXIT_STAGE_PATH}" "${EXIT_STAGE_OWNER_SHA256}" || die 1 '出口机 config staging 清理失败'
  LAST_COMPLETED_STEP='EXIT_STAGE_CLEANED'
  write_journal
}

activate_exit_exit() {
  local unit
  unit="ownexit-chain-exit-${CHAIN_ID}.service"
  ssh_exit systemctl daemon-reload
  ssh_exit systemctl start "${unit}"
  [[ "$(ssh_exit systemctl is-active "${unit}")" == active ]] || die 1 '出口机 service 未进入 active'
  [[ "$(ssh_exit systemctl is-enabled "${unit}")" == enabled ]] || die 1 '出口机 service 未按预期 enabled'
  ssh_exit "ss -H -ltnp | grep -q ':${EXIT_REALITY_PORT} '" || die 1 '出口机 Reality 端口未监听'
  LAST_COMPLETED_STEP='EXIT_ACTIVE'
  write_journal
}

write_prepare_relay_script() {
  local output
  output="$1"
  cat > "${output}" <<'PREPARE_RELAY'
#!/usr/bin/env bash
set -euo pipefail
umask 077
stage="$1"
stage_owner_hash="$2"
chain_id="$3"
relay_port="$4"
exit_host="$5"
exit_port="$6"
proxyd="$7"
owner_b64="$8"
[[ -d "$stage" && ! -L "$stage" && "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 101
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$stage_owner_hash" ]] || exit 102
[[ -x "$proxyd" && ! -L "$proxyd" ]] || exit 103
owner="$stage/$chain_id.owner.env"
printf '%s' "$owner_b64" | base64 -d > "$owner"
chown root:root "$owner"
chmod 600 "$owner"
socket="$stage/ownexit-chain-relay-$chain_id.socket"
service="$stage/ownexit-chain-relay-$chain_id.service"
cat > "$socket" <<EOF
[Unit]
Description=ownexit chain relay socket ($chain_id)

[Socket]
ListenStream=0.0.0.0:$relay_port
Accept=no
Service=ownexit-chain-relay-$chain_id.service
# 客户端 NAT 超时后的死连接靠 keepalive 回收：60s 无流量开始探测、4 次失败（约 120s）内核关闭客户端腿，
# proxyd 随即关出站腿释放 fd。没有这几行，僵尸连接会一直占到 fd 上限（2026-09-03 实机事故）。
KeepAlive=yes
KeepAliveTimeSec=60
KeepAliveIntervalSec=15
KeepAliveProbes=4

[Install]
WantedBy=sockets.target
EOF
cat > "$service" <<EOF
[Unit]
Description=ownexit chain relay service ($chain_id)
Requires=ownexit-chain-relay-$chain_id.socket
After=ownexit-chain-relay-$chain_id.socket network-online.target
Wants=network-online.target

[Service]
Type=exec
UMask=0077
ExecStart=$proxyd --connections-max=256 $exit_host:$exit_port
# 每条转发连接约占 6 个 fd（2 socket + splice 管道），systemd 默认软限制 1024 让 256 上限永远达不到；
# 实测约 165 条即刷 "Too many open files" 且新连接全部失败。
LimitNOFILE=65536
Restart=on-failure
RestartSec=3s
NoNewPrivileges=yes
CapabilityBoundingSet=
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
EOF
chown root:root "$socket" "$service"
chmod 644 "$socket" "$service"
systemd-analyze verify "$socket" "$service" >/dev/null
printf 'RELAY_OWNER_SHA256=%s\n' "$(sha256sum "$owner" | awk '{print $1}')"
printf 'RELAY_SOCKET_SHA256=%s\n' "$(sha256sum "$socket" | awk '{print $1}')"
printf 'RELAY_SERVICE_SHA256=%s\n' "$(sha256sum "$service" | awk '{print $1}')"
PREPARE_RELAY
  chmod 600 "${output}"
}

prepare_relay() {
  local owner_file owner_b64 script output
  owner_file="${OP_TMP}/relay-owner.env"
  render_owner_file "${owner_file}" relay "${RELAY_HOSTKEY_FINGERPRINT}"
  owner_b64="$(openssl base64 -A -in "${owner_file}")"
  create_remote_stage relay "${RELAY_STAGE_PATH}" "${RELAY_STAGE_OWNER_TEMP_PATH}" "${OP_TMP}/owners/relay-stage.env" "${RELAY_STAGE_OWNER_SHA256}" || die 1 '中转 unit staging 创建失败'
  script="${OP_TMP}/prepare-relay.sh"
  write_prepare_relay_script "${script}"
  output="$(ssh_relay_stdin bash -s -- "${RELAY_STAGE_PATH}" "${RELAY_STAGE_OWNER_SHA256}" "${CHAIN_ID}" "${RELAY_PORT}" "${EXIT_HOST}" "${EXIT_REALITY_PORT}" "${SOCKET_PROXYD_PATH}" "${owner_b64}" < "${script}")" || die 1 '中转 socket/service staging 失败'
  RELAY_OWNER_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "RELAY_OWNER_SHA256" {print $2}')"
  RELAY_SOCKET_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "RELAY_SOCKET_SHA256" {print $2}')"
  RELAY_SERVICE_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "RELAY_SERVICE_SHA256" {print $2}')"
  [[ "${RELAY_OWNER_SHA256}" =~ ^[0-9a-f]{64}$ && "${RELAY_SOCKET_SHA256}" =~ ^[0-9a-f]{64}$ && "${RELAY_SERVICE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die 1 '中转 staging hash 不完整'
  LAST_COMPLETED_STEP='RELAY_STAGED'
  write_journal
}

write_promote_relay_script() {
  local output
  output="$1"
  cat > "${output}" <<'PROMOTE_RELAY'
#!/usr/bin/env bash
set -euo pipefail
umask 077
stage="$1"
stage_owner_hash="$2"
chain_id="$3"
owner_hash="$4"
socket_hash="$5"
service_hash="$6"
link_target="$7"
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$stage_owner_hash" ]] || exit 111
owner_src="$stage/$chain_id.owner.env"
socket_src="$stage/ownexit-chain-relay-$chain_id.socket"
service_src="$stage/ownexit-chain-relay-$chain_id.service"
[[ "$(sha256sum "$owner_src" | awk '{print $1}')" == "$owner_hash" ]] || exit 112
[[ "$(sha256sum "$socket_src" | awk '{print $1}')" == "$socket_hash" ]] || exit 113
[[ "$(sha256sum "$service_src" | awk '{print $1}')" == "$service_hash" ]] || exit 114
owner_dst="/etc/ownexit-chain/$chain_id.owner.env"
socket_dst="/etc/systemd/system/ownexit-chain-relay-$chain_id.socket"
service_dst="/etc/systemd/system/ownexit-chain-relay-$chain_id.service"
link_dst="/etc/systemd/system/sockets.target.wants/ownexit-chain-relay-$chain_id.socket"
wants="$(dirname "$link_dst")"
[[ -d "$wants" && ! -L "$wants" && "$(stat -c %u "$wants")" == 0 ]] || exit 115
mode="$(stat -c %a "$wants")"
(( (8#$mode & 8#022) == 0 )) || exit 116
for path in "$owner_dst" "$socket_dst" "$service_dst" "$link_dst"; do
  [[ ! -e "$path" && ! -L "$path" ]] || exit 117
done
link "$owner_src" "$owner_dst"
link "$socket_src" "$socket_dst"
link "$service_src" "$service_dst"
ln --symbolic --no-target-directory "$link_target" "$link_dst"
[[ "$(readlink "$link_dst")" == "$link_target" ]] || exit 118
PROMOTE_RELAY
  chmod 600 "${output}"
}

install_relay() {
  local script
  script="${OP_TMP}/promote-relay.sh"
  write_promote_relay_script "${script}"
  ssh_relay_stdin bash -s -- "${RELAY_STAGE_PATH}" "${RELAY_STAGE_OWNER_SHA256}" "${CHAIN_ID}" "${RELAY_OWNER_SHA256}" "${RELAY_SOCKET_SHA256}" "${RELAY_SERVICE_SHA256}" "${RELAY_ENABLE_LINK_TARGET}" < "${script}" || die 1 '中转专属资源 no-replace 发布失败'
  LAST_COMPLETED_STEP='RELAY_INSTALLED'
  write_journal
  cleanup_remote_stage relay "${RELAY_STAGE_PATH}" "${RELAY_STAGE_OWNER_SHA256}" || die 1 '中转 unit staging 清理失败'
  LAST_COMPLETED_STEP='RELAY_STAGE_CLEANED'
  write_journal
}

activate_relay() {
  local socket service
  socket="ownexit-chain-relay-${CHAIN_ID}.socket"
  service="ownexit-chain-relay-${CHAIN_ID}.service"
  ssh_relay systemctl daemon-reload
  ssh_relay systemctl start "${socket}"
  [[ "$(ssh_relay systemctl is-active "${socket}")" == active ]] || die 1 '中转 socket 未进入 active'
  [[ "$(ssh_relay systemctl is-enabled "${socket}")" == enabled ]] || die 1 '中转 socket 未按预期 enabled'
  ssh_relay "ss -H -ltn | grep -q ':${RELAY_PORT} '" || die 1 '中转 relay 端口未监听'
  LAST_COMPLETED_STEP='RELAY_ACTIVE'
  write_journal
}

choose_local_port() {
  local attempt hex candidate
  attempt=0
  while (( attempt < 200 )); do
    hex="$(openssl rand -hex 2)"
    candidate="$((20000 + (16#${hex} % 40000)))"
    if ! tcp_probe 127.0.0.1 "${candidate}" 1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    attempt="$((attempt + 1))"
  done
  return 1
}

render_client_config() {
  local output local_port server server_port
  output="$1"
  local_port="$2"
  server="$3"
  server_port="$4"
  cat > "${output}" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "mixed",
    "tag": "verify-in",
    "listen": "127.0.0.1",
    "listen_port": ${local_port}
  }],
  "outbounds": [{
    "type": "vless",
    "tag": "exit-via-relay",
    "server": "${server}",
    "server_port": ${server_port},
    "uuid": "${VLESS_UUID}",
    "flow": "xtls-rprx-vision",
    "tls": {
      "enabled": true,
      "server_name": "${REALITY_SERVER_NAME}",
      "utls": { "enabled": true, "fingerprint": "chrome" },
      "reality": {
        "enabled": true,
        "public_key": "${REALITY_PUBLIC_KEY}",
        "short_id": "${REALITY_SHORT_ID}"
      }
    }
  }],
  "route": { "final": "exit-via-relay" }
}
EOF
  chmod 600 "${output}"
}

write_remote_smoke_script() {
  local output config b64
  output="$1"
  config="$2"
  b64="$(openssl base64 -A -in "${config}")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'umask 077'
    printf 'CONFIG_B64=%s\n' "${b64}"
    cat <<'REMOTE_SMOKE'
export LC_ALL=C
expected="$1"
local_port="$2"
binary="/opt/ownexit-chain/bin/sing-box-1.13.14"
tmp="$(mktemp -d /tmp/ownexit-chain-smoke.XXXXXX)"
config="$tmp/client.json"
log="$tmp/client.log"
pid=''
cleanup() {
  if [[ -n "$pid" && -d "/proc/$pid" ]]; then
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$exe" == "$binary" && "$cmd" == *"$config"* ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
printf '%s' "$CONFIG_B64" | base64 -d > "$config"
chmod 600 "$config"
cd /
env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH= LD_PRELOAD= "$binary" check -c "$config" >/dev/null
env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH= LD_PRELOAD= "$binary" run -c "$config" >"$log" 2>&1 &
pid="$!"
[[ "$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)" == "$binary" ]] || exit 121
started=0
attempt=0
while (( attempt < 50 )); do
  if ss -H -ltnp | awk -v port=":$local_port" -v pid="pid=$pid," 'index($4, port) && index($0, pid) {found=1} END {exit found ? 0 : 1}'; then
    started=1
    break
  fi
  kill -0 "$pid" 2>/dev/null || exit 122
  sleep 0.1
  attempt=$((attempt + 1))
done
[[ "$started" == 1 ]] || exit 123
success=0
for endpoint in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
  result="$(
    env -i HOME="$tmp" PATH=/usr/sbin:/usr/bin:/sbin:/bin curl --disable --fail --silent --show-error --proxy "socks5h://127.0.0.1:$local_port" --noproxy '' --max-time 15 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true
  )"
  if [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    [[ "$result" == "$expected" ]] || exit 124
    success=$((success + 1))
  fi
done
(( success >= 2 )) || exit 125
printf 'SMOKE=ok\n'
REMOTE_SMOKE
  } > "${output}"
  chmod 600 "${output}"
}

smoke_from_relay() {
  local server server_port label local_port config runner output
  # 远端 smoke 在中转机临时起 sing-box 并占用固定端口：前一次被断开的那次可能还占着端口，重试会以非 255
  # 失败并误报“Reality smoke 失败”，所以 smoke（含选端口）不参与只读重试（bash 动态作用域，被调函数读到的是这里的 0）。
  local READONLY_SSH_RETRY=0
  server="$1"
  server_port="$2"
  label="$3"
  local_port="$(choose_remote_port relay)" || die 1 "无法为 ${label} 选择中转本地 smoke 端口"
  config="${OP_TMP}/smoke-${label}.json"
  runner="${OP_TMP}/smoke-${label}.sh"
  render_client_config "${config}" "${local_port}" "${server}" "${server_port}"
  write_remote_smoke_script "${runner}" "${config}"
  output="$(ssh_relay_stdin bash -s -- "${EXPECTED_EXIT_IPV4}" "${local_port}" < "${runner}")" || die 1 "${label} Reality smoke 失败"
  [[ "${output}" == SMOKE=ok ]] || die 1 "${label} Reality smoke 返回异常"
}

local_process_metadata_matches() {
  local file operation_id pid start command_hash config_hash binary config op_tmp
  file="$1"
  operation_id="$2"
  require_secure_user_file "${file}" 600 || return 1
  [[ "$(awk -F= '{print $1}' "${file}")" == "$(printf '%s\n' SCHEMA_VERSION OPERATION_ID PID PROCESS_START PROCESS_COMMAND_SHA256 BINARY CONFIG CONFIG_SHA256 OP_TMP_PATH)" ]] || return 1
  [[ "$(kv_get "${file}" SCHEMA_VERSION)" == 1 && "$(kv_get "${file}" OPERATION_ID)" == "${operation_id}" ]] || return 1
  pid="$(kv_get "${file}" PID)"
  start="$(kv_get "${file}" PROCESS_START)"
  command_hash="$(kv_get "${file}" PROCESS_COMMAND_SHA256)"
  config_hash="$(kv_get "${file}" CONFIG_SHA256)"
  binary="$(kv_get "${file}" BINARY)"
  config="$(kv_get "${file}" CONFIG)"
  op_tmp="$(kv_get "${file}" OP_TMP_PATH)"
  [[ "${pid}" =~ ^[1-9][0-9]*$ && -n "${start}" && "${command_hash}" =~ ^[0-9a-f]{64}$ && "${config_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "${binary}" == "${op_tmp}"/* && "${config}" == "${op_tmp}"/* ]] || return 1
}

local_process_identity_status() {
  local file operation_id pid expected_start expected_command current_command binary config command_line
  file="$1"
  operation_id="$2"
  local_process_metadata_matches "${file}" "${operation_id}" || return 2
  pid="$(kv_get "${file}" PID)"
  expected_start="$(kv_get "${file}" PROCESS_START)"
  process_is_running_identity "${pid}" "${expected_start}" || return 1
  expected_command="$(kv_get "${file}" PROCESS_COMMAND_SHA256)"
  current_command="$(process_command_hash "${pid}" 2>/dev/null || true)"
  [[ "${current_command}" == "${expected_command}" ]] && return 0
  binary="$(kv_get "${file}" BINARY)"
  config="$(kv_get "${file}" CONFIG)"
  command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
  case "${command_line}" in
    *"${binary}"*"${config}"*) return 0 ;;
    *) return 2 ;;
  esac
}

local_process_is_live() {
  local_process_identity_status "$1" "$2"
}

publish_local_process() {
  local pid config start command_hash config_hash temp
  pid="$1"
  config="$2"
  start="$3"
  command_hash="$(process_command_hash "${pid}")"
  config_hash="$(sha256_file "${config}")"
  [[ -n "${start}" && "${config}" == "${OP_TMP}"/* && "${DARWIN_BINARY_PATH}" == "${OP_TMP}"/* ]] || return 1
  [[ "${command_hash}" =~ ^[0-9a-f]{64}$ && "${config_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ ! -e "${LOCAL_PROCESS_FILE}" && ! -L "${LOCAL_PROCESS_FILE}" ]] || return 1
  temp="${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp"
  ( set -o noclobber; : > "${temp}" ) 2>/dev/null || return 1
  {
    printf 'SCHEMA_VERSION=1\n'
    printf 'OPERATION_ID=%s\n' "${LOCK_OPERATION_ID}"
    printf 'PID=%s\n' "${pid}"
    printf 'PROCESS_START=%s\n' "${start}"
    printf 'PROCESS_COMMAND_SHA256=%s\n' "${command_hash}"
    printf 'BINARY=%s\n' "${DARWIN_BINARY_PATH}"
    printf 'CONFIG=%s\n' "${config}"
    printf 'CONFIG_SHA256=%s\n' "${config_hash}"
    printf 'OP_TMP_PATH=%s\n' "${OP_TMP}"
  } > "${temp}" || return 1
  chmod 600 "${temp}" || return 1
  sync
  link "${temp}" "${LOCAL_PROCESS_FILE}" || return 1
  rm -f "${temp}" || return 1
}

record_local_pid() {
  local start
  [[ -z "${TEMP_PID}" && -z "${TEMP_PID_CONFIG}" && -z "${TEMP_PID_START}" ]] || die 1 '本地临时进程登记发生重入'
  start="$(process_start_token "$1")"
  [[ -n "${start}" ]] || die 1 '无法读取本地临时进程启动身份'
  TEMP_PID="$1"
  TEMP_PID_CONFIG="$2"
  TEMP_PID_START="${start}"
  if ! publish_local_process "$1" "$2" "${start}"; then
    terminate_pid_with_start "$1" "${start}" || true
    remove_recorded_local_pid "$1" || true
    die 1 '本地临时进程持久登记失败'
  fi
}

terminate_pid_with_start() {
  local pid expected_start attempt
  pid="$1"
  expected_start="$2"
  [[ "${pid}" =~ ^[1-9][0-9]*$ && -n "${expected_start}" ]] || return 1
  if process_is_running_identity "${pid}" "${expected_start}"; then
    kill "${pid}" 2>/dev/null || true
    attempt=0
    while (( attempt < 50 )) && process_is_running_identity "${pid}" "${expected_start}"; do
      sleep 0.1
      attempt="$((attempt + 1))"
    done
    if process_is_running_identity "${pid}" "${expected_start}"; then
      kill -9 "${pid}" 2>/dev/null || true
      attempt=0
      while (( attempt < 50 )) && process_is_running_identity "${pid}" "${expected_start}"; do
        sleep 0.1
        attempt="$((attempt + 1))"
      done
    fi
    process_is_running_identity "${pid}" "${expected_start}" && return 1
    wait "${pid}" 2>/dev/null || true
  fi
  ! process_is_running_identity "${pid}" "${expected_start}"
}

cleanup_one_local_pid() {
  local pid config expected_start identity_rc
  pid="$1"
  config="$2"
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 0
  expected_start="${TEMP_PID_START}"
  if [[ -e "${LOCAL_PROCESS_FILE}" || -L "${LOCAL_PROCESS_FILE}" ]]; then
    local_process_metadata_matches "${LOCAL_PROCESS_FILE}" "${LOCK_OPERATION_ID}" || return 1
    [[ "$(kv_get "${LOCAL_PROCESS_FILE}" PID)" == "${pid}" && "$(kv_get "${LOCAL_PROCESS_FILE}" CONFIG)" == "${config}" ]] || return 1
    expected_start="$(kv_get "${LOCAL_PROCESS_FILE}" PROCESS_START)"
    if local_process_identity_status "${LOCAL_PROCESS_FILE}" "${LOCK_OPERATION_ID}"; then
      identity_rc=0
    else
      identity_rc="$?"
    fi
    [[ "${identity_rc}" -ne 2 ]] || return 1
    [[ "${identity_rc}" -eq 0 ]] || return 0
  fi
  terminate_pid_with_start "${pid}" "${expected_start}"
}

remove_recorded_local_pid() {
  local wanted identity_rc
  wanted="$1"
  [[ "${TEMP_PID}" == "${wanted}" ]] || return 1
  if [[ -e "${LOCAL_PROCESS_FILE}" || -L "${LOCAL_PROCESS_FILE}" ]]; then
    local_process_metadata_matches "${LOCAL_PROCESS_FILE}" "${LOCK_OPERATION_ID}" || return 1
    [[ "$(kv_get "${LOCAL_PROCESS_FILE}" PID)" == "${wanted}" ]] || return 1
    if local_process_identity_status "${LOCAL_PROCESS_FILE}" "${LOCK_OPERATION_ID}"; then
      identity_rc=0
    else
      identity_rc="$?"
    fi
    [[ "${identity_rc}" -eq 1 ]] || return 1
    rm -f "${LOCAL_PROCESS_FILE}"
  fi
  if [[ -e "${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp" || -L "${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp" ]]; then
    require_secure_user_file "${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp" 600 || return 1
    rm -f "${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp"
  fi
  TEMP_PID=''
  TEMP_PID_CONFIG=''
  TEMP_PID_START=''
}

start_local_smoke_process() {
  local config log gate pid token
  config="$1"
  log="$2"
  gate="${OP_TMP}/local-process-gate.${LOCK_OPERATION_ID}"
  [[ ! -e "${gate}" && ! -L "${gate}" ]] || die 1 '本地临时进程 gate 路径碰撞'
  mkfifo -m 600 "${gate}" || die 1 '无法创建本地临时进程 gate'
  (
    exec 9<>"${gate}"
    IFS= read -r -t 10 token <&9 || exit 124
    exec 9>&-
    [[ "${token}" == go ]] || exit 125
    exec "${DARWIN_BINARY_PATH}" run -c "${config}"
  ) >"${log}" 2>&1 &
  pid="$!"
  LOCAL_PROCESS_GATE="${gate}"
  record_local_pid "${pid}" "${config}"
  if ! printf 'go\n' > "${gate}"; then
    cleanup_one_local_pid "${pid}" "${config}" || true
    remove_recorded_local_pid "${pid}" || true
    die 1 '无法放行本地临时进程 gate'
  fi
  rm -f "${gate}"
  LOCAL_PROCESS_GATE=''
}

smoke_from_mac() {
  local local_port config log pid started success endpoint result interface
  if [[ "${DARWIN_BINARY_SHA256}" == NONE || -z "${DARWIN_BINARY_PATH}" ]]; then
    log_warn '没有本机平台的官方包，跳过本机层出口 smoke（非硬门槛，中转侧第 2/3 层已是部署硬门槛）'
    return 0
  fi
  interface="$(route_interface "${RELAY_HOST}")"
  [[ -n "${interface}" ]] || die 1 '无法判定本机到中转的实际路由接口'
  if interface_is_tunnel "${interface}"; then
    log_warn "本机到中转的路由经过 TUN（${interface}）；跳过本机层出口 smoke（非硬门槛，中转侧第 2/3 层已是部署硬门槛）"
    return 0
  fi
  local_port="$(choose_local_port)" || die 1 '无法为本机 smoke 选择本地端口'
  config="${OP_TMP}/smoke-mac.json"
  log="${OP_TMP}/smoke-mac.log"
  render_client_config "${config}" "${local_port}" "${RELAY_HOST}" "${RELAY_PORT}"
  "${DARWIN_BINARY_PATH}" check -c "${config}" >/dev/null || die 1 '本机 smoke config check 失败'
  start_local_smoke_process "${config}" "${log}"
  pid="${TEMP_PID}"
  started=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
    if tcp_probe 127.0.0.1 "${local_port}" 1; then
      started=1
      break
    fi
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  [[ "${started}" == 1 ]] || die 1 '本机临时 sing-box 未监听'
  success=0
  for endpoint in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
    result="$(
      env -i HOME="${OP_TMP}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" curl --disable --fail --silent --show-error --proxy "socks5h://127.0.0.1:${local_port}" --noproxy '' --max-time 15 "${endpoint}" 2>/dev/null | tr -d '[:space:]' || true
    )"
    if is_ipv4 "${result}"; then
      [[ "${result}" == "${EXPECTED_EXIT_IPV4}" ]] || die 1 '本机 smoke 得到非预期出口'
      success="$((success + 1))"
    fi
  done
  cleanup_one_local_pid "${pid}" "${config}"
  remove_recorded_local_pid "${pid}"
  (( success >= 2 )) || die 1 '本机 smoke 未通过 2-of-3 出口仲裁'
}

# 拒绝侧：本机（非中转来源）直连出口机 Reality 端口应当失败。provider（服务商白名单）与 managed（本项目 nft 白名单）
# 时是硬门槛；none 时能连上只记 WARN。本机经 TUN 出去时代理会接管连接，结果不可信，跳过并 WARN，不能当作通过。
probe_mac_reality_rejection() {
  local interface
  interface="$(route_interface "${EXIT_HOST}")"
  [[ -n "${interface}" ]] || die 1 '无法判定本机到出口机的实际路由接口'
  if interface_is_tunnel "${interface}"; then
    log_warn "本机到出口机的路由经过 TUN（${interface}）；非中转来源拒绝侧未验证（EXIT_SOURCE_FILTER=${EXIT_SOURCE_FILTER}），需在不经 TUN 的环境再跑 verify"
    return 0
  fi
  if tcp_probe "${EXIT_HOST}" "${EXIT_REALITY_PORT}" 5; then
    # none 时这是普通 VPS 的预期状态，没有凭据仍无法使用该端口。
    [[ "${EXIT_SOURCE_FILTER}" == none ]] || die 1 "非中转来源可直连出口机 Reality 端口，白名单拒绝侧失败（EXIT_SOURCE_FILTER=${EXIT_SOURCE_FILTER}）"
    log_warn '出口机 Reality 端口对非中转来源开放（EXIT_SOURCE_FILTER=none，未配置白名单；没有凭据仍无法使用）'
    return 0
  fi
  log_info '出口机 Reality 端口的本机直连拒绝侧通过'
}

render_node_artifact() {
  local output
  output="$1"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#Exit-via-Relay-%s\n' \
    "${VLESS_UUID}" "${RELAY_HOST}" "${RELAY_PORT}" "${REALITY_SERVER_NAME}" \
    "${REALITY_PUBLIC_KEY}" "${REALITY_SHORT_ID}" "${CHAIN_ID}" > "${output}"
  chmod 600 "${output}"
}

publish_local_artifacts() {
  local baseline_stage client_stage final_baseline final_client file
  baseline_stage="${LOCAL_STAGE_PATH}/baseline"
  client_stage="${LOCAL_STAGE_PATH}/client"
  mkdir "${client_stage}"
  chmod 700 "${client_stage}"
  render_node_artifact "${client_stage}/node.txt"
  NODE_SHA256="$(sha256_file "${client_stage}/node.txt")"
  write_journal
  final_baseline="${CHAIN_STATE_DIR}/baseline"
  final_client="${CHAIN_STATE_DIR}/client"
  [[ ! -e "${final_baseline}" && ! -L "${final_baseline}" ]] || die 4 '本地 baseline 目录碰撞'
  [[ ! -e "${final_client}" && ! -L "${final_client}" ]] || die 4 '本地 client 目录碰撞'
  mkdir "${final_baseline}"
  mkdir "${final_client}"
  chmod 700 "${final_baseline}" "${final_client}"
  for file in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
    link "${baseline_stage}/${file}" "${final_baseline}/${file}" || die 1 "本地 baseline no-replace 发布失败：${file}"
  done
  link "${client_stage}/node.txt" "${final_client}/node.txt" || die 1 'node.txt no-replace 发布失败'
  [[ "$(sha256_file "${final_client}/node.txt")" == "${NODE_SHA256}" ]] || die 1 'node.txt 发布后 hash 不符'
  cleanup_local_stage_if_owned || die 1 '本地 staging owner/允许清单复核失败'
  LAST_COMPLETED_STEP='LOCAL_ARTIFACTS_READY'
  write_journal
}

verify_local_artifacts() {
  local baseline file
  baseline="${CHAIN_STATE_DIR}/baseline"
  [[ -d "${baseline}" && ! -L "${baseline}" && "$(stat_uid "${baseline}")" == "$(id -u)" && "$(stat_mode "${baseline}")" == 700 ]] || return 1
  [[ -d "${CHAIN_STATE_DIR}/client" && ! -L "${CHAIN_STATE_DIR}/client" && "$(stat_uid "${CHAIN_STATE_DIR}/client")" == "$(id -u)" && "$(stat_mode "${CHAIN_STATE_DIR}/client")" == 700 ]] || return 1
  for file in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
    require_secure_user_file "${baseline}/${file}" 600 || return 1
  done
  require_secure_user_file "${CHAIN_STATE_DIR}/client/node.txt" 600 || return 1
  [[ "$(sha256_file "${baseline}/relay-config-manifest.txt")" == "${RELAY_BASELINE_CONFIG_MANIFEST_SHA256}" ]] || return 1
  [[ "$(sha256_file "${baseline}/relay-unit-manifest.txt")" == "${RELAY_BASELINE_UNIT_MANIFEST_SHA256}" ]] || return 1
  [[ "$(sha256_file "${baseline}/relay-binary-manifest.txt")" == "${RELAY_BASELINE_BINARY_MANIFEST_SHA256}" ]] || return 1
  [[ "$(sha256_file "${baseline}/relay-listeners.txt")" == "${RELAY_BASELINE_LISTEN_SHA256}" ]] || return 1
  [[ "$(sha256_file "${CHAIN_STATE_DIR}/client/node.txt")" == "${NODE_SHA256}" ]]
}

state_matches_loaded_transaction() {
  local expected_file line key value
  validate_checksum_env "${STATE_FILE}" state || return 1
  [[ "$(kv_get "${STATE_FILE}" SCHEMA_VERSION)" == 1 && "$(kv_get "${STATE_FILE}" STATUS)" == deployed ]] || return 1
  expected_file="${OP_TMP}/expected-common-state"
  emit_common_state_fields > "${expected_file}"
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$(kv_get "${STATE_FILE}" "${key}")" == "${value}" ]] || return 1
  done < "${expected_file}"
}

local_deployment_residue_absent() {
  local candidate
  for candidate in \
    "${CHAIN_STATE_DIR}/active-child.env" \
    "${CHAIN_STATE_DIR}/local-process.env" \
    "${CHAIN_STATE_DIR}"/.active-child.*.tmp \
    "${CHAIN_STATE_DIR}"/.local-process.*.tmp \
    "${CHAIN_STATE_DIR}"/.stage-local-* \
    "${CHAIN_STATE_DIR}"/.stage-owner.*.tmp \
    "${CHAIN_STATE_DIR}"/.state.env.*.tmp \
    "${CHAIN_STATE_DIR}"/.transaction.env.*.tmp \
    "${CHAIN_STATE_DIR}"/.node.txt.rotate.*.tmp \
    "${CHAIN_STATE_DIR}"/devices/.*.tmp \
    "${CHAIN_STATE_DIR}"/.migrate-exit.env.*.tmp \
    "${CHAIN_STATE_DIR}"/.lock.*.chain.tmp; do
    [[ ! -e "${candidate}" && ! -L "${candidate}" ]] || return 1
  done
  if [[ -d "${CHAIN_STATE_DIR}/audit" && ! -L "${CHAIN_STATE_DIR}/audit" ]]; then
    [[ -z "$(find "${CHAIN_STATE_DIR}/audit" -type f -name '.*.tmp' -print -quit)" ]] || return 1
  fi
}

write_remote_residue_check_script() {
  local output
  output="$1"
  cat > "${output}" <<'REMOTE_RESIDUE_CHECK'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
chain_id="$1"
config_hash="$2"
deployment_id="$3"
for parent in /etc/ownexit-chain /opt/ownexit-chain; do
  [[ -d "$parent" && ! -L "$parent" ]] || continue
  find "$parent" -maxdepth 1 -type d -name '.stage-*' -print | while IFS= read -r stage; do
    owner="$stage/stage-owner.env"
    if [[ "$stage" == *"$deployment_id" ]]; then
      exit 9
    fi
    [[ -f "$owner" && ! -L "$owner" ]] || continue
    grep -qx "CHAIN_ID=$chain_id" "$owner" || continue
    grep -qx "CONFIG_SHA256=$config_hash" "$owner" || continue
    exit 9
  done
  status="$?"
  [[ "$status" -eq 0 ]] || exit 1
  find "$parent" -maxdepth 1 -type f \( -name '.owner-*.part' -o -name '.owner-*.ready' \) -print | while IFS= read -r owner_temp; do
    if [[ "$owner_temp" == *"$deployment_id"* ]]; then
      exit 9
    fi
    [[ ! -L "$owner_temp" && "$(stat -c %u:%g:%a "$owner_temp")" == 0:0:600 ]] || continue
    grep -qx "CHAIN_ID=$chain_id" "$owner_temp" || continue
    grep -qx "CONFIG_SHA256=$config_hash" "$owner_temp" || continue
    exit 9
  done
  status="$?"
  [[ "$status" -eq 0 ]] || exit 1
done
REMOTE_RESIDUE_CHECK
  chmod 600 "${output}"
}

probe_deployment_residue() {
  local script rc
  local_deployment_residue_absent || return 30
  script="${OP_TMP}/remote-residue-check.sh"
  write_remote_residue_check_script "${script}" || return 30
  if ssh_relay_stdin bash -s -- "${CHAIN_ID}" "${CONFIG_SHA256}" "${DEPLOYMENT_ID}" < "${script}" >/dev/null; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || { [[ "${rc}" -eq 255 ]] && return 21; return 31; }
  if ssh_exit_stdin bash -s -- "${CHAIN_ID}" "${CONFIG_SHA256}" "${DEPLOYMENT_ID}" < "${script}" >/dev/null; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || { [[ "${rc}" -eq 255 ]] && return 22; return 32; }
}

deployment_residue_absent() {
  local rc
  if probe_deployment_residue; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]]
}

probe_relay_baseline() {
  local current file expected_active expected_enabled rc
  current="${OP_TMP}/baseline-current"
  expected_active="${RELAY_BASELINE_SERVICE_ACTIVE}"
  expected_enabled="${RELAY_BASELINE_SERVICE_ENABLED}"
  if probe_collect_relay_baseline "${current}"; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || return "${rc}"
  [[ "${RELAY_BASELINE_SERVICE_ACTIVE}" == "${expected_active}" ]] || return 41
  [[ "${RELAY_BASELINE_SERVICE_ENABLED}" == "${expected_enabled}" ]] || return 41
  for file in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
    cmp -s "${current}/${file}" "${CHAIN_STATE_DIR}/baseline/${file}" || return 41
  done
}

verify_relay_baseline() {
  probe_relay_baseline
}

write_verify_exit_script() {
  local output
  output="$1"
  cat > "${output}" <<'VERIFY_EXIT'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
chain_id="$1"
port="$2"
binary_hash="$3"
owner_hash="$4"
config_hash="$5"
unit_hash="$6"
link_target="$7"
link_hash="$8"
binary="/opt/ownexit-chain/bin/sing-box-1.13.14"
owner="/etc/ownexit-chain/$chain_id.owner.env"
config="/etc/ownexit-chain/$chain_id.exit.json"
unit="/etc/systemd/system/ownexit-chain-exit-$chain_id.service"
unit_name="ownexit-chain-exit-$chain_id.service"
link_path="/etc/systemd/system/multi-user.target.wants/$unit_name"

[[ -f "$binary" && ! -L "$binary" && "$(stat -c %u:%g:%a "$binary")" == 0:0:755 ]] || exit 131
[[ "$(sha256sum "$binary" | awk '{print $1}')" == "$binary_hash" ]] || exit 132
[[ ! -e "$(dirname "$binary")/libcronet.so" && ! -L "$(dirname "$binary")/libcronet.so" ]] || exit 133
[[ -f "$owner" && ! -L "$owner" && "$(stat -c %u:%g:%a "$owner")" == 0:0:600 ]] || exit 134
[[ -f "$config" && ! -L "$config" && "$(stat -c %u:%g:%a "$config")" == 0:0:600 ]] || exit 135
[[ -f "$unit" && ! -L "$unit" && "$(stat -c %u:%g:%a "$unit")" == 0:0:644 ]] || exit 136
[[ "$(sha256sum "$owner" | awk '{print $1}')" == "$owner_hash" ]] || exit 137
[[ "$(sha256sum "$config" | awk '{print $1}')" == "$config_hash" ]] || exit 138
[[ "$(sha256sum "$unit" | awk '{print $1}')" == "$unit_hash" ]] || exit 139
[[ -L "$link_path" && "$(readlink "$link_path")" == "$link_target" ]] || exit 140
[[ "$(printf '%s' "$(readlink "$link_path")" | sha256sum | awk '{print $1}')" == "$link_hash" ]] || exit 141
[[ "$(readlink -f "$link_path")" == "$unit" ]] || exit 142
fragment="$(systemctl show "$unit_name" -p FragmentPath --value)"
dropins="$(systemctl show "$unit_name" -p DropInPaths --value)"
[[ "$fragment" == "$unit" && -z "$dropins" ]] || exit 143
unit_paths="$(systemd-analyze unit-paths)"
while IFS= read -r unit_path; do
  [[ -n "$unit_path" ]] || continue
  candidate="$unit_path/$unit_name"
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    [[ "$candidate" == "$unit" && -f "$candidate" && ! -L "$candidate" ]] || exit 148
  fi
  [[ ! -e "$candidate.d" && ! -L "$candidate.d" ]] || exit 149
done <<EOF
$unit_paths
EOF
[[ "$(systemctl is-enabled "$unit_name")" == enabled ]] || exit 144
[[ "$(systemctl is-active "$unit_name")" == active ]] || exit 145
pid="$(systemctl show "$unit_name" -p MainPID --value)"
[[ "$pid" =~ ^[1-9][0-9]*$ && "$(readlink -f "/proc/$pid/exe")" == "$binary" ]] || exit 146
ss -H -ltnp | awk -v suffix=":$port" -v pid="pid=$pid," 'substr($4, length($4)-length(suffix)+1) == suffix && index($0, pid) {found=1} END {exit found ? 0 : 1}' || exit 147
# rotate-keys 的辅助文件（待切换配置 / 参数 / 旧配置备份 / 临时文件）只在命令中途存在；还在就说明轮换没收尾，
# 必须先重跑中断的那条命令（rotate-keys / add-device / remove-device），否则 rollback 会把含私钥的辅助文件留在机器上。
for rotate_leftover in "/etc/ownexit-chain/$chain_id".rotate.*; do
  [[ ! -e "$rotate_leftover" && ! -L "$rotate_leftover" ]] || exit 150
done
cd /
env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH= LD_PRELOAD= "$binary" check -c "$config" >/dev/null
printf 'VERIFY_EXIT=ok\n'
VERIFY_EXIT
  chmod 600 "${output}"
}

write_verify_relay_script() {
  local output
  output="$1"
  cat > "${output}" <<'VERIFY_RELAY'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
chain_id="$1"
port="$2"
binary_hash="$3"
owner_hash="$4"
socket_hash="$5"
service_hash="$6"
link_target="$7"
link_hash="$8"
proxyd="$9"
allow_start="${10}"
# 控制端由本地 blacklist.txt 渲染的预期 IPAddressDeny 回读串。ssh 会把参数拼成一条命令串交远端 shell
# 重新分词：空串会被吞、含空格会被拆，所以控制端用逗号连接、空列表用哨兵 "-"，这里再还原成空格分隔。
expected_deny="${11}"
[[ "$expected_deny" != '-' ]] || expected_deny=''
expected_deny="${expected_deny//,/ }"
dropin_name="${12}"
binary="/opt/ownexit-chain/bin/sing-box-1.13.14"
owner="/etc/ownexit-chain/$chain_id.owner.env"
socket="/etc/systemd/system/ownexit-chain-relay-$chain_id.socket"
service="/etc/systemd/system/ownexit-chain-relay-$chain_id.service"
socket_name="ownexit-chain-relay-$chain_id.socket"
service_name="ownexit-chain-relay-$chain_id.service"
link_path="/etc/systemd/system/sockets.target.wants/$socket_name"

# 唯一放行的 drop-in：黑名单非空时两个 unit 各恰好一个受管文件，黑名单为空时 .d 目录必须不存在。
# 任何其它 drop-in（含 /run、system.control 下 set-property 生成的）仍按 drift 处理。
check_managed_dropin() {
  local unit_name unit_file section dropins dir
  unit_name="$1"
  unit_file="$2"
  section="$3"
  dir="$unit_file.d"
  dropins="$(systemctl show "$unit_name" -p DropInPaths --value)"
  if [[ -z "$expected_deny" ]]; then
    [[ -z "$dropins" ]] || exit 175
    [[ ! -e "$dir" && ! -L "$dir" ]] || exit 176
  else
    [[ "$dropins" == "$dir/$dropin_name" ]] || exit 175
    [[ -d "$dir" && ! -L "$dir" && "$(stat -c %u:%g "$dir")" == 0:0 ]] || exit 176
    [[ "$(find "$dir" -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 1 ]] || exit 176
    [[ -f "$dir/$dropin_name" && ! -L "$dir/$dropin_name" && "$(stat -c %u:%g:%a "$dir/$dropin_name")" == 0:0:644 ]] || exit 176
    [[ "$(head -n 1 "$dir/$dropin_name")" == "[$section]" ]] || exit 176
  fi
  [[ "$(sorted_words "$(systemctl show "$unit_name" -p IPAddressDeny --value)")" == "$(sorted_words "$expected_deny")" ]] || exit 177
}

# systemd 回显的顺序不可依赖（内部按前缀归并排序），两端都按集合比较。
sorted_words() {
  printf '%s\n' "$1" | tr ' ' '\n' | awk 'NF' | sort | tr '\n' ' ' | sed -e 's/ *$//'
}

[[ -f "$binary" && ! -L "$binary" && "$(stat -c %u:%g:%a "$binary")" == 0:0:755 ]] || exit 151
[[ "$(sha256sum "$binary" | awk '{print $1}')" == "$binary_hash" ]] || exit 152
[[ ! -e "$(dirname "$binary")/libcronet.so" && ! -L "$(dirname "$binary")/libcronet.so" ]] || exit 153
[[ -f "$owner" && ! -L "$owner" && "$(stat -c %u:%g:%a "$owner")" == 0:0:600 ]] || exit 154
[[ -f "$socket" && ! -L "$socket" && "$(stat -c %u:%g:%a "$socket")" == 0:0:644 ]] || exit 155
[[ -f "$service" && ! -L "$service" && "$(stat -c %u:%g:%a "$service")" == 0:0:644 ]] || exit 156
[[ "$(sha256sum "$owner" | awk '{print $1}')" == "$owner_hash" ]] || exit 157
[[ "$(sha256sum "$socket" | awk '{print $1}')" == "$socket_hash" ]] || exit 158
[[ "$(sha256sum "$service" | awk '{print $1}')" == "$service_hash" ]] || exit 159
[[ -L "$link_path" && "$(readlink "$link_path")" == "$link_target" ]] || exit 160
[[ "$(printf '%s' "$(readlink "$link_path")" | sha256sum | awk '{print $1}')" == "$link_hash" ]] || exit 161
[[ "$(readlink -f "$link_path")" == "$socket" ]] || exit 162
[[ "$(systemctl show "$socket_name" -p FragmentPath --value)" == "$socket" ]] || exit 163
check_managed_dropin "$socket_name" "$socket" Socket
[[ "$(systemctl show "$service_name" -p FragmentPath --value)" == "$service" ]] || exit 165
check_managed_dropin "$service_name" "$service" Service
unit_paths="$(systemd-analyze unit-paths)"
while IFS= read -r unit_path; do
  [[ -n "$unit_path" ]] || continue
  for pair in "$socket_name:$socket" "$service_name:$service"; do
    name="${pair%%:*}"
    expected_path="${pair#*:}"
    candidate="$unit_path/$name"
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      [[ "$candidate" == "$expected_path" && -f "$candidate" && ! -L "$candidate" ]] || exit 173
    fi
    # 受管 .d 目录只允许出现在主 unit 所在的 /etc/systemd/system；其它 load path 下的 .d 仍是 drift。
    if [[ "$candidate" == "$expected_path" && -n "$expected_deny" ]]; then
      continue
    fi
    [[ ! -e "$candidate.d" && ! -L "$candidate.d" ]] || exit 174
  done
done <<EOF
$unit_paths
EOF
[[ "$(systemctl is-enabled "$socket_name")" == enabled ]] || exit 167
[[ "$(systemctl is-active "$socket_name")" == active ]] || exit 168
ss -H -ltn | awk -v suffix=":$port" 'substr($4, length($4)-length(suffix)+1) == suffix {found=1} END {exit found ? 0 : 1}' || exit 169
active="$(systemctl is-active "$service_name" 2>/dev/null || true)"
if [[ "$active" != active && "$allow_start" == yes ]]; then
  systemctl start "$service_name"
  active="$(systemctl is-active "$service_name" 2>/dev/null || true)"
fi
[[ "$active" == active ]] || exit 170
pid="$(systemctl show "$service_name" -p MainPID --value)"
[[ "$pid" =~ ^[1-9][0-9]*$ && "$(readlink -f "/proc/$pid/exe")" == "$proxyd" ]] || exit 171
requires="$(systemctl show "$service_name" -p Requires --value)"
case " $requires " in *" $socket_name "*) ;; *) exit 172 ;; esac
printf 'VERIFY_RELAY=ok\n'
VERIFY_RELAY
  chmod 600 "${output}"
}

probe_remote_resources() {
  local allow_relay_start exit_script relay_script output rc expected_deny
  allow_relay_start="$1"
  exit_script="${OP_TMP}/verify-exit.sh"
  relay_script="${OP_TMP}/verify-relay.sh"
  write_verify_exit_script "${exit_script}" || return 30
  write_verify_relay_script "${relay_script}" || return 30
  # 本地黑名单是权威副本：渲染预期回读串交给远端核对，本地空 ⇔ 远端无 drop-in 且 IPAddressDeny 为空。
  expected_deny="$(render_expected_deny)" || return 30
  expected_deny="${expected_deny// /,}"
  [[ -n "${expected_deny}" ]] || expected_deny='-'
  if output="$(ssh_exit_stdin bash -s -- "${CHAIN_ID}" "${EXIT_REALITY_PORT}" "${LINUX_BINARY_SHA256}" "${EXIT_OWNER_SHA256}" "${EXIT_EXIT_SHA256}" "${EXIT_SERVICE_SHA256}" "${EXIT_ENABLE_LINK_TARGET}" "${EXIT_ENABLE_LINK_SHA256}" < "${exit_script}")"; then
    rc=0
  else
    rc="$?"
  fi
  # 150 = 出口机上有未收尾的凭据 / 设备操作辅助文件；单独返回 33，让 status / verify / rollback 能提示重跑中断的命令。
  [[ "${rc}" -ne 150 ]] || return 33
  [[ "${rc}" -eq 0 ]] || { [[ "${rc}" -eq 255 ]] && return 22; return 32; }
  [[ "${output}" == VERIFY_EXIT=ok ]] || return 32
  if [[ "${EXIT_SOURCE_FILTER}" == managed ]]; then
    # 规则本身写在 unit 里（已由 EXIT_SERVICE_SHA256 核对）；这里确认它确实被加载，没被人手工删掉。
    if ssh_exit nft list table inet "ownexit_${CHAIN_ID//-/_}" >/dev/null 2>&1; then rc=0; else rc="$?"; fi
    [[ "${rc}" -ne 255 ]] || return 22
    [[ "${rc}" -eq 0 ]] || return 32
  fi
  if output="$(ssh_relay_stdin bash -s -- "${CHAIN_ID}" "${RELAY_PORT}" "${LINUX_BINARY_SHA256}" "${RELAY_OWNER_SHA256}" "${RELAY_SOCKET_SHA256}" "${RELAY_SERVICE_SHA256}" "${RELAY_ENABLE_LINK_TARGET}" "${RELAY_ENABLE_LINK_SHA256}" "${SOCKET_PROXYD_PATH}" "${allow_relay_start}" "${expected_deny}" "${RELAY_BLACKLIST_DROPIN}" < "${relay_script}")"; then
    rc=0
  else
    rc="$?"
  fi
  [[ "${rc}" -eq 0 ]] || { [[ "${rc}" -eq 255 ]] && return 21; return 31; }
  [[ "${output}" == VERIFY_RELAY=ok ]] || return 31
}

verify_remote_resources() {
  local rc
  if probe_remote_resources "$1"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]]
}

# 远端 binary 哈希来自状态（已由 adopt_recorded_assets 对照常量），这里只重新准备本机 smoke 用的包。
# 本机平台与部署时不同（换了控制端，或部署时没拿到本机包）不算 drift：本机 smoke 只是验证手段，按现在的平台进行。
ensure_local_assets_match_state() {
  local recorded_archive
  recorded_archive="${DARWIN_ARCHIVE_SHA256}"
  prepare_verified_assets readonly
  if [[ "${recorded_archive}" != "${DARWIN_ARCHIVE_SHA256}" ]]; then
    log_warn "本机平台的官方包与部署时不同（部署时=$(platform_of_archive_sha256 "${recorded_archive}" || printf 'NONE')，现在=${LOCAL_PLATFORM:-无}），本机侧出口验证按现在的平台进行"
  fi
}

verify_chain_smokes() {
  smoke_from_relay 127.0.0.1 "${RELAY_PORT}" relay-full
  smoke_from_mac
}

full_verify() {
  local rc
  remote_platform_preflight
  probe_exit_tls
  probe_exit_exit
  if probe_remote_resources yes; then rc=0; else rc="$?"; fi
  [[ "${rc}" -ne 33 ]] || die 5 '出口机上有未完成的凭据或设备操作（辅助文件未清理）；重跑中断的那条命令（rotate-keys / add-device / remove-device）收敛'
  [[ "${rc}" -eq 0 ]] || die 5 '远端文件、unit、进程、listener 或 binary 发生 drift'
  verify_local_artifacts || die 5 '本地 state 配套产物发生 drift'
  verify_relay_baseline || die 5 '中转既有 sing-box 零回归基线发生变化'
  smoke_from_relay "${EXIT_HOST}" "${EXIT_REALITY_PORT}" exit-direct
  probe_mac_reality_rejection
  verify_chain_smokes
  deployment_residue_absent || die 5 '发现本 deployment 或当前 chain/config 的 staging、owner-temp、child/temp 残留'
}

check_remote_shared_binary_or_absent() {
  local role script
  role="$1"
  script="${OP_TMP}/shared-binary-check.sh"
  cat > "${script}" <<'SHARED_CHECK'
#!/usr/bin/env bash
set -euo pipefail
umask 077
expected="$1"
version="$2"
binary="/opt/ownexit-chain/bin/sing-box-$version"
for directory in /opt/ownexit-chain /opt/ownexit-chain/bin /etc/ownexit-chain; do
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" && "$(stat -c %u:%g:%a "$directory")" == 0:0:755 ]] || exit 181
  fi
done
[[ ! -e /opt/ownexit-chain/bin/libcronet.so && ! -L /opt/ownexit-chain/bin/libcronet.so ]] || exit 184
if [[ -e "$binary" || -L "$binary" ]]; then
  [[ -f "$binary" && ! -L "$binary" && "$(stat -c %u:%g:%a "$binary")" == 0:0:755 ]] || exit 182
  [[ "$(sha256sum "$binary" | awk '{print $1}')" == "$expected" ]] || exit 183
  cd /
  actual="$(env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH= LD_PRELOAD= "$binary" version | awk '/^sing-box version / {print $3; exit}')"
  [[ "$actual" == "$version" ]] || exit 185
fi
SHARED_CHECK
  chmod 600 "${script}"
  if [[ "${role}" == relay ]]; then
    ssh_relay_stdin bash -s -- "${LINUX_BINARY_SHA256}" "${SING_BOX_VERSION}" < "${script}"
  else
    ssh_exit_stdin bash -s -- "${LINUX_BINARY_SHA256}" "${SING_BOX_VERSION}" < "${script}"
  fi
}

preflight_chain() {
  local before after baseline actual_linux actual_darwin state_relay_fp state_exit_fp
  if [[ -e "${CHAIN_STATE_DIR}" || -L "${CHAIN_STATE_DIR}" ]]; then
    private_dir_is_safe "${CHAIN_STATE_DIR}" || die 3 '现有 chain state 目录身份或权限不安全'
  fi
  before="$(snapshot_operation_state)"
  printf '%s\n' "${before}" | grep -qv '|absent$' && die 3 'preflight 起点存在 operation lock 或 transaction'
  require_local_dependencies
  prepare_verified_assets readonly
  actual_darwin="${DARWIN_BINARY_SHA256}"
  render_ssh_config
  probe_ssh_and_fingerprints
  remote_platform_preflight
  # 远端架构由预检确定后，LINUX_BINARY_SHA256 才是本次现场对应的常量。
  actual_linux="${LINUX_BINARY_SHA256}"
  probe_exit_tls
  probe_exit_exit
  check_remote_shared_binary_or_absent relay || die 3 '中转共享 binary/目录发生 drift'
  check_remote_shared_binary_or_absent exit || die 3 '出口机共享 binary/目录发生 drift'
  baseline="${OP_TMP}/baseline-preflight"
  collect_relay_baseline "${baseline}"
  if [[ -e "${STATE_FILE}" || -L "${STATE_FILE}" ]]; then
    state_relay_fp="${RELAY_HOSTKEY_FINGERPRINT}"
    state_exit_fp="${EXIT_HOSTKEY_FINGERPRINT}"
    load_state_file "${STATE_FILE}"
    [[ "${LINUX_BINARY_SHA256}" == "${actual_linux}" ]] || die 3 'active state 的远端官方 binary hash 与现场架构的固定资产不一致'
    [[ "${DARWIN_BINARY_SHA256}" == "${actual_darwin}" ]] || log_warn '本机平台的官方包与部署时不同，本机侧出口验证按现在的平台进行'
    [[ "${RELAY_HOSTKEY_FINGERPRINT}" == "${state_relay_fp}" && "${EXIT_HOSTKEY_FINGERPRINT}" == "${state_exit_fp}" ]] || die 3 'active state 的 host-key 指纹与当前连接不一致'
    remote_platform_preflight
    verify_remote_resources no || die 3 'active chain 远端资源不健康'
    verify_local_artifacts || die 3 'active chain 本地产物不健康'
    verify_relay_baseline || die 3 'active chain 的既有 sing-box 基线变化'
  else
    check_initial_collisions
  fi
  after="$(snapshot_operation_state)"
  [[ "${before}" == "${after}" ]] || die 3 'preflight 期间 lock/journal 身份发生变化'
  log_info "preflight 通过；chain=${CHAIN_ID} elapsed=$(elapsed_seconds)s"
}

archive_deploy_transaction() {
  local audit transaction_copy complete payload_hash
  audit="${CHAIN_STATE_DIR}/audit/deployed.${DEPLOYMENT_ID}.${OPERATION_ID}"
  ensure_private_dir "${CHAIN_STATE_DIR}/audit" || die 1 'deploy audit 父目录不安全'
  if [[ ! -e "${audit}" && ! -L "${audit}" ]]; then
    mkdir "${audit}" || die 1 'deploy audit 目录碰撞'
    chmod 700 "${audit}" || die 1 'deploy audit 目录权限设置失败'
  fi
  ensure_private_dir "${audit}" || die 1 'deploy audit 目录身份或权限不安全'
  transaction_copy="${audit}/transaction.env"
  if [[ ! -e "${transaction_copy}" && ! -L "${transaction_copy}" ]]; then
    link "${JOURNAL_FILE}" "${transaction_copy}" || die 1 'deploy audit transaction 发布失败'
    chmod 600 "${transaction_copy}" || die 1 'deploy audit transaction 权限设置失败'
  else
    require_secure_user_file "${transaction_copy}" 600 || die 1 'deploy audit transaction 身份异常'
    [[ "$(sha256_file "${transaction_copy}")" == "$(sha256_file "${JOURNAL_FILE}")" ]] || die 1 'deploy audit transaction 碰撞'
  fi
  payload_hash="$(sha256_file "${transaction_copy}")" || die 1 'deploy audit transaction 摘要失败'
  complete="${audit}/COMPLETE"
  if [[ ! -e "${complete}" && ! -L "${complete}" ]]; then
    {
      printf 'SCHEMA_VERSION=1\n'
      printf 'TRANSACTION_SHA256=%s\n' "${payload_hash}"
    } > "${OP_TMP}/deploy-complete" || die 1 'deploy COMPLETE payload 写入失败'
    write_checksummed_file "${complete}" new "${OP_TMP}/deploy-complete"
  fi
  validate_complete_marker "${complete}" "${payload_hash}" || die 1 'deploy COMPLETE marker 无效'
  [[ "$(sha256_file "${transaction_copy}")" == "${payload_hash}" ]] || die 1 'deploy audit 复核失败'
  validate_deploy_audit "${audit}" || die 1 'deploy audit 全量复核失败'
  rm -f "${JOURNAL_FILE}" || die 1 'deploy commit 后 transaction 删除失败'
  sync || die 1 'deploy commit 持久化失败'
  log_info "deploy audit=${audit}"
}

validate_complete_marker() {
  local file expected payload expected_payload actual_payload
  file="$1"
  expected="$2"
  require_secure_user_file "${file}" 600 || return 1
  [[ "$(awk -F= '{print $1}' "${file}")" == "$(printf '%s\n' SCHEMA_VERSION TRANSACTION_SHA256 PAYLOAD_SHA256)" ]] || return 1
  [[ "$(kv_get "${file}" SCHEMA_VERSION)" == 1 ]] || return 1
  [[ "$(kv_get "${file}" TRANSACTION_SHA256)" == "${expected}" ]] || return 1
  expected_payload="$(kv_get "${file}" PAYLOAD_SHA256)"
  [[ "${expected_payload}" =~ ^[0-9a-f]{64}$ ]] || return 1
  payload="${OP_TMP}/complete-payload.$$"
  sed '$d' "${file}" > "${payload}"
  actual_payload="$(sha256_file "${payload}")"
  rm -f "${payload}"
  [[ "${actual_payload}" == "${expected_payload}" ]]
}

validate_deploy_audit() {
  local audit item relative transaction transaction_hash
  audit="$1"
  private_dir_is_safe "${audit}" || return 1
  while IFS= read -r item; do
    relative="${item#${audit}/}"
    case "${relative}" in
      transaction.env|COMPLETE) ;;
      *) return 1 ;;
    esac
  done < <(find "${audit}" -mindepth 1 -print)
  transaction="${audit}/transaction.env"
  validate_checksum_env "${transaction}" journal || return 1
  [[ "$(kv_get "${transaction}" OPERATION)" == deploy ]] || return 1
  [[ "$(kv_get "${transaction}" OPERATION_ID)" == "${OPERATION_ID}" ]] || return 1
  [[ "$(kv_get "${transaction}" TARGET_STATE)" == deployed ]] || return 1
  [[ "$(kv_get "${transaction}" LAST_COMPLETED_STEP)" == COMMITTED ]] || return 1
  [[ "$(kv_get "${transaction}" CHAIN_ID)" == "${CHAIN_ID}" && "$(kv_get "${transaction}" DEPLOYMENT_ID)" == "${DEPLOYMENT_ID}" && "$(kv_get "${transaction}" CONFIG_SHA256)" == "${CONFIG_SHA256}" ]] || return 1
  transaction_hash="$(sha256_file "${transaction}")"
  validate_complete_marker "${audit}/COMPLETE" "${transaction_hash}"
}

commit_deploy() {
  LAST_COMPLETED_STEP='FULL_VERIFY_OK'
  write_journal
  write_active_state
  LAST_COMPLETED_STEP='STATE_WRITTEN'
  write_journal
  state_matches_loaded_transaction || die 1 'state 写入后与 transaction 字段不一致'
  verify_remote_resources no || die 1 'state 写入后的远端复核失败'
  verify_local_artifacts || die 1 'state 写入后的本地产物复核失败'
  verify_relay_baseline || die 1 'state 写入后的既有 sing-box 基线复核失败'
  deployment_residue_absent || die 1 'state 写入后仍存在 staging/owner-temp 残留'
  LAST_COMPLETED_STEP='COMMITTED'
  write_journal
  archive_deploy_transaction
}

deploy_chain() {
  local rc
  acquire_global_lock
  if acquire_chain_lock 1; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 1 'chain 正被其它操作占用或锁无法安全回收'
  migrate_gate
  require_local_dependencies
  # up 已在配免密之前自检过，这里不重复。
  [[ "${UP_MODE}" == 1 ]] || tun_precheck "${RELAY_HOST}" "${EXIT_HOST}"
  if [[ -e "${JOURNAL_FILE}" || -L "${JOURNAL_FILE}" ]]; then
    # 事务恢复必须作为独立命令执行；放进 `if`/`||` 会让 Bash 关闭整个函数链的 errexit。
    recover_incomplete_transaction
    # load_journal_file 会载入旧事务 id；恢复闭合后，新事务必须重新绑定本次锁身份。
    OPERATION_ID="${LOCK_OPERATION_ID}"
  fi
  render_ssh_config
  if [[ -e "${STATE_FILE}" || -L "${STATE_FILE}" ]]; then
    load_state_file "${STATE_FILE}"
    verify_loaded_binding
    ensure_local_assets_match_state
    full_verify
    log_info "deploy 幂等 no-op；chain=${CHAIN_ID} deployment=${DEPLOYMENT_ID:0:12}"
    return 0
  fi
  prepare_verified_assets deploy
  probe_ssh_and_fingerprints
  remote_platform_preflight
  probe_exit_tls
  probe_exit_exit
  check_remote_shared_binary_or_absent relay || die 4 '中转共享资源 drift'
  check_remote_shared_binary_or_absent exit || die 4 '出口机共享资源 drift'
  check_initial_collisions
  init_deploy_transaction_fields

  install_remote_binary relay "${RELAY_BINARY_STAGE_PATH}" "${RELAY_BINARY_STAGE_OWNER_SHA256}" "${OP_TMP}/owners/relay-binary.env" "${RELAY_BINARY_STAGE_OWNER_TEMP_PATH}"
  LAST_COMPLETED_STEP='RELAY_BINARY_READY'
  write_journal
  cleanup_remote_stage relay "${RELAY_BINARY_STAGE_PATH}" "${RELAY_BINARY_STAGE_OWNER_SHA256}"
  LAST_COMPLETED_STEP='RELAY_BINARY_STAGE_CLEANED'
  write_journal

  install_remote_binary exit "${EXIT_BINARY_STAGE_PATH}" "${EXIT_BINARY_STAGE_OWNER_SHA256}" "${OP_TMP}/owners/exit-binary.env" "${EXIT_BINARY_STAGE_OWNER_TEMP_PATH}"
  LAST_COMPLETED_STEP='EXIT_BINARY_READY'
  write_journal
  cleanup_remote_stage exit "${EXIT_BINARY_STAGE_PATH}" "${EXIT_BINARY_STAGE_OWNER_SHA256}"
  LAST_COMPLETED_STEP='EXIT_BINARY_STAGE_CLEANED'
  write_journal

  prepare_exit_exit
  install_exit_exit
  activate_exit_exit
  smoke_from_relay "${EXIT_HOST}" "${EXIT_REALITY_PORT}" exit-direct
  probe_mac_reality_rejection
  LAST_COMPLETED_STEP='EXIT_REALITY_SMOKE_OK'
  write_journal

  prepare_relay
  install_relay
  activate_relay
  smoke_from_relay 127.0.0.1 "${RELAY_PORT}" relay-full
  [[ "$(ssh_relay systemctl is-active "ownexit-chain-relay-${CHAIN_ID}.service")" == active ]] || die 1 '中转 service 未被真实连接激活'
  publish_local_artifacts
  smoke_from_mac
  full_verify
  commit_deploy
  log_info "deploy 完成；chain=${CHAIN_ID} deployment=${DEPLOYMENT_ID:0:12} node=${CHAIN_STATE_DIR}/client/node.txt elapsed=$(elapsed_seconds)s"
  log_info '备份：无（专属路径碰撞即拒绝）；两端共享目录与固定 binary 按设计保留'
}

write_fail_closed_probe_script() {
  local output config b64
  output="$1"
  config="$2"
  b64="$(openssl base64 -A -in "${config}")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'umask 077'
    printf 'CONFIG_B64=%s\n' "${b64}"
    cat <<'FAIL_CLOSED_PROBE'
tmp="$(mktemp -d /tmp/ownexit-chain-fail-closed.XXXXXX)"
config="$tmp/client.json"
binary="/opt/ownexit-chain/bin/sing-box-1.13.14"
pid=''
cleanup() {
  if [[ -n "$pid" && -d "/proc/$pid" && "$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)" == "$binary" ]]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmd" == *"$config"* ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
printf '%s' "$CONFIG_B64" | base64 -d > "$config"
chmod 600 "$config"
"$binary" check -c "$config" >/dev/null
"$binary" run -c "$config" >"$tmp/log" 2>&1 &
pid="$!"
sleep 1
kill -0 "$pid" 2>/dev/null || exit 126
ss -H -ltnp | awk -v suffix=":$1" -v pid="pid=$pid," 'substr($4, length($4)-length(suffix)+1) == suffix && index($0, pid) {found=1} END {exit found ? 0 : 1}' || exit 127
valid=0
for endpoint in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
  result="$(
    env -i HOME="$tmp" PATH=/usr/sbin:/usr/bin:/sbin:/bin curl --disable --fail --silent --show-error --proxy "socks5h://127.0.0.1:$1" --noproxy '' --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true
  )"
  [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && valid=$((valid + 1))
done
(( valid == 0 ))
FAIL_CLOSED_PROBE
  } > "${output}"
  chmod 600 "${output}"
}

verify_fail_closed() {
  local socket service timer timer_service local_port config probe accuracy triggers execstart
  socket="ownexit-chain-relay-${CHAIN_ID}.socket"
  service="ownexit-chain-relay-${CHAIN_ID}.service"
  WATCHDOG_UNIT="ownexit-chain-restore-${CHAIN_ID}-${OPERATION_ID}"
  timer="${WATCHDOG_UNIT}.timer"
  timer_service="${WATCHDOG_UNIT}.service"
  ssh_relay systemd-run --unit="${WATCHDOG_UNIT}" --on-active=90s --timer-property=AccuracySec=1s --timer-property=RemainAfterElapse=no --property=Type=exec "${SYSTEMCTL_PATH}" start "${socket}" >/dev/null
  # systemd-run 一旦成功就可能留下远端 transient unit；必须先置 armed，再做任何后续属性断言。
  WATCHDOG_ARMED=1
  accuracy="$(ssh_relay systemctl show "${timer}" -p AccuracyUSec --value)"
  triggers="$(ssh_relay systemctl show "${timer}" -p Triggers --value)"
  execstart="$(ssh_relay systemctl show "${timer_service}" -p ExecStart --value)"
  [[ "${accuracy}" == 1s && "${triggers}" == *"${timer_service}"* && "${execstart}" == *"${SYSTEMCTL_PATH}"*"${socket}"* ]] || die 1 'fail-closed watchdog 属性核验失败'
  [[ "$(ssh_relay systemctl is-active "${timer}")" == active ]] || die 1 'fail-closed watchdog timer 未 active'
  ssh_relay systemctl stop "${socket}"
  ssh_relay systemctl stop "${service}" || true
  ! ssh_relay "ss -H -ltn | grep -q ':${RELAY_PORT} '" || die 1 '停止后 relay 端口仍监听'
  local_port="$(choose_remote_port relay)" || die 1 '无法选择 fail-closed 临时端口'
  config="${OP_TMP}/fail-closed.json"
  probe="${OP_TMP}/fail-closed.sh"
  render_client_config "${config}" "${local_port}" 127.0.0.1 "${RELAY_PORT}"
  write_fail_closed_probe_script "${probe}" "${config}"
  ssh_relay_stdin bash -s -- "${local_port}" < "${probe}" || die 1 'fail-closed 期间仍得到有效代理响应'
  ssh_relay systemctl start "${socket}"
  verify_chain_smokes
  restore_and_disarm_fail_closed_watchdog || die 1 'relay socket 或 fail-closed watchdog 未安全闭合'
}

write_remove_chain_script() {
  local output
  output="$1"
  cat > "${output}" <<'REMOVE_CHAIN' || return 1
#!/usr/bin/env bash
set -euo pipefail
umask 077
role="$1"
chain_id="$2"
owner_hash="$3"
first_hash="$4"
second_hash="$5"
link_target="$6"
phase="$7"
port="$8"
dropin_name="$9"

check_file() {
  local path hash mode
  path="$1"
  hash="$2"
  mode="$3"
  [[ -f "$path" && ! -L "$path" && "$(stat -c %u:%g:%a "$path")" == "0:0:$mode" ]] || exit 191
  [[ "$(sha256sum "$path" | awk '{print $1}')" == "$hash" ]] || exit 192
}

check_unit_identity() {
  local unit expected fragment dropins unit_path candidate unit_paths managed_dir
  unit="$1"
  expected="$2"
  managed_dir="$expected.d"
  fragment="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null || true)"
  dropins="$(systemctl show "$unit" -p DropInPaths --value 2>/dev/null || true)"
  # 只放行黑名单受管 drop-in（ban 命令产物）；其它任何 drop-in 仍视为身份不符、拒绝拆除。
  [[ -z "$dropins" || "$dropins" == "$managed_dir/$dropin_name" ]] || exit 200
  [[ -z "$fragment" || "$fragment" == "$expected" ]] || exit 201
  unit_paths="$(systemd-analyze unit-paths)"
  while IFS= read -r unit_path; do
    [[ -n "$unit_path" ]] || continue
    candidate="$unit_path/$unit"
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      [[ "$candidate" == "$expected" && -f "$candidate" && ! -L "$candidate" ]] || exit 202
    fi
    if [[ "$candidate.d" == "$managed_dir" && -d "$managed_dir" && ! -L "$managed_dir" ]]; then
      [[ "$(find "$managed_dir" -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 1 && -f "$managed_dir/$dropin_name" && ! -L "$managed_dir/$dropin_name" ]] || exit 203
      continue
    fi
    [[ ! -e "$candidate.d" && ! -L "$candidate.d" ]] || exit 203
  done <<EOF
$unit_paths
EOF
}

# 拆除受管 drop-in（存在时）；目录里若有非受管文件，check_unit_identity 已先拒绝，这里不会跑到。
remove_managed_dropin() {
  local dir
  dir="$1.d"
  [[ -d "$dir" && ! -L "$dir" ]] || return 0
  rm -f "$dir/$dropin_name"
  rmdir "$dir"
}

require_unit_stopped() {
  local unit require_main_pid active main_pid
  unit="$1"
  require_main_pid="$2"
  active="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
  case "$active" in
    inactive|failed) ;;
    *) return 1 ;;
  esac
  if [[ "$require_main_pid" == yes ]]; then
    main_pid="$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)"
    [[ "$main_pid" == 0 ]] || return 1
  fi
}

if [[ "$role" == relay ]]; then
  owner="/etc/ownexit-chain/$chain_id.owner.env"
  first="/etc/systemd/system/ownexit-chain-relay-$chain_id.socket"
  second="/etc/systemd/system/ownexit-chain-relay-$chain_id.service"
  link_path="/etc/systemd/system/sockets.target.wants/ownexit-chain-relay-$chain_id.socket"
  first_unit="ownexit-chain-relay-$chain_id.socket"
  second_unit="ownexit-chain-relay-$chain_id.service"
else
  owner="/etc/ownexit-chain/$chain_id.owner.env"
  first="/etc/ownexit-chain/$chain_id.exit.json"
  second="/etc/systemd/system/ownexit-chain-exit-$chain_id.service"
  link_path="/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-$chain_id.service"
  first_unit=''
  second_unit="ownexit-chain-exit-$chain_id.service"
fi

if [[ "$phase" == stop ]]; then
  if [[ ! -e "$owner" && ! -L "$owner" ]]; then
    for path in "$first" "$second" "$link_path"; do
      [[ ! -e "$path" && ! -L "$path" ]] || exit 190
    done
    exit 0
  fi
  check_file "$owner" "$owner_hash" 600
  if [[ -e "$first" || -L "$first" ]]; then
    if [[ "$role" == relay ]]; then
      check_file "$first" "$first_hash" 644
    else
      check_file "$first" "$first_hash" 600
    fi
  fi
  if [[ -e "$second" || -L "$second" ]]; then
    check_file "$second" "$second_hash" 644
  fi
  if [[ -e "$link_path" || -L "$link_path" ]]; then
    [[ -L "$link_path" && "$(readlink "$link_path")" == "$link_target" ]] || exit 197
  fi
  if [[ "$role" == relay ]]; then
    check_unit_identity "$first_unit" "$first"
    check_unit_identity "$second_unit" "$second"
    systemctl stop "$first_unit" 2>/dev/null || true
    systemctl stop "$second_unit" 2>/dev/null || true
    require_unit_stopped "$first_unit" no || exit 193
    require_unit_stopped "$second_unit" yes || exit 194
    ! ss -H -ltn | awk -v suffix=":$port" 'substr($4, length($4)-length(suffix)+1) == suffix {found=1} END {exit found ? 0 : 1}' || exit 198
  else
    check_unit_identity "$second_unit" "$second"
    systemctl stop "$second_unit" 2>/dev/null || true
    require_unit_stopped "$second_unit" yes || exit 195
    ! ss -H -ltn | awk -v suffix=":$port" 'substr($4, length($4)-length(suffix)+1) == suffix {found=1} END {exit found ? 0 : 1}' || exit 199
  fi
  exit 0
fi

if [[ ! -e "$owner" && ! -L "$owner" ]]; then
  for path in "$first" "$second" "$link_path"; do
    [[ ! -e "$path" && ! -L "$path" ]] || exit 196
  done
  exit 0
fi
check_file "$owner" "$owner_hash" 600
if [[ -e "$first" || -L "$first" ]]; then
  if [[ "$role" == relay ]]; then
    check_file "$first" "$first_hash" 644
  else
    check_file "$first" "$first_hash" 600
  fi
fi
if [[ -e "$second" || -L "$second" ]]; then
  check_file "$second" "$second_hash" 644
fi
if [[ -e "$link_path" || -L "$link_path" ]]; then
  [[ -L "$link_path" && "$(readlink "$link_path")" == "$link_target" ]] || exit 197
fi
if [[ "$role" == relay ]]; then
  check_unit_identity "$first_unit" "$first"
  check_unit_identity "$second_unit" "$second"
else
  check_unit_identity "$second_unit" "$second"
fi
rm -f "$link_path"
if [[ "$role" == relay ]]; then
  remove_managed_dropin "$first"
  remove_managed_dropin "$second"
fi
rm -f "$second"
rm -f "$first"
rm -f "$owner"
systemctl daemon-reload
REMOVE_CHAIN
  chmod 600 "${output}" || return 1
}

stop_chain_role() {
  local role script
  role="$1"
  script="${OP_TMP}/remove-chain.sh"
  write_remove_chain_script "${script}" || return 1
  if [[ "${role}" == relay ]]; then
    ssh_relay_stdin bash -s -- relay "${CHAIN_ID}" "${RELAY_OWNER_SHA256}" "${RELAY_SOCKET_SHA256}" "${RELAY_SERVICE_SHA256}" "${RELAY_ENABLE_LINK_TARGET}" stop "${RELAY_PORT}" "${RELAY_BLACKLIST_DROPIN}" < "${script}"
  else
    ssh_exit_stdin bash -s -- exit "${CHAIN_ID}" "${EXIT_OWNER_SHA256}" "${EXIT_EXIT_SHA256}" "${EXIT_SERVICE_SHA256}" "${EXIT_ENABLE_LINK_TARGET}" stop "${EXIT_REALITY_PORT}" "${RELAY_BLACKLIST_DROPIN}" < "${script}"
  fi
}

remove_chain_role_files() {
  local role script
  role="$1"
  script="${OP_TMP}/remove-chain.sh"
  write_remove_chain_script "${script}" || return 1
  if [[ "${role}" == relay ]]; then
    ssh_relay_stdin bash -s -- relay "${CHAIN_ID}" "${RELAY_OWNER_SHA256}" "${RELAY_SOCKET_SHA256}" "${RELAY_SERVICE_SHA256}" "${RELAY_ENABLE_LINK_TARGET}" remove "${RELAY_PORT}" "${RELAY_BLACKLIST_DROPIN}" < "${script}"
  else
    ssh_exit_stdin bash -s -- exit "${CHAIN_ID}" "${EXIT_OWNER_SHA256}" "${EXIT_EXIT_SHA256}" "${EXIT_SERVICE_SHA256}" "${EXIT_ENABLE_LINK_TARGET}" remove "${EXIT_REALITY_PORT}" "${RELAY_BLACKLIST_DROPIN}" < "${script}"
  fi
}

write_verify_removed_role_script() {
  local output
  output="$1"
  cat > "${output}" <<'VERIFY_REMOVED_ROLE' || return 1
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
role="$1"
chain_id="$2"
port="$3"
if [[ "$role" == relay ]]; then
  first="/etc/systemd/system/ownexit-chain-relay-$chain_id.socket"
  second="/etc/systemd/system/ownexit-chain-relay-$chain_id.service"
  owner="/etc/ownexit-chain/$chain_id.owner.env"
  link_path="/etc/systemd/system/sockets.target.wants/ownexit-chain-relay-$chain_id.socket"
  units="ownexit-chain-relay-$chain_id.socket
ownexit-chain-relay-$chain_id.service"
else
  first="/etc/ownexit-chain/$chain_id.exit.json"
  second="/etc/systemd/system/ownexit-chain-exit-$chain_id.service"
  owner="/etc/ownexit-chain/$chain_id.owner.env"
  link_path="/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-$chain_id.service"
  units="ownexit-chain-exit-$chain_id.service"
fi
for path in "$owner" "$first" "$second" "$link_path"; do
  [[ ! -e "$path" && ! -L "$path" ]] || exit 211
done
unit_paths="$(systemd-analyze unit-paths)"
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  while IFS= read -r unit_path; do
    [[ -n "$unit_path" ]] || continue
    [[ ! -e "$unit_path/$unit" && ! -L "$unit_path/$unit" ]] || exit 212
    [[ ! -e "$unit_path/$unit.d" && ! -L "$unit_path/$unit.d" ]] || exit 213
  done <<EOF
$unit_paths
EOF
  load="$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)"
  fragment="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null || true)"
  dropins="$(systemctl show "$unit" -p DropInPaths --value 2>/dev/null || true)"
  active="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
  main_pid=0
  if [[ "$unit" == *.service ]]; then
    main_pid="$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)"
  fi
  case "$active" in
    inactive|failed) ;;
    *) exit 214 ;;
  esac
  [[ "$load" == not-found && -z "$fragment" && -z "$dropins" && "$main_pid" == 0 ]] || exit 214
done <<EOF
$units
EOF
! ss -H -ltn | awk -v suffix=":$port" 'substr($4, length($4)-length(suffix)+1) == suffix {found=1} END {exit found ? 0 : 1}' || exit 215
VERIFY_REMOVED_ROLE
  chmod 600 "${output}" || return 1
}

verify_removed_chain_role() {
  local role script
  role="$1"
  script="${OP_TMP}/verify-removed-role.sh"
  write_verify_removed_role_script "${script}" || return 1
  if [[ "${role}" == relay ]]; then
    ssh_relay_stdin bash -s -- relay "${CHAIN_ID}" "${RELAY_PORT}" < "${script}"
  else
    ssh_exit_stdin bash -s -- exit "${CHAIN_ID}" "${EXIT_REALITY_PORT}" < "${script}"
  fi
}

watchdog_is_absent() {
  local output
  output="$(ssh_relay "systemctl list-units --all --plain --no-legend 'ownexit-chain-restore-${CHAIN_ID}-*' 2>/dev/null")" || return 1
  [[ -z "${output}" ]]
}

restore_and_disarm_fail_closed_watchdog() {
  local socket timer timer_service socket_state timer_state service_state
  [[ "${WATCHDOG_ARMED}" == 1 && -n "${WATCHDOG_UNIT}" ]] || return 0
  socket="ownexit-chain-relay-${CHAIN_ID}.socket"
  timer="${WATCHDOG_UNIT}.timer"
  timer_service="${WATCHDOG_UNIT}.service"
  # 异常与成功路径共用同一闭合判据：先确认入口 socket active，再停/reset 两个 transient unit，最后核对通配残留为空。
  ssh_relay systemctl start "${socket}" >/dev/null 2>&1 || return 1
  socket_state="$(ssh_relay systemctl is-active "${socket}" 2>/dev/null)" || return 1
  [[ "${socket_state}" == active ]] || return 1
  ssh_relay systemctl stop "${timer}" "${timer_service}" >/dev/null 2>&1 || true
  ssh_relay systemctl reset-failed "${timer}" "${timer_service}" >/dev/null 2>&1 || true
  timer_state="$(ssh_relay systemctl is-active "${timer}" 2>/dev/null || true)"
  service_state="$(ssh_relay systemctl is-active "${timer_service}" 2>/dev/null || true)"
  case "${timer_state}" in active|activating|reloading|deactivating) return 1 ;; esac
  case "${service_state}" in active|activating|reloading|deactivating) return 1 ;; esac
  watchdog_is_absent || return 1
  WATCHDOG_ARMED=0
  WATCHDOG_UNIT=''
}

init_rollback_journal() {
  JOURNAL_OPERATION='rollback'
  TARGET_STATE='not_deployed'
  LAST_COMPLETED_STEP='ROLLBACK_PREPARED'
  LOCAL_STAGE_PATH='ABSENT'
  LOCAL_STAGE_OWNER_SHA256='ABSENT'
  RELAY_STAGE_PATH='ABSENT'
  EXIT_STAGE_PATH='ABSENT'
  RELAY_BINARY_STAGE_PATH='ABSENT'
  EXIT_BINARY_STAGE_PATH='ABSENT'
  RELAY_STAGE_OWNER_TEMP_PATH='ABSENT'
  EXIT_STAGE_OWNER_TEMP_PATH='ABSENT'
  RELAY_BINARY_STAGE_OWNER_TEMP_PATH='ABSENT'
  EXIT_BINARY_STAGE_OWNER_TEMP_PATH='ABSENT'
  RELAY_STAGE_OWNER_SHA256='ABSENT'
  EXIT_STAGE_OWNER_SHA256='ABSENT'
  RELAY_BINARY_STAGE_OWNER_SHA256='ABSENT'
  EXIT_BINARY_STAGE_OWNER_SHA256='ABSENT'
  write_journal
}

archive_rollback_artifacts() {
  local audit saved_step payload transaction_copy complete file transaction_hash
  validate_checksum_env "${STATE_FILE}" state || die 1 'rollback 归档前 active state 漂移'
  verify_local_artifacts || die 1 'rollback 归档前本地产物漂移'
  audit="${CHAIN_STATE_DIR}/audit/rolledback.${DEPLOYMENT_ID}.${OPERATION_ID}"
  ensure_private_dir "${CHAIN_STATE_DIR}/audit" || die 1 'rollback audit 父目录不安全'
  if [[ ! -e "${audit}" && ! -L "${audit}" ]]; then
    mkdir "${audit}" || die 1 'rollback audit 目录碰撞'
    chmod 700 "${audit}" || die 1 'rollback audit 目录权限设置失败'
  fi
  ensure_private_dir "${audit}" || die 1 'rollback audit 目录身份或权限不安全'
  ensure_private_dir "${audit}/baseline" || die 1 'rollback baseline audit 目录不安全'
  ensure_private_dir "${audit}/client" || die 1 'rollback client audit 目录不安全'
  if [[ ! -e "${audit}/state.env" ]]; then
    link "${STATE_FILE}" "${audit}/state.env" || die 1 'rollback audit state 发布失败'
  else
    require_secure_user_file "${audit}/state.env" 600 || die 1 'rollback audit state 身份异常'
    [[ "$(sha256_file "${audit}/state.env")" == "$(sha256_file "${STATE_FILE}")" ]] || die 1 'rollback audit state 碰撞'
  fi
  for file in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
    if [[ ! -e "${audit}/baseline/${file}" ]]; then
      link "${CHAIN_STATE_DIR}/baseline/${file}" "${audit}/baseline/${file}" || die 1 "rollback audit baseline 发布失败：${file}"
    else
      require_secure_user_file "${audit}/baseline/${file}" 600 || die 1 "rollback audit baseline 身份异常：${file}"
      [[ "$(sha256_file "${audit}/baseline/${file}")" == "$(sha256_file "${CHAIN_STATE_DIR}/baseline/${file}")" ]] || die 1 "rollback audit baseline 碰撞：${file}"
    fi
  done
  if [[ ! -e "${audit}/client/node.txt" ]]; then
    link "${CHAIN_STATE_DIR}/client/node.txt" "${audit}/client/node.txt" || die 1 'rollback audit node 发布失败'
  else
    require_secure_user_file "${audit}/client/node.txt" 600 || die 1 'rollback audit node 身份异常'
    [[ "$(sha256_file "${audit}/client/node.txt")" == "$(sha256_file "${CHAIN_STATE_DIR}/client/node.txt")" ]] || die 1 'rollback audit node 碰撞'
  fi
  saved_step="${LAST_COMPLETED_STEP}"
  LAST_COMPLETED_STEP='ROLLBACK_COMMITTED'
  payload="${OP_TMP}/rollback-archive-journal"
  render_journal_payload "${payload}" || die 1 'rollback audit transaction payload 生成失败'
  LAST_COMPLETED_STEP="${saved_step}"
  transaction_copy="${audit}/transaction.env"
  if [[ ! -e "${transaction_copy}" ]]; then
    write_checksummed_file "${transaction_copy}" new "${payload}"
  else
    validate_checksum_env "${transaction_copy}" journal || die 1 'rollback audit transaction 无效'
    [[ "$(kv_get "${transaction_copy}" LAST_COMPLETED_STEP)" == ROLLBACK_COMMITTED ]] || die 1 'rollback audit transaction step 错误'
  fi
  transaction_hash="$(sha256_file "${transaction_copy}")" || die 1 'rollback audit transaction 摘要失败'
  complete="${audit}/COMPLETE"
  if [[ ! -e "${complete}" ]]; then
    {
      printf 'SCHEMA_VERSION=1\n'
      printf 'TRANSACTION_SHA256=%s\n' "${transaction_hash}"
    } > "${OP_TMP}/rollback-complete" || die 1 'rollback COMPLETE payload 写入失败'
    write_checksummed_file "${complete}" new "${OP_TMP}/rollback-complete"
  fi
  validate_complete_marker "${complete}" "${transaction_hash}" || die 1 'rollback COMPLETE marker 无效'
  [[ "$(sha256_file "${transaction_copy}")" == "${transaction_hash}" ]] || die 1 'rollback audit transaction 漂移'
  validate_rollback_audit || die 1 'rollback audit 全量复核失败'
  printf '%s\n' "${audit}"
}

validate_rollback_audit() {
  local audit item relative file transaction transaction_hash key expected
  audit="${CHAIN_STATE_DIR}/audit/rolledback.${DEPLOYMENT_ID}.${OPERATION_ID}"
  private_dir_is_safe "${audit}" || return 1
  private_dir_is_safe "${audit}/baseline" || return 1
  private_dir_is_safe "${audit}/client" || return 1
  while IFS= read -r item; do
    relative="${item#${audit}/}"
    case "${relative}" in
      state.env|transaction.env|COMPLETE|baseline|baseline/relay-config-manifest.txt|baseline/relay-unit-manifest.txt|baseline/relay-binary-manifest.txt|baseline/relay-listeners.txt|client|client/node.txt) ;;
      *) return 1 ;;
    esac
  done < <(find "${audit}" -mindepth 1 -print)
  validate_checksum_env "${audit}/state.env" state || return 1
  [[ "$(kv_get "${audit}/state.env" CHAIN_ID)" == "${CHAIN_ID}" ]] || return 1
  [[ "$(kv_get "${audit}/state.env" DEPLOYMENT_ID)" == "${DEPLOYMENT_ID}" ]] || return 1
  [[ "$(kv_get "${audit}/state.env" CONFIG_SHA256)" == "${CONFIG_SHA256}" ]] || return 1
  for key in RELAY_OWNER_SHA256 RELAY_SOCKET_SHA256 RELAY_SERVICE_SHA256 EXIT_OWNER_SHA256 EXIT_EXIT_SHA256 EXIT_SERVICE_SHA256 RELAY_BASELINE_CONFIG_MANIFEST_SHA256 RELAY_BASELINE_UNIT_MANIFEST_SHA256 RELAY_BASELINE_BINARY_MANIFEST_SHA256 RELAY_BASELINE_LISTEN_SHA256 NODE_SHA256; do
    case "${key}" in
      RELAY_OWNER_SHA256) expected="${RELAY_OWNER_SHA256}" ;;
      RELAY_SOCKET_SHA256) expected="${RELAY_SOCKET_SHA256}" ;;
      RELAY_SERVICE_SHA256) expected="${RELAY_SERVICE_SHA256}" ;;
      EXIT_OWNER_SHA256) expected="${EXIT_OWNER_SHA256}" ;;
      EXIT_EXIT_SHA256) expected="${EXIT_EXIT_SHA256}" ;;
      EXIT_SERVICE_SHA256) expected="${EXIT_SERVICE_SHA256}" ;;
      RELAY_BASELINE_CONFIG_MANIFEST_SHA256) expected="${RELAY_BASELINE_CONFIG_MANIFEST_SHA256}" ;;
      RELAY_BASELINE_UNIT_MANIFEST_SHA256) expected="${RELAY_BASELINE_UNIT_MANIFEST_SHA256}" ;;
      RELAY_BASELINE_BINARY_MANIFEST_SHA256) expected="${RELAY_BASELINE_BINARY_MANIFEST_SHA256}" ;;
      RELAY_BASELINE_LISTEN_SHA256) expected="${RELAY_BASELINE_LISTEN_SHA256}" ;;
      NODE_SHA256) expected="${NODE_SHA256}" ;;
    esac
    [[ "$(kv_get "${audit}/state.env" "${key}")" == "${expected}" ]] || return 1
  done
  for file in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
    require_secure_user_file "${audit}/baseline/${file}" 600 || return 1
    case "${file}" in
      relay-config-manifest.txt) expected="${RELAY_BASELINE_CONFIG_MANIFEST_SHA256}" ;;
      relay-unit-manifest.txt) expected="${RELAY_BASELINE_UNIT_MANIFEST_SHA256}" ;;
      relay-binary-manifest.txt) expected="${RELAY_BASELINE_BINARY_MANIFEST_SHA256}" ;;
      relay-listeners.txt) expected="${RELAY_BASELINE_LISTEN_SHA256}" ;;
    esac
    [[ "$(sha256_file "${audit}/baseline/${file}")" == "${expected}" ]] || return 1
  done
  require_secure_user_file "${audit}/client/node.txt" 600 || return 1
  [[ "$(sha256_file "${audit}/client/node.txt")" == "${NODE_SHA256}" ]] || return 1
  transaction="${audit}/transaction.env"
  validate_checksum_env "${transaction}" journal || return 1
  [[ "$(kv_get "${transaction}" OPERATION)" == rollback ]] || return 1
  [[ "$(kv_get "${transaction}" OPERATION_ID)" == "${OPERATION_ID}" ]] || return 1
  [[ "$(kv_get "${transaction}" TARGET_STATE)" == not_deployed ]] || return 1
  [[ "$(kv_get "${transaction}" LAST_COMPLETED_STEP)" == ROLLBACK_COMMITTED ]] || return 1
  [[ "$(kv_get "${transaction}" CHAIN_ID)" == "${CHAIN_ID}" && "$(kv_get "${transaction}" DEPLOYMENT_ID)" == "${DEPLOYMENT_ID}" && "$(kv_get "${transaction}" CONFIG_SHA256)" == "${CONFIG_SHA256}" ]] || return 1
  transaction_hash="$(sha256_file "${transaction}")"
  validate_complete_marker "${audit}/COMPLETE" "${transaction_hash}"
}

remove_active_local_artifacts() {
  local file expected_hash
  if [[ -e "${CHAIN_STATE_DIR}/client" || -L "${CHAIN_STATE_DIR}/client" ]]; then
    private_dir_is_safe "${CHAIN_STATE_DIR}/client" || die 1 'client 目录删除前身份异常'
  fi
  if [[ -e "${CHAIN_STATE_DIR}/baseline" || -L "${CHAIN_STATE_DIR}/baseline" ]]; then
    private_dir_is_safe "${CHAIN_STATE_DIR}/baseline" || die 1 'baseline 目录删除前身份异常'
  fi
  if [[ -e "${CHAIN_STATE_DIR}/client/node.txt" || -L "${CHAIN_STATE_DIR}/client/node.txt" ]]; then
    require_secure_user_file "${CHAIN_STATE_DIR}/client/node.txt" 600 || die 1 'node.txt 删除前身份异常'
    [[ "$(sha256_file "${CHAIN_STATE_DIR}/client/node.txt")" == "${NODE_SHA256}" ]] || die 1 'node.txt 删除前 hash 漂移'
    rm -f "${CHAIN_STATE_DIR}/client/node.txt" || die 1 'node.txt 删除失败'
  fi
  [[ ! -d "${CHAIN_STATE_DIR}/client" ]] || rmdir "${CHAIN_STATE_DIR}/client" || die 1 'client 目录删除失败'
  # rotate-keys 中断留下的 node.txt 临时文件：不删的话 state 删除后它会被判成孤儿，status / deploy / rollback 都卡住。
  for file in "${CHAIN_STATE_DIR}"/.node.txt.rotate.*.tmp; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    require_secure_user_file "${file}" 600 || die 1 "rotate-keys 残留删除前身份异常：${file}"
    rm -f "${file}" || die 1 "rotate-keys 残留删除失败：${file}"
  done
  # 额外设备的本机缓存（设备表、节点文件、临时文件）随链一起退役：出口机已拆，这些凭据不再有效。
  if [[ -e "${CHAIN_STATE_DIR}/devices" || -L "${CHAIN_STATE_DIR}/devices" ]]; then
    private_dir_is_safe "${CHAIN_STATE_DIR}/devices" || die 1 'devices 目录删除前身份异常'
    for file in "${CHAIN_STATE_DIR}/devices"/devices.env "${CHAIN_STATE_DIR}/devices"/node-*.txt "${CHAIN_STATE_DIR}/devices"/.*.tmp; do
      [[ -e "${file}" || -L "${file}" ]] || continue
      require_secure_user_file "${file}" 600 || die 1 "设备文件删除前身份异常：${file}"
      rm -f "${file}" || die 1 "设备文件删除失败：${file}"
    done
    rmdir "${CHAIN_STATE_DIR}/devices" || die 1 'devices 目录删除失败（里面有不认识的文件）'
  fi
  for file in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
    if [[ -e "${CHAIN_STATE_DIR}/baseline/${file}" || -L "${CHAIN_STATE_DIR}/baseline/${file}" ]]; then
      require_secure_user_file "${CHAIN_STATE_DIR}/baseline/${file}" 600 || die 1 "baseline 删除前身份异常：${file}"
      case "${file}" in
        relay-config-manifest.txt) expected_hash="${RELAY_BASELINE_CONFIG_MANIFEST_SHA256}" ;;
        relay-unit-manifest.txt) expected_hash="${RELAY_BASELINE_UNIT_MANIFEST_SHA256}" ;;
        relay-binary-manifest.txt) expected_hash="${RELAY_BASELINE_BINARY_MANIFEST_SHA256}" ;;
        relay-listeners.txt) expected_hash="${RELAY_BASELINE_LISTEN_SHA256}" ;;
      esac
      [[ "$(sha256_file "${CHAIN_STATE_DIR}/baseline/${file}")" == "${expected_hash}" ]] || die 1 "baseline 删除前 hash 漂移：${file}"
      rm -f "${CHAIN_STATE_DIR}/baseline/${file}" || die 1 "baseline 删除失败：${file}"
    fi
  done
  [[ ! -d "${CHAIN_STATE_DIR}/baseline" ]] || rmdir "${CHAIN_STATE_DIR}/baseline" || die 1 'baseline 目录删除失败'
  if [[ -e "${STATE_FILE}" || -L "${STATE_FILE}" ]]; then
    validate_checksum_env "${STATE_FILE}" state || die 1 'state 删除前 checksum 漂移'
    rm -f "${STATE_FILE}" || die 1 'active state 删除失败'
  fi
  # 黑名单随 deployment 一起退役：远端 drop-in 已在 remove 段删除，本地副本若留下会让下次 verify 误判 drift。
  if [[ -e "${BLACKLIST_FILE}" || -L "${BLACKLIST_FILE}" ]]; then
    require_secure_user_file "${BLACKLIST_FILE}" 600 || die 1 'blacklist.txt 删除前身份异常'
    rm -f "${BLACKLIST_FILE}" || die 1 'blacklist.txt 删除失败'
  fi
}

perform_rollback_steps() {
  local audit rank
  case "${LAST_COMPLETED_STEP}" in
    ROLLBACK_PREPARED) rank=0 ;;
    RELAY_STOPPED) rank=1 ;;
    RELAY_FILES_REMOVED) rank=2 ;;
    EXIT_STOPPED) rank=3 ;;
    EXIT_FILES_REMOVED) rank=4 ;;
    LOCAL_ARTIFACTS_ARCHIVED) rank=5 ;;
    ROLLBACK_COMMITTED) rank=6 ;;
    *) die 1 "未知 rollback step：${LAST_COMPLETED_STEP}" ;;
  esac
  # 每次续做先闭合已完成步骤的不变量；不能因主机重启或手工漂移直接跳到删除/提交。
  if (( rank >= 2 )); then
    verify_removed_chain_role relay || die 1 'rollback 续做发现中转已删除状态漂移'
  elif (( rank >= 1 )); then
    stop_chain_role relay || die 1 'rollback 续做无法重新确认中转已停止'
  fi
  if (( rank >= 4 )); then
    verify_removed_chain_role exit || die 1 'rollback 续做发现出口机已删除状态漂移'
  elif (( rank >= 3 )); then
    stop_chain_role exit || die 1 'rollback 续做无法重新确认出口机已停止'
  fi
  if (( rank >= 5 )); then
    validate_rollback_audit || die 1 'rollback 续做发现审计归档或 COMPLETE 漂移'
  fi
  if (( rank < 1 )); then
    stop_chain_role relay || die 1 '中转停止失败'
    LAST_COMPLETED_STEP='RELAY_STOPPED'
    write_journal || die 1 '中转停止后 transaction 推进失败'
  fi
  if (( rank < 2 )); then
    remove_chain_role_files relay || die 1 '中转资源删除失败'
    verify_removed_chain_role relay || die 1 '中转资源删除后复核失败'
    LAST_COMPLETED_STEP='RELAY_FILES_REMOVED'
    write_journal || die 1 '中转删除后 transaction 推进失败'
  fi
  if (( rank < 3 )); then
    stop_chain_role exit || die 1 '出口机停止失败'
    LAST_COMPLETED_STEP='EXIT_STOPPED'
    write_journal || die 1 '出口机停止后 transaction 推进失败'
  fi
  if (( rank < 4 )); then
    remove_chain_role_files exit || die 1 '出口机资源删除失败'
    verify_removed_chain_role exit || die 1 '出口机资源删除后复核失败'
    LAST_COMPLETED_STEP='EXIT_FILES_REMOVED'
    write_journal || die 1 '出口机删除后 transaction 推进失败'
  fi
  if (( rank < 5 )); then
    audit="$(archive_rollback_artifacts)" || die 1 'rollback audit 未完整提交，保留 active state 与 transaction'
    LAST_COMPLETED_STEP='LOCAL_ARTIFACTS_ARCHIVED'
    write_journal || die 1 'rollback audit 后 transaction 推进失败'
    log_info "rollback audit=${audit}"
  fi
  if (( rank < 6 )); then
    remove_active_local_artifacts || die 1 'rollback 本地产物删除失败'
    LAST_COMPLETED_STEP='ROLLBACK_COMMITTED'
    write_journal || die 1 'rollback commit transaction 推进失败'
  fi
  rm -f "${JOURNAL_FILE}" || die 1 'rollback commit 后 transaction 删除失败'
  sync || die 1 'rollback commit 持久化失败'
}

rollback_chain() {
  local rc
  if acquire_chain_lock 1; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 6 'chain 正被其它操作占用或锁无法安全回收'
  migrate_gate
  require_local_dependencies
  render_ssh_config
  if [[ -e "${JOURNAL_FILE}" || -L "${JOURNAL_FILE}" ]]; then
    load_journal_file "${JOURNAL_FILE}"
    if [[ "${JOURNAL_OPERATION}" != rollback ]]; then
      # 同 deploy：恢复函数不可出现在条件命令上下文中。
      recover_incomplete_transaction
    fi
    if [[ ! -e "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]]; then
      OPERATION_ID="${LOCK_OPERATION_ID}"
    fi
    if [[ -e "${JOURNAL_FILE}" ]]; then
      load_journal_file "${JOURNAL_FILE}"
      [[ "${JOURNAL_OPERATION}" == rollback ]] || die 6 '活动 transaction 不是 rollback'
      verify_loaded_binding
      perform_rollback_steps
      return 0
    fi
  fi
  if [[ ! -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]]; then
    if configured_local_resources_absent && configured_resources_absent; then
      log_info 'rollback 幂等 no-op：chain 未部署'
      return 0
    fi
    die 6 '无 active state 但存在 orphan 或远端不可核证'
  fi
  load_state_file "${STATE_FILE}"
  verify_loaded_binding
  ensure_local_assets_match_state
  remote_platform_preflight
  if probe_remote_resources no; then rc=0; else rc="$?"; fi
  [[ "${rc}" -ne 33 ]] || die 6 'rollback 预校验发现出口机上有未完成的凭据或设备操作；先重跑中断的那条命令（rotate-keys / add-device / remove-device）收敛再 rollback'
  [[ "${rc}" -eq 0 ]] || die 6 'rollback 预校验发现远端 drift'
  verify_local_artifacts || die 6 'rollback 预校验发现本地产物 drift'
  verify_relay_baseline || die 6 'rollback 预校验发现既有 sing-box 基线变化'
  watchdog_is_absent || die 6 '存在 active/残留 fail-closed watchdog，拒绝 rollback'
  init_rollback_journal
  perform_rollback_steps
  log_info "rollback 完成；chain=${CHAIN_ID} elapsed=$(elapsed_seconds)s"
  log_info '备份：无（专属路径碰撞即拒绝）；两端共享目录与固定 binary 已保留'
}

write_cleanup_residue_script() {
  local output
  output="$1"
  cat > "${output}" <<'CLEAN_RESIDUE' || return 1
#!/usr/bin/env bash
set -euo pipefail
umask 077
stage="$1"
owner_hash="$2"
owner_base="$3"
chain_id="$4"

safe_small_owner_temp() {
  local path
  path="$1"
  [[ -f "$path" && ! -L "$path" && "$(stat -c %u:%g:%a "$path")" == 0:0:600 ]] || exit 201
  [[ "$(stat -c %s "$path")" -le 1024 ]] || exit 202
  rm -f "$path"
}

case "$stage" in
  ABSENT) ;;
  /opt/ownexit-chain/.stage-*|/etc/ownexit-chain/.stage-*)
    if [[ -e "$stage" || -L "$stage" ]]; then
      [[ -d "$stage" && ! -L "$stage" && "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 203
      if [[ -e "$stage/stage-owner.env" || -L "$stage/stage-owner.env" ]]; then
        [[ -f "$stage/stage-owner.env" && ! -L "$stage/stage-owner.env" ]] || exit 204
        [[ "$owner_hash" != ABSENT && "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$owner_hash" ]] || exit 205
      else
        [[ -z "$(find "$stage" -mindepth 1 -maxdepth 1 -print -quit)" ]] || exit 206
      fi
      while IFS= read -r item; do
        relative="${item#$stage/}"
        case "$stage:$relative" in
          /opt/ownexit-chain/.stage-binary-*:stage-owner.env|\
          /opt/ownexit-chain/.stage-binary-*:archive.tar.gz|\
          /opt/ownexit-chain/.stage-binary-*:extracted|\
          /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-amd64|\
          /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-amd64/LICENSE|\
          /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-amd64/libcronet.so|\
          /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-amd64/sing-box|\
          /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-arm64|\
          /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-arm64/LICENSE|\
          /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-arm64/libcronet.so|\
          /opt/ownexit-chain/.stage-binary-*:extracted/sing-box-1.13.14-linux-arm64/sing-box) ;;
          /etc/ownexit-chain/.stage-relay-*:"$chain_id.owner.env"|\
          /etc/ownexit-chain/.stage-relay-*:"ownexit-chain-relay-$chain_id.socket"|\
          /etc/ownexit-chain/.stage-relay-*:"ownexit-chain-relay-$chain_id.service"|\
          /etc/ownexit-chain/.stage-relay-*:stage-owner.env) ;;
          /etc/ownexit-chain/.stage-exit-*:"$chain_id.owner.env"|\
          /etc/ownexit-chain/.stage-exit-*:"$chain_id.exit.json"|\
          /etc/ownexit-chain/.stage-exit-*:"ownexit-chain-exit-$chain_id.service"|\
          /etc/ownexit-chain/.stage-exit-*:stage-owner.env) ;;
          *) exit 209 ;;
        esac
      done < <(find "$stage" -mindepth 1 -print)
      # stage-owner 是恢复授权，保留到其它允许项全部删除之后。
      find "$stage" -depth -mindepth 1 ! -path "$stage/stage-owner.env" -delete
      rm -f "$stage/stage-owner.env"
      rmdir "$stage"
    fi
    ;;
  *) exit 207 ;;
esac

if [[ "$owner_base" != ABSENT ]]; then
  case "$owner_base" in
    /opt/ownexit-chain/.owner-*|/etc/ownexit-chain/.owner-*) ;;
    *) exit 208 ;;
  esac
  for suffix in .part .ready; do
    path="$owner_base$suffix"
    if [[ -e "$path" || -L "$path" ]]; then
      safe_small_owner_temp "$path"
    fi
  done
fi
CLEAN_RESIDUE
  chmod 600 "${output}" || return 1
}

cleanup_remote_residue() {
  local role stage owner_hash owner_base script
  role="$1"
  stage="$2"
  owner_hash="$3"
  owner_base="$4"
  script="${OP_TMP}/cleanup-residue.sh"
  write_cleanup_residue_script "${script}" || return 1
  if [[ "${role}" == relay ]]; then
    ssh_relay_stdin bash -s -- "${stage}" "${owner_hash}" "${owner_base}" "${CHAIN_ID}" < "${script}"
  else
    ssh_exit_stdin bash -s -- "${stage}" "${owner_hash}" "${owner_base}" "${CHAIN_ID}" < "${script}"
  fi
}

cleanup_local_stage_if_owned() {
  local item relative owner keys expected_keys
  [[ "${LOCAL_STAGE_PATH}" != ABSENT ]] || return 0
  if [[ ! -e "${LOCAL_STAGE_PATH}" && ! -L "${LOCAL_STAGE_PATH}" ]]; then
    return 0
  fi
  [[ -d "${LOCAL_STAGE_PATH}" && ! -L "${LOCAL_STAGE_PATH}" && "$(stat_uid "${LOCAL_STAGE_PATH}")" == "$(id -u)" && "$(stat_mode "${LOCAL_STAGE_PATH}")" == 700 ]] || return 1
  owner="${LOCAL_STAGE_PATH}/stage-owner.env"
  if [[ -e "${owner}" || -L "${owner}" ]]; then
    require_secure_user_file "${owner}" 600 || return 1
    if [[ "${LOCAL_STAGE_OWNER_SHA256}" != ABSENT ]]; then
      [[ "$(sha256_file "${owner}")" == "${LOCAL_STAGE_OWNER_SHA256}" ]] || return 1
    else
      # 首份 journal 前收到信号时 hash 可能尚未赋值；此时用完整 owner schema 绑定本次锁后再清理。
      keys="$(awk -F= '{print $1}' "${owner}")"
      expected_keys="$(printf '%s\n' SCHEMA_VERSION CHAIN_ID DEPLOYMENT_ID OPERATION_ID CONFIG_SHA256)"
      [[ "${keys}" == "${expected_keys}" ]] || return 1
      [[ "$(kv_get "${owner}" SCHEMA_VERSION)" == 1 ]] || return 1
      [[ "$(kv_get "${owner}" CHAIN_ID)" == "${CHAIN_ID}" ]] || return 1
      [[ "$(kv_get "${owner}" DEPLOYMENT_ID)" == "${DEPLOYMENT_ID}" ]] || return 1
      [[ "$(kv_get "${owner}" OPERATION_ID)" == "${LOCK_OPERATION_ID}" ]] || return 1
      [[ "$(kv_get "${owner}" CONFIG_SHA256)" == "${CONFIG_SHA256}" ]] || return 1
    fi
  else
    [[ -z "$(find "${LOCAL_STAGE_PATH}" -mindepth 1 -print -quit)" ]] || return 1
  fi
  while IFS= read -r item; do
    relative="${item#${LOCAL_STAGE_PATH}/}"
    case "${relative}" in
      stage-owner.env|baseline|baseline/relay-config-manifest.txt|baseline/relay-unit-manifest.txt|baseline/relay-binary-manifest.txt|baseline/relay-listeners.txt|client|client/node.txt) ;;
      *) return 1 ;;
    esac
  done < <(find "${LOCAL_STAGE_PATH}" -mindepth 1 -print)
  find "${LOCAL_STAGE_PATH}" -depth -mindepth 1 -delete || return 1
  rmdir "${LOCAL_STAGE_PATH}" || return 1
}

archive_recovered_transaction() {
  local target
  ensure_private_dir "${CHAIN_STATE_DIR}/audit" || return 1
  target="${CHAIN_STATE_DIR}/audit/recovered.${DEPLOYMENT_ID}.${OPERATION_ID}.env"
  if [[ ! -e "${target}" && ! -L "${target}" ]]; then
    link "${JOURNAL_FILE}" "${target}" || return 1
    chmod 600 "${target}" || return 1
  else
    require_secure_user_file "${target}" 600 || return 1
    [[ "$(sha256_file "${target}")" == "$(sha256_file "${JOURNAL_FILE}")" ]] || return 1
  fi
}

deploy_commit_is_recoverable() {
  case "${LAST_COMPLETED_STEP}" in
    FULL_VERIFY_OK|STATE_WRITTEN|COMMITTED) ;;
    *) return 1 ;;
  esac
  if [[ -e "${STATE_FILE}" || -L "${STATE_FILE}" ]]; then
    [[ -f "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || return 1
    state_matches_loaded_transaction || return 1
  else
    [[ "${LAST_COMPLETED_STEP}" == FULL_VERIFY_OK ]] || return 1
  fi
  probe_remote_platform_preflight || return 1
  verify_remote_resources no || return 1
  verify_local_artifacts || return 1
  verify_relay_baseline || return 1
  deployment_residue_absent || return 1
}

finish_verified_deploy_commit() {
  case "${LAST_COMPLETED_STEP}" in
    FULL_VERIFY_OK|STATE_WRITTEN|COMMITTED) ;;
    *) die 1 "不可补齐的 deploy commit step：${LAST_COMPLETED_STEP}" ;;
  esac
  if [[ ! -e "${STATE_FILE}" && "${LAST_COMPLETED_STEP}" == FULL_VERIFY_OK ]]; then
    write_active_state
    LAST_COMPLETED_STEP='STATE_WRITTEN'
    write_journal
  fi
  [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 1 '补齐 deploy commit 时 active state 缺失'
  state_matches_loaded_transaction || die 1 '补齐 deploy commit 时 state/transaction 不一致'
  remote_platform_preflight
  verify_remote_resources no || die 1 '补齐 deploy commit 时远端资源复核失败'
  verify_local_artifacts || die 1 '补齐 deploy commit 时本地产物复核失败'
  verify_relay_baseline || die 1 '补齐 deploy commit 时既有 sing-box 基线复核失败'
  deployment_residue_absent || die 1 '补齐 deploy commit 时仍有部署残留'
  if [[ "${LAST_COMPLETED_STEP}" == COMMITTED ]]; then
    archive_deploy_transaction
    return 0
  fi
  LAST_COMPLETED_STEP='COMMITTED'
  write_journal
  archive_deploy_transaction
}

cleanup_incomplete_deploy() {
  if [[ "${RELAY_OWNER_SHA256}" != ABSENT ]]; then
    stop_chain_role relay || die 1 '恢复未完成 deploy 时中转停止失败'
    remove_chain_role_files relay || die 1 '恢复未完成 deploy 时中转资源删除失败'
    verify_removed_chain_role relay || die 1 '恢复未完成 deploy 时中转删除复核失败'
  fi
  if [[ "${EXIT_OWNER_SHA256}" != ABSENT ]]; then
    stop_chain_role exit || die 1 '恢复未完成 deploy 时出口机停止失败'
    remove_chain_role_files exit || die 1 '恢复未完成 deploy 时出口机资源删除失败'
    verify_removed_chain_role exit || die 1 '恢复未完成 deploy 时出口机删除复核失败'
  fi
  cleanup_remote_residue relay "${RELAY_STAGE_PATH}" "${RELAY_STAGE_OWNER_SHA256}" "${RELAY_STAGE_OWNER_TEMP_PATH}" || die 1 '恢复未完成 deploy 时中转配置 staging 清理失败'
  cleanup_remote_residue exit "${EXIT_STAGE_PATH}" "${EXIT_STAGE_OWNER_SHA256}" "${EXIT_STAGE_OWNER_TEMP_PATH}" || die 1 '恢复未完成 deploy 时出口机配置 staging 清理失败'
  cleanup_remote_residue relay "${RELAY_BINARY_STAGE_PATH}" "${RELAY_BINARY_STAGE_OWNER_SHA256}" "${RELAY_BINARY_STAGE_OWNER_TEMP_PATH}" || die 1 '恢复未完成 deploy 时中转 binary staging 清理失败'
  cleanup_remote_residue exit "${EXIT_BINARY_STAGE_PATH}" "${EXIT_BINARY_STAGE_OWNER_SHA256}" "${EXIT_BINARY_STAGE_OWNER_TEMP_PATH}" || die 1 '恢复未完成 deploy 时出口机 binary staging 清理失败'
  cleanup_local_stage_if_owned || die 1 '恢复未完成 deploy 时本地 staging 清理失败'
  if [[ -e "${CHAIN_STATE_DIR}/client" || -L "${CHAIN_STATE_DIR}/client" || -e "${CHAIN_STATE_DIR}/baseline" || -L "${CHAIN_STATE_DIR}/baseline" || -e "${STATE_FILE}" || -L "${STATE_FILE}" ]]; then
    remove_active_local_artifacts || die 1 '恢复未完成 deploy 时本地产物清理失败'
  fi
  archive_recovered_transaction || die 1 '未完成 deploy transaction 归档失败'
  rm -f "${JOURNAL_FILE}" || die 1 '未完成 deploy transaction 删除失败'
  sync || die 1 '未完成 deploy 恢复持久化失败'
  log_info '未完成 deploy 已逆序恢复；两端共享 binary/目录按设计保留'
}

recover_incomplete_transaction() {
  [[ -e "${JOURNAL_FILE}" || -L "${JOURNAL_FILE}" ]] || return 0
  load_journal_file "${JOURNAL_FILE}"
  render_ssh_config
  verify_loaded_binding
  if [[ "${JOURNAL_OPERATION}" == rollback ]]; then
    perform_rollback_steps
    return
  fi
  [[ "${JOURNAL_OPERATION}" == deploy ]] || die 1 "未知 transaction operation：${JOURNAL_OPERATION}"
  # 只有无副作用的完整一致性判定进入条件上下文；真正的 commit/cleanup 均作为独立命令执行。
  if deploy_commit_is_recoverable; then
    finish_verified_deploy_commit
    log_info '未完成 deploy 已按全量一致状态补齐 commit'
    return 0
  fi
  cleanup_incomplete_deploy
}

configured_resources_absent() {
  local script relay exit_rc
  script="${OP_TMP}/configured-absent.sh"
  cat > "${script}" <<'CONFIGURED_ABSENT'
#!/usr/bin/env bash
set -euo pipefail
umask 077
role="$1"
chain_id="$2"
config_hash="$3"
if [[ "$role" == relay ]]; then
  paths=(
    "/etc/ownexit-chain/$chain_id.owner.env"
    "/etc/systemd/system/ownexit-chain-relay-$chain_id.socket"
    "/etc/systemd/system/ownexit-chain-relay-$chain_id.service"
    "/etc/systemd/system/sockets.target.wants/ownexit-chain-relay-$chain_id.socket"
  )
else
  paths=(
    "/etc/ownexit-chain/$chain_id.owner.env"
    "/etc/ownexit-chain/$chain_id.exit.json"
    "/etc/systemd/system/ownexit-chain-exit-$chain_id.service"
    "/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-$chain_id.service"
  )
fi
for path in "${paths[@]}"; do
  [[ ! -e "$path" && ! -L "$path" ]] || exit 1
done
for parent in /etc/ownexit-chain /opt/ownexit-chain; do
  [[ -d "$parent" && ! -L "$parent" ]] || continue
  find "$parent" -maxdepth 1 -type d -name '.stage-*' -print | while IFS= read -r stage; do
    owner="$stage/stage-owner.env"
    [[ -f "$owner" && ! -L "$owner" ]] || continue
    grep -qx "CHAIN_ID=$chain_id" "$owner" || continue
    grep -qx "CONFIG_SHA256=$config_hash" "$owner" || continue
    exit 9
  done
  status="$?"
  [[ "$status" -eq 0 ]] || exit 1
  find "$parent" -maxdepth 1 -type f \( -name '.owner-*.part' -o -name '.owner-*.ready' \) -print | while IFS= read -r owner_temp; do
    [[ ! -L "$owner_temp" && "$(stat -c %u:%g:%a "$owner_temp")" == 0:0:600 ]] || continue
    grep -qx "CHAIN_ID=$chain_id" "$owner_temp" || continue
    grep -qx "CONFIG_SHA256=$config_hash" "$owner_temp" || continue
    exit 9
  done
  status="$?"
  [[ "$status" -eq 0 ]] || exit 1
  done
CONFIGURED_ABSENT
  chmod 600 "${script}"
  if ssh_relay_stdin bash -s -- relay "${CHAIN_ID}" "${CONFIG_SHA256}" < "${script}" >/dev/null; then relay=0; else relay="$?"; fi
  if ssh_exit_stdin bash -s -- exit "${CHAIN_ID}" "${CONFIG_SHA256}" < "${script}" >/dev/null; then exit_rc=0; else exit_rc="$?"; fi
  [[ "${relay}" -ne 255 ]] || return 21
  [[ "${exit_rc}" -ne 255 ]] || return 22
  [[ "${relay}" -eq 0 && "${exit_rc}" -eq 0 ]] || return 1
  if remote_unit_absent relay "ownexit-chain-relay-${CHAIN_ID}.socket"; then relay=0; else relay="$?"; fi
  if [[ "${relay}" -eq 0 ]]; then
    if remote_unit_absent relay "ownexit-chain-relay-${CHAIN_ID}.service"; then relay=0; else relay="$?"; fi
  fi
  if remote_unit_absent exit "ownexit-chain-exit-${CHAIN_ID}.service"; then exit_rc=0; else exit_rc="$?"; fi
  [[ "${relay}" -ne 2 ]] || return 21
  [[ "${exit_rc}" -ne 2 ]] || return 22
  [[ "${relay}" -eq 0 && "${exit_rc}" -eq 0 ]]
}

configured_local_resources_absent() {
  local candidate
  if [[ ! -e "${CHAIN_STATE_DIR}" && ! -L "${CHAIN_STATE_DIR}" ]]; then
    return 0
  fi
  private_dir_is_safe "${CHAIN_STATE_DIR}" || return 1
  for candidate in \
    "${CHAIN_STATE_DIR}/baseline" \
    "${CHAIN_STATE_DIR}/client" \
    "${CHAIN_STATE_DIR}/active-child.env" \
    "${CHAIN_STATE_DIR}/local-process.env" \
    "${CHAIN_STATE_DIR}"/.active-child.*.tmp \
    "${CHAIN_STATE_DIR}"/.local-process.*.tmp \
    "${CHAIN_STATE_DIR}"/.stage-local-* \
    "${CHAIN_STATE_DIR}"/.stage-owner.*.tmp \
    "${CHAIN_STATE_DIR}"/.state.env.*.tmp \
    "${CHAIN_STATE_DIR}"/.transaction.env.*.tmp \
    "${CHAIN_STATE_DIR}"/.node.txt.rotate.*.tmp \
    "${CHAIN_STATE_DIR}/devices"; do
    [[ ! -e "${candidate}" && ! -L "${candidate}" ]] || return 1
  done
}

verify_command() {
  local rc
  if acquire_chain_lock 1; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 5 'verify 无法取得 chain lock'
  require_local_dependencies
  [[ ! -e "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]] || die 5 '存在 incomplete transaction，verify 拒绝'
  [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 5 'chain 尚未部署'
  render_ssh_config
  load_state_file "${STATE_FILE}"
  verify_loaded_binding
  ensure_local_assets_match_state
  full_verify
  if [[ "${WITH_FAIL_CLOSED}" == 1 ]]; then
    verify_fail_closed
    full_verify
  fi
  log_info "verify 通过；chain=${CHAIN_ID} fail_closed=${WITH_FAIL_CLOSED} elapsed=$(elapsed_seconds)s"
}

# ---------- 中转连接治理：conns / kick / ban / unban / banlist ----------
# 这些命令不进入 deploy/rollback 的 transaction 机制：远端动作只有"写一个受管 drop-in + daemon-reload
# + 回读核对"或 ss -K，失败可重跑同一命令幂等修正；本地黑名单 blacklist.txt 是权威副本。

# 把 a.b.c.d 或 a.b.c.d/N 规范化为 a.b.c.d/N（与 systemctl show -p IPAddressDeny 回显形态一致）。
# 拒绝前导零、越界字节、前缀 >32、主机位非零——否则本地渲染串与远端回读串无法逐字比较。
normalize_ip_entry() {
  local entry ip prefix o1 o2 o3 o4 addr mask
  entry="$1"
  ip="${entry%%/*}"
  if [[ "${entry}" == */* ]]; then prefix="${entry#*/}"; else prefix=32; fi
  [[ "${ip}" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  [[ "${prefix}" =~ ^(0|[1-9][0-9]?)$ ]] || return 1
  (( prefix <= 32 )) || return 1
  IFS=. read -r o1 o2 o3 o4 <<<"${ip}"
  (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
  addr=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
  if (( prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF )); fi
  (( (addr & ~mask & 0xFFFFFFFF) == 0 )) || return 1
  printf '%d.%d.%d.%d/%d\n' "${o1}" "${o2}" "${o3}" "${o4}" "${prefix}"
}

# 判断规范化项 outer 是否覆盖 inner（inner 的网络落在 outer 内且前缀不短于 outer）。
# systemd 会把被覆盖的前缀折叠掉（/24 与其中的 /32 只回显 /24），所以本地列表必须保持互不重叠，
# 否则回读值永远对不上本地渲染串。
entry_covers() {
  local outer inner o1 o2 o3 o4 onet inet oprefix mask
  outer="$1"
  inner="$2"
  oprefix="${outer#*/}"
  (( oprefix <= ${inner#*/} )) || return 1
  IFS=. read -r o1 o2 o3 o4 <<<"${outer%%/*}"
  onet=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
  IFS=. read -r o1 o2 o3 o4 <<<"${inner%%/*}"
  inet=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
  if (( oprefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - oprefix)) & 0xFFFFFFFF )); fi
  (( (inet & mask) == onet ))
}

# 判断 a.b.c.d 是否落在某条规范化黑名单项内；供 conns 打 banned 标记。
ip_matches_entry() {
  local ip entry o1 o2 o3 o4 addr net prefix mask
  ip="$1"
  entry="$2"
  IFS=. read -r o1 o2 o3 o4 <<<"${ip}"
  addr=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
  IFS=. read -r o1 o2 o3 o4 <<<"${entry%%/*}"
  net=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
  prefix="${entry#*/}"
  if (( prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF )); fi
  (( (addr & mask) == (net & mask) ))
}

# 读本地黑名单（每行一条规范化项）；文件不存在视为空。内容非法或权限异常一律 die 5：
# 这是 verify 核远端的依据，不能"尽力解析"。
read_blacklist() {
  local line normalized
  [[ -e "${BLACKLIST_FILE}" || -L "${BLACKLIST_FILE}" ]] || return 0
  require_secure_user_file "${BLACKLIST_FILE}" 600 || die 5 "blacklist.txt 必须是本人 600 regular file：${BLACKLIST_FILE}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    normalized="$(normalize_ip_entry "${line}")" || die 5 "blacklist.txt 含非法条目：${line}"
    [[ "${normalized}" == "${line}" ]] || die 5 "blacklist.txt 条目未规范化：${line}"
    printf '%s\n' "${line}"
  done < "${BLACKLIST_FILE}"
}

# 渲染远端 IPAddressDeny 的预期回读串（空格分隔，顺序 = 文件顺序）。
render_expected_deny() {
  read_blacklist | tr '\n' ' ' | sed -e 's/ *$//'
}

# 渲染受管 drop-in 内容；首行节名是 verify 的核对项之一。
render_blacklist_dropin() {
  local section entries
  section="$1"
  entries="$2"
  printf '[%s]\n' "${section}"
  printf '%s\n' "${entries}" | awk 'NF { print "IPAddressDeny=" $0 }'
}

# 本地黑名单原子落盘：同目录 temp → mv；空列表直接删除文件（与"远端无 drop-in"契约对齐）。
write_blacklist_atomic() {
  local entries temp
  entries="$1"
  if [[ -z "${entries}" ]]; then
    rm -f "${BLACKLIST_FILE}" || die 5 'blacklist.txt 删除失败'
    return 0
  fi
  temp="${CHAIN_STATE_DIR}/.blacklist.${OPERATION_ID}.tmp"
  ( umask 077; printf '%s\n' "${entries}" > "${temp}" ) || die 5 'blacklist.txt 临时文件写入失败'
  mv -f "${temp}" "${BLACKLIST_FILE}" || { rm -f "${temp}"; die 5 'blacklist.txt 原子替换失败'; }
}

# 治理命令的统一门禁：锁 + 依赖 + 无 incomplete transaction + state 可加载 + host/key 绑定未漂移。
# mutating=1（kick/ban/unban）与 0（conns/banlist）的区别只在锁类型，远端 SSH 都受 run_managed_external 管控。
require_deployed_for_control() {
  local mutating rc
  mutating="$1"
  if acquire_chain_lock "${mutating}"; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    10) die 5 '同一 chain 有活动锁（busy）；稍后重试' ;;
    11) die 5 '存在 stale lock；先运行 verify 或其它 mutating 命令归档' ;;
    *) die 5 '无法安全取得 chain lock' ;;
  esac
  require_local_dependencies
  [[ ! -e "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]] || die 5 "存在 incomplete transaction，${COMMAND} 拒绝"
  [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 5 'chain 尚未部署'
  render_ssh_config
  load_state_file "${STATE_FILE}"
  verify_loaded_binding
}

write_relay_conns_script() {
  local output
  output="$1"
  cat > "${output}" <<'RELAY_CONNS'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
port="$1"
service_name="$2"
# ss -tnio 每个 socket 两行：首行含 peer，次行含 lastrcv:<ms>；这里压成 "ip lastrcv_ms" 一行。
ss -Htnio state established "( sport = :$port )" | awk '
  /^[0-9]/ { n = split($4, a, ":"); ip = a[n-1]; have = 1; next }
  have { v = 0; if (match($0, /lastrcv:[0-9]+/)) v = substr($0, RSTART + 8, RLENGTH - 8); print "CONN " ip " " v; have = 0 }
'
pid="$(systemctl show "$service_name" -p MainPID --value)"
if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
  used="$(ls "/proc/$pid/fd" | wc -l | tr -d ' ')"
  limit="$(awk '/^Max open files/ {print $4}' "/proc/$pid/limits")"
  printf 'FD %s %s\n' "$used" "$limit"
else
  printf 'FD 0 0\n'
fi
RELAY_CONNS
  chmod 600 "${output}"
}

relay_conns() {
  local script output entries fd_used fd_limit total peers line ip cnt idle_min idle_max banned entry
  require_deployed_for_control 0
  script="${OP_TMP}/relay-conns.sh"
  write_relay_conns_script "${script}"
  output="$(ssh_relay_stdin bash -s -- "${RELAY_PORT}" "ownexit-chain-relay-${CHAIN_ID}.service" < "${script}")" || die 5 '中转连接列表采集失败'
  entries="$(read_blacklist)"
  fd_used="$(printf '%s\n' "${output}" | awk '$1 == "FD" {print $2}')"
  fd_limit="$(printf '%s\n' "${output}" | awk '$1 == "FD" {print $3}')"
  total="$(printf '%s\n' "${output}" | awk '$1 == "CONN" {n++} END {print n + 0}')"
  printf '%-18s %6s %11s %11s %s\n' ip conns idle_min_s idle_max_s banned
  peers=0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    IFS=' ' read -r ip cnt idle_min idle_max <<<"${line}"
    banned=no
    while IFS= read -r entry; do
      [[ -n "${entry}" ]] || continue
      if ip_matches_entry "${ip}" "${entry}"; then banned="yes(${entry})"; break; fi
    done <<<"${entries}"
    printf '%-18s %6s %11s %11s %s\n' "${ip}" "${cnt}" "${idle_min}" "${idle_max}" "${banned}"
    peers=$((peers + 1))
  done <<<"$(printf '%s\n' "${output}" | awk '
    $1 == "CONN" { c[$2]++; s = int($3 / 1000); if (!($2 in mn) || s < mn[$2]) mn[$2] = s; if (s > mx[$2]) mx[$2] = s }
    END { for (ip in c) print ip, c[ip], mn[ip], mx[ip] }' | sort -k2,2nr -k1,1)"
  printf 'proxyd_fd=%s/%s established=%s peers=%s port=%s\n' "${fd_used}" "${fd_limit}" "${total}" "${peers}" "${RELAY_PORT}"
  log_info "[relay-control] conns chain=${CHAIN_ID} peers=${peers} established=${total} fd=${fd_used}/${fd_limit}"
}

write_relay_kick_script() {
  local output
  output="$1"
  cat > "${output}" <<'RELAY_KICK'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
port="$1"
target="$2"
err="$(mktemp /tmp/ownexit-kick.XXXXXX)"
trap 'rm -f "$err"' EXIT
# ss -K 在内核不支持 SOCK_DESTROY 时退出码仍为 0、只在 stderr 报 "Operation not supported"，必须看 stderr。
killed="$(ss -HK dst "$target" "( sport = :$port )" 2>"$err" | grep -c . || true)"
if [[ -s "$err" ]]; then
  cat "$err" >&2
  exit 185
fi
printf 'KICKED=%s\n' "$killed"
RELAY_KICK
  chmod 600 "${output}"
}

# 销毁指定来源在中转端口上的全部已建连接；target 可为 a.b.c.d 或 a.b.c.d/N（ss 过滤器原生支持 CIDR）。
kick_relay_target() {
  local target script output killed
  target="$1"
  script="${OP_TMP}/relay-kick.sh"
  write_relay_kick_script "${script}"
  output="$(ssh_relay_stdin bash -s -- "${RELAY_PORT}" "${target}" < "${script}")" || die 5 '中转 ss -K 失败（内核可能不支持 SOCK_DESTROY）'
  killed="${output#KICKED=}"
  [[ "${killed}" =~ ^[0-9]+$ ]] || die 5 '中转 kick 返回格式异常'
  printf '%s\n' "${killed}"
}

relay_kick() {
  local entry killed
  entry="$(normalize_ip_entry "${TARGET_IP}")" || die 2 "kick 需要合法 IPv4：${TARGET_IP}"
  [[ "${entry}" == */32 ]] || die 2 'kick 只接受单个 IPv4，不接受网段'
  require_deployed_for_control 1
  killed="$(kick_relay_target "${entry%/32}")"
  printf 'kicked ip=%s destroyed=%s\n' "${entry%/32}" "${killed}"
  log_info "[relay-control] kick ip=${entry%/32} destroyed=${killed}"
}

write_relay_blacklist_script() {
  local output
  output="$1"
  cat > "${output}" <<'RELAY_BLACKLIST'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
chain_id="$1"
dropin_name="$2"
expected="$3"
# 同 verify 脚本：经 ssh 传参空串会丢、空格会拆，控制端用逗号连接、"-" 表示空。
[[ "$expected" != '-' ]] || expected=''
expected="${expected//,/ }"
socket_b64="$4"
service_b64="$5"
tmp_in_flight=''
# 任一步失败都不能留下 .tmp：目录里多一个文件就会让 verify/status 判 drift。
trap '[[ -z "$tmp_in_flight" ]] || rm -f "$tmp_in_flight"' EXIT

# 对一个 unit 落地/撤销受管 drop-in。目录里出现任何非受管文件即拒绝：那不是本脚本的产物，不能替它做主。
apply_dropin() {
  local unit_file dir content_b64 tmp
  unit_file="$1"
  content_b64="$2"
  dir="$unit_file.d"
  [[ -f "$unit_file" && ! -L "$unit_file" ]] || exit 181
  if [[ -e "$dir" || -L "$dir" ]]; then
    [[ -d "$dir" && ! -L "$dir" && "$(stat -c %u:%g "$dir")" == 0:0 ]] || exit 182
    # 上一次中途失败留下的同名 .tmp 是本脚本自己的残留，可清；其它任何文件都不是我们的产物。
    find "$dir" -mindepth 1 -maxdepth 1 -name ".$dropin_name.*.tmp" -type f -delete
    find "$dir" -mindepth 1 -maxdepth 1 -print | while IFS= read -r entry; do
      [[ "$entry" == "$dir/$dropin_name" ]] || exit 182
    done
  fi
  if [[ -z "$expected" ]]; then
    if [[ -d "$dir" ]]; then
      rm -f "$dir/$dropin_name"
      rmdir "$dir"
    fi
    return 0
  fi
  [[ -d "$dir" ]] || mkdir -m 755 "$dir"
  tmp="$dir/.$dropin_name.$$.tmp"
  tmp_in_flight="$tmp"
  printf '%s' "$content_b64" | base64 -d > "$tmp"
  chown root:root "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$dir/$dropin_name"
  tmp_in_flight=''
}

socket_file="/etc/systemd/system/ownexit-chain-relay-$chain_id.socket"
service_file="/etc/systemd/system/ownexit-chain-relay-$chain_id.service"
apply_dropin "$socket_file" "$socket_b64"
apply_dropin "$service_file" "$service_b64"
systemctl daemon-reload
# 回读生效值：drop-in 写成功但 systemd 没接受（语法/平台）时，这里必须失败而不是静默"已拉黑"。
sorted_words() {
  printf '%s\n' "$1" | tr ' ' '\n' | awk 'NF' | sort | tr '\n' ' ' | sed -e 's/ *$//'
}
for unit in "ownexit-chain-relay-$chain_id.socket" "ownexit-chain-relay-$chain_id.service"; do
  [[ "$(sorted_words "$(systemctl show "$unit" -p IPAddressDeny --value)")" == "$(sorted_words "$expected")" ]] || exit 183
done
printf 'BLACKLIST=ok\n'
RELAY_BLACKLIST
  chmod 600 "${output}"
}

# 把整份列表推到中转并核回读；entries 为空 = 撤销 drop-in。
push_relay_blacklist() {
  local entries expected script socket_b64 service_b64 output
  entries="$1"
  expected="$(printf '%s\n' "${entries}" | awk 'NF' | tr '\n' ',' | sed -e 's/,*$//')"
  [[ -n "${expected}" ]] || expected='-'
  socket_b64="$(render_blacklist_dropin Socket "${entries}" | openssl base64 -A)"
  service_b64="$(render_blacklist_dropin Service "${entries}" | openssl base64 -A)"
  script="${OP_TMP}/relay-blacklist.sh"
  write_relay_blacklist_script "${script}"
  output="$(ssh_relay_stdin bash -s -- "${CHAIN_ID}" "${RELAY_BLACKLIST_DROPIN}" "${expected}" "${socket_b64}" "${service_b64}" < "${script}")" || die 5 '中转黑名单 drop-in 写入或回读核对失败（目录内有非受管文件、或平台不支持 IPAddressDeny）'
  [[ "${output}" == BLACKLIST=ok ]] || die 5 '中转黑名单脚本输出异常'
}

relay_ban() {
  local entry current updated count killed existing
  entry="$(normalize_ip_entry "${TARGET_IP}")" || die 2 "ban 需要合法 IPv4 或 CIDR（主机位须为 0）：${TARGET_IP}"
  require_deployed_for_control 1
  current="$(read_blacklist)"
  # 已被更宽的旧条目覆盖：不改任何东西（否则 systemd 折叠后回读值与本地对不上）。
  while IFS= read -r existing; do
    [[ -n "${existing}" ]] || continue
    if entry_covers "${existing}" "${entry}"; then
      printf 'already-covered entry=%s by=%s\n' "${entry}" "${existing}"
      return 0
    fi
  done <<<"${current}"
  # 新条目更宽时吸收被它覆盖的旧条目，保持列表互不重叠。
  updated="$(while IFS= read -r existing; do
    [[ -n "${existing}" ]] || continue
    entry_covers "${entry}" "${existing}" || printf '%s\n' "${existing}"
  done <<<"${current}"; printf '%s\n' "${entry}")"
  updated="$(printf '%s\n' "${updated}" | awk 'NF' | sort -u)"
  # 先推远端再落本地：远端成功、本地失败时 verify 会报 drift，重跑 ban 即可收敛；反过来会留下"本地有、远端无"的假安全。
  push_relay_blacklist "${updated}"
  write_blacklist_atomic "${updated}"
  count="$(printf '%s\n' "${updated}" | awk 'NF' | wc -l | tr -d ' ')"
  # BPF 只拦新包，连接表里的旧 socket 还挂着；顺手 ss -K 让它们立刻释放 proxyd 的 fd。
  killed="$(kick_relay_target "${entry}")"
  printf 'banned entry=%s entries=%s destroyed=%s\n' "${entry}" "${count}" "${killed}"
  log_info "[relay-control] ban ip=${entry} entries=${count} reload=ok destroyed=${killed}"
}

relay_unban() {
  local entry current updated count
  entry="$(normalize_ip_entry "${TARGET_IP}")" || die 2 "unban 需要合法 IPv4 或 CIDR：${TARGET_IP}"
  require_deployed_for_control 1
  current="$(read_blacklist)"
  printf '%s\n' "${current}" | grep -qx -- "${entry}" || die 2 "黑名单中不存在：${entry}"
  updated="$(printf '%s\n' "${current}" | grep -vx -- "${entry}" | awk 'NF' || true)"
  push_relay_blacklist "${updated}"
  write_blacklist_atomic "${updated}"
  count="$(printf '%s\n' "${updated}" | awk 'NF' | wc -l | tr -d ' ')"
  printf 'unbanned entry=%s entries=%s\n' "${entry}" "${count}"
  log_info "[relay-control] unban ip=${entry} entries=${count} reload=ok"
}

relay_banlist() {
  local expected socket_deny service_deny
  require_deployed_for_control 0
  expected="$(render_expected_deny)"
  socket_deny="$(ssh_relay systemctl show "ownexit-chain-relay-${CHAIN_ID}.socket" -p IPAddressDeny --value)" || die 5 '中转 socket IPAddressDeny 读取失败'
  service_deny="$(ssh_relay systemctl show "ownexit-chain-relay-${CHAIN_ID}.service" -p IPAddressDeny --value)" || die 5 '中转 service IPAddressDeny 读取失败'
  printf 'local:   %s\n' "${expected:-<empty>}"
  printf 'socket:  %s\n' "${socket_deny:-<empty>}"
  printf 'service: %s\n' "${service_deny:-<empty>}"
  expected="$(printf '%s\n' "${expected}" | tr ' ' '\n' | awk 'NF' | sort | tr '\n' ' ' | sed -e 's/ *$//')"
  socket_deny="$(printf '%s\n' "${socket_deny}" | tr ' ' '\n' | awk 'NF' | sort | tr '\n' ' ' | sed -e 's/ *$//')"
  service_deny="$(printf '%s\n' "${service_deny}" | tr ' ' '\n' | awk 'NF' | sort | tr '\n' ' ' | sed -e 's/ *$//')"
  if [[ "${expected}" == "${socket_deny}" && "${expected}" == "${service_deny}" ]]; then
    printf 'banlist=consistent entries=%s\n' "$(read_blacklist | awk 'NF' | wc -l | tr -d ' ')"
  else
    printf 'banlist=inconsistent next=run-ban-or-unban\n'
    return 5
  fi
}

# ---------- 出口机同机换 IP：rehost-exit ----------
# 适用场景：出口机还是同一台机器（ed25519 主机指纹不变），只是服务商换了公网 IP。
# 用户先把 config 的 EXIT_HOST / EXPECTED_EXIT_IPV4 改成新值，本命令把中转转发目标、两端 owner
# 和本地 state 原地收敛到新值。UUID、Reality 密钥、端口、客户端产物都不变，客户端无需重新订阅。
# 不进入 transaction/journal：每个远端步骤都同时接受“旧形态”和“已迁移形态”，本地 state 最后提交；
# 中途失败时重跑同一命令即可收敛，state 已经绑定新 config 时直接 noop。

# state 里记录的迁移前取值，由 load_state_for_rehost 填充，远端脚本用它们定位要替换的旧行。
REHOST_OLD_EXIT_HOST=''
REHOST_OLD_EXPECTED_EXIT_IPV4=''
REHOST_OLD_CONFIG_SHA256=''
# 1 表示 state 已绑定新 config（此前已迁移完成），本次不连远端、不写任何文件。
REHOST_IS_NOOP=0

# 按“只豁免 EXIT_HOST / EXPECTED_EXIT_IPV4”的口径加载 state。
# 进入时全局变量是新 config 的值。返回后全局变量仍是新值，state 的其余字段（凭据、哈希、CREATED_AT 等）
# 已由 probe_state_file 加载，REHOST_OLD_* 为 state 中的旧值。
# 不直接改 probe_state_file：临时把两键换回旧值后复用它，其余 10 个键和校验和仍按原逻辑逐项核验，
# 这样豁免范围不会被意外放宽。
load_state_for_rehost() {
  local rc new_host new_exit new_config old_host old_exit
  if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
  if [[ "${rc}" -eq 0 ]]; then
    REHOST_IS_NOOP=1
    return 0
  fi
  # rc=12 才表示 schema 与 checksum 都已通过、只在配置绑定上不一致；其它 rc 说明 state 本身损坏。
  [[ "${rc}" -eq 12 ]] || die 5 "state.env 校验失败：${STATE_PROBE_REASON}"
  new_host="${EXIT_HOST}"
  new_exit="${EXPECTED_EXIT_IPV4}"
  new_config="${CONFIG_SHA256}"
  old_host="$(kv_get "${STATE_FILE}" EXIT_HOST)" || die 5 'state.env 缺少 EXIT_HOST'
  old_exit="$(kv_get "${STATE_FILE}" EXPECTED_EXIT_IPV4)" || die 5 'state.env 缺少 EXPECTED_EXIT_IPV4'
  is_ipv4 "${old_host}" && is_ipv4 "${old_exit}" || die 5 'state.env 中的 EXIT_HOST / EXPECTED_EXIT_IPV4 不是 IPv4'
  EXIT_HOST="${old_host}"
  EXPECTED_EXIT_IPV4="${old_exit}"
  # 与 parse_config 同一算法重算旧配置摘要；只有其余 10 个键都与 state 一致时，它才会等于 state 里的 CONFIG_SHA256。
  CONFIG_SHA256="$(normalized_config | sha256_text)"
  if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 2 '除 EXIT_HOST / EXPECTED_EXIT_IPV4 外还有配置键与 state 不一致；rehost-exit 只迁移这两个键'
  REHOST_OLD_EXIT_HOST="${old_host}"
  REHOST_OLD_EXPECTED_EXIT_IPV4="${old_exit}"
  REHOST_OLD_CONFIG_SHA256="${CONFIG_SHA256}"
  EXIT_HOST="${new_host}"
  EXPECTED_EXIT_IPV4="${new_exit}"
  CONFIG_SHA256="${new_config}"
}

# 远端迁移脚本，出口机（role=exit）和中转（role=relay）共用。
# 所有替换都是“整文件哈希守门 + 单行精确替换”：文件哈希必须等于 state 记录的值才动手，
# 替换后除目标行外逐字节不变，所以同一输入必然得到同一新哈希。
# 哈希不等时，把新值反向替换回旧值再算哈希；等于 state 值说明上一次已经迁移过，按 already 放行，
# 否则就是外部改动（drift），拒绝继续。
write_rehost_remote_script() {
  local output
  output="$1"
  cat > "${output}" <<'REHOST_REMOTE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
role="$1"
chain_id="$2"
owner_state_hash="$3"
old_cfg="$4"
new_cfg="$5"
service_state_hash="${6:-}"
old_target="${7:-}"
new_target="${8:-}"
tmp_in_flight=''
scratch="$(mktemp /tmp/ownexit-rehost.XXXXXX)"
# 半写的 temp 会被 verify 的残留检查判 drift，任何退出路径都必须清掉。
trap '[[ -z "$tmp_in_flight" ]] || rm -f "$tmp_in_flight"; rm -f "$scratch"' EXIT

# owner 按整行精确匹配 CONFIG_SHA256=<hash>。
count_owner() { awk -v line="$2" '$0 == line {n++} END {print n + 0}' "$1"; }
replace_owner() { awk -v from="$2" -v to="$3" '{ if ($0 == from) print to; else print }' "$1"; }
# service 只认以 " <host:port>" 结尾的 ExecStart= 行。IP 里的点在 sed 正则里会匹配任意字符，所以这里用 awk 字符串比较。
count_service() {
  awk -v sfx=" $2" 'index($0, "ExecStart=") == 1 && length($0) > length(sfx) && substr($0, length($0) - length(sfx) + 1) == sfx {n++} END {print n + 0}' "$1"
}
replace_service() {
  awk -v sfx=" $2" -v to=" $3" '{
    if (index($0, "ExecStart=") == 1 && length($0) > length(sfx) && substr($0, length($0) - length(sfx) + 1) == sfx)
      print substr($0, 1, length($0) - length(sfx)) to
    else
      print
  }' "$1"
}

# 参数：文件、权限位、state 记录的哈希、kind(owner|service)、旧值、新值、身份异常码、行数异常码、drift 码。
migrate_file() {
  local file mode state_hash kind from to current tmp
  file="$1"; mode="$2"; state_hash="$3"; kind="$4"; from="$5"; to="$6"
  [[ -f "$file" && ! -L "$file" && "$(stat -c %u:%g:%a "$file")" == "0:0:$mode" ]] || exit "$7"
  current="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$current" == "$state_hash" ]]; then
    [[ "$("count_$kind" "$file" "$from")" == 1 ]] || exit "$8"
    tmp="$(dirname "$file")/.$(basename "$file").rehost.$$.tmp"
    tmp_in_flight="$tmp"
    "replace_$kind" "$file" "$from" "$to" > "$tmp"
    chown root:root "$tmp"
    chmod "$mode" "$tmp"
    # 同目录 mv 是原子替换：读者只会看到完整的旧文件或完整的新文件。
    mv -f "$tmp" "$file"
    tmp_in_flight=''
    MIGRATE_RESULT=changed
  else
    "replace_$kind" "$file" "$to" "$from" > "$scratch"
    [[ "$(sha256sum "$scratch" | awk '{print $1}')" == "$state_hash" ]] || exit "$9"
    MIGRATE_RESULT=already
  fi
}

owner="/etc/ownexit-chain/$chain_id.owner.env"
migrate_file "$owner" 600 "$owner_state_hash" owner "CONFIG_SHA256=$old_cfg" "CONFIG_SHA256=$new_cfg" 171 172 173
printf 'OWNER=%s\n' "$MIGRATE_RESULT"
printf 'OWNER_SHA256=%s\n' "$(sha256sum "$owner" | awk '{print $1}')"
[[ "$role" == relay ]] || exit 0

service="/etc/systemd/system/ownexit-chain-relay-$chain_id.service"
unit="ownexit-chain-relay-$chain_id.service"
if [[ "$old_target" == "$new_target" ]]; then
  # 只改了 EXPECTED_EXIT_IPV4：转发目标不变，service 必须与 state 完全一致。
  [[ -f "$service" && ! -L "$service" && "$(stat -c %u:%g:%a "$service")" == 0:0:644 ]] || exit 174
  [[ "$(sha256sum "$service" | awk '{print $1}')" == "$service_state_hash" ]] || exit 176
  MIGRATE_RESULT=unchanged
else
  migrate_file "$service" 644 "$service_state_hash" service "$old_target" "$new_target" 174 175 176
fi
printf 'SERVICE=%s\n' "$MIGRATE_RESULT"
printf 'SERVICE_SHA256=%s\n' "$(sha256sum "$service" | awk '{print $1}')"
systemctl daemon-reload
# socket 激活的 service：没有连接时本来就是 inactive，下一条连接会按新 ExecStart 拉起，不用主动启动。
# active 时看正在运行的进程是否已指向新目标；上一次改完文件但没重启成功的情况也在这里补上重启。
restarted=inactive
if [[ "$(systemctl is-active "$unit" || true)" == active ]]; then
  pid="$(systemctl show "$unit" -p MainPID --value)"
  cmdline=''
  # 不用 tr | grep -q 管道：pipefail 下 grep 提前退出可能让 tr 吃 SIGPIPE，被误判为“未指向新目标”。
  [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  if [[ "$cmdline" == *" $new_target "* ]]; then
    restarted=no
  else
    systemctl restart "$unit"
    [[ "$(systemctl is-active "$unit" || true)" == active ]] || exit 177
    restarted=yes
  fi
fi
printf 'RESTARTED=%s\n' "$restarted"
REHOST_REMOTE
  chmod 600 "${output}"
}

# 远端退出码 → 可读原因，让 die 信息直接指向哪一类问题。
rehost_remote_reason() {
  case "$1" in
    171) printf '171 owner 文件身份或权限异常（要求 root:root 600）' ;;
    172) printf '172 owner 中 CONFIG_SHA256=<旧摘要> 不是恰好 1 行' ;;
    173) printf '173 owner 与 state 记录的哈希不符，且不是已迁移形态（drift）' ;;
    174) printf '174 relay service 文件身份或权限异常（要求 root:root 644）' ;;
    175) printf '175 relay service 中以旧目标结尾的 ExecStart 不是恰好 1 行' ;;
    176) printf '176 relay service 与 state 记录的哈希不符，且不是已迁移形态（drift）' ;;
    177) printf '177 relay service 重启后未进入 active' ;;
    255) printf '255 SSH 不可达或会话中断' ;;
    *) printf '%s 远端脚本异常退出' "$1" ;;
  esac
}

# 从远端输出里取 KEY=VALUE。
rehost_output_value() {
  printf '%s\n' "$1" | awk -F= -v wanted="$2" '$1 == wanted {print $2}'
}

rehost_exit_owner() {
  local script output rc result hash
  script="${OP_TMP}/rehost-remote.sh"
  write_rehost_remote_script "${script}"
  if output="$(ssh_exit_stdin bash -s -- exit "${CHAIN_ID}" "${EXIT_OWNER_SHA256}" "${REHOST_OLD_CONFIG_SHA256}" "${CONFIG_SHA256}" < "${script}")"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 1 "出口机 owner 迁移失败：$(rehost_remote_reason "${rc}")"
  result="$(rehost_output_value "${output}" OWNER)"
  hash="$(rehost_output_value "${output}" OWNER_SHA256)"
  [[ "${result}" =~ ^(changed|already)$ && "${hash}" =~ ^[0-9a-f]{64}$ ]] || die 1 '出口机 owner 迁移输出格式异常'
  EXIT_OWNER_SHA256="${hash}"
  log_info "[rehost] exit-owner=${result}"
}

rehost_relay() {
  local script output rc owner_result owner_hash service_result service_hash restarted
  script="${OP_TMP}/rehost-remote.sh"
  write_rehost_remote_script "${script}"
  if output="$(ssh_relay_stdin bash -s -- relay "${CHAIN_ID}" "${RELAY_OWNER_SHA256}" "${REHOST_OLD_CONFIG_SHA256}" "${CONFIG_SHA256}" "${RELAY_SERVICE_SHA256}" "${REHOST_OLD_EXIT_HOST}:${EXIT_REALITY_PORT}" "${EXIT_HOST}:${EXIT_REALITY_PORT}" < "${script}")"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 1 "中转迁移失败：$(rehost_remote_reason "${rc}")"
  owner_result="$(rehost_output_value "${output}" OWNER)"
  owner_hash="$(rehost_output_value "${output}" OWNER_SHA256)"
  service_result="$(rehost_output_value "${output}" SERVICE)"
  service_hash="$(rehost_output_value "${output}" SERVICE_SHA256)"
  restarted="$(rehost_output_value "${output}" RESTARTED)"
  [[ "${owner_result}" =~ ^(changed|already)$ && "${owner_hash}" =~ ^[0-9a-f]{64}$ ]] || die 1 '中转 owner 迁移输出格式异常'
  [[ "${service_result}" =~ ^(changed|already|unchanged)$ && "${service_hash}" =~ ^[0-9a-f]{64}$ ]] || die 1 '中转 service 迁移输出格式异常'
  [[ "${restarted}" =~ ^(yes|no|inactive)$ ]] || die 1 '中转 service 重启结果格式异常'
  RELAY_OWNER_SHA256="${owner_hash}"
  RELAY_SERVICE_SHA256="${service_hash}"
  log_info "[rehost] relay-owner=${owner_result} relay-service=${service_result} restarted=${restarted}"
}

# 本地提交放在远端两步之后：只要 state 还是旧的，重跑就会重新走远端步骤（已迁移的按 already 放行）。
# 旧 state 先归档再替换，便于人工回溯迁移前的哈希。
commit_rehost_state() {
  local audit payload
  ensure_private_dir "${CHAIN_STATE_DIR}/audit" || die 1 'rehost audit 父目录不安全'
  audit="${CHAIN_STATE_DIR}/audit/rehosted.${DEPLOYMENT_ID}.${OPERATION_ID}"
  [[ ! -e "${audit}" && ! -L "${audit}" ]] || die 1 "rehost audit 目录碰撞：${audit}"
  mkdir "${audit}" || die 1 'rehost audit 目录创建失败'
  chmod 700 "${audit}" || die 1 'rehost audit 目录权限设置失败'
  # 直接写最终文件名：audit 下以 . 开头的 *.tmp 会被残留检查判 drift。
  cp "${STATE_FILE}" "${audit}/state.env" || die 1 'rehost 旧 state 归档失败'
  chmod 600 "${audit}/state.env" || die 1 'rehost 旧 state 归档权限设置失败'
  [[ "$(sha256_file "${audit}/state.env")" == "$(sha256_file "${STATE_FILE}")" ]] || die 1 'rehost 旧 state 归档复核失败'
  payload="${OP_TMP}/state-payload"
  # 此时全局变量里 EXIT_HOST / EXPECTED_EXIT_IPV4 / CONFIG_SHA256 是新值，三个远端哈希来自迁移输出，
  # 其余字段（含 CREATED_AT）原样沿用 state，所以凭据与端口不会变化。
  render_state_payload "${payload}" || die 1 'rehost state payload 生成失败'
  write_checksummed_file "${STATE_FILE}" replace "${payload}"
  if probe_state_file "${STATE_FILE}"; then :; else die 1 "rehost 后 state 与新 config 绑定失败：${STATE_PROBE_REASON}"; fi
  log_info "[rehost] state committed audit=${audit}"
}

rehost_exit_chain() {
  local rc
  if acquire_chain_lock 1; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    10) die 5 '同一 chain 有活动锁（busy）；稍后重试' ;;
    11) die 5 '存在 stale lock；先运行 verify 或其它 mutating 命令归档' ;;
    *) die 5 '无法安全取得 chain lock' ;;
  esac
  migrate_gate
  require_local_dependencies
  [[ ! -e "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]] || die 5 '存在 incomplete transaction，rehost-exit 拒绝'
  [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 5 'chain 尚未部署'
  load_state_for_rehost
  if [[ "${REHOST_IS_NOOP}" == 1 ]]; then
    printf 'rehost=noop chain=%s next=run-verify\n' "${CHAIN_ID}"
    log_info "[rehost] noop chain=${CHAIN_ID}：state 已绑定当前 config"
    return 0
  fi
  # SSH 配置里的出口机地址此时已是新 IP；旧 IP 不需要可达。
  render_ssh_config
  if probe_loaded_binding; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    11) die 5 '中转 SSH key 指纹漂移' ;;
    12) die 5 '出口机 SSH key 指纹漂移' ;;
    21) die 3 '中转实际协商 host-key 探针不可达' ;;
    22) die 3 "经中转访问新 EXIT_HOST=${EXIT_HOST} 失败；确认 ~/.ssh/known_hosts 已有该 IP 的 ed25519 条目，且中转到新 IP 的 SSH 可达" ;;
    31) die 3 '中转实际协商 host-key 指纹漂移' ;;
    # 同机判据：指纹不同就是换了机器，凭据和 exit 服务都不在新机器上，原地迁移没有意义。
    32) die 3 "新 EXIT_HOST=${EXIT_HOST} 的主机指纹与 state 不一致：不是同一台出口机，应走 rollback + deploy" ;;
    *) die 5 '主机/密钥绑定核验异常' ;;
  esac
  log_info "[rehost] start chain=${CHAIN_ID} old_host=${REHOST_OLD_EXIT_HOST} new_host=${EXIT_HOST} old_exit=${REHOST_OLD_EXPECTED_EXIT_IPV4} new_exit=${EXPECTED_EXIT_IPV4}"
  # 顺序与 deploy 一致：先出口机后中转，本地 state 最后。
  rehost_exit_owner
  rehost_relay
  commit_rehost_state
  ensure_local_assets_match_state
  full_verify
  log_info "rehost-exit 通过；chain=${CHAIN_ID} elapsed=$(elapsed_seconds)s"
}

# ---------- 中转机既有 sing-box 重新登记：rebaseline（docs/feature/feature-direct-native-install.md §5.1.10） ----------
#
# 用途：中转机上的“既有 sing-box”发生了合法变化（233boy 迁移为 ownexit-direct、直连改参数 / 新装 / 卸载）后，
# 按现场重新判定 RELAY_COHOSTS_SINGBOX、重新采集零回归基线，链本身（凭据、端口、node.txt、中转转发）不动。
# 关键约束：
#   - 不调用 remote_platform_preflight：它按 state 里的旧取值检查，迁移后必然失败；安全检查由基线采集脚本与
#     收尾的 full_verify（按新取值）承担。
#   - owner 迁移先于 noop 判定且无条件执行：中断可能把 owner 留在任意合法取值的摘要上，只有先收敛 owner，
#     noop 才不会掩盖“verify 永远 owner 漂移”。
#   - noop 一律与 state 比对，不与本地 baseline 文件比对（baseline 可能已替换而 state 未提交）。

REBASELINE_BINDING=''
REBASELINE_STATE_COHOST=''
REBASELINE_STATE_CONFIG_SHA256=''
REBASELINE_LIVE_COHOST=''
REBASELINE_OWNER_CHANGED=0

# 测试钩子：在指定阶段后以退出码 99 结束，用于中断恢复用例；正常使用不要设置。
rebaseline_test_stop() {
  if [[ "${OWNEXIT_TEST_CHAIN_STOP_AFTER:-}" == "$1" ]]; then
    log_warn "测试钩子：rebaseline 在 $1 之后停止"
    exit 99
  fi
}

# 以给定取值计算配置摘要（与 parse_config 同一算法）；不改变调用方的 RELAY_COHOSTS_SINGBOX。
config_sha256_with_cohost() {
  local saved digest
  saved="${RELAY_COHOSTS_SINGBOX}"
  RELAY_COHOSTS_SINGBOX="$1"
  digest="$(normalized_config | sha256_text)"
  RELAY_COHOSTS_SINGBOX="${saved}"
  printf '%s' "${digest}"
}

load_state_for_rebaseline() {
  local rc config_cohost
  if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
  if [[ "${rc}" -eq 0 ]]; then
    REBASELINE_BINDING=current
  else
    [[ "${rc}" -eq 12 ]] || die 5 "state.env 校验失败：${STATE_PROBE_REASON}"
    # 配置里只有 RELAY_COHOSTS_SINGBOX 与 state 不同（上次 rebaseline 改了配置未提交，或用户手工改了这一键）才放行。
    config_cohost="${RELAY_COHOSTS_SINGBOX}"
    RELAY_COHOSTS_SINGBOX="$(kv_get "${STATE_FILE}" RELAY_COHOSTS_SINGBOX)" || die 5 'state.env 缺少 RELAY_COHOSTS_SINGBOX'
    CONFIG_SHA256="$(normalized_config | sha256_text)"
    if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
    [[ "${rc}" -eq 0 ]] || die 2 '除 RELAY_COHOSTS_SINGBOX 外还有配置键与 state 不一致；rebaseline 只处理这一个键'
    REBASELINE_BINDING='config-ahead'
    log_info "[rebaseline] 配置里的 RELAY_COHOSTS_SINGBOX=${config_cohost} 与 state 不同（config-ahead）"
  fi
  REBASELINE_STATE_COHOST="$(kv_get "${STATE_FILE}" RELAY_COHOSTS_SINGBOX)"
  REBASELINE_STATE_CONFIG_SHA256="$(kv_get "${STATE_FILE}" CONFIG_SHA256)"
}

# 远端 owner 迁移：规范形态（CONFIG_SHA256 行换回 state 值）的哈希必须等于 state 记录的 owner 哈希，防外部改动；
# 当前值必须是 state 值或三种合法取值的摘要之一（覆盖任意次中断留下的中间值）；已是新值则不动。
write_rebaseline_owner_script() {
  local output
  output="$1"
  cat > "${output}" <<'REBASELINE_OWNER'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
chain_id="$1"
owner_state_hash="$2"
state_cfg="$3"
new_cfg="$4"
shift 4
owner="/etc/ownexit-chain/$chain_id.owner.env"
tmp=''
scratch="$(mktemp /tmp/ownexit-rebaseline.XXXXXX)"
trap '[[ -z "$tmp" ]] || rm -f "$tmp"; rm -f "$scratch"' EXIT
[[ -f "$owner" && ! -L "$owner" && "$(stat -c %u:%g:%a "$owner")" == 0:0:600 ]] || exit 180
[[ "$(awk 'index($0, "CONFIG_SHA256=") == 1 {n++} END {print n + 0}' "$owner")" == 1 ]] || exit 181
current="$(awk 'index($0, "CONFIG_SHA256=") == 1 {print substr($0, 15)}' "$owner")"
awk -v to="CONFIG_SHA256=$state_cfg" '{ if (index($0, "CONFIG_SHA256=") == 1) print to; else print }' "$owner" > "$scratch"
[[ "$(sha256sum "$scratch" | awk '{print $1}')" == "$owner_state_hash" ]] || exit 181
allowed=no
for candidate in "$state_cfg" "$@"; do
  [[ "$current" != "$candidate" ]] || allowed=yes
done
[[ "$allowed" == yes ]] || exit 182
if [[ "$current" == "$new_cfg" ]]; then
  result=already
else
  tmp="$(dirname "$owner")/.$(basename "$owner").rebaseline.$$.tmp"
  awk -v to="CONFIG_SHA256=$new_cfg" '{ if (index($0, "CONFIG_SHA256=") == 1) print to; else print }' "$owner" > "$tmp"
  chown root:root "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$owner"
  tmp=''
  result=changed
fi
printf 'OWNER=%s\n' "$result"
printf 'OWNER_SHA256=%s\n' "$(sha256sum "$owner" | awk '{print $1}')"
REBASELINE_OWNER
  chmod 600 "${output}"
}

rebaseline_owner_reason() {
  case "$1" in
    180) printf '180 owner 文件身份或权限异常（要求 root:root 600）' ;;
    181) printf '181 owner 规范形态与 state 不符（外部改动）' ;;
    182) printf '182 owner 中的配置摘要不是 state 值或三种合法取值的摘要之一' ;;
    255) printf '255 SSH 不可达或会话中断' ;;
    *) printf '%s 远端脚本异常退出' "$1" ;;
  esac
}

# 迁移一端 owner；role=exit|relay。输出写入 REBASELINE_OWNER_RESULT / REBASELINE_OWNER_HASH。
rebaseline_owner() {
  local role script output rc state_hash legal_yes legal_no legal_direct
  role="$1"
  script="${OP_TMP}/rebaseline-owner.sh"
  write_rebaseline_owner_script "${script}"
  if [[ "${role}" == exit ]]; then state_hash="${EXIT_OWNER_SHA256}"; else state_hash="${RELAY_OWNER_SHA256}"; fi
  legal_yes="$(config_sha256_with_cohost yes)"
  legal_no="$(config_sha256_with_cohost no)"
  legal_direct="$(config_sha256_with_cohost ownexit-direct)"
  if [[ "${role}" == exit ]]; then
    if output="$(ssh_exit_stdin bash -s -- "${CHAIN_ID}" "${state_hash}" "${REBASELINE_STATE_CONFIG_SHA256}" "${REBASELINE_NEW_CONFIG_SHA256}" "${legal_yes}" "${legal_no}" "${legal_direct}" < "${script}")"; then rc=0; else rc="$?"; fi
  else
    if output="$(ssh_relay_stdin bash -s -- "${CHAIN_ID}" "${state_hash}" "${REBASELINE_STATE_CONFIG_SHA256}" "${REBASELINE_NEW_CONFIG_SHA256}" "${legal_yes}" "${legal_no}" "${legal_direct}" < "${script}")"; then rc=0; else rc="$?"; fi
  fi
  [[ "${rc}" -eq 0 ]] || die 1 "${role} owner 迁移失败：$(rebaseline_owner_reason "${rc}")"
  REBASELINE_OWNER_RESULT="$(printf '%s\n' "${output}" | awk -F= '$1 == "OWNER" {print $2}')"
  REBASELINE_OWNER_HASH="$(printf '%s\n' "${output}" | awk -F= '$1 == "OWNER_SHA256" {print $2}')"
  [[ "${REBASELINE_OWNER_RESULT}" =~ ^(changed|already)$ && "${REBASELINE_OWNER_HASH}" =~ ^[0-9a-f]{64}$ ]] || die 1 "${role} owner 迁移输出格式异常"
  [[ "${REBASELINE_OWNER_RESULT}" == already ]] || REBASELINE_OWNER_CHANGED=1
  log_info "[rebaseline] ${role}-owner=${REBASELINE_OWNER_RESULT}"
}

# 原子改写配置文件中恰好一行 RELAY_COHOSTS_SINGBOX=（其余字节不变）；旧配置先复制进审计目录。
rewrite_config_cohost() {
  local audit current tmp count
  audit="$1"
  current="$(awk -F= '$1 == "RELAY_COHOSTS_SINGBOX" {print $2}' "${CONFIG_PATH}")"
  [[ "${current}" != "${REBASELINE_LIVE_COHOST}" ]] || return 0
  count="$(awk 'index($0, "RELAY_COHOSTS_SINGBOX=") == 1 {n++} END {print n + 0}' "${CONFIG_PATH}")"
  [[ "${count}" == 1 ]] || die 2 "配置文件中 RELAY_COHOSTS_SINGBOX= 不是恰好 1 行：${CONFIG_PATH}"
  cp "${CONFIG_PATH}" "${audit}/config.env" || die 1 'rebaseline 旧配置归档失败'
  chmod 600 "${audit}/config.env"
  tmp="$(dirname "${CONFIG_PATH}")/.$(basename "${CONFIG_PATH}").rebaseline.$$.tmp"
  awk -v to="RELAY_COHOSTS_SINGBOX=${REBASELINE_LIVE_COHOST}" '{ if (index($0, "RELAY_COHOSTS_SINGBOX=") == 1) print to; else print }' "${CONFIG_PATH}" > "${tmp}" || die 1 'rebaseline 配置改写失败'
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${CONFIG_PATH}" || die 1 'rebaseline 配置原子替换失败'
  log_info "[rebaseline] 配置 RELAY_COHOSTS_SINGBOX ${current} -> ${REBASELINE_LIVE_COHOST}"
}

# 旧 state 与旧基线归档，新基线替换 baseline/ 下 4 个文件，再按新值写 state。
publish_rebaseline() {
  local audit fresh file payload
  audit="$1"
  fresh="$2"
  cp "${STATE_FILE}" "${audit}/state.env" || die 1 'rebaseline 旧 state 归档失败'
  chmod 600 "${audit}/state.env"
  ensure_private_dir "${audit}/baseline" || die 1 'rebaseline baseline 审计目录不安全'
  ensure_private_dir "${CHAIN_STATE_DIR}/baseline" || die 1 'baseline 目录不安全'
  for file in relay-config-manifest.txt relay-unit-manifest.txt relay-binary-manifest.txt relay-listeners.txt; do
    if [[ -f "${CHAIN_STATE_DIR}/baseline/${file}" ]]; then
      cp "${CHAIN_STATE_DIR}/baseline/${file}" "${audit}/baseline/${file}"
      chmod 600 "${audit}/baseline/${file}"
    fi
    cp "${fresh}/${file}" "${CHAIN_STATE_DIR}/baseline/.${file}.rebaseline.tmp"
    chmod 600 "${CHAIN_STATE_DIR}/baseline/.${file}.rebaseline.tmp"
    mv -f "${CHAIN_STATE_DIR}/baseline/.${file}.rebaseline.tmp" "${CHAIN_STATE_DIR}/baseline/${file}"
  done
  rebaseline_test_stop baseline
  payload="${OP_TMP}/state-payload"
  render_state_payload "${payload}" || die 1 'rebaseline state payload 生成失败'
  write_checksummed_file "${STATE_FILE}" replace "${payload}"
  if probe_state_file "${STATE_FILE}"; then :; else die 1 "rebaseline 后 state 与配置绑定失败：${STATE_PROBE_REASON}"; fi
  log_info "[rebaseline] state committed audit=${audit}"
}

rebaseline_chain() {
  local rc fresh new_config_hash new_unit new_listen new_binary new_active new_enabled exit_hash relay_hash audit config_cohost
  if acquire_chain_lock 1; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    10) die 5 '同一 chain 有活动锁（busy）；稍后重试' ;;
    11) die 5 '存在 stale lock；先运行 verify 或其它 mutating 命令归档' ;;
    *) die 5 '无法安全取得 chain lock' ;;
  esac
  migrate_gate
  require_local_dependencies
  [[ ! -e "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]] || die 5 '存在 incomplete transaction，rebaseline 拒绝'
  [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 5 'chain 尚未部署'
  config_cohost="${RELAY_COHOSTS_SINGBOX}"
  load_state_for_rebaseline
  render_ssh_config
  if probe_loaded_binding; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    11) die 5 '中转 SSH key 指纹漂移' ;;
    12) die 5 '出口机 SSH key 指纹漂移' ;;
    21) die 3 '中转实际协商 host-key 探针不可达' ;;
    22) die 3 '经中转访问出口机失败' ;;
    31) die 3 '中转实际协商 host-key 指纹漂移' ;;
    32) die 3 '出口机实际协商 host-key 指纹漂移' ;;
    *) die 5 '主机/密钥绑定核验异常' ;;
  esac
  REBASELINE_LIVE_COHOST="$(relay_cohost_kind_via "${RELAY_SSH_KEY}" "${RELAY_SSH_PORT}" "${RELAY_HOST}")" \
    || die 3 "中转机上的 sing-box 状态不完整（${REBASELINE_LIVE_COHOST}）；先让既有服务完整运行或彻底移除再重跑"
  log_info "[rebaseline] kind state=${REBASELINE_STATE_COHOST} config=${config_cohost} live=${REBASELINE_LIVE_COHOST}"

  # 第 5 步：按现场取值采集基线、算新配置摘要（采集脚本按全局 RELAY_COHOSTS_SINGBOX 分支）。
  RELAY_COHOSTS_SINGBOX="${REBASELINE_LIVE_COHOST}"
  fresh="${OP_TMP}/baseline-rebaseline"
  collect_relay_baseline "${fresh}"
  new_config_hash="$(sha256_file "${fresh}/relay-config-manifest.txt")"
  new_unit="$(sha256_file "${fresh}/relay-unit-manifest.txt")"
  new_binary="$(sha256_file "${fresh}/relay-binary-manifest.txt")"
  new_listen="$(sha256_file "${fresh}/relay-listeners.txt")"
  new_active="${RELAY_BASELINE_SERVICE_ACTIVE}"
  new_enabled="${RELAY_BASELINE_SERVICE_ENABLED}"
  REBASELINE_NEW_CONFIG_SHA256="$(normalized_config | sha256_text)"

  # 第 6 步：owner 迁移先于 noop 判定，无条件执行（幂等）。
  rebaseline_owner exit
  exit_hash="${REBASELINE_OWNER_HASH}"
  rebaseline_owner relay
  relay_hash="${REBASELINE_OWNER_HASH}"
  rebaseline_test_stop owner

  # 第 6a 步：noop（比较对象一律是 state）。
  if [[ "${REBASELINE_BINDING}" == current && "${REBASELINE_LIVE_COHOST}" == "${REBASELINE_STATE_COHOST}" && "${REBASELINE_OWNER_CHANGED}" == 0 \
        && "${new_config_hash}" == "$(kv_get "${STATE_FILE}" RELAY_BASELINE_CONFIG_MANIFEST_SHA256)" \
        && "${new_unit}" == "$(kv_get "${STATE_FILE}" RELAY_BASELINE_UNIT_MANIFEST_SHA256)" \
        && "${new_binary}" == "$(kv_get "${STATE_FILE}" RELAY_BASELINE_BINARY_MANIFEST_SHA256)" \
        && "${new_listen}" == "$(kv_get "${STATE_FILE}" RELAY_BASELINE_LISTEN_SHA256)" \
        && "${new_active}" == "$(kv_get "${STATE_FILE}" RELAY_BASELINE_SERVICE_ACTIVE)" \
        && "${new_enabled}" == "$(kv_get "${STATE_FILE}" RELAY_BASELINE_SERVICE_ENABLED)" ]]; then
    printf 'rebaseline=noop chain=%s kind=%s\n' "${CHAIN_ID}" "${REBASELINE_LIVE_COHOST}"
    log_info "[rebaseline] noop chain=${CHAIN_ID}"
    return 0
  fi

  # 第 6b 步：审计目录（第 7 步复用）与配置改写。
  ensure_private_dir "${CHAIN_STATE_DIR}/audit" || die 1 'rebaseline audit 父目录不安全'
  audit="${CHAIN_STATE_DIR}/audit/rebaselined.${DEPLOYMENT_ID}.${OPERATION_ID}"
  [[ ! -e "${audit}" && ! -L "${audit}" ]] || die 1 "rebaseline audit 目录碰撞：${audit}"
  mkdir "${audit}" || die 1 'rebaseline audit 目录创建失败'
  chmod 700 "${audit}" || die 1 'rebaseline audit 目录权限设置失败'
  rewrite_config_cohost "${audit}"
  rebaseline_test_stop config

  # 第 7 步：全局变量换成新值后提交（其余字段沿用 state，凭据与端口不变）。
  CONFIG_SHA256="${REBASELINE_NEW_CONFIG_SHA256}"
  EXIT_OWNER_SHA256="${exit_hash}"
  RELAY_OWNER_SHA256="${relay_hash}"
  RELAY_BASELINE_CONFIG_MANIFEST_SHA256="${new_config_hash}"
  RELAY_BASELINE_UNIT_MANIFEST_SHA256="${new_unit}"
  RELAY_BASELINE_BINARY_MANIFEST_SHA256="${new_binary}"
  RELAY_BASELINE_LISTEN_SHA256="${new_listen}"
  RELAY_BASELINE_SERVICE_ACTIVE="${new_active}"
  RELAY_BASELINE_SERVICE_ENABLED="${new_enabled}"
  publish_rebaseline "${audit}" "${fresh}"

  # 第 8 步。
  ensure_local_assets_match_state
  full_verify
  log_info "rebaseline 通过；chain=${CHAIN_ID} kind=${REBASELINE_LIVE_COHOST} elapsed=$(elapsed_seconds)s"
}

# ---------- 出口机凭据与设备操作：rotate-keys / add-device / remove-device ----------
# （docs/feature/feature-formats-key-rotation.md §5.1.3、docs/feature/feature-devices-sni-scan.md §5.1.2）
#
# 三个命令共用一套“出口机凭据操作”：只改出口机 sing-box 配置（users 行，rotate 时另换私钥与 short id），
# 中转、端口、部署 ID、owner、配置摘要都不变。不走事务（同 rehost-exit）：中间状态放在出口机的辅助文件里，
# 本地 state 最后提交，任一步中断后重跑同一条命令都能按现场收敛。私钥与 UUID 只在出口机上生成。
#   <id>.rotate.json      待切换的新配置（rotate 时含新私钥）
#   <id>.rotate.env       MODE（本次操作）、新配置哈希、目标设备全表（DEVICE_<名字>=UUID）、rotate 时的公钥与 short id
#   <id>.rotate.bak.json  切换前的旧配置，新配置起不来时用它恢复
# 设备清单的权威是出口机生效配置的 users 行：远端按操作从它推导新表，本机文件只是缓存，每次都用远端输出覆盖。
# 辅助文件存在期间 verify / status / rollback 都会拒绝（出口机核验脚本 exit 150），提示重跑中断的那条命令。

EXIT_OP_RESULT=''
EXIT_OP_DEVICES=''
ROTATE_NEW_EXIT_SHA256=''
DEVICE_NAME=''

# 测试钩子：在本机侧的指定阶段后以退出码 99 结束（stage / swap 两个阶段在远端脚本内实现）；正常使用不要设置。
# 对 rotate-keys / add-device / remove-device 都生效。
rotate_test_stop() {
  if [[ "${OWNEXIT_TEST_ROTATE_STOP_AFTER:-}" == "$1" ]]; then
    log_warn "测试钩子：${COMMAND} 在 $1 之后停止"
    exit 99
  fi
}

# 出口机上执行的凭据 / 设备操作脚本。mode=apply 按判定表生成 / 切换 / 恢复；mode=cleanup 只在线上已是新配置时删除辅助文件。
write_rotate_remote_script() {
  local output
  output="$1"
  cat > "${output}" <<'ROTATE_REMOTE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
mode="$1"
chain_id="$2"
[[ "$chain_id" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || exit 191
live="/etc/ownexit-chain/$chain_id.exit.json"
pending="/etc/ownexit-chain/$chain_id.rotate.json"
env_file="/etc/ownexit-chain/$chain_id.rotate.env"
bak="/etc/ownexit-chain/$chain_id.rotate.bak.json"
unit="ownexit-chain-exit-$chain_id.service"
# 临时文件统一叫 <id>.rotate.<用途>.<pid>.tmp：任何退出路径都清掉（其中可能有新私钥），也在 verify 的 150 检查范围内。
trap 'rm -f /etc/ownexit-chain/"$chain_id".rotate.*."$$".tmp' EXIT

sha() { sha256sum "$1" | awk '{print $1}'; }
env_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$env_file"; }
remove_helpers() {
  rm -f /etc/ownexit-chain/"$chain_id".rotate.json /etc/ownexit-chain/"$chain_id".rotate.env /etc/ownexit-chain/"$chain_id".rotate.bak.json
}

[[ -f "$live" && ! -L "$live" && "$(stat -c %u:%g:%a "$live")" == 0:0:600 ]] || exit 191

if [[ "$mode" == cleanup ]]; then
  # 只有线上已经是新配置时才删：此前删掉 bak 会让“新配置起不来”时无法恢复。
  [[ "$(sha "$live")" == "$3" ]] || exit 197
  remove_helpers
  printf 'CLEANUP=ok\n'
  exit 0
fi

op="$3"
port="$4"
state_hash="$5"
binary="$6"
test_stop="$7"
break_port="$8"
case "$op" in rotate|add:*|remove:*) ;; *) exit 200 ;; esac
[[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || exit 198

check_config() {
  (cd / && env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LD_LIBRARY_PATH= LD_PRELOAD= "$binary" check -c "$1" >/dev/null 2>&1)
}

# 最多等 10 秒：服务 active、主进程是固定二进制、并且由它监听 Reality 端口（与 verify 出口机脚本同一判据）。
wait_ready() {
  local i pid
  for i in $(seq 1 20); do
    if [[ "$(systemctl is-active "$unit" || true)" == active ]]; then
      pid="$(systemctl show "$unit" -p MainPID --value)"
      if [[ "$pid" =~ ^[1-9][0-9]*$ && "$(readlink -f "/proc/$pid/exe")" == "$binary" ]] \
        && ss -H -ltnp | awk -v suffix=":$port" -v pid="pid=$pid," 'substr($4, length($4)-length(suffix)+1) == suffix && index($0, pid) {found=1} END {exit found ? 0 : 1}'; then
        return 0
      fi
    fi
    sleep 0.5
  done
  return 1
}

# 测试钩子：把文件里 "listen_port": <port>, 这一行换成 break_port，构造“配置合法但起不来”。
apply_break_port() {
  local file tmp
  file="$1"
  [[ "$break_port" != - ]] || return 0
  tmp="/etc/ownexit-chain/$chain_id.rotate.break.$$.tmp"
  awk -v from="    \"listen_port\": $port," -v to="    \"listen_port\": $break_port," \
    '{ if ($0 == from) { print to; n++ } else print } END { exit n == 1 ? 0 : 3 }' "$file" > "$tmp" || exit 192
  chown root:root "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# 新配置起不来：放回旧配置并重启。恢复成功 195（线上回到操作前），恢复后仍起不来 196（需人工处理）。
restore_old() {
  mv -f "$bak" "$live"
  rm -f /etc/ownexit-chain/"$chain_id".rotate.json /etc/ownexit-chain/"$chain_id".rotate.env
  systemctl restart "$unit" || true
  if wait_ready; then exit 195; fi
  exit 196
}

# 从生效配置解析设备表，每行“名字 UUID”。users 行由 deploy 模板固定为单行数组；
# 旧部署（v0.6.0 及更早）的唯一一项没有 name 字段，视为 default。不是这两种形态时 exit 192。
parse_users() {
  awk '
    { t = $0; sub(/^[ ]+/, "", t); if (index(t, "\"users\": [") == 1) { n++; line = t } }
    END {
      if (n != 1) exit 3
      count = 0
      while (match(line, /\{[^}]*\}/)) {
        obj = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        name = ""; uuid = ""
        if (match(obj, /"name": "[^"]*"/)) name = substr(obj, RSTART + 9, RLENGTH - 10)
        if (match(obj, /"uuid": "[^"]*"/)) uuid = substr(obj, RSTART + 9, RLENGTH - 10)
        count++; names[count] = name; uuids[count] = uuid
      }
      if (count == 0) exit 3
      for (i = 1; i <= count; i++) {
        if (names[i] == "") { if (count != 1) exit 3; names[i] = "default" }
        print names[i], uuids[i]
      }
    }' "$live"
}

# 把“名字 UUID”列表渲染成 users 整行（4 个空格缩进，与 deploy 模板一致）。
render_users_line() {
  awk 'BEGIN { printf "    \"users\": [" } { printf "%s{ \"name\": \"%s\", \"uuid\": \"%s\", \"flow\": \"xtls-rprx-vision\" }", (NR > 1 ? ", " : ""), $1, $2 } END { print "]," }'
}

# 生成待切换配置：按操作从生效配置推导新设备表，整行替换 users；rotate 时另替换私钥与 short id 两行。
# 先写 env 再写 json，两者都在时以 env 里的哈希核对 json，半写状态只会被判成“残缺”而重新生成。
generate_pending() {
  local current target name new_uuid count keypair private_key public_key short_id tmp_json tmp_env new_hash users_line line
  remove_helpers
  current="$(parse_users)" || exit 192
  # mawk 不一定支持 {m,n} 重复，长度用 length() 判断。
  printf '%s\n' "$current" | awk '$1 !~ /^[a-z0-9][a-z0-9-]*$/ || length($1) > 32 || $2 !~ /^[0-9a-f-]+$/ || length($2) != 36 {bad=1} END {exit bad ? 1 : 0}' || exit 192
  [[ "$(printf '%s\n' "$current" | head -n 1 | awk '{print $1}')" == default ]] || exit 192
  private_key=''
  case "$op" in
    add:*)
      name="${op#add:}"
      [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$name" != default ]] || exit 200
      if printf '%s\n' "$current" | awk -v n="$name" '$1 == n {f=1} END {exit f ? 0 : 1}'; then exit 201; fi
      count="$(printf '%s\n' "$current" | awk 'NF {c++} END {print c + 0}')"
      (( count < 32 )) || exit 202
      new_uuid="$("$binary" generate uuid)"
      [[ "$new_uuid" =~ ^[0-9a-f-]{36}$ ]] || exit 194
      target="$(printf '%s\n%s %s\n' "$current" "$name" "$new_uuid")"
      ;;
    remove:*)
      name="${op#remove:}"
      [[ "$name" != default ]] || exit 204
      printf '%s\n' "$current" | awk -v n="$name" '$1 == n {f=1} END {exit f ? 0 : 1}' || exit 203
      target="$(printf '%s\n' "$current" | awk -v n="$name" '$1 != n')"
      ;;
    rotate)
      # 轮换：每台设备（含 default）都换新 UUID，再换 Reality 密钥对与 short id；所有客户端都要重新导入。
      target=''
      while IFS=' ' read -r name _; do
        [[ -n "$name" ]] || continue
        new_uuid="$("$binary" generate uuid)"
        [[ "$new_uuid" =~ ^[0-9a-f-]{36}$ ]] || exit 194
        target="${target}${target:+$'\n'}${name} ${new_uuid}"
      done <<< "$current"
      keypair="$("$binary" generate reality-keypair)"
      private_key="$(printf '%s\n' "$keypair" | awk -F': ' '$1 == "PrivateKey" {print $2}')"
      public_key="$(printf '%s\n' "$keypair" | awk -F': ' '$1 == "PublicKey" {print $2}')"
      short_id="$("$binary" generate rand --hex 8)"
      [[ "$private_key" =~ ^[A-Za-z0-9_-]+$ && "$public_key" =~ ^[A-Za-z0-9_-]+$ && "$short_id" =~ ^[0-9a-f]{16}$ ]] || exit 194
      ;;
  esac
  users_line="$(printf '%s\n' "$target" | render_users_line)"
  tmp_json="/etc/ownexit-chain/$chain_id.rotate.json.$$.tmp"
  tmp_env="/etc/ownexit-chain/$chain_id.rotate.env.$$.tmp"
  awk -v u="$users_line" -v k="$private_key" -v s="${short_id:-}" '
    {
      t = $0
      sub(/^[ ]+/, "", t)
      if (index(t, "\"users\": [") == 1) { print u; nu++; next }
      if (k != "" && index(t, "\"private_key\": \"") == 1) { print "        \"private_key\": \"" k "\","; nk++; next }
      if (k != "" && index(t, "\"short_id\": [\"") == 1) { print "        \"short_id\": [\"" s "\"]"; ns++; next }
      print
    }
    END { exit (nu == 1 && (k == "" || (nk == 1 && ns == 1))) ? 0 : 3 }' "$live" > "$tmp_json" || exit 192
  chown root:root "$tmp_json"
  chmod 600 "$tmp_json"
  apply_break_port "$tmp_json"
  check_config "$tmp_json" || exit 194
  new_hash="$(sha "$tmp_json")"
  {
    printf 'MODE=%s\nNEW_SHA256=%s\n' "$op" "$new_hash"
    while IFS=' ' read -r name new_uuid; do
      [[ -n "$name" ]] || continue
      printf 'DEVICE_%s=%s\n' "$name" "$new_uuid"
    done <<< "$target"
    if [[ -n "$private_key" ]]; then
      printf 'REALITY_PUBLIC_KEY=%s\nREALITY_SHORT_ID=%s\n' "$public_key" "$short_id"
    fi
  } > "$tmp_env"
  chown root:root "$tmp_env"
  chmod 600 "$tmp_env"
  mv -f "$tmp_env" "$env_file"
  mv -f "$tmp_json" "$pending"
}

# 切换：先把旧配置备份成 bak（已有且就是 state 记录的旧配置时复用），再原子替换并重启。
do_swap() {
  local tmp
  if [[ ! -f "$bak" || "$(sha "$bak")" != "$state_hash" ]]; then
    tmp="/etc/ownexit-chain/$chain_id.rotate.bak.$$.tmp"
    cp -p "$live" "$tmp"
    mv -f "$tmp" "$bak"
  fi
  mv -f "$pending" "$live"
  systemctl restart "$unit" || true
  wait_ready || restore_old
}

pending_other() {
  printf 'PENDING_MODE=%s\n' "$env_mode"
  exit 199
}

live_hash="$(sha "$live")"
env_new=''
env_mode=''
if [[ -f "$env_file" && ! -L "$env_file" ]]; then
  env_new="$(env_get NEW_SHA256)"
  # v0.5.0 留下的 env 没有 MODE：它只可能来自 rotate-keys。
  env_mode="$(env_get MODE)"
  [[ -n "$env_mode" ]] || env_mode=rotate
fi

# 判定表（先分流，按操作推导只在“全新”分支执行：add 在切换后中断、重跑时 live 已含新设备，提前校验会被 201 误拒）。
if [[ "$live_hash" == "$state_hash" ]]; then
  if [[ -n "$env_new" && "$env_new" == "$live_hash" && "$env_mode" == "$op" ]]; then
    # 上一次同一操作已经提交了 state、只差清理：不再生成，交给本机核对后走 cleanup。
    result=resumed-after-commit
  elif [[ -n "$env_new" && "$env_new" == "$live_hash" ]]; then
    # 上一次另一操作已完成、只差清理：清掉后按全新处理本次操作。
    remove_helpers
    result=fresh
    generate_pending
    [[ "$test_stop" != stage ]] || exit 99
    do_swap
  elif [[ -n "$env_new" && -f "$pending" && ! -L "$pending" && "$(sha "$pending")" == "$env_new" ]]; then
    # 上一次在切换前中断：同一操作就复用，否则要先把那条命令重跑完。
    [[ "$env_mode" == "$op" ]] || pending_other
    result=resumed
    do_swap
  else
    result=fresh
    generate_pending
    [[ "$test_stop" != stage ]] || exit 99
    do_swap
  fi
elif [[ -n "$env_new" && "$live_hash" == "$env_new" ]]; then
  [[ "$env_mode" == "$op" ]] || pending_other
  # 已切换但本地还没提交：文件已是新配置，进程可能仍在跑旧配置（切换后、重启前中断），所以无条件重启一次。
  result=already
  [[ -f "$bak" && ! -L "$bak" ]] || exit 196
  apply_break_port "$live"
  systemctl restart "$unit" || true
  wait_ready || restore_old
else
  # 线上配置既不是 state 记录的，也不是本命令生成的：外部改动，什么都不动。
  exit 193
fi
[[ "$test_stop" != swap || "$result" == resumed-after-commit ]] || exit 99
printf 'RESULT=%s\n' "$result"
printf 'MODE=%s\n' "$op"
if awk -F= '$1 ~ /^DEVICE_/ {f=1} END {exit f ? 0 : 1}' "$env_file"; then
  awk -F= '$1 ~ /^DEVICE_/' "$env_file"
else
  # v0.5.0 的 env 只有 VLESS_UUID：它就是唯一的 default。
  printf 'DEVICE_default=%s\n' "$(env_get VLESS_UUID)"
fi
if [[ -n "$(env_get REALITY_PUBLIC_KEY)" ]]; then
  printf 'REALITY_PUBLIC_KEY=%s\n' "$(env_get REALITY_PUBLIC_KEY)"
  printf 'REALITY_SHORT_ID=%s\n' "$(env_get REALITY_SHORT_ID)"
fi
printf 'EXIT_EXIT_SHA256=%s\n' "$(sha "$live")"
ROTATE_REMOTE
  chmod 600 "${output}"
}

# 远端退出码 → 可读原因。
rotate_remote_reason() {
  case "$1" in
    191) printf '191 出口机配置文件身份或权限异常（要求 root:root 600、非软链）' ;;
    192) printf '192 出口机配置的 users / 私钥 / short id 行不是 deploy 生成的形态' ;;
    193) printf '193 出口机配置与 state 记录的哈希不符，且不是本命令生成的新配置（外部改动）' ;;
    194) printf '194 新凭据生成失败或新配置 sing-box check 未通过（线上未改动）' ;;
    195) printf '195 新配置启动失败，已恢复旧配置（线上仍是操作前的状态）' ;;
    196) printf '196 新配置启动失败，恢复旧配置后仍未起来（需人工检查出口机）' ;;
    197) printf '197 清理时线上配置不是新配置，拒绝删除辅助文件' ;;
    198) printf '198 出口机固定 sing-box 二进制缺失' ;;
    199) printf '199 出口机上有另一个未完成的操作' ;;
    200) printf '200 操作参数不合法' ;;
    201) printf '201 设备已存在' ;;
    202) printf '202 设备数已达上限 32（含 default）' ;;
    203) printf '203 没有这台设备' ;;
    204) printf '204 default 不能吊销' ;;
    255) printf '255 SSH 不可达或会话中断' ;;
    *) printf '%s 远端脚本异常退出' "$1" ;;
  esac
}

# 远端操作字符串对应的本机命令，用于“另一操作未完成”时告诉用户先重跑哪条。
exit_op_command_of() {
  case "$1" in
    rotate) printf 'rotate-keys' ;;
    add:*) printf 'add-device %s' "${1#add:}" ;;
    remove:*) printf 'remove-device %s' "${1#remove:}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# 执行远端 apply，结果写入 EXIT_OP_RESULT、EXIT_OP_DEVICES（每行 名字=UUID，含 default）、
# rotate 时的 REALITY_PUBLIC_KEY / REALITY_SHORT_ID，以及 ROTATE_NEW_EXIT_SHA256。
exit_op_apply() {
  local op script output rc test_stop break_port pending pbk sid
  op="$1"
  script="${OP_TMP}/rotate-remote.sh"
  write_rotate_remote_script "${script}"
  test_stop='-'
  case "${OWNEXIT_TEST_ROTATE_STOP_AFTER:-}" in stage|swap) test_stop="${OWNEXIT_TEST_ROTATE_STOP_AFTER}" ;; esac
  # ssh 会吞掉空参数，未设置时用 - 占位。
  break_port="${OWNEXIT_TEST_ROTATE_BREAK_PORT:--}"
  if output="$(ssh_exit_stdin bash -s -- apply "${CHAIN_ID}" "${op}" "${EXIT_REALITY_PORT}" "${EXIT_EXIT_SHA256}" "${REMOTE_BIN}" "${test_stop}" "${break_port}" < "${script}")"; then rc=0; else rc="$?"; fi
  if [[ "${rc}" -eq 99 && "${test_stop}" != - ]]; then
    log_warn "测试钩子：${COMMAND} 在远端 ${test_stop} 之后停止"
    exit 99
  fi
  case "${rc}" in
    0) ;;
    255) die 3 "出口机操作失败：$(rotate_remote_reason 255)" ;;
    199)
      pending="$(rehost_output_value "${output}" PENDING_MODE)"
      die 1 "出口机上有未完成的操作（$(exit_op_command_of "${pending}")）；先重跑 setup_chain.sh --id ${CHAIN_ID} $(exit_op_command_of "${pending}") 收敛，本次请求未执行"
      ;;
    201|202|203|204) die 2 "出口机操作被拒绝：$(rotate_remote_reason "${rc}")；出口机未改动" ;;
    *) die 1 "出口机操作失败：$(rotate_remote_reason "${rc}")" ;;
  esac
  EXIT_OP_RESULT="$(rehost_output_value "${output}" RESULT)"
  EXIT_OP_DEVICES="$(printf '%s\n' "${output}" | awk -F= '$1 ~ /^DEVICE_/ { sub(/^DEVICE_/, ""); print }')"
  ROTATE_NEW_EXIT_SHA256="$(rehost_output_value "${output}" EXIT_EXIT_SHA256)"
  [[ "${EXIT_OP_RESULT}" =~ ^(fresh|resumed|already|resumed-after-commit)$ ]] || die 1 '出口机操作输出格式异常（RESULT）'
  [[ "${ROTATE_NEW_EXIT_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die 1 '出口机操作输出格式异常（EXIT_EXIT_SHA256）'
  printf '%s\n' "${EXIT_OP_DEVICES}" | awk -F= '
    $1 !~ /^[a-z0-9][a-z0-9-]*$/ || length($1) > 32 || $2 !~ /^[0-9a-f-]+$/ || length($2) != 36 {bad=1}
    $1 == "default" {d++}
    END {exit (bad || d != 1) ? 1 : 0}' || die 1 '出口机返回的设备表不完整'
  VLESS_UUID="$(printf '%s\n' "${EXIT_OP_DEVICES}" | awk -F= '$1 == "default" {print $2; exit}')"
  pbk="$(rehost_output_value "${output}" REALITY_PUBLIC_KEY)"
  sid="$(rehost_output_value "${output}" REALITY_SHORT_ID)"
  if [[ "${op}" == rotate ]]; then
    [[ "${pbk}" =~ ^[A-Za-z0-9_-]+$ && "${sid}" =~ ^[0-9a-f]{16}$ ]] || die 1 '出口机未返回新的公钥与 short id'
    REALITY_PUBLIC_KEY="${pbk}"
    REALITY_SHORT_ID="${sid}"
  fi
  log_info "[exit-op] mode=${op} exit=${EXIT_OP_RESULT} devices=$(printf '%s\n' "${EXIT_OP_DEVICES}" | awk 'NF {c++} END {print c + 0}') new_exit_sha256=${ROTATE_NEW_EXIT_SHA256:0:12}"
}

# 额外设备的节点链接：与 render_node_artifact 相同的格式，UUID 与节点名不同。
# 节点名用 _ 连接（不在链名与设备名字符集里，避免与带连字符的链名重名；不用 @，部分客户端按最后一个 @ 拆用户信息）。
render_device_node() {
  local output name uuid
  output="$1"
  name="$2"
  uuid="$3"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#Exit-via-Relay-%s_%s\n' \
    "${uuid}" "${RELAY_HOST}" "${RELAY_PORT}" "${REALITY_SERVER_NAME}" \
    "${REALITY_PUBLIC_KEY}" "${REALITY_SHORT_ID}" "${CHAIN_ID}" "${name}" > "${output}"
  chmod 600 "${output}"
}

# 用远端输出覆盖本机产物：client/node.txt（default）与 devices/ 下的设备表和节点文件。
# client/node.txt 的临时文件放在 state 目录（不放 client/，否则中断残留会让 rollback 的 rmdir client 失败）；
# devices/ 下的文件用同目录 .<文件>.<操作ID>.tmp。都经 mv 原子替换。
publish_exit_op_artifacts() {
  local tmp devices_dir name uuid file keep
  tmp="${CHAIN_STATE_DIR}/.node.txt.rotate.${OPERATION_ID}.tmp"
  render_node_artifact "${tmp}"
  NODE_SHA256="$(sha256_file "${tmp}")"
  mv -f "${tmp}" "${CHAIN_STATE_DIR}/client/node.txt" || die 1 'node.txt 替换失败'
  require_secure_user_file "${CHAIN_STATE_DIR}/client/node.txt" 600 || die 1 'node.txt 替换后身份异常'
  [[ "$(sha256_file "${CHAIN_STATE_DIR}/client/node.txt")" == "${NODE_SHA256}" ]] || die 1 'node.txt 替换后 hash 不符'
  devices_dir="${CHAIN_STATE_DIR}/devices"
  keep="$(printf '%s\n' "${EXIT_OP_DEVICES}" | awk -F= 'NF && $1 != "default"')"
  if [[ -n "${keep}" ]]; then
    if [[ ! -d "${devices_dir}" ]]; then
      mkdir "${devices_dir}" || die 1 'devices 目录创建失败'
      chmod 700 "${devices_dir}" || die 1 'devices 目录权限设置失败'
    fi
    private_dir_is_safe "${devices_dir}" || die 1 'devices 目录身份异常'
    while IFS='=' read -r name uuid; do
      [[ -n "${name}" ]] || continue
      tmp="${devices_dir}/.node-${name}.txt.${OPERATION_ID}.tmp"
      render_device_node "${tmp}" "${name}" "${uuid}"
      mv -f "${tmp}" "${devices_dir}/node-${name}.txt" || die 1 "设备 ${name} 节点文件替换失败"
    done <<< "${keep}"
    tmp="${devices_dir}/.devices.env.${OPERATION_ID}.tmp"
    printf '%s\n' "${keep}" > "${tmp}"
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${devices_dir}/devices.env" || die 1 'devices.env 替换失败'
  fi
  if [[ -d "${devices_dir}" ]]; then
    # 不在新表里的设备（吊销的）：删掉它的节点文件。
    for file in "${devices_dir}"/node-*.txt; do
      [[ -e "${file}" ]] || continue
      name="$(basename "${file}" .txt)"
      name="${name#node-}"
      printf '%s\n' "${keep}" | awk -F= -v n="${name}" '$1 == n {f=1} END {exit f ? 0 : 1}' && continue
      require_secure_user_file "${file}" 600 || die 1 "设备节点文件身份异常：${file}"
      rm -f "${file}" || die 1 "设备节点文件删除失败：${file}"
    done
    if [[ -z "${keep}" ]]; then
      if [[ -e "${devices_dir}/devices.env" ]]; then
        require_secure_user_file "${devices_dir}/devices.env" 600 || die 1 'devices.env 身份异常'
        rm -f "${devices_dir}/devices.env" || die 1 'devices.env 删除失败'
      fi
      rmdir "${devices_dir}" 2>/dev/null || true
    fi
  fi
  log_info '[exit-op] node files published'
}

# 提交新 state（同 commit_rehost_state）：旧 state 先归档再替换；此时全局变量里凭据、EXIT_EXIT_SHA256、
# NODE_SHA256 是新值，其余字段原样沿用 state。$1 = audit 目录前缀（rotated / devices）。
commit_exit_op_state() {
  local prefix audit payload
  prefix="$1"
  ensure_private_dir "${CHAIN_STATE_DIR}/audit" || die 1 'audit 父目录不安全'
  audit="${CHAIN_STATE_DIR}/audit/${prefix}.${DEPLOYMENT_ID}.${OPERATION_ID}"
  [[ ! -e "${audit}" && ! -L "${audit}" ]] || die 1 "audit 目录碰撞：${audit}"
  mkdir "${audit}" || die 1 'audit 目录创建失败'
  chmod 700 "${audit}" || die 1 'audit 目录权限设置失败'
  # 直接写最终文件名：audit 下以 . 开头的 *.tmp 会被残留检查判 drift。
  cp "${STATE_FILE}" "${audit}/state.env" || die 1 '旧 state 归档失败'
  chmod 600 "${audit}/state.env" || die 1 '旧 state 归档权限设置失败'
  [[ "$(sha256_file "${audit}/state.env")" == "$(sha256_file "${STATE_FILE}")" ]] || die 1 '旧 state 归档复核失败'
  EXIT_EXIT_SHA256="${ROTATE_NEW_EXIT_SHA256}"
  payload="${OP_TMP}/state-payload"
  render_state_payload "${payload}" || die 1 'state payload 生成失败'
  write_checksummed_file "${STATE_FILE}" replace "${payload}"
  if probe_state_file "${STATE_FILE}"; then :; else die 1 "提交后 state 校验失败：${STATE_PROBE_REASON}"; fi
  log_info "[exit-op] state committed audit=${audit}"
}

rotate_cleanup_remote() {
  local script rc
  script="${OP_TMP}/rotate-remote.sh"
  write_rotate_remote_script "${script}"
  if ssh_exit_stdin bash -s -- cleanup "${CHAIN_ID}" "${EXIT_EXIT_SHA256}" < "${script}" >/dev/null; then rc=0; else rc="$?"; fi
  [[ "${rc}" -ne 255 ]] || die 3 "出口机辅助文件清理失败：$(rotate_remote_reason 255)；重跑 ${COMMAND} 收敛"
  [[ "${rc}" -eq 0 ]] || die 1 "出口机辅助文件清理失败：$(rotate_remote_reason "${rc}")"
  log_info '[exit-op] remote cleanup done'
}

# 加锁、核对 state 与主机绑定（rotate-keys / add-device / remove-device / list-devices 共用的前置步骤）。
exit_op_prepare() {
  local rc
  if acquire_chain_lock 1; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    10) die 5 '同一 chain 有活动锁（busy）；稍后重试' ;;
    11) die 5 '存在 stale lock；先运行 verify 或其它 mutating 命令归档' ;;
    *) die 5 '无法安全取得 chain lock' ;;
  esac
  # 迁移闸门放在 state 核对之前：迁移中配置与 state 必然不一致，否则会先报“配置与 state 不一致”而看不到迁移提示。
  # list-devices 只读，不拦。
  [[ "${COMMAND}" == list-devices ]] || migrate_gate
  require_local_dependencies
  [[ ! -e "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]] || die 5 "存在 incomplete transaction，${COMMAND} 拒绝"
  [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 5 'chain 尚未部署'
  if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    # rc=12：schema 与 checksum 通过、只是配置与 state 绑定不一致；这些命令不迁移任何配置键。
    12) die 2 "配置与 state 不一致；${COMMAND} 要求配置未改动（换出口 IP 用 rehost-exit，中转现状变化用 rebaseline）" ;;
    *) die 5 "state.env 校验失败：${STATE_PROBE_REASON}" ;;
  esac
  render_ssh_config
  if probe_loaded_binding; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    11) die 5 '中转 SSH key 指纹漂移' ;;
    12) die 5 '出口机 SSH key 指纹漂移' ;;
    21) die 3 '中转实际协商 host-key 探针不可达' ;;
    22) die 3 '经中转访问出口机失败' ;;
    31) die 3 '中转实际协商 host-key 指纹漂移' ;;
    32) die 3 '出口机实际协商 host-key 指纹漂移' ;;
    *) die 5 '主机/密钥绑定核验异常' ;;
  esac
}

# rotate-keys / add-device / remove-device 的共同流程。$1 = 远端操作（rotate / add:<名字> / remove:<名字>），
# $2 = audit 目录前缀。
exit_op_chain() {
  local op prefix leftover old_uuid old_sha
  op="$1"
  prefix="$2"
  exit_op_prepare
  # 上次中断留下的本机临时文件：与 rollback 侧同一口径，身份正常才删。
  for leftover in "${CHAIN_STATE_DIR}"/.node.txt.rotate.*.tmp "${CHAIN_STATE_DIR}"/devices/.*.tmp; do
    [[ -e "${leftover}" || -L "${leftover}" ]] || continue
    require_secure_user_file "${leftover}" 600 || die 5 "${COMMAND} 本机残留身份异常：${leftover}"
    rm -f "${leftover}" || die 5 "${COMMAND} 本机残留删除失败：${leftover}"
  done
  log_info "[exit-op] start chain=${CHAIN_ID} mode=${op} deployment=${DEPLOYMENT_ID:0:12}"
  old_uuid="${VLESS_UUID}"
  old_sha="${EXIT_EXIT_SHA256}"
  exit_op_apply "${op}"
  if [[ "${EXIT_OP_RESULT}" == resumed-after-commit ]]; then
    # state 已在上一次提交：出口机报告的 default 与配置哈希必须与 state 一致，否则说明现场与记录对不上，不做清理。
    [[ "${VLESS_UUID}" == "${old_uuid}" && "${ROTATE_NEW_EXIT_SHA256}" == "${old_sha}" ]] \
      || die 1 '出口机辅助文件中的参数与已提交的 state 不一致，拒绝清理；请人工核对出口机 /etc/ownexit-chain'
    publish_exit_op_artifacts
    [[ "${NODE_SHA256}" == "$(kv_get "${STATE_FILE}" NODE_SHA256)" ]] || die 1 '重建的 node.txt 与 state 记录不一致'
  else
    publish_exit_op_artifacts
    rotate_test_stop node
    commit_exit_op_state "${prefix}"
    rotate_test_stop state
  fi
  rotate_cleanup_remote
  rotate_test_stop cleanup
  ensure_local_assets_match_state
  full_verify
}

rotate_keys_chain() {
  exit_op_chain rotate rotated
  printf 'rotate=done chain=%s result=%s\n' "${CHAIN_ID}" "${EXIT_OP_RESULT}"
  log_info "[exit-op] 所有客户端需要重新导入 ${CHAIN_STATE_DIR}/client/node.txt 与 devices/ 下的设备节点（多链聚合需重新 render）"
  log_info "rotate-keys 通过；chain=${CHAIN_ID} result=${EXIT_OP_RESULT} elapsed=$(elapsed_seconds)s"
}

device_op_chain() {
  if [[ "${COMMAND}" == add-device ]]; then
    exit_op_chain "add:${DEVICE_NAME}" devices
    printf 'device=added chain=%s name=%s node=%s result=%s\n' "${CHAIN_ID}" "${DEVICE_NAME}" "${CHAIN_STATE_DIR}/devices/node-${DEVICE_NAME}.txt" "${EXIT_OP_RESULT}"
    log_info "add-device 通过；chain=${CHAIN_ID} device=${DEVICE_NAME} elapsed=$(elapsed_seconds)s"
  else
    exit_op_chain "remove:${DEVICE_NAME}" devices
    printf 'device=removed chain=%s name=%s result=%s\n' "${CHAIN_ID}" "${DEVICE_NAME}" "${EXIT_OP_RESULT}"
    log_info "remove-device 通过；chain=${CHAIN_ID} device=${DEVICE_NAME} elapsed=$(elapsed_seconds)s"
  fi
}

# 只读：读出口机生效配置 users 行里的设备名（不读 UUID），与本机节点文件对照。
list_devices_chain() {
  local names name node
  exit_op_prepare
  # name 字段只出现在 users 行；旧形态没有 name，grep 无匹配时远端用 || true 兜住，结果为空即只有 default。
  names="$(ssh_exit "grep -o '\"name\": \"[^\"]*\"' /etc/ownexit-chain/${CHAIN_ID}.exit.json || true")" || die 3 '读取出口机配置失败'
  names="$(printf '%s\n' "${names}" | sed -n 's/^"name": "\(.*\)"$/\1/p')"
  [[ -n "${names}" ]] || names=default
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if [[ "${name}" == default ]]; then
      node="${CHAIN_STATE_DIR}/client/node.txt"
    else
      node="${CHAIN_STATE_DIR}/devices/node-${name}.txt"
    fi
    [[ -f "${node}" ]] || node='missing（运行 rotate-keys 或任一设备命令可重建）'
    printf 'device=%s node=%s\n' "${name}" "${node}"
  done <<< "${names}"
}

# ---------- 出口机跨机迁移：migrate-exit（docs/feature/feature-exit-migration.md） ----------
#
# 用途：把链的出口机换成另一台机器，UUID、Reality 密钥、short id、全部设备、中转地址与端口不变，客户端不重新导入。
# 关键约束：
#   - 不走事务（同 rehost-exit / rotate-keys）：每一步都可重跑，本机 state 最后提交；中间状态放在迁移记录
#     ${CHAIN_STATE_DIR}/migrate-exit.env 里。
#   - 迁移记录里的 PHASE 只作下限参考，实际进度由现场推导（migrate_derive_stage）：配置是新是旧、state 绑定哪份配置、
#     中转 owner / service 指向旧还是新。这样“动作已完成、PHASE 还没写”就崩溃的情况也能正确接续，--abort 不会误拆新链。
#   - 私钥（出口机 exit.json）从旧出口机经本机内存直接写到新出口机：只存在于 bash 变量与管道里，不落本机磁盘，
#     不出现在命令行参数与日志里。
#   - 不调用 deploy 的 prepare_exit_exit / install_exit_exit / activate_exit_exit（它们会写 transaction.env）。

MIGRATE_MODE=''
MIGRATE_TO=''
MIGRATE_TO_PORT=''
MIGRATE_FILE=''
# 推导出的实际阶段：recorded / executing / partial / switched / cleanup（见 migrate_derive_stage）。
MIGRATE_STAGE=''
# 迁移前 state 里的中转 owner / service 哈希。中转切换脚本必须拿它们作“state 值”核对，
# 不能用切换后已被改写成新哈希的全局 RELAY_*_SHA256，否则重跑会把已迁移形态误判为 drift。
MIGRATE_STATE_RELAY_OWNER_SHA256=''
MIGRATE_STATE_RELAY_SERVICE_SHA256=''
MIGRATE_CLEANUP_RESULT=''

# 迁移记录的键，顺序即文件顺序。值为空时写 -（空值在 ssh 参数里会被吞掉，也不便校验）。
migrate_record_keys() {
  cat <<'MIGRATE_KEYS'
SCHEMA_VERSION
CHAIN_ID
PHASE
MIGRATE_ID
OLD_EXIT_HOST
OLD_EXIT_SSH_PORT
OLD_EXIT_SSH_KEY
OLD_EXIT_SSH_KEY_FINGERPRINT
OLD_EXPECTED_EXIT_IPV4
OLD_EXIT_HOSTKEY_FINGERPRINT
OLD_EXIT_REALITY_PORT
OLD_EXIT_OWNER_SHA256
OLD_EXIT_EXIT_SHA256
OLD_EXIT_SERVICE_SHA256
OLD_CONFIG_SHA256
NEW_EXIT_HOST
NEW_EXIT_SSH_PORT
NEW_EXIT_SSH_KEY
NEW_EXIT_SSH_KEY_FINGERPRINT
NEW_EXPECTED_EXIT_IPV4
NEW_EXIT_HOSTKEY_FINGERPRINT
NEW_CONFIG_SHA256
CONFIG_BACKUP
NEW_EXIT_REALITY_PORT
OLD_RELAY_TARGET
NEW_RELAY_TARGET
BINARY_STAGE_PATH
BINARY_STAGE_OWNER_SHA256
BINARY_STAGE_OWNER_TEMP_PATH
CONFIG_STAGE_PATH
CONFIG_STAGE_OWNER_SHA256
CONFIG_STAGE_OWNER_TEMP_PATH
NEW_EXIT_OWNER_SHA256
NEW_EXIT_EXIT_SHA256
NEW_EXIT_SERVICE_SHA256
MIGRATE_KEYS
}
# 加载时把全部记录变量置空：首次迁移（还没有记录）时这些变量要在准备阶段逐个赋值，
# set -u 下提前读到未赋值的变量会直接退出（例如 migrate_use_exit new 时新端口、新哈希都还没有）。
while IFS= read -r migrate_key; do
  eval "MIGRATE_${migrate_key}=''"
done < <(migrate_record_keys)
unset migrate_key

# 测试钩子：在指定步骤后以退出码 99 结束，用于中断恢复用例；正常使用不要设置。
migrate_test_stop() {
  if [[ "${OWNEXIT_TEST_MIGRATE_STOP_AFTER:-}" == "$1" ]]; then
    log_warn "测试钩子：migrate-exit 在 $1 之后停止"
    exit 99
  fi
}

# 迁移记录存在时拒绝其它修改类命令：它们按 state 或配置单方面操作出口机，会和迁移的中间状态互相踩踏。
# 退出码由 die 按命令映射（rollback 为 6，deploy 为 4），其余为 5。
migrate_gate() {
  [[ -e "${CHAIN_STATE_DIR}/migrate-exit.env" || -L "${CHAIN_STATE_DIR}/migrate-exit.env" ]] || return 0
  die 5 "链 ${CHAIN_ID} 正在迁移出口机，先重跑 migrate-exit（或 --abort / --abandon-cleanup）"
}

# 写迁移记录：同目录临时文件 + mv 原子替换，读者只会看到完整的旧记录或完整的新记录。
migrate_write_record() {
  local tmp key value
  ensure_private_dir "${CHAIN_STATE_DIR}" || die 1 'chain state 目录身份或权限不安全'
  tmp="${CHAIN_STATE_DIR}/.migrate-exit.env.${LOCK_OPERATION_ID}.tmp"
  ( set -o noclobber; : > "${tmp}" ) 2>/dev/null || die 1 '迁移记录临时文件碰撞'
  chmod 600 "${tmp}" || die 1 '迁移记录临时文件权限设置失败'
  while IFS= read -r key; do
    case "${key}" in
      SCHEMA_VERSION) value=1 ;;
      CHAIN_ID) value="${CHAIN_ID}" ;;
      *) eval "value=\"\${MIGRATE_${key}:-}\"" ;;
    esac
    [[ -n "${value}" ]] || value='-'
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}" || die 1 '迁移记录写入失败'
  done < <(migrate_record_keys)
  sync || die 1 '迁移记录持久化失败'
  mv -f "${tmp}" "${MIGRATE_FILE}" || die 1 '迁移记录原子替换失败'
  sync || die 1 '迁移记录持久化失败'
}

# 读迁移记录到 MIGRATE_<键>；格式不对就拒绝（记录是迁移中唯一的新出口机参数来源，猜测会拆错机器）。
migrate_load_record() {
  local expected actual key value
  require_secure_user_file "${MIGRATE_FILE}" 600 || die 5 "迁移记录身份或权限异常：${MIGRATE_FILE}"
  expected="$(migrate_record_keys)"
  actual="$(awk -F= 'NF >= 2 {print $1}' "${MIGRATE_FILE}")"
  [[ "${actual}" == "${expected}" ]] || die 5 "迁移记录键不完整或顺序不符：${MIGRATE_FILE}"
  [[ -z "$(grep -nEv '^[A-Z][A-Z0-9_]*=[A-Za-z0-9._/@+,=:~-]+$' "${MIGRATE_FILE}" || true)" ]] || die 5 "迁移记录含非法字符：${MIGRATE_FILE}"
  [[ "$(kv_get "${MIGRATE_FILE}" SCHEMA_VERSION)" == 1 ]] || die 5 '迁移记录 SCHEMA_VERSION 不认识'
  [[ "$(kv_get "${MIGRATE_FILE}" CHAIN_ID)" == "${CHAIN_ID}" ]] || die 5 '迁移记录不属于本链'
  while IFS= read -r key; do
    case "${key}" in SCHEMA_VERSION|CHAIN_ID) continue ;; esac
    value="$(kv_get "${MIGRATE_FILE}" "${key}")"
    [[ "${value}" != - ]] || value=''
    eval "MIGRATE_${key}=\"\${value}\""
  done < <(migrate_record_keys)
  [[ "${MIGRATE_PHASE}" =~ ^(recorded|config-rewritten|relay-switched|committed)$ ]] || die 5 "迁移记录 PHASE 不认识：${MIGRATE_PHASE}"
  [[ "${MIGRATE_MIGRATE_ID}" =~ ^[0-9a-f]{32}$ ]] || die 5 '迁移记录 MIGRATE_ID 格式错误'
  is_ipv4 "${MIGRATE_OLD_EXIT_HOST}" && is_ipv4 "${MIGRATE_NEW_EXIT_HOST}" || die 5 '迁移记录中的出口机地址不是 IPv4'
  is_ipv4 "${MIGRATE_OLD_EXPECTED_EXIT_IPV4}" && is_ipv4 "${MIGRATE_NEW_EXPECTED_EXIT_IPV4}" || die 5 '迁移记录中的出口 IP 不是 IPv4'
  for value in "${MIGRATE_OLD_CONFIG_SHA256}" "${MIGRATE_NEW_CONFIG_SHA256}" "${MIGRATE_OLD_EXIT_OWNER_SHA256}" "${MIGRATE_OLD_EXIT_EXIT_SHA256}" "${MIGRATE_OLD_EXIT_SERVICE_SHA256}"; do
    [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || die 5 '迁移记录中的旧哈希格式错误'
  done
  [[ "${MIGRATE_OLD_EXIT_HOSTKEY_FINGERPRINT}" == SHA256:* && "${MIGRATE_NEW_EXIT_HOSTKEY_FINGERPRINT}" == SHA256:* ]] || die 5 '迁移记录中的主机指纹格式错误'
  [[ "${MIGRATE_OLD_EXIT_SSH_KEY_FINGERPRINT}" == SHA256:* && "${MIGRATE_NEW_EXIT_SSH_KEY_FINGERPRINT}" == SHA256:* ]] || die 5 '迁移记录中的密钥指纹格式错误'
}

# 把出口机相关全局变量切到旧机或新机，然后重渲染 SSH 配置；之后 ssh_exit / ssh_exit_stdin 就指向这台机器（经中转机转接）。
# 必须直接在当前 shell 调用（不能放进 $( ) 子 shell），否则变量切换不会生效。
migrate_use_exit() {
  if [[ "$1" == old ]]; then
    EXIT_HOST="${MIGRATE_OLD_EXIT_HOST}"
    EXIT_SSH_PORT="${MIGRATE_OLD_EXIT_SSH_PORT}"
    EXIT_SSH_KEY="${MIGRATE_OLD_EXIT_SSH_KEY}"
    EXIT_SSH_KEY_FINGERPRINT="${MIGRATE_OLD_EXIT_SSH_KEY_FINGERPRINT}"
    EXIT_HOSTKEY_FINGERPRINT="${MIGRATE_OLD_EXIT_HOSTKEY_FINGERPRINT}"
    EXPECTED_EXIT_IPV4="${MIGRATE_OLD_EXPECTED_EXIT_IPV4}"
    EXIT_REALITY_PORT="${MIGRATE_OLD_EXIT_REALITY_PORT}"
    EXIT_OWNER_SHA256="${MIGRATE_OLD_EXIT_OWNER_SHA256}"
    EXIT_EXIT_SHA256="${MIGRATE_OLD_EXIT_EXIT_SHA256}"
    EXIT_SERVICE_SHA256="${MIGRATE_OLD_EXIT_SERVICE_SHA256}"
  else
    EXIT_HOST="${MIGRATE_NEW_EXIT_HOST}"
    EXIT_SSH_PORT="${MIGRATE_NEW_EXIT_SSH_PORT}"
    EXIT_SSH_KEY="${MIGRATE_NEW_EXIT_SSH_KEY}"
    EXIT_SSH_KEY_FINGERPRINT="${MIGRATE_NEW_EXIT_SSH_KEY_FINGERPRINT}"
    EXIT_HOSTKEY_FINGERPRINT="${MIGRATE_NEW_EXIT_HOSTKEY_FINGERPRINT}"
    EXPECTED_EXIT_IPV4="${MIGRATE_NEW_EXPECTED_EXIT_IPV4}"
    EXIT_REALITY_PORT="${MIGRATE_NEW_EXIT_REALITY_PORT}"
    EXIT_OWNER_SHA256="${MIGRATE_NEW_EXIT_OWNER_SHA256}"
    EXIT_EXIT_SHA256="${MIGRATE_NEW_EXIT_EXIT_SHA256}"
    EXIT_SERVICE_SHA256="${MIGRATE_NEW_EXIT_SERVICE_SHA256}"
  fi
  # EXIT_ENABLE_LINK_TARGET 只由 CHAIN_ID 决定，迁移前后相同，不需要切换。
  render_ssh_config
  log_info "[migrate] exit context=$1 host=${EXIT_HOST}"
}

# 中转与当前上下文出口机的身份核验：私钥指纹、实际协商的主机指纹都必须等于期望值。
migrate_check_binding() {
  local fingerprint
  [[ "$(fingerprint_private_key "${RELAY_SSH_KEY}")" == "${RELAY_SSH_KEY_FINGERPRINT}" ]] || die 5 '中转 SSH key 指纹漂移'
  [[ "$(fingerprint_private_key "${EXIT_SSH_KEY}")" == "${EXIT_SSH_KEY_FINGERPRINT}" ]] || die 5 "出口机 ${EXIT_HOST} 的 SSH key 指纹与迁移记录不符"
  fingerprint="$(negotiated_hostkey_fingerprint chain-relay)" || die 3 '中转实际协商 host-key 探针不可达'
  [[ "${fingerprint}" == "${RELAY_HOSTKEY_FINGERPRINT}" ]] || die 3 '中转实际协商 host-key 指纹漂移'
  fingerprint="$(negotiated_hostkey_fingerprint chain-exit)" || die 3 "经中转访问出口机 ${EXIT_HOST} 失败"
  [[ "${fingerprint}" == "${EXIT_HOSTKEY_FINGERPRINT}" ]] || die 3 "出口机 ${EXIT_HOST} 的主机指纹与迁移记录不符"
}

# 当前配置的四个出口键属于迁移前（old）、迁移后（new）还是都不是（other）。
migrate_config_side() {
  if [[ "${EXIT_HOST}" == "${MIGRATE_NEW_EXIT_HOST}" && "${EXIT_SSH_PORT}" == "${MIGRATE_NEW_EXIT_SSH_PORT}" && "${EXIT_SSH_KEY}" == "${MIGRATE_NEW_EXIT_SSH_KEY}" && "${EXPECTED_EXIT_IPV4}" == "${MIGRATE_NEW_EXPECTED_EXIT_IPV4}" ]]; then
    printf 'new'
  elif [[ "${EXIT_HOST}" == "${MIGRATE_OLD_EXIT_HOST}" && "${EXIT_SSH_PORT}" == "${MIGRATE_OLD_EXIT_SSH_PORT}" && "${EXIT_SSH_KEY}" == "${MIGRATE_OLD_EXIT_SSH_KEY}" && "${EXPECTED_EXIT_IPV4}" == "${MIGRATE_OLD_EXPECTED_EXIT_IPV4}" ]]; then
    printf 'old'
  else
    printf 'other'
  fi
}

# 中转现场只读检查：owner 与 service 分别是 state 值（state）、已迁移形态（new）还是外部改动（drift）。
# 与 rehost 远端脚本同一套整行匹配 / ExecStart 后缀匹配，但只读不写。rehost 脚本先改 owner 再改 service，
# 所以合法组合只有 state:state、new:state、new:new 三种。
write_migrate_relay_probe_script() {
  local output
  output="$1"
  cat > "${output}" <<'MIGRATE_RELAY_PROBE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
chain_id="$1"
owner_state_hash="$2"
old_cfg="$3"
new_cfg="$4"
service_state_hash="$5"
old_target="$6"
new_target="$7"
owner="/etc/ownexit-chain/$chain_id.owner.env"
service="/etc/systemd/system/ownexit-chain-relay-$chain_id.service"
sha() { sha256sum "$1" | awk '{print $1}'; }
replace_owner() { awk -v from="$2" -v to="$3" '{ if ($0 == from) print to; else print }' "$1"; }
replace_service() {
  awk -v sfx=" $2" -v to=" $3" '{
    if (index($0, "ExecStart=") == 1 && length($0) > length(sfx) && substr($0, length($0) - length(sfx) + 1) == sfx)
      print substr($0, 1, length($0) - length(sfx)) to
    else
      print
  }' "$1"
}
side() {
  local file mode state_hash kind
  file="$1"; mode="$2"; state_hash="$3"; kind="$4"
  if [[ ! -f "$file" || -L "$file" || "$(stat -c %u:%g:%a "$file")" != "0:0:$mode" ]]; then
    printf 'drift'
  elif [[ "$(sha "$file")" == "$state_hash" ]]; then
    printf 'state'
  elif [[ "$kind" == owner && "$(replace_owner "$file" "CONFIG_SHA256=$new_cfg" "CONFIG_SHA256=$old_cfg" | sha256sum | awk '{print $1}')" == "$state_hash" ]]; then
    printf 'new'
  elif [[ "$kind" == service && "$(replace_service "$file" "$new_target" "$old_target" | sha256sum | awk '{print $1}')" == "$state_hash" ]]; then
    printf 'new'
  else
    printf 'drift'
  fi
}
o="$(side "$owner" 600 "$owner_state_hash" owner)"
s="$(side "$service" 644 "$service_state_hash" service)"
case "$o:$s" in
  state:state) printf 'RELAY=none\n' ;;
  new:state) printf 'RELAY=partial\n' ;;
  new:new) printf 'RELAY=switched\n' ;;
  *) printf 'RELAY=drift owner=%s service=%s\n' "$o" "$s" ;;
esac
MIGRATE_RELAY_PROBE
  chmod 600 "${output}"
}

migrate_relay_status() {
  local script output
  if [[ -z "${MIGRATE_NEW_RELAY_TARGET}" ]]; then
    # 新端口还没选定时中转切换不可能开始。
    printf 'none'
    return 0
  fi
  script="${OP_TMP}/migrate-relay-probe.sh"
  write_migrate_relay_probe_script "${script}"
  output="$(ssh_relay_stdin bash -s -- "${CHAIN_ID}" "${MIGRATE_STATE_RELAY_OWNER_SHA256}" "${MIGRATE_OLD_CONFIG_SHA256}" "${MIGRATE_NEW_CONFIG_SHA256}" "${MIGRATE_STATE_RELAY_SERVICE_SHA256}" "${MIGRATE_OLD_RELAY_TARGET}" "${MIGRATE_NEW_RELAY_TARGET}" < "${script}")" || die 3 '中转现场检查失败（SSH 不可达或远端脚本异常）'
  output="$(printf '%s\n' "${output}" | awk '$1 ~ /^RELAY=/ {sub(/^RELAY=/, ""); print; exit}')"
  [[ -n "${output}" ]] || die 3 '中转现场检查输出格式异常'
  printf '%s' "${output}"
}

# 由现场推导实际阶段，结果写入 MIGRATE_STAGE。返回时：state 字段已按它绑定的那份配置加载进全局变量，
# CONFIG_SHA256 与四个出口键是配置文件里的当前值。
migrate_derive_stage() {
  local side rc relay saved_host saved_port saved_key saved_exit
  side="$(migrate_config_side)"
  case "${side}" in
    other) die 2 "配置里的出口机参数既不是迁移前也不是迁移后的值；请人工核对 ${CONFIG_PATH} 与 ${MIGRATE_CONFIG_BACKUP:-（无备份）}" ;;
    old)
      if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
      [[ "${rc}" -eq 0 ]] || die 2 "配置为迁移前的值，但 state 与它不一致（${STATE_PROBE_REASON}）；请人工核对"
      MIGRATE_STAGE=recorded
      return 0
      ;;
  esac
  if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
  if [[ "${rc}" -eq 0 ]]; then
    MIGRATE_STAGE=cleanup
    return 0
  fi
  [[ "${rc}" -eq 12 ]] || die 5 "state.env 校验失败：${STATE_PROBE_REASON}"
  # 临时换回迁移前的四个键重算摘要再核 state；其余 9 个键与校验和仍按原逻辑逐项核验，豁免范围不会被放宽。
  saved_host="${EXIT_HOST}"; saved_port="${EXIT_SSH_PORT}"; saved_key="${EXIT_SSH_KEY}"; saved_exit="${EXPECTED_EXIT_IPV4}"
  EXIT_HOST="${MIGRATE_OLD_EXIT_HOST}"; EXIT_SSH_PORT="${MIGRATE_OLD_EXIT_SSH_PORT}"; EXIT_SSH_KEY="${MIGRATE_OLD_EXIT_SSH_KEY}"; EXPECTED_EXIT_IPV4="${MIGRATE_OLD_EXPECTED_EXIT_IPV4}"
  CONFIG_SHA256="$(normalized_config | sha256_text)"
  if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
  EXIT_HOST="${saved_host}"; EXIT_SSH_PORT="${saved_port}"; EXIT_SSH_KEY="${saved_key}"; EXPECTED_EXIT_IPV4="${saved_exit}"
  CONFIG_SHA256="$(normalized_config | sha256_text)"
  [[ "${rc}" -eq 0 ]] || die 2 'state 既不绑定当前配置也不绑定迁移前的配置；请人工核对配置与 state'
  [[ "${CONFIG_SHA256}" == "${MIGRATE_NEW_CONFIG_SHA256}" ]] || die 2 '当前配置摘要与迁移记录不符；除四个出口键外配置还被改过'
  MIGRATE_STATE_RELAY_OWNER_SHA256="${RELAY_OWNER_SHA256}"
  MIGRATE_STATE_RELAY_SERVICE_SHA256="${RELAY_SERVICE_SHA256}"
  migrate_use_exit new
  relay="$(migrate_relay_status)"
  case "${relay}" in
    none) MIGRATE_STAGE=executing ;;
    partial) MIGRATE_STAGE=partial ;;
    switched) MIGRATE_STAGE=switched ;;
    *) die 1 "中转上本链的 owner / service 被外部改动（${relay}），迁移不再继续；请人工核对中转 /etc/ownexit-chain 与 relay service" ;;
  esac
}

# 改写配置文件中的四个出口键（各恰好 1 行，其余字节不变）；改写前备份到同目录 <文件名>.bak.<时间>。
migrate_rewrite_config() {
  local tmp key value count
  if [[ -z "${MIGRATE_CONFIG_BACKUP}" ]]; then
    MIGRATE_CONFIG_BACKUP="${CONFIG_PATH}.bak.$(date '+%Y%m%d_%H%M%S')"
    [[ ! -e "${MIGRATE_CONFIG_BACKUP}" && ! -L "${MIGRATE_CONFIG_BACKUP}" ]] || die 1 "配置备份路径碰撞：${MIGRATE_CONFIG_BACKUP}"
    ( set -o noclobber; cat "${CONFIG_PATH}" > "${MIGRATE_CONFIG_BACKUP}" ) || die 1 '配置备份失败'
    chmod 600 "${MIGRATE_CONFIG_BACKUP}" || die 1 '配置备份权限设置失败'
    migrate_write_record
  fi
  require_secure_user_file "${MIGRATE_CONFIG_BACKUP}" 600 || die 1 "配置备份身份或权限异常：${MIGRATE_CONFIG_BACKUP}"
  for key in EXIT_HOST EXIT_SSH_PORT EXIT_SSH_KEY EXPECTED_EXIT_IPV4; do
    count="$(awk -v k="${key}=" 'index($0, k) == 1 {n++} END {print n + 0}' "${CONFIG_PATH}")"
    [[ "${count}" == 1 ]] || die 2 "配置文件中 ${key}= 不是恰好 1 行：${CONFIG_PATH}"
  done
  tmp="$(dirname "${CONFIG_PATH}")/.$(basename "${CONFIG_PATH}").migrate.$$.tmp"
  awk -v h="EXIT_HOST=${MIGRATE_NEW_EXIT_HOST}" -v p="EXIT_SSH_PORT=${MIGRATE_NEW_EXIT_SSH_PORT}" \
      -v k="EXIT_SSH_KEY=${MIGRATE_NEW_EXIT_SSH_KEY}" -v e="EXPECTED_EXIT_IPV4=${MIGRATE_NEW_EXPECTED_EXIT_IPV4}" '{
    if (index($0, "EXIT_HOST=") == 1) print h
    else if (index($0, "EXIT_SSH_PORT=") == 1) print p
    else if (index($0, "EXIT_SSH_KEY=") == 1) print k
    else if (index($0, "EXPECTED_EXIT_IPV4=") == 1) print e
    else print
  }' "${CONFIG_PATH}" > "${tmp}" || die 1 '配置改写失败'
  chmod 600 "${tmp}" || die 1 '配置临时文件权限设置失败'
  mv -f "${tmp}" "${CONFIG_PATH}" || die 1 '配置原子替换失败'
  EXIT_HOST="${MIGRATE_NEW_EXIT_HOST}"
  EXIT_SSH_PORT="${MIGRATE_NEW_EXIT_SSH_PORT}"
  EXIT_SSH_KEY="${MIGRATE_NEW_EXIT_SSH_KEY}"
  EXPECTED_EXIT_IPV4="${MIGRATE_NEW_EXPECTED_EXIT_IPV4}"
  value="$(normalized_config | sha256_text)"
  [[ "${value}" == "${MIGRATE_NEW_CONFIG_SHA256}" ]] || die 1 '改写后的配置摘要与迁移记录不符'
  CONFIG_SHA256="${value}"
  MIGRATE_PHASE='config-rewritten'
  migrate_write_record
  log_info "[migrate] config rewritten backup=${MIGRATE_CONFIG_BACKUP}"
}

# 给新出口机配免密并登记 ed25519 主机指纹（与 init_setup_host 同一套做法，报错文字指向本命令而不是 init）。
migrate_setup_new_host() {
  local key rc
  key="$(init_key_path "${MIGRATE_TO}" "${MIGRATE_TO_PORT}")"
  log_info "[migrate] 新出口机 ${MIGRATE_TO}:${MIGRATE_TO_PORT} 配置免密"
  rc=0
  # connect_to.sh 的进度行写在 stdout；转到 stderr，stdout 只留 migrate= 这一行机器可读输出。
  bash "${SCRIPT_DIR}/../direct/connect_to.sh" --setup-only --host "${MIGRATE_TO}" --port "${MIGRATE_TO_PORT}" --user root >&2 || rc="$?"
  [[ "${rc}" -eq 0 ]] || die 3 "新出口机 ${MIGRATE_TO}:${MIGRATE_TO_PORT} 配置免密失败（原因见上方 reason=...）；配置与 state 未改动"
  if ! init_probe_ed25519 "${key}" "${MIGRATE_TO}" "${MIGRATE_TO_PORT}"; then
    init_record_ed25519_hostkey "${key}" "${MIGRATE_TO}" "${MIGRATE_TO_PORT}" \
      || die 3 "新出口机 ${MIGRATE_TO}:${MIGRATE_TO_PORT} 无法取得 ed25519 host key（chain 只接受 ed25519）"
    init_probe_ed25519 "${key}" "${MIGRATE_TO}" "${MIGRATE_TO_PORT}" \
      || die 3 "新出口机 ${MIGRATE_TO}:${MIGRATE_TO_PORT} 补记 ed25519 host key 后仍无法用 ed25519 登录"
  fi
  require_private_key_file "${key}" || die 3 "新出口机私钥身份或权限异常：${key}"
  MIGRATE_NEW_EXIT_SSH_KEY="${key}"
  MIGRATE_NEW_EXIT_SSH_KEY_FINGERPRINT="$(fingerprint_private_key "${key}")" || die 3 '无法读取新出口机私钥指纹'
  [[ "${MIGRATE_NEW_EXIT_SSH_KEY_FINGERPRINT}" == SHA256:* ]] || die 3 '新出口机私钥指纹格式错误'
  [[ "${MIGRATE_NEW_EXIT_SSH_KEY_FINGERPRINT}" != "${RELAY_SSH_KEY_FINGERPRINT}" ]] || die 2 '新出口机与中转使用了同一把私钥；chain 要求两把不同的私钥'
}

# 准备阶段（没有迁移记录时）：核旧链健康、探新机器，写迁移记录并改写配置。远端不做任何修改。
migrate_prepare() {
  local rc new_fp exit_ip answer path
  if probe_state_file "${STATE_FILE}"; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    12) die 2 '配置与 state 不一致；migrate-exit 要求配置未改动（出口机参数由本命令自己改写）' ;;
    *) die 5 "state.env 校验失败：${STATE_PROBE_REASON}" ;;
  esac
  is_ipv4 "${MIGRATE_TO}" || die 2 "--to 必须是 IPv4：${MIGRATE_TO}"
  [[ "${MIGRATE_TO}" != "${RELAY_HOST}" ]] || die 2 '--to 不能是中转机'
  [[ "${MIGRATE_TO}" != "${EXIT_HOST}" ]] || die 2 '--to 就是当前出口机；同一台机器换 IP 用 rehost-exit'
  # 旧链健康核验，顺序与 rollback 前置一致；同时让 remote_platform_preflight 给 SOCKET_PROXYD_PATH 赋值。
  render_ssh_config
  if probe_loaded_binding; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    11) die 5 '中转 SSH key 指纹漂移' ;;
    12) die 5 '出口机 SSH key 指纹漂移' ;;
    21) die 3 '中转实际协商 host-key 探针不可达' ;;
    22) die 3 '经中转访问旧出口机失败；旧出口机已经登录不了时不能迁移（私钥只在旧机器上），改用 rollback + deploy' ;;
    31) die 3 '中转实际协商 host-key 指纹漂移' ;;
    32) die 3 '旧出口机实际协商 host-key 指纹漂移' ;;
    *) die 5 '主机/密钥绑定核验异常' ;;
  esac
  remote_platform_preflight
  if probe_remote_resources no; then rc=0; else rc="$?"; fi
  [[ "${rc}" -ne 33 ]] || die 5 '旧出口机上有未完成的凭据或设备操作（辅助文件未清理）；先重跑中断的那条命令（rotate-keys / add-device / remove-device）收敛'
  [[ "${rc}" -eq 0 ]] || die 5 '旧链远端资源不健康；先运行 verify 查明并收敛'
  MIGRATE_MIGRATE_ID="$(random_hex_128)"
  MIGRATE_OLD_EXIT_HOST="${EXIT_HOST}"
  MIGRATE_OLD_EXIT_SSH_PORT="${EXIT_SSH_PORT}"
  MIGRATE_OLD_EXIT_SSH_KEY="${EXIT_SSH_KEY}"
  MIGRATE_OLD_EXIT_SSH_KEY_FINGERPRINT="${EXIT_SSH_KEY_FINGERPRINT}"
  MIGRATE_OLD_EXPECTED_EXIT_IPV4="${EXPECTED_EXIT_IPV4}"
  MIGRATE_OLD_EXIT_HOSTKEY_FINGERPRINT="${EXIT_HOSTKEY_FINGERPRINT}"
  MIGRATE_OLD_EXIT_REALITY_PORT="${EXIT_REALITY_PORT}"
  MIGRATE_OLD_EXIT_OWNER_SHA256="${EXIT_OWNER_SHA256}"
  MIGRATE_OLD_EXIT_EXIT_SHA256="${EXIT_EXIT_SHA256}"
  MIGRATE_OLD_EXIT_SERVICE_SHA256="${EXIT_SERVICE_SHA256}"
  MIGRATE_OLD_CONFIG_SHA256="${CONFIG_SHA256}"
  MIGRATE_OLD_RELAY_TARGET="${EXIT_HOST}:${EXIT_REALITY_PORT}"
  MIGRATE_NEW_EXIT_HOST="${MIGRATE_TO}"
  MIGRATE_NEW_EXIT_SSH_PORT="${MIGRATE_TO_PORT}"
  migrate_setup_new_host
  # 新机器指纹经中转取得：同时证明中转到新机器的 SSH 可达（迁移后的所有管理都走这条路）。
  migrate_use_exit new
  new_fp="$(negotiated_hostkey_fingerprint chain-exit)" || die 3 "经中转访问新出口机 ${MIGRATE_TO}:${MIGRATE_TO_PORT} 失败；确认中转到新机器的 SSH 可达"
  [[ "${new_fp}" != "${MIGRATE_OLD_EXIT_HOSTKEY_FINGERPRINT}" ]] || die 2 "新出口机 ${MIGRATE_TO} 的主机指纹与当前出口机相同：是同一台机器，换 IP 用 rehost-exit"
  MIGRATE_NEW_EXIT_HOSTKEY_FINGERPRINT="${new_fp}"
  EXIT_HOSTKEY_FINGERPRINT="${new_fp}"
  remote_platform_preflight
  check_remote_shared_binary_or_absent exit || die 3 '新出口机共享 binary / 目录与固定版本不一致'
  for path in "${REMOTE_CONFIG_DIR}/${CHAIN_ID}.owner.env" "${REMOTE_CONFIG_DIR}/${CHAIN_ID}.exit.json" \
    "/etc/systemd/system/ownexit-chain-exit-${CHAIN_ID}.service" \
    "/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-${CHAIN_ID}.service"; do
    require_remote_path_absent exit "${path}" "新出口机上已有本链的文件：${path}；配置未改动"
  done
  require_remote_unit_absent exit "ownexit-chain-exit-${CHAIN_ID}.service" "新出口机上已有本链的 unit；配置未改动"
  # 出口 IP 是 verify 的唯一允许值：在新机器上直接问 ipinfo.io，终端里要人确认。
  exit_ip="$(ssh_exit 'curl -4 -fsS -m 15 ipinfo.io/ip' 2>/dev/null | tr -d '[:space:]' || true)"
  is_ipv4 "${exit_ip}" || die 3 "无法在新出口机上取得公网 IPv4（需要 curl 能访问 ipinfo.io）；读到：${exit_ip:-空}"
  log_info "[migrate] 新出口机公网 IP：${exit_ip}"
  if [[ -t 0 ]]; then
    read -r -p "确认迁移后客户端经这条链出去的 IP 应当是 ${exit_ip}？[y/N] " answer
    [[ "${answer}" == y || "${answer}" == Y ]] || die 2 '未确认出口 IP，配置与 state 未改动'
  fi
  MIGRATE_NEW_EXPECTED_EXIT_IPV4="${exit_ip}"
  # 新配置摘要：四个出口键换成新值，其余与 parse_config 同一算法。
  EXIT_HOST="${MIGRATE_OLD_EXIT_HOST}"; EXIT_SSH_PORT="${MIGRATE_OLD_EXIT_SSH_PORT}"; EXIT_SSH_KEY="${MIGRATE_OLD_EXIT_SSH_KEY}"; EXPECTED_EXIT_IPV4="${MIGRATE_OLD_EXPECTED_EXIT_IPV4}"
  (
    EXIT_HOST="${MIGRATE_NEW_EXIT_HOST}"; EXIT_SSH_PORT="${MIGRATE_NEW_EXIT_SSH_PORT}"; EXIT_SSH_KEY="${MIGRATE_NEW_EXIT_SSH_KEY}"; EXPECTED_EXIT_IPV4="${MIGRATE_NEW_EXPECTED_EXIT_IPV4}"
    normalized_config | sha256_text
  ) > "${OP_TMP}/migrate-new-config-sha256" || die 1 '新配置摘要计算失败'
  MIGRATE_NEW_CONFIG_SHA256="$(cat "${OP_TMP}/migrate-new-config-sha256")"
  MIGRATE_BINARY_STAGE_PATH="${REMOTE_BASE}/.stage-binary-${MIGRATE_MIGRATE_ID}"
  MIGRATE_BINARY_STAGE_OWNER_TEMP_PATH="${REMOTE_BASE}/.owner-exit-binary-${MIGRATE_MIGRATE_ID}"
  MIGRATE_CONFIG_STAGE_PATH="${REMOTE_CONFIG_DIR}/.stage-exit-${MIGRATE_MIGRATE_ID}"
  MIGRATE_CONFIG_STAGE_OWNER_TEMP_PATH="${REMOTE_CONFIG_DIR}/.owner-exit-${MIGRATE_MIGRATE_ID}"
  MIGRATE_PHASE=recorded
  migrate_write_record
  log_info "[migrate] phase=prepare recorded chain=${CHAIN_ID} old=${MIGRATE_OLD_EXIT_HOST} new=${MIGRATE_NEW_EXIT_HOST} new_exit_ip=${MIGRATE_NEW_EXPECTED_EXIT_IPV4}"
  migrate_test_stop record
  migrate_rewrite_config
  migrate_test_stop config
}

# 清掉一个暂存（目录存在才核 stage-owner 后删除）与它的 owner 临时文件；kind=BINARY|CONFIG。
migrate_cleanup_stage() {
  local kind path hash temp rc
  kind="$1"
  eval "path=\"\${MIGRATE_${kind}_STAGE_PATH}\"; hash=\"\${MIGRATE_${kind}_STAGE_OWNER_SHA256:-ABSENT}\"; temp=\"\${MIGRATE_${kind}_STAGE_OWNER_TEMP_PATH}\""
  [[ -n "${hash}" ]] || hash=ABSENT
  if cleanup_remote_residue exit "${path}" "${hash}" "${temp}"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -ne 255 ]] || die 3 "新出口机暂存清理时 SSH 不可达：${path}"
  [[ "${rc}" -eq 0 ]] || die 1 "新出口机暂存清理失败（rc=${rc}）：${path}；请人工核对"
}

migrate_install_binary() {
  local owner_file
  migrate_cleanup_stage BINARY
  owner_file="${OP_TMP}/migrate-binary-owner.env"
  render_owner_file "${owner_file}" exit-binary-stage "${MIGRATE_NEW_EXIT_HOSTKEY_FINGERPRINT}"
  # 哈希先入记录再建暂存：建到一半中断时，下一次进程才有删除授权。
  MIGRATE_BINARY_STAGE_OWNER_SHA256="$(sha256_file "${owner_file}")"
  migrate_write_record
  install_remote_binary exit "${MIGRATE_BINARY_STAGE_PATH}" "${MIGRATE_BINARY_STAGE_OWNER_SHA256}" "${owner_file}" "${MIGRATE_BINARY_STAGE_OWNER_TEMP_PATH}"
  cleanup_remote_stage exit "${MIGRATE_BINARY_STAGE_PATH}" "${MIGRATE_BINARY_STAGE_OWNER_SHA256}" || die 1 '新出口机 binary 暂存清理失败'
  MIGRATE_BINARY_STAGE_OWNER_SHA256=''
  migrate_write_record
  log_info '[migrate] binary done'
  migrate_test_stop binary
}

# 新出口机上本链文件的发布情况：none（都不存在）/ partial（部分存在且哈希都对）/ full（全部存在且哈希都对）；
# 任一存在的文件身份或哈希不符（或记录里还没有哈希）退出 61。
write_migrate_published_script() {
  local output
  output="$1"
  cat > "${output}" <<'MIGRATE_PUBLISHED'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
chain_id="$1"
owner_hash="$2"
config_hash="$3"
unit_hash="$4"
link_target="$5"
present=0
check() {
  local path mode hash
  path="$1"; mode="$2"; hash="$3"
  [[ -e "$path" || -L "$path" ]] || return 0
  present=$((present + 1))
  [[ "$hash" != - && -f "$path" && ! -L "$path" && "$(stat -c %u:%g:%a "$path")" == "0:0:$mode" ]] || exit 61
  [[ "$(sha256sum "$path" | awk '{print $1}')" == "$hash" ]] || exit 61
}
check "/etc/ownexit-chain/$chain_id.owner.env" 600 "$owner_hash"
check "/etc/ownexit-chain/$chain_id.exit.json" 600 "$config_hash"
check "/etc/systemd/system/ownexit-chain-exit-$chain_id.service" 644 "$unit_hash"
link="/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-$chain_id.service"
if [[ -e "$link" || -L "$link" ]]; then
  present=$((present + 1))
  [[ -L "$link" && "$(readlink "$link")" == "$link_target" ]] || exit 61
fi
case "$present" in
  0) printf 'PUBLISHED=none\n' ;;
  4) printf 'PUBLISHED=full\n' ;;
  *) printf 'PUBLISHED=partial\n' ;;
esac
MIGRATE_PUBLISHED
  chmod 600 "${output}"
}

migrate_published_state() {
  local script output rc
  script="${OP_TMP}/migrate-published.sh"
  write_migrate_published_script "${script}"
  if output="$(ssh_exit_stdin bash -s -- "${CHAIN_ID}" "${MIGRATE_NEW_EXIT_OWNER_SHA256:--}" "${MIGRATE_NEW_EXIT_EXIT_SHA256:--}" "${MIGRATE_NEW_EXIT_SERVICE_SHA256:--}" "${EXIT_ENABLE_LINK_TARGET}" < "${script}")"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -ne 255 ]] || die 3 '检查新出口机发布情况时 SSH 不可达'
  [[ "${rc}" -ne 61 ]] || die 1 '新出口机上本链的文件与迁移记录不符（外部改动），不覆盖；请人工核对新出口机 /etc/ownexit-chain'
  [[ "${rc}" -eq 0 ]] || die 1 "检查新出口机发布情况失败（rc=${rc}）"
  output="$(printf '%s\n' "${output}" | awk -F= '$1 == "PUBLISHED" {print $2}')"
  [[ "${output}" =~ ^(none|partial|full)$ ]] || die 1 '新出口机发布情况输出格式异常'
  printf '%s' "${output}"
}

# 选新出口机的 Reality 端口：优先沿用旧端口（客户端看不到这个端口，但少一处变化便于排障）；被占用就另选。
# 记录里已有端口且尚未发布时再确认一次空闲（准备与发布之间可能被别的服务占用）。
migrate_choose_port() {
  local script state candidate
  script="${OP_TMP}/port-check.sh"
  write_port_check_script "${script}"
  candidate="${MIGRATE_NEW_EXIT_REALITY_PORT:-${MIGRATE_OLD_EXIT_REALITY_PORT}}"
  state="$(ssh_exit_stdin bash -s -- "${candidate}" < "${script}")" || die 3 '新出口机端口检查失败'
  if [[ "${state}" != free ]]; then
    candidate="$(choose_remote_port exit)" || die 3 '无法在新出口机选择 Reality 端口'
    log_info "[migrate] 新出口机上端口 ${MIGRATE_NEW_EXIT_REALITY_PORT:-${MIGRATE_OLD_EXIT_REALITY_PORT}} 已被占用，改用 ${candidate}"
  fi
  MIGRATE_NEW_EXIT_REALITY_PORT="${candidate}"
  MIGRATE_NEW_RELAY_TARGET="${MIGRATE_NEW_EXIT_HOST}:${candidate}"
  EXIT_REALITY_PORT="${candidate}"
  migrate_write_record
}

# 从旧出口机读出 exit.json（含私钥）写进新出口机的配置暂存。全程只经本机 bash 变量与管道：
# 旧机侧核哈希后输出 base64 单行，新机侧经 stdin 解码写入，再核一次哈希。
migrate_transfer_exit_config() {
  local script b64 rc target remote_hash
  script="${OP_TMP}/migrate-read-config.sh"
  cat > "${script}" <<'MIGRATE_READ_CONFIG'
#!/usr/bin/env bash
set -euo pipefail
umask 077
file="/etc/ownexit-chain/$1.exit.json"
[[ -f "$file" && ! -L "$file" && "$(stat -c %u:%g:%a "$file")" == 0:0:600 ]] || exit 61
[[ "$(sha256sum "$file" | awk '{print $1}')" == "$2" ]] || exit 62
base64 -w0 "$file"
MIGRATE_READ_CONFIG
  chmod 600 "${script}"
  migrate_use_exit old
  if b64="$(ssh_exit_stdin bash -s -- "${CHAIN_ID}" "${MIGRATE_OLD_EXIT_EXIT_SHA256}" < "${script}")"; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    255) die 3 '读取旧出口机配置时 SSH 不可达；旧出口机恢复后重跑，或 --abort 放弃迁移' ;;
    61|62) die 1 '旧出口机上本链的配置身份或哈希与 state 不符，拒绝搬运；请人工核对' ;;
    *) die 1 "读取旧出口机配置失败（rc=${rc}）" ;;
  esac
  [[ "${b64}" =~ ^[A-Za-z0-9+/]+=*$ ]] || die 1 '旧出口机返回的配置编码异常'
  migrate_use_exit new
  target="${MIGRATE_CONFIG_STAGE_PATH}/${CHAIN_ID}.exit.json"
  # 进程替换是管道，不落本机临时文件（bash 3.2 的 here-string 会写临时文件，不能用）。
  if ssh_exit_stdin "set -C; umask 077; base64 -d > '${target}' && chown root:root '${target}' && chmod 600 '${target}'" < <(printf '%s\n' "${b64}"); then rc=0; else rc="$?"; fi
  b64=''
  [[ "${rc}" -eq 0 ]] || die 1 "写入新出口机配置暂存失败（rc=${rc}）"
  remote_hash="$(ssh_exit sha256sum "${target}" | awk '{print $1}')" || die 3 '新出口机配置哈希读取失败'
  [[ "${remote_hash}" == "${MIGRATE_OLD_EXIT_EXIT_SHA256}" ]] || die 1 '新出口机上的配置哈希与旧出口机不一致'
  log_info "[migrate] exit config transferred sha256=${remote_hash:0:12}"
  if [[ "${MIGRATE_NEW_EXIT_REALITY_PORT}" != "${MIGRATE_OLD_EXIT_REALITY_PORT}" ]]; then
    # 与 rotate 的 apply_break_port 同一精确匹配：listen_port 行必须恰好 1 行，否则不改。
    if ssh_exit "awk -v from='    \"listen_port\": ${MIGRATE_OLD_EXIT_REALITY_PORT},' -v to='    \"listen_port\": ${MIGRATE_NEW_EXIT_REALITY_PORT},' '{ if (\$0 == from) { print to; n++ } else print } END { exit n == 1 ? 0 : 3 }' '${target}' > '${target}.port' && chown root:root '${target}.port' && chmod 600 '${target}.port' && mv -f '${target}.port' '${target}'"; then rc=0; else rc="$?"; fi
    [[ "${rc}" -eq 0 ]] || die 1 "新出口机配置的 listen_port 改写失败（rc=${rc}）"
    log_info "[migrate] listen_port ${MIGRATE_OLD_EXIT_REALITY_PORT} -> ${MIGRATE_NEW_EXIT_REALITY_PORT}"
  fi
}

# 新机器上建配置暂存、搬运 exit.json、渲染 owner 与 unit，三个哈希写入记录。
migrate_stage_config() {
  local owner_file stage_owner owner_b64 relay_source script output
  migrate_cleanup_stage CONFIG
  stage_owner="${OP_TMP}/migrate-config-stage-owner.env"
  render_owner_file "${stage_owner}" exit-stage "${MIGRATE_NEW_EXIT_HOSTKEY_FINGERPRINT}"
  MIGRATE_CONFIG_STAGE_OWNER_SHA256="$(sha256_file "${stage_owner}")"
  MIGRATE_NEW_EXIT_OWNER_SHA256=''
  MIGRATE_NEW_EXIT_EXIT_SHA256=''
  MIGRATE_NEW_EXIT_SERVICE_SHA256=''
  migrate_write_record
  create_remote_stage exit "${MIGRATE_CONFIG_STAGE_PATH}" "${MIGRATE_CONFIG_STAGE_OWNER_TEMP_PATH}" "${stage_owner}" "${MIGRATE_CONFIG_STAGE_OWNER_SHA256}" || die 1 '新出口机配置暂存创建失败'
  migrate_transfer_exit_config
  # owner 里是新主机指纹、新配置摘要与原部署 ID（CONFIG_SHA256 此时已是新值）。
  owner_file="${OP_TMP}/migrate-exit-owner.env"
  render_owner_file "${owner_file}" exit "${MIGRATE_NEW_EXIT_HOSTKEY_FINGERPRINT}"
  owner_b64="$(openssl base64 -A -in "${owner_file}")"
  relay_source='-'
  if [[ "${EXIT_SOURCE_FILTER}" == managed ]]; then
    relay_source="$(detect_relay_source_ip)"
    [[ "${EXIT_NFT_PATH}" == /* ]] || die 1 '没有取得新出口机 nft 路径，无法配置 managed 白名单'
    log_info "[migrate] 新出口机白名单放行来源=${relay_source}（EXIT_SOURCE_FILTER=managed）"
  fi
  script="${OP_TMP}/prepare-exit.sh"
  write_prepare_exit_script "${script}"
  output="$(ssh_exit_stdin bash -s -- "${MIGRATE_CONFIG_STAGE_PATH}" "${MIGRATE_CONFIG_STAGE_OWNER_SHA256}" "${REMOTE_BIN}" "${CHAIN_ID}" "${MIGRATE_NEW_EXIT_REALITY_PORT}" "${REALITY_SERVER_NAME}" "${owner_b64}" "${EXIT_SOURCE_FILTER}" "${EXIT_NFT_PATH:--}" "${relay_source}" reuse < "${script}")" || die 1 '新出口机 owner / unit 暂存失败'
  MIGRATE_NEW_EXIT_OWNER_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "EXIT_OWNER_SHA256" {print $2}')"
  MIGRATE_NEW_EXIT_EXIT_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "EXIT_EXIT_SHA256" {print $2}')"
  MIGRATE_NEW_EXIT_SERVICE_SHA256="$(printf '%s\n' "${output}" | awk -F= '$1 == "EXIT_SERVICE_SHA256" {print $2}')"
  [[ "${MIGRATE_NEW_EXIT_OWNER_SHA256}" =~ ^[0-9a-f]{64}$ && "${MIGRATE_NEW_EXIT_EXIT_SHA256}" =~ ^[0-9a-f]{64}$ && "${MIGRATE_NEW_EXIT_SERVICE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die 1 '新出口机暂存哈希不完整'
  migrate_write_record
  migrate_use_exit new
  log_info "[migrate] stage done exit_sha256=${MIGRATE_NEW_EXIT_EXIT_SHA256:0:12}"
  migrate_test_stop stage
}

# 从暂存把缺失的本链文件 link 到正式路径（已存在的必须哈希一致）；顺序同 deploy 的 promote：owner 最先，
# 因为拆除脚本要求“有其它文件就必须有 owner”。test_link1=link1 时在第一个 link 后退出 99（构造部分发布）。
write_migrate_promote_script() {
  local output
  output="$1"
  cat > "${output}" <<'MIGRATE_PROMOTE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
stage="$1"
stage_owner_hash="$2"
chain_id="$3"
owner_hash="$4"
config_hash="$5"
unit_hash="$6"
link_target="$7"
test_stop="$8"
[[ -d "$stage" && ! -L "$stage" && "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 90
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$stage_owner_hash" ]] || exit 91
wants=/etc/systemd/system/multi-user.target.wants
[[ -d "$wants" && ! -L "$wants" && "$(stat -c %u "$wants")" == 0 ]] || exit 95
mode="$(stat -c %a "$wants")"
(( (8#$mode & 8#022) == 0 )) || exit 96
linked=0
publish() {
  local src dst hash
  src="$1"; dst="$2"; hash="$3"
  if [[ -e "$dst" || -L "$dst" ]]; then
    [[ -f "$dst" && ! -L "$dst" && "$(sha256sum "$dst" | awk '{print $1}')" == "$hash" ]] || exit 97
    return 0
  fi
  [[ "$(sha256sum "$src" | awk '{print $1}')" == "$hash" ]] || exit 92
  link "$src" "$dst"
  linked=$((linked + 1))
  if [[ "$test_stop" == link1 && "$linked" == 1 ]]; then exit 99; fi
}
publish "$stage/$chain_id.owner.env" "/etc/ownexit-chain/$chain_id.owner.env" "$owner_hash"
publish "$stage/$chain_id.exit.json" "/etc/ownexit-chain/$chain_id.exit.json" "$config_hash"
publish "$stage/ownexit-chain-exit-$chain_id.service" "/etc/systemd/system/ownexit-chain-exit-$chain_id.service" "$unit_hash"
link_dst="$wants/ownexit-chain-exit-$chain_id.service"
if [[ -e "$link_dst" || -L "$link_dst" ]]; then
  [[ -L "$link_dst" && "$(readlink "$link_dst")" == "$link_target" ]] || exit 98
else
  ln --symbolic --no-target-directory "$link_target" "$link_dst"
  [[ "$(readlink "$link_dst")" == "$link_target" ]] || exit 98
fi
MIGRATE_PROMOTE
  chmod 600 "${output}"
}

migrate_promote() {
  local script test_stop rc
  script="${OP_TMP}/migrate-promote.sh"
  write_migrate_promote_script "${script}"
  test_stop='-'
  [[ "${OWNEXIT_TEST_MIGRATE_STOP_AFTER:-}" != link1 ]] || test_stop=link1
  if ssh_exit_stdin bash -s -- "${MIGRATE_CONFIG_STAGE_PATH}" "${MIGRATE_CONFIG_STAGE_OWNER_SHA256}" "${CHAIN_ID}" "${MIGRATE_NEW_EXIT_OWNER_SHA256}" "${MIGRATE_NEW_EXIT_EXIT_SHA256}" "${MIGRATE_NEW_EXIT_SERVICE_SHA256}" "${EXIT_ENABLE_LINK_TARGET}" "${test_stop}" < "${script}"; then rc=0; else rc="$?"; fi
  if [[ "${rc}" -eq 99 && "${test_stop}" == link1 ]]; then
    log_warn '测试钩子：migrate-exit 在 link1 之后停止'
    exit 99
  fi
  [[ "${rc}" -eq 0 ]] || die 1 "新出口机本链文件发布失败（rc=${rc}）"
}

# 发布新出口机上的本链文件并启动服务。只做 daemon-reload 与 start（同 activate_exit_exit）：启用链接已由 promote 创建。
migrate_publish() {
  local published unit
  published="$(migrate_published_state)"
  case "${published}" in
    none)
      migrate_stage_config
      migrate_promote
      ;;
    partial)
      # 暂存只在发布与启动全部完成后才清理；暂存不在而文件不全，只可能是外部改动。
      remote_path_absent exit "${MIGRATE_CONFIG_STAGE_PATH}" && die 1 '新出口机上本链文件部分发布但暂存已不在；请 --abort 后重新迁移'
      migrate_promote
      ;;
    full) ;;
  esac
  unit="ownexit-chain-exit-${CHAIN_ID}.service"
  ssh_exit systemctl daemon-reload || die 1 '新出口机 daemon-reload 失败'
  ssh_exit systemctl start "${unit}" || die 1 '新出口机 service 启动失败'
  [[ "$(ssh_exit systemctl is-active "${unit}")" == active ]] || die 1 '新出口机 service 未进入 active'
  [[ "$(ssh_exit systemctl is-enabled "${unit}")" == enabled ]] || die 1 '新出口机 service 未按预期 enabled'
  ssh_exit "ss -H -ltnp | grep -q ':${MIGRATE_NEW_EXIT_REALITY_PORT} '" || die 1 '新出口机 Reality 端口未监听'
  migrate_cleanup_stage CONFIG
  log_info "[migrate] publish done exit=${MIGRATE_NEW_EXIT_HOST}:${MIGRATE_NEW_EXIT_REALITY_PORT}"
  migrate_test_stop publish
}

# 中转切换（或在已切换时再核一次）：复用 rehost 远端脚本，state 值必须用迁移前 state 里的哈希。
# 已迁移的 owner / service 按 already 放行；运行中的 relay 若仍指向旧目标就重启。输出的新哈希赋给全局，
# 后面的核验与 state 提交都按新哈希走。
migrate_switch_relay() {
  local script output rc owner_result owner_hash service_result service_hash restarted
  script="${OP_TMP}/rehost-remote.sh"
  write_rehost_remote_script "${script}"
  if output="$(ssh_relay_stdin bash -s -- relay "${CHAIN_ID}" "${MIGRATE_STATE_RELAY_OWNER_SHA256}" "${MIGRATE_OLD_CONFIG_SHA256}" "${MIGRATE_NEW_CONFIG_SHA256}" "${MIGRATE_STATE_RELAY_SERVICE_SHA256}" "${MIGRATE_OLD_RELAY_TARGET}" "${MIGRATE_NEW_RELAY_TARGET}" < "${script}")"; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 1 "中转切换失败：$(rehost_remote_reason "${rc}")"
  owner_result="$(rehost_output_value "${output}" OWNER)"
  owner_hash="$(rehost_output_value "${output}" OWNER_SHA256)"
  service_result="$(rehost_output_value "${output}" SERVICE)"
  service_hash="$(rehost_output_value "${output}" SERVICE_SHA256)"
  restarted="$(rehost_output_value "${output}" RESTARTED)"
  [[ "${owner_result}" =~ ^(changed|already)$ && "${owner_hash}" =~ ^[0-9a-f]{64}$ ]] || die 1 '中转 owner 切换输出格式异常'
  [[ "${service_result}" =~ ^(changed|already)$ && "${service_hash}" =~ ^[0-9a-f]{64}$ ]] || die 1 '中转 service 切换输出格式异常'
  [[ "${restarted}" =~ ^(yes|no|inactive)$ ]] || die 1 '中转 service 重启结果格式异常'
  RELAY_OWNER_SHA256="${owner_hash}"
  RELAY_SERVICE_SHA256="${service_hash}"
  log_info "[migrate] relay owner=${owner_result} service=${service_result} restarted=${restarted} target=${MIGRATE_NEW_RELAY_TARGET}"
}

# 提交 state：出口相关字段与两个中转哈希取新值，其余字段（部署 ID、凭据、中转端口、基线、资产哈希）原样沿用。
migrate_commit_state() {
  local audit payload
  ensure_private_dir "${CHAIN_STATE_DIR}/audit" || die 1 'migrate audit 父目录不安全'
  audit="${CHAIN_STATE_DIR}/audit/migrated.${DEPLOYMENT_ID}.${OPERATION_ID}"
  [[ ! -e "${audit}" && ! -L "${audit}" ]] || die 1 "migrate audit 目录碰撞：${audit}"
  mkdir "${audit}" || die 1 'migrate audit 目录创建失败'
  chmod 700 "${audit}" || die 1 'migrate audit 目录权限设置失败'
  # 直接写最终文件名：audit 下以 . 开头的 *.tmp 会被残留检查判 drift。
  cp "${STATE_FILE}" "${audit}/state.env" || die 1 'migrate 旧 state 归档失败'
  chmod 600 "${audit}/state.env" || die 1 'migrate 旧 state 归档权限设置失败'
  [[ "$(sha256_file "${audit}/state.env")" == "$(sha256_file "${STATE_FILE}")" ]] || die 1 'migrate 旧 state 归档复核失败'
  # migrate_use_exit new 已把出口字段设为新值；这里再显式确认配置摘要，防止前面的探针改写过全局变量。
  migrate_use_exit new
  CONFIG_SHA256="${MIGRATE_NEW_CONFIG_SHA256}"
  payload="${OP_TMP}/state-payload"
  render_state_payload "${payload}" || die 1 'migrate state payload 生成失败'
  write_checksummed_file "${STATE_FILE}" replace "${payload}"
  migrate_test_stop state-nophase
  if probe_state_file "${STATE_FILE}"; then :; else die 1 "migrate 后 state 与新配置绑定失败：${STATE_PROBE_REASON}"; fi
  MIGRATE_PHASE=committed
  migrate_write_record
  log_info "[migrate] state committed audit=${audit}"
  migrate_test_stop state
}

# 执行阶段：装 binary、发布、切换前探针、切中转、提交前核验、提交 state。
# 进入时 state 绑定迁移前配置（全局变量是旧出口机的 state 值），配置已是新值。
migrate_execute() {
  local rc published
  migrate_use_exit new
  migrate_check_binding
  # 每个进程都要在新上下文跑一次：EXIT_NFT_PATH、SOCKET_PROXYD_PATH 只由它赋值。
  remote_platform_preflight
  log_info "[migrate] phase=execute stage=${MIGRATE_STAGE} chain=${CHAIN_ID}"
  if [[ "${MIGRATE_STAGE}" != switched ]]; then
    migrate_install_binary
    published=none
    [[ -z "${MIGRATE_NEW_EXIT_SERVICE_SHA256}" ]] || published="$(migrate_published_state)"
    if [[ "${published}" != none ]]; then
      # 已经发布过：端口沿用记录值，不再检查空闲（自己的服务正占着它）。
      EXIT_REALITY_PORT="${MIGRATE_NEW_EXIT_REALITY_PORT}"
    else
      migrate_choose_port
    fi
    migrate_publish
    migrate_use_exit new
    probe_exit_tls
    probe_exit_exit
    smoke_from_relay "${EXIT_HOST}" "${EXIT_REALITY_PORT}" exit-direct
    probe_mac_reality_rejection
    log_info '[migrate] probes done'
    migrate_test_stop probes
  fi
  migrate_switch_relay
  migrate_test_stop relay-nophase
  if [[ "${MIGRATE_PHASE}" != relay-switched ]]; then
    MIGRATE_PHASE='relay-switched'
    migrate_write_record
  fi
  migrate_test_stop relay
  # 提交前核验：新出口机与中转都按新哈希健康，并经中转端口真实走一次代理。
  if probe_remote_resources yes; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 1 "提交前核验失败（rc=${rc}）：新出口机或中转的文件、unit、进程、listener 与预期不符；修好后重跑"
  smoke_from_relay 127.0.0.1 "${RELAY_PORT}" relay-full
  migrate_commit_state
}

# 删除旧出口机上本链的 rotate 辅助文件与暂存（stage-owner 的 CHAIN_ID 必须是本链）。准备阶段已拒绝带辅助文件的旧链，
# 这里只是兜底。
write_migrate_old_leftover_script() {
  local output
  output="$1"
  cat > "${output}" <<'MIGRATE_OLD_LEFTOVER'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
chain_id="$1"
for leftover in "/etc/ownexit-chain/$chain_id".rotate.*; do
  [[ -e "$leftover" || -L "$leftover" ]] || continue
  [[ -f "$leftover" && ! -L "$leftover" && "$(stat -c %u "$leftover")" == 0 ]] || exit 221
  rm -f "$leftover"
done
for parent in /etc/ownexit-chain /opt/ownexit-chain; do
  [[ -d "$parent" && ! -L "$parent" ]] || continue
  while IFS= read -r stage; do
    owner="$stage/stage-owner.env"
    [[ -f "$owner" && ! -L "$owner" ]] || continue
    grep -qx "CHAIN_ID=$chain_id" "$owner" || continue
    [[ "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 222
    find "$stage" -depth -mindepth 1 ! -path "$owner" -delete
    rm -f "$owner"
    rmdir "$stage"
  done < <(find "$parent" -maxdepth 1 -type d -name '.stage-*' -print)
done
MIGRATE_OLD_LEFTOVER
  chmod 600 "${output}"
}

# 清理阶段：新链健康才拆旧机。旧机 SSH 不可达时保留记录（pending），重跑补做；哈希不符等漂移直接失败，不静默跳过。
migrate_cleanup() {
  local rc script step
  migrate_use_exit new
  migrate_check_binding
  remote_platform_preflight
  if probe_remote_resources yes; then rc=0; else rc="$?"; fi
  [[ "${rc}" -eq 0 ]] || die 1 "新链不健康（rc=${rc}），暂不清理旧出口机；先运行 verify 查明"
  log_info "[migrate] phase=cleanup old=${MIGRATE_OLD_EXIT_HOST}"
  if [[ "${OWNEXIT_TEST_MIGRATE_SKIP_CLEANUP:-}" == 1 ]]; then
    log_warn '测试钩子：跳过旧出口机清理'
    MIGRATE_CLEANUP_RESULT=pending
    return 0
  fi
  migrate_use_exit old
  script="${OP_TMP}/migrate-old-leftover.sh"
  write_migrate_old_leftover_script "${script}"
  # 四步依次执行；任一步 SSH 不可达（255）都按 pending 处理，其余非 0 视为漂移直接失败。每一步都可重跑。
  for step in stop remove verify leftover; do
    case "${step}" in
      stop) if stop_chain_role exit; then rc=0; else rc="$?"; fi ;;
      remove) if remove_chain_role_files exit; then rc=0; else rc="$?"; fi ;;
      verify) if verify_removed_chain_role exit; then rc=0; else rc="$?"; fi ;;
      leftover) if ssh_exit_stdin bash -s -- "${CHAIN_ID}" < "${script}"; then rc=0; else rc="$?"; fi ;;
    esac
    if [[ "${rc}" -eq 255 ]]; then
      log_warn "[migrate] old exit cleanup pending: ssh unreachable（${MIGRATE_OLD_EXIT_HOST}，step=${step}）；旧机器恢复后重跑 migrate-exit 补做，永久失联用 --abandon-cleanup"
      MIGRATE_CLEANUP_RESULT=pending
      migrate_use_exit new
      return 0
    fi
    [[ "${rc}" -eq 0 ]] || die 1 "旧出口机清理失败（step=${step} rc=${rc}）：文件身份或哈希与迁移记录不符；请人工核对 ${MIGRATE_OLD_EXIT_HOST}"
  done
  rm -f "${MIGRATE_FILE}" || die 1 '迁移记录删除失败'
  MIGRATE_CLEANUP_RESULT='done'
  log_info "[migrate] old exit cleanup done（${MIGRATE_OLD_EXIT_HOST}）"
  migrate_use_exit new
}

# --abort：只在中转确实没有切换、state 未提交时允许。拆掉新机器上已发布的本链文件，恢复配置，删除记录。
migrate_abort() {
  local rc key
  case "${MIGRATE_STAGE}" in
    recorded|executing) ;;
    *) die 2 '中转已切换或 state 已提交，不能 --abort；重跑 migrate-exit 完成迁移' ;;
  esac
  if [[ "${MIGRATE_STAGE}" == executing ]]; then
    migrate_check_binding
    remote_platform_preflight
    migrate_cleanup_stage BINARY
    migrate_cleanup_stage CONFIG
    # 拆除脚本按记录的新哈希核对；部分发布时缺失的文件自动跳过，stop 的 ExecStopPost 删除 nft 表。
    EXIT_REALITY_PORT="${MIGRATE_NEW_EXIT_REALITY_PORT:--}"
    EXIT_OWNER_SHA256="${MIGRATE_NEW_EXIT_OWNER_SHA256:--}"
    EXIT_EXIT_SHA256="${MIGRATE_NEW_EXIT_EXIT_SHA256:--}"
    EXIT_SERVICE_SHA256="${MIGRATE_NEW_EXIT_SERVICE_SHA256:--}"
    if stop_chain_role exit; then rc=0; else rc="$?"; fi
    [[ "${rc}" -ne 255 ]] || die 3 '新出口机 SSH 不可达；恢复后重跑 --abort'
    [[ "${rc}" -eq 0 ]] || die 1 "新出口机上本链的文件与迁移记录不符（rc=${rc}），不拆除；请人工核对"
    remove_chain_role_files exit || die 1 '新出口机删除本链文件失败'
    verify_removed_chain_role exit || die 1 '新出口机本链文件删除后复核失败'
    [[ -n "${MIGRATE_CONFIG_BACKUP}" ]] || die 1 '迁移记录缺少配置备份路径'
    require_secure_user_file "${MIGRATE_CONFIG_BACKUP}" 600 || die 1 "配置备份身份或权限异常：${MIGRATE_CONFIG_BACKUP}"
    for key in EXIT_HOST:OLD_EXIT_HOST EXIT_SSH_PORT:OLD_EXIT_SSH_PORT EXIT_SSH_KEY:OLD_EXIT_SSH_KEY EXPECTED_EXIT_IPV4:OLD_EXPECTED_EXIT_IPV4; do
      eval "[[ \"\$(kv_get \"\${MIGRATE_CONFIG_BACKUP}\" ${key%%:*})\" == \"\${MIGRATE_${key#*:}}\" ]]" || die 1 "配置备份里的 ${key%%:*} 与迁移前的值不符，不恢复；请人工核对 ${MIGRATE_CONFIG_BACKUP}"
    done
    cp "${MIGRATE_CONFIG_BACKUP}" "$(dirname "${CONFIG_PATH}")/.$(basename "${CONFIG_PATH}").abort.$$.tmp" || die 1 '配置恢复失败'
    chmod 600 "$(dirname "${CONFIG_PATH}")/.$(basename "${CONFIG_PATH}").abort.$$.tmp" || die 1 '配置恢复失败'
    mv -f "$(dirname "${CONFIG_PATH}")/.$(basename "${CONFIG_PATH}").abort.$$.tmp" "${CONFIG_PATH}" || die 1 '配置恢复失败'
    log_info "[migrate] config restored from ${MIGRATE_CONFIG_BACKUP}"
  fi
  rm -f "${MIGRATE_FILE}" || die 1 '迁移记录删除失败'
  printf 'migrate=aborted chain=%s\n' "${CHAIN_ID}"
  log_info "migrate-exit 已中止；chain=${CHAIN_ID} 仍使用出口机 ${MIGRATE_OLD_EXIT_HOST}；elapsed=$(elapsed_seconds)s"
}

migrate_exit_chain() {
  local rc leftover
  acquire_global_lock
  if acquire_chain_lock 1; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    10) die 5 '同一 chain 有活动锁（busy）；稍后重试' ;;
    11) die 5 '存在 stale lock；先运行 verify 或其它 mutating 命令归档' ;;
    *) die 5 '无法安全取得 chain lock' ;;
  esac
  require_local_dependencies
  [[ ! -e "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]] || die 5 '存在 incomplete transaction，migrate-exit 拒绝'
  MIGRATE_FILE="${CHAIN_STATE_DIR}/migrate-exit.env"
  # 上次进程在写记录时中断留下的临时文件：身份正常才删。
  for leftover in "${CHAIN_STATE_DIR}"/.migrate-exit.env.*.tmp; do
    [[ -e "${leftover}" || -L "${leftover}" ]] || continue
    require_secure_user_file "${leftover}" 600 || die 5 "迁移记录临时文件身份异常：${leftover}"
    rm -f "${leftover}" || die 5 "迁移记录临时文件删除失败：${leftover}"
  done
  if [[ ! -e "${MIGRATE_FILE}" && ! -L "${MIGRATE_FILE}" ]]; then
    [[ "${MIGRATE_MODE}" == run ]] || die 2 "链 ${CHAIN_ID} 没有进行中的出口机迁移"
    [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 5 'chain 尚未部署'
    migrate_prepare
  else
    [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 5 "迁移记录存在但链没有 state；请人工确认后删除 ${CHAIN_STATE_DIR}/migrate-exit.env"
    migrate_load_record
    if [[ "${MIGRATE_MODE}" == run ]]; then
      [[ "${MIGRATE_TO}" == "${MIGRATE_NEW_EXIT_HOST}" && "${MIGRATE_TO_PORT}" == "${MIGRATE_NEW_EXIT_SSH_PORT}" ]] \
        || die 2 "进行中的迁移目标是 ${MIGRATE_NEW_EXIT_HOST}:${MIGRATE_NEW_EXIT_SSH_PORT}；重跑时 --to / --to-port 必须一致（或先 --abort）"
    fi
  fi
  migrate_derive_stage
  log_info "[migrate] chain=${CHAIN_ID} phase=${MIGRATE_PHASE} stage=${MIGRATE_STAGE}"
  case "${MIGRATE_MODE}" in
    abort)
      migrate_abort
      return 0
      ;;
    abandon)
      [[ "${MIGRATE_STAGE}" == cleanup ]] || die 2 '迁移尚未提交，不能 --abandon-cleanup；重跑 migrate-exit 或 --abort'
      log_warn "[migrate] old exit cleanup abandoned; private key remains on ${MIGRATE_OLD_EXIT_HOST}：旧出口机上本链的配置（含私钥）未删除，请自行处理或销毁该机器"
      rm -f "${MIGRATE_FILE}" || die 1 '迁移记录删除失败'
      return 0
      ;;
  esac
  if [[ "${MIGRATE_STAGE}" == recorded ]]; then
    migrate_rewrite_config
    migrate_derive_stage
  fi
  if [[ "${MIGRATE_STAGE}" != cleanup ]]; then
    migrate_execute
  fi
  migrate_cleanup
  ensure_local_assets_match_state
  full_verify
  printf 'migrate=done chain=%s exit=%s:%s old_exit_cleanup=%s\n' "${CHAIN_ID}" "${EXIT_HOST}" "${EXIT_REALITY_PORT}" "${MIGRATE_CLEANUP_RESULT}"
  log_info "migrate-exit 通过；chain=${CHAIN_ID} exit=${EXIT_HOST}:${EXIT_REALITY_PORT} old_exit_cleanup=${MIGRATE_CLEANUP_RESULT} elapsed=$(elapsed_seconds)s"
}

# ---------- 少敲命令：省略 --id、up、qr、下一步提示、部署前 TUN 自检（docs/feature/feature-usability-v12.md） ----------

# 配置文件解析之后、各子命令之前的公共初始化（从 main 原样搬出，供 main 与 up_chain 共用）：
# 读配置 → 推导路径 → 生成本次操作 ID 并登记清理 trap → 建操作临时目录。顺序不能变：init_operation_tmp 依赖 CHAIN_ID、
# CONFIG_SHA256 与 LOCK_OPERATION_ID，trap 必须在任何会留下临时文件的步骤之前装好。
init_runtime() {
  parse_config
  init_paths
  OPERATION_ID="$(random_hex_128)"
  LOCK_OPERATION_ID="${OPERATION_ID}"
  trap 'cleanup_dispatcher $? EXIT' EXIT
  trap 'cleanup_dispatcher 130 INT' INT
  trap 'cleanup_dispatcher 143 TERM' TERM
  init_operation_tmp
}

# 本机只有一条链配置时把 CONFIG_PATH 指向它并返回 0；没有配置返回 10；多条在 stderr 列出各 id 后返回 11。
# 目录推导与 --id 分支、init_paths、init_chain 用同一算法。
resolve_single_chain_config() {
  local dir file count ids id
  dir="$(xdg_or_default "${XDG_CONFIG_HOME:-}" "${HOME}/.config")/ownexit/chains"
  count=0
  ids=''
  for file in "${dir}"/*.env; do
    [[ -f "${file}" ]] || continue
    count=$((count + 1))
    ids="${ids} $(basename "${file}" .env)"
    CONFIG_PATH="${file}"
  done
  if [[ "${count}" -eq 0 ]]; then
    CONFIG_PATH=''
    return 10
  fi
  if [[ "${count}" -gt 1 ]]; then
    CONFIG_PATH=''
    for id in ${ids}; do
      printf '  --id %s\n' "${id}" >&2
    done
    return 11
  fi
  log_info "自动选用链 $(basename "${CONFIG_PATH}" .env)（本机唯一）"
}

# 部署前自检：本机到每个服务器 IP 的出接口是不是代理的 TUN。经 TUN 时部署途中的 SSH 会被代理切断（历史上最常见的翻车），
# 默认拒绝；--allow-tun 只 WARN。只核 IPv4 字面量（主机名在 macOS 上会被 fake-ip 解析成 TUN 路由而误判）；
# 取不到出接口（缺 route / ip 命令等）按 doctor 的口径 WARN 继续，不拦。
tun_precheck() {
  local ip iface
  for ip in "$@"; do
    if ! is_ipv4 "${ip}"; then
      log_warn "目标 ${ip} 不是 IPv4，跳过 TUN 自检"
      continue
    fi
    iface="$(route_interface "${ip}")"
    if [[ -z "${iface}" ]]; then
      log_warn "无法判定到 ${ip} 的出接口，跳过 TUN 自检"
      continue
    fi
    interface_is_tunnel "${iface}" || continue
    if [[ "${ALLOW_TUN}" == 1 ]]; then
      log_warn "到 ${ip} 的路由经过 TUN（${iface}），已加 --allow-tun 继续；部署期间 SSH 可能被代理切断"
      continue
    fi
    die 3 "到 ${ip} 的路由经过 TUN（${iface}），部署期间 SSH 会被代理切断。
处理办法：关闭代理的 TUN 模式；或让这些 IP 走物理网卡（Clash Verge 见 docs/manual/clash-direct-ips.md）。
已按手册加了直连规则且 SSH 正常，或确认要继续：加 --allow-tun。"
  done
}

# deploy / up 成功后的“下一步”块（含幂等 no-op 路径）。数据来自 parse_config 的 EXPECTED_EXIT_IPV4 与
# 已核过哈希的 client/node.txt；二维码经 stdin 交给 qrencode，节点链接不进 argv。
print_chain_next_steps() {
  local node uri
  node="${CHAIN_STATE_DIR}/client/node.txt"
  require_secure_user_file "${node}" 600 || die 1 "node.txt 不存在或身份异常：${node}"
  uri="$(head -n 1 "${node}")"
  printf '==================== 下一步 ====================\n'
  printf '1. 导入客户端：下面的二维码用 Shadowrocket / 安卓客户端扫；Clash Verge 等复制这一行链接：\n'
  printf '   %s\n' "${uri}"
  printf '   （更多设备：ownexit chain add-device <名字>；随时再看二维码：ownexit chain qr）\n'
  printf '2. 在设备上打开 https://ipinfo.io，应显示 %s\n' "${EXPECTED_EXIT_IPV4}"
  printf '3. 出问题先跑：ownexit doctor\n'
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 < "${node}"
  else
    printf '（安装 qrencode 后可在终端显示二维码：macOS 用 brew install qrencode）\n'
  fi
  printf '================================================\n'
}

# qr：只读本机节点文件显示二维码，不连服务器、不改 state 与节点文件（取只读锁会像 status 一样写 operation.lock）。
# default 的节点文件由 verify_local_artifacts 核过 NODE_SHA256；设备节点只能核到“UUID 与 devices.env 一致”
# （devices.env 不在 state 哈希内，属弱保证）。
qr_chain() {
  local rc file expected uuid
  if acquire_chain_lock 0; then rc=0; else rc="$?"; fi
  case "${rc}" in
    0) ;;
    10) die 5 '同一 chain 有活动锁（busy）；稍后重试' ;;
    11) die 5 '存在 stale lock；先运行 verify 或其它 mutating 命令归档' ;;
    *) die 5 '无法安全取得 chain lock' ;;
  esac
  [[ -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die 5 '链未部署；先运行 chain up（或 deploy）'
  load_state_file "${STATE_FILE}"
  verify_local_artifacts || die 5 '本地节点文件与 state 不一致；运行 verify'
  if [[ -z "${QR_DEVICE}" ]]; then
    file="${CHAIN_STATE_DIR}/client/node.txt"
  else
    file="${CHAIN_STATE_DIR}/devices/node-${QR_DEVICE}.txt"
    [[ -e "${file}" || -L "${file}" ]] || die 2 "没有设备 ${QR_DEVICE}；运行 chain list-devices 查看"
    require_secure_user_file "${file}" 600 || die 5 "设备节点文件身份异常：${file}"
    require_secure_user_file "${CHAIN_STATE_DIR}/devices/devices.env" 600 || die 5 'devices.env 不存在或身份异常；运行 verify'
    expected="$(kv_get "${CHAIN_STATE_DIR}/devices/devices.env" "${QR_DEVICE}")" || die 2 "设备表里没有 ${QR_DEVICE}；运行 chain list-devices 查看"
    uuid="$(head -n 1 "${file}")"
    uuid="${uuid#vless://}"
    uuid="${uuid%%@*}"
    [[ "${uuid}" == "${expected}" ]] || die 5 "设备 ${QR_DEVICE} 的节点文件与设备表不一致；运行 verify"
  fi
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 < "${file}"
  else
    printf 'node=%s\n' "${file}"
    head -n 1 "${file}"
    printf '安装 qrencode（macOS: brew install qrencode）后可在终端显示二维码\n'
  fi
}

# up = init + deploy，可重跑：
#   - 没给 --id 也没给 IP：本机恰有一条链就复用它（没有则按 init 的方式新建 main，多条退出 2）；
#   - 配置不存在：走 init_chain（UP_MODE=1：先 TUN 自检，不打印 next=deploy）；
#   - 配置已存在：只比较显式给出的中转 / 出口地址与端口，不一致退出 2；显式给的 SNI / 过滤方式与配置不同只 WARN
#     （deploy 后不可改，改了会和 state 对不上）。
# 然后与 main 相同的初始化，再 deploy（已部署时 deploy 本身就是幂等 no-op + 完整 verify）。
up_chain() {
  local rc dir config_file mismatch
  UP_MODE=1
  if [[ "${INIT_ID_GIVEN}" == 0 && "${INIT_RELAY_GIVEN}" == 0 && "${INIT_EXIT_GIVEN}" == 0 ]]; then
    if resolve_single_chain_config; then rc=0; else rc="$?"; fi
    case "${rc}" in
      0) INIT_ID="$(basename "${CONFIG_PATH}" .env)" ;;
      10) INIT_ID=main ;;
      *) die 2 '本机有多条链，请用 --id <名字> 指定' ;;
    esac
  fi
  dir="$(xdg_or_default "${XDG_CONFIG_HOME:-}" "${HOME}/.config")/ownexit/chains"
  config_file="${dir}/${INIT_ID}.env"
  if [[ ! -e "${config_file}" && ! -L "${config_file}" ]]; then
    log_info "[up] config=new id=${INIT_ID}"
    init_chain
  else
    log_info "[up] config=existing id=${INIT_ID}"
    CONFIG_PATH="${config_file}"
    parse_config
    mismatch=0
    [[ "${INIT_RELAY_GIVEN}" == 0 || "${INIT_RELAY}" == "${RELAY_HOST}" ]] || mismatch=1
    [[ "${INIT_RELAY_PORT_GIVEN}" == 0 || "${INIT_RELAY_PORT}" == "${RELAY_SSH_PORT}" ]] || mismatch=1
    [[ "${INIT_EXIT_GIVEN}" == 0 || "${INIT_EXIT}" == "${EXIT_HOST}" ]] || mismatch=1
    [[ "${INIT_EXIT_PORT_GIVEN}" == 0 || "${INIT_EXIT_PORT}" == "${EXIT_SSH_PORT}" ]] || mismatch=1
    [[ "${mismatch}" == 0 ]] || die 2 "链 ${INIT_ID} 已有配置且地址不同（现有 中转=${RELAY_HOST}:${RELAY_SSH_PORT} 出口=${EXIT_HOST}:${EXIT_SSH_PORT}）；换一个 --id，或先 rollback 再删配置"
    [[ "${INIT_SNI_GIVEN}" == 0 || "${INIT_SNI}" == "${REALITY_SERVER_NAME}" ]] || log_warn "已有配置的 REALITY_SERVER_NAME=${REALITY_SERVER_NAME}，忽略本次给的 ${INIT_SNI}（deploy 后不可改）"
    [[ "${INIT_FILTER_GIVEN}" == 0 || "${INIT_EXIT_SOURCE_FILTER}" == "${EXIT_SOURCE_FILTER}" ]] || log_warn "已有配置的 EXIT_SOURCE_FILTER=${EXIT_SOURCE_FILTER}，忽略本次给的 ${INIT_EXIT_SOURCE_FILTER}（deploy 后不可改）"
    tun_precheck "${RELAY_HOST}" "${EXIT_HOST}"
  fi
  CONFIG_PATH="${config_file}"
  init_runtime
  deploy_chain
}

status_chain() {
  local rc
  if [[ -e "${JOURNAL_FILE}" || -L "${JOURNAL_FILE}" ]]; then
    if validate_checksum_env "${JOURNAL_FILE}" journal; then
      printf 'status=incomplete operation=%s step=%s next=run-mutating-command\n' "$(kv_get "${JOURNAL_FILE}" OPERATION)" "$(kv_get "${JOURNAL_FILE}" LAST_COMPLETED_STEP)"
    else
      printf 'status=drifted reason=transaction-corrupt next=inspect-transaction\n'
    fi
    return 5
  fi
  # 迁移进行中：state 与配置处在中间状态，其余检查都没有意义；提示重跑 migrate-exit（含 --abort / --abandon-cleanup）。
  if [[ -e "${CHAIN_STATE_DIR}/migrate-exit.env" || -L "${CHAIN_STATE_DIR}/migrate-exit.env" ]]; then
    printf 'status=drifted reason=exit-migration-pending next=rerun-interrupted-command\n'
    return 5
  fi
  if ! render_ssh_config; then
    printf 'status=drifted reason=local-ssh-config-render next=check-config\n'
    return 5
  fi
  if [[ ! -e "${STATE_FILE}" && ! -L "${STATE_FILE}" ]]; then
    if ! configured_local_resources_absent; then
      printf 'status=orphaned reason=local-stage-temp-or-artifact-present next=inspect-local-state\n'
      return 5
    fi
    if configured_resources_absent; then
      rc=0
    else
      rc="$?"
    fi
    case "${rc}" in
      0)
        printf 'status=not_deployed\n'
        return 0
        ;;
      21)
        printf 'status=unreachable role=relay reason=resource-absence-probe next=retry-status\n'
        return 5
        ;;
      22)
        printf 'status=unreachable role=exit reason=resource-absence-probe next=retry-status\n'
        return 5
        ;;
      *)
        printf 'status=orphaned reason=deterministic-resource-or-owned-stage-present next=inspect-orphan\n'
        return 5
        ;;
    esac
  fi
  if probe_state_file "${STATE_FILE}"; then
    rc=0
  else
    rc="$?"
  fi
  if [[ "${rc}" -ne 0 ]]; then
    printf 'status=drifted reason=%s next=inspect-state\n' "${STATE_PROBE_REASON:-state-corrupt}"
    return 5
  fi
  if probe_loaded_binding; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) ;;
    21) printf 'status=unreachable role=relay reason=hostkey-probe next=retry-status\n'; return 5 ;;
    22) printf 'status=unreachable role=exit reason=hostkey-probe next=retry-status\n'; return 5 ;;
    11|31) printf 'status=drifted role=relay reason=ssh-key-or-hostkey-binding next=inspect-binding\n'; return 5 ;;
    12|32) printf 'status=drifted role=exit reason=ssh-key-or-hostkey-binding next=inspect-binding\n'; return 5 ;;
    *) printf 'status=drifted reason=binding-probe next=inspect-binding\n'; return 5 ;;
  esac
  if probe_remote_platform_preflight; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) ;;
    21) printf 'status=unreachable role=relay reason=platform-preflight next=retry-status\n'; return 5 ;;
    22) printf 'status=unreachable role=exit reason=platform-preflight next=retry-status\n'; return 5 ;;
    *) printf 'status=drifted reason=platform-preflight next=inspect-platform\n'; return 5 ;;
  esac
  if ! verify_local_artifacts; then
    printf 'status=drifted reason=local-artifacts next=inspect-local-state\n'
    return 5
  fi
  if probe_relay_baseline; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) ;;
    21) printf 'status=unreachable role=relay reason=baseline next=retry-status\n'; return 5 ;;
    *) printf 'status=drifted role=relay reason=baseline next=inspect-baseline\n'; return 5 ;;
  esac
  if probe_deployment_residue; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) ;;
    21) printf 'status=unreachable role=relay reason=residue-probe next=retry-status\n'; return 5 ;;
    22) printf 'status=unreachable role=exit reason=residue-probe next=retry-status\n'; return 5 ;;
    *) printf 'status=drifted reason=deployment-residue next=inspect-residue\n'; return 5 ;;
  esac
  # 仅在身份、平台、静态资源、既有服务基线与残留全部通过后，才允许 socket 激活链的
  # relay service 自恢复；status 不写远端文件，但可能执行一次 systemctl start。
  if probe_remote_resources yes; then
    rc=0
  else
    rc="$?"
  fi
  case "${rc}" in
    0) ;;
    21) printf 'status=unreachable role=relay reason=resource-probe next=retry-status\n'; return 5 ;;
    22) printf 'status=unreachable role=exit reason=resource-probe next=retry-status\n'; return 5 ;;
    33) printf 'status=drifted reason=exit-op-pending next=rerun-interrupted-command\n'; return 5 ;;
    *) printf 'status=drifted reason=remote-resource-unit-process-or-listener next=run-verify\n'; return 5 ;;
  esac
  printf 'status=deployed health=healthy deployment=%s\n' "${DEPLOYMENT_ID:0:12}"
}

cleanup_recorded_local_pids() {
  if [[ -n "${TEMP_PID}" ]]; then
    cleanup_one_local_pid "${TEMP_PID}" "${TEMP_PID_CONFIG}" || return 1
    remove_recorded_local_pid "${TEMP_PID}" || return 1
  fi
  if [[ -n "${LOCAL_PROCESS_GATE}" ]]; then
    rm -f "${LOCAL_PROCESS_GATE}" || return 1
    LOCAL_PROCESS_GATE=''
  fi
  TEMP_PID=''
  TEMP_PID_CONFIG=''
  TEMP_PID_START=''
}

cleanup_operation_tmp() {
  [[ -n "${OP_TMP}" ]] || return 0
  if [[ ! -e "${OP_TMP}" && ! -L "${OP_TMP}" ]]; then
    return 0
  fi
  operation_tmp_owner_matches "${OP_TMP}" "${LOCK_OPERATION_ID}" "${OPERATION_CONFIG_SHA256}" || return 1
  find "${OP_TMP}" -depth -mindepth 1 ! -path "${OP_TMP}/operation-owner.env" -delete || return 1
  rm -f "${OP_TMP}/operation-owner.env"
  rmdir "${OP_TMP}"
}

cleanup_dispatcher() {
  local original_status event release_chain_lock temp_cleanup_failed child_safe local_process_safe
  original_status="$1"
  event="$2"
  if [[ "${CLEANUP_RUNNING}" == 1 ]]; then
    return
  fi
  CLEANUP_RUNNING=1
  release_chain_lock=1
  temp_cleanup_failed=0
  child_safe="${ACTIVE_CHILD_REGISTRY_SAFE}"
  local_process_safe=1
  set +e
  if [[ "${child_safe}" != 1 ]]; then
    release_chain_lock=0
  fi
  if [[ "${LOCK_CHAIN_HELD}" == 1 && ( -e "${ACTIVE_CHILD_FILE}" || -L "${ACTIVE_CHILD_FILE}" ) ]]; then
    if ! terminate_active_child; then
      child_safe=0
      release_chain_lock=0
      log_warn '外部 SSH/scp 子进程未能确认停止；保留锁与 transaction，禁止并发恢复'
    fi
  fi
  if [[ -n "${ACTIVE_CHILD_GATE}" ]]; then
    rm -f "${ACTIVE_CHILD_GATE}" 2>/dev/null || true
    ACTIVE_CHILD_GATE=''
  fi
  if [[ -e "${ACTIVE_CHILD_FILE}" || -L "${ACTIVE_CHILD_FILE}" || -e "${CHAIN_STATE_DIR}/.active-child.${LOCK_OPERATION_ID}.tmp" || -L "${CHAIN_STATE_DIR}/.active-child.${LOCK_OPERATION_ID}.tmp" ]]; then
    if ! cleanup_stale_active_child "${LOCK_OPERATION_ID}" "${ACTIVE_CHILD_FILE}"; then
      child_safe=0
      release_chain_lock=0
      log_warn '外部子进程 registry/temp 未能安全闭合；保留 operation lock 与操作目录'
    fi
  fi
  if [[ "${WATCHDOG_ARMED}" == 1 ]]; then
    if [[ "${child_safe}" == 1 && -n "${SSH_CONFIG}" && -f "${SSH_CONFIG}" ]] && restore_and_disarm_fail_closed_watchdog; then
      log_info '异常退出前已恢复 relay socket 并解除 fail-closed watchdog'
    else
      child_safe="${ACTIVE_CHILD_REGISTRY_SAFE}"
      release_chain_lock=0
      log_warn 'relay socket 或 fail-closed watchdog 未能安全闭合；保留锁、transaction 与操作目录'
    fi
  fi
  if [[ "${original_status}" -ne 0 && ( "${COMMAND}" == deploy || "${COMMAND}" == rollback ) && -n "${JOURNAL_FILE}" && -e "${JOURNAL_FILE}" ]]; then
    # EXIT 阶段只做进程/临时文件闭合，不在条件上下文中重入破坏性事务；下一次 mutating 命令会持锁续做。
    log_warn '操作失败；transaction 已保留，下一次 mutating 命令会继续恢复'
  fi
  if [[ "${original_status}" -ne 0 && "${COMMAND}" == deploy && -n "${JOURNAL_FILE}" && ! -e "${JOURNAL_FILE}" && -n "${LOCAL_STAGE_PATH}" && "${LOCAL_STAGE_PATH}" != ABSENT ]]; then
    if ! cleanup_local_stage_if_owned || ! cleanup_local_stage_owner_temp "${LOCK_OPERATION_ID}"; then
      # 保留当前锁，让下一条 mutating 命令以 stale-lock 身份继续安全恢复，不能留下不可见 orphan。
      release_chain_lock=0
      log_warn '首份 transaction 前的本地 staging 未能安全清理；保留 operation lock 供下次恢复'
    fi
  fi
  if [[ ( "${COMMAND}" == deploy || "${COMMAND}" == rollback ) && "${LOCK_CHAIN_HELD}" == 1 ]]; then
    cleanup_control_temps_by_lock_id "${LOCK_OPERATION_ID}" || temp_cleanup_failed=1
    if [[ "${COMMAND}" == deploy ]]; then
      cleanup_cache_temps_by_lock_id "${LOCK_OPERATION_ID}" || temp_cleanup_failed=1
    fi
    if [[ "${temp_cleanup_failed}" == 1 ]]; then
      release_chain_lock=0
      log_warn '锁绑定的状态/cache 临时文件未能安全清理；保留 operation lock 供下次恢复'
    fi
  fi
  if ! cleanup_recorded_local_pids; then
    local_process_safe=0
    release_chain_lock=0
  fi
  if [[ -e "${LOCAL_PROCESS_FILE}" || -L "${LOCAL_PROCESS_FILE}" || -e "${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp" || -L "${CHAIN_STATE_DIR}/.local-process.${LOCK_OPERATION_ID}.tmp" ]]; then
    if ! cleanup_stale_local_process "${LOCK_OPERATION_ID}" "${LOCAL_PROCESS_FILE}"; then
      local_process_safe=0
      release_chain_lock=0
      log_warn '本地临时进程 registry/temp 未能安全闭合；保留 operation lock 与操作目录'
    fi
  fi
  if [[ "${child_safe}" == 1 && "${local_process_safe}" == 1 && "${release_chain_lock}" == 1 ]]; then
    cleanup_operation_tmp || release_chain_lock=0
  fi
  if [[ "${LOCK_CHAIN_HELD}" == 1 ]]; then
    if [[ "${release_chain_lock}" == 1 ]]; then
      if release_lock_file "${CHAIN_LOCK}"; then
        LOCK_CHAIN_HELD=0
      else
        release_chain_lock=0
        log_warn 'operation lock 未能通过最终身份/残留闸门，已保留供 stale recovery'
      fi
    fi
  fi
  if [[ "${LOCK_GLOBAL_HELD}" == 1 ]]; then
    if [[ "${release_chain_lock}" == 1 ]] && release_lock_file "${GLOBAL_LOCK}"; then
      LOCK_GLOBAL_HELD=0
    else
      log_warn 'shared global lock 随未闭合 chain 操作保留，禁止其它 chain 并发写共享资源'
    fi
  fi
  CLEANUP_RUNNING=0
  set -e
  if [[ "${event}" != EXIT ]]; then
    trap - EXIT INT TERM
    if [[ "${event}" == INT ]]; then
      exit 130
    fi
    exit 143
  fi
  return "${original_status}"
}

# ---------- init：只问两个 IP，生成本链配置文件 ----------
#
# init 是唯一不读配置、不加锁、不建 operation 的子命令：它在 parse_config 之前分派（见 main），
# 只做三件事——给两台机器配免密（复用 direct/connect_to.sh）、只读探测出口 IP 与中转现状、在本机写一个配置文件。
# 远端不做任何修改；生成的文件随后由同一个严格解析器读回校验，后续 deploy / verify / rollback 只认这个文件。

# 与 direct/connect_to.sh、direct/target_lib.sh 的密钥路径推导完全一致；init 只支持 root（validate_config_values 要求）。
init_key_path() {
  printf '%s/.ssh/ownexit/id_ed25519_%s\n' "${HOME}" "$(printf '%s' "root_$1_$2" | tr -c '[:alnum:]_.@-' '_')"
}

# 缺参数时：终端里交互提问，非终端以退出码 2 报出缺哪个参数。
init_prompt_ipv4() {
  local label flag value
  label="$1"
  flag="$2"
  [[ -t 0 ]] || die 2 "缺少 ${flag}（${label}的公网 IPv4；非终端运行时必须显式给出）"
  read -r -p "${label}的公网 IPv4: " value
  is_ipv4 "${value}" || die 2 "${label}必须是 IPv4：${value}"
  printf '%s\n' "${value}"
}

# 给一台机器配免密，并确保 known_hosts 里有它的 ed25519 host key（chain 的 SSH 配置只接受 ed25519，见 render_ssh_config）。
init_setup_host() {
  local label host port key rc
  label="$1"
  host="$2"
  port="$3"
  key="$(init_key_path "${host}" "${port}")"
  log_info "${label} ${host}:${port} 配置免密"
  rc=0
  # 用 bash 显式执行：pip 安装的副本不保证保留可执行位。
  bash "${SCRIPT_DIR}/../direct/connect_to.sh" --setup-only --host "${host}" --port "${port}" --user root || rc="$?"
  [[ "${rc}" -eq 0 ]] || die 3 "${label} ${host}:${port} 配置免密失败（原因见上方 reason=...），未生成配置文件；修正后重跑 init"
  if init_probe_ed25519 "${key}" "${host}" "${port}"; then
    return 0
  fi
  # 较旧的 OpenSSH（如 Ubuntu 20.04 的 8.2）首次连接优先用 ECDSA，known_hosts 里只记了 ECDSA；之后强制 ed25519 时
  # 它把“换了密钥类型”当成主机身份变化而拒绝，不会自动补记。这里经刚刚已用已知主机密钥验证过的会话读取对方的
  # ed25519 公钥并补记，信任来源与第一次连接相同，不使用未经认证的 ssh-keyscan。
  init_record_ed25519_hostkey "${key}" "${host}" "${port}" \
    || die 3 "${label} ${host}:${port} 无法取得 ed25519 host key（chain 只接受 ed25519），请检查 sshd 的 HostKey 配置"
  init_probe_ed25519 "${key}" "${host}" "${port}" \
    || die 3 "${label} ${host}:${port} 补记 ed25519 host key 后仍无法用 ed25519 登录"
}

init_probe_ed25519() {
  ssh -n -i "$1" -p "$3" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=12 \
    -o HostKeyAlgorithms=ssh-ed25519 -o StrictHostKeyChecking=accept-new root@"$2" true >/dev/null 2>&1
}

init_record_ed25519_hostkey() {
  local key host port pub entry
  key="$1"
  host="$2"
  port="$3"
  pub="$(ssh -n -i "${key}" -p "${port}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=12 \
    -o StrictHostKeyChecking=yes root@"${host}" 'cat /etc/ssh/ssh_host_ed25519_key.pub' 2>/dev/null)" || return 1
  pub="$(printf '%s\n' "${pub}" | awk '$1 == "ssh-ed25519" && $2 ~ /^[A-Za-z0-9+\/]+=*$/ {print $1, $2; exit}')"
  [[ -n "${pub}" ]] || return 1
  if [[ "${port}" == 22 ]]; then entry="${host}"; else entry="[${host}]:${port}"; fi
  printf '%s %s\n' "${entry}" "${pub}" >> "${HOME}/.ssh/known_hosts" || return 1
  log_info "已经由已验证的会话补记 ${entry} 的 ed25519 host key"
}

# 在中转机上采集 co-host 判定表的 6 个信号并判定取值（yes / ownexit-direct / no），init 与 rebaseline 共用；
# 不满足任何一行时输出信号原文并返回 1。参数：私钥路径、SSH 端口、中转地址。
relay_cohost_kind_via() {
  local key="$1" port="$2" host="$3" probe u1 u2 d1 d2 p
  probe="$(ssh -n -i "${key}" -p "${port}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=12 \
    root@"${host}" 'u1=$(systemctl show sing-box.service -p LoadState --value 2>/dev/null || true); u2=$(systemctl show ownexit-direct.service -p LoadState --value 2>/dev/null || true); d1=no; { [ -e /etc/sing-box ] || [ -L /etc/sing-box ]; } && d1=yes; d2=no; { [ -e /etc/ownexit-direct ] || [ -L /etc/ownexit-direct ]; } && d2=yes; p=no; for e in /proc/[0-9]*/exe; do r=$(readlink -f "$e" 2>/dev/null || true); case "${r##*/}" in sing-box|sing-box-*) p=yes; break;; esac; done; printf "%s %s %s %s %s\n" "${u1:-unknown}" "${u2:-unknown}" "$d1" "$d2" "$p"' 2>/dev/null || true)"
  read -r u1 u2 d1 d2 p <<< "${probe}"
  if [[ "${u1}" == loaded && "${d1}" == yes && "${p}" == yes && "${u2}" == not-found && "${d2}" == no ]]; then
    printf 'yes'
  elif [[ "${u2}" == loaded && "${d2}" == yes && "${p}" == yes && "${u1}" == not-found && "${d1}" == no ]]; then
    printf 'ownexit-direct'
  elif [[ "${u1}" == not-found && "${u2}" == not-found && "${d1}" == no && "${d2}" == no && "${p}" == no ]]; then
    printf 'no'
  else
    printf 'sing-box.service=%s ownexit-direct.service=%s /etc/sing-box=%s /etc/ownexit-direct=%s 进程=%s' \
      "${u1:-未知}" "${u2:-未知}" "${d1:-未知}" "${d2:-未知}" "${p:-未知}"
    return 1
  fi
}

init_chain() {
  local relay exit_host chain_id relay_port exit_port sni relay_key exit_key exit_ip answer cohost
  local config_file tmp_file
  relay="${INIT_RELAY}"
  exit_host="${INIT_EXIT}"
  chain_id="${INIT_ID}"
  relay_port="${INIT_RELAY_PORT}"
  exit_port="${INIT_EXIT_PORT}"
  sni="${INIT_SNI}"

  [[ "${chain_id}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die 2 "--id 只允许 [a-z0-9][a-z0-9-]{0,31}：${chain_id}"
  [[ -n "${relay}" ]] || relay="$(init_prompt_ipv4 中转机 --relay)"
  is_ipv4 "${relay}" || die 2 "--relay 必须是 IPv4：${relay}"
  [[ -n "${exit_host}" ]] || exit_host="$(init_prompt_ipv4 出口机 --exit)"
  is_ipv4 "${exit_host}" || die 2 "--exit 必须是 IPv4：${exit_host}"
  [[ "${relay}" != "${exit_host}" ]] || die 2 '中转机和出口机必须是两台不同的主机'
  # up 在第一次 SSH（配免密）之前就自检 TUN；单独 init 不检（它只是生成配置）。
  [[ "${UP_MODE}" == 0 ]] || tun_precheck "${relay}" "${exit_host}"

  CONFIG_HOME="$(xdg_or_default "${XDG_CONFIG_HOME:-}" "${HOME}/.config")"
  CHAIN_CONFIG_DIR="${CONFIG_HOME}/ownexit/chains"
  config_file="${CHAIN_CONFIG_DIR}/${chain_id}.env"
  # 已存在就拒绝：覆盖会让已部署链的 state（绑定配置哈希）与配置对不上。
  [[ ! -e "${config_file}" && ! -L "${config_file}" ]] || die 2 "配置已存在：${config_file}；换一个 --id，或确认不再需要后手工删除它"
  # REPO_ROOT 为空（pip 安装形态）时不判断；否则 "${REPO_ROOT}"/* 会变成 /*，把所有路径都当成仓库内。
  if [[ -n "${REPO_ROOT}" ]]; then
    case "${config_file}" in
      "${REPO_ROOT}"|"${REPO_ROOT}"/*) die 2 '配置目录位于本仓库内；请把 XDG_CONFIG_HOME 指到仓库外' ;;
    esac
  fi

  init_setup_host 中转机 "${relay}" "${relay_port}"
  init_setup_host 出口机 "${exit_host}" "${exit_port}"
  relay_key="$(init_key_path "${relay}" "${relay_port}")"
  exit_key="$(init_key_path "${exit_host}" "${exit_port}")"

  # 出口 IP：在出口机上直接问 ipinfo.io；它是 verify 的唯一允许值，所以终端里要人确认。
  exit_ip="$(ssh -n -i "${exit_key}" -p "${exit_port}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=12 \
    root@"${exit_host}" 'curl -fsS -m 15 ipinfo.io/ip' 2>/dev/null | tr -d '[:space:]' || true)"
  is_ipv4 "${exit_ip}" || die 3 "无法在出口机上取得公网 IPv4（需要 curl 能访问 ipinfo.io）；读到：${exit_ip:-空}"
  log_info "出口机公网 IP：${exit_ip}"
  if [[ -t 0 ]]; then
    read -r -p "确认客户端经这条链出去的 IP 应当是 ${exit_ip}？[y/N] " answer
    [[ "${answer}" == y || "${answer}" == Y ]] || die 2 '未确认出口 IP，未生成配置文件'
  fi

  # 中转现状：判定方式与 preflight 远端脚本一致（co-host 判定表，§5.1.10），满足其中一行才自动填。
  cohost="$(relay_cohost_kind_via "${relay_key}" "${relay_port}" "${relay}")" || die 3 "中转机上的 sing-box 状态不完整（${cohost}）；请先让 233boy 的 sing-box 或 ownexit-direct 完整运行，或彻底移除，再重跑 init"
  log_info "中转机既有 sing-box：RELAY_COHOSTS_SINGBOX=${cohost}（yes=233boy、ownexit-direct=ownexit 直连、no=没有；deploy 会保护既有服务不受影响）"
  case "${INIT_EXIT_SOURCE_FILTER}" in
    managed) log_info 'EXIT_SOURCE_FILTER=managed：部署时会在出口机加 nft 白名单，Reality 端口只放行中转机' ;;
    provider) log_info 'EXIT_SOURCE_FILTER=provider：由服务商安全组只放行中转机，部署时严格检查' ;;
    none) log_info 'EXIT_SOURCE_FILTER=none：出口机 Reality 端口不限制来源（没有凭据用不了）' ;;
  esac

  ensure_private_dir "${CHAIN_CONFIG_DIR}" || die 2 "配置目录身份或权限不安全：${CHAIN_CONFIG_DIR}"
  tmp_file="$(mktemp "${CHAIN_CONFIG_DIR}/.${chain_id}.env.XXXXXX")"
  chmod 600 "${tmp_file}"
  {
    printf '# 由 setup_chain.sh init 生成；deploy 之后不要再改，改动会让 state 与配置对不上。\n'
    printf 'CHAIN_ID=%s\n' "${chain_id}"
    printf 'RELAY_HOST=%s\nRELAY_SSH_PORT=%s\nRELAY_SSH_USER=root\nRELAY_SSH_KEY=%s\n' "${relay}" "${relay_port}" "${relay_key}"
    printf 'EXIT_HOST=%s\nEXIT_SSH_PORT=%s\nEXIT_SSH_USER=root\nEXIT_SSH_KEY=%s\n' "${exit_host}" "${exit_port}" "${exit_key}"
    printf 'EXPECTED_EXIT_IPV4=%s\n' "${exit_ip}"
    printf 'REALITY_SERVER_NAME=%s\n' "${sni}"
    printf 'RELAY_COHOSTS_SINGBOX=%s\n' "${cohost}"
    printf 'EXIT_SOURCE_FILTER=%s\n' "${INIT_EXIT_SOURCE_FILTER}"
  } > "${tmp_file}"
  # 读回校验在子 shell 里跑：parse_config 失败会 die 退出，必须先删掉临时文件，不能留下一份坏配置。
  if ! ( CONFIG_PATH="${tmp_file}"; parse_config ) >/dev/null; then
    rm -f "${tmp_file}"
    die 2 '生成的配置未通过严格解析器校验，已删除；请把上方错误反馈给维护者'
  fi
  mv "${tmp_file}" "${config_file}"
  log_info "已生成 ${config_file}"
  # up 紧接着就 deploy，不提示“下一步 deploy”。
  [[ "${UP_MODE}" == 1 ]] || printf '[chain][init] next=%s --id %s deploy\n' "$(basename "${SCRIPT_PATH}")" "${chain_id}"
}

main() {
  local rc
  STARTED_AT="$(date '+%s')"
  parse_args "$@"
  init_repo_root
  if [[ "${COMMAND}" == init ]]; then
    init_chain
    exit 0
  fi
  if [[ "${COMMAND}" == up ]]; then
    up_chain
    print_chain_next_steps
    return 0
  fi
  init_runtime
  case "${COMMAND}" in
    status|conns|banlist|list-devices) READONLY_SSH_RETRY=1 ;;
    verify) [[ "${WITH_FAIL_CLOSED}" == 1 ]] || READONLY_SSH_RETRY=1 ;;
  esac

  case "${COMMAND}" in
    preflight)
      preflight_chain
      ;;
    deploy)
      deploy_chain
      print_chain_next_steps
      ;;
    qr)
      qr_chain
      ;;
    verify)
      verify_command
      ;;
    status)
      if acquire_chain_lock 0; then rc=0; else rc="$?"; fi
      case "${rc}" in
        0)
          require_local_dependencies
          status_chain
          ;;
        10)
          printf 'status=busy next=retry-status\n'
          return 5
          ;;
        11)
          printf 'status=stale_lock next=run-mutating-command\n'
          return 5
          ;;
        *) die 5 'status 无法安全处理 operation lock' ;;
      esac
      ;;
    rollback)
      rollback_chain
      ;;
    conns)
      relay_conns
      ;;
    kick)
      relay_kick
      ;;
    ban)
      relay_ban
      ;;
    unban)
      relay_unban
      ;;
    banlist)
      relay_banlist
      ;;
    rehost-exit)
      rehost_exit_chain
      ;;
    rebaseline)
      rebaseline_chain
      ;;
    rotate-keys)
      rotate_keys_chain
      ;;
    add-device|remove-device)
      device_op_chain
      ;;
    list-devices)
      list_devices_chain
      ;;
    migrate-exit)
      migrate_exit_chain
      ;;
  esac
}

main "$@"
