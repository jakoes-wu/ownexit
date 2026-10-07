# Command reference (frozen for 1.x)

**English** | [简体中文](commands.md)

This file lists, item by item, the options, subcommands, exit codes and machine-readable output of each `ownexit` subcommand. Throughout 1.x these items are only ever added to, never changed in meaning; the compatibility rules are in [compatibility.en.md](compatibility.en.md). `scripts/check_interface.sh` compares the backticked first column of the tables in the Chinese edition against the source code automatically, and compares this English edition's first columns against the Chinese edition.

Every subcommand prints its help and exits 0 when given `-h` / `--help` alone (help text is not frozen); the chain script shows help only for a lone `--help`, rejects `chain init --help` with exit code 2, and prints help with exit 0 for `chain up --help`. For a git clone, the script behind each subcommand is named under each section heading, and its options are identical to `ownexit <subcommand>`.

The scripts' human-readable progress and log lines follow `OWNEXIT_LANG` / the system language (see Environment variables); none of them are frozen.

## ownexit (entry point)

Script: `src/ownexit/cli.py`. Forwards subcommands unchanged to the bundled scripts.

| Usage | Effect |
| ---- | ---- |
| `ownexit -h` / `ownexit --help` / `ownexit help` | Prints the list of subcommands, exits 0 |
| `ownexit` (no arguments) | When standard input and output are both terminals, starts the guided setup: first choose a language (skipped when `OWNEXIT_LANG` is zh / en), then direct or relay chain, IP and SSH port, then hands over to `direct` or `chain up`; cancelling exits 130 (Ctrl+C) or 1 (end of input). Otherwise prints the list of subcommands and exits 0 |
| `ownexit -V` / `ownexit --version` | Prints `ownexit <version>`, exits 0 |
| `ownexit <subcommand> …` | Forwards to the matching script; the exit code is the script's |

Exit codes of the entry point itself: 2 for an unknown subcommand; 1 when a bundled script is missing or bash cannot be found; 130 when the guided setup is cancelled with Ctrl+C, 1 at end of input (Ctrl+D). The guided setup's prompts are not frozen.

## ownexit direct

Script: `direct/setup_direct.sh`. Deploys / reuses / reconfigures / migrates / uninstalls a direct exit and renders the subscriptions; day-to-day operations (formerly `ownexit subctl`) also start here.

### Subcommands

Subcommands may appear before or after options. No subcommand means `up`.

| Subcommand | Effect |
| ---- | ---- |
| `up` | Deploy / reuse (accepts `--host` `--sni` `--proxy-port` `--sub-ttl` `--allow-tun`); cannot be combined with the maintenance subcommands below |
| `rotate-keys` | Regenerates the UUID and Reality key / short id of every device (same as `--rotate-keys`) |
| `rotate-token` | Regenerates the subscription TOKEN and port (same as `--rotate-token`) |
| `add-device` | Adds a device, followed by its name (same as `--add-device`) |
| `remove-device` | Revokes a device, followed by its name (same as `--remove-device`) |
| `migrate` | Migrates an old 233boy install to ownexit-direct (same as `--migrate`) |
| `uninstall` | Removes the direct service and the subscription service (same as `--uninstall`) |
| `sub` | Followed by `start [--ttl <duration>]` or `stop`: turns the subscription service on or off (same as subctl start / stop) |
| `status` | Shows the status of the proxy service and the subscription service (same as subctl status) |
| `log` | Shows the proxy service log, optionally followed by a line count (same as subctl log) |
| `qr` | Shows the default device's node QR code in the terminal (same as subctl qr) |
| `devices` | Read-only list of devices and subscription URLs (same as subctl devices) |
| `login` | Logs in to the VPS with the key (same as subctl login) |

`sub` / `status` / `log` / `qr` / `devices` / `login` are day-to-day operations: they are handed over entirely to `direct/subctl`, and the exit code is subctl's (see the ownexit subctl section below). Only `--host` / `--user` / `--port` may come before them; `up`, a maintenance subcommand or a deployment option before them exits 2. Arguments after them are passed to subctl unchanged for it to validate.

### Options

| Long option | Short | Meaning |
| ---- | ---- | ---- |
| `--host` | | VPS address; without it the single remembered target is used, otherwise it asks interactively (exits 2 when not in a terminal) |
| `--user` | `-u` | SSH user, default root |
| `--port` | `-P` | SSH port, default 22 |
| `--sni` | | Reality camouflage domain (default for new installs: www.amazon.com) |
| `--proxy-port` | | Proxy port (default for new installs: random in 20000-59999) |
| `--sub-ttl` | | How long after starting the subscription service turns itself off (`<positive integer>[s/m/h]`, minutes when no unit is given, 1 minute to 24 hours); without it the service is not turned off automatically |
| `--migrate` | | Deprecated: use the `migrate` subcommand (still works; prints the new form on stderr) |
| `--uninstall` | | Deprecated: use the `uninstall` subcommand |
| `--rotate-token` | | Deprecated: use the `rotate-token` subcommand |
| `--rotate-keys` | | Deprecated: use the `rotate-keys` subcommand |
| `--add-device` | | Deprecated: use the `add-device` subcommand (device names `[a-z0-9][a-z0-9-]{0,31}`, not default) |
| `--remove-device` | | Deprecated: use the `remove-device` subcommand |
| `--allow-tun` | | When the route from this computer to the VPS goes through a proxy TUN, deployment is refused by default (exit 1); this option only warns and continues |

Mutual exclusions (a subcommand and its old option are equivalent): `migrate`, `uninstall` and `rotate-token` exclude each other; `rotate-keys` cannot be combined with `migrate` / `uninstall`; `add-device` and `remove-device` exclude each other and cannot be combined with `migrate` / `uninstall`; `--sni` / `--proxy-port` / `--sub-ttl` cannot be combined with `uninstall`; `up` cannot be combined with the maintenance subcommands.

### Exit codes

| Code | Meaning |
| ---- | ---- |
| 0 | All checks passed |
| 1 | Deployment failed or a check did not pass; the pre-deploy check found the route to the VPS going through TUN without `--allow-tun` |
| 2 | Argument error, missing argument (when not in a terminal), the server runs the old 233boy install and needs `--migrate`, or a refused device operation (already exists / does not exist / over the limit) |

### Output

Lines starting with `[*]` / `[+]` / `[!]` are progress for humans and are not frozen. What is frozen is the exit code and the generated subscriptions (paths and files in [files.en.md](files.en.md)).

## ownexit subctl

Script: `direct/subctl`. Day-to-day operations after a direct deployment. **Deprecated** (still works, may be removed in 2.0 at the earliest): use the `ownexit direct` subcommands instead (start / stop → `sub start` / `sub stop`, the rest keep their names). When called directly it prints one deprecation line on stderr; when reached through `ownexit direct` it does not.

### Options

| Long option | Short | Meaning |
| ---- | ---- | ---- |
| `--host` | | Target VPS; without it the single remembered target is used |
| `--port` | | SSH port, default 22 |
| `--user` | | SSH user, default root |
| `--ttl` | | Only with `start`: how long until the subscription service turns itself off (same format as direct's `--sub-ttl`) |

### Subcommands

| Subcommand | Effect |
| ---- | ---- |
| `login` | Logs in to the VPS with the key (default) |
| `start` | Starts the subscription service (accepts `--ttl`; cancels the previous auto-off timer first) |
| `stop` | Stops the subscription service |
| `status` | Shows the status of the proxy service and the subscription service |
| `log` | Shows the proxy service log, optionally followed by a line count (default 100) |
| `qr` | Shows the default device's node QR code in the terminal (reads the local subscription; needs qrencode) |
| `devices` | Read-only list of the devices on the VPS and the subscription URLs recorded locally |

There is also `help` (same as `-h` / `--help`).

### Exit codes

| Code | Meaning |
| ---- | ---- |
| 0 | Success |
| 1 | A remote operation failed or the key is missing |
| 2 | Argument error, or the target cannot be determined |

## ownexit connect

Script: `direct/connect_to.sh`. Sets up a dedicated SSH key for a server (called automatically by `ownexit direct` and `ownexit chain init`). Since 1.5.0 it is not listed in `ownexit --help`, but it still works.

### Options

| Long option | Short | Meaning |
| ---- | ---- | ---- |
| `--host` | | Server address |
| `--user` | `-u` | SSH user, default root |
| `--port` | `-P` | SSH port, default 22 |
| `--setup-only` | | Only set up and verify key login; do not open an interactive SSH session |

### Exit codes

| Code | Meaning |
| ---- | ---- |
| 0 | Success |
| 1 | Other failures |
| 2 | Argument error, or not running in a terminal and `OWNEXIT_SSH_PASSWORD` is not set |
| 3 | Login failed; the last line on stderr is `reason=<value>` |

### Output

With exit code 3, the last line on stderr is frozen (`ownexit direct` and `ownexit chain init` parse it).

#### reason values

| Value | Meaning |
| ---- | ---- |
| `reason=bad-password` | Wrong password |
| `reason=password-disabled` | The server has password login turned off |
| `reason=unreachable` | Cannot connect (IP / port / security group) |

## ownexit chain

Script: `chain/setup_chain.sh`. Relay + exit chain. Apart from `init` / `up`, every subcommand needs the configuration given with `--id <name>` or `--config <absolute path>` (one or the other), placed before the subcommand; while there is only one chain configuration on this computer it can be omitted (with none or several it exits 2 and says so).

### Options

| Long option | Applies to | Meaning |
| ---- | ---- | ---- |
| `--id` | global / init | Chain name `[a-z0-9][a-z0-9-]{0,31}`; as a global option it means `--config <config dir>/ownexit/chains/<name>.env`; for init it defaults to main |
| `--config` | global | Absolute path of the configuration file |
| `--relay` | init | The relay's IPv4 (asked interactively if omitted) |
| `--exit` | init | The exit's IPv4 (asked interactively if omitted) |
| `--relay-port` | init | The relay's SSH port, default 22 |
| `--exit-port` | init | The exit's SSH port, default 22 |
| `--sni` | init | Reality camouflage domain, default www.amazon.com |
| `--exit-source-filter` | init | managed (default) / provider / none |
| `--with-fail-closed` | verify | Also verifies that nothing leaks out of the exit while the relay is stopped |
| `--allow-tun` | deploy / up (accepted but ignored by init) | When the route from this computer to a server goes through a proxy TUN, it refuses by default (exit 3); this option only warns and continues |
| `--device` | qr | Shows that device's node QR code; without it shows default |
| `--to` | migrate-exit | The new exit's IPv4; excludes `--abort` and `--abandon-cleanup` |
| `--to-port` | migrate-exit | The new exit's SSH port, default 22; only together with `--to` |
| `--abort` | migrate-exit | Gives up the migration before the relay is switched and restores the original configuration |
| `--abandon-cleanup` | migrate-exit | Gives up cleanup when the migration is committed and the old exit is permanently unreachable |

### Subcommands

| Subcommand | Effect |
| ---- | ---- |
| `init` | Sets up key login, detects the exit IP and the relay's current state, and writes the chain configuration |
| `up` | init (when there is no configuration) + deploy + print the QR code and next steps; accepts all init options and `--allow-tun`; can be rerun — continues when a configuration exists and the explicitly given addresses / ports match, exits 2 when they differ; without IPs and with a single chain on this computer it reuses that chain |
| `qr` | Shows the default node's QR code (`--device <name>` for a device); only reads the local node file, does not connect to the servers |
| `preflight` | Read-only pre-check |
| `deploy` | Transactional deployment |
| `verify` | Full verification (optionally `--with-fail-closed`) |
| `status` | Health status (machine-readable output below) |
| `rollback` | Transactional teardown |
| `conns` | Connections per source IP on the relay port |
| `kick` | Drops a source's established connections (followed by an IPv4) |
| `ban` | Blocks a source (followed by an IPv4 or CIDR) |
| `unban` | Unblocks a source (followed by an IPv4 or CIDR) |
| `banlist` | Compares the local and relay blocklists |
| `rehost-exit` | Deprecated (still works, prints a notice on stderr): migrates in place after the exit got a new IP on the same machine, after editing the configuration by hand; use `migrate-exit` instead |
| `rebaseline` | Re-registers the existing sing-box on the relay |
| `rotate-keys` | Replaces the UUID and Reality key / short id of every device |
| `add-device` | Adds a device (followed by its name) |
| `remove-device` | Revokes a device (followed by its name) |
| `list-devices` | Read-only list of devices |
| `migrate-exit` | The exit got a new IP or moved to another machine; credentials and clients stay the same (followed by `--to` / `--abort` / `--abandon-cleanup`); when the new address is the same machine it switches over in place automatically (the SSH port must stay the same, otherwise exit 2), and the old IP need not be reachable |

### Exit codes

| Code | Meaning |
| ---- | ---- |
| 0 | Success, or `status` is deployed / not_deployed |
| 1 | Runtime failure (remote operation, local commit and so on) |
| 2 | Argument error, configuration not matching state, refused device operation; with `--id` omitted, no configuration or several; `up` with an existing configuration but different addresses; `qr` with no such device |
| 3 | Failed pre-check / check, unreachable server or mismatching host fingerprint (any `preflight` failure is 3; failed key setup or probes in `init` / `up` are 3 too); the pre-deploy check of `deploy` / `up` found a route through TUN without `--allow-tun` |
| 4 | The deployment phase of `deploy` / `up` failed (unreachable servers are still 3; refusal during an exit migration is also 4); `migrate-exit` found this chain's files on the new exit |
| 5 | `status` unhealthy (busy / stale_lock / incomplete / unreachable / orphaned / drifted), `verify` failed; for `qr`: chain not deployed, lock busy / stale, or node file not matching state; for other commands: lock, corrupted state, unfinished transaction or failed final verify; rehost-exit / rebaseline / rotate-keys / add-device / remove-device refused during an exit migration |
| 6 | `rollback` pre-check or execution failed (including refusal during an exit migration) |

### Output

The following lines on stdout are frozen; `[chain][<subcommand>] INFO / WARN / ERROR …` on stderr is logging and is not frozen.

`status` prints one line of the form `status=<status> [health=…] [role=…] [reason=…] [next=…] [deployment=…] [operation=… step=…]`. The table below lists the frozen values of `status` / `health` / `role` / `reason` / `next`; for `deployment=` (the first 12 characters of the deployment ID), `operation=` and `step=` only the key names are frozen. Adding values is a compatible change, and parsers should treat unknown values as "needs a human to look".

#### status values

| Value | Meaning |
| ---- | ---- |
| `status=deployed` | Deployed and healthy (also prints `health=healthy deployment=…`) |
| `status=not_deployed` | No active state and no chain-specific resources |
| `status=busy` | The same chain holds an active lock |
| `status=stale_lock` | The lock's identity is no longer valid |
| `status=incomplete` | A transaction is waiting to be recovered (also prints `operation=` `step=`) |
| `status=unreachable` | At least one server cannot be verified (also prints `role=`) |
| `status=orphaned` | No state, but chain-specific objects or staging directories exist |
| `status=drifted` | There is state, but hashes, permissions, units, listeners or the baseline do not match |
| `health=healthy` | Healthy |
| `role=relay` | The problem is on the relay |
| `role=exit` | The problem is on the exit |
| `reason=transaction-corrupt` | The transaction file is corrupted |
| `reason=local-ssh-config-render` | Generating the local isolated SSH configuration failed |
| `reason=local-stage-temp-or-artifact-present` | No state, but there is local staging or output |
| `reason=resource-absence-probe` | A server was unreachable while verifying that chain-specific resources are absent |
| `reason=deterministic-resource-or-owned-stage-present` | No state, but a server has this chain's resources or staging |
| `reason=state-corrupt` | state.env is corrupted |
| `reason=state-config-binding` | The state does not match the current configuration (or sing-box version) |
| `reason=state-value-format` | A state field has the wrong format |
| `reason=hostkey-probe` | Unreachable while probing the host fingerprint |
| `reason=ssh-key-or-hostkey-binding` | The SSH key or host fingerprint does not match the state |
| `reason=binding-probe` | The binding check failed unexpectedly |
| `reason=platform-preflight` | Platform pre-check failed or a server was unreachable |
| `reason=local-artifacts` | Local output does not match the state |
| `reason=baseline` | The baseline of the relay's existing sing-box changed, or the relay was unreachable |
| `reason=residue-probe` | Unreachable while checking for leftovers |
| `reason=deployment-residue` | Deployment leftovers exist |
| `reason=resource-probe` | Unreachable while verifying resources |
| `reason=exit-op-pending` | The exit has an unfinished credential or device operation |
| `reason=exit-migration-pending` | An exit migration is in progress (there is a local migration record) |
| `reason=remote-resource-unit-process-or-listener` | Remote files, units, processes or listeners do not match |
| `next=run-mutating-command` | Run a modifying command (deploy / rollback) to converge the transaction or archive the old lock |
| `next=inspect-transaction` | Inspect the transaction file by hand |
| `next=check-config` | Check the configuration |
| `next=inspect-local-state` | Inspect the local state directory by hand |
| `next=retry-status` | Retry status later |
| `next=inspect-orphan` | Inspect the orphaned resources by hand |
| `next=inspect-state` | Inspect state.env by hand |
| `next=inspect-binding` | Inspect the keys / host fingerprints by hand |
| `next=inspect-platform` | Inspect the server platform by hand |
| `next=inspect-baseline` | Check the relay's existing sing-box (rebaseline if needed) |
| `next=inspect-residue` | Inspect the leftovers by hand |
| `next=rerun-interrupted-command` | Rerun the interrupted rotate-keys / add-device / remove-device / migrate-exit (a migration can also use `--abort` / `--abandon-cleanup`) |
| `next=run-verify` | Run verify for details |

#### Other command output

| Line starts with | Full line | Command |
| ---- | ---- | ---- |
| `rotate=done` | `rotate=done chain=<chain> result=<fresh / resumed / already / resumed-after-commit>` | rotate-keys |
| `device=added` | `device=added chain=<chain> name=<name> node=<path> result=<…>` | add-device |
| `device=removed` | `device=removed chain=<chain> name=<name> result=<…>` | remove-device |
| `rehost=noop` | `rehost=noop chain=<chain> next=run-verify` | rehost-exit, migrate-exit (the same-machine switch is already done, nothing to migrate) |
| `rebaseline=noop` | `rebaseline=noop chain=<chain> kind=<yes / ownexit-direct / no>` | rebaseline (nothing to re-register) |
| `banlist=consistent` | `banlist=consistent entries=<count>` | banlist |
| `banlist=inconsistent` | `banlist=inconsistent next=run-ban-or-unban` | banlist |
| `kicked` | `kicked ip=<IP> destroyed=<count>` | kick |
| `banned` | `banned entry=<entry> entries=<count> destroyed=<count>` | ban |
| `already-covered` | `already-covered entry=<entry> by=<existing entry>` | ban (when already covered) |
| `unbanned` | `unbanned entry=<entry> entries=<count>` | unban |
| `migrate=done` | `migrate=done chain=<chain> exit=<new exit IP>:<port> old_exit_cleanup=<done / pending>` | migrate-exit |
| `migrate=aborted` | `migrate=aborted chain=<chain>` | migrate-exit --abort |
| `migrate=rehosted` | `migrate=rehosted chain=<chain> exit=<new exit IP>:<port>` | migrate-exit (the new address is the same exit; the in-place switch is complete) |

The leading key and its values are frozen; for the remaining keys only the key names are frozen, and their order is not promised.

#### Other output (checked by hand)

| Command | Output |
| ---- | ---- |
| list-devices | One line per device, `device=<name> node=<path>`; when the local node file is missing, node starts with `missing` (the hint text after it is not frozen) |
| conns | Header `ip conns idle_min_s idle_max_s banned`, one line per source, and a last line `proxyd_fd=<used>/<limit> established=<count> peers=<count> port=<port>` |
| banlist | Three read-back lines `local:` / `socket:` / `service:` before the `banlist=` line |
| init | On success the last line is `[chain][init] next=<script name> --id <chain> deploy` (stdout) |
| deploy / up | On success (including the idempotent no-op when already deployed) stdout prints a "next steps" block: the `vless://` node link, the exit IP you should see, `ownexit doctor`, and a terminal QR code when qrencode is installed |
| qr | A terminal QR code when qrencode is installed; otherwise `node=<path>`, one line with the node link, and an install hint |

## ownexit multi

Script: `chain/multi_chain_client.sh`. Combines several chains into one set of client artifacts; only reads the local chain output and does not connect to any server.

### Options

| Long option | Short | Meaning |
| ---- | ---- | ---- |
| `--chains` | | Comma-separated chain names; the order is the auto group's priority (required) |
| `--name` | | Output directory name, default all |
| `--group` | | Auto group type: fallback (default) / url-test |
| `--test-url` | | The auto group's health-check URL, default https://www.gstatic.com/generate_204 |
| `--interval` | | The auto group's health-check interval (seconds), default 300 |
| `--qr-out` | | QR code output directory (must not exist); by default a new one under `${TMPDIR:-/tmp}` |
| `--no-open` | | Do not open the QR code directory automatically |
| `--no-qr` | | Do not generate QR codes |

### Subcommands

| Subcommand | Effect |
| ---- | ---- |
| `verify` | Per chain, a real Reality handshake and exit arbitration from this computer |
| `render` | Generates the combined artifacts (files listed in files.en.md) |

### Exit codes

| Code | Meaning |
| ---- | ---- |
| 0 | Success |
| 1 | Runtime failure (missing local dependency, rendering) |
| 2 | Argument / configuration / node.txt validation error, or EXPECTED_EXIT_IPV4 differs across chains |
| 5 | A chain is unhealthy in verify, or all are skipped |

### Output

The following lines on stdout with the `[multi-chain-client]` prefix are frozen (everything else is logging):

| Line | Description |
| ---- | ---- |
| `[multi-chain-client] verify chain=<chain> addr=<relay address> result=<result> endpoints=<n>/3 elapsed=<seconds>s` | result ∈ ok / skipped / timeout / blocked / mismatch / error |
| `[multi-chain-client] render nodes=<path>` | Node list file |
| `[multi-chain-client] render clash_snippet=<path>` | Clash snippet file |
| `[multi-chain-client] render qr_dir=<path>` | QR code directory (when QR codes are generated) |

## ownexit doctor

Script: `direct/doctor.sh`. Read-only diagnostics of this computer, direct VPSes and chains, with an optional exit IP check and camouflage domain scan.

### Options

| Long option | Short | Meaning |
| ---- | ---- | ---- |
| `--host` | | Check only this direct VPS |
| `--port` | | With `--host`: SSH port, default 22 |
| `--user` | | With `--host`: SSH user, default root |
| `--chain` | | Check only this chain (can be combined with `--host`) |
| `--ip-check` | | Also check the exit IP from the exit server |
| `--scan-sni` | | Also scan camouflage domains from the exit server |
| `--sni-candidates` | | With `--scan-sni`: comma-separated candidate domains (at most 30) |
| `--local-only` | | Check only this computer (cannot be combined with `--host` / `--chain` / `--ip-check` / `--scan-sni`) |

### Exit codes

| Code | Meaning |
| ---- | ---- |
| 0 | No FAIL (WARN allowed) |
| 1 | At least one FAIL |
| 2 | Argument error |

### Output

One line per check, starting with `[OK]` / `[WARN]` / `[FAIL]`; the last line is `doctor: ok=<n> warn=<n> fail=<n>`. These two formats are frozen; the wording of each check and the content of the IP check and scan sections are not.

## Environment variables

| Variable | Effect |
| ---- | ---- |
| `OWNEXIT_SSH_PASSWORD` | Supplies the root password for non-interactive key setup; used by `ownexit connect`, the first `ownexit direct` deployment and `ownexit chain init` (inherited by child processes) |
| `XDG_CONFIG_HOME` / `XDG_STATE_HOME` / `XDG_CACHE_HOME` | Change the configuration, state and cache directories. Chain and doctor: values that are not absolute paths are ignored and the defaults are used; direct: used as given |
| `TMPDIR` | Default output directory for `ownexit multi render` QR codes |
| `OWNEXIT_PYTHON` | The Python interpreter used to type the password during the first key setup (must be able to `import pexpect`). The `ownexit` entry point sets it to its own interpreter (unless already set); when running the scripts directly you can set it yourself, otherwise `python3` and then the system `expect` are tried |
| `OWNEXIT_LANG` | Sets the language of the entry point's help and guided setup: with `zh` / `en` that language is forced and the guided setup no longer asks for a language; unset or any other value picks the help language by whether `LC_ALL` → `LC_MESSAGES` → `LANG` starts with `zh`, and the guided setup asks for the language first (Enter accepts that detected language). From 1.7.0 it also sets the language of the scripts' help, progress and messages (including the server-side `[vps]` log lines); a language chosen in the guided setup is passed on to the scripts. Machine-readable output (`status=`, `reason=`, `health=` and other frozen keys and values) is the same in both languages |

`~/.ssh/ownexit/` (dedicated keys) is not affected by XDG. Variables starting with `OWNEXIT_TEST_` are test hooks, not part of the public interface; do not set them in normal use.
