#!/usr/bin/env bash
# setup_direct.sh —— 直连部署入口：把一台 Debian / Ubuntu VPS 部署成自己的固定出口，并生成客户端订阅。
#
# 前置:
#   - 在本机（macOS 已验证；Linux 未测试）的本仓库目录内运行；本机需要 ssh、ssh-keygen、curl、openssl、base64，
#     第一次配免密还需要 expect（macOS: brew install expect）。
#   - 一台可以用 root 密码 SSH 登录的 Debian / Ubuntu VPS；第一次运行会交互问一次密码，之后全程免密。
#   - 第 4 阶段会经 SSH 交互式运行第三方安装脚本 233boy/sing-box（github.com/233boy/sing-box），
#     端口 / SNI / UUID 由你现场回答。
#   - 不应被 source。
#
# 流程：
#   1. 决定目标（--host > 上次记住的 VPS > 交互提问）；免密不可用时自动调用 connect_to.sh 配免密；
#      校验系统（仅支持 Debian/Ubuntu），通过后记住这台 VPS
#   2. VPS 上 curl ipinfo.io 确认公网 IP
#   3. 幂等开启 BBR
#   4. 经 SSH 交互式运行 233boy 安装 sing-box（已装则跳过）
#   5. 用 `sb url` 拉回真实节点参数（UUID/端口/SNI/public-key/short-id/flow），不手写猜测
#   6. 在本地暂存目录渲染订阅产物：
#      <TOKEN>/clash.yaml、<TOKEN>/shadowrocket.txt、<TOKEN>/node.txt、
#      根目录空 index.html（防目录列表泄露 TOKEN）、订阅服务 systemd 单元（SUB_PORT 已替换）
#   7. 调 sync_to_vps.sh 一次性同步到 VPS /opt/ownexit-subscription/，启用订阅服务
#   8. 分层验证：VPS 主机、订阅服务、订阅链接拉取校验
#   9. 打印三条订阅 URL、节点链接与后续步骤
#
# 不做：购买产品、改付款信息、删除服务器、重装系统、开放无关端口、运行与代理无关的服务。

set -euo pipefail

# 目标由参数、已记住的目标配置或交互提问决定（见 target_lib.sh），不要在这里填写真实 IP。
HOST=""
SSH_USER="root"
SSH_PORT="22"

NODE_NAME="ownexit-direct"
SUB_BASE_DIR="/opt/ownexit-subscription"
SUB_SERVICE="ownexit-subscription"
ROTATE_TOKEN=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

第一次部署（会问一次 VPS 的 root 密码）:
  $(basename "$0") --host 203.0.113.7
SSH 端口不是 22 时:
  $(basename "$0") --host 203.0.113.7 --port 2222
之后重新部署 / 换了客户端要重新拉订阅（自动使用上次记住的 VPS）:
  $(basename "$0")
怀疑订阅链接泄露，换一个新的订阅地址:
  $(basename "$0") --rotate-token

选项:
  --host <ip/host>            出口 VPS 地址；不给时用上次记住的 VPS，没有则交互提问
  -u, --user <user>           SSH 用户名，默认 root
  -P, --port <port>           SSH 端口，默认 22
  --rotate-token              重新生成 TOKEN 和 SUB_PORT，并清理 VPS 上旧 TOKEN 目录
  -h, --help                  显示帮助

退出码: 0 全部通过；1 部署失败或有验证项未通过；2 参数错误或缺参数（非终端运行时）。
EOF
}

die() {
  echo "[!] $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=target_lib.sh
. "${SCRIPT_DIR}/target_lib.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           HOST="${2:?--host 需要一个参数}"; shift 2 ;;
    --host=*)         HOST="${1#*=}"; shift ;;
    -u|--user)        SSH_USER="${2:?--user 需要一个参数}"; shift 2 ;;
    --user=*)         SSH_USER="${1#*=}"; shift ;;
    -P|--port)        SSH_PORT="${2:?--port 需要一个参数}"; shift 2 ;;
    --port=*)         SSH_PORT="${1#*=}"; shift ;;
    --rotate-token)   ROTATE_TOKEN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die_usage "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

resolve_target
if [[ "${SSH_USER}" != "root" ]]; then
  echo "[!] 注意：本脚本的远程命令（sysctl/systemctl/apt 等）按 root 设计，非 root 用户大概率失败"
fi

# 密钥路径推导必须与 connect_to.sh 完全一致
SAFE_NAME="$(target_safe_name "${SSH_USER}" "${HOST}" "${SSH_PORT}")"
KEY="${HOME}/.ssh/ownexit/id_ed25519_${SAFE_NAME}"

SSH_OPTS=(
  -i "${KEY}"
  -p "${SSH_PORT}"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=10
  # 强制发 VPS 已有的 C.UTF-8，覆盖本机转发的 zh_CN.UTF-8，避免远端 setlocale 警告
  -o SetEnv=LC_ALL=C.UTF-8
)

# 非交互远程执行；233boy 安装单独用 ssh -t 走交互
vssh() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "$@"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g'
}

# 从 URL query 串中取指定 key 的值（key=value&...）
query_param() {
  local query="$1" key="$2"
  printf '%s\n' "${query}" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n 1
}

# 解析 vless:// 链接，结果写入 PROXY_* 全局变量
parse_vless_link() {
  local link="$1" rest hostport query
  rest="${link#vless://}"
  PROXY_UUID="${rest%%@*}"
  rest="${rest#*@}"
  hostport="${rest%%\?*}"
  hostport="${hostport%%/*}"
  PROXY_SERVER="${hostport%%:*}"
  PROXY_PORT="${hostport##*:}"
  query="${rest#*\?}"
  query="${query%%#*}"
  PROXY_SNI="$(query_param "${query}" "sni")"
  PROXY_PBK="$(query_param "${query}" "pbk")"
  PROXY_SID="$(query_param "${query}" "sid")"
  PROXY_FLOW="$(query_param "${query}" "flow")"

  [[ -n "${PROXY_UUID}" && "${PROXY_UUID}" != "${link}" ]] || return 1
  [[ "${PROXY_PORT}" =~ ^[0-9]+$ ]] || return 1
  [[ -n "${PROXY_SERVER}" && -n "${PROXY_SNI}" && -n "${PROXY_PBK}" ]] || return 1
  return 0
}

FAIL_COUNT=0
pass() { echo "[+] $*"; }
fail() { echo "[!] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------- 1. 免密 SSH 与系统信息 ----------

echo "[*] 检查免密 SSH：${SSH_USER}@${HOST}:${SSH_PORT}"
if [[ ! -f "${KEY}" ]] || ! vssh "exit" >/dev/null 2>&1; then
  # 第一次部署或 VPS 重装后免密失效：直接调用 connect_to.sh 配好，省掉用户单独跑一条命令。
  # connect_to.sh 自己负责问密码、区分"密码错 / 关了密码登录 / 连不上"并打印 reason=...，
  # 这里只透传它的退出码，不重复解释失败原因。
  echo "[*] 免密不可用，调用 connect_to.sh 配置免密（会问一次 VPS 密码）"
  connect_rc=0
  "${SCRIPT_DIR}/connect_to.sh" --setup-only --host "${HOST}" --port "${SSH_PORT}" --user "${SSH_USER}" \
    || connect_rc=$?
  [[ "${connect_rc}" -eq 0 ]] || exit "${connect_rc}"
  vssh "exit" >/dev/null 2>&1 || die "connect_to.sh 报告成功，但免密登录仍不可用，请人工检查 ${KEY}"
fi
pass "免密 SSH 可用"

# 一次 SSH 同时取 ID 和 PRETTY_NAME。SSH 偶发失败（实测出现过刚配完免密后的单次失败）时重试一次，
# 仍失败就如实报“读取失败”，不能把空结果当成“不支持的系统”误导用户。
OS_INFO=""
for attempt in 1 2; do
  if OS_INFO="$(vssh '. /etc/os-release && printf "%s\n%s\n" "${ID}" "${PRETTY_NAME}"' 2>/dev/null)"; then
    break
  fi
  OS_INFO=""
  [[ "${attempt}" -eq 2 ]] || sleep 2
done
[[ -n "${OS_INFO}" ]] || die "读取 VPS 系统信息失败（SSH 命令连续 2 次失败），请稍后重跑；免密已配好，不会再问密码"
OS_ID="$(printf '%s\n' "${OS_INFO}" | sed -n 1p)"
OS_PRETTY="$(printf '%s\n' "${OS_INFO}" | sed -n 2p)"
case "${OS_ID}" in
  debian|ubuntu)
    pass "VPS 系统：${OS_PRETTY}"
    ;;
  *)
    die "VPS 系统为 '${OS_ID:-未知}'，本脚本只按 Debian/Ubuntu 设计，不猜其它发行版的包管理器，停止"
    ;;
esac

# 基础工具：curl（验IP）、wget（233boy 安装）、python3（订阅服务）
echo "[*] 检查 VPS 基础工具（curl / wget / python3）"
MISSING_PKGS="$(vssh 'missing=""; for c in curl wget python3; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done; echo "$missing"' | xargs || true)"
if [[ -n "${MISSING_PKGS}" ]]; then
  echo "[*] 安装缺失工具：${MISSING_PKGS}"
  vssh "apt-get update -qq && apt-get install -y -qq ${MISSING_PKGS}" \
    || die "apt 安装 ${MISSING_PKGS} 失败"
fi
pass "基础工具就绪"

# 免密和系统都确认可用后才记住这台 VPS，避免把一个连不上或不支持的目标记成"上次的 VPS"。
save_target

# ---------- 2. VPS 公网 IP ----------

echo "[*] 读取 VPS 公网 IP（curl ipinfo.io）"
VPS_PUBLIC_IP="$(vssh "curl -fsS -m 15 ipinfo.io/ip" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "${VPS_PUBLIC_IP}" ]]; then
  fail "VPS 上 curl ipinfo.io 失败，无法确认公网 IP"
else
  pass "VPS 公网 IP：${VPS_PUBLIC_IP}"
  if [[ "${VPS_PUBLIC_IP}" != "${HOST}" ]]; then
    echo "[!] 注意：VPS 出口 IP（${VPS_PUBLIC_IP}）与 SSH 地址（${HOST}）不一致，请人工确认是否符合预期"
  fi
fi

# ---------- 3. 幂等开启 BBR ----------

echo "[*] 开启 BBR（幂等，重复执行无害）"
BBR_NOW="$(vssh "cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1
sysctl -n net.ipv4.tcp_congestion_control" || true)"
if [[ "${BBR_NOW}" == "bbr" ]]; then
  pass "BBR 已启用"
else
  fail "BBR 未生效（当前拥塞算法：${BBR_NOW:-未知}），可能内核过旧，请人工检查"
fi

# ---------- 4. 233boy 安装 sing-box（交互式，已装则跳过） ----------

if vssh "command -v sb >/dev/null 2>&1 || test -x /usr/local/bin/sb" >/dev/null 2>&1; then
  pass "检测到 sb 命令，sing-box 已安装，跳过 233boy 安装"
else
  cat <<'EOF'
[*] 即将经 SSH 交互式运行 233boy sing-box 安装脚本（官方仓库 github.com/233boy/sing-box）。
    接下来出现的提示由你现场回答，建议：
      - 协议：按名称选 VLESS-REALITY / Reality（不要死记菜单编号）
      - 端口：直接回车（随机）
      - SNI：输入 www.microsoft.com（大众脸、抗封锁稳；想用默认直接回车也行）
      - UUID：直接回车（自动生成）
    遇到没见过的菜单/提示，按 Ctrl+C 退出并反馈，不要盲目回车。
EOF
  # 交互安装必须分配 tty；这里不复用 BatchMode 的 SSH_OPTS
  ssh -t -i "${KEY}" -p "${SSH_PORT}" \
    -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o SetEnv=LC_ALL=C.UTF-8 \
    "${SSH_USER}@${HOST}" \
    "bash <(wget -qO- https://raw.githubusercontent.com/233boy/sing-box/main/install.sh)" \
    || echo "[!] 233boy 安装进程退出码非零（无 tty 时属常见现象），以下面的 sb 检测为准"
  vssh "command -v sb >/dev/null 2>&1 || test -x /usr/local/bin/sb" >/dev/null 2>&1 \
    || die "安装后未检测到 sb 命令，233boy 安装可能未完成"
  pass "233boy sing-box 安装完成"
fi

# ---------- 5. 用 sb url 拉回真实节点参数 ----------

echo "[*] 用 'sb url' 拉取真实节点参数"
# VPS 上 sing-box 有多个配置文件时（例如你自己用 sb 另加过协议），裸 `sb url` 会弹出
# 「请选择配置」交互菜单，非交互 SSH 下读不到输入 → 死循环挂住（破坏脚本幂等重跑）。
# 显式把 reality 配置名传给 `sb url <名>` 直取该节点链接（只有单个配置时同样可用）。
REALITY_CONF="$(vssh "ls /etc/sing-box/conf/ 2>/dev/null | grep VLESS-REALITY | head -n1" 2>/dev/null | tr -d '[:space:]' || true)"
SB_URL_RAW="$(vssh "sb url ${REALITY_CONF} 2>/dev/null || /usr/local/bin/sb url ${REALITY_CONF}" | strip_ansi || true)"
NODE_LINK="$(printf '%s\n' "${SB_URL_RAW}" | grep -oE 'vless://[^[:space:]]+' | head -n 1 || true)"
[[ -n "${NODE_LINK}" ]] || die "'sb url' 输出中找不到 vless:// 链接；请在 VPS 上运行 sb 检查节点配置。原始输出：${SB_URL_RAW}"

parse_vless_link "${NODE_LINK}" \
  || die "无法从节点链接解析出 UUID/端口/SNI/public-key，请人工核对：${NODE_LINK}"
pass "节点参数：server=${PROXY_SERVER} port=${PROXY_PORT} sni=${PROXY_SNI} flow=${PROXY_FLOW:-无} sid=${PROXY_SID:-空}"

# 保留真实参数、只改备注名，方便客户端里按统一名称选择
SR_LINK="vless://${NODE_LINK#vless://}"
SR_LINK="${SR_LINK%%#*}#${NODE_NAME}"

# ---------- 6. 本地渲染订阅产物 ----------

# 订阅 TOKEN 是"VPS 上订阅目录名"的唯一记录，丢了就只能 --rotate-token，所以放 XDG state 而不是可随时清空的 cache。
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/ownexit/direct/${SAFE_NAME}"
STATE_FILE="${STATE_DIR}/state.env"
STAGING="${STATE_DIR}/${SUB_SERVICE}"
mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

OLD_TOKEN=""
SUB_PORT=""
TOKEN=""
if [[ -f "${STATE_FILE}" ]]; then
  # state.env 只含本脚本写入的 SUB_PORT / TOKEN 两个键（权限 600）。
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

TOKEN_CHANGED=0
if [[ "${ROTATE_TOKEN}" == "1" || -z "${TOKEN}" || -z "${SUB_PORT}" ]]; then
  OLD_TOKEN="${TOKEN:-}"
  TOKEN="$(openssl rand -hex 16)"
  # 随机高位订阅端口：避开代理端口，并确认 VPS 上未被占用
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    SUB_PORT="$(( (RANDOM % 40000) + 20000 ))"
    [[ "${SUB_PORT}" != "${PROXY_PORT}" ]] || continue
    if ! vssh "ss -ltn | awk '{print \$4}' | grep -q ':${SUB_PORT}\$'" >/dev/null 2>&1; then
      break
    fi
    SUB_PORT=""
  done
  [[ -n "${SUB_PORT}" ]] || die "连续 10 次未找到空闲订阅端口，请人工检查 VPS 端口占用"
  TOKEN_CHANGED=1
  pass "生成订阅参数：SUB_PORT=${SUB_PORT} TOKEN=${TOKEN}"
else
  pass "复用已有订阅参数：SUB_PORT=${SUB_PORT}（TOKEN 不变；如需轮换用 --rotate-token）"
fi

if [[ "${TOKEN_CHANGED}" == "1" ]]; then
  printf 'SUB_PORT=%s\nTOKEN=%s\n' "${SUB_PORT}" "${TOKEN}" > "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
fi

echo "[*] 本地渲染订阅产物：${STAGING}"
rm -rf "${STAGING}"
mkdir -p "${STAGING}/${TOKEN}"

# clash.yaml：完整可加载配置（mihomo -d 可直接使用），不是 merge 片段
{
  cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

proxies:
  - name: ${NODE_NAME}
    type: vless
    server: ${PROXY_SERVER}
    port: ${PROXY_PORT}
    uuid: ${PROXY_UUID}
    udp: true
    tls: true
    servername: ${PROXY_SNI}
    client-fingerprint: chrome
EOF
  # 233boy 节点链接带 flow 时必须同步写入，否则连不上
  if [[ -n "${PROXY_FLOW}" ]]; then
    echo "    flow: ${PROXY_FLOW}"
  fi
  cat <<EOF
    reality-opts:
      public-key: ${PROXY_PBK}
      short-id: "${PROXY_SID}"

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${NODE_NAME}
      - DIRECT

rules:
  # 国内网站 / IP 直连，其余全部走自己的出口；想全部走出口，在客户端把模式切到「全局」即可
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
} > "${STAGING}/${TOKEN}/clash.yaml"

# Shadowrocket 订阅：base64 编码的节点链接列表
printf '%s\n' "${SR_LINK}" | base64 | tr -d '\n' > "${STAGING}/${TOKEN}/shadowrocket.txt"
printf '\n' >> "${STAGING}/${TOKEN}/shadowrocket.txt"

# 备用节点链接（明文）
printf '%s\n' "${SR_LINK}" > "${STAGING}/${TOKEN}/node.txt"

# 空 index.html：python3 http.server 对无 index.html 的根目录会返回目录列表，
# 把所有 TOKEN 目录名暴露出来，随机 token 形同虚设
: > "${STAGING}/index.html"

# 订阅服务 systemd 单元：SUB_PORT 在本地渲染时替换（systemd 不展开占位符）。
# 以 nobody 非 root 运行：高位端口无需 root、只读分发 world-readable 静态文件，
# 最小权限缩小 python http.server 万一被利用时的爆炸半径（root→无权用户）。
cat > "${STAGING}/${SUB_SERVICE}.service" <<EOF
[Unit]
Description=ownexit subscription files
After=network-online.target

[Service]
WorkingDirectory=${SUB_BASE_DIR}
ExecStart=/usr/bin/python3 -m http.server ${SUB_PORT} --bind 0.0.0.0
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

# 本地校验渲染结果：关键字段必须齐全且无占位符残留
for field in "server: ${PROXY_SERVER}" "uuid: ${PROXY_UUID}" "public-key: ${PROXY_PBK}"; do
  grep -qF "${field}" "${STAGING}/${TOKEN}/clash.yaml" \
    || die "本地渲染的 clash.yaml 缺少字段：${field}"
done
grep -qF "http.server ${SUB_PORT}" "${STAGING}/${SUB_SERVICE}.service" \
  || die "systemd 单元 SUB_PORT 替换失败"
pass "本地订阅产物渲染并校验完成"

# ---------- 7. 同步到 VPS 并启用订阅服务 ----------

echo "[*] 调用 sync_to_vps.sh 一次性同步到 VPS"
"${SCRIPT_DIR}/sync_to_vps.sh" --host "${HOST}" --user "${SSH_USER}" --port "${SSH_PORT}" \
  "${STAGING}" "$(dirname "${SUB_BASE_DIR}")"

# 轮换 TOKEN 后清理 VPS 上的旧 TOKEN 目录（格式校验防误删）
if [[ -n "${OLD_TOKEN}" && "${OLD_TOKEN}" != "${TOKEN}" && "${OLD_TOKEN}" =~ ^[0-9a-f]{32}$ ]]; then
  echo "[*] 清理旧 TOKEN 目录：${SUB_BASE_DIR}/${OLD_TOKEN}"
  vssh "rm -rf '${SUB_BASE_DIR}/${OLD_TOKEN}'" || true
fi

echo "[*] 启用订阅服务 ${SUB_SERVICE}"
vssh "bash -s" <<REMOTE
set -euo pipefail
install -m 644 '${SUB_BASE_DIR}/${SUB_SERVICE}.service' '/etc/systemd/system/${SUB_SERVICE}.service'
rm -f '${SUB_BASE_DIR}/${SUB_SERVICE}.service'
systemctl daemon-reload
systemctl enable '${SUB_SERVICE}' >/dev/null 2>&1
systemctl restart '${SUB_SERVICE}'
REMOTE
pass "订阅服务已启动"

# 防火墙：只在 ufw 已启用时放行代理端口和订阅端口，不主动开启防火墙
UFW_STATUS="$(vssh "command -v ufw >/dev/null 2>&1 && ufw status | head -n 1 || echo none" || true)"
if [[ "${UFW_STATUS}" == *active* && "${UFW_STATUS}" != *inactive* ]]; then
  echo "[*] ufw 已启用，放行代理端口 ${PROXY_PORT} 与订阅端口 ${SUB_PORT}"
  vssh "ufw allow ${PROXY_PORT}/tcp >/dev/null && ufw allow ${SUB_PORT}/tcp >/dev/null" \
    || fail "ufw 放行端口失败，请人工处理"
elif [[ "${UFW_STATUS}" != "none" && "${UFW_STATUS}" != *inactive* ]]; then
  echo "[!] 无法确认防火墙状态（${UFW_STATUS}），若客户端连不上请检查 VPS 防火墙/服务商安全组放行 ${PROXY_PORT} 和 ${SUB_PORT}"
fi

# ---------- 8. 分层验证 ----------

CLASH_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/clash.yaml"
SR_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/shadowrocket.txt"
NODE_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/node.txt"

echo "[*] 验证：VPS 主机层"
if [[ "$(vssh 'systemctl is-active sing-box' 2>/dev/null || true)" == "active" ]]; then
  pass "sing-box 服务 active"
else
  fail "sing-box 服务非 active，VPS 上运行 'sb log' 查看日志"
fi
if vssh "ss -ltn | awk '{print \$4}' | grep -q ':${PROXY_PORT}\$'" >/dev/null 2>&1; then
  pass "代理端口 ${PROXY_PORT} 监听中"
else
  fail "代理端口 ${PROXY_PORT} 未监听"
fi

echo "[*] 验证：订阅服务层"
if [[ "$(vssh "systemctl is-active ${SUB_SERVICE}" 2>/dev/null || true)" == "active" ]]; then
  pass "${SUB_SERVICE} 服务 active"
else
  fail "${SUB_SERVICE} 服务非 active"
fi
if vssh "ss -ltn | awk '{print \$4}' | grep -q ':${SUB_PORT}\$'" >/dev/null 2>&1; then
  pass "订阅端口 ${SUB_PORT} 监听中"
else
  fail "订阅端口 ${SUB_PORT} 未监听"
fi

echo "[*] 验证：macOS 本地拉取订阅"
if curl -fsS -m 15 "${CLASH_URL}" | cmp -s - "${STAGING}/${TOKEN}/clash.yaml"; then
  pass "Clash 订阅链接可拉取且与本地渲染一致"
else
  fail "Clash 订阅链接拉取失败或内容不一致：${CLASH_URL}"
fi
ROOT_BODY="$(curl -fsS -m 15 "http://${HOST}:${SUB_PORT}/" 2>/dev/null || echo "__CURL_FAIL__")"
if [[ "${ROOT_BODY}" == "__CURL_FAIL__" ]]; then
  fail "根路径请求失败：http://${HOST}:${SUB_PORT}/"
elif [[ -z "${ROOT_BODY}" ]]; then
  pass "根路径返回空 index.html，TOKEN 不泄露"
else
  fail "根路径返回非空内容（可能是目录列表，泄露 TOKEN），请检查 ${SUB_BASE_DIR}/index.html"
fi

# ---------- 9. 交付汇总 ----------

cat <<EOF

==================== 交付结果 ====================
订阅链接（客户端「新增订阅链接」直接粘贴）:
  Clash Verge / mihomo : ${CLASH_URL}
  Shadowrocket         : ${SR_URL}
  节点链接备份(明文)    : ${NODE_URL}

vless 节点链接（仅故障排查/备份用）:
  ${SR_LINK}

二维码 / 备用导入方式：在 VPS 上执行 'sb qr' 或 'sb url' 查看

后续人工步骤:
  1. Clash Verge / mihomo：「订阅」页粘贴 Clash 订阅 URL → 导入并选中 → 代理页 PROXY 组选 ${NODE_NAME}
     → 开启系统代理（或 Tun 模式）→ 模式选「规则」
  2. iPhone Shadowrocket：+ → Subscribe → 粘贴 Shadowrocket 订阅 URL → 连接
  3. 连上后访问 ipinfo.io，确认出口 IP = ${VPS_PUBLIC_IP:-VPS IP}
  4. 所有设备都导入后，关掉订阅服务缩小暴露面：$(dirname "$0")/subctl stop

安全提醒:
  - 订阅是明文 HTTP：只在新增/更新客户端时手动拉取，不要配置成高频自动更新
  - 以后要给新设备导入订阅：先 $(dirname "$0")/subctl start，导入后再 stop
  - 怀疑订阅泄露时运行：$(basename "$0") --rotate-token（并在 VPS 上用 sb 更换 UUID/端口）
==================================================
EOF

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "[!] 有 ${FAIL_COUNT} 项验证未通过，详见上方 [!] 条目"
  exit 1
fi
echo "[+] 全部验证通过"
