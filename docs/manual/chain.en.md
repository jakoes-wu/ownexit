# Relay chain guide

**English** | [简体中文](chain.md)

Use a relay chain when the exit's IP is blocked, or when you want clients to enter and leave through different machines: clients connect to a relay, the relay only forwards TCP, and traffic finally leaves from the exit. Websites still see the exit's IP, and the relay holds no keys.

The full reference for commands and mechanisms is in [`chain/README.en.md`](../../chain/README.en.md); this guide walks once through the steps from nothing to a working chain. Commands are written for a git clone; with `pipx install ownexit`, replace `chain/setup_chain.sh` with `ownexit chain` and `chain/multi_chain_client.sh` with `ownexit multi` — the options are identical.

> From 1.7.0 the scripts print in English unless the system language is Chinese; set `OWNEXIT_LANG=en` or `OWNEXIT_LANG=zh` to choose. The messages quoted below are the English ones.

## 1. What you need

| Item | Requirements |
| ---- | ---- |
| Control machine | macOS or Linux (including WSL); install with `pipx install ownexit`, or `git clone` this repository |
| Relay | Linux amd64 or arm64 (same as the exit), root SSH login with a password, `systemd-socket-proxyd` installed; pick a machine close to your clients with a good route to the exit |
| Exit | Linux amd64 or arm64 (same as the relay), root SSH login with a password, a dedicated public IPv4 |
| Network | The exit's security group / firewall lets the relay in; both machines have an empty nft ruleset and UFW inactive |

"Only the relay may connect to the exit" is handled by this project by default: deploy adds an nft table on the exit that only admits the relay (`EXIT_SOURCE_FILTER=managed`), and rollback removes it. If your provider already has a security group that admits only the relay, use `--exit-source-filter provider`; to apply no restriction at all use `none` (the exit is still unusable without the credentials).

If you have no servers yet, see the [VPS guide](vps.en.md) for choosing, ordering, installing the OS and firewall settings.

Optional: a sing-box already running on the relay is fine — the scripts detect it and protect it.

## 2. Generate the configuration (just two IPs)

```bash
chain/setup_chain.sh init --relay 203.0.113.10 --exit 203.0.113.20
```

In order:

1. Set up key login to the relay: asks once for the relay's root password (not echoed; up to 3 tries).
2. Set up key login to the exit: asks once for the exit's root password.
3. Detect the exit's public IP and print it for you to confirm (`y`).
4. Check whether the relay runs sing-box and fill in the matching configuration keys.
5. Write `~/.config/ownexit/chains/main.env` (mode 600) and print the next command. The exit allow-list defaults to `managed` (see section 1).

Add `--relay-port` / `--exit-port` if SSH is not on port 22. To deploy several chains, give each a different name with `--id`.

`init` only sets up key login and makes read-only probes; it changes no remote configuration. If it fails halfway (a wrong password, say), no configuration file is written; fix the problem and rerun — machines that already have key login are skipped.

## 3. Deploy

Section 2 and this section can be one command: `chain/setup_chain.sh up --relay <relay IP> --exit <exit IP>` runs init when there is no configuration yet, then deploy, and prints the node QR code at the end; if it is interrupted, just run the same command again. Step by step:

```bash
chain/setup_chain.sh --id main preflight   # optional: a read-only check first
chain/setup_chain.sh --id main deploy
```

Before deploying, the command checks whether your computer's routes to the two servers go through a proxy TUN (SSH would be cut off halfway if they do): if so it refuses and tells you what to do — see [Keeping specific IPs out of Clash Verge's proxy](clash-direct-ips.en.md); add `--allow-tun` if you really want to continue.

`deploy` has both servers download the pinned sing-box release themselves (SHA-256 checked; your computer uploads it only if that fails), deploys the exit first and then the relay, and finally verifies the exit IP at three levels. Any failed step is cleaned up transactionally, leaving no half-configured state; if the network drops halfway, running `deploy` or `rollback` again converges from the transaction record.

On success the terminal prints a "next steps" block: the node QR code and `vless://` link, the exit IP you should see, and `ownexit doctor` as the first thing to run if something is wrong. The node link is also in `~/.local/state/ownexit/chains/main/client/node.txt` (contains credentials, mode 600); `chain/setup_chain.sh qr` shows the QR code again at any time (`--device <name>` for a device). While you have only one chain, every subcommand can omit `--id main`.

## 4. Import into clients

- **Clash Verge / mihomo / Android**: import the `vless://` link from `node.txt` as a node; with several chains, use the combined output from section 6.
- **iPhone Shadowrocket**: `chain/multi_chain_client.sh --chains main render` produces a QR code for each chain; scan to import, then delete the QR code directory (the images contain plain-text credentials).

Once connected, open `https://ipinfo.io`: the IP should be the exit's IP.

## 5. Day-to-day operations

```bash
chain/setup_chain.sh --id main status     # health status
chain/setup_chain.sh --id main verify     # full check of the exit
chain/setup_chain.sh --id main conns      # which source IPs are connected to the relay
chain/setup_chain.sh --id main ban 203.0.113.7    # block an unknown source
chain/setup_chain.sh --id main rotate-keys   # replace the UUID and Reality key / short id of every device
chain/setup_chain.sh --id main add-device phone      # add a device (its node is devices/node-phone.txt in the state directory)
chain/setup_chain.sh --id main remove-device phone   # revoke a device
chain/setup_chain.sh --id main rollback   # tear down this chain and restore both machines to their pre-deploy state
ownexit doctor --chain main --ip-check    # diagnose this computer and the chain, and check the exit IP from the exit
```

The relay port has no authentication: when `conns` shows a source IP you do not recognise, `ban` it first.

`rotate-keys` only replaces the credentials on the exit and restarts the exit's sing-box (1–3 seconds of downtime); the relay, ports and deployment stay the same. Afterwards every client must import again, and combined multi-chain output must be `render`ed again. `add-device` / `remove-device` give each device its own UUID, and revoking one does not affect the others; the credentials from deployment are the `default` device. If interrupted, rerun the same command to converge.

## 6. The relay got blocked

Prepare another relay and deploy a second chain (sharing the same exit):

```bash
chain/setup_chain.sh init --id backup --relay 198.51.100.10 --exit 203.0.113.20
chain/setup_chain.sh --id backup deploy
chain/multi_chain_client.sh --chains main,backup render
```

The `clash-snippet.yaml` from `render` has a `fallback` auto group (`Exit-Relay-auto`); once merged into Clash Verge, it switches to the next chain automatically when the current relay is unavailable. After confirming the new chain works, you can `rollback` the blocked one and drop it from `--chains`.

## 7. The exit changed

Whether the exit got a new IP or you moved to another machine, do not rollback and deploy again (that generates new credentials, and every client has to import again). There is one entry point, `migrate-exit`:

```bash
chain/setup_chain.sh migrate-exit --to <new IP>
```

It first works out whether the new address is the same machine, then:

- **A new machine, and the old one can still be reached**: migrates directly. The configuration (including the private key) is moved unchanged from the old machine to the new one, the relay is switched over, and this chain's service and files are removed from the old machine; clients need no changes. For the steps and interruption handling see [Moving the exit to another machine in `chain/README.en.md`](../../chain/README.en.md#moving-the-exit-to-another-machine).
- **The same machine with a new IP** (it works even if the old IP is unreachable): detected automatically; it registers the new IP's host key, backs up and rewrites the configuration, switches over in place and prints `migrate=rehosted`. The SSH port must stay the same. Details in [Exit IP changed in `chain/README.en.md`](../../chain/README.en.md#exit-ip-changed-same-machine).
- **A new machine, and the old one can no longer be reached**: the private key exists only on the old machine, so it cannot be migrated; the only option is rollback and a fresh deploy (clients must import again).

## 8. Troubleshooting

| Problem | Fix |
| ---- | ---- |
| `init` reports `reason=bad-password` / `password-disabled` / `unreachable` | Wrong password, password login turned off on the server, or unreachable, respectively; handle as in the [direct guide's troubleshooting](direct.en.md#7-troubleshooting) |
| `init` reports "Cannot get an ed25519 host key from the …" | Check that the machine's sshd `HostKey` settings include ed25519 |
| `init` reports "The sing-box state on the relay is incomplete" | Get the existing sing-box fully running (service, configuration and process all present), or remove it completely, then rerun |
| `init` reports "The configuration already exists" | A chain with that name already exists; use another `--id`, or make sure the old chain is no longer needed (rollback first) and delete its configuration file |
| `preflight` reports firewall or `sockets.target.wants` problems | Follow the commands in the error message; the scripts will not change your firewall or create standard systemd directories for you |
| TUN is on locally and `status` / `verify` print `[ssh-retry]` | Read-only commands retry up to 3 times when SSH drops; if it happens often, turn off TUN or route the relay's and exit's IPs directly (for Clash Verge see [Keeping specific IPs out of Clash Verge's proxy](clash-direct-ips.en.md); `ownexit doctor` shows which IPs go through TUN) |
| SSH drops in the middle of an operation and `verify` reports drift | Local TUN may have taken over SSH to the relay; turn TUN off (or route the relay's and exit's IPs directly as in [clash-direct-ips.en.md](clash-direct-ips.en.md)) and rerun |
| "The configuration directory's ownership or permissions are unsafe" | Some parent of the configuration / state directory is writable by the group or others (for example mode 775); move to a directory tree with modes 755 / 700 |
| "The relay and the exit must have the same CPU architecture" | One machine is amd64 and the other arm64, which is not supported yet |
| `status` prints `reason=exit-op-pending`, or `verify` / `rollback` report "… unfinished credential or device operation …" | The last `rotate-keys` / `add-device` / `remove-device` did not finish and left helper files on the exit; rerun the interrupted command |
| `verify` / `status` / `rollback` report "The relay's dependency, firewall or role declaration preflight failed" or "The zero-regression baseline of the relay's existing sing-box changed", and the relay also runs direct | Direct was just migrated, reconfigured, freshly installed or uninstalled; run `chain/setup_chain.sh --id <name> rebaseline` to register it again (see [`chain/README.en.md`](../../chain/README.en.md#re-registering-an-existing-sing-box-on-the-relay-rebaseline)) |
