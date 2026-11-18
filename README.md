# KVN VPN Installer

Family-oriented self-hosted VPN installer for **Ubuntu 22.04 / 24.04** on a fresh VPS.

Based on [kefir-100/kn-vpn-installer](https://github.com/kefir-100/kn-vpn-installer) (MIT). See `LICENSE` for the original copyright notice.

## What it installs

- **VLESS + XHTTP + REALITY** on **TCP/443**, using **3X-UI** to manage individual client credentials.
- **Pinned upstream releases**, independently SHA-256-checked **before extraction**:
  - [3X-UI v3.11.0](https://github.com/MHSanaei/3x-ui/releases/tag/v3.11.0)
  - [Xray-core v26.11.9](https://github.com/XTLS/Xray-core/releases/tag/v26.11.9)
- **Admin panel bound to 127.0.0.1**; the separate subscription listener is disabled.
- Private installer directory and logs (root-only), with password, subId and VLESS URLs excluded from the common log.
- Client link with `fp=chrome` instead of `randomized`.

## Requirements

- A **fresh, dedicated VPS**, not a system already running 3X-UI or other applications.
- Ubuntu 22.04/24.04; amd64 or arm64.
- SSH access with `sudo` and **working SSH key authentication**.
- TCP/443 reachable from client networks and SSH reachable from your computer.
- Provider firewall must permit TCP/443, but **do not expose the panel's random port**.

**Important:** This is a privileged installer that modifies the host, installs dependencies and configures a systemd service. Review the script first. It has **not been end-to-end tested on a VPS**; passing syntax/static checks alone is not proof of a working or uncensorable connection.

## Install

Clone and review this repository, then run on the **VPS**:

```bash
git clone https://github.com/antontuz/kvn-installer.git
cd kvn-installer
bash -n kn-vpn-installer.sh
sudo bash kn-vpn-installer.sh --keys 4
```

`--keys 4` creates four separate client links. You can create extra links later by re-running the installer and choosing **Add a new client**. Treat each link as a password. Do not paste it into public chats or commit it to Git.

The installer prints and saves files under `/home/kn-vpn-installer/`:

- `panel-credentials.txt`: panel URL and administrator login.
- `clients.txt`: individual VLESS links.
- `vpn-installer.log`: operational output **without** generated credentials/links.
- `state.env`: configuration and installation state.

These paths contain secrets (even if the common log omits them). Keep backups offline and restrict server access.

## Open the admin panel securely

The panel is **not publicly reachable**. Its URL uses `127.0.0.1` intentionally.

From your Mac, set up SSH local forwarding, replacing `PORT` with the panel port printed during installation and `VPS_IP` with the server address:

```bash
ssh -N -L 127.0.0.1:PORT:127.0.0.1:PORT root@VPS_IP
```

Keep that SSH session open and visit the saved `https://127.0.0.1:PORT/<random-path>/` URL on your Mac. The panel uses a **self-signed TLS certificate**; verify the endpoint before accepting a browser warning.

SSH tunneling affects **only panel administration**. Your family can still connect directly to public TCP/443 using their VLESS links.

## Safety notes

- **No unattended upgrades:** both software versions and digests are intentionally fixed; update them together after verifying official releases.
- `--dry-run` previews many operations but is **not** a comprehensive emulator, an end-to-end test, or a complete no-side-effect guarantee.
- **Reinstall from scratch is destructive:** it removes the existing 3X-UI installation, database, clients and locally stored links. Always back up before choosing option 1. Choose option 2 to add a client without resetting.
- If the VPS IP or TCP/443 is blocked by the network, a change of transport cannot guarantee access.
- Run one user per link if you want independent revocation. No explicit per-IP or per-user data limits are configured by default.
- The installer uses a TLS donor domain; its probe is from the **server**, not from your carrier. Provider routing and filtering must be tested in practice.
- The VPS hosting provider may count inbound and outbound transfer separately: verify the interpretation of any **3 TB monthly cap**.

## Checks

```bash
bash -n kn-vpn-installer.sh
bash tests/static-checks.sh
```

The tests are static and do not execute privileged installer operations. Test against a disposable VPS before using it for your family.

## License

MIT; see `LICENSE` and the original author's copyright.
