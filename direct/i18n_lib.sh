# shellcheck shell=bash
# i18n_lib.sh —— 脚本输出语言（中文 / 英文）的判断与选择，被各运行时脚本 source（docs/feature/feature-script-i18n.md）。
#
# 前置:
#   - 只能被 source，不能单独运行；不定义会 exit 的 -h。
#   - 必须在调用方 `export LC_ALL=C` 之前 source：判断看的是用户原来的 locale，固定成 C 之后就读不到了
#     （chain/setup_chain.sh、chain/multi_chain_client.sh 都会把 LC_ALL 固定为 C）。
#
# 规则与 src/ownexit/cli.py 的 _lang() 相同：OWNEXIT_LANG 为 zh / en 时用它；否则取 LC_ALL、LC_MESSAGES、LANG
# 中第一个非空值，以 zh 开头为中文，其余英文。判断结果写进 OWNEXIT_UI_LANG，并导出 OWNEXIT_LANG=<结果>，
# 让子脚本（setup_chain.sh 调 connect_to.sh 等）沿用同一语言——子脚本运行时 LC_ALL 往往已被父脚本固定为 C，
# 不导出的话它会误判成英文。

# 每次被 source 都重新判断（很便宜）：不信任环境里残留的 OWNEXIT_UI_LANG，保证 OWNEXIT_LANG 优先。
ownexit_forced="${OWNEXIT_LANG:-}"
ownexit_forced="${ownexit_forced//[[:space:]]/}"   # 与 cli.py _lang() 的 strip 一致
case "${ownexit_forced}" in
  [Zz][Hh]) OWNEXIT_UI_LANG=zh ;;
  [Ee][Nn]) OWNEXIT_UI_LANG=en ;;
  *)
    ownexit_locale="${LC_ALL:-}"
    [[ -n "${ownexit_locale}" ]] || ownexit_locale="${LC_MESSAGES:-}"
    [[ -n "${ownexit_locale}" ]] || ownexit_locale="${LANG:-}"
    case "${ownexit_locale}" in
      [Zz][Hh]*) OWNEXIT_UI_LANG=zh ;;
      *) OWNEXIT_UI_LANG=en ;;
    esac
    unset ownexit_locale
    ;;
esac
unset ownexit_forced
export OWNEXIT_UI_LANG
export OWNEXIT_LANG="${OWNEXIT_UI_LANG}"

# L <中文> <English>：按当前语言原样输出其中一个（不加换行、不做格式化）。
# 用法：die "$(L "找不到 ${x}" "${x} not found")"；printf 格式串同样可以，两种语言的 %s 个数与顺序必须一致。
L() {
  if [[ "${OWNEXIT_UI_LANG}" == en ]]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}
