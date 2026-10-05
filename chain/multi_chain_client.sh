#!/usr/bin/env bash
# multi_chain_client.sh —— 多链客户端聚合：把多条已 deploy 的链（每台中转机一条、共用同一台出口机）的节点
# 聚合成一组客户端产物，客户端用 fallback 组在中转机之间自动切换；某台中转被墙时无需人工换节点。
#
# 架构：客户端 → 中转机 A / B / …（各自一条 chain，systemd-socket-proxyd 转发）→ 同一台出口机出口机。
# 本脚本完全不连中转机与出口机，只读本机 chain 产物（env + node.txt），写自己的产物目录。
#
# 前置:
#   - 控制端 macOS（Apple 芯片 / Intel）或 Linux（amd64 / arm64，含 WSL），/bin/bash 3.2 及以上；必须从本仓库 Git worktree 内执行（git 是读取真实配置前的防泄漏闸门依赖）。
#   - --chains 里每个 CHAIN_ID 都已由 setup_chain.sh deploy 且 status=deployed/healthy：
#     本脚本按固定路径读 ${XDG_CONFIG_HOME:-~/.config}/ownexit/chains/<id>.env（只取 CHAIN_ID / RELAY_HOST / EXPECTED_EXIT_IPV4）
#     与 ${XDG_STATE_HOME:-~/.local/state}/ownexit/chains/<id>/client/node.txt（只读）。各链的 EXPECTED_EXIT_IPV4 必须相同。
#   - 本机依赖：route nc curl openssl tar git shasum（或 openssl dgst）；render 生成二维码时另需 qrencode（--no-qr 可免）。
#   - 不修改 setup_chain.sh 的任何状态（state.env / node.txt 只读），不写 known_hosts，不改出口机白名单，不改防火墙。
# 调用方：由使用者直接执行；不应被 source。

set -euo pipefail

umask 077
export LC_ALL=C

# 以下常量与 chain/setup_chain.sh 顶部的 SING_BOX_VERSION / ARCHIVE_SHA256_* / BINARY_SHA256_* / RELEASE_BASE_URL 保持同步
# （改版本先改那边，再同步这里）。verify 要在本机起 sing-box 做真实握手，按本机平台选包。
readonly SING_BOX_VERSION='1.13.14'
readonly ARCHIVE_SHA256_LINUX_AMD64='f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697'
readonly BINARY_SHA256_LINUX_AMD64='68aeab83cc4ab2659a5b92232261a20746ccdafc3b3d1e19b2d63247eec3bbf7'
readonly ARCHIVE_SHA256_LINUX_ARM64='4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e'
readonly BINARY_SHA256_LINUX_ARM64='85f570b96754cd7c354d28e50f66e9340b374e06b5d77ec9e15e8d04f0c87a25'
readonly ARCHIVE_SHA256_DARWIN_AMD64='5245d645e847f90bb708da74bc020ae078c28489690756419685c04f56b4e3bb'
readonly BINARY_SHA256_DARWIN_AMD64='9e550c4cc3bdb8a6f3525bbaaf97624f517d1e37e0d5c76a439988483a5b27a6'
readonly ARCHIVE_SHA256_DARWIN_ARM64='73e8967b0fc08e17bce4263ca56ebc394822401a16497a1c4e02316c888202ab'
readonly BINARY_SHA256_DARWIN_ARM64='813d8effd02a19572a8d75aef29fc073101404ca535b2496be86f21827c7684d'
readonly RELEASE_BASE_URL='https://github.com/SagerNet/sing-box/releases/download/v1.13.14'
readonly LOG_TAG='[multi-chain-client]'
readonly AUTO_GROUP_NAME='Exit-Relay-auto'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT=''

COMMAND=''
CHAINS_ARG=''
AGG_NAME='all'
GROUP_TYPE='fallback'
TEST_URL='https://www.gstatic.com/generate_204'
INTERVAL_SEC='300'
QR_OUT=''
OPEN_DIR=1
NO_QR=0

CONFIG_HOME=''
STATE_HOME=''
CACHE_HOME=''
OUT_DIR=''
OP_TMP=''

# 链记录：每行 "id|host|port|uuid|sni|pbk|sid|name"，顺序 = --chains 顺序 = fallback 优先级；
# 凭据逐链各异，任何字段都不得重新生成（否则与该链出口机侧凭据不匹配）。
CHAIN_RECORDS=''
CHAIN_COUNT=0
# 所有链共用的出口 IP：verify 的唯一允许值；跨链不一致直接退出 2。
EXPECTED_EXIT_IPV4=''

# 临时 sing-box 进程 pid 登记文件（OP_TMP 下，每行一个）。verify_one 在命令替换子 shell 里运行，改变量父进程看不到，
# 所以必须经文件登记，EXIT trap 才能在异常退出（如 Ctrl-C 命中 curl 窗口）时杀掉遗留进程。
TEMP_PID_FILE=''
DARWIN_BINARY_PATH=''

usage() {
  cat <<EOF
用法:
  $(basename "${SCRIPT_PATH}") --chains <id>[,<id>...] [--name <聚合名>] verify
  $(basename "${SCRIPT_PATH}") --chains <id>[,<id>...] [--name <聚合名>] render [--group fallback|url-test] [--test-url <url>]
                                   [--interval <秒>] [--qr-out <新目录>] [--no-open] [--no-qr]
  $(basename "${SCRIPT_PATH}") -h | --help

作用:
  verify        从本机对每条链的入口各做一次真实 Reality 握手 + 出口 IP 三端点仲裁（至少 2 个端点成功且都等于
                EXPECTED_EXIT_IPV4）；到该入口的路由经 TUN（本机代理的 TUN 模式开着）时该链标 skipped。
  render        聚合各链 node.txt：nodes.txt（每链一行 vless URI，原文）、clash-snippet.yaml（proxies + 自动组，
                供 Clash Verge 手工 merge）、每链一张二维码（iPhone Shadowrocket，放临时私有目录）。

参数:
  --chains <列表>      必填；逗号分隔的 CHAIN_ID（各 [a-z0-9][a-z0-9-]{0,31}，不重复），顺序即自动组优先级（第一条优先）。
                       每个 id 固定读 \${XDG_CONFIG_HOME:-~/.config}/ownexit/chains/<id>.env 与
                       \${XDG_STATE_HOME:-~/.local/state}/ownexit/chains/<id>/client/node.txt。
  --name <聚合名>      产物目录名，默认 all（[a-z0-9][a-z0-9-]{0,31}）。
  --group <类型>       自动组类型，默认 fallback（当前节点超时时按顺序取第一个可用）；可选 url-test。
  --test-url <url>     自动组健康检查地址，默认 https://www.gstatic.com/generate_204。
  --interval <秒>      自动组健康检查间隔，默认 300。
  --qr-out <目录>      二维码输出目录，必须不存在（已存在/断开的符号链接都拒绝，不覆盖）；默认在 \${TMPDIR:-/tmp} 下新建。
  --no-open            生成二维码后不自动打开目录。
  --no-qr              不生成二维码（不要求 qrencode）。
  -h, --help           显示本帮助并返回 0，不读取配置。

产物（render）:
  \${XDG_STATE_HOME:-~/.local/state}/ownexit/multi-chain-client/<聚合名>/nodes.txt
  \${XDG_STATE_HOME:-~/.local/state}/ownexit/multi-chain-client/<聚合名>/clash-snippet.yaml
  <二维码目录>/qr-<n>-<节点名>.png（含明文凭据，扫完即删）
  节点名 = 各链 node.txt 里的 Exit-via-Relay-<id>；自动组名 Exit-Relay-auto。终端不打印 uuid / pbk / sid / 完整 URI。

退出码:
  0 成功；2 参数 / env / node.txt 校验错误、EXPECTED_EXIT_IPV4 跨链不一致；5 verify 有链不健康或全部 skipped；
  1 运行时失败（本机依赖缺失、渲染）。

典型用法:
  $(basename "${SCRIPT_PATH}") --chains main,backup verify
  $(basename "${SCRIPT_PATH}") --chains main,backup render --no-open
  $(basename "${SCRIPT_PATH}") --chains main,backup render --group url-test --no-qr
  $(basename "${SCRIPT_PATH}") --chains main,backup --name home render --qr-out ~/Desktop/chain-qr

安全边界:
  不连中转机与出口机，不改 setup_chain.sh 的 state / node.txt / 远端资源，不写 known_hosts。
  产物 600、目录 700；二维码含明文凭据，扫完请按提示删除目录。
EOF
}

log_info() { printf '%s INFO %s\n' "${LOG_TAG}" "$*" >&2; }
log_warn() { printf '%s WARN %s\n' "${LOG_TAG}" "$*" >&2; }

# 退出码是对外契约（见 usage）：2 本地校验 / 5 verify 不健康 / 1 运行时；调用方按此区分"该改配置"还是"该看现场"。
die() {
  local code
  code="$1"
  shift
  printf '%s ERROR %s\n' "${LOG_TAG}" "$*" >&2
  exit "${code}"
}

# ---------- 以下 helper 与 chain/setup_chain.sh 保持同步（stat_uid/stat_mode/resolve_regular_path/require_secure_user_file/
# private_path_ancestors_safe/ensure_private_dir/xdg_or_default/sha256_file/is_ipv4 分别对应 :225-275、:289-344、:351-360、:207-215、:419-435）。 ----------

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

# 逐级 mkdir 而不是 mkdir -p 后 chmod：预置 symlink 会让 chmod 落到攻击者选的目标。
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

sha256_file() {
  local file
  file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    openssl dgst -sha256 "${file}" | awk '{print $NF}'
  fi
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

# ---------- 以上为同步复制段 ----------

cleanup() {
  local pid
  if [[ -n "${TEMP_PID_FILE}" && -f "${TEMP_PID_FILE}" ]]; then
    while IFS= read -r pid; do
      [[ "${pid}" =~ ^[0-9]+$ ]] || continue
      kill "${pid}" 2>/dev/null || true
    done < "${TEMP_PID_FILE}"
  fi
  if [[ -n "${OP_TMP}" && -d "${OP_TMP}" ]]; then
    rm -rf "${OP_TMP}"
  fi
}
trap cleanup EXIT

# ---------- 参数 ----------

parse_args() {
  local seen_command
  if [[ "$#" -eq 1 && ( "$1" == '-h' || "$1" == '--help' ) ]]; then
    usage
    exit 0
  fi
  [[ "$#" -ge 1 ]] || {
    usage >&2
    die 2 '参数不足；请用 --help 查看完整用法'
  }
  seen_command=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --chains)
        [[ "$#" -ge 2 && -n "${2:-}" ]] || die 2 '--chains 需要逗号分隔的 CHAIN_ID 列表'
        CHAINS_ARG="$2"; shift 2 ;;
      --name)
        [[ "$#" -ge 2 && "${2:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die 2 '--name 只允许 [a-z0-9][a-z0-9-]{0,31}'
        AGG_NAME="$2"; shift 2 ;;
      --group)
        [[ "${COMMAND}" == render ]] || die 2 '--group 只能跟在 render 后'
        [[ "$#" -ge 2 && ( "${2:-}" == fallback || "${2:-}" == url-test ) ]] || die 2 '--group 只接受 fallback 或 url-test'
        GROUP_TYPE="$2"; shift 2 ;;
      --test-url)
        [[ "${COMMAND}" == render ]] || die 2 '--test-url 只能跟在 render 后'
        [[ "$#" -ge 2 && "${2:-}" =~ ^https?://[A-Za-z0-9._/:@%+=~-]+$ ]] || die 2 '--test-url 必须是 http(s) URL 且不含空白/引号'
        TEST_URL="$2"; shift 2 ;;
      --interval)
        [[ "${COMMAND}" == render ]] || die 2 '--interval 只能跟在 render 后'
        [[ "$#" -ge 2 && "${2:-}" =~ ^[1-9][0-9]{0,5}$ ]] || die 2 '--interval 必须是正整数秒'
        INTERVAL_SEC="$2"; shift 2 ;;
      --qr-out)
        [[ "${COMMAND}" == render ]] || die 2 '--qr-out 只能跟在 render 后'
        [[ "$#" -ge 2 && -n "${2:-}" ]] || die 2 '--qr-out 需要目录'
        QR_OUT="$2"; shift 2 ;;
      --no-open)
        [[ "${COMMAND}" == render ]] || die 2 '--no-open 只能跟在 render 后'
        OPEN_DIR=0; shift ;;
      --no-qr)
        [[ "${COMMAND}" == render ]] || die 2 '--no-qr 只能跟在 render 后'
        NO_QR=1; shift ;;
      verify|render)
        [[ "${seen_command}" == 0 ]] || die 2 "重复的子命令：$1"
        COMMAND="$1"; seen_command=1; shift ;;
      -*) die 2 "未知参数：$1（用 --help 查看用法）" ;;
      *) die 2 "未知子命令：$1（只支持 verify / render）" ;;
    esac
  done
  [[ -n "${COMMAND}" ]] || die 2 '缺少子命令（verify / render）'
  [[ -n "${CHAINS_ARG}" ]] || die 2 '缺少 --chains'
}

# ---------- 本地依赖与配置 ----------

require_local_dependencies() {
  local command_name platform_commands
  case "$(uname -s)" in
    Darwin) platform_commands='route nc' ;;
    Linux) platform_commands='ip timeout' ;;
    *) die 1 "控制端只支持 macOS 与 Linux（当前：$(uname -s)）" ;;
  esac
  for command_name in ${platform_commands} curl openssl tar git awk sed grep sort tr head tail mktemp stat cut cat date sleep uname kill dirname basename id chmod mkdir rm cp mv wc; do
    command -v "${command_name}" >/dev/null 2>&1 || die 1 "本机缺少依赖：${command_name}"
  done
  command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 || die 1 '本机缺少 SHA-256 工具'
  if [[ "${COMMAND}" == render && "${NO_QR}" == 0 ]]; then
    command -v qrencode >/dev/null 2>&1 || die 1 '缺少 qrencode（brew install qrencode），或改用 --no-qr'
  fi
}

# 与 setup_chain.sh init_repo_root() 同步：真实配置不得位于仓库 worktree 内，git 不可用时先失败而不是跳过闸门。
init_repo_root() {
  REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)" || die 1 '无法确定脚本所属 Git worktree'
  [[ -n "${REPO_ROOT}" && -d "${REPO_ROOT}" && ! -L "${REPO_ROOT}" ]] || die 1 '脚本所属 Git worktree 身份异常'
}

reject_path_inside_repo() {
  case "$1" in
    "${REPO_ROOT}"|"${REPO_ROOT}"/*) die 2 "$2 必须位于 Git worktree 外：$1" ;;
  esac
}

init_paths() {
  CONFIG_HOME="$(xdg_or_default "${XDG_CONFIG_HOME:-}" "${HOME}/.config")"
  STATE_HOME="$(xdg_or_default "${XDG_STATE_HOME:-}" "${HOME}/.local/state")"
  CACHE_HOME="$(xdg_or_default "${XDG_CACHE_HOME:-}" "${HOME}/.cache")"
  # 产物目录与 chains/<id>/ 零交集：setup_chain.sh rollback 会 rmdir chains/<id>/client，里面多任何文件都会让它失败。
  OUT_DIR="${STATE_HOME}/ownexit/multi-chain-client/${AGG_NAME}"
  OP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/multi-chain-client.${AGG_NAME}.XXXXXX")"
  chmod 700 "${OP_TMP}"
  TEMP_PID_FILE="${OP_TMP}/temp-pids"
}

# 读一条链的 env：行文法与 setup_chain.sh parse_config（:485-512）同步（空行 / # 注释 / 严格 KEY=VALUE、拒 CR、值不含空白或控制字符、
# 键不重复），不校验键数、三键之外的键跳过。输出 "host|exit"。
read_chain_env() {
  local id path resolved line key value seen chain_id relay_host exit_ip
  id="$1"
  path="${CONFIG_HOME}/ownexit/chains/${id}.env"
  resolved="$(resolve_regular_path "${path}")" || die 2 "链 ${id} 的配置不存在或不是 regular file：${path}"
  require_secure_user_file "${resolved}" 600 || die 2 "链 ${id} 的配置必须由当前用户拥有且 mode 精确为 600：${resolved}"
  reject_path_inside_repo "${resolved}" "链 ${id} 的真实配置"
  seen=''
  chain_id=''
  relay_host=''
  exit_ip=''
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" != *$'\r'* ]] || die 2 "链 ${id} 的配置含 CR 控制字符"
    case "${line}" in
      '') continue ;;
      \#*) continue ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        [[ "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]] || die 2 "链 ${id} 的配置键格式错误"
        [[ -n "${value}" ]] || die 2 "链 ${id} 的配置值不能为空：${key}"
        if printf '%s' "${value}" | grep -q '[[:cntrl:][:space:]]'; then
          die 2 "链 ${id} 的配置值包含空白或控制字符：${key}"
        fi
        case "
${seen}
" in
          *"
${key}
"*) die 2 "链 ${id} 的配置键重复：${key}" ;;
        esac
        seen="${seen}
${key}"
        case "${key}" in
          CHAIN_ID) chain_id="${value}" ;;
          RELAY_HOST) relay_host="${value}" ;;
          EXPECTED_EXIT_IPV4) exit_ip="${value}" ;;
          *) ;;
        esac
        ;;
      *) die 2 "链 ${id} 的配置只允许空行、井号注释和 KEY=VALUE" ;;
    esac
  done < "${resolved}"
  [[ "${chain_id}" == "${id}" ]] || die 2 "链 ${id} 的配置里 CHAIN_ID 不等于文件名对应的 id（读到了别的链）"
  is_ipv4 "${relay_host}" || die 2 "链 ${id} 的 RELAY_HOST 缺失或不是 IPv4 字面量"
  is_ipv4 "${exit_ip}" || die 2 "链 ${id} 的 EXPECTED_EXIT_IPV4 缺失或不是 IPv4 字面量"
  printf '%s|%s\n' "${relay_host}" "${exit_ip}"
}

# 读一条链的 node.txt：它只在 setup_chain.sh render_node_artifact（:3689-3696）一处生成、模板固定；按模板逐字段拆，
# 任一字段不符即拒绝——防止读到别的链、手改过的产物，或把错误凭据聚合进所有客户端。输出 "port|uuid|sni|pbk|sid|name"。
read_chain_node() {
  local id relay_host state_dir node_file line rest uuid hostport host port query fragment expected_query sni pbk sid
  id="$1"
  relay_host="$2"
  state_dir="${STATE_HOME}/ownexit/chains/${id}"
  node_file="${state_dir}/client/node.txt"
  [[ -d "${state_dir}" && ! -L "${state_dir}" ]] || die 2 "链 ${id} 尚未 deploy（state 目录不存在）：${state_dir}"
  require_secure_user_file "${node_file}" 600 || die 2 "链 ${id} 的 node.txt 不存在或不是 600 regular file（已 rollback？）：${node_file}"
  [[ "$(wc -l < "${node_file}" | tr -d ' ')" == 1 ]] || die 2 "链 ${id} 的 node.txt 必须恰好一行"
  line="$(head -n 1 "${node_file}")"
  rest="${line#vless://}"
  [[ "${rest}" != "${line}" ]] || die 2 "链 ${id} 的 node.txt 不是 vless:// URI"
  uuid="${rest%%@*}"
  rest="${rest#*@}"
  hostport="${rest%%\?*}"
  rest="${rest#*\?}"
  host="${hostport%%:*}"
  port="${hostport#*:}"
  query="${rest%%#*}"
  fragment="${rest#*#}"
  [[ "${host}" == "${relay_host}" ]] || die 2 "链 ${id} 的 node.txt host 不等于其配置的 RELAY_HOST（产物已被改动或读错链）"
  [[ "${fragment}" == "Exit-via-Relay-${id}" ]] || die 2 "链 ${id} 的节点名不等于 Exit-via-Relay-${id}"
  [[ "${port}" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || die 2 "链 ${id} 的 node.txt 端口格式错误"
  # 与 setup_chain.sh 的 state 格式校验同步。
  [[ "${uuid}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 2 "链 ${id} 的 uuid 格式错误"
  [[ "${query}" =~ ^encryption=none\&flow=xtls-rprx-vision\&security=reality\&sni=([A-Za-z0-9.-]+)\&fp=chrome\&pbk=([A-Za-z0-9_-]+)\&sid=([0-9a-f]{16})\&type=tcp$ ]] \
    || die 2 "链 ${id} 的 node.txt query 与 render_node_artifact 模板不一致"
  sni="${BASH_REMATCH[1]}"
  pbk="${BASH_REMATCH[2]}"
  sid="${BASH_REMATCH[3]}"
  expected_query="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp"
  [[ "${query}" == "${expected_query}" ]] || die 2 "链 ${id} 的 node.txt query 与 render_node_artifact 模板不一致"
  printf '%s|%s|%s|%s|%s|%s\n' "${port}" "${uuid}" "${sni}" "${pbk}" "${sid}" "${fragment}"
}

load_chains() {
  local oldifs id env_fields node_fields host exit_ip count
  oldifs="${IFS}"
  IFS=,
  set -- ${CHAINS_ARG}
  IFS="${oldifs}"
  CHAIN_RECORDS=''
  count=0
  for id in "$@"; do
    [[ "${id}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die 2 "CHAIN_ID 格式错误：${id}"
    case "
${CHAIN_RECORDS}
" in
      *"
${id}|"*) die 2 "--chains 里 CHAIN_ID 重复：${id}" ;;
    esac
    env_fields="$(read_chain_env "${id}")"
    host="${env_fields%%|*}"
    exit_ip="${env_fields#*|}"
    if [[ -z "${EXPECTED_EXIT_IPV4}" ]]; then
      EXPECTED_EXIT_IPV4="${exit_ip}"
    elif [[ "${exit_ip}" != "${EXPECTED_EXIT_IPV4}" ]]; then
      die 2 "链 ${id} 的 EXPECTED_EXIT_IPV4 与前面的链不一致；本脚本只聚合共用同一出口机出口的链"
    fi
    node_fields="$(read_chain_node "${id}" "${host}")"
    if [[ -z "${CHAIN_RECORDS}" ]]; then
      CHAIN_RECORDS="${id}|${host}|${node_fields}"
    else
      CHAIN_RECORDS="${CHAIN_RECORDS}
${id}|${host}|${node_fields}"
    fi
    count="$((count + 1))"
  done
  (( count >= 1 )) || die 2 '--chains 为空'
  CHAIN_COUNT="${count}"
}

# 第 index 条链记录的第 field 个字段：1 id / 2 host / 3 port / 4 uuid / 5 sni / 6 pbk / 7 sid / 8 name。
chain_field() {
  printf '%s\n' "${CHAIN_RECORDS}" | sed -n "$1p" | cut -d'|' -f"$2"
}

# ---------- verify ----------

# 与 setup_chain.sh render_client_config（:3378 起）同步：sing-box 客户端 JSON 骨架，凭据逐链传入。
render_client_config() {
  local output local_port host port uuid sni pbk sid
  output="$1"; local_port="$2"; host="$3"; port="$4"; uuid="$5"; sni="$6"; pbk="$7"; sid="$8"
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
    "server": "${host}",
    "server_port": ${port},
    "uuid": "${uuid}",
    "flow": "xtls-rprx-vision",
    "tls": {
      "enabled": true,
      "server_name": "${sni}",
      "utls": { "enabled": true, "fingerprint": "chrome" },
      "reality": {
        "enabled": true,
        "public_key": "${pbk}",
        "short_id": "${sid}"
      }
    }
  }],
  "route": { "final": "exit-via-relay" }
}
EOF
  chmod 600 "${output}"
}

# 以下 4 个平台函数与 setup_chain.sh 的 local_platform / route_interface / interface_is_tunnel / tcp_probe 同步。
local_platform() {
  local os arch
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) return 0 ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) return 0 ;; esac
  printf '%s-%s\n' "${os}" "${arch}"
}

route_interface() {
  if [[ "$(uname -s)" == Darwin ]]; then
    route -n get "$1" 2>/dev/null | awk '/interface:/{print $2; exit}'
  else
    ip route get "$1" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
  fi
}

interface_is_tunnel() {
  case "$1" in utun*|tun*|wg*) return 0 ;; esac
  [[ "$(uname -s)" == Linux && -e "/sys/class/net/$1/tun_flags" ]]
}

tcp_probe() {
  if [[ "$(uname -s)" == Darwin ]]; then
    nc -4 -n -z -G "$3" "$1" "$2" >/dev/null 2>&1
  else
    timeout "$3" bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" >/dev/null 2>&1
  fi
}

# 准备本机平台的官方 sing-box：按链顺序找第一个 600 且哈希相等的 chain cache，都没有才下载到本脚本临时目录，绝不写 cache。
# verify 必须在本机做真实握手，本机平台没有官方包时直接失败（与 setup_chain.sh 部署时可跳过本机 smoke 不同）。
prepare_local_binary() {
  local platform archive archive_sha binary_sha index cache_path archive_path extract_root version_output
  platform="$(local_platform)"
  case "${platform}" in
    darwin-arm64) archive_sha="${ARCHIVE_SHA256_DARWIN_ARM64}"; binary_sha="${BINARY_SHA256_DARWIN_ARM64}" ;;
    darwin-amd64) archive_sha="${ARCHIVE_SHA256_DARWIN_AMD64}"; binary_sha="${BINARY_SHA256_DARWIN_AMD64}" ;;
    linux-amd64) archive_sha="${ARCHIVE_SHA256_LINUX_AMD64}"; binary_sha="${BINARY_SHA256_LINUX_AMD64}" ;;
    linux-arm64) archive_sha="${ARCHIVE_SHA256_LINUX_ARM64}"; binary_sha="${BINARY_SHA256_LINUX_ARM64}" ;;
    *) die 1 "本机平台（$(uname -s) $(uname -m)）没有 sing-box 官方包，无法做本机握手验证" ;;
  esac
  archive="sing-box-${SING_BOX_VERSION}-${platform}.tar.gz"
  archive_path=''
  index=1
  while (( index <= CHAIN_COUNT )); do
    cache_path="${CACHE_HOME}/ownexit/chains/$(chain_field "${index}" 1)/downloads/${archive}"
    if [[ -f "${cache_path}" && ! -L "${cache_path}" ]] && require_secure_user_file "${cache_path}" 600 \
      && [[ "$(sha256_file "${cache_path}")" == "${archive_sha}" ]]; then
      archive_path="${cache_path}"
      break
    fi
    index="$((index + 1))"
  done
  if [[ -z "${archive_path}" ]]; then
    archive_path="${OP_TMP}/${archive}"
    log_warn "各链缓存里都没有本机平台（${platform}）的 sing-box 官方包，从官方地址下载到临时目录（国内直连 GitHub 可能很慢）"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 --max-time 600 "${RELEASE_BASE_URL}/${archive}" -o "${archive_path}" || die 1 "下载 sing-box 官方包失败：${archive}"
    [[ "$(sha256_file "${archive_path}")" == "${archive_sha}" ]] || die 1 "sing-box 官方包摘要不符：${archive}"
  fi
  extract_root="${OP_TMP}/assets"
  mkdir "${extract_root}"
  tar -xzf "${archive_path}" -C "${extract_root}"
  DARWIN_BINARY_PATH="${extract_root}/sing-box-${SING_BOX_VERSION}-${platform}/sing-box"
  [[ -f "${DARWIN_BINARY_PATH}" && ! -L "${DARWIN_BINARY_PATH}" ]] || die 1 "官方包布局异常：${platform}"
  [[ "$(sha256_file "${DARWIN_BINARY_PATH}")" == "${binary_sha}" ]] || die 1 "binary 摘要不符：${platform}"
  chmod 700 "${DARWIN_BINARY_PATH}"
  version_output="$("${DARWIN_BINARY_PATH}" version | awk '/^sing-box version / {print $3; exit}')"
  [[ "${version_output}" == "${SING_BOX_VERSION}" ]] || die 1 '本机 binary 版本不符'
}

# 与 setup_chain.sh choose_local_port同步。
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

# 与 setup_chain.sh smoke_from_mac 同步的本机侧 smoke，差异：逐链分类返回而不是 die；
# 临时进程 pid 写进 TEMP_PID_FILE 供 EXIT trap 收尾（本函数在子 shell 里跑，改变量传不回父进程），不接入 chain 的 fifo gate / local-process 登记。
verify_one() {
  local index host interface local_port config log pid started success timeouts mismatch endpoint result rc
  index="$1"
  host="$(chain_field "${index}" 2)"
  interface="$(route_interface "${host}")"
  [[ -n "${interface}" ]] || { printf 'error|0\n'; return 0; }
  if interface_is_tunnel "${interface}"; then
    printf 'skipped|0\n'
    return 0
  fi
  local_port="$(choose_local_port)" || { printf 'error|0\n'; return 0; }
  config="${OP_TMP}/smoke-${index}.json"
  log="${OP_TMP}/smoke-${index}.log"
  render_client_config "${config}" "${local_port}" "${host}" "$(chain_field "${index}" 3)" "$(chain_field "${index}" 4)" \
    "$(chain_field "${index}" 5)" "$(chain_field "${index}" 6)" "$(chain_field "${index}" 7)"
  "${DARWIN_BINARY_PATH}" check -c "${config}" >/dev/null || { printf 'error|0\n'; return 0; }
  "${DARWIN_BINARY_PATH}" run -c "${config}" >"${log}" 2>&1 &
  pid="$!"
  printf '%s\n' "${pid}" >> "${TEMP_PID_FILE}"
  started=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
    if tcp_probe 127.0.0.1 "${local_port}" 1; then
      started=1
      break
    fi
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  if [[ "${started}" != 1 ]]; then
    kill "${pid}" 2>/dev/null || true
    printf 'error|0\n'
    return 0
  fi
  success=0
  timeouts=0
  mismatch=0
  for endpoint in https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip; do
    if result="$(env -i HOME="${OP_TMP}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" curl --disable --fail --silent --show-error --proxy "socks5h://127.0.0.1:${local_port}" --noproxy '' --max-time 15 "${endpoint}" 2>/dev/null | tr -d '[:space:]')"; then
      rc=0
    else
      rc="$?"
    fi
    if [[ "${rc}" -eq 28 ]]; then
      timeouts="$((timeouts + 1))"
    elif is_ipv4 "${result}"; then
      if [[ "${result}" == "${EXPECTED_EXIT_IPV4}" ]]; then
        success="$((success + 1))"
      else
        mismatch="$((mismatch + 1))"
      fi
    fi
  done
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  if (( mismatch > 0 )); then
    printf 'mismatch|%s\n' "${success}"
  elif (( success >= 2 )); then
    printf 'ok|%s\n' "${success}"
  elif (( success == 0 && timeouts == 3 )); then
    printf 'timeout|0\n'
  else
    printf 'blocked|%s\n' "${success}"
  fi
}

cmd_verify() {
  local index outcome result endpoints started_at elapsed unhealthy skipped
  unhealthy=0
  skipped=0
  prepare_local_binary
  index=1
  while (( index <= CHAIN_COUNT )); do
    started_at="$(date '+%s')"
    outcome="$(verify_one "${index}")"
    result="${outcome%%|*}"
    endpoints="${outcome#*|}"
    elapsed="$(( $(date '+%s') - started_at ))"
    printf '%s verify chain=%s addr=%s result=%s endpoints=%s/3 elapsed=%ss\n' \
      "${LOG_TAG}" "$(chain_field "${index}" 1)" "$(chain_field "${index}" 2)" "${result}" "${endpoints}" "${elapsed}"
    case "${result}" in
      ok) ;;
      skipped) skipped="$((skipped + 1))" ;;
      *) unhealthy="$((unhealthy + 1))" ;;
    esac
    index="$((index + 1))"
  done
  if (( skipped == CHAIN_COUNT )); then
    die 5 '本机到全部链入口的路由都经过 TUN（代理软件的 TUN 模式开着），本次未验证任何链；关闭 TUN 后重跑 verify'
  fi
  (( skipped == 0 )) || log_warn "${skipped} 条链因路由经 TUN 未验证（skipped 不计入失败，但也不算通过）"
  (( unhealthy == 0 )) || die 5 "${unhealthy} 条链不健康（见上方逐行结果）"
  log_info "verify 通过；链 ${CHAIN_COUNT} 条（skipped ${skipped}）"
}

# ---------- render ----------

# 第 index 条链的 vless URI：与 setup_chain.sh render_node_artifact（:3735 起）逐字同模板，字段全部来自该链 node.txt（等价于原文）。
node_uri() {
  local index
  index="$1"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$(chain_field "${index}" 4)" "$(chain_field "${index}" 2)" "$(chain_field "${index}" 3)" "$(chain_field "${index}" 5)" \
    "$(chain_field "${index}" 6)" "$(chain_field "${index}" 7)" "$(chain_field "${index}" 8)"
}

# mihomo proxies 条目，字段镜像 direct/setup_direct.sh 渲染 clash.yaml 的 proxies 段（udp: true 只是沿用既有订阅写法，chain 不承诺 UDP）。
render_proxy_entry() {
  local index
  index="$1"
  cat <<EOF
  - name: $(chain_field "${index}" 8)
    type: vless
    server: $(chain_field "${index}" 2)
    port: $(chain_field "${index}" 3)
    uuid: $(chain_field "${index}" 4)
    udp: true
    tls: true
    servername: $(chain_field "${index}" 5)
    client-fingerprint: chrome
    flow: xtls-rprx-vision
    reality-opts:
      public-key: $(chain_field "${index}" 6)
      short-id: "$(chain_field "${index}" 7)"
EOF
}

render_proxies_block() {
  local index
  index=1
  while (( index <= CHAIN_COUNT )); do
    render_proxy_entry "${index}"
    index="$((index + 1))"
  done
}

render_entry_names() {
  local index
  index=1
  while (( index <= CHAIN_COUNT )); do
    printf '      - %s\n' "$(chain_field "${index}" 8)"
    index="$((index + 1))"
  done
}

# 自动组：fallback = 当前节点超时时按顺序取第一个可用（--chains 第一条排首位 → 它可用时行为与单节点一致）；
# url/interval 显式写出，lazy 等其余字段用 mihomo 默认。
render_auto_group() {
  cat <<EOF
  - name: ${AUTO_GROUP_NAME}
    type: ${GROUP_TYPE}
    url: ${TEST_URL}
    interval: ${INTERVAL_SEC}
    proxies:
EOF
  render_entry_names
}

render_clash_snippet() {
  {
    printf '# 由 multi_chain_client.sh render 生成：聚合 %s 条链（%s）。合并进 Clash Verge 配置前先删除同名的旧单节点。\n' "${CHAIN_COUNT}" "${CHAINS_ARG}"
    printf 'proxies:\n'
    render_proxies_block
    printf '\nproxy-groups:\n'
    render_auto_group
  } > "$1"
  chmod 600 "$1"
}

# 二维码纪律：先校验后建目录、目录已存在（含断开的符号链接）即拒绝不覆盖、
# URI 走 stdin 交给 qrencode（不进 argv，ps 看不到凭据）。
render_qr_codes() {
  local target index name png uri
  if [[ -n "${QR_OUT}" ]]; then
    # mkdir 对已存在的目录项（包括断开的符号链接）直接失败，且不做任何路径预处理，交给内核逐段解析——这就是"拒绝覆盖"的全部实现。
    mkdir -m 700 "${QR_OUT}" 2>/dev/null || die 1 "二维码输出目录已存在或无法创建（不覆盖）：${QR_OUT}"
    target="${QR_OUT}"
  else
    target="$(mktemp -d "${TMPDIR:-/tmp}/multi-chain-client-qr.XXXXXX")"
    chmod 700 "${target}"
  fi
  index=1
  while (( index <= CHAIN_COUNT )); do
    name="$(chain_field "${index}" 8)"
    png="${target}/qr-${index}-${name}.png"
    uri="$(node_uri "${index}")"
    if ! printf '%s' "${uri}" | qrencode -s 10 -m 3 -o "${png}" 2>"${OP_TMP}/qrencode.err"; then
      rm -rf "${target}"
      die 1 "qrencode 生成链 $(chain_field "${index}" 1) 失败：$(head -c 200 "${OP_TMP}/qrencode.err")"
    fi
    chmod 600 "${png}"
    log_info "已生成二维码 链=$(chain_field "${index}" 1) 节点=${name} → ${png}"
    index="$((index + 1))"
  done
  printf '%s\n' "${target}"
}

cmd_render() {
  local nodes snippet index qr_dir
  ensure_private_dir "${OUT_DIR}" || die 1 "产物目录身份或权限不安全：${OUT_DIR}"
  nodes="${OUT_DIR}/nodes.txt"
  snippet="${OUT_DIR}/clash-snippet.yaml"
  {
    index=1
    while (( index <= CHAIN_COUNT )); do
      node_uri "${index}"
      index="$((index + 1))"
    done
  } > "${nodes}"
  chmod 600 "${nodes}"
  render_clash_snippet "${snippet}"
  log_info "render 完成；name=${AGG_NAME} 链 ${CHAIN_COUNT} 条（${CHAINS_ARG}） group=${GROUP_TYPE}"
  printf '%s render nodes=%s\n' "${LOG_TAG}" "${nodes}"
  printf '%s render clash_snippet=%s\n' "${LOG_TAG}" "${snippet}"
  if [[ "${NO_QR}" == 0 ]]; then
    qr_dir="$(render_qr_codes)"
    printf '%s render qr_dir=%s\n' "${LOG_TAG}" "${qr_dir}"
    log_info "iPhone Shadowrocket 逐张扫码导入；扫完删除（PNG 含明文凭据）：rm -rf '${qr_dir}'"
    if [[ "${OPEN_DIR}" == 1 ]] && command -v open >/dev/null 2>&1; then
      open "${qr_dir}" || true
    fi
  fi
}

# ---------- main ----------

main() {
  parse_args "$@"
  require_local_dependencies
  init_repo_root
  init_paths
  load_chains
  case "${COMMAND}" in
    verify) cmd_verify ;;
    render) cmd_render ;;
  esac
}

main "$@"
