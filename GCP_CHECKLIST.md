# GCP FreeScout Deployment Checklist

Quick reference for deploying and troubleshooting FreeScout on Google Cloud Platform.

## Pre-Deployment Checklist

### GCP Account & Project Setup
- [ ] GCP project created (https://console.cloud.google.com)
- [ ] Billing enabled for the project
- [ ] `gcloud` CLI installed locally (`gcloud auth login`)
- [ ] Quota check: Compute Engine instances (default: 24 vCPU quota)

### Compute Engine Instance
- [ ] Instance created: `gcloud compute instances create`
- [ ] Machine type: `e2-standard-2` or larger (minimum 2 vCPU, 8 GB RAM)
- [ ] OS image: Debian 12 or Ubuntu 20.04+ (tested)
- [ ] Boot disk: 50 GB (auto-expand enabled)
- [ ] SSH key configured (or OS Login enabled)
- [ ] Can SSH into instance: `gcloud compute ssh INSTANCE_NAME`

### Local Preparation
- [ ] FreeScout repo cloned locally (or deployment repo)
- [ ] `deploy.conf.gcp` copied to `deploy.conf`
- [ ] All passwords changed from template defaults
- [ ] GitHub PAT token created and set in REPO_TOKEN
- [ ] Module selection finalized (for BorealTek internal use the default full MODULES_TO_INSTALL; for clients trim as needed)

### Configuration Review (`deploy.conf`)
- [ ] `DOMAIN_NAME` set to actual domain or GCP IP
- [ ] `ADMIN_EMAIL`, `ADMIN_PASS` set securely
- [ ] `DB_ROOT_PASS`, `DB_PASS` changed from defaults
- [ ] `REPO_TOKEN` is valid (test: `git clone https://oauth:REPO_TOKEN@github.com/BorealTek/Crm-Module.git`)
- [ ] `ALLOWED_SOURCE_RANGES` configured (use specific IPs for testing, `0.0.0.0/0` for public)
- [ ] Modules list includes only required modules (save resources)

---

## Deployment

### Step 1: Copy Files to GCP Instance

```bash
# From local machine (or deploy locally on instance)
gcloud compute scp deployment/deploy.conf.gcp INSTANCE_NAME:~/deploy.conf --zone=ZONE
gcloud compute scp deployment/gcp_deploy.sh INSTANCE_NAME:~/gcp_deploy.sh --zone=ZONE
gcloud compute scp deployment/ INSTANCE_NAME:~/deployment-scripts/ --zone=ZONE --recurse
```

Or clone directly on the instance:

```bash
gcloud compute ssh INSTANCE_NAME --zone=ZONE
cd ~/
git clone https://github.com/BorealTek/Treescout-Deployments.git
cd Treescout-Deployments
cp deployment/deploy.conf.gcp deploy.conf
nano deploy.conf  # Edit all CRITICAL values
```

### Step 2: Run Deployment

```bash
# SSH into the instance if not already connected
gcloud compute ssh freescout-prod --zone=us-central1-a

# Navigate to deployment directory
cd ~/Treescout-Deployments

# Run GCP deployer (handles firewall, then calls docker_deploy.sh)
sudo bash deployment/gcp_deploy.sh
```

### Step 3: Monitor Deployment

```bash
# In a separate terminal, watch logs
gcloud compute ssh freescout-prod --zone=us-central1-a
cd /opt/freescout-docker
docker compose logs -f app
```

Deployment typically takes 10-20 minutes depending on module count and network speed.

---

## Post-Deployment Checklist

### Verify Deployment
- [ ] All Docker containers running: `docker compose ps` (status: Up)
  - [ ] `app` (Nginx + PHP)
  - [ ] `db` (MariaDB)
  - [ ] `redis` (Cache)
  - [ ] `queue` (Job worker)
  - [ ] `cron` (Scheduler)
  - [ ] `reverb` (WebSocket)

### Access Application
- [ ] Get external IP: `gcloud compute instances describe INSTANCE_NAME --format='get(networkInterfaces[0].accessConfigs[0].natIP)'`
- [ ] Open browser: `https://EXTERNAL_IP` (accept self-signed cert warning)
- [ ] Login with admin credentials (ADMIN_EMAIL from deploy.conf)
- [ ] Verify homepage loads without errors

### GCP Network & Security
- [ ] Firewall rule exists: `gcloud compute firewall-rules list --filter="name:allow-freescout"`
- [ ] Instance has network tag: `gcloud compute instances describe INSTANCE_NAME --format='get(tags)'` (should include `freescout`)
- [ ] Firewall rule points to correct ports (443, 80)

### Database Health
```bash
cd /opt/freescout-docker
docker compose exec db mysql -u freescout -p -e "SHOW DATABASES; SHOW TABLES IN freescout LIMIT 5;"
```
- [ ] Database `freescout` exists
- [ ] Tables exist (conversations, mailboxes, users, etc.)

### Module Installation
- [ ] Navigate to Admin → Modules
- [ ] Verify installed modules match deploy.conf
- [ ] All modules show "Active" status
- [ ] No failed module loads

---

## Troubleshooting

### Issue: Cannot Access Application (Connection Timeout)

**Cause 1: External IP not assigned**
```bash
gcloud compute instances describe INSTANCE_NAME --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
# If empty or NOT_FOUND:
gcloud compute instances add-access-config INSTANCE_NAME --zone=ZONE
```

**Cause 2: Firewall rule missing or misconfigured**
```bash
# Check rule exists and is correct
gcloud compute firewall-rules describe allow-freescout-https

# Check instance has the tag
gcloud compute instances describe INSTANCE_NAME --format='get(tags)'

# If tag missing, add it:
gcloud compute instances add-tags INSTANCE_NAME --tags=freescout --zone=ZONE
```

**Cause 3: Docker container not running**
```bash
cd /opt/freescout-docker
docker compose logs app | tail -50
docker compose logs db | tail -50

# If error, rebuild:
docker compose down
docker compose up -d
docker compose logs -f app  # Watch for startup errors
```

---

### Issue: Database Connection Failed

```bash
# Test connection from app container
cd /opt/freescout-docker
docker compose exec app mysql -h db -u freescout -p -e "SHOW DATABASES;"

# If error, check MariaDB logs
docker compose logs db

# Restart database
docker compose restart db
docker compose logs db  # Wait for "ready for connections"

# Check credentials in .env file
grep DB_ /opt/freescout-docker/src/.env
```

**Common causes:**
- Password mismatch: check `/opt/freescout-docker/docker-compose.yml` env vars vs `.env`
- MariaDB not initialized: restart with `docker compose down && docker compose up -d`
- Disk full: check `docker system df`

---

### Issue: Modules Won't Install

```bash
# Check REPO_TOKEN is valid
cd /opt/freescout-docker
cat docker-compose.yml | grep REPO_TOKEN

# Test token manually
git ls-remote https://oauth:REPO_TOKEN@github.com/BorealTek/Crm-Module.git

# If fails:
# 1. Verify token at: https://github.com/settings/tokens
# 2. Check token has "repo" scope
# 3. Token not expired (view date created)
# 4. If expired, regenerate and update deploy.conf
```

---

### Issue: High CPU/Memory Usage

```bash
# Check Docker resource usage
docker stats

# Check individual container consumption
docker stats --no-stream

# Identify process consuming resources
docker compose exec app top
docker compose exec db top

# Common causes:
# - Queue backed up: docker compose logs queue
# - Database slow queries: check database logs
# - PHP memory limit too low: increase PHP_MEMORY_LIMIT in docker-compose.yml
```

**Quick fix:**
```bash
cd /opt/freescout-docker

# Increase PHP memory limit
sed -i 's/PHP_MEMORY_LIMIT=512M/PHP_MEMORY_LIMIT=1024M/' docker-compose.yml

# Restart containers
docker compose down
docker compose up -d
```

---

### Issue: Self-Signed SSL Certificate Warning

**Expected behavior** for initial deployment. To upgrade to trusted certificate:

#### Option A: Let's Encrypt (Requires Public Domain)
```bash
cd /opt/freescout-docker

# Install certbot in app container
docker compose exec app apt-get update && apt-get install -y certbot python3-certbot-nginx

# Request certificate
docker compose exec app certbot certonly \
  --standalone \
  -d your-domain.com \
  -m admin@domain.com \
  --agree-tos \
  --non-interactive

# Update nginx config to use certificate
# Edit nginx/default.conf: change ssl_certificate paths

# Restart
docker compose restart app
```

#### Option B: GCP Managed Certificate (Production, Requires Cloud Load Balancer)
See: GCP_DEPLOYMENT.md → "Production Upgrades" → "Use Google Cloud Load Balancer"

---

### Issue: Deployment Script Hangs

```bash
# Check if waiting for input
ps aux | grep gcp_deploy

# Check if Docker build stuck
docker ps  # Should show freescout-app building

# If stuck > 10 minutes:
# Ctrl+C to cancel, then check logs
docker compose logs -f app

# Common causes:
# - Network timeout downloading base images
# - Disk full (check: df -h)
# - module git clone hanging (network issue)
```

**Recovery:**
```bash
cd /opt/freescout-docker

# Clean up and retry
docker compose down
docker system prune -f
docker compose up -d --build  # Force rebuild
```

---

## Monitoring & Maintenance

### Daily Checks

```bash
# Check container status
cd /opt/freescout-docker
docker compose ps

# Check for errors in logs (last 100 lines)
docker compose logs --tail=100 | grep -i "error\|warning\|exception"

# Monitor disk space (should be > 10% free)
df -h /
```

### Weekly Checks

```bash
# Database backup (if backup enabled)
ls -lh /opt/freescout-docker/backups/

# Check for updates
cd /opt/freescout-docker && git fetch  # Check if updates available

# Verify queue is processing (should be close to 0)
docker compose logs queue | tail -20
```

### GCP Cost Check

```bash
# View spent this month
gcloud billing accounts list --format="table(displayName, masterBillingAccount)"
gcloud billing accounts describe YOUR_ACCOUNT_ID --format="table(displayName, spendLastMonth)"

# Set budget alert
gcloud billing budgets create \
  --billing-account=YOUR_ACCOUNT \
  --display-name="FreeScout Budget" \
  --budget-amount=100 \
  --threshold-rule=percent=100 \
  --threshold-rule=percent=90
```

---

## Redeploy / Update

```bash
cd /opt/freescout-docker

# Backup database before update
docker compose exec db mysqldump -u freescout -p freescout > /tmp/freescout-backup-$(date +%s).sql

# Pull latest code
git pull origin laravel-11-foundation

# Rebuild and restart (preserves DB due to REUSE_DB=true)
docker compose down
docker compose up -d --build

# Run migrations (if needed)
docker compose exec app php artisan migrate
```

---

## GCP Console Quick Links

- **Compute Instances**: https://console.cloud.google.com/compute/instances
- **Firewall Rules**: https://console.cloud.google.com/vpc/firewalls
- **Cloud Logging**: https://console.cloud.google.com/logs
- **Cloud Monitoring**: https://console.cloud.google.com/monitoring
- **Billing**: https://console.cloud.google.com/billing

---

## Recovery / Cleanup

### Reset to Fresh Deploy

```bash
cd /opt/freescout-docker

# Stop & remove all containers
docker compose down -v  # -v removes volumes (DELETES DATABASE!)

# Confirm backup exists before running above!
# Restore backup: docker compose exec db mysql < /tmp/freescout-backup-*.sql

# Redeploy
sudo bash ../deployment/gcp_deploy.sh
```

### Remove Entire Deployment

```bash
# BackupDatabase first!
cd /opt/freescout-docker
docker compose exec db mysqldump -u freescout -p freescout > /tmp/final-backup.sql

# Stop services
docker compose down -v

# Remove directory
sudo rm -rf /opt/freescout-docker

# Delete GCP Firewall rule
gcloud compute firewall-rules delete allow-freescout-https

# Delete instance
gcloud compute instances delete freescout-prod --zone=us-central1-a
```

---

## Emergency Contacts & Escalation

1. **Deployment Issues**: Review logs in `/opt/freescout-docker` and GCP Cloud Logging
2. **Module Issues**: Check module README in `Modules/*/README.md`
3. **Database Issues**: Consult MariaDB docs or GCP Cloud SQL documentation
4. **GCP Issues**: File ticket with GCP support (https://console.cloud.google.com/support)

---

## See Also

- **GCP_DEPLOYMENT.md** — Full deployment guide with production upgrades
- **deployment/README.md** — Generic deployment documentation
- **docker_deploy.sh** — Docker Compose setup script (called by gcp_deploy.sh)
- **deploy.conf.gcp** — GCP configuration template with all options documented
