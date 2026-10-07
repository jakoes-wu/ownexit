# Direct deployment guide

**English** | [简体中文](direct.md)

Turn a VPS abroad into your own fixed exit: clients connect straight to the VPS, and websites see the VPS's IP. Everything runs on your own computer; you never have to log in to the server and type commands.

> The scripts currently print their progress and messages in Chinese. Where this guide quotes such a message, the original text is kept with an English gloss.

## 1. How it works

```text
Your devices (Clash Verge / mihomo / Shadowrocket / Android clients)
   │  VLESS-Reality: looks like ordinary HTTPS traffic
   ▼
Your VPS (sing-box)
   │  makes the request with this VPS's IP
   ▼
Target website
```

| Role | What it is | What you do |
| ---- | ---- | ---- |
| Server | The VPS you rent, running sing-box | Install it once with `setup_direct.sh`; it keeps running |
| Client | The proxy app on each device | Paste the subscription URL, pick the node, connect |
| Routing rules | Decide which traffic goes through the exit | By default mainland China traffic goes direct and the rest goes through the exit; switch the client to global mode if you want everything through the exit |

## 2. What you need

**One VPS.** When choosing, only these matter:

- OS: **Debian 12** or **Ubuntu 22.04 LTS** (the scripts support Debian / Ubuntu only).
- A **dedicated public IPv4** address, reachable as root over SSH with a password.
- Pick the region and route for how you will use it; if latency from mainland China matters, prefer routes optimised for it.
- Pay monthly at first, and commit longer only after the IP quality and route have proven stable.

For the full steps from choosing and ordering to installing the OS, see the [VPS guide](vps.en.md).

Once you have the machine, check its IP first: open `https://ipinfo.io/<your IP>` in a browser to see its owner and type, then look at its risk score with a tool such as Scamalytics. Replace it early if you are not happy with it.

**One computer** (macOS tested; Linux tested on Ubuntu 22.04) with:

- `git`, `ssh`, `curl`, `openssl` (built into macOS)
- A tool that types the password for you (used once, when setting up key login): ownexit installed with pipx ships the Python package pexpect, so nothing else is needed; when running the scripts from a git clone, either run `pip3 install pexpect` or install the system `expect` (macOS `brew install expect`, Debian / Ubuntu `sudo apt install expect`)
- `qrencode` (optional): shows the node QR code in the terminal; on macOS run `brew install qrencode`

## 3. Deploy

```sh
pipx install ownexit
ownexit direct up --host 203.0.113.7
```

Add `--port 2222` if SSH is not on port 22. The commands below are written for a git clone; with pipx, replace `./direct/setup_direct.sh` with `ownexit direct` — the subcommands and options are identical.

What happens:

1. **Key login**: the first run asks once for the VPS's root password (not echoed). You get up to 3 tries; after that everything uses a dedicated key stored in `~/.ssh/ownexit/`.
2. **System check, and the VPS is remembered**: later runs of `setup_direct.sh` (including day-to-day operations such as `status` and `sub stop`) no longer need `--host`.
3. **Enable BBR**, then **install sing-box**: the VPS downloads the pinned official sing-box release from GitHub and checks its SHA-256 (if the VPS cannot reach GitHub, your computer downloads it and uploads it), generates the Reality key, UUID and short id on the VPS, writes the `ownexit-direct` service and starts it. No questions are asked. The camouflage domain defaults to `www.amazon.com` and the proxy port is random in 20000–59999; pass `--sni <domain>` or `--proxy-port <port>` to choose your own.
   This step runs as a transient systemd job on the VPS: a dropped connection does not affect it, and if the VPS loses power, running the command again picks up where it stopped.
4. **Render the subscriptions and verify**: the node parameters are read back from the VPS, four subscription formats are rendered locally, uploaded to the VPS and served by a read-only subscription service, and then each item is checked. If `qrencode` is installed, the node QR code is printed in the terminal at the end.

At the end it prints one adaptive subscription URL, `.../sub`: paste that one URL into every client and the server returns the right format for each (Clash Verge / mihomo get `clash.yaml`, sing-box gets `sing-box.json`, other clients get a base64 node list). The four fixed-format URLs below still work; use them when the adaptive URL does not recognise your client:

| URL | For |
| ---- | ---- |
| `.../clash.yaml` | Clash Verge, mihomo, Clash Meta for Android |
| `.../shadowrocket.txt` | iPhone Shadowrocket, v2rayN / v2rayNG (base64 node list) |
| `.../sing-box.json` | The official sing-box clients (SFI / SFA / SFM, 1.12 or later) |
| `.../node.txt` | The plain `vless://` node link, for manual import into other clients or as a backup |

## 4. Import into clients

**Clash Verge (macOS / Windows / Linux)**

1. Download the installer for your system from the Releases of `clash-verge-rev/clash-verge-rev` on GitHub (Apple silicon: arm64 / aarch64). If macOS blocks the first launch, go to System Settings → Privacy & Security and click "Open Anyway".
2. On the Profiles page paste the Clash subscription URL → Import → click the profile card to select it.
3. On the Proxies page choose `ownexit-direct` in the `PROXY` group.
4. On the Settings page turn on the system proxy (turn on Tun mode if terminal commands should use the proxy too) and set the mode to Rule.

**iPhone Shadowrocket**: `+` at the top right → type Subscribe → paste the Shadowrocket subscription URL → save and update → pick the node → connect; allow adding the VPN configuration on the first connection.

**Official sing-box clients (iOS SFI / Android SFA / macOS SFM, 1.12 or later)**: Profiles → New → type Remote → paste the sing-box subscription URL → save and enable it. The profile has a tun inbound (used when the app turns on the VPN) and a mixed inbound on `127.0.0.1:7890`; mainland China domains and IPs go direct, everything else goes through the exit, and rule sets are downloaded through the proxy.

**v2rayN (Windows) / v2rayNG (Android)**: Subscription groups → Add → paste the Shadowrocket subscription URL (the same base64 node list) → update the subscription → pick the node.

**Android**: install Clash Meta for Android and create a profile with "Import from URL", pasting the Clash subscription URL; the sing-box or v2rayNG clients above also work. For clients that only accept node links, use the `vless://` link in `node.txt`.

**mihomo on the command line**:

```sh
mkdir -p ~/.config/mihomo
curl -L '<Clash subscription URL>' -o ~/.config/mihomo/config.yaml
mihomo -d ~/.config/mihomo
curl -x http://127.0.0.1:7890 https://ipinfo.io   # check from another terminal
```

**Default routing rules**: mainland China domains and IPs go direct; everything else goes through the `PROXY` group. To send all traffic through the exit, switch the client to Global mode.

## 5. Verify the exit

Once connected, open `https://ipinfo.io` in a browser: the IP shown should be your VPS's IP.

What `setup_direct.sh` has already checked:

| Layer | Checks |
| ---- | ---- |
| VPS host | The sing-box service is running and the proxy port is listening |
| Subscription service | The subscription service is running and its port is listening |
| Subscription content | The `clash.yaml` fetched from your computer is byte-identical to the locally rendered file; the adaptive URL is requested once with each of four client identifiers and returns the matching format; the root path, the service script and the TOKEN directory all return 404, so the subscription URL is not exposed |

You need to confirm the exit on the client side yourself.

## 6. Day-to-day maintenance

Add `--sub-ttl 30m` when deploying (for example `ownexit direct up --host <IP> --sub-ttl 30m`) and the subscription service turns itself off after 30 minutes; without it the service stays on until you run `sub stop` after importing. The timer only lasts for the current boot: after the VPS reboots, the subscription service starts again (it is enabled at boot) and stays on, so run `sub stop` or `sub start --ttl …` again.

```sh
./direct/setup_direct.sh status            # status of the proxy service and the subscription service
./direct/setup_direct.sh log               # last 100 lines of the proxy service log (log 300 for 300 lines)
./direct/setup_direct.sh qr                # show the node QR code in the terminal (needs qrencode)
./direct/setup_direct.sh sub stop          # turn the subscription service off once every device has imported (recommended default)
./direct/setup_direct.sh sub start         # turn it on briefly before importing on a new device, then sub stop
./direct/setup_direct.sh sub start --ttl 30m   # turn it on and have it turn off by itself after 30 minutes
./direct/setup_direct.sh login             # log in to this VPS with the key
./direct/setup_direct.sh rotate-token      # new subscription URL if you suspect the URL leaked
./direct/setup_direct.sh rotate-keys       # new UUID / Reality key / short id if you suspect the node credentials leaked
./direct/setup_direct.sh add-device phone      # give one device its own credentials and subscription URL
./direct/setup_direct.sh remove-device phone   # revoke that device; its subscription URL is deleted too
./direct/setup_direct.sh devices           # list devices and their subscription URLs
./direct/setup_direct.sh uninstall         # remove the proxy service and the subscription service from the VPS
./direct/doctor.sh                        # diagnose this computer and the servers, with a fix for each item (ownexit doctor)
./direct/doctor.sh --ip-check             # also check the exit IP from the VPS (AI services, streaming, common sites)
./direct/doctor.sh --scan-sni             # test candidate camouflage domains on the VPS one by one for real Reality use
```

- The subscription service is a plain-HTTP public port: keep it off and turn it on only while importing.
- The older spellings (`./direct/subctl …`, `--rotate-keys` / `--rotate-token` / `--add-device` / `--remove-device` / `--migrate` / `--uninstall`) still work throughout 1.x and print the new form; they may be removed in 2.0 at the earliest.
- Moving to another VPS: run `setup_direct.sh up --host <new IP>` against the new machine, then update the subscription in your clients. When several VPSes are remembered, `setup_direct.sh` without `--host` lists them and exits (day-to-day operations too).
- Changing the camouflage domain or proxy port: `setup_direct.sh up --sni <domain>` or `up --proxy-port <port>`; the UUID and keys stay the same, but clients must fetch the subscription again. Not every HTTPS site works as a camouflage domain: in tests `www.amazon.com` (the default) and `www.apple.com` work, while `www.microsoft.com` does not (the server rejects the client handshake). After changing the domain, confirm one device can still connect, and switch back if it cannot. Changing handshake parameters while you are using this tunnel locks you out: switch to another network first.
- Several devices: `add-device <name>` gives one device its own UUID and set of subscription URLs (listed separately in the output; give them only to that device), and `remove-device <name>` revokes it — it disconnects immediately and its subscription URLs are deleted, while other devices are unaffected. The existing credentials are the `default` device, whose subscription URLs stay the same. Device names may contain lowercase letters, digits and `-`, up to 32 characters, and each VPS holds at most 32 devices (including default). `ownexit direct devices` lists devices and their subscription URLs. If you switch computers and the new one has no subscription record for a device, running `setup_direct.sh` once regenerates it; device subscription directories created on the old computer are not deleted automatically. Once you have devices, keep this computer on 0.7.0 or later: older versions drop devices when changing parameters.
- Replacing credentials: `setup_direct.sh rotate-keys` regenerates the UUID, Reality key pair and short id of every device on the VPS, keeping the port, SNI and subscription URLs; if the new configuration fails to start, the old one is restored automatically. Old nodes stop working at once, so every device must fetch the subscription again. It can be combined with `rotate-token` (`rotate-keys rotate-token`) to replace the subscription URL at the same time, but not with `migrate` / `uninstall` (migrate an old 233boy install first, then rotate). If interrupted, just rerun the same command; anything already replaced is not replaced twice.
- Uninstalling: `setup_direct.sh uninstall` removes the `ownexit-direct` service, the subscription service and their directories from the VPS, and keeps the SSH key login, the remembered target, the BBR setting and any migration backup.
- If this VPS is also the relay of a relay chain, run `ownexit chain --id <name> rebaseline` as prompted after a fresh direct install, migration, parameter change or uninstall.
- Important files all live outside the repository on your computer: keys in `~/.ssh/ownexit/`, target configuration in `~/.config/ownexit/direct/`, subscription TOKENs in `~/.local/state/ownexit/direct/`.

## 7. Troubleshooting

Run `ownexit doctor` first: it checks local dependencies, proxy environment variables, directory permissions, whether the route to the VPS goes through a proxy TUN, and the service, subscription and BBR on the VPS, with a fix for each item. `--ip-check` sends requests to each service from the VPS to judge whether the exit IP works with ChatGPT / Claude / Gemini and Netflix / YouTube Premium / Disney+. The results are for reference only (services change their rules at any time; anything it cannot tell is reported as undetermined).

| Problem | Likely cause | Fix |
| ---- | ---- | ---- |
| `reason=bad-password` | The password was wrong 3 times | Check or reset the root password in your provider's console |
| `reason=password-disabled` | The server has password login turned off | Turn password login on in the console, or add the matching `.pub` from `~/.ssh/ownexit/` to the VPS's `~/.ssh/authorized_keys` yourself |
| `reason=unreachable` | Wrong IP or SSH port, or the security group blocks it | Check the IP and port; if SSH itself cannot connect, investigate from the provider's web console (VNC) |
| The public key was pushed but key login still fails | The provider's image turned off public key authentication in sshd | `connect_to.sh` changes `PubkeyAuthentication no` back to `yes` and restarts sshd automatically (needs root); if it still fails, change it by hand in the web console |
| Clients connect but nothing loads | The proxy port is blocked, or the SNI domain is unreachable | Check the provider's security group; run `setup_direct.sh log` for the log, and if needed change the SNI or port with `up --sni` / `up --proxy-port` |
| Message "服务器上是用 233boy 脚本装的旧版" (the server runs the old 233boy-based install; exit code 2) | This VPS was set up by an old ownexit version (233boy script) | Run `setup_direct.sh migrate`; see section 9 |
| Message "上次未完成的操作恢复失败" (recovering the unfinished operation failed) | The VPS lost power during a migration or similar, and the new service would not start during recovery | Check `setup_direct.sh log` as the message says; migration backups are in `/var/backups/ownexit-direct/` |
| Mainland China sites also go through the proxy | The client's GeoIP / GeoSite databases have not finished downloading | Update the databases once by hand in the client settings |
| Port tests connect instantly or contradict each other | TUN is on locally and every connection is taken over by the local proxy | Turn TUN off before testing, or keep the VPS's IP out of Clash (see [Keeping specific IPs out of Clash Verge's proxy](clash-direct-ips.en.md)) |
| SSH prints `setlocale: LC_ALL: cannot change locale` | Your computer forwards a Chinese locale to the VPS | Harmless; the scripts in this repository force `C.UTF-8` |
| The node connects but is slow | BBR is not active, or the route is congested at peak times | Check that BBR is `[+]` in the `setup_direct.sh` output; watch peak hours and change routes if needed |

## 8. Security notes

- Never put real IPs or passwords in any file you commit or share. The scripts in this repository have no "edit the IP at the top of the script" usage and no `--password` option.
- Use a strong root password; once key login works, consider turning off password login on the VPS (confirm key login first, and keep the provider's web console as a fallback).
- sing-box is installed from the pinned official release downloaded by the VPS, with the SHA-256 of both the archive and the binary hard-coded in the scripts; the Reality private key is generated on the VPS and never leaves it.
- Follow the laws of your jurisdiction and your provider's terms.

## 9. Migrating from the old version (233boy)

ownexit 0.3 and earlier installed sing-box with the third-party script 233boy/sing-box. When the current version finds such an install it stops (exit code 2) without changing anything on the server. Run once:

```sh
./direct/setup_direct.sh migrate
```

It will:

1. Check whether the old install can be migrated: 233boy installed exactly one VLESS-REALITY node and the old service is running. If several protocols are installed, it refuses and explains why.
2. Keep the existing UUID, Reality key, port, SNI and short id, and write the `ownexit-direct` service.
3. Back up the 233boy files to `/var/backups/ownexit-direct/233boy-<time>.tar.gz` (it contains the old private key; delete it yourself once you are sure you will not roll back).
4. Stop the old service and start the new one (about 1–3 seconds of proxy downtime); if the new service fails to start, it switches back to the old one automatically.
5. Once the new service is confirmed healthy, delete the 233boy files (including the `sb` command and the two alias lines in `.bashrc`).

Clients and subscription URLs need no changes. After migrating, what you used to do with `sb` is now `setup_direct.sh log`, `setup_direct.sh qr` and `setup_direct.sh up --sni / --proxy-port`.
