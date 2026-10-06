# 兼容承诺（1.x）

从 1.0.0 起，ownexit 遵循[语义化版本](https://semver.org/lang/zh-CN/)：主版本号.次版本号.修订号。本文件说明 1.x 内承诺什么、不承诺什么，以及升级时要注意的事。被承诺的接口逐项列在 [commands.md](commands.md) 与 [files.md](files.md)。

## 1. 冻结了什么

1.x 内下列接口只做向后兼容的新增，不删除、不改名、不改变已有项的含义：

- 命令：`ownexit` 的子命令，各子命令的参数与子命令名，参数的互斥规则，退出码及其含义。
- 机器可读输出：链式 `status` 行的 `status=` / `health=` / `role=` / `reason=` / `next=` 取值，其它命令的输出行（`rotate=` `device=` `rehost=` `rebaseline=` `banlist=` `migrate=` `kicked` `banned` `already-covered` `unbanned`），`ownexit connect` 失败时的 `reason=` 行，`ownexit multi` 带前缀的 verify / render 行，`ownexit doctor` 的行前缀与末行格式。
- 文件：本机配置 / 状态 / 订阅 / 设备文件的路径、键与格式；服务器上的配置文件、systemd 单元名、订阅路径；节点名与组名。
- 环境变量：`OWNEXIT_SSH_PASSWORD`、XDG 变量的取值规则、`TMPDIR` 的用途。

## 2. 什么算兼容变更（1.x 内可以做）

- 新增子命令、参数、输出行或输出键。
- 给已有输出键新增取值（例如新的 `reason=` / `next=` / `result=`）。解析方应把认不出的取值当作“需要人工查看”，不要当作成功。
- 新增可选的配置键（缺省时行为与之前相同）。
- 渲染出的客户端配置（clash.yaml、sing-box.json 等）在文件名、节点名、组名不变、仍可被对应客户端导入的前提下调整其余字段。
- 修正缺陷、改进日志与帮助文字。

## 3. 什么算不兼容变更（只在 2.0 做，并提供迁移）

- 删除或改名子命令、参数、输出键、配置键、文件或路径。
- 改变已有参数、取值、退出码的含义。
- 让已有部署在升级后无法继续管理（见第 5 节）。

要移除的项先废弃：在至少一个次版本里继续可用，并在输出里提示替代写法，最早在下一个主版本移除。

## 4. 不承诺的内容

以下内容可以在任何版本里改变：

- `--help` 的全文、所有日志与进度文字：链式 stderr 上的 `[chain][<子命令>] INFO / WARN / ERROR …`，直连与 subctl 的 `[*]` / `[+]` / `[!]` 行，doctor 每个检查项的文字，体检与扫描段落的内容。
- 内部脚本：`direct/direct_remote.sh`（服务器端执行的内部脚本）、`direct/sync_to_vps.sh`、`direct/target_lib.sh`，以及各命令投递到服务器的临时脚本、它们的退出码与临时文件。
- 内部文件：链式 `state.env` 的具体键（键表只供参考）、`transaction.env`、`baseline/`、`audit/`、`operation.lock`、`shared.lock`、`active-child.env`、`local-process.env`、各类临时文件；服务器上 `/opt/ownexit-direct/bin/`、`/opt/ownexit-chain/bin/` 的布局，`/var/lib/ownexit-direct/`，出口机上的 `<id>.rotate.*` 辅助文件。
- 以 `OWNEXIT_TEST_` 开头的测试钩子环境变量。
- `ownexit multi` 二维码目录的具体位置（默认在 `${TMPDIR:-/tmp}` 下新建）。

## 5. 升级与降级

- 1.y 必须能读取 1.x 写下的全部持久文件（包括第 4 节的内部文件）并继续管理已有部署：已部署的直连、链、设备在升级后不需要重新部署，订阅地址与客户端不需要重新导入。
- 链式 `state.env` 带 `SCHEMA_VERSION`。1.x 内若要新增 state 键，必须提升 SCHEMA_VERSION，且新版本继续能读旧 schema；旧版本读到新 schema 时按现有逻辑拒绝（降级不保证）。
- sing-box 版本：链式 state 记录了部署时的 sing-box 版本，服务器上的二进制路径也带版本号。1.x 内升级 sing-box 只有在同一版本提供已有部署的原地迁移（不换凭据、不需要 rollback）时才发布；做不到就放到 2.0。
- 升级前先收敛未完成的操作：链式有 `transaction.env`（`status=incomplete`）时先重跑 deploy / rollback；出口机有未清理的辅助文件（`status=drifted reason=exit-op-pending`）时先重跑中断的 rotate-keys / add-device / remove-device。有出口机迁移记录（`status=drifted reason=exit-migration-pending`）时先重跑 migrate-exit 完成（或 `--abort` / `--abandon-cleanup`）。
- 不保证降级。特别是：直连 VPS 加过设备后，不要用 0.7.0 之前的版本操作它（旧版本改参数时只渲染 default，会丢掉设备）。

## 6. 如何守住这些承诺

- `scripts/check_interface.sh`（CI 的 Interface freeze 步骤，lint 与 bash 3.2 两个 job 都运行）自动比对下列清单与本目录的参考文档，不一致时 CI 失败：`ownexit` 子命令；direct / connect / subctl / doctor / multi / chain 的长参数；subctl / multi / chain 的子命令；链式 status 取值与其它命令输出行；connect 的 reason 取值；链配置键（并与配置解析代码对照）；链 state.env 键；直连 client.env 键；订阅文件名。
- 其余承诺（退出码、服务器路径与单元名、nft 表名、节点名与组名、multi 的输出与产物、doctor 的输出格式、conns 输出、环境变量、本机目录规则）由代码评审对照本目录人工核对。
- 改动任何被承诺的接口时，同一个提交里必须更新本目录的参考文档与 CHANGELOG。
