# GCP Deployment Files — Summary

This directory now contains complete, production-ready GCP deployment automation for FreeScout.

## Files Created

### 1. **gcp_deploy.sh** (Executable Script)
**Purpose**: Automated GCP-specific setup wrapper that prepares the environment and launches Docker deployment.

**What it does:**
- Auto-detects GCP instance metadata (project ID, zone, internal/external IPs)
- Validates GCP environment (Docker, gcloud CLI, system resources)
- Creates GCP Firewall rules to allow HTTPS/HTTP access
- Optionally configures Cloud Logging and Cloud Monitoring integration
- Launches `docker_deploy.sh` for containerized deployment

**Usage:**
```bash
sudo bash deployment/gcp_deploy.sh
```

### 2. **deploy.conf.gcp** (Configuration Template)
**Purpose**: Pre-configured GCP-specific settings template with detailed documentation for every option.

**Key sections:**
- Network settings (domain, firewall rules, allowed IP ranges)
- Database configuration (host, credentials, naming)
- SSL/TLS options (self-signed, Google Managed, Let's Encrypt)
- Module selection (choose from 16+ available modules)
- GCP integrations (Cloud Logging, Cloud Monitoring, backups)
- Advanced settings (Monitoring, logging, database persistence)

**Usage:**
```bash
cp deployment/deploy.conf.gcp deploy.conf
nano deploy.conf  # Edit all values before deployment
```

### 3. **GCP_DEPLOYMENT.md** (Complete Guide)
**Purpose**: Comprehensive deployment guide for GCP with examples, architecture diagrams, and post-deployment procedures.

**Sections:**
- Quick Start (create instance, configure, deploy)
- Configuration Details (all options explained)
- Network Topology (visual diagram of GCP setup)
- Post-Deployment (access, monitoring, management)
- Production Upgrades (Cloud SQL, Load Balancer, Cloud Armor)
- Troubleshooting (common issues and solutions)
- Cost Optimization (GCP pricing tips)

### 4. **GCP_CHECKLIST.md** (Quick Reference)
**Purpose**: Quick checklist and quick-reference for deployment phases and troubleshooting.

**Sections:**
- Pre-Deployment Checklist
- Deployment Steps
- Post-Deployment Verification
- Troubleshooting (common issues with solutions)
- Monitoring & Maintenance
- Emergency Recovery

---

## Quick Start (3 Steps)

### Step 1: Create GCP Compute Instance

```bash
gcloud compute instances create freescout-prod \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --machine-type=e2-standard-2 \
  --zone=us-central1-a \
  --boot-disk-size=50GB
```

### Step 2: Prepare Configuration

```bash
# SSH into instance
gcloud compute ssh freescout-prod --zone=us-central1-a

# Clone deployment repo
git clone https://github.com/BorealTek/Treescout-Deployments.git
cd Treescout-Deployments

# Copy and edit configuration
cp deployment/deploy.conf.gcp deploy.conf
nano deploy.conf

# CRITICAL: Edit these values:
# - DOMAIN_NAME="your-domain.com"
# - ADMIN_EMAIL="admin@company.com"
# - ADMIN_PASS="secure-password"
# - REPO_TOKEN="github-pat-token"
# - Database passwords (DB_ROOT_PASS, DB_PASS)
```

### Step 3: Deploy

```bash
# Run GCP deployment script (handles everything)
sudo bash deployment/gcp_deploy.sh

# Deployment takes 10-20 minutes
# Monitor in separate terminal:
# gcloud compute ssh freescout-prod --zone=us-central1-a
# cd /opt/freescout-docker && docker compose logs -f app
```

---

## Architecture

```
┌─────────────────────────────────┐
│   gcp_deploy.sh (entry point)   │
│                                 │
│ 1. Auto-detect GCP metadata     │
│ 2. Validate environment         │
│ 3. Create firewall rules        │
│ 4. Setup Cloud Logging          │
│ 5. Call docker_deploy.sh        │
└────────────┬────────────────────┘
             ↓
┌─────────────────────────────────┐
│   docker_deploy.sh (core)       │
│                                 │
│ 1. Clone FreeScout repo         │
│ 2. Install modules              │
│ 3. Generate SSL certs           │
│ 4. Start Docker Compose         │
└────────────┬────────────────────┘
             ↓
┌─────────────────────────────────┐
│  Docker Compose Services        │
│                                 │
│ - app (Nginx + PHP 8.2)         │
│ - db (MariaDB 10.6)             │
│ - redis (Session cache)         │
│ - queue (Job worker)            │
│ - cron (Scheduler)              │
│ - reverb (WebSocket server)     │
└─────────────────────────────────┘
```

---

## Configuration Priority

### Required Before Deploy
1. **DOMAIN_NAME** — Domain or GCP external IP
2. **ADMIN_EMAIL** → Admin login email
3. **ADMIN_PASS** → Admin password (strong!)
4. **DB_ROOT_PASS** → Database root password (strong!)
5. **DB_PASS** → Database user password (strong!)
6. **REPO_TOKEN** → GitHub PAT for module repos

### Recommended Before Deploy
7. **MODULES_TO_INSTALL** — Select which modules to install
8. **ALLOWED_SOURCE_RANGES** — IP ranges allowed to access app
9. **AGENT_EMAIL**, **FINANCE_EMAIL**, **REPORTER_EMAIL** — Default test users

### Optional (Can Configure Later)
- Google OAuth integration
- Action1 RMM API keys
- Cloud Logging / Monitoring
- Let's Encrypt certificate
- Cloud SQL database

---

## Key Differences: OrbStack vs GCP Deploy

| Feature | OrbStack | GCP Deploy |
|---------|----------|-----------|
| **Target** | macOS Local | GCP Compute Engine |
| **Tunnel** | Cloudflare Tunnel | GCP Firewall Rules |
| **Entry Script** | orbstack_deploy.sh | gcp_deploy.sh |
| **Config Template** | deploy.conf.example | deploy.conf.gcp |
| **User Context** | Local user | www-data (33:33) |
| **Install Path** | ~/borealtek-ticketing | /opt/freescout-docker |
| **Database Reuse** | REUSE_DB=false | REUSE_DB=true |
| **SSL Certs** | Self-signed | Self-signed / Managed / Let's Encrypt |
| **Access** | Via Cloudflare | Via GCP Load Balancer or public IP |

---

## File Structure

```
deployment/
├── README.md                       # Original deployment docs
├── docker_deploy.sh                # Docker Compose setup (called by gcp_deploy.sh)
├── orbstack_deploy.sh              # OrbStack/macOS deployer (reference)
├── deploy.conf.example             # Generic template
├── deploy.conf.gcp                 # ← GCP-specific template (NEW)
├── gcp_deploy.sh                   # ← GCP entry script (NEW)
├── GCP_DEPLOYMENT.md               # ← Complete GCP guide (NEW)
├── GCP_CHECKLIST.md                # ← Quick reference (NEW)
└── cloudflared/                    # Cloudflare tunnel config (OrbStack only)
```

---

## Security Checklist

- [ ] All default passwords changed in deploy.conf
- [ ] GitHub PAT token uses minimal scope ("repo" only)
- [ ] Database credentials are strong (16+ chars, mixed)
- [ ] Admin password is strong and unique
- [ ] Firewall rule restricts IPs if testing (not `0.0.0.0/0`)
- [ ] SSL certificates upgraded to production certs post-deploy
- [ ] GCP service account used for Cloud Logging has minimal permissions
- [ ] Database backups enabled if configured
- [ ] Regular security updates applied to instance OS

---

## Post-Deployment Tasks

### Immediate (Day 1)
1. [ ] Access app at HTTPS and verify no errors
2. [ ] Login with admin credentials
3. [ ] Install additional modules via Admin UI (if any)
4. [ ] Configure mailbox(es) for email
5. [ ] Test email sending/receiving

### Short-term (Week 1)
6. [ ] Upgrade SSL certificate from self-signed
7. [ ] Configure Google OAuth (if needed)
8. [ ] Setup backup schedule
9. [ ] Configure GCP monitoring alerts
10. [ ] Load test the deployment

### Long-term (Ongoing)
11. [ ] Monitor costs in GCP Console
12. [ ] Review logs weekly
13. [ ] Apply OS and container updates
14. [ ] Plan capacity upgrades if needed

---

## Getting Help

### Documentation
- **GCP_DEPLOYMENT.md** — Complete guide with all options
- **GCP_CHECKLIST.md** — Quick troubleshooting reference
- **deployment/README.md** — Generic Docker deployment docs
- **Modules/*/README.md** — Module-specific documentation

### GCP Resources
- Compute Engine: https://cloud.google.com/compute/docs
- Firewall Rules: https://cloud.google.com/vpc/docs/firewalls
- Cloud SQL: https://cloud.google.com/sql/docs
- Cloud Logging: https://cloud.google.com/logging/docs

### FreeScout Resources
- Official API: https://api-docs.freescout.net
- GitHub: https://github.com/freescout-help-desk/freescout
- Module Development: See `Modules/*/README.md`

---

## Maintenance Commands

```bash
cd /opt/freescout-docker

# View container status
docker compose ps

# View logs (all services)
docker compose logs -f

# View specific service logs
docker compose logs -f app
docker compose logs -f queue
docker compose logs -f db

# Restart a service
docker compose restart queue

# Shell into a container
docker compose exec app bash
docker compose exec db mysql -u freescout -p

# Database backup
docker compose exec db mysqldump -u freescout -p freescout > /tmp/backup.sql

# Clean up unused Docker resources
docker system prune -f
```

---

## Next Steps

1. **Start Deployment:**
   ```bash
   sudo bash deployment/gcp_deploy.sh
   ```

2. **Read Full Guide:**
   - GCP_DEPLOYMENT.md for comprehensive setup & production tips
   - GCP_CHECKLIST.md for quick reference & troubleshooting

3. **Test Post-Deploy:**
   - Navigate to application URL
   - Verify all containers running
   - Test admin login
   - Create test conversation

---

**Version**: 1.0
**Last Updated**: March 2026
**Status**: Production-Ready ✅
