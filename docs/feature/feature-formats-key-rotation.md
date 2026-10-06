# v0.5.0：直连订阅新增 sing-box 格式、Reality 凭据轮换（直连与链式）

> **2026-10-05 注记**：已落地并通过 §8 回归（本机 Lima Ubuntu 22.04 arm64 虚拟机：直连 D1-D8、D5b、D5c，链式 C1-C12、C4b；S1 以 CI 为准）。实现锚点：直连 `direct/direct_remote.sh` 的 `op_reparam` WRITE 步 ROTATE 分支与 `probe` 的 `TXN_ROTATE`，`direct/setup_direct.sh` 的 `--rotate-keys` / `ROTATED` / `DO_ROTATE` 与 `sing-box.json` 渲染；链式 `chain/setup_chain.sh` 的 rotate-keys 函数组（`write_rotate_remote_script` 至 `rotate_keys_chain`，位于 `status_chain` 之前）、verify 出口机脚本的 `exit 150`、`probe_remote_resources` 的返回码 33。实现比方案多一个远端码 198（出口机固定二进制缺失）。回归中另外发现：直连帮助示例 `--sni www.microsoft.com` 实测不能当 Reality 伪装域名（客户端握手被服务器判为无效），已改为实测可用的 `www.apple.com`，并在帮助与手册中提示换域名后先实测。

## 1. 背景

- 直连订阅目前有三份产物：`clash.yaml`、`shadowrocket.txt`（base64 编码的 vless 链接列表）、`node.txt`（明文 vless 链接），见 `direct/setup_direct.sh:611-659`。没有 sing-box 客户端（官方 SFI / SFA / SFM 等）可以直接导入的配置。
- v2rayN / v2rayNG 的“订阅”接受 base64 编码的分享链接列表，与 `shadowrocket.txt` 内容格式相同，但交付汇总与手册只写了 Shadowrocket（`direct/setup_direct.sh:777`、`docs/manual/direct.md` §4）。
- 两种部署方式都没有换 Reality 凭据的手段：
  - 直连只能 `--sni` / `--proxy-port` 改参数，UUID 与密钥不变（`direct/direct_remote.sh:436-489`）；
  - 链式的 UUID / Reality 密钥只在 deploy 时由出口机生成一次（`chain/setup_chain.sh:3411-3418`），之后只能 rollback + deploy（中转端口、部署 ID 全变）。
- 用户已确认的版本计划：v0.5.0 = 候选 4（更多订阅格式：sing-box 客户端 / v2rayN）+ 候选 5（Reality 密钥轮换，直连与链式共用）。

## 2. 目标 / 非目标

目标：

1. 直连订阅新增 `sing-box.json`（完整可加载的 sing-box 客户端配置），交付汇总与文档写明 v2rayN / v2rayNG 使用 base64 订阅。
2. 直连新增 `--rotate-keys`：在服务器上重新生成 Reality 密钥对、short id 与 UUID，端口、SNI、flow、订阅地址不变；失败自动恢复原配置。
3. 链式新增 `rotate-keys` 子命令：只换出口机的 UUID / Reality 密钥 / short id，中转、端口、部署 ID、owner 不变；中途中断重跑同一条命令可收敛，最后跑完整 verify。

非目标：

- 链式与多链聚合（`multi_chain_client.sh`）不新增 sing-box 产物（链式目前唯一产物是 `node.txt`，聚合产物另有计划）。
- 不做定时自动轮换；不轮换订阅 TOKEN（已有 `--rotate-token`）；不改 SNI / 端口（已有 `--sni` / `--proxy-port`，链式换端口仍走 rollback + deploy）。
- 不自动对任何在用的链或直连执行轮换（轮换会让所有已导入客户端失效，由使用者自己决定何时做）。

## 3. 假设与约束

- sing-box 客户端配置按 1.12+ 新格式（DNS server 用 `type` 字段、路由动作用 `action`），与服务端固定版本 1.13.14 同代；以本机缓存的官方 darwin 包 `sing-box check` 作为格式验收（测试用，不进入运行时依赖）。
- 链式出口机配置文件由 `write_prepare_exit_script` 的 heredoc 生成（`chain/setup_chain.sh:3421-3449`），UUID、私钥、short id 各自独占一行且行内容固定：

```text
    "users": [{ "uuid": "<uuid>", "flow": "xtls-rprx-vision" }],
        "private_key": "<private_key>",
        "short_id": ["<short_id>"]
```

  轮换按“恰好 1 行”精确替换这三行，不复制模板（避免与 deploy 模板分叉）。
- 链式 CHAIN_ID 只允许 `[a-z0-9][a-z0-9-]{0,31}`（`chain/setup_chain.sh:625`），不含点，`<id>.rotate.*` 不会与其它链的文件名冲突。
- 轮换后所有已导入的客户端都要重新导入（旧凭据立刻失效）；这是功能本意，命令输出与文档明确提示。

## 4. 涉及模块

| 区域 | 行号锚点（基线 main 897fff7） | 改动类型 | 改动点 |
| ---- | ---- | ---- | ---- |
| `direct/setup_direct.sh` 用法与参数 | 60-93、105-130 | 修改 | 新增 `--rotate-keys`；与 `--migrate` / `--uninstall` 互斥，可与 `--sni` / `--proxy-port` / `--rotate-token` 同用 |
| `direct/setup_direct.sh` 复用分支 | 517-528 | 修改 | `ROTATE_KEYS=1` 时也走 `start_op reparam`，多传 `ROTATE=1`；提示文案区分 |
| `direct/setup_direct.sh` none / legacy 分支 | 489-498、537-552 | 修改 | 新装时 `--rotate-keys` 无意义，打印提示后按新装处理；legacy 未迁移时拒绝 |
| `direct/setup_direct.sh` 渲染订阅 | 652-659 邻近 | 新增 | 渲染 `sing-box.json`，本地校验关键字段 |
| `direct/setup_direct.sh` 交付汇总 | 770-795 | 修改 | 新增 sing-box 订阅 URL；Shadowrocket 行改为 “Shadowrocket / v2rayN”；轮换后提示重新导入 |
| `direct/direct_remote.sh` `op_reparam` WRITE 步 | 445-458 | 修改 | `arg ROTATE` 为 1 时现场生成新密钥对 / UUID / short id，`client.env` 的 SOURCE 不变 |
| `direct/direct_remote.sh` 头部用法注释 | 1-30 | 修改 | op.args 新增键 `ROTATE` |
| `direct/direct_remote.sh` `probe` | 99-134 | 修改 | 有未完成操作时多输出 `TXN_ROTATE`（读 op.args 的 `ROTATE`，无则 0） |
| `direct/setup_direct.sh` in_progress 恢复 | 436-444 | 修改 | 恢复结果为 `OP=reparam RESULT=ok` 时置 `CHANGED_PARAMS=1`；`OP=reparam`、`RESULT=ok` 且 `TXN_ROTATE=1` 时置 `ROTATED=1` |
| `chain/setup_chain.sh` 用法 | 146-200 | 修改 | 新增 `rotate-keys` 说明 |
| `chain/setup_chain.sh` `parse_args` | 563 | 修改 | 命令白名单加 `rotate-keys` |
| `chain/setup_chain.sh` `write_verify_exit_script` | 4373 邻近（`exit 147` 之后） | 新增 | 存在 `/etc/ownexit-chain/<id>.rotate.*` 时 `exit 150`（未完成的轮换） |
| `chain/setup_chain.sh` `probe_remote_resources` | 4508-4509 | 修改 | 出口机脚本返回 150 时返回新码 33（其余非 255 仍为 32） |
| `chain/setup_chain.sh` `status_chain` | 6776-6787 | 修改 | 远端资源码 33 时输出 `status=drifted reason=rotate-pending next=run-rotate-keys` |
| `chain/setup_chain.sh` `full_verify` | 4552 | 修改 | 由 `verify_remote_resources yes` 改为直接调用 `probe_remote_resources yes` 并按返回码分支：33 时 `die 5` 提示重跑 rotate-keys，其余非 0 保持原 `die 5` 信息 |
| `chain/setup_chain.sh` `rollback_chain` | 5430 | 修改 | 同理直接调用 `probe_remote_resources no`：33 时 `die 6` 提示先重跑 rotate-keys，其余非 0 保持原 `die 6` 信息 |
| `chain/setup_chain.sh` `remove_active_local_artifacts` | 5294-5332 | 修改 | 删除 `${CHAIN_STATE_DIR}/.node.txt.rotate.*.tmp`（逐个先 `require_secure_user_file 600`），避免 rollback 后留下孤儿残留 |
| `chain/setup_chain.sh` `local_deployment_residue_absent` | 4213-4230 | 修改 | 候选列表加 `${CHAIN_STATE_DIR}/.node.txt.rotate.*.tmp` |
| `chain/setup_chain.sh` `configured_local_resources_absent` | 5739-5758 | 修改 | 同一候选模式（rollback 的未部署 no-op 判定不放过残留） |
| `chain/setup_chain.sh` 新函数组 | `status_chain`（6674）之前 | 新增 | `write_rotate_remote_script`、`rotate_remote_reason`、`rotate_exit_keys`、`publish_rotated_node`、`commit_rotate_state`、`rotate_cleanup_remote`、`rotate_test_stop`、`rotate_keys_chain` |
| `chain/setup_chain.sh` `main` | 7151 邻近 | 新增 | `rotate-keys) rotate_keys_chain ;;` |
| `src/ownexit/__init__.py` | 1 | 修改 | 版本 0.5.0 |
| 文档 | README 两份、`docs/manual/direct.md` §4/§6、`docs/manual/chain.md` §5/§8、`chain/README.md` 命令与新节、`SECURITY.md`、`CHANGELOG.md` | 修改 | 新格式、两个新命令、退出码 |

## 5. 方案

### 5.1 实现要点

#### 5.1.1 直连 `sing-box.json`

插入位置：`direct/setup_direct.sh:659`（`node.txt` 渲染）之后。内容（变量替换后为合法 JSON，FLOW 为空时省略 `"flow"` 字段）：

```json
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [
      { "type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "proxy" },
      { "type": "local", "tag": "local" }
    ],
    "rules": [{ "rule_set": "geosite-cn", "server": "local" }],
    "final": "remote"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true },
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 7890 }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "proxy",
      "server": "<PROXY_SERVER>", "server_port": <PROXY_PORT>,
      "uuid": "<PROXY_UUID>", "flow": "<PROXY_FLOW>",
      "tls": {
        "enabled": true, "server_name": "<PROXY_SNI>",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "<PROXY_PBK>", "short_id": "<PROXY_SID>" }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct" }
    ],
    "rule_set": [
      { "type": "remote", "tag": "geosite-cn", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", "download_detour": "proxy" },
      { "type": "remote", "tag": "geoip-cn", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs", "download_detour": "proxy" }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": "local"
  }
}
```

- 路由意图与 `clash.yaml` 相同：国内域名（geosite-cn）与国内 IP 目标（geoip-cn，对直接以 IP 访问的连接生效）直连，其余走出口；不保证与 mihomo 的 GEOIP（会先解析域名）逐条等价。规则集经代理下载（GitHub raw 在国内常不可达）。客户端最低版本 1.12（DNS `type: https` 与路由 `action` 是 1.12 引入的格式）；`route.default_domain_resolver` 必须保留（1.13.14 缺它时 `check` 报 FATAL，已实测）。
- tun 入站给官方图形客户端（SFI / SFA / SFM 必须有 tun 才能开 VPN）；mixed 入站给命令行 / 浏览器手动代理，端口与 `clash.yaml` 的 `mixed-port` 一致。
- 本地校验：与 clash 相同，`grep -qF` 核对 `"server": "<PROXY_SERVER>"`、`"uuid": "<PROXY_UUID>"`、`"public_key": "<PROXY_PBK>"`（`direct/setup_direct.sh:684-687` 同款循环）；有 `python3` 时再做 `json.load` 解析校验，没有则跳过（本机依赖不新增）。
- 订阅服务无需改动：`python3 -m http.server` 按扩展名给 `application/json`。
- 交付汇总新增 `sing-box: http://<host>:<port>/<TOKEN>/sing-box.json`，`Shadowrocket` 行改为 `Shadowrocket / v2rayN`，人工步骤新增“sing-box 官方客户端：配置 → 新建远程配置 → 粘贴 sing-box 订阅 URL”“v2rayN：订阅分组 → 添加 → 粘贴 base64 订阅 URL → 更新订阅”。

#### 5.1.2 直连 `--rotate-keys`

本机（`direct/setup_direct.sh`）：

- 新变量 `ROTATE_KEYS=0`、`ROTATED=0`，`--rotate-keys` 置 `ROTATE_KEYS=1`。互斥检查的最终形式：`(( DO_MIGRATE + DO_UNINSTALL + ROTATE_TOKEN <= 1 ))`（原样保留）且 `(( DO_MIGRATE + DO_UNINSTALL + ROTATE_KEYS <= 1 ))`；即 `--rotate-keys` 可与 `--rotate-token` / `--sni` / `--proxy-port` 同用，不能与 `--migrate` / `--uninstall` 同用。
- in_progress 恢复（`:436-444`）：恢复的操作是 `reparam` 且结果 ok 时置 `CHANGED_PARAMS=1`（同机链的 rebaseline 提示与“重新导入”提示不丢）；仅当恢复的 `OP=reparam`、`RESULT=ok` 且 probe 输出 `TXN_ROTATE=1` 时置 `ROTATED=1`（恢复以 `rolled-back` 结束时凭据未变，`ROTATED` 保持 0，本次 `--rotate-keys` 照常执行）。
- 状态分派：
  - `none`：打印“新装本来就会生成全新凭据，忽略 --rotate-keys”，按新装处理；
  - `ownexit` / `migrated_leftover`：令 `DO_ROTATE = ROTATE_KEYS 且 ROTATED=0`（刚恢复完成的操作已经轮换过，本次不再轮换，避免凭据被换两次）；`DO_ROTATE=1` 或 SNI / 端口有变化时执行 `start_op reparam "NEW_SNI=…" "NEW_PORT=…" "ROTATE=${DO_ROTATE}"`（取值 0 / 1），提示行按是否轮换分别显示“UUID 与密钥不变”或“UUID / Reality 密钥 / short id 全部重新生成”；成功后 `CHANGED_PARAMS=1`（触发链式 rebaseline 提示与“重新导入”提示）；
  - `legacy`：未加 `--migrate` 时照旧退出 2；`--migrate` 与 `--rotate-keys` 互斥，提示先迁移再轮换；
  - `conflict` / `in_progress`：不变（in_progress 恢复时使用服务器上原 op.args，`ROTATE` 随之恢复）。
- 交付汇总在 `DO_ROTATE=1` 或 `ROTATED=1` 时追加：“已更换节点凭据：所有设备都要重新拉取订阅，旧节点已失效”。

服务器（`direct/direct_remote.sh` `op_reparam` WRITE 步，替换 `:448-456` 读 UUID / 公钥 / short id / 私钥的几行）：

```bash
if [[ "$(arg ROTATE)" == 1 ]]; then
  bin="$(binary_path)"
  keypair="$("${bin}" generate reality-keypair)"
  private_key="$(printf '%s\n' "${keypair}" | awk -F': ' '$1 == "PrivateKey" {print $2}')"
  public_key="$(printf '%s\n' "${keypair}" | awk -F': ' '$1 == "PublicKey" {print $2}')"
  uuid="$("${bin}" generate uuid)"
  short_id="$("${bin}" generate rand --hex 8)"
  # 与 op_fresh 相同的格式校验（direct_remote.sh:381-382）
else
  # 原有读取逻辑不变
fi
```

- `flow` / `listen` / `SOURCE` 仍从旧 `client.env` 读取（迁移来的节点 `listen=::`、`SOURCE=migrated` 保留）。
- WRITE 步重入时重新生成一次也无副作用：此时线上文件尚未替换，只覆盖 `.new` 文件；进入 BACKUP 之后的步骤只使用已写好的 `.new` 文件，不再生成。
- 回滚沿用 `reparam_rollback`（`:419-434`）：恢复备份的 `config.json` / `client.env` 并重启，结果 `rolled-back`。
- 二进制：改参数分支不经过 repair（repair 只在参数不变的 else 分支，`setup_direct.sh:528-537`）。在 ROTATE 分支内先检查 `binary_path` 可执行，否则 `CAUSE=binary; false`；ERR 由 on_err 在 WRITE 步处理（只删 `.new`，`direct_remote.sh:726-731`），线上不受影响。该检查只放在 WRITE 步的 ROTATE 分支，不影响恢复到 BACKUP 之后的步骤。

#### 5.1.3 链式 `rotate-keys`

总体顺序（与 rehost-exit 一致：不走事务，每一步可重入，本地 state 最后提交）：

```text
取锁（同 rehost_exit_chain 的 rc 映射）→ require_local_dependencies → 拒绝未完成事务 / 未部署
→ 载入 state（probe_state_file 必须返回 0，返回 12 退出 2，其它退出 5）→ render_ssh_config
→ probe_loaded_binding（返回值映射照抄 rehost_exit_chain:6388-6398：21/22/31/32 退出 3，11/12 与其它退出 5）
→ 清理本机 ${CHAIN_STATE_DIR}/.node.txt.rotate.*.tmp 残留（逐个先 require_secure_user_file 600，与 rollback 侧口径一致）
→ 远端 rotate（出口机）：生成或复用待切换配置 → 切换 → 重启 → 核验；输出新参数与新配置哈希
→ 本机发布新 node.txt（同目录临时文件 + mv）
→ 归档旧 state 到 audit/rotated.<部署ID>.<操作ID>/state.env，提交新 state
→ 远端 cleanup（删除出口机上的 <id>.rotate.* 文件）
→ ensure_local_assets_match_state → full_verify
```

出口机上的三个辅助文件（root:root 600，与线上配置同目录 `/etc/ownexit-chain/`）：

| 文件 | 内容 |
| ---- | ---- |
| `<id>.rotate.json` | 待切换的新配置（含新私钥） |
| `<id>.rotate.env` | `NEW_SHA256` / `VLESS_UUID` / `REALITY_PUBLIC_KEY` / `REALITY_SHORT_ID`（无私钥） |
| `<id>.rotate.bak.json` | 切换前的旧配置，用于重启失败时恢复 |

远端脚本 `write_rotate_remote_script`，参数：`mode`（`apply` / `cleanup`）、`chain_id`、`port`、`state_exit_hash`（state 的 `EXIT_EXIT_SHA256`）、`binary`（`${REMOTE_BIN}`）。`apply` 的判定表（live = 线上配置哈希，env.NEW = `<id>.rotate.env` 里的 `NEW_SHA256`）：

| 现场 | 判定 | 动作 |
| ---- | ---- | ---- |
| live = state，且 env 存在、`<id>.rotate.json` 哈希 = env.NEW | 上次在切换前中断 | 复用待切换配置，执行切换 |
| live = state，且 env 存在、env.NEW = live | 上次已提交 state、未清理 | 只做 cleanup，输出 `RESULT=resumed-after-commit` 与 env 里的参数；本机核对参数与 state 一致后跳过发布与提交，直接收尾 verify（不再轮换） |
| live = state，其它情况（无辅助文件或不一致） | 全新轮换 | 删除残缺辅助文件；生成新凭据，按三行精确替换生成 `<id>.rotate.json`，`sing-box check` 通过后先写 env（临时文件 + mv）再写 json（临时文件 + mv） |
| live ≠ state，且 env 存在、live = env.NEW | 已切换、本地未提交 | 跳过切换，重启一次（防止“文件已换但进程仍跑旧配置”），核验后输出参数；核验失败走与切换相同的恢复（此时 bak 必然存在） |
| live ≠ state，其它 | 外部改动 | `exit 193`，不动任何文件 |

切换：`cp -p live → <id>.rotate.bak.json`（bak 已存在且哈希 = state 时复用），`mv <id>.rotate.json → live`，`systemctl restart`，等待最多 10 秒 `active`、`MainPID` 指向固定二进制、端口监听；失败则 `mv bak → live`、restart、删除 `<id>.rotate.json` 与 env，成功恢复 `exit 195`、恢复后仍起不来 `exit 196`。成功时输出 `RESULT=fresh|resumed|already`、`VLESS_UUID`、`REALITY_PUBLIC_KEY`、`REALITY_SHORT_ID`、`EXIT_EXIT_SHA256`。

三行替换：用 awk 字符串比较（不用 sed 正则），对每行去掉前导空白后做前缀比较，前缀分别为 `"users": [{ "uuid": "`、`"private_key": "`、`"short_id": ["`，整行替换为同样缩进（4 / 8 / 8 个空格，`chain/setup_chain.sh:3434`、`:3441-3442`）的新行；各自必须恰好 1 行，否则 `exit 192`。旧值不需要读出。

远端临时文件统一命名 `/etc/ownexit-chain/<id>.rotate.<用途>.$$.tmp`，脚本用 EXIT trap 清理（仿 `write_rehost_remote_script` 的 `:6205-6207`）；`<id>.rotate.*` 的 150 检查同时覆盖这些临时文件。

`cleanup`：删除三个辅助文件；只在 `live 哈希 = 参数传入的新哈希` 时执行（防止在错误时机删掉恢复所需的 bak），否则 `exit 197`。

其它退出码：`191` 线上配置文件身份或权限异常（要求 root:root 600、非软链）；`194` 新配置 `sing-box check` 失败（已删除辅助文件，线上未动）；`198` 出口机固定 sing-box 二进制缺失；`255` SSH 不可达（本机按退出码 3 处理）。`rotate_remote_reason` 把这些码翻译成中文原因（同 `rehost_remote_reason`，`chain/setup_chain.sh:6293-6306`）。

本机发布 node.txt：设置新 `VLESS_UUID` / `REALITY_PUBLIC_KEY` / `REALITY_SHORT_ID` 后调用现有 `render_node_artifact`（`:4149`）写 `${CHAIN_STATE_DIR}/.node.txt.rotate.<操作ID>.tmp`（600；放在 state 目录而不是 `client/`，否则中断残留会让 rollback 的 `rmdir client`（`:5307`）失败），`mv -f` 到 `client/node.txt`（同一文件系统，原子替换；原 node.txt 是 deploy 时的硬链接，替换不影响 audit 里的副本），复核哈希，更新 `NODE_SHA256`。

提交 state：仿 `commit_rehost_state`（`:6346-6364`）：归档旧 state 到 `audit/rotated.<部署ID>.<操作ID>/state.env` 并复核，`EXIT_EXIT_SHA256` 用远端输出值，`render_state_payload` + `write_checksummed_file replace`，最后 `probe_state_file` 必须返回 0。

重入路径（任何一步中断后重跑同一命令）：

| 中断点 | 重跑时现场 | 收敛方式 |
| ---- | ---- | ---- |
| 生成待切换配置前 / 中 | live = state，辅助文件缺失或残缺 | 全新轮换 |
| 切换前 | live = state，辅助文件完整 | 复用并切换 |
| 切换后、node.txt 前 | live = env.NEW | already：重启、重新渲染 node.txt、提交 |
| node.txt 后、state 前 | 同上；node.txt 已是新内容 | 重新渲染得到相同内容，提交 |
| state 后、cleanup 前 | live = state（新）、env.NEW = live | `resumed-after-commit`：只做 cleanup 与收尾 verify，不再轮换 |
| cleanup 后、verify 前 | 一切已提交 | 重跑即再轮换一次；只想核验时跑 `verify` |

辅助文件存在时 `verify` / `status` / `rollback` 失败：出口机脚本 `exit 150`，`probe_remote_resources` 返回新码 33，`status` 输出 `status=drifted reason=rotate-pending next=run-rotate-keys`（沿用已公开的 `drifted` 取值，只新增 reason），`full_verify` 与 `rollback_chain` 改为直接调用 `probe_remote_resources` 并在 33 时提示先重跑 `rotate-keys`。本机 `.node.txt.rotate.*.tmp` 残留让 `full_verify` 的残留检查失败；rotate-keys 开头会清理它；rollback 在 `remove_active_local_artifacts` 中删除它（不在 `client/` 下，不影响 `rmdir client`），保证 rollback 后不会留下让 status / deploy 判孤儿的文件。

测试钩子（正常使用不要设置）：

- `OWNEXIT_TEST_ROTATE_STOP_AFTER=stage|swap|node|state|cleanup`：在对应阶段后以退出码 99 结束（同 `rebaseline_test_stop`）。`stage` 与 `swap` 发生在远端脚本内部，本机把它作为第 6 个参数 `test_stop`（`stage` / `swap` / `-`）传给远端：`stage` 在写完待切换配置后 `exit 99`，`swap` 在切换并核验通过、输出参数之前 `exit 99`。
- `OWNEXIT_TEST_ROTATE_BREAK_PORT=<端口>`：作为第 7 个参数传给远端（未设置时传 `-` 作哨兵，ssh 会吞掉空参数），生成待切换配置时额外把 `"listen_port": <原端口>,` 一行（必须恰好 1 行）替换成该端口；在 already 路径上则对线上新配置做同样替换后再重启，用于构造“配置合法但启动失败”（端口被占用）的恢复路径。


命令输出：成功时 `rotate=done chain=<id> result=<fresh|resumed|already|resumed-after-commit>`，并打印“所有客户端需要重新导入 node.txt（多链聚合需要重新 render）”。退出码：0 成功；2 配置与 state 不一致；3 出口机不可达（含远端脚本返回 255）或主机指纹不符；5 锁、state 损坏、有未完成事务或收尾 verify 失败；1 远端轮换或本地提交失败（信息里带 191–197）。

### 5.2 接口变更

| 接口 | 变更 | 兼容性 |
| ---- | ---- | ---- |
| 直连订阅目录 | 新增 `<TOKEN>/sing-box.json` | 新增，旧链接不变 |
| `setup_direct.sh` / `ownexit direct` | 新增 `--rotate-keys` | 新增；不加时行为不变 |
| `direct_remote.sh` op.args | 新增可选键 `ROTATE`（`0` / `1`） | 旧 op.args 无此键按 0 处理，进行中的旧操作可恢复 |
| `direct_remote.sh` probe 输出 | 新增 `TXN_ROTATE` | 本机旧版本忽略未知键 |
| `setup_chain.sh` / `ownexit chain` | 新增子命令 `rotate-keys` | 新增 |
| 链式出口机文件 | 新增临时文件 `/etc/ownexit-chain/<id>.rotate.{json,env,bak.json}`，命令成功后删除 | 旧版本脚本看不到这些文件；残留时新版本 verify 报 drift |
| 链式 verify 出口机脚本 | 新增退出码 150；`probe_remote_resources` 新增返回码 33；`status` 在 `status=drifted` 下新增 `reason=rotate-pending next=run-rotate-keys`（不新增状态取值） | 只在新功能残留时出现 |
| `state.env` | 字段不变；轮换后 `VLESS_UUID` / `REALITY_PUBLIC_KEY` / `REALITY_SHORT_ID` / `EXIT_EXIT_SHA256` / `NODE_SHA256` 取新值 | 旧版本脚本可直接管理轮换后的链 |
| 本机 audit | 新增 `audit/rotated.<部署ID>.<操作ID>/state.env` | 与 `rehosted.*` / `rebaselined.*` 同形态 |

不涉及 `docs/reference/*`，无需 sibling 回补检查。

## 6. 备选方案与决策

- 链式轮换走 rollback + deploy：中转端口、部署 ID、基线全部重来，期间链不可用时间长；否决。
- 链式轮换在本机生成密钥：需要本机有 sing-box 或支持 X25519 的 openssl（macOS 自带 LibreSSL 版本不一），且私钥会经过本机；否决，沿用“密钥只在出口机生成”。
- 链式轮换走事务日志（transaction.env）：要改 deploy / rollback 的恢复分派，改动面大；否决，采用 rehost-exit 的“可重入 + 最后提交”模式，用出口机辅助文件承载中间状态。
- 链式重写配置用模板重新渲染：与 deploy 模板重复，后续改模板容易漏一处；否决，采用三行精确替换。

## 7. 影响分析

正向：

- 直连 `op_reparam` 被 `ROTATE` 参数扩展：不传时走原分支，`--sni` / `--proxy-port` 行为不变（§8 D2）。轮换会改 `/etc/ownexit-direct/config.json`，若这台 VPS 同时是链的中转机，链的基线（`RELAY_COHOSTS_SINGBOX=ownexit-direct` 时采集 ownexit-direct 的配置清单）漂移，需要 `rebaseline`；`CHANGED_PARAMS=1` 已触发 `print_chain_hints`（§8 D5）。
- 直连订阅目录多一个文件：订阅服务只读静态文件，根路径空 `index.html` 不变（§8 D1 的根路径检查）。
- 链式 `write_verify_exit_script` 新增一行检查：被 `probe_remote_resources`（`:4493`）调用；直接调用方只有 `verify_remote_resources`（`:4528`，折成真假）与 status（`:6777`），本方案再把 full_verify、rollback 改为直接调用。经 `verify_remote_resources` 的全部调用点（无截断 grep）：full_verify `:4552`、preflight_chain `:4623`、commit_deploy `:4714`、rollback_chain `:5430`、deploy 恢复 `:5598` / `:5617`、status_chain `:6777`；rehost-exit / rebaseline 经 full_verify 使用。新返回码 33 只在辅助文件存在时出现：preflight / commit_deploy / deploy 恢复对它与 32 同样按 drift 处理（只判非 0），full_verify / rollback / status 给出专门提示。没有辅助文件时结果不变（§8 C1、C8、C10）。
- `local_deployment_residue_absent` 多一个候选模式：调用方为 full_verify `:4558`、commit_deploy `:4717`、deploy 恢复 `:5601` / `:5620`、status `:6764`；`configured_local_resources_absent` 加同一模式，影响 rollback 的未部署 no-op 判定、status 的孤儿判定与 deploy 前的碰撞检查（`:2163`）；因 rollback 会删除该残留，正常流程下不会触发，只有用户手工制造或旧版本留下时才判孤儿。正常情况下该模式不存在（§8 C1、C11）。
- `remove_active_local_artifacts` 多删一类文件：调用方为 rollback 第 6 步（`:5388`）与 deploy 恢复的 `cleanup_incomplete_deploy`（`:5647`）；后者多删一个本链残留无副作用。非 600 的同名文件会让它 die（与现有 node.txt 的处理一致，此时远端可能已拆除，重跑 rollback 前需人工处理该文件）。
- 直连 in_progress 恢复后置 `CHANGED_PARAMS=1`：原来恢复 reparam 成功后不提示重新导入与 rebaseline，现在会提示（§8 D5）。

反向：

- 出口机上同一目录的其它文件：`<id>.owner.env`、`<id>.exit.json` 不被轮换改动以外的路径触碰；其它链的文件名带各自 CHAIN_ID，不冲突。
- 中转机：不连中转、不改中转文件；中转转发目标（出口 IP:端口）不变，在途连接只在出口机重启时断开一次。
- `multi_chain_client.sh`：只读 `node.txt`，轮换后它的 `verify` 用新凭据握手；已 render 的聚合产物仍是旧凭据，需要重新 render（文档提示，§8 C9）。
- 部署后 managed 白名单：nft 规则写在 unit 的 ExecStartPre 里，重启时按原样重建（unit 不变）。

运行时：

- 链式轮换期间出口机重启一次 sing-box（中断 1-3 秒）；重启失败自动恢复旧配置。
- 没有新常驻进程；直连订阅 payload 增加约 2 KB。
- 部署形态：直连 Debian / Ubuntu（systemd ≥ 240）不变；链式出口机需要 awk、sha256sum、systemctl（deploy 预检已要求）。

## 8. 回归测试

在本机临时 Lima Ubuntu 虚拟机上执行（直连 1 台、链式中转与出口各 1 台），测完删除 Lima。凡写“重跑”的用例，重跑时一律不带测试变量（`setup_direct.sh:356-357` 每次启动临时单元都会重新传 `OWNEXIT_TEST_DIRECT_*`）。

| 编号 | 用例 | 判据 |
| ---- | ---- | ---- |
| D1 | 新装直连 | 订阅目录有 `sing-box.json`；本机 `sing-box check -c`（缓存的 darwin 包）通过；`curl` 拉回与本地一致；根路径仍为空 |
| D2 | 已部署直连加 `--sni` | UUID / 公钥 / short id 不变，SNI 改变（原 reparam 行为） |
| D3 | `--rotate-keys` | UUID / 公钥 / short id 全变，端口 / SNI / TOKEN 不变；用新 `sing-box.json` 在本机起 sing-box 经 mixed 端口 `curl` 出口 IP = VPS IP；旧凭据握手失败 |
| D4 | `--rotate-keys --rotate-token` | 凭据与 TOKEN 都变，旧 TOKEN 目录被删除 |
| D5 | 轮换在 RESTART 步被打断（`OWNEXIT_TEST_DIRECT_PAUSE_AT=RESTART` 后杀掉临时单元），带 `--rotate-keys` 重跑 | 恢复后服务 active；凭据只轮换一次（与暂停时线上 `client.env` 的 UUID 相同）；订阅与服务器 `client.env` 一致；输出“重新导入”提示 |
| D5b | 同 D5 中断后不带参数重跑 | 恢复完成，输出“重新导入”提示（`CHANGED_PARAMS=1`） |
| D5c | 轮换在 CHECK 步注入失败并在回滚前暂停（`FAIL_AT=CHECK` + `PAUSE_AT=ROLLBACK`，杀掉临时单元），带 `--rotate-keys` 重跑 | 恢复结果 `rolled-back`，随后本次再轮换一次并成功；最终 UUID 与轮换前不同 |
| D6 | 轮换在 CHECK 步注入失败（`OWNEXIT_TEST_DIRECT_FAIL_AT=CHECK`） | 结果 `rolled-back`，凭据与轮换前一致，服务 active |
| D7 | `--migrate --rotate-keys`、`--uninstall --rotate-keys` | 退出 2，服务器无改动 |
| D8 | 新装时加 `--rotate-keys` | 提示忽略，正常新装 |
| C1 | 链 deploy 后 `rotate-keys` | `rotate=done result=fresh`；state 中 UUID / 公钥 / short id / `EXIT_EXIT_SHA256` / `NODE_SHA256` 变化，其余字段不变；出口机无 `<id>.rotate.*`；`verify` 通过；`status` healthy |
| C2 | `OWNEXIT_TEST_ROTATE_STOP_AFTER=stage` 后 `verify`，再重跑 | `verify` 失败（150）；重跑 `result=resumed`，`verify` 通过 |
| C3 | `STOP_AFTER=swap` 后重跑 | `result=already`；node.txt 与线上凭据一致；`verify` 通过 |
| C4 | `STOP_AFTER=node`、`STOP_AFTER=state` 后重跑 | 分别 `already`、`resumed-after-commit`；后者 UUID 与中断前提交的一致（不再轮换）；最终 `verify` 通过 |
| C4b | `STOP_AFTER=swap` 后，带 `BREAK_PORT=<被占用端口>` 重跑 | 退出 1，信息含 195；线上恢复旧配置，辅助文件已删，`verify` 通过 |
| C5 | 手工改出口机配置（加空格）后 `rotate-keys` | 退出 1，信息含 193；出口机文件未变 |
| C6 | 出口机先用 `nc -l` 占住一个端口，`OWNEXIT_TEST_ROTATE_BREAK_PORT=<该端口>` 后 `rotate-keys` | 退出 1，信息含 195；线上恢复旧配置，`verify` 通过 |
| C7 | 配置里改 `REALITY_SERVER_NAME` 后 `rotate-keys` | 退出 2，远端无改动 |
| C8 | 轮换后 `rollback` | 成功；出口机 `/etc/ownexit-chain` 下无本链文件 |
| C9 | 轮换后 `multi_chain_client.sh --chains <id> verify` | 通过（使用新 node.txt） |
| C10 | `STOP_AFTER=stage` 后 `status`、`rollback` | `status` 输出 `reason=rotate-pending next=run-rotate-keys`；`rollback` 退出 6 并提示重跑 rotate-keys，远端未拆 |
| C11 | 本机伪造 `${CHAIN_STATE_DIR}/.node.txt.rotate.x.tmp`（600）后 `rollback` | rollback 成功并删除该文件；随后 `status` 为 `not_deployed`，再 `deploy` 通过 |
| C12 | 本机伪造同名残留后直接 `rotate-keys` | 开头清理残留，轮换成功，`verify` 通过 |
| S1 | CI | lint、shellcheck、help 冒烟、隐私扫描通过 |

## 9. 日志 / 观测点

- 直连：`[*] 改参数：… 凭据=重新生成` 一行；服务器日志 `[vps]` 中 `STEP=WRITE … ROTATE=1`；结果行 `OP=reparam 结果=ok|fail reason=…`。
- 链式：`[chain][rotate-keys] INFO [rotate] exit=<fresh|resumed|already> new_exit_sha256=<前 12 位>`、`[rotate] node published`、`[rotate] state committed audit=<路径>`、`[rotate] remote cleanup done`、最后 `rotate-keys 通过；chain=<id> result=<…> elapsed=<秒>s`；失败时 `die` 信息带远端码与中文原因。
- 观测命令：直连 `ownexit subctl status`、`ownexit subctl log`；链式 `verify` / `status`，出口机 `ls /etc/ownexit-chain/<id>.rotate.*` 应为空。
