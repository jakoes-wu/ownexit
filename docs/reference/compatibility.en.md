# Compatibility promise (1.x)

**English** | [简体中文](compatibility.md)

From 1.0.0, ownexit follows [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH. This file explains what 1.x promises, what it does not, and what to watch for when upgrading. The promised interfaces are listed item by item in [commands.en.md](commands.en.md) and [files.en.md](files.en.md).

## 1. What is frozen

Throughout 1.x the following interfaces only receive backward-compatible additions; nothing is removed, renamed or changed in meaning:

- Commands: the `ownexit` subcommands, each subcommand's options and subcommand names, the mutual-exclusion rules between options, and the exit codes and their meanings.
- Machine-readable output: the `status=` / `health=` / `role=` / `reason=` / `next=` values of the chain `status` line, the output lines of other commands (`rotate=` `device=` `rehost=` `rebaseline=` `banlist=` `migrate=` `kicked` `banned` `already-covered` `unbanned`), the `reason=` line when `ownexit connect` fails, the prefixed verify / render lines of `ownexit multi`, and the line prefixes and last-line format of `ownexit doctor`.
- Files: the paths, keys and formats of local configuration / state / subscription / device files; configuration files, systemd unit names and subscription paths on the servers; node names and group names.
- Environment variables: `OWNEXIT_SSH_PASSWORD`, the interpretation of the XDG variables, and the use of `TMPDIR`.

## 2. Compatible changes (allowed within 1.x)

- Adding subcommands, options, output lines or output keys.
- Adding values to existing output keys (for example new `reason=` / `next=` / `result=` values). Parsers should treat values they do not recognise as "needs a human to look", never as success.
- Adding optional configuration keys (behaving as before when absent).
- Adjusting other fields of the rendered client configurations (clash.yaml, sing-box.json and so on) as long as file names, node names and group names stay the same and the matching clients can still import them.
- Fixing bugs and improving logs and help text.

## 3. Incompatible changes (only in 2.0, with a migration path)

- Removing or renaming subcommands, options, output keys, configuration keys, files or paths.
- Changing the meaning of existing options, values or exit codes.
- Leaving existing deployments unmanageable after an upgrade (see section 5).

Anything to be removed is deprecated first: it keeps working for at least one minor version and the output suggests the replacement; it may be removed in the next major version at the earliest.

## 3a. Deprecated items

The following still work and print the replacement on stderr when used; they may be removed in 2.0 at the earliest.

| Deprecated | Replacement | Deprecated in |
| ---- | ---- | ---- |
| `ownexit direct --rotate-keys` / `--rotate-token` / `--add-device <name>` / `--remove-device <name>` / `--migrate` / `--uninstall` | `ownexit direct rotate-keys` / `rotate-token` / `add-device <name>` / `remove-device <name>` / `migrate` / `uninstall` | 1.5.0 |
| `ownexit subctl start` / `stop` / `status` / `log` / `qr` / `devices` / `login` | `ownexit direct sub start` / `sub stop` / `status` / `log` / `qr` / `devices` / `login` | 1.5.0 |
| `ownexit chain rehost-exit` | `ownexit chain migrate-exit --to <new IP>` (the same machine is detected automatically) | 1.5.0 |

## 4. What is not promised

The following may change in any version:

- The full text of `--help` and all log and progress text: `[chain][<subcommand>] INFO / WARN / ERROR …` on the chain script's stderr, the `[*]` / `[+]` / `[!]` lines of direct and subctl, the wording of each doctor check, and the content of the IP check and scan sections.
- Internal scripts: `direct/direct_remote.sh` (an internal script run on the server), `direct/sync_to_vps.sh`, `direct/target_lib.sh`, and the temporary scripts each command sends to the servers, along with their exit codes and temporary files.
- Internal files: the specific keys of the chain `state.env` (the key table is for reference only), `transaction.env`, `baseline/`, `audit/`, `operation.lock`, `shared.lock`, `active-child.env`, `local-process.env` and the various temporary files; the layout of `/opt/ownexit-direct/bin/` and `/opt/ownexit-chain/bin/` on the servers, `/var/lib/ownexit-direct/`, and the `<id>.rotate.*` helper files on the exit.
- Test-hook environment variables starting with `OWNEXIT_TEST_`.
- The exact location of the `ownexit multi` QR code directory (by default a new one under `${TMPDIR:-/tmp}`).

## 5. Upgrading and downgrading

- 1.y must be able to read every persistent file 1.x wrote (including the internal files in section 4) and keep managing existing deployments: deployed direct exits, chains and devices need no redeployment after an upgrade, and subscription URLs and clients need no re-import.
- The chain `state.env` carries `SCHEMA_VERSION`. If a state key is added within 1.x, SCHEMA_VERSION must be raised and the new version must still read the old schema; an older version that reads the new schema refuses it under its existing logic (downgrading is not guaranteed).
- sing-box version: the chain state records the sing-box version used at deployment, and the binary path on the servers includes the version. Within 1.x a sing-box upgrade ships only if the same release migrates existing deployments in place (no credential change, no rollback needed); otherwise it waits for 2.0.
- Converge unfinished operations before upgrading: when a chain has `transaction.env` (`status=incomplete`), rerun deploy / rollback first; when the exit has helper files left over (`status=drifted reason=exit-op-pending`), rerun the interrupted rotate-keys / add-device / remove-device first; when there is an exit migration record (`status=drifted reason=exit-migration-pending`), rerun migrate-exit to completion first (or `--abort` / `--abandon-cleanup`).
- Downgrading is not guaranteed. In particular, once devices have been added to a direct VPS, do not operate it with a version older than 0.7.0 (older versions render only default when changing parameters, and drop the devices).

## 6. How these promises are kept

- `scripts/check_interface.sh` (the Interface freeze step in CI, run by both the lint and bash 3.2 jobs) automatically compares the following lists against the reference documents in this directory and fails CI on any mismatch: the `ownexit` subcommands; the long options of direct / connect / subctl / doctor / multi / chain; the subcommands of direct / subctl / multi / chain; the chain status values and other command output lines; the connect reason values; the chain configuration keys (also checked against the configuration parser); the chain state.env keys; the direct client.env keys; the subscription file names; and that the table first columns of the Chinese and English editions of the reference documents (`*.md` and `*.en.md`) agree after normalising placeholders. `scripts/check_i18n.sh` (also run in CI) checks that every Chinese / English document pair exists and links to each other, and that links in the English pages do not point back to the Chinese editions and their anchors resolve.
- The other promises (exit codes, server paths and unit names, nft table names, node and group names, multi output and artifacts, doctor output format, conns output, environment variables, local directory rules) are checked by hand against this directory during code review.
- Any change to a promised interface must update the reference documents in this directory (both languages) and the CHANGELOG in the same commit.
