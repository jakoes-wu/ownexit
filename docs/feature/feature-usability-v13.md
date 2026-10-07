# v1.3.0：少装东西（自适应订阅地址、pexpect 替代本机 expect）

> **2026-10-06 注记**：已落地于 v1.3.0。§8 在本机 Lima 一台 Ubuntu 22.04 arm64 上实测 T1–T11、R1 共 52 项检查全部通过（环境 P 经装了本分支 wheel 的 venv 入口运行，PATH 为系统命令全集去掉 expect / python3；环境 E / N 同法构造）。实测顺带暴露 v1.2.0 TUN 自检的缺陷：缺 `route` / `ip` 命令时 `iface="$(route_interface …)"` 在 `set -e` 下静默退出 127，与“取不到出接口只警告”相悖；已在 `direct/setup_direct.sh` 与 `chain/setup_chain.sh` 的 `tun_precheck` 改为 `"$(route_interface "${ip}" || true)"`。wheel 自动包含 `subserver.py`，未改 package-data。

## 1. 背景

- 直连部署结束打印 4 条订阅链接（`clash.yaml` / `shadowrocket.txt` / `sing-box.json` / `node.txt`），用户要先知道自己的客户端对应哪一条。VPS 上的订阅服务是 `python3 -m http.server` 静态目录（`direct/setup_direct.sh:909-921`），只能按文件名取，无法按客户端区分。
- 本机第一次配免密靠 `expect` 自动输入密码（`direct/connect_to.sh:184-232`），它是 README 前置条件里唯一要 `brew install` 的非系统自带命令（`README.zh-CN.md:55-67`）；pipx 装 ownexit 时装不上它，用户得单独再装一次。
- 用户 2026-10-06 拍板：认不出的客户端默认返回 base64 节点列表（即 `shadowrocket.txt`）；自适应地址成为部署结束“下一步”里唯一推荐的那一条，4 条老地址仍列在后面、照常可用。

## 2. 目标 / 非目标

目标：

1. 直连订阅新增 `http://<VPS>:<订阅端口>/<TOKEN>/sub`：服务器按请求的 User-Agent 返回 `clash.yaml`、`sing-box.json` 或 `shadowrocket.txt` 的内容；default 与每台设备的 TOKEN 都有；4 个老地址不变。
2. 首次配免密改为优先用 Python 包 `pexpect`（pipx / pip 安装时自动带上），没有 pexpect 再用 `expect`，两者都没有才报错并给两种安装方法；返回码契约与行为（密码只发一次、三种失败原因、超时）不变。
3. README 前置条件去掉 `expect`；部署结束“下一步”只推荐 `/sub` 这一条。

非目标：

- 不改订阅文件的名字、内容、节点名、组名；不改订阅端口与 TOKEN 规则；不加鉴权、不改 HTTP 为 HTTPS。
- 不改链式的任何服务器端文件；链式 `init` / `up` 经 `connect_to.sh` 配免密，自动受益于目标 2，不单独改。
- 不做订阅服务自动关闭（v1.4.0 U11）。

## 3. 假设与约束

- VPS 上有 `python3`（`direct/direct_remote.sh:6` 已是前置；Debian 12 为 3.11、Ubuntu 22.04 为 3.10），新的订阅服务脚本只用标准库 `http.server`，仍以 `nobody` 运行。
- 新脚本随本机渲染目录一起 `scp` 到 VPS（`direct/sync_to_vps.sh:137`），落在 `/opt/ownexit-subscription/subserver.py`；它只响应 `GET` / `HEAD` `/<32 位十六进制 TOKEN>/<clash.yaml|shadowrocket.txt|sing-box.json|node.txt|sub>`，其它路径（含 `/`、`/subserver.py`、`/index.html`、目录）一律 404 空体，不再依赖空 `index.html` 防目录列表（文件保留，不再有作用）。
- User-Agent 判定（小写，按顺序）：含子串 `clash` / `mihomo` / `stash` / `verge` → `clash.yaml`；含子串 `sing-box` / `singbox`，或以 `sfa/` `sfi/` `sfm/` 开头 → `sing-box.json`；其余（含 Shadowrocket、v2rayN、curl、空 UA）→ `shadowrocket.txt`。`Content-Type` 对 `/sub` 与固定文件路径同一张表：`clash.yaml` → `text/yaml; charset=utf-8`，`sing-box.json` → `application/json`，`shadowrocket.txt` / `node.txt` → `text/plain; charset=utf-8`。`/sub` 返回 clash.yaml 时附 `Content-Disposition: attachment; filename="ownexit.yaml"`（目的是让 Clash Verge 用它作订阅名；仓库内不可验证，T2 顺带核头部存在即可）。
- `docs/manual/direct.md:106` 现写“根路径返回空内容”，改为“非白名单路径返回 404”。
- 订阅服务不再把请求行写进 journal（`http.server` 默认会记录含 TOKEN 的路径）；只在启动失败时有日志。
- 已部署的直连在升级 ownexit 后，`/sub` 要等下一次 `ownexit direct`（幂等重跑会重新同步目录并重启订阅服务，`direct/setup_direct.sh:970-979`）才可用；旧地址不受影响。手册写明。
- pexpect 用哪个 Python：`ownexit` 入口把 `OWNEXIT_PYTHON=<入口自己的解释器路径>` 放进环境再 `exec` 脚本（pipx 的 venv 里装着 pexpect）；`connect_to.sh` 先试 `OWNEXIT_PYTHON`，再试 `PATH` 里的 `python3`，都导不进 `pexpect` 才用 `expect`。git clone 用法下没有 venv，用户装 `pip3 install pexpect` 或 `expect` 任一即可。
- pexpect 的 `spawn` 用 `setsid` 起子进程（子进程是会话首进程、pid 等于进程组号），判定失败后 `killpg(TERM)` 再退出，与 expect 版 `kill -TERM -[exp_pid]` 等价，避免 ssh-copy-id 内部 ssh 读到空输入再提交一次密码。
- 测试床：本机 Lima 一台 Ubuntu 22.04 arm64（直连 D，vzNAT 地址，本机到它走物理桥接）；配免密的各失败分支通过改 VM 的 sshd 配置 / 删 authorized_keys / 换端口构造。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main e178100） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `direct/subserver.py` | 新文件 | 新增 | 订阅服务：参数 `--port` `--root`；白名单路径 + UA 自适应 `/sub`；不记请求日志 |
| `pyproject.toml` | `[project]` 无 `dependencies`（`:11` `requires-python` 之后）；`[tool.setuptools.package-data]` `"ownexit.direct"`（`:45`） | 修改 | 加 `dependencies = ["pexpect>=4.8"]`；`direct/` 已声明为包，`.py` 模块按 setuptools 规则本就进 wheel——编码时用 `unzip -l dist/*.whl | grep subserver` 核验，缺才加 package-data |
| `src/ownexit/cli.py` `main` | 100-121（`os.execv` `:121`） | 修改 | 环境加 `OWNEXIT_PYTHON=sys.executable`（已设则不覆盖），改用 `os.execve` |
| `direct/setup_direct.sh` 头注释 | 6（“还需要 expect”）、20（“空 index.html”） | 修改 | 前置改为 pexpect 或 expect；index.html 说明改为“保留但不再承担防目录列表” |
| `direct/setup_direct.sh` 渲染后 | 902-922（空 `index.html` 注释与 unit heredoc） | 修改 | 把 `${SCRIPT_DIR}/subserver.py` 复制进 `${STAGING}/subserver.py`；`ExecStart=/usr/bin/python3 ${SUB_BASE_DIR}/subserver.py --port ${SUB_PORT} --root ${SUB_BASE_DIR}` |
| `direct/setup_direct.sh` 本地校验 | 938-939 `grep -qF "http.server ${SUB_PORT}"` | 修改 | 改为核对 `subserver.py --port ${SUB_PORT}`；有 python3 时编译一次新脚本（不写缓存） |
| `direct/setup_direct.sh` §8 分层验证 | 994 起 `CLASH_URL=…`；1029-1036 根路径检查（现要求 `/` 返回 2xx 空体） | 修改 | 新增 `SUB_URL`；用 4 种 UA 请求 `/sub` 分别 `cmp` 对应文件；**替换** 1029-1036 为 `/`、`/subserver.py`、`/${TOKEN}/` 均须 404（`curl -o /dev/null -w '%{http_code}'`），不再保留“根路径 200 空体”判定 |
| `direct/setup_direct.sh` §9 交付汇总 | “下一步（最常用）”块与“订阅链接”块、设备订阅块 | 修改 | 第 1 条只给 `SUB_URL`；老 4 条移到“按客户端固定格式”段；每台设备加 `sub` 行 |
| `direct/connect_to.sh` 头注释 | 5-6 | 修改 | 前置改为“pexpect（pipx 安装自带）或 expect 任一” |
| `direct/connect_to.sh` `require_expect` | 147-162 | 修改 | 改名 `select_password_backend`：按 §3 顺序选 `pexpect` / `expect`，都没有时 die 并给两种安装方法；打印 `[*] 密码输入方式：pexpect（<python>）` 或 `expect` |
| `direct/connect_to.sh` `run_with_password` | 184-232 | 修改 | 现函数体改名 `run_with_password_expect`；新增 `run_with_password_pexpect`（Python 脚本经 heredoc 交给 `$PYTHON_BIN -`，密码仍经环境变量 `CONNECT_TO_PASS`，返回码 5 / 6 / 7 / 124 / 子命令码同原契约）；`run_with_password` 按后端分派 |
| `direct/connect_to.sh` `install_public_key_with_password` | 252 `require_expect` | 修改 | 改调 `select_password_backend` |
| `direct/doctor.sh` L2 可选命令 | 200-215 | 修改 | `expect` 改为“密码输入后端”：`OWNEXIT_PYTHON` / `python3` 可导入 pexpect 或有 `expect` 任一即 ok，否则 WARN 给两种安装方法 |
| `docs/reference/files.md` | 128-129（服务器 unit / 目录）、132（订阅地址段）、149-157（订阅文件表之后） | 修改 | unit 行改为 `subserver.py`；目录行加 `subserver.py`、“空 index.html”说明改为“保留，防目录列表现由服务脚本自身保证”；订阅地址段加一句 `/<TOKEN>/sub` 自适应说明。**不往订阅文件表加行**（`check_interface.sh:219-222` 把该表与源码写出的文件名比对，`sub` 不是文件） |
| `docs/reference/commands.md` | §环境变量 | 修改 | 加 `OWNEXIT_PYTHON`（入口设置、脚本读取；手工运行脚本时可自己设） |
| `README.md` / `README.zh-CN.md` | 50-70 前置条件；快速上手直连第 2 步表 | 修改 | 必需去掉 `expect`；brew / apt 行去掉 `expect`；加一句“git clone 用法要 `pip3 install pexpect` 或装 `expect`”；导入表首行改为 `/sub` 自适应地址 |
| `docs/manual/direct.md` | 39（expect 前置）、57、63-70 导入、106（“根路径返回空内容”） | 修改 | 同上；106 改为“非白名单路径返回 404”；加“升级后老部署重跑一次 `ownexit direct` 才有 `/sub`” |
| `direct/README.md` | 49-50（index.html 与订阅服务说明） | 修改 | `python3 -m http.server` → `subserver.py`；加 `/sub` 一句 |
| `direct/subctl` `devices` 输出 | 140、145 | 修改 | 每行先给 `…/<TOKEN>/sub`（自适应），括号里保留“及同目录 clash.yaml 等固定格式” |
| `CHANGELOG.md` / `src/ownexit/__init__.py` | | 修改 | 1.3.0 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 `direct/subserver.py`

- 标准库：`argparse`、`http.server`、`re`、`os`。`ThreadingHTTPServer` 绑定 `0.0.0.0:<port>`。
- `do_GET` / `do_HEAD`：路径用正则 `^/([0-9a-f]{32})/(clash\.yaml|shadowrocket\.txt|sing-box\.json|node\.txt|sub)$` 匹配，不匹配 → 404 空体；`sub` 按 §3 的 UA 规则选文件名；文件不存在 → 404；读文件二进制原样返回，`Content-Length` 精确，`Cache-Control: no-store`。文件路径用 `os.path.join(root, token, name)` 且 token / name 已被正则限定，不存在路径穿越。
- `log_message` 覆盖为空：不记请求（`log_error` 内部也走 `log_message`，一并静默；端口被占等启动失败是异常回溯直接到 stderr → journal，不受影响）。
- `--root` 必须是存在的目录，否则退出 2。

#### 5.1.2 直连脚本接入（`direct/setup_direct.sh`）

- 渲染阶段：`cp "${SCRIPT_DIR}/subserver.py" "${STAGING}/subserver.py"`（随后 `sync_to_vps.sh` 整目录 scp，与现有文件同一路径）；有 `python3` 时 `python3 -c "compile(open(f).read(), f, 'exec')"` 编译一次（不写 `__pycache__`）。
- unit：`ExecStart=/usr/bin/python3 ${SUB_BASE_DIR}/subserver.py --port ${SUB_PORT} --root ${SUB_BASE_DIR}`，其余不变（`User=nobody`、`Restart=always`）。安装与重启流程（`:970-979`）不变。
- §8 验证新增（都带 `-m 15`，失败走现有 `fail`）：
  - `curl -A 'clash-verge/2.0' SUB_URL | cmp clash.yaml`；`curl -A 'SFA/1.12 sing-box' … | cmp sing-box.json`；`curl -A 'Shadowrocket/2.2' … | cmp shadowrocket.txt`；`curl -A 'curl/8' … | cmp shadowrocket.txt`。
  - `curl -o /dev/null -w '%{http_code}'` 对 `/`、`/subserver.py`、`/${TOKEN}/` 均须 `404`。
- §9 交付：`SUB_URL="http://${HOST}:${SUB_PORT}/${TOKEN}/sub"`；“下一步（最常用）”第 1 条改为“所有客户端都粘贴这一条：`${SUB_URL}`（Clash Verge / mihomo / Shadowrocket / v2rayN / sing-box 自动得到各自的格式）”；原“订阅链接”块标题改为“按客户端固定格式的地址（一般不需要）”，4 条照旧；设备订阅每台加 `自适应：http://…/<设备 TOKEN>/sub` 作首行。

#### 5.1.3 `connect_to.sh` 的 pexpect 后端

- `select_password_backend`：
  1. `${OWNEXIT_PYTHON:-}` 非空且 `"$OWNEXIT_PYTHON" -c 'import pexpect' >/dev/null 2>&1` → `PASSWORD_BACKEND=pexpect; PYTHON_BIN="$OWNEXIT_PYTHON"`；
  2. 否则 `command -v python3` 且能导入 → 同上用 `python3`；
  3. 否则 `command -v expect` → `PASSWORD_BACKEND=expect`；
  4. 否则 die：“缺少自动输入密码的工具：pipx 安装的 ownexit 自带（重新 `pipx install --force ownexit`）；git clone 用法运行 `pip3 install pexpect`，或安装 expect（macOS `brew install expect`、Debian/Ubuntu `sudo apt install expect`）”。
  - 打印 `[*] 密码输入方式：pexpect（${PYTHON_BIN}）` / `[*] 密码输入方式：expect`。
- `run_with_password_pexpect "$@"`：`export CONNECT_TO_PASS`；`"$PYTHON_BIN" - "$@" <<'PY' … PY`，脚本：

  ```text
  child = pexpect.spawn(sys.argv[1], sys.argv[2:], timeout=30, encoding='utf-8', codec_errors='replace'); child.logfile_read = sys.stdout
  sent = False
  patterns = [continue-connecting, password:, permission denied, 连不上类, 被断开类, TIMEOUT, EOF]（与 expect 版同一组正则，均不区分大小写）
  循环 child.expect(patterns)：
    continue-connecting → sendline('yes')
    password: → sent 时 bail(5)；否则 sendline(密码)，sent=True
    permission denied → sent 时 bail(5) 否则 bail(6)
    连不上 → bail(7)
    被断开 → sent 时 bail(5) 否则 bail(7)
    TIMEOUT → bail(124)
    EOF → child.close(); exit(child.exitstatus if not None else 128 + child.signalstatus)
  bail(code)：os.killpg(child.pid, SIGTERM)（忽略异常）；exit(code)
  ```

  `child.logfile_read = sys.stdout`：把子进程输出原样回显到终端，与 Tcl expect 默认 `log_user 1` 一致（用户仍能看到 ssh-copy-id 的提示与 `Number of key(s) added`；密码由 ssh 关回显，不会出现在输出里）。`sys.argv[0]` 是 `-`，被 spawn 的命令取 `sys.argv[1]`、参数取 `sys.argv[2:]`。密码只从环境变量读，脚本正文与 argv 中不出现密码；脚本结束后 `unset CONNECT_TO_PASS`（同原逻辑）。
- `run_with_password`：`case "${PASSWORD_BACKEND}" in pexpect) run_with_password_pexpect "$@" ;; *) run_with_password_expect "$@" ;; esac`。调用方（`push_public_key_once`、`expect_fix_pubkey_auth`）不改。

#### 5.1.4 入口与打包

- `cli.py`：`env = dict(os.environ); env.setdefault("OWNEXIT_PYTHON", sys.executable); os.execve(bash, [bash, script] + args[1:], env)`。
- `pyproject.toml`：`dependencies = ["pexpect>=4.8"]`（pexpect 4.9 支持 Python 3.8+，纯 Python，自带 ptyprocess）；`subserver.py` 是否进 wheel 先 `unzip -l dist/*.whl | grep subserver` 核验（`direct/` 已声明为包，`.py` 按 setuptools 规则应自动进入），缺才给 `"ownexit.direct"` package-data 加 `"*.py"`（与 §4 一致）。
- CI 的 package job（全新 venv 安装 wheel 后跑各子命令 `--help`）会顺带验证依赖可装；另加一步：`python -c "import pexpect"` 与 `python -m py_compile direct/subserver.py`。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| 直连订阅地址 | 新增 `/<TOKEN>/sub`（default 与设备）；按 UA 返回三种格式之一，认不出给 base64 列表 | 新增路径；4 个老地址与文件内容不变 |
| 订阅服务 | `ExecStart` 由 `python3 -m http.server` 改为 `python3 /opt/ownexit-subscription/subserver.py`；只响应白名单路径，其余 404；不记请求日志 | 服务名、端口、目录、文件名不变；`/`（原返回空 index）与任意其它路径由 200 / 403 变 404——不在冻结面内 |
| 服务器文件 | `/opt/ownexit-subscription/subserver.py` 新增 | 新增 |
| `ownexit connect` / 首次配免密 | 优先 pexpect，其次 expect；退出码与 `reason=` 取值不变 | 行为等价；本机前置条件放宽 |
| 环境变量 | 新增 `OWNEXIT_PYTHON`（入口自动设置；手工跑脚本可自设） | 新增 |
| Python 包 | 新增运行时依赖 `pexpect` | pip / pipx 自动安装 |

**reference sibling 回补检查**：
- Q1 涉及 reference 章节：`docs/reference/files.md` §直连（服务器）unit / 目录行、§订阅文件；`docs/reference/commands.md` §环境变量。
- Q2 源码暴露面完整性：订阅文件名由 `scripts/check_interface.sh` 第 13 项（`:219-222`）比对源码写出的文件名与 files.md 订阅文件表——`sub` 不是文件，不进表、不进比对，写在订阅地址段落。`check_interface.sh` 不比对环境变量，人工核。
- Q3 本方案是否回补：是，同步落地。
- Q4 placeholder：N/A。

## 6. 备选方案与决策

- 用 nginx / caddy 做 UA 分流：要在 VPS 装软件、改配置模板，违背“服务器只需 python3”的前置；否决。
- 自适应地址放在根 `/<TOKEN>`（无 `sub` 后缀）：与现有“TOKEN 目录”语义混淆；用显式 `sub`。
- 去掉 expect 路径只留 pexpect：git clone 用法的用户没有 venv，要多装一个 pip 包；保留 expect 作后备。
- 用 `sshpass` 替代：仍是额外系统包，且不能区分“密码错 / 关了密码登录 / 连不上”三种原因；否决。

## 7. 影响分析

- 订阅服务换实现：`subctl start/stop/status` 只操作 unit 名，不受影响（`direct/subctl:15`）；doctor D4 读 `systemctl is-active`，不受影响；`--uninstall` 删除整个 `/opt/ownexit-subscription`（`direct_remote.sh:798`），新文件一并删除。→ T1、T5、R1。
- 老部署升级后未重跑 `ownexit direct`：服务器仍是 `http.server`，`/sub` 404、老地址照常；重跑一次即切换（unit 内容变了，现有流程 `install` + `daemon-reload` + `restart`）。→ T4。
- 请求日志不再写 journal：以前 `journalctl -u ownexit-subscription` 能看到谁拉过订阅（含 TOKEN），现在看不到；安全上是改进（TOKEN 不落日志），排障少一个信号，手册“常见问题”注明。
- 根路径由 200 变 404：没有已知消费方；订阅客户端只访问带 TOKEN 的地址。
- `connect_to.sh` 后端切换：返回码契约不变；三个调用方（`setup_direct.sh:248-259`、`chain/setup_chain.sh` `migrate_setup_new_host` `:7851-7852`、`init_setup_host` `:8932-8933`）只透传退出码 3 与 stderr 末行 `reason=`，不解析，不动。pexpect 版正则与 expect 版逐条对应；`setsid` 行为由 pexpect 默认保证。→ T6–T9。
- `OWNEXIT_PYTHON` 经 `execve` 传给脚本，再经 `bash` 子进程传给 `connect_to.sh`；`setup_chain.sh` 调 `connect_to.sh` 时环境继承。手工 `bash direct/setup_direct.sh` 运行时该变量为空 → 走 `python3` 或 `expect`。
- 新增 pip 依赖：pipx 安装体积 +~1 MB；无网络环境下 `pip install` 需同时拿到 pexpect 与 ptyprocess（CHANGELOG 注明）。
- 运行时：订阅服务改为线程池 HTTP 服务，内存与 `http.server` 同量级；UA 判定是字符串包含，无额外开销。

## 8. 回归测试

本机 Lima 一台 Ubuntu 22.04 arm64（直连 D，vzNAT 地址）。本机测试环境（本机 `PATH` 上的 `python3` 已装 pexpect，`/usr/bin/python3` 没有，`expect` 在 `/usr/bin`）：

- 环境 P（pexpect）：先从本分支 `python -m build` 并 `pipx install --force dist/*.whl`，不设 `OWNEXIT_PYTHON`，由 `ownexit` 入口自动带入自己的解释器（验证“pipx 装的 ownexit 自带 pexpect”这条主张）；`PATH` 用补集法：把 `/usr/bin/*` 与 `/bin/*` 全部软链进临时目录后删掉 `expect`。
- 环境 E（expect）：补集目录保留 `expect`，并把 `python3` 软链指向 `/usr/bin/python3`（无 pexpect）；`env -u OWNEXIT_PYTHON bash direct/setup_direct.sh …` 直接跑脚本（经 `ownexit` 入口无法去掉 `OWNEXIT_PYTHON`）。
- 环境 N（都没有）：环境 E 去掉 `expect` 软链。

测完删除 Lima。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| T1 | 环境 P 下全新 `direct --host D` | 退出 0；输出有“密码输入方式：pexpect”；交付块第 1 条是 `/sub`；§8 新增验证全过 |
| T2 | 本机用 4 种 UA 请求 `/sub` 与 `cmp` 三个文件；`curl -I`（HEAD）`/sub`；`/`、`/subserver.py`、`/<TOKEN>/`、`/<错 TOKEN>/sub` | 分别得到 clash.yaml / sing-box.json / shadowrocket.txt ×2；HEAD 200 且 `Content-Length` 等于文件大小、clash 的响应含 `Content-Disposition`；四个异常路径 404 |
| T3 | `add-device phone` 后请求设备的 `/sub` | 与设备目录的对应文件一致；交付块设备段首行是 `sub` |
| T4 | 升级路径：先把 VM 的 unit 改回 `python3 -m http.server`（模拟老部署）并重启，确认 `/sub` 404；再重跑 `direct --host D` | 重跑后 `/sub` 200，unit 为 subserver.py |
| T5 | `subctl stop` / `start` / `status`；`journalctl -u ownexit-subscription` 在请求后无 TOKEN 字样 | 正常；日志无 TOKEN |
| T6 | 删 VM 的 authorized_keys 与本机密钥后 `direct --host D`，密码正确 | 配免密成功，一次密码 |
| T7 | 同上但 `OWNEXIT_SSH_PASSWORD` 错误 | 退出 3，`reason=bad-password`；VM 上 `journalctl -u ssh --since <开始时刻> | grep -c 'Failed password'` 前后差值为 1 |
| T8 | VM 设 `PasswordAuthentication no` 后同 T6 | `reason=password-disabled` |
| T9 | `--port 2299`（没开） | `reason=unreachable` |
| T10 | 环境 E 下同 T6 | “密码输入方式：expect”，成功 |
| T11 | 环境 N 下同 T6；同环境跑 `bash direct/doctor.sh --local-only` | 退出 1，信息含 `pip3 install pexpect` 与 `brew install expect`；doctor 对密码后端 WARN |
| R1 | `direct --host D --uninstall`；`doctor` 本机段 | 服务器目录清空；doctor 对密码后端 ok |
| R2 | `chain init --relay R --exit D`（可选，pexpect 路径走链式入口） | 退出 0 |
| S1 | `bash -n`、`/bin/bash -n`、`shellcheck -S warning`、`python3 -m py_compile direct/subserver.py`、`check_interface.sh`、`check_public.sh`、CI package job 装 wheel 后 `import pexpect` | 通过 |

## 9. 日志 / 观测点

- `connect_to.sh`：`[*] 密码输入方式：pexpect（<python>）` / `expect`；失败仍是 `reason=bad-password|password-disabled|unreachable`。
- `setup_direct.sh` §8：`[+] 自适应订阅：clash / sing-box / shadowrocket / 未知 UA 四种返回正确`、`[+] 订阅服务非白名单路径返回 404`；失败 `[!] 自适应订阅 <UA> 返回与 <文件> 不一致`。
- 服务器：`systemctl status ownexit-subscription` 的 ExecStart 含 `subserver.py`；`journalctl -u ownexit-subscription` 只有启动 / 失败记录。
