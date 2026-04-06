#!/usr/bin/env bash
# ==============================================================================
# TreeScout GCP Workstation Setup & Assertion Tool
#
# Run this from your Windows workstation (Git Bash, WSL2, or macOS Terminal)
# ONCE before first deploy, and anytime you need to assert / repair the setup.
#
# Usage:
#   bash deployment/gcp/gcp-workstation-setup.sh                           # interactive
#   bash deployment/gcp/gcp-workstation-setup.sh --from-file=secrets.conf  # non-interactive
#   bash deployment/gcp/gcp-workstation-setup.sh --from-file=secrets.conf --yes
#   bash deployment/gcp/gcp-workstation-setup.sh --from-file=secrets.conf --skip-deploy
#
# What this script does (idempotent — safe to run repeatedly):
#   1. Selects / confirms the GCP project
#   2. Enables required APIs  (Compute Engine, Secret Manager, IAM)
#   3. Creates or asserts the Compute Engine instance
#        - Correct machine type, disk size, and zone
#        - cloud-platform OAuth scope  (required for Secret Manager access)
#        - Network tag for firewall targeting
#   4. Grants the Compute default service account secretmanager.secretAccessor
#   5. Creates / asserts the HTTPS+HTTP firewall rule
#   6. Pushes all secrets from secrets.conf to GCP Secret Manager
#   7. Stores non-secret config (domain, emails, etc.) as instance custom metadata
#        → The server-side script reads these; no deploy.conf ever touches the VM
#   8. Offers to SSH into the VM and run gcp-server-init.sh automatically
#
# Compatibility:
#   - Git Bash on Windows  (requires gcloud CLI on PATH)
#   - WSL2 / Ubuntu
#   - macOS Terminal
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
readonly FOREST='\033[38;5;22m'
readonly COLOR_DIM="$GREY"

log_info()    { echo -e "${CYAN}ℹ ${NC} $*"; }
log_success() { echo -e "${GREEN}✔${NC} $*"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $*"; }
log_error()   { echo -e "${RED}✖${NC} $*" >&2; }
log_step()    { echo ""; echo -e "${MAGENTA}━━━ ${BLUE}$*${NC}"; }
log_code()    { echo -e "${GREY}  ↳ $*${NC}"; }

# ==============================================================================
# GLOBALS
# ==============================================================================

PROJECT_ID=""
CONFIG_FILE=""
AUTO_APPROVE=false
SKIP_DEPLOY=false
ERRORS=0
START_SECTION="full"

# Defaults (overridden by secrets.conf)
GCP_ZONE="us-central1-a"
GCP_INSTANCE_NAME="treescout-prod"
GCP_MACHINE_TYPE="e2-standard-2"
GCP_DISK_SIZE="50"
GCP_NETWORK_TAG="treescout"
GCP_FIREWALL_RULE_NAME="allow-treescout-https"
GCP_SSH_FIREWALL_RULE_NAME="allow-treescout-iap-ssh"
ALLOWED_SOURCE_RANGES="0.0.0.0/0"
DOCKER_SUBNET="172.20.0.0/16"
DB_USER="treescout"
DB_NAME="treescout"
DB_HOST="db"
GIT_REPO_URL="https://github.com/BorealTek/Treescout-Core.git"
GIT_BRANCH="main"
MODULE_DIR_POLICY="replace" # skip|replace|abort|ask
DEFAULT_INSTALL_DIR="/opt/treescout-docker"
EXPOSE_PUBLIC_PORTS="true"
ENABLE_HTTPS="true"
TLS_EMAIL=""
ENABLE_KROKI="false"
ENABLE_GCP_LOGGING="false"

# Required (must be supplied in secrets.conf or interactively)
DOMAIN_NAME=""
ADMIN_EMAIL=""
ADMIN_FIRST_NAME="System"
ADMIN_LAST_NAME="Administrator"

# Secrets (pushed to Secret Manager)
APP_KEY=""
REPO_TOKEN=""
DOCKER_TOKEN=""
DB_ROOT_PASS=""
DB_PASS=""
ADMIN_PASS=""
AGENT_PASS=""
FINANCE_PASS=""
REPORTER_PASS=""
GOOGLE_CLIENT_ID=""
GOOGLE_CLIENT_SECRET=""
GOOGLE_ADMIN_EMAILS=""
GOOGLE_ALLOWED_DOMAINS=""
ACTION1_SYNC_CLIENT_ID=""
ACTION1_SYNC_CLIENT_SECRET=""
ACTION1_AUTOMATION_RUNNER_CLIENT_ID=""
ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET=""
ACTION1_SCRIPT_MANAGER_CLIENT_ID=""
ACTION1_SCRIPT_MANAGER_CLIENT_SECRET=""
ACTION1_REGION="us"

# GoDaddy DNS (optional — auto-registers A record on first deploy)
GODADDY_API_KEY=""
GODADDY_API_SECRET=""

# Optional seeded users
AGENT_EMAIL=""
AGENT_FIRST_NAME="Support"
AGENT_LAST_NAME="Agent"
FINANCE_EMAIL=""
FINANCE_FIRST_NAME="Finance"
FINANCE_LAST_NAME="Manager"
REPORTER_EMAIL=""
REPORTER_FIRST_NAME="Report"
REPORTER_LAST_NAME="Viewer"

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

for arg in "$@"; do
    case "$arg" in
        --from-file=*) CONFIG_FILE="${arg#--from-file=}" ;;
        --project=*)   PROJECT_ID="${arg#--project=}" ;;
        --start-at=*)  START_SECTION="${arg#--start-at=}" ;;
        --yes|-y)      AUTO_APPROVE=true ;;
        --skip-deploy) SKIP_DEPLOY=true ;;
        -h|--help)
            sed -n '3,25p' "$0"   # Print the header comment
            exit 0
            ;;
    esac
done

if [ "${CI:-false}" = "true" ] || [ "${NONINTERACTIVE:-false}" = "true" ]; then
    AUTO_APPROVE=true
fi

# Auto-detect secrets.conf in CWD or script dir
if [ -z "$CONFIG_FILE" ]; then
    for candidate in "secrets.conf" "${SCRIPT_DIR}/../secrets.conf" "${SCRIPT_DIR}/secrets.conf"; do
        if [ -f "$candidate" ]; then
            CONFIG_FILE="$candidate"
            break
        fi
    done
fi

# ==============================================================================
# BANNER
# ==============================================================================

show_banner() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${FOREST}       # #### ####${NC}"
    echo -e "${FOREST}     ### \\/#|### |/####${NC}"
    echo -e "${FOREST}    ##\\/#/ \\||/##/_/##/_#${NC}      ${CYAN}  ____                        _ _______   _          ${NC}"
    echo -e "${FOREST}  ###  \\/###|/ \\/ # ###${NC}        ${CYAN} |  _ \\                      | |__   __| | |        ${NC}"
    echo -e "${FOREST} ##_\\_#\\_\\## | #/###_/_####${NC}   ${CYAN}  | |_) | ___   _ __.__  ___  | |  | |  __| | __     ${NC}"
    echo -e "${FOREST}## #### # \\ #| /  #### ##/##${NC}    ${CYAN}|  _ < / _ \\| '__/ _ \\/ _ \\\`| |  | |/ _ \\ |/ /     ${NC}"
    echo -e "${FOREST} __#_--###\`  |{,###---###-~${NC}     ${CYAN}| |_) | (_) | |  | __/ (_| || |  | || __/   <        ${NC}"
    echo -e "${FOREST}           \\ }{${NC}                 ${CYAN}|____/ \\___/|_|  \\___|\\__,_||_|  |_|\\___|_|\\_\\ ${NC}"
    echo -e "${FOREST}            }}{${NC}"
    echo -e "${FOREST}            }}{${NC}             ${GREEN} T R E E S C O U T   G C P   W O R K S T A T I O N ${NC}"
    echo -e "${FOREST}            }}{${NC}"
    echo -e "${FOREST}      , -=-~{ .-^- _${NC}"
    echo -e "${FOREST}            \`${NC}"
    if [ -n "$CONFIG_FILE" ]; then
        echo -e "   Config: ${GREY}$CONFIG_FILE${NC}"
    fi
    echo -e "${COLOR_DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
}

normalize_start_section() {
    case "$START_SECTION" in
        0|full|all|run) START_SECTION="full" ;;
        1|project|config|prereqs) START_SECTION="prereqs" ;;
        2|apis) START_SECTION="apis" ;;
        3|instance) START_SECTION="instance" ;;
        4|iam) START_SECTION="iam" ;;
        5|firewall) START_SECTION="firewall" ;;
        6|secrets) START_SECTION="secrets" ;;
        7|metadata) START_SECTION="metadata" ;;
        8|verify|verify-secrets) START_SECTION="verify" ;;
        9|bootstrap|deploy) START_SECTION="bootstrap" ;;
        *)
            log_warning "Unknown --start-at target '$START_SECTION' — defaulting to full run."
            START_SECTION="full"
            ;;
    esac
}

prompt_start_section() {
    normalize_start_section

    if [ "$AUTO_APPROVE" = true ]; then
        return
    fi

    echo -e "${CYAN}Start Options${NC}"
    echo -e "  ${GREY}[0]${NC} Full run"
    echo -e "  ${GREY}[1]${NC} Jump to config + auth"
    echo -e "  ${GREY}[2]${NC} Jump to API enablement"
    echo -e "  ${GREY}[3]${NC} Jump to instance assertion"
    echo -e "  ${GREY}[4]${NC} Jump to IAM grant"
    echo -e "  ${GREY}[5]${NC} Jump to firewall checks"
    echo -e "  ${GREY}[6]${NC} Jump to secrets push"
    echo -e "  ${GREY}[7]${NC} Jump to metadata write"
    echo -e "  ${GREY}[8]${NC} Jump to secret verification"
    echo -e "  ${GREY}[9]${NC} Jump to bootstrap only"
    echo ""

    local choice=""
    read -r -p "  Select start section [0-9] (Enter for full run): " choice
    [ -z "$choice" ] && choice="0"
    START_SECTION="$choice"
    normalize_start_section
}

run_selected_sections() {
    case "$START_SECTION" in
        full)
            enable_apis
            assert_or_create_instance
            grant_iam_role
            assert_firewall_rule
            push_secrets
            set_instance_metadata
            verify_secrets
            show_summary
            offer_server_bootstrap
            ;;
        prereqs)
            show_summary
            offer_server_bootstrap
            ;;
        apis)
            enable_apis
            assert_or_create_instance
            grant_iam_role
            assert_firewall_rule
            push_secrets
            set_instance_metadata
            verify_secrets
            show_summary
            offer_server_bootstrap
            ;;
        instance)
            assert_or_create_instance
            grant_iam_role
            assert_firewall_rule
            push_secrets
            set_instance_metadata
            verify_secrets
            show_summary
            offer_server_bootstrap
            ;;
        iam)
            grant_iam_role
            assert_firewall_rule
            push_secrets
            set_instance_metadata
            verify_secrets
            show_summary
            offer_server_bootstrap
            ;;
        firewall)
            assert_firewall_rule
            push_secrets
            set_instance_metadata
            verify_secrets
            show_summary
            offer_server_bootstrap
            ;;
        secrets)
            push_secrets
            set_instance_metadata
            verify_secrets
            show_summary
            offer_server_bootstrap
            ;;
        metadata)
            set_instance_metadata
            verify_secrets
            show_summary
            offer_server_bootstrap
            ;;
        verify)
            verify_secrets
            show_summary
            offer_server_bootstrap
            ;;
        bootstrap)
            show_summary
            offer_server_bootstrap
            ;;
    esac
}

# ==============================================================================
# CONFIG LOADING
# ==============================================================================

load_config() {
    log_step "Loading configuration"

    if [ -n "$CONFIG_FILE" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            log_error "Config file not found: $CONFIG_FILE"
            exit 1
        fi

        # Strip Windows line endings (CRLF -> LF) to prevent invisible bugs
        sed -i 's/\r$//' "$CONFIG_FILE" 2>/dev/null || true

        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        log_success "Loaded: $CONFIG_FILE"
    else
        log_info "No config file specified — using interactive prompts for required values"
    fi

    # Support GCP_PROJECT_ID alias (used in gcp-secrets-bootstrap.sh template)
    if [ -z "$PROJECT_ID" ] && [ -n "${GCP_PROJECT_ID:-}" ]; then
        PROJECT_ID="$GCP_PROJECT_ID"
    fi

    # Override PROJECT_ID from env if set
    if [ -n "${CLOUDSDK_CORE_PROJECT:-}" ]; then
        PROJECT_ID="${CLOUDSDK_CORE_PROJECT}"
    fi
}

# ==============================================================================
# PREREQUISITES — gcloud, auth, project selection
# ==============================================================================

check_prereqs() {
    log_step "Checking prerequisites"

    if ! command -v gcloud >/dev/null 2>&1; then
        log_error "gcloud CLI not found."
        log_info "Install from: https://cloud.google.com/sdk/docs/install"
        if uname -r 2>/dev/null | grep -qi microsoft; then
            log_info "WSL detected — install gcloud inside WSL:"
            log_code "curl https://sdk.cloud.google.com | bash"
        fi
        exit 1
    fi
    log_success "gcloud CLI found: $(gcloud version --format='value(Google Cloud SDK)' 2>/dev/null || echo 'version unknown')"

    local active_account
    active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    if [ -z "$active_account" ]; then
        log_warning "Not authenticated — launching gcloud auth login..."
        gcloud auth login --update-adc
        active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    fi
    if [ -z "$active_account" ]; then log_error "Authentication failed. Run: gcloud auth login"; exit 1; fi
    log_success "Authenticated as: $active_account"

    # Project selection
    if [ -z "$PROJECT_ID" ]; then
        local cfg_project
        cfg_project=$(gcloud config get-value project 2>/dev/null || echo "")
        if [ -n "$cfg_project" ]; then
            PROJECT_ID="$cfg_project"
            log_info "Using gcloud default project: $PROJECT_ID"
        else
            _select_project
        fi
    fi
    export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
    log_success "Project: $PROJECT_ID"
}

_select_project() {
    log_info "Fetching accessible GCP projects..."
    local projects_list=""
    projects_list=$(timeout 20 gcloud projects list --limit=20 --format="value(projectId)" 2>/dev/null || true)

    if [ -n "$projects_list" ]; then
        echo ""
        echo -e "  ${CYAN}Available projects:${NC}"
        local i=1
        while IFS= read -r p; do
            echo -e "  ${GREY}[$i]${NC} $p"
            (( i++ ))
        done <<< "$projects_list"
        echo ""
        local project_count
        project_count=$(echo "$projects_list" | wc -l | tr -d ' ')
        local choice
        read -r -p "  Select project [1-${project_count}] or press Enter to type manually: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$project_count" ]; then
            PROJECT_ID=$(echo "$projects_list" | sed -n "${choice}p")
        fi
    fi

    if [ -z "$PROJECT_ID" ]; then
        read -r -p "  Enter GCP project ID: " PROJECT_ID
    fi
    if [ -z "$PROJECT_ID" ]; then log_error "No project ID provided."; exit 1; fi
}

# ==============================================================================
# ENABLE REQUIRED APIs
# ==============================================================================

enable_apis() {
    log_step "Enabling required GCP APIs"

    local apis=("compute.googleapis.com" "secretmanager.googleapis.com" "iam.googleapis.com")
    for api in "${apis[@]}"; do
        log_info "Enabling $api..."
        if gcloud services enable "$api" --project="$PROJECT_ID" --quiet 2>/dev/null; then
            log_success "Enabled: $api"
        else
            log_warning "Could not enable $api (may already be enabled or insufficient permissions)"
        fi
    done
}

# ==============================================================================
# ASSERT / CREATE COMPUTE INSTANCE
# ==============================================================================

assert_or_create_instance() {
    log_step "Asserting Compute Engine instance"

    if [ -z "$GCP_INSTANCE_NAME" ]; then
        log_error "GCP_INSTANCE_NAME is not set. Set it in secrets.conf"
        ERRORS=$(( ERRORS + 1 ))
        return 1
    fi

    if gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_success "Instance exists: $GCP_INSTANCE_NAME ($GCP_ZONE)"
        _assert_instance_config
    else
        log_warning "Instance '$GCP_INSTANCE_NAME' not found in zone $GCP_ZONE"
        _create_instance
    fi
}

_assert_instance_config() {
    local need_scope_fix=false

    # Check instance status and start if it's terminated
    local status
    status=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="value(status)" 2>/dev/null || echo "UNKNOWN")

    if [ "$status" = "TERMINATED" ]; then
        log_warning "Instance is TERMINATED. Starting it now..."
        if gcloud compute instances start "$GCP_INSTANCE_NAME" \
            --zone="$GCP_ZONE" --project="$PROJECT_ID" --quiet; then
            log_success "Instance started successfully"
        else
            log_error "Failed to start instance"
            ERRORS=$(( ERRORS + 1 ))
            return 1
        fi
    elif [ "$status" != "RUNNING" ]; then
        log_warning "Instance state is '$status' (must be RUNNING for SSH later)"
    else
        log_success "Instance state: RUNNING"
    fi

    # Check machine type
    local actual_type
    actual_type=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="value(machineType.basename())" 2>/dev/null)
    if [ "$actual_type" = "$GCP_MACHINE_TYPE" ]; then
        log_success "Machine type: $actual_type"
    else
        log_warning "Machine type is '$actual_type', expected '$GCP_MACHINE_TYPE' — this is OK unless performance is a concern"
    fi

    # Check disk size
    local actual_disk
    actual_disk=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="value(disks[0].diskSizeGb)" 2>/dev/null || echo "0")
    if [ "${actual_disk:-0}" -ge "$GCP_DISK_SIZE" ] 2>/dev/null; then
        log_success "Boot disk: ${actual_disk} GB"
    else
        log_warning "Boot disk is ${actual_disk} GB (recommended ≥ ${GCP_DISK_SIZE} GB)"
    fi

    # Check cloud-platform scope
    local scopes
    scopes=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="value(serviceAccounts[0].scopes)" 2>/dev/null || echo "")
    if echo "$scopes" | grep -q "cloud-platform"; then
        log_success "OAuth scope: cloud-platform  ✔"
    else
        log_error "Instance is MISSING the 'cloud-platform' scope — Secret Manager calls will fail"
        need_scope_fix=true
        ERRORS=$(( ERRORS + 1 ))
    fi

    # Check network tag
    local tags
    tags=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="value(tags.items[])" 2>/dev/null || echo "")
    if echo "$tags" | grep -q "$GCP_NETWORK_TAG"; then
        log_success "Network tag: $GCP_NETWORK_TAG  ✔"
    else
        log_info "Network tag '$GCP_NETWORK_TAG' not set — adding now..."
        if gcloud compute instances add-tags "$GCP_INSTANCE_NAME" \
            --zone="$GCP_ZONE" --project="$PROJECT_ID" \
            --tags="$GCP_NETWORK_TAG" --quiet 2>/dev/null; then
            log_success "Network tag '$GCP_NETWORK_TAG' added"
        else
            log_warning "Could not add network tag (insufficient permissions)"
            log_code "gcloud compute instances add-tags $GCP_INSTANCE_NAME --zone=$GCP_ZONE --tags=$GCP_NETWORK_TAG"
        fi
    fi

    # Fix scope if needed (requires stop/update/start — disruptive)
    if [ "$need_scope_fix" = true ]; then
        _fix_instance_scope
    fi
}

_fix_instance_scope() {
    echo ""
    log_warning "Scope fix requires stopping the instance (~1-2 min downtime)."

    local do_fix="y"
    if [ "$AUTO_APPROVE" != true ]; then
        read -r -p "  Stop instance, update scope, and restart? [Y/n]: " do_fix
    fi

    if [[ "${do_fix:-y}" =~ ^[Nn]$ ]]; then
        log_info "Skipped. Fix manually from workstation:"
        log_code "gcloud compute instances stop $GCP_INSTANCE_NAME --zone=$GCP_ZONE"
        log_code "gcloud compute instances set-service-account $GCP_INSTANCE_NAME --zone=$GCP_ZONE --scopes=cloud-platform"
        log_code "gcloud compute instances start $GCP_INSTANCE_NAME --zone=$GCP_ZONE"
        return
    fi

    log_info "Stopping instance..."
    gcloud compute instances stop "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" --quiet \
        && log_success "Stopped" || { log_error "Stop failed"; return; }

    log_info "Updating access scopes to cloud-platform..."
    gcloud compute instances set-service-account "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --scopes=cloud-platform --quiet \
        && log_success "Scope updated" || log_warning "Could not update scope — check permissions"

    log_info "Starting instance..."
    gcloud compute instances start "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" --quiet \
        && log_success "Instance restarted" || log_warning "Could not start instance"

    # Recheck
    local scopes_new
    scopes_new=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="value(serviceAccounts[0].scopes)" 2>/dev/null || echo "")
    if echo "$scopes_new" | grep -q "cloud-platform"; then
        log_success "Scope confirmed: cloud-platform"
        ERRORS=$(( ERRORS > 0 ? ERRORS - 1 : 0 ))
    fi
}

_create_instance() {
    echo ""
    log_info "Will create:"
    log_code "  Name:         $GCP_INSTANCE_NAME"
    log_code "  Zone:         $GCP_ZONE"
    log_code "  Machine type: $GCP_MACHINE_TYPE"
    log_code "  Disk:         ${GCP_DISK_SIZE} GB"
    log_code "  OS:           debian-12 (latest)"
    log_code "  Scopes:       cloud-platform"
    log_code "  Tag:          $GCP_NETWORK_TAG"
    echo ""

    local do_create="y"
    if [ "$AUTO_APPROVE" != true ]; then
        read -r -p "  Create instance now? [Y/n]: " do_create
    fi

    if [[ "${do_create:-y}" =~ ^[Nn]$ ]]; then log_info "Skipped instance creation."; return; fi

    log_info "Creating instance (this takes ~30 seconds)..."
    if gcloud compute instances create "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" \
        --project="$PROJECT_ID" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --machine-type="$GCP_MACHINE_TYPE" \
        --boot-disk-size="${GCP_DISK_SIZE}GB" \
        --boot-disk-type=pd-balanced \
        --scopes=cloud-platform \
        --tags="$GCP_NETWORK_TAG" \
        --quiet; then
        log_success "Instance created: $GCP_INSTANCE_NAME"
    else
        log_error "Failed to create instance — check IAM permissions"
        log_code "Required: compute.instances.create on project $PROJECT_ID"
        ERRORS=$(( ERRORS + 1 ))
    fi
}

# ==============================================================================
# FIREWALL RULE
# ==============================================================================

assert_firewall_rule() {
    log_step "Asserting firewall rule"

    if [ -z "$ALLOWED_SOURCE_RANGES" ]; then
        log_error "ALLOWED_SOURCE_RANGES is empty — set in secrets.conf"
        log_code "  e.g. ALLOWED_SOURCE_RANGES=\"0.0.0.0/0\"   # public"
        log_code "  e.g. ALLOWED_SOURCE_RANGES=\"203.0.113.0/24\"  # office-only"
        ERRORS=$(( ERRORS + 1 ))
        return 1
    fi

    if gcloud compute firewall-rules describe "$GCP_FIREWALL_RULE_NAME" \
        --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_success "Firewall rule exists: $GCP_FIREWALL_RULE_NAME"

        # Check that it targets the correct tag
        local target_tags
        target_tags=$(gcloud compute firewall-rules describe "$GCP_FIREWALL_RULE_NAME" \
            --project="$PROJECT_ID" --format="value(targetTags[])" 2>/dev/null || echo "")
        if echo "$target_tags" | grep -q "$GCP_NETWORK_TAG"; then
            log_success "Firewall targets tag: $GCP_NETWORK_TAG"
        else
            log_warning "Firewall rule doesn't target '$GCP_NETWORK_TAG' tag — traffic may not reach the instance"
            log_code "gcloud compute firewall-rules update $GCP_FIREWALL_RULE_NAME --target-tags=$GCP_NETWORK_TAG"
        fi
    else
        log_info "Creating firewall rule: $GCP_FIREWALL_RULE_NAME"
        if gcloud compute firewall-rules create "$GCP_FIREWALL_RULE_NAME" \
            --project="$PROJECT_ID" \
            --allow=tcp:443,tcp:80 \
            --source-ranges="$ALLOWED_SOURCE_RANGES" \
            --target-tags="$GCP_NETWORK_TAG" \
            --description="TreeScout HTTPS/HTTP access" \
            --quiet; then
            log_success "Firewall rule created"
            log_code "Allows: tcp:80, tcp:443"
            log_code "Source: $ALLOWED_SOURCE_RANGES"
            log_code "Target: tag=$GCP_NETWORK_TAG"
        else
            log_error "Could not create firewall rule — check IAM (compute.firewalls.create)"
            ERRORS=$(( ERRORS + 1 ))
        fi
    fi

    assert_iap_ssh_firewall
}

assert_iap_ssh_firewall() {
    local iap_range="35.235.240.0/20"

    log_info "Asserting IAP SSH firewall rule (${GCP_SSH_FIREWALL_RULE_NAME})"
    if gcloud compute firewall-rules describe "$GCP_SSH_FIREWALL_RULE_NAME" \
        --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_success "IAP SSH firewall rule exists: $GCP_SSH_FIREWALL_RULE_NAME"

        local ssh_target_tags ssh_sources
        ssh_target_tags=$(gcloud compute firewall-rules describe "$GCP_SSH_FIREWALL_RULE_NAME" \
            --project="$PROJECT_ID" --format="value(targetTags[])" 2>/dev/null || echo "")
        ssh_sources=$(gcloud compute firewall-rules describe "$GCP_SSH_FIREWALL_RULE_NAME" \
            --project="$PROJECT_ID" --format="value(sourceRanges[])" 2>/dev/null || echo "")

        if ! echo "$ssh_target_tags" | grep -q "$GCP_NETWORK_TAG"; then
            log_warning "IAP SSH rule does not target '$GCP_NETWORK_TAG' tag."
            log_code "gcloud compute firewall-rules update $GCP_SSH_FIREWALL_RULE_NAME --target-tags=$GCP_NETWORK_TAG"
        fi
        if ! echo "$ssh_sources" | grep -q "$iap_range"; then
            log_warning "IAP SSH rule does not include source range $iap_range."
            log_code "gcloud compute firewall-rules update $GCP_SSH_FIREWALL_RULE_NAME --source-ranges=$iap_range"
        fi
        return
    fi

    log_info "Creating IAP SSH firewall rule for tcp:22 from $iap_range"
    if gcloud compute firewall-rules create "$GCP_SSH_FIREWALL_RULE_NAME" \
        --project="$PROJECT_ID" \
        --allow=tcp:22 \
        --source-ranges="$iap_range" \
        --target-tags="$GCP_NETWORK_TAG" \
        --description="Allow SSH from IAP tunnel to TreeScout instances" \
        --quiet; then
        log_success "IAP SSH firewall rule created"
    else
        log_warning "Could not create IAP SSH firewall rule — SSH over IAP may fail"
        log_code "gcloud compute firewall-rules create $GCP_SSH_FIREWALL_RULE_NAME --allow=tcp:22 --source-ranges=$iap_range --target-tags=$GCP_NETWORK_TAG"
    fi
}

# ==============================================================================
# IAM — grant Compute SA access to Secret Manager
# ==============================================================================

grant_iam_role() {
    log_step "Asserting IAM: Compute SA → secretmanager.secretAccessor"

    local project_number
    project_number=$(gcloud projects describe "$PROJECT_ID" \
        --format="value(projectNumber)" 2>/dev/null || echo "")

    if [ -z "$project_number" ]; then
        log_warning "Could not retrieve project number — skipping IAM assertion"
        log_code "Grant manually: gcloud projects add-iam-policy-binding $PROJECT_ID \\"
        log_code "  --member=\"serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com\" \\"
        log_code "  --role=\"roles/secretmanager.secretAccessor\""
        return
    fi

    local compute_sa="${project_number}-compute@developer.gserviceaccount.com"
    log_info "Service account: $compute_sa"

    if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${compute_sa}" \
        --role="roles/secretmanager.secretAccessor" \
        --condition=None \
        --quiet 2>/dev/null; then
        log_success "IAM binding ensured: secretmanager.secretAccessor"
    else
        log_warning "Could not update IAM policy — may require owner/editor role"
        log_code "gcloud projects add-iam-policy-binding $PROJECT_ID \\"
        log_code "  --member=\"serviceAccount:${compute_sa}\" \\"
        log_code "  --role=\"roles/secretmanager.secretAccessor\""
    fi
}

# ==============================================================================
# PUSH SECRETS TO SECRET MANAGER
# ==============================================================================

_upsert_secret() {
    local name="$1" value="$2"
    if gcloud secrets describe "$name" --project="$PROJECT_ID" >/dev/null 2>&1; then
        echo -n "$value" | gcloud secrets versions add "$name" \
            --project="$PROJECT_ID" --data-file=- >/dev/null
        log_success "Updated:  $name"
    else
        echo -n "$value" | gcloud secrets create "$name" \
            --project="$PROJECT_ID" \
            --replication-policy=automatic \
            --data-file=- >/dev/null
        log_success "Created:  $name"
    fi
}

_push_if_set() {
    local label="$1" secret_name="$2" value="$3" required="${4:-optional}"
    if [ -z "$value" ]; then
        if [ "$required" = "required" ]; then
            log_error "${label} is REQUIRED but empty — set it in secrets.conf"
            ERRORS=$(( ERRORS + 1 ))
        else
            log_info "Skipping (empty): $secret_name"
        fi
        return 0
    fi
    _upsert_secret "$secret_name" "$value"
}

push_secrets() {
    log_step "Pushing secrets to GCP Secret Manager"

    # Auto-generate APP_KEY if not provided
    if [ -z "$APP_KEY" ]; then
        APP_KEY="base64:$(openssl rand -base64 32)"
        log_info "Auto-generated Laravel APP_KEY"
    fi

    _push_if_set "Laravel App Key"                      "treescout-app-key"                            "${APP_KEY:-}"                                 "required"
    _push_if_set "GitHub PAT (REPO_TOKEN)"              "treescout-repo-token"                         "${REPO_TOKEN:-}"                              "required"
    _push_if_set "GHCR PAT (DOCKER_TOKEN)"              "treescout-docker-token"                       "${DOCKER_TOKEN:-}"
    _push_if_set "Database root password"               "treescout-db-root-pass"                       "${DB_ROOT_PASS:-}"                            "required"
    _push_if_set "Database app-user password"           "treescout-db-pass"                            "${DB_PASS:-}"                                 "required"
    _push_if_set "Admin user password"                  "treescout-admin-pass"                         "${ADMIN_PASS:-}"                              "required"

    _push_if_set "Agent user password"                  "treescout-agent-pass"                         "${AGENT_PASS:-}"
    _push_if_set "Finance user password"                "treescout-finance-pass"                       "${FINANCE_PASS:-}"
    _push_if_set "Reporter user password"               "treescout-reporter-pass"                      "${REPORTER_PASS:-}"

    _push_if_set "Google OAuth Client ID"               "treescout-google-client-id"                   "${GOOGLE_CLIENT_ID:-}"
    _push_if_set "Google OAuth Client Secret"           "treescout-google-client-secret"               "${GOOGLE_CLIENT_SECRET:-}"
    _push_if_set "Google Admin Emails"                  "treescout-google-admin-emails"                "${GOOGLE_ADMIN_EMAILS:-}"
    _push_if_set "Google Allowed Domains"               "treescout-google-allowed-domains"             "${GOOGLE_ALLOWED_DOMAINS:-}"

    _push_if_set "Action1 Sync Client ID"               "treescout-action1-sync-client-id"             "${ACTION1_SYNC_CLIENT_ID:-}"
    _push_if_set "Action1 Sync Client Secret"           "treescout-action1-sync-client-secret"         "${ACTION1_SYNC_CLIENT_SECRET:-}"
    _push_if_set "Action1 Automation Runner Client ID"  "treescout-action1-automation-runner-client-id" "${ACTION1_AUTOMATION_RUNNER_CLIENT_ID:-}"
    _push_if_set "Action1 Automation Runner Secret"     "treescout-action1-automation-runner-client-secret" "${ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET:-}"
    _push_if_set "Action1 Script Manager Client ID"     "treescout-action1-script-manager-client-id"   "${ACTION1_SCRIPT_MANAGER_CLIENT_ID:-}"
    _push_if_set "Action1 Script Manager Secret"        "treescout-action1-script-manager-client-secret" "${ACTION1_SCRIPT_MANAGER_CLIENT_SECRET:-}"
    _push_if_set "Action1 Region"                       "treescout-action1-region"                     "${ACTION1_REGION:-}"

    _push_if_set "GoDaddy API Key"                       "treescout-godaddy-api-key"                    "${GODADDY_API_KEY:-}"
    _push_if_set "GoDaddy API Secret"                    "treescout-godaddy-api-secret"                 "${GODADDY_API_SECRET:-}"
}

# ==============================================================================
# SET NON-SECRET CONFIG AS INSTANCE CUSTOM METADATA
# Metadata keys prefixed with "ts-" are read by gcp-server-init.sh on the VM.
# No deploy.conf is ever needed on the server.
# ==============================================================================

set_instance_metadata() {
    log_step "Writing configuration to instance metadata"

    if [ "$AUTO_APPROVE" != true ]; then
        echo ""
        echo -e "${CYAN}Module Folder Conflict Policy${NC}"
        echo -e "  ${GREY}[r]${NC} replace existing folder (default)"
        echo -e "  ${GREY}[s]${NC} skip existing folder"
        echo -e "  ${GREY}[a]${NC} abort bootstrap if folder exists"
        echo -e "  ${GREY}[k]${NC} ask on VM when interactive"
        local policy_choice=""
        read -r -p "  Choose policy [s/r/a/k] (Enter for current: $MODULE_DIR_POLICY): " policy_choice
        case "${policy_choice,,}" in
            "") ;;
            s|skip) MODULE_DIR_POLICY="skip" ;;
            r|replace) MODULE_DIR_POLICY="replace" ;;
            a|abort) MODULE_DIR_POLICY="abort" ;;
            k|ask) MODULE_DIR_POLICY="ask" ;;
            *)
                log_warning "Unknown choice '$policy_choice' — keeping '$MODULE_DIR_POLICY'."
                ;;
        esac
    fi

    case "${MODULE_DIR_POLICY,,}" in
        skip|replace|abort|ask) ;;
        *)
            log_warning "Invalid MODULE_DIR_POLICY '$MODULE_DIR_POLICY' — defaulting to 'replace'."
            MODULE_DIR_POLICY="replace"
            ;;
    esac

    if [ -z "$DOMAIN_NAME" ]; then
        log_error "DOMAIN_NAME is required but not set in secrets.conf"
        ERRORS=$(( ERRORS + 1 ))
        return 1
    fi

    if [ -z "$ADMIN_EMAIL" ]; then
        log_error "ADMIN_EMAIL is required but not set in secrets.conf"
        ERRORS=$(( ERRORS + 1 ))
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    # Expand $tmpdir NOW (double-quotes) so the path is baked into the trap string.
    # Single-quotes would defer expansion to RETURN, where local variables may be
    # unresolvable under set -u in some bash versions.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    # Write each config value to its own temp file (safe for values with commas)
    echo -n "$DOMAIN_NAME"          > "$tmpdir/ts-domain"
    echo -n "$ADMIN_EMAIL"          > "$tmpdir/ts-admin-email"
    echo -n "$ADMIN_FIRST_NAME"     > "$tmpdir/ts-admin-first"
    echo -n "$ADMIN_LAST_NAME"      > "$tmpdir/ts-admin-last"
    echo -n "$GIT_REPO_URL"         > "$tmpdir/ts-git-repo"
    echo -n "$GIT_BRANCH"           > "$tmpdir/ts-git-branch"
    echo -n "$MODULE_DIR_POLICY"    > "$tmpdir/ts-module-dir-policy"
    echo -n "$DEFAULT_INSTALL_DIR"  > "$tmpdir/ts-install-dir"
    echo -n "$DOCKER_SUBNET"        > "$tmpdir/ts-docker-subnet"
    echo -n "$DB_USER"              > "$tmpdir/ts-db-user"
    echo -n "$DB_NAME"              > "$tmpdir/ts-db-name"
    echo -n "$DB_HOST"              > "$tmpdir/ts-db-host"
    echo -n "$EXPOSE_PUBLIC_PORTS"  > "$tmpdir/ts-expose-public"
    echo -n "$ENABLE_HTTPS"         > "$tmpdir/ts-enable-https"
    echo -n "${TLS_EMAIL:-$ADMIN_EMAIL}" > "$tmpdir/ts-tls-email"
    echo -n "$GCP_FIREWALL_RULE_NAME" > "$tmpdir/ts-firewall-rule"
    echo -n "$ALLOWED_SOURCE_RANGES" > "$tmpdir/ts-allowed-ranges"
    echo -n "$GCP_NETWORK_TAG"      > "$tmpdir/ts-network-tag"
    echo -n "$ENABLE_KROKI"         > "$tmpdir/ts-enable-kroki"
    echo -n "$ENABLE_GCP_LOGGING"   > "$tmpdir/ts-enable-logging"

    # Optional seeded user accounts (skip if empty)
    if [ -n "$AGENT_EMAIL" ]; then
        echo -n "$AGENT_EMAIL"      > "$tmpdir/ts-agent-email"
        echo -n "$AGENT_FIRST_NAME" > "$tmpdir/ts-agent-first"
        echo -n "$AGENT_LAST_NAME"  > "$tmpdir/ts-agent-last"
    fi
    if [ -n "$FINANCE_EMAIL" ]; then
        echo -n "$FINANCE_EMAIL"      > "$tmpdir/ts-finance-email"
        echo -n "$FINANCE_FIRST_NAME" > "$tmpdir/ts-finance-first"
        echo -n "$FINANCE_LAST_NAME"  > "$tmpdir/ts-finance-last"
    fi
    if [ -n "$REPORTER_EMAIL" ]; then
        echo -n "$REPORTER_EMAIL"      > "$tmpdir/ts-reporter-email"
        echo -n "$REPORTER_FIRST_NAME" > "$tmpdir/ts-reporter-first"
        echo -n "$REPORTER_LAST_NAME"  > "$tmpdir/ts-reporter-last"
    fi

    # Build a single comma-joined KEY=FILE string for --metadata-from-file.
    # This is the documented gcloud syntax and works across all gcloud versions.
    # (Repeated --metadata-from-file flags via an array can silently fail on some versions.)
    local meta_kv=""
    local meta_count=0
    for f in "$tmpdir"/ts-*; do
        local key
        key=$(basename "$f")
        meta_kv="${meta_kv:+${meta_kv},}${key}=${f}"
        meta_count=$(( meta_count + 1 ))
    done

    log_info "Setting ${meta_count} metadata keys on instance $GCP_INSTANCE_NAME..."
    if gcloud compute instances add-metadata "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" \
        --project="$PROJECT_ID" \
        --metadata-from-file="$meta_kv" \
        --quiet; then
        log_success "Instance metadata updated (${meta_count} keys)"
        log_code "Domain:       $DOMAIN_NAME"
        log_code "Admin email:  $ADMIN_EMAIL"
        log_code "Module policy: $MODULE_DIR_POLICY"
        [ -n "$AGENT_EMAIL" ]    && log_code "Agent email:  $AGENT_EMAIL" || true
        [ -n "$FINANCE_EMAIL" ]  && log_code "Finance email: $FINANCE_EMAIL" || true
        [ -n "$REPORTER_EMAIL" ] && log_code "Reporter email: $REPORTER_EMAIL" || true
    else
        log_error "Failed to set instance metadata — check IAM (compute.instances.setMetadata)"
        ERRORS=$(( ERRORS + 1 ))
    fi
}

# ==============================================================================
# VERIFY REQUIRED SECRETS ARE READABLE
# ==============================================================================

verify_secrets() {
    log_step "Verifying required secrets are readable"

    local all_ok=true
    for secret in treescout-app-key treescout-repo-token treescout-db-root-pass treescout-db-pass treescout-admin-pass; do
        if gcloud secrets versions access latest --secret="$secret" --project="$PROJECT_ID" >/dev/null 2>&1; then
            log_success "Readable: $secret"
        else
            log_warning "Cannot read: $secret — check IAM after IAM binding propagates (~60s)"
            all_ok=false
        fi
    done

    [ "$all_ok" = false ] && log_info "If secrets fail after ~60s, re-run this script to re-verify." || true
}

# ==============================================================================
# TRIGGER SERVER-SIDE BOOTSTRAP (optional)
# ==============================================================================

_probe_ssh_command() {
    local mode="$1"
    local -a ssh_args=(
        compute ssh "$GCP_INSTANCE_NAME"
        --zone="$GCP_ZONE"
        --project="$PROJECT_ID"
        --command='echo ssh-ok'
        --quiet
        --ssh-flag="-o BatchMode=yes"
        --ssh-flag="-o ConnectTimeout=10"
        --ssh-flag="-o StrictHostKeyChecking=accept-new"
    )

    if [ "$mode" = "iap" ]; then
        ssh_args+=(--tunnel-through-iap)
    fi

    # Retry up to 3 times — SSH key propagation to VM metadata can take ~30-60 s
    local attempt
    for attempt in 1 2 3; do
        if gcloud "${ssh_args[@]}" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            log_info "SSH probe attempt ${attempt}/3 failed via ${mode} — retrying in 20s (SSH key propagation)..."
            sleep 20
        fi
    done
    return 1
}

_run_bootstrap_command() {
    local mode="$1"
    local cmd="$2"
    local -a ssh_args=(
        compute ssh "$GCP_INSTANCE_NAME"
        --zone="$GCP_ZONE"
        --project="$PROJECT_ID"
    )

    if [ "$mode" = "iap" ]; then
        ssh_args+=(--tunnel-through-iap)
    fi

    gcloud "${ssh_args[@]}" -- "$cmd"
}

_run_bootstrap_stdin() {
    local mode="$1"
    local script_path="$2"
    local -a ssh_args=(
        compute ssh "$GCP_INSTANCE_NAME"
        --zone="$GCP_ZONE"
        --project="$PROJECT_ID"
    )

    if [ "$mode" = "iap" ]; then
        ssh_args+=(--tunnel-through-iap)
    fi

    # PowerShell doesn't support the '<' redirect operator naturally. Avoid literal `<`.
    cat "$script_path" | gcloud "${ssh_args[@]}" -- 'sudo bash -s'
}

_diagnose_ssh_failure() {
    echo ""
    log_warning "Diagnosing SSH failure..."

    # Check IAP firewall rule exists
    local rule_ok=false
    if gcloud compute firewall-rules describe "$GCP_SSH_FIREWALL_RULE_NAME" \
        --project="$PROJECT_ID" >/dev/null 2>&1; then
        local src_ranges
        src_ranges=$(gcloud compute firewall-rules describe "$GCP_SSH_FIREWALL_RULE_NAME" \
            --project="$PROJECT_ID" --format="value(sourceRanges[])" 2>/dev/null || echo "")
        if echo "$src_ranges" | grep -q "35.235.240.0"; then
            log_success "Firewall rule '$GCP_SSH_FIREWALL_RULE_NAME' exists with IAP source range."
            rule_ok=true
        else
            log_error "Firewall rule '$GCP_SSH_FIREWALL_RULE_NAME' exists but is MISSING 35.235.240.0/20."
            log_code "gcloud compute firewall-rules update $GCP_SSH_FIREWALL_RULE_NAME --source-ranges=35.235.240.0/20 --project=$PROJECT_ID"
        fi
    else
        log_error "IAP SSH firewall rule '$GCP_SSH_FIREWALL_RULE_NAME' does NOT exist."
        log_code "gcloud compute firewall-rules create $GCP_SSH_FIREWALL_RULE_NAME --allow=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=$GCP_NETWORK_TAG --project=$PROJECT_ID"
    fi

    # Check VM has the required network tag
    local tag_ok=false
    local tags
    tags=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="value(tags.items[])" 2>/dev/null || echo "")
    if echo "$tags" | grep -q "$GCP_NETWORK_TAG"; then
        log_success "Instance tag '$GCP_NETWORK_TAG' is set."
        tag_ok=true
    else
        log_error "Instance '$GCP_INSTANCE_NAME' is MISSING network tag '$GCP_NETWORK_TAG'."
        log_code "gcloud compute instances add-tags $GCP_INSTANCE_NAME --zone=$GCP_ZONE --tags=$GCP_NETWORK_TAG --project=$PROJECT_ID"
    fi

    # Check instance is RUNNING
    local status
    status=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="value(status)" 2>/dev/null || echo "UNKNOWN")
    if [ "$status" = "RUNNING" ]; then
        log_success "Instance status: RUNNING"
    else
        log_error "Instance status: $status (must be RUNNING for SSH to work)"
        log_code "gcloud compute instances start $GCP_INSTANCE_NAME --zone=$GCP_ZONE --project=$PROJECT_ID"
    fi

    if [ "$rule_ok" = true ] && [ "$tag_ok" = true ] && [ "$status" = "RUNNING" ]; then
        log_warning "Infrastructure looks correct — sshd may not be ready yet or key propagation is slow."
        log_info "Wait 60 s and re-run, or SSH manually:"
    else
        log_info "Fix the issue(s) above, then re-run this script."
    fi
    echo ""
    log_code "gcloud compute ssh $GCP_INSTANCE_NAME --project=$PROJECT_ID --zone=$GCP_ZONE --tunnel-through-iap"
    log_info "To deep-diagnose the IAP tunnel:"
    log_code "gcloud compute ssh $GCP_INSTANCE_NAME --project=$PROJECT_ID --zone=$GCP_ZONE --troubleshoot --tunnel-through-iap"
}

_select_ssh_mode() {
    local ext_ip
    ext_ip=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)

    log_info "Preflight: probing SSH connectivity..."

    if [ -n "$ext_ip" ]; then
        log_info "Public IP detected ($ext_ip) — testing direct SSH first."
        if _probe_ssh_command "direct"; then
            echo "direct"
            return 0
        fi
        log_info "Direct SSH probe failed — falling back to IAP."
    fi

    log_info "Testing SSH over IAP tunnel (up to 3 attempts × 20 s)..."
    if _probe_ssh_command "iap"; then
        echo "iap"
        return 0
    fi

    log_error "Unable to establish SSH to $GCP_INSTANCE_NAME (direct or IAP)."
    _diagnose_ssh_failure
    return 1
}

offer_server_bootstrap() {
    # Locate gcp-server-init.sh — search next to this script, then common relative paths
    local server_init=""
    for candidate in \
        "${SCRIPT_DIR}/gcp-server-init.sh" \
        "${PWD}/deployment/gcp/gcp-server-init.sh" \
        "${PWD}/gcp-server-init.sh"; do
        if [ -f "$candidate" ]; then
            server_init="$candidate"
            break
        fi
    done

    echo ""
    echo -e "${CYAN}━━━ Run server-side bootstrap${NC}"
    echo ""
    log_info "The GCP VM is now fully configured via metadata."
    log_info "To deploy TreeScout, run gcp-server-init.sh on the VM:"
    echo ""
    if [ -n "$server_init" ]; then
        log_code "cat $server_init | gcloud compute ssh $GCP_INSTANCE_NAME --zone=$GCP_ZONE \\"
    else
        log_code "cat deployment/gcp/gcp-server-init.sh | gcloud compute ssh $GCP_INSTANCE_NAME --zone=$GCP_ZONE \\"
    fi
    log_code "  --project=$PROJECT_ID -- 'sudo bash -s'"
    echo ""

    if [ "$SKIP_DEPLOY" = true ]; then
        log_info "--skip-deploy set — skipping automatic SSH"
        return
    fi

    local ssh_mode
    if ! ssh_mode=$(_select_ssh_mode | tail -n1); then
        ERRORS=$(( ERRORS + 1 ))
        return
    fi

    if [ "$ssh_mode" != "iap" ] && [ "$ssh_mode" != "direct" ]; then
        log_error "Could not determine SSH mode (got: '$ssh_mode')."
        ERRORS=$(( ERRORS + 1 ))
        return
    fi

    if [ "$ssh_mode" = "iap" ]; then
        log_info "Using SSH over IAP tunnel for bootstrap."
    else
        log_info "Using direct SSH for bootstrap."
    fi

    # If the file wasn't found locally, offer to stream it from GitHub instead
    if [ -z "$server_init" ]; then
        log_warning "gcp-server-init.sh not found alongside this script."
        echo ""
        log_info "Option A: Place gcp-server-init.sh in the same folder as this script and re-run."
        log_info "Option B: Stream it directly from GitHub now (requires curl on the VM)."
        echo ""

        local do_stream="y"
        if [ "$AUTO_APPROVE" != true ]; then
            read -r -p "  Stream gcp-server-init.sh from GitHub and run it on the VM now? [y/N]: " do_stream
        fi

        if [[ ! "${do_stream:-n}" =~ ^[Yy]$ ]]; then
            log_info "Skipped — copy gcp-server-init.sh next to this script and re-run."
            return
        fi

        local raw_url="https://raw.githubusercontent.com/BorealTek/Treescout-Core/${GIT_BRANCH}/deployment/gcp/gcp-server-init.sh"
        log_step "Streaming gcp-server-init.sh from GitHub to $GCP_INSTANCE_NAME..."
        if ! _run_bootstrap_command "$ssh_mode" "curl -fsSL '$raw_url' | sudo bash"; then
            log_error "Bootstrap stream command failed on VM."
            ERRORS=$(( ERRORS + 1 ))
        fi
        return
    fi

    local do_ssh="y"
    if [ "$AUTO_APPROVE" != true ]; then
        read -r -p "  SSH into $GCP_INSTANCE_NAME and run the bootstrap now? [y/N]: " do_ssh
    fi

    if [[ ! "${do_ssh:-n}" =~ ^[Yy]$ ]]; then log_info "Skipped — run the command above manually."; return; fi

    log_step "Connecting to $GCP_INSTANCE_NAME and running bootstrap..."
    if ! _run_bootstrap_stdin "$ssh_mode" "$server_init"; then
        log_error "Bootstrap command failed over ${ssh_mode} SSH."
        if [ "$ssh_mode" = "direct" ]; then
            local retry_iap="n"
            if [ "$AUTO_APPROVE" != true ]; then
                read -r -p "  Retry bootstrap over IAP tunnel? [y/N]: " retry_iap
            else
                log_info "AUTO_APPROVE mode: skipping automatic IAP retry."
            fi

            if [[ "${retry_iap:-n}" =~ ^[Yy]$ ]]; then
                log_info "Retrying once via IAP tunnel..."
                if _run_bootstrap_stdin "iap" "$server_init"; then
                    log_success "Bootstrap succeeded over IAP fallback."
                    return
                fi
            fi
        fi
        log_error "Could not complete bootstrap over SSH."
        ERRORS=$(( ERRORS + 1 ))
    fi
}

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================

show_summary() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"

    if [ "$ERRORS" -eq 0 ]; then
        echo -e "${GREEN}✔  All assertions passed — GCP environment is ready.${NC}"
    else
        echo -e "${YELLOW}⚠  Completed with $ERRORS error(s) — review output above.${NC}"
    fi

    echo ""
    echo -e "  Instance:  ${GREY}$GCP_INSTANCE_NAME${NC}  (${GCP_ZONE})"
    echo -e "  Project:   ${GREY}$PROJECT_ID${NC}"

    local ext_ip
    ext_ip=$(gcloud compute instances describe "$GCP_INSTANCE_NAME" \
        --zone="$GCP_ZONE" --project="$PROJECT_ID" \
        --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "unknown")
    echo -e "  Public IP: ${GREY}${ext_ip}${NC}"
    [ -n "$DOMAIN_NAME" ] && echo -e "  Domain:    ${GREY}${DOMAIN_NAME}${NC}" || true

    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    show_banner
    prompt_start_section
    load_config
    check_prereqs
    run_selected_sections
}

main "$@"
