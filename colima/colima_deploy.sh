#!/usr/bin/env bash


#===============================================================================
# FreeScout Colima Deployer (macOS/Linux + Cloudflare Tunnel)
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

# Ensure docker/colima binaries are on PATH when run via non-interactive SSH
# (macOS doesn't source .zshrc/.bashrc in non-interactive sessions). Colima and
# its docker CLI install via Homebrew into these standard prefixes — no extra
# vendor-specific bin directory needed (unlike OrbStack's bundled ~/.orbstack/bin).
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

#===============================================================================
# GLOBALS & CONFIGURATION
#===============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO="https://github.com/BorealTek/Treescout-Core.git"
DEFAULT_BRANCH="main"
DEFAULT_INSTALL_DIR="$HOME/borealtek-ticketing"
readonly CONFIG_FILE="${SCRIPT_DIR}/../linux/deploy.conf"

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

# Default Modules — mirrors the submodule list in Treescout-Core's .gitmodules
# (kept independent of git submodule linkage; install_modules() clones these
# as standalone repos so module updates don't require touching the core repo).
MODULES_TO_INSTALL=(
    "Action1|https://github.com/BorealTek/Action1-Module.git|REPO_TOKEN|main"
    "Alerts|https://github.com/BorealTek/Alerts-Module.git|REPO_TOKEN|main"
    "AssetManagement|https://github.com/BorealTek/AssetManagement-Module.git|REPO_TOKEN|main"
    "CaseManager|https://github.com/BorealTek/CaseManager-Module.git|REPO_TOKEN|main"
    "ClientPortal|https://github.com/BorealTek/ClientPortal-Module.git|REPO_TOKEN|main"
    "ContractManager|https://github.com/BorealTek/ContractManager-Module.git|REPO_TOKEN|main"
    "Crm|https://github.com/BorealTek/Crm-Module.git|REPO_TOKEN|main"
    "DeploymentManager|https://github.com/BorealTek/DeploymentManager-Module.git|REPO_TOKEN|main"
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

sed_in_place() {
    local expression="$1"
    local file="$2"

    if sed --version >/dev/null 2>&1; then
        sed -i "$expression" "$file"
    else
        sed -i '' "$expression" "$file"
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

    # Check Docker (Colima)
    if ! command_exists docker; then
        log_error "Docker CLI not found! Install with: brew install colima docker docker-compose"
        log_info "Docs: https://github.com/abiosoft/colima"
        exit 1
    fi

    if ! command_exists colima; then
        log_warning "colima not found on PATH — assuming an equivalent Docker context is running."
    fi

    # Check GitHub CLI — REPO_TOKEN is derived from `gh auth token` (see
    # deploy.conf), not stored as a raw PAT on disk. An unauthenticated gh
    # silently produces an empty REPO_TOKEN, which then fails private module
    # clones with a confusing error deep into the run — fail fast here instead.
    if ! command_exists gh; then
        log_error "GitHub CLI (gh) not found! Install with: brew install gh"
        exit 1
    fi

    if ! gh auth status >/dev/null 2>&1; then
        log_error "gh is not authenticated. Run: gh auth login"
        exit 1
    fi
    log_success "gh authenticated as $(gh api user --jq .login 2>/dev/null || echo 'unknown user')"

    # Verify Docker is running
    log_info "Verifying Docker Status..."
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is installed but not running"
        if command_exists colima; then
            log_info "Try starting it with: colima start"
        fi
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
    # `clear` needs TERM set to a known terminfo entry — under automation
    # (ssh host script, cron) that's often missing even with a pty allocated.
    # Never let a cosmetic banner clear abort the whole deploy.
    clear 2>/dev/null || true
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

preview_config_values() {
    # Presence-only preview (never prints actual values — this may include secrets
    # like DB_PASS/REPO_TOKEN). Sourced once in a subshell so nothing leaks into the
    # caller's environment before the operator has actually confirmed the file.
    local keys=(
        ADMIN_EMAIL ADMIN_PASS DB_NAME DB_PASS DB_ROOT_PASS DB_USER
        DEFAULT_INSTALL_DIR DOMAIN_NAME GIT_BRANCH GIT_REPO_URL
        GOOGLE_ADMIN_EMAILS GOOGLE_ALLOWED_DOMAINS GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
        IMAP_ENCRYPTION IMAP_HOST IMAP_PASSWORD IMAP_PORT IMAP_USERNAME
        KB_URL MAIL_FROM_ADDRESS MAIL_FROM_NAME MAIL_HOST MAIL_PASSWORD MAIL_PORT MAIL_SCHEME MAIL_USERNAME
        REPO_TOKEN TICKET_URL
    )
    local populated=() unpopulated=() key val dump

    dump=$(
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" 2>/dev/null
        for k in "${keys[@]}"; do
            printf '%s=%s\n' "$k" "${!k:-}"
        done
    )

    while IFS='=' read -r key val; do
        if [ -n "$val" ]; then populated+=("$key"); else unpopulated+=("$key"); fi
    done <<< "$dump"

    echo ""
    echo -e "${CYAN}Configuration preview (values hidden):${NC}"
    if [ ${#populated[@]} -gt 0 ]; then
        echo -e "  ${GREEN}Populated:${NC}"
        printf '    %s\n' "${populated[@]}" | sort
    fi
    if [ ${#unpopulated[@]} -gt 0 ]; then
        echo -e "  ${YELLOW}Not set:${NC}"
        printf '    %s\n' "${unpopulated[@]}" | sort
    fi
    echo ""
}

load_or_create_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_success "Configuration file found: $CONFIG_FILE"

        if [ -t 0 ] || [ -c /dev/tty ]; then
            preview_config_values
            safe_read "Use this configuration? [Y/n] " use_config
            use_config=${use_config:-Y}

            if [[ "$use_config" =~ ^[Yy]$ ]]; then
                log_info "Loading configuration..."
                # shellcheck disable=SC1090
                source "$CONFIG_FILE"

                # Sync config variables to internal variables
                if [ -n "${GIT_REPO_URL:-}" ]; then DEFAULT_REPO="$GIT_REPO_URL"; fi
                if [ -n "${GIT_BRANCH:-}" ]; then DEFAULT_BRANCH="$GIT_BRANCH"; fi

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
# FreeScout Colima Deployment Configuration (macOS/Linux)
#===============================================================================

# Installation Settings
GIT_REPO_URL="$DEFAULT_REPO"
GIT_BRANCH="$DEFAULT_BRANCH"
DEFAULT_INSTALL_DIR="$DEFAULT_INSTALL_DIR"

# Domain & Cloudflare Tunnel
DOMAIN_NAME="devtickets.scotchmcdonald.dev"

# Ticketing / Knowledge Base URL split (optional — both fall back to APP_URL /
# APP_URL+'/kb' when unset; only set these if you want a dedicated KB hostname,
# see app/Http/Middleware/SetContextUrl.php)
TICKET_URL=""
KB_URL=""

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

# Mail (Optional — falls back to the `log` driver, i.e. mail is written to
# storage/logs/laravel.log instead of sent, if left blank)
MAIL_HOST=""
MAIL_PORT="587"
MAIL_USERNAME=""
MAIL_PASSWORD=""
MAIL_SCHEME="tls"
MAIL_FROM_ADDRESS=""
MAIL_FROM_NAME=""

# IMAP (Optional — only needed for a global default mailbox-fetch account;
# most mailboxes are configured per-mailbox via the Settings UI instead)
IMAP_HOST=""
IMAP_PORT="993"
IMAP_USERNAME=""
IMAP_PASSWORD=""
IMAP_ENCRYPTION="ssl"

# Define your access tokens (optional)
export REPO_TOKEN="ghp_your_token_here"

# Configure modules to install
# Format: "ModuleName|RepoURL|TokenEnvVarName"
MODULES_TO_INSTALL=(
    "Action1|https://github.com/BorealTek/Action1-Module.git|REPO_TOKEN|main"
    "Alerts|https://github.com/BorealTek/Alerts-Module.git|REPO_TOKEN|main"
    "AssetManagement|https://github.com/BorealTek/AssetManagement-Module.git|REPO_TOKEN|main"
    "CaseManager|https://github.com/BorealTek/CaseManager-Module.git|REPO_TOKEN|main"
    "ClientPortal|https://github.com/BorealTek/ClientPortal-Module.git|REPO_TOKEN|main"
    "ContractManager|https://github.com/BorealTek/ContractManager-Module.git|REPO_TOKEN|main"
    "Crm|https://github.com/BorealTek/Crm-Module.git|REPO_TOKEN|main"
    "DeploymentManager|https://github.com/BorealTek/DeploymentManager-Module.git|REPO_TOKEN|main"
    "EmailMigration|https://github.com/BorealTek/EmailMigration-Module.git|REPO_TOKEN|main"
    "GoogleAdmin|https://github.com/BorealTek/GoogleAdmin-Module.git|REPO_TOKEN|main"
    "KnowledgeBase|https://github.com/BorealTek/KnowledgeBase-Module.git|REPO_TOKEN|main"
    "PIB|https://github.com/BorealTek/PIB-Module.git|REPO_TOKEN|main"
    "Payment|https://github.com/BorealTek/Payment-Module.git|REPO_TOKEN|main"
    "SoftwareSubscriptions|https://github.com/BorealTek/SoftwareSubscriptions-Module.git|REPO_TOKEN|main"
    "WidgetRegistry|https://github.com/BorealTek/WidgetRegistry-Module.git|REPO_TOKEN|main"
)
EOF
}


interactive_menu() {
    local choice
    while true; do
        # show_banner - removed to prevent flickering
        echo ""
        echo -e "  ${COLOR_PRIMARY}[1]${NC} Deploy to Colima (Fresh)"
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
    log_step "Interactive Setup"

    # Cloudflare configuration
    log_info "Cloudflare Configuration"
    safe_read "Domain Name [devtickets.scotchmcdonald.dev]: " input_domain
    DOMAIN_NAME="${input_domain:-devtickets.scotchmcdonald.dev}"


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
    read -rp "Press ENTER to start deployment (or Ctrl+C to cancel)..." _ignore
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
        local existing_email existing_pass existing_key
        existing_email=$(grep "^ADMIN_EMAIL=" "$laravel_env" | cut -d '=' -f2 | tr -d '"' | tr -d "'" || echo "")
        existing_pass=$(grep "^ADMIN_PASSWORD=" "$laravel_env" | cut -d '=' -f2 | tr -d '"' | tr -d "'" || echo "")
        # Preserve APP_KEY so sessions survive redeployment
        existing_key=$(grep "^APP_KEY=" "$laravel_env" | head -1 | cut -d '=' -f2- | tr -d '"' | tr -d "'" || echo "")

        if [ -n "$existing_email" ]; then ADMIN_EMAIL=$existing_email; fi
        if [ -n "$existing_pass" ]; then ADMIN_PASS=$existing_pass; fi
        if [ -n "$existing_key" ]; then EXISTING_APP_KEY=$existing_key; fi
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

decommission_existing() {
    # Kill any orphaned containers from a previous deploy by project label.
    # This handles the case where the install dir was wiped without docker compose down.
    local orphans
    orphans=$(docker ps -q --filter "label=com.docker.compose.project=boreal-treescout" 2>/dev/null || true)
    if [ -n "$orphans" ]; then
        log_warning "Stopping orphaned containers from a previous deployment..."
        docker rm -f $orphans >/dev/null 2>&1 || true
    fi

    if [ -f "$DEFAULT_INSTALL_DIR/docker-compose.yml" ]; then
        log_step "Decommissioning Existing Installation"

        cd "$DEFAULT_INSTALL_DIR"

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
             docker compose down 2>/dev/null || true
        else
             log_warning "Nuking everything - all data will be lost!"
             # If decision was made previously and it was Nuke, we should doubly confirm?
             # No, assume they meant it. Or auto-confirm.
             if [ "${EXISTING_DECISION_MADE:-false}" = false ]; then
                safe_read "Type 'yes' to confirm: " confirm
                if [ "$confirm" != "yes" ]; then
                    log_error "Aborted by user."
                    exit 1
                fi
             fi

             log_info "Removing containers and volumes..."
             docker compose down -v --remove-orphans 2>/dev/null || true

             log_info "Removing source code directory..."
             rm -rf src
             log_success "Everything nuked"
        fi
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
FROM serversideup/php:8.3-fpm-nginx

USER root

# Install system dependencies, cron, MySQL Client, and Node.js 24.x LTS
RUN apt-get update && apt-get install -y gnupg git curl ca-certificates cron default-mysql-client && \
    # Disable SSL for MySQL Client (Fixes ERROR 2026)
    mkdir -p /etc/mysql/conf.d && \
    printf "[client]\nssl=0\nskip-ssl\n" > /etc/mysql/conf.d/disable_ssl.cnf && \
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
    log_step "Generating Nginx Configuration (HTTP for tunnel + HTTPS for local access)"

    cat > nginx/default.conf <<'EOF'
# Plain HTTP on port 8080 — used by the Cloudflare tunnel.
# The tunnel itself handles TLS between the browser and Cloudflare's edge;
# no SSL is needed (or desired) between cloudflared and this origin.
server {
    listen 8080 default_server;
    server_name _;
    root /var/www/html/public;
    index index.php index.html;
    client_max_body_size 20M;

    # Use Docker's embedded DNS resolver so upstream hostnames (e.g. reverb)
    # are re-resolved when containers restart and get new IPs. Without this,
    # nginx caches the IP at startup and returns 502 after any container restart.
    resolver 127.0.0.11 valid=10s ipv6=off;

    # Gzip — reduces 153KB CSS to ~30KB, JS chunks proportionally
    gzip            on;
    gzip_vary       on;
    gzip_comp_level 6;
    gzip_types      text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;
    gzip_min_length 256;

    # WebSocket proxy to Reverb container.
    # Using a variable for proxy_pass forces nginx to re-resolve the hostname
    # via the resolver above on each request, not just at startup.
    location /app/ {
        set $reverb_upstream http://reverb:8080;
        proxy_pass $reverb_upstream;
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
        # Cloudflare always delivers HTTPS to users; mark PHP as HTTPS.
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

    # Vite build assets — long-lived cache (hashed filenames = safe forever)
    location ^~ /build/ {
        expires 1y;
        access_log off;
        add_header Cache-Control "public, immutable";
    }

    # Security
    location ~ /\. {
        deny all;
    }
}

# HTTPS on port 8443 — emergency local LAN access only (accept the cert warning).
# Not used by Cloudflare tunnel.
server {
    listen 8443 ssl;
    http2 on;
    server_name _;
    root /var/www/html/public;
    index index.php index.html;
    client_max_body_size 20M;

    gzip            on;
    gzip_vary       on;
    gzip_comp_level 6;
    gzip_types      text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;
    gzip_min_length 256;

    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    resolver 127.0.0.11 valid=10s ipv6=off;

    location /app/ {
        set $reverb_upstream http://reverb:8080;
        proxy_pass $reverb_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
    }

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
EOF

    # Pass through any environment variables ending in _TOKEN, _KEY, or _SECRET
    # This allows passing git access tokens for modules
    env | grep -E '(_TOKEN|_KEY|_SECRET)=' | grep -vE '^(DB_|APP_|REDIS_|GOOGLE_|REVERB_|TUNNEL_)' >> .env || true

    log_success "Docker .env generated"
}

generate_docker_compose() {
    log_step "Generating Docker Compose Configuration"

    cat > docker-compose.yml <<EOF
services:
  app:
    build:
      context: .
    image: freescout-app
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"  # HTTP — Cloudflare tunnel origin (HTTP, not HTTPS)
      - "127.0.0.1:8443:8443"  # HTTPS — local emergency access only
    env_file:
      - ./src/.env.secrets
    environment:
      - PUID=$(id -u)
      - PGID=$(id -g)
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
      # Named volumes: prevent storage/ and bootstrap/cache/ permission drift
      # between www-data (in-container) and your local user (host bind mount).
      - storage_data:/var/www/html/storage
      - bootstrap_cache:/var/www/html/bootstrap/cache
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
    # Use mariadbd with SSL explicitly disabled to fix "SSL is required" error
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW --innodb-file-per-table=1 --skip-innodb-read-only-compressed --skip-ssl --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
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
    env_file:
      - ./src/.env.secrets
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
      - storage_data:/var/www/html/storage
      - bootstrap_cache:/var/www/html/bootstrap/cache
    depends_on:
      - app
      - db
      - redis
    networks:
      - fs-net
    healthcheck:
      disable: true

  cron:
    image: freescout-app
    restart: unless-stopped
    env_file:
      - ./src/.env.secrets
    environment:
      - PHP_OPCACHE_ENABLE=1
      - ENABLE_CRON=true
    command: >
      /bin/sh -c '
      echo "* * * * * cd /var/www/html && php artisan schedule:run >> /var/log/cron.log 2>&1" | crontab - &&
      echo "Starting cron..." &&
      cron -f
      '
    volumes:
      - ./src:/var/www/html
      - storage_data:/var/www/html/storage
      - bootstrap_cache:/var/www/html/bootstrap/cache
    depends_on:
      - app
      - db
      - redis
    networks:
      - fs-net
    healthcheck:
      disable: true

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
    env_file:
      - ./src/.env.secrets
    environment:
      - PHP_OPCACHE_ENABLE=1
    volumes:
      - ./src:/var/www/html
      - storage_data:/var/www/html/storage
      - bootstrap_cache:/var/www/html/bootstrap/cache
    depends_on:
      - app
      - db
      - redis
    networks:
      - fs-net
    healthcheck:
      disable: true

networks:
  fs-net:
    driver: bridge

volumes:
  db_data:
  # storage_data: persists uploads, logs, and framework cache across source code updates
  storage_data:
  # bootstrap_cache: persists compiled config/routes/views between container restarts
  bootstrap_cache:
EOF

    log_success "Docker Compose config generated"
}

generate_update_script() {
    log_step "Generating Update Script"

    cat > update.sh <<EOF
#!/usr/bin/env bash
#===============================================================================
# FreeScout Zero-Downtime Update Script (generated by colima_deploy.sh)
#
# Sequence:
#   1. Maintenance mode ON        → users see 503, not 500
#   2. git pull + submodule sync  → get latest code
#   3. Rebuild image + restart    → new containers
#   4. Init storage in volumes    → safe after named-volume remount
#   5. composer install           → locked deps (never composer update)
#   6. npm build                  → bake assets before cache warm
#   7. migrate                    → schema changes under maintenance mode
#   8. Cache warm                 → config/route/view/event caches
#   9. queue:restart              → workers pick up new code gracefully
#  10. Maintenance mode OFF       → site goes live
#===============================================================================
set -euo pipefail

readonly GREEN='\\\033[38;5;46m'
readonly CYAN='\\\033[38;5;51m'
readonly YELLOW='\\\033[38;5;226m'
readonly NC='\\\033[0m'

log_step() { echo -e "\n\${CYAN}➜\${NC} \$*"; }
log_ok()   { echo -e "\${GREEN}✔\${NC} \$*"; }
log_warn() { echo -e "\${YELLOW}⚠\${NC} \$*"; }

CD_HERE=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)
cd "\$CD_HERE"

run_artisan() {
    local desc="\$1"; shift
    log_step "\$desc"
    if ! docker compose exec -T app php artisan "\$@"; then
        log_warn "Artisan step failed: php artisan \$*"
        docker compose exec -T app php artisan up 2>/dev/null || true
        exit 1
    fi
}

# ── 1. Maintenance Mode ───────────────────────────────────────────────────────
log_step "Entering maintenance mode (users will see 503)..."
docker compose exec -T app php artisan down --retry=60 2>/dev/null || log_warn "Could not enter maintenance mode (first deploy?)"

# ── 2. Pull Latest Code ───────────────────────────────────────────────────────
log_step "Pulling latest source code..."
cd src
git pull origin ${DEFAULT_BRANCH}
git submodule update --init --recursive
cd ..

# ── 3. Rebuild & Restart Containers ──────────────────────────────────────────
log_step "Rebuilding application image..."
docker compose build app

log_step "Restarting app and worker containers (zero-downtime: DB/Redis stay up)..."
docker compose up -d --no-deps app queue cron reverb

# Re-enter maintenance mode after container restart (artisan up was reset)
docker compose exec -T app php artisan down --retry=60 2>/dev/null || true

# ── 4. Re-initialize Storage in Named Volumes ────────────────────────────────
log_step "Re-initializing storage directories in named volumes..."
docker compose exec -T -u root app bash -c '
    mkdir -p /var/www/html/storage/framework/{cache,sessions,views,testing} \
             /var/www/html/storage/logs \
             /var/www/html/bootstrap/cache && \
    chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache && \
    chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache
'

# ── 5. Install Dependencies ───────────────────────────────────────────────────
log_step "Installing Composer dependencies (locked versions)..."
docker compose exec -T -u root app composer install --no-dev --optimize-autoloader
docker compose exec -T -u root app chown -R www-data:www-data /var/www/html/vendor /var/www/html/composer.lock

# ── 6. Build Frontend Assets ─────────────────────────────────────────────────
log_step "Building frontend assets..."
docker compose exec -T -u root app npm install
docker compose exec -T -u root app npm run build
docker compose exec -T -u root app chown -R www-data:www-data /var/www/html/public/build 2>/dev/null || true

# ── 7. Run Migrations ─────────────────────────────────────────────────────────
run_artisan "Running core database migrations..." migrate --force
run_artisan "Running module migrations..." module:migrate --all --force

# ── 8. Warm Caches ────────────────────────────────────────────────────────────
# NOTE: after config:cache, env() outside config files returns null.
# This codebase routes all env() through config() — safe to apply.
run_artisan "Caching configuration..." config:cache
run_artisan "Caching routes..." route:cache
run_artisan "Caching Blade views..." view:cache
run_artisan "Caching event/listener map..." event:cache

# ── 9. Restart Queue Workers ──────────────────────────────────────────────────
run_artisan "Signalling queue workers to restart with new code..." queue:restart

# ── 10. Go Live ───────────────────────────────────────────────────────────────
log_step "Exiting maintenance mode — site is live!"
docker compose exec -T app php artisan up

log_step "Pruning unused Docker layers..."
docker image prune -f >/dev/null 2>&1 || true

APP_URL=\$(grep "^APP_URL=" src/.env | cut -d'=' -f2)
log_ok "Update complete! App is live at \${APP_URL}"
EOF

    chmod +x update.sh
    log_success "Update script generated"
}

clone_or_update_repo() {
    log_step "Cloning/Updating Repository"

    if [ -d "src" ]; then
        # Guard: src/ exists but is NOT a git repo (leftover from a failed deploy).
        # Re-clone rather than crashing on the update path.
        if ! git -C src rev-parse --git-dir >/dev/null 2>&1; then
            log_warning "src/ exists but is not a git repository (stale directory). Removing and re-cloning..."
            rm -rf src
            log_info "Cloning source..."
            git clone -b "$DEFAULT_BRANCH" "$DEFAULT_REPO" src
        else
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
        fi
    else
        log_info "Cloning source..."
        git clone -b "$DEFAULT_BRANCH" "$DEFAULT_REPO" src
    fi

    # Initialize the deployment submodule so cloudflared/ config is available
    # for deploy_cloudflared() which runs later in main().
    if [ -n "${REPO_TOKEN:-}" ]; then
        log_info "Initializing deployment submodule..."
        cd src
        git config submodule.deployment.url \
            "https://oauth2:${REPO_TOKEN}@github.com/BorealTek/Treescout-Deployments"
        GIT_TERMINAL_PROMPT=0 git -c credential.helper= submodule update --init deployment \
            || log_warning "Could not initialize deployment submodule (cloudflared may be unavailable)"
        cd ..
    fi

    log_success "Repository ready"
}

configure_laravel() {
    log_step "Configuring Laravel Environment"

    cp "src/.env.example" "src/.env"

    local env_file="src/.env"
    local secrets_file="src/.env.secrets"

    # .env.secrets: sensitive values only (passwords/API secrets — never hostnames,
    # usernames, IDs, or feature flags). Injected into containers via docker-compose
    # env_file:, which sets real OS env vars — phpdotenv never overwrites an
    # already-set env var, so these values win over anything in .env automatically.
    # Never baked into the image, chmod 600, gitignored.
    : > "$secrets_file"
    chmod 600 "$secrets_file"

    # NOTE: .env.example has DB settings commented out — match the commented forms
    # APP_NAME is already set correctly in .env.example
    sed_in_place "s/DB_CONNECTION=sqlite/DB_CONNECTION=mysql/g" "$env_file"
    sed_in_place "s|# DB_HOST=127.0.0.1|DB_HOST=db|g" "$env_file"
    sed_in_place "s/# DB_PORT=3306/DB_PORT=3306/g" "$env_file"
    sed_in_place "s/# DB_DATABASE=freescout/DB_DATABASE=${DB_NAME}/g" "$env_file"
    sed_in_place "s/# DB_USERNAME=freescout/DB_USERNAME=${DB_USER}/g" "$env_file"
    # DB_PASSWORD stays a secret — leave .env.example's line blank/commented, real
    # value goes to .env.secrets below.
    sed_in_place "s|APP_URL=http://localhost|APP_URL=https://${DOMAIN_NAME}|g" "$env_file"
    sed_in_place "s/CACHE_STORE=database/CACHE_STORE=redis/g" "$env_file"
    sed_in_place "s/SESSION_DRIVER=database/SESSION_DRIVER=redis/g" "$env_file"
    sed_in_place "s/REDIS_HOST=127.0.0.1/REDIS_HOST=redis/g" "$env_file"
    # Must run as production — debug mode adds significant per-request overhead
    sed_in_place "s/^APP_ENV=.*/APP_ENV=production/g" "$env_file"
    sed_in_place "s/^APP_DEBUG=.*/APP_DEBUG=false/g" "$env_file"

    cat >> "$secrets_file" <<EOF
DB_PASSWORD=${DB_PASS}
EOF

    # Admin credentials — email isn't sensitive, password is
    cat >> "$env_file" <<EOF

# Admin Credentials
ADMIN_EMAIL=${ADMIN_EMAIL}
EOF
    cat >> "$secrets_file" <<EOF
ADMIN_PASSWORD=${ADMIN_PASS}
EOF

    # TICKET_URL / KB_URL — both optional (config/app.php falls back to APP_URL /
    # APP_URL+'/kb' when unset), only written when the operator explicitly wants a
    # dedicated ticketing/KB hostname split (see SetContextUrl middleware).
    if [ -n "${TICKET_URL:-}" ] || [ -n "${KB_URL:-}" ]; then
        cat >> "$env_file" <<EOF

# Ticketing / Knowledge Base URL split (see app/Http/Middleware/SetContextUrl.php)
EOF
        [ -n "${TICKET_URL:-}" ] && echo "TICKET_URL=${TICKET_URL}" >> "$env_file"
        [ -n "${KB_URL:-}" ] && echo "KB_URL=${KB_URL}" >> "$env_file"
    fi

    # Mail (optional — falls back to the `log` driver via .env.example defaults)
    if [ -n "${MAIL_HOST:-}" ]; then
        cat >> "$env_file" <<EOF

# Mail
MAIL_MAILER=smtp
MAIL_HOST=${MAIL_HOST}
MAIL_PORT=${MAIL_PORT:-587}
MAIL_USERNAME=${MAIL_USERNAME:-}
MAIL_SCHEME=${MAIL_SCHEME:-tls}
MAIL_FROM_ADDRESS=${MAIL_FROM_ADDRESS:-$ADMIN_EMAIL}
MAIL_FROM_NAME="${MAIL_FROM_NAME:-$DOMAIN_NAME}"
EOF
        [ -n "${MAIL_PASSWORD:-}" ] && echo "MAIL_PASSWORD=${MAIL_PASSWORD}" >> "$secrets_file"
    fi

    # IMAP (optional — only needed if mailboxes fetch via a global default account)
    if [ -n "${IMAP_HOST:-}" ]; then
        cat >> "$env_file" <<EOF

# IMAP
IMAP_HOST=${IMAP_HOST}
IMAP_PORT=${IMAP_PORT:-993}
IMAP_USERNAME=${IMAP_USERNAME:-}
IMAP_ENCRYPTION=${IMAP_ENCRYPTION:-ssl}
EOF
        [ -n "${IMAP_PASSWORD:-}" ] && echo "IMAP_PASSWORD=${IMAP_PASSWORD}" >> "$secrets_file"
    fi

    # Reverb/Broadcasting — strip ALL existing BROADCAST/REVERB lines then append
    # a single authoritative block. This is idempotent and immune to sed pattern
    # mismatches against stale .env.example placeholder values.
    # REVERB_APP_KEY (not the secret) also feeds VITE_REVERB_APP_KEY, which Vite
    # bakes into the frontend bundle at build time — it must stay in .env, not
    # .env.secrets, or `npm run build` won't see it.
    local reverb_app_id reverb_app_key reverb_app_secret
    reverb_app_id=$(openssl rand -hex 8)
    reverb_app_key=$(openssl rand -hex 16)
    reverb_app_secret=$(openssl rand -hex 16)

    grep -vE '^(BROADCAST_CONNECTION=|REVERB_|VITE_REVERB_|# REVERB|# Reverb|# In Docker.*REVERB)' "$env_file" > "${env_file}.tmp" && mv "${env_file}.tmp" "$env_file"

    cat >> "$env_file" <<EOF

#===============================================================================
# BROADCASTING (Reverb WebSockets)
#===============================================================================
BROADCAST_CONNECTION=reverb
REVERB_APP_ID=${reverb_app_id}
REVERB_APP_KEY=${reverb_app_key}
# Internal Docker hostname of the reverb service
REVERB_HOST=reverb
REVERB_PORT=8080
REVERB_SCHEME=http
# Public hostname used by the browser / Echo client
REVERB_SERVER_HOST=${DOMAIN_NAME}
REVERB_SERVER_PORT=443
REVERB_SERVER_PATH=""
VITE_REVERB_APP_KEY="${reverb_app_key}"
VITE_REVERB_HOST="${DOMAIN_NAME}"
VITE_REVERB_PORT=443
VITE_REVERB_SCHEME=https
EOF
    cat >> "$secrets_file" <<EOF
REVERB_APP_SECRET=${reverb_app_secret}
EOF

    # Google OAuth (if configured) — strip any pre-existing GOOGLE_ADMIN_EMAILS/
    # GOOGLE_ALLOWED_DOMAINS lines first (.env.example already declares blank
    # placeholders for both; phpdotenv keeps the FIRST definition of a key it sees,
    # so appending without stripping left the real values silently shadowed by the
    # empty placeholder — Google SSO's domain/email allowlist never actually applied).
    if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
        grep -vE '^(GOOGLE_ADMIN_EMAILS=|GOOGLE_ALLOWED_DOMAINS=)' "$env_file" > "${env_file}.tmp" && mv "${env_file}.tmp" "$env_file"

        cat >> "$env_file" <<EOF

# Google OAuth
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_REDIRECT_URI=https://${DOMAIN_NAME}/auth/google/callback
GOOGLE_ADMIN_EMAILS="${GOOGLE_ADMIN_EMAILS:-}"
GOOGLE_ALLOWED_DOMAINS="${GOOGLE_ALLOWED_DOMAINS:-}"
EOF
        cat >> "$secrets_file" <<EOF
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
EOF
    fi

    # Trust Cloudflare proxies
    sed_in_place "s|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|g" "$env_file"
    # Append only if the key doesn't already exist in .env.example
    grep -q "^TRUSTED_PROXIES=" "$env_file" || echo "TRUSTED_PROXIES=*" >> "$env_file"

    log_success "Laravel environment configured (.env.secrets separated, chmod 600)"
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

        # Guard: target_dir exists but isn't a real git checkout of its own —
        # e.g. an uninitialized submodule placeholder, or a stale copy left
        # behind by an earlier deploy that skipped install_modules(). Check
        # for a *direct* .git entry rather than `git rev-parse --git-dir`,
        # which walks up to Treescout-Core's own .git for any plain
        # subdirectory and would never report these as non-repos.
        if [ -d "$target_dir" ] && [ ! -e "$target_dir/.git" ]; then
            log_warning "Module $name exists but is not a git repository (stale/uninitialized copy). Removing and re-cloning..."
            rm -rf "$target_dir"
        fi

        if [ -d "$target_dir" ]; then
            log_info "Module $name already exists. Updating..."
            cd "$target_dir"
            local token_var_update=$(echo "$module_entry" | cut -d'|' -f3)
            local token_val_update="${!token_var_update:-}"
            if [ -n "$token_val_update" ]; then
                local remote_url
                remote_url=$(git remote get-url origin 2>/dev/null || echo "")
                if [[ "$remote_url" != *"@"* ]] && [ -n "$remote_url" ]; then
                    local clean_remote="${remote_url#https://}"
                    git remote set-url origin "https://oauth2:${token_val_update}@${clean_remote}" 2>/dev/null || true
                fi
            fi
            GIT_TERMINAL_PROMPT=0 git -c credential.helper= fetch origin
            GIT_TERMINAL_PROMPT=0 git -c credential.helper= pull
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

        GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone "$final_url" "$target_dir" || log_error "Failed to clone $name"
    done

    log_success "Modules installed"
}

sync_modules_statuses() {
    log_step "Syncing modules_statuses.json to installed modules"

    local statuses_file="$DEFAULT_INSTALL_DIR/src/modules_statuses.json"

    # Build JSON from what is physically present in src/Modules/, ensuring
    # only cloned modules are registered with nwidart. Any module listed in
    # the repo's modules_statuses.json but NOT cloned would cause a crash.
    local json="{"
    local first=true

    if [ -d "$DEFAULT_INSTALL_DIR/src/Modules" ]; then
        for module_dir in "$DEFAULT_INSTALL_DIR/src/Modules"/*/; do
            [ -d "$module_dir" ] || continue
            local module_name
            module_name=$(basename "$module_dir")
            if [ "$first" = true ]; then
                json+="\"${module_name}\": true"
                first=false
            else
                json+=", \"${module_name}\": true"
            fi
        done
    fi

    json+="}"

    echo "$json" > "$statuses_file"
    log_success "modules_statuses.json updated ($(echo "$json" | grep -o '"[A-Za-z]*": true' | wc -l | tr -d ' ') modules enabled)"
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

    # 775: owner/group (www-data) can write; others can read. Safer than 777.
    chmod -R 775 src/storage src/bootstrap/cache

    log_success "Storage directories ready"
}

build_and_launch_containers() {
    log_step "Building & Launching Docker Containers"

    log_info "Building application image (with BuildKit)..."
    docker compose build app

    # Start only core services — queue workers and cron are deferred until AFTER
    # migrations run.  Starting them now would cause a fatal error because the
    # `jobs` table (and other Laravel tables) do not yet exist in the database.
    log_info "Starting core services (db, redis, app, reverb)..."
    # --force-recreate: ensures fresh bind mounts even if old containers with the
    # same project name exist (e.g. from a failed deploy that wasn't cleaned up).
    # --remove-orphans: removes leftover containers from prior compose configs.
    docker compose up -d --force-recreate --remove-orphans db redis app reverb

    log_success "Core containers launched (queue workers will start after migrations)"
}

wait_for_database() {
    log_step "Waiting for Database"

    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T db mariadb -u root -p"${DB_ROOT_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
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

wait_for_app_database_connectivity() {
    log_step "Validating App -> DB Connectivity"

    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T app php -r '
            $dsn = "mysql:host=" . getenv("DB_HOST") . ";port=" . getenv("DB_PORT") . ";dbname=" . getenv("DB_DATABASE");
            new PDO($dsn, getenv("DB_USERNAME"), getenv("DB_PASSWORD"));
            echo "ok";
        ' >/dev/null 2>&1; then
            log_success "App container can connect to database"
            return 0
        fi

        ((attempt++))
        echo -ne "\r${CYAN}⏳${NC} Attempt $attempt/$max_attempts..."
        sleep 2
    done

    log_error "App container could not connect to database"
    return 1
}

dump_failure_diagnostics() {
    log_warning "Collecting diagnostics..."

    docker compose ps || true

    echo ""
    log_warning "Last 120 lines of app logs"
    docker compose logs --tail=120 app || true

    echo ""
    log_warning "Last 120 lines of db logs"
    docker compose logs --tail=120 db || true

    echo ""
    log_warning "Last 120 lines of Laravel log"
    docker compose exec -T app sh -lc 'if [ -f /var/www/html/storage/logs/laravel.log ]; then tail -n 120 /var/www/html/storage/logs/laravel.log; else echo "No laravel.log present"; fi' || true
}

run_artisan_step() {
    local description="$1"
    shift

    log_info "$description"
    if ! docker compose exec -T app php artisan "$@"; then
        log_error "Failed artisan step: php artisan $*"
        dump_failure_diagnostics
        return 1
    fi
}

install_dependencies() {
    log_step "Installing Dependencies"

    # Initialize storage directory tree INSIDE the named volumes.
    # Named volumes start empty, so this must run before anything tries to write
    # to storage/ or bootstrap/cache/ (e.g. Composer autoloader, Blade compiler).
    log_info "Initializing storage directories in named volumes..."
    docker compose exec -T -u root app bash -c '
        mkdir -p /var/www/html/storage/framework/{cache,sessions,views,testing} \
                 /var/www/html/storage/logs \
                 /var/www/html/bootstrap/cache && \
        chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache && \
        chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache
    '

    log_info "Installing Composer dependencies..."
    docker compose exec -T -u root app composer install --no-dev --optimize-autoloader
    docker compose exec -T -u root app chown -R www-data:www-data /var/www/html/vendor /var/www/html/composer.lock

    log_info "Installing NPM dependencies..."
    docker compose exec -T -u root app npm install

    log_info "Building frontend assets..."
    docker compose exec -T -u root app npm run build
    docker compose exec -T -u root app chown -R www-data:www-data /var/www/html/public/build 2>/dev/null || true

    log_success "Dependencies installed"
}

finalize_installation() {
    log_step "Finalizing Installation"

    # ── APP_KEY ────────────────────────────────────────────────────────────────
    # On a fresh install: generate a new key.
    # On a redeployment: restore the existing key so active sessions survive.
    # Regenerating on redeploy would invalidate all sessions and any database
    # values encrypted with the old key (e.g. mailbox passwords).
    local current_key
    current_key=$(grep "^APP_KEY=" src/.env 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -z "$current_key" ] && [ -n "${EXISTING_APP_KEY:-}" ]; then
        log_info "Restoring APP_KEY from previous installation to preserve sessions..."
        sed_in_place "s|^APP_KEY=.*|APP_KEY=${EXISTING_APP_KEY}|" src/.env
    elif [ -z "$current_key" ]; then
        run_artisan_step "Generating application key (fresh install)..." key:generate
    else
        log_info "APP_KEY already set — skipping key:generate to preserve sessions"
    fi

    # ── Maintenance Mode ───────────────────────────────────────────────────────
    # Puts up a 503 page so users don't hit 500 errors while migrations run.
    # We use || true so a fresh install (no DB yet) doesn't abort.
    log_info "Entering maintenance mode..."
    docker compose exec -T app php artisan down --retry=60 2>/dev/null || true

    # ── Migrations ────────────────────────────────────────────────────────────
    if [ "$REUSE_DB" = true ]; then
        run_artisan_step "Running core migrations..." migrate --force || {
            docker compose exec -T app php artisan up 2>/dev/null || true
            return 1
        }
    else
        log_info "Running fresh FreeScout installation..."
        if ! docker compose exec -T app php artisan freescout:install \
            --force \
            --email="$ADMIN_EMAIL" \
            --password="$ADMIN_PASS" \
            --first_name="${ADMIN_FIRST_NAME:-Admin}" \
            --last_name="${ADMIN_LAST_NAME:-User}"; then
            log_error "Failed artisan step: php artisan freescout:install"
            docker compose exec -T app php artisan up 2>/dev/null || true
            dump_failure_diagnostics
            return 1
        fi
    fi

    run_artisan_step "Running module migrations..." module:migrate --all --force || {
        docker compose exec -T app php artisan up 2>/dev/null || true
        return 1
    }

    # ── Seeding ───────────────────────────────────────────────────────────────
    log_info "Seeding modules..."
    # Use nwidart's native --all flag to seed every enabled module.
    # This is more reliable than piping PHP into tinker.
    docker compose exec -T app php artisan module:seed --all --force || true

    run_artisan_step "Seeding themes..." db:seed --class=ThemeSeeder --force

    # ── Cache Warming ──────────────────────────────────────────────────────────
    # Must run AFTER all migrations and seeders are complete.
    #
    # IMPORTANT: After config:cache is applied, any env() call outside a config
    # file returns null. This codebase correctly routes all env() through config().
    # Route closures cannot be cached — this app uses controller classes only. ✓
    log_info "Warming application caches..."
    run_artisan_step "Caching configuration (eliminates per-request config parsing)..." config:cache
    run_artisan_step "Caching routes (10-15x faster route resolution)..." route:cache
    run_artisan_step "Caching Blade views (eliminates first-hit compile cost)..." view:cache
    run_artisan_step "Caching event/listener map (faster module boot)..." event:cache

    # ── Queue Restart ─────────────────────────────────────────────────────────
    # Signals running queue workers to gracefully finish their current job and
    # restart, picking up the freshly cached config and new code.
    run_artisan_step "Signalling queue workers to restart with new code..." queue:restart

    # ── Back Online ───────────────────────────────────────────────────────────
    log_info "Exiting maintenance mode..."
    docker compose exec -T app php artisan up

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
    echo -e "     ${YELLOW}Service Type:${NC} HTTP  ${RED}(not HTTPS — tunnel handles TLS)${NC}"
    echo -e "     ${YELLOW}URL:${NC}          http://localhost:8080"
    echo -e "     ${YELLOW}Origin Name:${NC}  $DOMAIN_NAME"
    echo ""
    echo -e "  ${CYAN}ℹ  The Cloudflare tunnel encrypts the public-facing connection."
    echo -e "     No SSL is needed between cloudflared and this origin.${NC}"
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
    echo -e "  • Emergency: ${YELLOW}https://localhost:8443${NC} (accept cert warning) or ${YELLOW}http://localhost:8080${NC}"
    echo ""
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    show_banner
    if [ "$INTERACTIVE" = true ]; then
        # Check if pre-flight checks should be visible before menu?
        # User requested splashscreen FIRST.
        interactive_menu
        # After menu, run checks
        preflight_checks
    else
        preflight_checks
    fi

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

    log_info "Validating configuration..."

    # Validate required variables
    validate_required_var "DOMAIN_NAME" "${DOMAIN_NAME:-}"

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
    sync_modules_statuses
    patch_modules
    patch_database_seeder
    setup_storage_permissions
    build_and_launch_containers
    wait_for_database
    wait_for_app_database_connectivity
    install_dependencies
    finalize_installation

    # Queue workers and cron are safe to start now — all migrations have run,
    # the config cache is warm, and the jobs/failed_jobs tables exist.
    log_step "Starting Queue Workers & Cron"
    docker compose up -d queue cron
    log_success "Queue workers and cron scheduler started"

    deploy_cloudflared

    # Cleanup
    log_info "Pruning unused Docker resources..."
    docker image prune -f >/dev/null 2>&1 || true

    show_completion_message
}

deploy_cloudflared() {
    if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
        log_step "Checking Cloudflare Tunnel"

        local existing_tunnels
        existing_tunnels=$(docker ps --format "{{.ID}}|{{.Names}}|{{.Image}}" | grep -i "cloudflared" || true)

        local do_deploy_cf=true
        if [ -n "$existing_tunnels" ]; then
            log_warning "Existing cloudflared containers detected:"
            echo "$existing_tunnels" | while IFS='|' read -r id name image; do
                echo "  - $name ($id)"
            done

            if [ -t 0 ] || [ -c /dev/tty ]; then
                echo ""
                safe_read "Do you want to stop existing tunnel containers and redeploy the standalone utility? [y/N]: " redeploy_cf
                if [[ "$redeploy_cf" =~ ^[Yy]$ ]]; then
                    echo "$existing_tunnels" | while IFS='|' read -r id name image; do
                        log_info "Stopping $name..."
                        docker stop "$id" >/dev/null || true
                    done
                else
                    log_info "Skipping standalone cloudflared deployment."
                    do_deploy_cf=false
                fi
            else
                log_warning "Non-interactive mode: skipping standalone cloudflared deployment to avoid interrupting existing services."
                do_deploy_cf=false
            fi
        fi

        if [ "$do_deploy_cf" = true ]; then
            log_info "Deploying standalone Cloudflare Tunnel..."
            local cf_dir="$DEFAULT_INSTALL_DIR/src/deployment/docker/cloudflared"
            if [ -d "$cf_dir" ]; then
                cd "$cf_dir"
                echo "CF_TUNNEL_TOKEN=\"${CF_TUNNEL_TOKEN}\"" > .env
                docker compose up -d
                cd - >/dev/null
                log_success "Cloudflare Tunnel deployed"
            else
                log_error "Cloudflared directory not found at $cf_dir"
            fi
        fi
    fi
}

# Run main function
main "$@"
