# ownexit

**English** | [简体中文](https://github.com/jakoes-wu/ownexit/blob/main/README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/jakoes-wu/ownexit)](https://github.com/jakoes-wu/ownexit/releases)
[![CI](https://github.com/jakoes-wu/ownexit/actions/workflows/ci.yml/badge.svg)](https://github.com/jakoes-wu/ownexit/actions/workflows/ci.yml)
[![PyPI](https://img.shields.io/pypi/v/ownexit)](https://pypi.org/project/ownexit/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](https://github.com/jakoes-wu/ownexit/blob/main/LICENSE)
![bash](https://img.shields.io/badge/bash-3.2%2B-blue)
![platform](https://img.shields.io/badge/control-macOS%20%7C%20Linux-lightgrey)

Turn a VPS you rent into your own fixed exit IP — connect directly, or through a relay — set up from your laptop with one command.

```sh
pipx install ownexit
ownexit direct up --host 203.0.113.7   # asks for the VPS root password once
```

When it finishes, paste the printed subscription URL into Clash Verge or Shadowrocket. That's it.

![ownexit demo: set up a relay + exit chain with two IPs](https://raw.githubusercontent.com/jakoes-wu/ownexit/main/docs/assets/demo.gif)

<sub>The IPs in the demo are examples.</sub>

- **One command, from your laptop.** No logging into the server to type commands.
- **A fixed exit that is yours.** Your traffic leaves from your own VPS; the IP is not shared with strangers.
- **Still works when the IP gets blocked.** Add a relay server in front; the exit IP and your client settings stay the same.
- **Undoable.** The relay setup rolls back both servers to how they were, and the relay never holds any keys.

## How it works

**Direct** — your devices connect straight to your VPS:

```text
phone / laptop ──VLESS-Reality──▶ your VPS (sing-box) ──▶ websites see your VPS's IP
```

**Relay** — for when the VPS IP is blocked from where you are. The relay only forwards TCP bytes; it cannot read your traffic and stores no keys:

```text
phone / laptop ──VLESS-Reality──▶ relay (systemd-socket-proxyd) ──▶ exit VPS (sing-box) ──▶ websites see the exit's IP
```

Everything runs on your laptop and talks to the servers over SSH. Configuration, keys and state stay on your laptop, outside this repository.

## Prerequisites

**Servers.** One VPS for direct, two for relay, running Debian 12 or Ubuntu 22.04 and reachable as root over SSH with a password (used once). Never bought a VPS? Follow the step-by-step guide: [docs/manual/vps.en.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/manual/vps.en.md) — choosing, ordering, installing the OS, firewalls.

**Your computer.**

| | Direct | Relay |
| ---- | ---- | ---- |
| Operating system | macOS or Linux | macOS or Linux (WSL counts as Linux) |
| Needed | Python 3.8+ with `pipx`, `ssh`, `curl`, `openssl` | same |
| Optional | `qrencode`, to show the node as a QR code | `qrencode`, for QR codes in `ownexit multi render` |

Install what is missing:

```sh
# macOS (with Homebrew, https://brew.sh); ssh, curl and openssl come with macOS
brew install pipx
pipx ensurepath            # then open a new terminal

# Debian / Ubuntu / WSL
sudo apt update
sudo apt install -y pipx openssh-client curl openssl
pipx ensurepath            # then open a new terminal
```

The first time it sets up key login on a server it types the root password for you, using the Python package pexpect, which pipx installs along with ownexit. If you run the scripts from a git clone, either `pip3 install pexpect` or install the system `expect` (macOS `brew install expect`, Debian / Ubuntu `sudo apt install expect`).

Windows itself is not supported; use WSL. If your computer runs a proxy in TUN mode (Clash and similar), turn it off while deploying — see [Supported platforms](#supported-platforms).

## Install

```sh
brew install jakoes-wu/tap/ownexit   # macOS (Homebrew); also installs qrencode for QR codes
pipx install ownexit                 # elsewhere, or without Homebrew; pip install --user ownexit also works
ownexit                              # no arguments in a terminal: pick a language, then a guided setup
```

Pick one of the two (it is the same package).

Output language: the scripts print in Chinese when the system language (`LC_ALL` / `LC_MESSAGES` / `LANG`) starts with `zh`, otherwise in English; `OWNEXIT_LANG=zh` or `OWNEXIT_LANG=en` overrides it, and the language picked in the guided setup is used for the whole run.

`ownexit` is a thin wrapper around the bundled bash scripts, so you can also run them straight from a clone — the commands map one to one:

| `ownexit …` | script in a clone |
| ---- | ---- |
| `ownexit direct` | `direct/setup_direct.sh` |
| `ownexit subctl` (deprecated, use `ownexit direct sub …` / `status` / `log` …) | `direct/subctl` |
| `ownexit connect` | `direct/connect_to.sh` |
| `ownexit chain` | `chain/setup_chain.sh` |
| `ownexit multi` | `chain/multi_chain_client.sh` |

```sh
# needs git
git clone https://github.com/jakoes-wu/ownexit && cd ownexit
./direct/setup_direct.sh --host 203.0.113.7
```

When run from a clone, the chain scripts additionally refuse configuration files that live inside the clone, so real IPs and keys cannot be committed by accident.

## Quick start: direct

1. **Deploy**

   ```sh
   ownexit direct up --host 203.0.113.7       # add --port 2222 if SSH is not on 22
   ```

   It sets up key login, checks the system, enables BBR, has the server download a pinned official sing-box release and check its SHA-256, generates the Reality keys on the server, renders subscriptions, uploads them and verifies every layer. No questions asked. Pass `--sni <domain>` or `--proxy-port <port>` to choose them yourself; run it again with new values to change them later (the UUID and keys stay the same).

2. **Import on your devices** — the script prints one subscription URL ending in `/sub`; paste that same URL into every client. The server returns the right format for each one (Clash Verge / mihomo get a Clash config, sing-box gets a sing-box config, Shadowrocket, v2rayN and others get a node list). Phones can also scan the QR code in the terminal. If your client isn't recognised, use one of the fixed-format URLs:

   | URL | For |
   | ---- | ---- |
   | `…/clash.yaml` | Clash Verge, mihomo, Clash Meta for Android |
   | `…/shadowrocket.txt` | Shadowrocket on iPhone, v2rayN / v2rayNG |
   | `…/sing-box.json` | sing-box apps (SFI / SFA / SFM, 1.12 or later) |
   | `…/node.txt` | the plain `vless://` link, for anything else |

3. **Check and close up** — open `https://ipinfo.io` on a device: it should show your VPS's IP. Then turn the subscription endpoint off until you need it again:

   ```sh
   ownexit direct sub stop
   ```

The VPS is remembered, so later runs need no `--host`: `ownexit direct up` to redeploy, `ownexit direct sub start|stop`, `ownexit direct status|log|qr`, `ownexit direct uninstall` to remove it. `ownexit direct rotate-keys` replaces the UUIDs, Reality key pair and short id on the server (every device must re-import the subscription). `ownexit direct add-device phone` gives one device its own UUID and subscription URLs; `ownexit direct remove-device phone` revokes it without touching the others; `ownexit direct devices` lists them. (The older spellings `ownexit subctl …` and `ownexit direct --rotate-keys` etc. still work in 1.x and print the new form.)

**Set up with the 233boy script by an earlier version?** Run `ownexit direct migrate` once. It keeps the existing UUID, keys, port and SNI, switches to ownexit's own service and removes the 233boy files (backed up first) — your clients and subscription URLs keep working.

Step-by-step guide: [docs/manual/direct.en.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/manual/direct.en.md).

## Quick start: relay

1. **One command**

   ```sh
   ownexit chain up --relay 203.0.113.10 --exit 203.0.113.20
   ```

   It sets up key login on both servers (one password prompt each), detects the exit IP and asks you to confirm it, writes `~/.config/ownexit/chains/main.env`, then deploys: both servers download the pinned sing-box release from GitHub themselves (falling back to an upload from your computer), the exit first, then the relay, as one transaction, and the exit IP is verified three different ways. If anything fails, it cleans up; if your network drops halfway, run the same `chain up` again and it converges. By default an nftables rule on the exit lets only the relay reach its Reality port (`--exit-source-filter managed`); use `provider` if your provider's security group already does that, or `none` to skip it. Prefer two steps? `chain init …` writes the config, `chain deploy` deploys it.

2. **Import**: the node QR code and `vless://` link are printed at the end (any time later: `ownexit chain qr`). Open `https://ipinfo.io` on the device; it should show the exit's IP.

Day to day (no `--id` needed while you have a single chain): `ownexit chain status | verify | conns | rollback`. `ownexit chain rotate-keys` replaces the exit's UUIDs, Reality key pair and short id in place (relay, ports and deployment stay; re-import afterwards). `add-device <name>` / `remove-device <name>` / `list-devices` manage per-device UUIDs; `qr --device <name>` shows one device's QR code. With several chains add `--id <name>`. If the relay also runs a direct exit and you migrate, reconfigure or uninstall that direct exit, run `ownexit chain rebaseline` afterwards so the chain re-records what it protects (the direct script reminds you). Relay blocked? Deploy a second relay with `init --id backup …` and combine both with `multi_chain_client.sh` — clients switch automatically. Full reference: [chain/README.en.md](https://github.com/jakoes-wu/ownexit/blob/main/chain/README.en.md); guide: [docs/manual/chain.en.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/manual/chain.en.md).

## Supported platforms

| | Direct | Relay |
| ---- | ---- | ---- |
| Control machine | macOS (tested); Linux (tested on Ubuntu 22.04); Windows not supported — try WSL at your own risk | macOS on Apple silicon (tested), macOS on Intel (untested), Linux amd64 (tested on Ubuntu 20.04), Linux arm64 and WSL (untested) |
| Server OS | Debian, Ubuntu (systemd 240 or later) | Linux with systemd; the relay needs `systemd-socket-proxyd`; no nftables tables other than ownexit's own, UFW inactive |
| Server CPU | amd64 (tested on cloud servers) or arm64 (tested on Ubuntu 22.04 arm64 virtual machines) | amd64 (tested on cloud servers) or arm64 (tested on Ubuntu 22.04 arm64 virtual machines); relay and exit must match |
| Clients | Clash Verge, mihomo, Shadowrocket tested; sing-box and v2rayN subscriptions provided; any VLESS-Reality client via `vless://` | Clash Verge, mihomo, Shadowrocket tested; any VLESS-Reality client via `vless://` |

If your computer runs a proxy in TUN mode (Clash and similar), SSH to the servers gets cut off halfway through a deploy. Deploy commands now check the route to each server first and refuse when it goes through the TUN, telling you what to do: turn TUN off, or route the server IPs through the physical interface (Clash Verge: [docs/manual/clash-direct-ips.en.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/manual/clash-direct-ips.en.md)); pass `--allow-tun` to proceed anyway.

## Stability

From 1.0.0 the command-line interface, configuration keys and on-disk formats are frozen for the whole 1.x series: releases only add things, nothing is renamed or removed, and existing deployments keep working after an upgrade without redeploying or re-importing clients. Breaking changes are reserved for 2.0 and will come with a migration. The frozen surface is listed in [docs/reference/commands.en.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/reference/commands.en.md) and [docs/reference/files.en.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/reference/files.en.md); the rules are in [docs/reference/compatibility.en.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/reference/compatibility.en.md). The design records under `docs/feature/` are Chinese only; every user-facing document has an English edition.

## Security notes

- No real IP, password or key ever goes into this repository. There is no "edit the IP at the top of the script" step and no `--password` option. Passwords are typed interactively (or passed via `OWNEXIT_SSH_PASSWORD` for non-interactive use), submitted once per try, and never written to disk.
- A wrong password is retried at most 3 times, and each try is submitted to the server only once, so you are unlikely to trip fail2ban. Failures end with `reason=bad-password`, `reason=password-disabled` or `reason=unreachable`.
- The direct subscription endpoint is plain HTTP protected by a random path. Keep it stopped (`ownexit direct sub stop`) except while importing, and use `ownexit direct rotate-token` if a URL leaks, `ownexit direct rotate-keys` if the node credentials leak.
- The relay only runs `systemd-socket-proxyd`; the Reality private key lives only on the exit server, in a mode-600 file. By default the exit's Reality port only accepts connections from the relay (an nftables table that starts and stops with the exit service).
- Both setups download a pinned official sing-box release on each server and check the SHA-256 of both the archive and the binary; if a server cannot reach GitHub, your computer downloads and uploads it instead. Reality private keys are generated on the server and never leave it.

See [SECURITY.md](https://github.com/jakoes-wu/ownexit/blob/main/SECURITY.md) for how to report a vulnerability.

## FAQ

**Something isn't working. Where do I start?** Run `ownexit doctor`. It checks this computer (required commands, proxy variables, directory permissions, whether a proxy TUN captures the route to your servers), every remembered direct VPS and every chain, and prints a fix for each problem. `ownexit doctor --scan-sni` tests which Reality camouflage domains actually work from your exit server (a real Reality handshake on the server's loopback, not just a TLS 1.3 check). `ownexit doctor --ip-check` also tests the exit IP from the server itself: owner and type, ChatGPT / Claude / Gemini, Netflix / YouTube Premium / Disney+, and common sites (indicative only). Chain checks run `status`, which holds that chain's lock for a few seconds.

**Can I change the SSH port or user?** Direct: `--port`, `--user`. Relay: `--relay-port`, `--exit-port`; the relay setup requires root.

**I manage several VPSes.** Pass `--host` to pick one. Without it, `ownexit direct` lists the remembered servers and exits.

**How do I undo it?** Relay: `ownexit chain rollback`. Direct: `ownexit direct uninstall` (keeps your SSH key login and any migration backup).

**Where are my files?** Keys: `~/.ssh/ownexit/`. Configuration: `~/.config/ownexit/`. State and subscriptions: `~/.local/state/ownexit/`.

## Contributing

Issues and pull requests are welcome; please read [CONTRIBUTING.md](https://github.com/jakoes-wu/ownexit/blob/main/CONTRIBUTING.md) first. The project follows the [Contributor Covenant](https://github.com/jakoes-wu/ownexit/blob/main/CODE_OF_CONDUCT.md).

## License

[MIT](https://github.com/jakoes-wu/ownexit/blob/main/LICENSE). Use this software in accordance with the laws where you live and the terms of your server provider.
