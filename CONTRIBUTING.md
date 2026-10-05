# 参与贡献

感谢你对 ownexit 的关注！

## 基本约定

- 全部是 bash 脚本，没有构建步骤。链式脚本（`chain/`）必须能被 macOS 自带的 `/bin/bash` 3.2 解析，不要用 bash 4 以上才有的语法（关联数组、`${var,,}`、`mapfile` 等）。
- 每个可执行脚本：头部有“前置:”注释块写明运行环境和依赖；`set -euo pipefail`；`-h` / `--help` 覆盖所有用法；未知参数报错并以非 0 退出。被 `source` 的文件（如 `direct/target_lib.sh`）不加会 `exit` 的 `-h`。
- 变量后面紧跟中文时用花括号定界，例如 `${HOST}：`，否则 `set -u` 下会报 unbound variable。
- 脚本必须幂等：重复运行收敛到同一结果；不覆盖、不删除不属于本项目的文件。
- 事务 / 恢复类函数不能放在 `if`、`||`、`&&`、`!` 的条件位置：那里 `set -e` 会失效，中途失败不会停下。
- `README.md` 同时是 PyPI 项目页的正文，里面的链接一律写完整 URL（`https://github.com/jakoes-wu/ownexit/blob/main/...`）或页内锚点，不写相对路径，否则在 PyPI 上会 404；CI 会检查。`README.zh-CN.md` 和其它文档不受此限。
- 真实 IP、域名、UUID、Reality 参数、节点链接和密码一律不进仓库，也不写进普通日志。示例里的 IP 只用文档专用网段（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`）。

## 提交前自检

```sh
for f in direct/*.sh direct/subctl chain/*.sh scripts/*.sh; do bash -n "$f" || echo "语法错误：$f"; done
for f in chain/*.sh; do /bin/bash -n "$f" || echo "bash 3.2 无法解析：$f"; done   # macOS 上
shellcheck -S warning direct/*.sh direct/subctl chain/*.sh scripts/*.sh
scripts/check_public.sh            # 隐私扫描：非白名单 IPv4、本地黑名单词
```

`scripts/check_public.sh` 会额外读取仓库外的本地黑名单 `~/.config/ownexit-dev/denylist`（每行一个词），用来拦截你自己的服务商名、主机别名等不想公开的字面量。

shellcheck 的告警要修掉；确实是误报的，在出现告警的那一行加 `# shellcheck disable=SCxxxx` 并写明理由，不要在全局关闭规则。

## Pull Request

1. 较大的改动先开 issue 讨论。
2. 说明你在什么环境下实测过（控制端系统、VPS 发行版和版本）。
3. 用户可见的行为变化要同时更新 `README.md`、`README.zh-CN.md`、`docs/manual/` 下的手册和 `CHANGELOG.md`。

## 发布

1. 在功能分支上把 `src/ownexit/__init__.py` 的 `__version__` 改成新版本，并把 `CHANGELOG.md` 的 `[Unreleased]` 内容移到新版本下。
2. 合并到 `main`、CI 通过后，用自己的凭据发布：`gh release create vX.Y.Z --target <合并提交> --notes-file <说明>`。
3. `Publish to PyPI` 工作流随之构建 sdist / wheel 并经 Trusted Publishing 上传；它会核对 wheel 版本等于 tag，没改 `__version__` 就会失败。给已有 tag 补传：`gh workflow run pypi.yml -f tag=vX.Y.Z`。
4. 演示动画与社交预览图：`python3 scripts/make-assets.py`（macOS，需要 Pillow），生成到 `docs/assets/`；社交预览图需要在仓库 Settings → Social preview 手动上传。

