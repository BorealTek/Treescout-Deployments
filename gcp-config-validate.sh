#!/usr/bin/env bash

#===============================================================================
# GCP TreeScout Configuration Validator
#
# Pre-deployment validation script that checks deploy.conf for common errors
# before launching gcp_deploy.sh.
#
# Usage:
#   bash deployment/gcp-config-validate.sh
#   bash deployment/gcp-config-validate.sh deploy.conf  # Custom path
#
#===============================================================================

# Note: -e (errexit) is intentionally omitted — this script collects all
# validation failures before reporting; immediate exit would hide later issues.
set -uo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/deploy.conf"

# Colors
readonly RED='\033[38;5;196m'
readonly GREEN='\033[38;5;46m'
readonly YELLOW='\033[38;5;226m'
readonly CYAN='\033[38;5;51m'
readonly BLUE='\033[38;5;27m'
readonly GREY='\033[38;5;240m'
readonly NC='\033[0m'

# Counters
ERRORS=0
WARNINGS=0
NOTES=0
AUTO_APPROVE=false

#===============================================================================
# LOGGING
#===============================================================================

log_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}$*${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*"
    ((ERRORS++))
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $*"
    ((WARNINGS++))
}

log_note() {
    echo -e "${BLUE}ℹ${NC} $*"
    ((NOTES++))
}

log_code() {
    echo -e "${GREY}  → $*${NC}"
}

#===============================================================================
# VALIDATION FUNCTIONS
#===============================================================================

validate_file_exists() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        echo ""
        echo "Create from template:"
        log_code "cp deployment/deploy.conf.gcp deploy.conf"
        exit 1
    fi
    log_success "Configuration file found: $CONFIG_FILE"
}

validate_key() {
    local key=$1
    # Returns: 0=found and non-empty, 1=key present but empty, 2=key absent from file
    if ! grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        return 2
    fi
    local value
    value=$(grep "^${key}=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -z "$value" ]; then
        return 1
    fi
    return 0
}

get_value() {
    local key=$1
    grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo ""
}

validate_required() {
    local key=$1
    local description=$2
    local rc=0
    validate_key "$key" || rc=$?

    case "$rc" in
        0) log_success "$description: $key" ; return 0 ;;
        1) log_error "$description is empty: $key=" ; return 1 ;;
        2) log_error "$description is missing from config: $key" ; return 1 ;;
    esac
}

validate_password() {
    local key=$1
    local description=$2
    local min_length=${3:-8}

    if validate_key "$key"; then
        local value
        value=$(get_value "$key")

        # Check for default/template values
        if [[ "$value" =~ ^(change_me|ChangeMe|changeme|password123|change_me_password|DEFAULT|TEMPLATE) ]]; then
            log_error "$description still uses template default: $value. Please change!"
            return 1
        fi

        # Check minimum length
        if [ ${#value} -lt $min_length ]; then
            log_warning "$description is less than $min_length characters: ${#value} chars"
            return 1
        fi

        log_success "$description is secure (${#value} chars)"
        return 0
    else
        log_error "$description is missing: $key"
        return 1
    fi
}

validate_domain() {
    local key=$1
    local description=$2

    if validate_key "$key"; then
        local value
        value=$(get_value "$key")

        # Check for template value
        if [[ "$value" =~ ^(example\.com|yourcompany\.com|DOMAIN|treescout\.example\.com|your-domain\.com)$ ]]; then
            log_error "$description still uses template default: $value. Set to actual domain or GCP IP"
            return 1
        fi

        # Check basic format (must not be empty or a sentence)
        if [ ${#value} -lt 5 ]; then
            log_error "$description appears invalid: $value (too short)"
            return 1
        fi

        # Warn if looks like hostname
        if [[ "$value" =~ \. ]]; then
            log_success "$description looks valid: $value"
            return 0
        else
            log_warning "$description might be incomplete (no dot): $value"
            return 0
        fi
    else
        log_error "$description is missing: $key"
        return 1
    fi
}

validate_email() {
    local key=$1
    local description=$2

    if validate_key "$key"; then
        local value
        value=$(get_value "$key")

        # Check for template value
        if [[ "$value" =~ @example\.com$ ]]; then
            log_error "$description still uses template: $value. Set to actual email"
            return 1
        fi

        # Basic email validation
        if [[ "$value" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_success "$description looks valid: $value"
            return 0
        else
            log_warning "$description might be invalid: $value"
            return 0
        fi
    else
        log_error "$description is missing: $key"
        return 1
    fi
}

validate_token() {
    local key=$1
    local description=$2

    if validate_key "$key"; then
        local value
        value=$(get_value "$key")

        if [ -z "$value" ]; then
            log_warning "$description is not set (modules will fail to install)"
            return 1
        fi

        # GitHub token starts with 'ghp_'
        if [[ "$value" =~ ^(ghp_|token_|REPO_TOKEN)$ ]]; then
            log_error "$description still uses template or placeholder: $value"
            return 1
        fi

        if [[ "$value" =~ ^ghp_ ]]; then
            log_success "$description looks valid (GitHub PAT format)"
            return 0
        else
            log_warning "$description doesn't look like a GitHub PAT (should start with ghp_)"
            return 0
        fi
    else
        log_note "$description not set (optional, but modules require it)"
        return 0
    fi
}

validate_url() {
    local key=$1
    local description=$2

    if validate_key "$key"; then
        local value
        value=$(get_value "$key")

        if [[ "$value" =~ ^https?:// ]]; then
            log_success "$description looks valid: $value"
            return 0
        else
            log_warning "$description might be invalid (should start with http:// or https://): $value"
            return 0
        fi
    else
        log_note "$description not found in config"
        return 0
    fi
}

validate_boolean() {
    local key=$1
    local description=$2

    if validate_key "$key"; then
        local value
        local value_lower
        value=$(get_value "$key")

        # Lowercase for comparison
        value_lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')

        if [[ "$value_lower" =~ ^(true|false)$ ]]; then
            log_success "$description is set: $value"
            return 0
        else
            log_warning "$description has unexpected value (should be true/false): $value"
            return 0
        fi
    else
        log_note "$description not found in config"
        return 0
    fi
}

# Returns 0 if the given secret-name variable is set AND USE_GCP_SECRET_MANAGER=true.
# Usage: is_sm_managed "DB_ROOT_PASS_SECRET" && echo "managed by SM"
is_sm_managed() {
    local secret_var="$1"
    local use_sm
    use_sm=$(get_value "USE_GCP_SECRET_MANAGER")
    [ "$use_sm" = "true" ] || return 1
    local secret_name
    secret_name=$(get_value "$secret_var")
    [ -n "$secret_name" ] || return 1
    return 0
}

#===============================================================================
# MAIN VALIDATION FLOW
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

    log_header "TreeScout GCP Configuration Validator"

    echo ""

    # File check
    echo -e "${YELLOW}1. Checking file...${NC}"
    validate_file_exists
    echo ""

    # Critical fields
    echo -e "${YELLOW}2. Validating CRITICAL settings (must fix before deploy)...${NC}"
    validate_domain "DOMAIN_NAME" "Domain Name"
    if is_sm_managed "ADMIN_PASS_SECRET"; then
        log_success "Admin Password: managed by Secret Manager ($(get_value ADMIN_PASS_SECRET))"
    else
        validate_password "ADMIN_PASS" "Admin Password" 8
    fi
    if is_sm_managed "DB_ROOT_PASS_SECRET"; then
        log_success "Database Root Password: managed by Secret Manager ($(get_value DB_ROOT_PASS_SECRET))"
    else
        validate_password "DB_ROOT_PASS" "Database Root Password" 8
    fi
    if is_sm_managed "DB_PASS_SECRET"; then
        log_success "Database User Password: managed by Secret Manager ($(get_value DB_PASS_SECRET))"
    else
        validate_password "DB_PASS" "Database User Password" 8
    fi
    validate_email "ADMIN_EMAIL" "Admin Email"
    echo ""

    # Important fields
    echo -e "${YELLOW}3. Validating IMPORTANT settings...${NC}"
    validate_required "DB_USER" "Database User"
    validate_required "DB_NAME" "Database Name"
    validate_email "AGENT_EMAIL" "Agent Email"
    echo ""

    # GCP-specific fields
    echo -e "${YELLOW}4. Validating GCP settings...${NC}"
    validate_boolean "EXPOSE_PUBLIC_PORTS" "Expose Public Ports"
    validate_required "ALLOWED_SOURCE_RANGES" "Allowed Source Ranges (IPs)"
    validate_required "GCP_FIREWALL_RULE_NAME" "GCP Firewall Rule Name"
    echo ""

    # Optional integrations
    echo -e "${YELLOW}5. Checking optional integrations...${NC}"
    if validate_key "GOOGLE_CLIENT_ID"; then
        log_note "Google OAuth appears configured"
    else
        log_note "Google OAuth not configured (optional)"
    fi

    if validate_key "LETSENCRYPT_EMAIL"; then
        log_note "Let's Encrypt email configured"
    else
        log_note "Let's Encrypt not configured (default: self-signed certs)"
    fi
    echo ""

    # Module check
    echo -e "${YELLOW}6. Checking module configuration...${NC}"
    local module_count=0
    if grep -q "MODULES_TO_INSTALL=(" "$CONFIG_FILE"; then
        local module_count
        module_count=$(awk '
            /^[[:space:]]*MODULES_TO_INSTALL=\(/ { in_array=1; next }
            in_array && /^[[:space:]]*\)/ { in_array=0 }
            in_array && /^[[:space:]]*"/ { count++ }
            END { print count+0 }
        ' "$CONFIG_FILE")
        log_note "Modules configured in MODULES_TO_INSTALL array: $module_count"
        if grep -q "REPO_TOKEN|main" "$CONFIG_FILE"; then
            log_success "Module repos show placeholder REPO_TOKEN (will be substituted)"
        fi

        if [ "$module_count" -gt 0 ]; then
            if is_sm_managed "REPO_TOKEN_SECRET"; then
                log_success "REPO_TOKEN: managed by Secret Manager ($(get_value REPO_TOKEN_SECRET))"
            elif validate_key "REPO_TOKEN"; then
                local repo_token
                repo_token=$(get_value "REPO_TOKEN")
                if [[ "$repo_token" =~ ^(REPO_TOKEN|ghp_your_token_here)$ ]] || [ -z "$repo_token" ]; then
                    log_error "REPO_TOKEN is required when MODULES_TO_INSTALL has entries (or enable USE_GCP_SECRET_MANAGER=true)"
                else
                    log_success "REPO_TOKEN is set for module repository access"
                fi
            else
                log_error "REPO_TOKEN is required when MODULES_TO_INSTALL has entries (or enable USE_GCP_SECRET_MANAGER=true)"
            fi
        fi
    else
        log_warning "MODULES_TO_INSTALL not found in config"
    fi
    echo ""

    # Summary
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    VALIDATION SUMMARY${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [ $ERRORS -gt 0 ]; then
        echo -e "${RED}❌ ERRORS: $ERRORS (FIX REQUIRED)${NC}"
    else
        echo -e "${GREEN}✓ No errors${NC}"
    fi

    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠ WARNINGS: $WARNINGS (Review recommended)${NC}"
    else
        echo -e "${GREEN}✓ No warnings${NC}"
    fi

    if [ $NOTES -gt 0 ]; then
        echo -e "${BLUE}ℹ NOTES: $NOTES (Informational)${NC}"
    fi

    echo ""

    # Decision
    if [ $ERRORS -gt 0 ]; then
        echo -e "${RED}❌ Configuration validation FAILED${NC}"
        echo ""
        echo "Fix the errors above in: $CONFIG_FILE"
        echo ""
        echo "Then run validation again:"
        log_code "bash deployment/gcp-config-validate.sh"
        exit 1
    fi

    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠ Configuration has issues (warnings above)${NC}"
        echo ""
        if [ "$AUTO_APPROVE" = true ]; then
            log_note "Proceeding past warnings (auto-approved via --yes / CI=true)"
        else
            read -p "Proceed with deployment anyway? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Cancelled. Review and fix warnings, then try again."
                exit 0
            fi
        fi
    fi

    echo -e "${GREEN}✓ Configuration validation PASSED${NC}"
    echo ""
    echo "Configuration is ready for deployment. Run:"
    log_code "sudo bash deployment/gcp_deploy.sh"
    echo ""
    exit 0
}

# Run if sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
