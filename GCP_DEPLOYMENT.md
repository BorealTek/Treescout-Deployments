# FreeScout GCP Deployment Guide

Deploy FreeScout on Google Cloud Platform using Docker Compose with enterprise-grade reliability, monitoring, and networking.

## Quick Start

### 1. Create a GCP Compute Engine Instance

```bash
# Using gcloud CLI
gcloud compute instances create freescout-prod \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --machine-type=e2-standard-2 \
  --zone=us-central1-a \
  --boot-disk-size=50GB \
  --tags=http-server,https-server

# SSH into the instance
gcloud compute ssh freescout-prod --zone=us-central1-a
```

### 2. Clone and Prepare Deployment

```bash
# On the GCP instance
cd /tmp
git clone https://github.com/BorealTek/Treescout-Deployments.git
cd Treescout-Deployments

# Copy GCP configuration template
cp deployment/deploy.conf.gcp deploy.conf

# Edit configuration with your settings
nano deploy.conf
# CRITICAL: Update these:
#   DOMAIN_NAME="your-domain.com"
#   ADMIN_EMAIL="admin@company.com"
#   ADMIN_PASS="strong-password"
#   REPO_TOKEN="your-github-pat-token"
#   DB_ROOT_PASS, DB_PASS (change from defaults!)
```

### 3. Run GCP Deployer

```bash
# The gcp_deploy.sh script will:
# ✔ Auto-detect GCP metadata (project, zone, IP)
# ✔ Create firewall rules
# ✔ Setup Cloud Logging integration (optional)
# ✔ Launch docker_deploy.sh

sudo bash deployment/gcp_deploy.sh
```

### 4. Access Your Instance

```bash
# Get the external IP
EXTERNAL_IP=$(gcloud compute instances describe freescout-prod \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo "Access at: https://$EXTERNAL_IP"
# Warning: Self-signed certificate — accept the warning in your browser
```

---

## Configuration Details

### `deploy.conf.gcp`

Comprehensive GCP-specific settings. Key sections:

#### Network & Access
```bash
DOMAIN_NAME="freescout.yourdomain.com"        # Your actual domain (DNS must be configured)
EXPOSE_PUBLIC_PORTS="true"                    # Expose to internet via firewall rules
ALLOWED_SOURCE_RANGES="0.0.0.0/0"             # Restrict to your IP for testing: "203.0.113.5/32"
GCP_FIREWALL_RULE_NAME="allow-freescout-https"
```

#### Database
```bash
DB_HOST="db"                                  # Use "db" for embedded MariaDB
# Or: Google Cloud SQL private IP for managed DB
DB_USER="freescout"
DB_PASS="secure-password"
DB_NAME="freescout"
```

#### SSL/TLS
```bash
# Option 1: Self-signed (default, for development)
USE_MANAGED_SSL="false"

# Option 2: Google Managed Certificates (production, requires Cloud Load Balancer)
USE_MANAGED_SSL="true"
GCP_SSL_CERTIFICATE_NAME="freescout-ssl-cert"

# Option 3: Let's Encrypt via Certbot
LETSENCRYPT_EMAIL="admin@yourdomain.com"
```

#### Modules
```bash
# Edit MODULES_TO_INSTALL array to include only what you need
# Full list available in deployment/deploy.conf.gcp

# Example: Core MSP deployment (CRM + Billing + Portal)
MODULES_TO_INSTALL=(
    "Crm|https://github.com/BorealTek/Crm-Module.git|REPO_TOKEN|main"
    "PIB|https://github.com/BorealTek/PIB-Module.git|REPO_TOKEN|main"
    "AssetManagement|https://github.com/BorealTek/AssetManagement-Module.git|REPO_TOKEN|main"
    "ClientPortal|https://github.com/BorealTek/ClientPortal-Module.git|REPO_TOKEN|main"
)

# CRITICAL: Set REPO_TOKEN to your GitHub Personal Access Token
export REPO_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxx"
```

#### Monitoring & Logging
```bash
ENABLE_GCP_LOGGING="true"        # Ship Docker logs to Cloud Logging
ENABLE_GCP_MONITORING="true"     # Enable Cloud Monitoring metrics
ENABLE_GCP_BACKUPS="false"       # Backup to Cloud Storage (requires setup)
```

---

## Deployment Script: `gcp_deploy.sh`

Automated setup wrapper that handles GCP-specific configuration before launching Docker deployment.

### What It Does

1. **GCP Environment Detection**
   - Queries GCP metadata service to auto-populate project ID, zone, instance name
   - Detects internal and external IPs
   - Displays metadata for verification

2. **Health Checks**
   - Validates Docker, Docker Compose, Git, curl
   - Checks system RAM (warns if < 4 GB)
   - Verifies gcloud CLI authentication (optional, but helpful)

3. **Firewall Rule Creation**
   - Creates GCP Firewall rule allowing HTTPS/HTTP
   - Applies network tags to the instance
   - Configurable source IP ranges (default: open to internet)

4. **GCP Integration** (optional)
   - Cloud Logging: Ship container logs to Cloud Logging
   - Cloud Monitoring: Enable metrics dashboard
   - Cloud Backups: Automated database backups to Cloud Storage

5. **Launches docker_deploy.sh**
   - Clones the FreeScout repository
   - Downloads and installs modules
   - Generates SSL certificates
   - Starts Docker Compose containers (app, db, redis, queue, cron)

### Usage

```bash
# Basic deployment
sudo bash deployment/gcp_deploy.sh

# The script will:
# 1. Ask you to review the configuration
# 2. Create firewall rules
# 3. Run docker_deploy.sh
```

---

## Network Topology

```
┌─────────────────────────────────────────────────────────────┐
│ Google Cloud Platform                                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  GCP Compute Engine Instance (e2-standard-2)              │
│  ├─ External IP: YOUR_EXTERNAL_IP (via Cloud NAT)         │
│  ├─ Internal IP: 10.128.0.2 (GCP internal network)        │
│  │                                                         │
│  └─ Docker Containers (docker-compose.yml)                │
│     ├─ app: Nginx + PHP (port 8443 HTTPS)                │
│     ├─ db: MariaDB 10.6 (internal only)                  │
│     ├─ redis: Session/cache store                         │
│     ├─ queue: Laravel queue worker                        │
│     ├─ cron: Task scheduler                               │
│     └─ reverb: WebSocket server                           │
│                                                             │
│  GCP Firewall Rules                                        │
│  └─ allow-freescout-https: HTTPS/HTTP from allowed IPs  │
│                                                             │
└─────────────────────────────────────────────────────────────┘

         Users                     GCP Load Balancer
           │                       (Optional, production)
           └─────────────>[HTTPS]◄──────┘
                          ↓
                    Firewall Rule
                          ↓
                    Compute Instance
                          ↓
                   Docker Containers
```

---

## Post-Deployment

### Access the Application

```bash
# Get instance IP
gcloud compute instances describe freescout-prod \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'

# Open in browser
https://YOUR_EXTERNAL_IP

# Use admin credentials from deploy.conf
# Email: (ADMIN_EMAIL)
# Password: (ADMIN_PASS)
```

### Monitor Deployment

```bash
# SSH into the instance
gcloud compute ssh freescout-prod --zone=us-central1-a

# Check container logs
cd /opt/freescout-docker
docker compose logs -f app

# View all containers
docker compose ps

# Check database
docker compose exec db mysql -u freescout -p freescout -e "SELECT VERSION();"
```

### Manage Services

```bash
cd /opt/freescout-docker

# Stop all services
docker compose down

# Start services
docker compose up -d

# View logs (follow mode)
docker compose logs -f

# Restart a specific service
docker compose restart queue
```

### View GCP Logs

```bash
# Cloud Logging (if enabled)
gcloud logging read "resource.type=gce_instance AND resource.labels.instance_id=YOUR_INSTANCE_ID" \
  --limit 50 --format json

# Or use GCP Console
# → Logging → Logs Explorer
# → Filter: resource.type="gce_instance" AND resource.labels.instance_id="YOUR_INSTANCE_ID"

# Cloud Monitoring Dashboard
# → Monitoring → Dashboards → Create dashboard
# → Add widget for CPU, memory, disk usage
```

---

## Production Upgrades

### Use Google Cloud SQL (Managed Database)

```bash
# 1. Create Cloud SQL instance (MariaDB 10.6)
gcloud sql instances create freescout-db \
  --database-version=MARIADB_10_6 \
  --tier=db-f1-micro \
  --region=us-central1 \
  --no-backup

# 2. Create database & user
gcloud sql databases create freescout --instance=freescout-db
gcloud sql users create freescout --instance=freescout-db --password=SECURE_PASSWORD

# 3. Get private IP of Cloud SQL instance
gcloud sql instances describe freescout-db --format='get(ipAddresses[0].ipAddress)'

# 4. Update deploy.conf
DB_HOST="10.x.x.x"  # Private IP from step 3
DB_USER="freescout"
DB_PASS="SECURE_PASSWORD"

# 5. Redeploy
sudo bash deployment/gcp_deploy.sh
```

### Use Google Cloud Load Balancer (SSL/TLS Termination)

```bash
# 1. Create managed SSL certificate
gcloud compute ssl-certificates create freescout-ssl \
  --domains=freescout.yourdomain.com

# 2. Create health check
gcloud compute health-checks create https freescout-health \
  --port=8443 \
  --request-path=/health

# 3. Create backend service
gcloud compute backend-services create freescout-backend \
  --protocol=HTTPS \
  --health-checks=freescout-health \
  --global

# 4. Add instance group to backend
gcloud compute instance-groups managed create freescout-ig \
  --base-instance-name=freescout \
  --template=freescout-instance-template \
  --size=1 \
  --zone=us-central1-a

gcloud compute backend-services add-backend freescout-backend \
  --instance-group=freescout-ig \
  --instance-group-zone=us-central1-a \
  --global

# 5. Create frontend
gcloud compute forwarding-rules create freescout-forwarding \
  --global \
  --target-https-proxy=freescout-proxy \
  --address=freescout-ip \
  --ports=443

# 6. Create URL map
gcloud compute url-maps create freescout-urlmap \
  --default-service=freescout-backend

# 7. Create target HTTPS proxy
gcloud compute target-https-proxies create freescout-proxy \
  --url-map=freescout-urlmap \
  --ssl-certificates=freescout-ssl
```

### Enable GCP Cloud Armor (DDoS Protection)

```bash
# 1. Create Cloud Armor policy
gcloud compute security-policies create freescout-armor \
  --description="DDoS and bot protection"

# 2. Add rules (example: block if request rate > 100/minute)
gcloud compute security-policies rules create 1000 \
  --security-policy=freescout-armor \
  --action=rate-based-ban \
  --rate-limit-options-enforce-on-key=IP \
  --rate-limit-options-ban-duration-sec=600 \
  --rate-limit-options-conform-action=allow \
  --rate-limit-options-exceed-action=deny-429 \
  --rate-limit-options-rate-limit-threshold-count=100 \
  --rate-limit-options-rate-limit-threshold-interval-sec=60

# 3. Attach to load balancer
gcloud compute backend-services update freescout-backend \
  --security-policy=freescout-armor \
  --global
```

---

## Troubleshooting

### Deployment Fails

```bash
# Check logs from gcp_deploy.sh
tail -f /tmp/gcp-deploy-*.log

# Check docker_deploy.sh logs
cd /opt/freescout-docker
docker compose logs app | head -50

# Verify firewall rules
gcloud compute firewall-rules list --filter="name:freescout"
```

### Cannot Access Application

1. **Check instance has external IP:**
   ```bash
   gcloud compute instances describe freescout-prod \
     --zone=us-central1-a \
     --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
   ```

2. **Verify firewall rule:**
   ```bash
   gcloud compute firewall-rules describe allow-freescout-https
   # Should show: Target tags: freescout
   ```

3. **Check instance has the tag:**
   ```bash
   gcloud compute instances describe freescout-prod \
     --zone=us-central1-a \
     --format='get(tags)'
   # Should include: freescout
   ```

### Database Connection Fails

```bash
# Verify MariaDB is running
cd /opt/freescout-docker
docker compose ps db

# Check database logs
docker compose logs db

# Test connection
docker compose exec app mysql -h db -u freescout -pYOUR_PASSWORD -e "SHOW DATABASES;"
```

### Modules Won't Install

```bash
# Check REPO_TOKEN is set and valid
cd /opt/freescout-docker
echo $REPO_TOKEN

# Clone a module manually to verify token works
cd /tmp
git clone https://github.com/BorealTek/Crm-Module.git
# If this fails, token is invalid or expired

# Regenerate token at: https://github.com/settings/tokens
# Required scopes: repo (full control of private repositories)
```

---

## GCP Cost Optimization

| Component | Estimated Monthly Cost |
|-----------|------------------------|
| e2-standard-2 instance (730 hrs) | ~$35 |
| 50 GB persistent disk | ~$2-3 |
| Ingress (typically free) | $0 |
| Cloud SQL micro (if used) | ~$15-20 |
| **Total (basic setup)** | **~$40-55/month** |

### Cost Reduction Tips

- **Use e2-micro** for very light workloads (~$8/month), but not recommended for production
- **Enable VM auto-shutdown** if instance is test-only
- **Use Cloud SQL on-demand** instead of committed instances for variable workloads
- **Enable GCP Committed Use Discounts** for predictable, long-term usage (20-50% savings)

---

## Support & Next Steps

1. **GCP Documentation**
   - Firewall rules: https://cloud.google.com/vpc/docs/firewalls
   - Compute Engine: https://cloud.google.com/compute/docs
   - Cloud SQL: https://cloud.google.com/sql/docs

2. **FreeScout Documentation**
   - API: https://api-docs.freescout.net
   - Module development: See `Modules/*/README.md`

3. **Troubleshooting**
   - Review deployment logs in `/opt/freescout-docker`
   - Check GCP Cloud Logging for system-level issues
   - Consult deployment/README.md for docker_deploy.sh details

---

## File Reference

- **`deployment/gcp_deploy.sh`** — Main GCP deployment script (auto-configures, calls docker_deploy.sh)
- **`deployment/deploy.conf.gcp`** — GCP configuration template (edit before deployment)
- **`deployment/docker_deploy.sh`** — Docker Compose setup (called by gcp_deploy.sh)
- **`deployment/deploy.conf.example`** — Generic deployment template (reference only)
