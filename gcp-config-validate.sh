#!/usr/bin/env bash

#===============================================================================
# GCP FreeScout Configuration Validator
#
# Pre-deployment validation script that checks deploy.conf for common errors
# before launching gcp_deploy.sh.
#
# Usage:
#   bash deployment/gcp-config-validate.sh
#   bash deployment/gcp-config-validate.sh deploy.conf  # Custom path
#
#===============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${1:-${SCRIPT_DIR}/deploy.conf}"

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
    local value
    value=$(grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true

    if [ -z "$value" ]; then
        return 1  # Not found or empty
    fi
    return 0  # Found
}

get_value() {
    local key=$1
    grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo ""
}

validate_required() {
    local key=$1
    local description=$2

    if validate_key "$key"; then
        local value
        value=$(get_value "$key")

        if [ -z "$value" ] || [ "$value" = "" ]; then
            log_error "$description is empty: $key="
            return 1
        fi

        log_success "$description: $key"
        return 0
    else
        log_error "$description is missing: $key"
        return 1
    fi
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
        if [[ "$value" =~ ^(example\.com|yourcompany\.com|DOMAIN|freescout\.example\.com|your-domain\.com)$ ]]; then
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

#===============================================================================
# MAIN VALIDATION FLOW
#===============================================================================

main() {
    log_header "FreeScout GCP Configuration Validator"

    echo ""

    # File check
    echo -e "${YELLOW}1. Checking file...${NC}"
    validate_file_exists
    echo ""

    # Critical fields
    echo -e "${YELLOW}2. Validating CRITICAL settings (must fix before deploy)...${NC}"
    validate_required "DOMAIN_NAME" "Domain Name"
    validate_password "ADMIN_PASS" "Admin Password" 8
    validate_password "DB_ROOT_PASS" "Database Root Password" 8
    validate_password "DB_PASS" "Database User Password" 8
    validate_email "ADMIN_EMAIL" "Admin Email"
    echo ""

    # Important fields
    echo -e "${YELLOW}3. Validating IMPORTANT settings...${NC}"
    validate_required "DB_USER" "Database User"
    validate_required "DB_NAME" "Database Name"
    validate_email "AGENT_EMAIL" "Agent Email"
    validate_token "REPO_TOKEN" "GitHub PAT Token (required for modules)"
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
        read -p "Proceed with deployment anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled. Review and fix warnings, then try again."
            exit 0
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
