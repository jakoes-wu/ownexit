#!/usr/bin/env bash
# doctor.sh —— ownexit 诊断：检查本机环境、已记住的直连 VPS、已配置的链，可选在出口服务器上做出口 IP 体检。
#
# 前置:
#   - 在本机（macOS / Linux / WSL）运行，bash 3.2 及以上；需要 ssh、awk、sed、grep，macOS 另需 route，Linux 另需 ip。
#   - 不需要密码：只用已有的免密密钥（~/.ssh/ownexit/），连不上就报 FAIL，不会交互。
#   - 读直连目标 ${XDG_CONFIG_HOME:-~/.config}/ownexit/direct/*.env（经同目录 target_lib.sh）与
#     链配置 <配置目录>/ownexit/chains/*.env（按链式脚本的 XDG 规则；按行解析，不 source）。
#   - 链的检查调用同包内 ../chain/setup_chain.sh status：它会给该链加排他操作锁（约 10-30 秒，期间同一条链的
#     deploy / verify 会得到 busy），并可能在中转机执行一次幂等的 systemctl start。
#   - 不修改服务器配置，不改本机配置与状态文件，不写 known_hosts（SSH 用 -F /dev/null 与 StrictHostKeyChecking=yes）。
#     --scan-sni 会在服务器 /tmp 下临时建目录、临时运行只监听 127.0.0.1 的 sing-box，结束即删。
#   - 不应被 source。
#
# 设计：docs/feature/feature-doctor-ipcheck.md。

set -euo pipefail

usage() {
  cat <<'EOF'
用法: doctor.sh [选项]

检查本机环境、已记住的直连 VPS 和已配置的链，逐项输出 [OK] / [WARN] / [FAIL] 与处理建议。

选项:
  --host <ip>        只检查这一台直连 VPS（默认检查全部已记住的 VPS 与全部链）
  --port <n>         配合 --host：SSH 端口，默认 22
  --user <u>         配合 --host：SSH 用户，默认 root
  --chain <id>       只检查这一条链（可与 --host 同用）
  --ip-check         另在每台出口服务器上做出口 IP 体检（直连 = VPS 本身，链式 = 出口机）
  --scan-sni         另在每台出口服务器上扫描伪装域名：对候选域名逐个做真实 Reality 握手（服务器 /tmp 下临时建目录、
                     临时运行只监听 127.0.0.1 的 sing-box，结束即删）
  --sni-candidates <a.com,b.com>  配合 --scan-sni：只测这些域名（最多 30 个），默认测内置的 15 个
  --local-only       只检查本机，不连接任何服务器（不能与 --host / --chain / --ip-check / --scan-sni 同用）
  -h, --help         显示帮助

示例:
  ownexit doctor
  ownexit doctor --local-only
  ownexit doctor --ip-check
  ownexit doctor --host 203.0.113.7 --ip-check
  ownexit doctor --chain main
  ownexit doctor --scan-sni
  ownexit doctor --chain main --scan-sni --sni-candidates www.amazon.com,www.apple.com

说明:
  - 链的检查运行 `ownexit chain --id <名字> status`，期间同一条链的其它命令会提示 busy。
  - 出口 IP 体检结果仅供参考，以各服务实际为准；不计入 OK / WARN / FAIL 汇总。

退出码: 0 没有 FAIL（可以有 WARN）；1 至少一项 FAIL；2 参数错误。
EOF
}

die() { echo "[!] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=target_lib.sh
. "${SCRIPT_DIR}/target_lib.sh"
CHAIN_SCRIPT="${SCRIPT_DIR}/../chain/setup_chain.sh"

HOST=""
SSH_PORT="22"
SSH_USER="root"
ONLY_CHAIN=""
IP_CHECK=0
SCAN_SNI=0
SNI_CANDIDATES=""
LOCAL_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       HOST="${2:?--host 需要一个参数}"; shift 2 ;;
    --host=*)     HOST="${1#*=}"; shift ;;
    --port)       SSH_PORT="${2:?--port 需要一个参数}"; shift 2 ;;
    --port=*)     SSH_PORT="${1#*=}"; shift ;;
    --user)       SSH_USER="${2:?--user 需要一个参数}"; shift 2 ;;
    --user=*)     SSH_USER="${1#*=}"; shift ;;
    --chain)      ONLY_CHAIN="${2:?--chain 需要一个参数}"; shift 2 ;;
    --chain=*)    ONLY_CHAIN="${1#*=}"; shift ;;
    --ip-check)   IP_CHECK=1; shift ;;
    --scan-sni)   SCAN_SNI=1; shift ;;
    --sni-candidates)   SNI_CANDIDATES="${2:?--sni-candidates 需要一个参数}"; shift 2 ;;
    --sni-candidates=*) SNI_CANDIDATES="${1#*=}"; shift ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die_usage "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

if [[ "${LOCAL_ONLY}" == 1 && ( -n "${HOST}" || -n "${ONLY_CHAIN}" || "${IP_CHECK}" == 1 || "${SCAN_SNI}" == 1 ) ]]; then
  die_usage "--local-only 不能与 --host / --chain / --ip-check / --scan-sni 同用"
fi
if [[ -n "${SNI_CANDIDATES}" ]]; then
  [[ "${SCAN_SNI}" == 1 ]] || die_usage "--sni-candidates 只能与 --scan-sni 同用"
  n=0
  for d in ${SNI_CANDIDATES//,/ }; do
    n=$((n + 1))
    [[ "${d}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || die_usage "候选域名必须是 ASCII 域名：${d}"
  done
  (( n >= 1 && n <= 30 )) || die_usage "--sni-candidates 最多 30 个域名"
fi
[[ -z "${HOST}" ]] || validate_target "${HOST}" "${SSH_PORT}" "${SSH_USER}"
if [[ -n "${ONLY_CHAIN}" && ! "${ONLY_CHAIN}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then
  die_usage "--chain 只允许 [a-z0-9][a-z0-9-]{0,31}：${ONLY_CHAIN}"
fi

# ---------- 输出与计数 ----------

N_OK=0
N_WARN=0
N_FAIL=0

ok()   { N_OK=$((N_OK + 1));   printf '[OK]   %s\n' "$1"; }
warn() { N_WARN=$((N_WARN + 1)); printf '[WARN] %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       建议：%s\n' "$2"; }
fail() { N_FAIL=$((N_FAIL + 1)); printf '[FAIL] %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       建议：%s\n' "$2"; }

# ---------- 与链式脚本保持一致的小工具（复制自 chain/setup_chain.sh，改动时两边同步） ----------

# 同 chain/setup_chain.sh 的 xdg_or_default：XDG 变量不是绝对路径时回落默认值。
xdg_or_default() {
  if [[ -n "$1" && "$1" == /* ]]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

# 同 chain/setup_chain.sh 的 route_interface / interface_is_tunnel。
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

stat_mode() {
  if [[ "$(uname -s)" == Darwin ]]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}
stat_uid() {
  if [[ "$(uname -s)" == Darwin ]]; then stat -f '%u' "$1"; else stat -c '%u' "$1"; fi
}

# 权限位的“group / other”两位（八进制末两位）。
mode_group_other() { local m; m="$(stat_mode "$1")"; printf '%s' "${m: -2}"; }

# 按行取 KEY=VALUE（不 source，防止配置文件里的命令被执行）。
kv_get() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"; }

CONFIG_HOME="$(xdg_or_default "${XDG_CONFIG_HOME:-}" "${HOME}/.config")"
STATE_HOME="$(xdg_or_default "${XDG_STATE_HOME:-}" "${HOME}/.local/state")"
CHAIN_CONFIG_DIR="${CONFIG_HOME}/ownexit/chains"
KEY_DIR="${HOME}/.ssh/ownexit"

# 隔离用户 ~/.ssh/config，不写 known_hosts，不更新主机密钥；BatchMode 保证不会卡在密码提示。
SSH_SAFE_OPTS=(-F /dev/null -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=8)

# ---------- 收集目标 ----------

DIRECT_TARGETS=()   # 每项 "user|host|port"
CHAIN_IDS=()

collect_targets() {
  local file
  if [[ -n "${HOST}" ]]; then
    DIRECT_TARGETS+=("${SSH_USER}|${HOST}|${SSH_PORT}")
  elif [[ -z "${ONLY_CHAIN}" && -d "${OWNEXIT_DIRECT_TARGET_DIR}" ]]; then
    for file in "${OWNEXIT_DIRECT_TARGET_DIR}"/*.env; do
      [[ -f "${file}" ]] || continue
      if read_target_file "${file}"; then
        DIRECT_TARGETS+=("${TARGET_USER}|${TARGET_HOST}|${TARGET_PORT}")
      else
        warn "本机 目标配置格式不对：${file}" "删除该文件后重跑 ownexit direct --host <IP>"
      fi
    done
  fi
  if [[ -n "${ONLY_CHAIN}" ]]; then
    CHAIN_IDS+=("${ONLY_CHAIN}")
  elif [[ -z "${HOST}" && -d "${CHAIN_CONFIG_DIR}" ]]; then
    for file in "${CHAIN_CONFIG_DIR}"/*.env; do
      [[ -f "${file}" ]] || continue
      CHAIN_IDS+=("$(basename "${file}" .env)")
    done
  fi
}

# ---------- 本机检查 L1-L5 ----------

check_local() {
  local missing='' optional='' cmd file dir mode go iface ip seen='' item
  echo "== 本机 =="

  # L1
  if (( BASH_VERSINFO[0] > 3 || ( BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2 ) )); then
    ok "本机 系统与 bash：$(uname -sm)，bash ${BASH_VERSION}"
  else
    fail "本机 bash 版本过低：${BASH_VERSION}" "升级到 bash 3.2 及以上"
  fi

  # L2：直连必需命令
  for cmd in ssh scp ssh-keygen curl openssl base64; do
    command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"
  done
  command -v qrencode >/dev/null 2>&1 || optional="${optional} qrencode"
  if [[ -z "${missing}" ]]; then
    ok "本机 直连所需命令齐全（ssh scp ssh-keygen curl openssl base64）"
  else
    fail "本机 缺少直连所需命令：${missing# }" "用系统包管理器安装（macOS: brew install <命令>）"
  fi
  if [[ -n "${optional}" ]]; then
    warn "本机 缺少可选命令：${optional# }（只用于终端二维码）" "需要时安装（macOS: brew install qrencode）"
  fi
  # 首次配免密要能自动输入密码：pexpect（OWNEXIT_PYTHON 指向的解释器或 PATH 里的 python3）或 expect，任一即可。
  item=''
  for cmd in "${OWNEXIT_PYTHON:-}" python3; do
    [[ -n "${cmd}" ]] || continue
    if "${cmd}" -c 'import pexpect' >/dev/null 2>&1; then item="pexpect（${cmd}）"; break; fi
  done
  if [[ -z "${item}" ]] && command -v expect >/dev/null 2>&1; then item=expect; fi
  if [[ -n "${item}" ]]; then
    ok "本机 首次配免密的密码输入工具：${item}"
  else
    warn "本机 没有自动输入密码的工具（只在第一次给服务器配免密时需要）" "pipx 安装的 ownexit 自带；git clone 用法运行 pip3 install pexpect，或安装 expect（macOS: brew install expect）"
  fi
  # 链式依赖：完整清单在 chain/setup_chain.sh 的 require_local_dependencies，这里只查常见项。
  if [[ "${#CHAIN_IDS[@]}" -gt 0 ]]; then
    missing=''
    for cmd in tar awk mkfifo; do command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"; done
    if [[ "$(uname -s)" == Darwin ]]; then
      for cmd in nc route; do command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"; done
    else
      for cmd in ip timeout; do command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"; done
    fi
    if [[ -n "${missing}" ]]; then
      fail "本机 缺少链式所需命令：${missing# }" "安装后重跑；完整依赖以下面链的 status 结果为准"
    elif ! ssh -E /dev/null -V >/dev/null 2>&1; then
      fail "本机 OpenSSH 不支持 -E（链式主机指纹探测需要）" "升级 OpenSSH"
    else
      ok "本机 链式常用命令齐全（完整依赖以链的 status 为准）"
    fi
  fi

  # L3
  item=''
  for cmd in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
    [[ -z "${!cmd:-}" ]] || item="${item} ${cmd}"
  done
  if [[ -n "${item}" ]]; then
    warn "本机 设置了代理环境变量：${item# }（本机 curl 访问 VPS 订阅地址时会走代理）" "把 VPS / 中转 IP 加进 no_proxy，或运行前 unset 这些变量"
  else
    ok "本机 没有设置代理环境变量"
  fi

  # L4：按链式脚本的实际权限要求
  dir="${STATE_HOME}/ownexit"
  if [[ -d "${dir}" ]]; then
    mode="$(stat_mode "${dir}")"
    if [[ "${mode}" == 700 ]]; then ok "本机 ${dir} 权限 700"; else fail "本机 ${dir} 权限是 ${mode}，链式要求 700（否则无法加锁）" "chmod 700 '${dir}'"; fi
  fi
  if [[ -d "${CHAIN_CONFIG_DIR}" ]]; then
    mode="$(stat_mode "${CHAIN_CONFIG_DIR}")"
    if [[ "${mode}" == 700 ]]; then ok "本机 ${CHAIN_CONFIG_DIR} 权限 700"; else fail "本机 ${CHAIN_CONFIG_DIR} 权限是 ${mode}，链式要求 700" "chmod 700 '${CHAIN_CONFIG_DIR}'"; fi
  fi
  if [[ -d "${STATE_HOME}/ownexit/chains" ]]; then
    for dir in "${STATE_HOME}/ownexit/chains"/*; do
      [[ -d "${dir}" ]] || continue
      mode="$(stat_mode "${dir}")"
      [[ "${mode}" == 700 ]] || fail "本机 ${dir} 权限是 ${mode}，链式要求 700" "chmod 700 '${dir}'"
    done
  fi
  dir="${CONFIG_HOME}/ownexit"
  if [[ -d "${dir}" ]]; then
    go="$(mode_group_other "${dir}")"
    case "${go}" in
      00) ok "本机 ${dir} 权限 $(stat_mode "${dir}")" ;;
      *[2367]*) fail "本机 ${dir} 可被同组或其他用户写入（权限 $(stat_mode "${dir}")），链式会拒绝读取配置" "chmod 700 '${dir}'" ;;
      *) warn "本机 ${dir} 权限 $(stat_mode "${dir}")，其他用户可以列出其中的文件" "chmod 700 '${dir}'" ;;
    esac
  fi
  if [[ -d "${KEY_DIR}" ]]; then
    go="$(mode_group_other "${KEY_DIR}")"
    case "${go}" in
      *[2367]*) warn "本机 ${KEY_DIR} 可被同组或其他用户写入（权限 $(stat_mode "${KEY_DIR}")）" "chmod 700 '${KEY_DIR}'" ;;
      *) ok "本机 ${KEY_DIR} 权限 $(stat_mode "${KEY_DIR}")" ;;
    esac
  fi

  # L5：到每个目标 IP 的出接口是否是 TUN
  for item in "${DIRECT_TARGETS[@]+"${DIRECT_TARGETS[@]}"}"; do
    ip="$(printf '%s' "${item}" | cut -d'|' -f2)"
    seen="${seen} ${ip}"
  done
  for item in "${CHAIN_IDS[@]+"${CHAIN_IDS[@]}"}"; do
    file="${CHAIN_CONFIG_DIR}/${item}.env"
    [[ -f "${file}" ]] || continue
    seen="${seen} $(kv_get "${file}" RELAY_HOST) $(kv_get "${file}" EXIT_HOST)"
  done
  # 同一 IP 可能出现在多条链里，只查一次。
  seen="$(printf '%s\n' ${seen} | sort -u | tr '\n' ' ')"
  for ip in ${seen}; do
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    iface="$(route_interface "${ip}")"
    if [[ -n "${iface}" ]] && interface_is_tunnel "${iface}"; then
      warn "本机 到 ${ip} 的路由经过 TUN（${iface}），部署 / verify 期间 SSH 可能被代理软件断开" "关闭代理的 TUN 模式，或在代理规则里让 ${ip} 走直连"
    elif [[ -n "${iface}" ]]; then
      ok "本机 到 ${ip} 的路由走 ${iface}（不经过 TUN）"
    fi
  done
}

# ---------- 直连 VPS 检查 D1-D5 ----------

# 在直连 VPS 上执行的只读脚本：服务种类判据照搬 direct/subctl 的 status；client.env 里有 UUID，只取 PORT。
read -r -d '' DIRECT_PROBE <<'PROBE' || true
if [ -e /etc/systemd/system/ownexit-direct.service ]; then
  kind=ownexit; unit=ownexit-direct
elif [ -L /usr/local/bin/sb ]; then
  kind=legacy; unit=sing-box
else
  kind=none; unit=''
fi
active=inactive
[ -z "$unit" ] || active="$(systemctl is-active "$unit" < /dev/null 2>/dev/null || true)"
port=''
[ "$kind" != ownexit ] || port="$(awk -F= '$1 == "PORT" {print $2; exit}' /etc/ownexit-direct/client.env 2>/dev/null < /dev/null || true)"
listening=no
if [ -n "$port" ] && ss -H -ltn < /dev/null 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port\$"; then listening=yes; fi
printf 'KIND=%s\nACTIVE=%s\nPORT=%s\nLISTENING=%s\n' "$kind" "$active" "$port" "$listening"
printf 'SUB_ACTIVE=%s\n' "$(systemctl is-active ownexit-subscription < /dev/null 2>/dev/null || true)"
printf 'CC=%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control < /dev/null 2>/dev/null || true)"
printf 'SNI=%s\n' "$(awk -F= '$1 == "SNI" {print $2; exit}' /etc/ownexit-direct/client.env 2>/dev/null < /dev/null || true)"
PROBE

# 在出口服务器上执行的 IP 体检（docs/feature/feature-doctor-ipcheck.md §5.1.3）：只读，全部请求强制 IPv4、带超时，
# 输出 KEY=VALUE，由本机渲染。原始结果只取判定需要的片段，不回传整页内容。
read -r -d '' IPCHECK_PROBE <<'PROBE' || true
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
c() { curl -4 -sS -m 12 -A "$UA" "$@" < /dev/null 2>/dev/null; }
# ip-api 把 & 转义成 \u0026，还原后再取字段。
body="$(c 'http://ip-api.com/json/?fields=status,country,countryCode,city,isp,org,as,hosting,proxy,mobile,query' | sed 's/\\u0026/\&/g' || true)"
for k in status country countryCode city isp as query; do
  v="$(printf '%s' "$body" | sed -n "s/.*\"$k\":\"\\([^\"]*\\)\".*/\\1/p")"
  printf 'IP_%s=%s\n' "$k" "$v"
done
for k in hosting proxy mobile; do
  v="$(printf '%s' "$body" | sed -n "s/.*\"$k\":\\(true\\|false\\).*/\\1/p")"
  printf 'IP_%s=%s\n' "$k" "$v"
done
printf 'GPT_LOC=%s\n' "$(c https://chatgpt.com/cdn-cgi/trace | awk -F= '$1 == "loc" {print $2; exit}')"
b="$(c https://api.openai.com/compliance/cookie_requirements)" && rc=0 || rc=$?
if [ "$rc" != 0 ] || [ -z "$b" ]; then r=fail; elif printf '%s' "$b" | grep -q unsupported_country; then r=no; elif printf '%s' "$b" | grep -q cookie_consent_required; then r=yes; else r=unknown; fi
printf 'GPT=%s\n' "$r"
out="$(c -X POST -H 'content-type: application/json' -d '{}' -w '\n%{http_code}' https://api.anthropic.com/v1/messages)" && rc=0 || rc=$?
code="$(printf '%s' "$out" | tail -n 1)"
if [ "$rc" != 0 ] || [ "$code" = 000 ]; then r=fail; elif [ "$code" = 401 ] && printf '%s' "$out" | grep -q authentication_error; then r=yes; elif [ "$code" = 403 ]; then r=no; else r=unknown; fi
printf 'CLAUDE=%s\n' "$r"
b="$(c 'https://generativelanguage.googleapis.com/v1beta/models?key=invalid')" && rc=0 || rc=$?
if [ -z "$b" ]; then r=fail; elif printf '%s' "$b" | grep -q 'User location is not supported'; then r=no; elif printf '%s' "$b" | grep -q 'API key not valid'; then r=yes; else r=unknown; fi
printf 'GEMINI=%s\n' "$r"
n1="$(c -o /dev/null -w '%{http_code}' https://www.netflix.com/title/81280792 || true)"
n2="$(c -o /dev/null -w '%{http_code}' https://www.netflix.com/title/70143836 || true)"
printf 'NETFLIX=%s,%s\n' "${n1:-000}" "${n2:-000}"
b="$(c -H 'Accept-Language: en' https://www.youtube.com/premium)" && rc=0 || rc=$?
if [ -z "$b" ]; then r=fail; elif printf '%s' "$b" | grep -q 'Premium is not available in your country'; then r=no; elif printf '%s' "$b" | grep -q 'ad-free'; then r=yes; else r=unknown; fi
printf 'YOUTUBE=%s\n' "$r"
printf 'DISNEY=%s\n' "$(c -o /dev/null -w '%{http_code} %{redirect_url}' https://www.disneyplus.com/ || true)"
for site in www.google.com www.youtube.com github.com www.wikipedia.org x.com telegram.org; do
  printf 'SITE_%s=%s\n' "$site" "$(c -o /dev/null -w '%{http_code} %{time_total}' "https://$site/" || true)"
done
PROBE

# 在出口服务器上执行的伪装域名扫描（docs/feature/feature-devices-sni-scan.md §5.1.4）：对每个候选域名，
# 用服务器上本项目安装的 sing-box 在 127.0.0.1 上临时起一对 Reality 服务端 / 客户端，真实握手一次；
# 能经它拿到 generate_204 才算“可用”（只看 TLS 1.3 不够：www.microsoft.com 支持 TLS 1.3 却当不了伪装域名）。
# 参数：$1 = direct | chain（决定去哪找 sing-box），$2 = 逗号分隔的候选域名。临时进程只监听 127.0.0.1 ，
# 每个都套 timeout，目录与进程由 trap 在任何退出路径清理；所有命令 < /dev/null，避免吞掉 bash -s 后续的脚本行。
read -r -d '' SCAN_PROBE <<'PROBE' || true
kind="$1"; list="$2"
for cmd in curl openssl timeout ss; do
  command -v "$cmd" > /dev/null 2>&1 || { printf 'SCAN_ERROR=缺少 %s\n' "$cmd"; exit 0; }
done
bin=''
if [ "$kind" = direct ]; then
  bin="$(systemctl show ownexit-direct -p ExecStart --value < /dev/null 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1)"
else
  bin="$(ls /opt/ownexit-chain/bin/sing-box-* 2>/dev/null < /dev/null | sort | tail -n 1)"
fi
[ -n "$bin" ] && [ -x "$bin" ] || { printf 'SCAN_SKIP=没有本项目安装的 sing-box\n'; exit 0; }
work="$(mktemp -d)"
pids=''
cleanup() { for p in $pids; do kill "$p" 2> /dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
free_port() {
  local i p
  for i in 1 2 3 4 5 6 7 8 9 10; do
    p=$(( (RANDOM % 40000) + 20000 ))
    ss -Hltn < /dev/null | awk '{print $4}' | grep -Eq "[:.]$p\$" || { printf '%s' "$p"; return 0; }
  done
  return 1
}
IFS=',' read -r -a domains <<< "$list"
for d in "${domains[@]}"; do
  [ -n "$d" ] || continue
  tls13=no; h2=no; ok=no; t=0
  if out="$(timeout 12 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -groups X25519 -alpn h2 < /dev/null 2>&1)"; then
    tls13=yes
    printf '%s' "$out" | grep -q 'ALPN protocol: h2' && h2=yes
  fi
  sp="$(free_port)" && cp="$(free_port)" || { printf 'SNI=%s|err|%s|%s|0\n' "$d" "$tls13" "$h2"; continue; }
  kp="$("$bin" generate reality-keypair < /dev/null)"
  pk="$(printf '%s\n' "$kp" | awk -F': ' '$1 == "PrivateKey" {print $2}')"
  pb="$(printf '%s\n' "$kp" | awk -F': ' '$1 == "PublicKey" {print $2}')"
  u="$("$bin" generate uuid < /dev/null)"
  cat > "$work/s.json" <<EOF
{"log":{"level":"error"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$sp,"users":[{"uuid":"$u","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"$d","reality":{"enabled":true,"handshake":{"server":"$d","server_port":443},"private_key":"$pk","short_id":["0123456789abcdef"]}}}],"outbounds":[{"type":"direct"}]}
EOF
  cat > "$work/c.json" <<EOF
{"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":$cp}],"outbounds":[{"type":"vless","server":"127.0.0.1","server_port":$sp,"uuid":"$u","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"$d","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"$pb","short_id":"0123456789abcdef"}}}]}
EOF
  timeout 20 "$bin" run -c "$work/s.json" < /dev/null > "$work/s.log" 2>&1 & ps1=$!
  timeout 20 "$bin" run -c "$work/c.json" < /dev/null > "$work/c.log" 2>&1 & ps2=$!
  pids="$ps1 $ps2"
  sleep 1
  r="$(curl -4 -sS -m 12 -o /dev/null -w '%{http_code} %{time_total}' -x "socks5h://127.0.0.1:$cp" https://www.gstatic.com/generate_204 < /dev/null 2>/dev/null || true)"
  [ "${r%% *}" = 204 ] && ok=yes && t="${r#* }"
  kill "$ps1" "$ps2" 2> /dev/null || true
  wait "$ps1" "$ps2" 2> /dev/null || true
  pids=''
  printf 'SNI=%s|%s|%s|%s|%s\n' "$d" "$ok" "$tls13" "$h2" "$t"
done
PROBE

SCAN_DEFAULT_CANDIDATES='www.amazon.com,www.apple.com,www.microsoft.com,www.cloudflare.com,www.nvidia.com,www.tesla.com,www.samsung.com,www.oracle.com,www.intel.com,www.amd.com,www.yahoo.com,www.bing.com,dl.google.com,gateway.icloud.com,swdist.apple.com'

# 本机渲染扫描结果。$1 = 服务器标签，$2 = 远端输出（空 = 未执行），$3 = 当前 SNI，$4 = direct | chain。
render_scan() {
  local label="$1" out="$2" current="$3" kind="$4" v line d ok tls h2 t mark
  echo "== 伪装域名扫描：${label}（本机回环 Reality 握手；结果仅供参考） =="
  if [[ -z "${out}" ]]; then echo "  未执行（SSH 失败）"; return 0; fi
  v="$(printf '%s\n' "${out}" | sed -n 's/^SCAN_ERROR=//p')"
  if [[ -n "${v}" ]]; then echo "  无法判定（${v}）"; return 0; fi
  v="$(printf '%s\n' "${out}" | sed -n 's/^SCAN_SKIP=//p')"
  if [[ -n "${v}" ]]; then echo "  跳过（${v}）"; return 0; fi
  # 可用的按握手耗时升序，再列不可用的。
  for ok in yes no err; do
    while IFS='|' read -r d v tls h2 t; do
      [[ "${v}" == "${ok}" ]] || continue
      mark=''
      [[ "${d}" != "${current}" ]] || mark='（当前）'
      case "${v}" in
        yes) line="可用    握手 $(printf '%s' "${t}" | awk '{printf "%.2f", $1}') 秒" ;;
        no)  line="不可用" ;;
        *)   line="无法判定（端口不足）" ;;
      esac
      printf '  %-22s %s  TLS1.3+X25519=%s  h2=%s%s\n' "${d}" "${line}" "${tls}" "${h2}" "${mark}"
    done < <(printf '%s\n' "${out}" | sed -n 's/^SNI=//p' | sort -t'|' -k5,5n)
  done
  if [[ "${kind}" == direct ]]; then
    echo "  改用其它域名：ownexit direct --sni <域名>（改完先用一台设备确认能连上）"
  else
    echo "  链式改伪装域名需要 rollback 后改配置的 REALITY_SERVER_NAME 再 deploy：会删除全部设备，所有客户端重新导入"
  fi
}

# 本机渲染 IP 体检结果。$1 = 服务器标签，$2 = 远端输出（为空表示没执行成功）。
render_ipcheck() {
  local label="$1" out="$2" v t n1 n2 code url site
  echo "== 出口 IP 体检：${label}（结果仅供参考，以服务方实际为准） =="
  if [[ -z "${out}" ]]; then
    echo "  未执行（SSH 失败）"
    return 0
  fi
  g() { printf '%s\n' "${out}" | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }
  if [[ "$(g IP_status)" == success ]]; then
    if [[ "$(g IP_hosting)" == true ]]; then t='机房 IP'; elif [[ "$(g IP_mobile)" == true ]]; then t='移动网络'; else t='非机房（家用或商用宽带）'; fi
    [[ "$(g IP_proxy)" != true ]] || t="${t}，被标记为代理"
    echo "  出口 IP      ：$(g IP_query)  $(g IP_country)（$(g IP_countryCode)）$(g IP_city)"
    echo "  运营商 / ASN ：$(g IP_isp) / $(g IP_as)"
    echo "  类型         ：${t}"
  else
    echo "  出口 IP      ：无法判断（ip-api.com 请求失败）"
  fi
  verdict() { case "$1" in yes) echo '可用' ;; no) echo '不可用' ;; fail) echo '无法判断（请求失败）' ;; *) echo '无法判断' ;; esac; }
  echo "  ChatGPT      ：$(verdict "$(g GPT)")（地区 $(g GPT_LOC)）"
  echo "  Claude       ：$(verdict "$(g CLAUDE)")"
  echo "  Gemini       ：$(verdict "$(g GEMINI)")"
  v="$(g NETFLIX)"; n1="${v%%,*}"; n2="${v##*,}"
  if [[ "${n1}" == 000 || -z "${n1}" ]]; then t='无法判断（请求失败）'
  elif [[ "${n1}" == 200 && "${n2}" == 200 ]]; then t='完整解锁'
  elif [[ "${n1}" == 200 ]]; then t='仅自制剧'
  elif [[ ( "${n1}" == 403 || "${n1}" == 404 ) && ( "${n2}" == 403 || "${n2}" == 404 ) ]]; then t='不可用'
  else t="无法判断（HTTP ${n1} / ${n2}）"; fi
  echo "  Netflix      ：${t}"
  echo "  YouTube Prem ：$(verdict "$(g YOUTUBE)")"
  v="$(g DISNEY)"; code="${v%% *}"; url="${v#* }"
  if [[ "${code}" == 000 || -z "${code}" ]]; then t='无法判断（请求失败）'
  elif [[ "${url}" == *unavailable* ]]; then t='不可用'
  elif [[ "${code}" == 200 ]]; then t='可访问（未验证内容库）'
  else t="无法判断（HTTP ${code}）"; fi
  echo "  Disney+      ：${t}"
  for site in www.google.com www.youtube.com github.com www.wikipedia.org x.com telegram.org; do
    v="$(g "SITE_${site}")"; code="${v%% *}"
    if [[ "${code}" =~ ^[23][0-9][0-9]$ ]]; then t="通（$(printf '%s' "${v#* }" | awk '{printf "%.2f", $1}') 秒）"; else t="不通（HTTP ${code:-000}）"; fi
    printf '  %-13s：%s\n' "${site#www.}" "${t}"
  done
}

check_direct() {
  local user="$1" host="$2" port="$3" label key err rc out out_probe scan_out kind active pport listening
  label="${user}@${host}:${port}"
  echo "== 直连 VPS ${label} =="
  key="${KEY_DIR}/id_ed25519_$(target_safe_name "${user}" "${host}" "${port}")"
  # D1：私钥判据同链式（属于当前用户、group / other 无权限）
  if [[ ! -f "${key}" ]]; then
    fail "直连 ${label} 找不到免密密钥 ${key}" "重跑 ownexit direct --host ${host} --port ${port} 配免密"
    [[ "${IP_CHECK}" == 0 ]] || render_ipcheck "${label}" ""
    return 0
  fi
  if [[ "$(stat_uid "${key}")" != "$(id -u)" || "$(mode_group_other "${key}")" != 00 ]]; then
    fail "直连 ${label} 密钥权限过宽或不属于当前用户：${key}（$(stat_mode "${key}")）" "chmod 600 '${key}'"
  else
    ok "直连 ${label} 密钥 ${key}"
  fi
  # D2：按顺序匹配 stderr（主机指纹变化时两种文案同时出现，先匹配前者）
  err="$(ssh "${SSH_SAFE_OPTS[@]}" -n -i "${key}" -p "${port}" "${user}@${host}" true 2>&1 >/dev/null)" && rc=0 || rc=$?
  if [[ "${rc}" != 0 ]]; then
    case "${err}" in
      *"REMOTE HOST IDENTIFICATION HAS CHANGED"*) fail "直连 ${label} 主机指纹与 known_hosts 记录不符" "确认服务器是否重装；确属同一台机器时用 ssh-keygen -R ${host} 删除旧记录后重跑 ownexit direct" ;;
      *"Host key verification failed"*) fail "直连 ${label} known_hosts 没有这台机器的记录" "重跑 ownexit direct --host ${host} 重新登记" ;;
      *"Permission denied"*) fail "直连 ${label} 免密登录失效" "重跑 ownexit direct --host ${host}（会提示输入一次 root 密码）" ;;
      *) fail "直连 ${label} 连不上：$(printf '%s\n' "${err}" | tail -n 1)" "检查网络、服务器是否开机、SSH 端口是否正确" ;;
    esac
    [[ "${IP_CHECK}" == 0 ]] || render_ipcheck "${label}" ""
    return 0
  fi
  ok "直连 ${label} SSH 免密登录正常"
  out="$(printf '%s\n' "${DIRECT_PROBE}" | ssh "${SSH_SAFE_OPTS[@]}" -i "${key}" -p "${port}" "${user}@${host}" 'bash -s' 2>/dev/null)" || out=''
  out_probe="${out}"
  kind="$(printf '%s\n' "${out}" | kv_get /dev/stdin KIND)"
  active="$(printf '%s\n' "${out}" | kv_get /dev/stdin ACTIVE)"
  pport="$(printf '%s\n' "${out}" | kv_get /dev/stdin PORT)"
  listening="$(printf '%s\n' "${out}" | kv_get /dev/stdin LISTENING)"
  # D3
  case "${kind}" in
    ownexit)
      if [[ "${active}" == active && "${listening}" == yes ]]; then
        ok "直连 ${label} ownexit-direct 运行中，代理端口 ${pport} 在监听"
      else
        fail "直连 ${label} ownexit-direct 状态=${active:-未知}，代理端口 ${pport:-未知} 监听=${listening:-未知}" "ownexit subctl --host ${host} log 查看原因，或重跑 ownexit direct 修复"
      fi
      ;;
    legacy)
      if [[ "${active}" == active ]]; then
        warn "直连 ${label} 运行的是 233boy 旧版" "ownexit direct --host ${host} --migrate 换成本项目的服务（参数不变）"
      else
        fail "直连 ${label} 233boy 旧版的服务没有运行（状态=${active:-未知}）" "在 VPS 上用 sb 恢复，或迁移 / 重新部署"
      fi
      ;;
    none) fail "直连 ${label} 没有安装代理服务" "ownexit direct --host ${host}" ;;
    *) fail "直连 ${label} 无法读取服务状态" "ownexit subctl --host ${host} status" ;;
  esac
  # D4
  if [[ "$(printf '%s\n' "${out}" | kv_get /dev/stdin SUB_ACTIVE)" == active ]]; then
    warn "直连 ${label} 订阅服务开着（明文 HTTP 公网端口）" "所有设备导入后运行 ownexit subctl --host ${host} stop"
  else
    ok "直连 ${label} 订阅服务已关闭"
  fi
  # D5
  if [[ "$(printf '%s\n' "${out}" | kv_get /dev/stdin CC)" == bbr ]]; then
    ok "直连 ${label} BBR 已开启"
  else
    warn "直连 ${label} 拥塞控制不是 BBR" "重跑 ownexit direct 会开启 BBR"
  fi
  if [[ "${IP_CHECK}" == 1 ]]; then
    out="$(printf '%s\n' "${IPCHECK_PROBE}" | ssh "${SSH_SAFE_OPTS[@]}" -i "${key}" -p "${port}" "${user}@${host}" 'bash -s' 2>/dev/null)" || out=''
    render_ipcheck "${label}" "${out}"
  fi
  if [[ "${SCAN_SNI}" == 1 ]]; then
    echo "  （扫描 $(printf '%s' "${SNI_CANDIDATES:-${SCAN_DEFAULT_CANDIDATES}}" | tr ',' '\n' | awk 'NF {c++} END {print c + 0}') 个域名，通常 1-2 分钟）"
    scan_out="$(printf '%s\n' "${SCAN_PROBE}" | ssh "${SSH_SAFE_OPTS[@]}" -i "${key}" -p "${port}" "${user}@${host}" "bash -s -- direct ${SNI_CANDIDATES:-${SCAN_DEFAULT_CANDIDATES}}" 2>/dev/null)" || scan_out=''
    render_scan "${label}" "${scan_out}" "$(printf '%s\n' "${out_probe}" | kv_get /dev/stdin SNI)" direct
  fi
}

check_chain() {
  local id="$1" file out_file err_file rc last err_line relay rport rkey exit_host eport ekey out proxy
  file="${CHAIN_CONFIG_DIR}/${id}.env"
  echo "== 链 ${id} =="
  if [[ ! -f "${file}" ]]; then
    fail "链 ${id} 找不到配置 ${file}" "ownexit chain init --id ${id} …"
    return 0
  fi
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  bash "${CHAIN_SCRIPT}" --id "${id}" status < /dev/null > "${out_file}" 2> "${err_file}" && rc=0 || rc=$?
  last="$(grep '^status=' "${out_file}" | tail -n 1 || true)"
  err_line="$(grep 'ERROR' "${err_file}" | tail -n 1 || true)"
  rm -f "${out_file}" "${err_file}"
  case "${last}" in
    'status=deployed health=healthy'*) ok "链 ${id} ${last}" ;;
    status=not_deployed*) warn "链 ${id} 尚未部署" "ownexit chain --id ${id} deploy" ;;
    status=*) fail "链 ${id} ${last}" "按 next= 的提示处理：$(printf '%s' "${last}" | sed -n 's/.*next=\([^ ]*\).*/\1/p')" ;;
    *) fail "链 ${id} status 没有给出结论（退出码 ${rc}）：${err_line:-无错误输出}" "按错误信息处理后重跑 ownexit chain --id ${id} status" ;;
  esac
  if [[ "${IP_CHECK}" == 1 ]]; then
    relay="$(kv_get "${file}" RELAY_HOST)"; rport="$(kv_get "${file}" RELAY_SSH_PORT)"; rkey="$(kv_get "${file}" RELAY_SSH_KEY)"
    exit_host="$(kv_get "${file}" EXIT_HOST)"; eport="$(kv_get "${file}" EXIT_SSH_PORT)"; ekey="$(kv_get "${file}" EXIT_SSH_KEY)"
    # 经中转登录出口机，known_hosts 查找键与链式一致（出口机按 EXIT_HOST 记录）。
    proxy="ssh -F /dev/null -i ${rkey} -p ${rport:-22} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=8 -W %h:%p root@${relay}"
    out="$(printf '%s\n' "${IPCHECK_PROBE}" | ssh "${SSH_SAFE_OPTS[@]}" -i "${ekey}" -p "${eport:-22}" -o ProxyCommand="${proxy}" "root@${exit_host}" 'bash -s' 2>/dev/null)" || out=''
    render_ipcheck "链 ${id} 出口机 ${exit_host}" "${out}"
  fi
  if [[ "${SCAN_SNI}" == 1 ]]; then
    relay="$(kv_get "${file}" RELAY_HOST)"; rport="$(kv_get "${file}" RELAY_SSH_PORT)"; rkey="$(kv_get "${file}" RELAY_SSH_KEY)"
    exit_host="$(kv_get "${file}" EXIT_HOST)"; eport="$(kv_get "${file}" EXIT_SSH_PORT)"; ekey="$(kv_get "${file}" EXIT_SSH_KEY)"
    proxy="ssh -F /dev/null -i ${rkey} -p ${rport:-22} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=8 -W %h:%p root@${relay}"
    echo "  （扫描 $(printf '%s' "${SNI_CANDIDATES:-${SCAN_DEFAULT_CANDIDATES}}" | tr ',' '\n' | awk 'NF {c++} END {print c + 0}') 个域名，通常 1-2 分钟）"
    out="$(printf '%s\n' "${SCAN_PROBE}" | ssh "${SSH_SAFE_OPTS[@]}" -i "${ekey}" -p "${eport:-22}" -o ProxyCommand="${proxy}" "root@${exit_host}" "bash -s -- chain ${SNI_CANDIDATES:-${SCAN_DEFAULT_CANDIDATES}}" 2>/dev/null)" || out=''
    render_scan "链 ${id} 出口机 ${exit_host}" "${out}" "$(kv_get "${file}" REALITY_SERVER_NAME)" chain
  fi
}

# ---------- 主流程 ----------

collect_targets
check_local
if [[ "${LOCAL_ONLY}" == 0 ]]; then
  for item in "${DIRECT_TARGETS[@]+"${DIRECT_TARGETS[@]}"}"; do
    IFS='|' read -r t_user t_host t_port <<< "${item}"
    check_direct "${t_user}" "${t_host}" "${t_port}"
  done
  for item in "${CHAIN_IDS[@]+"${CHAIN_IDS[@]}"}"; do
    check_chain "${item}"
  done
  if [[ "${#DIRECT_TARGETS[@]}" -eq 0 && "${#CHAIN_IDS[@]}" -eq 0 ]]; then
    echo "（没有已记住的直连 VPS，也没有链配置；部署后再运行 doctor 可检查服务器）"
  fi
fi
echo "doctor: ok=${N_OK} warn=${N_WARN} fail=${N_FAIL}"
[[ "${N_FAIL}" -eq 0 ]]
