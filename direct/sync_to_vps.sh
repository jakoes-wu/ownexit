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

HOST=""          # 由 --host 指定，与 connect_to.sh 使用的地址保持一致
SSH_USER="root"
SSH_PORT="22"
REMOTE_DIR="/opt"

usage() {
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
}

die() {
  echo "[!] $*" >&2
  exit 1
}

POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:?--host 需要一个参数}"
      shift 2
      ;;
    --host=*)
      HOST="${1#*=}"
      shift
      ;;
    -u|--user)
      SSH_USER="${2:?--user 需要一个参数}"
      shift 2
      ;;
    --user=*)
      SSH_USER="${1#*=}"
      shift
      ;;
    -P|--port)
      SSH_PORT="${2:?--port 需要一个参数}"
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
      die "未知选项: $1"
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
[[ ${#POSITIONAL[@]} -le 2 ]] || die "位置参数过多（最多 2 个）"
[[ -n "${HOST}" ]] || die "请用 --host 指定 VPS 地址"
[[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "SSH 端口必须是数字"

SRC="${POSITIONAL[0]}"
if [[ ${#POSITIONAL[@]} -eq 2 ]]; then
  REMOTE_DIR="${POSITIONAL[1]}"
fi
[[ -n "${REMOTE_DIR}" ]] || die "远程目录不能为空"
[[ -e "${SRC}" ]] || die "本地路径不存在：${SRC}"

# 密钥路径推导必须与 connect_to.sh 完全一致，否则找不到已推送的 key
SAFE_NAME="$(printf '%s' "${SSH_USER}_${HOST}_${SSH_PORT}" | tr -c '[:alnum:]_.@-' '_')"
KEY="${HOME}/.ssh/ownexit/id_ed25519_${SAFE_NAME}"

[[ -f "${KEY}" ]] || die "未找到密钥 ${KEY}，请先运行 ./connect_to.sh --setup-only"

SSH_OPTS=(
  -i "${KEY}"
  -p "${SSH_PORT}"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=8
)

if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "exit" >/dev/null 2>&1; then
  die "免密登录不可用：${SSH_USER}@${HOST}:${SSH_PORT}，请先运行 ./connect_to.sh --setup-only"
fi

echo "[*] 确保远程目录存在：${REMOTE_DIR}"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "mkdir -p -- '${REMOTE_DIR}'" \
  || die "远程目录创建失败：${REMOTE_DIR}"

echo "[*] 同步 ${SRC}  →  ${SSH_USER}@${HOST}:${REMOTE_DIR}/"
# scp 用 -P 指定端口（与 ssh 的 -p 不同）；-rp 兼顾文件与目录并保留时间戳/权限
if ! scp -i "${KEY}" -P "${SSH_PORT}" \
     -o IdentitiesOnly=yes \
     -o BatchMode=yes \
     -o StrictHostKeyChecking=accept-new \
     -rp "${SRC}" "${SSH_USER}@${HOST}:${REMOTE_DIR}/"; then
  die "scp 同步失败"
fi

echo "[+] 同步完成：${SSH_USER}@${HOST}:${REMOTE_DIR}/"
