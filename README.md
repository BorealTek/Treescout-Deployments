---
doc_type: how-to
owner: "@devops-team"
reviewers:
    - "@platform-team"
last_reviewed: 2026-07-12
review_cycle_days: 45
source_paths:
    - deployment/
stability: active
---

# BorealTek Treescout — Deployment

## Deployment Architecture

**`docker_deploy.sh` is the canonical deployment mechanism.** It builds the image locally on the server and bind-mounts `src/` into the container. This is required because:

- FreeScout's module system git-clones module repos into `Modules/` at install time, and the UI module manager expects live `.git` directories. Baking modules into an immutable image strips `.git` and breaks this.
- APP_KEY generation works normally — there's a real `.env` file on disk.
- Module updates don't require rebuilding and pushing a new image.

The GHCR pre-built image (`Dockerfile.prod`) exists for CI validation and multi-server deployments where modules are managed entirely by CI. For a single-server BorealTek install, use `docker_deploy.sh`.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Ubuntu 22.04+ | Script installs Docker if missing |
| 4 GB RAM | 2 GB minimum, 4 GB recommended |
| `REPO_TOKEN` | GitHub PAT with `repo` scope — used to clone all private module repos |
| `CF_TUNNEL_TOKEN` | From Cloudflare Zero Trust → Networks → Tunnels |

---

## Quick Start

```bash
# One-liner (interactive setup):
sudo bash <(curl -sL https://raw.githubusercontent.com/BorealTek/Treescout-Deployments/master/docker/docker_deploy.sh)

# Or with a pre-filled config:
cp linux/deploy.conf.example linux/deploy.conf
nano linux/deploy.conf   # set DOMAIN_NAME, REPO_TOKEN, DB creds, ADMIN_EMAIL
sudo ./docker/docker_deploy.sh
```

The script is idempotent — re-running prompts whether to keep or destroy the existing database.

---

## Cloudflare Tunnel Setup

cloudflared runs as a **separate stack** so that `docker compose down` on the app never kills SSH or tunnel connectivity. The deployment script starts it automatically if `CF_TUNNEL_TOKEN` is set in `deploy.conf`.

**Cloudflare Zero Trust → Networks → Tunnels → your tunnel → Configure → Public Hostnames:**

| Hostname | Service | URL |
|----------|---------|-----|
| `ssh.tickets.borealtek.ca` | SSH | `localhost:22` |
| `tickets.borealtek.ca` | **HTTP** | `localhost:8080` |

> The app nginx serves plain HTTP on 8080. The Cloudflare tunnel handles TLS between users and Cloudflare's edge — no SSL between cloudflared and origin.

If cloudflared is on a **different VM** (non-standard), the app port binds to `0.0.0.0:8080` so it's reachable over the LAN. Emergency HTTPS (self-signed) is at `<server-ip>:8443`.

---

## Key `deploy.conf` Fields

```bash
DOMAIN_NAME="tickets.borealtek.ca"    # Public URL (sets APP_URL)
DOCKER_SUBNET="192.168.220.0/24"      # Docker bridge subnet (must not conflict with LAN)
ADMIN_EMAIL="scott.mcdonald@borealtek.ca"
ADMIN_PASS="..."                       # Saved; used by freescout:install on fresh deploy

export REPO_TOKEN="ghp_..."           # GitHub PAT (repo scope) for private module repos
export CF_TUNNEL_TOKEN="eyJ..."       # Cloudflare tunnel token

# Optional integrations
GOOGLE_CLIENT_ID=""
ACTION1_SYNC_CLIENT_ID=""
```

---

## Update Workflow

```bash
cd /opt/treescout-docker
sudo ./update.sh
```

The generated `update.sh` follows this sequence:
1. Maintenance mode ON (503 to users)
2. `git pull` + submodule sync
3. Rebuild image, restart containers
4. `composer install`, `npm run build`
5. `migrate`, `module:migrate`
6. `config:cache`, `route:cache`, `view:cache`, `event:cache`
7. `queue:restart`
8. Maintenance mode OFF

---

## Deployment Targets

| Script | Platform | Architecture |
|--------|----------|--------------|
| `docker/docker_deploy.sh` | Ubuntu/Linux | Bind-mount, local build, **use this** |
| `orbstack/orbstack_deploy.sh` | macOS/OrbStack | Bind-mount, local build |
| `gcp/gcp_deploy.sh` | GCP | Legacy, not maintained |

---

## Known Gotchas

| Issue | Fix |
|-------|-----|
| `freescout:install` not found | Platform uses `freescout:*` namespace, not `treescout:*` |
| queue/cron/reverb show unhealthy | serversideup/php bakes in nginx healthcheck; these containers run PHP CLI — `healthcheck: disable: true` is required |
| APP_KEY empty after deploy | Only matters with `env_file` approach (GHCR image). bind-mount has real `.env` — `key:generate` writes to disk normally |
| Cloudflare HTTPS detection broken | `TRUSTED_PROXIES=*` required in `.env` — the tunnel sends X-Forwarded-Proto: https |
| FreeScout crashes on boot | `modules_statuses.json` lists modules that aren't cloned — script generates this file from what's actually on disk |

---

## Structure

- `docker/` — Linux Docker deployer, cloudflared sidecar, kroki sidecar
- `orbstack/` — macOS/OrbStack deployer
- `gcp/` — Legacy GCP tooling
- `linux/` — Shared config template (`deploy.conf.example`), module manifest

> **Never commit `linux/deploy.conf`** — it contains REPO_TOKEN and DB passwords.
