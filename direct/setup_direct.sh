#!/usr/bin/env bash
# setup_direct.sh —— 直连部署入口：把一台 Debian / Ubuntu VPS 部署成自己的固定出口，并生成客户端订阅。
#
# 前置:
#   - 在本机运行（macOS 已验证；Linux 未测试）；本机需要 ssh、scp、ssh-keygen、curl、openssl、base64，
#     第一次配免密还需要能自动输入密码的工具：pexpect（pipx 安装自带，经 OWNEXIT_PYTHON 传入）或 expect；显示二维码需要 qrencode（可选）。
#   - 一台可以用 root 密码 SSH 登录的 Debian / Ubuntu VPS（systemd ≥ 240）；第一次运行会交互问一次密码，之后全程免密。
#   - sing-box 由 VPS 自己从 GitHub 下载固定版本官方包并校验 SHA-256（下载失败时由本机下载后上传），全程无交互。
#   - 不应被 source。
#
# 流程（docs/feature/feature-direct-native-install.md）：
#   1. 决定目标（--host > 上次记住的 VPS > 交互提问）；免密不可用时自动调用 connect_to.sh 配免密；
#      校验系统（仅支持 Debian/Ubuntu），通过后记住这台 VPS
#   2. VPS 上 curl ipinfo.io 确认公网 IP
#   3. 幂等开启 BBR
#   4. 探测服务器状态（新机 / 已是本项目 / 233boy 旧版 / 迁移残局 / 未完成操作 / 冲突），按状态与参数选择操作：
#      新装、修复、改参数、迁移（migrate）、卸载（uninstall）；改动 sing-box 的操作由 VPS 上的
#      systemd 临时单元执行（direct_remote.sh），SSH 断开不影响，中途断电下次运行自动恢复
#   5. 从 VPS 读回 /etc/ownexit-direct/client.env 得到节点参数（服务器是唯一权威源）
#   6. 在本地暂存目录渲染订阅产物：<TOKEN>/clash.yaml、shadowrocket.txt、node.txt、sing-box.json、订阅服务脚本 subserver.py、订阅服务单元
#      （空 index.html 保留，防目录列表现由 subserver.py 的路径白名单保证）
#   7. 调 sync_to_vps.sh 一次性同步到 VPS /opt/ownexit-subscription/，启用订阅服务
#   8. 分层验证：VPS 主机、订阅服务、订阅链接拉取校验
#   9. 打印订阅 URL、节点链接、二维码（有 qrencode 时）与后续步骤；同机有链时提示 rebaseline
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
# rotate-keys：在服务器上重新生成 UUID / Reality 密钥 / short id（端口、SNI、订阅地址不变）。
ROTATE_KEYS=0
# 本机到 VPS 的路由经代理 TUN 时默认拒绝部署；--allow-tun 置 1 后只警告继续。
ALLOW_TUN=0
# 本次运行中已经完成过一次凭据轮换（来自恢复的未完成操作）；为 1 时不再轮换，避免用户重跑时凭据被换两次。
ROTATED=0
# add-device / remove-device 的设备名（docs/feature/feature-devices-sni-scan.md §5.1.1）；default 指现有 UUID，保留。
WANT_ADD_DEVICE=""
WANT_REMOVE_DEVICE=""
# 本次运行（含恢复的未完成操作）改动了设备表：其它设备不必重新导入，但同机链需要 rebaseline。
CHANGED_DEVICES=0
DO_MIGRATE=0
DO_UNINSTALL=0
WANT_SNI=""
WANT_PROXY_PORT=""
# --sub-ttl：订阅服务自动关闭的时长（原值，如 30m）；空 = 不自动关闭（默认，与 1.3.0 相同）。
WANT_SUB_TTL=""
SUB_TTL_SECONDS=""

# sing-box 固定版本与官方包摘要：必须与 chain/setup_chain.sh 的同名常量逐字一致（CI 的“sing-box 常量一致”检查）。
readonly SING_BOX_VERSION='1.13.14'
readonly ARCHIVE_SHA256_LINUX_AMD64='f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697'
readonly BINARY_SHA256_LINUX_AMD64='68aeab83cc4ab2659a5b92232261a20746ccdafc3b3d1e19b2d63247eec3bbf7'
readonly ARCHIVE_SHA256_LINUX_ARM64='4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e'
readonly BINARY_SHA256_LINUX_ARM64='85f570b96754cd7c354d28e50f66e9340b374e06b5d77ec9e15e8d04f0c87a25'
readonly OFFICIAL_RELEASE_BASE_URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}"
# 仅供测试下载失败回退：只改 VPS 端的下载地址；本机回退下载固定走官方地址。正常使用不要设置。
REMOTE_RELEASE_BASE_URL="${OWNEXIT_TEST_RELEASE_BASE_URL:-${OFFICIAL_RELEASE_BASE_URL}}"
# 与链式默认 SNI 一致（chain/setup_chain.sh:66）。
readonly DIRECT_SNI_DEFAULT='www.amazon.com'
readonly REMOTE_WORK='/var/lib/ownexit-direct'
readonly OP_UNIT='ownexit-direct-op'

usage() {
  if [[ "${OWNEXIT_UI_LANG}" == en ]]; then
    cat <<EOF
Usage: ownexit direct [subcommand] [options]      (git clone: $(basename "$0") [subcommand] [options])

Deploy (no subcommand means up; the first run asks once for the VPS root password):
  ownexit direct up --host 203.0.113.7
  ownexit direct up --host 203.0.113.7 --port 2222      # SSH not on port 22
  ownexit direct up                                     # redeploy / refresh the subscription (uses the remembered VPS)
  ownexit direct up --sni www.apple.com                 # change the camouflage domain (UUID and keys unchanged; clients re-import)
  ownexit direct up --proxy-port 34567                  # change the proxy port
  ownexit direct up --sub-ttl 30m                       # the subscription service turns itself off after 30 minutes

Maintenance:
  ownexit direct rotate-token               subscription URL may have leaked: get a new subscription URL
  ownexit direct rotate-keys                node credentials may have leaked: new UUID / Reality key / short id (every device re-imports)
  ownexit direct rotate-keys rotate-token   replace both
  ownexit direct add-device phone           give a new device its own credentials and subscription URL (others unaffected)
  ownexit direct remove-device phone        revoke a device
  ownexit direct migrate                    switch an old install made with the 233boy script to this project's service (keeps credentials and port; clients need nothing)
  ownexit direct uninstall                  remove the direct service and the subscription service from the VPS (keeps SSH key login and migration backups)

Day-to-day operations (no redeploy):
  ownexit direct sub start [--ttl 30m]      turn the subscription service on (briefly, to import on a new device; --ttl turns it off when due)
  ownexit direct sub stop                   turn the subscription service off (keep it off normally)
  ownexit direct status                     status of the proxy service and the subscription service
  ownexit direct log [lines]                recent proxy service log, 100 lines by default
  ownexit direct qr                         show the node QR code in the terminal (needs qrencode)
  ownexit direct devices                    list devices and their subscription URLs
  ownexit direct login                      log in to the VPS with the key
  With several remembered VPSes add --host, for example: ownexit direct --host 203.0.113.7 status

Options:
  --host <ip/host>            the exit VPS address; without it the remembered VPS is used, otherwise it asks
  -u, --user <user>           SSH user, default root
  -P, --port <port>           SSH port, default 22
  --sni <domain>              Reality camouflage domain; default for new installs ${DIRECT_SNI_DEFAULT}. Not every HTTPS site works
                              (www.microsoft.com does not in tests); confirm one device can connect after changing it
  --proxy-port <port>         proxy port; random in 20000-59999 for new installs
  --sub-ttl <duration>        how long after starting the subscription service turns itself off (for example 30m, 2h;
                              minutes when no unit is given, 1 minute to 24 hours); without it, run ownexit direct sub stop after importing
  --allow-tun                 refused by default when the route from this computer to the VPS goes through a proxy TUN (SSH would be cut
                              off during deployment); with it, only warn and continue. To route the VPS IP through the physical interface see
                              docs/manual/clash-direct-ips.en.md
  -h, --help                  show this help

migrate, uninstall and rotate-token exclude each other; rotate-keys cannot be combined with migrate / uninstall;
add-device and remove-device exclude each other and cannot be combined with migrate / uninstall; --sni / --proxy-port / --sub-ttl
cannot be combined with uninstall; up cannot be combined with maintenance subcommands; day-to-day operations cannot be combined with
deployment / maintenance options (arguments after a day-to-day operation are handled by it).

Removed in 2.0 (calling them exits 2 and prints the new form):
  --rotate-token / --rotate-keys / --add-device <name> / --remove-device <name> / --migrate / --uninstall
                                       →  rotate-token / rotate-keys / add-device <name> / remove-device <name> / migrate / uninstall
  ownexit subctl <start|stop|status|log|qr|devices|login>   →  ownexit direct sub start / sub stop / status / …

Exit codes: 0 all checks passed; 1 deployment failed or a check did not pass; 2 argument error, missing argument (when not in a
terminal), or the server runs the old install and needs migrate.
EOF
  else
    # i18n:zh-begin
    cat <<EOF
用法: ownexit direct [子命令] [选项]      （git clone 用法：$(basename "$0") [子命令] [选项]）

部署（不带子命令等同 up；第一次会问一次 VPS 的 root 密码）:
  ownexit direct up --host 203.0.113.7
  ownexit direct up --host 203.0.113.7 --port 2222      # SSH 端口不是 22
  ownexit direct up                                     # 重新部署 / 重新拉订阅（自动用上次记住的 VPS）
  ownexit direct up --sni www.apple.com                 # 换伪装域名（UUID 与密钥不变，客户端需重新导入订阅）
  ownexit direct up --proxy-port 34567                  # 换代理端口
  ownexit direct up --sub-ttl 30m                       # 订阅服务 30 分钟后自动关闭

维护:
  ownexit direct rotate-token               怀疑订阅链接泄露：换一个新的订阅地址
  ownexit direct rotate-keys                怀疑节点凭据泄露：换一套新的 UUID / Reality 密钥 / short id（所有设备都要重新导入）
  ownexit direct rotate-keys rotate-token   两者一起换
  ownexit direct add-device phone           给一台新设备单独一套凭据和订阅地址（其它设备不受影响）
  ownexit direct remove-device phone        吊销一台设备
  ownexit direct migrate                    把用 233boy 脚本装的旧版换成本项目的服务（沿用原有凭据与端口，客户端不用动）
  ownexit direct uninstall                  卸载 VPS 上的直连服务与订阅服务（保留 SSH 免密与迁移备份）

日常操作（不重新部署）:
  ownexit direct sub start [--ttl 30m]      打开订阅服务（给新设备导入订阅时临时打开；--ttl 到时自动关闭）
  ownexit direct sub stop                   关闭订阅服务（平时应保持关闭）
  ownexit direct status                     查看代理服务与订阅服务状态
  ownexit direct log [行数]                 查看代理服务最近的日志，默认 100 行
  ownexit direct qr                         在终端显示节点二维码（需要 qrencode）
  ownexit direct devices                    列出设备与各设备的订阅地址
  ownexit direct login                      免密登录 VPS
  记住了多台 VPS 时加 --host 指定，例：ownexit direct --host 203.0.113.7 status

选项:
  --host <ip/host>            出口 VPS 地址；不给时用上次记住的 VPS，没有则交互提问
  -u, --user <user>           SSH 用户名，默认 root
  -P, --port <port>           SSH 端口，默认 22
  --sni <域名>                Reality 伪装域名；新装默认 ${DIRECT_SNI_DEFAULT}。不是每个 HTTPS 站点都能用
                              （实测 www.microsoft.com 不可用），改完先用一台设备确认能连上
  --proxy-port <端口>         代理端口；新装默认在 20000-59999 随机
  --sub-ttl <时长>            订阅服务启动后多久自动关闭（例：30m、2h；不带单位按分钟，1 分钟到 24 小时）；
                              不给则不自动关闭，导入后手动 ownexit direct sub stop
  --allow-tun                 本机到 VPS 的路由经代理 TUN 时默认拒绝（部署途中 SSH 会被切断），加它只警告继续；
                              让 VPS 的 IP 走物理网卡的做法见 docs/manual/clash-direct-ips.md
  -h, --help                  显示帮助

migrate、uninstall、rotate-token 三者互斥；rotate-keys 不能与 migrate / uninstall 同用；
add-device 与 remove-device 互斥，且不能与 migrate / uninstall 同用；--sni / --proxy-port / --sub-ttl 不能与 uninstall 同用；
up 不能与维护子命令同用；日常操作不能与部署 / 维护参数同用（日常操作之后的参数交给它自己处理）。

2.0 已移除的写法（调用时退出 2 并提示新写法）:
  --rotate-token / --rotate-keys / --add-device <名> / --remove-device <名> / --migrate / --uninstall
                                       →  rotate-token / rotate-keys / add-device <名> / remove-device <名> / migrate / uninstall
  ownexit subctl <start|stop|status|log|qr|devices|login>   →  ownexit direct sub start / sub stop / status / …

退出码: 0 全部通过；1 部署失败或有验证项未通过；2 参数错误、缺参数（非终端运行时）或服务器是旧版需要 migrate。
EOF
    # i18n:zh-end
  fi
}

die() {
  echo "[!] $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 输出语言（中文 / 英文）的判断与 L 函数；target_lib.sh 的提示也依赖它，必须先 source。
# shellcheck source=i18n_lib.sh
. "${SCRIPT_DIR}/i18n_lib.sh"
# shellcheck source=target_lib.sh
. "${SCRIPT_DIR}/target_lib.sh"

# 子命令形态（1.5.0）：维护操作写成 direct rotate-keys 等子命令。旧的 --rotate-keys 等参数 1.5.0 废弃、2.0 移除：
# 主循环仍识别它们，但遇到即以退出码 2 结束并给出新写法——不能删掉这些分支让它们落进“未知参数”，
# 那样用户看不到该换成什么（docs/feature/feature-remove-deprecated.md）。
# $1 = 用户写的旧参数，$2 = 对应的新写法（不含 ownexit direct 前缀）。
removed_flag() { die_usage "$(L "$1 已在 2.0 移除，改用：ownexit direct $2" "$1 was removed in 2.0; use: ownexit direct $2")"; }
# --add-device / --remove-device 后面的设备名：$2 存在且不以 - 开头才算给了名字（--add-device --host x 不算），
# 没给时提示里用占位 <名>。只用于拼提示，不校验名字合法性。
removed_device_name() { if [[ -n "${1:-}" && "${1}" != -* ]]; then printf '%s' "$1"; else L '<名>' '<name>'; fi; }
# 出现过 up、维护操作（子命令或旧参数）或部署参数（--sni 等）：之后再出现日常操作词（status 等）就是混用，报错。
SAW_DEPLOY_ARG=0
SAW_UP=0
# 用户显式给出的 --host / --user / --port：转给 subctl 时原样带上。只带显式给出的，不带默认值——
# subctl 没有 --host 时按“唯一记住的目标”解析，硬塞默认端口 22 会盖掉记住的非 22 端口。
FWD_TARGET=()

# 日常操作（原 subctl 的功能）整体转给 subctl，不在这里重写：sub start|stop、status、log、qr、devices、login。
# 日常操作词之后的参数原样交给 subctl 校验与报错（-u / -P 换成 subctl 认的长参数）；exec 后退出码、交互终端都属于 subctl。
# OWNEXIT_VIA_DIRECT=1 是内部标记：subctl 没有它时视为用户直接调用已移除的 ownexit subctl，退出 2。
forward_to_subctl() {
  local word="$1" arg subctl_args
  shift
  (( SAW_DEPLOY_ARG == 0 )) || die_usage "$(L "${word} 是日常操作，不能与部署 / 维护参数同用（用 --help 查看用法）" "${word} is a day-to-day operation and cannot be combined with deployment / maintenance options (see --help)")"
  if [[ "${word}" == sub ]]; then
    [[ "${1:-}" == start || "${1:-}" == stop ]] || die_usage "$(L "sub 后面跟 start 或 stop（例：ownexit direct sub stop）" "sub must be followed by start or stop (for example: ownexit direct sub stop)")"
    word="$1"
    shift
  fi
  subctl_args=(${FWD_TARGET[@]+"${FWD_TARGET[@]}"} "${word}")
  for arg in "$@"; do
    [[ "${arg}" != -u ]] || arg=--user
    [[ "${arg}" != -P ]] || arg=--port
    subctl_args+=("${arg}")
  done
  OWNEXIT_VIA_DIRECT=1 exec bash "${SCRIPT_DIR}/subctl" "${subctl_args[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           HOST="${2:?$(L '--host 需要一个参数' '--host needs a value')}"; FWD_TARGET+=(--host "${HOST}"); shift 2 ;;
    --host=*)         HOST="${1#*=}"; FWD_TARGET+=(--host "${HOST}"); shift ;;
    -u|--user)        SSH_USER="${2:?$(L '--user 需要一个参数' '--user needs a value')}"; FWD_TARGET+=(--user "${SSH_USER}"); shift 2 ;;
    --user=*)         SSH_USER="${1#*=}"; FWD_TARGET+=(--user "${SSH_USER}"); shift ;;
    -P|--port)        SSH_PORT="${2:?$(L '--port 需要一个参数' '--port needs a value')}"; FWD_TARGET+=(--port "${SSH_PORT}"); shift 2 ;;
    --port=*)         SSH_PORT="${1#*=}"; FWD_TARGET+=(--port "${SSH_PORT}"); shift ;;
    --sni)            WANT_SNI="${2:?$(L '--sni 需要一个参数' '--sni needs a value')}"; SAW_DEPLOY_ARG=1; shift 2 ;;
    --sni=*)          WANT_SNI="${1#*=}"; SAW_DEPLOY_ARG=1; shift ;;
    --proxy-port)     WANT_PROXY_PORT="${2:?$(L '--proxy-port 需要一个参数' '--proxy-port needs a value')}"; SAW_DEPLOY_ARG=1; shift 2 ;;
    --proxy-port=*)   WANT_PROXY_PORT="${1#*=}"; SAW_DEPLOY_ARG=1; shift ;;
    --sub-ttl)        WANT_SUB_TTL="${2:?$(L '--sub-ttl 需要一个时长' '--sub-ttl needs a duration')}"; SAW_DEPLOY_ARG=1; shift 2 ;;
    --sub-ttl=*)      WANT_SUB_TTL="${1#*=}"; SAW_DEPLOY_ARG=1; shift ;;
    # 2.0 已移除的旧参数：遇到即退出 2，先于后面的互斥检查，和什么参数组合都得到同一条提示。
    --migrate)        removed_flag --migrate migrate ;;
    --uninstall)      removed_flag --uninstall uninstall ;;
    --rotate-token)   removed_flag --rotate-token rotate-token ;;
    --rotate-keys)    removed_flag --rotate-keys rotate-keys ;;
    --add-device)     removed_flag --add-device "add-device $(removed_device_name "${2:-}")" ;;
    --add-device=*)   removed_flag --add-device "add-device $(removed_device_name "${1#*=}")" ;;
    --remove-device)  removed_flag --remove-device "remove-device $(removed_device_name "${2:-}")" ;;
    --remove-device=*) removed_flag --remove-device "remove-device $(removed_device_name "${1#*=}")" ;;
    --allow-tun)      ALLOW_TUN=1; SAW_DEPLOY_ARG=1; shift ;;
    # 子命令（1.5.0 起的写法）：后面的互斥检查与执行路径都按这组变量判断。
    up)               SAW_UP=1; SAW_DEPLOY_ARG=1; shift ;;
    rotate-keys)      ROTATE_KEYS=1; SAW_DEPLOY_ARG=1; shift ;;
    rotate-token)     ROTATE_TOKEN=1; SAW_DEPLOY_ARG=1; shift ;;
    migrate)          DO_MIGRATE=1; SAW_DEPLOY_ARG=1; shift ;;
    uninstall)        DO_UNINSTALL=1; SAW_DEPLOY_ARG=1; shift ;;
    add-device)       [[ $# -ge 2 && -n "$2" ]] || die_usage "$(L "add-device 需要一个设备名（例：ownexit direct add-device phone）" "add-device needs a device name (for example: ownexit direct add-device phone)")"
                      WANT_ADD_DEVICE="$2"; SAW_DEPLOY_ARG=1; shift 2 ;;
    remove-device)    [[ $# -ge 2 && -n "$2" ]] || die_usage "$(L "remove-device 需要一个设备名（例：ownexit direct remove-device phone）" "remove-device needs a device name (for example: ownexit direct remove-device phone)")"
                      WANT_REMOVE_DEVICE="$2"; SAW_DEPLOY_ARG=1; shift 2 ;;
    sub|status|log|qr|devices|login)
                      FWD_WORD="$1"; shift; forward_to_subctl "${FWD_WORD}" "$@" ;;
    -h|--help)        usage; exit 0 ;;
    *)                die_usage "$(L "未知参数: $1（用 --help 查看用法）" "Unknown option: $1 (see --help)")" ;;
  esac
done

if [[ "${SAW_UP}" == 1 ]] && { (( DO_MIGRATE + DO_UNINSTALL + ROTATE_TOKEN + ROTATE_KEYS > 0 )) || [[ -n "${WANT_ADD_DEVICE}${WANT_REMOVE_DEVICE}" ]]; }; then
  die_usage "$(L "up 只用于部署，不能与 migrate / uninstall / rotate-token / rotate-keys / add-device / remove-device 同用" "up is only for deploying and cannot be combined with migrate / uninstall / rotate-token / rotate-keys / add-device / remove-device")"
fi
(( DO_MIGRATE + DO_UNINSTALL + ROTATE_TOKEN <= 1 )) || die_usage "$(L "migrate、uninstall、rotate-token 只能选一个" "Choose only one of migrate, uninstall and rotate-token")"
# 迁移承诺“沿用旧凭据”，与轮换矛盾；卸载后无凭据可换。要换旧版的凭据：先 migrate，再 rotate-keys。
(( DO_MIGRATE + DO_UNINSTALL + ROTATE_KEYS <= 1 )) || die_usage "$(L "rotate-keys 不能与 migrate / uninstall 同用（旧版先 migrate 再 rotate-keys）" "rotate-keys cannot be combined with migrate / uninstall (for an old install, migrate first, then rotate-keys)")"
if [[ -n "${WANT_ADD_DEVICE}" || -n "${WANT_REMOVE_DEVICE}" ]]; then
  [[ -z "${WANT_ADD_DEVICE}" || -z "${WANT_REMOVE_DEVICE}" ]] || die_usage "$(L "add-device 与 remove-device 一次只能用一个" "Use only one of add-device and remove-device at a time")"
  (( DO_MIGRATE + DO_UNINSTALL == 0 )) || die_usage "$(L "add-device / remove-device 不能与 migrate / uninstall 同用" "add-device / remove-device cannot be combined with migrate / uninstall")"
  DEVICE_ARG="${WANT_ADD_DEVICE}${WANT_REMOVE_DEVICE}"
  [[ "${DEVICE_ARG}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die_usage "$(L "设备名只允许小写字母、数字和 -，最多 32 个字符：${DEVICE_ARG}" "Device names may contain only lowercase letters, digits and -, up to 32 characters: ${DEVICE_ARG}")"
  [[ "${DEVICE_ARG}" != default ]] || die_usage "$(L "default 指现有的那套凭据，不能新增或吊销；要整体换凭据用 ownexit direct rotate-keys" "default refers to the existing credentials and cannot be added or revoked; to replace all credentials use ownexit direct rotate-keys")"
fi
if [[ "${DO_UNINSTALL}" == 1 && ( -n "${WANT_SNI}" || -n "${WANT_PROXY_PORT}" || -n "${WANT_SUB_TTL}" ) ]]; then
  die_usage "$(L "uninstall 不能与 --sni / --proxy-port / --sub-ttl 同用" "uninstall cannot be combined with --sni / --proxy-port / --sub-ttl")"
fi
if [[ -n "${WANT_SUB_TTL}" ]]; then
  SUB_TTL_SECONDS="$(parse_ttl "${WANT_SUB_TTL}")" || exit 2
  # 不带单位按分钟：提示里补上 m，避免显示成“30 后自动关闭”。
  [[ "${WANT_SUB_TTL}" =~ [smh]$ ]] || WANT_SUB_TTL="${WANT_SUB_TTL}m"
fi
if [[ -n "${WANT_SNI}" && ! "${WANT_SNI}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
  die_usage "$(L "--sni 必须是域名：${WANT_SNI}" "--sni must be a domain name: ${WANT_SNI}")"
fi
if [[ -n "${WANT_PROXY_PORT}" ]] && { [[ ! "${WANT_PROXY_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] || (( WANT_PROXY_PORT > 65535 )); }; then
  die_usage "$(L "--proxy-port 必须是 1-65535 的数字：${WANT_PROXY_PORT}" "--proxy-port must be a number from 1 to 65535: ${WANT_PROXY_PORT}")"
fi

resolve_target
if [[ "${SSH_USER}" != "root" ]]; then
  echo "$(L "[!] 注意：本脚本的远程命令（sysctl/systemctl/apt 等）按 root 设计，非 root 用户大概率失败" "[!] Note: the remote commands of this script (sysctl/systemctl/apt and so on) are designed for root; a non-root user will most likely fail")"
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

# 非交互远程执行
vssh() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "$@"
}

# 从 KEY=VALUE 文本里取一个键（只按行解析，不 eval）。
kv_get() {
  printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

FAIL_COUNT=0
pass() { echo "[+] $*"; }
fail() { echo "[!] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------- 0. 部署前自检：本机到 VPS 的路由是否经代理 TUN（docs/feature/feature-usability-v12.md §5.1.6） ----------
# 与 doctor.sh / chain/setup_chain.sh 的 route_interface / interface_is_tunnel 同一实现。
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
# 经 TUN 时部署途中的 SSH 会被代理切断，默认拒绝；--allow-tun 只警告。只核 IPv4 字面量（主机名会被 fake-ip 解析误判）；
# 取不到出接口只警告继续。
tun_precheck() {
  local ip iface
  ip="$1"
  if [[ ! "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$(L "[*] 目标 ${ip} 不是 IPv4，跳过 TUN 自检" "[*] Target ${ip} is not IPv4; skipping the TUN self-check")"
    return 0
  fi
  iface="$(route_interface "${ip}" || true)"  # 缺 route / ip 命令时管道失败，set -e 下会静默退出；这里只要“取不到就跳过”
  if [[ -z "${iface}" ]]; then
    echo "$(L "[*] 无法判定到 ${ip} 的出接口，跳过 TUN 自检" "[*] Cannot determine the outgoing interface for ${ip}; skipping the TUN self-check")"
    return 0
  fi
  interface_is_tunnel "${iface}" || return 0
  if [[ "${ALLOW_TUN}" == 1 ]]; then
    echo "$(L "[!] 到 ${ip} 的路由经过 TUN（${iface}），已加 --allow-tun 继续；部署期间 SSH 可能被代理切断" "[!] The route to ${ip} goes through TUN (${iface}); continuing because of --allow-tun; SSH may be cut off by the proxy during deployment")"
    return 0
  fi
  # 三行说明写成单行 L + 换行符（$'\n' 拼接），保证 check_ui_lang 能认出整条提示都在 L 里。
  die "$(L "到 ${ip} 的路由经过 TUN（${iface}），部署期间 SSH 会被代理切断。" "The route to ${ip} goes through TUN (${iface}); SSH would be cut off by the proxy during deployment.")"$'\n'"$(L '处理办法：关闭代理的 TUN 模式；或让这个 IP 走物理网卡（Clash Verge 见 docs/manual/clash-direct-ips.md）。' 'Fix: turn off the proxy'"'"'s TUN mode, or route this IP through the physical interface (Clash Verge: docs/manual/clash-direct-ips.en.md).')"$'\n'"$(L '已按手册加了直连规则且 SSH 正常，或确认要继续：加 --allow-tun。' 'If you have added the direct rule as described and SSH works, or you really want to continue: add --allow-tun.')"
}
tun_precheck "${HOST}"

# ---------- 1. 免密 SSH 与系统信息 ----------

echo "$(L "[*] 检查免密 SSH：${SSH_USER}@${HOST}:${SSH_PORT}" "[*] Checking key-based SSH: ${SSH_USER}@${HOST}:${SSH_PORT}")"
if [[ ! -f "${KEY}" ]] || ! vssh "exit" >/dev/null 2>&1; then
  # 第一次部署或 VPS 重装后免密失效：直接调用 connect_to.sh 配好，省掉用户单独跑一条命令。
  # connect_to.sh 自己负责问密码、区分"密码错 / 关了密码登录 / 连不上"并打印 reason=...，
  # 这里只透传它的退出码，不重复解释失败原因。
  echo "$(L "[*] 免密不可用，调用 connect_to.sh 配置免密（会问一次 VPS 密码）" "[*] Key login does not work yet; running connect_to.sh to set it up (asks once for the VPS password)")"
  connect_rc=0
  # 用 bash 显式执行兄弟脚本：pip 安装的副本不保证保留可执行位。
  bash "${SCRIPT_DIR}/connect_to.sh" --setup-only --host "${HOST}" --port "${SSH_PORT}" --user "${SSH_USER}" \
    || connect_rc=$?
  [[ "${connect_rc}" -eq 0 ]] || exit "${connect_rc}"
  vssh "exit" >/dev/null 2>&1 || die "$(L "connect_to.sh 报告成功，但免密登录仍不可用，请人工检查 ${KEY}" "connect_to.sh reported success but key login still does not work; check ${KEY} by hand")"
fi
pass "$(L "免密 SSH 可用" "Key-based SSH works")"

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
[[ -n "${OS_INFO}" ]] || die "$(L "读取 VPS 系统信息失败（SSH 命令连续 2 次失败），请稍后重跑；免密已配好，不会再问密码" "Could not read the VPS system information (the SSH command failed twice); rerun later — key login is set up, so the password will not be asked again")"
OS_ID="$(printf '%s\n' "${OS_INFO}" | sed -n 1p)"
OS_PRETTY="$(printf '%s\n' "${OS_INFO}" | sed -n 2p)"
case "${OS_ID}" in
  debian|ubuntu)
    pass "$(L "VPS 系统：${OS_PRETTY}" "VPS system: ${OS_PRETTY}")"
    ;;
  *)
    die "$(L "VPS 系统为 '${OS_ID:-未知}'，本脚本只按 Debian/Ubuntu 设计，不猜其它发行版的包管理器，停止" "The VPS system is '${OS_ID:-unknown}'; this script is designed only for Debian/Ubuntu and will not guess other distributions' package managers; stopping")"
    ;;
esac

# 基础工具：curl（验 IP、下载官方包）、python3（订阅服务、读迁移配置）、tar（解压官方包）
if [[ "${DO_UNINSTALL}" == 0 ]]; then
  echo "$(L "[*] 检查 VPS 基础工具（curl / python3 / tar）" "[*] Checking basic tools on the VPS (curl / python3 / tar)")"
  MISSING_PKGS="$(vssh 'missing=""; for c in curl python3 tar; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done; echo "$missing"' | xargs || true)"
  if [[ -n "${MISSING_PKGS}" ]]; then
    echo "$(L "[*] 安装缺失工具：${MISSING_PKGS}" "[*] Installing missing tools: ${MISSING_PKGS}")"
    vssh "apt-get update -qq && apt-get install -y -qq ${MISSING_PKGS}" \
      || die "$(L "apt 安装 ${MISSING_PKGS} 失败" "apt failed to install ${MISSING_PKGS}")"
  fi
  pass "$(L "基础工具就绪" "Basic tools ready")"
fi

# 免密和系统都确认可用后才记住这台 VPS，避免把一个连不上或不支持的目标记成"上次的 VPS"。
save_target

if [[ "${DO_UNINSTALL}" == 0 ]]; then
  # ---------- 2. VPS 公网 IP ----------

  echo "$(L "[*] 读取 VPS 公网 IP（curl ipinfo.io）" "[*] Reading the VPS public IP (curl ipinfo.io)")"
  VPS_PUBLIC_IP="$(vssh "curl -fsS -m 15 ipinfo.io/ip" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "${VPS_PUBLIC_IP}" ]]; then
    fail "$(L "VPS 上 curl ipinfo.io 失败，无法确认公网 IP；节点地址将退回使用 SSH 地址 ${HOST}" "curl ipinfo.io failed on the VPS, so the public IP cannot be confirmed; the node address falls back to the SSH address ${HOST}")"
  else
    pass "$(L "VPS 公网 IP：${VPS_PUBLIC_IP}" "VPS public IP: ${VPS_PUBLIC_IP}")"
    if [[ "${VPS_PUBLIC_IP}" != "${HOST}" ]]; then
      echo "$(L "[!] 注意：VPS 出口 IP（${VPS_PUBLIC_IP}）与 SSH 地址（${HOST}）不一致，请人工确认是否符合预期" "[!] Note: the VPS exit IP (${VPS_PUBLIC_IP}) differs from the SSH address (${HOST}); check whether that is what you expect")"
    fi
  fi

  # ---------- 3. 幂等开启 BBR ----------

  echo "$(L "[*] 开启 BBR（幂等，重复执行无害）" "[*] Enabling BBR (idempotent; harmless to repeat)")"
  # 远端 heredoc 的内容与结束标记必须顶格：缩进的 EOF 不会结束 heredoc，sysctl 一条都不会执行。
  BBR_NOW="$(vssh "cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1
sysctl -n net.ipv4.tcp_congestion_control" || true)"
  if [[ "${BBR_NOW}" == "bbr" ]]; then
    pass "$(L "BBR 已启用" "BBR enabled")"
  else
    fail "$(L "BBR 未生效（当前拥塞算法：${BBR_NOW:-未知}），可能内核过旧，请人工检查" "BBR is not active (current congestion control: ${BBR_NOW:-unknown}); the kernel may be too old, check by hand")"
  fi
fi

# 订阅 TOKEN 是"VPS 上订阅目录名"的唯一记录，丢了就只能 rotate-token，所以放 XDG state 而不是可随时清空的 cache。
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/ownexit/direct/${SAFE_NAME}"
STATE_FILE="${STATE_DIR}/state.env"
STAGING="${STATE_DIR}/${SUB_SERVICE}"
OLD_TOKEN=""
SUB_PORT=""
TOKEN=""
if [[ -f "${STATE_FILE}" ]]; then
  # state.env 只含本脚本写入的 SUB_PORT / TOKEN 两个键（权限 600），按行解析不 source。
  SUB_PORT="$(kv_get "$(cat "${STATE_FILE}")" SUB_PORT)"
  TOKEN="$(kv_get "$(cat "${STATE_FILE}")" TOKEN)"
fi

# ---------- 同机链提示（§5.1.8） ----------

# 找出 RELAY_HOST 等于本次 HOST 的链：直连在这台机器上的任何变动都会让这些链的预检 / 基线核验失败，
# 需要用户运行 rebaseline 重新登记（转发本身不受影响）。只按 KEY=VALUE 逐行读，不 source 链配置。
print_chain_hints() {
  local dir file relay id found=0
  dir="${XDG_CONFIG_HOME:-${HOME}/.config}/ownexit/chains"
  [[ -d "${dir}" ]] || return 0
  for file in "${dir}"/*.env; do
    [[ -f "${file}" ]] || continue
    relay="$(awk -F= '$1 == "RELAY_HOST" { sub(/^[^=]*=/, ""); print; exit }' "${file}")"
    [[ "${relay}" == "${HOST}" ]] || continue
    id="$(basename "${file}" .env)"
    if [[ "${found}" == 0 ]]; then
      echo
      echo "$(L "[!] 这台 VPS 也是链式部署的中转机。直连的变动会让下列链的 verify / status / rollback 在预检或基线核验处失败" "[!] This VPS is also the relay of a relay chain. Changes to direct make verify / status / rollback of the chains below fail at the precheck or baseline check")"
      echo "$(L "    （中转转发本身不受影响），请运行：" "    (relay forwarding itself is unaffected); run:")"
      found=1
    fi
    echo "      ownexit chain --id ${id} rebaseline"
  done
}

# ---------- 4. 服务器状态探测与操作（§5.1.2–§5.1.7） ----------

case "$(vssh 'uname -m' 2>/dev/null || true)" in
  x86_64)  REMOTE_ARCH=amd64; ARCHIVE_SHA256="${ARCHIVE_SHA256_LINUX_AMD64}"; BINARY_SHA256="${BINARY_SHA256_LINUX_AMD64}" ;;
  aarch64) REMOTE_ARCH=arm64; ARCHIVE_SHA256="${ARCHIVE_SHA256_LINUX_ARM64}"; BINARY_SHA256="${BINARY_SHA256_LINUX_ARM64}" ;;
  *)       die "$(L "VPS CPU 架构不受支持（只支持 x86_64 / aarch64）" "Unsupported VPS CPU architecture (only x86_64 / aarch64)")" ;;
esac
ARCHIVE_NAME="sing-box-${SING_BOX_VERSION}-linux-${REMOTE_ARCH}.tar.gz"

# 把服务器端脚本投递到 VPS（root 700 目录），每次都覆盖为本版本，避免恢复执行时跑到旧版脚本。
upload_remote_script() {
  vssh "install -d -m 700 '${REMOTE_WORK}' && cat > '${REMOTE_WORK}/op.sh' && chmod 600 '${REMOTE_WORK}/op.sh'" \
    < "${SCRIPT_DIR}/direct_remote.sh" || die "$(L "无法把 direct_remote.sh 上传到 VPS" "Could not upload direct_remote.sh to the VPS")"
}

probe_server() {
  # 探测输出里的提示跟随本机语言；OWNEXIT_UI_LANG 只会是 zh / en（i18n_lib.sh 归一化过），可以直接拼进远端命令。
  PROBE="$(vssh "OWNEXIT_UI_LANG=${OWNEXIT_UI_LANG} bash '${REMOTE_WORK}/op.sh' probe" 2>/dev/null)" || die "$(L "服务器状态探测失败（SSH 中断或脚本异常），请重跑" "Probing the server state failed (SSH dropped or the script failed); please rerun")"
  STATE="$(kv_get "${PROBE}" STATE)"
  [[ -n "${STATE}" ]] || die "$(L "服务器状态探测没有返回 STATE：${PROBE}" "Probing the server state returned no STATE: ${PROBE}")"
}

local_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

# VPS 下载官方包失败时：本机固定从官方地址下载、校验归档摘要，再上传到 VPS 保留的暂存目录。
upload_archive_from_local() {
  local stage="$1" tmp
  [[ "${stage}" == /opt/ownexit-direct/.stage-* ]] || die "$(L "VPS 返回的暂存目录不合法：${stage}" "The staging directory returned by the VPS is invalid: ${stage}")"
  tmp="$(mktemp -d)"
  echo "$(L "[*] VPS 下载官方包失败，改由本机下载 ${ARCHIVE_NAME} 后上传" "[*] The VPS failed to download the official package; downloading ${ARCHIVE_NAME} on this computer and uploading it instead")"
  if ! curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 --max-time 600 \
      -o "${tmp}/archive.tar.gz" "${OFFICIAL_RELEASE_BASE_URL}/${ARCHIVE_NAME}"; then
    rm -rf "${tmp}"
    die "$(L "本机也无法下载 ${ARCHIVE_NAME}（需要能访问 github.com）；VPS 上的操作保持在可恢复状态，网络恢复后重跑即可" "This computer cannot download ${ARCHIVE_NAME} either (github.com must be reachable); the operation on the VPS stays recoverable, so rerun once the network is back")"
  fi
  [[ "$(local_sha256 "${tmp}/archive.tar.gz")" == "${ARCHIVE_SHA256}" ]] || { rm -rf "${tmp}"; die "$(L "本机下载的官方包摘要不符，停止" "The digest of the official package downloaded on this computer does not match; stopping")"; }
  scp -q -i "${KEY}" -P "${SSH_PORT}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "${tmp}/archive.tar.gz" "${SSH_USER}@${HOST}:${stage}/archive.tar.gz" || { rm -rf "${tmp}"; die "$(L "上传官方包到 VPS 失败" "Uploading the official package to the VPS failed")"; }
  rm -rf "${tmp}"
}

# 写 op.args：只放业务参数，测试钩子不进这里（恢复执行时不应再次触发）。
write_op_args() {
  local op="$1"; shift
  {
    printf 'OP=%s\n' "${op}"
    printf 'VERSION=%s\nARCH=%s\nARCHIVE_SHA256=%s\nBINARY_SHA256=%s\nRELEASE_URL=%s/%s\n' \
      "${SING_BOX_VERSION}" "${REMOTE_ARCH}" "${ARCHIVE_SHA256}" "${BINARY_SHA256}" "${REMOTE_RELEASE_BASE_URL}" "${ARCHIVE_NAME}"
    printf 'SUB_PORT=%s\n' "${SUB_PORT}"
    local kv
    for kv in "$@"; do printf '%s\n' "${kv}"; done
  } | vssh "cat > '${REMOTE_WORK}/op.args' && chmod 600 '${REMOTE_WORK}/op.args'" || die "$(L "无法写入 VPS 上的 op.args" "Could not write op.args on the VPS")"
}

# 启动（或等待已在运行的）临时单元并取回结果。临时单元由 systemd 托管，与本次 SSH 会话无关：
# 本机断网 / 退出不影响它；这里只是轮询，不能用 --wait 把结果绑在 SSH 连接上。
# 结果写入全局 OP_RESULT（result.env 的全文）。
execute_remote_op() {
  local offset active setenv='' tries
  offset="$(vssh "stat -c %s '${REMOTE_WORK}/op.log' 2>/dev/null || echo 0" | tr -d '[:space:]')"
  [[ "${offset}" =~ ^[0-9]+$ ]] || offset=0
  active="$(vssh "systemctl show '${OP_UNIT}' -p ActiveState --value 2>/dev/null" | tr -d '[:space:]' || true)"
  if [[ "${active}" != active && "${active}" != activating && "${active}" != deactivating && "${active}" != reloading ]]; then
    # 临时单元不继承 SSH 会话的环境，服务端日志（op.log 里的 [vps] 行）的语言必须显式传进去。
    setenv=" --setenv=OWNEXIT_UI_LANG=${OWNEXIT_UI_LANG}"
    [[ -z "${OWNEXIT_TEST_DIRECT_FAIL_AT:-}" ]] || setenv="${setenv} --setenv=OWNEXIT_TEST_DIRECT_FAIL_AT=${OWNEXIT_TEST_DIRECT_FAIL_AT}"
    [[ -z "${OWNEXIT_TEST_DIRECT_PAUSE_AT:-}" ]] || setenv="${setenv} --setenv=OWNEXIT_TEST_DIRECT_PAUSE_AT=${OWNEXIT_TEST_DIRECT_PAUSE_AT}"
    vssh "rm -f '${REMOTE_WORK}/result.env'; systemctl reset-failed '${OP_UNIT}' >/dev/null 2>&1; \
      systemd-run --unit='${OP_UNIT}' --collect --quiet \
        -p StandardOutput=append:${REMOTE_WORK}/op.log -p StandardError=append:${REMOTE_WORK}/op.log${setenv} \
        bash '${REMOTE_WORK}/op.sh' run" || die "$(L "无法在 VPS 上启动 ${OP_UNIT}（需要 systemd ≥ 240）" "Cannot start ${OP_UNIT} on the VPS (systemd 240 or later is required)")"
  else
    echo "$(L "[*] VPS 上已有一个操作在运行，等待它结束" "[*] An operation is already running on the VPS; waiting for it to finish")"
  fi
  tries=0
  while :; do
    sleep 2
    if active="$(vssh "systemctl show '${OP_UNIT}' -p ActiveState --value 2>/dev/null" 2>/dev/null)"; then
      tries=0
      active="$(printf '%s' "${active}" | tr -d '[:space:]')"
      case "${active}" in active|activating|deactivating|reloading) continue ;; esac
      break
    fi
    # SSH 断开：操作仍在 VPS 上继续，这里重连等待即可。
    tries=$((tries + 1))
    (( tries <= 60 )) || die "$(L "与 VPS 的连接持续中断；VPS 上的操作会自行完成，网络恢复后重跑本命令即可看到结果" "The connection to the VPS keeps dropping; the operation on the VPS will finish by itself, so rerun this command once the network is back to see the result")"
  done
  vssh "tail -c +$((offset + 1)) '${REMOTE_WORK}/op.log' 2>/dev/null" | sed 's/^/    [vps] /' || true
  OP_RESULT="$(vssh "cat '${REMOTE_WORK}/result.env' 2>/dev/null" || true)"
}

# 执行一个操作直到有结论：下载失败时走本机上传后以同一操作重入（最多一次）。
run_op_to_end() {
  local reason
  execute_remote_op
  reason="$(kv_get "${OP_RESULT}" REASON)"
  if [[ "$(kv_get "${OP_RESULT}" RESULT)" == fail && "${reason}" == download ]]; then
    upload_archive_from_local "$(kv_get "${OP_RESULT}" STAGE)"
    execute_remote_op
  fi
  [[ -n "$(kv_get "${OP_RESULT}" RESULT)" ]] || die "$(L "VPS 上的操作没有留下结果（可能被中断），重跑本命令会自动恢复" "The operation on the VPS left no result (it may have been interrupted); rerunning this command recovers it automatically")"
  local backup
  backup="$(kv_get "${OP_RESULT}" BACKUP)"
  [[ -z "${backup}" ]] || echo "$(L "[*] 迁移备份：${backup}（含旧私钥，确认无需回退后可自行删除）" "[*] Migration backup: ${backup} (contains the old private key; delete it yourself once you are sure you will not roll back)")"
  echo "$(L "[*] 服务器操作 OP=$(kv_get "${OP_RESULT}" OP) 结果=$(kv_get "${OP_RESULT}" RESULT) reason=$(kv_get "${OP_RESULT}" REASON)" "[*] Server operation OP=$(kv_get "${OP_RESULT}" OP) result=$(kv_get "${OP_RESULT}" RESULT) reason=$(kv_get "${OP_RESULT}" REASON)")"
}

start_op() {
  write_op_args "$@"
  run_op_to_end
}

op_ok() { [[ "$(kv_get "${OP_RESULT}" RESULT)" == ok ]]; }

# 订阅端口要在新装前就确定，新装选代理端口时才能避开它。
ensure_sub_params() {
  if [[ "${ROTATE_TOKEN}" == "1" || -z "${TOKEN}" || -z "${SUB_PORT}" ]]; then
    OLD_TOKEN="${TOKEN:-}"
    TOKEN="$(openssl rand -hex 16)"
    # 随机高位订阅端口：确认 VPS 上未被占用
    SUB_PORT=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      SUB_PORT="$(( (RANDOM % 40000) + 20000 ))"
      if ! vssh "ss -ltn | awk '{print \$4}' | grep -q ':${SUB_PORT}\$'" >/dev/null 2>&1; then
        break
      fi
      SUB_PORT=""
    done
    [[ -n "${SUB_PORT}" ]] || die "$(L "连续 10 次未找到空闲订阅端口，请人工检查 VPS 端口占用" "No free subscription port found after 10 tries; check port usage on the VPS by hand")"
    TOKEN_CHANGED=1
    pass "$(L "生成订阅参数：SUB_PORT=${SUB_PORT} TOKEN=${TOKEN}" "Generated subscription parameters: SUB_PORT=${SUB_PORT} TOKEN=${TOKEN}")"
  else
    TOKEN_CHANGED=0
    pass "$(L "复用已有订阅参数：SUB_PORT=${SUB_PORT}（TOKEN 不变；如需轮换用 ownexit direct rotate-token）" "Reusing the existing subscription parameters: SUB_PORT=${SUB_PORT} (TOKEN unchanged; to rotate it use ownexit direct rotate-token)")"
  fi
}

upload_remote_script
probe_server
SYSTEMD_VERSION="$(kv_get "${PROBE}" SYSTEMD_VERSION)"
[[ "${SYSTEMD_VERSION}" =~ ^[0-9]+$ ]] && (( SYSTEMD_VERSION >= 240 )) \
  || die "$(L "VPS 的 systemd 版本为 ${SYSTEMD_VERSION:-未知}，需要 ≥ 240（Debian 10 / Ubuntu 20.04 及以上）" "The VPS systemd version is ${SYSTEMD_VERSION:-unknown}; 240 or later is required (Debian 10 / Ubuntu 20.04 or later)")"
echo "$(L "[*] 服务器状态：STATE=${STATE} ARCH=${REMOTE_ARCH}" "[*] Server state: STATE=${STATE} ARCH=${REMOTE_ARCH}")"

# 未完成的操作先恢复（§5.1.2 第 5 条）：只有成功或已回到可用旧状态（rolled-back）才继续本次请求。
if [[ "${STATE}" == in_progress ]]; then
  echo "$(L "[*] 恢复上次未完成的操作：OP=$(kv_get "${PROBE}" TXN_OP) STEP=$(kv_get "${PROBE}" TXN_STEP)" "[*] Resuming the unfinished operation: OP=$(kv_get "${PROBE}" TXN_OP) STEP=$(kv_get "${PROBE}" TXN_STEP)")"
  RECOVERED_ROTATE="$(kv_get "${PROBE}" TXN_ROTATE)"
  RECOVERED_DEVICE_ADD="$(kv_get "${PROBE}" TXN_DEVICE_ADD)"
  RECOVERED_DEVICE_REMOVE="$(kv_get "${PROBE}" TXN_DEVICE_REMOVE)"
  RECOVERED_PARAMS="$(kv_get "${PROBE}" TXN_PARAMS)"
  run_op_to_end
  if ! op_ok && [[ "$(kv_get "${OP_RESULT}" REASON)" != rolled-back ]]; then
    die "$(L "上次未完成的操作恢复失败（REASON=$(kv_get "${OP_RESULT}" REASON)），本次请求未执行；详见上方 [vps] 日志与 ownexit direct log" "Recovering the unfinished operation failed (REASON=$(kv_get "${OP_RESULT}" REASON)); this request was not carried out; see the [vps] log above and ownexit direct log")"
  fi
  # 恢复完成的是一次改参数：节点参数已变，后面要提示重新导入与同机链的 rebaseline。
  # 只有结果 ok 才算凭据已换；rolled-back 表示回到了旧凭据，本次 rotate-keys 仍要照常执行。
  if [[ "$(kv_get "${OP_RESULT}" OP)" == reparam ]] && op_ok; then
    # 纯设备操作（没有 SNI / 端口 / 轮换变化）不要求其它设备重新导入，只记设备变动。
    # TXN_PARAMS 为空是 v0.6.0 及更早留下的操作：按改参数处理。
    [[ "${RECOVERED_PARAMS}" == 0 ]] || CHANGED_PARAMS_RECOVERED=1
    [[ "${RECOVERED_ROTATE}" != 1 ]] || ROTATED=1
    if [[ -n "${RECOVERED_DEVICE_ADD}${RECOVERED_DEVICE_REMOVE}" ]]; then
      CHANGED_DEVICES=1
      # 恢复完成的正是本次要做的设备操作：不再重复提交（否则会报 device-exists / device-missing）。
      if [[ -n "${WANT_ADD_DEVICE}" && "${WANT_ADD_DEVICE}" == "${RECOVERED_DEVICE_ADD}" ]]; then
        echo "$(L "[*] 刚恢复完成的操作已经新增了设备 ${WANT_ADD_DEVICE}，本次不再重复" "[*] The operation just recovered already added device ${WANT_ADD_DEVICE}; not repeating it")"
        WANT_ADD_DEVICE=""
      fi
      if [[ -n "${WANT_REMOVE_DEVICE}" && "${WANT_REMOVE_DEVICE}" == "${RECOVERED_DEVICE_REMOVE}" ]]; then
        echo "$(L "[*] 刚恢复完成的操作已经吊销了设备 ${WANT_REMOVE_DEVICE}，本次不再重复" "[*] The operation just recovered already revoked device ${WANT_REMOVE_DEVICE}; not repeating it")"
        WANT_REMOVE_DEVICE=""
      fi
    fi
  fi
  probe_server
  echo "$(L "[*] 恢复后的服务器状态：STATE=${STATE}" "[*] Server state after recovery: STATE=${STATE}")"
fi

# ---------- 卸载分支（§5.1.7） ----------

if [[ "${DO_UNINSTALL}" == 1 ]]; then
  case "${STATE}" in
    legacy) die "$(L "服务器是 233boy 旧版，ownexit 不会卸载它：先运行 ownexit direct migrate，或在 VPS 上用 233boy 自带的卸载" "The server runs the old 233boy install, which ownexit will not uninstall: run ownexit direct migrate first, or uninstall it on the VPS with 233boy's own uninstaller")" ;;
  esac
  LEFTOVER_STATE="${STATE}"
  # 先取消订阅自动关闭计时器：卸载后它到点去停一个已不存在的服务，会留下失败的瞬时单元。
  vssh "$(ttl_remote_cmd)" || true
  start_op uninstall
  op_ok || die "$(L "卸载未完成（REASON=$(kv_get "${OP_RESULT}" REASON)）；重跑 ownexit direct uninstall 会从中断处继续" "Uninstall did not finish (REASON=$(kv_get "${OP_RESULT}" REASON)); rerunning ownexit direct uninstall continues from where it stopped")"
  # 结果已读到、临时单元已结束：最后才删工作目录（结果通道在其中）。
  vssh "systemctl is-active --quiet '${OP_UNIT}' || rm -rf '${REMOTE_WORK}'" || true
  RESIDUE="$(vssh 'for u in ownexit-direct.service ownexit-subscription.service; do s=$(systemctl show "$u" -p LoadState --value 2>/dev/null); [ "$s" = not-found ] || echo "$u($s)"; done; for d in /etc/ownexit-direct /opt/ownexit-direct /opt/ownexit-subscription /var/lib/ownexit-direct; do [ -e "$d" ] && echo "$d"; done; true')"
  [[ -z "${RESIDUE}" ]] || die "$(L "卸载后仍有残留：$(printf '%s' "${RESIDUE}" | tr '\n' ' ')" "Leftovers remain after uninstall: $(printf '%s' "${RESIDUE}" | tr '\n' ' ')")"
  pass "$(L "卸载残留核验通过" "Uninstall leftover check passed")"
  rm -rf "${STATE_DIR}"
  if [[ "${LEFTOVER_STATE}" == conflict || "${LEFTOVER_STATE}" == migrated_leftover ]]; then
    # 卸载后实时核对 VPS 上剩下的 233boy / 其它 sing-box 文件（卸载前的 SEEN 还包含已删掉的 ownexit 路径）。
    OTHERS="$(vssh 'for p in /usr/local/bin/sb /usr/local/bin/sing-box /etc/sing-box /lib/systemd/system/sing-box.service; do [ -e "$p" ] || [ -L "$p" ] && echo "$p"; done; s=$(systemctl show sing-box.service -p LoadState --value 2>/dev/null); [ "$s" = not-found ] || echo "sing-box.service($s)"; true')"
    if [[ -n "${OTHERS}" && "${LEFTOVER_STATE}" == conflict ]]; then
      # §5.1.3 conflict 行：只删 ownexit 的路径后仍不是 none，按失败退出。
      rm -rf "${STATE_DIR}"
      die "$(L "已删除 ownexit 的文件，但 VPS 上仍有其它 sing-box 相关文件，未处理：$(printf '%s' "${OTHERS}" | tr '\n' ' ')" "ownexit's files were deleted, but other sing-box related files remain on the VPS and were not touched: $(printf '%s' "${OTHERS}" | tr '\n' ' ')")"
    elif [[ -n "${OTHERS}" ]]; then
      echo "$(L "[!] 卸载只删除了 ownexit 的文件；VPS 上的 233boy 残留未处理：$(printf '%s' "${OTHERS}" | tr '\n' ' ')" "[!] Uninstall only removed ownexit's files; the 233boy leftovers on the VPS were not touched: $(printf '%s' "${OTHERS}" | tr '\n' ' ')")"
    fi
  fi
  vssh 'ls /var/backups/ownexit-direct/*.tar.gz 2>/dev/null' | while IFS= read -r backup_file; do
    echo "$(L "[*] 迁移备份仍保留（含旧私钥）：${backup_file}" "[*] Migration backup kept (contains the old private key): ${backup_file}")"
  done || true
  echo "$(L "[*] 保留：SSH 免密密钥 ${KEY}、记住的目标、BBR 设置" "[*] Kept: the SSH key ${KEY}, the remembered target, the BBR setting")"
  print_chain_hints
  echo "$(L "[+] 卸载完成" "[+] Uninstall complete")"
  exit 0
fi

# ---------- 新装 / 复用 / 改参数 / 迁移 ----------

read_client_env() {
  CLIENT_ENV="$(vssh "cat /etc/ownexit-direct/client.env" 2>/dev/null)" || die "$(L "无法读取 VPS 上的 /etc/ownexit-direct/client.env" "Could not read /etc/ownexit-direct/client.env on the VPS")"
}

server_port_in_use() {
  vssh "ss -H -ltn | awk '{print \$4}' | grep -Eq '[:.]$1\$'" >/dev/null 2>&1
}

CHANGED_PARAMS="${CHANGED_PARAMS_RECOVERED:-0}"
DO_ROTATE=0
case "${STATE}" in
  none)
    [[ "${DO_MIGRATE}" == 0 ]] || { echo "$(L "[!] 服务器上没有可迁移的 233boy 旧版" "[!] There is no old 233boy install on the server to migrate")" >&2; exit 2; }
    [[ "${ROTATE_KEYS}" == 0 ]] || echo "$(L "[*] 新装本来就会生成全新凭据，忽略 rotate-keys" "[*] A new install generates fresh credentials anyway; ignoring rotate-keys")"
    [[ -z "${WANT_ADD_DEVICE}${WANT_REMOVE_DEVICE}" ]] || die_usage "$(L "服务器上还没有部署：先运行 ownexit direct up 完成部署，再新增 / 吊销设备" "Nothing is deployed on the server yet: run ownexit direct up to deploy first, then add / revoke devices")"
    ensure_sub_params
    if [[ -n "${WANT_PROXY_PORT}" ]]; then
      [[ "${WANT_PROXY_PORT}" != "${SUB_PORT}" ]] || die_usage "$(L "--proxy-port 与订阅端口 ${SUB_PORT} 相同，请换一个" "--proxy-port is the same as the subscription port ${SUB_PORT}; choose another")"
      ! server_port_in_use "${WANT_PROXY_PORT}" || die_usage "$(L "VPS 上端口 ${WANT_PROXY_PORT} 已被占用" "Port ${WANT_PROXY_PORT} is already in use on the VPS")"
    fi
    echo "$(L "[*] 新装：服务器自己下载 sing-box ${SING_BOX_VERSION} 官方包并生成密钥" "[*] New install: the server downloads the official sing-box ${SING_BOX_VERSION} package itself and generates the keys")"
    start_op fresh "SNI=${WANT_SNI:-${DIRECT_SNI_DEFAULT}}" "PROXY_PORT=${WANT_PROXY_PORT}"
    op_ok || die "$(L "新装失败（REASON=$(kv_get "${OP_RESULT}" REASON)），VPS 已撤销本次写入；处理后重跑即可" "New install failed (REASON=$(kv_get "${OP_RESULT}" REASON)); the VPS has undone this run's changes; fix the problem and rerun")"
    ;;
  ownexit|migrated_leftover)
    if [[ "${STATE}" == migrated_leftover && "${DO_MIGRATE}" == 1 ]]; then
      echo "$(L "[*] 继续清理迁移残留的 233boy 文件" "[*] Continuing to clean up the 233boy files left by the migration")"
      start_op migrate "MIGRATE_START=CLEAN"
      op_ok || die "$(L "迁移清理未完成（REASON=$(kv_get "${OP_RESULT}" REASON)）" "Migration cleanup did not finish (REASON=$(kv_get "${OP_RESULT}" REASON))")"
    elif [[ "${STATE}" == migrated_leftover ]]; then
      echo "$(L "[!] 迁移未清理完，运行 ownexit direct migrate 继续清理 233boy 残留；本次按已迁移的新版处理" "[!] Migration cleanup is incomplete; run ownexit direct migrate to finish cleaning up the 233boy leftovers; treating it as the migrated new version this time")"
    elif [[ "${DO_MIGRATE}" == 1 ]]; then
      echo "$(L "[*] 服务器已是新版，无需迁移，按复用处理" "[*] The server already runs the new version; no migration needed, reusing it")"
    fi
    ensure_sub_params
    read_client_env
    CUR_SNI="$(kv_get "${CLIENT_ENV}" SNI)"
    CUR_PORT="$(kv_get "${CLIENT_ENV}" PORT)"
    NEW_SNI=""; NEW_PORT=""
    [[ -z "${WANT_SNI}" || "${WANT_SNI}" == "${CUR_SNI}" ]] || NEW_SNI="${WANT_SNI}"
    [[ -z "${WANT_PROXY_PORT}" || "${WANT_PROXY_PORT}" == "${CUR_PORT}" ]] || NEW_PORT="${WANT_PROXY_PORT}"
    if [[ "${ROTATE_KEYS}" == 1 && "${ROTATED}" == 1 ]]; then
      echo "$(L "[*] 刚恢复完成的操作已经换过凭据，本次不再轮换" "[*] The operation just recovered already replaced the credentials; not rotating again")"
    elif [[ "${ROTATE_KEYS}" == 1 ]]; then
      DO_ROTATE=1
    fi
    if [[ -n "${NEW_SNI}" || -n "${NEW_PORT}" || "${DO_ROTATE}" == 1 || -n "${WANT_ADD_DEVICE}${WANT_REMOVE_DEVICE}" ]]; then
      if [[ -n "${NEW_PORT}" ]]; then
        [[ "${NEW_PORT}" != "${SUB_PORT}" ]] || die_usage "$(L "--proxy-port 与订阅端口 ${SUB_PORT} 相同，请换一个" "--proxy-port is the same as the subscription port ${SUB_PORT}; choose another")"
        ! server_port_in_use "${NEW_PORT}" || die_usage "$(L "VPS 上端口 ${NEW_PORT} 已被占用" "Port ${NEW_PORT} is already in use on the VPS")"
      fi
      if [[ "${DO_ROTATE}" == 1 ]]; then
        CRED_NOTE="$(L "凭据=重新生成 UUID / Reality 密钥 / short id" "credentials=new UUID / Reality key / short id")"
      else
        CRED_NOTE="$(L "UUID 与密钥不变" "UUID and keys unchanged")"
      fi
      DEVICE_NOTE=""
      [[ -z "${WANT_ADD_DEVICE}" ]] || DEVICE_NOTE="$(L "，设备=新增 ${WANT_ADD_DEVICE}" ", devices=add ${WANT_ADD_DEVICE}")"
      [[ -z "${WANT_REMOVE_DEVICE}" ]] || DEVICE_NOTE="$(L "，设备=吊销 ${WANT_REMOVE_DEVICE}" ", devices=revoke ${WANT_REMOVE_DEVICE}")"
      echo "$(L "[*] 改参数：sni ${CUR_SNI} -> ${NEW_SNI:-不变}，port ${CUR_PORT} -> ${NEW_PORT:-不变}（${CRED_NOTE}${DEVICE_NOTE}）" "[*] Changing parameters: sni ${CUR_SNI} -> ${NEW_SNI:-unchanged}, port ${CUR_PORT} -> ${NEW_PORT:-unchanged} (${CRED_NOTE}${DEVICE_NOTE})")"
      start_op reparam "NEW_SNI=${NEW_SNI}" "NEW_PORT=${NEW_PORT}" "ROTATE=${DO_ROTATE}" \
        "DEVICE_ADD=${WANT_ADD_DEVICE}" "DEVICE_REMOVE=${WANT_REMOVE_DEVICE}"
      if ! op_ok; then
        case "$(kv_get "${OP_RESULT}" REASON)" in
          *device-exists) die_usage "$(L "设备 ${WANT_ADD_DEVICE} 已存在（ownexit direct devices 查看现有设备），VPS 未改动" "Device ${WANT_ADD_DEVICE} already exists (list devices with ownexit direct devices); the VPS was not changed")" ;;
          *device-missing) die_usage "$(L "没有名为 ${WANT_REMOVE_DEVICE} 的设备（ownexit direct devices 查看现有设备），VPS 未改动" "There is no device named ${WANT_REMOVE_DEVICE} (list devices with ownexit direct devices); the VPS was not changed")" ;;
          *device-limit) die_usage "$(L "设备数已达上限 32（含 default），VPS 未改动" "The device limit of 32 (including default) is reached; the VPS was not changed")" ;;
        esac
        die "$(L "改参数失败（REASON=$(kv_get "${OP_RESULT}" REASON)），VPS 已恢复原配置" "Changing parameters failed (REASON=$(kv_get "${OP_RESULT}" REASON)); the VPS restored the original configuration")"
      fi
      # 只有 SNI / 端口 / 凭据变化才要求已导入的设备重新拉订阅；纯设备增删不影响其它设备。
      [[ -z "${NEW_SNI}${NEW_PORT}" && "${DO_ROTATE}" == 0 ]] || CHANGED_PARAMS=1
      [[ -z "${WANT_ADD_DEVICE}${WANT_REMOVE_DEVICE}" ]] || CHANGED_DEVICES=1
      [[ "${DO_ROTATE}" == 0 ]] || ROTATED=1
    else
      BIN_OK="$(vssh "test -f /opt/ownexit-direct/bin/sing-box-${SING_BOX_VERSION} && sha256sum /opt/ownexit-direct/bin/sing-box-${SING_BOX_VERSION} | awk '{print \$1}'" 2>/dev/null || true)"
      if [[ "${BIN_OK}" != "${BINARY_SHA256}" ]] || ! vssh "systemctl is-active --quiet ownexit-direct" >/dev/null 2>&1; then
        echo "$(L "[*] 二进制缺失或服务未运行，修复中" "[*] The binary is missing or the service is not running; repairing")"
        start_op repair
        op_ok || die "$(L "服务无法启动（REASON=$(kv_get "${OP_RESULT}" REASON)），配置文件未改动；运行 ownexit direct log 查看原因" "The service cannot start (REASON=$(kv_get "${OP_RESULT}" REASON)); the configuration file was not changed; run ownexit direct log to see why")"
      else
        pass "$(L "ownexit-direct 已在运行，参数不变" "ownexit-direct is already running; parameters unchanged")"
      fi
    fi
    ;;
  legacy)
    if [[ "${DO_MIGRATE}" == 0 ]]; then
      echo "$(L "[!] 服务器上是用 233boy 脚本装的旧版。运行 ownexit direct migrate 换成本项目的服务：" "[!] The server runs the old install set up with the 233boy script. Run ownexit direct migrate to switch to this project's service:")" >&2
      echo "$(L "    沿用原有 UUID / 密钥 / 端口 / SNI，客户端与订阅链接不用动；服务器本次未做任何改动" "    it keeps the existing UUID / keys / port / SNI, so clients and subscription URLs need no changes; nothing was changed on the server this time")" >&2
      exit 2
    fi
    [[ "$(kv_get "${PROBE}" LEGACY_ACTIVE)" == yes ]] \
      || die "$(L "233boy 的 sing-box 服务当前没有运行；先在 VPS 上用 sb 把它恢复运行再迁移（保证失败时能回退到可用状态）" "233boy's sing-box service is not running; restore it with sb on the VPS before migrating (so a failure can fall back to a working state)")"
    ensure_sub_params
    echo "$(L "[*] 迁移：沿用 233boy 的节点参数，换成 ownexit-direct 服务（切换时代理中断约 1-3 秒）" "[*] Migrating: keeping 233boy's node parameters and switching to the ownexit-direct service (about 1-3 seconds of proxy downtime during the switch)")"
    start_op migrate
    op_ok || die "$(L "迁移失败（REASON=$(kv_get "${OP_RESULT}" REASON)）；详见上方 [vps] 日志" "Migration failed (REASON=$(kv_get "${OP_RESULT}" REASON)); see the [vps] log above")"
    CHANGED_PARAMS=1
    ;;
  conflict)
    die "$(L "VPS 上的文件组合无法自动处理：$(kv_get "${PROBE}" SEEN)（sing-box.service=$(kv_get "${PROBE}" SINGBOX_UNIT)）。可运行 ownexit direct uninstall 只删除 ownexit 的文件" "The combination of files on the VPS cannot be handled automatically: $(kv_get "${PROBE}" SEEN) (sing-box.service=$(kv_get "${PROBE}" SINGBOX_UNIT)). Run ownexit direct uninstall to delete only ownexit's files")"
    ;;
  *)
    die "$(L "未知服务器状态：${STATE}" "Unknown server state: ${STATE}")"
    ;;
esac

# ---------- 5. 读回节点参数 ----------

read_client_env
# 设备表（名字=UUID，不含 default）：服务器是唯一权威源，本机只记每台设备的订阅 TOKEN。
DEVICES_ENV="$(vssh "cat /etc/ownexit-direct/devices.env 2>/dev/null || true")" || die "$(L "无法读取 VPS 上的设备表" "Could not read the device list on the VPS")"
PROXY_PORT="$(kv_get "${CLIENT_ENV}" PORT)"
PROXY_UUID="$(kv_get "${CLIENT_ENV}" UUID)"
PROXY_PBK="$(kv_get "${CLIENT_ENV}" PUBLIC_KEY)"
PROXY_SID="$(kv_get "${CLIENT_ENV}" SHORT_ID)"
PROXY_SNI="$(kv_get "${CLIENT_ENV}" SNI)"
PROXY_FLOW="$(kv_get "${CLIENT_ENV}" FLOW)"
[[ "${PROXY_PORT}" =~ ^[0-9]+$ && -n "${PROXY_UUID}" && -n "${PROXY_PBK}" && -n "${PROXY_SNI}" ]] \
  || die "$(L "VPS 上的 client.env 不完整：${CLIENT_ENV}" "client.env on the VPS is incomplete: ${CLIENT_ENV}")"

# 节点地址取 VPS 公网 IP（与 233boy 原节点地址同源时订阅逐字不变），取不到时退回 SSH 地址。
PROXY_SERVER="${VPS_PUBLIC_IP:-${HOST}}"
pass "$(L "节点参数：server=${PROXY_SERVER} port=${PROXY_PORT} sni=${PROXY_SNI} flow=${PROXY_FLOW:-无} sid=${PROXY_SID:-空} source=$(kv_get "${CLIENT_ENV}" SOURCE)" "Node parameters: server=${PROXY_SERVER} port=${PROXY_PORT} sni=${PROXY_SNI} flow=${PROXY_FLOW:-none} sid=${PROXY_SID:-empty} source=$(kv_get "${CLIENT_ENV}" SOURCE)")"

# 节点链接字段顺序与链式一致（chain/setup_chain.sh:4116）；FLOW 为空时省略 flow=。
FLOW_PARAM=""
[[ -z "${PROXY_FLOW}" ]] || FLOW_PARAM="&flow=${PROXY_FLOW}"
# 参数：UUID、节点名。各设备只有这两项不同。
make_sr_link() {
  printf 'vless://%s@%s:%s?encryption=none%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$1" "${PROXY_SERVER}" "${PROXY_PORT}" "${FLOW_PARAM}" "${PROXY_SNI}" "${PROXY_PBK}" "${PROXY_SID}" "$2"
}
SR_LINK="$(make_sr_link "${PROXY_UUID}" "${NODE_NAME}")"

# ---------- 6. 本地渲染订阅产物 ----------

# 链式把锁放在 ${XDG_STATE_HOME}/ownexit/ 下并要求该目录为 700；直连先建这一级时必须同样私有，
# 否则同一台电脑先用直连、后用链式会拿不到锁。旧版留下的 755 也在这里收紧。
(umask 077; mkdir -p "${STATE_DIR}")
chmod 700 "${STATE_DIR}" "$(dirname "${STATE_DIR}")" "$(dirname "$(dirname "${STATE_DIR}")")"
# 订阅端口与代理端口撞上（迁移沿用的旧端口恰好等于订阅端口）时换一个订阅端口。
if [[ "${SUB_PORT}" == "${PROXY_PORT}" ]]; then
  # 只换订阅端口、保留 TOKEN：迁移承诺订阅链接的路径部分不变（端口变化概率约 1/40000）。
  OLD_SUB_PORT="${SUB_PORT}"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    SUB_PORT="$(( (RANDOM % 40000) + 20000 ))"
    [[ "${SUB_PORT}" != "${PROXY_PORT}" ]] || continue
    vssh "ss -ltn | awk '{print \$4}' | grep -q ':${SUB_PORT}\$'" >/dev/null 2>&1 || break
    SUB_PORT=""
  done
  [[ -n "${SUB_PORT}" ]] || die "$(L "连续 10 次未找到空闲订阅端口，请人工检查 VPS 端口占用" "No free subscription port found after 10 tries; check port usage on the VPS by hand")"
  TOKEN_CHANGED=1
  echo "$(L "[!] 订阅端口 ${OLD_SUB_PORT} 与代理端口相同，改为 ${SUB_PORT}（TOKEN 不变），客户端需要重新导入订阅" "[!] The subscription port ${OLD_SUB_PORT} equals the proxy port; changing it to ${SUB_PORT} (TOKEN unchanged); clients must import the subscription again")"
fi
if [[ "${TOKEN_CHANGED:-0}" == "1" ]]; then
  printf 'SUB_PORT=%s\nTOKEN=%s\n' "${SUB_PORT}" "${TOKEN}" > "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
fi

echo "$(L "[*] 本地渲染订阅产物：${STAGING}" "[*] Rendering the subscription locally: ${STAGING}")"
rm -rf "${STAGING}"
mkdir -p "${STAGING}/${TOKEN}"

# 把一套客户端订阅（clash.yaml / shadowrocket.txt / node.txt / sing-box.json）渲染进 RENDER_DIR。
# 输入是全局变量：RENDER_DIR、PROXY_UUID、NODE_NAME、SR_LINK 因设备而异，其余节点参数各设备相同。
# default 与每台设备各调用一次（docs/feature/feature-devices-sni-scan.md §5.1.1）。
render_subscription_dir() {
mkdir -p "${RENDER_DIR}"
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
  # flow 来自 VPS 上的 client.env；节点带 flow 时客户端必须同步，否则连不上
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
} > "${RENDER_DIR}/clash.yaml"

# Shadowrocket 订阅：base64 编码的节点链接列表
printf '%s\n' "${SR_LINK}" | base64 | tr -d '\n' > "${RENDER_DIR}/shadowrocket.txt"
printf '\n' >> "${RENDER_DIR}/shadowrocket.txt"

# 备用节点链接（明文）
printf '%s\n' "${SR_LINK}" > "${RENDER_DIR}/node.txt"

# sing-box.json：sing-box 官方客户端（SFI / SFA / SFM，1.12 及以上）可直接导入的完整配置。
# 路由意图同 clash.yaml：国内域名与国内 IP 目标直连，其余走出口；规则集经代理下载（GitHub raw 在国内常不可达）。
# tun 入站给图形客户端开 VPN 用，mixed 入站给命令行 / 手动代理用，端口与 clash.yaml 的 mixed-port 一致。
# route.default_domain_resolver 不能删：1.12 起没有它 check 直接报 FATAL。
SB_FLOW_FIELD=""
[[ -z "${PROXY_FLOW}" ]] || SB_FLOW_FIELD="\"flow\": \"${PROXY_FLOW}\", "
cat > "${RENDER_DIR}/sing-box.json" <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [
      { "type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "proxy" },
      { "type": "local", "tag": "local" }
    ],
    "rules": [{ "rule_set": "geosite-cn", "server": "local" }],
    "final": "remote"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true },
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890 }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "proxy",
      "server": "${PROXY_SERVER}", "server_port": ${PROXY_PORT},
      "uuid": "${PROXY_UUID}", ${SB_FLOW_FIELD}
      "tls": {
        "enabled": true, "server_name": "${PROXY_SNI}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "${PROXY_PBK}", "short_id": "${PROXY_SID}" }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct" }
    ],
    "rule_set": [
      { "type": "remote", "tag": "geosite-cn", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", "download_detour": "proxy" },
      { "type": "remote", "tag": "geoip-cn", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs", "download_detour": "proxy" }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": "local"
  }
}
EOF
}

RENDER_DIR="${STAGING}/${TOKEN}"
render_subscription_dir

# ---------- 设备订阅（docs/feature/feature-devices-sni-scan.md §5.1.1） ----------
# 本机设备 TOKEN 文件：每行 名字=TOKEN；以 ! 开头的行是“待在 VPS 上删除的旧 TOKEN”（吊销的设备、
# rotate-token 换下的旧 TOKEN），VPS 删除成功后才从文件去掉，同步中断时下次仍能找到它们。
DEVICE_TOKENS_FILE="${STATE_DIR}/devices.env"
device_token_of() {
  [[ -f "${DEVICE_TOKENS_FILE}" ]] || return 0
  awk -F= -v n="$1" '$1 == n {print $2; exit}' "${DEVICE_TOKENS_FILE}"
}
NEW_DEVICE_TOKENS=""
PENDING_DELETE=""
if [[ -f "${DEVICE_TOKENS_FILE}" ]]; then
  PENDING_DELETE="$(awk '/^!/' "${DEVICE_TOKENS_FILE}")"
fi
while IFS='=' read -r dev_name dev_uuid; do
  [[ -n "${dev_name}" ]] || continue
  dev_token="$(device_token_of "${dev_name}")"
  if [[ "${ROTATE_TOKEN}" == 1 && -n "${dev_token}" ]]; then
    PENDING_DELETE="${PENDING_DELETE}${PENDING_DELETE:+$'\n'}!${dev_name}=${dev_token}"
    dev_token=""
  fi
  [[ "${dev_token}" =~ ^[0-9a-f]{32}$ ]] || dev_token="$(openssl rand -hex 16)"
  NEW_DEVICE_TOKENS="${NEW_DEVICE_TOKENS}${dev_name}=${dev_token}"$'\n'
  RENDER_DIR="${STAGING}/${dev_token}"
  PROXY_UUID="${dev_uuid}"
  NODE_NAME="ownexit-direct-${dev_name}"
  SR_LINK="$(make_sr_link "${PROXY_UUID}" "${NODE_NAME}")"
  render_subscription_dir
done <<< "${DEVICES_ENV}"
# 本机有记录、服务器上已没有的设备：它的订阅目录待删除。
if [[ -f "${DEVICE_TOKENS_FILE}" ]]; then
  while IFS='=' read -r dev_name dev_token; do
    [[ -n "${dev_name}" && "${dev_name}" != '!'* ]] || continue
    printf '%s\n' "${DEVICES_ENV}" | awk -F= -v n="${dev_name}" '$1 == n {f=1} END {exit f ? 0 : 1}' \
      || PENDING_DELETE="${PENDING_DELETE}${PENDING_DELETE:+$'\n'}!${dev_name}=${dev_token}"
  done < "${DEVICE_TOKENS_FILE}"
fi
{ printf '%s' "${NEW_DEVICE_TOKENS}"; [[ -z "${PENDING_DELETE}" ]] || printf '%s\n' "${PENDING_DELETE}"; } > "${DEVICE_TOKENS_FILE}.tmp"
chmod 600 "${DEVICE_TOKENS_FILE}.tmp"
mv -f "${DEVICE_TOKENS_FILE}.tmp" "${DEVICE_TOKENS_FILE}"
[[ -s "${DEVICE_TOKENS_FILE}" ]] || rm -f "${DEVICE_TOKENS_FILE}"
# 汇总与校验仍按 default 设备。
PROXY_UUID="$(kv_get "${CLIENT_ENV}" UUID)"
NODE_NAME="ownexit-direct"
SR_LINK="$(make_sr_link "${PROXY_UUID}" "${NODE_NAME}")"

# 空 index.html 保留（老版本靠它防止 http.server 列出 TOKEN 目录）；现在的订阅服务脚本只响应白名单路径，
# 根目录、本文件、index.html 一律 404，防目录列表不再依赖它。
: > "${STAGING}/index.html"
# 订阅服务脚本随订阅目录一起同步到 VPS：按客户端 User-Agent 返回对应格式的 /<TOKEN>/sub，老的固定文件路径照旧。
cp "${SCRIPT_DIR}/subserver.py" "${STAGING}/subserver.py" || die "$(L "复制 subserver.py 失败" "Copying subserver.py failed")"
chmod 644 "${STAGING}/subserver.py"
# 本机有 python3 时先编译一遍（compile 不写 __pycache__），别把语法错的脚本送上服务器。
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "${STAGING}/subserver.py" \
    || die "$(L "subserver.py 编译失败" "Compiling subserver.py failed")"
fi

# 订阅服务 systemd 单元：SUB_PORT 在本地渲染时替换（systemd 不展开占位符）。
# 以 nobody 非 root 运行：高位端口无需 root、只读分发 world-readable 静态文件，
# 最小权限缩小订阅服务万一被利用时的爆炸半径（root→无权用户）。
cat > "${STAGING}/${SUB_SERVICE}.service" <<EOF
[Unit]
Description=ownexit subscription files
After=network-online.target

[Service]
WorkingDirectory=${SUB_BASE_DIR}
ExecStart=/usr/bin/python3 ${SUB_BASE_DIR}/subserver.py --port ${SUB_PORT} --root ${SUB_BASE_DIR}
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

# 本地校验渲染结果：关键字段必须齐全且无占位符残留
for field in "server: ${PROXY_SERVER}" "uuid: ${PROXY_UUID}" "public-key: ${PROXY_PBK}"; do
  grep -qF "${field}" "${STAGING}/${TOKEN}/clash.yaml" \
    || die "$(L "本地渲染的 clash.yaml 缺少字段：${field}" "The locally rendered clash.yaml lacks a field: ${field}")"
done
for field in "\"server\": \"${PROXY_SERVER}\"" "\"uuid\": \"${PROXY_UUID}\"" "\"public_key\": \"${PROXY_PBK}\""; do
  grep -qF "${field}" "${STAGING}/${TOKEN}/sing-box.json" \
    || die "$(L "本地渲染的 sing-box.json 缺少字段：${field}" "The locally rendered sing-box.json lacks a field: ${field}")"
done
# 有 python3 时再做一次 JSON 解析（不新增本机依赖：没有就跳过）。
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${STAGING}/${TOKEN}/sing-box.json" \
    || die "$(L "本地渲染的 sing-box.json 不是合法 JSON" "The locally rendered sing-box.json is not valid JSON")"
fi
grep -qF "subserver.py --port ${SUB_PORT} " "${STAGING}/${SUB_SERVICE}.service" \
  || die "$(L "systemd 单元 SUB_PORT 替换失败" "Substituting SUB_PORT in the systemd unit failed")"
pass "$(L "本地订阅产物渲染并校验完成" "Local subscription rendered and validated")"

# ---------- 7. 同步到 VPS 并启用订阅服务 ----------

echo "$(L "[*] 调用 sync_to_vps.sh 一次性同步到 VPS" "[*] Syncing to the VPS in one go with sync_to_vps.sh")"
bash "${SCRIPT_DIR}/sync_to_vps.sh" --host "${HOST}" --user "${SSH_USER}" --port "${SSH_PORT}" \
  "${STAGING}" "$(dirname "${SUB_BASE_DIR}")"

# 轮换 TOKEN 后清理 VPS 上的旧 TOKEN 目录（格式校验防误删）
if [[ -n "${OLD_TOKEN}" && "${OLD_TOKEN}" != "${TOKEN}" && "${OLD_TOKEN}" =~ ^[0-9a-f]{32}$ ]]; then
  echo "$(L "[*] 清理旧 TOKEN 目录：${SUB_BASE_DIR}/${OLD_TOKEN}" "[*] Removing the old TOKEN directory: ${SUB_BASE_DIR}/${OLD_TOKEN}")"
  vssh "rm -rf '${SUB_BASE_DIR}/${OLD_TOKEN}'" || true
fi
# 吊销设备与换下的设备 TOKEN：只删本机记录过的目录，不删本机不认识的（可能是另一台电脑生成的订阅）。
if [[ -n "${PENDING_DELETE}" ]]; then
  DELETE_FAILED=0
  while IFS='=' read -r dev_name dev_token; do
    [[ -n "${dev_token}" && "${dev_token}" =~ ^[0-9a-f]{32}$ ]] || continue
    echo "$(L "[*] 清理设备 ${dev_name#!} 的旧订阅目录" "[*] Removing the old subscription directory of device ${dev_name#!}")"
    vssh "rm -rf '${SUB_BASE_DIR}/${dev_token}'" || DELETE_FAILED=1
  done <<< "${PENDING_DELETE}"
  if [[ "${DELETE_FAILED}" == 0 && -f "${DEVICE_TOKENS_FILE}" ]]; then
    awk '!/^!/' "${DEVICE_TOKENS_FILE}" > "${DEVICE_TOKENS_FILE}.tmp"
    chmod 600 "${DEVICE_TOKENS_FILE}.tmp"
    mv -f "${DEVICE_TOKENS_FILE}.tmp" "${DEVICE_TOKENS_FILE}"
    [[ -s "${DEVICE_TOKENS_FILE}" ]] || rm -f "${DEVICE_TOKENS_FILE}"
  elif [[ "${DELETE_FAILED}" == 1 ]]; then
    echo "$(L "[!] 有设备的旧订阅目录没删掉，下次运行会再试" "[!] Some devices' old subscription directories were not deleted; the next run will try again")"
  fi
fi

echo "$(L "[*] 启用订阅服务 ${SUB_SERVICE}" "[*] Enabling the subscription service ${SUB_SERVICE}")"
vssh "bash -s" <<REMOTE
set -euo pipefail
install -m 644 '${SUB_BASE_DIR}/${SUB_SERVICE}.service' '/etc/systemd/system/${SUB_SERVICE}.service'
rm -f '${SUB_BASE_DIR}/${SUB_SERVICE}.service'
systemctl daemon-reload
systemctl enable '${SUB_SERVICE}' >/dev/null 2>&1
systemctl restart '${SUB_SERVICE}'
# 先清掉上一次留下的自动关闭计时器（不存在时无副作用）；给了 --sub-ttl 才再起一个。
$(ttl_remote_cmd "${SUB_TTL_SECONDS}")
REMOTE
pass "$(L "订阅服务已启动" "Subscription service started")"
[[ -z "${WANT_SUB_TTL}" ]] || pass "$(L "订阅服务将在 ${WANT_SUB_TTL} 后自动关闭" "The subscription service will turn itself off in ${WANT_SUB_TTL}")"

# 防火墙：只在 ufw 已启用时放行代理端口和订阅端口，不主动开启防火墙
UFW_STATUS="$(vssh "command -v ufw >/dev/null 2>&1 && ufw status | head -n 1 || echo none" || true)"
if [[ "${UFW_STATUS}" == *active* && "${UFW_STATUS}" != *inactive* ]]; then
  echo "$(L "[*] ufw 已启用，放行代理端口 ${PROXY_PORT} 与订阅端口 ${SUB_PORT}" "[*] ufw is enabled; allowing the proxy port ${PROXY_PORT} and the subscription port ${SUB_PORT}")"
  vssh "ufw allow ${PROXY_PORT}/tcp >/dev/null && ufw allow ${SUB_PORT}/tcp >/dev/null" \
    || fail "$(L "ufw 放行端口失败，请人工处理" "ufw failed to allow the ports; handle it by hand")"
elif [[ "${UFW_STATUS}" != "none" && "${UFW_STATUS}" != *inactive* ]]; then
  echo "$(L "[!] 无法确认防火墙状态（${UFW_STATUS}），若客户端连不上请检查 VPS 防火墙/服务商安全组放行 ${PROXY_PORT} 和 ${SUB_PORT}" "[!] Cannot determine the firewall state (${UFW_STATUS}); if clients cannot connect, make sure the VPS firewall / provider security group allows ${PROXY_PORT} and ${SUB_PORT}")"
fi

# ---------- 8. 分层验证 ----------

CLASH_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/clash.yaml"
SR_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/shadowrocket.txt"
SINGBOX_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/sing-box.json"
NODE_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/node.txt"
# 自适应地址：服务器按客户端 User-Agent 返回上面三种格式之一，用户只需要这一条。
SUB_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/sub"

echo "$(L "[*] 验证：VPS 主机层" "[*] Verifying: VPS host")"
if [[ "$(vssh 'systemctl is-active ownexit-direct' 2>/dev/null || true)" == "active" ]]; then
  pass "$(L "ownexit-direct 服务 active" "ownexit-direct service active")"
else
  fail "$(L "ownexit-direct 服务非 active，运行 ownexit direct log 查看日志" "ownexit-direct service is not active; run ownexit direct log to see the log")"
fi
if vssh "ss -ltn | awk '{print \$4}' | grep -q ':${PROXY_PORT}\$'" >/dev/null 2>&1; then
  pass "$(L "代理端口 ${PROXY_PORT} 监听中" "Proxy port ${PROXY_PORT} is listening")"
else
  fail "$(L "代理端口 ${PROXY_PORT} 未监听" "Proxy port ${PROXY_PORT} is not listening")"
fi

echo "$(L "[*] 验证：订阅服务层" "[*] Verifying: subscription service")"
if [[ "$(vssh "systemctl is-active ${SUB_SERVICE}" 2>/dev/null || true)" == "active" ]]; then
  pass "$(L "${SUB_SERVICE} 服务 active" "${SUB_SERVICE} service active")"
else
  fail "$(L "${SUB_SERVICE} 服务非 active" "${SUB_SERVICE} service is not active")"
fi
if vssh "ss -ltn | awk '{print \$4}' | grep -q ':${SUB_PORT}\$'" >/dev/null 2>&1; then
  pass "$(L "订阅端口 ${SUB_PORT} 监听中" "Subscription port ${SUB_PORT} is listening")"
else
  fail "$(L "订阅端口 ${SUB_PORT} 未监听" "Subscription port ${SUB_PORT} is not listening")"
fi

echo "$(L "[*] 验证：本机拉取订阅" "[*] Verifying: fetching the subscription from this computer")"
if curl -fsS -m 15 "${CLASH_URL}" | cmp -s - "${STAGING}/${TOKEN}/clash.yaml"; then
  pass "$(L "Clash 订阅链接可拉取且与本地渲染一致" "The Clash subscription URL can be fetched and matches the local rendering")"
else
  fail "$(L "Clash 订阅链接拉取失败或内容不一致：${CLASH_URL}" "Fetching the Clash subscription URL failed or the content differs: ${CLASH_URL}")"
fi
# 自适应订阅：四种 User-Agent 必须各自拿到对应文件（最后一种模拟认不出的客户端 → base64 列表）。
SUB_OK=1
while IFS='|' read -r ua expected; do
  if ! curl -fsS -m 15 -A "${ua}" "${SUB_URL}" 2>/dev/null | cmp -s - "${STAGING}/${TOKEN}/${expected}"; then
    fail "$(L "自适应订阅 UA=${ua} 返回与 ${expected} 不一致：${SUB_URL}" "The adaptive subscription returned something other than ${expected} for UA=${ua}: ${SUB_URL}")"
    SUB_OK=0
  fi
done <<'UA_CASES'
clash-verge/2.0|clash.yaml
SFA/1.12 sing-box|sing-box.json
Shadowrocket/2.2|shadowrocket.txt
curl/8|shadowrocket.txt
UA_CASES
[[ "${SUB_OK}" == 0 ]] || pass "$(L "自适应订阅：clash / sing-box / shadowrocket / 未知 UA 四种返回正确" "Adaptive subscription: correct responses for the clash / sing-box / shadowrocket / unknown UAs")"
# 非白名单路径一律 404：根目录、服务脚本本身、TOKEN 目录都不能列出或下载，TOKEN 不泄露。
NOT_FOUND_OK=1
for probe in "/" "/subserver.py" "/${TOKEN}/"; do
  code="$(curl -s -m 15 -o /dev/null -w '%{http_code}' "http://${HOST}:${SUB_PORT}${probe}" 2>/dev/null || echo 000)"
  if [[ "${code}" != 404 ]]; then
    fail "$(L "订阅服务对 ${probe} 返回 ${code}（应为 404）" "The subscription service returned ${code} for ${probe} (should be 404)")"
    NOT_FOUND_OK=0
  fi
done
[[ "${NOT_FOUND_OK}" == 0 ]] || pass "$(L "订阅服务非白名单路径返回 404，TOKEN 不泄露" "The subscription service returns 404 for paths outside the allow-list; the TOKEN is not exposed")"

# ---------- 9. 交付汇总 ----------

if [[ -n "${WANT_SUB_TTL}" ]]; then
  SUB_CLOSE_HINT="$(L "订阅服务将在 ${WANT_SUB_TTL} 后自动关闭，到时请先导入完" "The subscription service turns itself off in ${WANT_SUB_TTL}; finish importing before then")"
else
  SUB_CLOSE_HINT="$(L "所有设备都导入后，关掉订阅服务缩小暴露面：ownexit direct sub stop" "Once every device has imported, turn the subscription service off to reduce exposure: ownexit direct sub stop")"
fi

if [[ "${OWNEXIT_UI_LANG}" == en ]]; then
  cat <<EOF

==================== Result ====================
Next steps (the usual path):
  1. Import: paste this one subscription URL into every client (Clash Verge / mihomo / Shadowrocket / v2rayN / sing-box each get their own format):
           ${SUB_URL}
           iPhone / Android can also scan the QR code below
  2. Open https://ipinfo.io on the device; it should show ${VPS_PUBLIC_IP:-VPS IP}
  3. ${SUB_CLOSE_HINT}
  4. If something is wrong, run: ownexit doctor

Subscription URLs with a fixed client format (usually not needed; use them when the adaptive URL does not recognise your client):
  Clash Verge / mihomo : ${CLASH_URL}
  Shadowrocket / v2rayN: ${SR_URL}
  sing-box             : ${SINGBOX_URL}
  Node link backup (plaintext): ${NODE_URL}

vless node link (troubleshooting / backup only):
  ${SR_LINK}

Manual steps afterwards:
  1. Clash Verge / mihomo: on the Subscriptions page paste the Clash subscription URL -> import and select it -> on the Proxies
     page pick ${NODE_NAME} in the PROXY group -> turn on the system proxy (or Tun mode) -> choose Rule mode
  2. iPhone Shadowrocket: + -> Subscribe -> paste the Shadowrocket subscription URL -> connect
     v2rayN / v2rayNG: subscription group -> add -> paste the same URL -> update the subscription
     official sing-box client (1.12+): Profiles -> New -> Remote -> paste the sing-box subscription URL
  3. Once connected, visit ipinfo.io and confirm the exit IP = ${VPS_PUBLIC_IP:-VPS IP}
  4. ${SUB_CLOSE_HINT}

Security reminders:
  - The subscription is plain HTTP: fetch it by hand only when adding / updating a client; do not set frequent automatic updates
  - To import on a new device later: ownexit direct sub start --ttl 30m (turns itself off when due), or sub start, import, then sub stop
  - If the subscription may have leaked: ownexit direct rotate-token
  - If the node credentials may have leaked: ownexit direct rotate-keys (every device must re-import)
EOF
else
  # i18n:zh-begin
  cat <<EOF

==================== 交付结果 ====================
下一步（最常用）:
  1. 导入：所有客户端都粘贴这一条订阅地址（Clash Verge / mihomo / Shadowrocket / v2rayN / sing-box 自动得到各自的格式）：
           ${SUB_URL}
           iPhone / 安卓也可以直接扫下面的二维码
  2. 在设备上打开 https://ipinfo.io，应显示 ${VPS_PUBLIC_IP:-VPS IP}
  3. ${SUB_CLOSE_HINT}
  4. 出问题先跑：ownexit doctor

按客户端固定格式的订阅地址（一般不需要，自适应地址认不出你的客户端时用）:
  Clash Verge / mihomo : ${CLASH_URL}
  Shadowrocket / v2rayN: ${SR_URL}
  sing-box             : ${SINGBOX_URL}
  节点链接备份(明文)    : ${NODE_URL}

vless 节点链接（仅故障排查/备份用）:
  ${SR_LINK}

后续人工步骤:
  1. Clash Verge / mihomo：「订阅」页粘贴 Clash 订阅 URL → 导入并选中 → 代理页 PROXY 组选 ${NODE_NAME}
     → 开启系统代理（或 Tun 模式）→ 模式选「规则」
  2. iPhone Shadowrocket：+ → Subscribe → 粘贴 Shadowrocket 订阅 URL → 连接
     v2rayN / v2rayNG：订阅分组 → 添加 → 粘贴同一条 URL → 更新订阅
     sing-box 官方客户端（1.12+）：配置 → 新建 → 远程 → 粘贴 sing-box 订阅 URL
  3. 连上后访问 ipinfo.io，确认出口 IP = ${VPS_PUBLIC_IP:-VPS IP}
  4. ${SUB_CLOSE_HINT}

安全提醒:
  - 订阅是明文 HTTP：只在新增/更新客户端时手动拉取，不要配置成高频自动更新
  - 以后要给新设备导入订阅：ownexit direct sub start --ttl 30m（到时自动关闭），或先 sub start、导入后再 sub stop
  - 怀疑订阅泄露时运行：ownexit direct rotate-token
  - 怀疑节点凭据泄露时运行：ownexit direct rotate-keys（所有设备都要重新导入）
EOF
  # i18n:zh-end
fi
if command -v qrencode >/dev/null 2>&1; then
  echo
  echo "$(L "节点二维码（iPhone Shadowrocket / 安卓客户端扫码导入）:" "Node QR code (scan with iPhone Shadowrocket / Android clients):")"
  qrencode -t ANSIUTF8 < "${STAGING}/${TOKEN}/node.txt"
else
  echo "$(L "[*] 想在终端显示节点二维码：安装 qrencode（macOS: brew install qrencode）后运行 ownexit direct qr" "[*] To show the node QR code in the terminal: install qrencode (macOS: brew install qrencode), then run ownexit direct qr")"
fi
if [[ -n "${NEW_DEVICE_TOKENS}" ]]; then
  echo
  echo "$(L "设备订阅（每台设备只导入自己那一组；default 就是上面的链接）:" "Device subscriptions (each device imports only its own set; default is the URL above):")"
  while IFS='=' read -r dev_name dev_token; do
    [[ -n "${dev_name}" ]] || continue
    mark=""
    [[ "${dev_name}" != "${WANT_ADD_DEVICE:-}" || -z "${WANT_ADD_DEVICE:-}" ]] || mark="$(L "  ← 新增：只把这一组发给新设备" "  ← new: give only this set to the new device")"
    echo "$(L "  设备 ${dev_name}${mark}" "  Device ${dev_name}${mark}")"
    echo "$(L "    自适应（推荐）       : http://${HOST}:${SUB_PORT}/${dev_token}/sub" "    Adaptive (recommended): http://${HOST}:${SUB_PORT}/${dev_token}/sub")"
    echo "    Clash Verge / mihomo : http://${HOST}:${SUB_PORT}/${dev_token}/clash.yaml"
    echo "    Shadowrocket / v2rayN: http://${HOST}:${SUB_PORT}/${dev_token}/shadowrocket.txt"
    echo "    sing-box             : http://${HOST}:${SUB_PORT}/${dev_token}/sing-box.json"
  done <<< "${NEW_DEVICE_TOKENS}"
fi
[[ -z "${WANT_REMOVE_DEVICE}" ]] || echo "$(L "  - 设备 ${WANT_REMOVE_DEVICE} 已吊销：它的凭据与订阅地址都已失效" "  - Device ${WANT_REMOVE_DEVICE} has been revoked: its credentials and subscription URLs no longer work")"
if [[ "${ROTATED}" == 1 ]]; then
  echo "$(L "  - 已更换节点凭据：所有设备都要重新拉取订阅，旧节点已失效" "  - Node credentials were replaced: every device must fetch the subscription again; the old nodes no longer work")"
elif [[ "${CHANGED_PARAMS}" == 1 && "${STATE}" != legacy ]]; then
  echo "$(L "  - 本次改了节点参数：已导入的客户端需要重新拉取一次订阅" "  - Node parameters changed this time: clients that already imported must fetch the subscription once more")"
fi
echo "=================================================="


if [[ "${STATE}" != ownexit || "${CHANGED_PARAMS}" == 1 || "${CHANGED_DEVICES}" == 1 ]]; then
  print_chain_hints
fi

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "$(L "[!] 有 ${FAIL_COUNT} 项验证未通过，详见上方 [!] 条目" "[!] ${FAIL_COUNT} check(s) did not pass; see the [!] items above")"
  exit 1
fi
echo "$(L "[+] 全部验证通过" "[+] All checks passed")"
