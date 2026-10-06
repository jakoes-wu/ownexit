#!/usr/bin/env bash
# check_public.sh —— 公开前隐私扫描：防止真实 IP、私网地址和个人标识进入公开仓库。
#
# 前置:
#   - 在本仓库 git 工作区内运行（依赖 git ls-files / git log）；需要 grep、awk、sort。
#   - 可选本地黑名单：${OWNEXIT_DENYLIST:-~/.config/ownexit-dev/denylist}，每行一个不区分大小写的字面量
#     （供应商名、主机别名、个人账号等）。黑名单放在仓库外：把它提交进来本身就等于公开了这些词。
#     CI 里没有这个文件，只做 IPv4 白名单检查。
#   - 不应被 source。
#
# 检查项：
#   1. IPv4 白名单：所有被跟踪文件里出现的 IPv4 字面量必须属于白名单（回环、文档网段、fake-ip 网段、公共 DNS），
#      私网地址（10/8、172.16/12、192.168/16）也算失败——它们会暴露个人局域网拓扑。
#   2. 本地黑名单：逐行不区分大小写匹配。
#   加 --history 时，对 `git log -p --all` 的全部输出做同样的检查（首次推送前、改公开前各跑一次）。

set -euo pipefail

usage() {
  cat <<'EOF'
用法: scripts/check_public.sh [--history]

  （无参数）   扫描当前被 git 跟踪的文件（含暂存区里新增但未提交的文件）
  --history    改为扫描全部提交历史（git log -p --all）
  -h, --help   显示帮助

示例:
  scripts/check_public.sh
  scripts/check_public.sh --history
  OWNEXIT_DENYLIST=~/my-denylist scripts/check_public.sh

退出码: 0 通过；1 发现问题（逐条打印 文件:行号: 命中值）；2 参数错误或不在 git 工作区。
EOF
}

MODE=tree
case "${1:-}" in
  '') ;;
  --history) MODE=history ;;
  -h|--help) usage; exit 0 ;;
  *) echo "[!] 未知参数：$1（用 --help 查看用法）" >&2; exit 2 ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo '[!] 不在 git 工作区内' >&2; exit 2; }
cd "${REPO_ROOT}"
DENYLIST="${OWNEXIT_DENYLIST:-${HOME}/.config/ownexit-dev/denylist}"
FAILED=0

# 白名单判断：只放行明确无害的地址。新增白名单前先想清楚它会不会暴露真实环境。
ipv4_allowed() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"${ip}"
  for octet in "${a}" "${b}" "${c}" "${d}"; do
    # 任一段超过 3 位或大于 255 就不是 IPv4（多半是版本号之类），不当作地址
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] && (( 10#${octet} <= 255 )) || return 0
  done
  a=$((10#${a})) b=$((10#${b})) c=$((10#${c}))
  (( a == 127 )) && return 0                                  # 回环
  [[ "${ip}" == 0.0.0.0 ]] && return 0                        # 监听通配
  (( a == 192 && b == 0 && c == 2 )) && return 0              # RFC 5737 TEST-NET-1
  (( a == 198 && b == 51 && c == 100 )) && return 0           # RFC 5737 TEST-NET-2
  (( a == 203 && b == 0 && c == 113 )) && return 0            # RFC 5737 TEST-NET-3
  (( a == 198 && (b == 18 || b == 19) )) && return 0          # mihomo fake-ip 网段 198.18.0.0/15
  [[ "${ip}" == 172.19.0.1 ]] && return 0                    # sing-box.json 的 tun 虚拟网卡地址（客户端本机虚拟网段，固定值）
  case "${ip}" in
    1.1.1.1|8.8.8.8|223.5.5.5|119.29.29.29) return 0 ;;      # 渲染配置里用到的公共 DNS
  esac
  return 1
}

report() {
  echo "[!] $*"
  FAILED=1
}

# 输入：每行 "位置<TAB>文本"；位置在 tree 模式是 文件:行号，history 模式是 提交:文件。
# 用一个 awk 进程完成提取，避免逐行起子进程（仓库里单个脚本就有六千多行）。
# 输出：每行 "IP<TAB>位置<TAB>地址" 或 "DENY<TAB>位置"。
extract_hits() {
  local deny_file="$1"
  awk -F '\t' -v deny_file="${deny_file}" '
    BEGIN {
      n = 0
      if (deny_file != "") {
        while ((getline w < deny_file) > 0) {
          if (w == "" || substr(w, 1, 1) == "#") continue
          deny[++n] = tolower(w)
        }
      }
    }
    {
      where = $1
      text = substr($0, length($1) + 2)
      rest = text
      while (match(rest, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        before = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
        after = substr(rest, RSTART + RLENGTH, 1)
        ip = substr(rest, RSTART, RLENGTH)
        # 前后紧邻数字或点说明是更长串（如五段版本号）的一部分，不当作地址
        if (before !~ /[0-9.]/ && after !~ /[0-9.]/) print "IP\t" where "\t" ip
        rest = substr(rest, RSTART + RLENGTH)
      }
      low = tolower(text)
      for (i = 1; i <= n; i++) if (index(low, deny[i]) > 0) { print "DENY\t" where; break }
    }'
}

scan_stream() {
  local kind where value deny_file=""
  [[ -f "${DENYLIST}" ]] && deny_file="${DENYLIST}"
  while IFS=$'\t' read -r kind where value; do
    case "${kind}" in
      IP) ipv4_allowed "${value}" || report "${where}: 非白名单 IPv4 ${value}" ;;
      DENY) report "${where}: 命中本地黑名单词" ;;
    esac
  done < <(extract_hits "${deny_file}")
}

tree_lines() {
  local file
  # 只扫被跟踪 / 已暂存的文件；本脚本自身包含白名单 IP，显式排除。
  git ls-files --cached -z | while IFS= read -r -d '' file; do
    [[ "${file}" == scripts/check_public.sh ]] && continue
    [[ -f "${file}" ]] || continue
    grep -Iq . "${file}" 2>/dev/null || continue   # 跳过二进制文件
    awk -v f="${file}" '{ printf "%s:%d\t%s\n", f, NR, $0 }' "${file}"
  done
}

history_lines() {
  # 以 "提交:文件" 定位；只看新增行（+ 开头），删除行在历史里本来就看得到，同样要报，所以 - 行也扫。
  git log -p --all --format='commit %H' | awk '
    /^commit [0-9a-f]+$/ { c = substr($2, 1, 12); next }
    /^diff --git / { f = $4; sub(/^b\//, "", f); next }
    /^[+-]/ && !/^(\+\+\+|---) / { printf "%s:%s\t%s\n", c, f, substr($0, 2) }
  ' | grep -v '^[0-9a-f]*:scripts/check_public.sh'$'\t' || true
}

if [[ "${MODE}" == history ]]; then
  scan_stream < <(history_lines)
else
  scan_stream < <(tree_lines)
fi

if [[ ! -f "${DENYLIST}" ]]; then
  echo "[*] 未找到本地黑名单 ${DENYLIST}，只做了 IPv4 白名单检查"
fi
if [[ "${FAILED}" -ne 0 ]]; then
  echo "[!] 隐私扫描未通过（mode=${MODE}）"
  exit 1
fi
echo "[+] 隐私扫描通过（mode=${MODE}）"
