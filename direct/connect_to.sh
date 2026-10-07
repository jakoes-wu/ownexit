#!/usr/bin/env bash
# connect_to.sh —— 给一台 VPS 配好专用 SSH 密钥并验证免密登录（直连和链式的 init 都调用它）。
#
# 前置:
#   - 在本机运行；需要 ssh、ssh-keygen，第一次配免密还需要能自动输入密码的工具，二选一：
#     Python 包 pexpect（pipx / pip 安装 ownexit 时自动带上；入口把自己的解释器路径放在 OWNEXIT_PYTHON 里，
#     git clone 用法可 pip3 install pexpect）或系统命令 expect（macOS: brew install expect；Debian/Ubuntu: sudo apt install expect）。
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

# 输出语言（中文 / 英文）的判断与 L 函数（direct/i18n_lib.sh）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=i18n_lib.sh
. "${SCRIPT_DIR}/i18n_lib.sh"

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
  if [[ "${OWNEXIT_UI_LANG}" == en ]]; then
    cat <<EOF
Usage: $(basename "$0") --host <ip/host> [options]

Examples:
  $(basename "$0") --host 203.0.113.7                       # set up key login, then open an interactive SSH session
  $(basename "$0") --host 203.0.113.7 --setup-only          # only set up key login, do not log in
  $(basename "$0") --host 203.0.113.7 --port 2222 --setup-only
  OWNEXIT_SSH_PASSWORD=... $(basename "$0") --host 203.0.113.7 --setup-only < /dev/null   # non-interactive

Options:
  --host <ip/host>           target VPS address (required)
  -u, --user <user>          SSH user, default root
  -P, --port <port>          SSH port, default 22
  --setup-only               only install and verify the public key, no interactive SSH
  -h, --help                 show this help

Exit codes: 0 success; 1 other failure; 2 argument error or missing password; 3 login failed, the last stderr line is
  reason=bad-password (wrong password) | reason=password-disabled (the server disabled password login) |
  reason=unreachable (cannot connect: IP / port / security group)
EOF
  else
    # i18n:zh-begin
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
    # i18n:zh-end
  fi
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
    --host)      HOST="${2:?$(L '--host 需要一个参数' '--host needs a value')}"; shift 2 ;;
    --host=*)    HOST="${1#*=}"; shift ;;
    -u|--user)   SSH_USER="${2:?$(L '--user 需要一个参数' '--user needs a value')}"; shift 2 ;;
    --user=*)    SSH_USER="${1#*=}"; shift ;;
    -P|--port)   SSH_PORT="${2:?$(L '--port 需要一个参数' '--port needs a value')}"; shift 2 ;;
    --port=*)    SSH_PORT="${1#*=}"; shift ;;
    --setup-only) SETUP_ONLY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die_usage "$(L "未知参数: $1（用 --help 查看用法）" "Unknown option: $1 (see --help)")" ;;
  esac
done

[[ -n "${HOST}" ]] || die_usage "$(L "缺少 --host（VPS 公网 IP）" "Missing --host (the VPS public IP)")"
[[ "${HOST}" =~ ^[A-Za-z0-9.:-]+$ ]] || die_usage "$(L "VPS 地址格式不对：${HOST}" "Invalid VPS address: ${HOST}")"
[[ "${SSH_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die_usage "$(L "SSH 用户名格式不对：${SSH_USER}" "Invalid SSH user name: ${SSH_USER}")"
[[ "${SSH_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || die_usage "$(L "SSH 端口必须是 1-65535 的数字：${SSH_PORT}" "The SSH port must be a number from 1 to 65535: ${SSH_PORT}")"

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
    echo "$(L "[*] 生成本地 SSH 密钥：${KEY}" "[*] Generating a local SSH key: ${KEY}")"
    ssh-keygen -t ed25519 -N "" -f "${KEY}" -C "ownexit-${SSH_USER}@${HOST}" >/dev/null
  fi

  if [[ ! -f "${KEY}.pub" ]]; then
    echo "$(L "[*] 补全公钥文件：${KEY}.pub" "[*] Restoring the public key file: ${KEY}.pub")"
    ssh-keygen -y -f "${KEY}" > "${KEY}.pub"
  fi

  chmod 600 "${KEY}"
  chmod 644 "${KEY}.pub"
}

can_login_with_key() {
  ssh "${SSH_TEST_OPTS[@]}" "${SSH_USER}@${HOST}" "exit" >/dev/null 2>&1
}

forget_old_host_key() {
  echo "$(L "[*] 清理 known_hosts 中 ${HOST} 的旧记录" "[*] Removing old known_hosts entries for ${HOST}")"
  ssh-keygen -R "${HOST}" >/dev/null 2>&1 || true
  if [[ "${SSH_PORT}" != "22" ]]; then
    ssh-keygen -R "[${HOST}]:${SSH_PORT}" >/dev/null 2>&1 || true
  fi
}

# 选自动输入密码的后端：先 pexpect（OWNEXIT_PYTHON 指向的解释器，其次 PATH 里的 python3），再 expect；都没有才报错。
# pexpect 优先是因为 pipx 安装的 ownexit 自带它，用户不必再装系统包；expect 保留给 git clone 用法与老环境。
PASSWORD_BACKEND=""
PYTHON_BIN=""
select_password_backend() {
  local candidate
  for candidate in "${OWNEXIT_PYTHON:-}" python3; do
    [[ -n "${candidate}" ]] || continue
    if "${candidate}" -c 'import pexpect' >/dev/null 2>&1; then
      PASSWORD_BACKEND=pexpect
      PYTHON_BIN="${candidate}"
      echo "$(L "[*] 密码输入方式：pexpect（${PYTHON_BIN}）" "[*] Password input: pexpect (${PYTHON_BIN})")"
      return
    fi
  done
  if command -v expect >/dev/null 2>&1; then
    PASSWORD_BACKEND=expect
    echo "$(L "[*] 密码输入方式：expect" "[*] Password input: expect")"
    return
  fi
  die "$(L "缺少自动输入密码的工具。pipx 安装的 ownexit 自带（重新运行 pipx install --force ownexit）；git clone 用法运行 pip3 install pexpect，或安装 expect（macOS: brew install expect；Debian/Ubuntu: sudo apt install expect）" "No tool to type the password automatically. ownexit installed with pipx ships one (run pipx install --force ownexit again); for a git clone run pip3 install pexpect, or install expect (macOS: brew install expect; Debian/Ubuntu: sudo apt install expect)")"
}

# 交互读取密码到 PASS（不回显）。非终端且没有 OWNEXIT_SSH_PASSWORD 时以退出码 2 结束，避免卡住等输入。
prompt_password() {
  local note="${1:-}"
  [[ -t 0 ]] || die_usage "$(L "需要 ${SSH_USER}@${HOST} 的 SSH 密码：请在终端里运行，或设置环境变量 OWNEXIT_SSH_PASSWORD" "The SSH password for ${SSH_USER}@${HOST} is needed: run this in a terminal, or set the environment variable OWNEXIT_SSH_PASSWORD")"
  [[ -z "${note}" ]] || echo "[!] ${note}" >&2
  read -r -s -p "$(L "VPS 密码（${SSH_USER}@${HOST}:${SSH_PORT}）: " "VPS password (${SSH_USER}@${HOST}:${SSH_PORT}): ")" PASS
  echo >&2
  [[ -n "${PASS}" ]] || die_usage "$(L "密码为空" "The password is empty")"
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
  case "${PASSWORD_BACKEND}" in
    pexpect) run_with_password_pexpect "$@" ;;
    *) run_with_password_expect "$@" ;;
  esac
}

# pexpect 版：与下面 expect 版同一组模式、同一套返回码；密码只经环境变量进入 Python，不进脚本正文与 argv。
# 子进程输出原样回显（logfile_read），与 Tcl expect 默认 log_user 1 一致；密码由 ssh 关回显，不会出现在输出里。
# pexpect 用 setsid 起子进程（pid 等于进程组号），判定失败后 killpg(TERM) 再退出，与 expect 版 kill -TERM -[exp_pid] 等价。
run_with_password_pexpect() {
  local rc=0
  export CONNECT_TO_PASS="${PASS}"
  "${PYTHON_BIN}" - "$@" <<'PEXPECT_EOF' || rc=$?
import os
import signal
import sys

import pexpect

child = pexpect.spawn(sys.argv[1], sys.argv[2:], timeout=30, encoding="utf-8", codec_errors="replace")
child.logfile_read = sys.stdout
sent = False


def bail(code):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except OSError:
        pass
    sys.exit(code)


patterns = [
    r"(?i)are you sure you want to continue connecting",
    r"(?i)password:",
    r"(?i)permission denied",
    r"(?i)(connection refused|no route to host|could not resolve|connection timed out|operation timed out|network is unreachable)",
    r"(?i)(connection closed by|connection reset|kex_exchange_identification)",
    pexpect.TIMEOUT,
    pexpect.EOF,
]
while True:
    index = child.expect(patterns)
    if index == 0:
        child.sendline("yes")
    elif index == 1:
        if sent:
            bail(5)
        sent = True
        child.sendline(os.environ["CONNECT_TO_PASS"])
    elif index == 2:
        bail(5 if sent else 6)
    elif index == 3:
        bail(7)
    elif index == 4:
        bail(5 if sent else 7)
    elif index == 5:
        bail(124)
    else:
        child.close()
        if child.exitstatus is not None:
            sys.exit(child.exitstatus)
        sys.exit(128 + (child.signalstatus or 0))
PEXPECT_EOF
  unset CONNECT_TO_PASS
  return "${rc}"
}

run_with_password_expect() {
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
  select_password_backend
  [[ -n "${PASS}" ]] || prompt_password
  while true; do
    if command -v ssh-copy-id >/dev/null 2>&1; then
      echo "$(L "[*] 使用 ssh-copy-id 推送公钥" "[*] Pushing the public key with ssh-copy-id")"
    else
      echo "$(L "[*] 当前系统没有 ssh-copy-id，改用 scp + ssh 推送公钥" "[*] ssh-copy-id is not available on this system; pushing the public key with scp + ssh instead")"
    fi
    rc=0
    push_public_key_once || rc=$?
    case "${rc}" in
      0) return 0 ;;
      5)
        if [[ "${PASS_FROM_ENV}" == "1" ]]; then
          die_login bad-password "$(L "OWNEXIT_SSH_PASSWORD 中的密码不对（${SSH_USER}@${HOST}），请核对后重试" "The password in OWNEXIT_SSH_PASSWORD is wrong (${SSH_USER}@${HOST}); check it and try again")"
        fi
        if (( attempt >= MAX_PASSWORD_ATTEMPTS )); then
          die_login bad-password "$(L "密码连续错误 ${MAX_PASSWORD_ATTEMPTS} 次（${SSH_USER}@${HOST}）。请到服务商控制台核对或重置 ${SSH_USER} 密码后再运行" "Wrong password ${MAX_PASSWORD_ATTEMPTS} times in a row (${SSH_USER}@${HOST}). Check or reset the ${SSH_USER} password in your provider's console, then run again")"
        fi
        attempt=$((attempt + 1))
        PASS=""
        prompt_password "$(L "密码错误，还可再试 $((MAX_PASSWORD_ATTEMPTS - attempt + 1)) 次" "Wrong password; $((MAX_PASSWORD_ATTEMPTS - attempt + 1)) tries left")"
        ;;
      6)
        die_login password-disabled "$(L "服务器没有给出密码提示就拒绝了登录，多半关闭了密码登录。请到服务商控制台开启密码登录，或手工把 ${KEY}.pub 的内容加入 VPS 的 ~/.ssh/authorized_keys" "The server refused the login without asking for a password, so password login is most likely turned off. Turn it on in your provider's console, or add the contents of ${KEY}.pub to ~/.ssh/authorized_keys on the VPS yourself")"
        ;;
      7|124)
        die_login unreachable "$(L "连不上 ${HOST}:${SSH_PORT}。请核对 IP、SSH 端口，以及服务商安全组 / 防火墙是否放行该端口" "Cannot connect to ${HOST}:${SSH_PORT}. Check the IP, the SSH port, and whether your provider's security group / firewall allows that port")"
        ;;
      *)
        die "$(L "推送公钥失败（退出码 ${rc}），请手动检查 ${SSH_USER}@${HOST}:${SSH_PORT} 的 SSH 配置" "Pushing the public key failed (exit code ${rc}); check the SSH configuration of ${SSH_USER}@${HOST}:${SSH_PORT} by hand")"
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
    echo "$(L "[!] 当前 SSH 用户非 root，自动修复 sshd 需 root，跳过（请手动以 root 改 PubkeyAuthentication）" "[!] The SSH user is not root and fixing sshd automatically needs root; skipped (change PubkeyAuthentication as root by hand)")"
    return 0
  fi
  # 修复尽力而为，最终成败由随后的免密重试判定，故吞掉非零退出码不让 set -e 中断
  expect_fix_pubkey_auth || true
}

ensure_local_key

if can_login_with_key; then
  echo "$(L "[+] 免密登录已可用：${SSH_USER}@${HOST}:${SSH_PORT}" "[+] Key login works: ${SSH_USER}@${HOST}:${SSH_PORT}")"
else
  echo "$(L "[*] 免密登录不可用，开始使用密码配置公钥" "[*] Key login does not work yet; setting up the public key with the password")"
  forget_old_host_key
  install_public_key_with_password

  echo "$(L "[*] 验证免密登录" "[*] Verifying key login")"
  if ! can_login_with_key; then
    echo "$(L "[*] 免密仍不可用，尝试自动修复服务商模板可能关闭的 sshd 公钥认证（PubkeyAuthentication no → yes）" "[*] Key login still fails; trying to fix sshd public key authentication that the provider's image may have turned off (PubkeyAuthentication no → yes)")"
    fix_remote_pubkey_auth
    echo "$(L "[*] 重新验证免密登录" "[*] Verifying key login again")"
    if ! can_login_with_key; then
      PASS=""
      die "$(L "公钥推送并尝试修复 sshd 后仍无法免密登录，请手动检查 VPS 的 SSH 配置（如 /etc/ssh/sshd_config 的 PubkeyAuthentication、AllowUsers、Match 块）" "Key login still fails after pushing the public key and trying to fix sshd; check the VPS's SSH configuration by hand (for example PubkeyAuthentication, AllowUsers and Match blocks in /etc/ssh/sshd_config)")"
    fi
    echo "$(L "[+] 已自动修复 sshd 公钥认证" "[+] Fixed sshd public key authentication automatically")"
  fi
  PASS=""

  echo "$(L "[+] 免密配置完成：${SSH_USER}@${HOST}:${SSH_PORT}" "[+] Key login set up: ${SSH_USER}@${HOST}:${SSH_PORT}")"
fi

if [[ "${SETUP_ONLY}" == "1" ]]; then
  echo "$(L "[+] --setup-only 已完成，不进入交互式 SSH" "[+] --setup-only finished; not opening an interactive SSH session")"
  exit 0
fi

echo "$(L "[*] 进入交互式 SSH" "[*] Opening an interactive SSH session")"
exec ssh "${SSH_BASE_OPTS[@]}" "${SSH_USER}@${HOST}"
