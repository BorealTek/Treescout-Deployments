# FreeScout GCP Deployment Guide

Complete guide to deploying FreeScout + all BorealTek modules on Google Cloud Platform using Docker Compose and GCP Secret Manager.

---

## Contents

1. [Requirements](#requirements)
2. [Architecture](#architecture)
3. [Phase 1 — Create GCP Instance](#phase-1--create-gcp-instance)
4. [Phase 2 — Bootstrap Secrets](#phase-2--bootstrap-secrets)
5. [Phase 3 — Configure deploy.conf](#phase-3--configure-deployconf)
6. [Phase 4 — Validate & Deploy](#phase-4--validate--deploy)
7. [Post-Deployment Checklist](#post-deployment-checklist)
8. [Day-to-Day Operations](#day-to-day-operations)
9. [Redeploy / Update](#redeploy--update)
10. [Production Upgrades](#production-upgrades)
11. [Troubleshooting](#troubleshooting)
12. [Cost Reference](#cost-reference)

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| GCP account with billing enabled | https://console.cloud.google.com |
| `gcloud` CLI installed & authenticated | `gcloud auth login` |
| GitHub PAT token | https://github.com/settings/tokens — scope: `repo` |
| Domain name or GCP external IP | e.g. `34.x.x.x.nip.io` for testing |
| Machine: e2-standard-2 or larger | 2 vCPU, 8 GB RAM minimum |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Google Cloud Platform                                       │
│                                                              │
│  Secret Manager                                              │
│  ├─ freescout-repo-token                  (GitHub PAT)      │
│  ├─ freescout-db-root-pass / db-pass                        │
│  ├─ freescout-admin-pass                                     │
│  ├─ freescout-agent/finance/reporter-pass (optional)        │
│  ├─ freescout-google-client-id/secret     (optional)        │
│  ├─ freescout-google-admin-emails         (optional)        │
│  ├─ freescout-google-allowed-domains      (optional)        │
│  ├─ freescout-action1-sync-client-id/secret (optional)      │
│  ├─ freescout-action1-automation-runner-*  (optional)       │
│  └─ freescout-action1-script-manager-*    (optional)        │
│                        ↓ pulled at deploy time               │
│  Compute Engine Instance (e2-standard-2, Debian 12)         │
│  ├─ External IP ←── GCP Firewall Rule (allow-freescout-https)│
│  └─ /opt/freescout-docker/                                   │
│     └─ Docker Compose                                        │
│        ├─ app    Nginx + PHP 8.3 (HTTPS :443)               │
│        ├─ db     MariaDB 10.6 (internal only)               │
│        ├─ redis  Session & cache                             │
│        ├─ queue  Laravel queue worker                        │
│        ├─ cron   Task scheduler                              │
│        └─ reverb WebSocket server                            │
└──────────────────────────────────────────────────────────────┘
```

**Script flow:**

```
gcp_deploy.sh
  1. Detect GCP instance metadata
  2. Load deploy.conf
  3. Pull secrets from Secret Manager
  4. Create firewall rules + apply network tags
  5. exec → docker_deploy.sh
              ├─ Clone FreeScout repo
              ├─ Clone & install modules (using REPO_TOKEN from SM)
              ├─ Generate SSL certs
              └─ docker compose up -d
```

---

## Phase 1 — Create GCP Instance

Run from your **local workstation**.

```bash
gcloud compute instances create freescout-prod \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --machine-type=e2-standard-2 \
  --zone=us-central1-a \
  --boot-disk-size=50GB \
  --scopes=cloud-platform
```

> **`--scopes=cloud-platform` is required.** Without it the VM's OAuth token will not have permission to call the Secret Manager API, causing all secret pulls to fail with "insufficient authentication scopes" even if the IAM role is correct. If you created your instance without this flag, see [Secrets not pulling](#secrets-not-pulling-at-deploy-time).

Verify it has an external IP:

```bash
gcloud compute instances describe treescout-prod  --zone=us-central1-a   --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

Pre-deploy checklist:
- [x] Instance created and running
- [x] Can SSH: `gcloud compute ssh freescout-prod --zone=us-central1-a`
- [x] Disk: 50 GB minimum

---

## Phase 2 — Bootstrap Secrets

Run from your **local workstation** (not the VM). This creates all credentials in GCP Secret Manager so nothing sensitive ever touches the config file.

```bash
git clone https://github.com/BorealTek/Treescout-Deployments.git
cd Treescout-Deployments
bash deployment/gcp-secrets-bootstrap.sh
```

The wizard will prompt for each secret, confirm your input, and create or update the secret in Secret Manager. It also grants the Compute Engine default service account the `secretAccessor` IAM role.

Secrets created:

**Required secrets:**

| Secret name | What it holds |
|-------------|---------------|
| `freescout-repo-token` | GitHub PAT (scope: `repo`) for private module repos |
| `freescout-db-root-pass` | MariaDB root password |
| `freescout-db-pass` | MariaDB application-user password |
| `freescout-admin-pass` | Admin account initial password |

**Optional — seeded user accounts:**

| Secret name | What it holds |
|-------------|---------------|
| `freescout-agent-pass` | Agent account password |
| `freescout-finance-pass` | Finance account password |
| `freescout-reporter-pass` | Reporter account password |

**Optional — Google OAuth (requires GoogleAdmin module):**

| Secret name | What it holds |
|-------------|---------------|
| `freescout-google-client-id` | Google OAuth 2.0 Client ID |
| `freescout-google-client-secret` | Google OAuth 2.0 Client Secret |
| `freescout-google-admin-emails` | Comma-separated emails auto-promoted to admin on first OAuth sign-in |
| `freescout-google-allowed-domains` | Comma-separated domains whose users are auto-provisioned as internal accounts |

> **`GOOGLE_ALLOWED_DOMAINS` behaviour:** existing users (already in the database) can always sign in with Google regardless of domain. This setting only gates **new account auto-provisioning** — users from unlisted domains are denied the ability to create a new account via Google OAuth, but can still be added manually by an admin.

**Optional — Action1 RMM (requires Action1 module):**

| Secret name | What it holds |
|-------------|---------------|
| `freescout-action1-sync-client-id` | Action1 Sync role OAuth Client ID (read-only inventory) |
| `freescout-action1-sync-client-secret` | Action1 Sync role OAuth Client Secret |
| `freescout-action1-automation-runner-client-id` | Action1 Automation Runner role Client ID (execute scripts) |
| `freescout-action1-automation-runner-client-secret` | Action1 Automation Runner role Client Secret |
| `freescout-action1-script-manager-client-id` | Action1 Script Manager role Client ID (create/modify scripts) |
| `freescout-action1-script-manager-client-secret` | Action1 Script Manager role Client Secret |

To rotate any secret later:

```bash
echo -n "NewPassword!" | gcloud secrets versions add freescout-admin-pass --data-file=-
```

Pre-deploy checklist:
- [ ] All required secrets created (bootstrap script shows ✔ for each)
- [ ] Can verify readability: `gcloud secrets versions access latest --secret="freescout-repo-token"`
- [ ] Compute Engine SA has `secretAccessor` role (bootstrap handles this)

---

## Phase 3 — Configure deploy.conf

SSH into the VM:

```bash
gcloud compute ssh freescout-prod --zone=us-central1-a
```

Clone and configure on the VM:

```bash
mkdir -p /opt/treescout-deploy
git clone https://github.com/BorealTek/Treescout-Deployments.git /opt/treescout-deploy/deployment
cd /opt/treescout-deploy

cp deployment/deploy.conf.gcp deploy.conf
chmod 600 deploy.conf   # Restrict access before editing
nano deploy.conf
```

**Only two values are required** — everything else is pulled from Secret Manager:

```bash
DOMAIN_NAME="your-domain.com"   # Your actual domain or GCP external IP
ALLOWED_SOURCE_RANGES="0.0.0.0/0"  # Public app: allow all IPs (ports 443/80)
                                    # Internal/VPN-only: restrict to CIDRs e.g. "203.0.113.0/24,10.0.0.0/8"
```

> **Public vs. restricted access:** `ALLOWED_SOURCE_RANGES` controls the GCP firewall rule for ports 443 and 80 only. For a customer-facing application, `0.0.0.0/0` is the correct setting — you cannot know all client IPs ahead of time. Use a restricted CIDR only for internal tools accessed over a VPN or from a known office network.

Non-secret values you may want to review:

| Key | Default | Notes |
|-----|---------|-------|
| `ADMIN_EMAIL` | `admin@example.com` | Admin login email — change this |
| `GCP_ZONE` | `us-central1-a` | Auto-detected; override if needed |
| `EXPOSE_PUBLIC_PORTS` | `true` | Set `false` for internal-only |
| `REUSE_DB` | `true` | Preserves DB on redeploy |
| `ENABLE_GCP_LOGGING` | `true` | Ships Docker logs to Cloud Logging |
| `ENABLE_GCP_BACKUPS` | `false` | **Set `true` before going live** |
| `GCP_BACKUP_BUCKET` | _(empty)_ | `gs://your-bucket/freescout/` |

### Optional integrations

If you populated Google OAuth or Action1 secrets in Phase 2, ensure the `_SECRET` name entries in `deploy.conf` match (they already do in `deploy.conf.gcp`). Leave the plaintext value fields blank — they are filled automatically at deploy time from Secret Manager.

For Google OAuth, also review:

```bash
GOOGLE_ADMIN_EMAILS=""          # leave blank — pulled from SM via GOOGLE_ADMIN_EMAILS_SECRET
GOOGLE_ALLOWED_DOMAINS=""       # leave blank — pulled from SM via GOOGLE_ALLOWED_DOMAINS_SECRET
```

For Action1, set the region if your organisation is outside the US default:

```bash
ACTION1_REGION="us"             # us | eu | ap
```

### Module selection

The default `MODULES_TO_INSTALL` array in `deploy.conf.gcp` includes all 18 BorealTek modules (full internal profile). For a client deployment, trim it to the required profile. The canonical list of modules and profiles lives in `deployment/modules.manifest.json`.

Example trimmed client profile:

```bash
MODULES_TO_INSTALL=(
    "Crm|https://github.com/BorealTek/Crm-Module.git|REPO_TOKEN|main"
    "PIB|https://github.com/BorealTek/PIB-Module.git|REPO_TOKEN|main"
    "AssetManagement|https://github.com/BorealTek/AssetManagement-Module.git|REPO_TOKEN|main"
    "ClientPortal|https://github.com/BorealTek/ClientPortal-Module.git|REPO_TOKEN|main"
    "ContractManager|https://github.com/BorealTek/ContractManager-Module.git|REPO_TOKEN|main"
)
```

---

## Phase 4 — Validate & Deploy

### Validate

```bash
cd /opt/treescout-deploy
bash deployment/gcp-config-validate.sh
```

Expected output: all passwords show `managed by Secret Manager`, no errors.
Warnings about optional settings can be accepted at the prompt.

Pre-deploy checklist:
- [ ] `DOMAIN_NAME` is not the placeholder value
- [ ] `ALLOWED_SOURCE_RANGES` is set
- [ ] `ADMIN_EMAIL` changed from `admin@example.com`
- [ ] Validator shows 0 errors

### Deploy

```bash
sudo bash deployment/gcp_deploy.sh
```

Deployment takes **10–20 minutes** depending on module count. Watch progress in a second terminal:

```bash
gcloud compute ssh freescout-prod --zone=us-central1-a
cd /opt/freescout-docker && docker compose logs -f app
```

### Access

```bash
EXTERNAL_IP=$(gcloud compute instances describe freescout-prod \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo "https://$EXTERNAL_IP"
```

Accept the self-signed certificate warning and log in with `ADMIN_EMAIL` and the password stored in `freescout-admin-pass`.

---

## Post-Deployment Checklist

### Infrastructure

- [ ] All containers running: `docker compose ps` (status: `Up`)
  - `app` · `db` · `redis` · `queue` · `cron` · `reverb`
- [ ] Firewall rule exists: `gcloud compute firewall-rules list --filter="name:allow-freescout"`
- [ ] Instance has `freescout` network tag: `gcloud compute instances describe freescout-prod --format='get(tags)'`

### Application

- [ ] Homepage loads at `https://<EXTERNAL_IP>` (accept cert warning for self-signed)
- [ ] Admin login works
- [ ] Admin → Modules: all installed modules show **Active**
- [ ] No PHP errors in logs: `docker compose logs app | grep -i error`

### Database

```bash
cd /opt/freescout-docker
docker compose exec db mysql -u freescout -p -e "SHOW TABLES IN freescout;" 2>/dev/null
```

- [ ] Database `freescout` exists and has tables

### Day 1 tasks

- [ ] Configure at least one mailbox (Admin → Mailboxes)
- [ ] Test sending and receiving email
- [ ] Set `ENABLE_GCP_BACKUPS="true"` and `GCP_BACKUP_BUCKET` in `deploy.conf`, then redeploy
- [ ] Plan SSL upgrade (self-signed → Let's Encrypt or GCP Managed Certificate)

---

## Day-to-Day Operations

All commands run from `/opt/freescout-docker` on the VM.

### Logs

```bash
docker compose logs -f app     # Application (Nginx + PHP)
docker compose logs -f queue   # Job queue worker
docker compose logs -f db      # Database
docker compose logs --tail=100 | grep -i "error\|exception"
```

### Service management

```bash
docker compose ps              # Status of all containers
docker compose stop            # Stop all
docker compose start           # Start all
docker compose restart queue   # Restart one service
docker compose exec app bash   # Shell into the app container
```

### Database backup

```bash
docker compose exec db mysqldump -u freescout -p freescout \
  > /tmp/freescout-backup-$(date +%F).sql
```

### Disk / resource health

```bash
df -h /                        # Disk usage
docker stats --no-stream       # Container CPU/memory
docker system df               # Docker layer/volume sizes
docker system prune -f         # Clean unused layers (safe)
```

---

## Redeploy / Update

Always back up the database first.

```bash
cd /opt/freescout-docker

# 1. Backup
docker compose exec db mysqldump -u freescout -p freescout \
  > /tmp/freescout-backup-$(date +%F).sql

# 2. Pull latest code
git -C /opt/treescout-deploy pull origin master

# 3. Rebuild and restart (REUSE_DB=true preserves data)
docker compose down
docker compose up -d --build

# 4. Run any pending migrations
docker compose exec app php artisan migrate --force
```

### Reset to clean state (destructive)

```bash
cd /opt/freescout-docker
docker compose down -v          # ⚠ Deletes volumes — all data lost
sudo bash /opt/treescout-deploy/deployment/gcp_deploy.sh
```

---

## Production Upgrades

### Let's Encrypt SSL (requires public domain + port 80 open)

```bash
cd /opt/freescout-docker
docker compose exec app apt-get install -y certbot python3-certbot-nginx
docker compose exec app certbot certonly \
  --standalone \
  -d your-domain.com \
  -m admin@your-domain.com \
  --agree-tos \
  --non-interactive
```

Update the Nginx SSL certificate paths and restart: `docker compose restart app`

### GCP Managed Certificate (requires Cloud Load Balancer)

```bash
# 1. Create the certificate
gcloud compute ssl-certificates create freescout-ssl \
  --domains=freescout.your-domain.com

# 2. Create health check
gcloud compute health-checks create https freescout-health \
  --port=443 --request-path=/health

# 3. Create backend service and wire everything up
gcloud compute backend-services create freescout-backend \
  --protocol=HTTPS --health-checks=freescout-health --global

# Update deploy.conf and set USE_MANAGED_SSL="true" for subsequent deploys
```

### Google Cloud SQL (managed database, recommended for production)

```bash
# 1. Create instance
gcloud sql instances create freescout-db \
  --database-version=MARIADB_10_6 \
  --tier=db-f1-micro \
  --region=us-central1

# 2. Create database and user
gcloud sql databases create freescout --instance=freescout-db
gcloud sql users create freescout --instance=freescout-db --password=STRONG_PASS

# 3. Get private IP
gcloud sql instances describe freescout-db --format='get(ipAddresses[0].ipAddress)'

# 4. Update deploy.conf
#    DB_HOST="<private_ip>"   DB_PASS="STRONG_PASS"
# 5. Redeploy: sudo bash deployment/gcp_deploy.sh
```

### Cloud Armor (DDoS / rate limiting)

```bash
gcloud compute security-policies create freescout-armor \
  --description="Rate limiting and bot protection"

gcloud compute security-policies rules create 1000 \
  --security-policy=freescout-armor \
  --action=rate-based-ban \
  --rate-limit-options-enforce-on-key=IP \
  --rate-limit-options-ban-duration-sec=600 \
  --rate-limit-options-exceed-action=deny-429 \
  --rate-limit-options-rate-limit-threshold-count=100 \
  --rate-limit-options-rate-limit-threshold-interval-sec=60

# Attach to backend service after creating a load balancer
gcloud compute backend-services update freescout-backend \
  --security-policy=freescout-armor --global
```

---

## Troubleshooting

### Cannot reach the application

```bash
# 1. Confirm external IP is assigned
gcloud compute instances describe freescout-prod \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'

# 2. Check firewall rule
gcloud compute firewall-rules describe allow-freescout-https
# Must show: target-tags: freescout, allow: tcp:443,tcp:80

# 3. Check instance tag
gcloud compute instances describe freescout-prod --format='get(tags)'
# Must include: freescout
# If missing: gcloud compute instances add-tags freescout-prod --tags=freescout --zone=us-central1-a

# 4. Check containers
cd /opt/freescout-docker && docker compose ps
```

### Secrets not pulling at deploy time

```bash
# Test access from the VM
gcloud secrets versions access latest --secret="freescout-repo-token"
# If permission denied → re-run gcp-secrets-bootstrap.sh (IAM step) from workstation
```

**"insufficient authentication scopes"** — two layered causes:

**Layer 1 — VM access scope** (set at instance level):
The VM was created without `--scopes=cloud-platform`. Fix from your workstation:
```bash
gcloud compute instances stop   treescout-prod --zone=us-central1-a
gcloud compute instances set-service-account treescout-prod \
  --zone=us-central1-a --scopes=cloud-platform
gcloud compute instances start  treescout-prod --zone=us-central1-a
```

**Layer 2 — gcloud `core/account` config** (even after correct VM scopes are set):
If gcloud on the VM has `core/account` in its config, it uses a locally-cached credential rather than fetching a fresh token from the metadata server. Diagnose and fix on the VM:
```bash
# Check
sudo gcloud config list | grep account
sudo curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes"

# Fix: clear the explicit account so gcloud falls back to the metadata server
sudo gcloud config unset core/account
```

`gcp_deploy.sh` now also works around this automatically by fetching the metadata token directly and injecting it via `CLOUDSDK_AUTH_ACCESS_TOKEN` before calling gcloud.

The [`gcp-secrets-bootstrap.sh`](gcp-secrets-bootstrap.sh) script will also offer to update VM scopes interactively.

### Database connection failed

```bash
cd /opt/freescout-docker
docker compose logs db | tail -30
docker compose exec app mysql -h db -u freescout -p -e "SHOW DATABASES;"
docker compose restart db
```

### Modules won't clone

```bash
# Verify token resolves from Secret Manager and is valid
gcloud secrets versions access latest --secret="freescout-repo-token"
# Token must start with ghp_ and have repo scope
# If expired: rotate with echo -n "new_token" | gcloud secrets versions add freescout-repo-token --data-file=-
```

### High CPU / memory

```bash
docker stats --no-stream
# Common causes: queue backlog, slow DB queries, PHP memory limit
# Quick fix:
sed -i 's/PHP_MEMORY_LIMIT=512M/PHP_MEMORY_LIMIT=1024M/' /opt/freescout-docker/docker-compose.yml
docker compose restart app
```

### Deployment script hangs > 10 minutes

```bash
# Check for disk full
df -h /
# Check Docker build progress
docker ps
# Kill and retry with clean state
docker compose down && docker system prune -f
sudo bash deployment/gcp_deploy.sh
```

---

## Cost Reference

| Component | Est. monthly cost |
|-----------|-------------------|
| e2-standard-2 instance (730 h) | ~$35 |
| 50 GB persistent disk | ~$3 |
| Secret Manager (< 10k accesses/mo) | ~$0 |
| Cloud SQL db-f1-micro (if used) | ~$15–20 |
| Networking (egress) | ~$1–2 |
| **Total (basic)** | **~$40/month** |
| **Total (with Cloud SQL)** | **~$55/month** |

Tips: use **e2-medium** (~$25) if load is light; apply **Committed Use Discounts** for 1–3 year terms (20–57% savings); enable auto-shutdown cron for dev/test VMs.

Set a budget alert:

```bash
gcloud billing budgets create \
  --billing-account=YOUR_ACCOUNT_ID \
  --display-name="FreeScout Budget" \
  --budget-amount=60USD \
  --threshold-rule=percent=90 \
  --threshold-rule=percent=100
```

---

## GCP Console Quick Links

- Compute Instances: https://console.cloud.google.com/compute/instances
- Firewall Rules: https://console.cloud.google.com/vpc/firewalls
- Secret Manager: https://console.cloud.google.com/security/secret-manager
- Cloud Logging: https://console.cloud.google.com/logs
- Cloud Monitoring: https://console.cloud.google.com/monitoring
- Billing / Budgets: https://console.cloud.google.com/billing

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `gcp-secrets-bootstrap.sh` | One-time wizard to create all secrets in Secret Manager |
| `gcp_deploy.sh` | Main deployer — detects GCP, pulls secrets, creates firewall, launches docker_deploy.sh |
| `deploy.conf.gcp` | Config template (no secrets — safe to commit) |
| `gcp-config-validate.sh` | Pre-deploy config validator |
| `docker_deploy.sh` | Core Docker Compose installer (called by gcp_deploy.sh) |
| `modules.manifest.json` | Canonical source of truth for module definitions and deployment profiles |
