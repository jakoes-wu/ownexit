# 让指定 IP 不走 Clash Verge 的代理

[English](clash-direct-ips.en.md) | **简体中文**

本机开着 Clash Verge（尤其是 TUN 模式）时，连 VPS、中转机、出口机的 SSH 也会被它接管：可能经代理节点绕一圈，也可能被代理切换中途断开。部署、`verify`、`migrate-exit` 这类命令一路都靠 SSH，断开后会以退出码 3 停下或留下待收尾的步骤。最省事的办法是让这几台服务器的 IP 直接连出去，不经过 Clash。

本文在 Clash Verge Rev 2.5.7（mihomo 内核，macOS，TUN 开启）上实测通过。其它版本请按第 4 节逐项核对。

## 1. 先看用的是哪种模式

| 模式 | 规则是否生效 | 做法 |
| ---- | ---- | ---- |
| 规则模式 | 生效 | 加直连规则即可（第 3 节的规则部分） |
| 全局模式 | 不生效：所有经过 Clash 的连接都交给 GLOBAL 组 | 只能让这些 IP 不进 TUN（第 3 节的 TUN 排除部分） |

全局模式下，“连接”页的链路显示为 `GLOBAL / <节点名>`，这时加再多直连规则也没用。下面的脚本把两种做法写在一起，两种模式都适用。

## 2. 备份

全局扩展脚本在：

```text
~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/Script.js
```

改之前先备份：

```bash
cd ~/Library/Application\ Support/io.github.clash-verge-rev.clash-verge-rev/profiles
cp Script.js Script.js.bak.$(date +%Y%m%d_%H%M%S)
```

Linux / WSL：路径一般在 `~/.config/clash-verge-rev/profiles/Script.js`（按你的实际安装位置确认），备份命令把 `cd` 的路径换掉即可。

## 3. 修改全局扩展脚本

可以直接编辑上面的文件，也可以在 Clash Verge 的“订阅”页打开“全局扩展脚本”编辑。

在 `function main` 之前加：

```js
// ----------- DIRECT-IPS BEGIN -----------
// 这些 IP 一律直连、不走代理（例如 SSH 登录服务器）。
// 回滚：把 DIRECT_IPS_ENABLED 改成 false，重新激活订阅并重开 TUN。
const DIRECT_IPS_ENABLED = true;
const DIRECT_IPS = ["203.0.113.10", "203.0.113.20"];
// ----------- DIRECT-IPS END -----------
```

在 `main` 里的 `return config;` 之前加：

```js
  // ----------- DIRECT-IPS BEGIN -----------
  if (DIRECT_IPS_ENABLED) {
    // 规则模式：直连规则放在最前面（规则自上而下匹配）；no-resolve 只按目标 IP 匹配，不做 DNS 解析。
    // IPv6 用 IP-CIDR6 + /128，IPv4 用 IP-CIDR + /32。
    const ruleOf = (ip) => ip.includes(":")
      ? `IP-CIDR6,${ip}/128,DIRECT,no-resolve`
      : `IP-CIDR,${ip}/32,DIRECT,no-resolve`;
    const directRules = DIRECT_IPS.map(ruleOf);
    config.rules = directRules.concat((config.rules || []).filter((r) => !directRules.includes(r)));
    // 全局模式不看规则：让这些 IP 根本不进 TUN，系统直接走物理网卡。
    config.tun = config.tun || {};
    const excludes = DIRECT_IPS.map((ip) => ip.includes(":") ? `${ip}/128` : `${ip}/32`);
    config.tun["route-exclude-address"] = (config.tun["route-exclude-address"] || [])
      .filter((a) => !excludes.includes(a))
      .concat(excludes);
  }
  // ----------- DIRECT-IPS END -----------
```

把 `DIRECT_IPS` 换成你自己服务器的 IP：直连 VPS、中转机、出口机都可以放进去，IPv6 地址也能直接填（脚本会自动用 `/128` 和 `IP-CIDR6`）。要按网段放行，把 `/32` 改成对应的前缀长度（IPv6 从 `/128` 起）。

原来没有全局扩展脚本时，整个文件写成：

```js
// （上面两段里 main 之前的那段）
function main(config, profileName) {
  // （上面 main 里的那段）
  return config;
}
```

脚本先去掉同名项再追加，重复执行不会产生重复条目。

## 4. 生效与核对

1. 在“订阅”页重新激活当前订阅（或右键刷新），脚本会重新执行。
2. 在“设置”页把 TUN 模式关掉再打开，让系统路由按新配置重建。
3. 核对系统路由（以 `203.0.113.10` 为例）：

```bash
route -n get 203.0.113.10 | grep interface   # 应显示 en0 一类的物理网卡，而不是 utun 开头的 TUN 网卡
route -n get 1.1.1.1 | grep interface        # 对照：其它地址仍走 utun
```

Linux / WSL：用 `ip route get 203.0.113.10`，看 `dev` 后面是物理网卡（如 `eth0`）而不是 tun 设备。

4. 再 SSH 一次，到 Clash Verge 的“连接”页搜这个 IP：TUN 排除生效的话搜不到；如果看到一条 DIRECT 记录，那是规则模式的兜底，也算正常。只有全局模式下还走了代理节点，才算没生效。

第 3 步如果仍显示 utun，可能是你的 Clash Verge 版本用自己的 TUN 设置覆盖了脚本里的 `route-exclude-address`。这时：
- 规则模式下，直连规则照样生效；
- 全局模式下，改为在 Clash Verge 自己的 TUN 设置里排除这些地址（如果你的版本提供这一项），或者部署期间关闭 TUN。

## 5. 回滚

任选一种，改完都要重新激活订阅并重开 TUN：

- 把 `DIRECT_IPS_ENABLED` 改成 `false`：直连规则与 TUN 排除一起失效；
- 恢复备份：`cp Script.js.bak.<时间戳> Script.js`；
- 删除两处 `DIRECT-IPS BEGIN` 到 `END` 之间的内容。

## 6. 注意

- **系统代理**：Clash Verge 同时开着系统代理时，浏览器这类会读系统代理的程序，访问这些 IP 时仍会交给 Clash，全局模式下会走代理节点。SSH、curl 这类命令行程序默认不读系统代理，除非终端里设置了 `http_proxy` / `https_proxy`，这种情况下用 `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY <命令>` 临时去掉。
- **节点服务器本身**：某个 IP 同时是 Clash 里某个节点的服务器地址时也可以加：到它的连接直接走物理网卡，而客户端连节点本来就要直接连到它，节点照常可用。
- **哪些 IP 经过了 TUN**：`ownexit doctor` 会指出本机到哪些服务器 IP 的路由经过 TUN，可以拿来核对是否漏加。
