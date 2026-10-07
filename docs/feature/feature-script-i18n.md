# v1.7.0：部署脚本输出中英双语

## 1. 背景

- v1.6.0 起向导与 GitHub 文档已中英双语，但向导之后执行的部署脚本——`direct/setup_direct.sh`、`direct/subctl`、`direct/connect_to.sh`、`direct/doctor.sh`、`direct/sync_to_vps.sh`、`direct/target_lib.sh`、服务器端的 `direct/direct_remote.sh`、`chain/setup_chain.sh`、`chain/multi_chain_client.sh`——的 `--help`、进度、报错、“下一步”提示只有中文。粗计含中文的非注释行约 1600 行（`setup_chain.sh` 约 1000 行，其中 `die` 约 700 行）。英文向导里只能提示“部署脚本输出目前是中文”（`src/ownexit/cli.py` `_WIZARD["en"]["scripts_zh"]`），英文文档引用报错时要附中文原文。
- 用户 2026-10-06 拍板：脚本输出语言跟入口一致（`OWNEXIT_LANG=zh|en` 优先，否则系统语言以 zh 开头用中文、其余英文，向导所选语言带给脚本）；范围为全部用户可见输出（含服务器端回传的 `[vps]` 日志），机器可读的冻结输出不变；本版 1.7.0 只做双语，不删任何东西（删废弃写法在随后的 2.0.0）。

## 2. 目标 / 非目标

目标：

1. 上述 9 个脚本的全部用户可见文字（`--help`、进度 `[*]` / `[+]` / `[!]`、`die` 报错、链式 `[chain][…] INFO / WARN / ERROR` 日志、doctor 的检查行与处理办法、“下一步”与交付块、交互提问、服务器端回传给用户看的日志）按语言输出中文或英文。
2. 语言判断与入口完全一致，并在整次运行中固定：父脚本判断一次后导出，子脚本（`setup_chain.sh` 调 `connect_to.sh`、`setup_direct.sh` 转 `subctl` 等）与服务器端脚本沿用同一语言；向导选的语言传给脚本。
3. 文档与向导去掉“脚本输出只有中文”的说明；英文文档引用的报错改为英文原文；加一项 CI 检查防止以后新增未双语化的中文提示。

非目标：

- 不改任何机器可读输出（`status=…`、`reason=…`、`migrate=…`、`reason=bad-password`、doctor 的 `[OK]` / `[WARN]` / `[FAIL]` 前缀与末行格式、`[multi-chain-client]` 冻结行等）、退出码、文件格式与命令行接口。
- 不翻译代码注释、开发者工具（`scripts/*.sh` 的帮助与输出）、测试钩子的提示。
- 不删除任何旧写法（属 2.0.0）。

## 3. 假设与约束

- 语言判断（与 `src/ownexit/cli.py:70` `_lang()` 同一规则）：`OWNEXIT_LANG` 为 `zh` / `en` 时用它；否则取 `LC_ALL`、`LC_MESSAGES`、`LANG` 中第一个非空值，以 `zh` 开头为中文，否则英文。结果写入 `OWNEXIT_UI_LANG` 并 `export OWNEXIT_LANG=<结果>`，保证子脚本不受父脚本后续 `export LC_ALL=C` 影响（`chain/setup_chain.sh:24`、`chain/multi_chain_client.sh:20` 会把 locale 固定为 C，判断必须在这之前完成）。
- 系统语言不是中文的中文用户，从 1.7.0 起看到英文输出（用户已接受）；设 `OWNEXIT_LANG=zh` 可改回。CHANGELOG 与 README 写明。
- 日志、进度、帮助文字不在冻结范围内（`docs/reference/compatibility.md` §4），改变它们是兼容变更。
- bash 3.2 兼容；脚本 `set -euo pipefail` 下行为不变。
- 打包：`pyproject.toml` 的 package-data `"ownexit.direct" = ["*.sh", …]` 会自动带上新文件 `direct/i18n_lib.sh`。

## 4. 涉及模块

| 区域 | 锚点（基线 main b3ad226） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `direct/i18n_lib.sh` | 新文件 | 新增 | 语言判断与 `L` 函数（§5.1.1） |
| `chain/setup_chain.sh` | 24 `export LC_ALL=C` 之前；`usage`（178-300）；全部含中文的 `die` / `log_*` / `echo` / `printf` / `read -p`（约 860 处）；`REMOTE_PREFLIGHT`（1980-2153，带引号，42 行 `fail`）及其两处调用（2163、2173）；`init_setup_host` / `init_prompt_ipv4` 的中文角色名参数（9177-9198）；init 生成配置的注释行（9225）；跨行提示（8721-8723） | 修改 | 第 24 行前 source `../direct/i18n_lib.sh`；usage 改为中英两份；提示改为 `L` 形式；`REMOTE_PREFLIGHT` 按 §5.1.2 远端规则；跨行提示改为单行 `L` |
| `chain/multi_chain_client.sh` | 20 `export LC_ALL=C` 之前；`usage`；全部提示（约 100 处）；写进 clash-snippet.yaml 的注释行（803） | 修改 | 同上 |
| `direct/setup_direct.sh` | 133-135 source 处；`usage`（72-121）；全部提示（约 240 处）；`run_op_to_end` 的 `systemd-run`（500-505 已有 `--setenv` 通道）；交付块 heredoc（1145 起）；`:643` 的 sed 替换串 | 修改 | source 语言工具；usage 与交付块两份；提示改 `L`；`systemd-run` 加 `--setenv=OWNEXIT_UI_LANG=<zh\|en>`；`:643` 改为 `while read` + printf（英文里的 `/` 会破坏 sed） |
| `direct/direct_remote.sh` | `log` 调用与报错（153-899 间约 18 处） | 修改 | 自带最小 `L`，语言取环境变量 `OWNEXIT_UI_LANG`（由 `systemd-run --setenv` 与 probe 调用的命令前缀传入；缺省中文）。`--help`（897 行，打印文件头注释）是内部脚本的维护说明，不改 |
| `direct/subctl`、`direct/doctor.sh`、`direct/target_lib.sh` | source 处、`usage`、全部提示；`subctl` 的 `<<REMOTE` status 块（149-162，不带引号）；`doctor.sh` 的 `SCAN_PROBE`（336-390，带引号）| 修改 | 同上；`target_lib.sh` 被 source，依赖调用方先 source 语言工具；`<<REMOTE` 块里本机展开 `$(L …)`（结果被远端单引号包住，英文不得含 `'`）；`SCAN_PROBE` 见 §5.1.2 远端规则 |
| `direct/connect_to.sh`、`direct/sync_to_vps.sh` | 文件开头（目前没有 `SCRIPT_DIR`，也不 source 任何文件）；`usage`；全部提示 | 修改 | 新增 `SCRIPT_DIR` 推导并 source 语言工具；其余同上 |
| `src/ownexit/cli.py` | `main` 开头（先 `lang = None`）、`os.execve` 前（约 260 行）；`_WIZARD["en"]["scripts_zh"]` | 修改 | 向导结束时把所选语言写进子进程环境 `OWNEXIT_LANG`（不走向导时不设）；删除“脚本输出为中文”的提示 |
| `scripts/check_ui_lang.sh` | 新文件（git 模式 100755） | 新增 | CI 检查：运行时脚本里不得出现未双语化的中文提示；`L` 两个参数的 `%` 与 `${…}` 个数一致（§5.1.3） |
| `.github/workflows/ci.yml` | lint job（Help output 循环 46-48）与 bash32 job | 修改 | lint 与 bash32 都运行 `check_ui_lang.sh`；Help output 循环加入它，并对 7 个入口脚本分别以 `OWNEXIT_LANG=zh` / `en` 跑一次 `--help` |
| `docs/reference/commands.md` / `.en.md` | `commands.md:378`、`commands.en.md:9`、`:380` | 修改 | `OWNEXIT_LANG` 也决定脚本输出语言；去掉“脚本输出为中文”的说明 |
| `README.md:161`、`docs/manual/direct.en.md:7`、`:158-159`、`docs/manual/chain.en.md:9`、`:115-124`、`chain/README.en.md:20`、`:182` | “脚本输出为中文”提示；引用中文报错并附英文释义处 | 修改 | 删除提示；引用改为脚本的英文原文（如 `binary 来源=…` 改为 `binary source=…`） |
| `README.md` / `README.zh-CN.md` | 安装或环境节 | 修改 | 一句说明输出语言规则与 `OWNEXIT_LANG` |
| `CONTRIBUTING.md` | 基本约定 | 修改 | 新增提示必须用 `L "中文" "English"`，CI 检查兜底；英文里有撇号时 `L` 参数用双引号并注意转义 `$`、反引号 |
| `CHANGELOG.md` / `src/ownexit/__init__.py` | | 修改 | 1.7.0 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 语言工具 `direct/i18n_lib.sh`

被 source 时执行一次判断：

```text
OWNEXIT_UI_LANG=zh|en      # 按 §3 规则判断
export OWNEXIT_LANG="${OWNEXIT_UI_LANG}"   # 固定给子进程
L() { [[ "${OWNEXIT_UI_LANG}" == en ]] && printf '%s' "$2" || printf '%s' "$1"; }
```

- `L` 只做选择，不做格式化；两个参数都必须给（CI 检查 §5.1.3）。
- 每次被 source 都按规则重新判断（判断很便宜；不信任环境里残留的 `OWNEXIT_UI_LANG`，保证 `OWNEXIT_LANG` 优先）；`OWNEXIT_LANG` 先去掉空白再匹配，与 `_lang()` 的 strip 一致。大小写不敏感用 `[Zz][Hh]*` 一类模式实现（bash 3.2 没有 `${x,,}`）。
- 链式两个脚本在各自 `export LC_ALL=C` 之前 source 它：`. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../direct/i18n_lib.sh"`（与 `chain/setup_chain.sh` 已有的 `../direct/connect_to.sh` 相对路径同一布局，git clone 与 pip 安装都成立）。

#### 5.1.2 改写规则

- 单行提示：把字面量换成 `"$(L '中文' 'English')"`（原为单引号）或 `"$(L "中文${X}" "English ${X}")"`（原为双引号，保留变量与 `$(…)` 展开）。`printf` 格式串同法替换，两种语言的 `%s` 个数与顺序必须一致。
- 多行文字与帮助：`usage()` 等多行 heredoc 改为两份，`[[ "${OWNEXIT_UI_LANG}" == en ]]` 选英文那份；内容逐行对应。
- 远端脚本（在服务器上执行）：全集为 `setup_chain.sh` 的 `REMOTE_PREFLIGHT`（42 行 `fail`，经 stderr 直接显示给用户）、`doctor.sh` 的 `SCAN_PROBE`（`SCAN_ERROR=` / `SCAN_SKIP=` 两处，本机原样显示）、`subctl` 的 `<<REMOTE` status 块、`direct_remote.sh`（其余 50 个链式远端 heredoc 只有中文注释，不改）。
  - 带引号的 heredoc（`REMOTE_PREFLIGHT`、`SCAN_PROBE`）：脚本里自定义同义的 `L`，语言作为调用时末尾的位置参数传入（`bash -s -- relay "${RELAY_COHOSTS_SINGBOX}" "${OWNEXIT_UI_LANG}"`），缺省中文；中文文字保留在 `L` 的第一个参数里。
  - 不带引号的 `<<REMOTE`：本机展开 `$(L …)`；结果被远端单引号包住，英文不得含 `'`。
  - `direct_remote.sh`：语言取环境变量 `OWNEXIT_UI_LANG`，缺省中文。`run_op_to_end` 的 `systemd-run` 加 `--setenv=OWNEXIT_UI_LANG=<当前语言>`（与已有测试钩子同一通道），probe 调用以命令前缀传入。恢复执行也走 `run_op_to_end`，所以恢复时用的是本次运行的语言；op.args 格式不变。
  - 远端输出里被本机解析的 `KEY=VALUE`、退出码、状态字不改。
- 跨行的中文字符串（`setup_direct.sh:307-309`、`setup_chain.sh:8721-8723`）改写为单行 `L`（用 `\n` 换行或拆成两条输出），不保留跨行写法。
- 生成文件里的注释（`multi_chain_client.sh:803` 写进 clash-snippet.yaml、`setup_chain.sh:9225` 写进链配置）随语言变化：只是注释，不影响解析；已有文件的哈希按已有内容计算，不受影响。
- 链式日志的级别词 `INFO` / `WARN` / `ERROR`（`setup_chain.sh:305`、`:309` 等处的 printf 格式）与 `[chain][<子命令>]` 前缀不翻译：`doctor.sh:597` 靠 grep `ERROR` 取链式最后一条错误。
- 本机代码按文字匹配远端输出的地方（如 `grep` 远端日志里的某句中文）：改写前逐一核对，确保匹配对象是不随语言变化的机器字段；有依赖中文文字的匹配一律改为匹配机器字段，并列入影响分析。
- 冻结输出：check_interface 第 7、8 项提取的 `printf 'status=…'` 等行、`die_login` 的 reason 值、doctor 的 `[OK]` 前缀、`[multi-chain-client]` 冻结行与末行，文字原样保留。
- 用户可见的引用路径：英文输出里提到的手册路径改指英文版（如 `docs/manual/clash-direct-ips.en.md`）。

#### 5.1.3 防回退检查 `scripts/check_ui_lang.sh`

- 扫描 9 个运行时脚本，逐行判断：
  - 中文帮助等多行 heredoc 用固定标记注释 `# i18n:zh-begin` / `# i18n:zh-end` 包住，块内跳过。
  - 其余 heredoc 正文：首个非空白字符是 `#` 的整行（远端脚本的注释）跳过；不去行内 ` #`（帮助正文里的 ` # 说明` 是给用户看的）；其余行与代码行同一规则（中文必须在 `L` 第一个参数里），每行独立判断引号状态，不跨行延续。
  - 代码行：去掉注释（行首 `#`、行内 ` #` 之后）后若含中文，中文必须位于某个 `L` 调用的第一个参数里；`L` 只认前面是行首、空白、`(` 或 `$(` 的写法，排除 `-L` 文件测试。
  - 不允许跨行的 `L` 参数（§5.1.2 已把跨行字符串改成单行）。
- 每个 `L` 调用：第二个参数非空、不含中文，两个参数里 `%`（printf 占位）、`${` 与 `$(` 的个数相等——英文漏传或多传一个值是本次改写最主要的风险。
- 报错列出 `文件:行` 与原因；只用 awk / grep，`LC_ALL=C`，bash 3.2 可跑；头部前置注释与 `-h`。

#### 5.1.4 入口与文档

- `cli.py`：`main` 开头 `lang = None`，向导结束后记下所选语言；`os.execve` 前 `lang` 非空时 `env["OWNEXIT_LANG"] = lang`（不走向导时不设，交给脚本按 §3 判断）；删除 `scripts_zh` 文案与打印。
- 文档：删除 `docs/manual/direct.en.md`、`chain.en.md`、`chain/README.en.md`、`commands.en.md` 里“脚本输出目前是中文”的段落；英文文档里引用中文报错的地方（`direct.en.md` §7 两行、`chain.en.md` §8 七行、`chain/README.en.md` 的 `binary 来源=…` 等）改为脚本英文原文；`README.md:161` 删除 “The scripts' progress messages are currently in Chinese”。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `OWNEXIT_LANG` | 也决定 9 个脚本的输出语言；未设时按系统语言 | 新增用途，取值不变 |
| `OWNEXIT_UI_LANG` | 内部变量（脚本间固定语言），不进参考文档的环境变量表，不冻结 | — |
| 服务器端 `direct_remote.sh` 的运行环境 | 新增 `OWNEXIT_UI_LANG`（经 `systemd-run --setenv` 与命令前缀传入，缺省中文） | 内部，不在冻结范围；op.args 格式不变 |
| 帮助、进度、报错、日志文字 | 随语言变化 | 不冻结（compatibility.md §4） |
| 机器可读输出、退出码 | 不变 | — |

**reference sibling 回补检查**：

- Q1 涉及 reference 章节：`commands.md` / `commands.en.md` §环境变量 `OWNEXIT_LANG` 行与开头说明；`files.md` 不涉及。
- Q2 源码暴露面完整性：不新增命令、参数、输出键、文件；check_interface 现有 23 项不变。
- Q3 是否回补：`OWNEXIT_LANG` 描述同步更新。
- Q4 placeholder：N/A。

## 6. 备选方案与决策

- gettext / 消息目录文件：需要 `gettext` 依赖或自写目录解析，bash 3.2 与 macOS 默认环境不一定有；内联 `L "中文" "English"` 零依赖，中英并排也便于维护时对照修改。
- 每条消息一个编号、集中在一个表里：改动时要在两处跳转，且 1600 条编号难维护；内联更直接。
- 只翻常用输出：用户已选全部。

## 7. 影响分析

- 运行时：每条提示多一次 `$(L …)` 子 shell（只在打印时发生，不在热循环里），耗时可忽略。→ T 系列实测部署耗时与 1.6.0 同量级。
- 语言固定：父脚本导出 `OWNEXIT_LANG` 后，子脚本即使在 `LC_ALL=C` 下也沿用父脚本语言。→ T3。
- 系统语言非中文的现有中文用户：输出变英文。→ CHANGELOG、README 说明；T4。
- 远端：`direct_remote.sh` 每次运行都重新上传本版（`direct/setup_direct.sh:445`）；语言经 `--setenv` 与命令前缀传入，缺省中文；恢复执行时用本次运行的语言。→ T5。
- 链式 `REMOTE_PREFLIGHT` 与 doctor `SCAN_PROBE` 多一个末尾位置参数，缺省中文。→ T8、T9。
- 生成文件注释随语言变化（clash-snippet.yaml、链配置），不影响解析。→ T3、T10。
- `INFO` / `WARN` / `ERROR` 级别词不变，doctor 取链式错误不受影响。→ T4 的 doctor 判据。
- 冻结输出不变：check_interface 23 项、doctor 末行、status 行。→ S1、T 系列判据。
- 本机解析远端文字：改写前核对，改成匹配机器字段。→ T 系列全流程（任何解析失败都会体现为部署失败）。
- 文档：英文文档引用的报错文字须与脚本英文原文一致。→ S3 人工抽查。

## 8. 回归测试

本机 Lima 三台 Ubuntu 22.04 arm64（中转 R、出口 E、直连 D；网络同 v1.5.0：vzNAT + user-v2）。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| T1 | 7 个入口脚本（setup_direct、subctl、connect_to、doctor、sync_to_vps、setup_chain、multi_chain_client）`--help`：`OWNEXIT_LANG=zh`、`=en`、`LANG=en_US.UTF-8`（不设 OWNEXIT_LANG）、`LANG=zh_CN.UTF-8`；`direct_remote.sh` 是内部脚本、`target_lib.sh` 只能被 source，不在此列 | 退出 0；对应语言；英文帮助不含中文字符 |
| T2 | 参数错误类报错（如 `direct up rotate-keys`、`chain --id x status` 无配置、`doctor --local-only --host x`、`multi --chains`）两种语言 | 退出码与 1.6.0 相同；文字为对应语言 |
| T3 | `LANG=en_US.UTF-8` 下 `chain up`（R→E）全流程，含 init 时由 `setup_chain.sh` 调起的 `connect_to.sh` 提示 | 部署成功；输出（含 connect_to 与 `[chain]` 日志）为英文；`status` 行与 1.6.0 格式相同 |
| T4 | `LANG=en_US.UTF-8` 下 `direct up --host D`、`direct status`、`direct rotate-token`、`doctor`；`OWNEXIT_LANG=zh` 下 `direct up`、`direct log` | 成功；语言正确；`[vps]` 服务器端日志也是对应语言；doctor 末行格式不变 |
| T5 | 中文下以 `OWNEXIT_TEST_DIRECT_PAUSE_AT=RESTART` 运行 `direct up --sni www.apple.com`，暂停期间在 D 上 `systemctl kill -s KILL ownexit-direct-op`；然后以 `LANG=en_US.UTF-8`、不带钩子重跑 | 重跑先报 `STATE=in_progress`，恢复期间的 `[vps]` 日志为英文，退出 0 |
| T6 | 链式 `verify`、`rotate-keys`、`migrate-exit --to <同机新地址>`、`rollback` 英文各一次 | 成功；机器可读行（`rotate=done`、`migrate=rehosted` 等）不变 |
| T7 | 向导选 English 后执行（`OWNEXIT_TEST_WIZARD_PRINT` 关闭，伪终端驱动到 `direct up` 的第一行输出） | 子脚本输出为英文；选中文时为中文 |
| T8 | 在 E 上先 `ufw allow OpenSSH` 再 `ufw --force enable`（保持经中转的 SSH 可达），英文跑 `chain preflight` | 预检失败，远端报错（`preflight:` 行）为英文；中文跑一次为中文；关掉 ufw 恢复 |
| T9 | 在 D 上 `direct uninstall` 之后英文跑 `doctor --host D --scan-sni`（触发 SKIP），验完重装 | `SCAN_SKIP` 文字为英文 |
| T10 | 英文跑 `multi --chains main render`、英文 `chain init` 生成配置 | clash-snippet.yaml 与链配置的注释行为英文，严格解析器接受该配置 |
| S1 | `bash -n` / `/bin/bash -n` / shellcheck、`check_interface.sh`（23 项）、`check_i18n.sh`、`check_public.sh`、CI | 通过 |
| S2 | `scripts/check_ui_lang.sh`；负向（验完恢复）：加一行 `die "未翻译"`、加一个第二参数为空的 `L`、第二参数含中文、两参数 `%s` 个数不同、远端 heredoc 里写一行裸中文 `fail '中文'`、跨行 `L`；正向：`[[ -L x ]]`、远端 heredoc 里的 `fail "$(L …)"` 与整行中文注释都不报 | 正常退出 0；负向各退出 1 并指出行号；正向不报 |
| S3 | 人工抽查：英文文档引用的报错与脚本英文原文一致；英文输出里没有残留中文 | 一致 |

## 9. 日志 / 观测点

- 每条提示按语言输出；`[chain][<子命令>]` 前缀与 `INFO` / `WARN` / `ERROR` 级别词、`[*]` / `[+]` / `[!]` 前缀、doctor 前缀不变。
- `check_ui_lang.sh` 失败时列出 `文件:行` 与原因（未双语化 / 第二参数为空或含中文）。
