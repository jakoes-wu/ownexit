# shellcheck shell=bash
# target_lib.sh —— 直连目标（出口 VPS）的记忆与读取，供 setup_direct.sh 与 subctl 共用。
#
# 前置:
#   - 只能被 source，不能直接执行；调用方须已 `set -euo pipefail`，并已定义 die（退出码 1）。
#   - 读写 ${XDG_CONFIG_HOME:-$HOME/.config}/ownexit/direct/<safe_name>.env，仓库外、权限 600。
#
# 目标配置是"上次成功部署的 VPS"的唯一记录：setup_direct.sh 第 1 阶段（免密与系统检查）通过后才写，
# 之后两个脚本不带 --host 时都从这里取目标。文件只允许 HOST / SSH_PORT / SSH_USER 三个键，
# 解析时不执行 shell（不 source），防止被手工改坏的文件把任意命令带进来。

OWNEXIT_DIRECT_TARGET_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/ownexit/direct"

# 缺参数时的用法错误：退出码 2，与链式脚本的"CLI 参数错误返回 2"保持一致。
die_usage() {
  echo "[!] $*" >&2
  exit 2
}

# 本地 key、状态目录与目标配置的文件名都用同一个 safe_name，推导规则必须与 connect_to.sh 完全一致，
# 否则 setup_direct.sh 找不到 connect_to.sh 刚生成的密钥。
target_safe_name() {
  printf '%s' "$1_$2_$3" | tr -c '[:alnum:]_.@-' '_'
}

validate_target() {
  local host="$1" port="$2" user="$3"
  [[ "${host}" =~ ^[A-Za-z0-9.:-]+$ ]] || die_usage "VPS 地址格式不对：${host}"
  [[ "${port}" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || die_usage "SSH 端口必须是 1-65535 的数字：${port}"
  [[ "${user}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die_usage "SSH 用户名格式不对：${user}"
}

# 读取一个目标配置到 TARGET_HOST / TARGET_PORT / TARGET_USER；遇到未知键、重复键或缺键返回 1。
read_target_file() {
  local file="$1" line key value seen=""
  TARGET_HOST="" TARGET_PORT="" TARGET_USER=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" == *=* ]] || return 1
    key="${line%%=*}"
    value="${line#*=}"
    case " ${seen} " in *" ${key} "*) return 1 ;; esac
    seen="${seen} ${key}"
    case "${key}" in
      HOST) TARGET_HOST="${value}" ;;
      SSH_PORT) TARGET_PORT="${value}" ;;
      SSH_USER) TARGET_USER="${value}" ;;
      *) return 1 ;;
    esac
  done < "${file}"
  [[ -n "${TARGET_HOST}" && -n "${TARGET_PORT}" && -n "${TARGET_USER}" ]]
}

# 按"参数 > 唯一的已记住目标 > 交互提问"决定本次目标，结果写回 HOST / SSH_PORT / SSH_USER。
# 调用方设置 TARGET_NO_PROMPT_HINT 时不提问，没有目标就以该提示退出（退出码 2）。
# 调用前 HOST 为空表示用户没给 --host；SSH_PORT / SSH_USER 已带默认值（22 / root）或参数值。
resolve_target() {
  local files=() file
  if [[ -n "${HOST}" ]]; then
    validate_target "${HOST}" "${SSH_PORT}" "${SSH_USER}"
    return 0
  fi

  if [[ -d "${OWNEXIT_DIRECT_TARGET_DIR}" ]]; then
    for file in "${OWNEXIT_DIRECT_TARGET_DIR}"/*.env; do
      [[ -f "${file}" ]] && files+=("${file}")
    done
  fi

  if [[ "${#files[@]}" -eq 1 ]]; then
    read_target_file "${files[0]}" || die "目标配置格式不对（只允许 HOST / SSH_PORT / SSH_USER）：${files[0]}"
    validate_target "${TARGET_HOST}" "${TARGET_PORT}" "${TARGET_USER}"
    HOST="${TARGET_HOST}" SSH_PORT="${TARGET_PORT}" SSH_USER="${TARGET_USER}"
    echo "[*] 使用上次记住的 VPS：${SSH_USER}@${HOST}:${SSH_PORT}（换目标请加 --host）"
    return 0
  fi

  if [[ "${#files[@]}" -gt 1 ]]; then
    {
      echo "[!] 记住了多台 VPS，请用 --host 指定本次要操作哪一台："
      for file in "${files[@]}"; do
        read_target_file "${file}" && echo "      --host ${TARGET_HOST} --port ${TARGET_PORT} --user ${TARGET_USER}"
      done
    } >&2
    exit 2
  fi

  # 调用方不允许提问时（subctl 不负责首次部署），给出它自己的提示。
  [[ -z "${TARGET_NO_PROMPT_HINT:-}" ]] || die_usage "${TARGET_NO_PROMPT_HINT}"
  # 没有记住的目标：只在终端里才提问；CI / 管道里直接报缺参数，避免卡在等输入。
  [[ -t 0 ]] || die_usage "缺少 --host（VPS 公网 IP）"
  read -r -p "VPS 公网 IP: " HOST
  validate_target "${HOST}" "${SSH_PORT}" "${SSH_USER}"
}

# 原子写入目标配置：先写同目录临时文件并 chmod 600，再 mv 覆盖，避免中途失败留下半个文件。
save_target() {
  local file tmp
  # 与链式共用 ${XDG_CONFIG_HOME}/ownexit/：这一级也必须私有（链式的安全检查要求父目录不可被他人写）。
  (umask 077; mkdir -p "${OWNEXIT_DIRECT_TARGET_DIR}")
  chmod 700 "${OWNEXIT_DIRECT_TARGET_DIR}" "$(dirname "${OWNEXIT_DIRECT_TARGET_DIR}")"
  file="${OWNEXIT_DIRECT_TARGET_DIR}/$(target_safe_name "${SSH_USER}" "${HOST}" "${SSH_PORT}").env"
  tmp="$(mktemp "${OWNEXIT_DIRECT_TARGET_DIR}/.target.XXXXXX")"
  chmod 600 "${tmp}"
  printf 'HOST=%s\nSSH_PORT=%s\nSSH_USER=%s\n' "${HOST}" "${SSH_PORT}" "${SSH_USER}" > "${tmp}"
  mv -f "${tmp}" "${file}"
}

# 订阅服务自动关闭的时长：<正整数>[s|m|h]，不带单位按分钟；换算成秒后必须在 60 秒到 24 小时之间。
# 输出秒数；格式或范围不对时以退出码 2 结束（参数错误）。setup_direct.sh 的 --sub-ttl 与 subctl start --ttl 共用。
parse_ttl() {
  local value="$1" number unit seconds
  [[ "${value}" =~ ^([1-9][0-9]{0,5})([smh]?)$ ]] || die_usage "时长格式不对：${value}（例：30m、2h、90s；不带单位按分钟）"
  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]:-m}"
  case "${unit}" in
    s) seconds="${number}" ;;
    m) seconds=$((number * 60)) ;;
    h) seconds=$((number * 3600)) ;;
  esac
  (( seconds >= 60 && seconds <= 86400 )) || die_usage "时长要在 1 分钟到 24 小时之间：${value}"
  printf '%s\n' "${seconds}"
}

# 远端命令片段：清掉上一次的自动关闭计时器（不存在时无副作用）；seconds 非空时再起一个瞬时计时器，
# 到时 systemctl stop 订阅服务。瞬时单元不落盘，VPS 重启后消失——订阅服务按 enabled 照常起来，与不设时长一致。
ttl_remote_cmd() {
  local seconds="${1:-}"
  printf '%s' "systemctl stop ownexit-subscription-ttl.timer >/dev/null 2>&1 || true; systemctl reset-failed ownexit-subscription-ttl.timer ownexit-subscription-ttl.service >/dev/null 2>&1 || true"
  # AccuracySec=1s：默认精度 1 分钟，会让 2m 实际在 2-3 分钟之间触发；RemainAfterElapse=no + --collect：触发后卸载，
  # 不留 inactive / failed 的同名单元挡住下一次 systemd-run。写法与 chain 的 fail-closed watchdog 一致。
  [[ -z "${seconds}" ]] || printf '%s' "; systemd-run --quiet --collect --unit=ownexit-subscription-ttl --on-active=${seconds} --timer-property=AccuracySec=1s --timer-property=RemainAfterElapse=no /bin/systemctl stop ownexit-subscription"
}
