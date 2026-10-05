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
ownexit direct --host 203.0.113.7   # asks for the VPS root password once
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
| Operating system | macOS (Linux untested) | macOS or Linux (WSL counts as Linux) |
| Needed | Python 3.8+ with `pipx`, `ssh`, `curl`, `openssl`, `expect` | same |
| Optional | — | `qrencode`, for QR codes in `ownexit multi render` |

Install what is missing:

```sh
# macOS (with Homebrew, https://brew.sh); ssh, curl and openssl come with macOS
brew install pipx expect
pipx ensurepath            # then open a new terminal

# Debian / Ubuntu / WSL
sudo apt update
sudo apt install -y pipx expect openssh-client curl openssl
pipx ensurepath            # then open a new terminal
```

Windows itself is not supported; use WSL. If your computer runs a proxy in TUN mode (Clash and similar), turn it off while deploying — see [Supported platforms](#supported-platforms).

## Install

```sh
pipx install ownexit        # or: pip install --user ownexit
ownexit --help
```

`ownexit` is a thin wrapper around the bundled bash scripts, so you can also run them straight from a clone — the commands map one to one:

| `ownexit …` | script in a clone |
| ---- | ---- |
| `ownexit direct` | `direct/setup_direct.sh` |
| `ownexit subctl` | `direct/subctl` |
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
   ownexit direct --host 203.0.113.7          # add --port 2222 if SSH is not on 22
   ```

   It sets up key login, checks the system, enables BBR, installs sing-box (by running the third-party installer [233boy/sing-box](https://github.com/233boy/sing-box) interactively — choose **VLESS-REALITY** and press Enter for the rest), renders subscriptions, uploads them and verifies every layer.

2. **Import on your devices** — the script prints three URLs:

   | URL | For |
   | ---- | ---- |
   | `…/clash.yaml` | Clash Verge, mihomo, Clash Meta for Android |
   | `…/shadowrocket.txt` | Shadowrocket on iPhone |
   | `…/node.txt` | the plain `vless://` link, for anything else |

3. **Check and close up** — open `https://ipinfo.io` on a device: it should show your VPS's IP. Then turn the subscription endpoint off until you need it again:

   ```sh
   ownexit subctl stop
   ```

The VPS is remembered, so later runs need no arguments: `ownexit direct` to redeploy, `ownexit subctl status|start|stop`. Step-by-step guide: [docs/manual/direct.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/manual/direct.md) (Chinese).

## Quick start: relay

1. **Give it two IPs**

   ```sh
   ownexit chain init --relay 203.0.113.10 --exit 203.0.113.20
   ```

   It sets up key login on both servers (one password prompt each), detects the exit IP and asks you to confirm it, checks whether the relay already runs sing-box, and writes `~/.config/ownexit/chains/main.env`. Nothing on the servers is changed yet. By default deploy will also add an nftables rule on the exit so that only the relay can reach its Reality port (`--exit-source-filter managed`); use `provider` if your provider's security group already does that, or `none` to skip it.

2. **Deploy**

   ```sh
   ownexit chain --id main deploy
   ```

   Both servers download the pinned sing-box release from GitHub themselves (falling back to an upload from your computer). It deploys the exit first, then the relay, as one transaction, and verifies the exit IP three different ways. If anything fails, it cleans up; if your network drops halfway, run `deploy` or `rollback` again and it converges.

3. **Import** the node from `~/.local/state/ownexit/chains/main/client/node.txt`, or run `ownexit multi --chains main render` for QR codes and a Clash snippet.

Day to day: `ownexit chain --id main status | verify | conns | rollback`. Relay blocked? Deploy a second relay with `init --id backup …` and combine both with `multi_chain_client.sh` — clients switch automatically. Full reference: [chain/README.md](https://github.com/jakoes-wu/ownexit/blob/main/chain/README.md); guide: [docs/manual/chain.md](https://github.com/jakoes-wu/ownexit/blob/main/docs/manual/chain.md) (both in Chinese).

## Supported platforms

| | Direct | Relay |
| ---- | ---- | ---- |
| Control machine | macOS (tested); Linux (untested); Windows not supported — try WSL at your own risk | macOS on Apple silicon (tested), macOS on Intel (untested), Linux amd64 (tested on Ubuntu 20.04), Linux arm64 and WSL (untested) |
| Server OS | Debian, Ubuntu | Linux with systemd; the relay needs `systemd-socket-proxyd`; no nftables tables other than ownexit's own, UFW inactive |
| Server CPU | whatever 233boy/sing-box supports (amd64, arm64) | amd64 (tested) or arm64 (untested); relay and exit must match |
| Clients | Clash Verge, mihomo, Shadowrocket tested; any VLESS-Reality client via `vless://` | same |

If your computer runs a proxy in TUN mode (Clash and similar), SSH to the servers may be cut off halfway through a deploy. Turn TUN off, or route the relay and exit IPs directly, while running chain commands.

## Security notes

- No real IP, password or key ever goes into this repository. There is no "edit the IP at the top of the script" step and no `--password` option. Passwords are typed interactively (or passed via `OWNEXIT_SSH_PASSWORD` for non-interactive use), submitted once per try, and never written to disk.
- A wrong password is retried at most 3 times, and each try is submitted to the server only once, so you are unlikely to trip fail2ban. Failures end with `reason=bad-password`, `reason=password-disabled` or `reason=unreachable`.
- The direct subscription endpoint is plain HTTP protected by a random path. Keep it stopped (`ownexit subctl stop`) except while importing, and use `ownexit direct --rotate-token` if a URL leaks.
- The relay only runs `systemd-socket-proxyd`; the Reality private key lives only on the exit server, in a mode-600 file. By default the exit's Reality port only accepts connections from the relay (an nftables table that starts and stops with the exit service).
- The direct setup installs sing-box through the third-party script 233boy/sing-box. The relay setup downloads a pinned official sing-box release on each server and checks the SHA-256 of both the archive and the binary.

See [SECURITY.md](https://github.com/jakoes-wu/ownexit/blob/main/SECURITY.md) for how to report a vulnerability.

## FAQ

**Can I change the SSH port or user?** Direct: `--port`, `--user`. Relay: `--relay-port`, `--exit-port`; the relay setup requires root.

**I manage several VPSes.** Pass `--host` to pick one. Without it, `ownexit direct` and `ownexit subctl` list the remembered servers and exit.

**How do I undo it?** Relay: `ownexit chain --id main rollback`. Direct (0.1.0 has no uninstall command yet): on the VPS, `systemctl disable --now ownexit-subscription`, remove `/opt/ownexit-subscription` and `/etc/systemd/system/ownexit-subscription.service`, and remove sing-box with the installer's own `sb` tool.

**Where are my files?** Keys: `~/.ssh/ownexit/`. Configuration: `~/.config/ownexit/`. State and subscriptions: `~/.local/state/ownexit/`.

## Contributing

Issues and pull requests are welcome; please read [CONTRIBUTING.md](https://github.com/jakoes-wu/ownexit/blob/main/CONTRIBUTING.md) first. The project follows the [Contributor Covenant](https://github.com/jakoes-wu/ownexit/blob/main/CODE_OF_CONDUCT.md).

## License

[MIT](https://github.com/jakoes-wu/ownexit/blob/main/LICENSE). Use this software in accordance with the laws where you live and the terms of your server provider.
