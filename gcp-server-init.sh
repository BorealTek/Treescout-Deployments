#!/usr/bin/env bash
# ==============================================================================
# TreeScout GCP Server Bootstrap — gcp-server-init.sh
#
# Deploys TreeScout primarily from GHCR, with an automatic local-build fallback
# when registry auth/image pull fails.
#
# What this script does:
#   1. Verifies running on GCP (metadata service check)
#   2. Fetches a service-account OAuth token (for Secret Manager REST API)
#   3. Installs Docker CE + jq (idempotent — skips if already present)
#   4. Reads non-secret config from instance custom metadata (ts-* keys)
#   5. Pulls secrets from GCP Secret Manager via REST API (no gcloud needed)
#   6. Tries Docker login to GHCR using REPO_TOKEN from Secret Manager
#   7. Writes /opt/treescout/docker-compose.prod.yml and .env
#   8. Tries docker compose pull; if it fails, builds image locally from source
#   9. docker compose up -d
#  10. Runs database migrations
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
APP_IMAGE="ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE}-latest"
BUILD_DIR="/opt/treescout-build"

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

# GoDaddy DNS
GODADDY_API_KEY=""
GODADDY_API_SECRET=""

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
    apt-get install -y -q ca-certificates curl gnupg lsb-release jq git

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

    _pull_secret "GODADDY_API_KEY"    "treescout-godaddy-api-key"
    _pull_secret "GODADDY_API_SECRET" "treescout-godaddy-api-secret"

    log_success "All required secrets pulled"
}

# ==============================================================================
# STEP 5b — Register / update GoDaddy DNS A record
# ==============================================================================

# Extracts the apex registered domain from a FQDN.
# Correctly handles ccTLDs (.co.uk) by querying the GoDaddy API to verify ownership.
_apex_domain() {
    local fqdn="$1"
    local auth="$2"
    local candidate="$fqdn"

    while echo "$candidate" | grep -q '\.'; do
        local status
        status=$(curl -sf -o /dev/null -w "%{http_code}" \
            -H "Authorization: $auth" \
            "https://api.godaddy.com/v1/domains/${candidate}" 2>/dev/null || echo "000")
        if [ "$status" = "200" ]; then
            echo "$candidate"
            return 0
        fi
        candidate="${candidate#*.}"
    done

    # Fallback to naive parsing if the API fails entirely
    echo "$fqdn" | awk -F. '{if (NF>=2) {print $(NF-1)"."$NF} else {print $0}}'
}

# Extracts the subdomain / record name for GoDaddy (@ if root).
# e.g. treescout.example.com -> treescout
#      example.com            -> @
_record_name() {
    local fqdn="$1" apex="$2"
    local sub="${fqdn%.$apex}"

    if [ "$sub" = "$fqdn" ] || [ -z "$sub" ]; then
        echo "@"
    else
        echo "${sub%.}"
    fi
}

register_godaddy_dns() {
    if [ -z "$GODADDY_API_KEY" ] || [ -z "$GODADDY_API_SECRET" ]; then
        log_info "GoDaddy credentials not set — skipping automatic DNS registration."
        return
    fi

    log_step "Registering DNS with GoDaddy"

    # Resolve the VM's external IP from the metadata service
    local public_ip
    public_ip=$(_meta "instance/network-interfaces/0/access-configs/0/external-ip" || true)

    if [ -z "$public_ip" ]; then
        log_warning "Could not determine public IP from metadata — skipping DNS registration."
        return
    fi
    log_info "Public IP: $public_ip"

    local auth_header="sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}"
    local apex record_name
    apex=$(_apex_domain "$DOMAIN_NAME" "$auth_header")
    record_name=$(_record_name "$DOMAIN_NAME" "$apex")

    log_info "Domain:      $DOMAIN_NAME"
    log_info "Apex:        $apex"
    log_info "Record name: ${record_name} (A → $public_ip)"

    local api_url="https://api.godaddy.com/v1/domains/${apex}/records/A/${record_name}"
    local payload="[{\"data\":\"${public_ip}\",\"ttl\":600}]"

    local http_status
    http_status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X PUT "$api_url" \
        -H "Authorization: $auth_header" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || echo "000")

    if [ "$http_status" = "200" ]; then
        log_success "GoDaddy A record updated: ${record_name}.${apex} → $public_ip (TTL 600)"
    else
        log_warning "GoDaddy API returned HTTP $http_status — DNS not updated automatically."
        log_info "Set the record manually in the GoDaddy console:"
        log_code "Type: A  |  Name: ${record_name}  |  Value: $public_ip  |  TTL: 600 s"
    fi
}

# ==============================================================================
# STEP 5c — Install systemd DNS updater (runs on every VM boot)
#
# GCP ephemeral IPs change each time the instance starts.  This installs a
# oneshot systemd service that fetches fresh GoDaddy credentials from Secret
# Manager and re-registers the A record automatically on every boot.
# No credentials are written to disk — everything is fetched at runtime.
# ==============================================================================

install_dns_updater() {
    if [ -z "$GODADDY_API_KEY" ] || [ -z "$GODADDY_API_SECRET" ]; then
        log_info "GoDaddy credentials not set — skipping DNS updater installation."
        return
    fi

    log_step "Installing boot-time DNS updater (treescout-dns-update)"

    # ── /usr/local/bin/treescout-dns-update ───────────────────────────────────
    # Written with single-quoted heredoc so variables are NOT expanded here;
    # the script reads everything from metadata / Secret Manager at boot time.
    cat > /usr/local/bin/treescout-dns-update <<'UPDATER_EOF'
#!/usr/bin/env bash
# treescout-dns-update — refreshes the GoDaddy A record on every VM boot.
# Credentials are pulled live from GCP Secret Manager; nothing is stored on disk.
set -euo pipefail

readonly METADATA="http://metadata.google.internal/computeMetadata/v1"
_meta() { curl -sf -H "Metadata-Flavor: Google" "${METADATA}/$1" 2>/dev/null || echo ""; }
_attr() { _meta "instance/attributes/$1"; }

# Obtain a fresh service-account OAuth token
TOKEN=$(python3 -c \
    "import sys,json; print(json.load(sys.stdin)['access_token'])" \
    <<< "$(_meta instance/service-accounts/default/token)" 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
    echo "ERROR: could not obtain OAuth token from metadata service" >&2
    exit 1
fi

PROJECT=$(_meta project/project-id)
if [ -z "$PROJECT" ]; then
    echo "ERROR: could not determine GCP project from metadata" >&2
    exit 1
fi

# Pull a single secret from Secret Manager
_secret() {
    curl -sf \
        -H "Authorization: Bearer ${TOKEN}" \
        "https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${1}/versions/latest:access" \
        2>/dev/null \
    | python3 -c \
        "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['payload']['data']).decode())" \
    2>/dev/null || echo ""
}

GODADDY_API_KEY=$(_secret treescout-godaddy-api-key)
GODADDY_API_SECRET=$(_secret treescout-godaddy-api-secret)
DOMAIN_NAME=$(_attr ts-domain)

if [ -z "$GODADDY_API_KEY" ] || [ -z "$GODADDY_API_SECRET" ]; then
    echo "GoDaddy credentials not in Secret Manager — skipping DNS update."
    exit 0
fi
if [ -z "$DOMAIN_NAME" ]; then
    echo "ERROR: ts-domain instance attribute not set" >&2
    exit 1
fi

# Wait up to 60 s for the external IP to be assigned after boot
PUBLIC_IP=""
for i in $(seq 1 12); do
    PUBLIC_IP=$(_meta instance/network-interfaces/0/access-configs/0/external-ip)
    [ -n "$PUBLIC_IP" ] && break
    echo "Waiting for external IP... attempt ${i}/12"
    sleep 5
done
if [ -z "$PUBLIC_IP" ]; then
    echo "ERROR: external IP still not available after 60 s" >&2
    exit 1
fi

# Derive apex domain and GoDaddy record name
AUTH="sso-key ${GODADDY_API_KEY}:${GODADDY_API_SECRET}"

APEX="$DOMAIN_NAME"
while echo "$APEX" | grep -q '\.'; do
    STATUS=$(curl -sf -o /dev/null -w "%{http_code}" -H "Authorization: ${AUTH}" "https://api.godaddy.com/v1/domains/${APEX}" 2>/dev/null || echo "000")
    if [ "$STATUS" = "200" ]; then
        break
    fi
    APEX="${APEX#*.}"
done

if ! echo "$APEX" | grep -q '\.'; then
    # Fallback to naive parsing if API fails entirely
    APEX=$(echo "$DOMAIN_NAME" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}')
fi

SUB="${DOMAIN_NAME%.$APEX}"
if [ "$SUB" = "$DOMAIN_NAME" ] || [ -z "$SUB" ]; then RECORD="@"; else RECORD="${SUB%.}"; fi

PAYLOAD="[{\"data\":\"${PUBLIC_IP}\",\"ttl\":600}]"

echo "Updating GoDaddy: ${RECORD}.${APEX} → ${PUBLIC_IP}"
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X PUT "https://api.godaddy.com/v1/domains/${APEX}/records/A/${RECORD}" \
    -H "Authorization: ${AUTH}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" 2>/dev/null || echo "000")

if [ "$STATUS" = "200" ]; then
    echo "SUCCESS: ${RECORD}.${APEX} → ${PUBLIC_IP} (TTL 600)"
else
    echo "ERROR: GoDaddy API returned HTTP ${STATUS}" >&2
    exit 1
fi
UPDATER_EOF

    chmod 755 /usr/local/bin/treescout-dns-update
    log_success "Updater script written: /usr/local/bin/treescout-dns-update"

    # ── systemd service unit ──────────────────────────────────────────────────
    cat > /etc/systemd/system/treescout-dns.service <<'SERVICE_EOF'
[Unit]
Description=Update GoDaddy DNS A record with current external IP
Documentation=https://github.com/Scotchmcdonald/freescout
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/treescout-dns-update
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
# Retry up to 3 times if the network isn't fully ready yet
Restart=on-failure
RestartSec=15
StartLimitBurst=3
StartLimitIntervalSec=120

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable treescout-dns.service
    log_success "systemd service enabled: treescout-dns.service (runs on every boot)"
    log_info "View DNS update logs:  journalctl -u treescout-dns.service -n 50"
}

# ==============================================================================
# STEP 6 — Log Docker into GHCR
# ==============================================================================

docker_login_ghcr() {
    log_step "Authenticating Docker with GitHub Container Registry"

    # Some older Docker versions require a username matching the literal owner,
    # instead of the truncated token prefix which is standard for GH CR.
    if echo "$REPO_TOKEN" | docker login ghcr.io -u "Scotchmcdonald" --password-stdin 2>/dev/null \
        || echo "$REPO_TOKEN" | docker login ghcr.io -u "borealtek" --password-stdin; then
        log_success "Docker authenticated with ghcr.io"
        return 0
    fi

    log_warning "Docker login to ghcr.io failed — local source build fallback will be used."
    return 1
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
        image: ${APP_IMAGE}
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
        image: ${APP_IMAGE}
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
        image: ${APP_IMAGE}
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
        image: ${APP_IMAGE}
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
APP_IMAGE=${APP_IMAGE}

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

build_local_image() {
    log_step "Building local application image (fallback mode)"

    local src_dir="${BUILD_DIR}/src"
    rm -rf "$src_dir"
    mkdir -p "$BUILD_DIR"

    log_info "Cloning app source (${GIT_BRANCH})..."
    git clone --depth=1 --branch "$GIT_BRANCH" "$GIT_REPO_URL" "$src_dir"

    local manifest_path="${src_dir}/deployment/modules.manifest.json"
    if [ ! -f "$manifest_path" ]; then
        log_error "Module manifest not found: $manifest_path"
        exit 1
    fi

    mkdir -p "${src_dir}/Modules"
    local modules
    modules=$(jq -r --arg p "$TREESCOUT_PROFILE" '.profiles[$p].modules[]' "$manifest_path" 2>/dev/null || true)
    if [ -z "$modules" ]; then
        log_error "No modules resolved for profile '${TREESCOUT_PROFILE}' in modules.manifest.json"
        exit 1
    fi

    while IFS= read -r module; do
        [ -z "$module" ] && continue
        local repo branch
        repo=$(jq -r --arg m "$module" '.modules[$m].repo // empty' "$manifest_path")
        branch=$(jq -r --arg m "$module" '.modules[$m].branch // "main"' "$manifest_path")

        if [ -z "$repo" ]; then
            log_error "Missing repo URL in manifest for module: $module"
            exit 1
        fi

        log_info "Cloning module: $module @ $branch"
        git clone --depth=1 --branch "$branch" \
            "https://oauth2:${REPO_TOKEN}@${repo#https://}" \
            "${src_dir}/Modules/${module}" -q
        rm -rf "${src_dir}/Modules/${module}/.git"
    done <<< "$modules"

    local vcs_ref
    vcs_ref=$(git -C "$src_dir" rev-parse --short HEAD 2>/dev/null || echo "local")
    local build_date
    build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    APP_IMAGE="treescout-local:${TREESCOUT_PROFILE}-latest"
    log_info "Building Docker image: ${APP_IMAGE}"
    docker build \
        -f "${src_dir}/Dockerfile.prod" \
        -t "${APP_IMAGE}" \
        --build-arg "PROFILE=${TREESCOUT_PROFILE}" \
        --build-arg "BUILD_DATE=${build_date}" \
        --build-arg "VCS_REF=${vcs_ref}" \
        "$src_dir"

    # Keep compose substitution in sync after fallback image selection.
    sed -i "s#^APP_IMAGE=.*#APP_IMAGE=${APP_IMAGE}#" "${DEPLOY_DIR}/.env"
    log_success "Local image built: ${APP_IMAGE}"
}

# ==============================================================================
# STEP 8 — Pull image and start services
# ==============================================================================

deploy() {
    log_step "Pulling image and starting services"

    cd "$DEPLOY_DIR"

    APP_IMAGE="ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE}-latest"
    sed -i "s#^APP_IMAGE=.*#APP_IMAGE=${APP_IMAGE}#" "${DEPLOY_DIR}/.env"

    log_info "Pulling image: ${APP_IMAGE}"
    if ! docker compose -f docker-compose.prod.yml pull; then
        log_warning "GHCR pull failed; switching to local source-build fallback."
        build_local_image
    fi

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
    register_godaddy_dns
    install_dns_updater
    docker_login_ghcr || true
    write_app_files
    deploy
    post_deploy
}

main "$@"
