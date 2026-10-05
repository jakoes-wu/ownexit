# ownexit

**English** | [简体中文](README.zh-CN.md)

[![CI](https://github.com/jakoes-wu/ownexit/actions/workflows/ci.yml/badge.svg)](https://github.com/jakoes-wu/ownexit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![bash](https://img.shields.io/badge/bash-3.2%2B-blue)
![macOS](https://img.shields.io/badge/control-macOS-lightgrey)

Turn a VPS you rent into your own fixed exit IP — connect directly, or through a relay — set up from your laptop with one command.

```sh
git clone https://github.com/jakoes-wu/ownexit && cd ownexit
./direct/setup_direct.sh --host 203.0.113.7   # asks for the VPS root password once
```

When it finishes, paste the printed subscription URL into Clash Verge or Shadowrocket. That's it.

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

## What you need

| | Direct | Relay |
| ---- | ---- | ---- |
| Your computer | macOS (Linux untested) | Mac with Apple silicon |
| Servers | 1 × Debian / Ubuntu VPS | 2 × Linux amd64 (relay + exit) |
| Login | root password over SSH, used once | same, for each server |
| Tools | `git`, `ssh`, `curl`, `openssl`, `expect` (`brew install expect`) | same |

The first run asks for each server's root password (not echoed); after that everything uses a dedicated SSH key in `~/.ssh/ownexit/`.

## Quick start: direct

1. **Deploy**

   ```sh
   ./direct/setup_direct.sh --host 203.0.113.7          # add --port 2222 if SSH is not on 22
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
   ./direct/subctl stop
   ```

The VPS is remembered, so later runs need no arguments: `./direct/setup_direct.sh` to redeploy, `./direct/subctl status|start|stop`. Step-by-step guide: [docs/manual/direct.md](docs/manual/direct.md) (Chinese).

## Quick start: relay

1. **Give it two IPs**

   ```sh
   chain/setup_chain.sh init --relay 203.0.113.10 --exit 203.0.113.20
   ```

   It sets up key login on both servers (one password prompt each), detects the exit IP and asks you to confirm it, checks whether the relay already runs sing-box, and writes `~/.config/ownexit/chains/main.env`. Nothing on the servers is changed yet. If your provider has a security group that only lets the relay reach the exit, add `--exit-source-filter provider` so deploy checks that strictly; a plain VPS works with the default.

2. **Deploy**

   ```sh
   chain/setup_chain.sh --id main deploy
   ```

   It deploys the exit first, then the relay, as one transaction, and verifies the exit IP three different ways. If anything fails, it cleans up.

3. **Import** the node from `~/.local/state/ownexit/chains/main/client/node.txt`, or run `chain/multi_chain_client.sh --chains main render` for QR codes and a Clash snippet.

Day to day: `chain/setup_chain.sh --id main status | verify | conns | rollback`. Relay blocked? Deploy a second relay with `init --id backup …` and combine both with `multi_chain_client.sh` — clients switch automatically. Full reference: [chain/README.md](chain/README.md); guide: [docs/manual/chain.md](docs/manual/chain.md) (both in Chinese).

## Supported platforms

| | Direct | Relay |
| ---- | ---- | ---- |
| Control machine | macOS (tested); Linux (untested); Windows not supported — try WSL at your own risk | macOS on Apple silicon only |
| Server OS | Debian, Ubuntu | Linux with systemd; the relay needs `systemd-socket-proxyd`; empty nftables, UFW inactive |
| Server CPU | whatever 233boy/sing-box supports (amd64, arm64) | amd64 only |
| Clients | Clash Verge, mihomo, Shadowrocket tested; any VLESS-Reality client via `vless://` | same |

Wider relay support (Intel Macs, Linux and WSL as control machine, arm64 servers) is planned for 0.2.0.

## Security notes

- No real IP, password or key ever goes into this repository. There is no "edit the IP at the top of the script" step and no `--password` option. Passwords are typed interactively (or passed via `OWNEXIT_SSH_PASSWORD` for non-interactive use), submitted once per try, and never written to disk.
- A wrong password is retried at most 3 times, and each try is submitted to the server only once, so you are unlikely to trip fail2ban. Failures end with `reason=bad-password`, `reason=password-disabled` or `reason=unreachable`.
- The direct subscription endpoint is plain HTTP protected by a random path. Keep it stopped (`subctl stop`) except while importing, and use `setup_direct.sh --rotate-token` if a URL leaks.
- The relay only runs `systemd-socket-proxyd`; the Reality private key lives only on the exit server, in a mode-600 file.
- The direct setup installs sing-box through the third-party script 233boy/sing-box. The relay setup downloads a pinned official sing-box release and checks its SHA-256.

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## FAQ

**Can I change the SSH port or user?** Direct: `--port`, `--user`. Relay: `--relay-port`, `--exit-port`; the relay setup requires root.

**I manage several VPSes.** Pass `--host` to pick one. Without it, `setup_direct.sh` and `subctl` list the remembered servers and exit.

**How do I undo it?** Relay: `chain/setup_chain.sh --id main rollback`. Direct (0.1.0 has no uninstall command yet): on the VPS, `systemctl disable --now ownexit-subscription`, remove `/opt/ownexit-subscription` and `/etc/systemd/system/ownexit-subscription.service`, and remove sing-box with the installer's own `sb` tool.

**Where are my files?** Keys: `~/.ssh/ownexit/`. Configuration: `~/.config/ownexit/`. State and subscriptions: `~/.local/state/ownexit/`.

## Contributing

Issues and pull requests are welcome; please read [CONTRIBUTING.md](CONTRIBUTING.md) first. The project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE). Use this software in accordance with the laws where you live and the terms of your server provider.
