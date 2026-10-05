# v0.3.0：发布到 PyPI 与 README 演示动画

> 2026-10-05 注记：代码已落地并完成本地验证（P1–P6），P7 待维护者在 PyPI 登记 pending publisher 后随 v0.3.0 release 验证。行号以 v0.2.0（`09a6946`）为基线。

## 1. 背景

ownexit 目前只能 `git clone` 后运行。本次增加 PyPI 发布渠道（`pipx install ownexit`），并在 README 顶部放 PyPI 徽章和一段演示动画。

两处现状决定了实现方式：

- 项目全部是 bash 脚本，没有 Python 代码；脚本之间有 3 处直接执行兄弟脚本（`direct/setup_direct.sh:158`、`:403`，`chain/setup_chain.sh:6645`），依赖可执行位，而 wheel 安装不保证保留可执行位。
- 链式脚本把“真实配置不得位于 git 工作区内”作为防泄漏闸门：`init_repo_root()`（`chain/setup_chain.sh:1650-1654`、`chain/multi_chain_client.sh:355-359`）要求脚本所在目录属于某个 git 工作区，否则退出。pip 安装的副本不在任何仓库里，按现状会直接失败。

## 2. 目标 / 非目标

### 目标

1. `pipx install ownexit` 后得到单一命令 `ownexit`，子命令与脚本一一对应，参数原样转发。
2. git clone 用法与防泄漏闸门不变；pip 安装的副本跳过闸门（那里没有仓库可泄漏）。
3. GitHub release 发布时自动构建并经 PyPI Trusted Publishing 上传；README 显示 PyPI 徽章与演示动画。

### 非目标

- 不提供 Homebrew、`curl | sh` 安装器。
- 不把脚本改写成 Python；入口只做转发。
- 不支持 Windows 原生运行。

## 3. 假设与约束

- PyPI 上 `ownexit` 尚无人注册（2026-10-05 查询返回 404）。
- Trusted Publishing 需要维护者在 pypi.org 登记一次“pending publisher”（项目 `ownexit`、仓库 `jakoes-wu/ownexit`、工作流 `pypi.yml`、环境 `pypi`）；未登记时构建照常通过、上传失败，不影响 GitHub release 本身。
- 运行仍需要 `bash`、`ssh` 等依赖，与 git clone 用法相同；Python ≥ 3.8 只用于入口转发。

## 4. 涉及模块

| 区域 | 位置（v0.2.0） | 类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| 打包配置 | `pyproject.toml` | 新增 | setuptools；`ownexit` 包来自 `src/ownexit`，`ownexit.direct` / `ownexit.chain` 两个数据包直接映射仓库根的 `direct/`、`chain/`，不复制脚本 |
| 入口 | `src/ownexit/__init__.py`、`src/ownexit/cli.py` | 新增 | `__version__`；子命令表与 `os.execvp("bash", …)` 转发 |
| 脚本互调 | `direct/setup_direct.sh:158`、`:403`，`chain/setup_chain.sh:6645` | 修改 | 改为 `bash "<脚本>"`，不依赖可执行位 |
| 工作区闸门 | `chain/setup_chain.sh:1650-1654`、`:6701`；`chain/multi_chain_client.sh:355-363` | 修改 | 按安装形态区分（§5.1.2）；`REPO_ROOT` 为空时不做“位于仓库内”判断 |
| 发布工作流 | `.github/workflows/pypi.yml` | 新增 | release 发布时构建 sdist / wheel、`twine check`、核对 wheel 版本等于 tag，经 Trusted Publishing 上传 |
| CI | `.github/workflows/ci.yml` | 修改 | 新增 `package` 任务：构建、安装 wheel、跑 `ownexit --help` 与各子命令 `--help` |
| 演示动画 | `scripts/make-assets.py`、`docs/assets/demo.gif` | 新增 | 回放真实输出逐帧绘制（§5.1.4） |
| 文档 | `README.md`、`README.zh-CN.md`、`CHANGELOG.md`、`CONTRIBUTING.md` | 修改 | PyPI 徽章、动画、安装方式、发布步骤 |

## 5. 方案

### 5.1 实现要点

**5.1.1 子命令**

| 子命令 | 脚本 |
| ---- | ---- |
| `ownexit direct …` | `direct/setup_direct.sh` |
| `ownexit subctl …` | `direct/subctl` |
| `ownexit connect …` | `direct/connect_to.sh` |
| `ownexit chain …` | `chain/setup_chain.sh` |
| `ownexit multi …` | `chain/multi_chain_client.sh` |

`ownexit`、`ownexit -h|--help` 打印子命令表；`ownexit --version` 打印版本；未知子命令退出码 2。子命令之后的参数原样交给脚本（含脚本自己的 `-h`）。

**5.1.2 工作区闸门**

`init_repo_root()` 改为：

- 脚本所在目录的上一级存在 `.git`（文件或目录，即 git clone 或 worktree 用法）：照旧要求 `git` 可用并取得 `REPO_ROOT`，取不到就失败（防泄漏闸门不放松）；
- 不存在 `.git`（pip 安装的副本）：`REPO_ROOT` 置空并跳过。所有“配置位于仓库内”的判断在 `REPO_ROOT` 为空时不执行（`setup_chain.sh:661` 已如此；`:6701` 与 `multi_chain_client.sh:363` 补上非空判断，否则 `"${REPO_ROOT}"/*` 会变成 `/*` 而拒绝一切路径）。

**5.1.3 发布**

版本号唯一来源 `src/ownexit/__init__.py` 的 `__version__`；发布流程：改版本号与 CHANGELOG → 合并 → `gh release create vX.Y.Z` → `pypi.yml` 构建并上传。

**5.1.4 演示动画**

`scripts/make-assets.py` 不连接任何服务器：内置一段取自真实运行的终端会话（`ownexit chain init` 与 `ownexit chain --id main deploy` 的关键输出行，以及部署后的出口 IP 检查），IP 一律替换为文档专用地址（`203.0.113.x`），不含 UUID、密钥、节点链接；按终端样式（深色背景、逐字打出命令、输出逐行出现）绘制 GIF。README 注明“演示中的 IP 是示例”。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| 新命令 `ownexit` | 新增（PyPI 安装时） | git clone 用法不变 |
| 链式脚本工作区闸门 | pip 安装形态下跳过 | git clone 形态行为不变 |
| 脚本互调 | 改为 `bash <脚本>` | 行为不变 |

本方案不涉及 `docs/reference/*`。

## 6. 备选方案与决策

| 备选 | 结论 | 理由 |
| ---- | ---- | ---- |
| 把 `direct/`、`chain/` 搬进 `src/ownexit/` | 否决 | git clone 用法的路径全部变化，README 与手册大面积改写 |
| 每个脚本装成独立命令 | 否决（用户选定单一命令） | 命令名冗长，不利于记忆 |
| 演示动画实时连服务器录制 | 否决 | 生成过程依赖真实服务器且可能泄露信息 |

## 7. 影响分析

- 脚本互调改为 `bash <脚本>`：被调脚本都是 bash 脚本且有 `#!/usr/bin/env bash`，行为相同；`setup_chain.sh` 的 `init` 依赖 `connect_to.sh` 的退出码，`bash` 原样返回子脚本退出码。
- 工作区闸门：git clone 形态仍走原逻辑；pip 形态下配置文件仍须权限 600、非符号链接，只是不再检查“是否在仓库内”。
- 仓库根新增 `pyproject.toml`、`src/`，不影响脚本运行。

## 8. 回归测试

| 编号 | 内容 | 判据 |
| ---- | ---- | ---- |
| P1 | 构建 | `python -m build` 产出 sdist 与 wheel，`twine check --strict` 通过，wheel 内含全部脚本 |
| P2 | 安装后入口 | 在全新虚拟环境安装 wheel，`ownexit --version`、`ownexit --help`、`ownexit direct --help`、`ownexit chain --help`、`ownexit multi --help`、`ownexit subctl --help`、`ownexit connect --help` 退出码 0；未知子命令退出码 2 |
| P3 | pip 形态工作区闸门 | 安装副本对现有链执行 `ownexit chain --id main status`，正常返回 healthy |
| P4 | clone 形态闸门不变 | 仓库内把配置路径指向工作区内文件时仍以退出码 2 拒绝 |
| P5 | 脚本互调 | pip 形态下 `ownexit connect --help`、`ownexit direct` 缺参数时退出码 2（证明转发与互调路径正确） |
| P6 | 静态 | `bash -n`、`shellcheck -S warning`、隐私扫描通过；CI 新增 `package` 任务通过 |
| P7 | 发布 | release 后 `pypi.yml` 成功，`pipx install ownexit` 可装；需维护者先登记 pending publisher |

## 9. 日志 / 观测点

- `ownexit --version` 输出与 tag 一致。
- `pypi.yml` 的 “Check the version” 步骤核对 wheel 文件名中的版本等于 tag。
