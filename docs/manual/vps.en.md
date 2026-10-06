# Getting a VPS ready

**English** | [简体中文](vps.md)

This page walks you through preparing the servers from scratch: what kind of VPS to buy, how to order it, how to install (or reinstall) the operating system, what to watch out for with firewalls, and finally how to hand it to ownexit.

When you are done you should have:

- Direct: **1** VPS. Relay: **2** VPSes (a relay and an exit).
- For each server: its **public IPv4**, its **SSH port** (usually 22) and the **root password**.
- **Debian 12** or **Ubuntu 22.04 LTS**, preferably on **x86_64 (amd64)**.

> The providers named here are common examples to help you find your way around their consoles. They are not recommendations, and there are no referral links. Prices, plans and console layouts change often; go by what the provider's website shows today.

## 1. Decide how many servers you need

| Your situation | Choose | Servers |
| ---- | ---- | ---- |
| You can reach the VPS directly from where you are | Direct | 1 |
| The VPS's IP is unreachable or unstable from where you are, but that IP is the one you need | Relay | 2: an exit (provides the final IP) + a relay (reachable from you, with a good route to the exit) |

If unsure, start with one server in direct mode. You can add a relay later and turn the first server into the exit.

## 2. What to look for

| Item | Choose | Why |
| ---- | ---- | ---- |
| Operating system | Debian 12 or Ubuntu 22.04 LTS (64-bit) | Direct supports only Debian / Ubuntu; relay needs systemd. Both systems qualify and are what this project is tested on |
| CPU architecture | x86_64 (amd64) | Tested on real cloud servers. arm64 also works for relay (tested on Ubuntu 22.04 arm64 virtual machines, not yet on cloud servers); both servers must match |
| Size | The entry plan is enough (e.g. 1 vCPU, 1 GB RAM) | The proxy itself uses very little; the route and traffic allowance matter more |
| Public IP | One dedicated IPv4 | That is what websites see; shared-IP or NAT servers do not work |
| Traffic | Check the monthly allowance and overage rules | Estimate from your own usage |
| Location and route | Exit: where you want the IP to be. Relay: close to you, with a good route to the exit | If latency from mainland China matters, prefer routes advertised as optimized for it |
| Billing | Start with hourly or monthly | You only learn the IP's reputation and the route quality by using it; replace it early if unhappy |
| Login | root password over SSH | ownexit uses the root password once to set up key login, then only keys |

## 3. Common providers

| Provider | Billing | Console | Good for |
| ---- | ---- | ---- | ---- |
| Vultr | Hourly, delete any time | Its own web console | Trying several locations / IPs |
| DigitalOcean | Hourly, delete any time | Its own web console (servers are called Droplets) | Same, with thorough docs |
| RackNerd | Mostly monthly / yearly deals | SolusVM panel (details sent by email) | Low budget, long-term use |
| BandwagonHost | Mostly quarterly / yearly, with routes optimized for mainland China | KiwiVM panel | Low latency from mainland China |

Payment methods (credit card, PayPal, Alipay and so on) differ; check before ordering.

## 4. Ordering (common steps)

The screens differ but the flow is similar:

1. **Sign up** and add a payment method or top up.
2. **Create a server** (Vultr: Deploy; DigitalOcean: Create Droplet; RackNerd / BandwagonHost: order a plan directly).
3. **Pick a location**, following section 2.
4. **Pick the image**: Debian 12 x64 or Ubuntu 22.04 x64.
5. **Pick a plan**: the entry plan is fine.
6. **Pick the login method**: if asked to choose between "SSH key" and "password", choose **password**. If only keys are offered, see section 8.
7. **Extras**: paid backups are optional; IPv6 on or off makes no difference.
8. **Create** it; it is usually ready within 1–3 minutes.
9. **Write down three things**: public IPv4, SSH port, root password.

Where to find them:

| Provider | IP and root password | SSH port |
| ---- | ---- | ---- |
| Vultr | Server Overview page; the password is hidden until you click the eye icon | 22 |
| DigitalOcean | IP on the Droplet page; the password is the one you set when creating it | 22 |
| RackNerd | In the welcome email | Usually 22; check the email |
| BandwagonHost | KiwiVM panel | Often not 22; check the panel |

## 5. Check the server

**IP reputation**: open `https://ipinfo.io/<your IP>` in a browser and look at the location, the network and the type (hosting or isp); a tool such as Scamalytics shows a risk score. If you are unhappy and billed hourly, deleting and recreating the server usually gives you a new IP.

**Reachability** (on your own computer, preferably with your local proxy's TUN mode turned off):

```sh
nc -vz <your IP> 22        # use the real port if not 22; "succeeded" / "open" means reachable
```

- Reachable: fine for direct, or as a relay.
- Unreachable or flaky: not suitable for direct. Use it as a relay exit and find another server you can reach as the relay.

**(Optional) log in once by hand**:

```sh
ssh -p 22 root@<your IP>   # type the root password; answer yes on first connect
cat /etc/os-release        # should be Debian 12 or Ubuntu 22.04
uname -m                   # x86_64 means amd64, aarch64 means arm64
exit
```

Not required — ownexit checks the system itself — but it confirms you copied the password correctly.

## 6. Installing or reinstalling the OS

If the new server already runs Debian 12 / Ubuntu 22.04, skip to section 7. Reinstall first when:

- you picked the wrong image, or the provider installed something else by default;
- the server previously ran another proxy, panel or firewall rules (relay mode requires no nftables tables other than ownexit's own, and UFW, if installed, must be inactive);
- you want to start from a clean system.

> Reinstalling **wipes the whole server**. If an ownexit relay chain is deployed on it, run `ownexit chain --id <name> rollback` on your computer first.

Where to reinstall:

| Provider | Where | Notes |
| ---- | ---- | ---- |
| Vultr | Server page → Settings → Change OS; or Reinstall to reinstall the same OS | IP stays the same |
| DigitalOcean | Droplet page → Destroy → Rebuild Droplet, pick a new image | Rebuild keeps the IP; do not destroy the Droplet (the IP is released) |
| RackNerd | SolusVM panel → Reinstall, pick a template | Use the root password from the panel or email |
| BandwagonHost | KiwiVM panel → Stop first, then Install new OS | The panel shows the new root password and SSH port |

After reinstalling:

- **The root password may have changed**; use the one from the panel or email.
- **The server's SSH host key has changed.** Just run the ownexit command again: when key login no longer works, it removes the server's old entry from your `known_hosts` and sets up key login again with the new password. If you see `REMOTE HOST IDENTIFICATION HAS CHANGED` when logging in with plain `ssh`, run `ssh-keygen -R <your IP>` (and `ssh-keygen -R "[<your IP>]:<port>"` if the port is not 22), then log in again.

## 7. Firewalls and security groups

A "security group" or "firewall" in the provider's console is an inbound rule set enforced outside the server; many providers leave it off by default. If you enable one:

| Mode | Inbound TCP ports to allow |
| ---- | ---- |
| Direct | SSH; the sing-box port (random between 20000 and 59999, or set with `--proxy-port`, shown in the output); the subscription port (random between 20000 and 59999, shown in the output) |
| Relay: relay server | SSH; the relay port (random between 20000 and 59999, chosen at deploy) |
| Relay: exit server | SSH (only you and the relay need it); the Reality port (random between 20000 and 59999), reachable at least from the relay |

Since the random ports are unknown before deploying, the simplest approach is to leave the security group off (or allow 20000–65535 temporarily) while deploying, then tighten it to the ports shown in the output.

Firewalls **inside** the server:

- Direct: if UFW is active, ownexit opens the proxy and subscription ports; if not, it leaves UFW alone.
- Relay: UFW must be inactive, there must be no nftables tables other than ownexit's own, and legacy iptables must have no active rules. Restricting the exit's Reality port to the relay is done by default with an nftables table that ownexit adds on the exit (see the [relay guide](chain.md), in Chinese).

## 8. The provider only allows SSH keys

Some providers or images disable root password login. ownexit then exits with `reason=password-disabled`. Two ways out:

1. Set a root password and enable password login in the console (many panels have a "reset root password" button), then run again;
2. Keep password login off: run ownexit once so it creates its dedicated key on your computer (`~/.ssh/ownexit/id_ed25519_root_<IP>_<port>`), then use the provider's web console (VNC / Console) to append the contents of the matching `.pub` file to `/root/.ssh/authorized_keys` on the server, and run again.

## 9. Hand it to ownexit

Put what you wrote down into the commands (the IPs below are examples):

```sh
# Direct: one server
ownexit direct --host 203.0.113.7               # add --port 2222 if SSH is not on 22

# Relay: relay + exit
ownexit chain init --relay 203.0.113.10 --exit 203.0.113.20   # add --relay-port / --exit-port if not 22
ownexit chain --id main deploy
```

The first run asks for each server's root password (not echoed); after that only keys are used. Next steps: the [README](../../README.md#quick-start-direct), the [direct guide](direct.md) and the [relay guide](chain.md) (both in Chinese).

## 10. Security tips

- Use a strong root password, never share it, and never put it in a file you commit or share.
- Once key login works and ownexit can log in, consider disabling password login on the server; keep the provider's web console as a fallback before you do.
- Follow the laws where you live and your provider's terms.
