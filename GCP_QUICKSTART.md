# FreeScout GCP Deployment — Quick Start

Deploy FreeScout on Google Cloud Platform in 4 steps.
Secrets are stored in **GCP Secret Manager** — no passwords in files.

## 📋 Requirements

- **GCP Account** with billing enabled
- **gcloud CLI** installed and authenticated (`gcloud auth login`)
- **GitHub PAT Token** for private BorealTek modules (`https://github.com/settings/tokens` — scope: `repo`)
- **Domain name** or GCP external IP (e.g. `34.x.x.x.nip.io` for testing)

---

## 🚀 Deploy in 4 Steps

### Step 1 — Create GCP Instance

```bash
gcloud compute instances create freescout-prod \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --machine-type=e2-standard-2 \
  --zone=us-central1-a \
  --boot-disk-size=50GB
```

**SSH in:**
```bash
gcloud compute ssh freescout-prod --zone=us-central1-a
```

---

### Step 2 — Bootstrap Secrets (run from your workstation, not the VM)

This creates all credentials in GCP Secret Manager — **nothing sensitive ever touches the config file**.

```bash
# Clone the deployment repo
git clone https://github.com/BorealTek/Treescout-Deployments.git
cd Treescout-Deployments

# Interactive wizard — prompts for each secret, confirms, then creates/updates them
bash deployment/gcp-secrets-bootstrap.sh
```

The wizard will prompt you for:

| Secret | GCP Secret Manager name |
|--------|------------------------|
| GitHub PAT (scope: `repo`) | `freescout-repo-token` |
| Database root password | `freescout-db-root-pass` |
| Database app-user password | `freescout-db-pass` |
| Admin user password | `freescout-admin-pass` |
| Agent user password _(optional)_ | `freescout-agent-pass` |
| Finance user password _(optional)_ | `freescout-finance-pass` |
| Reporter user password _(optional)_ | `freescout-reporter-pass` |

It also grants the Compute Engine default service account the `secretAccessor` IAM role so the VM can read secrets at deploy time.

---

### Step 3 — Configure Deployment

On the **VM** (after SSH):

```bash
# Clone deployment repo (if not already cloned on the VM)
git clone https://github.com/BorealTek/Treescout-Deployments.git /opt/treescout-deploy
cd /opt/treescout-deploy

# Copy the GCP template (deploy.conf is gitignored — safe to fill in)
cp deployment/deploy.conf.gcp deploy.conf
chmod 600 deploy.conf
nano deploy.conf
```

**Only these two values need editing** — everything else is pulled from Secret Manager at deploy time:

```bash
DOMAIN_NAME="your-domain.com"          # ← your actual domain or external IP
ALLOWED_SOURCE_RANGES="203.0.113.5/32" # ← your IP(s) — use 0.0.0.0/0 only for testing
```

**Validate before deploying:**
```bash
bash deployment/gcp-config-validate.sh
```

All passwords should show `managed by Secret Manager` — no errors expected.

---

### Step 4 — Deploy

```bash
sudo bash deployment/gcp_deploy.sh
```

Deployment takes **10–20 minutes**. Watch live in a second terminal:
```bash
cd /opt/freescout-docker && docker compose logs -f app
```

---

## ✅ Verify Deployment

```bash
# Get external IP
gcloud compute instances describe freescout-prod \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

Open `https://<EXTERNAL_IP>` in your browser, accept the self-signed certificate warning,
and log in with the admin email and the password you entered in Step 2.

---

## 🔧 Configuration Reference

The following values in `deploy.conf` are **non-secret** and can be edited freely:

| Key | Default | Notes |
|-----|---------|-------|
| `DOMAIN_NAME` | _(required)_ | Domain or GCP IP |
| `ADMIN_EMAIL` | `admin@example.com` | Admin login email |
| `ALLOWED_SOURCE_RANGES` | _(required)_ | CIDR(s) for firewall rule |
| `EXPOSE_PUBLIC_PORTS` | `true` | Set `false` for internal-only |
| `REUSE_DB` | `true` | Preserve DB on redeploy |
| `ENABLE_GCP_LOGGING` | `true` | Ship logs to Cloud Logging |
| `ENABLE_GCP_BACKUPS` | `false` | **Set `true` for production** |
| `GCP_BACKUP_BUCKET` | _(empty)_ | `gs://your-bucket/freescout/` |

### Modules (choose a profile in `deploy.conf`)

```bash
# Full internal deployment — 18 modules (default in deploy.conf.gcp)
# Source of truth: deployment/modules.manifest.json

# Example trimmed client profile — edit MODULES_TO_INSTALL in deploy.conf:
MODULES_TO_INSTALL=(
    "Crm|https://github.com/BorealTek/Crm-Module.git|REPO_TOKEN|main"
    "PIB|https://github.com/BorealTek/PIB-Module.git|REPO_TOKEN|main"
    "AssetManagement|https://github.com/BorealTek/AssetManagement-Module.git|REPO_TOKEN|main"
    "ClientPortal|https://github.com/BorealTek/ClientPortal-Module.git|REPO_TOKEN|main"
)
```

---

## 📂 Key Files

| File | Purpose |
|------|---------|
| `gcp-secrets-bootstrap.sh` | Create/update all secrets in Secret Manager (run once from workstation) |
| `gcp_deploy.sh` | Main deployer — detects GCP, creates firewall, launches docker_deploy.sh |
| `deploy.conf.gcp` | Config template (no secrets — committed to git) |
| `gcp-config-validate.sh` | Pre-deploy config validator |
| `GCP_DEPLOYMENT.md` | Full guide — production upgrades, Cloud SQL, SSL, cost |
| `GCP_CHECKLIST.md` | Pre/post-deploy checklist, troubleshooting |

---

## 🛠️ Common Tasks

### View Logs
```bash
cd /opt/freescout-docker
docker compose logs -f app     # Application
docker compose logs -f queue   # Job queue
docker compose logs -f db      # Database
```

### Stop / Start Services
```bash
cd /opt/freescout-docker
docker compose stop
docker compose start
docker compose restart queue
```

### Database Backup
```bash
cd /opt/freescout-docker
docker compose exec db mysqldump -u freescout -p freescout > /tmp/backup-$(date +%F).sql
```

### Rotate a Secret
```bash
# Update the value in Secret Manager (no redeploy needed for next deploy)
echo -n "NewStrongPassword!" | gcloud secrets versions add freescout-admin-pass --data-file=-
```

---

## ⚠️ Troubleshooting

### Cannot access the application?
```bash
# Check external IP
gcloud compute instances describe freescout-prod \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)' --zone=us-central1-a

# Check firewall rule
gcloud compute firewall-rules list --filter="name:allow-freescout"

# Check containers
cd /opt/freescout-docker && docker compose ps
```

### Secrets not pulling at deploy time?
```bash
# Verify the VM service account has access
gcloud secrets versions access latest --secret="freescout-repo-token"
# If denied → re-run: bash deployment/gcp-secrets-bootstrap.sh  (IAM step)
```

### Module clone failing?
```bash
# Verify token is readable and valid
gcloud secrets versions access latest --secret="freescout-repo-token"
# Token must start with ghp_ and have repo scope
```

See **GCP_CHECKLIST.md** for more troubleshooting steps.

---

## 💰 Estimated Monthly Costs

| Component | Cost |
|-----------|------|
| e2-standard-2 instance | ~$35 |
| 50 GB persistent disk | ~$3 |
| Secret Manager (< 10k accesses) | ~$0 |
| Networking | ~$1–2 |
| **Total** | **~$40/month** |

See `GCP_DEPLOYMENT.md → GCP Cost Optimization` for ways to reduce costs.

---

## 🔐 Security Checklist

- [ ] Secrets stored in GCP Secret Manager — not in `deploy.conf`
- [ ] `deploy.conf` mode `600` (readable only by owner)
- [ ] `ALLOWED_SOURCE_RANGES` restricted to your IP(s) for production
- [ ] `ENABLE_GCP_BACKUPS="true"` set before going live
- [ ] Upgrade self-signed cert to production SSL (Let's Encrypt or GCP Managed)
- [ ] Enable Cloud Armor for DDoS protection (optional, production)

---

## 📖 Full Documentation

| Guide | Contents |
|-------|----------|
| **GCP_DEPLOYMENT.md** | Cloud SQL, production SSL, upgrades, cost optimisation |
| **GCP_CHECKLIST.md** | Pre/post-deploy checklist, maintenance runbook |
| **GCP_README.md** | Architecture overview, all files explained |
