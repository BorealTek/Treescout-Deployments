#!/usr/bin/env bash
# ==============================================================================
# GCP Secrets Bootstrap for TreeScout
#
# Creates or updates all application secrets in GCP Secret Manager.
# Run this ONCE before deploying, from any machine with gcloud authenticated.
#
# Usage:
#   bash deployment/gcp-secrets-bootstrap.sh [--project=PROJECT_ID]
#
#   Interactive wizard (default):
#     bash deployment/gcp-secrets-bootstrap.sh
#
#   Generate a config file template to fill in offline:
#     bash deployment/gcp-secrets-bootstrap.sh --create-config
#     bash deployment/gcp-secrets-bootstrap.sh --create-config=/path/to/secrets.conf
#
#   Populate secrets non-interactively from a filled-in config file:
#     bash deployment/gcp-secrets-bootstrap.sh --from-file=secrets.conf
#
# Config file format:
#   KEY="value"   (shell variable assignments — sourced directly)
#   Empty values are silently skipped (optional secrets).
#   Keep the file outside version control — it contains real secrets.
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
CONFIG_FILE=""
MODE="interactive"   # interactive | create-config | from-file

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --project=*) PROJECT_ID="${arg#--project=}" ;;
        --create-config)        MODE="create-config"; CONFIG_FILE="secrets.conf" ;;
        --create-config=*)      MODE="create-config"; CONFIG_FILE="${arg#--create-config=}" ;;
        --from-file=*)          MODE="from-file";     CONFIG_FILE="${arg#--from-file=}" ;;
        -h|--help)
            echo "Usage: bash deployment/gcp-secrets-bootstrap.sh [OPTIONS]"
            echo ""
            echo "  (no flags)               Interactive wizard"
            echo "  --create-config[=FILE]   Write a blank config template (default: secrets.conf)"
            echo "  --from-file=FILE         Load secrets from a config file (non-interactive)"
            echo "  --project=PROJECT_ID     Override GCP project"
            exit 0
            ;;
    esac
done

# Auto-detect secrets.conf in the current directory when no mode was specified
if [ "$MODE" = "interactive" ]; then
    for candidate in "secrets.conf" "$(dirname "$0")/secrets.conf"; do
        if [ -f "$candidate" ]; then
            echo -e "${YELLOW}⚠${NC} Found config file: ${candidate}"
            local_choice=""
            read -r -p "  Use this file instead of the interactive wizard? [Y/n]: " local_choice
            if [[ ! "$local_choice" =~ ^[Nn]$ ]]; then
                MODE="from-file"
                CONFIG_FILE="$candidate"
            fi
            break
        fi
    done
fi

# ==============================================================================
# CONFIG FILE SUPPORT
# ==============================================================================

# Write a blank template the operator fills in offline.
create_secrets_config() {
    local out="${CONFIG_FILE:-secrets.conf}"

    if [ -f "$out" ]; then
        log_warning "File already exists: $out"
        local overwrite
        read -r -p "  Overwrite? [y/N]: " overwrite
        [[ "$overwrite" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }
    fi

    cat > "$out" <<'EOF'
# =============================================================================
# TreeScout GCP Secrets Config
#
# Fill in the values below, then run:
#   bash deployment/gcp-secrets-bootstrap.sh --from-file=secrets.conf
#
# Rules:
#   - Leave a value empty ("") to skip that secret (safe for optional ones).
#   - REQUIRED values must be non-empty or the script will abort.
#   - Keep this file OUT of version control — it contains real secrets.
# =============================================================================

# ---------------------------------------------------------------------------
# REQUIRED
# ---------------------------------------------------------------------------
REPO_TOKEN=""             # GitHub PAT (scope: repo) for private module repos
DB_ROOT_PASS=""           # MariaDB root password
DB_PASS=""                # MariaDB application-user password
ADMIN_PASS=""             # Admin account initial password

# ---------------------------------------------------------------------------
# OPTIONAL — seeded user accounts
# ---------------------------------------------------------------------------
AGENT_PASS=""             # Agent account password
FINANCE_PASS=""           # Finance account password
REPORTER_PASS=""          # Reporter account password

# ---------------------------------------------------------------------------
# OPTIONAL — Google OAuth  (requires GoogleAdmin module)
# ---------------------------------------------------------------------------
GOOGLE_CLIENT_ID=""
GOOGLE_CLIENT_SECRET=""
GOOGLE_ADMIN_EMAILS=""    # CSV — emails auto-promoted to admin on first OAuth sign-in
GOOGLE_ALLOWED_DOMAINS="" # CSV — domains whose new users are auto-provisioned internally

# ---------------------------------------------------------------------------
# OPTIONAL — Action1 RMM  (requires Action1 module)
# ---------------------------------------------------------------------------
ACTION1_SYNC_CLIENT_ID=""
ACTION1_SYNC_CLIENT_SECRET=""
ACTION1_AUTOMATION_RUNNER_CLIENT_ID=""
ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET=""
ACTION1_SCRIPT_MANAGER_CLIENT_ID=""
ACTION1_SCRIPT_MANAGER_CLIENT_SECRET=""
ACTION1_REGION="us"          # Region for Action1 API (e.g. us, eu)
EOF

    chmod 600 "$out"
    log_success "Template written: $out"
    log_info  "Fill in the values, then run:"
    log_code  "  bash deployment/gcp-secrets-bootstrap.sh --from-file=${out}"
    echo ""
}

# Source the config file and push every non-empty value to Secret Manager.
push_all_from_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    log_step "Loading secrets from config file: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    # Helper: push if non-empty, abort if required and empty.
    _push() {
        local label="$1" secret_name="$2" value="$3" required="${4:-optional}"
        if [ -z "$value" ]; then
            if [ "$required" = "required" ]; then
                log_error "${label} is required but empty in ${CONFIG_FILE}"
                exit 1
            fi
            log_info "Skipped (empty): ${secret_name}"
            return 0
        fi
        upsert_secret "$secret_name" "$value"
    }

    log_step "Required secrets"
    _push "GitHub PAT"                "treescout-repo-token"   "${REPO_TOKEN:-}"   "required"
    _push "Database root password"    "treescout-db-root-pass" "${DB_ROOT_PASS:-}" "required"
    _push "Database app-user password" "treescout-db-pass"      "${DB_PASS:-}"      "required"
    _push "Admin user password"       "treescout-admin-pass"   "${ADMIN_PASS:-}"   "required"

    log_step "Optional secrets (seeded user accounts)"
    _push "Agent user password"    "treescout-agent-pass"    "${AGENT_PASS:-}"
    _push "Finance user password"  "treescout-finance-pass"  "${FINANCE_PASS:-}"
    _push "Reporter user password" "treescout-reporter-pass" "${REPORTER_PASS:-}"

    log_step "Google OAuth integration"
    _push "Google OAuth Client ID"        "treescout-google-client-id"       "${GOOGLE_CLIENT_ID:-}"
    _push "Google OAuth Client Secret"    "treescout-google-client-secret"   "${GOOGLE_CLIENT_SECRET:-}"
    _push "Google Admin Emails"           "treescout-google-admin-emails"    "${GOOGLE_ADMIN_EMAILS:-}"
    _push "Google Allowed Domains"        "treescout-google-allowed-domains" "${GOOGLE_ALLOWED_DOMAINS:-}"

    log_step "Action1 RMM integration"
    _push "Action1 Sync Client ID"                    "treescout-action1-sync-client-id"                    "${ACTION1_SYNC_CLIENT_ID:-}"
    _push "Action1 Sync Client Secret"                "treescout-action1-sync-client-secret"                "${ACTION1_SYNC_CLIENT_SECRET:-}"
    _push "Action1 Automation Runner Client ID"       "treescout-action1-automation-runner-client-id"       "${ACTION1_AUTOMATION_RUNNER_CLIENT_ID:-}"
    _push "Action1 Automation Runner Client Secret"   "treescout-action1-automation-runner-client-secret"   "${ACTION1_AUTOMATION_RUNNER_CLIENT_SECRET:-}"
    _push "Action1 Script Manager Client ID"          "treescout-action1-script-manager-client-id"          "${ACTION1_SCRIPT_MANAGER_CLIENT_ID:-}"
    _push "Action1 Script Manager Client Secret"      "treescout-action1-script-manager-client-secret"      "${ACTION1_SCRIPT_MANAGER_CLIENT_SECRET:-}"
    _push "Action1 Region"                            "treescout-action1-region"                            "${ACTION1_REGION:-}"
}

# ==============================================================================
# PREREQUISITES
# ==============================================================================

check_prereqs() {
    log_step "Checking prerequisites"

    if ! command -v gcloud >/dev/null 2>&1; then
        log_error "gcloud CLI not found."
        if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
            log_info "WSL detected: the Windows gcloud install is not available here."
            log_info "Install gcloud inside WSL:"
            log_code "  curl https://sdk.cloud.google.com | bash && exec -l \$SHELL"
        else
            log_code "Install: https://cloud.google.com/sdk/docs/install"
        fi
        exit 1
    fi
    log_success "gcloud CLI found"

    local active_account
    active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    if [ -z "$active_account" ]; then
        log_warning "gcloud not authenticated — launching login..."
        if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
            log_info "WSL detected: a browser window will open on your Windows host to complete login."
        fi
        if ! gcloud auth login --update-adc 2>&1; then
            log_error "Authentication failed or was cancelled."
            exit 1
        fi
        active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
        if [ -z "$active_account" ]; then
            log_error "Still not authenticated after login attempt. Please run: gcloud auth login"
            exit 1
        fi
    fi
    log_success "Authenticated as: $active_account"

    # Resolve project
    if [ -z "$PROJECT_ID" ]; then
        PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
    fi
    if [ -z "$PROJECT_ID" ]; then
        # Try to list accessible projects and let the user pick one
        log_info "Fetching accessible GCP projects..."
        local projects_list
        projects_list=$(gcloud projects list --format="value(projectId)" 2>/dev/null)
        local project_count
        project_count=$(echo "$projects_list" | grep -c . 2>/dev/null || echo 0)

        if [ "$project_count" -gt 0 ]; then
            echo ""
            echo -e "  ${CYAN}Available projects:${NC}"
            local i=1
            while IFS= read -r proj; do
                echo -e "  ${GREY}[$i]${NC} $proj"
                i=$((i + 1))
            done <<< "$projects_list"
            echo ""

            local choice
            read -r -p "  Select project number (or press Enter to type an ID manually): " choice

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$project_count" ]; then
                PROJECT_ID=$(echo "$projects_list" | sed -n "${choice}p")
            fi
        fi
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
    # ── Non-interactive modes (no banner, no full wizard) ─────────────────────
    if [ "$MODE" = "create-config" ]; then
        create_secrets_config
        exit 0
    fi

    if [ "$MODE" = "from-file" ]; then
        clear
        echo -e "${CYAN}"
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║         TreeScout — GCP Secrets Bootstrap                    ║"
        echo "║         Non-interactive mode (--from-file)                   ║"
        echo "╚═══════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        check_prereqs
        push_all_from_config

        log_step "Verifying required secrets are readable"
        local all_ok=true
        for secret in treescout-repo-token treescout-db-root-pass treescout-db-pass treescout-admin-pass; do
            verify_secret "$secret" || all_ok=false
        done
        setup_iam

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
        exit 0
    fi

    # ── Interactive wizard ────────────────────────────────────────────────────
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         TreeScout — GCP Secrets Bootstrap                    ║"
    echo "║   Creates or updates all app secrets in Secret Manager       ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    log_info "Secrets that will be created / updated:"
    echo ""
    log_code "  REQUIRED"
    log_code "    treescout-repo-token        GitHub PAT for private module repos"
    log_code "    treescout-db-root-pass      Database root password"
    log_code "    treescout-db-pass           Database application-user password"
    log_code "    treescout-admin-pass        Admin user initial password"
    echo ""
    log_code "  OPTIONAL (default seeded users)"
    log_code "    treescout-agent-pass        Agent user password"
    log_code "    treescout-finance-pass      Finance user password"
    log_code "    treescout-reporter-pass     Reporter user password"
    echo ""
    log_code "  OPTIONAL (Google OAuth integration)"
    log_code "    treescout-google-client-id       Google OAuth Client ID"
    log_code "    treescout-google-client-secret   Google OAuth Client Secret"
    log_code "    treescout-google-admin-emails    CSV — auto-promoted admin emails"
    log_code "    treescout-google-allowed-domains CSV — auto-internal user domains"
    echo ""
    log_code "  OPTIONAL (Action1 RMM — 3 roles: Sync / Run / Manage)"
    log_code "    treescout-action1-sync-client-id       Action1 Sync Client ID"
    log_code "    treescout-action1-sync-client-secret   Action1 Sync Client Secret"
    log_code "    treescout-action1-automation-runner-client-id     Action1 Automation Runner Client ID"
    log_code "    treescout-action1-automation-runner-client-secret Action1 Automation Runner Client Secret"
    log_code "    treescout-action1-script-manager-client-id        Action1 Script Manager Client ID"
    log_code "    treescout-action1-script-manager-client-secret    Action1 Script Manager Client Secret"
    log_code "    treescout-action1-region                          Action1 API region (e.g. us, eu)"
    echo ""

    check_prereqs

    # ── Required secrets ─────────────────────────────────────────────────────
    log_step "Required secrets"

    prompt_secret "GitHub PAT (scope: repo)" "treescout-repo-token"
    prompt_secret "Database root password"   "treescout-db-root-pass"
    prompt_secret "Database app-user password" "treescout-db-pass"
    prompt_secret "Admin user password"      "treescout-admin-pass"

    # ── Optional secrets ──────────────────────────────────────────────────────
    log_step "Optional secrets (seeded user accounts)"

    log_info "These create the default agent / finance / reporter accounts on first install."
    log_info "Skip any you don't need — those accounts won't be created."
    echo ""

    prompt_secret "Agent user password"    "treescout-agent-pass"    "optional"
    prompt_secret "Finance user password"  "treescout-finance-pass"  "optional"
    prompt_secret "Reporter user password" "treescout-reporter-pass" "optional"

    # ── Google OAuth integration ─────────────────────────────────────────────
    log_step "Google OAuth integration (optional)"

    log_info "Required only when the GoogleAdmin module is installed."
    log_info "GOOGLE_ADMIN_EMAILS   — comma-separated emails auto-promoted to admin."
    log_info "GOOGLE_ALLOWED_DOMAINS — comma-separated domains for auto-internal provisioning."
    echo ""

    prompt_secret "Google OAuth Client ID"        "treescout-google-client-id"       "optional"
    prompt_secret "Google OAuth Client Secret"    "treescout-google-client-secret"   "optional"
    prompt_secret "Google Admin Emails (CSV)"     "treescout-google-admin-emails"    "optional"
    prompt_secret "Google Allowed Domains (CSV)"  "treescout-google-allowed-domains" "optional"

    # ── Action1 RMM integration ───────────────────────────────────────────────
    log_step "Action1 RMM integration (optional — 3 roles)"

    log_info "Requires Action1 API credentials (3 least-privilege roles)."
    log_info "Create credentials at: https://app.action1.com → Settings → API"
    log_info "  Sync   = read-only inventory"
    log_info "  Run    = execute scripts / actions"
    log_info "  Manage = full administrative control"
    echo ""

    prompt_secret "Action1 Sync Client ID"          "treescout-action1-sync-client-id"       "optional"
    prompt_secret "Action1 Sync Client Secret"      "treescout-action1-sync-client-secret"   "optional"
    prompt_secret "Action1 Automation Runner Client ID"     "treescout-action1-automation-runner-client-id"     "optional"
    prompt_secret "Action1 Automation Runner Client Secret" "treescout-action1-automation-runner-client-secret" "optional"
    prompt_secret "Action1 Script Manager Client ID"        "treescout-action1-script-manager-client-id"        "optional"
    prompt_secret "Action1 Script Manager Client Secret"    "treescout-action1-script-manager-client-secret"    "optional"
    prompt_secret "Action1 Region (e.g. us, eu)"           "treescout-action1-region"                          "optional"

    # ── Verify readability ────────────────────────────────────────────────────
    log_step "Verifying secrets are readable"

    local all_ok=true
    for secret in treescout-repo-token treescout-db-root-pass treescout-db-pass treescout-admin-pass; do
        verify_secret "$secret" || all_ok=false
    done
    for secret in treescout-agent-pass treescout-finance-pass treescout-reporter-pass \
                  treescout-google-client-id treescout-google-client-secret \
                  treescout-google-admin-emails treescout-google-allowed-domains \
                  treescout-action1-sync-client-id treescout-action1-sync-client-secret \
                  treescout-action1-automation-runner-client-id treescout-action1-automation-runner-client-secret \
                  treescout-action1-script-manager-client-id treescout-action1-script-manager-client-secret \
                  treescout-action1-region; do
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
    log_info "Tip: next time you can use a config file instead of the interactive wizard:"
    log_code "  bash deployment/gcp-secrets-bootstrap.sh --create-config   # generates template"
    log_code "  bash deployment/gcp-secrets-bootstrap.sh --from-file=secrets.conf  # populates from it"
    echo ""
}

main "$@"
