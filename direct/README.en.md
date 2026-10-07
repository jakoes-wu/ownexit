# Direct: one VPS as your exit

**English** | [简体中文](README.md)

```sh
./direct/setup_direct.sh up --host 203.0.113.7   # asks for the VPS root password once
```

For step-by-step instructions (choosing a machine, importing into clients, verifying, troubleshooting) see [`docs/manual/direct.en.md`](../docs/manual/direct.en.md).

## Scripts

| Script | Purpose |
| ---- | ---- |
| `setup_direct.sh` | Deployment entry point: key login → system check → BBR → install sing-box → render and upload subscriptions → verify |
| `subctl` | Day-to-day operations after deploying: `status` / `start` / `stop` the subscription service, `log`, `qr`, `devices` to list devices, or log in to the VPS with the key. Since 1.5.0 it is called by the `sub start` / `sub stop` / `status` / `log` / `qr` / `devices` / `login` subcommands of `setup_direct.sh`; calling it directly is deprecated (still works, and prints the new form) |
| `connect_to.sh` | Sets up a dedicated SSH key for a VPS; `setup_direct.sh` and the chain `init` call it automatically |
| `sync_to_vps.sh` | Uploads the locally rendered subscription directory to the VPS; called by `setup_direct.sh` |
| `doctor.sh` | Diagnostics: checks this computer, the remembered direct VPSes and chains; `--ip-check` checks the exit IP and `--scan-sni` scans for usable camouflage domains (`ownexit doctor`) |
| `target_lib.sh` | The "remembered target VPS" logic shared by `setup_direct.sh` and `subctl`; cannot run on its own |

Every executable script supports `-h` / `--help`.

## Where the target comes from

`setup_direct.sh` and `subctl` decide which VPS to act on in this order:

1. `--host` on the command line (optionally `--port`, default 22, and `--user`, default root).
2. The target remembered after the last successful deployment: `~/.config/ownexit/direct/<user>_<host>_<port>.env`, with only the keys `HOST`, `SSH_PORT` and `SSH_USER`, mode 600. If exactly one is remembered it is used automatically; if several are, they are listed and you choose with `--host`.
3. If there is neither: `setup_direct.sh` asks in the terminal; `subctl` tells you to deploy first. When not running in a terminal, a missing argument ends with exit code 2.

## Password

Needed only once, when setting up key login; typed interactively and not echoed. You get 3 tries, and each is submitted to the server only once to avoid triggering bans. For non-interactive runs (from a script, for example) pass it in the environment variable `OWNEXIT_SSH_PASSWORD`; a wrong password is not retried.

When login fails, `connect_to.sh` exits with code 3 and the last line gives the reason:

| Output | Meaning |
| ---- | ---- |
| `reason=bad-password` | Wrong password |
| `reason=password-disabled` | The server has password login turned off |
| `reason=unreachable` | Cannot connect: an IP, port or security-group problem |

## Files on your computer and on the VPS

| Location | Contents |
| ---- | ---- |
| `~/.ssh/ownexit/id_ed25519_<user>_<host>_<port>` | The dedicated key for each VPS |
| `~/.config/ownexit/direct/` | Remembered target VPSes |
| `~/.local/state/ownexit/direct/<user>_<host>_<port>/` | `state.env` (the subscription `SUB_PORT` and `TOKEN`, mode 600) and the locally rendered subscription directory |
| `/opt/ownexit-subscription/` on the VPS | Subscription files and the subscription service script `subserver.py`; the service only answers `/<TOKEN>/<file name>` and the adaptive `/<TOKEN>/sub`, returns 404 for every other path and never exposes the TOKEN (the empty `index.html` is kept but no longer needed to prevent directory listing) |
| `ownexit-subscription.service` on the VPS | The read-only subscription service (`python3 subserver.py` running as `nobody`; before 1.3.0 it was `python3 -m http.server`, and running `ownexit direct` once switches it) |
