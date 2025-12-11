#!/bin/bash
# Store Aurora Master Credentials in Vault
# This script should be run after Vault is initialized and Aurora is created

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Check if Vault is accessible
if ! vault status > /dev/null 2>&1; then
    log_error "Cannot connect to Vault. Make sure VAULT_ADDR and VAULT_TOKEN are set."
    echo ""
    echo "Set environment variables:"
    echo "  export VAULT_ADDR='http://127.0.0.1:8200'"
    echo "  export VAULT_TOKEN='your-root-token'"
    exit 1
fi

log_section "Storing Aurora Master Credentials in Vault"

# Get Aurora credentials
if [ "$#" -eq 2 ]; then
    DB_USERNAME=$1
    DB_PASSWORD=$2
    log_info "Using provided credentials"
else
    log_info "Fetching Aurora credentials from Terraform outputs and AWS Secrets Manager..."

    # Get secret ARN from Terraform
    SECRET_ARN=$(terraform output -json 2>/dev/null | jq -r '.aurora_secret_arn.value')
    if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "null" ]; then
        log_error "Could not get Aurora secret ARN from Terraform"
        echo ""
        echo "Usage: $0 <db_username> <db_password>"
        echo "  OR: Run from terraform directory with Aurora already deployed"
        exit 1
    fi

    # Get region from Terraform
    REGION=$(terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type == "aws_instance") | .values.availability_zone' | head -1 | sed 's/[a-z]$//')

    # Get credentials from Secrets Manager
    SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" --query 'SecretString' --output text)
    DB_USERNAME=$(echo "$SECRET_JSON" | jq -r '.username')
    DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')

    log_success "Retrieved credentials from AWS Secrets Manager"
fi

# Enable KV v2 secrets engine if not already enabled
log_info "Ensuring KV v2 secrets engine is enabled..."
vault secrets enable -version=2 -path=secret kv 2>&1 | grep -v "path is already in use" || true
log_success "KV v2 secrets engine ready at path: secret/"

# Store credentials in Vault
log_info "Storing Aurora master credentials in Vault..."
vault kv put secret/aurora/master \
    username="$DB_USERNAME" \
    password="$DB_PASSWORD"

log_success "Aurora master credentials stored at: secret/aurora/master"

# Create db-access policy for database credentials
log_info "Creating db-access Vault policy..."
vault policy write db-access - <<POLICY_EOF
# Allow reading Aurora master credentials
path "secret/data/aurora/master" {
  capabilities = ["read"]
}
POLICY_EOF

log_success "Policy created: db-access"

log_section "Setup Complete"

echo ""
log_info "Aurora master credentials are now stored in Vault"
echo "  Path: secret/aurora/master"
echo "  Username: $DB_USERNAME"
echo ""
log_info "The db-access policy has been created"
echo "  Add this policy to any Nomad job that needs database access"
echo ""
log_info "Test reading the credentials:"
echo "  vault kv get secret/aurora/master"

