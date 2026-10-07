# Keeping specific IPs out of Clash Verge's proxy

**English** | [简体中文](clash-direct-ips.md)

When Clash Verge is running on your computer (especially in TUN mode), SSH to the VPS, relay and exit is taken over by it too: it may detour through a proxy node, or be cut off halfway when the proxy switches. Commands such as deploy, `verify` and `migrate-exit` depend on SSH throughout; when it drops they stop with exit code 3 or leave steps to finish later. The simplest fix is to let these servers' IPs go out directly, bypassing Clash.

Tested on Clash Verge Rev 2.5.7 (mihomo core, macOS, TUN on). For other versions, check each item in section 4.

## 1. Check which mode you use

| Mode | Do rules apply? | What to do |
| ---- | ---- | ---- |
| Rule mode | Yes | Add direct rules (the rules part of section 3) |
| Global mode | No: every connection through Clash goes to the GLOBAL group | The only option is to keep these IPs out of TUN (the TUN exclusion part of section 3) |

In global mode the Connections page shows the chain as `GLOBAL / <node name>`, and no number of direct rules will help. The script below combines both approaches, so it works in either mode.

## 2. Back up

The global extension script is at:

```text
~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/Script.js
```

Back it up before changing it:

```bash
cd ~/Library/Application\ Support/io.github.clash-verge-rev.clash-verge-rev/profiles
cp Script.js Script.js.bak.$(date +%Y%m%d_%H%M%S)
```

## 3. Edit the global extension script

Edit the file above directly, or open "Global Extend Script" on Clash Verge's Profiles page.

Before `function main`, add:

```js
// ----------- DIRECT-IPS BEGIN -----------
// These IPs always go direct, never through the proxy (for example SSH to the servers).
// Roll back: set DIRECT_IPS_ENABLED to false, re-activate the profile and turn TUN off and on.
const DIRECT_IPS_ENABLED = true;
const DIRECT_IPS = ["203.0.113.10", "203.0.113.20"];
// ----------- DIRECT-IPS END -----------
```

Inside `main`, before `return config;`, add:

```js
  // ----------- DIRECT-IPS BEGIN -----------
  if (DIRECT_IPS_ENABLED) {
    // Rule mode: put the direct rules first (rules match top to bottom); no-resolve matches the target IP only, without DNS.
    const directRules = DIRECT_IPS.map((ip) => `IP-CIDR,${ip}/32,DIRECT,no-resolve`);
    config.rules = directRules.concat((config.rules || []).filter((r) => !directRules.includes(r)));
    // Global mode ignores rules: keep these IPs out of TUN entirely so the system uses the physical interface.
    config.tun = config.tun || {};
    const excludes = DIRECT_IPS.map((ip) => `${ip}/32`);
    config.tun["route-exclude-address"] = (config.tun["route-exclude-address"] || [])
      .filter((a) => !excludes.includes(a))
      .concat(excludes);
  }
  // ----------- DIRECT-IPS END -----------
```

Replace `DIRECT_IPS` with your own servers' IPs: the direct VPS, the relay and the exit can all go in. To allow a whole range, change `/32` to the matching prefix length.

If you had no global extension script before, write the whole file as:

```js
// (the part above that goes before main)
function main(config, profileName) {
  // (the part above that goes inside main)
  return config;
}
```

The script removes existing entries before appending, so running it repeatedly creates no duplicates.

## 4. Apply and check

1. On the Profiles page, re-activate the current profile (or right-click → refresh) so the script runs again.
2. On the Settings page, turn TUN mode off and on so the system routes are rebuilt from the new configuration.
3. Check the system route (using `203.0.113.10` as an example):

```bash
route -n get 203.0.113.10 | grep interface   # should show a physical interface such as en0, not a TUN interface starting with utun
route -n get 1.1.1.1 | grep interface        # for comparison: other addresses still use utun
```

4. SSH once more: the IP should no longer appear on Clash Verge's Connections page. That means the connection bypassed Clash, which is what you want.

If step 3 still shows utun, your Clash Verge version may override the script's `route-exclude-address` with its own TUN settings. In that case:
- in rule mode, the direct rules still apply;
- in global mode, exclude these addresses in Clash Verge's own TUN settings instead (if your version offers that), or turn TUN off while deploying.

## 5. Roll back

Pick one; after any of them, re-activate the profile and turn TUN off and on:

- Set `DIRECT_IPS_ENABLED` to `false`: the direct rules and the TUN exclusion stop applying together;
- Restore the backup: `cp Script.js.bak.<timestamp> Script.js`;
- Delete everything between the two `DIRECT-IPS BEGIN` and `END` markers.

## 6. Notes

- **System proxy**: if Clash Verge also has the system proxy on, programs that read it (such as browsers) still hand connections to these IPs to Clash, and in global mode they go through a proxy node. Command-line programs such as SSH and curl do not read the system proxy by default, unless `http_proxy` / `https_proxy` is set in the terminal; in that case drop them for one command with `env -u http_proxy -u https_proxy <command>`.
- **Node servers themselves**: an IP that is also the server address of a Clash node can be added too: connections to it then use the physical interface, and since the client connects to the node directly anyway, the node keeps working.
- **Which IPs go through TUN**: `ownexit doctor` lists the server IPs whose routes from your computer go through TUN, so you can check you have not missed any.
