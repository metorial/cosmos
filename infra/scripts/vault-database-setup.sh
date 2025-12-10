#!/bin/bash
# Vault Database Secrets Engine Setup for Aurora PostgreSQL

# This script configures Vault's database secrets engine to dynamically
# generate database credentials for applications running in Nomad.

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

# Function to configure Vault database secrets engine
configure_vault_database_secrets() {
    local db_host=$1
    local db_port=$2
    local db_name=$3
    local db_username=$4
    local db_password=$5
    local region=$6

    log_section "Configuring Vault Database Secrets Engine"

    # Enable database secrets engine
    log_info "Enabling database secrets engine..."
    vault secrets enable -path=database database 2>&1 | grep -v "path is already in use" || true
    log_success "Database secrets engine enabled at path: database/"

    # Configure PostgreSQL connection
    log_info "Configuring Aurora PostgreSQL connection..."
    vault write database/config/aurora-postgres \
        plugin_name=postgresql-database-plugin \
        allowed_roles="nomad-app-readonly,nomad-app-readwrite,admin" \
        connection_url="postgresql://{{username}}:{{password}}@${db_host}:${db_port}/${db_name}?sslmode=require" \
        username="${db_username}" \
        password="${db_password}" \
        password_authentication=scram-sha-256

    log_success "Aurora PostgreSQL connection configured"

    # Test connection
    log_info "Testing database connection..."
    if vault read database/config/aurora-postgres > /dev/null 2>&1; then
        log_success "Database connection test successful"
    else
        log_error "Database connection test failed"
        return 1
    fi

    # Create read-only role for Nomad applications
    log_info "Creating read-only database role..."
    vault write database/roles/nomad-app-readonly \
        db_name=aurora-postgres \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
            GRANT CONNECT ON DATABASE ${db_name} TO \"{{name}}\"; \
            GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
            GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; \
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO \"{{name}}\";" \
        default_ttl="1h" \
        max_ttl="24h"

    log_success "Read-only role created: nomad-app-readonly"

    # Create read-write role for Nomad applications
    log_info "Creating read-write database role..."
    vault write database/roles/nomad-app-readwrite \
        db_name=aurora-postgres \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
            GRANT CONNECT ON DATABASE ${db_name} TO \"{{name}}\"; \
            GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
            GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; \
            GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\"; \
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"{{name}}\"; \
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO \"{{name}}\";" \
        default_ttl="1h" \
        max_ttl="24h"

    log_success "Read-write role created: nomad-app-readwrite"

    # Create admin role (for migrations, schema changes, etc.)
    log_info "Creating admin database role..."
    vault write database/roles/admin \
        db_name=aurora-postgres \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
            GRANT CONNECT ON DATABASE ${db_name} TO \"{{name}}\"; \
            GRANT ALL PRIVILEGES ON SCHEMA public TO \"{{name}}\"; \
            GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; \
            GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\"; \
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO \"{{name}}\"; \
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO \"{{name}}\";" \
        default_ttl="30m" \
        max_ttl="2h"

    log_success "Admin role created: admin"

    # Create Vault policies for database access
    log_info "Creating Vault policies for database access..."

    # Policy for read-only access
    vault policy write database-readonly - <<POLICY_EOF
# Allow reading credentials for read-only role
path "database/creds/nomad-app-readonly" {
  capabilities = ["read"]
}
POLICY_EOF
    log_success "Policy created: database-readonly"

    # Policy for read-write access
    vault policy write database-readwrite - <<POLICY_EOF
# Allow reading credentials for read-write role
path "database/creds/nomad-app-readwrite" {
  capabilities = ["read"]
}
POLICY_EOF
    log_success "Policy created: database-readwrite"

    # Policy for admin access
    vault policy write database-admin - <<POLICY_EOF
# Allow reading credentials for admin role
path "database/creds/admin" {
  capabilities = ["read"]
}

# Allow rotating root credentials
path "database/rotate-root/aurora-postgres" {
  capabilities = ["update"]
}

# Allow reading database configuration
path "database/config/aurora-postgres" {
  capabilities = ["read"]
}
POLICY_EOF
    log_success "Policy created: database-admin"

    # Create combined policy for Nomad workloads that need both read and write
    vault policy write nomad-database-access - <<POLICY_EOF
# Default read-write access for most Nomad workloads
path "database/creds/nomad-app-readwrite" {
  capabilities = ["read"]
}

# Allow read-only access as well
path "database/creds/nomad-app-readonly" {
  capabilities = ["read"]
}
POLICY_EOF
    log_success "Policy created: nomad-database-access"

    log_section "Database Secrets Engine Configuration Complete"

    echo ""
    log_info "Available database roles:"
    echo "  - nomad-app-readonly: Read-only access for queries"
    echo "  - nomad-app-readwrite: Full CRUD operations"
    echo "  - admin: Full admin access (for migrations)"

    echo ""
    log_info "Available Vault policies:"
    echo "  - database-readonly: Access to read-only credentials"
    echo "  - database-readwrite: Access to read-write credentials"
    echo "  - database-admin: Full admin access"
    echo "  - nomad-database-access: Default policy for Nomad workloads (read + write)"

    echo ""
    log_info "Example usage in Nomad job:"
    echo "  vault {"
    echo "    policies = [\"nomad-database-access\"]"
    echo "  }"
    echo ""
    echo "  template {"
    echo "    data = <<EOH"
    echo "{{ with secret \"database/creds/nomad-app-readwrite\" }}"
    echo "DB_HOST=${db_host}"
    echo "DB_PORT=${db_port}"
    echo "DB_NAME=${db_name}"
    echo "DB_USER={{ .Data.username }}"
    echo "DB_PASSWORD={{ .Data.password }}"
    echo "{{ end }}"
    echo "EOH"
    echo "    destination = \"secrets/db.env\""
    echo "    env = true"
    echo "  }"

    echo ""
    log_info "Test credential generation:"
    echo "  vault read database/creds/nomad-app-readonly"
    echo "  vault read database/creds/nomad-app-readwrite"
}

# Main execution
if [ "$#" -ne 6 ]; then
    log_error "Usage: $0 <db_host> <db_port> <db_name> <db_username> <db_password> <region>"
    echo ""
    echo "Example:"
    echo "  $0 aurora-cluster.cluster-xyz.us-east-1.rds.amazonaws.com 5432 cosmos dbadmin mypassword us-east-1"
    exit 1
fi

DB_HOST=$1
DB_PORT=$2
DB_NAME=$3
DB_USERNAME=$4
DB_PASSWORD=$5
REGION=$6

# Check if Vault is accessible
if ! vault status > /dev/null 2>&1; then
    log_error "Cannot connect to Vault. Make sure VAULT_ADDR and VAULT_TOKEN are set."
    echo ""
    echo "Set environment variables:"
    echo "  export VAULT_ADDR='http://127.0.0.1:8200'"
    echo "  export VAULT_TOKEN='your-root-token'"
    exit 1
fi

# Run configuration
configure_vault_database_secrets "$DB_HOST" "$DB_PORT" "$DB_NAME" "$DB_USERNAME" "$DB_PASSWORD" "$REGION"

log_success "Vault database secrets engine setup complete!"
