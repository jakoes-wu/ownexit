# 参与贡献

感谢你对 ownexit 的关注！

## 基本约定

- 全部是 bash 脚本，没有构建步骤。链式脚本（`chain/`）必须能被 macOS 自带的 `/bin/bash` 3.2 解析，不要用 bash 4 以上才有的语法（关联数组、`${var,,}`、`mapfile` 等）。
- 每个可执行脚本：头部有“前置:”注释块写明运行环境和依赖；`set -euo pipefail`；`-h` / `--help` 覆盖所有用法；未知参数报错并以非 0 退出。被 `source` 的文件（如 `direct/target_lib.sh`）不加会 `exit` 的 `-h`。
- 变量后面紧跟中文时用花括号定界，例如 `${HOST}：`，否则 `set -u` 下会报 unbound variable。
- 脚本必须幂等：重复运行收敛到同一结果；不覆盖、不删除不属于本项目的文件。
- 事务 / 恢复类函数不能放在 `if`、`||`、`&&`、`!` 的条件位置：那里 `set -e` 会失效，中途失败不会停下。
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
