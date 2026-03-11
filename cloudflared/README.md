# Cloudflare Tunnel — Standalone Setup

The tunnel runs **outside** the app stack so:
- `docker compose down` on the app has no effect on SSH or tunnel connectivity
- It can serve multiple public hostnames (SSH, the app, other services on the same host) from a single token
- It has its own independent restart/update lifecycle

---

## Quickstart (Docker Compose)

```bash
cd deployment/cloudflared

# Create an env file with your token
echo "CF_TUNNEL_TOKEN=eyJ..." > .env

# Start (detached)
docker compose up -d

# Tail logs
docker compose logs -f
```

The container uses `network_mode: host`, so cloudflared can reach any port on the host directly (no `extra_hosts` or bridge plumbing needed).

---

## Cloudflare Zero Trust — Public Hostnames

In **Zero Trust → Networks → Tunnels → your tunnel → Configure → Public Hostnames**, add:

| Subdomain | Domain | Service | URL | Notes |
|---|---|---|---|---|
| `ssh` | `tickets.borealtek.ca` | SSH | `localhost:22` | Dev/admin access |
| _(root)_ | `tickets.borealtek.ca` | HTTPS | `localhost:443` | Web app |

For the HTTPS hostname, toggle **No TLS Verify ON** (the app container uses a self-signed cert).

---

## Google OAuth Protection for SSH

1. **Zero Trust → Access → Applications → Add application → Self-hosted**
2. Application domain: `ssh.tickets.borealtek.ca`
3. Add a policy using your Google OAuth provider — allow `borealtek.ca` domain or specific emails
4. Under **Settings**, leave browser rendering disabled (VS Code uses native SSH, not browser SSH)

---

## Client Setup (your laptop)

Install `cloudflared` locally:

```bash
# macOS
brew install cloudflare/cloudflare/cloudflared

# Linux (Debian/Ubuntu)
curl -L https://pkg.cloudflare.com/cloudflared-stable-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb
```

Add to `~/.ssh/config`:

```
Host ssh.tickets.borealtek.ca
    ProxyCommand cloudflared access ssh --hostname %h
    User <your-linux-user-on-the-server>
```

Connect:

```bash
ssh ssh.tickets.borealtek.ca
# First connection opens a browser tab for Google OAuth, then proceeds
```

**VS Code Remote SSH:** Install the *Remote - SSH* extension, add `ssh.tickets.borealtek.ca` as a host, and connect. Point the remote workspace at `/var/www/html`.

---

## Alternative: systemd (no Docker)

If you prefer to skip the container entirely, cloudflared can run natively as a systemd service. This is the most resilient option — it starts before Docker and survives any container operations:

```bash
# Install cloudflared binary
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# Install and start as a systemd service
cloudflared service install <your-tunnel-token>

# Verify
systemctl status cloudflared
```

Uninstall with `cloudflared service uninstall` if you switch back to Docker.
