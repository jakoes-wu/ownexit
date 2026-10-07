#!/usr/bin/env bash
# check_interface.sh —— 接口冻结守护（2.x）：从源码提取命令参数、子命令、机器可读输出、配置与状态键、订阅文件名，
# 与 docs/reference/ 下的参考文档逐项比对，不一致就失败（docs/feature/feature-v1-freeze.md §5.1.2）。
#
# 前置:
#   - 在开发机或 CI 上运行（macOS / Linux，bash 3.2 及以上）；只用 awk / grep / sed / sort / comm，不连网、不改文件。
#   - 默认检查本脚本所在的仓库；--root 指定另一个仓库副本（负向测试用）。
#   - 不应被 source。
#
# 子命令清单含 direct（主参数循环的分支词）、multi、chain（direct/subctl 2.0 起是 direct 日常操作的内部实现，不再单列）。
# 另比对 docs/reference/ 下中英两版（*.md 与 *.en.md）的表格首列（第 14 项）。
# 用途：以后改动参数、子命令、status 取值、配置 / 状态键、订阅文件名时，必须同步更新参考文档，
# 否则本脚本（CI 的 Interface freeze 步骤）失败。只守护“可机读”的清单；退出码、路径、节点名等由人工核对
# （见 docs/reference/compatibility.md）。

# 不用 set -e：grep 没有匹配会返回 1，提取不到的情况应当表现为“集合为空”，交给 compare 报出来，而不是让脚本静默退出。
set -uo pipefail
# 固定 C locale：部分 awk 按 locale 排序规则（strcoll）比较字符串，UTF-8 下汉字可能被当作可忽略字符，
# 导致“### 参数”与“### 子命令”被判为相等（CI 的 macOS 实测如此）。C locale 下逐字节比较。
export LC_ALL=C

usage() {
  cat <<'EOF'
用法: check_interface.sh [--root <仓库根目录>]

比对源码里的公开接口与 docs/reference/ 参考文档，全部一致时退出 0，否则打印差异并退出 1。

选项:
  --root <目录>   要检查的仓库根目录，默认是本脚本所在的仓库
  -h, --help      显示帮助

示例:
  scripts/check_interface.sh
  scripts/check_interface.sh --root /tmp/ownexit-copy

退出码: 0 全部一致；1 有不一致；2 参数错误或文件缺失。
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

CMDS=docs/reference/commands.md
FILES=docs/reference/files.md
for f in "${CMDS}" "${FILES}" docs/reference/compatibility.md \
         docs/reference/commands.en.md docs/reference/files.en.md docs/reference/compatibility.en.md src/ownexit/cli.py direct/setup_direct.sh direct/connect_to.sh direct/subctl direct/doctor.sh \
         direct/direct_remote.sh chain/setup_chain.sh chain/multi_chain_client.sh chain/chain.example.env; do
  [[ -f "${f}" ]] || { echo "[!] 缺少文件：${f}" >&2; exit 2; }
done

N_OK=0
N_FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# 比较两个集合（每行一个取值）。$1 = 检查项名，$2 = 源码集合文件，$3 = 文档集合文件。
compare() {
  local name="$1" src="$2" doc="$3" only_src only_doc
  sort -u "${src}" | awk 'NF' > "${src}.s"
  sort -u "${doc}" | awk 'NF' > "${doc}.s"
  only_src="$(comm -23 "${src}.s" "${doc}.s" | tr '\n' ' ')"
  only_doc="$(comm -13 "${src}.s" "${doc}.s" | tr '\n' ' ')"
  if [[ -z "${only_src}${only_doc}" && -s "${src}.s" ]]; then
    N_OK=$((N_OK + 1))
    printf '[ok] %s（%s 项）\n' "${name}" "$(awk 'END {print NR}' "${src}.s")"
  else
    N_FAIL=$((N_FAIL + 1))
    printf '[FAIL] %s：源码有、文档没有：%s／文档有、源码没有：%s\n' "${name}" "${only_src:-无}" "${only_doc:-无}"
    [[ -s "${src}.s" ]] || printf '       （源码侧一个都没提取到，提取锚点可能失效）\n'
  fi
}

# ---------- 源码提取 ----------

# 主参数循环（从 while [[ $# -gt 0 ]] 到其后第一个 done）里 case 分支模式中的 --名字（去掉 =*，排除 --help）。
main_loop() { awk '/^while \[\[ \$# -gt 0 \]\]/ {f=1} f {print} f && /^done/ {exit}' "$1"; }
# 函数体：从 "<名>() {" 到第一个行首的 "}"。
func_body() { awk -v n="$2() {" 'index($0, n) == 1 {f=1} f {print} f && /^}/ {exit}' "$1"; }
# 从一段代码里取 case 分支模式中的长参数。
long_opts() {
  grep -E '^[[:space:]]*[^#[:space:]][^)]*\)' | sed -E 's/\).*//' | tr '|' '\n' \
    | sed -E 's/^[[:space:]]+//; s/=\*$//' | grep -E '^--[a-z][a-z0-9-]*$' | grep -vx -- '--help' || true
}
# 从一段代码里取不以 - 开头的 case 分支词（子命令）。
sub_words() {
  grep -E '^[[:space:]]*[a-z][a-z|-]*\)' | sed -E 's/^[[:space:]]+//; s/\).*//' | tr '|' '\n' \
    | grep -vE '^(-|\*|help$)' || true
}

# ---------- 文档提取 ----------

# 比较标题时拼接部分加括号，避免不同 awk 对“比较与拼接”优先级的差异。
# 取 commands.md 中 "## ownexit <名>" 节下 "### <小节>" 表格首列反引号内的值。
doc_table() {
  local file="$1" section="$2" sub="$3"
  awk -v sec="${section}" -v want="${sub}" '
    /^## / { insec = ($0 == ("## " sec)); next }
    insec && /^### / { insub = ($0 == ("### " want)); next }
    insec && insub && /^#### / { insub = 0 }
    insec && insub && /^\| `/ { s = $0; sub(/^\| `/, "", s); sub(/`.*/, "", s); print s }
  ' "${file}"
}
# 取某个 H4 标题（在指定 H2 节内）下表格首列反引号内的值。
doc_h4() {
  local file="$1" section="$2" h4="$3"
  awk -v sec="${section}" -v h4="${h4}" '
    /^## / { insec = ($0 == ("## " sec)); next }
    insec && /^#{3,4} / { inh4 = ($0 == ("#### " h4)); next }
    insec && inh4 && /^\| `/ { s = $0; sub(/^\| `/, "", s); sub(/`.*/, "", s); print s }
  ' "${file}"
}
# 取 files.md 中某个 H3 标题下表格首列反引号内的值。
doc_h3() {
  local file="$1" h3="$2"
  awk -v h3="${h3}" '
    /^#{2,3} / { in3 = ($0 == ("### " h3)); next }
    in3 && /^\| `/ { s = $0; sub(/^\| `/, "", s); sub(/`.*/, "", s); print s }
  ' "${file}"
}

# ---------- 检查项 ----------

# 1. ownexit 子命令
grep -E '^    "[a-z]+": \(' src/ownexit/cli.py | sed -E 's/^    "([a-z]+)".*/\1/' > "${TMP}/a"
grep -E '^## ownexit [a-z]+$' "${CMDS}" | sed -E 's/^## ownexit //' > "${TMP}/b"
compare "ownexit 子命令" "${TMP}/a" "${TMP}/b"

# 2. 各子命令参数（主参数循环）
for pair in direct:direct/setup_direct.sh connect:direct/connect_to.sh doctor:direct/doctor.sh; do
  name="${pair%%:*}"; file="${pair#*:}"
  main_loop "${file}" | long_opts > "${TMP}/a"
  doc_table "${CMDS}" "ownexit ${name}" 参数 > "${TMP}/b"
  compare "${name} 参数" "${TMP}/a" "${TMP}/b"
done

# 3b. direct 子命令（1.5.0 起的子命令形态：主参数循环里不以 - 开头的分支词）
main_loop direct/setup_direct.sh | sub_words > "${TMP}/a"
doc_table "${CMDS}" "ownexit direct" 子命令 > "${TMP}/b"
compare "direct 子命令" "${TMP}/a" "${TMP}/b"

# 4. multi 参数与子命令（parse_args 函数体）
func_body chain/multi_chain_client.sh parse_args | long_opts > "${TMP}/a"
doc_table "${CMDS}" "ownexit multi" 参数 > "${TMP}/b"
compare "multi 参数" "${TMP}/a" "${TMP}/b"
func_body chain/multi_chain_client.sh parse_args | sub_words > "${TMP}/a"
doc_table "${CMDS}" "ownexit multi" 子命令 > "${TMP}/b"
compare "multi 子命令" "${TMP}/a" "${TMP}/b"

# 5. chain 参数（parse_init_args + parse_args，加上 verify 的 --with-fail-closed 字面量）
{
  func_body chain/setup_chain.sh parse_init_args | long_opts
  func_body chain/setup_chain.sh parse_args | long_opts
  func_body chain/setup_chain.sh parse_args | grep -o "'--with-fail-closed'" | tr -d "'"
} > "${TMP}/a"
doc_table "${CMDS}" "ownexit chain" 参数 > "${TMP}/b"
compare "chain 参数" "${TMP}/a" "${TMP}/b"

# 6. chain 子命令（parse_args 里 case "${COMMAND}" 的分支词，加 init）
{
  func_body chain/setup_chain.sh parse_args | awk '/case "\$\{COMMAND\}" in/ {f=1; next} f && /^  esac/ {exit} f' | sub_words
  echo init
  echo up
} > "${TMP}/a"
doc_table "${CMDS}" "ownexit chain" 子命令 > "${TMP}/b"
compare "chain 子命令" "${TMP}/a" "${TMP}/b"
# 6b. 省略 --id 用的子命令词表（is_chain_subcommand）必须与主 case 的分支词一致，否则有的子命令不能省略 --id。
func_body chain/setup_chain.sh parse_args | awk '/case "\$\{COMMAND\}" in/ {f=1; next} f && /^  esac/ {exit} f' | sub_words > "${TMP}/a"
func_body chain/setup_chain.sh is_chain_subcommand | sub_words > "${TMP}/b"
compare "chain 子命令词表（is_chain_subcommand 对照主 case）" "${TMP}/a" "${TMP}/b"

# 7. chain status 取值
# 约束：status 行只在 status_chain() 与 main() 的 status 分支里输出，动态 reason 只来自 probe_state_file() 的
# STATE_PROBE_REASON 赋值。把 status 输出挪到别的函数会让新增取值漏检（已有取值仍受检）；在这两个函数里
# 用 printf 打日志时不要写成 key=value 形式，否则会被当成冻结取值。
{
  func_body chain/setup_chain.sh status_chain | grep -o "printf '[^']*'" || true
  func_body chain/setup_chain.sh main | grep -o "printf 'status=[^']*'" || true
} | grep -oE '(status|health|role|reason|next)=[^ \\%]+' | grep -v '%' > "${TMP}/a"
func_body chain/setup_chain.sh probe_state_file | grep -oE "STATE_PROBE_REASON='[a-z-]+'" \
  | sed -E "s/STATE_PROBE_REASON='(.*)'/reason=\1/" >> "${TMP}/a"
doc_h4 "${CMDS}" "ownexit chain" "status 取值" > "${TMP}/b"
compare "chain status 取值" "${TMP}/a" "${TMP}/b"

# 8. chain 其它命令输出行（printf 字面值的行首键=值或首词）
grep -oE "printf '(rotate|device|rehost|rebaseline|banlist|migrate)=[a-z-]+|printf '(kicked|banned|already-covered|unbanned) " chain/setup_chain.sh \
  | sed -E "s/^printf '//; s/ $//" > "${TMP}/a"
doc_h4 "${CMDS}" "ownexit chain" "其它命令输出" > "${TMP}/b"
compare "chain 其它命令输出" "${TMP}/a" "${TMP}/b"

# 9. connect 的 reason 取值
grep -oE 'die_login [a-z-]+' direct/connect_to.sh | awk '{print $2}' > "${TMP}/a"
doc_h4 "${CMDS}" "ownexit connect" "reason 取值" | sed -E 's/^reason=//' > "${TMP}/b"
compare "connect reason 取值" "${TMP}/a" "${TMP}/b"

# 10. 链配置键（example.env 与 set_config_value 必须先相等）
grep -vE '^[[:space:]]*(#|$)' chain/chain.example.env | cut -d= -f1 > "${TMP}/a"
func_body chain/setup_chain.sh set_config_value | grep -oE '^[[:space:]]+[A-Z][A-Z0-9_]+\)' | tr -d ' )' > "${TMP}/c"
compare "链配置键（example.env 对照 set_config_value）" "${TMP}/a" "${TMP}/c"
doc_h3 "${FILES}" "链配置键" > "${TMP}/b"
compare "链配置键（源码对照文档）" "${TMP}/a" "${TMP}/b"

# 11. 链 state.env 键（参考）
func_body chain/setup_chain.sh state_key_list | awk "/<<'STATE_KEYS'/ {f=1; next} /^STATE_KEYS\$/ {exit} f" | grep -E '^[A-Z0-9_]+$' > "${TMP}/a"
doc_h3 "${FILES}" "链 state.env 键（参考）" > "${TMP}/b"
compare "链 state.env 键" "${TMP}/a" "${TMP}/b"

# 12. 直连 client.env 键
func_body direct/direct_remote.sh render_client_env | grep -o "printf '[^']*'" | grep -oE '[A-Z_]+=' | tr -d '=' > "${TMP}/a"
doc_h3 "${FILES}" "直连 client.env 键" > "${TMP}/b"
compare "直连 client.env 键" "${TMP}/a" "${TMP}/b"

# 13. 订阅文件名
grep -oE '"\$\{RENDER_DIR\}/[a-z.-]+"' direct/setup_direct.sh | sed -E 's/.*\/([a-z.-]+)"/\1/' > "${TMP}/a"
doc_h3 "${FILES}" "订阅文件" > "${TMP}/b"
compare "订阅文件名" "${TMP}/a" "${TMP}/b"

# 14. 参考文档中英两版（docs/feature/feature-bilingual-docs.md §5.1.3）：所有表格行首列反引号值按文件顺序逐行一致。
# 不复用 compare()：它 sort -u 去重，而首列值大量重复（--host、CHAIN_ID …），删掉一行重复值会漏检；这里不排序不去重，
# 行数与行序走样都能抓到。占位符 <…> 两侧统一换成 <>，英文版可以写 <name>、中文版写 <名字>。围栏代码块里的行跳过。
first_cols() {
  awk '/^```/ {inblock = !inblock; next} !inblock && /^\| `/ { s = $0; sub(/^\| `/, "", s); sub(/`.*/, "", s); print s }' "$1" \
    | sed -E 's/<[^>]*>/<>/g'
}
for name in commands files compatibility; do
  first_cols "docs/reference/${name}.md" > "${TMP}/zh"
  first_cols "docs/reference/${name}.en.md" > "${TMP}/en"
  if [[ -s "${TMP}/zh" ]] && diff "${TMP}/zh" "${TMP}/en" > "${TMP}/d"; then
    N_OK=$((N_OK + 1))
    printf '[ok] %s 中英两版表格首列（%s 行）\n' "${name}" "$(awk 'END {print NR}' "${TMP}/zh")"
  else
    N_FAIL=$((N_FAIL + 1))
    printf '[FAIL] %s 中英两版表格首列不一致（< 中文版 / > 英文版）：\n' "${name}"
    sed 's/^/       /' "${TMP}/d"
  fi
done

echo "interface: ok=${N_OK} fail=${N_FAIL}"
[[ "${N_FAIL}" -eq 0 ]]
