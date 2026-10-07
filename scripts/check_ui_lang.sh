#!/usr/bin/env bash
# check_ui_lang.sh —— 防止运行时脚本里出现没有双语化的中文提示（docs/feature/feature-script-i18n.md §5.1.3）。
#
# 前置:
#   - 在开发机或 CI 上运行（macOS / Linux，bash 3.2 及以上）；只用 awk，不连网、不改文件。
#   - 默认检查本脚本所在的仓库；--root 指定另一个仓库副本（负向测试用）。
#   - 不应被 source。
#
# 规则（逐行、带引号状态跨行延续）：
#   1. 代码里的中文必须在某个 L 调用的第一个参数里：L "中文" "English"。注释（行首或空白后的 #）不查。
#      L 只认前面是行首、空白、( 或 " 的写法，排除 -L 文件测试。
#   2. 每个 L：第二个参数非空、不含中文，两个参数里 %、${、$( 的个数相等，printf 占位符的类型与顺序一致（printf 占位或变量漏传是改写的主要风险）；
#      参数不得跨行。
#   3. heredoc 正文：中文帮助等整块中文用 `# i18n:zh-begin` / `# i18n:zh-end` 两行标记包住，块内不查；
#      其余正文的整行注释跳过，其它行按规则 1、2 逐行判断（不去行内 #：帮助里的 ` # 说明` 是给用户看的）。
#   4. 跨行字符串里的中文（不在 L 里）同样报错。

set -uo pipefail
# 按字节匹配中文：UTF-8 的 CJK 汉字与全角标点首字节在 \343-\351，以及 \357\274 / \357\275 开头的全角字符。
export LC_ALL=C

usage() {
  cat <<'EOF'
用法: scripts/check_ui_lang.sh [--root <仓库根目录>]

检查运行时脚本里的中文提示都已写成 L "中文" "English"，且两种语言的 % 与 ${ 个数一致。
全部通过退出 0，否则逐条打印 文件:行 与原因并退出 1。

选项:
  --root <目录>   要检查的仓库根目录，默认是本脚本所在的仓库
  -h, --help      显示帮助

示例:
  scripts/check_ui_lang.sh
  scripts/check_ui_lang.sh --root /tmp/ownexit-copy

退出码: 0 全部通过；1 有问题；2 参数错误或文件缺失。
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

FILES='direct/setup_direct.sh direct/subctl direct/connect_to.sh direct/doctor.sh direct/sync_to_vps.sh direct/direct_remote.sh direct/target_lib.sh chain/setup_chain.sh chain/multi_chain_client.sh'
for f in ${FILES}; do
  [[ -f "${f}" ]] || { echo "[!] 缺少文件：${f}" >&2; exit 2; }
done

# shellcheck disable=SC2086  # FILES 是固定的空格分隔清单，有意按空格拆开
awk '
# 另含 \342\200 开头的中文弯引号 U+2018/2019/201C/201D（只由引号与中文标点组成的提示也要拦）；
# 省略号 U+2026 与破折号 U+2014 英文里也常用，不算中文。
function has_cjk(s) { return s ~ /[\343-\351]|\357\274|\357\275|\342\200[\230\231\234\235]/ }
# printf 占位符按出现顺序拼成序列（如 "%s|%d|"），用来比较两种语言的类型与顺序。
function pct_seq(s,   out, t) { out = ""; t = s; while (match(t, /%[-+ #0-9.]*[a-zA-Z%]/)) { out = out substr(t, RSTART, RLENGTH) "|"; t = substr(t, RSTART + RLENGTH) } return out }
function count(s, pat,   n, t) { n = 0; t = s; while (match(t, pat)) { n++; t = substr(t, RSTART + RLENGTH) } return n }
function err(msg) { printf "[FAIL] %s:%d：%s\n", FILENAME, FNR, msg; fails++ }
# 从 pos 起解析一个 shell 单词（相邻的引号段与裸字符），返回结束位置的下一个字符；内容放在 WORD，跨行时 WORD_EOL=1。
function parse_word(s, pos,   c, n, depth, q) {
  WORD = ""; WORD_EOL = 0; n = length(s)
  while (pos <= n) {
    c = substr(s, pos, 1)
    if (c == " " || c == "\t" || c == ")" || c == ";") break
    if (c == "\\") { WORD = WORD substr(s, pos, 2); pos += 2; continue }
    if (c == "'"'"'") {
      q = index(substr(s, pos + 1), "'"'"'")
      if (q == 0) { WORD_EOL = 1; WORD = WORD substr(s, pos + 1); return n + 1 }
      WORD = WORD substr(s, pos + 1, q - 1); pos += q + 1; continue
    }
    if (c == "\"") {
      pos++; depth = 0
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (c == "\\") { WORD = WORD substr(s, pos, 2); pos += 2; continue }
        if (depth == 0 && c == "\"") break
        if (substr(s, pos, 2) == "$(") { depth++; WORD = WORD "$("; pos += 2; continue }
        if (depth > 0 && c == ")") depth--
        WORD = WORD c; pos++
      }
      if (pos > n) { WORD_EOL = 1; return n + 1 }
      pos++; continue
    }
    WORD = WORD c; pos++
  }
  return pos
}
FNR == 1 { state = ""; stack = ""; inhd = 0; inmark = 0; pending = "" }
{
  line = $0
  hdline = 0
  if (inhd) {
    t = line; if (hdstrip) sub(/^\t+/, "", t)
    if (t == hdterm) { inhd = 0; next }
    if (inmark) next
    # heredoc 正文：整行注释（远端脚本里的说明）跳过；其余行按代码规则逐行判断，引号状态不跨行、不去行内 #。
    if (line ~ /^[ \t]*#/) next
    hdline = 1; state = ""; saved_stack = stack; stack = ""
  }
  if (state == "" && line ~ /^[ \t]*# i18n:zh-begin/) { inmark = 1; next }
  if (state == "" && line ~ /^[ \t]*# i18n:zh-end/) { inmark = 0; next }
  if (inmark) {
    # 标记块内照样识别 heredoc，避免块内 heredoc 的终止符被当成代码。
    if (match(line, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
      w = substr(line, RSTART, RLENGTH); hdstrip = (w ~ /^<<-/); gsub(/^<<-?[ \t]*["'"'"']?|["'"'"']?$/, "", w)
      hdterm = w; inhd = 1
    }
    next
  }
  # stack 记录 "$( … )" 的嵌套，要跨行延续（双引号里的多行远端命令很常见）。
  out = ""; i = 1; n = length(line)
  while (i <= n) {
    c = substr(line, i, 1)
    if (state == "sq") {
      if (c == "'"'"'") state = ""
      if (has_cjk(c)) sqcjk = 1
      out = out c; i++; continue
    }
    if (state == "dq") {
      if (c == "\\") { out = out substr(line, i, 2); i += 2; continue }
      if (substr(line, i, 2) == "$(") { stack = stack "d"; state = ""; out = out "$("; i += 2; continue }
      if (c == "\"") state = ""
      out = out c; i++; continue
    }
    # 代码状态
    if (!hdline && c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;(]/)) break
    if (c == "\\") { out = out substr(line, i, 2); i += 2; continue }
    if (c == ")" && length(stack) > 0) { stack = substr(stack, 1, length(stack) - 1); state = "dq"; out = out c; i++; continue }
    if (c == "L" && substr(line, i + 1, 1) == " " && (i == 1 || substr(line, i - 1, 1) ~ /[ \t("]/)) {
      j = parse_word(line, i + 2)
      if (WORD_EOL) { err("L 的参数跨行"); out = out substr(line, i); break }
      a1 = WORD
      while (substr(line, j, 1) == " ") j++
      k = parse_word(line, j)
      if (WORD_EOL) { err("L 的参数跨行"); out = out substr(line, i); break }
      a2 = WORD
      if (a2 == "") err("L 缺少英文（第二个参数为空）")
      else if (has_cjk(a2)) err("L 的英文（第二个参数）里有中文")
      if (count(a1, "%") != count(a2, "%")) err("L 两种语言的 % 占位个数不同")
      else if (pct_seq(a1) != pct_seq(a2)) err("L 两种语言的 % 占位类型或顺序不同")
      if (count(a1, "\\$\\{") != count(a2, "\\$\\{")) err("L 两种语言的 ${ 个数不同")
      if (count(a1, "\\$\\(") != count(a2, "\\$\\(")) err("L 两种语言的 $( 个数不同")
      out = out "L"; i = k; continue
    }
    if (c == "'"'"'") { state = "sq"; sqcjk = 0; out = out c; i++; continue }
    if (c == "\"") { state = "dq"; out = out c; i++; continue }
    if (!hdline && substr(line, i, 2) == "<<" && substr(line, i, 3) != "<<<") {
      if (match(substr(line, i), /^<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
        w = substr(line, i, RLENGTH); pending_strip = (w ~ /^<<-/); gsub(/^<<-?[ \t]*["'"'"']?|["'"'"']?$/, "", w)
        pending = w; i += RLENGTH; out = out w; continue
      }
    }
    out = out c; i++
  }
  if (has_cjk(out)) err(hdline ? "heredoc 正文里的中文不在 L 的第一个参数里（整块中文帮助请用 # i18n:zh-begin / zh-end 标记）" : "中文不在 L \"中文\" \"English\" 的第一个参数里")
  if (hdline) { state = ""; stack = saved_stack }
  if (pending != "") { inhd = 1; hdterm = pending; hdstrip = pending_strip; pending = "" }
}
END {
  printf "ui-lang: fail=%d\n", fails + 0
  exit (fails > 0) ? 1 : 0
}
' ${FILES}
