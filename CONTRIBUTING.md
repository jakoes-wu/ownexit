# Contributing / 参与贡献

[English](#english) | [简体中文](#简体中文)

## English

Thank you for your interest in ownexit!

### Ground rules

- Everything is bash, with no build step. The chain scripts (`chain/`) must parse with macOS's built-in `/bin/bash` 3.2: do not use syntax that needs bash 4 or later (associative arrays, `${var,,}`, `mapfile` and so on).
- Every executable script has a "前置:" (prerequisites) comment block at the top describing its environment and dependencies; uses `set -euo pipefail`; has `-h` / `--help` covering every usage; and rejects unknown arguments with a non-zero exit. Files that are `source`d (such as `direct/target_lib.sh`) do not get an `-h` that would `exit`.
- When a variable is immediately followed by Chinese text, delimit it with braces, for example `${HOST}：`; otherwise `set -u` reports an unbound variable.
- Scripts must be idempotent: repeated runs converge to the same result, and files that do not belong to this project are never overwritten or deleted.
- Transaction / recovery functions must not sit in the condition of `if`, `||`, `&&` or `!`: `set -e` is disabled there, so a failure halfway would not stop them.
- `README.md` is also the body of the PyPI project page, so its links must be full URLs (`https://github.com/jakoes-wu/ownexit/blob/main/...`) or in-page anchors, never relative paths, which 404 on PyPI; CI checks this. `README.zh-CN.md` and the other documents are not restricted.
- Real IPs, domains, UUIDs, Reality parameters, node links and passwords never go into the repository or ordinary logs. Example IPs use only the documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`).
- Documentation is bilingual: user-facing documents come in pairs (`docs/manual/*.md` with `*.en.md`, `docs/reference/*.md` with `*.en.md`, `chain/README.md` and `direct/README.md` with `README.en.md`, `README.zh-CN.md` with `README.md`). When you change one, change the other in the same pull request. The design records in `docs/feature/` are Chinese only.
- Script output is bilingual: every message a user can see is written as `L "中文" "English"` (from `direct/i18n_lib.sh`), multi-line help as two heredocs with the Chinese one between `# i18n:zh-begin` / `# i18n:zh-end`; both texts must have the same `%`, `${` and `$(` placeholders. When the English contains an apostrophe, quote the `L` arguments with double quotes (and escape `$` and backticks) or write `'\''`. Frozen machine-readable output (`key=value` lines) is never translated. `scripts/check_ui_lang.sh` checks this in CI.

### Self-check before committing

```sh
for f in direct/*.sh direct/subctl chain/*.sh scripts/*.sh; do bash -n "$f" || echo "syntax error: $f"; done
for f in chain/*.sh; do /bin/bash -n "$f" || echo "bash 3.2 cannot parse: $f"; done   # on macOS
shellcheck -S warning direct/*.sh direct/subctl chain/*.sh scripts/*.sh
scripts/check_interface.sh         # the frozen interface and the reference docs (both languages) agree
scripts/check_i18n.sh              # Chinese / English document pairs exist and link correctly
scripts/check_ui_lang.sh           # every Chinese message in the scripts has an English twin
scripts/check_public.sh            # privacy scan: non-allow-listed IPv4, local denylist words (git add new files first)
```

`scripts/check_public.sh` also reads a local denylist outside the repository, `~/.config/ownexit-dev/denylist` (one word per line), to block literals you do not want public, such as your own provider names and host aliases.

Fix shellcheck warnings; for a genuine false positive, add `# shellcheck disable=SCxxxx` with a reason on the offending line instead of disabling the rule globally.

### Pull requests

1. Open an issue first for larger changes.
2. Say where you tested (control machine OS, VPS distribution and version).
3. User-visible behaviour changes must also update `README.md`, `README.zh-CN.md`, the guides under `docs/manual/` and `docs/reference/` (both languages), and `CHANGELOG.md`.

### Releasing

1. On the feature branch, set `__version__` in `src/ownexit/__init__.py` to the new version and move the `[Unreleased]` content of `CHANGELOG.md` under the new version.
2. After merging to `main` and CI passing, publish with your own credentials: `gh release create vX.Y.Z --target <merge commit> --notes-file <notes>`.
3. The `Publish to PyPI` workflow then builds the sdist / wheel and uploads them through Trusted Publishing; it checks that the wheel version equals the tag, so it fails if `__version__` was not changed. To upload for an existing tag: `gh workflow run pypi.yml -f tag=vX.Y.Z`.
4. Demo animation and social preview image: `python3 scripts/make-assets.py` (macOS, needs Pillow) writes them to `docs/assets/`; the social preview must be uploaded by hand under Settings → Social preview.

## 简体中文

感谢你对 ownexit 的关注！

### 基本约定

- 全部是 bash 脚本，没有构建步骤。链式脚本（`chain/`）必须能被 macOS 自带的 `/bin/bash` 3.2 解析，不要用 bash 4 以上才有的语法（关联数组、`${var,,}`、`mapfile` 等）。
- 每个可执行脚本：头部有“前置:”注释块写明运行环境和依赖；`set -euo pipefail`；`-h` / `--help` 覆盖所有用法；未知参数报错并以非 0 退出。被 `source` 的文件（如 `direct/target_lib.sh`）不加会 `exit` 的 `-h`。
- 变量后面紧跟中文时用花括号定界，例如 `${HOST}：`，否则 `set -u` 下会报 unbound variable。
- 脚本必须幂等：重复运行收敛到同一结果；不覆盖、不删除不属于本项目的文件。
- 事务 / 恢复类函数不能放在 `if`、`||`、`&&`、`!` 的条件位置：那里 `set -e` 会失效，中途失败不会停下。
- `README.md` 同时是 PyPI 项目页的正文，里面的链接一律写完整 URL（`https://github.com/jakoes-wu/ownexit/blob/main/...`）或页内锚点，不写相对路径，否则在 PyPI 上会 404；CI 会检查。`README.zh-CN.md` 和其它文档不受此限。
- 真实 IP、域名、UUID、Reality 参数、节点链接和密码一律不进仓库，也不写进普通日志。示例里的 IP 只用文档专用网段（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`）。
- 文档中英双语：面向用户的文档成对存在（`docs/manual/*.md` 与 `*.en.md`、`docs/reference/*.md` 与 `*.en.md`、`chain/README.md` 和 `direct/README.md` 与 `README.en.md`、`README.zh-CN.md` 与 `README.md`），改一份就在同一个 PR 里改另一份。`docs/feature/` 下的设计记录只有中文。
- 脚本输出中英双语：用户看得到的提示一律写成 `L "中文" "English"`（来自 `direct/i18n_lib.sh`），多行帮助写成两份 heredoc，中文那份用 `# i18n:zh-begin` / `# i18n:zh-end` 包住；两种语言的 `%`、`${`、`$(` 个数必须一致。英文里有撇号时，`L` 的参数改用双引号（注意转义 `$` 与反引号）或写成 `'\''`。冻结的机器可读输出（`键=值` 行）不翻译。CI 用 `scripts/check_ui_lang.sh` 检查。

### 提交前自检

```sh
for f in direct/*.sh direct/subctl chain/*.sh scripts/*.sh; do bash -n "$f" || echo "语法错误：$f"; done
for f in chain/*.sh; do /bin/bash -n "$f" || echo "bash 3.2 无法解析：$f"; done   # macOS 上
shellcheck -S warning direct/*.sh direct/subctl chain/*.sh scripts/*.sh
scripts/check_interface.sh         # 冻结接口与参考文档（中英两版）一致
scripts/check_i18n.sh              # 中英成对文档存在、互链与链接正确
scripts/check_ui_lang.sh           # 脚本里每条中文提示都有对应英文
scripts/check_public.sh            # 隐私扫描：非白名单 IPv4、本地黑名单词（新文件先 git add）
```

`scripts/check_public.sh` 会额外读取仓库外的本地黑名单 `~/.config/ownexit-dev/denylist`（每行一个词），用来拦截你自己的服务商名、主机别名等不想公开的字面量。

shellcheck 的告警要修掉；确实是误报的，在出现告警的那一行加 `# shellcheck disable=SCxxxx` 并写明理由，不要在全局关闭规则。

### Pull Request

1. 较大的改动先开 issue 讨论。
2. 说明你在什么环境下实测过（控制端系统、VPS 发行版和版本）。
3. 用户可见的行为变化要同时更新 `README.md`、`README.zh-CN.md`、`docs/manual/` 与 `docs/reference/` 下的文档（中英两版）和 `CHANGELOG.md`。

### 发布

1. 在功能分支上把 `src/ownexit/__init__.py` 的 `__version__` 改成新版本，并把 `CHANGELOG.md` 的 `[Unreleased]` 内容移到新版本下。
2. 合并到 `main`、CI 通过后，用自己的凭据发布：`gh release create vX.Y.Z --target <合并提交> --notes-file <说明>`。
3. `Publish to PyPI` 工作流随之构建 sdist / wheel 并经 Trusted Publishing 上传；它会核对 wheel 版本等于 tag，没改 `__version__` 就会失败。给已有 tag 补传：`gh workflow run pypi.yml -f tag=vX.Y.Z`。
4. 演示动画与社交预览图：`python3 scripts/make-assets.py`（macOS，需要 Pillow），生成到 `docs/assets/`；社交预览图需要在仓库 Settings → Social preview 手动上传。
