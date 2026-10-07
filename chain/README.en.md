# Relay chain: relay + exit

**English** | [简体中文](README.md)

Clients connect to a TCP port on the relay; the relay forwards the bytes unchanged to the exit with `systemd-socket-proxyd`, and VLESS-Reality terminates only on the exit. When the exit's IP is blocked, swap in another relay — the exit IP and client credentials stay the same.

```text
Computer / phone
  │ VLESS-Reality
  ▼
Relay
  │ systemd-socket-proxyd, plain TCP byte forwarding (no decryption, no keys stored)
  ▼
Exit
  │ sing-box VLESS-Reality + direct
  ▼
Target websites see the exit's IP
```

> From 1.7.0 the scripts print in English unless the system language is Chinese; set `OWNEXIT_LANG=en` or `OWNEXIT_LANG=zh` to choose. The messages quoted below are the English ones.

## Quick start

From the repository root:

```bash
# One command: init if there is no configuration yet (key login, detect the exit IP), then deploy, then print the node QR code and next steps
chain/setup_chain.sh up --relay 203.0.113.10 --exit 203.0.113.20
```

If interrupted, run the same command again to converge; once deployed, running it again amounts to a full verify. Step by step:

```bash
# 1. Two IPs only: set up key login to both machines (asks for each root password once), detect the exit IP and the relay's current state, write the configuration
chain/setup_chain.sh init --relay 203.0.113.10 --exit 203.0.113.20

# 2. Deploy (read-only preflight first, then a transactional deploy in the order exit → relay, then a full verify)
chain/setup_chain.sh --id main deploy

# 3. Show the node QR code again at any time; the node link is in ~/.local/state/ownexit/chains/main/client/node.txt (contains credentials, mode 600)
chain/setup_chain.sh qr
```

To see whether a deploy would work without touching the servers: `chain/setup_chain.sh --id main preflight`.

While you have only one chain, every subcommand can omit `--id` (`chain/setup_chain.sh status`); with no configuration or several, it exits 2 and says so. Before deploying (`up` / `deploy`), the command checks whether your computer's routes to the two servers go through a proxy TUN: if they do it refuses (exit 3) and tells you what to do — turn TUN off, or route the server IPs through the physical interface as described in [docs/manual/clash-direct-ips.en.md](../docs/manual/clash-direct-ips.en.md); add `--allow-tun` if you really want to continue.

The configuration from `init` is written to `~/.config/ownexit/chains/<name>.env` (default name `main`). After that, `deploy`, `verify`, `rollback` and the rest read only this file and accept no host arguments to override it: the deployment state is bound to the configuration file's hash, so a changed configuration no longer matches the state. To deploy a second chain, use `init --id <new name>`.

## Requirements

1. The control machine runs macOS (Apple silicon / Intel; the built-in `/bin/bash` 3.2 is enough) or Linux (amd64 / arm64, including WSL). Running from a git clone needs `git` (used to make sure the real configuration is outside the repository); a pipx install does not. No parent directory of the configuration and state directories may be writable by the group or others, or the safety checks refuse.
2. Two Linux servers, both amd64 or both arm64 (mixed architectures are not supported), with root SSH login by password (used only once, by `init`).
3. The exit's cloud security group / firewall lets the relay in; the scripts call no cloud provider API. "Only the relay may reach the exit's Reality port" can be done three ways, chosen by `EXIT_SOURCE_FILTER`: the default `managed`, where deploy adds an nft table on the exit that only admits the relay's outbound address; `provider`, where the provider's security group outside the machine takes care of it; and `none`, no restriction (the exit is still unusable without the credentials). With `managed` and `provider`, deploy strictly checks that your computer cannot connect directly.
4. Apart from this project's `table inet ownexit_*` allow-list tables, neither machine has any nft table; if UFW is installed it must be inactive; legacy iptables must have no active rules.
5. The relay has `systemd-socket-proxyd` installed, and both ends have the system tools that `preflight` lists. On a brand-new machine also make sure `/etc/systemd/system/sockets.target.wants` exists (root:root 755); if it is missing, `preflight` prints the command to create it — the scripts do not create standard systemd directories for you.
6. A sing-box already running on the relay is fine: `init` detects it — `RELAY_COHOSTS_SINGBOX=yes` for a 233boy install, `ownexit-direct` for ownexit direct, `no` for neither — and deploy keeps the existing service untouched; an incomplete state (a configuration without a process, both coexisting and so on) makes `init` refuse.

## Security boundaries

- The SSH user on both ends is always `root`, with key login and a trusted ed25519 host key (set up by `init`). The scripts generate an isolated SSH config that inherits none of your own ProxyCommand, port forwards or remote commands; management connections to the exit go through the relay with `ProxyJump`.
- Host key fingerprints are taken from each SSH session's `ssh -vv -E` log, not from public key files on the servers, and the relay's fingerprint seen through ProxyJump is never mistaken for the exit's.
- The scripts do not change firewalls, cloud security groups or an existing sing-box configuration.
- A chain-specific remote path that already exists is never overwritten; the pinned shared binary is reused only when owner, mode, version and hash all match.
- The Reality private key exists only in the exit's mode-600 configuration; logs never print UUIDs, keys, short ids or full node links.
- Only TCP + `socks5h` are verified; UDP, QUIC/HTTP3, ICMP and zero client DNS leaks are not promised.

## Configuration (editing by hand is advanced use)

The file from `init` has the same format as `chain/chain.example.env`. The parser executes no shell and accepts only blank lines, `#` comments and strict `KEY=VALUE` lines, and it must contain exactly these 13 keys:

| Key | Description | Where `init` gets it |
| ---- | ---- | ---- |
| `CHAIN_ID` | `[a-z0-9][a-z0-9-]{0,31}`; names the local state directory and the remote units | `--id`, default `main` |
| `RELAY_HOST` / `RELAY_SSH_PORT` | The relay's IPv4 and SSH port | `--relay`, `--relay-port` (default 22) |
| `RELAY_SSH_USER` | Always `root` | Fixed |
| `RELAY_SSH_KEY` | Absolute path of the relay's private key on your computer | `~/.ssh/ownexit/id_ed25519_root_<ip>_<port>` |
| `EXIT_HOST` / `EXIT_SSH_PORT` | The exit's IPv4 and SSH port | `--exit`, `--exit-port` (default 22) |
| `EXIT_SSH_USER` | Always `root` | Fixed |
| `EXIT_SSH_KEY` | Absolute path of the exit's private key on your computer; never copied to the relay | Same rule as above |
| `EXPECTED_EXIT_IPV4` | The only IPv4 allowed back from the exit checks | Detected on the exit and confirmed by you in the terminal |
| `REALITY_SERVER_NAME` | Reality camouflage domain (ASCII FQDN); there is no automatic fallback | `--sni`, default `www.amazon.com` |
| `RELAY_COHOSTS_SINGBOX` | `yes` protects 233boy's `sing-box.service`; `ownexit-direct` protects ownexit direct's `ownexit-direct.service`; `no` requires no sing-box at all on the relay | Detected by logging in to the relay; maintained by `rebaseline` afterwards — do not edit by hand |
| `EXIT_SOURCE_FILTER` | `managed`: this project adds an nft allow-list on the exit; `provider`: the provider's security group admits only the relay; with either, deploy / verify fail if your computer can reach the exit's Reality port directly. `none`: no restriction; direct reachability only logs a WARN | `--exit-source-filter`, default `managed` |

The configuration file must be owned by the current user, mode 600, not a symlink, and outside any git work tree; private keys must grant no permissions to group / other.

## Commands

```bash
chain/setup_chain.sh init --relay <ip> --exit <ip> [--id <name>] [--relay-port N] [--exit-port N] [--sni <domain>] [--exit-source-filter managed|provider|none]
chain/setup_chain.sh up [all init options] [--allow-tun]        # init (if needed) + deploy + QR code; can be rerun
chain/setup_chain.sh --id main preflight
chain/setup_chain.sh --id main deploy [--allow-tun]
chain/setup_chain.sh --id main qr [--device <name>]
chain/setup_chain.sh --id main verify
chain/setup_chain.sh --id main verify --with-fail-closed
chain/setup_chain.sh --id main status
chain/setup_chain.sh --id main rollback

# Relay connection management (once the chain is deployed)
chain/setup_chain.sh --id main conns              # connections / idle seconds / ban status per source IP, plus proxyd fd usage
chain/setup_chain.sh --id main kick 203.0.113.7   # drop that source's established connections with ss -K
chain/setup_chain.sh --id main ban 203.0.113.7    # add to the blocklist, effective immediately (also kicks)
chain/setup_chain.sh --id main ban 198.51.100.0/24
chain/setup_chain.sh --id main unban 203.0.113.7
chain/setup_chain.sh --id main banlist            # compare the local blocklist with the IPAddressDeny read back from the relay's two units

# The exit changed: a new public IP or a new machine (credentials and clients unchanged).
# The same machine is detected automatically and switched in place; a new machine asks for its root password the first time
chain/setup_chain.sh --id main migrate-exit --to 203.0.113.30

# After direct on the relay is migrated / reconfigured / freshly installed / uninstalled, re-register the existing sing-box to protect
chain/setup_chain.sh --id main rebaseline

# Replace the exit's UUID / Reality key / short id (every client must import again)
chain/setup_chain.sh --id main rotate-keys

# Several devices: one UUID per device, revocable individually
chain/setup_chain.sh --id main add-device phone
chain/setup_chain.sh --id main remove-device phone
chain/setup_chain.sh --id main list-devices
```

`--id <name>` is shorthand for `--config ~/.config/ownexit/chains/<name>.env`; use one or the other.

The blocklist lives in a managed drop-in for the relay's two chain-specific units (`<unit>.d/50-ownexit-chain-blacklist.conf`, containing `IPAddressDeny=`, enforced by systemd cgroup BPF rather than a firewall); it takes effect right after `daemon-reload`, without restarting the services or affecting other sources. The authoritative local copy is `${XDG_STATE_HOME:-~/.local/state}/ownexit/chains/<id>/blacklist.txt`; `verify` / `status` accept only this one drop-in and require the `IPAddressDeny` value read back from the server to match the local list exactly, and when the list is empty the server must have no drop-in. `kick` needs a relay kernel that supports `ss -K`, and `ban` needs cgroup v2; both were tested on Debian 12 / systemd 252. The relay port is an unauthenticated layer-4 forward: when `conns` shows an unknown source, `ban` it first, and only then consider rolling back and redeploying on another port.

`preflight` prepares assets only in the operation's temporary directory and writes no persistent cache, remote units or authoritative state. `deploy` reruns every check after taking the lock and does not reuse an earlier preflight's results.

`verify --with-fail-closed` briefly stops this chain's relay socket, confirms that new connections get no working exit IP, then restores the socket and reruns the full exit check. A 90-second timer on the server is the second line of recovery in case the controlling process crashes.

The isolated SSH configuration fixes `ConnectTimeout=12`, `ServerAliveInterval=15` and `ServerAliveCountMax=2`; once the lock is held, every SSH / scp also has a 600-second overall timeout on the control machine, and a timeout is classified as "server unreachable". `status` is normally read-only, but when state, identities, platform, baseline and leftovers all pass and the socket is active while the relay service is inactive, it runs `systemctl start` once and checks again; it never writes remote files.

## Status and exit codes

`status` prints one of:

| Status | Meaning | Exit code |
| ---- | ---- | ---- |
| `deployed/healthy` | State, resources on both ends, processes, listeners and the baseline of existing services all match | 0 |
| `not_deployed` | No active state, transaction, chain-specific resources or staging directories for this chain | 0 |
| `busy` | The same chain holds an active lock with a valid identity | 5 |
| `stale_lock` | The lock's identity is no longer valid; the next modifying command archives it | 5 |
| `incomplete` | A deploy / rollback transaction is waiting to be recovered | 5 |
| `unreachable` | At least one server could not be verified through the controlled SSH probe | 5 |
| `orphaned` | No state, but chain-specific objects or staging directories exist | 5 |
| `drifted` | There is state, but hashes, permissions, units, listeners or the baseline do not match | 5 |

When unhealthy, the output includes a redacted `reason` (where applicable) and `next=<safe action>`; `unreachable` also gives `role=relay|exit`, for example `status=unreachable role=exit reason=hostkey-probe next=retry-status`.

Exit codes: 2 for argument errors; 3 for failed preflight / checks (including failed key setup or probes in `init`); 4 for path collisions; 5 for unhealthy state or verify; 6 for a failed rollback pre-check.

## Verification model

Deploy and `verify` check three layers, none of which replaces another:

1. A TLS 1.3 / certificate probe from the exit to the Reality camouflage site.
2. A temporary sing-box on the relay connecting directly to the exit, proving the allow-list, SNI, credentials and the exit's direct outbound all work.
3. The full path from the relay through the relay forward, plus your computer connecting to the public relay with the Darwin build of sing-box.

Exit requests always use `api.ipify.org`, `icanhazip.com` and `ifconfig.me/ip`: at least two must succeed, and every valid response must equal `EXPECTED_EXIT_IPV4`; there is no direct fallback.

When `RELAY_COHOSTS_SINGBOX=yes` (or `ownexit-direct`), the zero-regression baseline is taken from the MainPID of the running `sing-box.service` (or `ownexit-direct.service`): the actual configuration is resolved from `-c/-C` in `/proc/<pid>/cmdline` and from `/proc/<pid>/cwd`, and the cmdline, cwd, ExecStart, unit and drop-ins, executable metadata and that process's listening ports are recorded; the configuration is not assumed to be in `/etc/sing-box`. With `no`, four `none` placeholders are written.

## Files on your computer

| Path | Contents |
| ---- | ---- |
| `${XDG_CONFIG_HOME:-$HOME/.config}/ownexit/chains/<id>.env` | This chain's configuration (generated by `init` or written by hand) |
| `${XDG_STATE_HOME:-$HOME/.local/state}/ownexit/chains/<id>/state.env` | Authoritative deployment state with an embedded checksum |
| `.../transaction.env` | Transaction log; its presence means a transaction is unfinished |
| `.../baseline/` | Four read-only baselines of the relay's existing sing-box, or `none` placeholders |
| `.../client/node.txt` | The only persistent client artifact, mode 600 |
| `.../audit/` | Complete deploy / rollback and stale-lock audit records |
| `${XDG_CACHE_HOME:-$HOME/.cache}/ownexit/chains/<id>/downloads/` | Pinned official assets; safe to delete and re-download |
| `${XDG_STATE_HOME:-$HOME/.local/state}/ownexit/multi-chain-client/<name>/` | Combined multi-chain output of `multi_chain_client.sh render`; separate from `chains/<id>/` |
| `~/.ssh/ownexit/` | Dedicated keys that `init` (through `direct/connect_to.sh`) generates for each machine |

## Server-side download and local verification

- The servers download the pinned sing-box from GitHub themselves and check its SHA-256 (archive and binary hashes for the 4 platform packages are hard-coded at the top of the script); only if the server download fails does your computer download it and upload it. `binary source=remote-download|local-upload` in the log shows which path was taken.
- Your computer only prepares the official package for its own platform, used for the "local exit smoke" layer. If there is no official package for your platform, or the cache is missing and the download fails, that layer is skipped with a WARN and deployment continues; `multi_chain_client.sh verify`, however, requires the local package.
- The state file keeps the fields of v0.1.0, so chains deployed with v0.1.0 can be managed by newer versions directly.

## Server resources

Relay-specific resources:

```text
/etc/ownexit-chain/<id>.owner.env
/etc/systemd/system/ownexit-chain-relay-<id>.socket
/etc/systemd/system/ownexit-chain-relay-<id>.service
/etc/systemd/system/sockets.target.wants/ownexit-chain-relay-<id>.socket
# Only when the blocklist is not empty (created by ban, removed by rollback):
/etc/systemd/system/ownexit-chain-relay-<id>.socket.d/50-ownexit-chain-blacklist.conf
/etc/systemd/system/ownexit-chain-relay-<id>.service.d/50-ownexit-chain-blacklist.conf
```

Exit-specific resources (with `managed` there is also an nft table `table inet ownexit_<id with - replaced by _>` that starts and stops with `ownexit-chain-exit-<id>.service`, its rules written in that unit's `ExecStartPre` / `ExecStopPost`):

```text
/etc/ownexit-chain/<id>.owner.env
/etc/ownexit-chain/<id>.exit.json
/etc/systemd/system/ownexit-chain-exit-<id>.service
/etc/systemd/system/multi-user.target.wants/ownexit-chain-exit-<id>.service
```

Shared by both ends and expected to remain after rollback:

```text
/etc/ownexit-chain
/opt/ownexit-chain
/opt/ownexit-chain/bin
/opt/ownexit-chain/bin/sing-box-1.13.14
```

The `libcronet.so` in the official Linux package is used only to check the archive layout and is not published to the shared directory.

## Rollback and recovery

Before stopping anything, `rollback` verifies every owner, hash, symlink, systemd load path, local artifact, host and key fingerprint, and the baseline of the existing sing-box. If all pass, it removes the chain-specific resources in the order relay → exit; after stopping it accepts only the definite end states `inactive` / `failed`, a service must have `MainPID=0`, and after deletion it confirms `LoadState=not-found`, no fragment or drop-ins, and no listeners. Only after the state, baseline, node and final transaction are all archived into `audit/rolledback.*` with a `COMPLETE` marker is the active state deleted.

If the control machine is killed with `kill -9` or loses power, the next modifying command reads `transaction.env`: a deploy is committed only if full verification finished and the state matches the servers; any other deploy is cleaned up in reverse, and a rollback continues from its last completed step. Shared directories and the pinned binary are not on a single chain's rollback list.

To switch to another relay, run `init` with a new `--id` and deploy it, confirm the new chain works, then roll back the old one.

## Re-registering an existing sing-box on the relay (`rebaseline`)

When the relay also runs direct (`ownexit direct`), the chain records that service as a baseline it must keep unchanged. After direct is migrated (233boy → ownexit-direct), reconfigured, freshly installed or uninstalled, the chain's `verify` / `status` / `rollback` fail at the precheck or baseline comparison (relay forwarding itself is unaffected). Then run:

```bash
chain/setup_chain.sh --id main rebaseline
```

It re-detects `RELAY_COHOSTS_SINGBOX` (`yes` / `ownexit-direct` / `no`) on the relay, recaptures the baseline, rewrites only that one line of the configuration if needed and syncs the owner files on both ends, then runs a full `verify`. Credentials, ports and `client/node.txt` stay the same, and the relay service is not restarted. If the live state already matches the records it prints `rebaseline=noop`. If interrupted, rerun the same command to converge. The old state, baseline and configuration are archived in `audit/rebaselined.<deployment ID>.<operation ID>/`. Exit codes: 0 success or noop; 2 a key other than `RELAY_COHOSTS_SINGBOX` changed in the configuration; 3 the relay is unreachable or its sing-box state is incomplete; 5 lock, corrupted state or an unfinished transaction; 1 the remote owner migration or local commit failed (remote codes 180 owner identity abnormal, 181 owner does not match state, 182 a digest in the owner is outside its allowed values).

## Replacing node credentials (`rotate-keys`) and several devices (`add-device` / `remove-device` / `list-devices`)

```bash
chain/setup_chain.sh --id main rotate-keys
chain/setup_chain.sh --id main add-device phone      # add a device; its node is <state directory>/devices/node-phone.txt
chain/setup_chain.sh --id main remove-device phone   # revoke the device; it disconnects immediately
chain/setup_chain.sh --id main list-devices          # read-only: devices on the exit and local node files
```

The credentials from deployment are the device named `default` (its node is still `client/node.txt`). Each extra device has its own UUID and node file (node name `Exit-via-Relay-<chain>_<name>`), and revoking one does not affect the others. Device names may only match `[a-z0-9][a-z0-9-]{0,31}`; `default` is reserved, and each chain holds at most 32 devices (including default). Multi-chain aggregation (`multi_chain_client.sh`) only combines each chain's default.

`rotate-keys` regenerates the UUID of every device (including default) on the exit, along with the Reality key pair and short id. All three commands change only the exit's configuration (the users line; rotate also replaces the private key and short id) and restart the exit's sing-box (connections in flight drop for 1–3 seconds), then update the local node files and state, and finally run a full `verify`. The relay, the ports on both ends, the deployment ID, the owner files and the configuration stay the same; private keys and UUIDs are generated only on the exit and never pass through your computer. After rotate-keys every client must import again, and users of `multi_chain_client.sh` must `render` again.

The device list follows the exit's active configuration: each command derives the new configuration from the exit's current one ("add one / remove one / rotate"), and the local `devices/` is only a cache, overwritten every time with the exit's result (if the local files are lost, running any device command or rotate-keys rebuilds them).

These commands are not transactional. Intermediate state is kept in three helper files on the exit: `/etc/ownexit-chain/<id>.rotate.json` (the configuration to switch to), `<id>.rotate.env` (operation type and new parameters, no private key) and `<id>.rotate.bak.json` (the old configuration); the local state is committed last. If interrupted, rerun the same command: an interruption before the switch reuses the already generated configuration (`result=resumed`), one after the switch but before the commit restarts and completes the commit (`result=already`), and one after the commit with only cleanup left just cleans up without doing it again (`result=resumed-after-commit`). If the previous command did not finish and another is run, it refuses and asks you to rerun the previous one first. If the new configuration fails to start, the old one is put back automatically. While helper files exist, `status` prints `status=drifted reason=exit-op-pending next=rerun-interrupted-command`, and `verify` / `rollback` refuse to run. The old state is archived in `audit/rotated.<deployment ID>.<operation ID>/` or `audit/devices.<deployment ID>.<operation ID>/`. Rollback deletes the local `devices/`.

Exit codes: 0 success; 2 argument errors, configuration not matching state, or a refused device operation (remote codes 201 already exists, 202 over the limit, 203 no such device, 204 default cannot be revoked); 3 the exit is unreachable or its host fingerprint does not match; 5 lock, corrupted state, an unfinished transaction or a failed final verify; 1 a remote operation or the local commit failed (remote codes 191 configuration file identity abnormal, 192 configuration not in the form deploy generated, 193 configuration changed externally, 194 new configuration fails validation, 195 new configuration fails to start and the old one was restored, 196 still fails to start after restoring, 197 the live configuration is not the new one during cleanup, 198 the exit's sing-box binary is missing, 199 another operation is unfinished).

## Exit IP changed (same machine)

When your provider gives the exit a new public IP but the machine itself is the same (its ed25519 host fingerprint is unchanged), just run `migrate-exit --to <new IP>`; do not roll back and deploy: rollback needs the old IP, and deploy generates new credentials, so every client would have to import again.

```bash
# Run once for each chain that shares this exit; it works even if the old IP is unreachable
chain/setup_chain.sh --id main migrate-exit --to <new IP>
```

It connects to the new IP through the relay with the current exit's private key: if the negotiated host fingerprint equals the value recorded in the state, the machine is the same one. It then reads the host public key and the new exit IP over that same connection (in a terminal it asks you to confirm the exit IP), registers the new IP's ed25519 entry in `~/.ssh/known_hosts` (an identical entry is not written twice; a different ed25519 entry makes it exit 3 so you can check), backs up the configuration as `<configuration>.bak.<time>`, rewrites `EXIT_HOST` / `EXPECTED_EXIT_IPV4` and switches over in place, printing `migrate=rehosted chain=<chain> exit=<new IP>:<port>` on success. If the fingerprint differs or the address cannot be reached, it is treated as a new machine (see the next section). The SSH port must stay the same: giving a different `--to-port` for the same machine exits 2.

If it is interrupted after rewriting the configuration, rerun the same command to continue (when the configuration already points at the new IP while the state still has the old one, it only confirms that those two keys are the ones that differ, registers known_hosts if needed and carries on); once the switch is complete it prints `rehost=noop`. The old spelling `rehost-exit` (edit the two keys above and add the known_hosts entry by hand, then run it) was removed in 2.0: it exits 2 and suggests `migrate-exit`; a rehost-exit interrupted under 1.x after the configuration was rewritten is finished after upgrading with `migrate-exit --to <EXIT_HOST from the configuration>`. Order of the switch: the exit's owner → the relay's owner and the relay service's `ExecStart` target (followed by `daemon-reload`; if the running relay still points at the old target it is restarted once, dropping connections in flight, and clients reconnect automatically) → the local state (the old state is archived to `audit/rehosted.<deployment ID>.<operation ID>/state.env`) → an automatic full check identical to `verify`. The UUID, Reality key, ports and `client/node.txt` stay the same, so clients need not import again.

The in-place switch is not transactional: every remote step uses "whole-file hash guard + single-line replacement" and accepts both the old and the migrated form, so after a failure you simply rerun the same command to converge; when the state is already bound to the new configuration it prints `rehost=noop` and returns 0. Exit codes: 0 success or noop; 2 argument errors, other configuration keys differ, the same machine with a different SSH port, or the exit IP was not confirmed; 3 the new IP is unreachable, known_hosts already has a mismatching entry, or it is not the same machine; 5 lock, corrupted state, an unfinished transaction or a failed final verify; 1 the remote migration or local commit failed (the message includes remote codes 171–177 and their meaning).

## Moving the exit to another machine

When the exit moves to a different machine (a new provider, a new data centre, the old machine expiring), use `migrate-exit`; do not roll back and deploy: it moves this chain's configuration (including the Reality private key) unchanged from the old exit to the new machine, so the UUID, keys, short id, all devices, relay address and port stay the same and clients need not import again.

```bash
chain/setup_chain.sh --id main migrate-exit --to 203.0.113.30              # add --to-port 2222 if the new machine's SSH is not on port 22
chain/setup_chain.sh --id main migrate-exit --abort                        # give up the migration before the relay is switched
chain/setup_chain.sh --id main migrate-exit --abandon-cleanup              # migration done, old machine permanently unreachable: give up cleanup
```

Prerequisites: the chain is deployed and healthy, and the old exit can still be reached through the relay (the private key exists only there; if the old machine can no longer be reached, the only options are rollback + deploy, or migrating and then `rotate-keys`); the new machine has the same architecture as the relay (amd64 or arm64) and holds none of this chain's files. With `EXIT_SOURCE_FILTER=provider`, first make the new provider's security group admit only the relay, or the pre-switch rejection probe fails.

The process: set up key login to the new machine (asks for its root password the first time, or uses `OWNEXIT_SSH_PASSWORD` when not in a terminal; the global lock is held while you type, so other chains' deploys wait) → ask ipinfo.io on the new machine for the new exit IP (confirm it in the terminal) → write the migration record `<state directory>/chains/<id>/migrate-exit.env`, back up the configuration as `<id>.env.bak.<time>` and rewrite its four lines `EXIT_HOST` / `EXIT_SSH_PORT` / `EXIT_SSH_KEY` / `EXPECTED_EXIT_IPV4` → install the pinned sing-box on the new machine, move the old machine's configuration over through your computer's memory (never written to your disk), keep the original port (or pick another if it is taken) and start the service → pre-switch probes (exit IP, a Reality handshake to the new machine through the relay, rejection of non-relay sources) → switch the relay's forwarding target to the new machine (the relay restarts once, dropping connections in flight; clients reconnect automatically) → commit the local state after checking (the old state is archived to `audit/migrated.<deployment ID>.<operation ID>/`) → stop and delete this chain's service, configuration, units and allow-list on the old exit → an automatic full verify. On success stdout prints `migrate=done chain=<id> exit=<new IP>:<port> old_exit_cleanup=done`.

If interrupted, rerun the same command (with the same `--to`): progress is judged from the live situation (configuration, state, which exit the relay points at), and completed steps are not redone. Before the relay is switched you can `--abort`: the half-built pieces on the new machine are removed, the original configuration is restored and the chain is back on the old exit, printing `migrate=aborted`; once the relay has been switched, the migration can only be completed. While a migration is in progress, `status` prints `status=drifted reason=exit-migration-pending next=rerun-interrupted-command`, and deploy, rollback, rebaseline, rotate-keys, add-device and remove-device refuse to run. If SSH to the old machine fails during cleanup, it prints `old_exit_cleanup=pending` and keeps the record; rerun once the old machine is back to finish. If it is gone for good, use `--abandon-cleanup` (this chain's configuration, including the private key, remains on the old machine — destroy that machine yourself).

When several chains share this exit, migrate them one by one; multi-chain aggregation requires the same exit IP across chains, so `multi_chain_client.sh … render` again only after all of them are migrated. Exit codes: 0 success; 2 argument errors, `--to` is the current exit / the relay / the same machine, a different `--to` on rerun, or `--abort` after the relay was switched; 3 the new or old machine is unreachable, key setup failed, or a host fingerprint does not match; 4 the new machine already has this chain's files; 5 lock, corrupted state, an unhealthy old chain or an unfinished operation; 1 a remote operation, check or local commit failed.

`status`, `verify` without `--with-fail-closed`, `conns` and `banlist` are read-only: when SSH returns 255 (a connection-level failure) and it is not the control machine's 600-second timeout, they retry up to 3 times (3 / 6 seconds apart) and print `[ssh-retry] role=… attempt=n/3` on stderr; the relay smoke inside verify is not retried. Other commands do not retry.

Note: when your computer runs a TUN mode such as Clash's, SSH to the relay may also be taken over by the proxy, and any SSH drop during deployment makes the command stop with exit code 3 (in read-only phases) or leave a transaction to recover (converged by the next deploy / rollback from the transaction record). At the moment the relay restarts or the client switches between chains, the control machine's SSH is cut, and the final verify may report drift or leftovers. The state has already been committed by then, so just run `verify` again; to avoid it, turn TUN off before running, or route the relay's IP directly.

## Combining several chains for clients (`multi_chain_client.sh`)

The relay's IP is the most likely to be blocked. You can deploy one chain per relay (each with its own `--id`, all sharing the same exit), then combine each chain's `node.txt` into client artifacts with `multi_chain_client.sh`: Clash Verge / mihomo switch between chains automatically through a `fallback` auto group, and on iPhone you scan each chain and switch by hand. The script only reads the local `chains/<id>.env` and `chains/<id>/client/node.txt`; it connects to neither the relay nor the exit and does not change any chain's state.

```bash
# Per chain: a real Reality handshake from your computer + arbitration across three exit endpoints; with local TUN on, that chain is marked skipped (all skipped exits 5)
chain/multi_chain_client.sh --chains main,backup verify
# Combined output: nodes.txt (one vless per chain), clash-snippet.yaml (proxies + fallback auto group, to merge into Clash Verge by hand),
# and one QR code per chain (for iPhone Shadowrocket; delete the directory after scanning)
chain/multi_chain_client.sh --chains main,backup render
chain/multi_chain_client.sh --chains main,backup render --group url-test --no-qr
```

The order of `--chains` is the auto group's priority; `--name` sets the output directory `${XDG_STATE_HOME:-~/.local/state}/ownexit/multi-chain-client/<name>/` (default `all`). Node names are each chain's own `Exit-via-Relay-<id>` (delete the old single node of the same name before merging into Clash Verge), and the auto group is named `Exit-Relay-auto`. Every chain's `EXPECTED_EXIT_IPV4` must be the same. Exit codes: 0 success; 2 argument / configuration / `node.txt` validation errors, or exit IPs differing across chains; 5 a chain is unhealthy in `verify`, or all are skipped; 1 runtime failure.

After a relay changes IP or is blocked: deploy a new chain with a new `--id`, add it to `--chains`, roll back the old chain and remove it from the list, then `render` again and import.
