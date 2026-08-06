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

The app nginx serves plain **HTTP** internally — no SSL. The Cloudflare tunnel terminates TLS at the edge and delivers plain HTTP to the origin. The container always listens on 8080/8443 internally; `HTTP_PORT`/`HTTPS_PORT` in `deploy.conf` (colima only) control which *host* ports those map to — point your tunnel's Service URL at whichever you configured (defaults to 8080/8443).

Configure your tunnel public hostname as:

| Hostname | Service | URL |
|----------|---------|-----|
| `tickets.borealtek.ca` | **HTTP** | `localhost:$HTTP_PORT` |
| `ssh.tickets.borealtek.ca` | SSH | `localhost:22` |

If `KB_URL` is set to a dedicated subdomain (e.g. `kb.borealtek.ca`), add a second Public Hostname entry pointing at the **same** `localhost:$HTTP_PORT` — `SetContextUrl` routes ticketing vs. KB by the `Host` header, not by port, so one origin serves both.

The tunnel is managed externally (not started by this script). Emergency HTTPS (self-signed) is available at `<server-ip>:$HTTPS_PORT`.

**colima only — port binding is `0.0.0.0`, not `127.0.0.1`:** colima's Docker daemon runs inside a Linux VM; its hostagent can only forward a port to the host's loopback *or* all interfaces, never a single specific one. This matters if your cloudflared (or reverse proxy) runs on a *different* host than the app — e.g. reaching it over Tailscale — since `127.0.0.1` would make it unreachable from anywhere but the app host itself. The tradeoff: if the host also has a LAN IP, `$HTTP_PORT`/`$HTTPS_PORT` are reachable there too (plain HTTP, no TLS) — there's no docker-compose-layer way to restrict this to just one interface. The app requires login, but treat this as a real exposure, not a non-issue, on a host with an untrusted LAN.

---

## Key `deploy.conf` Fields

```bash
DOMAIN_NAME="tickets.borealtek.ca"    # Public URL (sets APP_URL)
KB_URL=""                             # Optional dedicated KB hostname (colima only — see below)
HTTP_PORT="8080"                      # colima only — host port the tunnel targets; change if
HTTPS_PORT="8443"                     #   the host runs other services that might want 8080/8443
DOCKER_SUBNET="192.168.220.0/24"      # Docker bridge subnet (must not conflict with LAN)
ADMIN_EMAIL="scott.mcdonald@borealtek.ca"
ADMIN_PASS="..."                       # Saved; used by freescout:install on fresh deploy

export REPO_TOKEN="ghp_..."           # GitHub PAT (repo scope) for private module repos

# Optional integrations
GOOGLE_CLIENT_ID=""
ACTION1_SYNC_CLIENT_ID=""
MAIL_HOST=""
IMAP_HOST=""
```

Full catalog of every field (deploy.conf-managed or not): [`linux/ENV_REFERENCE.md`](linux/ENV_REFERENCE.md).

---

## Secrets Separation (`.env` vs `.env.secrets`)

`configure_laravel()` in both `docker_deploy.sh` and `colima_deploy.sh` writes two files into `src/`, not one:

- **`.env`** — structural config: hostnames, usernames, IDs, feature flags. Bind-mounted into the container, read by Laravel's normal dotenv boot.
- **`.env.secrets`** — passwords and API secrets only (`DB_PASSWORD`, `ADMIN_PASSWORD`, `REVERB_APP_SECRET`, `GOOGLE_CLIENT_SECRET`, `ACTION1_*_CLIENT_SECRET`, `MAIL_PASSWORD`, `IMAP_PASSWORD`). Chmod 600, gitignored, never baked into the image. Injected into every service (`app`, `queue`, `cron`, `reverb`) via Docker Compose's `env_file:`, which sets real container OS environment variables — phpdotenv never overwrites an already-set env var, so these values silently win over anything with the same key in `.env` with zero extra code on the Laravel side.

This mirrors what `linux/setup-server.sh` (the GHCR pre-built-image path) already did — `docker_deploy.sh`/`colima_deploy.sh` just didn't have it until now. `REVERB_APP_KEY` (not the secret) deliberately stays in `.env`: it also feeds `VITE_REVERB_APP_KEY`, which Vite bakes into the frontend bundle at `npm run build` time, so it needs to be on disk when the build runs, not just injected as a runtime container env var.

`docker_deploy.sh`'s separate `secrets.env` (deploy-time, outside git, at `$DEFAULT_INSTALL_DIR/secrets.env`) is a different, complementary mechanism — it's what makes DB/Reverb credentials stable across re-deploys (`sudo ./docker_deploy.sh --secrets` to view). `configure_laravel()` reads those stable values and is what actually writes them into `.env.secrets` for the running containers to consume.

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
| `colima/colima_deploy.sh` | macOS/Linux + Colima | Local dev, or a dedicated macOS sandbox/multi-purpose server |

---

## Known Gotchas

| Issue | Fix |
|-------|-----|
| `freescout:install` not found | Platform uses `freescout:*` namespace, not `treescout:*` |
| queue/cron/reverb show unhealthy | serversideup/php bakes in nginx healthcheck; these containers run PHP CLI — `healthcheck: disable: true` is required |
| APP_KEY empty after deploy | `APP_KEY` lives in bind-mounted `.env` (not `.env.secrets`) — `key:generate` writes to disk normally on both deploy paths |
| Cloudflare HTTPS detection broken | `TRUSTED_PROXIES=*` required in `.env` — the tunnel sends X-Forwarded-Proto: https |
| FreeScout crashes on boot | `modules_statuses.json` lists modules that aren't cloned — script generates this file from what's actually on disk |
| Google SSO allowlist has no effect | Historically `GOOGLE_ADMIN_EMAILS`/`GOOGLE_ALLOWED_DOMAINS` got appended to `.env` without stripping `.env.example`'s blank placeholder first — phpdotenv keeps the *first* definition it sees, so the real value was silently shadowed. Fixed in `configure_laravel()` (strips before appending); if you hit this on an older install, check `.env` for duplicate `GOOGLE_ADMIN_EMAILS=`/`GOOGLE_ALLOWED_DOMAINS=` lines and keep only the non-blank one |

---

## Structure

- `docker/` — Linux server deployer (`docker_deploy.sh`)
- `colima/` — macOS/Linux deployer using Colima (`colima_deploy.sh`) — local dev or a standalone sandbox server
- `linux/` — Shared config template (`deploy.conf.example`), module manifest (`modules.manifest.json`), full env var catalog (`ENV_REFERENCE.md`)

> **Never commit `linux/deploy.conf`** — it contains REPO_TOKEN and DB passwords.

See [`linux/ENV_REFERENCE.md`](linux/ENV_REFERENCE.md) for what every `.env`/`.env.secrets` key actually does, which file it belongs in, and which keys are dead/deprecated.
