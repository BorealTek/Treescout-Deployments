#!/usr/bin/env bash
# ==============================================================================
# GCP Secrets Bootstrap for FreeScout / TreeScout
#
# Creates or updates all application secrets in GCP Secret Manager.
# Run this ONCE before deploying, from any machine with gcloud authenticated.
#
# Usage:
#   bash deployment/gcp-secrets-bootstrap.sh [--project=PROJECT_ID]
#
# Requirements:
#   - gcloud CLI installed and authenticated
#   - Secret Manager API enabled (this script enables it automatically)
#   - IAM:  roles/secretmanager.admin  (or secretVersionAdder + secretCreator)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
readonly RED='\033[38;5;196m'
readonly GREEN='\033[38;5;46m'
readonly YELLOW='\033[38;5;226m'
readonly CYAN='\033[38;5;51m'
readonly BLUE='\033[38;5;27m'
readonly GREY='\033[38;5;240m'
readonly NC='\033[0m'

log_info()    { echo -e "${CYAN}ℹ ${NC} $*"; }
log_success() { echo -e "${GREEN}✔${NC} $*"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $*"; }
log_error()   { echo -e "${RED}✖${NC} $*" >&2; }
log_step()    { echo ""; echo -e "${BLUE}▶${NC} ${CYAN}$*${NC}"; echo ""; }
log_code()    { echo -e "${GREY}  $*${NC}"; }

PROJECT_ID=""

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --project=*) PROJECT_ID="${arg#--project=}" ;;
        -h|--help)
            echo "Usage: bash deployment/gcp-secrets-bootstrap.sh [--project=PROJECT_ID]"
            exit 0
            ;;
    esac
done

# ==============================================================================
# PREREQUISITES
# ==============================================================================

check_prereqs() {
    log_step "Checking prerequisites"

    if ! command -v gcloud >/dev/null 2>&1; then
        log_error "gcloud CLI not found."
        log_code "Install: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    log_success "gcloud CLI found"

    local active_account
    active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    if [ -z "$active_account" ]; then
        log_error "gcloud not authenticated. Run: gcloud auth login"
        exit 1
    fi
    log_success "Authenticated as: $active_account"

    # Resolve project
    if [ -z "$PROJECT_ID" ]; then
        PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
    fi
    if [ -z "$PROJECT_ID" ]; then
        read -r -p "  Enter GCP project ID: " PROJECT_ID
    fi
    if [ -z "$PROJECT_ID" ]; then
        log_error "No GCP project ID provided."
        exit 1
    fi
    export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
    log_success "Project: $PROJECT_ID"

    # Enable Secret Manager API
    log_info "Enabling Secret Manager API (safe to run if already enabled)..."
    gcloud services enable secretmanager.googleapis.com --project="$PROJECT_ID" --quiet 2>/dev/null \
        && log_success "Secret Manager API enabled" \
        || log_warning "Could not enable API — may already be enabled or require higher permissions"
}

# ==============================================================================
# SECRET MANAGEMENT
# ==============================================================================

# Create a new secret version (or create the secret if it doesn't exist yet).
upsert_secret() {
    local name="$1"
    local value="$2"

    if gcloud secrets describe "$name" --project="$PROJECT_ID" >/dev/null 2>&1; then
        echo -n "$value" | gcloud secrets versions add "$name" \
            --project="$PROJECT_ID" \
            --data-file=- >/dev/null
        log_success "Updated:  $name"
    else
        echo -n "$value" | gcloud secrets create "$name" \
            --project="$PROJECT_ID" \
            --replication-policy=automatic \
            --data-file=- >/dev/null
        log_success "Created:  $name"
    fi
}

# Verify a secret can be read back.
verify_secret() {
    local name="$1"
    if gcloud secrets versions access latest --secret="$name" --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_success "Verified: $name"
        return 0
    else
        log_warning "Cannot verify: $name (check IAM — see section below)"
        return 1
    fi
}

# Interactive prompt for a secret value (hidden input with confirmation).
# $1 = human label   $2 = GCP secret name   $3 = "optional" to allow skipping
prompt_secret() {
    local label="$1"
    local secret_name="$2"
    local optional="${3:-required}"

    local existing_tag=""
    if gcloud secrets describe "$secret_name" --project="$PROJECT_ID" >/dev/null 2>&1; then
        local created
        created=$(gcloud secrets describe "$secret_name" \
            --project="$PROJECT_ID" \
            --format="value(createTime)" 2>/dev/null || echo "unknown")
        existing_tag=" ${GREY}[exists — created: ${created}]${NC}"
    fi

    echo -e "  ${CYAN}${label}${NC}${existing_tag}"
    echo -e "  ${GREY}Secret: ${secret_name}${NC}"

    # If secret already exists, ask whether to update
    if [ -n "$existing_tag" ]; then
        local update_choice
        read -r -p "  Update value? [y/N]: " update_choice
        if [[ ! "$update_choice" =~ ^[Yy]$ ]]; then
            echo ""
            return 0
        fi
    fi

    local value=""
    while true; do
        read -r -s -p "  Value: " value
        echo ""
        if [ -z "$value" ]; then
            if [ "$optional" = "optional" ]; then
                log_info "Skipped (optional)"
                echo ""
                return 0
            fi
            log_warning "Value cannot be empty. Press Ctrl+C to abort."
            continue
        fi
        local confirm
        read -r -s -p "  Confirm: " confirm
        echo ""
        if [ "$value" = "$confirm" ]; then
            break
        fi
        log_warning "Values do not match — try again."
    done

    upsert_secret "$secret_name" "$value"
    echo ""
}

# ==============================================================================
# IAM SETUP
# ==============================================================================

setup_iam() {
    log_step "IAM — granting Secret Manager access to Compute Engine"

    local default_sa="${PROJECT_ID}-compute@developer.gserviceaccount.com"

    log_info "The Compute Engine default service account needs secretAccessor role."
    echo ""
    log_code "Service account: ${default_sa}"
    log_code "Role:            roles/secretmanager.secretAccessor"
    echo ""

    local grant_now
    read -r -p "  Grant access now? [Y/n]: " grant_now
    if [[ "$grant_now" =~ ^[Nn]$ ]]; then
        echo ""
        log_info "Skipped. Grant manually when ready:"
        log_code "gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
        log_code "  --member=\"serviceAccount:${default_sa}\" \\"
        log_code "  --role=\"roles/secretmanager.secretAccessor\""
        echo ""
        return 0
    fi

    if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${default_sa}" \
        --role="roles/secretmanager.secretAccessor" \
        --quiet 2>/dev/null; then
        log_success "IAM binding applied for $default_sa"
    else
        log_warning "Could not apply IAM binding — grant manually with the command above."
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║       FreeScout / TreeScout — GCP Secrets Bootstrap          ║"
    echo "║   Creates or updates all app secrets in Secret Manager       ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    log_info "Secrets that will be created / updated:"
    echo ""
    log_code "  REQUIRED"
    log_code "    freescout-repo-token        GitHub PAT for private module repos"
    log_code "    freescout-db-root-pass      Database root password"
    log_code "    freescout-db-pass           Database application-user password"
    log_code "    freescout-admin-pass        Admin user initial password"
    echo ""
    log_code "  OPTIONAL (default seeded users)"
    log_code "    freescout-agent-pass        Agent user password"
    log_code "    freescout-finance-pass      Finance user password"
    log_code "    freescout-reporter-pass     Reporter user password"
    echo ""
    log_code "  OPTIONAL (Google OAuth integration)"
    log_code "    freescout-google-client-id       Google OAuth Client ID"
    log_code "    freescout-google-client-secret   Google OAuth Client Secret"
    log_code "    freescout-google-admin-emails    CSV — auto-promoted admin emails"
    log_code "    freescout-google-allowed-domains CSV — auto-internal user domains"
    echo ""
    log_code "  OPTIONAL (Action1 RMM — 3 roles: Sync / Run / Manage)"
    log_code "    freescout-action1-sync-client-id       Action1 Sync Client ID"
    log_code "    freescout-action1-sync-client-secret   Action1 Sync Client Secret"
    log_code "    freescout-action1-automation-runner-client-id     Action1 Automation Runner Client ID"
    log_code "    freescout-action1-automation-runner-client-secret Action1 Automation Runner Client Secret"
    log_code "    freescout-action1-script-manager-client-id        Action1 Script Manager Client ID"
    log_code "    freescout-action1-script-manager-client-secret    Action1 Script Manager Client Secret"
    echo ""

    check_prereqs

    # ── Required secrets ─────────────────────────────────────────────────────
    log_step "Required secrets"

    prompt_secret "GitHub PAT (scope: repo)" "freescout-repo-token"
    prompt_secret "Database root password"   "freescout-db-root-pass"
    prompt_secret "Database app-user password" "freescout-db-pass"
    prompt_secret "Admin user password"      "freescout-admin-pass"

    # ── Optional secrets ──────────────────────────────────────────────────────
    log_step "Optional secrets (seeded user accounts)"

    log_info "These create the default agent / finance / reporter accounts on first install."
    log_info "Skip any you don't need — those accounts won't be created."
    echo ""

    prompt_secret "Agent user password"    "freescout-agent-pass"    "optional"
    prompt_secret "Finance user password"  "freescout-finance-pass"  "optional"
    prompt_secret "Reporter user password" "freescout-reporter-pass" "optional"

    # ── Google OAuth integration ─────────────────────────────────────────────
    log_step "Google OAuth integration (optional)"

    log_info "Required only when the GoogleAdmin module is installed."
    log_info "GOOGLE_ADMIN_EMAILS   — comma-separated emails auto-promoted to admin."
    log_info "GOOGLE_ALLOWED_DOMAINS — comma-separated domains for auto-internal provisioning."
    echo ""

    prompt_secret "Google OAuth Client ID"        "freescout-google-client-id"       "optional"
    prompt_secret "Google OAuth Client Secret"    "freescout-google-client-secret"   "optional"
    prompt_secret "Google Admin Emails (CSV)"     "freescout-google-admin-emails"    "optional"
    prompt_secret "Google Allowed Domains (CSV)"  "freescout-google-allowed-domains" "optional"

    # ── Action1 RMM integration ───────────────────────────────────────────────
    log_step "Action1 RMM integration (optional — 3 roles)"

    log_info "Requires Action1 API credentials (3 least-privilege roles)."
    log_info "Create credentials at: https://app.action1.com → Settings → API"
    log_info "  Sync   = read-only inventory"
    log_info "  Run    = execute scripts / actions"
    log_info "  Manage = full administrative control"
    echo ""

    prompt_secret "Action1 Sync Client ID"          "freescout-action1-sync-client-id"       "optional"
    prompt_secret "Action1 Sync Client Secret"      "freescout-action1-sync-client-secret"   "optional"
    prompt_secret "Action1 Automation Runner Client ID"     "freescout-action1-automation-runner-client-id"     "optional"
    prompt_secret "Action1 Automation Runner Client Secret" "freescout-action1-automation-runner-client-secret" "optional"
    prompt_secret "Action1 Script Manager Client ID"        "freescout-action1-script-manager-client-id"        "optional"
    prompt_secret "Action1 Script Manager Client Secret"    "freescout-action1-script-manager-client-secret"    "optional"

    # ── Verify readability ────────────────────────────────────────────────────
    log_step "Verifying secrets are readable"

    local all_ok=true
    for secret in freescout-repo-token freescout-db-root-pass freescout-db-pass freescout-admin-pass; do
        verify_secret "$secret" || all_ok=false
    done
    for secret in freescout-agent-pass freescout-finance-pass freescout-reporter-pass \
                  freescout-google-client-id freescout-google-client-secret \
                  freescout-google-admin-emails freescout-google-allowed-domains \
                  freescout-action1-sync-client-id freescout-action1-sync-client-secret \
                  freescout-action1-automation-runner-client-id freescout-action1-automation-runner-client-secret \
                  freescout-action1-script-manager-client-id freescout-action1-script-manager-client-secret; do
        # Only verify optional secrets that were actually created
        if gcloud secrets describe "$secret" --project="$PROJECT_ID" >/dev/null 2>&1; then
            verify_secret "$secret" || true
        fi
    done

    # ── IAM ───────────────────────────────────────────────────────────────────
    setup_iam

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}✔ All required secrets are set and readable.${NC}"
    else
        echo -e "${YELLOW}⚠ Some secrets could not be verified — see IAM notes above.${NC}"
    fi
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    log_code "  1. Edit  deployment/deploy.conf.gcp  — set DOMAIN_NAME, ALLOWED_SOURCE_RANGES"
    log_code "  2. Validate:  bash deployment/gcp-config-validate.sh"
    log_code "  3. Deploy:    sudo bash deployment/gcp_deploy.sh"
    echo ""
}

main "$@"
