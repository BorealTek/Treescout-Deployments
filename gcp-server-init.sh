#!/usr/bin/env bash
# ==============================================================================
# TreeScout GCP Server Bootstrap — gcp-server-init.sh
#
# Deploys TreeScout from a pre-built GHCR image. No git clone, no docker build,
# no gcloud CLI required on the server.
#
# What this script does:
#   1. Verifies running on GCP (metadata service check)
#   2. Fetches a service-account OAuth token (for Secret Manager REST API)
#   3. Installs Docker CE + jq (idempotent — skips if already present)
#   4. Reads non-secret config from instance custom metadata (ts-* keys)
#   5. Pulls secrets from GCP Secret Manager via REST API (no gcloud needed)
#   6. Logs Docker into GHCR using REPO_TOKEN from Secret Manager
#   7. Writes /opt/treescout/docker-compose.prod.yml and .env
#   8. docker compose pull && up -d
#   9. Runs database migrations
#
# HOW TO RUN:
#
#   Option A — via gcp-workstation-setup.sh (streams this script over SSH)
#
#   Option B — pipe over SSH:
#     gcloud compute ssh treescout-prod --zone=us-central1-a \
#       --project=YOUR_PROJECT -- 'sudo bash -s' < deployment/gcp-server-init.sh
#
#   Option C — stream directly from GitHub:
#     gcloud compute ssh treescout-prod --zone=us-central1-a -- \
#       "curl -fsSL 'https://raw.githubusercontent.com/Scotchmcdonald/freescout/laravel-11-foundation/deployment/gcp-server-init.sh' | sudo bash"
#
# REQUIREMENTS:
#   - GCP Compute Engine VM, Debian 12+
#   - VM has 'cloud-platform' OAuth scope
#   - VM service account has secretmanager.secretAccessor IAM role
#   - gcp-workstation-setup.sh run first (pushes secrets + metadata)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# COLORS & LOGGING
# ==============================================================================

readonly RED='\033[38;5;196m'
readonly GREEN='\033[38;5;46m'
readonly YELLOW='\033[38;5;226m'
readonly CYAN='\033[38;5;51m'
readonly BLUE='\033[38;5;27m'
readonly MAGENTA='\033[38;5;201m'
readonly GREY='\033[38;5;240m'
readonly NC='\033[0m'

log_info()    { echo -e "${CYAN}ℹ ${NC} $*"; }
log_success() { echo -e "${GREEN}✔${NC} $*"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $*"; }
log_error()   { echo -e "${RED}✖${NC} $*" >&2; }
log_step()    { echo ""; echo -e "${MAGENTA}━━━ ${BLUE}$*${NC}"; }
log_code()    { echo -e "${GREY}  ↳ $*${NC}"; }

# ==============================================================================
# RUNTIME STATE
# ==============================================================================

GCP_PROJECT_ID=""
GCP_INSTANCE_NAME=""
GCP_ZONE=""
GCE_TOKEN=""

DEPLOY_DIR="/opt/treescout"
TREESCOUT_PROFILE="full"

# Config from instance metadata
DOMAIN_NAME=""
ADMIN_EMAIL=""
ADMIN_FIRST_NAME="System"
ADMIN_LAST_NAME="Administrator"
DB_USER="treescout"
DB_NAME="treescout"
DB_HOST="db"
DOCKER_SUBNET="172.20.0.0/16"
EXPOSE_PUBLIC_PORTS="true"
ENABLE_KROKI="false"
ENABLE_GCP_LOGGING="false"
GIT_REPO_URL="https://github.com/Scotchmcdonald/freescout.git"
GIT_BRANCH="laravel-11-foundation"

# Optional seeded users
AGENT_EMAIL="" AGENT_FIRST_NAME="Support" AGENT_LAST_NAME="Agent"
FINANCE_EMAIL="" FINANCE_FIRST_NAME="Finance" FINANCE_LAST_NAME="Manager"
REPORTER_EMAIL="" REPORTER_FIRST_NAME="Report" REPORTER_LAST_NAME="Viewer"

# Secrets from Secret Manager
APP_KEY="" REPO_TOKEN="" DB_ROOT_PASS="" DB_PASS="" ADMIN_PASS=""
AGENT_PASS="" FINANCE_PASS="" REPORTER_PASS=""
GOOGLE_CLIENT_ID="" GOOGLE_CLIENT_SECRET="" GOOGLE_ADMIN_EMAILS="" GOOGLE_ALLOWED_DOMAINS=""
ACTION1_REGION="us"
ACTION1_SYNC_CLIENT_ID="" ACTION1_SYNC_CLIENT_SECRET=""
ACTION1_AUTOMATION_RUNNER_CLIENT_ID="" ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET=""
ACTION1_SCRIPT_MANAGER_CLIENT_ID="" ACTION1_SCRIPT_MANAGER_CLIENT_SECRET=""

# ==============================================================================
# GCP METADATA HELPERS
# ==============================================================================

readonly METADATA_BASE="http://metadata.google.internal/computeMetadata/v1"

_meta() { curl -sf -H "Metadata-Flavor: Google" "${METADATA_BASE}/$1" 2>/dev/null || echo ""; }
_attr() { _meta "instance/attributes/$1"; }

# ==============================================================================
# STEP 1 — Verify running on GCP
# ==============================================================================

verify_on_gcp() {
    log_step "Verifying GCP environment"

    if ! curl -sf -H "Metadata-Flavor: Google" \
        "${METADATA_BASE}/project/project-id" >/dev/null 2>&1; then
        log_error "GCP metadata service not reachable."
        log_error "This script must be run on a GCP Compute Engine VM."
        exit 1
    fi

    GCP_PROJECT_ID=$(_meta "project/project-id")
    GCP_INSTANCE_NAME=$(_meta "instance/name")
    GCP_ZONE=$(_meta "instance/zone" | awk -F'/' '{print $NF}')

    log_success "Running on GCP"
    log_code "Project:  $GCP_PROJECT_ID"
    log_code "Instance: $GCP_INSTANCE_NAME  ($GCP_ZONE)"
}

# ==============================================================================
# STEP 2 — Obtain service-account OAuth token (for Secret Manager REST API)
# ==============================================================================

fetch_gce_token() {
    log_step "Obtaining service-account OAuth token"

    local response
    response=$(_meta "instance/service-accounts/default/token")

    if [ -z "$response" ]; then
        log_error "Could not fetch OAuth token from metadata service."
        log_error "Ensure the VM has 'cloud-platform' access scope."
        exit 1
    fi

    # jq not available yet — use python3 (pre-installed on Debian 12)
    GCE_TOKEN=$(echo "$response" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")

    if [ -z "$GCE_TOKEN" ]; then
        log_error "Could not parse access_token from metadata response."
        exit 1
    fi

    log_success "OAuth token obtained (valid ~3600s)"
}

# ==============================================================================
# STEP 3 — Install Docker CE + jq  (idempotent)
# ==============================================================================

install_deps() {
    log_step "Installing dependencies"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # Base packages — jq needed for Secret Manager API response parsing
    apt-get install -y -q ca-certificates curl gnupg lsb-release jq

    log_success "Base packages ready"

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_success "Docker already installed: $(docker --version)"
        return
    fi

    log_info "Installing Docker CE..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -q \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker

    log_success "Docker installed: $(docker --version)"
}

# ==============================================================================
# STEP 4 — Read non-secret config from instance custom metadata
# ==============================================================================

read_metadata() {
    log_step "Reading configuration from instance metadata"

    local val
    val=$(_attr "ts-domain");          if [ -n "$val" ]; then DOMAIN_NAME="$val"; fi
    val=$(_attr "ts-admin-email");     if [ -n "$val" ]; then ADMIN_EMAIL="$val"; fi
    val=$(_attr "ts-admin-first");     if [ -n "$val" ]; then ADMIN_FIRST_NAME="$val"; fi
    val=$(_attr "ts-admin-last");      if [ -n "$val" ]; then ADMIN_LAST_NAME="$val"; fi
    val=$(_attr "ts-db-user");         if [ -n "$val" ]; then DB_USER="$val"; fi
    val=$(_attr "ts-db-name");         if [ -n "$val" ]; then DB_NAME="$val"; fi
    val=$(_attr "ts-db-host");         if [ -n "$val" ]; then DB_HOST="$val"; fi
    val=$(_attr "ts-docker-subnet");   if [ -n "$val" ]; then DOCKER_SUBNET="$val"; fi
    val=$(_attr "ts-expose-public");   if [ -n "$val" ]; then EXPOSE_PUBLIC_PORTS="$val"; fi
    val=$(_attr "ts-enable-kroki");    if [ -n "$val" ]; then ENABLE_KROKI="$val"; fi
    val=$(_attr "ts-enable-logging");  if [ -n "$val" ]; then ENABLE_GCP_LOGGING="$val"; fi
    val=$(_attr "ts-git-repo");        if [ -n "$val" ]; then GIT_REPO_URL="$val"; fi
    val=$(_attr "ts-git-branch");      if [ -n "$val" ]; then GIT_BRANCH="$val"; fi
    val=$(_attr "ts-deploy-profile");  if [ -n "$val" ]; then TREESCOUT_PROFILE="$val"; fi

    # Optional seeded users
    val=$(_attr "ts-agent-email");     if [ -n "$val" ]; then AGENT_EMAIL="$val"; fi
    val=$(_attr "ts-agent-first");     if [ -n "$val" ]; then AGENT_FIRST_NAME="$val"; fi
    val=$(_attr "ts-agent-last");      if [ -n "$val" ]; then AGENT_LAST_NAME="$val"; fi
    val=$(_attr "ts-finance-email");   if [ -n "$val" ]; then FINANCE_EMAIL="$val"; fi
    val=$(_attr "ts-finance-first");   if [ -n "$val" ]; then FINANCE_FIRST_NAME="$val"; fi
    val=$(_attr "ts-finance-last");    if [ -n "$val" ]; then FINANCE_LAST_NAME="$val"; fi
    val=$(_attr "ts-reporter-email");  if [ -n "$val" ]; then REPORTER_EMAIL="$val"; fi
    val=$(_attr "ts-reporter-first");  if [ -n "$val" ]; then REPORTER_FIRST_NAME="$val"; fi
    val=$(_attr "ts-reporter-last");   if [ -n "$val" ]; then REPORTER_LAST_NAME="$val"; fi

    # Fail fast on required values
    local missing=false
    if [ -z "$DOMAIN_NAME" ]; then
        log_error "ts-domain not set — run gcp-workstation-setup.sh first"
        missing=true
    fi
    if [ -z "$ADMIN_EMAIL" ]; then
        log_error "ts-admin-email not set — run gcp-workstation-setup.sh first"
        missing=true
    fi
    if [ "$missing" = true ]; then exit 1; fi

    log_success "Metadata loaded"
    log_code "Profile:  $TREESCOUT_PROFILE"
    log_code "Domain:   $DOMAIN_NAME"
    log_code "Admin:    $ADMIN_EMAIL"
    log_code "Install:  $DEPLOY_DIR"
}

# ==============================================================================
# STEP 5 — Pull secrets from GCP Secret Manager (REST API — no gcloud needed)
# ==============================================================================

_pull_secret() {
    local var_name="$1" secret_name="$2" required="${3:-optional}"

    local response
    response=$(curl -sf \
        -H "Authorization: Bearer $GCE_TOKEN" \
        "https://secretmanager.googleapis.com/v1/projects/${GCP_PROJECT_ID}/secrets/${secret_name}/versions/latest:access" \
        2>/dev/null || echo "")

    if [ -z "$response" ]; then
        if [ "$required" = "required" ]; then
            log_error "Required secret not found: $secret_name"
            log_info  "Run gcp-workstation-setup.sh to push secrets first."
            exit 1
        fi
        log_info "Optional secret not set (skipping): $secret_name"
        return
    fi

    local value
    value=$(echo "$response" | jq -r '.payload.data' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    if [ -z "$value" ]; then
        if [ "$required" = "required" ]; then
            log_error "Required secret is empty: $secret_name"
            exit 1
        fi
        return
    fi

    export "${var_name}=${value}"
    log_success "Pulled: $secret_name"
}

pull_secrets() {
    log_step "Pulling secrets from GCP Secret Manager"

    _pull_secret "APP_KEY"      "treescout-app-key"      "required"
    _pull_secret "REPO_TOKEN"   "treescout-repo-token"   "required"
    _pull_secret "DB_ROOT_PASS" "treescout-db-root-pass" "required"
    _pull_secret "DB_PASS"      "treescout-db-pass"      "required"
    _pull_secret "ADMIN_PASS"   "treescout-admin-pass"   "required"

    _pull_secret "AGENT_PASS"    "treescout-agent-pass"
    _pull_secret "FINANCE_PASS"  "treescout-finance-pass"
    _pull_secret "REPORTER_PASS" "treescout-reporter-pass"

    _pull_secret "GOOGLE_CLIENT_ID"       "treescout-google-client-id"
    _pull_secret "GOOGLE_CLIENT_SECRET"   "treescout-google-client-secret"
    _pull_secret "GOOGLE_ADMIN_EMAILS"    "treescout-google-admin-emails"
    _pull_secret "GOOGLE_ALLOWED_DOMAINS" "treescout-google-allowed-domains"

    _pull_secret "ACTION1_SYNC_CLIENT_ID"                    "treescout-action1-sync-client-id"
    _pull_secret "ACTION1_SYNC_CLIENT_SECRET"                "treescout-action1-sync-client-secret"
    _pull_secret "ACTION1_AUTOMATION_RUNNER_CLIENT_ID"       "treescout-action1-automation-runner-client-id"
    _pull_secret "ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET"   "treescout-action1-automation-runner-client-secret"
    _pull_secret "ACTION1_SCRIPT_MANAGER_CLIENT_ID"          "treescout-action1-script-manager-client-id"
    _pull_secret "ACTION1_SCRIPT_MANAGER_CLIENT_SECRET"      "treescout-action1-script-manager-client-secret"

    local action1_region
    action1_region=$(curl -sf \
        -H "Authorization: Bearer $GCE_TOKEN" \
        "https://secretmanager.googleapis.com/v1/projects/${GCP_PROJECT_ID}/secrets/treescout-action1-region/versions/latest:access" \
        2>/dev/null | jq -r '.payload.data' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$action1_region" ]; then ACTION1_REGION="$action1_region"; fi

    log_success "All required secrets pulled"
}

# ==============================================================================
# STEP 6 — Log Docker into GHCR
# ==============================================================================

docker_login_ghcr() {
    log_step "Authenticating Docker with GitHub Container Registry"

    echo "$REPO_TOKEN" | docker login ghcr.io -u "$(echo "$REPO_TOKEN" | cut -c1-4)..." --password-stdin 2>/dev/null \
        || echo "$REPO_TOKEN" | docker login ghcr.io --username=borealtek --password-stdin

    log_success "Docker authenticated with ghcr.io"
}

# ==============================================================================
# STEP 7 — Write docker-compose.prod.yml and .env
# ==============================================================================

write_app_files() {
    log_step "Writing app files to $DEPLOY_DIR"

    mkdir -p "$DEPLOY_DIR"

    # ── docker-compose.prod.yml ────────────────────────────────────────────────
    cat > "${DEPLOY_DIR}/docker-compose.prod.yml" <<'COMPOSE_EOF'
# Generated by gcp-server-init.sh — do not edit by hand, re-run the script.
services:
  app:
    image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE:-full}-latest
    container_name: treescout-app
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    env_file: .env
    volumes:
      - storage_data:/var/www/html/storage
      - bootstrap_cache:/var/www/html/bootstrap/cache
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - treescout-net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  queue:
    image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE:-full}-latest
    container_name: treescout-queue
    restart: always
    command: php artisan queue:work --queue=emails,default,long-running --sleep=3 --tries=3 --max-time=3600
    env_file: .env
    volumes:
      - storage_data:/var/www/html/storage
      - bootstrap_cache:/var/www/html/bootstrap/cache
    depends_on: [app, db, redis]
    networks:
      - treescout-net

  cron:
    image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE:-full}-latest
    container_name: treescout-cron
    restart: unless-stopped
    command: >
      /bin/sh -c 'while true; do
        php artisan schedule:run >> /var/www/html/storage/logs/cron.log 2>&1;
        sleep 60;
      done'
    env_file: .env
    volumes:
      - storage_data:/var/www/html/storage
      - bootstrap_cache:/var/www/html/bootstrap/cache
    depends_on: [app, db, redis]
    networks:
      - treescout-net

  reverb:
    image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE:-full}-latest
    container_name: treescout-reverb
    restart: unless-stopped
    command: php artisan reverb:start --host=0.0.0.0 --port=8081
    env_file: .env
    ports:
      - "127.0.0.1:8081:8081"
    volumes:
      - storage_data:/var/www/html/storage
      - bootstrap_cache:/var/www/html/bootstrap/cache
    depends_on: [app, db, redis]
    networks:
      - treescout-net

  db:
    image: mariadb:10.6
    container_name: treescout-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW --innodb-file-per-table=1 --skip-innodb-read-only-compressed
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MARIADB_DATABASE: ${DB_NAME}
      MARIADB_USER: ${DB_USER}
      MARIADB_PASSWORD: ${DB_PASS}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - treescout-net
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: treescout-redis
    restart: unless-stopped
    networks:
      - treescout-net

networks:
  treescout-net:
    driver: bridge

volumes:
  db_data:
  storage_data:
  bootstrap_cache:
COMPOSE_EOF

    # ── .env ──────────────────────────────────────────────────────────────────
    # Written with restricted permissions — secrets are in this file.
    # docker compose auto-loads .env for both ${VAR} substitution in the YAML
    # AND passes all vars to services using env_file: .env.
    cat > "${DEPLOY_DIR}/.env" <<ENV_EOF
# Generated by gcp-server-init.sh  $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# chmod 600 — do not share or commit this file.

TREESCOUT_PROFILE=${TREESCOUT_PROFILE}

# ── Application ──────────────────────────────────────────────────────────────
APP_NAME=TreeScout
APP_ENV=production
APP_DEBUG=false
APP_KEY=${APP_KEY}
APP_URL=https://${DOMAIN_NAME}

LOG_CHANNEL=stack
LOG_LEVEL=warning

# ── Database ─────────────────────────────────────────────────────────────────
DB_CONNECTION=mysql
DB_HOST=${DB_HOST}
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}
DB_ROOT_PASS=${DB_ROOT_PASS}

# ── Cache / Session / Queue ───────────────────────────────────────────────────
REDIS_HOST=redis
REDIS_PORT=6379
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=database

# ── Broadcasting (Reverb) ────────────────────────────────────────────────────
BROADCAST_DRIVER=reverb
REVERB_HOST=reverb
REVERB_PORT=8081
REVERB_APP_ID=treescout-001
REVERB_APP_KEY=treescout-reverb-key
REVERB_APP_SECRET=${DB_ROOT_PASS}

# ── Mail ─────────────────────────────────────────────────────────────────────
MAIL_MAILER=log

# ── Admin seeding ────────────────────────────────────────────────────────────
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_FIRST_NAME=${ADMIN_FIRST_NAME}
ADMIN_LAST_NAME=${ADMIN_LAST_NAME}
ADMIN_PASS=${ADMIN_PASS}
ENV_EOF

    # Append optional seeded users if set
    if [ -n "$AGENT_EMAIL" ]; then
        cat >> "${DEPLOY_DIR}/.env" <<ENV_EOF
AGENT_EMAIL=${AGENT_EMAIL}
AGENT_FIRST_NAME=${AGENT_FIRST_NAME}
AGENT_LAST_NAME=${AGENT_LAST_NAME}
AGENT_PASS=${AGENT_PASS:-}
ENV_EOF
    fi

    if [ -n "$FINANCE_EMAIL" ]; then
        cat >> "${DEPLOY_DIR}/.env" <<ENV_EOF
FINANCE_EMAIL=${FINANCE_EMAIL}
FINANCE_FIRST_NAME=${FINANCE_FIRST_NAME}
FINANCE_LAST_NAME=${FINANCE_LAST_NAME}
FINANCE_PASS=${FINANCE_PASS:-}
ENV_EOF
    fi

    if [ -n "$REPORTER_EMAIL" ]; then
        cat >> "${DEPLOY_DIR}/.env" <<ENV_EOF
REPORTER_EMAIL=${REPORTER_EMAIL}
REPORTER_FIRST_NAME=${REPORTER_FIRST_NAME}
REPORTER_LAST_NAME=${REPORTER_LAST_NAME}
REPORTER_PASS=${REPORTER_PASS:-}
ENV_EOF
    fi

    # Append optional integrations
    if [ -n "$GOOGLE_CLIENT_ID" ]; then
        cat >> "${DEPLOY_DIR}/.env" <<ENV_EOF

# ── Google OAuth ─────────────────────────────────────────────────────────────
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
GOOGLE_ADMIN_EMAILS=${GOOGLE_ADMIN_EMAILS:-}
GOOGLE_ALLOWED_DOMAINS=${GOOGLE_ALLOWED_DOMAINS:-}
ENV_EOF
    fi

    if [ -n "$ACTION1_SYNC_CLIENT_ID" ]; then
        cat >> "${DEPLOY_DIR}/.env" <<ENV_EOF

# ── Action1 RMM ───────────────────────────────────────────────────────────────
ACTION1_REGION=${ACTION1_REGION}
ACTION1_SYNC_CLIENT_ID=${ACTION1_SYNC_CLIENT_ID}
ACTION1_SYNC_CLIENT_SECRET=${ACTION1_SYNC_CLIENT_SECRET}
ACTION1_AUTOMATION_RUNNER_CLIENT_ID=${ACTION1_AUTOMATION_RUNNER_CLIENT_ID:-}
ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET=${ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET:-}
ACTION1_SCRIPT_MANAGER_CLIENT_ID=${ACTION1_SCRIPT_MANAGER_CLIENT_ID:-}
ACTION1_SCRIPT_MANAGER_CLIENT_SECRET=${ACTION1_SCRIPT_MANAGER_CLIENT_SECRET:-}
ENV_EOF
    fi

    chmod 600 "${DEPLOY_DIR}/.env"
    chown root:root "${DEPLOY_DIR}/.env"

    log_success "docker-compose.prod.yml written"
    log_success ".env written (chmod 600, root-only)"
}

# ==============================================================================
# STEP 8 — Pull image and start services
# ==============================================================================

deploy() {
    log_step "Pulling image and starting services"

    cd "$DEPLOY_DIR"

    log_info "Pulling image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE}-latest"
    docker compose -f docker-compose.prod.yml pull

    log_info "Starting containers..."
    docker compose -f docker-compose.prod.yml up -d

    log_success "Containers started"
    log_code "$(docker compose -f docker-compose.prod.yml ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || true)"
}

# ==============================================================================
# STEP 9 — Post-deploy: migrations + summary
# ==============================================================================

post_deploy() {
    log_step "Running database migrations"

    cd "$DEPLOY_DIR"

    # Wait for app to become healthy (up to 90s)
    local attempts=0
    until docker compose -f docker-compose.prod.yml exec -T app \
            php artisan --version >/dev/null 2>&1; do
        attempts=$(( attempts + 1 ))
        if [ "$attempts" -ge 18 ]; then
            log_error "App container did not become ready in time"
            docker compose -f docker-compose.prod.yml logs app | tail -30
            exit 1
        fi
        log_info "Waiting for app container... (${attempts}/18)"
        sleep 5
    done

    docker compose -f docker-compose.prod.yml exec -T app \
        php artisan migrate --force --no-interaction
    log_success "Migrations complete"

    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✔  TreeScout deployed successfully!${NC}"
    echo ""
    echo -e "  Profile:  ${GREY}${TREESCOUT_PROFILE}${NC}"
    echo -e "  Domain:   ${GREY}${DOMAIN_NAME}${NC}"
    echo -e "  App dir:  ${GREY}${DEPLOY_DIR}${NC}"
    echo ""
    echo -e "  Useful commands:"
    echo -e "  ${GREY}docker compose -f ${DEPLOY_DIR}/docker-compose.prod.yml logs -f app${NC}"
    echo -e "  ${GREY}docker compose -f ${DEPLOY_DIR}/docker-compose.prod.yml exec app php artisan tinker${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         TreeScout  —  GCP Server Bootstrap                  ║${NC}"
    echo -e "${CYAN}║   Image pull + compose up  (no git, no build, no gcloud)    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    verify_on_gcp
    fetch_gce_token
    install_deps
    read_metadata
    pull_secrets
    docker_login_ghcr
    write_app_files
    deploy
    post_deploy
}

main "$@"


# Config values (read from instance metadata)
DOMAIN_NAME=""
ADMIN_EMAIL=""
ADMIN_FIRST_NAME="System"
ADMIN_LAST_NAME="Administrator"
GIT_REPO_URL="https://github.com/Scotchmcdonald/freescout.git"
GIT_BRANCH="laravel-11-foundation"
DEFAULT_INSTALL_DIR="/opt/treescout-docker"
DOCKER_SUBNET="172.20.0.0/16"
DB_USER="treescout"
DB_NAME="treescout"
DB_HOST="db"
EXPOSE_PUBLIC_PORTS="true"
GCP_FIREWALL_RULE_NAME="allow-treescout-https"
ALLOWED_SOURCE_RANGES="0.0.0.0/0"
GCP_NETWORK_TAG="treescout"
ENABLE_KROKI="false"
ENABLE_GCP_LOGGING="false"

# Deploy dest for deployment scripts (defaults to same repo as app)
DEPLOY_DIR="/opt/treescout-deploy"

# ==============================================================================
# GCP METADATA SERVICE HELPERS
# ==============================================================================

readonly METADATA_BASE="http://metadata.google.internal/computeMetadata/v1"

# Fetch any metadata endpoint
_meta() {
    curl -s -f -H "Metadata-Flavor: Google" "${METADATA_BASE}/$1" 2>/dev/null || echo ""
}

# Read a custom instance attribute (ts-* keys set by gcp-workstation-setup.sh)
_attr() {
    _meta "instance/attributes/$1"
}

# ==============================================================================
# STEP 1 — Verify running on GCP
# ==============================================================================

verify_on_gcp() {
    log_step "Verifying GCP environment"

    if ! curl -s -f -H "Metadata-Flavor: Google" \
        "${METADATA_BASE}/project/project-id" >/dev/null 2>&1; then
        log_error "GCP metadata service not reachable."
        log_error "This script must be run on a GCP Compute Engine instance."
        exit 1
    fi

    GCP_PROJECT_ID=$(_meta "project/project-id")
    GCP_INSTANCE_NAME=$(_meta "instance/name")
    GCP_ZONE=$(_meta "instance/zone" | awk -F'/' '{print $NF}')

    log_success "Running on GCP"
    log_code "Project:  $GCP_PROJECT_ID"
    log_code "Instance: $GCP_INSTANCE_NAME"
    log_code "Zone:     $GCP_ZONE"
}

# ==============================================================================
# STEP 2 — Obtain service account OAuth token
# ==============================================================================

fetch_gce_token() {
    log_step "Obtaining service account OAuth token"

    GCE_TOKEN=$(_meta "instance/service-accounts/default/token" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")

    if [ -z "$GCE_TOKEN" ]; then
        log_error "Could not obtain OAuth token from metadata service."
        log_error "Ensure the VM has the 'cloud-platform' access scope."
        log_info "Fix from your workstation:"
        log_code "gcloud compute instances stop $GCP_INSTANCE_NAME --zone=$GCP_ZONE"
        log_code "gcloud compute instances set-service-account $GCP_INSTANCE_NAME --zone=$GCP_ZONE --scopes=cloud-platform"
        log_code "gcloud compute instances start $GCP_INSTANCE_NAME --zone=$GCP_ZONE"
        exit 1
    fi

    log_success "OAuth token obtained (expires in ~3600s)"
}

# ==============================================================================
# STEP 3 — Install system dependencies
# ==============================================================================

install_system_deps() {
    log_step "Installing system dependencies"

    export DEBIAN_FRONTEND=noninteractive

    log_info "Updating apt package lists..."
    apt-get update -qq

    log_info "Installing base packages..."
    apt-get install -y -q \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        git \
        openssl \
        python3 \
        jq \
        apt-transport-https \
        software-properties-common

    log_success "Base packages installed"
}

# ==============================================================================
# STEP 4 — Install Docker CE + Compose plugin
# ==============================================================================

install_docker() {
    log_step "Installing Docker"

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_success "Docker + Compose already installed: $(docker --version)"
        return
    fi

    log_info "Adding Docker's official GPG key and repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq

    log_info "Installing docker-ce, docker-compose-plugin..."
    apt-get install -y -q \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    log_success "Docker installed: $(docker --version)"
    log_success "Compose installed: $(docker compose version)"
}

# ==============================================================================
# STEP 5 — Install gcloud CLI (required by gcp_deploy.sh)
# ==============================================================================

install_gcloud() {
    log_step "Installing gcloud CLI"

    if command -v gcloud >/dev/null 2>&1; then
        log_success "gcloud already installed: $(gcloud version --format='value(Google Cloud SDK)' 2>/dev/null || echo 'version unknown')"
        return
    fi

    log_info "Adding Google Cloud SDK apt repository..."
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null

    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
        | tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null

    apt-get update -qq
    apt-get install -y -q google-cloud-cli

    log_success "gcloud installed: $(gcloud version --format='value(Google Cloud SDK)' 2>/dev/null)"
}

# ==============================================================================
# STEP 6 — Configure gcloud to use the VM's service account token
# ==============================================================================

configure_gcloud_auth() {
    log_step "Configuring gcloud authentication"

    # Use the token obtained from the metadata service.
    # This ensures the VM's OAuth scopes are honoured, regardless of any
    # gcloud user account or Application Default Credentials that may exist.
    export CLOUDSDK_AUTH_ACCESS_TOKEN="$GCE_TOKEN"
    export CLOUDSDK_CORE_PROJECT="$GCP_PROJECT_ID"
    unset GOOGLE_APPLICATION_CREDENTIALS   # prevent key-file override

    # Clear any locally configured user account that would override the token
    gcloud config unset core/account 2>/dev/null || true

    log_success "gcloud will use VM service account token"
}

# ==============================================================================
# STEP 7 — Read non-secret config from instance custom metadata (ts-* keys)
# ==============================================================================

read_metadata() {
    log_step "Reading configuration from instance metadata"

    DOMAIN_NAME=$(_attr "ts-domain")
    ADMIN_EMAIL=$(_attr "ts-admin-email")
    ADMIN_FIRST_NAME=$(_attr "ts-admin-first")
    ADMIN_LAST_NAME=$(_attr "ts-admin-last")
    GIT_REPO_URL=$(_attr "ts-git-repo")
    GIT_BRANCH=$(_attr "ts-git-branch")
    DEFAULT_INSTALL_DIR=$(_attr "ts-install-dir")
    DOCKER_SUBNET=$(_attr "ts-docker-subnet")
    DB_USER=$(_attr "ts-db-user")
    DB_NAME=$(_attr "ts-db-name")
    DB_HOST=$(_attr "ts-db-host")
    EXPOSE_PUBLIC_PORTS=$(_attr "ts-expose-public")
    GCP_FIREWALL_RULE_NAME=$(_attr "ts-firewall-rule")
    ALLOWED_SOURCE_RANGES=$(_attr "ts-allowed-ranges")
    GCP_NETWORK_TAG=$(_attr "ts-network-tag")
    ENABLE_KROKI=$(_attr "ts-enable-kroki")
    ENABLE_GCP_LOGGING=$(_attr "ts-enable-logging")

    # Optional user emails
    local attr_agent_email attr_finance_email attr_reporter_email
    attr_agent_email=$(_attr "ts-agent-email")
    attr_finance_email=$(_attr "ts-finance-email")
    attr_reporter_email=$(_attr "ts-reporter-email")

    # Apply defaults for values that weren't set in metadata
    if [ -z "$GIT_REPO_URL" ];           then GIT_REPO_URL="https://github.com/Scotchmcdonald/freescout.git"; fi
    if [ -z "$GIT_BRANCH" ];             then GIT_BRANCH="laravel-11-foundation"; fi
    if [ -z "$DEFAULT_INSTALL_DIR" ];    then DEFAULT_INSTALL_DIR="/opt/treescout-docker"; fi
    if [ -z "$DOCKER_SUBNET" ];          then DOCKER_SUBNET="172.20.0.0/16"; fi
    if [ -z "$DB_USER" ];                then DB_USER="treescout"; fi
    if [ -z "$DB_NAME" ];                then DB_NAME="treescout"; fi
    if [ -z "$DB_HOST" ];                then DB_HOST="db"; fi
    if [ -z "$EXPOSE_PUBLIC_PORTS" ];    then EXPOSE_PUBLIC_PORTS="true"; fi
    if [ -z "$GCP_FIREWALL_RULE_NAME" ]; then GCP_FIREWALL_RULE_NAME="allow-treescout-https"; fi
    if [ -z "$ALLOWED_SOURCE_RANGES" ];  then ALLOWED_SOURCE_RANGES="0.0.0.0/0"; fi
    if [ -z "$GCP_NETWORK_TAG" ];        then GCP_NETWORK_TAG="treescout"; fi
    if [ -z "$ENABLE_KROKI" ];           then ENABLE_KROKI="false"; fi
    if [ -z "$ENABLE_GCP_LOGGING" ];     then ENABLE_GCP_LOGGING="false"; fi

    # Validate required values that must have been set by workstation script
    local missing=false
    if [ -z "$DOMAIN_NAME" ]; then
        log_error "ts-domain metadata key not set — run gcp-workstation-setup.sh first"
        missing=true
    fi
    if [ -z "$ADMIN_EMAIL" ]; then
        log_error "ts-admin-email metadata key not set — run gcp-workstation-setup.sh first"
        missing=true
    fi
    if [ "$missing" = true ]; then exit 1; fi

    log_success "Metadata read:"
    log_code "Domain:      $DOMAIN_NAME"
    log_code "Admin:       $ADMIN_EMAIL"
    log_code "Git repo:    $GIT_REPO_URL ($GIT_BRANCH)"
    log_code "Install dir: $DEFAULT_INSTALL_DIR"
    log_code "DB:          $DB_NAME (user: $DB_USER)"
    [ -n "$attr_agent_email" ]    && log_code "Agent:       $attr_agent_email" || true
    [ -n "$attr_finance_email" ]  && log_code "Finance:     $attr_finance_email" || true
    [ -n "$attr_reporter_email" ] && log_code "Reporter:    $attr_reporter_email" || true

    # Export optional user info for deploy.conf generation
    AGENT_EMAIL="$attr_agent_email"
    AGENT_FIRST_NAME=$(_attr "ts-agent-first")
    AGENT_LAST_NAME=$(_attr "ts-agent-last")
    FINANCE_EMAIL="$attr_finance_email"
    FINANCE_FIRST_NAME=$(_attr "ts-finance-first")
    FINANCE_LAST_NAME=$(_attr "ts-finance-last")
    REPORTER_EMAIL="$attr_reporter_email"
    REPORTER_FIRST_NAME=$(_attr "ts-reporter-first")
    REPORTER_LAST_NAME=$(_attr "ts-reporter-last")
}

# ==============================================================================
# STEP 8 — Pull secrets from GCP Secret Manager
# ==============================================================================

_pull_secret() {
    local var_name="$1"
    local secret_name="$2"
    local required="${3:-optional}"

    local value
    value=$(gcloud secrets versions access latest \
        --secret="$secret_name" \
        --project="$GCP_PROJECT_ID" 2>/dev/null || echo "")

    if [ -z "$value" ]; then
        if [ "$required" = "required" ]; then
            log_error "Required secret not found or empty: $secret_name"
            log_info "Ensure gcp-workstation-setup.sh has been run to push secrets."
            exit 1
        fi
        log_info "Secret not set (skipping): $secret_name"
        return
    fi

    # Export the value into the named variable
    export "${var_name}=${value}"
    log_success "Pulled: $secret_name → \$$var_name"
}

pull_secrets() {
    log_step "Pulling secrets from GCP Secret Manager"

    _pull_secret "REPO_TOKEN"    "treescout-repo-token"    "required"
    _pull_secret "DB_ROOT_PASS"  "treescout-db-root-pass"  "required"
    _pull_secret "DB_PASS"       "treescout-db-pass"       "required"
    _pull_secret "ADMIN_PASS"    "treescout-admin-pass"    "required"

    _pull_secret "AGENT_PASS"    "treescout-agent-pass"
    _pull_secret "FINANCE_PASS"  "treescout-finance-pass"
    _pull_secret "REPORTER_PASS" "treescout-reporter-pass"

    _pull_secret "GOOGLE_CLIENT_ID"       "treescout-google-client-id"
    _pull_secret "GOOGLE_CLIENT_SECRET"   "treescout-google-client-secret"
    _pull_secret "GOOGLE_ADMIN_EMAILS"    "treescout-google-admin-emails"
    _pull_secret "GOOGLE_ALLOWED_DOMAINS" "treescout-google-allowed-domains"

    _pull_secret "ACTION1_SYNC_CLIENT_ID"                "treescout-action1-sync-client-id"
    _pull_secret "ACTION1_SYNC_CLIENT_SECRET"            "treescout-action1-sync-client-secret"
    _pull_secret "ACTION1_AUTOMATION_RUNNER_CLIENT_ID"   "treescout-action1-automation-runner-client-id"
    _pull_secret "ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET" "treescout-action1-automation-runner-client-secret"
    _pull_secret "ACTION1_SCRIPT_MANAGER_CLIENT_ID"      "treescout-action1-script-manager-client-id"
    _pull_secret "ACTION1_SCRIPT_MANAGER_CLIENT_SECRET"  "treescout-action1-script-manager-client-secret"

    local action1_region
    action1_region=$(gcloud secrets versions access latest \
        --secret="treescout-action1-region" \
        --project="$GCP_PROJECT_ID" 2>/dev/null || echo "us")
    ACTION1_REGION="${action1_region:-us}"

    log_success "All required secrets pulled"
}

# ==============================================================================
# STEP 9 — Clone the deployment / app repository
# ==============================================================================

clone_repo() {
    log_step "Cloning deployment repository"

    mkdir -p "$DEPLOY_DIR"

    local clone_url
    # Use REPO_TOKEN to authenticate the private-module-capable clone
    clone_url="https://${REPO_TOKEN}@${GIT_REPO_URL#https://}"

    if [ -d "$DEPLOY_DIR/.git" ]; then
        log_info "Repository already cloned at $DEPLOY_DIR — pulling latest..."
        git -C "$DEPLOY_DIR" remote set-url origin "$clone_url" 2>/dev/null || true
        git -C "$DEPLOY_DIR" fetch --quiet origin
        git -C "$DEPLOY_DIR" checkout "$GIT_BRANCH" --quiet 2>/dev/null || true
        git -C "$DEPLOY_DIR" reset --hard "origin/$GIT_BRANCH" --quiet
        log_success "Repository updated: $GIT_BRANCH"
    else
        log_info "Cloning $GIT_REPO_URL (branch: $GIT_BRANCH)..."
        git clone --branch "$GIT_BRANCH" --depth=1 "$clone_url" "$DEPLOY_DIR" --quiet
        log_success "Cloned to $DEPLOY_DIR"
    fi

    # Remove the token from remote URL immediately after clone (security hygiene)
    git -C "$DEPLOY_DIR" remote set-url origin "$GIT_REPO_URL" 2>/dev/null || true
}

# ==============================================================================
# STEP 10 — Generate deploy.conf from secrets + metadata (ephemeral, chmod 600)
# ==============================================================================

generate_deploy_conf() {
    log_step "Generating deploy.conf from secrets and instance metadata"

    local conf_path="${DEPLOY_DIR}/deployment/deploy.conf"

    # Write the generated config (never committed — ephemeral to this deploy run)
    cat > "$conf_path" <<EOF
#================================================================================
# deploy.conf — GENERATED BY gcp-server-init.sh  $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Do NOT edit by hand. Re-run gcp-server-init.sh to regenerate from source.
#================================================================================

USE_GCP_SECRET_MANAGER="false"    # Values already pulled and injected below

#--- Installation ---------------------------------------------------------------
GIT_REPO_URL="${GIT_REPO_URL}"
GIT_BRANCH="${GIT_BRANCH}"
DEFAULT_INSTALL_DIR="${DEFAULT_INSTALL_DIR}"

#--- GCP -----------------------------------------------------------------------
GCP_PROJECT_ID="${GCP_PROJECT_ID}"
GCP_ZONE="${GCP_ZONE}"

#--- Network -------------------------------------------------------------------
DOMAIN_NAME="${DOMAIN_NAME}"
EXPOSE_PUBLIC_PORTS="${EXPOSE_PUBLIC_PORTS}"
GCP_FIREWALL_RULE_NAME="${GCP_FIREWALL_RULE_NAME}"
ALLOWED_SOURCE_RANGES="${ALLOWED_SOURCE_RANGES}"
DOCKER_SUBNET="${DOCKER_SUBNET}"

#--- Database ------------------------------------------------------------------
DB_HOST="${DB_HOST}"
DB_USER="${DB_USER}"
DB_NAME="${DB_NAME}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"
DB_PASS="${DB_PASS:-}"

#--- Admin user ----------------------------------------------------------------
ADMIN_EMAIL="${ADMIN_EMAIL}"
ADMIN_FIRST_NAME="${ADMIN_FIRST_NAME}"
ADMIN_LAST_NAME="${ADMIN_LAST_NAME}"
ADMIN_PASS="${ADMIN_PASS:-}"

EOF

    # Append optional seeded user accounts if their emails are set
    if [ -n "${AGENT_EMAIL:-}" ]; then
        cat >> "$conf_path" <<EOF
#--- Agent user ----------------------------------------------------------------
AGENT_EMAIL="${AGENT_EMAIL}"
AGENT_FIRST_NAME="${AGENT_FIRST_NAME:-Support}"
AGENT_LAST_NAME="${AGENT_LAST_NAME:-Agent}"
AGENT_PASS="${AGENT_PASS:-}"

EOF
    fi

    if [ -n "${FINANCE_EMAIL:-}" ]; then
        cat >> "$conf_path" <<EOF
#--- Finance user --------------------------------------------------------------
FINANCE_EMAIL="${FINANCE_EMAIL}"
FINANCE_FIRST_NAME="${FINANCE_FIRST_NAME:-Finance}"
FINANCE_LAST_NAME="${FINANCE_LAST_NAME:-Manager}"
FINANCE_PASS="${FINANCE_PASS:-}"

EOF
    fi

    if [ -n "${REPORTER_EMAIL:-}" ]; then
        cat >> "$conf_path" <<EOF
#--- Reporter user -------------------------------------------------------------
REPORTER_EMAIL="${REPORTER_EMAIL}"
REPORTER_FIRST_NAME="${REPORTER_FIRST_NAME:-Report}"
REPORTER_LAST_NAME="${REPORTER_LAST_NAME:-Viewer}"
REPORTER_PASS="${REPORTER_PASS:-}"

EOF
    fi

    # Append Google OAuth if configured
    if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
        cat >> "$conf_path" <<EOF
#--- Google OAuth --------------------------------------------------------------
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
GOOGLE_ADMIN_EMAILS="${GOOGLE_ADMIN_EMAILS:-}"
GOOGLE_ALLOWED_DOMAINS="${GOOGLE_ALLOWED_DOMAINS:-}"

EOF
    fi

    # Append Action1 if configured
    if [ -n "${ACTION1_SYNC_CLIENT_ID:-}" ]; then
        cat >> "$conf_path" <<EOF
#--- Action1 RMM ---------------------------------------------------------------
ACTION1_REGION="${ACTION1_REGION:-us}"
ACTION1_SYNC_CLIENT_ID="${ACTION1_SYNC_CLIENT_ID:-}"
ACTION1_SYNC_CLIENT_SECRET="${ACTION1_SYNC_CLIENT_SECRET:-}"
ACTION1_RUN_CLIENT_ID="${ACTION1_AUTOMATION_RUNNER_CLIENT_ID:-}"
ACTION1_RUN_CLIENT_SECRET="${ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET:-}"
ACTION1_MANAGE_CLIENT_ID="${ACTION1_SCRIPT_MANAGER_CLIENT_ID:-}"
ACTION1_MANAGE_CLIENT_SECRET="${ACTION1_SCRIPT_MANAGER_CLIENT_SECRET:-}"

EOF
    fi

    # Append REPO_TOKEN so docker_deploy.sh can clone private module repos
    cat >> "$conf_path" <<EOF
#--- Private repo access -------------------------------------------------------
REPO_TOKEN="${REPO_TOKEN:-}"

#--- Optional services ---------------------------------------------------------
ENABLE_KROKI="${ENABLE_KROKI}"
ENABLE_GCP_LOGGING="${ENABLE_GCP_LOGGING}"
EOF

    # Restrict permissions — readable only by root (owner), not world
    chmod 600 "$conf_path"
    chown root:root "$conf_path"

    log_success "deploy.conf written: $conf_path  (chmod 600)"
    log_info "Contains NO credentials visible to non-root — ephemeral to this run"
}

# ==============================================================================
# STEP 11 — Run gcp_deploy.sh —yes
# ==============================================================================

run_deployment() {
    log_step "Launching GCP deployment"

    local deploy_script="${DEPLOY_DIR}/deployment/gcp_deploy.sh"

    if [ ! -f "$deploy_script" ]; then
        log_error "gcp_deploy.sh not found at $deploy_script"
        log_error "Ensure the repository was cloned successfully."
        exit 1
    fi

    chmod +x "$deploy_script"
    chmod +x "${DEPLOY_DIR}/deployment/docker_deploy.sh" 2>/dev/null || true

    # Pass the metadata token to gcp_deploy.sh so it can call Secret Manager
    # if it needs to re-pull anything (e.g. for log/monitoring features)
    export CLOUDSDK_AUTH_ACCESS_TOKEN="$GCE_TOKEN"
    export CLOUDSDK_CORE_PROJECT="$GCP_PROJECT_ID"

    log_info "Running: sudo -E bash $deploy_script --yes"
    echo ""

    cd "${DEPLOY_DIR}/deployment"
    exec sudo -E bash "$deploy_script" --yes
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         TreeScout  —  GCP Server Bootstrap                  ║${NC}"
    echo -e "${CYAN}║   All config loaded from metadata + Secret Manager           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    verify_on_gcp
    fetch_gce_token
    install_system_deps
    install_docker
    install_gcloud
    configure_gcloud_auth
    read_metadata
    pull_secrets
    clone_repo
    generate_deploy_conf
    run_deployment
}

main "$@"
