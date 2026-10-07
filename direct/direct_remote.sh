#!/usr/bin/env bash
# direct_remote.sh —— 直连部署在 VPS 上执行的部分：只读状态探测，以及所有会改动 sing-box 服务的操作。
#
# 前置:
#   - 在 VPS 上以 root 运行，由本机的 setup_direct.sh 投递，用户不直接调用；Debian / Ubuntu，systemd ≥ 240，
#     有 python3、tar、sha256sum、curl 或 wget。
#   - 两种用法（docs/feature/feature-direct-native-install.md §5.1.2、§5.1.3）：
#       probe：经 SSH 前台执行，只读，输出 KEY=VALUE（STATE、ARCH 等），不改服务器。
#       run  ：由 systemd-run 临时单元 ownexit-direct-op 执行，参数取自 /var/lib/ownexit-direct/op.args，
#              进度写 txn.env、结果写 result.env；SSH 断开不影响它。
#   - op.args 的可选键 ROTATE=1（OP=reparam）表示在服务器上重新生成 UUID / Reality 密钥 / short id
#     （docs/feature/feature-formats-key-rotation.md §5.1.2）；没有这个键按 0 处理，旧版本留下的操作照常恢复。
#   - op.args 的可选键 DEVICE_ADD=<名字> / DEVICE_REMOVE=<名字>（OP=reparam）新增或吊销一台设备；设备表在
#     /etc/ownexit-direct/devices.env（每行 名字=UUID，不含 default），与 config.json 同一事务维护
#     （docs/feature/feature-devices-sni-scan.md §5.1.1）。
#   - 测试钩子只经环境变量传入（OWNEXIT_TEST_DIRECT_FAIL_AT / OWNEXIT_TEST_DIRECT_PAUSE_AT），不写进 op.args，
#     所以服务器重启后的恢复执行不会再次触发。
#
# 关键约束（误改即出事）：
#   - txn.env 的 STEP 是“即将或正在执行的步骤”：先写 STEP 再执行；被信号杀死时 txn.env 保留，下次运行据此恢复。
#   - 失败收尾只由 ERR trap 触发，不捕获 TERM / KILL / EXIT——否则断电与 systemctl stop 也会被当成失败撤销，
#     恢复路径就不存在了。
#   - 迁移回滚前必须确认 233boy 仍完整；不完整时绝不删除 /etc/ownexit-direct（那里是唯一可用的私钥配置）。
#   - 任何路径都不删除 /var/backups/ownexit-direct（迁移备份含旧私钥，由用户决定去留）。

set -eEuo pipefail
umask 077
export LC_ALL=C

# 日志语言：本脚本单独上传到 VPS 执行，不能 source 本机的 i18n_lib.sh。语言由本机经 systemd-run --setenv
# 或命令前缀传入 OWNEXIT_UI_LANG（docs/feature/feature-script-i18n.md §5.1.2）；没传时按中文，兼容旧版本的调用。
L() {
  if [[ "${OWNEXIT_UI_LANG:-zh}" == en ]]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

readonly WORK=/var/lib/ownexit-direct
readonly ETC=/etc/ownexit-direct
readonly OPT=/opt/ownexit-direct
readonly UNIT_NAME=ownexit-direct.service
readonly UNIT_FILE=/etc/systemd/system/ownexit-direct.service
readonly SUB_UNIT_FILE=/etc/systemd/system/ownexit-subscription.service
readonly BACKUP_DIR=/var/backups/ownexit-direct
readonly LEGACY_UNIT_FILE=/lib/systemd/system/sing-box.service
readonly LEGACY_DIR=/etc/sing-box
readonly TXN="${WORK}/txn.env"
readonly RESULT="${WORK}/result.env"
readonly ARGS="${WORK}/op.args"

FAIL_AT="${OWNEXIT_TEST_DIRECT_FAIL_AT:-}"
PAUSE_AT="${OWNEXIT_TEST_DIRECT_PAUSE_AT:-}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# ---------- KEY=VALUE 文件读写：只按行解析，不 source ----------

kv_file_get() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v k="${key}" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${file}"
}

# 原子改写一个键：同目录临时文件写完再 mv，读者只会看到完整的旧文件或新文件。
kv_file_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "$(dirname "${file}")/.$(basename "${file}").XXXXXX")"
  if [[ -f "${file}" ]]; then
    awk -F= -v k="${key}" '$1 != k' "${file}" > "${tmp}"
  fi
  printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${file}"
}

arg() { kv_file_get "${ARGS}" "$1"; }
txn_get() { kv_file_get "${TXN}" "$1"; }
txn_set() { kv_file_set "${TXN}" "$1" "$2"; }
result_set() { printf '%s=%s\n' "$1" "$2" >> "${RESULT}"; }

# ---------- 服务器现场信号 ----------

unit_load_state() { systemctl show "$1" -p LoadState --value 2>/dev/null || printf 'not-found'; }
unit_active() { [[ "$(systemctl is-active "$1" 2>/dev/null || true)" == active ]]; }
port_listening() { ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"; }

ownexit_installed() { [[ -e "${UNIT_FILE}" && -e "${ETC}" ]]; }
ownexit_partial() { [[ ( -e "${UNIT_FILE}" && ! -e "${ETC}" ) || ( ! -e "${UNIT_FILE}" && -e "${ETC}" ) ]]; }
legacy_any() { [[ -e /usr/local/bin/sb || -L /usr/local/bin/sb || -e "${LEGACY_DIR}" || "$(unit_load_state sing-box.service)" != not-found ]]; }
sb_link_is_233boy() {
  [[ -L /usr/local/bin/sb ]] || return 1
  case "$(readlink /usr/local/bin/sb)" in "${LEGACY_DIR}"/sh/*) return 0 ;; *) return 1 ;; esac
}
legacy_complete() { sb_link_is_233boy && [[ -d "${LEGACY_DIR}/conf" && "$(unit_load_state sing-box.service)" == loaded ]]; }

# 回滚的前提：233boy 启动所需的文件都还在（单元、Reality 配置、二进制、全局配置）。
legacy_intact() {
  [[ -f "${LEGACY_UNIT_FILE}" && -x "${LEGACY_DIR}/bin/sing-box" && -f "${LEGACY_DIR}/config.json" ]] || return 1
  compgen -G "${LEGACY_DIR}/conf/VLESS-REALITY-*.json" >/dev/null
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) printf 'amd64' ;;
    aarch64) printf 'arm64' ;;
    *) printf 'unsupported' ;;
  esac
}

# ---------- probe：只读探测（§5.1.3，按顺序判定，命中即停） ----------

probe() {
  local state seen=''
  printf 'ARCH=%s\n' "$(detect_arch)"
  [[ "$(detect_arch)" != unsupported ]] || exit 1
  printf 'SYSTEMD_VERSION=%s\n' "$(systemctl --version | awk 'NR==1 {print $2}')"
  if [[ -f "${TXN}" ]]; then
    state=in_progress
    printf 'TXN_OP=%s\nTXN_STEP=%s\n' "$(txn_get OP)" "$(txn_get STEP)"
    # 本机据此判断“恢复完成的这次操作是否已经换过凭据”，避免用户用 rotate-keys 重跑时再换一次。
    printf 'TXN_ROTATE=%s\n' "$( [[ -f "${ARGS}" && "$(arg ROTATE)" == 1 ]] && printf 1 || printf 0)"
    # 恢复完成的若是同一个设备操作，本机跳过重复提交（否则会报 device-exists / device-missing）。
    printf 'TXN_DEVICE_ADD=%s\nTXN_DEVICE_REMOVE=%s\n' "$(arg DEVICE_ADD)" "$(arg DEVICE_REMOVE)"
    printf 'TXN_PARAMS=%s\n' "$( [[ -n "$(arg NEW_SNI)$(arg NEW_PORT)" || "$(arg ROTATE)" == 1 ]] && printf 1 || printf 0)"
  elif ownexit_installed && legacy_any && ! unit_active sing-box.service; then
    state=migrated_leftover
  elif ownexit_installed && ! legacy_any; then
    state=ownexit
  elif [[ ! -e "${UNIT_FILE}" && ! -e "${ETC}" ]] && legacy_complete; then
    state=legacy
  elif [[ ! -e "${UNIT_FILE}" && ! -e "${ETC}" ]] && ! legacy_any; then
    state=none
  else
    state=conflict
  fi
  printf 'STATE=%s\n' "${state}"
  if [[ "${state}" == legacy ]]; then
    printf 'LEGACY_ACTIVE=%s\n' "$(unit_active sing-box.service && printf yes || printf no)"
  fi
  if [[ "${state}" == ownexit || "${state}" == migrated_leftover ]]; then
    printf 'OWNEXIT_ACTIVE=%s\n' "$(unit_active "${UNIT_NAME}" && printf yes || printf no)"
  fi
  # 让本机能把“看到了什么”原样告诉用户（conflict / 残留清单）。
  for item in "${UNIT_FILE}" "${ETC}" "${OPT}" "${WORK}" /usr/local/bin/sb /usr/local/bin/sing-box "${LEGACY_DIR}" "${LEGACY_UNIT_FILE}"; do
    [[ -e "${item}" || -L "${item}" ]] && seen="${seen}${seen:+,}${item}"
  done
  printf 'SEEN=%s\n' "${seen}"
  # 只输出设备名，不输出 UUID（UUID 由本机读 devices.env 时取）。
  printf 'DEVICES=%s\n' "$( [[ -f "${ETC}/devices.env" ]] && awk -F= 'NF {printf "%s%s", (n++ ? "," : ""), $1}' "${ETC}/devices.env")"
  printf 'SINGBOX_UNIT=%s\n' "$(unit_load_state sing-box.service)"
}

# ---------- 步骤框架 ----------

# 进入步骤：先写 STEP，再按钩子暂停 / 失败，最后由调用方执行步骤内容。
enter_step() {
  STEP="$1"
  txn_set STEP "${STEP}"
  log "STEP=${STEP}"
  if [[ -n "${PAUSE_AT}" && "${PAUSE_AT}" == "${STEP}" ]]; then
    log "$(L "测试钩子：在 ${STEP} 暂停 120 秒" "Test hook: pausing 120 seconds at ${STEP}")"
    sleep 120
  fi
  if [[ -n "${FAIL_AT}" && "${FAIL_AT}" == "${STEP}" ]]; then
    CAUSE=test-hook
    false
  fi
}

finish_ok() {
  rm -f "${TXN}"
  result_set RESULT ok
  log "$(L "操作 ${OP} 完成" "Operation ${OP} completed")"
  exit 0
}

# 以固定原因结束：调用方已经把服务器收拾到声明的状态。keep_txn=yes 表示保留 txn.env 供下次恢复。
finish_fail() {
  local reason="$1" keep_txn="${2:-no}"
  trap - ERR
  [[ "${keep_txn}" == yes ]] || rm -f "${TXN}"
  result_set RESULT fail
  result_set REASON "${reason}"
  log "$(L "操作 ${OP} 失败：REASON=${reason}" "Operation ${OP} failed: REASON=${reason}")"
  exit 1
}

wait_active_and_port() {
  local unit="$1" port="$2" seconds="${3:-10}" i
  for ((i = 0; i < seconds * 2; i++)); do
    if unit_active "${unit}" && port_listening "${port}"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# ---------- 二进制安装（§5.1.4 第 2 步） ----------

ensure_binary() {
  local version archive_sha binary_sha arch url bin stage source candidate actual
  version="$(arg VERSION)"; archive_sha="$(arg ARCHIVE_SHA256)"; binary_sha="$(arg BINARY_SHA256)"
  arch="$(arg ARCH)"; url="$(arg RELEASE_URL)"
  bin="${OPT}/bin/sing-box-${version}"
  if [[ -f "${bin}" && ! -L "${bin}" && "$(sha256sum "${bin}" | awk '{print $1}')" == "${binary_sha}" ]]; then
    log "$(L "binary 来源=reused arch=${arch}" "binary source=reused arch=${arch}")"
    result_set BINARY_SOURCE reused
    return 0
  fi
  install -d -m 755 "${OPT}" "${OPT}/bin"
  stage="$(txn_get STAGE)"
  if [[ -z "${stage}" || ! -d "${stage}" ]]; then
    stage="$(mktemp -d "${OPT}/.stage-XXXXXX")"
    txn_set STAGE "${stage}"
  fi
  if [[ -f "${stage}/archive.tar.gz" ]]; then
    # 暂存目录里已有归档：只可能是上一次下载失败后本机上传的。
    source=local-upload
  else
    source=remote-download
    if command -v curl >/dev/null 2>&1; then
      curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 --max-time 300 -o "${stage}/archive.tar.gz" "${url}" || rm -f "${stage}/archive.tar.gz"
    elif command -v wget >/dev/null 2>&1; then
      wget --quiet --https-only --timeout=60 --tries=2 -O "${stage}/archive.tar.gz" "${url}" || rm -f "${stage}/archive.tar.gz"
    fi
    if [[ ! -s "${stage}/archive.tar.gz" ]] || [[ "$(sha256sum "${stage}/archive.tar.gz" | awk '{print $1}')" != "${archive_sha}" ]]; then
      rm -f "${stage}/archive.tar.gz"
      # 下载失败不是错误收尾：保留 txn 与暂存目录，交给本机从官方地址下载后上传，再以同一操作重入。
      result_set STAGE "${stage}"
      finish_fail download yes
    fi
  fi
  [[ "$(sha256sum "${stage}/archive.tar.gz" | awk '{print $1}')" == "${archive_sha}" ]] || { CAUSE='archive-sha'; false; }
  rm -rf "${stage}/extracted"
  mkdir "${stage}/extracted"
  tar --no-same-owner --no-same-permissions -xzf "${stage}/archive.tar.gz" -C "${stage}/extracted"
  candidate="${stage}/extracted/sing-box-${version}-linux-${arch}/sing-box"
  [[ -f "${candidate}" && ! -L "${candidate}" ]] || { CAUSE='archive-layout'; false; }
  [[ "$(sha256sum "${candidate}" | awk '{print $1}')" == "${binary_sha}" ]] || { CAUSE='binary-sha'; false; }
  chown root:root "${candidate}"
  chmod 755 "${candidate}"
  actual="$(cd / && env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin "${candidate}" version | awk '/^sing-box version / {print $3; exit}')"
  [[ "${actual}" == "${version}" ]] || { CAUSE='binary-version'; false; }
  mv -f "${candidate}" "${bin}"
  rm -rf "${stage}"
  kv_file_set "${TXN}" STAGE ''
  log "$(L "binary 来源=${source} arch=${arch}" "binary source=${source} arch=${arch}")"
  result_set BINARY_SOURCE "${source}"
}

binary_path() { printf '%s/bin/sing-box-%s' "${OPT}" "$(arg VERSION)"; }

# ---------- 配置、客户端参数与单元（§5.1.1） ----------

# 与链式出口机同构（chain/setup_chain.sh:3385-3412）；listen / short_id 由调用方给出（迁移时沿用旧值）。
# 渲染 users 数组的内容（不含方括号，单行）：第一项是 default（client.env 里的 UUID），其后是设备文件的每一行。
# 设备文件为空串或不存在表示没有额外设备。
render_users() {
  local uuid="$1" flow="$2" devices_file="$3" line name dev_uuid users
  users="{ \"name\": \"default\", \"uuid\": \"${uuid}\", \"flow\": \"${flow}\" }"
  if [[ -n "${devices_file}" && -f "${devices_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      name="${line%%=*}"; dev_uuid="${line#*=}"
      users="${users}, { \"name\": \"${name}\", \"uuid\": \"${dev_uuid}\", \"flow\": \"${flow}\" }"
    done < "${devices_file}"
  fi
  printf '%s' "${users}"
}

render_config() {
  local out="$1" listen="$2" port="$3" uuid="$4" flow="$5" sni="$6" private_key="$7" short_id="$8" devices_file="${9:-}" users
  users="$(render_users "${uuid}" "${flow}" "${devices_file}")"
  cat > "${out}" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [{ "type": "local", "tag": "local-dns" }],
    "final": "local-dns",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [{
    "type": "vless",
    "tag": "direct-in",
    "listen": "${listen}",
    "listen_port": ${port},
    "users": [${users}],
    "tls": {
      "enabled": true,
      "server_name": "${sni}",
      "reality": {
        "enabled": true,
        "handshake": { "server": "${sni}", "server_port": 443 },
        "private_key": "${private_key}",
        "short_id": ["${short_id}"]
      }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "default_domain_resolver": "local-dns", "final": "direct" }
}
EOF
  chown root:root "${out}"
  chmod 600 "${out}"
}

# client.env 只放公开参数（无私钥）；本机每次都从这里读回参数渲染订阅，服务器是唯一权威源。
render_client_env() {
  local out="$1"
  printf 'PORT=%s\nUUID=%s\nPUBLIC_KEY=%s\nSHORT_ID=%s\nSNI=%s\nFLOW=%s\nLISTEN=%s\nSOURCE=%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" > "${out}"
  chown root:root "${out}"
  chmod 600 "${out}"
}

# 保留 CAP_NET_BIND_SERVICE：迁移沿用的旧端口可能小于 1024（链式出口机清空了全部能力，这里不能照抄）。
write_unit() {
  local bin tmp
  bin="$(binary_path)"
  tmp="$(mktemp "/etc/systemd/system/.ownexit-direct.XXXXXX")"
  cat > "${tmp}" <<EOF
[Unit]
Description=ownexit direct
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
UMask=0077
ExecStartPre=${bin} check -c ${ETC}/config.json
ExecStart=${bin} run -c ${ETC}/config.json
Restart=on-failure
RestartSec=3s
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF
  chown root:root "${tmp}"
  chmod 644 "${tmp}"
  # 内容没变就不替换：复用 / 修复路径承诺“不改动文件”，也避免无谓的 daemon-reload。
  if [[ -f "${UNIT_FILE}" ]] && cmp -s "${tmp}" "${UNIT_FILE}"; then
    rm -f "${tmp}"
    return 0
  fi
  mv -f "${tmp}" "${UNIT_FILE}"
  systemd-analyze verify "${UNIT_FILE}" >/dev/null 2>&1 || { CAUSE=analyze; false; }
  systemctl daemon-reload
}

check_config() {
  (cd / && env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin "$(binary_path)" check -c "$1") >/dev/null 2>&1 || { CAUSE='config-check'; false; }
}

remove_ownexit_service_files() {
  if [[ -e "${UNIT_FILE}" ]]; then
    systemctl disable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
    rm -f "${UNIT_FILE}"
    systemctl daemon-reload
  fi
  rm -rf "${ETC}"
}

pick_free_port() {
  local avoid="$1" candidate i
  for ((i = 0; i < 10; i++)); do
    candidate=$(( (RANDOM % 40000) + 20000 ))
    [[ "${candidate}" != "${avoid}" ]] || continue
    port_listening "${candidate}" && continue
    printf '%s' "${candidate}"
    return 0
  done
  return 1
}

# ---------- OP=fresh（§5.1.4） ----------

op_fresh() {
  local port uuid keypair private_key public_key short_id sni bin
  if [[ "$(txn_get STEP)" == '' ]]; then enter_step PORT; else STEP="$(txn_get STEP)"; fi
  case "${STEP}" in PORT) ;; BINARY) ;; KEYS) ;; UNIT) ;; CHECK) ;; *) enter_step PORT ;; esac

  if [[ "${STEP}" == PORT ]]; then
    port="$(txn_get PORT)"
    if [[ -z "${port}" ]]; then
      port="$(arg PROXY_PORT)"
      if [[ -z "${port}" ]]; then
        port="$(pick_free_port "$(arg SUB_PORT)")" || { CAUSE='no-free-port'; false; }
      elif port_listening "${port}"; then
        CAUSE='port-in-use'; false
      fi
      txn_set PORT "${port}"
    fi
    enter_step BINARY
  fi
  port="$(txn_get PORT)"
  if [[ "${STEP}" == BINARY ]]; then
    ensure_binary
    enter_step KEYS
  fi
  if [[ "${STEP}" == KEYS ]]; then
    install -d -m 700 "${ETC}"
    if [[ ! -f "${ETC}/client.env" || ! -f "${ETC}/config.json" ]]; then
      bin="$(binary_path)"
      keypair="$("${bin}" generate reality-keypair)"
      private_key="$(printf '%s\n' "${keypair}" | awk -F': ' '$1 == "PrivateKey" {print $2}')"
      public_key="$(printf '%s\n' "${keypair}" | awk -F': ' '$1 == "PublicKey" {print $2}')"
      uuid="$("${bin}" generate uuid)"
      short_id="$("${bin}" generate rand --hex 8)"
      [[ "${private_key}" =~ ^[A-Za-z0-9_-]+$ && "${public_key}" =~ ^[A-Za-z0-9_-]+$ ]] || { CAUSE=keypair; false; }
      [[ "${uuid}" =~ ^[0-9a-f-]{36}$ && "${short_id}" =~ ^[0-9a-f]{16}$ ]] || { CAUSE=uuid; false; }
      sni="$(arg SNI)"
      render_config "${ETC}/config.json" 0.0.0.0 "${port}" "${uuid}" xtls-rprx-vision "${sni}" "${private_key}" "${short_id}" ''
      render_client_env "${ETC}/client.env" "${port}" "${uuid}" "${public_key}" "${short_id}" "${sni}" xtls-rprx-vision 0.0.0.0 fresh
    fi
    check_config "${ETC}/config.json"
    enter_step UNIT
  fi
  if [[ "${STEP}" == UNIT ]]; then
    write_unit
    systemctl enable --now "${UNIT_NAME}" >/dev/null 2>&1 || { CAUSE=enable; false; }
    enter_step CHECK
  fi
  wait_active_and_port "${UNIT_NAME}" "${port}" 10 || { CAUSE='not-listening'; false; }
  finish_ok
}

# ---------- OP=repair：复用时二进制丢失或服务未运行（§5.1.5 第 1、3 条） ----------

op_repair() {
  local port
  enter_step BINARY
  ensure_binary
  enter_step START
  port="$(kv_file_get "${ETC}/client.env" PORT)"
  write_unit
  systemctl enable "${UNIT_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${UNIT_NAME}" >/dev/null 2>&1 || true
  if ! wait_active_and_port "${UNIT_NAME}" "${port}" 10; then
    # 复用路径不改任何配置文件；起不来就如实报告，交给 subctl log 排查。
    finish_fail START-not-active
  fi
  finish_ok
}

# ---------- OP=reparam（§5.1.5） ----------

# 由现有设备表与 op.args 生成 devices.env.new（设备新增 / 吊销 / 轮换都在这里），线上文件不动。
# 计数与过滤用 awk：grep 无匹配返回 1，会在 set -e 下误触发 ERR 撤销。
build_devices_new() {
  local cur="${ETC}/devices.env" out="${ETC}/devices.env.new" add del bin count tmp name
  add="$(arg DEVICE_ADD)"; del="$(arg DEVICE_REMOVE)"
  : > "${out}"
  chmod 600 "${out}"
  [[ ! -f "${cur}" ]] || awk 'NF' "${cur}" > "${out}"
  if [[ -n "${add}" ]]; then
    [[ "${add}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "${add}" != default ]] || { CAUSE=device-name; false; }
    [[ "$(awk -F= -v n="${add}" '$1 == n {c++} END {print c + 0}' "${out}")" == 0 ]] || { CAUSE=device-exists; false; }
    count="$(awk 'NF {c++} END {print c + 0}' "${out}")"
    (( count < 31 )) || { CAUSE=device-limit; false; }
    bin="$(binary_path)"
    printf '%s=%s\n' "${add}" "$("${bin}" generate uuid)" >> "${out}"
    log "$(L "设备：新增 ${add}" "Devices: added ${add}")"
  fi
  if [[ -n "${del}" ]]; then
    [[ "$(awk -F= -v n="${del}" '$1 == n {c++} END {print c + 0}' "${out}")" != 0 ]] || { CAUSE=device-missing; false; }
    tmp="${out}.tmp"
    awk -F= -v n="${del}" '$1 != n' "${out}" > "${tmp}"
    mv -f "${tmp}" "${out}"
    log "$(L "设备：吊销 ${del}" "Devices: revoked ${del}")"
  fi
  if [[ "$(arg ROTATE)" == 1 ]]; then
    # 轮换时每台设备都换新 UUID（名字不变），被泄露的旧 UUID 一并失效。
    bin="$(binary_path)"
    tmp="${out}.tmp"
    : > "${tmp}"
    while IFS= read -r name || [[ -n "${name}" ]]; do
      [[ -n "${name}" ]] || continue
      printf '%s=%s\n' "${name%%=*}" "$("${bin}" generate uuid)" >> "${tmp}"
    done < "${out}"
    mv -f "${tmp}" "${out}"
  fi
  chown root:root "${out}"
  chmod 600 "${out}"
}

reparam_rollback() {
  local bak_config bak_client bak_devices port
  # 经 enter_step 写入 STEP，测试钩子 PAUSE_AT=ROLLBACK 才能在回滚途中打断（验证回滚中断后的恢复）。
  enter_step ROLLBACK
  trap 'rollback_failed' ERR
  bak_config="$(txn_get BACKUP_CONFIG)"; bak_client="$(txn_get BACKUP_CLIENT)"; bak_devices="$(txn_get BACKUP_DEVICES)"
  [[ -f "${bak_config}" ]] && cp -f "${bak_config}" "${ETC}/config.json"
  [[ -f "${bak_client}" ]] && cp -f "${bak_client}" "${ETC}/client.env"
  # BACKUP_DEVICES：备份路径 = 恢复；none = 操作前没有设备表，删除；空 = v0.6.0 及更早留下的操作，不碰设备表。
  if [[ "${bak_devices}" == none ]]; then
    rm -f "${ETC}/devices.env"
  elif [[ -n "${bak_devices}" && -f "${bak_devices}" ]]; then
    cp -f "${bak_devices}" "${ETC}/devices.env"
  fi
  rm -f "${ETC}/config.json.new" "${ETC}/client.env.new" "${ETC}/devices.env.new"
  port="$(kv_file_get "${ETC}/client.env" PORT)"
  systemctl restart "${UNIT_NAME}" >/dev/null 2>&1 || true
  if wait_active_and_port "${UNIT_NAME}" "${port}" 10; then
    finish_fail rolled-back
  fi
  rollback_failed
}

op_reparam() {
  local new_sni new_port uuid public_key short_id flow listen private_key ts bin keypair
  STEP="$(txn_get STEP)"
  [[ -n "${STEP}" ]] || STEP=WRITE
  case "${STEP}" in
    ROLLBACK) reparam_rollback ;;
    WRITE|BACKUP|REPLACE|RESTART|CHECK) ;;
    *) STEP=WRITE ;;
  esac
  if [[ "${STEP}" == WRITE ]]; then
    enter_step WRITE
    new_sni="$(arg NEW_SNI)"; new_port="$(arg NEW_PORT)"
    flow="$(kv_file_get "${ETC}/client.env" FLOW)"
    listen="$(kv_file_get "${ETC}/client.env" LISTEN)"
    [[ -n "${new_sni}" ]] || new_sni="$(kv_file_get "${ETC}/client.env" SNI)"
    [[ -n "${new_port}" ]] || new_port="$(kv_file_get "${ETC}/client.env" PORT)"
    if [[ "$(arg ROTATE)" == 1 ]]; then
      # 轮换凭据：UUID、密钥对、short id 全部现场重新生成，旧客户端随之失效。
      # 此时线上文件还没动，WRITE 步重入时重新生成只会覆盖 .new；进入 BACKUP 之后只用已写好的 .new，不再生成。
      bin="$(binary_path)"
      [[ -x "${bin}" ]] || { CAUSE=binary; false; }
      keypair="$("${bin}" generate reality-keypair)"
      private_key="$(printf '%s\n' "${keypair}" | awk -F': ' '$1 == "PrivateKey" {print $2}')"
      public_key="$(printf '%s\n' "${keypair}" | awk -F': ' '$1 == "PublicKey" {print $2}')"
      uuid="$("${bin}" generate uuid)"
      short_id="$("${bin}" generate rand --hex 8)"
      [[ "${private_key}" =~ ^[A-Za-z0-9_-]+$ && "${public_key}" =~ ^[A-Za-z0-9_-]+$ ]] || { CAUSE=keypair; false; }
      [[ "${uuid}" =~ ^[0-9a-f-]{36}$ && "${short_id}" =~ ^[0-9a-f]{16}$ ]] || { CAUSE=uuid; false; }
      log "$(L "轮换凭据：已生成新的 UUID / Reality 密钥 / short id" "Rotating credentials: generated a new UUID / Reality key / short id")"
    else
      uuid="$(kv_file_get "${ETC}/client.env" UUID)"
      public_key="$(kv_file_get "${ETC}/client.env" PUBLIC_KEY)"
      short_id="$(kv_file_get "${ETC}/client.env" SHORT_ID)"
      private_key="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inbounds"][0]["tls"]["reality"]["private_key"])' "${ETC}/config.json")"
    fi
    build_devices_new
    render_config "${ETC}/config.json.new" "${listen}" "${new_port}" "${uuid}" "${flow}" "${new_sni}" "${private_key}" "${short_id}" "${ETC}/devices.env.new"
    render_client_env "${ETC}/client.env.new" "${new_port}" "${uuid}" "${public_key}" "${short_id}" "${new_sni}" "${flow}" "${listen}" "$(kv_file_get "${ETC}/client.env" SOURCE)"
    check_config "${ETC}/config.json.new"
    STEP=BACKUP
  fi
  if [[ "${STEP}" == BACKUP ]]; then
    enter_step BACKUP
    if [[ -z "$(txn_get BACKUP_CONFIG)" || ! -f "$(txn_get BACKUP_CONFIG)" ]]; then
      ts="$(date '+%Y%m%d_%H%M%S')"
      # BACKUP_DEVICES 必须先于 BACKUP_CONFIG 写：BACKUP_CONFIG 是“备份已完成”的标记，反过来写时中断会漏掉设备备份。
      if [[ -f "${ETC}/devices.env" ]]; then
        cp -p "${ETC}/devices.env" "${ETC}/devices.env.bak.${ts}"
        txn_set BACKUP_DEVICES "${ETC}/devices.env.bak.${ts}"
      else
        txn_set BACKUP_DEVICES none
      fi
      cp -p "${ETC}/config.json" "${ETC}/config.json.bak.${ts}"
      cp -p "${ETC}/client.env" "${ETC}/client.env.bak.${ts}"
      txn_set BACKUP_CONFIG "${ETC}/config.json.bak.${ts}"
      txn_set BACKUP_CLIENT "${ETC}/client.env.bak.${ts}"
    fi
    STEP=REPLACE
  fi
  if [[ "${STEP}" == REPLACE ]]; then
    enter_step REPLACE
    [[ ! -f "${ETC}/config.json.new" ]] || mv -f "${ETC}/config.json.new" "${ETC}/config.json"
    [[ ! -f "${ETC}/client.env.new" ]] || mv -f "${ETC}/client.env.new" "${ETC}/client.env"
    # 设备表为空（吊销了最后一台）时删除文件，不留空文件。
    if [[ -f "${ETC}/devices.env.new" ]]; then
      if [[ -s "${ETC}/devices.env.new" ]]; then
        mv -f "${ETC}/devices.env.new" "${ETC}/devices.env"
      else
        rm -f "${ETC}/devices.env.new" "${ETC}/devices.env"
      fi
    fi
    STEP=RESTART
  fi
  if [[ "${STEP}" == RESTART ]]; then
    enter_step RESTART
    systemctl restart "${UNIT_NAME}" >/dev/null 2>&1 || true
    STEP=CHECK
  fi
  enter_step CHECK
  wait_active_and_port "${UNIT_NAME}" "$(kv_file_get "${ETC}/client.env" PORT)" 10 || { CAUSE='not-listening'; false; }
  finish_ok
}

# ---------- OP=migrate（§5.1.6） ----------

# 读出 233boy 的 Reality 参数（233boy src/core.sh:322-336、1248-1256 的 JSON 形态）；不合格时 exit 3 并打印原因。
legacy_params() {
  python3 - "${LEGACY_DIR}/conf" <<'PY'
import glob, json, os, sys
conf_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(conf_dir, "*.json")))
def bad(msg):
    print("ERROR=" + msg)
    sys.exit(3)
if len(files) != 1:
    bad("conf-count:%d" % len(files))
name = os.path.basename(files[0])
if not name.startswith("VLESS-REALITY-"):
    bad("conf-name:" + name)
data = json.load(open(files[0]))
inb = data.get("inbounds", [{}])[0]
if inb.get("type") != "vless" or "transport" in inb:
    bad("not-vless-reality-tcp")
user = inb.get("users", [{}])[0]
tls = inb.get("tls", {})
reality = tls.get("reality", {})
if user.get("flow") != "xtls-rprx-vision":
    bad("flow")
pub = ""
for out in data.get("outbounds", []):
    tag = out.get("tag", "")
    if tag.startswith("public_key_"):
        pub = tag[len("public_key_"):]
sid = (reality.get("short_id") or [""])[0]
values = {
    "LISTEN": inb.get("listen", "::"),
    "PORT": inb.get("listen_port"),
    "UUID": user.get("uuid", ""),
    "SNI": tls.get("server_name", ""),
    "PRIVATE_KEY": reality.get("private_key", ""),
    "PUBLIC_KEY": pub,
    "SHORT_ID": sid,
}
for key in ("PORT", "UUID", "SNI", "PRIVATE_KEY", "PUBLIC_KEY"):
    if not values[key]:
        bad("missing:" + key)
for key, value in values.items():
    print("%s=%s" % (key, value))
PY
}

# 私钥 → 公钥（X25519），用于核对 233boy 存的公钥确实与私钥配对；私钥不离开服务器。
derive_public_key() {
  local private_b64="$1" der pub
  command -v openssl >/dev/null 2>&1 || return 2
  der="$(python3 -c '
import base64,sys
k=sys.argv[1]; k += "=" * (-len(k) % 4)
raw=base64.urlsafe_b64decode(k)
sys.stdout.buffer.write(bytes.fromhex("302e020100300506032b656e04220420") + raw)' "${private_b64}" | base64 -w0)"
  pub="$(printf '%s' "${der}" | base64 -d | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  [[ -n "${pub}" ]] || return 1
  printf '%s' "${pub}"
}

migrate_rollback() {
  local port
  # 经 enter_step 写入 STEP，测试钩子 PAUSE_AT=ROLLBACK 才能在回滚途中打断（验证回滚中断后的恢复）。
  enter_step ROLLBACK
  trap 'rollback_failed' ERR
  if ! legacy_intact; then
    # CLEAN 已删掉一部分 233boy：旧服务起不来，绝不能再删新服务的配置（唯一可用的私钥副本）。
    systemctl enable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
    log "$(L "233boy 已不完整，保留 ownexit-direct；迁移备份：$(txn_get BACKUP_TAR)" "233boy is already incomplete; keeping ownexit-direct; migration backup: $(txn_get BACKUP_TAR)")"
    result_set BACKUP "$(txn_get BACKUP_TAR)"
    finish_fail clean-unhealthy
  fi
  port="$(txn_get LEGACY_PORT)"
  if [[ -e "${UNIT_FILE}" ]]; then systemctl disable --now "${UNIT_NAME}" >/dev/null 2>&1 || true; fi
  systemctl enable --now sing-box.service >/dev/null 2>&1 || true
  if wait_active_and_port sing-box.service "${port}" 10; then
    # 旧服务确认可用之后才删除新服务的文件。
    rm -f "${UNIT_FILE}"
    systemctl daemon-reload
    rm -rf "${ETC}"
    finish_fail rolled-back
  fi
  systemctl disable --now sing-box.service >/dev/null 2>&1 || true
  systemctl enable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
  finish_fail rollback-failed
}

migrate_clean() {
  local port
  port="$(kv_file_get "${ETC}/client.env" PORT)"
  if ! wait_active_and_port "${UNIT_NAME}" "${port}" 2; then
    systemctl restart "${UNIT_NAME}" >/dev/null 2>&1 || true
    wait_active_and_port "${UNIT_NAME}" "${port}" 10 || migrate_rollback
  fi
  # 健康核验已过：之后的删除出错不回滚，保留新服务（见 on_err 的 CLEAN_PHASE 分支）。
  CLEAN_PHASE=delete
  rm -rf /etc/systemd/system/sing-box.service.d
  rm -f "${LEGACY_UNIT_FILE}"
  systemctl daemon-reload
  for link in /usr/local/bin/sb /usr/local/bin/sing-box; do
    if [[ -L "${link}" ]]; then
      case "$(readlink "${link}")" in "${LEGACY_DIR}"/sh/*) rm -f "${link}" ;; esac
    fi
  done
  rm -rf "${LEGACY_DIR}" /var/log/sing-box
  if [[ -f /root/.bashrc ]]; then
    # 233boy install.sh:424-425 写入的两行，逐字匹配，不碰用户自己的内容。
    grep -vxF -e 'alias sb=/usr/local/bin/sing-box' -e 'alias sing-box=/usr/local/bin/sing-box' /root/.bashrc > /root/.bashrc.ownexit-tmp || true
    cat /root/.bashrc.ownexit-tmp > /root/.bashrc
    rm -f /root/.bashrc.ownexit-tmp
  fi
}

op_migrate() {
  local params pub derived ts tar_path start
  STEP="$(txn_get STEP)"
  start="$(arg MIGRATE_START)"
  if [[ -z "${STEP}" ]]; then
    STEP="${start:-INSPECT}"
  fi
  case "${STEP}" in
    ROLLBACK) migrate_rollback ;;
    SWITCH|CHECK)
      # 恢复：新服务的单元与配置都在才重新切换，否则只能回滚。
      if [[ -e "${UNIT_FILE}" && -f "${ETC}/config.json" ]]; then STEP=SWITCH; else migrate_rollback; fi
      ;;
  esac
  if [[ "${STEP}" == INSPECT ]]; then
    enter_step INSPECT
    unit_active sing-box.service || { CAUSE='legacy-not-active'; false; }
    params="$(legacy_params)" || { log "$(L "不可迁移：${params}" "Cannot migrate: ${params}")"; CAUSE="$(printf '%s\n' "${params}" | awk -F= '$1=="ERROR"{print $2}')"; false; }
    pub="$(printf '%s\n' "${params}" | awk -F= '$1=="PUBLIC_KEY"{print $2}')"
    if derived="$(derive_public_key "$(printf '%s\n' "${params}" | awk -F= '$1=="PRIVATE_KEY"{print $2}')")"; then
      [[ "${derived}" == "${pub}" ]] || { CAUSE='keypair-mismatch'; false; }
    else
      log "$(L "服务器没有可用的 openssl，跳过公私钥配对校验" "The server has no usable openssl; skipping the key pair check")"
    fi
    txn_set LEGACY_PORT "$(printf '%s\n' "${params}" | awk -F= '$1=="PORT"{print $2}')"
    STEP=BINARY
  fi
  if [[ "${STEP}" == BINARY ]]; then
    enter_step BINARY
    ensure_binary
    STEP=CONFIG
  fi
  if [[ "${STEP}" == CONFIG ]]; then
    enter_step CONFIG
    params="$(legacy_params)" || { CAUSE='legacy-changed'; false; }
    get() { printf '%s\n' "${params}" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print}'; }
    install -d -m 700 "${ETC}"
    render_config "${ETC}/config.json" "$(get LISTEN)" "$(get PORT)" "$(get UUID)" xtls-rprx-vision "$(get SNI)" "$(get PRIVATE_KEY)" "$(get SHORT_ID)" ''
    render_client_env "${ETC}/client.env" "$(get PORT)" "$(get UUID)" "$(get PUBLIC_KEY)" "$(get SHORT_ID)" "$(get SNI)" xtls-rprx-vision "$(get LISTEN)" migrated
    check_config "${ETC}/config.json"
    write_unit
    STEP=BACKUP
  fi
  if [[ "${STEP}" == BACKUP ]]; then
    enter_step BACKUP
    if [[ -z "$(txn_get BACKUP_TAR)" || ! -f "$(txn_get BACKUP_TAR)" ]]; then
      install -d -m 700 "${BACKUP_DIR}"
      ts="$(date '+%Y%m%d_%H%M%S')"
      tar_path="${BACKUP_DIR}/233boy-${ts}.tar.gz"
      txn_set BACKUP_TAR_PENDING "${tar_path}"
      tar czf "${tar_path}" --ignore-failed-read "${LEGACY_DIR}" "${LEGACY_UNIT_FILE}" /usr/local/bin/sb /usr/local/bin/sing-box /root/.bashrc 2>/dev/null
      chmod 600 "${tar_path}"
      txn_set BACKUP_TAR "${tar_path}"
    fi
    log "$(L "迁移备份：$(txn_get BACKUP_TAR)" "Migration backup: $(txn_get BACKUP_TAR)")"
    result_set BACKUP "$(txn_get BACKUP_TAR)"
    STEP=SWITCH
  fi
  if [[ "${STEP}" == SWITCH ]]; then
    enter_step SWITCH
    systemctl stop sing-box.service >/dev/null 2>&1 || true
    systemctl disable sing-box.service >/dev/null 2>&1 || true
    systemctl enable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
    STEP=CHECK
  fi
  if [[ "${STEP}" == CHECK ]]; then
    enter_step CHECK
    wait_active_and_port "${UNIT_NAME}" "$(kv_file_get "${ETC}/client.env" PORT)" 10 || { CAUSE='not-listening'; false; }
    STEP=CLEAN
  fi
  enter_step CLEAN
  migrate_clean
  finish_ok
}

# ---------- OP=uninstall（§5.1.7，conflict / leftover / none 也走这里，只删 ownexit 路径） ----------

op_uninstall() {
  local port sub_port
  enter_step STOP
  port="$(kv_file_get "${ETC}/client.env" PORT)"
  sub_port="$(arg SUB_PORT)"
  for unit in "${UNIT_NAME}" ownexit-subscription.service; do
    if [[ "$(unit_load_state "${unit}")" != not-found ]]; then
      systemctl disable --now "${unit}" >/dev/null 2>&1 || true
    fi
  done
  enter_step FILES
  rm -f "${UNIT_FILE}" "${SUB_UNIT_FILE}"
  systemctl daemon-reload
  systemctl reset-failed "${UNIT_NAME}" ownexit-subscription.service >/dev/null 2>&1 || true
  rm -rf "${ETC}" "${OPT}" /opt/ownexit-subscription
  enter_step UFW
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n 1 | grep -q 'Status: active'; then
    [[ -z "${port}" ]] || ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    [[ -z "${sub_port}" ]] || ufw delete allow "${sub_port}/tcp" >/dev/null 2>&1 || true
  fi
  finish_ok
}

# ---------- 失败收尾（§5.1.2 第 4 条） ----------

rollback_failed() {
  trap - ERR
  set +e
  log "$(L "回滚本身失败；ownexit-direct=$(systemctl is-active "${UNIT_NAME}" 2>/dev/null) sing-box=$(systemctl is-active sing-box.service 2>/dev/null) 备份=$(txn_get BACKUP_TAR)" "The rollback itself failed; ownexit-direct=$(systemctl is-active "${UNIT_NAME}" 2>/dev/null) sing-box=$(systemctl is-active sing-box.service 2>/dev/null) backup=$(txn_get BACKUP_TAR)")"
  rm -f "${TXN}"
  result_set RESULT fail
  result_set REASON rollback-failed
  exit 1
}

on_err() {
  set +e
  trap - ERR
  local cause="${CAUSE:-error}"
  log "$(L "步骤 ${STEP:-?} 出错（${cause}）" "Step ${STEP:-?} failed (${cause})")"
  case "${OP}" in
    fresh)
      remove_ownexit_service_files
      ;;
    repair)
      ;;
    reparam)
      if [[ "${STEP}" == WRITE ]]; then
        rm -f "${ETC}/config.json.new" "${ETC}/client.env.new" "${ETC}/devices.env.new" "${ETC}/devices.env.new.tmp"
      else
        set -eE; reparam_rollback
      fi
      ;;
    migrate)
      if [[ "${CLEAN_PHASE:-}" == delete ]]; then
        rm -f "${TXN}"
        result_set RESULT fail
        result_set REASON "CLEAN-${cause}"
        exit 1
      fi
      case "${STEP}" in
        INSPECT|BINARY|CONFIG|BACKUP)
          remove_ownexit_service_files
          [[ -z "$(txn_get BACKUP_TAR_PENDING)" || -n "$(txn_get BACKUP_TAR)" ]] || rm -f "$(txn_get BACKUP_TAR_PENDING)"
          ;;
        *)
          set -eE; migrate_rollback
          ;;
      esac
      ;;
    uninstall)
      # 卸载不撤销：保留 txn，下次运行继续卸载（各步幂等）。
      result_set RESULT fail
      result_set REASON "${STEP}-${cause}"
      exit 1
      ;;
  esac
  rm -f "${TXN}"
  result_set RESULT fail
  result_set REASON "${STEP}-${cause}"
  exit 1
}

run_op() {
  [[ -f "${ARGS}" ]] || { echo "$(L "缺少 ${ARGS}" "Missing ${ARGS}")" >&2; exit 2; }
  : > "${RESULT}"
  chmod 600 "${RESULT}"
  OP="$(txn_get OP)"
  if [[ -z "${OP}" ]]; then
    OP="$(arg OP)"
    txn_set OP "${OP}"
    txn_set STARTED "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  else
    log "$(L "恢复上次未完成的操作：OP=${OP} STEP=$(txn_get STEP)" "Resuming the unfinished operation: OP=${OP} STEP=$(txn_get STEP)")"
    result_set RESUMED "${OP}"
  fi
  result_set OP "${OP}"
  STEP=''
  CAUSE=''
  CLEAN_PHASE=''
  trap on_err ERR
  case "${OP}" in
    fresh) op_fresh ;;
    repair) op_repair ;;
    reparam) op_reparam ;;
    migrate) op_migrate ;;
    uninstall) op_uninstall ;;
    *) trap - ERR; rm -f "${TXN}"; echo "$(L "未知操作：${OP}" "Unknown operation: ${OP}")" >&2; exit 2 ;;
  esac
}

case "${1:-}" in
  probe) probe ;;
  run) run_op ;;
  -h|--help) sed -n '2,20p' "$0" ;;
  *) echo "$(L "用法：direct_remote.sh probe | run（由 setup_direct.sh 投递到 VPS 执行）" "Usage: direct_remote.sh probe | run (sent to the VPS and run by setup_direct.sh)")" >&2; exit 2 ;;
esac
