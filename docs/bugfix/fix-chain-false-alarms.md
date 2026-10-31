# 链式误报三处与 CI 打包检查（v2.3.1）

> **2026-10-30 注记**：已落地（v2.3.1）。Docker 测试床 T1–T10 通过：未 reload 部署 rc=0；2.3.0 部署的旧格式链 b 在 2.3.0 下报 `reason=baseline`、新代码 healthy；改启动参数、多监听端口仍报 baseline；负载下旧启动检查误判 13/200、新检查 0/200；替换 proxyd 后报 `reason=relay-process-stale`，重启后恢复；校验脚本换成 `/usr/bin/sleep` 仍退出 171。T11：PR #27 的 lint / bash32 / package 全部通过，package 日志显示 Python 3.8.18。T12：7 条真实链在 2.3.0 与 2.3.1 下的 `status` 结果相同——1 条 healthy，另 6 条报 `reason=hostkey-probe`；这 6 台中转从本机直连时 ssh 握手中途被本机进程强杀（退出 137），经另一台机器跳转能正常登录，属本机网络环境问题，与本次改动无关。经跳转在全部 7 台中转只读执行 A-1 的 sed 管道，输出均为一行、以 ` }` 结尾、不含 `start_time` 与 `pid=`；原始输出含 `pid=0`、`start_time=[n/a]`。
> 源码位置：采集 `chain/setup_chain.sh:2808-2810`、`:2832`；兼容比对 `baseline_file_matches`（`:5016-5046`）；smoke 等待 `:4551-4571`；178 分支 `:5240-5245`；34 映射 `:5284-5289`；status `:9833-9834`。

本方案修四个互不依赖的小问题，合在一个补丁版里发布：

- A. 中转既有 sing-box 的“零回归基线”误报变化；
- B. 中转 smoke 刚启动就查进程身份，偶发误判失败；
- C. 中转转发进程是系统升级前的旧进程时，只报笼统的 drift；
- D. CI 的 package 任务装不上 Python 3.8。

## 1. 背景

### A. 零回归基线误报

- 中转上已有 sing-box（`RELAY_COHOSTS_SINGBOX=yes`）或同机直连（`=ownexit-direct`）时，部署前会采集一份“既有服务基线”。采集脚本写在 `chain/setup_chain.sh:2679-2833`。之后 deploy 收尾、verify、status、change-port、rollback 等命令都会重新采集一次，再和本机保存的那份逐字节比对：`probe_relay_baseline`，`chain/setup_chain.sh:4992-5008`，比对在 `:5006` 的 `cmp -s`。
- 2026-10-30 在两轮测试床里都遇到过：链 a 第一次部署在最后核验时报“中转既有 sing-box 零回归基线发生变化”（up rc=4），之后部署链 b 正常，重跑 a 也能成功。
- 真实环境里只有链 main（`RELAY_COHOSTS_SINGBOX=ownexit-direct`）有非空基线。它本机保存的 `relay-unit-manifest.txt` 含 `EXECSTART_SHA256=` 行，`relay-listeners.txt` 有 1 行以空格结尾。其余 6 条链都是 `no`，基线文件内容是 `none`。

### B. smoke 启动竞态

- `write_remote_smoke_script` 先在后台启动 `env -i ... "$binary" run -c "$config" &`（`chain/setup_chain.sh:4545`），紧接着在 `:4547` 检查 `readlink -f /proc/$pid/exe == binary`，不相等就 `exit 121`。
- 2026-10-19 部署一条真实链时在真实中转上触发过，诊断输出显示 rc=121，事后看 exe 已经是 sing-box；当时用临时副本加“最多等 2 秒重查”绕了过去。

### C. 转发进程是旧进程时报错笼统

- 中转校验脚本 `write_verify_relay_script`（`chain/setup_chain.sh:5080` 起）在 `:5184` 检查 relay service 的 MainPID 的 exe 是不是 `systemd-socket-proxyd`，不是就 `exit 171`。
- `probe_remote_resources` 把中转侧所有非 0、非 255 的返回一律归成 31（`:5223`）。status 再把它打印成 `status=drifted reason=remote-resource-unit-process-or-listener next=run-verify`（`:9766`），verify / change-port 也只报“远端文件、unit、进程、listener 或 binary 发生 drift”（`:5256`、`:8408`）。
- 2026-10-30 链 main 的现场：校验码是 171，`readlink /proc/<pid>/exe` 是 `/usr/lib/systemd/systemd-socket-proxyd (deleted)`，因为系统升级把这个文件替换了，旧进程还在跑；unit 与监听的哈希都正常。只重启 `ownexit-chain-relay-main.service` 后就通过了。

### D. CI package 任务

- `.github/workflows/ci.yml:70-77` 的 package 任务写的是 `runs-on: ubuntu-latest` + `python-version: "3.8"`。GitHub 的 ubuntu-latest 已经是 26.04，main 最近一次运行（run 41165654709）报 `The version '3.8' with architecture 'x64' was not found for Ubuntu 26.04.`；PR #23–#26 的 package 检查都失败。lint 与 bash32 两个任务正常。
- `pyproject.toml:11` 声明的是 `requires-python = ">=3.8"`。actions/python-versions 的 versions-manifest 里，3.8.18 的 linux x64 构建有 20.04 / 22.04 / 24.04 三个版本（2026-10-31 读取）。

## 2. 目标 / 非目标

目标：

1. 中转既有服务没有变化时，基线比对不再因为 systemd 重载或其它进程的监听而报变化；真实变化（unit 文件、drop-in、命令行、配置、二进制、自身监听、启用 / 运行状态）照样能查出来。已部署链升级后不用做任何操作，status 与之前一致。
2. smoke 不再因为子进程还没完成 exec 就误判失败。
3. 中转转发进程是“已被替换的旧文件”时，status / verify / change-port 等命令明确说出这个原因，并给出重启命令。
4. CI 的 package 任务恢复通过，并且仍然在 Python 3.8 上测。

非目标：

- 不改基线覆盖的范围，也不自动重启或自动 rebaseline。
- 不处理出口机 sing-box（ownexit 自己的 `/opt/ownexit-chain/bin/...`，只有 ownexit 会替换它）、既有 sing-box 本身被替换为新文件这两种情况。
- 不处理不稳定网络下的 SSH 重试（待办第 4 项，另立版本）。
- 不改 lint / bash32 两个 CI 任务。

## 3. 假设与约束

- `systemctl show <unit> -p ExecStart --value` 的每一项格式是 `{ path=… ; argv[]=… ; ignore_errors=… ; start_time=[…] ; stop_time=[…] ; pid=… ; code=… ; status=… }`。已在 systemd 245（Ubuntu 20.04 宿主）和测试床 Ubuntu 22.04（systemd 249）上实测。
- `ss -H` 输出的最后一列（Process）会按当前所有行里最长的那一个补空格。已在测试床的 iproute2-5.15.0 上实测，见 §5.1-A 的复现记录。
- 进程正在运行的可执行文件被替换后，`readlink -f /proc/<pid>/exe` 返回 `<原路径> (deleted)`。已在测试床实测（cp 新文件后 mv 覆盖）。
- 兼容约束见 `docs/reference/compatibility.md:19`：可以给已有输出键新增取值，解析方应把认不出的取值当作“需要人工查看”。

## 4. 涉及模块

| 区域 | 行号锚点（main 0601d9c） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| 基线采集脚本头注释 | `chain/setup_chain.sh:2684-2685` | 修改 | 注释改成新的输出约定 |
| 基线采集：ExecStart 行 | `chain/setup_chain.sh:2806` | 修改 | 只哈希 path 与 argv，键名改为 `EXECSTART_COMMAND_SHA256` |
| 基线采集：监听行 | `chain/setup_chain.sh:2828` | 修改 | sed 末尾去掉首尾空白 |
| 基线比对 | `chain/setup_chain.sh:5005-5007` | 修改 | 改为调用新函数 `baseline_file_matches` |
| 新函数 `baseline_file_matches` | 在 `probe_relay_baseline`（`:4992`）之前追加 | 新增 | 按文件类型做兼容比对 |
| smoke 启动检查 | `chain/setup_chain.sh:4547` | 修改 | 改为最多等 5 秒的循环 |
| 中转校验脚本 | `chain/setup_chain.sh:5183-5184` | 修改 | 先区分“旧文件已被替换”（新退出码 178），再查 171 |
| `probe_remote_resources` | `chain/setup_chain.sh:5223` | 修改 | 中转 178 时 log_warn 并返回 34 |
| status | `chain/setup_chain.sh:9762-9766` | 新增一个 case | `34)` 输出新 reason / next |
| CI | `.github/workflows/ci.yml:72` | 修改 | `runs-on: ubuntu-24.04` |
| 参考文档 | reason 行：`commands.md:220` / `commands.en.md:222` 之后；next 行：`commands.md:233` / `commands.en.md:235` 之后 | 新增 | 新 reason / next 各一行 |
| 版本与更新日志 | `src/ownexit/__init__.py:7`、`CHANGELOG.md` 的 `[Unreleased]` | 修改 | 2.3.1 |

## 5. 方案

### 5.0 根因分析

**A（两处独立原因，测试床都已复现）**

- **原因 1：ExecStart 值带运行时字段**
  - 现象：首次部署收尾报基线变化。
  - 原因：`EXECSTART_SHA256` 哈希的是 `systemctl show -p ExecStart --value` 的整行（`:2806`）。这一行包含 `start_time` 与 `pid`，systemd 执行 daemon-reload 后会把它们清成 `start_time=[n/a] … pid=0`。
  - 触发条件：既有 sing-box 启动后还没经历过 daemon-reload（例如中转机刚重启）。ownexit 部署本身会执行 daemon-reload，所以采集基线时还是 `pid=90`，收尾核验时已经变成 `pid=0`。
  - 复现记录（2026-10-31，测试容器 `oxtb-exp`）：
    - reload 前：`{ path=/usr/local/bin/sing-box ; argv[]=… ; ignore_errors=no ; start_time=[Sat 2026-10-31 04:31:45 UTC] ; stop_time=[n/a] ; pid=90 ; code=(null) ; status=0/0 }`；
    - reload 后：`start_time=[n/a] ; … ; pid=0`；
    - 采集脚本两次输出只有第 6 行 `EXECSTART_SHA256=` 不同。
- **原因 2：监听行尾随空格随其它监听变化**
  - 原因：`ss -H -ltnup` 的最后一列按所有行里最长的进程串补空格。`:2828` 的 sed 把连续空白压成一个空格，但没有去掉行尾的空格。
  - 结果：中转上一旦出现进程串更长的监听，既有 sing-box 那一行末尾就会多一个空格。部署时 ownexit 会临时起 smoke sing-box，后续还会有别的链和别的服务，这一列的宽度都会跟着变。
  - 复现记录：再起一个进程名为 `a-very-long-procname` 的监听，采集脚本第 18 行从 `…users:(("sing-box",))` 变成 `…users:(("sing-box",)) `（多一个行尾空格）。
  - 这也解释了“中转已经做过 daemon-reload，链 a 仍然 rc=4”：原因 1 不成立时，原因 2 依然会触发。
- **错误代码点**：`chain/setup_chain.sh:2806`、`:2828`，比对点在 `:5006`。

**B**

- `cmd &` 返回的 `$!` 是 bash fork 出来的子进程。它要依次 exec `env`、再 exec sing-box，exe 才会变成 sing-box；`:4547` 只读一次，如果此时 exec 还没完成，就会 `exit 121`。
- 复现记录（测试容器，同样的 `env -i … & readlink` 写法，各 200 次）：空闲时误判 3 次；`stress-ng --cpu 8` 负载下误判 37 次。
- 附带问题：误判退出时，cleanup（`:4529-4539`）只在 exe 已经是 sing-box 时才 kill 这个子进程，所以子进程之后完成 exec 的话，会留下一个没人管的 smoke sing-box。

**C**

- `:5184` 把“MainPID 的 exe 是 `<proxyd> (deleted)`”和“exe 是别的程序”合在同一个退出码 171 里；`:5223` 又把所有校验码归成 31，最终只能报笼统的 drift。
- 复现记录：cp 一个新文件再 mv 覆盖正在运行的程序，`readlink -f /proc/<pid>/exe` 返回 `/tmp/fakeproxyd (deleted)`。

**D**

- 见 §1-D：runner 升级到 Ubuntu 26.04 后，setup-python 没有 3.8 的构建。

### 5.0.1 复现步骤

- **A**：
  1. 在测试床中转上安装并启动既有 sing-box，启动后不执行 daemon-reload；
  2. 用 2.3.0 部署一条链，收尾时 rc=4（原因 1：部署中途 `:4447` 的 daemon-reload 把 ExecStart 里的 pid 清成 0，和部署前采集的不同）；
  3. 部署成功后，在中转上起一个进程名超过 `sing-box` 长度的监听，`chain status` 报 `reason=baseline`（原因 2）。
- **B**：在中转上 `stress-ng --cpu <核数×2>` 的负载下反复 `chain verify`；或者直接在中转上用 §5.0 那个 200 次的循环。
- **C**：
  1. 部署一条链；
  2. 先让 relay service 运行起来：在中转上 `systemctl start ownexit-chain-relay-<id>.service`（或经链发一次连接），记下 `systemctl show -p MainPID --value` 的值；
  3. 再替换程序文件：`cp /usr/lib/systemd/systemd-socket-proxyd /tmp/p && mv -f /tmp/p /usr/lib/systemd/systemd-socket-proxyd`；
  4. 确认 `readlink -f /proc/<MainPID>/exe` 以 ` (deleted)` 结尾；
  5. `chain status` 报 `reason=remote-resource-unit-process-or-listener`。
  - 顺序不能反：status 用 `allow_start=yes` 调校验脚本（`:5178-5180`），服务没在运行时会自己拉起一个新进程，新进程的 exe 是新文件，复现不出来。
- **D**：任意 PR 都能复现，package 任务在 setup-python 这一步失败。

### 5.0.2 影响版本

- **A**：引入既有 sing-box 基线以来的所有版本，直到 2.3.0；只影响中转有既有 sing-box 或同机直连的链。
- **B**：引入中转 smoke 以来的所有版本，直到 2.3.0；所有链的 deploy / verify / change-port / migrate-exit 都会受影响。
- **C**：所有版本，直到 2.3.0；只在中转系统升级替换了 systemd-socket-proxyd、且 relay service 没有重启时出现。
- **D**：只影响 CI，2026-10 下旬 GitHub 把 ubuntu-latest 切到 26.04 之后出现，不影响发布产物：PyPI 发布流程用的是 3.12。

### 5.1 实现要点

**A-1 采集（`:2806`）**：把这一行替换成：

```bash
printf 'EXECSTART_COMMAND_SHA256=%s\n' "$(systemctl show "$unit" -p ExecStart --value | sed -E 's/ ; ignore_errors=[^}]*\}/ }/g' | sha256sum | awk '{print $1}')"
```

- 每一项只留下 `{ path=… ; argv[]=… }`。万一将来格式变了、sed 没有匹配上，就退回哈希整行，结果是可能误报，不会漏报。
- 换键名是为了让比对端能从文件内容认出这是新格式还是旧格式（见 A-3）。

**A-2 采集（`:2828`）**：在 sed 表达式末尾加 `; s/^ //; s/ $//`。

**A-3 比对**：新增 `baseline_file_matches <文件名> <当前采集> <本机保存>`，替换 `:5006` 的 `cmp -s`：

- 文件名为 `relay-listeners.txt`：两边各自去掉每行行尾空白后再比（`sed -E 's/[[:space:]]+$//'`）。旧版保存的文件可能带行尾空格，新采集的不带，去掉之后两边一致。
- 文件名为 `relay-unit-manifest.txt`，且本机保存的那份里有 `^EXECSTART_SHA256=` 行（旧格式）：两边都删掉 `^EXECSTART_SHA256=` 与 `^EXECSTART_COMMAND_SHA256=` 两种行之后再比；保存的是新格式时直接 `cmp`。
  - 旧格式少比的只有 ExecStart 这一项。ExecStart 本身的改动仍然能被查出来：改 unit 文件靠 FragmentPath 的元数据哈希（`:2807-2808`），改 drop-in 靠 DropInPaths 的元数据（`:2809`），实际命令行靠 `MAINPID_CMDLINE_SHA256`（`:2804`）。
  - 用户运行 `rebaseline` 之后，保存的就是新格式。
- 其它文件：照旧 `cmp -s`。
- 只用 sed / grep / cmp 和临时文件（放 `${OP_TMP}`），兼容 bash 3.2。

函数前面加注释，写明这是给旧版本保存的基线做兼容，删掉这段会让所有已部署的链报基线变化。

**A-4 采集脚本头注释（`:2684-2685`）**：“yes 时与旧版逐字相同”这句已经不再成立，改成：输出只取决于 systemctl、/proc、ss；ExecStart 只取 path 与 argv，监听行去掉首尾空白；旧版保存的基线由 `baseline_file_matches` 兼容比对。

**B（`:4547`）**：替换为（循环变量叫 `exe_wait`，避免与紧接着的端口等待循环里的 `attempt` 混淆；cmdline 判断写法与 cleanup 一致）：

```bash
exe_ok=0
exe_wait=0
while (( exe_wait < 50 )); do
  if [[ "$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)" == "$binary" ]]; then
    exe_ok=1
    break
  fi
  kill -0 "$pid" 2>/dev/null || exit 121
  sleep 0.1
  exe_wait=$((exe_wait + 1))
done
if [[ "$exe_ok" != 1 ]]; then
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  if [[ "$cmd" == *"$config"* ]]; then
    kill "$pid" 2>/dev/null || true
  fi
  exit 121
fi
```

- 超时时先核对 `/proc/$pid/cmdline` 里含本次的 `$config` 路径（临时目录里唯一的文件名），确认是本次拉起的 smoke 进程再 kill，避免误杀别的进程。这样 env 阶段卡住的进程不会留下；子进程 5 秒都还停在刚 fork 出的 bash 阶段时，cmdline 不含配置路径、不会被 kill，属于可以忽略的极端情况。
- 退出码仍然是 121，本机侧映射不变（`:4590` 的 `|| die 1 "… Reality smoke 失败"`）。
- 其它在后台启动后检查 exe 的地方：`:5525` 的 fail-closed 探测是直接 `"$binary" run &`（只有一次 exec），并且先 `sleep 1` 再判断，不受影响；`:2377`、`:2737`、`:5066`、`:5184`、`:7622` 查的都是 systemd 的 MainPID，也不受影响。

**C-1 中转校验脚本（`:5183-5184`）**：替换为：

```bash
pid="$(systemctl show "$service_name" -p MainPID --value)"
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || exit 171
exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
[[ "$exe" != "$proxyd (deleted)" ]] || exit 178
[[ "$exe" == "$proxyd" ]] || exit 171
```

178 目前没有被占用：`grep -n 'exit 178'` 无结果。

**C-2 `probe_remote_resources`（`:5223`）**：在归成 31 之前加一行：

```bash
if [[ "${rc}" -eq 178 ]]; then
  log_warn "<中英提示>"
  return 34
fi
```

提示内容：中转转发程序 `systemd-socket-proxyd` 已被系统更新替换，正在运行的还是旧进程；在中转上运行 `systemctl restart ownexit-chain-relay-${CHAIN_ID}.service` 后重试；不要用 rebaseline 掩盖。

调用方核对（`grep -n 'probe_remote_resources\|verify_remote_resources'`，除定义外共 12 处调用）：

- `:5229`、`:5254`、`:5327`、`:5418`、`:6154`、`:6324`、`:6343`、`:8406`、`:8857`、`:9269`、`:9313`：都是“非 0 即失败”或者只单独判 33，34 照样走失败分支；提示由 C-2 的 log_warn 打在 stderr 上，原来的 die 文案不变。
- status（`:9756`）：在 `:9765` 之后加一个 case：

```bash
34) printf 'status=drifted role=relay reason=relay-process-stale next=restart-relay-service\n'; return 5 ;;
```

**D（`.github/workflows/ci.yml:72`）**：package 任务的 `runs-on: ubuntu-latest` 改为 `runs-on: ubuntu-24.04`，`python-version: "3.8"` 不变，并在上方加一句注释，说明固定版本的原因。

**版本与文档**：

- `__init__.py` 改为 `2.3.1`；
- CHANGELOG 加 `[2.3.1]`（Fixed / 修复，中英双语；Upgrading 写明不需要任何操作，旧基线照常比对，想换成新格式可运行 `rebaseline`）；
- commands.md 与 commands.en.md 各加两行，见 §5.2。

### 5.2 接口变更

- **新增 status 取值**：`reason=relay-process-stale`、`next=restart-relay-service`，同时输出 `status=drifted role=relay`。属于兼容约束 `docs/reference/compatibility.md:19` 允许的“给已有输出键新增取值”。老的解析方按约定会把它当作需要人工查看。
- **基线文件内容变化**：本机 `baseline/relay-unit-manifest.txt` 新部署或 rebaseline 后写的是 `EXECSTART_COMMAND_SHA256=`，`relay-listeners.txt` 不再带行尾空格。`docs/reference/files.md:44` 把 `baseline/` 列为内部文件，参考文档没有写它们的格式（`grep -rn 'EXECSTART\|relay-listeners\|relay-unit-manifest' docs/` 无结果）。`compatibility.md:48` 要求 2.x 能读 1.x 与 2.x 写下的内部文件：已核 v1.0.0、v1.6.0、v2.0.0 的采集脚本，EXECSTART_SHA256 行与监听 sed 和 2.3.0 相同，所以这些版本写下的基线都走 A-3 的旧格式兼容分支。state.env 的键不变。
- **中转校验脚本退出码 178**：内部退出码，不对外。
- 其它子命令、参数、配置键都没有变化。

**reference sibling 回补检查**（按 §"方案文档章节内容质量要求" §5）：

- Q1 涉及 reference 章节：`docs/reference/commands.md` 与 `commands.en.md` 的链式 status 取值表（`:195-236` / 英文版对应段）。
- Q2 源码暴露面完整性：编码后用 `scripts/check_interface.sh` 核对。它会把源码里 status 输出的 reason / next 取值与参考文档逐个比对，不一致时 CI 失败。
- Q3 本方案是否回补：N/A，新增的暴露面与文档化同步落地。
- Q4 placeholder：N/A。

## 6. 备选方案与决策

- **A 的兼容方式**
  - 备选：给 state 加一个基线格式版本键，按版本选择采集算法。
  - 否决理由：需要新增 state 键（属于接口面），而且旧链要保留会误报的旧算法。现在的做法从文件内容就能认出新旧格式，比对端单点处理即可，不新增 state 键。
- **C 的报告方式**
  - 备选：让 status 自动重启 relay service。
  - 否决理由：status 只在“服务没有 active”时才会自恢复（`:9754-9755` 的注释），这里服务是 active 的，重启属于修改远端；按现有约定交给用户执行。
- **D**
  - 备选：把最低测试版本提到 3.9 以上。
  - 否决理由：和 `requires-python >=3.8` 的承诺不一致。

## 7. 影响分析

- **A 正向**：
  - `probe_collect_relay_baseline` 在部署前（`:5318`）、在 `:3761` 与 rebaseline（`:7485`）采集时都会写入新格式；其他时候采集的结果只用于比对，不落盘。
  - `probe_relay_baseline` 的调用方共 7 处：`verify_relay_baseline`（`:5010`）的 6 处调用点 `:5258`、`:5329`、`:5420`、`:6158`、`:6326`、`:6345`，加上 status 的 `:9733`。全部经过新比对函数，行为一致。
  - 本机 state 记录的基线文件哈希（`:3760-3765` 写入，`:4877-4887` 校验）针对的是本机文件本身，本方案不改已保存的文件，旧链照常通过。
  - rollback 审计目录（`:5896-5986`）复制并校验的也是本机文件，不受影响。
- **A 反向**：
  - 中转上的采集脚本输出变了。真实环境里只有链 main 有非空基线，它保存的是旧格式，走兼容分支。
  - 用 2.3.0 部署、再用 2.3.1 比对：兼容分支负责。
  - 旧格式链在 2.3.1 下运行 rebaseline：noop 判定（`:7501-7511`）拿新采集的哈希和 state 里记的旧哈希比，ExecStart 行的键名变了，哈希一定不同，所以不会输出 `rebaseline=noop`，而是照常归档旧基线到 audit 目录、写入新格式。这是预期行为，T3 覆盖。
  - 用 2.3.1 rebaseline 后又降级回 2.3.0：旧版会因为 `EXECSTART_COMMAND_SHA256` 报基线变化，需要用旧版再 rebaseline 一次。写进 CHANGELOG 的 Upgrading。
- **A 检测能力**：
  - 新格式下，ExecStart 的 path / argv 变化照样能查出来；不再比较的只有启动时间和 pid。原来主进程重启后能被发现，是因为 `MAINPID_CMDLINE_SHA256` 以外的 status 字段（ACTIVE / ENABLED）；单纯一次重启本来也不算 drift。
  - 旧格式下不比较 ExecStart 行，理由见 A-3。
- **B**：
  - 成功路径最多多花 0.1 秒左右，实际 exec 通常在第一次检查之前就完成了。
  - 失败路径（sing-box 起不来）：exec 失败时子进程退出，`kill -0` 失败，立即返回 121，和原来一样快。
  - 只有“进程活着但始终不是 sing-box”这种异常情况，才会等满 5 秒。
- **C**：
  - 只有在原来就会返回 171 的情况里，多分出一种 178；判断成功（exe 等于 proxyd）的路径不变。
  - 12 处调用点的核对见 §5.1 C-2。
  - 新增的 log_warn 打在 stderr，不改变各命令 stdout 上的机器可读行。
- **D**：只影响 package 任务的 runner。24.04 上 Python 3.8 的构建来自 actions/python-versions。
- **运行时**：没有新增进程或网络请求；比对是本机的几次 sed / cmp，可以忽略。

## 8. 回归测试

测试床：Docker（Ubuntu 22.04 镜像 `ownexit-testbed:v231`，包含控制端、中转、出口三台容器）。中转预装既有 sing-box，并起一个 HTTP 回显服务；控制端安装本次源码快照。T3 还需要一台装 2.3.0 的控制端（同一个控制端容器先装 2.3.0）。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| T1 | 中转既有 sing-box 启动后不做 daemon-reload，直接部署链 a | up rc=0；基线文件里有 `EXECSTART_COMMAND_SHA256=`，没有 `EXECSTART_SHA256=` |
| T2 | T1 之后在中转上起一个进程名比 sing-box 长的监听，再跑 status 与 verify | status `health=healthy`，verify rc=0 |
| T3 | 旧格式兼容：2.3.0 在“启动后未 reload”的状态下部署必然 rc=4（§5.0.1 A），所以先 reload 再部署：① 中转 daemon-reload，并保持长进程名监听在跑（进程名取满 15 个字符，部署前用 `ss -H -ltnup` 确认它的 users 串是全场最长的）；② 用 2.3.0 部署链 b（应成功，保存的 ExecStart 是 `pid=0`），确认本机基线 `grep -c '^EXECSTART_SHA256='` 为 1、listeners `grep -c ' $'` ≥1；③ 撤掉长监听，并 `systemctl restart` 既有 sing-box、不 reload，让 ExecStart 里的 pid 与启动时间变成非 0 的新值；④ 2.3.0 跑 status，新代码跑 status 与 verify；⑤ 新代码 rebaseline 后再跑 status | ④ 2.3.0 报 `reason=baseline`，新代码 healthy、verify rc=0；⑤ rebaseline 不输出 `rebaseline=noop`、audit 目录新增一份归档，基线 `grep -c '^EXECSTART_COMMAND_SHA256='` 为 1，status 仍 healthy |
| T4 | 真实变化仍能查出：既有 sing-box 的 unit 文件改 ExecStart 参数（daemon-reload 后重启服务），对链 a（新格式）和链 b 跑 status；链 b 要在 T3 第 ⑤ 步 rebaseline 之前做这一步（旧格式），T4 结束后把 unit 改回 | 链 a、链 b 都报 `reason=baseline` |
| T5 | 真实变化仍能查出：既有 sing-box 改成多监听一个端口并重启 | 报 `reason=baseline` |
| T6 | smoke 竞态：主判据是在中转上用新的启动检查循环 200 次（`stress-ng --cpu 8` 负载下），对照旧检查同条件下的误判数；另在负载下跑 verify 3 次作为端到端补充 | 新检查 200 次误判 0 次（旧检查同条件下误判 >0）；verify 3 次都是 rc=0；中转上没有残留的 smoke 进程与 `/tmp/ownexit-chain-smoke.*` |
| T7 | 旧转发进程：按 §5.0.1 C 的顺序（先起服务、记 MainPID，再替换文件，确认 exe 以 ` (deleted)` 结尾）构造后跑 status 与 verify | status 输出 `status=drifted role=relay reason=relay-process-stale next=restart-relay-service`，stderr 有重启提示；verify 退出 5，也有同样的提示 |
| T8 | T7 之后在中转上 `systemctl restart ownexit-chain-relay-<id>.service` | status healthy，verify rc=0 |
| T9 | 171 分支仍在：在中转上直接运行渲染出的校验脚本，proxyd 参数换成另一个存在的程序路径（如 `/usr/bin/sleep`），其余参数取自 state | 校验脚本退出 171（不是 178） |
| T10 | 本地静态检查：`bash -n`、`scripts/check_interface.sh`、`scripts/check_i18n.sh`、`scripts/check_ui_lang.sh`、CI 同款 shellcheck（若本机可用） | 全部通过 |
| T11 | CI：PR 上 lint / bash32 / package 三个任务 | 全部通过，package 任务日志显示 Python 3.8 |
| T12 | 真实线路只读：升级前用 2.3.0、升级后用 2.3.1，各跑一次 7 条链的 `chain --id <名> status`；另在 main 的中转上只读执行一次 A-1 的 sed 管道，核对输出只剩 `{ path=… ; argv[]=… }` | 2.3.0 下 healthy 的链在 2.3.1 下仍 healthy；2.3.0 下报 baseline 的链如实记录输出；main（旧格式基线、监听带行尾空格）保持 healthy；sed 输出格式符合预期 |

T1、T3、T6 也同时覆盖了 deploy、verify、rollback 主路径；每条用例结束后 rollback，最后核对中转和出口机上没有 ownexit 残留。

## 9. 日志 / 观测点

- 部署收尾与 verify 的报错文案：`中转既有 sing-box 零回归基线发生变化`。T1 / T2 不应再出现，T4 / T5 应该出现。
- status 输出行：`reason=baseline`、`reason=relay-process-stale`。
- C 的 stderr 提示：含 `systemd-socket-proxyd` 和 `systemctl restart ownexit-chain-relay-<id>.service`。
- smoke 失败文案：`Reality smoke 失败`。T6 不应出现。
- 本机基线文件 `~/.local/state/ownexit/chains/<id>/baseline/relay-unit-manifest.txt` 里是哪个键（`grep -c '^EXECSTART_COMMAND_SHA256='`）。
