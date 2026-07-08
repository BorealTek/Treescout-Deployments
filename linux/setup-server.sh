#!/usr/bin/env bash
# =============================================================================
# TreeScout Server Setup
#
# Bootstraps a fresh Ubuntu/Debian server for a Proxmox-hosted TreeScout
# deployment. Run as root or a sudo-capable user.
#
# What it does:
#   1. Installs Docker + Compose plugin if missing
#   2. Creates /opt/treescout/ with all required files
#   3. Prompts for all configuration (passwords, tokens, domain)
#   4. Authenticates to GHCR and pulls the app image
#   5. Starts the stack with docker compose
#   6. Runs first-time artisan setup (key:generate, treescout:install,
#      module:migrate, ThemeSeeder) on a fresh install
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/BorealTek/Treescout-Core/main/deployment/linux/setup-server.sh | sudo bash
#   — or —
#   sudo bash setup-server.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/treescout"
GHCR_IMAGE="ghcr.io/borealtek/treescout"
GHCR_USER="scotchmcdonald"
DEFAULT_PROFILE="full"

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}  ➜${NC}  $*"; }
log_success() { echo -e "${GREEN}  ✔${NC}  $*"; }
log_warning() { echo -e "${YELLOW}  ⚠${NC}  $*"; }
log_error()   { echo -e "${RED}  ✖${NC}  $*" >&2; }
log_step()    { echo ""; echo -e "${CYAN}━━━  $* ${NC}"; }

ask() {
    # ask VAR_NAME "Prompt text" ["default"]
    # Reads from /dev/tty so it works when script is piped via curl | bash
    local var="$1" prompt="$2" default="${3:-}"
    local display_default=""
    if [[ -n "$default" ]]; then display_default=" [${default}]"; fi
    read -rp "  ${prompt}${display_default}: " val </dev/tty
    if [[ -z "$val" && -n "$default" ]]; then val="$default"; fi
    printf -v "$var" '%s' "$val"
}

ask_secret() {
    local var="$1" prompt="$2"
    read -rsp "  ${prompt}: " val </dev/tty
    echo ""
    printf -v "$var" '%s' "$val"
}

rand_hex() { openssl rand -hex "$1"; }

# ── Preflight ─────────────────────────────────────────────────────────────────

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Run as root or with sudo."
        exit 1
    fi
}

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_success "Docker $(docker --version | cut -d' ' -f3 | tr -d ',') already installed"
        return
    fi
    log_info "Installing Docker..."
    apt-get update -qq
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    log_success "Docker installed"
}

# ── Detect existing install ───────────────────────────────────────────────────

IS_FRESH_INSTALL=true

detect_existing() {
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        IS_FRESH_INSTALL=false
        log_warning "Existing installation found at ${INSTALL_DIR}"
        echo ""
        echo "  [1] Update config and restart (keep data)"
        echo "  [2] Fresh install (DESTROYS all database data)"
        echo "  [3] Exit"
        echo ""
        read -rp "  Choice [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            2)
                log_warning "Stopping containers and removing volumes..."
                cd "${INSTALL_DIR}"
                docker compose -f docker-compose.prod.yml down -v 2>/dev/null || true
                IS_FRESH_INSTALL=true
                ;;
            3) exit 0 ;;
            *) IS_FRESH_INSTALL=false ;;
        esac
    fi
}

# ── Interactive config ────────────────────────────────────────────────────────

gather_config() {
    log_step "Configuration"

    echo ""
    echo "  Press ENTER to accept defaults where shown."
    echo ""

    # Domain
    ask APP_URL "App URL (e.g. https://tickets.borealtek.ca)" ""
    while [[ -z "${APP_URL:-}" ]]; do
        ask APP_URL "App URL (required)" ""
    done

    # Profile
    ask TREESCOUT_PROFILE "Image profile (full / core-msp / helpdesk-only / google-workspace-msp)" "$DEFAULT_PROFILE"

    # Database passwords — auto-generate, show for confirmation
    local gen_db_root; gen_db_root=$(rand_hex 20)
    local gen_db_pass; gen_db_pass=$(rand_hex 20)
    local gen_redis;   gen_redis=$(rand_hex 20)

    echo ""
    log_info "Generated credentials (press ENTER to accept, or type your own):"
    ask DB_ROOT_PASS "MariaDB root password" "$gen_db_root"
    ask DB_PASS      "MariaDB treescout user password" "$gen_db_pass"
    ask REDIS_PASSWORD "Redis password" "$gen_redis"

    DB_NAME="treescout"
    DB_USER="treescout"

    # Reverb keys (always auto-generate)
    REVERB_APP_ID=$(rand_hex 8)
    REVERB_APP_KEY=$(rand_hex 16)
    REVERB_APP_SECRET=$(rand_hex 16)

    # Mail
    echo ""
    log_info "Mail (SMTP outbound)"
    ask MAIL_HOST     "SMTP host" ""
    ask MAIL_PORT     "SMTP port" "587"
    ask MAIL_USERNAME "SMTP username" ""
    ask_secret MAIL_PASSWORD "SMTP password"
    ask MAIL_FROM_ADDRESS "From address" "noreply@borealtek.ca"
    ask MAIL_FROM_NAME    "From name" "BorealTek Treescout"

    # IMAP (optional)
    echo ""
    log_info "Inbound mail / IMAP (leave blank to skip)"
    ask IMAP_HOST     "IMAP host" ""
    if [[ -n "${IMAP_HOST:-}" ]]; then
        ask IMAP_PORT     "IMAP port" "993"
        ask IMAP_USERNAME "IMAP username" ""
        ask_secret IMAP_PASSWORD "IMAP password"
    else
        IMAP_PORT=""
        IMAP_USERNAME=""
        IMAP_PASSWORD=""
    fi

    # Admin account (used by treescout:install on first run)
    echo ""
    log_info "Admin account"
    ask ADMIN_EMAIL "Admin email" "scott.mcdonald@borealtek.ca"
    ask_secret ADMIN_PASSWORD "Admin password"
    while [[ -z "${ADMIN_PASSWORD:-}" ]]; do
        ask_secret ADMIN_PASSWORD "Admin password (required)"
    done

    # GitHub tokens
    echo ""
    log_info "GitHub tokens"
    ask_secret GHCR_PULL_TOKEN "GitHub PAT for image pull (read:packages scope)"
    while [[ -z "${GHCR_PULL_TOKEN:-}" ]]; do
        ask_secret GHCR_PULL_TOKEN "GitHub PAT (required to pull from ghcr.io)"
    done
    ask_secret APP_GITHUB_API_TOKEN "GitHub PAT for runtime module API (repo scope)"
    while [[ -z "${APP_GITHUB_API_TOKEN:-}" ]]; do
        ask_secret APP_GITHUB_API_TOKEN "Runtime PAT (required)"
    done

    # Cloudflare Tunnel
    echo ""
    log_info "Cloudflare Tunnel"
    ask_secret CF_TUNNEL_TOKEN "CF Tunnel token (from Zero Trust dashboard)"

    # Optional: Google Admin
    echo ""
    log_info "Google Workspace / Admin (leave blank to skip)"
    ask GOOGLE_DOMAIN_SLUG "Domain slug e.g. BOREALTEK" ""
    if [[ -n "${GOOGLE_DOMAIN_SLUG:-}" ]]; then
        GOOGLE_DOMAIN_SLUG="${GOOGLE_DOMAIN_SLUG^^}"
        ask "GOOGLE_${GOOGLE_DOMAIN_SLUG}_ADMIN"       "Admin email for ${GOOGLE_DOMAIN_SLUG}" ""
        ask "GOOGLE_${GOOGLE_DOMAIN_SLUG}_CUSTOMER"    "Customer ID for ${GOOGLE_DOMAIN_SLUG}" ""
        ask "GOOGLE_${GOOGLE_DOMAIN_SLUG}_CREDENTIALS" "Path to service account JSON" "/secrets/google/${GOOGLE_DOMAIN_SLUG,,}-service-account.json"
    fi
}

# ── Write files ───────────────────────────────────────────────────────────────

create_dirs() {
    log_step "Creating directories"
    mkdir -p "${INSTALL_DIR}/cloudflared"
    log_success "${INSTALL_DIR}/ and cloudflared/ ready"
}

write_compose() {
    log_step "Writing docker-compose.prod.yml"
    cat > "${INSTALL_DIR}/docker-compose.prod.yml" <<'COMPOSE_EOF'
# =============================================================================
# TreeScout Production Docker Compose
#
# Uses pre-built images from GHCR — no build step on the server.
#
# Run from /opt/treescout/:
#   docker compose pull
#   docker compose up -d
#   docker compose exec app php artisan migrate --force
# =============================================================================

services:
    app:
        image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE:-full}-latest
        container_name: treescout-app
        restart: unless-stopped
        ports:
            - "127.0.0.1:8080:8080"
        env_file:
            - .env
            - .secrets
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
        ulimits:
            nofile:
                soft: 65536
                hard: 65536
        healthcheck:
            test: [ "CMD", "curl", "-f", "http://localhost:8080" ]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 60s

    queue:
        image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE:-full}-latest
        container_name: treescout-queue
        restart: always
        command: php artisan queue:work --queue=emails,default,long-running --sleep=3 --tries=3 --max-time=3600
        env_file:
            - .env
            - .secrets
        volumes:
            - storage_data:/var/www/html/storage
            - bootstrap_cache:/var/www/html/bootstrap/cache
        depends_on:
            - app
            - db
            - redis
        networks:
            - treescout-net
        healthcheck:
            disable: true

    cron:
        image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE:-full}-latest
        container_name: treescout-cron
        restart: unless-stopped
        command: >
            /bin/sh -c 'while true; do
              php artisan schedule:run >> /var/www/html/storage/logs/cron.log 2>&1;
              sleep 60;
            done'
        env_file:
            - .env
            - .secrets
        volumes:
            - storage_data:/var/www/html/storage
            - bootstrap_cache:/var/www/html/bootstrap/cache
        depends_on:
            - app
            - db
            - redis
        networks:
            - treescout-net
        healthcheck:
            disable: true

    reverb:
        image: ghcr.io/borealtek/treescout:${TREESCOUT_PROFILE:-full}-latest
        container_name: treescout-reverb
        restart: unless-stopped
        command: php artisan reverb:start --host=0.0.0.0 --port=8081
        env_file:
            - .env
            - .secrets
        ports:
            - "127.0.0.1:8081:8081"
        volumes:
            - storage_data:/var/www/html/storage
            - bootstrap_cache:/var/www/html/bootstrap/cache
        depends_on:
            - app
            - db
            - redis
        networks:
            - treescout-net
        healthcheck:
            disable: true

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
            test: [ "CMD", "healthcheck.sh", "--connect", "--innodb_initialized" ]
            interval: 10s
            timeout: 5s
            retries: 5

    redis:
        image: redis:7-alpine
        container_name: treescout-redis
        restart: unless-stopped
        command: redis-server --requirepass ${REDIS_PASSWORD}
        networks:
            - treescout-net
        healthcheck:
            test: [ "CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping" ]
            interval: 10s
            timeout: 5s
            retries: 5

networks:
    treescout-net:
        driver: bridge

volumes:
    db_data:
    storage_data:
    bootstrap_cache:
COMPOSE_EOF
    log_success "docker-compose.prod.yml written"
}

write_cloudflared_compose() {
    log_step "Writing cloudflared/compose.yml"
    cat > "${INSTALL_DIR}/cloudflared/compose.yml" <<'CF_EOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --protocol http2 run
    network_mode: host
    environment:
      - TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
CF_EOF
    log_success "cloudflared/compose.yml written"
}

write_env() {
    log_step "Writing .env"

    local reverb_host
    reverb_host=$(echo "${APP_URL}" | sed 's|https://||;s|http://||;s|/.*||')

    cat > "${INSTALL_DIR}/.env" <<EOF
# ── Compose substitution vars (MariaDB init + Redis auth) ─────────────────────
TREESCOUT_PROFILE=${TREESCOUT_PROFILE}
DB_ROOT_PASS=${DB_ROOT_PASS}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
REDIS_PASSWORD=${REDIS_PASSWORD}

# ── Laravel app ───────────────────────────────────────────────────────────────
APP_NAME="BorealTek Treescout"
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=${APP_URL}
TICKET_URL=${APP_URL}
TRUSTED_PROXIES=*
APP_LOCALE=en
APP_FALLBACK_LOCALE=en
APP_TIMEZONE=UTC
APP_MAINTENANCE_DRIVER=file

# Database
DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

# Session / Cache / Queue
SESSION_DRIVER=redis
SESSION_LIFETIME=120
SESSION_SECURE_COOKIE=true
SESSION_ENCRYPT=false
SESSION_PATH=/
SESSION_DOMAIN=null
QUEUE_CONNECTION=redis
CACHE_STORE=redis
CACHE_PREFIX=
FILESYSTEM_DISK=local

# Redis
REDIS_CLIENT=phpredis
REDIS_HOST=redis
REDIS_PORT=6379

# WebSockets (Reverb)
BROADCAST_CONNECTION=reverb
REVERB_APP_ID=${REVERB_APP_ID}
REVERB_APP_KEY=${REVERB_APP_KEY}
REVERB_APP_SECRET=${REVERB_APP_SECRET}
REVERB_HOST=reverb
REVERB_PORT=8081
REVERB_SCHEME=http
VITE_REVERB_APP_KEY=${REVERB_APP_KEY}
VITE_REVERB_HOST=${reverb_host}
VITE_REVERB_PORT=443
VITE_REVERB_SCHEME=https

# Mail
MAIL_MAILER=${MAIL_HOST:+smtp}${MAIL_HOST:-log}
MAIL_HOST=${MAIL_HOST:-}
MAIL_PORT=${MAIL_PORT:-587}
MAIL_USERNAME=${MAIL_USERNAME:-}
MAIL_PASSWORD=${MAIL_PASSWORD:-}
MAIL_FROM_ADDRESS=${MAIL_FROM_ADDRESS}
MAIL_FROM_NAME="${MAIL_FROM_NAME}"

# IMAP (inbound mail)
IMAP_HOST=${IMAP_HOST:-}
IMAP_PORT=${IMAP_PORT:-993}
IMAP_ENCRYPTION=ssl
IMAP_VALIDATE_CERT=true
IMAP_PROTOCOL=imap
IMAP_USERNAME=${IMAP_USERNAME:-}
IMAP_PASSWORD=${IMAP_PASSWORD:-}
IMAP_DEFAULT_ACCOUNT=default

# Logging
LOG_CHANNEL=stack
LOG_STACK=single
LOG_LEVEL=error

# First-run seeder credentials
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF

    # Append optional Google Admin block
    if [[ -n "${GOOGLE_DOMAIN_SLUG:-}" ]]; then
        local slug="${GOOGLE_DOMAIN_SLUG}"
        cat >> "${INSTALL_DIR}/.env" <<EOF

# Google Workspace — ${slug}
GOOGLE_${slug}_CREDENTIALS=$(eval echo "\${GOOGLE_${slug}_CREDENTIALS:-}")
GOOGLE_${slug}_ADMIN=$(eval echo "\${GOOGLE_${slug}_ADMIN:-}")
GOOGLE_${slug}_CUSTOMER=$(eval echo "\${GOOGLE_${slug}_CUSTOMER:-}")
EOF
    fi

    chmod 600 "${INSTALL_DIR}/.env"
    log_success ".env written (mode 600)"
}

write_secrets() {
    log_step "Writing .secrets"
    cat > "${INSTALL_DIR}/.secrets" <<EOF
APP_GITHUB_API_TOKEN=${APP_GITHUB_API_TOKEN}
EOF
    chmod 600 "${INSTALL_DIR}/.secrets"
    log_success ".secrets written (mode 600)"
}

write_cloudflared_env() {
    if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
        log_step "Writing cloudflared/.env"
        cat > "${INSTALL_DIR}/cloudflared/.env" <<EOF
CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
EOF
        chmod 600 "${INSTALL_DIR}/cloudflared/.env"
        log_success "cloudflared/.env written (mode 600)"
    else
        log_warning "No CF_TUNNEL_TOKEN provided — skipping cloudflared/.env (add it later)"
    fi
}

# ── Docker auth + stack ───────────────────────────────────────────────────────

authenticate_ghcr() {
    log_step "Authenticating to GHCR"
    echo "${GHCR_PULL_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin
    log_success "Authenticated to ghcr.io"
}

pull_and_start() {
    log_step "Pulling images and starting stack"
    cd "${INSTALL_DIR}"
    docker compose -f docker-compose.prod.yml pull
    docker compose -f docker-compose.prod.yml up -d
    log_success "Stack started"

    log_info "Waiting for database to be healthy..."
    local attempts=0
    until docker compose -f docker-compose.prod.yml exec -T db healthcheck.sh --connect --innodb_initialized &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 30 ]]; then
            log_error "Database did not become healthy after 60s"
            docker compose -f docker-compose.prod.yml logs db | tail -20
            exit 1
        fi
        sleep 2
    done
    log_success "Database healthy"
}

first_run_setup() {
    log_step "First-run application setup"
    cd "${INSTALL_DIR}"

    log_info "Generating app key..."
    # key:generate writes to a .env inside the container (no file there at runtime).
    # Use --show to print the key and write it to the host .env, then restart containers.
    local app_key
    app_key=$(docker compose -f docker-compose.prod.yml exec -T app php artisan key:generate --show)
    sed -i "s|^APP_KEY=.*|APP_KEY=${app_key}|" "${INSTALL_DIR}/.env"
    docker compose -f docker-compose.prod.yml up -d --force-recreate app queue cron reverb

    log_info "Running freescout:install..."
    docker compose -f docker-compose.prod.yml exec -T app php artisan freescout:install \
        --force \
        --email="${ADMIN_EMAIL}" \
        --password="${ADMIN_PASSWORD}"

    log_info "Running module migrations..."
    docker compose -f docker-compose.prod.yml exec -T app php artisan module:migrate --all --force

    log_info "Seeding themes..."
    docker compose -f docker-compose.prod.yml exec -T app php artisan db:seed --class=ThemeSeeder --force

    log_success "Application initialised"
}

start_cloudflared() {
    if [[ -f "${INSTALL_DIR}/cloudflared/.env" ]]; then
        log_step "Starting Cloudflare tunnel"
        cd "${INSTALL_DIR}/cloudflared"
        docker compose up -d
        log_success "Cloudflare tunnel running"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────

show_summary() {
    local reverb_host
    reverb_host=$(echo "${APP_URL}" | sed 's|https://||;s|http://||;s|/.*||')

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  TreeScout deployment complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  URL:    ${CYAN}${APP_URL}${NC}"
    echo -e "  Admin:  ${CYAN}${ADMIN_EMAIL}${NC}"
    echo ""
    echo "  Useful commands:"
    echo "    docker compose -f /opt/treescout/docker-compose.prod.yml logs -f"
    echo "    docker compose -f /opt/treescout/docker-compose.prod.yml ps"
    echo "    docker compose -f /opt/treescout/docker-compose.prod.yml pull && docker compose -f /opt/treescout/docker-compose.prod.yml up -d"
    echo ""
    if [[ -z "${CF_TUNNEL_TOKEN:-}" ]]; then
        echo -e "  ${YELLOW}⚠  Cloudflare tunnel token was not provided.${NC}"
        echo "     Add it to /opt/treescout/cloudflared/.env and run:"
        echo "     cd /opt/treescout/cloudflared && docker compose up -d"
        echo ""
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}  TreeScout Server Setup${NC}"
    echo ""

    check_root
    install_docker
    detect_existing
    gather_config

    create_dirs
    write_compose
    write_cloudflared_compose
    write_env
    write_secrets
    write_cloudflared_env

    authenticate_ghcr

    pull_and_start

    if [[ "$IS_FRESH_INSTALL" == "true" ]]; then
        first_run_setup
    else
        log_info "Skipping first-run setup (existing installation — run migrations manually if needed)"
        log_info "  docker compose -f /opt/treescout/docker-compose.prod.yml exec app php artisan migrate --force"
    fi

    start_cloudflared
    show_summary
}

main "$@"
