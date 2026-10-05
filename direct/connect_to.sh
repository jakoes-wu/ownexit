#!/usr/bin/env bash
# connect_to.sh —— 给一台 VPS 配好专用 SSH 密钥并验证免密登录（直连和链式的 init 都调用它）。
#
# 前置:
#   - 在本机运行；需要 ssh、ssh-keygen，第一次配免密还需要 expect（macOS: brew install expect；
#     Debian/Ubuntu: sudo apt install expect）。
#   - 目标 VPS 允许用密码 SSH 登录（只在第一次配免密时用一次）。
#   - 密码来源：终端里交互输入（不回显）；非交互运行时读环境变量 OWNEXIT_SSH_PASSWORD。
#     没有 --password 选项，避免密码进入 shell 历史和进程列表。
#   - 不应被 source。
#
# 行为：
#   1. 按 VPS 地址、端口、用户生成本地专用密钥 ~/.ssh/ownexit/id_ed25519_<user>_<host>_<port>
#   2. 先尝试免密登录；已可用则直接结束
#   3. 不可用时问一次密码并推送公钥；密码错了最多再问两次（共 3 次），每次只向服务器提交一次
#   4. 推送后仍免密失败（多为服务商模板写死 PubkeyAuthentication no）时，用密码会话把它翻回 yes
#      并重启 sshd（需 root），再重试一次免密
#   5. 默认进入交互式 SSH；--setup-only 只配置不登录
#
# 退出码：0 成功；1 其它失败；2 参数错误或缺少密码（非终端）；3 登录失败（最后一行 stderr 为 reason=...）。

set -euo pipefail

HOST=""
SSH_USER="root"
SSH_PORT="22"
SETUP_ONLY=0

# 密码只在内存里：来自交互输入或 OWNEXIT_SSH_PASSWORD，用完即清空，不写盘、不打印。
PASS="${OWNEXIT_SSH_PASSWORD:-}"
PASS_FROM_ENV=0
[[ -z "${PASS}" ]] || PASS_FROM_ENV=1
# 交互模式下输错密码最多可以试的总次数。
readonly MAX_PASSWORD_ATTEMPTS=3

usage() {
  cat <<EOF
用法: $(basename "$0") --host <ip/host> [选项]

示例:
  $(basename "$0") --host 203.0.113.7                       # 配好免密后进入交互式 SSH
  $(basename "$0") --host 203.0.113.7 --setup-only          # 只配免密，不登录
  $(basename "$0") --host 203.0.113.7 --port 2222 --setup-only
  OWNEXIT_SSH_PASSWORD=... $(basename "$0") --host 203.0.113.7 --setup-only < /dev/null   # 非交互

选项:
  --host <ip/host>           目标 VPS 地址（必填）
  -u, --user <user>          SSH 用户名，默认 root
  -P, --port <port>          SSH 端口，默认 22
  --setup-only               只配置和验证公钥，不进入交互式 SSH
  -h, --help                 显示帮助

退出码: 0 成功；1 其它失败；2 参数错误或缺少密码；3 登录失败，stderr 最后一行为
  reason=bad-password（密码错误）| reason=password-disabled（服务器关闭了密码登录）|
  reason=unreachable（连不上：IP / 端口 / 安全组）
EOF
}

die() {
  echo "[!] $*" >&2
  exit 1
}

die_usage() {
  echo "[!] $*" >&2
  exit 2
}

# 登录失败统一出口：先给人看的提示，最后一行固定 reason=...，供 setup_direct.sh / setup_chain.sh init 转述。
die_login() {
  local reason="$1"; shift
  echo "[!] $*" >&2
  echo "reason=${reason}" >&2
  exit 3
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)      HOST="${2:?--host 需要一个参数}"; shift 2 ;;
    --host=*)    HOST="${1#*=}"; shift ;;
    -u|--user)   SSH_USER="${2:?--user 需要一个参数}"; shift 2 ;;
    --user=*)    SSH_USER="${1#*=}"; shift ;;
    -P|--port)   SSH_PORT="${2:?--port 需要一个参数}"; shift 2 ;;
    --port=*)    SSH_PORT="${1#*=}"; shift ;;
    --setup-only) SETUP_ONLY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die_usage "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

[[ -n "${HOST}" ]] || die_usage "缺少 --host（VPS 公网 IP）"
[[ "${HOST}" =~ ^[A-Za-z0-9.:-]+$ ]] || die_usage "VPS 地址格式不对：${HOST}"
[[ "${SSH_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die_usage "SSH 用户名格式不对：${SSH_USER}"
[[ "${SSH_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || die_usage "SSH 端口必须是 1-65535 的数字：${SSH_PORT}"

# 密钥路径推导必须与 target_lib.sh 的 target_safe_name、setup_chain.sh init 完全一致
SAFE_NAME="$(printf '%s' "${SSH_USER}_${HOST}_${SSH_PORT}" | tr -c '[:alnum:]_.@-' '_')"
KEY_DIR="${HOME}/.ssh/ownexit"
KEY="${KEY_DIR}/id_ed25519_${SAFE_NAME}"

SSH_BASE_OPTS=(
  -i "${KEY}"
  -p "${SSH_PORT}"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  # 强制发 VPS 已有的 C.UTF-8，覆盖本机转发的 zh_CN.UTF-8，避免远端 setlocale 警告
  -o SetEnv=LC_ALL=C.UTF-8
)

SSH_TEST_OPTS=(
  "${SSH_BASE_OPTS[@]}"
  -o BatchMode=yes
  -o PasswordAuthentication=no
  -o ConnectTimeout=8
)

ensure_local_key() {
  mkdir -p "${KEY_DIR}"
  chmod 700 "${KEY_DIR}"

  if [[ ! -f "${KEY}" ]]; then
    echo "[*] 生成本地 SSH 密钥：${KEY}"
    ssh-keygen -t ed25519 -N "" -f "${KEY}" -C "ownexit-${SSH_USER}@${HOST}" >/dev/null
  fi

  if [[ ! -f "${KEY}.pub" ]]; then
    echo "[*] 补全公钥文件：${KEY}.pub"
    ssh-keygen -y -f "${KEY}" > "${KEY}.pub"
  fi

  chmod 600 "${KEY}"
  chmod 644 "${KEY}.pub"
}

can_login_with_key() {
  ssh "${SSH_TEST_OPTS[@]}" "${SSH_USER}@${HOST}" "exit" >/dev/null 2>&1
}

forget_old_host_key() {
  echo "[*] 清理 known_hosts 中 ${HOST} 的旧记录"
  ssh-keygen -R "${HOST}" >/dev/null 2>&1 || true
  if [[ "${SSH_PORT}" != "22" ]]; then
    ssh-keygen -R "[${HOST}]:${SSH_PORT}" >/dev/null 2>&1 || true
  fi
}

require_expect() {
  if command -v expect >/dev/null 2>&1; then
    return
  fi

  case "$(uname -s)" in
    Darwin)
      die "缺少 expect，无法自动输入密码。请先运行: brew install expect"
      ;;
    Linux)
      die "缺少 expect，无法自动输入密码。Ubuntu/Debian 可运行: sudo apt install expect"
      ;;
    *)
      die "缺少 expect，无法自动输入密码。请先安装 expect"
      ;;
  esac
}

# 交互读取密码到 PASS（不回显）。非终端且没有 OWNEXIT_SSH_PASSWORD 时以退出码 2 结束，避免卡住等输入。
prompt_password() {
  local note="${1:-}"
  [[ -t 0 ]] || die_usage "需要 ${SSH_USER}@${HOST} 的 SSH 密码：请在终端里运行，或设置环境变量 OWNEXIT_SSH_PASSWORD"
  [[ -z "${note}" ]] || echo "[!] ${note}" >&2
  read -r -s -p "VPS 密码（${SSH_USER}@${HOST}:${SSH_PORT}）: " PASS
  echo >&2
  [[ -n "${PASS}" ]] || die_usage "密码为空"
}

# 用密码跑一条会触发 SSH 密码提示的命令（ssh-copy-id / scp / ssh）。
# 返回码约定（bash 侧据此区分失败原因，不要随意改动数值）：
#   5   同一会话第二次出现密码提示，或提交密码后被拒 → 密码错误
#   6   还没提交过密码就被拒（如 Permission denied (publickey)）→ 服务器关闭了密码登录
#   7   连接被拒 / 无路由 / 解析失败 / 连接超时 / 提交密码前被断开 → 连不上
#   124 expect 等待超时 → 连不上
#   其它 子命令自身的退出码
# 密码每个会话只发一次：服务器第二次提示时立即停下，不重发同一个错密码，
# 这样每输错一次服务器只记一次失败，降低触发 fail2ban 一类封禁的概率。
run_with_password() {
  local rc=0
  export CONNECT_TO_PASS="${PASS}"
  expect -f - -- "$@" <<'EXPECT_EOF' || rc=$?
set timeout 30
set sent 0
# 判定失败后先杀掉整个进程组再退出：spawn 出的进程是会话首进程，进程组号等于它的 pid。
# 只退出 expect 会关闭伪终端，ssh-copy-id 内部的 ssh 收不到挂断信号，会读到空输入再提交一次，
# 让服务器多记一次失败（实测：同一连接两条 Failed password）。
proc bail {code} {
  catch {exec kill -TERM -[exp_pid]}
  exit $code
}
spawn {*}$argv
expect {
  -nocase -re "are you sure you want to continue connecting" {
    send -- "yes\r"
    exp_continue
  }
  -nocase -re "password:" {
    if {$sent} { bail 5 }
    set sent 1
    send -- "$env(CONNECT_TO_PASS)\r"
    exp_continue
  }
  -nocase -re "permission denied" {
    if {$sent} { bail 5 }
    bail 6
  }
  -nocase -re "(connection refused|no route to host|could not resolve|connection timed out|operation timed out|network is unreachable)" {
    bail 7
  }
  -nocase -re "(connection closed by|connection reset|kex_exchange_identification)" {
    # 还没提交密码就被断开：端口不对、不是 SSH 服务，或本机 TUN 先接下连接再断开，都按“连不上”处理。
    if {$sent} { bail 5 }
    bail 7
  }
  timeout {
    bail 124
  }
  eof {
    catch wait result
    exit [lindex $result 3]
  }
}
EXPECT_EOF
  unset CONNECT_TO_PASS
  return "${rc}"
}

# 推送一次公钥：有 ssh-copy-id 就用它，否则 scp 公钥到 /tmp 再 ssh 追加到 authorized_keys。
push_public_key_once() {
  local remote_tmp="/tmp/connect_to_${SAFE_NAME}.pub" remote_cmd
  if command -v ssh-copy-id >/dev/null 2>&1; then
    run_with_password ssh-copy-id -i "${KEY}.pub" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new \
      "${SSH_USER}@${HOST}"
    return
  fi
  run_with_password scp -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${KEY}.pub" \
    "${SSH_USER}@${HOST}:${remote_tmp}" || return
  remote_cmd="umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && if ! grep -qxF -f '${remote_tmp}' ~/.ssh/authorized_keys; then cat '${remote_tmp}' >> ~/.ssh/authorized_keys; fi && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && rm -f '${remote_tmp}'"
  run_with_password ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" "${remote_cmd}"
}

# 推送公钥，按返回码区分"密码错 / 关了密码登录 / 连不上"。交互模式下密码错可重输，共 MAX_PASSWORD_ATTEMPTS 次；
# 密码来自环境变量时不重试（重试也只会再提交同一个错密码）。
install_public_key_with_password() {
  local attempt=1 rc
  require_expect
  [[ -n "${PASS}" ]] || prompt_password
  while true; do
    if command -v ssh-copy-id >/dev/null 2>&1; then
      echo "[*] 使用 ssh-copy-id 推送公钥"
    else
      echo "[*] 当前系统没有 ssh-copy-id，改用 scp + ssh 推送公钥"
    fi
    rc=0
    push_public_key_once || rc=$?
    case "${rc}" in
      0) return 0 ;;
      5)
        if [[ "${PASS_FROM_ENV}" == "1" ]]; then
          die_login bad-password "OWNEXIT_SSH_PASSWORD 中的密码不对（${SSH_USER}@${HOST}），请核对后重试"
        fi
        if (( attempt >= MAX_PASSWORD_ATTEMPTS )); then
          die_login bad-password "密码连续错误 ${MAX_PASSWORD_ATTEMPTS} 次（${SSH_USER}@${HOST}）。请到服务商控制台核对或重置 ${SSH_USER} 密码后再运行"
        fi
        attempt=$((attempt + 1))
        PASS=""
        prompt_password "密码错误，还可再试 $((MAX_PASSWORD_ATTEMPTS - attempt + 1)) 次"
        ;;
      6)
        die_login password-disabled "服务器没有给出密码提示就拒绝了登录，多半关闭了密码登录。请到服务商控制台开启密码登录，或手工把 ${KEY}.pub 的内容加入 VPS 的 ~/.ssh/authorized_keys"
        ;;
      7|124)
        die_login unreachable "连不上 ${HOST}:${SSH_PORT}。请核对 IP、SSH 端口，以及服务商安全组 / 防火墙是否放行该端口"
        ;;
      *)
        die "推送公钥失败（退出码 ${rc}），请手动检查 ${SSH_USER}@${HOST}:${SSH_PORT} 的 SSH 配置"
        ;;
    esac
  done
}

# 用密码会话把服务商模板可能写死的 PubkeyAuthentication no 翻回 yes 并重启 sshd。
# 远端脚本只翻「显式的 no」、sshd -t 校验通过才重启（避免改错把自己锁在门外；
# 已建立的本会话不受 sshd 重启影响），主配置与 sshd_config.d/*.conf 都扫一遍。
expect_fix_pubkey_auth() {
  local remote_cmd
  remote_cmd=$(cat <<'RCMD'
fixed=0
for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  [ -f "$f" ] || continue
  if grep -qiE '^[[:space:]]*PubkeyAuthentication[[:space:]]+no' "$f"; then
    sed -i -E 's/^[[:space:]]*PubkeyAuthentication[[:space:]]+no/PubkeyAuthentication yes/I' "$f"
    fixed=1
  fi
done
if [ "$fixed" = 1 ]; then
  if command -v sshd >/dev/null 2>&1; then SSHD_BIN=sshd; else SSHD_BIN=/usr/sbin/sshd; fi
  "$SSHD_BIN" -t && { systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null; } && echo SSHD_PUBKEY_FIXED || echo SSHD_FIX_FAILED
else
  echo SSHD_NO_PUBKEY_NO_LINE
fi
RCMD
)
  run_with_password ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" "${remote_cmd}"
}

# 公钥已推上去但免密仍失败时的自愈：多为服务商模板关掉了 sshd 公钥认证。
# 需 root；非 root 时跳过，回退到手动提示。此时密码刚验证通过，PASS 一定非空。
fix_remote_pubkey_auth() {
  if [[ "${SSH_USER}" != "root" ]]; then
    echo "[!] 当前 SSH 用户非 root，自动修复 sshd 需 root，跳过（请手动以 root 改 PubkeyAuthentication）"
    return 0
  fi
  # 修复尽力而为，最终成败由随后的免密重试判定，故吞掉非零退出码不让 set -e 中断
  expect_fix_pubkey_auth || true
}

ensure_local_key

if can_login_with_key; then
  echo "[+] 免密登录已可用：${SSH_USER}@${HOST}:${SSH_PORT}"
else
  echo "[*] 免密登录不可用，开始使用密码配置公钥"
  forget_old_host_key
  install_public_key_with_password

  echo "[*] 验证免密登录"
  if ! can_login_with_key; then
    echo "[*] 免密仍不可用，尝试自动修复服务商模板可能关闭的 sshd 公钥认证（PubkeyAuthentication no → yes）"
    fix_remote_pubkey_auth
    echo "[*] 重新验证免密登录"
    if ! can_login_with_key; then
      PASS=""
      die "公钥推送并尝试修复 sshd 后仍无法免密登录，请手动检查 VPS 的 SSH 配置（如 /etc/ssh/sshd_config 的 PubkeyAuthentication、AllowUsers、Match 块）"
    fi
    echo "[+] 已自动修复 sshd 公钥认证"
  fi
  PASS=""

  echo "[+] 免密配置完成：${SSH_USER}@${HOST}:${SSH_PORT}"
fi

if [[ "${SETUP_ONLY}" == "1" ]]; then
  echo "[+] --setup-only 已完成，不进入交互式 SSH"
  exit 0
fi

echo "[*] 进入交互式 SSH"
exec ssh "${SSH_BASE_OPTS[@]}" "${SSH_USER}@${HOST}"
