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

---

## Quick Start

**First run (no config file yet):**
```bash
sudo ./docker/docker_deploy.sh
# → "Create a configuration template? [Y/n]"  → Y
# → Script writes linux/deploy.conf and exits
# → Edit the config, fill in required fields, run again to deploy
```

**Subsequent runs (config exists):**
```bash
sudo ./docker/docker_deploy.sh
# → "Use this configuration? [Y/n]"  → Y
# → Deploys non-interactively — no prompts
```

**Validate config without deploying:**
```bash
sudo ./docker/docker_deploy.sh --check
# → Tests all required fields, GitHub token auth, prints deployment plan
```

**One-liner from remote (generates config template, then exits):**
```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/BorealTek/Treescout-Deployments/master/docker/docker_deploy.sh)
```

The script is idempotent — re-running prompts whether to keep or destroy the existing database.

---

## Cloudflare Tunnel

The app nginx serves plain **HTTP on port 8080** — no SSL. The Cloudflare tunnel terminates TLS at the edge and delivers plain HTTP to the origin.

Configure your tunnel public hostname as:

| Hostname | Service | URL |
|----------|---------|-----|
| `tickets.borealtek.ca` | **HTTP** | `localhost:8080` |
| `ssh.tickets.borealtek.ca` | SSH | `localhost:22` |

The tunnel is managed externally (not started by this script). Emergency HTTPS (self-signed) is available at `<server-ip>:8443`.

---

## Key `deploy.conf` Fields

```bash
DOMAIN_NAME="tickets.borealtek.ca"    # Public URL (sets APP_URL)
DOCKER_SUBNET="192.168.220.0/24"      # Docker bridge subnet (must not conflict with LAN)
ADMIN_EMAIL="scott.mcdonald@borealtek.ca"
ADMIN_PASS="..."                       # Saved; used by freescout:install on fresh deploy

export REPO_TOKEN="ghp_..."           # GitHub PAT (repo scope) for private module repos

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

| Script | Platform | Notes |
|--------|----------|-------|
| `docker/docker_deploy.sh` | Ubuntu/Linux server | **Canonical — use this for all server deployments** |
| `orbstack/orbstack_deploy.sh` | macOS/OrbStack | Local dev only |

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

- `docker/` — Linux server deployer (`docker_deploy.sh`)
- `orbstack/` — macOS/OrbStack local dev deployer
- `linux/` — Shared config template (`deploy.conf.example`), module manifest (`modules.manifest.json`)

> **Never commit `linux/deploy.conf`** — it contains REPO_TOKEN and DB passwords.
