# FreeScout GCP Deployment — Quick Start

Deploy FreeScout on Google Cloud Platform in 3 commands.

## 📋 Requirements

- **GCP Account** with billing enabled
- **gcloud CLI** installed (https://cloud.google.com/sdk/docs/install)
- **GitHub PAT Token** for private modules (https://github.com/settings/tokens)
- **Domain name** (or use GCP IP temporarily)

---

## 🚀 Deploy in 3 Steps

### Step 1: Create GCP Instance

```bash
gcloud compute instances create freescout-prod \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --machine-type=e2-standard-2 \
  --zone=us-central1-a \
  --boot-disk-size=50GB
```

**Then SSH in:**
```bash
gcloud compute ssh freescout-prod --zone=us-central1-a
```

### Step 2: Setup Configuration

```bash
# Clone deployment repo
git clone https://github.com/BorealTek/Treescout-Deployments.git
cd Treescout-Deployments

# Copy config template
cp deployment/deploy.conf.gcp deploy.conf

# Edit ALL these values:
nano deploy.conf
```

**Critical edits in deploy.conf:**
```bash
DOMAIN_NAME="your-domain.com"              # or use GCP external IP
ADMIN_EMAIL="admin@yourcompany.com"
ADMIN_PASS="StrongPassword123!"            # Change from default!
DB_ROOT_PASS="DatabaseRootPass123!"        # Change from default!
DB_PASS="DatabaseUserPass123!"             # Change from default!
export REPO_TOKEN="ghp_xxxxxxxxxxxx"       # GitHub PAT token
```

**Validate config before deploying:**
```bash
bash deployment/gcp-config-validate.sh
```

### Step 3: Deploy

```bash
sudo bash deployment/gcp_deploy.sh
```

**Deployment takes 10-20 minutes.** Watch logs in another terminal:
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

# Open in browser (replace with actual IP)
https://1.2.3.4

# Accept self-signed certificate warning
# Login: admin@yourcompany.com / (your admin password)
```

---

## 📂 Files Created

| File | Purpose | Size |
|------|---------|------|
| **gcp_deploy.sh** | Main deployment script (auto-detects GCP, creates firewall) | 18K |
| **deploy.conf.gcp** | GCP configuration template (edit before deploy) | 12K |
| **gcp-config-validate.sh** | Validates deploy.conf before deployment | 13K |
| **GCP_DEPLOYMENT.md** | Complete guide with production upgrades | 15K |
| **GCP_CHECKLIST.md** | Quick reference & troubleshooting | 12K |
| **GCP_README.md** | Overview of all GCP files | 11K |

---

## 🔧 Configuration Options

### Essential
```bash
DOMAIN_NAME="your-domain.com"
ADMIN_EMAIL="admin@company.com"
ADMIN_PASS="strong-password"
REPO_TOKEN="ghp_xxxxx"  # GitHub PAT
```

### Database
```bash
DB_ROOT_PASS="strong-root-password"
DB_PASS="strong-user-password"
DB_NAME="freescout"
```

### Network
```bash
EXPOSE_PUBLIC_PORTS="true"              # Expose to internet
ALLOWED_SOURCE_RANGES="0.0.0.0/0"       # Or restrict to your IP: "203.0.113.5/32"
```

### SSL/TLS
```bash
USE_MANAGED_SSL="false"                 # Use self-signed (default)
# Other options: Google Managed, Let's Encrypt (see GCP_DEPLOYMENT.md)
```

### Modules (Choose What to Install)
```bash
MODULES_TO_INSTALL=(
    "Crm|https://github.com/BorealTek/Crm-Module.git|REPO_TOKEN|main"
    "PIB|https://github.com/BorealTek/PIB-Module.git|REPO_TOKEN|main"
    # Add more as needed (see deploy.conf.gcp for full list)
)
```

---

## 📖 Documentation

- **GCP_DEPLOYMENT.md** — Full guide, production upgrades, cost optimization
- **GCP_CHECKLIST.md** — Pre/post deployment checklist, troubleshooting
- **GCP_README.md** — Overview of all files and architecture

---

## 🛠️ Common Tasks

### Access Application
```bash
# Get external IP
gcloud compute instances describe freescout-prod --format='get(networkInterfaces[0].accessConfigs[0].natIP)' --zone=us-central1-a

# Open in browser
https://<EXTERNAL_IP>
```

### SSH into Instance
```bash
gcloud compute ssh freescout-prod --zone=us-central1-a
```

### View Logs
```bash
# SSH in, then:
cd /opt/freescout-docker
docker compose logs -f app    # Application logs
docker compose logs -f queue  # Job queue logs
docker compose logs -f db     # Database logs
```

### Stop/Start Services
```bash
cd /opt/freescout-docker
docker compose stop           # Stop all
docker compose start          # Start all
docker compose restart queue  # Restart specific service
```

### Database Backup
```bash
cd /opt/freescout-docker
docker compose exec db mysqldump -u freescout -p freescout > /tmp/backup.sql
```

---

## ⚠️ Troubleshooting

### Cannot Access Application?
1. Check external IP is assigned:
   ```bash
   gcloud compute instances describe freescout-prod --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
   ```

2. Check firewall rule exists:
   ```bash
   gcloud compute firewall-rules list --filter="name:allow-freescout"
   ```

3. Check containers running:
   ```bash
   ssh into instance
   cd /opt/freescout-docker && docker compose ps
   ```

### Database Connect Failed?
```bash
ssh into instance
cd /opt/freescout-docker
docker compose logs db | tail -20
docker compose restart db
```

### Modules Won't Install?
```bash
# Check GitHub token is valid
git ls-remote https://oauth:REPO_TOKEN@github.com/BorealTek/Crm-Module.git

# Token should start with ghp_
# If expired/invalid, regenerate at: https://github.com/settings/tokens
```

See **GCP_CHECKLIST.md** for more troubleshooting.

---

## 💰 Estimated Costs

| Component | Monthly Cost |
|-----------|--------------|
| e2-standard-2 instance | ~$35 |
| 50 GB disk | ~$2-3 |
| Networking | ~$0-2 |
| **Total** | **~$40/month** |

See GCP_DEPLOYMENT.md → "GCP Cost Optimization" for ways to reduce costs.

---

## 🔐 Security Reminders

- [ ] Change all default passwords before deploying
- [ ] Use strong passwords (16+ characters)
- [ ] Restrict `ALLOWED_SOURCE_RANGES` to your IP for testing
- [ ] Upgrade from self-signed certs to production certs (Let's Encrypt or Google Managed)
- [ ] Enable Cloud Armor for DDoS protection (optional, production)
- [ ] Enable Cloud Monitoring & Logging for audit trail

---

## 📞 Need Help?

| Topic | Resource |
|-------|----------|
| **GCP Setup Issues** | https://cloud.google.com/compute/docs |
| **Deployment Errors** | Check logs: `/opt/freescout-docker` |
| **Configuration** | Edit: `deploy.conf` (see GCP_README.md for options) |
| **Module Issues** | See: `Modules/*/README.md` |
| **Quick Reference** | GCP_CHECKLIST.md (pre/post checklists) |
| **Full Guide** | GCP_DEPLOYMENT.md (complete with examples) |

---

## 📋 Next Steps

1. **Customize deploy.conf:**
   ```bash
   nano deployment/deploy.conf.gcp
   ```

2. **Validate configuration:**
   ```bash
   bash deployment/gcp-config-validate.sh
   ```

3. **Deploy:**
   ```bash
   sudo bash deployment/gcp_deploy.sh
   ```

4. **Access at:**
   ```
   https://<GCP_EXTERNAL_IP>
   ```

---

**Questions?** See the comprehensive guides:
- **GCP_DEPLOYMENT.md** — Production setup, upgrades, cost optimization
- **GCP_CHECKLIST.md** — Troubleshooting and maintenance

Good luck! 🚀
