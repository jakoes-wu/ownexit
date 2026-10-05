#!/usr/bin/env bash
# 出口机 + 中转主机独立链路的部署、验证、状态查询与回滚入口。
# 前置：
#   - 控制端：macOS（Apple 芯片 / Intel，系统 /bin/bash 3.2 即可）或 Linux（amd64 / arm64，含 WSL）。
#   - 两台 Linux 主机（同为 amd64 或同为 arm64）均已配置 root 免密 SSH，ed25519 host key 已进入 known_hosts（init 会配好）。
#   - 出口机安全组已允许中转主机访问；配置文件权限为 600，git clone 使用时还须位于仓库工作区外（pip 安装时没有工作区，不检查）。
#   - 两台远端的依赖、防火墙与既有 sing-box 状态须通过 preflight；脚本不会自动安装软件包或改防火墙。
#   - 连接治理命令（conns/kick/ban/unban/banlist）要求链已 deploy；kick 依赖中转内核支持 ss -K，
#     ban 依赖中转 cgroup v2 + systemd IPAddressDeny=（BPF），二者实测于 Debian 12 / systemd 252。
#   - rehost-exit 要求链已 deploy、config 已改好新 EXIT_HOST / EXPECTED_EXIT_IPV4、known_hosts 已有新 IP 的
#     ed25519 条目，且新 IP 与 state 的主机指纹一致（同一台出口机）。
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
MANAGED_CHILD_TIMEOUT_SECONDS=600

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
# kick/ban/unban 的目标；ban/unban 经 normalize_ip_entry 规范化为 a.b.c.d/N 后才落黑名单。
TARGET_IP=''
BLACKLIST_FILE=''
# 中转受管 drop-in 文件名；verify/rollback 只放行这一个文件，其余 drop-in 一律判 drifted。
readonly RELAY_BLACKLIST_DROPIN='50-ownexit-chain-blacklist.conf'
CONFIG_SHA256=''
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
  $(basename "${SCRIPT_PATH}") --id <名字> <子命令>          # 等价于 --config ~/.config/ownexit/chains/<名字>.env
  $(basename "${SCRIPT_PATH}") --config <绝对路径> preflight
  $(basename "${SCRIPT_PATH}") --config <绝对路径> deploy
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
  $(basename "${SCRIPT_PATH}") -h | --help

作用:
  init       只问两个 IP：给中转机和出口机配免密（第一次各问一次 root 密码），探测出口 IP 与中转现状，
             生成 ~/.config/ownexit/chains/<名字>.env（默认名字 main）。不修改远端，已存在同名配置时拒绝。
  preflight  只读核验本机、两台远端、官方资产、出口与碰撞条件。
  deploy     持锁重跑全部 gate，按出口机出口 -> 中转入口顺序事务部署。
  verify     按 state 核验资源、既有服务基线和三层真实代理出口。
  status     返回 healthy/not_deployed/busy/stale_lock/incomplete/unreachable/orphaned/drifted。
  rollback   先全量预校验，再按中转 -> 出口机顺序事务拆除专属资源。
  conns      只读列出中转端口上各来源 IP 的连接数、空闲秒数、是否在黑名单，以及 proxyd fd 用量。
  kick       用 ss -K 销毁指定来源 IP 在中转端口上的全部已建连接（客户端会自动重连）。
  ban        把 IP/网段加入持久黑名单：本地 blacklist.txt + 中转受管 drop-in（IPAddressDeny=），
             daemon-reload 后立即生效并顺带 kick；重复 ban 幂等。
  unban      从黑名单移除；列表为空时删除中转 drop-in，恢复"无 drop-in"契约。
  banlist    只读对照本地黑名单与中转两个 unit 的 IPAddressDeny 回读值，不一致返回 5。
  rehost-exit  出口机同机换 IP：先在 config 改 EXIT_HOST / EXPECTED_EXIT_IPV4，再原地迁移
             中转转发目标与两端 owner、本地 state，最后自动完整 verify。要求新 IP 的主机指纹与 state
             一致（同一台机）；UUID、密钥、端口、客户端订阅都不变；中途失败可重跑，已迁移时输出 noop。

参数:
  --config <路径>       仓库外 600 regular file，格式见 chain.example.env（init 会自动生成）。
  --id <名字>           --config 的简写，与 --config 二选一。
  init 的参数：--relay / --exit 两台机器的 IPv4（不给则交互提问）；--id 配置名，默认 main；
                --relay-port / --exit-port SSH 端口，默认 22；--sni Reality 伪装域名，默认 www.amazon.com；
                --exit-source-filter 出口机 Reality 端口如何只放行中转：managed（默认，本项目加 nft 白名单）、
                provider（服务商安全组负责）、none（不限制）；managed / provider 时部署严格检查。
  --with-fail-closed    仅可跟在 verify 后；会短暂停止本 chain 并验证新连接失败。
  <ipv4>                kick 只接受点分 IPv4；ban/unban 另接受 CIDR，且主机位必须为 0（如 198.51.100.0/24）。
  -h, --help            显示本帮助并返回 0，不读取配置、不连接远端。

前置:
  控制端 macOS 或 Linux（含 WSL），Bash 3.2+；两端 Linux 同为 amd64 或 arm64；root 免密 SSH；known_hosts 中已有 ed25519 host key（init 会配好这两项）；
  出口机的安全组允许中转来源（provider 时还必须拒绝其它来源）；出口机除 ownexit_* 白名单表外没有防火墙规则；远端防火墙为空且所需命令已安装。
  连接治理命令要求链已 deploy 且无 incomplete transaction；kick 依赖中转内核 ss -K，
  ban 依赖中转 cgroup v2 + systemd IPAddressDeny=（cgroup BPF，非防火墙）。

典型用法:
  $(basename "${SCRIPT_PATH}") init --relay 203.0.113.10 --exit 203.0.113.20
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
      deploy)
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
      --relay) [[ "$#" -ge 2 ]] || die 2 '--relay 需要 IPv4'; INIT_RELAY="$2"; shift 2 ;;
      --exit) [[ "$#" -ge 2 ]] || die 2 '--exit 需要 IPv4'; INIT_EXIT="$2"; shift 2 ;;
      --id) [[ "$#" -ge 2 ]] || die 2 '--id 需要名字'; INIT_ID="$2"; shift 2 ;;
      --relay-port)
        [[ "$#" -ge 2 && "$2" =~ ^[1-9][0-9]{0,4}$ ]] && (( $2 <= 65535 )) || die 2 '--relay-port 必须是 1-65535'
        INIT_RELAY_PORT="$2"; shift 2 ;;
      --exit-port)
        [[ "$#" -ge 2 && "$2" =~ ^[1-9][0-9]{0,4}$ ]] && (( $2 <= 65535 )) || die 2 '--exit-port 必须是 1-65535'
        INIT_EXIT_PORT="$2"; shift 2 ;;
      --exit-source-filter)
        [[ "$#" -ge 2 && ( "$2" == managed || "$2" == provider || "$2" == none ) ]] || die 2 '--exit-source-filter 只能是 managed、provider 或 none'
        INIT_EXIT_SOURCE_FILTER="$2"; shift 2 ;;
      --sni)
        [[ "$#" -ge 2 && "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || die 2 '--sni 必须是 ASCII 域名'
        INIT_SNI="$2"; shift 2 ;;
      *) die 2 "init 不认识的参数：$1" ;;
    esac
  done
}

parse_args() {
  if [[ "$#" -eq 1 && ( "$1" == '-h' || "$1" == '--help' ) ]]; then
    usage
    exit 0
  fi
  if [[ "${1:-}" == init ]]; then
    COMMAND=init
    shift
    parse_init_args "$@"
    return 0
  fi
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
    *) die 2 '首个参数必须是 init、--config 或 --id' ;;
  esac
  [[ "$3" != --config && "$3" != --id ]] || die 2 '--config 与 --id 只能二选一'
  COMMAND="$3"
  shift 3
  case "${COMMAND}" in
    preflight|deploy|status|rollback|conns|banlist|rehost-exit)
      [[ "$#" -eq 0 ]] || die 2 "${COMMAND} 不接受额外参数"
      ;;
    verify)
      if [[ "$#" -eq 1 && "$1" == '--with-fail-closed' ]]; then
        WITH_FAIL_CLOSED=1
      elif [[ "$#" -ne 0 ]]; then
        die 2 'verify 只接受可选的 --with-fail-closed'
      fi
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
  [[ "${RELAY_COHOSTS_SINGBOX}" == 'yes' || "${RELAY_COHOSTS_SINGBOX}" == 'no' ]] || die 2 'RELAY_COHOSTS_SINGBOX 只能是 yes 或 no'
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

ssh_relay() {
  run_managed_external ssh ssh -n -F "${SSH_CONFIG}" chain-relay "$@"
}

ssh_exit() {
  run_managed_external ssh ssh -n -F "${SSH_CONFIG}" chain-exit "$@"
}

ssh_relay_stdin() {
  run_managed_external ssh ssh -F "${SSH_CONFIG}" chain-relay "$@"
}

ssh_exit_stdin() {
  run_managed_external ssh ssh -F "${SSH_CONFIG}" chain-exit "$@"
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
  local alias debug_file fingerprint rc
  alias="$1"
  debug_file="${OP_TMP}/ssh-target-debug.${alias}.${LOCK_OPERATION_ID}"
  [[ ! -e "${debug_file}" && ! -L "${debug_file}" ]] || return 1
  ( set -o noclobber; : > "${debug_file}" ) 2>/dev/null || return 1
  chmod 600 "${debug_file}" || return 1
  # ProxyJump 子进程会继承 verbose 等级，但不会继承外层 ssh 的 LogFile；因此 -E 文件只含目标会话日志，
  # 避免从合并 stderr 的第一条 `Server host key` 误取中转机指纹。
  if run_managed_external ssh ssh -vv -E "${debug_file}" -n -F "${SSH_CONFIG}" "${alias}" true >/dev/null 2>&1; then
    rc=0
  else
    rc="$?"
  fi
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
  for command_name in ssh scp ssh-keygen curl openssl tar ps mktemp mkfifo stat readlink link ln sync awk sed grep sort tr head tail cmp find chmod mkdir rmdir rm cp mv cut cat date sleep uname kill dirname basename id git ${platform_commands}; do
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

  load_state="$(systemctl show sing-box.service -p LoadState --value 2>/dev/null || true)"
  config_seen=no
  [[ -e /etc/sing-box || -L /etc/sing-box ]] && config_seen=yes
  process_seen=no
  for proc_exe in /proc/[0-9]*/exe; do
    resolved="$(readlink -f "$proc_exe" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || continue
    case "$(basename "$resolved")" in
      sing-box|sing-box-*) process_seen=yes; break ;;
    esac
  done
  if [[ "$cohosts" == yes ]]; then
    [[ "$load_state" == loaded && "$config_seen" == yes && "$process_seen" == yes ]] || fail '声明 co-host，但既有 sing-box 配置、进程或 unit 缺失'
    [[ -d /etc/sing-box && ! -L /etc/sing-box ]] || fail '既有 /etc/sing-box 目录身份不安全'
    config_mode="$(stat -c %a /etc/sing-box)"
    (( (8#$config_mode & 8#022) == 0 )) || fail '既有 /etc/sing-box 可被 group/other 写'
    [[ "$(systemctl is-active sing-box.service 2>/dev/null || true)" == active ]] || fail '既有 sing-box service 非 active'
    pid="$(systemctl show sing-box.service -p MainPID --value)"
    [[ "$pid" =~ ^[1-9][0-9]*$ && -d "/proc/$pid" ]] || fail '既有 sing-box MainPID 无效'
    exe="$(readlink -f "/proc/$pid/exe")"
    [[ -f "$exe" && ! -L "$exe" ]] || fail '既有 sing-box executable 不安全'
  else
    [[ "$load_state" == not-found && "$config_seen" == no && "$process_seen" == no ]] || fail '声明全新中转，但发现既有 sing-box 配置、进程或 unit'
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
    31) die 3 '中转依赖、防火墙或角色声明预检失败' ;;
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

pid="$(systemctl show sing-box.service -p MainPID --value)"
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
  printf 'EXECSTART_SHA256=%s\n' "$(systemctl show sing-box.service -p ExecStart --value | sha256sum | awk '{print $1}')"
  fragment="$(systemctl show sing-box.service -p FragmentPath --value)"
  [[ -n "$fragment" ]] && metadata "$fragment"
  systemctl show sing-box.service -p DropInPaths --value | tr ' ' '\n' | sed '/^$/d' | while IFS= read -r item; do metadata "$item"; done
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
printf 'ACTIVE=%s\n' "$(systemctl is-active sing-box.service)"
printf 'ENABLED=%s\n' "$(systemctl is-enabled sing-box.service 2>/dev/null || true)"
COLLECT_BASELINE
  chmod 600 "${script}"
  if output="$(ssh_relay_stdin bash -s < "${script}")"; then
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
[[ -d "$stage" && ! -L "$stage" && "$(stat -c %u:%g:%a "$stage")" == 0:0:700 ]] || exit 81
[[ "$(sha256sum "$stage/stage-owner.env" | awk '{print $1}')" == "$stage_owner_hash" ]] || exit 82
[[ -f "$binary" && ! -L "$binary" && "$(stat -c %u:%g:%a "$binary")" == 0:0:755 ]] || exit 83
set +x
keypair="$("$binary" generate reality-keypair)"
private_key="$(printf '%s\n' "$keypair" | awk -F': ' '$1 == "PrivateKey" {print $2}')"
public_key="$(printf '%s\n' "$keypair" | awk -F': ' '$1 == "PublicKey" {print $2}')"
uuid="$("$binary" generate uuid)"
short_id="$("$binary" generate rand --hex 8)"
[[ "$private_key" =~ ^[A-Za-z0-9_-]+$ && "$public_key" =~ ^[A-Za-z0-9_-]+$ ]] || exit 84
[[ "$uuid" =~ ^[0-9a-f-]{36}$ && "$short_id" =~ ^[0-9a-f]{16}$ ]] || exit 85

config="$stage/$chain_id.exit.json"
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
    "users": [{ "uuid": "$uuid", "flow": "xtls-rprx-vision" }],
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
printf 'VLESS_UUID=%s\n' "$uuid"
printf 'REALITY_PUBLIC_KEY=%s\n' "$public_key"
printf 'REALITY_SHORT_ID=%s\n' "$short_id"
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
  output="$(ssh_exit_stdin bash -s -- "${EXIT_STAGE_PATH}" "${EXIT_STAGE_OWNER_SHA256}" "${REMOTE_BIN}" "${CHAIN_ID}" "${EXIT_REALITY_PORT}" "${REALITY_SERVER_NAME}" "${owner_b64}" "${EXIT_SOURCE_FILTER}" "${EXIT_NFT_PATH:--}" "${relay_source}" < "${script}")" || die 1 '出口机 Reality config/unit staging 失败'
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
  remote_platform_preflight
  probe_exit_tls
  probe_exit_exit
  verify_remote_resources yes || die 5 '远端文件、unit、进程、listener 或 binary 发生 drift'
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
  require_local_dependencies
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
  verify_remote_resources no || die 6 'rollback 预校验发现远端 drift'
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
    "${CHAIN_STATE_DIR}"/.transaction.env.*.tmp; do
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
  operation_tmp_owner_matches "${OP_TMP}" "${LOCK_OPERATION_ID}" "${CONFIG_SHA256}" || return 1
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

init_chain() {
  local relay exit_host chain_id relay_port exit_port sni relay_key exit_key exit_ip answer cohost probe
  local load_state config_seen process_seen config_file tmp_file
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

  # 中转现状：判定方式与 preflight 远端脚本一致（unit LoadState、/etc/sing-box、sing-box 进程），三者一致才自动填。
  probe="$(ssh -n -i "${relay_key}" -p "${relay_port}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=12 \
    root@"${relay}" 'ls=$(systemctl show sing-box.service -p LoadState --value 2>/dev/null || true); cs=no; { [ -e /etc/sing-box ] || [ -L /etc/sing-box ]; } && cs=yes; ps=no; for e in /proc/[0-9]*/exe; do r=$(readlink -f "$e" 2>/dev/null || true); case "${r##*/}" in sing-box|sing-box-*) ps=yes; break;; esac; done; printf "%s %s %s\n" "${ls:-unknown}" "$cs" "$ps"' 2>/dev/null || true)"
  read -r load_state config_seen process_seen <<EOF
${probe}
EOF
  if [[ "${load_state}" == loaded && "${config_seen}" == yes && "${process_seen}" == yes ]]; then
    cohost=yes
  elif [[ "${load_state}" == not-found && "${config_seen}" == no && "${process_seen}" == no ]]; then
    cohost=no
  else
    die 3 "中转机上的 sing-box 状态不完整（unit=${load_state:-未知} 配置目录=${config_seen:-未知} 进程=${process_seen:-未知}）；请先让它完整运行或彻底移除，再重跑 init"
  fi
  log_info "中转机已有 sing-box：${cohost}（RELAY_COHOSTS_SINGBOX=${cohost}，deploy 会保护它不受影响）"
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
  printf '[chain][init] next=%s --id %s deploy\n' "$(basename "${SCRIPT_PATH}")" "${chain_id}"
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
  parse_config
  init_paths
  OPERATION_ID="$(random_hex_128)"
  LOCK_OPERATION_ID="${OPERATION_ID}"
  trap 'cleanup_dispatcher $? EXIT' EXIT
  trap 'cleanup_dispatcher 130 INT' INT
  trap 'cleanup_dispatcher 143 TERM' TERM
  init_operation_tmp

  case "${COMMAND}" in
    preflight)
      preflight_chain
      ;;
    deploy)
      deploy_chain
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
  esac
}

main "$@"
