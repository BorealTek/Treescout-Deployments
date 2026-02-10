#!/usr/bin/env bash


#===============================================================================
# FreeScout OrbStack Deployer (macOS + Cloudflare Tunnel)
# 
# Enterprise-grade deployment script with:
# - Bash strict mode (set -euo pipefail)
# - Trap handlers for cleanup
# - Progress indicators
# - Pre-flight validation
# - Docker BuildKit optimization
# - Self-signed SSL certificates
# - Cloudflare Tunnel integration
# - Idempotent re-deployment (safely re-run over existing installations)
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# GLOBALS & CONFIGURATION
#===============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_REPO="https://github.com/Scotchmcdonald/freescout.git"
readonly DEFAULT_BRANCH="laravel-11-foundation"
readonly DEFAULT_INSTALL_DIR="$HOME/borealtek-ticketing"
readonly CONFIG_FILE="${SCRIPT_DIR}/deploy.conf"

# Boreal Theme Colors
readonly RED='\033[38;5;196m'        # Bright Red
readonly GREEN='\033[38;5;46m'       # Neon Green
readonly FOREST='\033[38;5;22m'      # Forest Green
readonly YELLOW='\033[38;5;226m'     # Bright Yellow
readonly CYAN='\033[38;5;51m'        # Ice Blue/Cyan
readonly BLUE='\033[38;5;27m'        # Deep Blue
readonly MAGENTA='\033[38;5;201m'    # Neon Pink/Magenta
readonly WHITE='\033[38;5;231m'      # Bright White
readonly GREY='\033[38;5;240m'       # Dark Grey
readonly NC='\033[0m' # No Color

# Theme Aliases
readonly COLOR_PRIMARY=$CYAN
readonly COLOR_SECONDARY=$GREEN
readonly COLOR_ACCENT=$WHITE
readonly COLOR_DIM=$GREY
readonly COLOR_SUCCESS=$GREEN
readonly COLOR_WARNING=$YELLOW
readonly COLOR_ERROR=$RED

# State variables
INTERACTIVE=true
REUSE_DB=false
CLEANUP_NEEDED=false

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

log_info() {
    echo -e "${CYAN}ℹ ${NC} $*"
}

log_success() {
    echo -e "${GREEN}✔${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

log_error() {
    echo -e "${RED}✖${NC} $*" >&2
}

log_step() {
    echo ""
    echo -e "${MAGENTA}➜${NC} ${BLUE}$*${NC}"
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

cleanup() {
    local exit_code=$?
    
    if [ "$CLEANUP_NEEDED" = true ]; then
        log_warning "Cleaning up after error..."
    fi
    
    if [ $exit_code -ne 0 ]; then
        log_error "Script failed with exit code $exit_code"
    fi
    
    exit $exit_code
}

trap cleanup EXIT INT TERM

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

safe_read() {
    # $1: prompt
    # $2: variable name
    if [ -t 0 ]; then
        read -rp "$1" "$2"
    elif [ -c /dev/tty ]; then
        # Prompt to stderr so it shows up
        echo -ne "$1" >&2
        read -r "$2" < /dev/tty
        echo "" >&2
    else
        log_error "Interactive input required but no TTY available."
        exit 1
    fi
}

validate_required_var() {
    local var_name=$1
    local var_value=${2:-}
    
    if [ -z "$var_value" ]; then
        log_error "Required variable '$var_name' is not set"
        exit 1
    fi
}

#===============================================================================
# PRE-FLIGHT CHECKS
#===============================================================================

preflight_checks() {
    log_step "Running Pre-Flight Checks"
    
    # Check for Homebrew (informational)
    if ! command_exists brew; then
        log_warning "Homebrew not found. Assuming dependencies are met."
    fi
    
    # Check required tools
    local required_tools=("git" "curl" "openssl")
    for tool in "${required_tools[@]}"; do
        if ! command_exists "$tool"; then
            log_error "Missing tool: $tool"
            if command_exists brew; then
                log_info "Install with: brew install $tool"
            fi
            exit 1
        fi
    done
    
    # Check Docker (OrbStack or Docker Desktop)
    if ! command_exists docker; then
        log_error "Docker not found! Install OrbStack first."
        log_info "Download from: https://orbstack.dev"
        exit 1
    fi
    
    # Verify Docker is running
    log_info "Verifying Docker Status..."
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is installed but not running"
        exit 1
    fi

    # Check System Resources (macOS)
    if command_exists sysctl; then
        log_info "Checking system resources..."
        local total_mem
        total_mem=$(sysctl -n hw.memsize)
        # Check for at least 4GB RAM (approx 4294967296 bytes) since macOS is heavy
        if [ "$total_mem" -lt 4294967296 ]; then
            log_warning "System memory is below 4GB. Docker performance may be degraded."
            sleep 2
        else
            log_success "System memory check passed"
        fi
    fi
    
    # Enable BuildKit
    export DOCKER_BUILDKIT=1
    export COMPOSE_DOCKER_CLI_BUILD=1
    
    log_success "Pre-flight checks passed"
}

#===============================================================================
# CONFIGURATION MANAGEMENT
#===============================================================================

show_banner() {
    clear
    echo -e "${FOREST}       # #### ####${NC}"
    echo -e "${FOREST}     ### \\/#|### |/####${NC}"
    echo -e "${FOREST}    ##\\/#/ \\||/##/_/##/_#${NC}      ${CYAN}  ____                        _ _______   _          ${NC}"
    echo -e "${FOREST}  ###  \\/###|/ \\/ # ###${NC}        ${CYAN} |  _ \\                      | |__   __| | |        ${NC}"
    echo -e "${FOREST} ##_\\_#\\_\\## | #/###_/_####${NC}   ${CYAN}  | |_) | ___   _ __.__  ___  | |  | |  __| | __     ${NC}"
    echo -e "${FOREST}## #### # \\ #| /  #### ##/##${NC}    ${CYAN}|  _ < / _ \| '__/ _ \/ _ \\\`| |  | |/ _ \ |/ /     ${NC}"
    echo -e "${FOREST} __#_--###\`  |{,###---###-~${NC}     ${CYAN}| |_) | (_) | |  | __/ (_| || |  | || __/   <        ${NC}"
    echo -e "${FOREST}           \\ }{${NC}                 ${CYAN}|____/ \\___/|_|  \\___|\\__,_||_|  |_|\\___|_|\\_\\ ${NC}"
    echo -e "${FOREST}            }}{${NC}"
    echo -e "${FOREST}            }}{${NC}                     ${GREEN} T R E E S C O U T   E N T E R P R I S E     ${NC}"
    echo -e "${FOREST}            }}{${NC}"
    echo -e "${FOREST}      , -=-~{ .-^- _${NC}"
    echo -e "${FOREST}            \`${NC}"
    echo ""
    echo -e "${COLOR_DIM}────────────────────────────────────────────────────────────────────────${NC}"
}

load_or_create_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_success "Configuration file found: $CONFIG_FILE"
        
        if [ -t 0 ] || [ -c /dev/tty ]; then
            safe_read "Use this configuration? [Y/n] " use_config
            use_config=${use_config:-Y}
            
            if [[ "$use_config" =~ ^[Yy]$ ]]; then
                log_info "Loading configuration..."
                # shellcheck disable=SC1090
                source "$CONFIG_FILE"
                INTERACTIVE=false
                
                # Ensure array exists if not defined in config
                if [ -z "${MODULES_TO_INSTALL+x}" ]; then
                    MODULES_TO_INSTALL=()
                fi
                return
            fi
        fi
    else
        log_info "No configuration file found"
        
        if [ -t 0 ] || [ -c /dev/tty ]; then
            safe_read "Create configuration template? [y/N] " create_config
            
            if [[ "$create_config" =~ ^[Yy]$ ]]; then
                create_config_template
                log_success "Configuration template created at $CONFIG_FILE"
                log_info "Please edit the file and paste your Cloudflare Tunnel Token, then run again"
                exit 0
            fi
        fi
    fi
}

create_config_template() {
    cat > "$CONFIG_FILE" <<EOF
#===============================================================================
# FreeScout OrbStack Deployment Configuration (macOS)
#===============================================================================

# Installation Settings
GIT_REPO_URL="$DEFAULT_REPO"
GIT_BRANCH="$DEFAULT_BRANCH"
DEFAULT_INSTALL_DIR="$DEFAULT_INSTALL_DIR"

# Domain & Cloudflare Tunnel
DOMAIN_NAME="devtickets.scotchmcdonald.dev"
CF_TUNNEL_TOKEN=""  # Get from Cloudflare Zero Trust Dashboard

# Database Settings
DB_ROOT_PASS="$(openssl rand -hex 16)"
DB_USER="freescout"
DB_PASS="$(openssl rand -hex 16)"
DB_NAME="freescout"

# Admin User
ADMIN_EMAIL="admin@scotchmcdonald.dev"
ADMIN_PASS="$(openssl rand -hex 12)"

# Google OAuth (Optional)
GOOGLE_CLIENT_ID=""
GOOGLE_CLIENT_SECRET=""
GOOGLE_ADMIN_EMAILS=""
GOOGLE_ALLOWED_DOMAINS=""

# Define your access tokens (optional)
export REPO_TOKEN="ghp_your_token_here"

# Configure modules to install
# Format: "ModuleName|RepoURL|TokenEnvVarName"
MODULES_TO_INSTALL=(
    "Crm|https://github.com/Example/Crm.git|REPO_TOKEN"
    "PIB|https://github.com/Example/PIB.git|REPO_TOKEN"
    "AssetManagement|https://github.com/Example/AssetManagement.git|REPO_TOKEN"
)
EOF
}


interactive_menu() {
    local choice
    while true; do
        show_banner
        echo -e "  ${COLOR_PRIMARY}[1]${NC} Deploy to OrbStack (Fresh)"
        echo -e "  ${COLOR_PRIMARY}[2]${NC} Update Existing/Redeploy"
        echo -e "  ${COLOR_PRIMARY}[4]${NC} View Logs"
        echo -e "  ${COLOR_PRIMARY}[0]${NC} Exit"
        echo ""
        safe_read "  Enter Selection: " choice
        
        case $choice in
            1) return 0 ;;
            2) return 0 ;;
            4)
                if command_exists docker; then
                     docker compose logs -f app
                fi
                ;;
            0) exit 0 ;;
            *) log_error "Invalid selection" ; sleep 1 ;;
        esac
    done
}

interactive_setup() {
     # If script provided with args, skip menu
    if [ "$INTERACTIVE" = true ]; then
        interactive_menu
    fi

    log_step "Interactive Setup"
    
    # Cloudflare configuration
    log_info "Cloudflare Configuration"
    safe_read "Domain Name [devtickets.scotchmcdonald.dev]: " input_domain
    DOMAIN_NAME="${input_domain:-devtickets.scotchmcdonald.dev}"
    
    while [ -z "${CF_TUNNEL_TOKEN:-}" ]; do
        echo -e "${YELLOW}Paste your Cloudflare Tunnel Token (starts with ey...):${NC}"
        safe_read "> " CF_TUNNEL_TOKEN
    done
    echo ""
    
    # Admin configuration
    log_info "Admin User"
    safe_read "Admin Email [admin@scotchmcdonald.dev]: " input_email
    ADMIN_EMAIL="${input_email:-admin@scotchmcdonald.dev}"
    safe_read "Admin Password [auto-generate]: " input_pass
    ADMIN_PASS="${input_pass:-$(openssl rand -hex 12)}"
    echo ""
    
    # Google OAuth (optional)
    log_info "Google OAuth (Optional)"
    safe_read "Google Client ID (Enter to skip): " GOOGLE_CLIENT_ID
    if [ -n "$GOOGLE_CLIENT_ID" ]; then
        safe_read "Google Client Secret: " GOOGLE_CLIENT_SECRET
        safe_read "Google Admin Emails (comma separated): " GOOGLE_ADMIN_EMAILS
        safe_read "Allowed Domains (comma separated): " GOOGLE_ALLOWED_DOMAINS
    fi
    echo ""
    
    # Configuration summary
    echo "────────────────────────────────────────────────────────────"
    echo -e "CONFIGURATION SUMMARY:"
    echo -e "  Repository: ${GREEN}$DEFAULT_REPO${NC}"
    echo -e "  Branch:     ${GREEN}$DEFAULT_BRANCH${NC}"
    echo -e "  Domain:     ${GREEN}$DOMAIN_NAME${NC}"
    echo -e "  Tunnel:     ${GREEN}Configured${NC}"
    if [ -n "$GOOGLE_CLIENT_ID" ]; then
        echo -e "  Google:     ${GREEN}Configured${NC}"
    else
        echo -e "  Google:     ${YELLOW}Skipped${NC}"
    fi
    echo "────────────────────────────────────────────────────────────"
    echo ""
    read -rp "Press ENTER to start deployment (or Ctrl+C to cancel)..."
}

#===============================================================================
# DEPLOYMENT FUNCTIONS
#===============================================================================

load_existing_credentials() {
    local env_file=$1
    
    # Load Docker .env credentials
    if [ -f "$env_file" ]; then
        DB_PASS=$(grep "^DB_PASSWORD=" "$env_file" | cut -d '=' -f2 || echo "")
        DB_ROOT_PASS=$(grep "^DB_ROOT_PASSWORD=" "$env_file" | cut -d '=' -f2 || echo "")
        DB_USER=$(grep "^DB_USER=" "$env_file" | cut -d '=' -f2 || echo "")
        DB_NAME=$(grep "^DB_DATABASE=" "$env_file" | cut -d '=' -f2 || echo "")
    fi
    
    # Load Laravel .env credentials
    local laravel_env="$DEFAULT_INSTALL_DIR/src/.env"
    if [ -f "$laravel_env" ]; then
        local existing_email existing_pass
        existing_email=$(grep "^ADMIN_EMAIL=" "$laravel_env" | cut -d '=' -f2 | tr -d '"' | tr -d "'" || echo "")
        existing_pass=$(grep "^ADMIN_PASSWORD=" "$laravel_env" | cut -d '=' -f2 | tr -d '"' | tr -d "'" || echo "")
        
        if [ -n "$existing_email" ]; then ADMIN_EMAIL=$existing_email; fi
        if [ -n "$existing_pass" ]; then
            ADMIN_PASS=$existing_pass
        fi
    fi
}

check_existing_installation() {
    local existing_env="$DEFAULT_INSTALL_DIR/.env"
    
    if [ -f "$existing_env" ]; then
        log_warning "Existing installation found at $DEFAULT_INSTALL_DIR"
        
        if [ -t 0 ] || [ -c /dev/tty ]; then
            echo ""
            echo "1) Reuse existing database (Keep data)"
            echo "2) Overwrite database (DESTROY ALL DATA)"
            safe_read "Select [1-2]: " reuse_opt
            
            case "$reuse_opt" in
                2)
                    REUSE_DB=false
                    log_error "WARNING: Existing database will be destroyed!"
                    ;;
                *)
                    REUSE_DB=true
                    ;;
            esac
        else
            # Non-interactive: default to safe option
            REUSE_DB=true
        fi
        
        if [ "$REUSE_DB" = true ]; then
            log_info "Loading existing credentials..."
            load_existing_credentials "$existing_env"
        fi
    else
        # Fresh installation - ensure REUSE_DB is false
        REUSE_DB=false
    fi
}

decommission_existing() {
    if [ -f "$DEFAULT_INSTALL_DIR/docker-compose.yml" ]; then
        log_step "Decommissioning Existing Installation"
        
        cd "$DEFAULT_INSTALL_DIR"
        
        log_warning "Existing deployment detected!"
        echo ""
        echo -e "${YELLOW}What would you like to do?${NC}"
        echo "  1) Reuse existing data (keep database and volumes)"
        echo "  2) Nuke everything (fresh install, all data lost)"
        echo "  3) Cancel deployment"
        echo ""
        safe_read "Enter choice [1-3]: " choice
        
        case $choice in
            1)
                REUSE_DB=true
                log_info "Reusing existing data - stopping containers only..."
                docker compose down 2>/dev/null || true
                ;;
            2)
                REUSE_DB=false
                log_warning "Nuking everything - all data will be lost!"
                safe_read "Type 'yes' to confirm: " confirm
                if [ "$confirm" = "yes" ]; then
                    log_info "Stopping and removing containers and volumes..."
                    docker compose down -v --remove-orphans 2>/dev/null || true
                    log_info "Removing source code directory..."
                    rm -rf src
                    log_success "Everything nuked"
                else
                    log_error "Nuke cancelled"
                    exit 1
                fi
                ;;
            3)
                log_info "Deployment cancelled by user"
                exit 0
                ;;
            *)
                log_error "Invalid choice"
                exit 1
                ;;
        esac
    fi
}

setup_directories() {
    log_step "Setting Up Directory Structure"
    
    mkdir -p "$DEFAULT_INSTALL_DIR/nginx"
    cd "$DEFAULT_INSTALL_DIR"
    
    log_success "Directories created"
}

generate_dockerfile() {
    log_step "Generating Dockerfile"
    
    cat > Dockerfile <<'EOF'
FROM serversideup/php:8.2-fpm-nginx

USER root

# Install system dependencies and Node.js 24.x LTS
RUN apt-get update && apt-get install -y gnupg git curl ca-certificates && \
    # Install Docker CLI and Compose
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli docker-compose-plugin || apt-get install -y docker.io docker-buildx || true && \
    # Install Node.js
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    # Install PHP extensions
    curl -sSLf \
        -o /usr/local/bin/install-php-extensions \
        https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions && \
    chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions imap gmp soap intl bcmath gd && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Configure Docker socket access for www-data user
# We use a startup script to dynamically assign the group based on the mounted socket
RUN mkdir -p /etc/entrypoint.d && \
    printf "#!/bin/sh\n\
if [ -S /var/run/docker.sock ]; then\n\
    SOCK_GID=\$(stat -c '%%g' /var/run/docker.sock)\n\
    echo \"Fixing docker socket permissions (GID: \$SOCK_GID)...\"\n\
    if getent group \$SOCK_GID; then\n\
        GROUP_NAME=\$(getent group \$SOCK_GID | cut -d: -f1)\n\
        usermod -aG \$GROUP_NAME www-data\n\
    else\n\
        groupadd -g \$SOCK_GID docker_sock_runtime\n\
        usermod -aG docker_sock_runtime www-data\n\
    fi\n\
fi\n" > /etc/entrypoint.d/99-fix-docker-sock.sh && \
    chmod +x /etc/entrypoint.d/99-fix-docker-sock.sh

# Note: We run as root to allow the entrypoint script to fix permissions.
# The base image handles dropping privileges to www-data for PHP-FPM.
EOF
    
    log_success "Dockerfile generated"
}

generate_nginx_config() {
    log_step "Generating Nginx Configuration (HTTPS + WebSocket)"
    
    cat > nginx/default.conf <<'EOF'
upstream reverb_backend {
    server reverb:8080;
}

server {
    listen 8080 ssl http2 default_server;
    server_name _;
    root /var/www/html/public;
    index index.php index.html;
    client_max_body_size 20M;
    
    # SSL Configuration
    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    
    # Proxy WebSocket requests to Reverb container
    location /app/ {
        proxy_pass http://reverb_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
    }
    
    # PHP Application
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_param HTTPS on;
    }
    
    # Static assets
    location ~* ^/storage/attachment/ {
        expires 1M;
        access_log off;
        try_files $uri $uri/ /index.php?$query_string;
    }
    
    location ~* ^/(?:css|js)/.*\.(?:css|js)$ {
        expires 2d;
        access_log off;
        add_header Cache-Control "public, must-revalidate";
    }
    
    # Security
    location ~ /\. {
        deny all;
    }
}
EOF
    
    log_success "Nginx config generated"
}

generate_ssl_certificates() {
    log_step "Generating Self-Signed SSL Certificates"
    
    mkdir -p nginx/ssl
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout nginx/ssl/key.pem \
        -out nginx/ssl/cert.pem \
        -subj "/C=US/ST=State/L=City/O=FreeScout/CN=${DOMAIN_NAME}" \
        2>&1 | grep -v "writing new private key" || true
    
    # Verify certificates
    if [ ! -f "nginx/ssl/cert.pem" ] || [ ! -f "nginx/ssl/key.pem" ]; then
        log_error "Failed to generate SSL certificates"
        exit 1
    fi
    
    log_success "SSL certificates generated"
}

generate_docker_env() {
    log_step "Generating Docker Environment File"
    
    cat > .env <<EOF
DB_ROOT_PASSWORD=${DB_ROOT_PASS}
DB_DATABASE=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASS}
APP_URL=https://${DOMAIN_NAME}
REDIS_HOST=redis
REDIS_PORT=6379
TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
EOF

    # Pass through any environment variables ending in _TOKEN, _KEY, or _SECRET
    # This allows passing git access tokens for modules
    env | grep -E '(_TOKEN|_KEY|_SECRET)=' | grep -vE '^(DB_|APP_|REDIS_|GOOGLE_|REVERB_|TUNNEL_)' >> .env || true
    
    log_success "Docker .env generated"
}

generate_docker_compose() {
    log_step "Generating Docker Compose Configuration"
    
    # Detect Docker socket GID for permission handling
    # OrbStack typically uses same socket path as Docker Desktop
    local DOCKER_GID="999"
    if [ -S "/var/run/docker.sock" ]; then
        # Try GNU stat (Linux) then BSD stat (macOS)
        DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -f '%g' /var/run/docker.sock 2>/dev/null || echo "999")
        log_info "Docker socket GID detected: $DOCKER_GID"
    else
        log_warning "Docker socket not found, using default GID: $DOCKER_GID"
    fi
    
    cat > docker-compose.yml <<EOF
services:
  app:
    build:
      context: .
      args:
        DOCKER_GID: ${DOCKER_GID}
    image: freescout-app
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"  # Local only (tunnel handles public)
    environment:
      - PUID=$(id -u)
      - PGID=$(id -g)
      # Docker GID for socket access (enables sibling container spawning)
      - DOCKER_GID=${DOCKER_GID}
      # Host path for DooD volume mounting
      - HOST_SRC_PATH=${PWD}/src
      - PHP_MEMORY_LIMIT=512M
      - PHP_OPCACHE_ENABLE=1
      - PHP_POST_MAX_SIZE=20M
      - PHP_UPLOAD_MAX_FILESIZE=20M
      # Database Configuration
      - DB_CONNECTION=mysql
      - DB_HOST=db
      - DB_PORT=3306
      - DB_DATABASE=\${DB_DATABASE}
      - DB_USERNAME=\${DB_USER}
      - DB_PASSWORD=\${DB_PASSWORD}
    volumes:
      - ./src:/var/www/html
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf
      - ./nginx/ssl:/etc/nginx/ssl
      # DOCKER-OUTSIDE-OF-DOCKER (Sibling Container Architecture)
      # Mount Docker socket to allow app container to spawn sibling containers
      # Used by EmailMigration module for spinning up temporary test mail servers
      # OrbStack: Uses same socket path as standard Docker (/var/run/docker.sock)
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - fs-net
    healthcheck:
      test: ["CMD", "curl", "-fk", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  db:
    image: mariadb:10.6
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW --innodb-file-per-table=1 --skip-innodb-read-only-compressed
    environment:
      MARIADB_ROOT_PASSWORD: \${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: \${DB_DATABASE}
      MARIADB_USER: \${DB_USER}
      MARIADB_PASSWORD: \${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - fs-net
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:alpine
    restart: unless-stopped
    networks:
      - fs-net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  queue:
    image: freescout-app
    restart: always
    command: php artisan queue:work --queue=emails,default,long-running --sleep=3 --tries=3 --max-time=3600
    environment:
      - PHP_MEMORY_LIMIT=512M
      - PHP_OPCACHE_ENABLE=1
      # Database Configuration
      - DB_CONNECTION=mysql
      - DB_HOST=db
      - DB_PORT=3306
      - DB_DATABASE=\${DB_DATABASE}
      - DB_USERNAME=\${DB_USER}
      - DB_PASSWORD=\${DB_PASSWORD}
    volumes:
      - ./src:/var/www/html
    depends_on:
      - app
      - db
      - redis
    networks:
      - fs-net

  cron:
    image: freescout-app
    restart: unless-stopped
    environment:
      - PHP_OPCACHE_ENABLE=1
      - ENABLE_CRON=true
    volumes:
      - ./src:/var/www/html
    depends_on:
      - app
      - db
      - redis
    networks:
      - fs-net

  reverb:
    image: freescout-app
    restart: unless-stopped
    command: >
      sh -c '
      while [ ! -f /var/www/html/vendor/autoload.php ]; do
        echo "Waiting for composer dependencies to be installed...";
        sleep 5;
      done;
      echo "Dependencies ready, starting Reverb...";
      php artisan reverb:start --host="0.0.0.0" --port=8080
      '
    environment:
      - PHP_OPCACHE_ENABLE=1
    volumes:
      - ./src:/var/www/html
    depends_on:
      - app
      - db
      - redis
    networks:
      - fs-net

  tunnel:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=\${TUNNEL_TOKEN}
    networks:
      - fs-net

networks:
  fs-net:
    driver: bridge

volumes:
  db_data:
EOF
    
    log_success "Docker Compose config generated"
}

generate_update_script() {
    log_step "Generating Update Script"
    
    cat > update.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "🔄 Updating FreeScout..."

cd src
git pull origin ${DEFAULT_BRANCH}
cd ..

echo "🐳 Rebuilding containers..."
docker compose build app
docker compose up -d

echo "🗄️  Running migrations..."
docker compose exec -T app php artisan migrate --force

echo "📦 Installing dependencies..."
docker compose exec -T -u root app composer install --no-dev --optimize-autoloader
docker compose exec -T -u root app npm install
docker compose exec -T -u root app npm run build

echo "🧹 Clearing caches..."
docker compose exec -T app php artisan freescout:clear-cache

echo "✅ Update complete!"
EOF
    
    chmod +x update.sh
    log_success "Update script generated"
}

clone_or_update_repo() {
    log_step "Cloning/Updating Repository"
    
    if [ -d "src" ]; then
        log_info "Source folder exists. Syncing..."
        
        cd src
        git config --global --add safe.directory "$PWD"
        git remote set-url origin "$DEFAULT_REPO"
        git fetch origin
        
        if ! git checkout "$DEFAULT_BRANCH" 2>/dev/null; then
            git checkout -b "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
        fi
        
        if ! git pull origin "$DEFAULT_BRANCH"; then
            log_error "Git pull failed! Local changes detected."
            
            if [ -t 0 ]; then
                echo ""
                echo "1) Discard local changes (git reset --hard)"
                echo "2) Nuke & Re-clone (Delete src and download fresh)"
                echo "3) Exit and fix manually"
                read -rp "Select [1-3]: " git_opt
                
                case "$git_opt" in
                    1)
                        log_info "Resetting to origin/$DEFAULT_BRANCH..."
                        git reset --hard "origin/$DEFAULT_BRANCH"
                        ;;
                    2)
                        log_warning "Nuking source directory..."
                        cd ..
                        rm -rf src
                        git clone -b "$DEFAULT_BRANCH" "$DEFAULT_REPO" src
                        cd src
                        ;;
                    *)
                        log_error "Aborting. Please fix git conflicts manually."
                        exit 1
                        ;;
                esac
            else
                log_error "Cannot handle git conflict in non-interactive mode"
                exit 1
            fi
        fi
        
        cd ..
    else
        log_info "Cloning source..."
        git clone -b "$DEFAULT_BRANCH" "$DEFAULT_REPO" src
    fi
    
    log_success "Repository ready"
}

configure_laravel() {
    log_step "Configuring Laravel Environment"
    
    cp "src/.env.example" "src/.env"
    
    local env_file="src/.env"
    
    # Use BSD sed syntax for macOS
    sed -i '' "s|APP_URL=http://localhost|APP_URL=https://${DOMAIN_NAME}|g" "$env_file"
    sed -i '' "s/DB_HOST=127.0.0.1/DB_HOST=db/g" "$env_file"
    sed -i '' "s/DB_PASSWORD=/DB_PASSWORD=${DB_PASS}/g" "$env_file"
    sed -i '' "s/CACHE_STORE=database/CACHE_STORE=redis/g" "$env_file"
    sed -i '' "s/REDIS_HOST=127.0.0.1/REDIS_HOST=redis/g" "$env_file"
    sed -i '' "s/APP_FORCE_HTTPS=false/APP_FORCE_HTTPS=true/g" "$env_file"
    
    # Admin credentials
    cat >> "$env_file" <<EOF

# Admin Credentials
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD="${ADMIN_PASS}"
EOF
    
    # Reverb/Broadcasting
    local reverb_app_id reverb_app_key reverb_app_secret
    reverb_app_id=$(openssl rand -hex 8)
    reverb_app_key=$(openssl rand -hex 16)
    reverb_app_secret=$(openssl rand -hex 16)
    
    cat >> "$env_file" <<EOF

# Broadcasting (Reverb)
BROADCAST_CONNECTION=reverb
REVERB_APP_ID=${reverb_app_id}
REVERB_APP_KEY=${reverb_app_key}
REVERB_APP_SECRET=${reverb_app_secret}
REVERB_HOST="reverb"
REVERB_PORT=8080
REVERB_SCHEME=http

VITE_REVERB_APP_KEY="${reverb_app_key}"
VITE_REVERB_HOST="${DOMAIN_NAME}"
VITE_REVERB_PORT=443
VITE_REVERB_SCHEME=https
EOF
    
    # Google OAuth (if configured)
    if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
        cat >> "$env_file" <<EOF

# Google OAuth
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
GOOGLE_REDIRECT_URI=https://${DOMAIN_NAME}/auth/google/callback
GOOGLE_ADMIN_EMAILS="${GOOGLE_ADMIN_EMAILS:-}"
GOOGLE_ALLOWED_DOMAINS="${GOOGLE_ALLOWED_DOMAINS:-}"
EOF
    fi
    
    # Trust Cloudflare proxies
    echo "TRUSTED_PROXIES=*" >> "$env_file"
    
    log_success "Laravel environment configured"
}

install_modules() {
    log_step "Installing Modules"

    if [ ${#MODULES_TO_INSTALL[@]} -eq 0 ]; then
        log_info "No modules configured to install."
        return
    fi

    # Ensure Modules directory exists
    mkdir -p "$DEFAULT_INSTALL_DIR/src/Modules"

    for module_entry in "${MODULES_TO_INSTALL[@]}"; do
        local name=$(echo "$module_entry" | cut -d'|' -f1)
        local repo_url=$(echo "$module_entry" | cut -d'|' -f2)
        local token_var=$(echo "$module_entry" | cut -d'|' -f3)

        if [ -z "$name" ] || [ -z "$repo_url" ]; then
            log_warning "Invalid module entry: $module_entry"
            continue
        fi

        local target_dir="$DEFAULT_INSTALL_DIR/src/Modules/$name"

        if [ -d "$target_dir" ]; then
            log_info "Module $name already exists. Updating..."
            cd "$target_dir"
            git fetch origin
            git pull
            cd - >/dev/null
            continue
        fi

        log_info "Installing module: $name"
        
        local final_url="$repo_url"
        if [ -n "$token_var" ]; then
            local token_val="${!token_var:-}"
            
            if [ -n "$token_val" ]; then
                # Inject token into URL for HTTPS
                local clean_url="${repo_url#https://}"
                final_url="https://oauth2:${token_val}@${clean_url}"
            else
                log_warning "Token variable $token_var is not set or empty."
            fi
        fi

        git clone "$final_url" "$target_dir" || log_error "Failed to clone $name"
    done
    
    log_success "Modules installed"
}

patch_modules() {
    log_step "Patching Modules for Compatibility"
    
    # Patches have been moved to the modules themselves.
    # This function is kept as a placeholder for future compatibility fixes if needed.
    
    log_success "Modules patched (Skipped - fixes applied to source)"
}

patch_database_seeder() {
    log_step "Patching DatabaseSeeder"
    local seeder_file="$DEFAULT_INSTALL_DIR/src/database/seeders/DatabaseSeeder.php"
    # No patches required for current modules
    log_success "DatabaseSeeder patched"
}

setup_storage_permissions() {
    log_step "Setting Up Storage & Permissions"
    
    # Clear potential cache files
    rm -f src/bootstrap/cache/*.php 2>/dev/null || true
    rm -rf src/storage/framework/cache/* 2>/dev/null || true
    rm -rf src/storage/framework/views/* 2>/dev/null || true
    rm -rf src/storage/framework/sessions/* 2>/dev/null || true
    
    # Create directories
    mkdir -p src/storage/framework/{cache,sessions,views,testing}
    mkdir -p src/storage/logs
    mkdir -p src/bootstrap/cache
    
    # Set permissive permissions for Docker
    chmod -R 777 src/storage src/bootstrap/cache
    
    log_success "Storage directories ready"
}

build_and_launch_containers() {
    log_step "Building & Launching Docker Containers"
    
    log_info "Building application image (with BuildKit)..."
    docker compose build app
    
    log_info "Starting all services..."
    docker compose up -d
    
    log_success "Containers launched"
}

wait_for_database() {
    log_step "Waiting for Database"
    
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T db mysqladmin ping -h localhost -u root -p"${DB_ROOT_PASS}" >/dev/null 2>&1; then
            log_success "Database is ready"
            return 0
        fi
        
        ((attempt++))
        echo -ne "\r${CYAN}⏳${NC} Attempt $attempt/$max_attempts..."
        sleep 2
    done
    
    log_error "Database failed to become ready"
    return 1
}

install_dependencies() {
    log_step "Installing Dependencies"
    
    log_info "Installing Composer dependencies..."
    docker compose exec -T -u root app composer install --no-dev --optimize-autoloader
    docker compose exec -T -u root app chown -R www-data:www-data /var/www/html/vendor /var/www/html/composer.lock
    
    log_info "Installing NPM dependencies..."
    docker compose exec -T -u root app npm install
    
    log_info "Building frontend assets..."
    docker compose exec -T -u root app npm run build
    
    log_success "Dependencies installed"
}

finalize_installation() {
    log_step "Finalizing Installation"
    
    log_info "Generating application key..."
    docker compose exec -T app php artisan key:generate
    
    if [ "$REUSE_DB" = true ]; then
        log_info "Running migrations on existing database..."
        docker compose exec -T app php artisan migrate --force
    else
        log_info "Installing FreeScout..."
        docker compose exec -T app php artisan freescout:install \
            --force \
            --email="$ADMIN_EMAIL" \
            --password="$ADMIN_PASS" \
            --first_name="Admin" \
            --last_name="User"
    fi
    
    log_info "Running module migrations..."
    docker compose exec -T app php artisan module:migrate --force
    
    log_info "Seeding KnowledgeBase content..."
    echo '
$modules = Module::all();
foreach($modules as $module) {
    if (!$module->isEnabled()) continue;
    $seeder = "Modules\\" . $module->getName() . "\\Database\\Seeders\\KnowledgeBaseSeeder";
    if (class_exists($seeder)) {
        echo "Seeding " . $module->getName() . "...\n";
        Artisan::call("db:seed", ["--class" => $seeder, "--force" => true]);
    }
}
' | docker compose exec -T app php artisan tinker

    log_info "Seeding themes..."
    docker compose exec -T app php artisan db:seed --class=ThemeSeeder --force
    
    log_success "Installation finalized"
}

show_completion_message() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}║                 ${GREEN}✓${NC} DEPLOYMENT COMPLETE ${GREEN}✓${NC}                     ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Access Information:${NC}"
    echo -e "  URL:   ${GREEN}https://$DOMAIN_NAME${NC}"
    echo -e "  Email: ${GREEN}$ADMIN_EMAIL${NC}"
    echo -e "  Pass:  ${GREEN}$ADMIN_PASS${NC}"
    echo ""
    echo -e "${CYAN}Cloudflare Tunnel Configuration:${NC}"
    echo -e "  1. Go to Cloudflare Zero Trust → Networks → Tunnels"
    echo -e "  2. Click your tunnel → Configure → Public Hostname"
    echo -e "  3. Add/Edit Public Hostname:"
    echo -e "     ${YELLOW}Service Type:${NC} HTTPS"
    echo -e "     ${YELLOW}URL:${NC}          https://app:8080"
    echo -e "     ${YELLOW}TLS Verify:${NC}   ${RED}Disabled${NC} (toggle 'No TLS Verify' ON)"
    echo -e "     ${YELLOW}Origin Name:${NC}  $DOMAIN_NAME"
    echo ""
    
    if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
        echo -e "${CYAN}Google OAuth Setup:${NC}"
        echo -e "  Add this redirect URI to Google Cloud Console:"
        echo -e "  ${GREEN}https://$DOMAIN_NAME/auth/google/callback${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}Next Steps:${NC}"
    echo -e "  • Update:    ${YELLOW}cd $DEFAULT_INSTALL_DIR && ./update.sh${NC}"
    echo -e "  • View logs: ${YELLOW}docker compose logs -f${NC}"
    echo -e "  • Stop:      ${YELLOW}docker compose down${NC}"
    echo -e "  • Emergency: ${YELLOW}https://localhost:8080${NC} (accept cert warning)"
    echo ""
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    show_banner
    preflight_checks
    load_or_create_config
    
    # Set defaults
    DB_ROOT_PASS="${DB_ROOT_PASS:-$(openssl rand -hex 16)}"
    DB_USER="${DB_USER:-freescout}"
    DB_PASS="${DB_PASS:-$(openssl rand -hex 16)}"
    DB_NAME="${DB_NAME:-freescout}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@scotchmcdonald.dev}"
    ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -hex 12)}"
    
    check_existing_installation

    if [ "$INTERACTIVE" = true ]; then
        interactive_setup
    fi
    
    # Validate required variables
    validate_required_var "DOMAIN_NAME" "${DOMAIN_NAME:-}"
    validate_required_var "CF_TUNNEL_TOKEN" "${CF_TUNNEL_TOKEN:-}"
    
    # Execute deployment
    decommission_existing
    setup_directories
    generate_dockerfile
    generate_nginx_config
    generate_ssl_certificates
    generate_docker_env
    generate_docker_compose
    generate_update_script
    clone_or_update_repo
    configure_laravel
    install_modules
    patch_modules
    patch_database_seeder
    setup_storage_permissions
    build_and_launch_containers
    wait_for_database
    install_dependencies
    finalize_installation
    
    # Cleanup
    log_info "Pruning unused Docker resources..."
    docker image prune -f >/dev/null 2>&1 || true
    
    show_completion_message
}

# Run main function
main "$@"
