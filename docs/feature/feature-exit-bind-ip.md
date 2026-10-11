# v2.1.0：链式出口机多 IP 出站（`--exit-bind`）

> **2026-10-11 注记**：已落地于 v2.1.0。关键位置（落地后的行号）：`chain/setup_chain.sh` 的 `normalized_config`（`:957`）与 `parse_config`（`:975`）、`write_exit_probe_script`（`:2398`）与 `probe_exit_exit`（`:2440`）、`write_prepare_exit_script`（`:3797`）、`migrate_prepare`（`:8222`）、`init_chain`（`:9382`）；`chain/multi_chain_client.sh` 的 `load_chains`（`:567`）与 `render_auto_group`（`:888`）；`direct/doctor.sh` 的 `IPCHECK_PROBE`（`:378`）。§8 实测：L0 在 macOS 的 bash 3.2 上通过（S1、C1–C4、A1、M1–M5）；L1 在一台 Linux 测试机上用三个带 systemd 的 Ubuntu 22.04 容器实测，P1、D1–D11、C5、R1、R2 全部通过（公网出口仲裁在测试机的网络下偶发失败，无绑定链的部署有两步用了第二次尝试）。与原期望的差异：D3 里 `verify` 发现绑定地址不在网卡上时退出 5 而不是 3——`die` 按子命令改写退出码是既有约定，文档已按此改正；L1 的容器出自同一镜像，要先各自重新生成 SSH 主机密钥，D5 的“另一台机器”才成立。X1（真实出口机的三个公网 IP）尚未完成：控制端所在网络到两台服务器的 SSH 连接偶发在握手前被断开，部署在只读预检阶段反复中止，两台服务器未被改动。

## 1. 背景

- 一台出口机配有多个公网 IPv4 时，现有版本部署多条链只能得到同一个出口 IP：出口机 sing-box 的出站是不绑定地址的 `direct`（`chain/setup_chain.sh:3809`），源地址由系统默认路由决定；`init` 在出口机上执行不带绑定的 `curl ipinfo.io/ip` 登记 `EXPECTED_EXIT_IPV4`（`:9346-9347`）；`verify` 用不带绑定的 `wget` 做出口仲裁（`:2385`）。
- 多链聚合 `multi_chain_client.sh` 要求各链 `EXPECTED_EXIT_IPV4` 相同（`:554-558`），verify 用同一个全局值比对（`:749`），自动组只有 `fallback` / `url-test`（`:366`）。
- 用户 2026-10-11 的需求：一台出口机有 3 个 IPv4，复用同一台中转机部署 3 条链，3 个节点各自从一个 IP 出站；交付形式为每条链一个节点链接，外加一份包含三个节点的 Clash 片段。
- 已在目标出口机（Debian 12、x86_64、sing-box 1.13.14 官方包）实测：`direct` 出站加 `inet4_bind_address` 后，经它出去的连接在 api.ipify.org 与 icanhazip.com 上显示的就是绑定的那个地址（三个地址各测一次，结果各不相同）；绑定到机器上没有的地址时 `sing-box check` 仍然通过，但连接全部失败。

## 2. 目标 / 非目标

目标：

1. `init` / `up` 新增 `--exit-bind <IPv4>`，链配置新增可选键 `EXIT_BIND_IPV4`：该链在出口机上的出站连接从这个本机地址发起，`EXPECTED_EXIT_IPV4` 登记为经它出去时的公网 IP。
2. `preflight` / `deploy` / `verify` 的出口仲裁、`doctor --ip-check` 的出口 IP 体检都按绑定地址执行；绑定地址不在出口机网卡上时明确报错。
3. `multi` 新增 `--mixed-exits` 与 `--group select`：出口 IP 不同的多条链可以一起 verify，并渲染成带手动选择组的 Clash 片段。

非目标：

- 已部署的链原地加上、去掉或更换绑定地址（要换就 rollback 后重新 init / deploy，凭据会重新生成）。
- 带绑定地址的链迁到另一台出口机（新机器上绑定地址不成立，本版拒绝）。同一台出口机换了 SSH 地址、绑定地址还在网卡上时，`migrate-exit` 照常原地切换。
- 绑定地址本身被服务商收回后的自动修复：该链出站失败，只能把地址加回网卡，或 rollback 后重新 init / deploy。
- 命令行向导（只敲 `ownexit` 进入的交互流程）询问绑定地址。
- IPv6 出站绑定、按设备选择出口 IP、链式订阅服务。
- 在出口机上配置附加 IP（由服务商或使用者事先配好）。

## 3. 假设与约束

- `EXIT_BIND_IPV4` 是出口机网卡上已配置的 IPv4 地址，可以是私网地址（云厂商 NAT 场景），所以公网出口 IP 仍以探测结果为准，不假定等于绑定地址。它可以等于 `EXIT_HOST`。
- 缺省（配置里没有这个键）时所有行为与 2.0.0 相同：配置摘要 `CONFIG_SHA256` 的计算结果不变，出口机 `exit.json` 逐字节不变，已部署的链升级后不需要任何操作。
- 不新增 state 键，`SCHEMA_VERSION` 不变：绑定地址只存在于链配置与出口机 `exit.json`，两者已分别由 `CONFIG_SHA256` 与 `EXIT_EXIT_SHA256` 纳入漂移检查。
- 出口机 Reality 入站仍监听 `0.0.0.0`，中转仍连 `EXIT_HOST`；同一台出口机上的多条链各自一个端口、一组单元、一张 nft 表（既有行为，`:2229`、`:2522-2525`）。
- `inet4_bind_address` 只约束 IPv4 连接。出口机 DNS 策略是 `prefer_ipv4`（`:3790`），只有 IPv6 地址的目标仍按既有行为从 IPv6 出去，不受本功能约束。
- 出口机若同时有 IPv6，双栈目标是否改走 IPv6 取决于 sing-box 拨号器，本方案不作断言；本次目标出口机没有全局 IPv6 地址。
- Reality 握手探针 `probe_exit_tls`（`:2366-2368`）与 sing-box 入站向伪装站点发起的握手连接不绑定地址，维持现状。
- 出口仲裁脚本用 GNU wget 的 `--bind-address`；支持的服务器系统只有 Debian / Ubuntu，都是 GNU wget。
- `multi` 的 `select` 组名用新名字 `Exit-Relay-select`，已冻结的 `Exit-Relay-auto` 含义不变。
- 两个脚本都要能在 macOS 自带的 bash 3.2 上运行（CI 的 bash 3.2 job），新增代码不用关联数组、`${var,,}`、`mapfile` 等 bash 4 语法。

## 4. 涉及模块

行号锚点为基线 main `039be01`。

| 区域 | 行号锚点 | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `chain/setup_chain.sh` 全局变量 | 80、104、120 邻近 | 新增 | `INIT_EXIT_BIND=''`、`INIT_EXIT_BIND_GIVEN=0`、`EXIT_BIND_IPV4=''` |
| `chain/setup_chain.sh` `usage` | 183-185、267-268、327-329、397-398 | 修改 | init / up 用法与参数说明加 `--exit-bind`（中英两段） |
| `chain/setup_chain.sh` `parse_init_args` | 728-756 | 修改 | 新分支 `--exit-bind`，值必须过 `is_ipv4` |
| `chain/setup_chain.sh` `set_config_value` | 881-901 | 修改 | 新分支 `EXIT_BIND_IPV4` |
| `chain/setup_chain.sh` `validate_config_values` | 921-941 | 修改 | 非空时必须是 IPv4 字面量 |
| `chain/setup_chain.sh` `normalized_config` | 943-957 | 修改 | 非空时在末尾追加一行 `EXIT_BIND_IPV4=` |
| `chain/setup_chain.sh` `parse_config` | 999 | 修改 | 键数判断改为“13 个必填键齐全，另可有可选键” |
| `chain/setup_chain.sh` `write_exit_probe_script` / `probe_exit_exit` | 2370-2403 | 修改 | 第 2 个参数为绑定地址；先核 `ip` 命令与地址在网卡上，再用 `--bind-address` 仲裁；新远端退出码 23、24 |
| `chain/setup_chain.sh` `write_prepare_exit_script` | 3764-3767、3809 | 修改 | 新增第 12 个参数；非 `-` 时出站带 `inet4_bind_address` |
| `chain/setup_chain.sh` `prepare_exit_exit` | 3898 | 修改 | 调用处追加第 12 个参数并打日志 |
| `chain/setup_chain.sh` `migrate_probe_same_host` / `migrate_rehost_same_host` | 6859、6914 | 修改 | 同机探测的 curl 在有绑定地址时加 `--interface`；取不到出口 IP 时的报错提示绑定地址 |
| `chain/setup_chain.sh` `migrate_prepare` | 8158-8165 | 修改 | 跨机迁移的准备阶段，state 校验通过之后，带绑定地址的链退出 2 |
| `chain/setup_chain.sh` `up_chain` | 8955-8959 | 修改 | 重跑时比对 `--exit-bind` 与已有配置 |
| `chain/setup_chain.sh` `init_chain` | 9345-9353、9367-9376 | 修改 | 给了 `--exit-bind` 时核地址、按绑定地址探测出口 IP、写入配置 |
| `chain/multi_chain_client.sh` 头注释与 `usage` | 2-12、72-176 | 修改 | 说明新参数与新组类型（中英两段） |
| `chain/multi_chain_client.sh` 全局变量 | 38、47-52 邻近 | 新增 | 常量 `SELECT_GROUP_NAME`（`:38` 之后）；`MIXED_EXITS=0`、`GROUP_GIVEN=0`、`TEST_URL_GIVEN=0`、`INTERVAL_GIVEN=0`（`:52` 之后） |
| `chain/multi_chain_client.sh` `parse_args` | 344-395 | 修改 | 新参数 `--mixed-exits`；`--group` 接受 `select`；循环后做组合校验 |
| `chain/multi_chain_client.sh` `load_chains` / `chain_field` | 535-575 | 修改 | 链记录追加第 9 个字段（该链出口 IP）；`--mixed-exits` 时不要求一致 |
| `chain/multi_chain_client.sh` `verify_one` | 749 | 修改 | 用该链自己的出口 IP 比对 |
| `chain/multi_chain_client.sh` `render_auto_group` | 850-859 | 修改 | `select` 时组名 `Exit-Relay-select`，不写 `url` / `interval` |
| `direct/doctor.sh` `IPCHECK_PROBE` 与链式 `--ip-check` 调用处 | 376-378、647-653 | 修改 | 探针接受可选的绑定地址参数；链配置有 `EXIT_BIND_IPV4` 时传入 |
| `chain/chain.example.env` | 文件末尾 | 新增 | 注释形式的可选键 `# EXIT_BIND_IPV4=…` |
| `scripts/check_interface.sh` 第 10 项 | 206 | 修改 | 示例文件的键提取同时接受注释形式的可选键（§5.1.1） |
| `docs/reference/commands.md` / `.en.md` | `## ownexit chain` 参数表（129 之后）、退出码表（168-169）、`migrate-exit` 行（160）；`## ownexit multi` 参数表（271-276）、退出码表（291）、输出表 verify 行（300）；`## ownexit doctor` 的 `--ip-check` 行（317） | 修改 | 见 §5.2；verify 行说明 `--mixed-exits` 时行末多 `exit=<IP>` |
| `docs/reference/files.md` / `.en.md` | `### 链配置键`（46-62）及其后“必须且只能包含这 13 个键”一句（64）、节点名与组名表（185） | 修改 | 新键、新组名；该句改为“13 个必填键，另可有可选键” |
| `docs/reference/compatibility.md` / `.en.md` | §5 | 修改 | 注明带 `EXIT_BIND_IPV4` 的配置不能被 2.1.0 之前的版本读取 |
| `chain/README.md` / `chain/README.en.md` | `## 配置`（66-82，含 68 的“必须且只能包含下面 13 个键”）、`## 出口机换 IP（同一台机器）`（255 起）、`## 出口机换一台机器`（270 起）、`## 多链客户端聚合`（292 起） | 修改 | 新键说明与键数表述、同机换 IP 对绑定地址的要求、跨机迁移限制、新增“一台出口机多个出口 IP”小节 |
| `docs/manual/chain.md` / `.en.md` | §6 之后、§7 | 新增 / 修改 | “出口机有多个 IP”一节；§7 补带绑定地址的链的迁移限制 |
| `CHANGELOG.md` / `src/ownexit/__init__.py` | | 修改 | 2.1.0 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 配置键 `EXIT_BIND_IPV4`

- `set_config_value` 认识该键；`validate_config_values` 在它非空时要求 `is_ipv4`，否则退出 2。
- `parse_config`（`:959-1002`）：函数开头把全局 `EXIT_BIND_IPV4` 置空（`up` 对已有配置会解析两次），循环内用局部标志记录本次是否读到该键。`count` 是已读到的键数。新判断为“读到 `EXIT_BIND_IPV4` 时 `count` 必须是 14，否则必须是 13”。键不重复、没有未知键已由循环保证，所以这等价于 13 个必填键齐全。报错文字改为“必须包含 chain.example.env 的 13 个必填键，另外只允许可选的 EXIT_BIND_IPV4”。
- `normalized_config`：原有 13 行不变；`EXIT_BIND_IPV4` 非空时在第 13 行之后追加 `EXIT_BIND_IPV4=<值>`。没有这个键的配置摘要与 2.0.0 逐字节相同。所有重算摘要的位置（`:6581`、`:6940`、`:6976`、`:6991`、`:7164`、`:8079`、`:8082`、`:8127`、`:8229`）都调用 `normalized_config`，自动带上这一行。
- `rebaseline` 改写配置是按行替换 `RELAY_COHOSTS_SINGBOX=`（`:7081-7095`），其余行原样保留，不受影响。
- `chain/chain.example.env` 末尾加两行：一行中文说明，一行 `# EXIT_BIND_IPV4=REPLACE_WITH_EXIT_LOCAL_IPV4`。
- `scripts/check_interface.sh` 第 10 项（`:206`）提取示例文件的键时，除现有的非注释行外，再取匹配 `^#[[:space:]]*[A-Z][A-Z0-9_]*=` 的行并去掉行首的 `#` 与空白。示例文件现有的注释行都以中文或小写字母开头，不会被误取。这样“示例文件 = `set_config_value` = 参考文档”三方比对继续覆盖可选键。

#### 5.1.2 `init` / `up` 的 `--exit-bind`

`parse_init_args` 新分支：`--exit-bind <IPv4>`，缺值或不是 IPv4 退出 2；置 `INIT_EXIT_BIND` 与 `INIT_EXIT_BIND_GIVEN=1`。

`init_chain` 在出口机配好免密之后（替换 `:9345-9349` 的探测段）：

```text
没有 --exit-bind：维持现状（curl -fsS -m 15 ipinfo.io/ip）
有 --exit-bind <B>：
  1. 经 init 既有的直连 ssh 在出口机上执行 ip -4 -o addr show，取每行第 4 列去掉 /前缀长度 后的地址列表，
     确认 B 是其中之一；不是（含远端没有 ip 命令、列表为空）→ 退出 3：
     “出口机网卡上没有 B（读到的地址：…）；未生成配置文件”
  2. 在出口机上执行 curl -4 -fsS -m 15 --interface B ipinfo.io/ip 取公网 IP；不是 IPv4 → 退出 3
  3. 日志：[exit-bind] chain=<id> bind=B exit_ip=<公网 IP>
```

两条新 ssh 命令沿用 `:9346-9347` 的写法（`ssh -n`、`2>/dev/null`、`|| true`）：不带 `-n` 会吃掉后面确认提问要用的标准输入，不带 `|| true` 会在 `set -e` 下无提示退出。终端下的确认提问不变（显示探测到的出口 IP）。写配置时（`:9367-9376`）在 `EXIT_SOURCE_FILTER` 之后追加 `EXIT_BIND_IPV4=B`；之后既有的读回校验照常执行。

`up_chain` 已有配置时的比对（`:8955-8959`）新增一条：给了 `--exit-bind` 且不等于已有配置的 `EXIT_BIND_IPV4`（含已有配置没有该键）时 `mismatch=1`，退出 2；提示文字里补上现有的绑定地址。没给 `--exit-bind` 时不比对。

#### 5.1.3 出口机配置渲染

`write_prepare_exit_script` 新增第 12 个位置参数 `bind="${12:--}"`（第 11 个 `reuse` 不变）：

- `bind` 为 `-`：出站行与现在逐字节相同。
- 否则要求匹配 `^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$`（不匹配退出 89），出站行为 `"outbounds": [{ "type": "direct", "tag": "direct", "inet4_bind_address": "<bind>" }],`。
- `reuse` 模式不渲染配置，`bind` 不起作用。

`prepare_exit_exit`（`:3898`）在末尾的 `-`（reuse 位）之后追加 `"${EXIT_BIND_IPV4:--}"`，绑定地址非空时打日志 `[exit-bind] chain=<id> bind=<地址>`。`migrate_stage_config` 的调用处不传第 12 个参数（默认 `-`）。

`rotate-keys` / `add-device` / `remove-device` 只改 `users` 行、私钥与 short id（全脚本只有 `:3809` 一处写出站行），绑定地址保留。

#### 5.1.4 出口仲裁

`write_exit_probe_script` 的远端脚本新增第 2 个参数 `bind="${2:--}"`：

```text
bind 不是 -：
  command -v ip 失败 → exit 24
  ip -4 -o addr show 的输出交给单个 awk：第 4 列按 / 切开取地址，等于 bind 时只置标志，读完全部输入后在 END 里决定退出码；
  没有命中 → exit 23
  （不用 ip … | grep -q：脚本开着 pipefail，grep 提前退出会让 ip 收到 SIGPIPE，见 :2162-2163 的既有说明）
  三个端点的 wget 各加 --bind-address="$bind"
其余逻辑不变（2-of-3，任一端点返回的 IPv4 不等于 expected → 21，成功不足 2 个 → 22）
```

`ip` 不进入 `:2194` 的通用依赖清单：那会让没装 iproute2 的已有部署在 preflight 新增失败。它只在使用绑定地址时才被要求。

`probe_exit_exit` 传入 `"${EXIT_BIND_IPV4:--}"`，并把 `:2402` 的 `… || die 3` 改成仓库惯用的 `if …; then rc=0; else rc="$?"; fi` 后分派：

| 远端退出码 | 处理 |
| ---- | ---- |
| 0 | 通过 |
| 23 | 退出 3：“EXIT_BIND_IPV4=<地址> 不在出口机网卡上” |
| 24 | 退出 3：“出口机没有 ip 命令，无法核对 EXIT_BIND_IPV4（安装 iproute2）” |
| 其它（含 255） | 退出 3，沿用原文案；有绑定地址时在句末附 `bind=<地址>` |

表中的“退出 3”是传给 `die` 的码。`die`（`:459-475`）按子命令改写非 2 的退出码，这是既有约定：`preflight` 一律 3，`deploy` / `up` 保留 3，`verify` / `status` 一律 5，`rollback` 一律 6。所以同一条报错在 `verify` 里以 5 退出。

它的四个调用点（`:4931` full_verify、`:4992` preflight、`:5133` deploy、`:8581` migrate）不改。

经链路的出口核验（`smoke_from_relay` `:4268`、`smoke_from_mac` `:4490`）本来就与 `EXPECTED_EXIT_IPV4` 比对，绑定生效后自然得到绑定地址对应的公网 IP，不改。

#### 5.1.5 `migrate-exit`

同机换地址与跨机迁移都从 `migrate_exit_chain` 进入（`:8736-8763`），分别处理：

- **同一台出口机换了 SSH 地址**（三个同机分支，`:8737-8762`）：放行。`migrate_probe_same_host` 里取出口 IP 的远端命令（`:6859`）在 `EXIT_BIND_IPV4` 非空时写成 `curl -4 -fsS -m 15 --interface <绑定地址> ipinfo.io/ip || true`，否则不变。绑定地址已经不在网卡上时该命令取不到 IP，`migrate_rehost_same_host` 既有的检查（`:6914`）以退出 3 结束且不改配置；报错文字在有绑定地址时补一句“确认 EXIT_BIND_IPV4=<地址> 还在出口机网卡上”。其后的配置改写只按行替换 `EXIT_HOST` 与 `EXPECTED_EXIT_IPV4`（`:6931-6934`），绑定地址那一行保留；出口机上的 `exit.json` 不重写。
- **换了一台机器**：在 `migrate_prepare`（跨机迁移的准备阶段，由 `:8765` 调用）内、既有的 state 校验（`:8160-8165`）之后新增判断。放在 state 校验之后，是为了让 state 损坏、配置与 state 不一致这两种情况继续按原文案报错。`EXIT_BIND_IPV4` 非空时退出 2，“链 <id> 设置了 EXIT_BIND_IPV4，不能迁到另一台出口机（新地址经中转连不上时也会按另一台机器处理）；先 rollback，再在新机器上用 --exit-bind 重新 init / deploy”。带绑定地址的链因此不会产生迁移记录，“已有迁移记录”的分支不需要改。

绑定地址被收回、旧 `EXIT_HOST` 也连不上的情况本版不处理（§2 非目标），手册写明：让 `EXIT_HOST` 与绑定地址中至少有一个是不打算更换的地址。

#### 5.1.6 `multi` 的 `--mixed-exits` 与 `--group select`

- `parse_args`：新参数 `--mixed-exits`（不带值，位置不限，verify 与 render 都接受）；`--group` 接受 `fallback` / `url-test` / `select`，并记 `GROUP_GIVEN=1`。循环结束后：
  - `--mixed-exits` 且没给 `--group`：组类型取 `select`（对 verify 没有可见效果）。
  - `--mixed-exits` 且 `--group` 为 `fallback` 或 `url-test`：退出 2（自动切换会在不知情时换出口 IP）。
  - 组类型为 `select` 且给了 `--test-url` 或 `--interval`（各记一个 `*_GIVEN` 标志）：退出 2（手动选择组不做健康检查）。
- `load_chains`：链记录在末尾追加该链的出口 IP（第 9 个字段，`chain_field` 的注释同步）。没有 `--mixed-exits` 时维持“与前面的链不一致即退出 2”；有时不比较。
- `verify_one`（`:749`）：与 `chain_field <index> 9` 比对。各链出口 IP 相同时结果与现在一致。
- `render_auto_group`：`select` 时输出组名 `Exit-Relay-select`、`type: select` 与 `proxies:` 列表，不输出 `url` / `interval`；另两种类型的输出不变。
- `render` 结束时的日志 `group=<类型>` 照常；`--mixed-exits` 时 verify / render 各打一行 `mixed-exits=1`，并在 verify 的逐链结果行末尾追加 `exit=<该链出口 IP>`（新增输出键）。

#### 5.1.7 `doctor --ip-check`

`IPCHECK_PROBE`（`direct/doctor.sh:376` 起）开头读取可选的第 1 个参数 `bind="${1:--}"`，它的 curl 封装 `c()`（`:378`）在 `bind` 不是 `-` 时加 `--interface "$bind"`；探针（`:376-411`）里的全部请求都经 `c()`，只改这一处。链式调用处（`:647-653`）用 `kv_get` 读 `EXIT_BIND_IPV4`，非空且形如 IPv4（四段、每段 1–3 位数字的内联正则；该值在链式脚本一侧已过 `is_ipv4`，这里只做形态门）时把远端命令从 `bash -s` 改为 `bash -s -- <绑定地址>`，并在标题里附上“出站绑定 <地址>”；直连调用处（`:617`）不传参数，行为不变。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| `ownexit chain init` / `up` | 新增参数 `--exit-bind <IPv4>` | 兼容新增 |
| 链配置 | 新增可选键 `EXIT_BIND_IPV4`；缺省时行为与摘要不变 | 兼容新增；带该键的配置 2.0.0 及更早版本会以“未知配置键”拒绝（降级不保证） |
| `ownexit chain` 退出码 | 2：带绑定地址的链迁到另一台机器、`up` 重跑时 `--exit-bind` 与已有配置不同；3：`init` / `preflight` / `deploy` / `up` / `migrate-exit` 发现绑定地址不在出口机网卡上、出口机没有 `ip` 命令（`verify` 发现时按既有约定为 5） | 新增拒绝条件只在使用新功能后出现 |
| `ownexit doctor --ip-check` | 带绑定地址的链按绑定地址体检，标题附绑定地址 | 输出行前缀与末行格式不变 |
| 出口机 `exit.json` | 带绑定地址时出站多一个 `inet4_bind_address` 字段 | 内部文件；缺省时逐字节不变 |
| `ownexit multi` | 新增参数 `--mixed-exits`；`--group` 新增取值 `select` | 兼容新增 |
| `ownexit multi` 输出 | verify 行新增键 `exit=`；新增组名 `Exit-Relay-select` | 兼容新增 |
| `ownexit multi` 退出码 | 2 的“各链 EXPECTED_EXIT_IPV4 不一致”限定为没有 `--mixed-exits` 时；新增两种参数组合错误 | 原有调用结果不变 |
| state.env | 不变 | 不变 |

**reference sibling 回补检查**（按 §"方案文档章节内容质量要求" §5）：

- Q1 涉及 reference 章节：`docs/reference/commands.md` §`ownexit chain`（参数、子命令表的 `migrate-exit` 行、退出码）、§`ownexit multi`（参数、退出码、输出）与 §`ownexit doctor`（`--ip-check` 行）；`docs/reference/files.md` §链配置键、节点名与组名表；`docs/reference/compatibility.md` §5；以及三份的英文版。
- Q2 源码暴露面完整性：`scripts/check_interface.sh` 第 4、5、10、14 项守护 multi 参数、chain 参数、链配置键与中英表格首列；基线上该脚本通过（编码前复跑确认）。
- Q3 本方案是否回补：是，新增暴露面与文档同步落地（§4 表）。
- Q4 placeholder 落地：N/A（已回补）。

## 6. 备选方案与决策

- **一条链、多个出站、按用户分流**：一个出口进程里给不同设备配不同出站。要改 `users` 渲染、路由规则与设备管理的全部路径，且客户端仍只有一个入口端口；否决，按链绑定只动一行出站。
- **策略路由（`ip rule` 按源端口或 fwmark 选源地址）**：要改出口机的系统网络配置，rollback 也要负责还原；否决，sing-box 自带的出站绑定不碰系统配置。
- **`multi` 遇到不同出口 IP 时自动放行**：会让原本退出 2 的调用悄悄成功，并可能把不同出口 IP 放进自动切换组；否决，用显式的 `--mixed-exits`。
- **绑定地址存入 state**：需要提升 `SCHEMA_VERSION`；配置摘要与 `exit.json` 哈希已经覆盖它，否决。

## 7. 影响分析

- `parse_config` / `normalized_config`：所有子命令都经过它。没有新键的配置键数判断与摘要不变（§8 C1）；有新键时摘要不同，state 的配置绑定检查照常生效，已部署的链手工加上该键会被判为 `state-config-binding`（与手工改其它键一致，§8 C5）。
- `write_prepare_exit_script` 参数表加长：deploy 传第 12 个参数，migrate 的 reuse 调用不传；缺省路径的 `exit.json` 逐字节不变，`EXIT_EXIT_SHA256` 的含义不变（§8 R1）。
- `probe_exit_exit`：preflight、deploy、verify、migrate 四处调用。没有绑定地址时远端脚本的 wget 参数不变（§8 R1）；有绑定地址时多一次 `ip -4 -o addr show`，耗时可忽略。
- `init_chain`：没给 `--exit-bind` 时探测命令与生成的配置不变（§8 R1）。
- `up_chain`：没给 `--exit-bind` 时不新增比对；对带绑定地址的已有配置不带参数重跑照常继续（§8 D6）。
- `migrate_exit_chain`：只对带绑定地址的链在跨机分支新增拒绝；同机分支的探测命令只在有绑定地址时多一个 `--interface`，其它链的命令字符串不变（§8 D5、D9、D10、R2）。
- 同一台出口机、同一台中转上的多条链：各链独立端口、单元、nft 表，互不影响；managed 白名单按中转出站源地址放行，与绑定地址无关（§8 D1）。
- 出口机运行时：绑定只发生在出站拨号时，不新增进程；绑定地址被摘掉后该链的 IPv4 出站失败，`verify` 指出原因并以 5 退出（§8 D3），其它链不受影响。
- `multi`：没有新参数时 verify / render 的判定与产物不变（§8 M1）；记录多一个字段只在本脚本内部使用。`verify` 行新增 `exit=` 键只在 `--mixed-exits` 时出现。
- `doctor`：按键读取链配置（`direct/doctor.sh:336`、`:649`），多一个键不影响解析；`--ip-check` 对没有绑定地址的链与直连目标，远端命令与探针行为不变（§8 D11）。
- 降级：带 `EXIT_BIND_IPV4` 的配置被 2.0.0 读取时以“未知配置键”退出 2，不会误操作（文档写明）。

## 8. 回归测试

分三层。L0 不需要服务器；L1 在一台 Linux 测试机上用带 systemd 的容器搭中转、出口（出口容器配 3 个地址）与控制端；L3 是真实的中转机与出口机。L1 的容器都经同一个公网地址出网，公网出口 IP 无法区分，所以“sing-box 的连接确实从绑定地址发起”用中转容器上的 HTTP 回显服务观察来源地址；出口仲裁里 wget 的绑定、`doctor --ip-check` 的绑定、“公网出口 IP 各不相同”只在 L3 闭合。L3 用例里的地址用文档网段表示，真实地址不写进仓库。

| 编号 | 层 | 用例 | 判据 |
| ---- | ---- | ---- | ---- |
| S1 | L0 | 与 CI 相同的检查：`scripts/check_interface.sh`、`check_i18n.sh`、`check_ui_lang.sh`、`check_public.sh`；`bash -n`（含 macOS 的 `/bin/bash` 3.2）；`shellcheck -S warning chain/*.sh scripts/*.sh` | 全部退出 0 |
| C1 | L0 | 同一份 13 键配置分别用基线脚本与新脚本计算 `CONFIG_SHA256`（测试夹具：去掉脚本末行的 `main "$@"` 后 source，调用 `parse_config` 并打印摘要；基线副本用 `git archive` 导出成完整目录，保留 `chain/` 与 `direct/` 的相对位置；不调用 `init_repo_root`；配置放仓库外、600，两把私钥用 `ssh-keygen` 临时生成） | 相同 |
| C2 | L0 | 13 键 + `EXIT_BIND_IPV4=198.51.100.7` | 解析通过；摘要与 C1 不同 |
| C3 | L0 | `EXIT_BIND_IPV4=abc`、`EXIT_BIND_IPV4=1.2.3.999` | 退出 2，stderr 含 `EXIT_BIND_IPV4`（基线脚本对同一文件报的是“未知配置键”） |
| C4 | L0 | 去掉 `EXIT_SOURCE_FILTER` 但有 `EXIT_BIND_IPV4`（共 13 行）；重复 `EXIT_BIND_IPV4`；多一个未知键 | 都退出 2；第一种的 stderr 是 `:999` 的新文案（“13 个必填键”），证明键数判断没有把可选键当必填键凑数 |
| C5 | L1 | 已部署的无绑定链，手工在配置里加 `EXIT_BIND_IPV4` 后 `status` | 输出含 `reason=state-config-binding`，退出 5；删掉该行后恢复 healthy |
| A1 | L0 | `init --exit-bind`（缺值）、`init --exit-bind abc` | 退出 2，stderr 是 `--exit-bind` 分支自己的文案（“--exit-bind 需要 IPv4”一类），不是基线的“不认识的参数” |
| P1 | L1 | 在测试床的出口容器里直接运行出口仲裁脚本（`expected` 取容器内 `curl -4 ipinfo.io/ip` 的结果）：不带绑定；绑定容器的第 2 个地址；绑定一个不在网卡上的地址；带绑定但 PATH 指向一个临时目录，里面只放脚本用到的其它命令的符号链接、不放 `ip` | 前两种输出 `EXIT_BASELINE=ok`；第三种退出 23；第四种退出 24 |
| M1 | L0 | 两条出口 IP 相同的夹具链：基线脚本与新脚本各 `render --no-qr` | `nodes.txt`、`clash-snippet.yaml` 逐字节相同 |
| M2 | L0 | 三条出口 IP 不同的夹具链，不带 `--mixed-exits` 的 render / verify | 退出 2，文字同基线 |
| M3 | L0 | 同上，`--mixed-exits render --no-qr` | 退出 0；片段有 3 个节点、组名 `Exit-Relay-select`、`type: select`、无 `url` / `interval` |
| M4 | L0 | `--chains a,b,c --mixed-exits render --group fallback --no-qr`；`--chains a,b render --group select --interval 60 --no-qr` | 都退出 2，stderr 分别是两条新增的组合校验文案（不是“未知参数”或“只能跟在 render 后”） |
| M5 | L0 | 出口 IP 相同的链 `render --group select --no-qr` | 退出 0，组为 `Exit-Relay-select` |
| D1 | L1 | 同一中转、同一出口部署三条链：a 绑第 2 个地址、b 绑第 3 个地址、c 不绑定 | 三条都 `status=deployed health=healthy`、`verify` 通过；a、b 的 `exit.json` 含各自的 `inet4_bind_address`，c 不含；控制端按各链 `node.txt` 的参数起一个本机 sing-box 客户端（socks 入站，配置骨架同 `render_client_config`），经它访问中转容器上的 HTTP 回显服务，服务端看到的来源地址分别是出口的第 2、第 3、主地址 |
| D2 | L1 | 对 a 做 `rotate-keys`、`add-device x`、`remove-device x` | 都成功；`exit.json` 仍含原绑定地址；`verify` 通过 |
| D3 | L1 | 摘掉出口容器上 a 的绑定地址后 `verify`；加回后再 `verify` | 第一次退出 5（`verify` 的失败码）且提示地址不在网卡上，b、c 的 `verify` 不受影响；加回后通过 |
| D4 | L1 | `init --exit-bind <出口上没有的地址>` | 退出 3，未生成配置文件 |
| D5 | L1 | 对 a 运行 `migrate-exit --to <控制端容器地址>`（另一台机器；测试床里各容器出自同一镜像，要先各自重新生成 SSH 主机密钥，保证主机指纹不同） | 退出 2，stderr 含 `EXIT_BIND_IPV4`；配置、state 不变，没有迁移记录 |
| D6 | L1 | `up --id a` 带相同 `--exit-bind` 重跑；带不同 `--exit-bind` 重跑；不带参数重跑 | 第一、三种幂等继续；第二种退出 2 |
| D7 | L1 | `multi --chains a,b,c --mixed-exits verify`（控制端到中转不经 TUN）；再把三条链的配置与状态目录复制到另一组 XDG 目录，把其中 b 的 `EXPECTED_EXIT_IPV4` 改成 `198.51.100.9` 后同样 verify | 第一次逐链 `result=ok`，行末有 `exit=`；第二次 b 为 `result=mismatch`、a 与 c 仍为 `ok`，退出 5（证明按各链自己的出口 IP 比对） |
| D9 | L1 | 链 b（`EXIT_HOST` 为出口主地址、绑定第 3 个地址）运行 `migrate-exit --to <出口第 2 个地址>` | 输出 `migrate=rehosted`；配置里 `EXIT_HOST` 变为第 2 个地址、`EXIT_BIND_IPV4` 不变；`verify` 通过 |
| D10 | L1 | 接 D9，摘掉 b 的绑定地址后运行 `migrate-exit --to <出口主地址>` | 退出 3，stderr 提示 `EXIT_BIND_IPV4`；配置与 state 不变；地址加回后同一命令成功 |
| D11 | L1 | `doctor --chain a --ip-check`、`doctor --chain c --ip-check` | 都正常输出体检段落；a 的标题带绑定地址，c 的不带 |
| D8 | L1 | 最后执行：三条链依次 `rollback` | 都成功；出口与中转上本链文件、单元、nft 表清空 |
| R1 | L1 | 不带 `--exit-bind` 的链 `up`、`verify`、`rollback` | 与 2.0.0 行为相同；`exit.json` 与 R2 用 2.0.0 部署出的 `exit.json` 相比，只有端口、UUID、私钥、short id 四处取值不同 |
| R2 | L1 | 用 2.0.0 脚本部署一条链，换成新脚本后 `status`、`verify`、`rotate-keys` | 都成功，不需要重新部署 |
| X1 | L3 | 真实环境（地址以文档网段代称）：中转 `203.0.113.10`，上面已有一组非 ownexit 的转发单元；出口机有 `198.51.100.20`（主）、`.21`、`.22` 三个地址。部署三条链，分别绑定三个地址 | 三条链 `verify` 通过（仲裁里的 wget 没绑定就会因出口 IP 与登记值不同而以 21 失败）；三个节点经客户端访问到的出口 IP 分别是三个地址；`multi --mixed-exits verify` 三条 `result=ok` 且 `exit=` 各不相同；`doctor --ip-check` 三条链显示的出口 IP 各不相同；中转上原有的转发单元仍为 active、主进程号与监听端口不变 |

L1 的测试床若搭不起来（容器内 systemd、从容器下载 sing-box 官方包等前提不成立），D、R、C5 各项改在 L3 的真实机器上执行，并在验证报告中写明。

## 9. 日志 / 观测点

- `init`：`[chain][init] INFO [exit-bind] chain=<id> bind=<地址> exit_ip=<公网 IP>`；地址不在网卡上时 `ERROR … 出口机网卡上没有 <地址>（读到的地址：…）`。
- `deploy`：`[chain][deploy] INFO [exit-bind] chain=<id> bind=<地址>`（渲染出口配置前）。
- 出口仲裁失败：`EXIT_BIND_IPV4=<地址> 不在出口机网卡上`，或原仲裁失败文案加 `bind=<地址>`；`preflight` / `deploy` / `up` 退出 3，`verify` 退出 5。
- 出口机没有 `ip` 命令：同上的退出码，`出口机没有 ip 命令，无法核对 EXIT_BIND_IPV4`。
- `migrate-exit`：跨机被拒时退出 2，文字含 `EXIT_BIND_IPV4`；同机切换取不到出口 IP 时退出 3，文字提示核对 `EXIT_BIND_IPV4` 是否还在网卡上。
- `doctor --ip-check`：带绑定地址的链，体检段落标题附“出站绑定 <地址>”。
- 出口机上核对：`grep inet4_bind_address /etc/ownexit-chain/<id>.exit.json`；`journalctl -u ownexit-chain-exit-<id>` 里出站失败会带 bind 错误。
- `multi`：`--mixed-exits` 时 stderr 一行 `mixed-exits=1`，verify 结果行 `… result=<…> endpoints=<n>/3 elapsed=<n>s exit=<IP>`。
