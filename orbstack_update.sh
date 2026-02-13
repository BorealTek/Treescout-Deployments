#!/usr/bin/env bash

#===============================================================================
# FreeScout OrbStack Quick Update Script
# 
# Fast update script for pulling latest code and restarting containers
# without full rebuild. Use this for quick deployments after git commits.
#
# Features:
# - Bash strict mode
# - Configuration file support
# - Progress indicators
# - Error handling
# - Cache optimization
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# GLOBALS & CONFIGURATION
#===============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

cleanup() {
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "Update failed with exit code $exit_code"
    fi
    
    exit $exit_code
}

trap cleanup EXIT INT TERM

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

#===============================================================================
# MAIN FUNCTIONS
#===============================================================================

show_banner() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}║         FreeScout Quick Update v${SCRIPT_VERSION}                  ║${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

load_configuration() {
    log_step "Loading Configuration"
    
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Loading from $CONFIG_FILE..."
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        INSTALL_DIR="${DEFAULT_INSTALL_DIR:-$HOME/borealtek-ticketing}"
    else
        log_warning "No deploy.conf found, using current directory"
        INSTALL_DIR="$(pwd)"
    fi
    
    log_success "Install directory: $INSTALL_DIR"
}

verify_installation() {
    log_step "Verifying Installation"
    
    if [ ! -d "$INSTALL_DIR" ]; then
        log_error "Install directory not found: $INSTALL_DIR"
        exit 1
    fi
    
    cd "$INSTALL_DIR"
    
    if [ ! -f "docker-compose.yml" ]; then
        log_error "docker-compose.yml not found. Is this a valid installation?"
        exit 1
    fi
    
    if [ ! -d "src" ]; then
        log_error "src directory not found. Is this a valid installation?"
        exit 1
    fi
    
    # Check Docker
    if ! command_exists docker; then
        log_error "Docker not found. Install OrbStack or Docker Desktop."
        exit 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running"
        exit 1
    fi
    
    log_success "Installation verified"
}

pull_latest_code() {
    log_step "Pulling Latest Code"
    
    cd "$INSTALL_DIR/src"
    
    # Get current branch
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    
    log_info "Current branch: $current_branch"
    
    # Check for uncommitted changes
    if [ -n "$(git status --porcelain)" ]; then
        log_warning "Uncommitted changes detected"
        
        if [ -t 0 ]; then
            read -rp "Stash changes and continue? [y/N] " stash_opt
            if [[ "$stash_opt" =~ ^[Yy]$ ]]; then
                log_info "Stashing changes..."
                git stash
            else
                log_error "Cannot pull with uncommitted changes"
                exit 1
            fi
        else
            log_error "Cannot pull with uncommitted changes in non-interactive mode"
            exit 1
        fi
    fi
    
    log_info "Fetching from origin..."
    git fetch origin
    
    log_info "Pulling latest changes..."
    git pull origin "$current_branch"
    
    cd "$INSTALL_DIR"
    
    log_success "Code updated"
}

pull_docker_images() {
    log_step "Pulling Latest Docker Images"
    
    log_info "Checking for base image updates..."
    docker compose pull 2>&1 | grep -v "Pulling" || true
    
    log_success "Docker images updated"
}

restart_containers() {
    log_step "Restarting Containers"
    
    log_info "Stopping containers..."
    docker compose down
    
    log_info "Starting containers..."
    docker compose up -d
    
    log_success "Containers restarted"
}

wait_for_app() {
    log_step "Waiting for Application"
    
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T app php artisan --version >/dev/null 2>&1; then
            log_success "Application is ready"
            return 0
        fi
        
        ((attempt++))
        echo -ne "\r${CYAN}⏳${NC} Attempt $attempt/$max_attempts..."
        sleep 2
    done
    
    log_error "Application failed to become ready"
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

run_migrations() {
    log_step "Running Database Migrations"
    
    log_info "Checking for pending migrations..."
    docker compose exec -T app php artisan migrate --force
    
    log_info "Running module migrations..."
    docker compose exec -T app php artisan module:migrate --all --force
    
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

    log_success "Migrations complete"
}

clear_caches() {
    log_step "Clearing Application Caches"
    
    log_info "Clearing cache..."
    docker compose exec -T app php artisan cache:clear
    
    log_info "Clearing config cache..."
    docker compose exec -T app php artisan config:clear
    
    log_info "Clearing view cache..."
    docker compose exec -T app php artisan view:clear
    
    log_info "Clearing route cache..."
    docker compose exec -T app php artisan route:clear
    
    log_success "Caches cleared"
}

optimize_application() {
    log_step "Optimizing Application"
    
    log_info "Caching configuration..."
    docker compose exec -T app php artisan config:cache
    
    log_info "Caching routes..."
    docker compose exec -T app php artisan route:cache
    
    log_info "Caching views..."
    docker compose exec -T app php artisan view:cache
    
    log_success "Application optimized"
}

show_container_status() {
    log_step "Container Status"
    
    docker compose ps
}

show_completion_message() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}║                  ${GREEN}✓${NC} UPDATE COMPLETE ${GREEN}✓${NC}                      ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo -e "  • View logs:      ${YELLOW}docker compose logs -f${NC}"
    echo -e "  • Check services: ${YELLOW}docker compose ps${NC}"
    echo -e "  • Stop all:       ${YELLOW}docker compose down${NC}"
    echo ""
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    show_banner
    load_configuration
    verify_installation
    pull_latest_code
    pull_docker_images
    restart_containers
    wait_for_app
    install_dependencies
    run_migrations
    clear_caches
    optimize_application
    
    echo ""
    show_container_status
    show_completion_message
}

# Run main function
main "$@"
