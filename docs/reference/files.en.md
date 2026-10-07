# File reference (frozen for 1.x)

**English** | [简体中文](files.md)

This file lists the files, keys and paths ownexit reads and writes on your computer and on the servers. Throughout 1.x these paths, keys and formats are only ever added to, never changed in meaning; items marked "reference" or "internal" are not part of the public interface. The compatibility rules are in [compatibility.en.md](compatibility.en.md). `scripts/check_interface.sh` compares the backticked first column of the tables in the Chinese edition against the source code automatically, and compares this English edition's first columns against the Chinese edition.

## Local directories

| Directory | Default | Notes |
| ---- | ---- | ---- |
| Config directory | `~/.config/ownexit/` | Affected by `XDG_CONFIG_HOME` |
| State directory | `~/.local/state/ownexit/` | Affected by `XDG_STATE_HOME`; the `ownexit/` level must be 700 (the chain script keeps its global lock here) |
| Cache directory | `~/.cache/ownexit/` | Affected by `XDG_CACHE_HOME`; safe to delete, re-downloaded when needed |
| Key directory | `~/.ssh/ownexit/` | Not affected by XDG; one `id_ed25519_<safe_name>` (and `.pub`) per server |

`safe_name` = `<user>_<address>_<port>`, with every character other than letters, digits, `_` `.` `@` `-` replaced by `_`. For how the XDG variables are interpreted see [commands.en.md](commands.en.md#environment-variables).

## Direct (local)

| Path (relative to the config / state directory) | Contents |
| ---- | ---- |
| `direct/<safe_name>.env` (config directory) | The remembered target; only the keys `HOST` / `SSH_PORT` / `SSH_USER` are allowed |
| `direct/<safe_name>/state.env` (state directory) | Subscription parameters: `SUB_PORT`, `TOKEN` (32 hex characters) |
| `direct/<safe_name>/devices.env` (state directory) | The subscription TOKEN of each extra device, one `name=TOKEN` per line; lines starting with `!` are old TOKENs waiting to be deleted on the VPS |
| `direct/<safe_name>/ownexit-subscription/<TOKEN>/` (state directory) | The locally rendered subscription (the copy synced to the VPS); `ownexit direct qr` reads the default `node.txt` in it |

## Relay chain (local)

| Path | Contents |
| ---- | ---- |
| `<config dir>/chains/<id>.env` | Chain configuration; keys in "Chain configuration keys" below |
| `<state dir>/chains/<id>/state.env` | Authoritative deployment state with an embedded checksum; keys in "Chain state.env keys (reference)" |
| `<state dir>/chains/<id>/client/node.txt` | The default device's node: one vless URI line, fragment `#Exit-via-Relay-<id>` |
| `<state dir>/chains/<id>/devices/devices.env` | Extra devices, one `name=UUID` per line (default excluded); a local cache of the exit's configuration |
| `<state dir>/chains/<id>/devices/node-<name>.txt` | An extra device's node: one vless URI line, fragment `#Exit-via-Relay-<id>_<name>` |
| `<state dir>/chains/<id>/blacklist.txt` | The authoritative local copy of the relay blocklist |
| `<state dir>/chains/<id>/migrate-exit.env` | Exit migration record (since 1.1.0); exists only while a `migrate-exit` is in progress or the old exit awaits cleanup; KEY=VALUE, 600, empty values written as `-`; while it exists, status prints `reason=exit-migration-pending` |
| `<config dir>/chains/<id>.env.bak.<time>` | Backup taken before `migrate-exit` rewrites the configuration (600; not deleted automatically after migrating) |
| `<state dir>/multi-chain-client/<name>/nodes.txt` | `ownexit multi render`: one vless URI per chain |
| `<state dir>/multi-chain-client/<name>/clash-snippet.yaml` | `ownexit multi render`: proxies and auto group snippet |
| `${TMPDIR:-/tmp}/multi-chain-client-qr.*/qr-<n>-<node name>.png` | QR codes from `ownexit multi render` (`--qr-out` chooses the directory; they contain plain-text credentials, delete after scanning) |
| `<cache dir>/chains/<id>/downloads/` | Cache of the pinned official sing-box packages |

Internal files (not part of the public interface, but 1.y must be able to read what 1.x wrote): under `<state dir>/chains/<id>/`, `transaction.env`, `baseline/`, `audit/`, `operation.lock`, `active-child.env`, `local-process.env` and the various temporary files starting with `.` (including `.migrate-exit.env.*.tmp`); under `<state dir>/`, `shared.lock`.

### Chain configuration keys

| Key | Value / meaning |
| ---- | ---- |
| `CHAIN_ID` | Chain name, `[a-z0-9][a-z0-9-]{0,31}`, same as the file name |
| `RELAY_HOST` | The relay's IPv4 |
| `RELAY_SSH_PORT` | The relay's SSH port |
| `RELAY_SSH_USER` | The relay's SSH user (must be root) |
| `RELAY_SSH_KEY` | Absolute path of the relay's private key |
| `EXIT_HOST` | The exit's IPv4 (the relay logs in to the exit through it) |
| `EXIT_SSH_PORT` | The exit's SSH port |
| `EXIT_SSH_USER` | The exit's SSH user (must be root) |
| `EXIT_SSH_KEY` | Absolute path of the exit's private key |
| `EXPECTED_EXIT_IPV4` | The expected public exit IPv4 |
| `REALITY_SERVER_NAME` | Reality camouflage domain (ASCII FQDN) |
| `RELAY_COHOSTS_SINGBOX` | Existing sing-box on the relay: `yes` (233boy install) / `ownexit-direct` (ownexit direct) / `no` (none) |
| `EXIT_SOURCE_FILTER` | How the exit's Reality port admits only the relay: `managed` (this project adds an nft allow-list) / `provider` (the provider's security group handles it) / `none` |

The configuration must contain exactly these 13 keys; keys added within 1.x must be optional (behaving as before when absent).

### Chain state.env keys (reference)

`state.env` is written by ownexit with an embedded checksum; external programs should not read or modify it directly. What is frozen is the meaning of `SCHEMA_VERSION=1` and the promise that "1.y can read the state 1.x wrote"; the key table below is for reference only, and the check script keeps it from changing silently.

| Key |
| ---- |
| `SCHEMA_VERSION` |
| `STATUS` |
| `CHAIN_ID` |
| `DEPLOYMENT_ID` |
| `CONFIG_SHA256` |
| `RELAY_HOST` |
| `RELAY_SSH_PORT` |
| `RELAY_SSH_USER` |
| `RELAY_HOSTKEY_FINGERPRINT` |
| `RELAY_SSH_KEY_PATH` |
| `RELAY_SSH_KEY_FINGERPRINT` |
| `EXIT_HOST` |
| `EXIT_SSH_PORT` |
| `EXIT_SSH_USER` |
| `EXIT_HOSTKEY_FINGERPRINT` |
| `EXIT_SSH_KEY_PATH` |
| `EXIT_SSH_KEY_FINGERPRINT` |
| `EXPECTED_EXIT_IPV4` |
| `REALITY_SERVER_NAME` |
| `RELAY_COHOSTS_SINGBOX` |
| `RELAY_PORT` |
| `EXIT_REALITY_PORT` |
| `SING_BOX_VERSION` |
| `LINUX_ARCHIVE_SHA256` |
| `LINUX_BINARY_SHA256` |
| `DARWIN_ARCHIVE_SHA256` |
| `DARWIN_BINARY_SHA256` |
| `VLESS_UUID` |
| `REALITY_PUBLIC_KEY` |
| `REALITY_SHORT_ID` |
| `RELAY_OWNER_SHA256` |
| `RELAY_SOCKET_SHA256` |
| `RELAY_SERVICE_SHA256` |
| `RELAY_ENABLE_LINK_TARGET` |
| `RELAY_ENABLE_LINK_SHA256` |
| `EXIT_OWNER_SHA256` |
| `EXIT_EXIT_SHA256` |
| `EXIT_SERVICE_SHA256` |
| `EXIT_ENABLE_LINK_TARGET` |
| `EXIT_ENABLE_LINK_SHA256` |
| `RELAY_BASELINE_CONFIG_MANIFEST_SHA256` |
| `RELAY_BASELINE_LISTEN_SHA256` |
| `RELAY_BASELINE_BINARY_MANIFEST_SHA256` |
| `RELAY_BASELINE_UNIT_MANIFEST_SHA256` |
| `RELAY_BASELINE_SERVICE_ACTIVE` |
| `RELAY_BASELINE_SERVICE_ENABLED` |
| `NODE_SHA256` |
| `CREATED_AT` |
| `PAYLOAD_SHA256` |

## Direct (server)

| Path | Contents |
| ---- | ---- |
| `/etc/ownexit-direct/config.json` | sing-box server configuration (root 600, contains the private key); each users entry is `{ "name": …, "uuid": …, "flow": … }`, the first being default |
| `/etc/ownexit-direct/client.env` | Public client parameters (root 600, no private key), keys in "Direct client.env keys" below; your computer reads the parameters back from here each time it renders the subscriptions |
| `/etc/ownexit-direct/devices.env` | Extra devices, one `name=UUID` per line (default excluded); absent when there are no extra devices |
| `/etc/systemd/system/ownexit-direct.service` | The proxy service |
| `ownexit-subscription-ttl.timer` / `.service` | Transient units that turn the subscription service off automatically (created by `systemd-run`, nothing on disk); exist only after `--sub-ttl` / `direct sub start --ttl`, run `systemctl stop ownexit-subscription` when due, and disappear when the VPS reboots |
| `/etc/systemd/system/ownexit-subscription.service` | The subscription service (`python3 /opt/ownexit-subscription/subserver.py`, running as nobody; before 1.3.0 it was `python3 -m http.server`, and running `ownexit direct` once switches it) |
| `/opt/ownexit-subscription/` | Subscription directory: one subdirectory per TOKEN (files in "Subscription files"), the service script `subserver.py`, and an empty `index.html` (since 1.3.0 the script answers only allow-listed paths and returns 404 for the root and everything else; index.html is kept but no longer needed to prevent directory listing) |
| `/var/backups/ownexit-direct/233boy-<time>.tar.gz` | The 233boy backup taken before `--migrate` (contains the old private key; never deleted by any operation) |

Subscription URL: `http://<VPS address>:<SUB_PORT>/<TOKEN>/<file name>`. The default device uses the TOKEN in `state.env`; each extra device uses its own TOKEN. Since 1.3.0 there is also an adaptive URL `http://<VPS address>:<SUB_PORT>/<TOKEN>/sub` (not a file): a User-Agent containing clash / mihomo / stash / verge gets `clash.yaml`, one containing sing-box / singbox or starting with sfa/, sfi/ or sfm/ gets `sing-box.json`, and everything else gets `shadowrocket.txt`. Every other path returns 404.

Internal (not part of the public interface): the binary layout under `/opt/ownexit-direct/bin/` and the operation working directory under `/var/lib/ownexit-direct/`.

### Direct client.env keys

| Key | Meaning |
| ---- | ---- |
| `PORT` | Proxy port |
| `UUID` | The default device's UUID |
| `PUBLIC_KEY` | Reality public key |
| `SHORT_ID` | Reality short id (may be empty for migrated nodes) |
| `SNI` | Reality camouflage domain |
| `FLOW` | VLESS flow (usually xtls-rprx-vision; may be empty) |
| `LISTEN` | Server listen address |
| `SOURCE` | Where the parameters came from: fresh (new install) / migrated (from 233boy) |

### Subscription files

| File | For |
| ---- | ---- |
| `clash.yaml` | Clash Verge / mihomo / Clash Meta for Android: a complete loadable configuration, group name `PROXY` |
| `shadowrocket.txt` | Shadowrocket, v2rayN / v2rayNG: a base64-encoded list of vless links |
| `sing-box.json` | Official sing-box clients (1.12 or later): a complete configuration |
| `node.txt` | One plain vless URI line |

File names, node names, group names and "importable by the matching client" are frozen; other fields in the files may evolve compatibly.

## Relay chain (server)

| Machine | Path / name | Contents |
| ---- | ---- | ---- |
| Relay, exit | `/etc/ownexit-chain/<id>.owner.env` | This chain's ownership record |
| Exit | `/etc/ownexit-chain/<id>.exit.json` | sing-box server configuration (root 600, contains the private key); one users line, each entry `{ "name": …, "uuid": …, "flow": "xtls-rprx-vision" }`, the first being default (the single entry of deployments from v0.6.0 or earlier has no name) |
| Exit | `ownexit-chain-exit-<id>.service` | The exit service |
| Exit | nft table `inet ownexit_<id with - replaced by _>` | The allow-list that starts and stops with the exit service when `EXIT_SOURCE_FILTER=managed` |
| Relay | `ownexit-chain-relay-<id>.socket` / `ownexit-chain-relay-<id>.service` | systemd-socket-proxyd forwarding |
| Relay | `<the units above>.d/50-ownexit-chain-blacklist.conf` | Blocklist drop-in (`IPAddressDeny=`) |

Internal (not part of the public interface): the binary layout under `/opt/ownexit-chain/bin/`, the helper files starting with `<id>.rotate.` and the `.stage-*` staging directories under `/etc/ownexit-chain/`.

## Node and group names

| Name | Source |
| ---- | ---- |
| `ownexit-direct` | Direct default device |
| `ownexit-direct-<name>` | Direct extra device |
| `Exit-via-Relay-<id>` | Chain default device |
| `Exit-via-Relay-<id>_<name>` | Chain extra device |
| `PROXY` | The selector group in direct clash.yaml |
| `Exit-Relay-auto` | The auto group from `ownexit multi render` |
