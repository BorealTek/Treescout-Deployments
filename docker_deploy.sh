#!/usr/bin/env bash

#===============================================================================
# FreeScout Docker Deployer (Ubuntu/Linux)
# 
# Enterprise-grade deployment script with:
# - Bash strict mode (set -euo pipefail)
# - Trap handlers for cleanup
# - Progress indicators
# - Pre-flight validation
# - Docker BuildKit optimization
# - Comprehensive error handling
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# GLOBALS & CONFIGURATION
#===============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO="https://github.com/Scotchmcdonald/freescout.git"
DEFAULT_BRANCH="laravel-11-foundation"
DEFAULT_INSTALL_DIR="/opt/freescout-docker"
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
REUSE_DB=true  # Optimistic default - decommission_existing will handle gracefully if no DB exists
ADMIN_PASS_PRESERVED=false
CLEANUP_NEEDED=false

# Default Modules
MODULES_TO_INSTALL=(
    "Action1|https://github.com/BorealTek/Action1-Module.git|REPO_TOKEN|main"
    "Alerts|https://github.com/BorealTek/Alerts-Module.git|REPO_TOKEN|main"
    "AssetManagement|https://github.com/BorealTek/AssetManagement-Module.git|REPO_TOKEN|main"
    "ClientPortal|https://github.com/BorealTek/ClientPortal-Module.git|REPO_TOKEN|main"
    "ContractManager|https://github.com/BorealTek/ContractManager-Module.git|REPO_TOKEN|main"
    "Crm|https://github.com/BorealTek/Crm-Module.git|REPO_TOKEN|main"
    "DevFeedback|https://github.com/BorealTek/DevFeedback-Module.git|REPO_TOKEN|main"
    "EmailMigration|https://github.com/BorealTek/EmailMigration-Module.git|REPO_TOKEN|main"
    "GoogleAdmin|https://github.com/BorealTek/GoogleAdmin-Module.git|REPO_TOKEN|main"
    "KnowledgeBase|https://github.com/BorealTek/KnowledgeBase-Module.git|REPO_TOKEN|main"
    "PIB|https://github.com/BorealTek/PIB-Module.git|REPO_TOKEN|main"
    "Payment|https://github.com/BorealTek/Payment-Module.git|REPO_TOKEN|main"
    "SoftwareSubscriptions|https://github.com/BorealTek/SoftwareSubscriptions-Module.git|REPO_TOKEN|main"
    "WidgetRegistry|https://github.com/BorealTek/WidgetRegistry-Module.git|REPO_TOKEN|main"
)

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
        # Add cleanup logic if needed
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
        # Ensure read has a variable to avoid exit code 1 on empty input in strict mode
        read -rp "$1" "$2" || true
    elif [ -c /dev/tty ]; then
        # Prompt to stderr
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
    
    # Check if running as root or with sudo access
    if [ "$(id -u)" -eq 0 ]; then
        if ! command_exists sudo; then
            sudo() { "$@"; }
        fi
    else
        if ! command_exists sudo; then
            log_error "This script requires sudo access"
            exit 1
        fi
    fi
    
    # Check for required tools
    local required_tools=("git" "curl" "openssl")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_warning "Installing missing tools: ${missing_tools[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing_tools[@]}"
    fi
    
    # Check Docker
    if ! command_exists docker; then
        log_warning "Docker not found. Installing..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sudo sh /tmp/get-docker.sh
        rm /tmp/get-docker.sh
    fi
    
    # Verify Docker is running
    log_info "Verifying Docker daemon status..."
    if ! sudo docker info >/dev/null 2>&1; then
        log_error "Docker is installed but not running"
        log_info "Try starting it with: sudo systemctl start docker"
        exit 1
    fi

    # Check System Resources
    log_info "Checking system resources..."
    if [ -f /proc/meminfo ]; then
        local total_mem
        total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        # Check for at least 2GB RAM
        if [ "$total_mem" -lt 2000000 ]; then
            log_warning "System memory is below 2GB. Performance may be degraded."
            log_warning "Recommended: 4GB+ for production."
            sleep 2
        else 
            log_success "System memory check passed"
        fi
    fi

    # Enable BuildKit for faster builds
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
        # Fix ownership if needed
        if [ -n "${SUDO_USER:-}" ] && [ "$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)" = "root" ]; then
            chown "$SUDO_USER:$(id -g "$SUDO_USER")" "$CONFIG_FILE"
        fi
        
        log_success "Configuration file found: $CONFIG_FILE"
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"

        # Sync config variables to internal variables
        if [ -n "${GIT_REPO_URL:-}" ]; then DEFAULT_REPO="$GIT_REPO_URL"; fi
        if [ -n "${GIT_BRANCH:-}" ]; then DEFAULT_BRANCH="$GIT_BRANCH"; fi
        
        # Ensure array exists if not defined in config
        if [ -z "${MODULES_TO_INSTALL+x}" ]; then
            MODULES_TO_INSTALL=()
        fi
    else
        log_info "No configuration file found. Starting setup wizard..."
    fi
}

interactive_menu() {
    local choice
    while true; do
        # show_banner - removed to prevent flickering
        echo ""
        echo -e "  ${COLOR_PRIMARY}[1]${NC} Deploy to Docker (Fresh)"
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
                     sudo docker compose logs -f app
                fi
                ;;
            0) exit 0 ;;
            *) log_error "Invalid selection" ; sleep 1 ;;
        esac
    done
}

save_current_config() {
    log_info "Saving configuration to $CONFIG_FILE..."
    
    # Generate array string for MODULES_TO_INSTALL
    local modules_str=""
    if [ -n "${MODULES_TO_INSTALL+x}" ]; then
        for mod in "${MODULES_TO_INSTALL[@]}"; do
            modules_str+="    \"$mod\""$'\n'
        done
    fi

    cat > "$CONFIG_FILE" <<EOF
#===============================================================================
# FreeScout Deployment Configuration
# Generated on $(date)
#===============================================================================

# Installation Settings
GIT_REPO_URL="${GIT_REPO_URL:-$DEFAULT_REPO}"
GIT_BRANCH="${GIT_BRANCH:-$DEFAULT_BRANCH}"
DEFAULT_INSTALL_DIR="${DEFAULT_INSTALL_DIR:-/opt/freescout-docker}"

# Network Settings
DOMAIN_NAME="${DOMAIN_NAME:-}"
DOCKER_SUBNET="${DOCKER_SUBNET:-}"

# Database Settings
DB_ROOT_PASS="${DB_ROOT_PASS:-}"
DB_USER="${DB_USER:-freescout}"
DB_PASS="${DB_PASS:-}"
DB_NAME="${DB_NAME:-freescout}"

# Admin User
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_PASS="${ADMIN_PASS:-}"

# Additional Users (Optional)
AGENT_EMAIL="${AGENT_EMAIL:-}"
AGENT_PASS="${AGENT_PASS:-}"
FINANCE_EMAIL="${FINANCE_EMAIL:-}"
FINANCE_PASS="${FINANCE_PASS:-}"
REPORTER_EMAIL="${REPORTER_EMAIL:-}"
REPORTER_PASS="${REPORTER_PASS:-}"

# Google OAuth (Optional)
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
GOOGLE_ADMIN_EMAILS="${GOOGLE_ADMIN_EMAILS:-}"
GOOGLE_ALLOWED_DOMAINS="${GOOGLE_ALLOWED_DOMAINS:-}"

# Mailbox Auto-Provisioning (Optional)
MAILBOX_EMAIL="${MAILBOX_EMAIL:-}"
MAILBOX_NAME="${MAILBOX_NAME:-}"
MAILBOX_IMAP_HOST="${MAILBOX_IMAP_HOST:-}"
MAILBOX_IMAP_PORT="${MAILBOX_IMAP_PORT:-993}"
MAILBOX_IMAP_USER="${MAILBOX_IMAP_USER:-}"
MAILBOX_IMAP_PASS="${MAILBOX_IMAP_PASS:-}"
MAILBOX_SMTP_HOST="${MAILBOX_SMTP_HOST:-}"
MAILBOX_SMTP_PORT="${MAILBOX_SMTP_PORT:-587}"
MAILBOX_SMTP_USER="${MAILBOX_SMTP_USER:-}"
MAILBOX_SMTP_PASS="${MAILBOX_SMTP_PASS:-}"

# Sample Data Seeding
SEED_SAMPLE_DATA=${SEED_SAMPLE_DATA:-false}

# Define your access tokens
export REPO_TOKEN="${REPO_TOKEN:-}"

# Configure modules to install
MODULES_TO_INSTALL=(
${modules_str})

EOF
    
    if [ -n "${SUDO_USER:-}" ]; then
        chown "$SUDO_USER:$(id -g "$SUDO_USER")" "$CONFIG_FILE"
    fi
    log_success "Configuration saved."
}


interactive_menu() {
    local choice
    while true; do
        show_banner
        echo -e "  ${COLOR_PRIMARY}[1]${NC} Deploy Fresh (Standard)"
        echo -e "  ${COLOR_PRIMARY}[2]${NC} Update Existing Installation"
        echo -e "  ${COLOR_PRIMARY}[3]${NC} Manage Modules"
        echo -e "  ${COLOR_PRIMARY}[4]${NC} View Logs"
        echo -e "  ${COLOR_PRIMARY}[0]${NC} Exit"
        echo ""
        safe_read "  Enter Selection: " choice
        
        case $choice in
            1) return 0 ;;
            2) 
                if [ -f "./update.sh" ]; then
                    bash ./update.sh
                    safe_read "Press Enter to continue..." dummy
                else
                    log_error "Update script not found."
                    sleep 2
                fi
                ;;
            3)
                log_info "Module management is automated via deploy.conf"
                sleep 2
                ;;
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
    if [ "$INTERACTIVE" = true ] && [ -z "${1:-}" ]; then
        interactive_menu
    fi

    # Check for existing config to allow skipping detailed setup
    if [ -n "${DOMAIN_NAME:-}" ] && [ -n "${DOCKER_SUBNET:-}" ]; then
        echo ""
        log_info "Configuration loaded from $CONFIG_FILE"
        echo -e "  Domain: ${GREEN}$DOMAIN_NAME${NC}"
        echo -e "  Subnet: ${GREEN}$DOCKER_SUBNET${NC}"
        safe_read "Use these settings? [Y/n] " use_defaults
        if [[ "${use_defaults:-Y}" =~ ^[Yy]$ ]]; then
             # Check for token
             if [ -z "${REPO_TOKEN:-}" ]; then
                 safe_read "Enter GitHub Token (for modules): " REPO_TOKEN
                 export REPO_TOKEN
                 save_current_config
             fi
             return
        fi
    fi

    log_step "Interactive Setup"
    
    # Repository configuration
    local current_repo="${GIT_REPO_URL:-$DEFAULT_REPO}"
    echo -e "Repository URL: ${YELLOW}$current_repo${NC}"
    safe_read "Press ENTER to confirm, or paste a new URL: " input_repo
    GIT_REPO_URL="${input_repo:-$current_repo}"
    
    local current_branch="${GIT_BRANCH:-$DEFAULT_BRANCH}"
    echo -e "Branch: ${YELLOW}$current_branch${NC}"
    safe_read "Press ENTER to confirm, or type a new branch: " input_branch
    GIT_BRANCH="${input_branch:-$current_branch}"
    echo ""
    
    # Network configuration
    log_info "Network Configuration"
    local current_domain="${DOMAIN_NAME:-}" 
    if [ -n "$current_domain" ]; then
        echo -e "Domain Name: ${YELLOW}$current_domain${NC}"
        safe_read "Press ENTER to confirm, or type new domain: " input_domain
        DOMAIN_NAME="${input_domain:-$current_domain}"
    else
        while [ -z "${DOMAIN_NAME:-}" ]; do
            safe_read "Domain Name: " DOMAIN_NAME
        done
    fi
    
    local current_subnet="${DOCKER_SUBNET:-}"
    if [ -n "$current_subnet" ]; then
         echo -e "Docker Subnet: ${YELLOW}$current_subnet${NC}"
         safe_read "Press ENTER to confirm, or type new: " input_subnet
         DOCKER_SUBNET="${input_subnet:-$current_subnet}"
    else
        while [ -z "${DOCKER_SUBNET:-}" ]; do
            safe_read "Docker Subnet (CIDR, e.g. 192.168.220.0/24): " DOCKER_SUBNET
        done
    fi
    echo ""

    # Access Tokens
    log_info "Authentication"
    local current_token="${REPO_TOKEN:-}"
    if [ -n "$current_token" ]; then
        echo -e "Repo Token: ${YELLOW}********${NC}"
    else
        echo -e "Repo Token: ${YELLOW}<not set>${NC}"
    fi
    safe_read "Press ENTER to keep, or paste new token (required for modules): " input_token
    if [ -n "$input_token" ]; then
        REPO_TOKEN="$input_token"
    fi
    export REPO_TOKEN="${REPO_TOKEN:-}"
    echo ""
    
    # Google OAuth (optional)
    log_info "Google OAuth (Optional)"
    local current_client_id="${GOOGLE_CLIENT_ID:-}"
    echo -e "Google Client ID: ${YELLOW}${current_client_id:-<not set>}${NC}"
    safe_read "Enter Client ID (or ENTER to skip/keep): " input_client_id
    
    if [ -n "$input_client_id" ]; then
         GOOGLE_CLIENT_ID="$input_client_id"
    fi
    
    if [ -n "$GOOGLE_CLIENT_ID" ]; then
        safe_read "Google Client Secret [${GOOGLE_CLIENT_SECRET:0:5}...]: " input_secret
        GOOGLE_CLIENT_SECRET="${input_secret:-$GOOGLE_CLIENT_SECRET}"
        
        safe_read "Google Admin Emails [${GOOGLE_ADMIN_EMAILS}]: " input_emails
        GOOGLE_ADMIN_EMAILS="${input_emails:-$GOOGLE_ADMIN_EMAILS}"
        
        safe_read "Allowed Domains [${GOOGLE_ALLOWED_DOMAINS}]: " input_domains
        GOOGLE_ALLOWED_DOMAINS="${input_domains:-$GOOGLE_ALLOWED_DOMAINS}"
    fi
    echo ""
    
    # Sample data seeding
    log_info "Sample Data Seeding"
    if [ "$REUSE_DB" = true ]; then
        log_warning "WARNING: Reusing existing database"
        log_warning "Seeding may cause conflicts or duplicates"
    fi
    
    local default_seed="N"
    if [ "$SEED_SAMPLE_DATA" = true ]; then default_seed="Y"; fi
    
    safe_read "Seed sample data (Mailboxes, Users, Conversations)? [y/N] (Current: $default_seed) " input_seed
    if [ -z "$input_seed" ]; then
         : # Keep current
    elif [[ "$input_seed" =~ ^[Yy]$ ]]; then
        SEED_SAMPLE_DATA=true
    else
        SEED_SAMPLE_DATA=false
    fi
    echo ""

    # Save Config
    safe_read "Save this configuration to $CONFIG_FILE? [Y/n] " save_opt
    save_opt="${save_opt:-Y}"
    if [[ "$save_opt" =~ ^[Yy]$ ]]; then
        save_current_config
    fi
    
    # Configuration summary
    echo "────────────────────────────────────────────────────────────"
    echo -e "CONFIGURATION SUMMARY:"
    echo -e "  Repository: ${GREEN}$GIT_REPO_URL${NC}"
    echo -e "  Branch:     ${GREEN}$GIT_BRANCH${NC}"
    echo -e "  Domain:     ${GREEN}$DOMAIN_NAME${NC}"
    if [ -n "$GOOGLE_CLIENT_ID" ]; then
        echo -e "  Google:     ${GREEN}Configured${NC}"
    else
        echo -e "  Google:     ${YELLOW}Skipped${NC}"
    fi
    echo "────────────────────────────────────────────────────────────"
    echo ""
    safe_read "Press ENTER to start deployment (or Ctrl+C to cancel)..." dummy
}

check_existing_installation() {
    local existing_env="$DEFAULT_INSTALL_DIR/.env"
    
    if [ -f "$existing_env" ]; then
        log_warning "Existing installation found at $DEFAULT_INSTALL_DIR"
        
        if [ -t 0 ]; then
            echo ""
            echo "1) Reuse existing database (Keep data)"
            echo "2) Overwrite database (DESTROY ALL DATA)"
            read -rp "Select [1-2]: " reuse_opt || true
            
            case "$reuse_opt" in
                2)
                    REUSE_DB=false
                    log_error "WARNING: Existing database will be destroyed!"
                    ;;
                *)
                    REUSE_DB=true
                    ;;
            esac
            EXISTING_DECISION_MADE=true
        else
            # Non-interactive: default to safe option
            REUSE_DB=true
            EXISTING_DECISION_MADE=true
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
            ADMIN_PASS_PRESERVED=true
        fi
    fi
}

#===============================================================================
# DEPLOYMENT FUNCTIONS
#===============================================================================

decommission_existing() {
    if [ -d "$DEFAULT_INSTALL_DIR" ] && [ -f "$DEFAULT_INSTALL_DIR/docker-compose.yml" ]; then
        log_step "Decommissioning Existing Installation"
        
        cd "$DEFAULT_INSTALL_DIR"
        
        # Always prompt for what to do with existing deployment
        log_warning "Existing deployment detected!"
        
        if [ "${EXISTING_DECISION_MADE:-false}" = true ]; then
            log_info "Using previous selection (Reuse Database: $REUSE_DB)"
        else
            echo ""
            echo -e "${YELLOW}What would you like to do?${NC}"
            echo "  1) Reuse existing data (keep database and volumes)"
            echo "  2) Nuke everything (fresh install, all data lost)"
            echo "  3) Cancel deployment"
            echo ""
            safe_read "Enter choice [1-3]: " choice
            
            case $choice in
                1) REUSE_DB=true ;;
                2) REUSE_DB=false ;;
                3) exit 0 ;;
                *) REUSE_DB=true ;;
            esac
        fi
        
        if [ "$REUSE_DB" = true ]; then
            log_info "Reusing existing data - stopping containers only..."
            sudo docker compose down 2>/dev/null || true
        else
            log_warning "Nuking everything - all data will be lost!"
            
            if [ "${EXISTING_DECISION_MADE:-false}" = false ]; then
                safe_read "Type 'yes' to confirm: " confirm
                if [ "$confirm" != "yes" ]; then
                     log_error "Aborted by user."
                     exit 1
                fi
            fi

            log_info "Stopping and removing containers and volumes..."
            sudo docker compose down -v 2>/dev/null || true
            log_info "Removing source code directory..."
            sudo rm -rf src
            log_success "Everything nuked"
        fi
        
        log_info "Pruning unused networks..."
        sudo docker network prune -f >/dev/null 2>&1 || true
        
        log_success "Decommissioning complete"
    else
        # No existing installation - treat as fresh install regardless of REUSE_DB
        if [ "$REUSE_DB" = true ]; then
            log_info "No existing installation found - proceeding with fresh install"
            REUSE_DB=false
        fi
    fi
}

setup_directories() {
    log_step "Setting Up Directory Structure"
    
    sudo mkdir -p "$DEFAULT_INSTALL_DIR/nginx"
    sudo chown -R "$USER:$USER" "$DEFAULT_INSTALL_DIR"
    cd "$DEFAULT_INSTALL_DIR"
    
    log_success "Directories created"
}

generate_dockerfile() {
    log_step "Generating Dockerfile"
    
    cat > Dockerfile <<'EOF'
FROM serversideup/php:8.3-fpm-nginx

USER root

# Install system dependencies, cron, Node.js 22.x, MySQL client, and utilities for Composer
RUN apt-get update && apt-get install -y gnupg curl ca-certificates unzip git cron default-mysql-client && \
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
    install-php-extensions imap gmp soap intl bcmath gd redis sockets pcntl zip && \
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
REDIS_PASSWORD=null
REDIS_PORT=6379
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID:-}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET:-}
GOOGLE_REDIRECT_URI=https://${DOMAIN_NAME}/auth/google/callback
EOF

    # Pass through any environment variables ending in _TOKEN, _KEY, or _SECRET
    # This allows passing git access tokens for modules
    env | grep -E '(_TOKEN|_KEY|_SECRET)=' | grep -vE '^(DB_|APP_|REDIS_|GOOGLE_|REVERB_)' >> .env || true
    
    log_success "Docker .env generated"
}

generate_docker_compose() {
    log_step "Generating Docker Compose Configuration"
    
    # Detect Docker socket GID for permission handling
    # This allows the app container to communicate with Docker daemon
    local DOCKER_GID
    if [ -S "/var/run/docker.sock" ]; then
        DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "999")
        log_info "Docker socket GID detected: $DOCKER_GID"
    else
        DOCKER_GID="999"
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
      - "443:8080"  # HTTPS on standard port
    environment:
      - PUID=33
      - PGID=33
      # Docker GID for socket access (enables sibling container spawning)
      - DOCKER_GID=${DOCKER_GID}
      # Host path for DooD volume mounting
      - HOST_SRC_PATH=${PWD}/src
      - PHP_MEMORY_LIMIT=512M
      - PHP_OPCACHE_ENABLE=1
      - PHP_POST_MAX_SIZE=20M
      - PHP_UPLOAD_MAX_FILESIZE=20M
    volumes:
      - ./src:/var/www/html
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf
      - ./nginx/ssl:/etc/nginx/ssl
      # DOCKER-OUTSIDE-OF-DOCKER (Sibling Container Architecture)
      # Mount Docker socket to allow app container to spawn sibling containers
      # Used by EmailMigration module for spinning up temporary test mail servers
      # This enables "docker run" commands from within the app container
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - fs-net
    healthcheck:
      test: ["CMD", "curl", "-fk", "https://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  db:
    image: mariadb:10.6
    restart: unless-stopped
    # Use mariadbd with SSL explicitly disabled to fix "SSL is required" error
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW --innodb-file-per-table=1 --skip-innodb-read-only-compressed --skip-ssl
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
    command: >
      /bin/sh -c '
      echo "* * * * * cd /var/www/html && php artisan schedule:run >> /var/log/cron.log 2>&1" | crontab - &&
      echo "Starting cron..." &&
      cron -f
      '
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
    ports:
      - "6001:8080"
    volumes:
      - ./src:/var/www/html
    depends_on:
      - app
      - db
      - redis
    networks:
      - fs-net

networks:
  fs-net:
    driver: bridge
    ipam:
      config:
        - subnet: ${DOCKER_SUBNET}

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

echo "🔄 Updating FreeScout (${GIT_BRANCH})..."

cd src
git fetch origin
git checkout ${GIT_BRANCH}
git pull origin ${GIT_BRANCH}
cd ..

echo "🐳 Rebuilding containers..."
sudo docker compose build app
sudo docker compose up -d

echo "🗄️  Running migrations..."
sudo docker compose exec -T app php artisan migrate --force

echo "📦 Installing dependencies..."
sudo docker compose exec -e COMPOSER_PROCESS_TIMEOUT=2000 -T app composer update --no-dev --optimize-autoloader
sudo docker compose exec -T app npm install
sudo docker compose exec -T app npm run build

echo "🧹 Clearing caches..."
sudo docker compose exec -T app php artisan optimize:clear
sudo docker compose exec -T app php artisan freescout:clear-cache

echo "✅ Update complete!"
EOF
    
    chmod +x update.sh
    log_success "Update script generated"
}

clone_or_update_repo() {
    log_step "Cloning/Updating Repository"
    
    if [ -d "$DEFAULT_INSTALL_DIR/src" ]; then
        log_info "Source folder exists. Syncing..."
        
        cd "$DEFAULT_INSTALL_DIR/src"
        git config --global --add safe.directory "$DEFAULT_INSTALL_DIR/src"
        git remote set-url origin "$GIT_REPO_URL"
        git fetch origin
        
        if ! git checkout "$GIT_BRANCH" 2>/dev/null; then
            git checkout -b "$GIT_BRANCH" "origin/$GIT_BRANCH"
        fi
        
        if ! git pull origin "$GIT_BRANCH"; then
            log_error "Git pull failed! Local changes detected."
            
            if [ -t 0 ]; then
                echo ""
                echo "1) Discard local changes (git reset --hard)"
                echo "2) Nuke & Re-clone (Delete src and download fresh)"
                echo "3) Exit and fix manually"
                read -rp "Select [1-3]: " git_opt
                
                case "$git_opt" in
                    1)
                        log_info "Resetting to origin/$GIT_BRANCH..."
                        git reset --hard "origin/$GIT_BRANCH"
                        ;;
                    2)
                        log_warning "Nuking source directory..."
                        cd ..
                        sudo rm -rf src
                        git clone -b "$GIT_BRANCH" "$GIT_REPO_URL" src
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
        log_info "Cloning branch '$GIT_BRANCH'..."
        git clone -b "$GIT_BRANCH" "$GIT_REPO_URL" src
    fi
    
    log_success "Repository ready"
}

configure_laravel() {
    log_step "Configuring Laravel Environment"
    
    cp "$DEFAULT_INSTALL_DIR/src/.env.example" "$DEFAULT_INSTALL_DIR/src/.env"
    
    local env_file="$DEFAULT_INSTALL_DIR/src/.env"
    
    # Database configuration
    sed -i "s/APP_NAME=Laravel/APP_NAME=\"BorealTek Treescout\"/g" "$env_file"
    sed -i "s/DB_CONNECTION=sqlite/DB_CONNECTION=mysql/g" "$env_file"
    sed -i "s/# DB_HOST=127.0.0.1/DB_HOST=db/g" "$env_file"
    sed -i "s/# DB_PORT=3306/DB_PORT=3306/g" "$env_file"
    sed -i "s/# DB_DATABASE=laravel/DB_DATABASE=$DB_NAME/g" "$env_file"
    sed -i "s/# DB_USERNAME=root/DB_USERNAME=$DB_USER/g" "$env_file"
    sed -i "s/# DB_PASSWORD=/DB_PASSWORD=$DB_PASS/g" "$env_file"
    
    # App URL and caching  
    sed -i "s|APP_URL=http://localhost|APP_URL=https://$DOMAIN_NAME|g" "$env_file"
    sed -i "s/CACHE_STORE=database/CACHE_STORE=redis/g" "$env_file"
    sed -i "s/SESSION_DRIVER=database/SESSION_DRIVER=redis/g" "$env_file"
    sed -i "s/REDIS_HOST=127.0.0.1/REDIS_HOST=redis/g" "$env_file"
    
    # Admin credentials
    cat >> "$env_file" <<EOF

# Admin Credentials
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD="${ADMIN_PASS}"
ADMIN_FIRST_NAME="${ADMIN_FIRST_NAME:-System}"
ADMIN_LAST_NAME="${ADMIN_LAST_NAME:-Administrator}"

# Agent User
AGENT_EMAIL="${AGENT_EMAIL:-agent@example.com}"
AGENT_PASSWORD="${AGENT_PASS:-agent123456789}"
AGENT_FIRST_NAME="${AGENT_FIRST_NAME:-Support}"
AGENT_LAST_NAME="${AGENT_LAST_NAME:-Agent}"

# Finance User
FINANCE_EMAIL="${FINANCE_EMAIL:-finance@example.com}"
FINANCE_PASSWORD="${FINANCE_PASS:-finance123456789}"
FINANCE_FIRST_NAME="${FINANCE_FIRST_NAME:-Finance}"
FINANCE_LAST_NAME="${FINANCE_LAST_NAME:-Manager}"

# Reporter User
REPORTER_EMAIL="${REPORTER_EMAIL:-reporter@example.com}"
REPORTER_PASSWORD="${REPORTER_PASS:-reporter123456789}"
REPORTER_FIRST_NAME="${REPORTER_FIRST_NAME:-Report}"
REPORTER_LAST_NAME="${REPORTER_LAST_NAME:-Viewer}"
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
    
    log_success "Laravel environment configured"
}

setup_storage_permissions() {
    log_step "Setting Up Storage & Permissions"
    
    mkdir -p src/storage/framework/{cache,sessions,views}
    mkdir -p src/storage/logs
    mkdir -p src/storage/app/public
    mkdir -p src/bootstrap/cache
    mkdir -p src/Modules
    mkdir -p src/public/modules
    
    sudo chown -R 33:33 src
    
    log_success "Storage directories ready"
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
        local branch=$(echo "$module_entry" | cut -d'|' -f4)

        if [ -z "$name" ] || [ -z "$repo_url" ]; then
            log_warning "Invalid module entry: $module_entry"
            continue
        fi

        local target_dir="$DEFAULT_INSTALL_DIR/src/Modules/$name"

        if [ -d "$target_dir" ]; then
            log_info "Module $name already exists. Updating..."
            cd "$target_dir"
            git fetch origin
            if [ -n "$branch" ]; then
                git checkout "$branch" || git checkout -b "$branch" "origin/$branch"
                git pull origin "$branch"
            else
                git pull
            fi
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

        if [ -n "$branch" ]; then
            git clone -b "$branch" "$final_url" "$target_dir" || log_error "Failed to clone $name"
        else
            git clone "$final_url" "$target_dir" || log_error "Failed to clone $name"
        fi
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

build_and_launch_containers() {
    log_step "Building & Launching Docker Containers"
    
    log_info "Stopping any existing containers..."
    sudo docker compose down --remove-orphans 2>/dev/null || true
    
    # Check and free ports 80 and 443
    for port in 80 443; do
        if sudo ss -lptn "sport = :$port" | grep -q ":$port"; then
            log_warning "Port $port is in use. Attempting to release..."
            if command_exists fuser; then
                sudo fuser -k -n tcp "$port" >/dev/null 2>&1 || true
            else
                # Fallback to kill if fuser is missing
                pids=$(sudo ss -lptn "sport = :$port" | grep -o 'pid=[0-9]*' | cut -d= -f2)
                if [ -n "$pids" ]; then
                    echo "$pids" | xargs -r sudo kill -9 >/dev/null 2>&1 || true
                fi
            fi
        fi
    done
    
    log_info "Building application image (with BuildKit)..."
    sudo docker compose build app
    
    log_info "Starting all services..."
    sudo docker compose up -d
    
    log_success "Containers launched"
}

wait_for_database() {
    log_step "Waiting for Database"
    
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if sudo docker compose exec -T db mysqladmin ping -h localhost -u root -p"${DB_ROOT_PASS}" >/dev/null 2>&1; then
            log_success "Database is ready"
            return 0
        fi
        
        ((attempt++))
        echo -ne "\r${CYAN}⏳${NC} Attempt $attempt/$max_attempts..."
        sleep 2
    done
    
    log_error "Database failed to become ready"
    log_error "Check docker logs: sudo docker compose logs db"
    exit 1
}

install_dependencies() {
    log_step "Installing Dependencies"
    
    if [ "${SEED_SAMPLE_DATA:-false}" = true ]; then
        log_info "Installing Composer dependencies (including dev for seeding)..."
        if [ ${#MODULES_TO_INSTALL[@]} -gt 0 ]; then
            sudo docker compose exec -e COMPOSER_PROCESS_TIMEOUT=2000 -T app composer update --optimize-autoloader
        else
            sudo docker compose exec -e COMPOSER_PROCESS_TIMEOUT=2000 -T app composer install --optimize-autoloader
        fi
    else
        log_info "Installing Composer dependencies..."
        if [ ${#MODULES_TO_INSTALL[@]} -gt 0 ]; then
             sudo docker compose exec -e COMPOSER_PROCESS_TIMEOUT=2000 -T app composer update --no-dev --optimize-autoloader
        else
             sudo docker compose exec -e COMPOSER_PROCESS_TIMEOUT=2000 -T app composer install --no-dev --optimize-autoloader
        fi
    fi
     
    log_info "Installing NPM dependencies..."
    sudo docker compose exec -T app npm install
    
    log_info "Building frontend assets..."
    sudo docker compose exec -T app npm run build
    
    log_success "Dependencies installed"
}

finalize_installation() {
    log_step "Finalizing Installation"
    
    log_info "Generating application key..."
    sudo docker compose exec -T app php artisan key:generate
    
    if [ "$REUSE_DB" = true ]; then
        log_info "Running migrations on existing database..."
        sudo docker compose exec -T app php artisan migrate --force
    else
        log_info "Installing FreeScout..."
        sudo docker compose exec -T app php artisan freescout:install \
            --force \
            --email="$ADMIN_EMAIL" \
            --password="$ADMIN_PASS" \
            --first_name="Admin" \
            --last_name="User"
    fi
    
    if [ ${#MODULES_TO_INSTALL[@]} -gt 0 ]; then
        log_info "Running module migrations..."
        sudo docker compose exec -T app php artisan module:migrate --all --force
        
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
' | sudo docker compose exec -T app php artisan tinker
    else
        log_info "No modules to migrate."
    fi
    
    log_info "Seeding themes..."
    sudo docker compose exec -T app php artisan db:seed --class=ThemeSeeder --force
    
    if [ "${SEED_SAMPLE_DATA:-false}" = true ]; then
        log_info "Seeding sample data..."
        sudo docker compose exec -T app php artisan db:seed --class=DatabaseSeeder --force
        
        log_info "Cleaning up dev dependencies..."
        sudo docker compose exec -e COMPOSER_PROCESS_TIMEOUT=2000 -T app composer install --no-dev --optimize-autoloader
    fi
    
    # Seed default users for all roles
    log_info "Seeding default users (Admin, Agent, Finance, Reporter)..."
    sudo docker compose exec -T app php artisan db:seed --class=UserSeeder --force
    
    # Configure git safe directory
    cd "$DEFAULT_INSTALL_DIR"
    sudo git config --global --add safe.directory "$DEFAULT_INSTALL_DIR/src"
    
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
    echo ""
    echo -e "${CYAN}Default User Accounts:${NC}"
    echo -e "  ${YELLOW}Admin${NC} - Full System Access"
    echo -e "    Email: ${GREEN}$ADMIN_EMAIL${NC}"
    
    if [ "$REUSE_DB" = true ] && [ "$ADMIN_PASS_PRESERVED" = true ]; then
        echo -e "    Pass:  ${YELLOW}(Existing password unchanged)${NC}"
    else
        echo -e "    Pass:  ${GREEN}$ADMIN_PASS${NC}"
    fi
    
    echo ""
    echo -e "  ${YELLOW}Agent${NC} - Standard Support Access"
    echo -e "    Email: ${GREEN}${AGENT_EMAIL:-agent@example.com}${NC}"
    echo -e "    Pass:  ${GREEN}${AGENT_PASS:-agent123456789}${NC}"
    echo ""
    echo -e "  ${YELLOW}Finance${NC} - Billing & Invoice Access"
    echo -e "    Email: ${GREEN}${FINANCE_EMAIL:-finance@example.com}${NC}"
    echo -e "    Pass:  ${GREEN}${FINANCE_PASS:-finance123456789}${NC}"
    echo ""
    echo -e "  ${YELLOW}Reporter${NC} - Read-Only Access"
    echo -e "    Email: ${GREEN}${REPORTER_EMAIL:-reporter@example.com}${NC}"
    echo -e "    Pass:  ${GREEN}${REPORTER_PASS:-reporter123456789}${NC}"
    
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo -e "  • To update: ${YELLOW}cd $DEFAULT_INSTALL_DIR && sudo ./update.sh${NC}"
    echo -e "  • View logs: ${YELLOW}sudo docker compose logs -f${NC}"
    echo -e "  • Stop:      ${YELLOW}sudo docker compose down${NC}"
    echo ""
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    show_banner
    if [ "$INTERACTIVE" = true ]; then
        if [ -n "${1:-}" ]; then
            # Arguments passed, skip menu
            GIT_REPO_URL=$1
            GIT_BRANCH=${2:-$DEFAULT_BRANCH}
            log_info "Arguments detected, skipping interactive menu..."
        else
            interactive_menu
        fi
    fi

    preflight_checks
    load_or_create_config
    
    # Set defaults for credentials
    DB_ROOT_PASS="${DB_ROOT_PASS:-$(openssl rand -hex 16)}"
    DB_USER="${DB_USER:-freescout}"
    DB_PASS="${DB_PASS:-$(openssl rand -hex 16)}"
    DB_NAME="${DB_NAME:-freescout}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@freescout.local}"
    ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -hex 12)}"
    
    check_existing_installation
    
    if [ "$INTERACTIVE" = true ]; then
        if [ -z "${1:-}" ]; then
            interactive_setup
        fi
    fi
    
    # Validate required variables
    validate_required_var "DOMAIN_NAME" "${DOMAIN_NAME:-}"
    validate_required_var "DOCKER_SUBNET" "${DOCKER_SUBNET:-}"
    
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
    
    # Cleanup and success
    log_info "Pruning unused Docker resources..."
    sudo docker image prune -f >/dev/null 2>&1 || true
    
    show_completion_message
}

# Run main function
main "$@"
