#!/usr/bin/env bash

#===============================================================================
# TreeScout GCP Docker Update Utility
#
# Applies a new application release to an existing GCP Docker deployment:
#   1. Pulls latest source code from Git
#   2. Rebuilds the Docker application image (npm build runs in node-builder stage)
#   3. Performs a zero-downtime container swap (docker compose up -d)
#   4. Runs database migrations
#   5. Clears & rebuilds all caches
#   6. Updates APP_BUILD_COMMIT in the application .env
#
# Usage:
#   sudo bash /opt/treescout-docker/deployment/gcp/gcp_update.sh
#   sudo bash /opt/treescout-docker/deployment/gcp/gcp_update.sh --yes
#
# Requirements:
#   - Must be run as root or with sudo
#   - Docker & docker compose must be available
#   - Existing installation at /opt/treescout-docker
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# CONFIGURATION
#===============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="/opt/treescout-docker"
readonly SRC_DIR="${INSTALL_DIR}/src"
readonly APP_ENV="${INSTALL_DIR}/src/.env"
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly CONFIG_FILE="${SCRIPT_DIR}/deploy.conf.gcp"

# Colors (matching gcp_deploy.sh / docker_deploy.sh palette)
readonly RED='\033[38;5;196m'
readonly GREEN='\033[38;5;46m'
readonly YELLOW='\033[38;5;226m'
readonly CYAN='\033[38;5;51m'
readonly BLUE='\033[38;5;27m'
readonly MAGENTA='\033[38;5;201m'
readonly NC='\033[0m'

AUTO_APPROVE=false

#===============================================================================
# LOGGING HELPERS
#===============================================================================

log_info()    { echo -e "${CYAN}ℹ ${NC} $*"; }
log_success() { echo -e "${GREEN}✔${NC} $*"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $*"; }
log_error()   { echo -e "${RED}✖${NC} $*" >&2; }
log_step()    { echo ""; echo -e "${MAGENTA}➜${NC} ${BLUE}$*${NC}"; }
log_code()    { echo -e "  ${CYAN}$*${NC}"; }

#===============================================================================
# PRE-FLIGHT CHECKS
#===============================================================================

preflight_checks() {
    log_step "Pre-flight Checks"

    # Must be run as root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root or with sudo."
        log_code  "  sudo bash $0"
        exit 1
    fi

    # Verify install directory exists
    if [ ! -d "$INSTALL_DIR" ]; then
        log_error "Installation directory not found: $INSTALL_DIR"
        log_info  "Run gcp_deploy.sh first to set up the initial deployment."
        exit 1
    fi

    # Verify source directory exists
    if [ ! -d "$SRC_DIR/.git" ]; then
        log_error "Source repository not found at $SRC_DIR"
        log_info  "Expected a git-cloned working tree at $SRC_DIR"
        exit 1
    fi

    # Verify docker compose
    if ! command -v docker &>/dev/null; then
        log_error "docker not found on PATH"
        exit 1
    fi

    if ! docker compose version &>/dev/null; then
        log_error "docker compose (v2) not available"
        exit 1
    fi

    # Verify the app container is running
    if ! docker compose -f "$COMPOSE_FILE" ps --status running app 2>/dev/null | grep -q "app"; then
        log_warning "The 'app' container does not appear to be running."
        log_info    "Proceeding anyway — 'docker compose up -d' will start it."
    fi

    log_success "Pre-flight checks passed"
}

#===============================================================================
# LOAD CONFIGURATION
#===============================================================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_info "Loaded configuration from $(basename "$CONFIG_FILE")"
    else
        log_warning "deploy.conf.gcp not found — using defaults from git repository"
    fi
}

#===============================================================================
# SHOW BANNER
#===============================================================================

show_banner() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}TreeScout GCP Update Utility${NC}  ${BLUE}v${SCRIPT_VERSION}${NC}              ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BLUE}Install Dir:${NC}  $INSTALL_DIR"
    echo -e "  ${BLUE}Source Dir: ${NC}  $SRC_DIR"
    echo -e "  ${BLUE}Compose:    ${NC}  $COMPOSE_FILE"
    echo ""
}

#===============================================================================
# SHOW CURRENT AND REMOTE VERSIONS
#===============================================================================

show_versions() {
    log_step "Checking Versions"

    local current_commit
    current_commit=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local current_branch
    current_branch=$(git -C "$SRC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    log_info "Current branch:  $current_branch"
    log_info "Current commit:  $current_commit"

    log_info "Fetching remote ref..."
    git -C "$SRC_DIR" fetch origin "$current_branch" --quiet

    local remote_commit
    remote_commit=$(git -C "$SRC_DIR" rev-parse --short "origin/$current_branch" 2>/dev/null || echo "unknown")

    if [ "$current_commit" = "$remote_commit" ]; then
        log_success "Already up to date ($current_commit) — nothing to pull"
        if [ "$AUTO_APPROVE" = false ]; then
            echo ""
            read -p "Continue anyway (force rebuild)? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Update cancelled."
                exit 0
            fi
        fi
    else
        log_warning "Update available!"
        log_info    "  Current: $current_commit"
        log_info    "  Remote:  $remote_commit"
    fi
}

#===============================================================================
# PULL LATEST SOURCE
#===============================================================================

pull_source() {
    log_step "Pulling Latest Source Code"

    local branch
    branch=$(git -C "$SRC_DIR" rev-parse --abbrev-ref HEAD)

    git -C "$SRC_DIR" pull origin "$branch"

    local new_commit
    new_commit=$(git -C "$SRC_DIR" rev-parse HEAD)
    log_success "Source updated → $new_commit"

    # Persist full commit SHA for APP_BUILD_COMMIT update later
    NEW_COMMIT_SHA="$new_commit"
    NEW_COMMIT_SHORT=$(git -C "$SRC_DIR" rev-parse --short HEAD)
}

#===============================================================================
# REBUILD APPLICATION DOCKER IMAGE
#===============================================================================

rebuild_image() {
    log_step "Rebuilding Application Image"
    log_info  "This runs npm install + npm run build inside the node-builder stage"
    log_info  "and produces an immutable image with pre-compiled assets. This may take a few minutes."

    cd "$INSTALL_DIR"

    DOCKER_BUILDKIT=1 docker compose build app

    log_success "Application image rebuilt"
}

#===============================================================================
# RESTART CONTAINERS
#===============================================================================

restart_containers() {
    log_step "Restarting Containers"

    cd "$INSTALL_DIR"
    docker compose up -d

    log_success "Containers restarted"

    # Give the app a moment to boot before running artisan
    local max_wait=30
    local waited=0
    log_info "Waiting for application container to become healthy..."
    while [ $waited -lt $max_wait ]; do
        if docker compose exec -T app php artisan --version &>/dev/null 2>&1; then
            log_success "Application container is ready"
            return 0
        fi
        sleep 2
        (( waited+=2 ))
    done

    log_warning "App container did not respond within ${max_wait}s — proceeding anyway"
}

#===============================================================================
# RUN MIGRATIONS
#===============================================================================

run_migrations() {
    log_step "Running Database Migrations"

    cd "$INSTALL_DIR"
    docker compose exec -T app php artisan migrate --force

    log_success "Migrations complete"
}

#===============================================================================
# CLEAR CACHES
#===============================================================================

clear_caches() {
    log_step "Clearing & Rebuilding Caches"

    cd "$INSTALL_DIR"
    docker compose exec -T app php artisan optimize:clear
    docker compose exec -T app php artisan optimize

    log_success "Caches cleared and rebuilt"
}

#===============================================================================
# UPDATE APP_BUILD_COMMIT IN .ENV
#===============================================================================

update_build_commit() {
    if [ -z "${NEW_COMMIT_SHA:-}" ]; then
        return 0
    fi

    log_step "Updating APP_BUILD_COMMIT"

    if [ ! -f "$APP_ENV" ]; then
        log_warning ".env not found at $APP_ENV — skipping APP_BUILD_COMMIT update"
        return 0
    fi

    if grep -q "^APP_BUILD_COMMIT=" "$APP_ENV"; then
        sed -i "s|^APP_BUILD_COMMIT=.*|APP_BUILD_COMMIT=${NEW_COMMIT_SHA}|" "$APP_ENV"
        log_success "APP_BUILD_COMMIT → $NEW_COMMIT_SHORT"
    else
        echo "APP_BUILD_COMMIT=${NEW_COMMIT_SHA}" >> "$APP_ENV"
        log_success "APP_BUILD_COMMIT added → $NEW_COMMIT_SHORT"
    fi
}

#===============================================================================
# SHOW COMPLETION SUMMARY
#===============================================================================

show_completion() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}            ${GREEN}✔  Update Complete!${NC}                       ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BLUE}Deployed commit:${NC}  ${NEW_COMMIT_SHORT:-unknown}"
    echo ""
    echo -e "  To view live logs:"
    log_code "  docker compose -f $COMPOSE_FILE logs -f app"
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    # Parse flags
    for arg in "$@"; do
        case "$arg" in
            --yes|-y) AUTO_APPROVE=true ;;
        esac
    done

    if [ "${CI:-false}" = "true" ] || [ "${NONINTERACTIVE:-false}" = "true" ]; then
        AUTO_APPROVE=true
    fi

    show_banner
    preflight_checks
    load_config
    show_versions

    echo ""
    if [ "$AUTO_APPROVE" = true ]; then
        log_info "Proceeding with update (auto-approved)"
    else
        read -p "Proceed with update? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Update cancelled."
            exit 0
        fi
    fi

    pull_source
    rebuild_image
    restart_containers
    run_migrations
    clear_caches
    update_build_commit
    show_completion
}

main "$@"
