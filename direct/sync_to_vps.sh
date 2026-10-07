#!/usr/bin/env bash
# sync_to_vps.sh —— 把本地渲染好的订阅暂存目录一次性同步到 VPS 指定目录。
#
# 前置:
#   - 在本机运行；已由 connect_to.sh（或 setup_direct.sh 自动调用它）配好免密；本脚本不处理密码。
#   - 不应被 source。
#
# 行为：
#   1. 复用 connect_to.sh 已生成并推送的免密 key（~/.ssh/ownexit/），
#      key 不存在或免密不可用时直接报错退出，不做密码引导
#   2. 远程目录自动 mkdir -p；scp -rp 递归上传；同名覆盖，幂等可重复
#
# 由 setup_direct.sh 调用，也可在重渲染订阅后单独执行。

set -euo pipefail

# 输出语言（中文 / 英文）的判断与 L 函数（direct/i18n_lib.sh）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=i18n_lib.sh
. "${SCRIPT_DIR}/i18n_lib.sh"

HOST=""          # 由 --host 指定，与 connect_to.sh 使用的地址保持一致
SSH_USER="root"
SSH_PORT="22"
REMOTE_DIR="/opt"

usage() {
  if [[ "${OWNEXIT_UI_LANG}" == en ]]; then
    cat <<EOF
Usage: $(basename "$0") [options] <local_path> [remote_dir]

Options:
  --host <ip/host>       target VPS address (must match the one used with connect_to.sh; the key is looked up by it)
  -u, --user <user>      SSH user, default root
  -P, --port <port>      SSH port, default 22
  -h, --help             show this help

Positional arguments:
  local_path   required. Local file or directory to sync (directories are uploaded recursively)
  remote_dir   optional. Remote target directory, default ${REMOTE_DIR}

Examples:
  $(basename "$0") --host 203.0.113.7 ~/.local/state/ownexit/direct/root_203.0.113.7_22/ownexit-subscription /opt
  $(basename "$0") --host 203.0.113.7 --port 2222 ./some-dir /opt

Prerequisite:
  run connect_to.sh --setup-only (or setup_direct.sh) first to set up key login; this script does not handle passwords.
EOF
  else
    # i18n:zh-begin
    cat <<EOF
用法: $(basename "$0") [选项] <local_path> [remote_dir]

选项:
  --host <ip/host>       目标 VPS 地址（需与 connect_to.sh 使用的一致，密钥按它查找）
  -u, --user <user>      SSH 用户名，默认 root
  -P, --port <port>      SSH 端口，默认 22
  -h, --help             显示帮助

位置参数:
  local_path   必填。本地待同步的文件或目录（目录递归上传）
  remote_dir   可选。远程目标目录，默认 ${REMOTE_DIR}

示例:
  $(basename "$0") --host 203.0.113.7 ~/.local/state/ownexit/direct/root_203.0.113.7_22/ownexit-subscription /opt
  $(basename "$0") --host 203.0.113.7 --port 2222 ./some-dir /opt

前置:
  先运行 connect_to.sh --setup-only（或 setup_direct.sh）完成免密配置；本脚本不处理密码。
EOF
    # i18n:zh-end
  fi
}

die() {
  echo "[!] $*" >&2
  exit 1
}

POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:?$(L '--host 需要一个参数' '--host needs a value')}"
      shift 2
      ;;
    --host=*)
      HOST="${1#*=}"
      shift
      ;;
    -u|--user)
      SSH_USER="${2:?$(L '--user 需要一个参数' '--user needs a value')}"
      shift 2
      ;;
    --user=*)
      SSH_USER="${1#*=}"
      shift
      ;;
    -P|--port)
      SSH_PORT="${2:?$(L '--port 需要一个参数' '--port needs a value')}"
      shift 2
      ;;
    --port=*)
      SSH_PORT="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      POSITIONAL+=("$@")
      break
      ;;
    -*)
      die "$(L "未知选项: $1" "Unknown option: $1")"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
  usage
  exit 0
fi
[[ ${#POSITIONAL[@]} -le 2 ]] || die "$(L "位置参数过多（最多 2 个）" "Too many positional arguments (at most 2)")"
[[ -n "${HOST}" ]] || die "$(L "请用 --host 指定 VPS 地址" "Give the VPS address with --host")"
[[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "$(L "SSH 端口必须是数字" "The SSH port must be a number")"

SRC="${POSITIONAL[0]}"
if [[ ${#POSITIONAL[@]} -eq 2 ]]; then
  REMOTE_DIR="${POSITIONAL[1]}"
fi
[[ -n "${REMOTE_DIR}" ]] || die "$(L "远程目录不能为空" "The remote directory must not be empty")"
[[ -e "${SRC}" ]] || die "$(L "本地路径不存在：${SRC}" "Local path does not exist: ${SRC}")"

# 密钥路径推导必须与 connect_to.sh 完全一致，否则找不到已推送的 key
SAFE_NAME="$(printf '%s' "${SSH_USER}_${HOST}_${SSH_PORT}" | tr -c '[:alnum:]_.@-' '_')"
KEY="${HOME}/.ssh/ownexit/id_ed25519_${SAFE_NAME}"

[[ -f "${KEY}" ]] || die "$(L "未找到密钥 ${KEY}，请先运行 ./connect_to.sh --setup-only" "Key ${KEY} not found; run ./connect_to.sh --setup-only first")"

SSH_OPTS=(
  -i "${KEY}"
  -p "${SSH_PORT}"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=8
)

if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "exit" >/dev/null 2>&1; then
  die "$(L "免密登录不可用：${SSH_USER}@${HOST}:${SSH_PORT}，请先运行 ./connect_to.sh --setup-only" "Key login does not work: ${SSH_USER}@${HOST}:${SSH_PORT}; run ./connect_to.sh --setup-only first")"
fi

echo "$(L "[*] 确保远程目录存在：${REMOTE_DIR}" "[*] Making sure the remote directory exists: ${REMOTE_DIR}")"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "mkdir -p -- '${REMOTE_DIR}'" \
  || die "$(L "远程目录创建失败：${REMOTE_DIR}" "Could not create the remote directory: ${REMOTE_DIR}")"

echo "$(L "[*] 同步 ${SRC}  →  ${SSH_USER}@${HOST}:${REMOTE_DIR}/" "[*] Syncing ${SRC}  →  ${SSH_USER}@${HOST}:${REMOTE_DIR}/")"
# scp 用 -P 指定端口（与 ssh 的 -p 不同）；-rp 兼顾文件与目录并保留时间戳/权限
if ! scp -i "${KEY}" -P "${SSH_PORT}" \
     -o IdentitiesOnly=yes \
     -o BatchMode=yes \
     -o StrictHostKeyChecking=accept-new \
     -rp "${SRC}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/"; then
  die "$(L "scp 同步失败" "scp sync failed")"
fi

echo "$(L "[+] 同步完成：${SSH_USER}@${HOST}:${REMOTE_DIR}/" "[+] Sync complete: ${SSH_USER}@${HOST}:${REMOTE_DIR}/")"
