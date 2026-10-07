#!/usr/bin/env bash
# check_i18n.sh —— 中英双语文档防走样：成对文档都存在、互相链接，英文页不链回中文页、锚点有效
# （docs/feature/feature-bilingual-docs.md §5.1.3）。只查结构，不查译文是否准确。
#
# 前置:
#   - 在开发机或 CI 上运行（macOS / Linux，bash 3.2 及以上）；只用 awk / grep / sed / tr，不连网、不改文件。
#   - 默认检查本脚本所在的仓库；--root 指定另一个仓库副本（负向测试用）。
#   - 不应被 source。
#
# 检查项（逐对）：
#   1. 中文版与英文版两个文件都存在。
#   2. 中文版前 5 行有指向英文版的链接，英文版前 5 行有指向中文版的链接（按 ](文件名) 或 /文件名) 精确匹配）。
#   3. 英文版里的链接（顶部切换行除外）：仓库内目标必须存在，且不得是成对清单里的中文版。
#      README.md 里 https://github.com/jakoes-wu/ownexit/blob/main/<路径> 形式的链接按仓库内路径处理。
#   4. 英文版链接里的 #锚点：含非 ASCII 字符直接判失败（英文页的目标标题都是英文，中文锚点必是漏改）；
#      ASCII 锚点必须对应目标文件里的某个标题（GitHub 规则：小写，去掉字母、数字、_、-、空格以外的字符，空格换 -）。
#   围栏代码块（```）里的内容不检查。

set -uo pipefail
# 固定 C locale：BSD awk 在 UTF-8 locale 下可能把汉字当作可忽略字符（check_interface.sh 同样的教训）。
export LC_ALL=C

usage() {
  cat <<'EOF'
用法: scripts/check_i18n.sh [--root <仓库根目录>]

检查中英成对文档的结构：都存在、顶部互相链接、英文页不链回中文页、英文页锚点有效。
全部通过退出 0，否则逐条打印问题并退出 1。

选项:
  --root <目录>   要检查的仓库根目录，默认是本脚本所在的仓库
  -h, --help      显示帮助

示例:
  scripts/check_i18n.sh
  scripts/check_i18n.sh --root /tmp/ownexit-copy

退出码: 0 全部通过；1 有问题；2 参数错误。
EOF
}

ROOT=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 && -n "$2" ]] || { echo "[!] --root 需要一个目录（用 --help 查看用法）" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] 未知参数: $1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done
[[ -n "${ROOT}" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}" || { echo "[!] 无法进入 ${ROOT}" >&2; exit 2; }

# 成对清单：中文版 英文版。新增成对文档时在这里加一行，CONTRIBUTING.md 的约定同步。
PAIRS='docs/manual/direct.md docs/manual/direct.en.md
docs/manual/chain.md docs/manual/chain.en.md
docs/manual/clash-direct-ips.md docs/manual/clash-direct-ips.en.md
docs/manual/vps.md docs/manual/vps.en.md
docs/reference/commands.md docs/reference/commands.en.md
docs/reference/files.md docs/reference/files.en.md
docs/reference/compatibility.md docs/reference/compatibility.en.md
chain/README.md chain/README.en.md
direct/README.md direct/README.en.md
README.zh-CN.md README.md'

REPO_URL_PREFIX='https://github.com/jakoes-wu/ownexit/blob/main/'
N_FAIL=0
fail() { N_FAIL=$((N_FAIL + 1)); printf '[FAIL] %s\n' "$*"; }

# 中文版文件集合：英文页链接到其中任何一个都算“链回中文版”。
ZH_SET=" $(printf '%s\n' "${PAIRS}" | awk '{printf "%s ", $1}')"

# 把 "<所在目录>/<相对路径>" 规整成仓库内路径（处理 . 与 ..），越出仓库时输出空。
normalize_path() {
  printf '%s\n' "$1" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n == 0) { print ""; exit } ; n--; continue }
      part[++n] = $i
    }
    out = ""
    for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") part[i]
    print out
  }'
}

# 文件里所有标题的 GitHub 锚点（只对 ASCII 部分有意义；非 ASCII 字符被删掉，不会与 ASCII 锚点误配）。
heading_slugs() {
  awk '/^```/ {inblock = !inblock; next} !inblock && /^#+ / { sub(/^#+ +/, ""); print }' "$1" \
    | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9_ -]//g; s/ /-/g'
}

# 输出文件里围栏代码块外的链接：行号<TAB>目标。
links_of() {
  awk '/^```/ {inblock = !inblock; next}
       !inblock {
         line = $0
         while (match(line, /\]\([^)]+\)/)) {
           target = substr(line, RSTART + 2, RLENGTH - 3)
           printf "%d\t%s\n", NR, target
           line = substr(line, RSTART + RLENGTH)
         }
       }' "$1"
}

check_top_link() {
  local file="$1" other="$2" base
  base="$(basename "${other}")"
  # 精确匹配 ](base) 或 /base)，避免 README.md 误配 README.en.md 之类的子串。
  head -n 5 "${file}" | grep -qF -e "](${base})" -e "/${base})" \
    || fail "${file}：前 5 行没有指向 ${other} 的切换链接"
}

check_en_links() {
  local en="$1" zh="$2" dir lineno target path anchor resolved
  dir="$(dirname "${en}")"
  [[ "${dir}" == . ]] && dir=''
  while IFS="$(printf '\t')" read -r lineno target; do
    [[ -n "${target}" ]] || continue
    case "${target}" in
      mailto:*) continue ;;
      "${REPO_URL_PREFIX}"*) path="${target#"${REPO_URL_PREFIX}"}"; resolved_base='' ;;
      http://*|https://*) continue ;;
      *) path="${target}"; resolved_base="${dir}" ;;
    esac
    anchor=''
    case "${path}" in
      *'#'*) anchor="${path#*#}"; path="${path%%#*}" ;;
    esac
    if [[ -z "${path}" ]]; then
      resolved="${en}"
    elif [[ -n "${resolved_base}" ]]; then
      resolved="$(normalize_path "${resolved_base}/${path}")"
    else
      resolved="$(normalize_path "${path}")"
    fi
    if [[ -z "${resolved}" ]]; then
      fail "${en}:${lineno}：链接 ${target} 越出了仓库"
      continue
    fi
    # 顶部切换行指向自己的中文版，是唯一允许的“链回中文版”。
    if [[ "${resolved}" == "${zh}" && "${lineno}" -le 5 ]]; then
      continue
    fi
    if [[ ! -e "${resolved}" ]]; then
      fail "${en}:${lineno}：链接目标不存在：${target}"
      continue
    fi
    case "${ZH_SET}" in
      *" ${resolved} "*) fail "${en}:${lineno}：英文页链回了中文版 ${resolved}（应改链英文版）"; continue ;;
    esac
    [[ -n "${anchor}" ]] || continue
    if printf '%s' "${anchor}" | LC_ALL=C grep -q '[^ -~]'; then
      fail "${en}:${lineno}：锚点含非 ASCII 字符（中文锚点漏改）：${target}"
      continue
    fi
    [[ -f "${resolved}" ]] || continue
    heading_slugs "${resolved}" | grep -qxF -- "${anchor}" \
      || fail "${en}:${lineno}：${resolved} 里没有锚点 #${anchor} 对应的标题"
  done < <(links_of "${en}")
}

N_PAIRS=0
while read -r zh en; do
  [[ -n "${zh}" ]] || continue
  N_PAIRS=$((N_PAIRS + 1))
  missing=0
  [[ -f "${zh}" ]] || { fail "缺少中文版：${zh}"; missing=1; }
  [[ -f "${en}" ]] || { fail "缺少英文版：${en}"; missing=1; }
  [[ "${missing}" == 0 ]] || continue
  check_top_link "${zh}" "${en}"
  check_top_link "${en}" "${zh}"
  check_en_links "${en}" "${zh}"
done <<EOF
${PAIRS}
EOF

echo "i18n: pairs=${N_PAIRS} fail=${N_FAIL}"
[[ "${N_FAIL}" -eq 0 ]]
