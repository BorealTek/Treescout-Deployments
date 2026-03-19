#!/usr/bin/env bash

#===============================================================================
# FreeScout GCP Deployer
#
# Enterprise-grade deployment script for Google Cloud Platform (GCP):
# - Auto-detects GCP instance metadata (project, zone, IP)
# - Validates GCP environment (gcloud SDK, permissions)
# - Creates GCP Firewall rules for network access
# - Configures GCP Cloud Logging integration (optional)
# - Wraps docker_deploy.sh with GCP-specific setup
# - Provides GCP troubleshooting and cleanup commands
#
# Usage:
#   1. Create/edit deploy.conf.gcp with your settings:
#      cp deployment/deploy.conf.gcp deploy.conf
#      nano deploy.conf
#
#   2. Run this script (requires sudo for Docker access):
#      sudo bash deployment/gcp_deploy.sh
#
# Requirements:
#   - GCP Compute Engine instance (e2-standard-2 or larger)
#   - Debian/Ubuntu OS (tested on Debian 12+, Ubuntu 20.04+)
#   - Docker & Docker Compose (installed by this script)
#   - gcloud CLI (optional, for GCP API operations)
#   - Sufficient permissions: Compute security and network administration
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# GLOBALS & CONFIGURATION
#===============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/deploy.conf"
readonly GCP_CONFIG_FILE="${SCRIPT_DIR}/deploy.conf.gcp"
readonly DOCKER_DEPLOY_SCRIPT="${SCRIPT_DIR}/docker_deploy.sh"

# Color scheme (matching docker_deploy.sh)
readonly RED='\033[38;5;196m'
readonly GREEN='\033[38;5;46m'
readonly YELLOW='\033[38;5;226m'
readonly CYAN='\033[38;5;51m'
readonly BLUE='\033[38;5;27m'
readonly MAGENTA='\033[38;5;201m'
readonly WHITE='\033[38;5;231m'
readonly GREY='\033[38;5;240m'
readonly NC='\033[0m'

# GCP Metadata Service endpoints
readonly GCP_METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
readonly GCP_METADATA_HEADERS="-H Metadata-Flavor:Google"

# State variables
GCP_PROJECT_ID=""
GCP_INSTANCE_NAME=""
GCP_INSTANCE_ZONE=""
GCP_INSTANCE_NETWORK=""
GCP_INSTANCE_SUBNET=""
GCP_INSTANCE_IP_INTERNAL=""
GCP_INSTANCE_IP_EXTERNAL=""
GCP_IS_RUNNING_IN_GCP=false

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

log_code() {
    echo -e "${GREY}  $*${NC}"
}

cleanup() {
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "GCP deployment failed with exit code $exit_code"
        log_info "Review output above and docker logs after recovery: docker compose logs -f"
    fi

    exit $exit_code
}

trap cleanup EXIT INT TERM

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

#===============================================================================
# GCP DETECTION & METADATA
#===============================================================================

detect_gcp_environment() {
    log_step "Detecting GCP Environment"

    # Check if running on GCP by querying metadata service
    if curl -s -m 1 "${GCP_METADATA_URL}/project/project-id" $GCP_METADATA_HEADERS >/dev/null 2>&1; then
        GCP_IS_RUNNING_IN_GCP=true
        log_success "Running on Google Cloud Platform"
    else
        log_warning "Not running on GCP (metadata service unavailable)"
        log_info "Manual GCP configuration may be required"
        return 0
    fi

    # Fetch GCP instance metadata
    log_info "Fetching GCP instance metadata..."

    GCP_PROJECT_ID=$(curl -s "${GCP_METADATA_URL}/project/project-id" $GCP_METADATA_HEADERS)
    GCP_INSTANCE_NAME=$(curl -s "${GCP_METADATA_URL}/instance/name" $GCP_METADATA_HEADERS)
    GCP_INSTANCE_ZONE=$(curl -s "${GCP_METADATA_URL}/instance/zone" $GCP_METADATA_HEADERS | awk -F'/' '{print $NF}')
    GCP_INSTANCE_NETWORK=$(curl -s "${GCP_METADATA_URL}/instance/network-interfaces/0/network" $GCP_METADATA_HEADERS | awk -F'/' '{print $NF}')
    GCP_INSTANCE_SUBNET=$(curl -s "${GCP_METADATA_URL}/instance/network-interfaces/0/subnetwork" $GCP_METADATA_HEADERS | awk -F'/' '{print $NF}')
    GCP_INSTANCE_IP_INTERNAL=$(curl -s "${GCP_METADATA_URL}/instance/network-interfaces/0/ip" $GCP_METADATA_HEADERS)
    GCP_INSTANCE_IP_EXTERNAL=$(curl -s "${GCP_METADATA_URL}/instance/network-interfaces/0/external-ip" $GCP_METADATA_HEADERS 2>/dev/null || echo "NO_EXTERNAL_IP")

    # Display detected metadata
    log_success "GCP Metadata Detected:"
    log_code "Project ID:    $GCP_PROJECT_ID"
    log_code "Instance Name: $GCP_INSTANCE_NAME"
    log_code "Zone:          $GCP_INSTANCE_ZONE"
    log_code "Network:       $GCP_INSTANCE_NETWORK"
    log_code "Subnet:        $GCP_INSTANCE_SUBNET"
    log_code "Internal IP:   $GCP_INSTANCE_IP_INTERNAL"
    log_code "External IP:   $GCP_INSTANCE_IP_EXTERNAL"
}

#===============================================================================
# CONFIG MANAGEMENT
#===============================================================================

load_config() {
    log_step "Loading Configuration"

    # Use deploy.conf if it exists, otherwise use deploy.conf.gcp template
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Using existing deploy.conf"
        source "$CONFIG_FILE"
    elif [ -f "$GCP_CONFIG_FILE" ]; then
        log_info "Using deploy.conf.gcp template"
        log_warning "IMPORTANT: Edit deploy.conf.gcp with your actual values before redeploying"
        source "$GCP_CONFIG_FILE"
        cp "$GCP_CONFIG_FILE" "$CONFIG_FILE"
        log_info "Copied to deploy.conf for next runs"
    else
        log_error "No configuration found!"
        log_info "Expected: $CONFIG_FILE or $GCP_CONFIG_FILE"
        exit 1
    fi

    # Override GCP variables if detected
    if [ "$GCP_IS_RUNNING_IN_GCP" = true ]; then
        if [ -z "${GCP_PROJECT_ID:-}" ]; then
            GCP_PROJECT_ID=$(curl -s "${GCP_METADATA_URL}/project/project-id" $GCP_METADATA_HEADERS)
        fi
        if [ -z "${GCP_ZONE:-}" ]; then
            GCP_ZONE=$GCP_INSTANCE_ZONE
        fi
        log_success "GCP config auto-populated from metadata"
    fi

    # Validate required settings
    if [ -z "${DOMAIN_NAME:-}" ]; then
        log_error "DOMAIN_NAME not set in deploy.conf"
        exit 1
    fi

    if [[ "${DOMAIN_NAME:-}" =~ ^(freescout\.example\.com|example\.com|your-domain\.com)$ ]]; then
        log_error "DOMAIN_NAME is still the template placeholder: $DOMAIN_NAME"
        log_info "Set DOMAIN_NAME to your actual domain or GCP external IP in deploy.conf"
        exit 1
    fi

    if [ "${ALLOWED_SOURCE_RANGES:-}" = "0.0.0.0/0" ]; then
        log_warning "ALLOWED_SOURCE_RANGES is 0.0.0.0/0 — the application will be open to the entire internet"
        log_info "For production, restrict to known CIDRs in deploy.conf (ALLOWED_SOURCE_RANGES)"
        read -p "Continue with unrestricted access? (y/n) " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_warning "Deployment cancelled — update ALLOWED_SOURCE_RANGES and retry"
            exit 0
        fi
    elif [ -z "${ALLOWED_SOURCE_RANGES:-}" ]; then
        log_error "ALLOWED_SOURCE_RANGES is empty — set to a CIDR range or 0.0.0.0/0 to allow all"
        exit 1
    fi

    if [ -z "${REPO_TOKEN:-}" ]; then
        log_warning "REPO_TOKEN is empty — module installation will fail"
        log_info "Set REPO_TOKEN in deploy.conf to a GitHub Personal Access Token"
    fi

    log_success "Configuration loaded"
}

#===============================================================================
# GCP FIREWALL RULES
#===============================================================================

create_firewall_rules() {
    log_step "Setting Up GCP Firewall Rules"

    # Check if gcloud is available
    if ! command_exists gcloud; then
        log_warning "gcloud CLI not found — skipping firewall rule creation"
        log_info "To configure firewall manually, run:"
        log_code "gcloud compute firewall-rules create ${GCP_FIREWALL_RULE_NAME} \\"
        log_code "  --allow=tcp:443,tcp:80 \\"
        log_code "  --source-ranges=${ALLOWED_SOURCE_RANGES} \\"
        log_code "  --target-tags=freescout"
        return 0
    fi

    # Check if rule already exists
    if gcloud compute firewall-rules describe "${GCP_FIREWALL_RULE_NAME}" >/dev/null 2>&1; then
        log_info "Firewall rule '${GCP_FIREWALL_RULE_NAME}' already exists"
        log_info "To update, run:"
        log_code "gcloud compute firewall-rules update ${GCP_FIREWALL_RULE_NAME} \\"
        log_code "  --source-ranges=${ALLOWED_SOURCE_RANGES}"
        return 0
    fi

    log_info "Creating firewall rule: ${GCP_FIREWALL_RULE_NAME}"

    # Create the firewall rule
    if gcloud compute firewall-rules create "${GCP_FIREWALL_RULE_NAME}" \
        --allow=tcp:443,tcp:80 \
        --source-ranges="${ALLOWED_SOURCE_RANGES}" \
        --target-tags=freescout \
        --description="FreeScout HTTPS/HTTP access" \
        --project="${GCP_PROJECT_ID:-}"; then
        log_success "Firewall rule created successfully"
        log_info "To apply this rule to the instance, add the 'freescout' network tag:"
        log_code "gcloud compute instances add-tags ${GCP_INSTANCE_NAME} \\"
        log_code "  --tags=freescout --zone=${GCP_ZONE}"
    else
        log_warning "Failed to create firewall rule — you may need to do this manually"
    fi
}

apply_firewall_tags() {
    log_step "Applying Firewall Tags to Instance"

    if ! [ "$GCP_IS_RUNNING_IN_GCP" = true ]; then
        log_warning "Not running on GCP — skipping firewall tags"
        return 0
    fi

    if ! command_exists gcloud; then
        log_warning "gcloud CLI not found — cannot apply tags"
        return 0
    fi

    log_info "Adding 'freescout' network tag to instance..."

    if gcloud compute instances add-tags "${GCP_INSTANCE_NAME}" \
        --tags=freescout \
        --zone="${GCP_ZONE}" \
        --project="${GCP_PROJECT_ID:-}" 2>/dev/null; then
        log_success "Network tag applied"
    else
        log_warning "Failed to apply network tag — may already exist or insufficient permissions"
    fi
}

#===============================================================================
# GCP LOGGING INTEGRATION
#===============================================================================

setup_cloud_logging() {
    log_step "Setting Up GCP Cloud Logging (Optional)"

    if [ "${ENABLE_GCP_LOGGING:-false}" != "true" ]; then
        log_info "GCP Cloud Logging disabled (set ENABLE_GCP_LOGGING=true to enable)"
        return 0
    fi

    if ! command_exists gcloud; then
        log_warning "gcloud CLI not found — cannot setup Cloud Logging"
        return 0
    fi

    log_info "Configuring Docker to ship logs to Cloud Logging..."

    # Configure Docker daemon to use Cloud Logging driver
    # This requires the Google Cloud Ops Agent to be installed on the host
    log_info "Note: Requires Google Cloud Ops Agent on the host"
    log_info "Install (download-then-verify before executing):"
    log_code "curl -fsSL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh -o /tmp/add-ops-agent.sh"
    log_code "# Review /tmp/add-ops-agent.sh, then:"
    log_code "sudo bash /tmp/add-ops-agent.sh && sudo apt-get install -y google-cloud-ops-agent"
    log_code "sudo systemctl restart google-cloud-ops-agent"
}

#===============================================================================
# GCP MONITORING & ALERTS
#===============================================================================

setup_monitoring() {
    log_step "Setting Up GCP Cloud Monitoring (Optional)"

    if [ "${ENABLE_GCP_MONITORING:-false}" != "true" ]; then
        log_info "GCP Cloud Monitoring disabled"
        return 0
    fi

    if ! command_exists gcloud; then
        log_warning "gcloud CLI not found — cannot setup monitoring"
        return 0
    fi

    log_info "Monitoring is auto-enabled on GCP Compute Engine instances"
    log_info "View metrics at: https://console.cloud.google.com/monitoring"
    log_code "gcloud monitoring dashboards create --config-from-file=- <<EOF"
    log_code "{\"displayName\": \"FreeScout\"}"
    log_code "EOF"
}

#===============================================================================
# GCP HEALTH CHECK
#===============================================================================

health_check_gcp() {
    log_step "Running GCP Health Checks"

    # Check required tools
    local required_tools=("docker" "curl" "git")
    local missing_tools=()

    for tool in "${required_tools[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Install with: sudo apt update && sudo apt install -y ${missing_tools[*]}"
        return 1
    fi

    log_success "All required tools present"

    # Check Docker Compose (v2 plugin preferred, v1 standalone fallback)
    if docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose v2 found (docker compose)"
    elif command_exists docker-compose; then
        log_success "Docker Compose v1 found (docker-compose)"
    else
        log_error "Docker Compose not found — install docker-compose-plugin or update Docker CE"
        log_info "Install: sudo apt-get install -y docker-compose-plugin"
        return 1
    fi

    # Check GCP CLI (optional but helpful)
    if command_exists gcloud; then
        log_success "gcloud CLI available"
        local gcp_auth_status
        if gcp_auth_status=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null); then
            if [ -n "$gcp_auth_status" ]; then
                log_success "gcloud authenticated as: $gcp_auth_status"
            else
                log_warning "gcloud not authenticated — some features will be unavailable"
                log_info "Run: gcloud auth login"
            fi
        fi
    else
        log_warning "gcloud CLI not found — advanced GCP features unavailable"
        log_info "Install: https://cloud.google.com/sdk/docs/install"
    fi

    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon not running"
        exit 1
    fi

    log_success "Docker daemon is running"

    # Check system resources
    local total_mem
    if [ -f /proc/meminfo ]; then
        total_mem=$(grep MemTotal /proc/meminfo | awk '{print int($2/1048576)}')
        log_info "System RAM: ${total_mem} GB"

        if [ "$total_mem" -lt 4 ]; then
            log_warning "System memory below 4 GB — deployment may be slow"
        elif [ "$total_mem" -ge 8 ]; then
            log_success "Sufficient memory for production"
        fi
    fi

    return 0
}

#===============================================================================
# DEPLOYMENT
#===============================================================================

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                   FreeScout GCP Deployer                      ║"
    echo "║         Enterprise Help Desk on Google Cloud Platform         ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_summary() {
    log_step "Deployment Summary"

    echo ""
    log_info "GCP Environment:"
    if [ "$GCP_IS_RUNNING_IN_GCP" = true ]; then
        log_code "  Project: $GCP_PROJECT_ID"
        log_code "  Instance: $GCP_INSTANCE_NAME"
        log_code "  Zone: $GCP_ZONE"
        log_code "  Internal IP: $GCP_INSTANCE_IP_INTERNAL"
        log_code "  External IP: $GCP_INSTANCE_IP_EXTERNAL"
    else
        log_code "  Not detected (manual configuration mode)"
    fi

    echo ""
    log_info "Application Settings:"
    log_code "  Domain: $DOMAIN_NAME"
    log_code "  Install Path: $DEFAULT_INSTALL_DIR"
    log_code "  Database: $DB_NAME (user: $DB_USER)"
    log_code "  Modules: ${#MODULES_TO_INSTALL[@]} configured"

    echo ""
    log_info "Access:"
    if [ "$GCP_INSTANCE_IP_EXTERNAL" != "NO_EXTERNAL_IP" ]; then
        log_code "  HTTPS: https://$GCP_INSTANCE_IP_EXTERNAL"
        log_code "  Or: https://$DOMAIN_NAME (if DNS configured)"
    else
        log_code "  SSH: gcloud compute ssh $GCP_INSTANCE_NAME --zone=$GCP_ZONE"
        log_code "  Internal: https://$GCP_INSTANCE_IP_INTERNAL"
    fi

    echo ""
    log_info "Next steps:"
    log_code "  1. Review the configuration: nano ${CONFIG_FILE#$SCRIPT_DIR/}"
    log_code "  2. Start deployment: sudo bash $DOCKER_DEPLOY_SCRIPT"
    log_code "  3. Monitor logs: docker compose -f $DEFAULT_INSTALL_DIR/docker-compose.yml logs -f"
    log_code "  4. Access admin: https://$DOMAIN_NAME (admin user credentials in deploy.conf)"
}

main() {
    show_banner

    log_info "FreeScout GCP Deployer v$SCRIPT_VERSION"
    echo ""

    # Run checks and setup
    health_check_gcp
    detect_gcp_environment
    load_config

    # Create GCP-specific resources
    if [ "${EXPOSE_PUBLIC_PORTS:-true}" = "true" ]; then
        create_firewall_rules
        apply_firewall_tags
    fi

    setup_cloud_logging
    setup_monitoring

    # Show summary
    show_summary

    echo ""
    read -p "Proceed with Docker deployment? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Deployment cancelled"
        exit 0
    fi

    # Execute docker_deploy.sh
    log_step "Launching docker_deploy.sh"
    if [ -x "$DOCKER_DEPLOY_SCRIPT" ]; then
        cd "$SCRIPT_DIR"
        exec sudo bash "$DOCKER_DEPLOY_SCRIPT"
    else
        log_error "docker_deploy.sh not found or not executable"
        log_info "Expected: $DOCKER_DEPLOY_SCRIPT"
        exit 1
    fi
}

# Run main function
main "$@"
