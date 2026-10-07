# v1.6.0：向导先选语言、GitHub 文档中英双语

## 1. 背景

- 用户 2026-10-06 指出：终端里只敲 `ownexit` 时，向导直接按系统语言给出中文界面，看不到切换英文的办法（截图：标题后直接是“在你这里能直接连上这台 VPS 吗？”）。向导语言目前由 `_lang()`（`src/ownexit/cli.py:70`）按 `OWNEXIT_LANG` → `LC_ALL` → `LC_MESSAGES` → `LANG` 自动决定，界面上没有入口。
- 用户要求：向导改成开头先选语言；本项目受众是全球用户，评估把 GitHub 上的文档改为中英双语。
- 现状：已经双语的只有 `README.md`（英）/ `README.zh-CN.md`（中）与 `docs/manual/vps.en.md` / `vps.md`。其余面向用户的文档只有中文：`docs/manual/direct.md`、`chain.md`、`clash-direct-ips.md`，`docs/reference/commands.md`、`files.md`、`compatibility.md`，`chain/README.md`、`direct/README.md`，`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`，`.github/` 下的 issue / PR 模板，`CHANGELOG.md`。英文 README 第 132 行把直连手册标为“(Chinese)”。
- `docs/reference/commands.md:376` 写 `OWNEXIT_LANG`“只影响入口的帮助文字”，1.4.0 起它也决定向导语言，描述已过时。

## 2. 目标 / 非目标

目标：

1. 向导第一步选语言（中文 / English），之后的提问、报错、“即将运行”都用所选语言；选 English 时提示部署脚本的进度输出目前是中文。
2. 面向用户的 GitHub 文档全部有英文版（清单与做法见 §5.1.2），每页顶部有语言切换链接；英文页之间互相链接英文版。
3. 加检查防止两种语言版本走样：参考文档中英两版表格首列一致（接入 `check_interface.sh`），成对文档必须同时存在且互相链接（新脚本，接入 CI）。

非目标：

- 不做部署脚本（`setup_direct.sh`、`setup_chain.sh` 等）运行时输出与 `--help` 的英文化：几百条提示，单独评估（见 §10）。
- 不翻译 `docs/feature/` 下的设计记录（12 份约 2800 行）：是开发过程档案，翻译会两边走样，英文 README 注明它们只有中文。
- 不改历史 CHANGELOG 条目的语言；不改 `ownexit --help` 的自动选语言逻辑。

## 3. 假设与约束

- 语言问题的回车默认值取 `_lang()` 的自动判断结果，提示里写明默认是哪种（例：`回车 = 中文` / `Enter = English`），所以按回车的用户与 1.5.0 的体验相同，只多按一次回车。设了 `OWNEXIT_LANG=zh|en` 时不问，直接用它（可脚本化、可跳过）。
- 语言问题出现在任何语言确定之前，提示与取消文字中英并列（`已取消 / Cancelled`）。
- 文件命名沿用 `vps.md` / `vps.en.md` 的约定：现有中文文件名不变，英文版加 `.en.md`；README 维持 `README.md`（英）/ `README.zh-CN.md`（中）。GitHub 社区文件（`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`）与 issue / PR 模板 GitHub 只认一个文件名，改为单文件内英文在前、中文在后。
- `README.md` 是 PyPI 项目页正文，新增链接只写完整 URL（CI 的 README links 检查）。
- 只改文档与入口 Python，不改任何 bash 脚本行为，不需要 Lima 虚拟机实测。
- 新增的 `direct/README.en.md`、`chain/README.en.md` 不进 PyPI 包（`pyproject.toml:47-48` 的 package-data 只列 `README.md`，运行时没有代码读包内 README）；`scripts/` 与 `docs/` 本来就不打包。
- 参考文档表格首列里的占位符（`<子命令>`、`<状态目录>`、`<名字>` 等）在英文版写成英文（`<subcommand>`、`<state dir>`、`<name>`）；防走样比较前两侧都把 `<…>` 统一换成 `<>`（§5.1.3）。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main a8cc771） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `src/ownexit/cli.py` `_WIZARD` | 99-133 | 修改 | 两套文案各加 `scripts_zh`（英文版：部署输出为中文的提示；中文版为空） |
| `src/ownexit/cli.py` 新函数 `_choose_lang` | `_ask_port`（154-156）之后 | 新增 | §5.1.1 |
| `src/ownexit/cli.py` `_wizard` | 159-185 | 修改 | 改为接收语言参数 `lang`，不再自己调用 `_lang()` |
| `src/ownexit/cli.py` `main` 向导分支 | 190-210 | 修改 | 先 `_choose_lang()` 再 `_wizard(lang)`；语言确定前的取消用中英并列文字 |
| `docs/manual/direct.md`、`chain.md`、`clash-direct-ips.md` | 顶部 | 修改 + 新增 | 中文版加切换行；新增 `direct.en.md`、`chain.en.md`、`clash-direct-ips.en.md` |
| `docs/reference/commands.md`、`files.md`、`compatibility.md` | 顶部；`commands.md:17`（入口无参数行）、`:376`（`OWNEXIT_LANG`） | 修改 + 新增 | 中文版加切换行；17 行改为“先选语言（`OWNEXIT_LANG` 为 zh / en 时跳过），再问直连还是链式、IP 与 SSH 端口”；376 行改为“决定入口帮助与向导的语言；为 zh / en 时向导不问语言，其它值等同未设”；新增三份 `.en.md` |
| `docs/manual/vps.en.md` | 123、145 | 修改 | 两处指向 `chain.md` / `direct.md` 并注明 in Chinese 的链接改链 `.en.md`，去掉 in Chinese |
| `chain/README.md`、`direct/README.md` | 顶部 | 修改 + 新增 | 加切换行；新增 `README.en.md` |
| `CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md` | 全文；`CONTRIBUTING.md:16-21` 自检命令、`:32` 同步清单 | 修改 | 英文在前、中文在后（CODE_OF_CONDUCT 英文段用 Contributor Covenant 官方英文原文）；CONTRIBUTING 同步清单加“对应 `.en.md` 与 docs/reference 中英两版”，自检命令加 `scripts/check_interface.sh`、`scripts/check_i18n.sh` |
| `.github/ISSUE_TEMPLATE/bug_report.md`、`feature_request.md`、`config.yml`、`.github/pull_request_template.md` | 全文；PR 模板第 8 行同步清单 | 修改 | 名称与正文中英并列；PR 模板同步清单同 CONTRIBUTING |
| `README.md` / `README.zh-CN.md` | `README.md` 132、146、157、161 四处带 (Chinese) 的链接；两份 README 里描述向导的一句 | 修改 | 英文 README 四处改链英文版并去掉 (Chinese)；说明 `docs/feature/` 只有中文；向导一句加“先选语言” |
| `CHANGELOG.md` | 头部、新增 1.6.0 | 修改 | 头部说明中英；1.6.0 起小节标题写 `### Added / 新增` 这类双语，条目英文一行在前、中文一行在后 |
| `scripts/check_interface.sh` | 54-57 文件存在性循环；第 13 项之后 | 修改 + 新增 | 存在性循环加入三份 `.en.md`；第 14 项（三对各一次，共 23 项）见 §5.1.3 |
| `scripts/check_i18n.sh` | 新文件 | 新增 | 成对文档存在性 + 顶部互链检查（§5.1.3） |
| `.github/workflows/ci.yml` | lint job 第 27 行 Interface freeze 之后；44-45 Help output 循环；bash32 job 第 82 行之后 | 新增 | lint 加一步 `scripts/check_i18n.sh`；Help output 循环加入新脚本；bash32 job 加 `/bin/bash scripts/check_i18n.sh` |
| `src/ownexit/__init__.py` | | 修改 | 1.6.0 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 向导先选语言（`cli.py`）

```text
ownexit
  1) 中文
  2) English
请选择 / Choose [1/2] (Enter = 中文; set OWNEXIT_LANG=zh|en to skip):
```

- 回车默认值为 `_lang()` 结果（`zh` → 1，`en` → 2），提示行里的默认语言名（`中文` / `English`）随之变化；提示行用半角括号，并说明设 `OWNEXIT_LANG=zh|en` 可跳过这一步。只接受 1 / 2 / 空，其它重问（提示 `1 / 2`）。
- `OWNEXIT_LANG` 为 `zh` / `en` 时不显示这一步；其它值等同未设，照问。
- 之后的标题、问题、报错、`即将运行` / `About to run` 用所选语言；选 English 时在 `About to run …` 之后打印一行：`Note: the setup scripts print their progress in Chinese for now; the commands and results are the same.`
- Ctrl+C / EOF：语言确定前打印 `已取消 / Cancelled`，确定后打印所选语言的取消文字；退出码不变（130 / 1）。
- 测试钩子 `OWNEXIT_TEST_WIZARD_PRINT=1` 行为不变（只打印参数，不执行）。

#### 5.1.2 文档双语

| 文档 | 英文版 | 说明 |
| ---- | ---- | ---- |
| `docs/manual/direct.md` / `chain.md` / `clash-direct-ips.md` | 同目录 `.en.md` | 逐段翻译；命令、代码块、表格结构与中文版一致 |
| `docs/reference/commands.md` / `files.md` / `compatibility.md` | 同目录 `.en.md` | 表格行一一对应，首列反引号值在占位符归一化后逐字相同（第 14 项检查）；中文版仍是 `check_interface.sh` 其它检查项的对照对象 |
| `chain/README.md` / `direct/README.md` | 同目录 `README.en.md` | |
| `CONTRIBUTING.md` / `SECURITY.md` / `CODE_OF_CONDUCT.md` | 同一文件 | 顶部 `English | 中文` 锚点导航，英文段在前 |
| issue / PR 模板、`config.yml` | 同一文件 | 名称写 `Bug report / 问题反馈`，正文小标题中英并列 |
| `CHANGELOG.md` | 同一文件 | 头部说明：1.6.0 起条目中英双语，此前只有中文 |

- 每对文档第一行标题下一行写切换链接：中文版 `[English](<名>.en.md) | **简体中文**`，英文版 `**English** | [简体中文](<名>.md)`（与 `vps.md` 一致）。
- 英文页里指向其它文档的相对链接一律指向 `.en.md`（或 `README.en.md`）；中文页保持指向中文版。
- 英文版用户可见的中文输出（脚本打印的中文提示、日志行）保留原文并在必要处用括号给英文释义，不臆造脚本没有的英文输出。

#### 5.1.3 防走样检查

- `check_interface.sh` 第 14 项：独立实现，不复用 `compare()`（它 `sort -u` 去重，而首列值大量重复，删一行重复值会漏检）。对 `commands`、`files`、`compatibility` 三对文件各比较一次（计 3 项，总数 23）：按文件顺序取所有表格行（围栏代码块外、以 `` | ` `` 开头）第一对反引号之间的值，把 `<…>` 统一替换成 `<>`，两侧逐行 `diff`（不排序不去重，同时抓行数与行序走样），一致记 ok，否则打印差异记 FAIL。
- `scripts/check_i18n.sh`（头部前置注释 + `-h`）：内置成对清单（中文路径 → 英文路径：§5.1.2 表前三行的 8 对，加 `README.zh-CN.md` → `README.md`、`docs/manual/vps.md` → `vps.en.md`），逐对检查：
  1. 两个文件都存在；
  2. 中文版前 5 行含指向英文版的链接、英文版前 5 行含指向中文版的链接，按 `](<文件名>)` 或 `/<文件名>)` 精确匹配（兼容 README.md 的完整 URL 写法），不做裸子串匹配；
  3. 英文版里除切换行外的所有相对链接：目标文件存在，且不是成对清单里的中文版（英文页不得链回中文页）；
  4. 英文版里带 `#锚点` 的链接（含只有锚点的页内链接）：锚点含非 ASCII 字符直接判失败（英文页的目标标题都是英文，中文锚点必是漏改）；ASCII 锚点必须在目标文件里有对应标题（按 GitHub 规则生成：小写，去掉字母、数字、`-`、空格以外的字符，空格换 `-`）。
  相对路径按所在文件的目录解析（含 `..`）；`README.md` 里 `https://github.com/jakoes-wu/ownexit/blob/main/<路径>` 形式的链接当作仓库内路径同样检查第 3、4 条。脚本固定 `export LC_ALL=C`（同 `check_interface.sh:18` 的教训）。
  全部通过退出 0，否则逐条打印并退出 1，参数错误退出 2。只用 grep / awk / sed，bash 3.2 可跑。
- CI lint job 增加一步 `scripts/check_i18n.sh`，Help output 检查纳入它；bash32 job 也跑一次。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit`（无参数、终端里） | 向导第一步先选语言；`OWNEXIT_LANG` 已设时跳过 | 向导文字不冻结；退出码不变 |
| `OWNEXIT_LANG` | 语义扩为“决定入口帮助与向导的语言，已设时向导不问语言” | 只是文档修正与新增用途，取值不变 |
| 文档路径 | 新增 8 个：3 份手册、3 份参考文档的 `.en.md`，2 份 `README.en.md` | 新增；原路径不变 |

**reference sibling 回补检查**：

- Q1 涉及 reference 章节：`commands.md` §环境变量 `OWNEXIT_LANG` 行、§ownexit（入口）无参数行；新增三份 reference 英文版。
- Q2 源码暴露面完整性：本方案不新增命令、参数、输出或文件；`check_interface.sh` 现有 20 项覆盖不变。
- Q3 是否回补：`OWNEXIT_LANG` 描述过时一处本方案修正。
- Q4 placeholder：N/A。

## 6. 备选方案与决策

- 语言用双语并列显示而不是先选：每行翻倍，用户已选定“开头先选语言”。
- 社区文件也拆 `.en.md`：GitHub 的 Community profile、新建 issue 页只链接固定文件名，拆开后英文用户看不到；所以单文件双语。
- 英文版放 `docs/en/` 子目录：与已有 `vps.en.md` 约定不一致，且相对链接要多一层；沿用同目录 `.en.md`。
- 翻译设计记录 `docs/feature/`：开发档案、体量大、改动频繁，不翻（§2）。

## 7. 影响分析

- 向导：多一步语言选择，回车即沿用自动判断；`OWNEXIT_LANG` 设了就跳过。非终端、带参数调用不进向导，不受影响。→ T1-T5。
- 入口其它路径（`--help`、子命令转发）不变。→ T6。
- 文档：新增文件与顶部切换行，不改中文版正文含义；`check_interface.sh` 现有检查只读中文版，不受英文版影响，新增第 14 项要求两版表格首列一致。→ S1、S2。
- CI：lint job 多一步、Help output 多一个脚本。→ S3。
- PyPI 页面：README 改链接与文字；README links 检查约束完整 URL。→ S3。
- 维护成本：今后改文档要同时改两版；CONTRIBUTING 写明，检查脚本兜底结构性走样（不检查译文语义）。

## 8. 回归测试

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| T1 | 伪终端 `LANG=zh_CN.UTF-8`、不设 `OWNEXIT_LANG` 运行向导（`OWNEXIT_TEST_WIZARD_PRINT=1`），语言一步直接回车，选 1、输入 IP、端口回车 | 先出现语言选择且标明回车 = 中文；后续中文；参数 `direct up --host …`，退出 0 |
| T2 | `LANG=en_US.UTF-8`，语言选 2，走链式（中转 / 出口两个 IP） | 回车默认标为 English；后续英文；`About to run` 之后有 Chinese 输出提示；参数 `chain up …` |
| T3 | `LANG=en_US.UTF-8`，语言选 1 | 后续中文、没有 Chinese 输出提示 |
| T4 | `OWNEXIT_LANG=en` | 不出现语言选择，直接英文向导 |
| T5 | 语言一步输入 `3` 再输入 `2`；语言一步按 Ctrl+C；语言一步按 Ctrl+D；选完语言后按 Ctrl+C；选完语言后按 Ctrl+D | 非法重问；语言一步的两种取消打印 `已取消 / Cancelled` 并分别退出 130 / 1；选完语言后的两种取消打印所选语言的取消文字并分别退出 130 / 1 |
| T4b | `OWNEXIT_LANG=fr` | 照常出现语言选择 |
| T6 | `ownexit < /dev/null`、`ownexit --help`、`OWNEXIT_LANG=en ownexit --help` | 不进向导，帮助与 1.5.0 相同 |
| S1 | `scripts/check_interface.sh` | 23 项全过；负向（验完恢复）：删 `commands.en.md` 里一行首列为 `--host` 的表格行 → 第 14 项失败；只把某行占位符 `<name>` 改成 `<foo>` → 仍通过；改掉首列非占位部分 → 失败 |
| S2 | `scripts/check_i18n.sh`；`--help`；负向（验完恢复）：删掉某英文文件的切换行、在英文页加一个指向中文版的链接、把英文页一个锚点改错、把英文页一个锚点改成中文锚点、把 `README.md` 一处完整 URL 改回指向中文手册 | 正常退出 0；五种负向各退出 1 并指出文件与链接 |
| S3 | `bash -n` / `/bin/bash -n` / `shellcheck -S warning`（含新脚本）、`check_public.sh`（先 `git add` 新文件，它只扫已跟踪文件）、README links、CI | 通过 |
| S4 | 人工抽查：每对文档标题、章节数、表格行数、代码块数一致；`vps.en.md` 两处链接已改链英文版 | 一致 |
| S5 | Homebrew：配方更新到 1.6.0 后 `brew install` → `brew test` → `brew audit` → 卸载（先查依赖是否过期） | 通过；brew 版本清单恢复 |

## 9. 日志 / 观测点

- 向导输出：语言选择行、`即将运行：ownexit …` / `About to run: ownexit …`、英文时的 Chinese 输出提示、取消文字。
- `check_interface.sh` 第 14 项、`check_i18n.sh` 的失败输出指明哪对文件、哪一项不一致。

## 10. 开放问题

- 部署脚本运行时输出与 `--help` 的英文化：受众全球时这是英文用户体验的主要缺口（向导之后全是中文）。涉及 `setup_direct.sh`、`setup_chain.sh`、`connect_to.sh`、`doctor.sh`、`subctl`、`multi_chain_client.sh` 的全部提示，需单独评估做法（按 `OWNEXIT_LANG` 切换的消息表）与工作量，本版只在英文向导里如实提示。同类问题：`setup_direct.sh:113,308`、`setup_chain.sh:257,8722` 的帮助与报错指向中文版 `docs/manual/clash-direct-ips.md`，随脚本英文化一并处理。
