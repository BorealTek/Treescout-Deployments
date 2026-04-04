# TreeScout GCP Deployment Guide

---

## Contents

1. [Prerequisites](#prerequisites)
2. [Step 1 — Fill in secrets.conf](#step-1--fill-in-secretsconf)
3. [Step 2 — Workstation setup script](#step-2--workstation-setup-script-gcp-workstation-setupsh)
4. [Step 3 — Server bootstrap script](#step-3--server-bootstrap-script-gcp-server-initsh)
5. [Architecture](#architecture)
6. [Secret Manager — full key reference](#secret-manager--full-key-reference)
7. [Instance metadata — full key reference](#instance-metadata--full-key-reference)
8. [Re-deploy / Update](#re-deploy--update)
9. [Rotate a secret](#rotate-a-secret)
10. [Day-to-Day Operations](#day-to-day-operations)
11. [Production upgrades](#production-upgrades)
12. [Troubleshooting](#troubleshooting)
13. [Cost reference](#cost-reference)

---

## Prerequisites

| Tool | Notes |
|------|-------|
| `gcloud` CLI | https://cloud.google.com/sdk/docs/install |
| Git Bash (Windows) or WSL2 | https://git-scm.com/download/win |
| GCP project with billing enabled | https://console.cloud.google.com |
| GitHub PAT | https://github.com/settings/tokens — scope: `repo` |

The workstation scripts work from **Git Bash on Windows**, WSL2, or macOS Terminal.
No tools need to be installed on the server beforehand — the server bootstrap handles that.

---

## Step 1 — Fill in `secrets.conf`

`secrets.conf` is the **single source of truth** for a deployment. It lives only on
your workstation and is never committed to version control.

Generate the template:

```bash
bash deployment/gcp/gcp-secrets-bootstrap.sh --create-config
# Edit secrets.conf — fill in every value before proceeding
```

**Minimum required fields:**

| Field | Description |
|-------|-------------|
| `GCP_PROJECT_ID` | Your GCP project ID (e.g. `treescout-491720`) |
| `DOMAIN_NAME` | Domain or GCP external IP (e.g. `34.x.x.x.nip.io` for testing) |
| `ADMIN_EMAIL` | Admin login email |
| `REPO_TOKEN` | GitHub PAT with `repo` scope for private module repos |
| `DB_ROOT_PASS` | MariaDB root password |
| `DB_PASS` | MariaDB app-user password |
| `ADMIN_PASS` | Admin account initial password |

All other fields are optional — leave blank to skip.

See [Secret Manager — full key reference](#secret-manager--full-key-reference) and
[Instance metadata — full key reference](#instance-metadata--full-key-reference) for
the complete list.

---

## Step 2 — Workstation setup script (`gcp-workstation-setup.sh`)

```bash
bash deployment/gcp/gcp-workstation-setup.sh --from-file=secrets.conf
```

This is **idempotent** — safe to run repeatedly to assert or repair the setup.

### What it does (in order)

| # | Action | Details |
|---|--------|---------|
| 1 | **Select project** | Reads `GCP_PROJECT_ID` from `secrets.conf`; falls back to `gcloud` default or interactive list |
| 2 | **Enable APIs** | `compute.googleapis.com`, `secretmanager.googleapis.com`, `iam.googleapis.com` |
| 3 | **Assert / create VM** | Creates `GCP_INSTANCE_NAME` in `GCP_ZONE` with `GCP_MACHINE_TYPE`, `GCP_DISK_SIZE` GB, `--scopes=cloud-platform`, and network tag `GCP_NETWORK_TAG`. If the VM exists, checks that the scope and tag are correct and fixes them automatically (stop/update/start cycle if scope is missing). |
| 4 | **IAM binding** | Grants the Compute Engine default service account `roles/secretmanager.secretAccessor` on the project |
| 5 | **Firewall rule** | Creates `GCP_FIREWALL_RULE_NAME` allowing `tcp:80,443` from `ALLOWED_SOURCE_RANGES`, targeting `GCP_NETWORK_TAG`. Updates if rule already exists but has wrong settings. |
| 6 | **Push secrets** | Upserts every non-empty secret from `secrets.conf` into GCP Secret Manager (see [full key reference](#secret-manager--full-key-reference)) |
| 7 | **Write instance metadata** | Stores all non-secret config values as `ts-*` custom metadata keys on the VM (see [full key reference](#instance-metadata--full-key-reference)). The server script reads these — no `deploy.conf` needs to be placed on the server. |
| 8 | **Verify secrets** | Reads back the four required secrets to confirm IAM propagated correctly |
| 9 | **Offer SSH deploy** | Asks whether to pipe `gcp-server-init.sh` over SSH automatically |

### Flags

| Flag | Effect |
|------|--------|
| `--from-file=secrets.conf` | Load config non-interactively |
| `--project=PROJECT_ID` | Override project selection |
| `--yes` / `-y` | Skip confirmation prompts (CI use) |
| `--skip-deploy` | Run steps 1-8 only; don't offer the SSH deploy |

---

## Step 3 — Server bootstrap script (`gcp-server-init.sh`)

The workstation script will offer to SSH in and run this automatically.
Run manually if needed:

```bash
gcloud compute ssh treescout-prod --zone=us-central1-a \
  --project=YOUR_PROJECT_ID -- 'sudo bash -s' < deployment/gcp/gcp-server-init.sh
```

No files need to pre-exist on the server. Everything is piped in via stdin.

### What it does (in order)

| # | Action | Details |
|---|--------|---------|
| 1 | **Verify on GCP** | Checks the metadata service is reachable; aborts with a clear message if run outside GCP |
| 2 | **Obtain OAuth token** | Fetches the VM service account token from the metadata service; aborts if the `cloud-platform` scope is missing with exact remediation steps |
| 3 | **Install system deps** | `apt-get update` + `ca-certificates curl gnupg git openssl python3 jq` |
| 4 | **Install Docker CE** | Adds the official Docker apt repo, installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, and enables the Docker service. No-ops if already installed. |
| 5 | **Install gcloud CLI** | Adds the Google Cloud SDK apt repo and installs `google-cloud-cli`. No-ops if already installed. |
| 6 | **Configure gcloud auth** | Injects the metadata-service OAuth token via `CLOUDSDK_AUTH_ACCESS_TOKEN` and clears any locally-stored `core/account` config. This ensures VM scopes are honoured rather than stale user credentials. |
| 7 | **Read instance metadata** | Pulls all `ts-*` custom metadata keys written by the workstation script. Validates that `ts-domain` and `ts-admin-email` are present; fails immediately with a helpful message if they are missing. |
| 8 | **Pull secrets** | Calls `gcloud secrets versions access latest` for all `treescout-*` secrets. Required secrets hard-abort if missing; optional ones are silently skipped. |
| 9 | **Clone repo** | Clones (or pulls) `GIT_REPO_URL` at `GIT_BRANCH` into `/opt/treescout-deploy`. Uses `REPO_TOKEN` for the initial clone URL, then immediately rewrites the remote to strip the token. |
| 10 | **Generate `deploy.conf`** | Writes an ephemeral `deploy.conf` assembled from the metadata and secrets pulled above. File is `chmod 600 / chown root:root` — not readable by other users, not committed anywhere. |
| 11 | **Exec deploy** | `exec sudo -E bash gcp_deploy.sh --yes` — hands off to the existing deploy pipeline |

---

## Architecture

```
workstation (Windows Git Bash / WSL2)
  ┌──────────────────────────────────────────────────────────────┐
  │  secrets.conf                                                │
  │    GCP_PROJECT_ID, DOMAIN_NAME, ADMIN_EMAIL                 │
  │    REPO_TOKEN, DB_*_PASS, ADMIN_PASS                        │
  │    GOOGLE_*, ACTION1_*, ...                                  │
  └──────────────┬───────────────────────────────────┬──────────┘
                 │ gcp-workstation-setup.sh           │
                 ▼                                    ▼
    GCP Secret Manager                   Compute VM — custom metadata
    ┌──────────────────────┐             ┌──────────────────────────┐
    │ treescout-repo-token │             │ ts-domain                │
    │ treescout-db-*-pass  │             │ ts-admin-email           │
    │ treescout-admin-pass │             │ ts-git-repo/branch       │
    │ treescout-google-*   │             │ ts-db-user/name/host     │
    │ treescout-action1-*  │             │ ts-allowed-ranges        │
    └──────────────────────┘             │ ts-agent/finance/...     │
                                         └──────────────────────────┘

GCP Compute VM (Debian 12, e2-standard-2+)
  ┌──────────────────────────────────────────────────────────────┐
  │  gcp-server-init.sh                                          │
  │  ├─ installs Docker CE, gcloud CLI, git                     │
  │  ├─ reads custom metadata  →  non-secret config             │
  │  ├─ pulls Secret Manager   →  secrets                       │
  │  ├─ clones app repo                                         │
  │  ├─ generates deploy.conf  (chmod 600, root-only, ephemeral) │
  │  └─ exec → gcp_deploy.sh → docker_deploy.sh                │
  │             └─ docker compose up -d                         │
  │                ├─ app    (Nginx + PHP 8.3, HTTPS :443)      │
  │                ├─ db     (MariaDB 10.6, internal only)      │
  │                ├─ redis  (session & cache)                   │
  │                ├─ queue  (Laravel queue worker)              │
  │                ├─ cron   (task scheduler)                    │
  │                └─ reverb (WebSocket server)                  │
  └──────────────────────────────────────────────────────────────┘
```

---

## Secret Manager — full key reference

All secrets are namespaced `treescout-*` with automatic replication.
Pushed by `gcp-workstation-setup.sh` (or `gcp-secrets-bootstrap.sh`).

### Required

| Secret name | `secrets.conf` key | Description |
|------------|-------------------|-------------|
| `treescout-repo-token` | `REPO_TOKEN` | GitHub PAT (`repo` scope) for private module repos |
| `treescout-db-root-pass` | `DB_ROOT_PASS` | MariaDB root password |
| `treescout-db-pass` | `DB_PASS` | MariaDB app-user password |
| `treescout-admin-pass` | `ADMIN_PASS` | Admin account initial password |

### Optional — seeded user accounts

| Secret name | `secrets.conf` key | Description |
|------------|-------------------|-------------|
| `treescout-agent-pass` | `AGENT_PASS` | Agent account password |
| `treescout-finance-pass` | `FINANCE_PASS` | Finance account password |
| `treescout-reporter-pass` | `REPORTER_PASS` | Reporter account password |

### Optional — Google OAuth (requires GoogleAdmin module)

| Secret name | `secrets.conf` key | Description |
|------------|-------------------|-------------|
| `treescout-google-client-id` | `GOOGLE_CLIENT_ID` | OAuth 2.0 Client ID |
| `treescout-google-client-secret` | `GOOGLE_CLIENT_SECRET` | OAuth 2.0 Client Secret |
| `treescout-google-admin-emails` | `GOOGLE_ADMIN_EMAILS` | CSV — emails auto-promoted to admin on first OAuth sign-in |
| `treescout-google-allowed-domains` | `GOOGLE_ALLOWED_DOMAINS` | CSV — domains whose new users are auto-provisioned as internal accounts |

> `GOOGLE_ALLOWED_DOMAINS` only gates **new account auto-provisioning**. Existing users
> can always sign in with Google regardless of domain.

### Optional — Action1 RMM (requires Action1 module)

| Secret name | `secrets.conf` key | Description |
|------------|-------------------|-------------|
| `treescout-action1-sync-client-id` | `ACTION1_SYNC_CLIENT_ID` | Sync role — read-only inventory |
| `treescout-action1-sync-client-secret` | `ACTION1_SYNC_CLIENT_SECRET` | |
| `treescout-action1-automation-runner-client-id` | `ACTION1_AUTOMATION_RUNNER_CLIENT_ID` | Runner role — execute scripts |
| `treescout-action1-automation-runner-client-secret` | `ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET` | |
| `treescout-action1-script-manager-client-id` | `ACTION1_SCRIPT_MANAGER_CLIENT_ID` | Manager role — create/modify scripts |
| `treescout-action1-script-manager-client-secret` | `ACTION1_SCRIPT_MANAGER_CLIENT_SECRET` | |
| `treescout-action1-region` | `ACTION1_REGION` | API region: `us` \| `eu` \| `ap` |

---

## Instance metadata — full key reference

Non-secret config stored as `ts-*` custom instance metadata.
Written by `gcp-workstation-setup.sh`, read by `gcp-server-init.sh`.

| Metadata key | `secrets.conf` key | Default | Description |
|-------------|-------------------|---------|-------------|
| `ts-domain` | `DOMAIN_NAME` | — | **Required.** Domain or external IP |
| `ts-admin-email` | `ADMIN_EMAIL` | — | **Required.** Admin login email |
| `ts-admin-first` | `ADMIN_FIRST_NAME` | `System` | Admin first name |
| `ts-admin-last` | `ADMIN_LAST_NAME` | `Administrator` | Admin last name |
| `ts-git-repo` | `GIT_REPO_URL` | `github.com/BorealTek/Treescout-Core` | App repo URL |
| `ts-git-branch` | `GIT_BRANCH` | `laravel-11-foundation` | Branch to deploy |
| `ts-install-dir` | `DEFAULT_INSTALL_DIR` | `/opt/treescout-docker` | Docker Compose root |
| `ts-docker-subnet` | `DOCKER_SUBNET` | `172.20.0.0/16` | Internal Docker network |
| `ts-db-user` | `DB_USER` | `treescout` | Database user |
| `ts-db-name` | `DB_NAME` | `treescout` | Database name |
| `ts-db-host` | `DB_HOST` | `db` | DB host (`db` = embedded container) |
| `ts-expose-public` | `EXPOSE_PUBLIC_PORTS` | `true` | Create public firewall rule |
| `ts-firewall-rule` | `GCP_FIREWALL_RULE_NAME` | `allow-treescout-https` | Firewall rule name |
| `ts-allowed-ranges` | `ALLOWED_SOURCE_RANGES` | `0.0.0.0/0` | Source CIDRs for the firewall rule |
| `ts-network-tag` | `GCP_NETWORK_TAG` | `treescout` | VM network tag |
| `ts-enable-kroki` | `ENABLE_KROKI` | `false` | Start Kroki diagram sidecar |
| `ts-enable-logging` | `ENABLE_GCP_LOGGING` | `false` | Ship Docker logs to Cloud Logging |
| `ts-agent-email` | `AGENT_EMAIL` | _(empty = skip)_ | Agent account email |
| `ts-agent-first/last` | `AGENT_FIRST/LAST_NAME` | `Support Agent` | |
| `ts-finance-email` | `FINANCE_EMAIL` | _(empty = skip)_ | Finance account email |
| `ts-finance-first/last` | `FINANCE_FIRST/LAST_NAME` | `Finance Manager` | |
| `ts-reporter-email` | `REPORTER_EMAIL` | _(empty = skip)_ | Reporter account email |
| `ts-reporter-first/last` | `REPORTER_FIRST/LAST_NAME` | `Report Viewer` | |

---

## Re-deploy / Update

### Update secrets or config only (no redeploy)

```bash
# Edit secrets.conf, then:
bash deployment/gcp/gcp-workstation-setup.sh --from-file=secrets.conf --skip-deploy
```

### Full redeploy (picks up all latest config and secrets)

```bash
# 1. Push any config/secret changes from workstation
bash deployment/gcp/gcp-workstation-setup.sh --from-file=secrets.conf --skip-deploy

# 2. Re-run server bootstrap (pulls fresh secrets, regenerates deploy.conf, redeploys)
gcloud compute ssh treescout-prod --zone=us-central1-a \
  -- 'sudo bash -s' < deployment/gcp/gcp-server-init.sh
```

### Reset to clean state (destructive — deletes all data)

```bash
# SSH into the VM
gcloud compute ssh treescout-prod --zone=us-central1-a

# On the VM:
cd /opt/treescout-docker
docker compose down -v    # ⚠ deletes all volumes and data
```

Then re-pipe the server init script from your workstation to start fresh.

---

## Rotate a secret

Rotation only requires redeploying if the value is used at container startup
(DB passwords require a container restart; API keys are read at request time).

```bash
# Update in secrets.conf and push from workstation:
bash deployment/gcp/gcp-workstation-setup.sh --from-file=secrets.conf --skip-deploy

# Or rotate a single secret directly:
echo -n "NewPassword!" | gcloud secrets versions add treescout-admin-pass \
  --project=YOUR_PROJECT_ID --data-file=-
```

For DB password rotation, update the secret and restart the affected containers:

```bash
gcloud compute ssh treescout-prod --zone=us-central1-a
cd /opt/treescout-docker && docker compose restart db app queue
```

---

## Day-to-Day Operations

All commands run on the VM under `/opt/treescout-docker`.

### Logs

```bash
docker compose logs -f app         # Nginx + PHP
docker compose logs -f queue       # Job queue worker
docker compose logs -f db          # MariaDB
docker compose logs --tail=100 | grep -iE "error|exception"
```

### Service management

```bash
docker compose ps                  # Status of all containers
docker compose restart queue       # Restart one service
docker compose stop                # Stop all
docker compose start               # Start all
docker compose exec app bash       # Shell into the app container
```

### Database backup

```bash
docker compose exec db \
  mysqldump -u treescout -p treescout \
  > /tmp/treescout-backup-$(date +%F).sql
```

### Disk / resource health

```bash
df -h /                            # Disk usage
docker stats --no-stream           # Container CPU/memory
docker system df                   # Docker layer/volume sizes
docker system prune -f             # Clean unused layers (safe)
```

---

## Production upgrades

### Let's Encrypt SSL (requires public domain + port 80 open)

```bash
docker compose exec app \
  certbot certonly --standalone \
  -d your-domain.com \
  -m admin@your-domain.com \
  --agree-tos --non-interactive
# Update Nginx SSL certificate paths and restart:
docker compose restart app
```

### Google Cloud SQL (managed DB, recommended for high availability)

```bash
gcloud sql instances create treescout-db \
  --database-version=MARIADB_10_6 \
  --tier=db-f1-micro \
  --region=us-central1

gcloud sql databases create treescout --instance=treescout-db
gcloud sql users create treescout --instance=treescout-db --password=STRONG_PASS

# Get private IP, update secrets.conf with DB_HOST and DB_PASS, then redeploy
```

### Cloud Armor (DDoS / rate limiting)

```bash
gcloud compute security-policies create treescout-armor \
  --description="Rate limiting and bot protection"

gcloud compute security-policies rules create 1000 \
  --security-policy=treescout-armor \
  --action=rate-based-ban \
  --rate-limit-options-enforce-on-key=IP \
  --rate-limit-options-ban-duration-sec=600 \
  --rate-limit-options-exceed-action=deny-429 \
  --rate-limit-options-rate-limit-threshold-count=100 \
  --rate-limit-options-rate-limit-threshold-interval-sec=60
```

### Set a billing budget alert

```bash
gcloud billing budgets create \
  --billing-account=YOUR_ACCOUNT_ID \
  --display-name="TreeScout Budget" \
  --budget-amount=60USD \
  --threshold-rule=percent=90 \
  --threshold-rule=percent=100
```

---

## Troubleshooting

### Cannot reach the application

```bash
# Confirm external IP
gcloud compute instances describe treescout-prod \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'

# Check firewall rule — targetTags must include: treescout; allow must include: tcp:443,tcp:80
gcloud compute firewall-rules describe allow-treescout-https

# Check the VM has the network tag — re-run gcp-workstation-setup.sh if missing
gcloud compute instances describe treescout-prod \
  --zone=us-central1-a --format='get(tags)'

# Check containers on the VM
docker compose -f /opt/treescout-docker/docker-compose.yml ps
```

### "insufficient authentication scopes" when pulling secrets

The VM was created without `--scopes=cloud-platform`.
Re-run `gcp-workstation-setup.sh` — it detects this and fixes it automatically.

Or fix manually from your workstation:

```bash
gcloud compute instances stop treescout-prod --zone=us-central1-a
gcloud compute instances set-service-account treescout-prod \
  --zone=us-central1-a --scopes=cloud-platform
gcloud compute instances start treescout-prod --zone=us-central1-a
```

Also check for a stale gcloud account config on the VM:

```bash
sudo gcloud config unset core/account
```

`gcp-server-init.sh` prevents this automatically by injecting the metadata token
directly via `CLOUDSDK_AUTH_ACCESS_TOKEN`.

### Metadata keys missing (`ts-domain not set`)

The workstation script hasn't been run yet, or was run against a different instance.

```bash
# Verify from workstation:
gcloud compute instances describe treescout-prod \
  --zone=us-central1-a \
  --format='yaml(metadata)'

# Re-push metadata:
bash deployment/gcp/gcp-workstation-setup.sh --from-file=secrets.conf --skip-deploy
```

### Modules won't clone

```bash
# Verify the token is present and valid
gcloud secrets versions access latest \
  --secret="treescout-repo-token" --project=YOUR_PROJECT_ID
# Token must start with ghp_ and have repo scope
# Rotate if expired:
echo -n "new_ghp_token" | gcloud secrets versions add treescout-repo-token \
  --project=YOUR_PROJECT_ID --data-file=-
```

### Database connection failed

```bash
cd /opt/treescout-docker
docker compose logs db | tail -30
docker compose exec app mysql -h db -u treescout -p -e "SHOW DATABASES;"
docker compose restart db
```

### High CPU / memory

```bash
docker stats --no-stream
# If PHP memory is the culprit:
sed -i 's/PHP_MEMORY_LIMIT=512M/PHP_MEMORY_LIMIT=1024M/' \
  /opt/treescout-docker/docker-compose.yml
docker compose restart app
```

---

## Cost reference

| Component | Est. monthly |
|-----------|-------------|
| e2-standard-2 (730 h) | ~$35 |
| 50 GB persistent disk | ~$3 |
| Secret Manager (< 10k accesses) | ~$0 |
| Cloud SQL db-f1-micro (optional) | ~$15–20 |
| Networking (egress) | ~$1–2 |
| **Total (basic)** | **~$40/month** |
| **Total (with Cloud SQL)** | **~$55/month** |

Use `e2-medium` (~$25/mo) for lighter workloads; apply Committed Use Discounts for
20–57% savings on 1–3 year terms.

---

## GCP Console quick links

- Compute Instances: https://console.cloud.google.com/compute/instances
- Firewall Rules: https://console.cloud.google.com/vpc/firewalls
- Secret Manager: https://console.cloud.google.com/security/secret-manager
- Cloud Logging: https://console.cloud.google.com/logs
- Cloud Monitoring: https://console.cloud.google.com/monitoring
- Billing / Budgets: https://console.cloud.google.com/billing

---

## Script reference

| Script | Run from | Purpose |
|--------|----------|---------|
| `gcp-workstation-setup.sh` | Workstation | Create / assert GCP infrastructure, push secrets, write instance metadata |
| `gcp-server-init.sh` | VM (piped via SSH) | Install deps, pull secrets + metadata, generate `deploy.conf`, run deploy |
| `gcp-secrets-bootstrap.sh` | Workstation | Push secrets only — useful for credential rotation without a full setup run |
| `gcp_deploy.sh` | VM | GCP-aware deploy wrapper: firewall, Cloud Logging setup, then calls `docker_deploy.sh` |
| `docker_deploy.sh` | VM | Core Docker Compose installer: clone repo, install modules, SSL certs, `compose up` |
| `gcp-config-validate.sh` | VM | Pre-deploy validator for `deploy.conf` (called automatically by `gcp_deploy.sh`) |
| `modules.manifest.json` | Reference | Canonical module list and deployment profiles |
