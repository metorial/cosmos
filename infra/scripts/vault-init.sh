#!/bin/bash
# Vault auto-initialization setup

create_vault_init_script() {
    local cluster_name=$1
    local region=$2
    local instance_name=$3

    log_info "Creating Vault initialization script..."

    cat > /usr/local/bin/vault-init.sh <<'INITSCRIPT'
#!/bin/bash
# Vault Auto-Initialize Script
# Runs after Vault starts to automatically initialize if needed

# Get environment from systemd or use defaults
CLUSTER_NAME="${CLUSTER_NAME:-CLUSTER_NAME_PLACEHOLDER}"
REGION="${REGION:-REGION_PLACEHOLDER}"
INSTANCE_NAME="${INSTANCE_NAME:-INSTANCE_NAME_PLACEHOLDER}"

# Logging
exec >> /var/log/vault-init.log 2>&1

echo "==================================="
echo "Vault Auto-Init: $(date)"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Instance: $INSTANCE_NAME"
echo "==================================="

# Source cloud helper functions for SSM storage
if [ -f /tmp/cloud-helpers.sh ]; then
    source /tmp/cloud-helpers.sh
    echo "Loaded cloud helper functions"
else
    echo "WARNING: cloud-helpers.sh not found at /tmp/cloud-helpers.sh"
    echo "Recovery keys will not be saved to SSM Parameter Store"
fi

# Export Vault address
export VAULT_ADDR="http://127.0.0.1:8200"

# Wait for Vault API to be responsive
# Note: vault status returns exit code 2 when sealed/uninitialized, which is expected
MAX_WAIT=60
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  vault status >/dev/null 2>&1
  EXIT_CODE=$?
  # Exit code 0 = unsealed, 1 = error, 2 = sealed (both 0 and 2 mean API is responsive)
  if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 2 ]; then
    echo "Vault API is responsive (exit code: $EXIT_CODE)"
    break
  fi
  echo "Waiting for Vault API... ($WAIT_COUNT/$MAX_WAIT)"
  sleep 2
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
  echo "ERROR: Vault API did not become responsive in time"
  exit 1
fi

# Automated initialization (only runs on first server, idempotent)
echo "Checking if Vault needs initialization..."

# Check if already initialized
if vault status 2>&1 | grep -q "Initialized.*false"; then
  echo "Vault is not initialized. Attempting to initialize..."

  # Use Consul KV as a distributed lock to ensure only one server initializes
  # Try to acquire lock with a 60-second TTL
  LOCK_ACQUIRED=false
  for i in {1..5}; do
    if consul lock -timeout=5s -n=1 vault/init-lock sleep 120 & LOCK_PID=$!; then
      sleep 2
      # Double-check we still have the lock by checking if process is running
      if ps -p $LOCK_PID > /dev/null 2>&1; then
        LOCK_ACQUIRED=true
        echo "Acquired initialization lock"
        break
      fi
    fi
    echo "Failed to acquire lock, attempt $i/5. Waiting 10 seconds..."
    sleep 10
  done

  if [ "$LOCK_ACQUIRED" = true ]; then
    # Double-check Vault is still uninitialized
    if vault status 2>&1 | grep -q "Initialized.*false"; then
      echo "Initializing Vault with recovery keys (KMS auto-unseal enabled)..."

      # Initialize with 5 recovery keys, threshold of 3
      INIT_OUTPUT=$(vault operator init \
        -recovery-shares=5 \
        -recovery-threshold=3 \
        -format=json 2>&1)

      INIT_EXIT_CODE=$?

      if [ $INIT_EXIT_CODE -eq 0 ]; then
        echo "Vault initialized successfully!"

        # Store initialization output securely in cloud provider secret store (encrypted)
        # Try to create secret
        cloud_put_secret \
          "/$CLUSTER_NAME/vault/init-keys" \
          "$INIT_OUTPUT" \
          "$REGION" \
          "Vault recovery keys and root token (ENCRYPTED - DO NOT SHARE)" \
          2>&1 | tee /var/log/vault-init-storage.log
        SSM_EXIT_CODE=${PIPESTATUS[0]}

        # If secret already exists, update it
        if [ $SSM_EXIT_CODE -ne 0 ]; then
          echo "Secret may already exist, trying to update..."
          cloud_update_secret \
            "/$CLUSTER_NAME/vault/init-keys" \
            "$INIT_OUTPUT" \
            "$REGION" \
            2>&1 | tee -a /var/log/vault-init-storage.log
          SSM_EXIT_CODE=${PIPESTATUS[0]}
        fi

        if [ $SSM_EXIT_CODE -eq 0 ]; then
          echo "Recovery keys and root token securely stored in SSM Parameter Store"
          echo "Parameter: /$CLUSTER_NAME/vault/init-keys (SecureString)"

          # Also store in local file with restricted permissions (backup)
          echo "$INIT_OUTPUT" > /opt/vault/init-keys.json
          chmod 600 /opt/vault/init-keys.json
          chown vault:vault /opt/vault/init-keys.json

          # Extract root token for verification
          ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

          # Mark as initialized in Consul KV
          consul kv put vault/initialized true
          consul kv put vault/initialized-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          consul kv put vault/initialized-by "$INSTANCE_NAME"

          echo "Vault initialization complete!"
          echo "Root token stored securely in SSM Parameter Store"
          echo ""
          echo "IMPORTANT: Recovery keys and root token are stored in:"
          echo "  - SSM Parameter Store: /$CLUSTER_NAME/vault/init-keys (encrypted)"
          echo "  - Local file: /opt/vault/init-keys.json (backup)"
          echo ""
          echo "To retrieve:"
          echo "  aws ssm get-parameter --region $REGION --name '/$CLUSTER_NAME/vault/init-keys' --with-decryption --query 'Parameter.Value' --output text | jq ."

          # Configure Vault PKI for Cosmos
          echo ""
          echo "Configuring Vault PKI for Cosmos certificates..."
          export VAULT_TOKEN="$ROOT_TOKEN"

          # Enable PKI secrets engine
          vault secrets enable -path=cosmos-pki pki 2>&1 | tee -a /var/log/vault-init.log || echo "PKI may already be enabled"

          # Configure max lease TTL
          vault secrets tune -max-lease-ttl=87600h cosmos-pki 2>&1 | tee -a /var/log/vault-init.log

          # Generate root CA
          vault write -field=certificate cosmos-pki/root/generate/internal \
              common_name="Cosmos Internal CA" \
              issuer_name="cosmos-root" \
              ttl=87600h > /opt/vault/cosmos-ca.crt 2>&1

          echo "Root CA certificate saved to /opt/vault/cosmos-ca.crt"

          # Configure CA and CRL URLs
          vault write cosmos-pki/config/urls \
              issuing_certificates="http://active.vault.service.consul:8200/v1/cosmos-pki/ca" \
              crl_distribution_points="http://active.vault.service.consul:8200/v1/cosmos-pki/crl" 2>&1 | tee -a /var/log/vault-init.log

          # Create role for controller certificates
          vault write cosmos-pki/roles/controller \
              allowed_domains="controller,cosmos-controller,service.consul,consul" \
              allow_subdomains=true \
              allow_bare_domains=true \
              allow_localhost=true \
              allow_any_name=true \
              allow_ip_sans=true \
              max_ttl="8760h" \
              ttl="8760h" \
              key_bits=2048 \
              key_type=rsa 2>&1 | tee -a /var/log/vault-init.log

          # Create role for agent certificates
          vault write cosmos-pki/roles/agent \
              allowed_domains="agent,cosmos-agent,service.consul,consul" \
              allow_subdomains=true \
              allow_bare_domains=true \
              allow_localhost=true \
              allow_any_name=true \
              allow_ip_sans=true \
              max_ttl="720h" \
              ttl="72h" \
              key_bits=2048 \
              key_type=rsa 2>&1 | tee -a /var/log/vault-init.log

          echo "Vault PKI configured successfully for Cosmos"

          # Create Vault policies for Cosmos
          echo ""
          echo "Creating Vault policies for Cosmos..."

          # Controller policy
          vault policy write cosmos-controller - <<POLICY_EOF
path "cosmos-pki/issue/controller" {
  capabilities = ["create", "update"]
}
path "cosmos-pki/certs" {
  capabilities = ["list"]
}
path "cosmos-pki/revoke" {
  capabilities = ["create", "update"]
}
POLICY_EOF

          # Agent policy
          vault policy write cosmos-agent - <<POLICY_EOF
path "cosmos-pki/issue/agent" {
  capabilities = ["create", "update"]
}
path "cosmos-pki/certs" {
  capabilities = ["list"]
}
path "cosmos-pki/revoke" {
  capabilities = ["create", "update"]
}
POLICY_EOF

          echo "Vault policies created successfully"

          # Create tokens for Cosmos components
          echo ""
          echo "Creating Vault tokens for Cosmos components..."

          # Controller token
          CONTROLLER_TOKEN=$(vault token create \
              -policy=cosmos-controller \
              -ttl=0 \
              -display-name="cosmos-controller" \
              -format=json | jq -r '.auth.client_token')

          # Agent token
          AGENT_TOKEN=$(vault token create \
              -policy=cosmos-agent \
              -ttl=0 \
              -display-name="cosmos-agent" \
              -format=json | jq -r '.auth.client_token')

          echo "Cosmos tokens created successfully"

          # Store tokens in SSM
          echo ""
          echo "Storing Cosmos tokens in SSM Parameter Store..."

          cloud_put_secret \
            "/$CLUSTER_NAME/cosmos/controller-token" \
            "$CONTROLLER_TOKEN" \
            "$REGION" \
            "Vault token for cosmos-controller (policy: cosmos-controller)" \
            2>&1 | tee /var/log/cosmos-controller-token.log || \
          cloud_update_secret \
            "/$CLUSTER_NAME/cosmos/controller-token" \
            "$CONTROLLER_TOKEN" \
            "$REGION" \
            2>&1 | tee -a /var/log/cosmos-controller-token.log

          cloud_put_secret \
            "/$CLUSTER_NAME/cosmos/agent-token" \
            "$AGENT_TOKEN" \
            "$REGION" \
            "Vault token for cosmos-agent (policy: cosmos-agent)" \
            2>&1 | tee /var/log/cosmos-agent-token.log || \
          cloud_update_secret \
            "/$CLUSTER_NAME/cosmos/agent-token" \
            "$AGENT_TOKEN" \
            "$REGION" \
            2>&1 | tee -a /var/log/cosmos-agent-token.log

          echo "Cosmos tokens stored in SSM Parameter Store:"
          echo "  - /$CLUSTER_NAME/cosmos/controller-token"
          echo "  - /$CLUSTER_NAME/cosmos/agent-token"

          # Also store in Consul KV for Nomad templates
          echo ""
          echo "Storing tokens in Consul KV for Nomad job templates..."
          consul kv put cosmos/controller-token "$CONTROLLER_TOKEN"
          consul kv put cosmos/agent-token "$AGENT_TOKEN"
          echo "Cosmos tokens stored in Consul KV"

          # Configure Aurora PostgreSQL database secrets engine
          echo ""
          echo "Configuring Vault database secrets engine for Aurora PostgreSQL..."

          # Retrieve Aurora connection info from Terraform outputs via SSM or environment
          # These should be set as environment variables in the systemd service
          DB_HOST=${AURORA_ENDPOINT:-""}
          DB_READER_HOST=${AURORA_READER_ENDPOINT:-""}
          DB_PORT=${AURORA_PORT:-"5432"}
          DB_NAME=${AURORA_DATABASE:-"postgres"}

          # Get master password from Secrets Manager
          if [ -n "$DB_HOST" ]; then
            echo "Aurora endpoint found: $DB_HOST"

            # Retrieve master password from Secrets Manager
            DB_SECRET=$(aws secretsmanager get-secret-value \
              --region $REGION \
              --secret-id "$CLUSTER_NAME-aurora-master-password" \
              --query 'SecretString' \
              --output text 2>/dev/null || echo "")

            if [ -n "$DB_SECRET" ]; then
              DB_USERNAME=$(echo "$DB_SECRET" | jq -r '.username')
              DB_PASSWORD=$(echo "$DB_SECRET" | jq -r '.password')

              # Enable database secrets engine
              vault secrets enable -path=database database 2>&1 | grep -v "path is already in use" || true

              # Configure PostgreSQL connection
              vault write database/config/aurora-postgres \
                plugin_name=postgresql-database-plugin \
                allowed_roles="nomad-app-readonly,nomad-app-readwrite,admin" \
                connection_url="postgresql://{{username}}:{{password}}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require" \
                username="$DB_USERNAME" \
                password="$DB_PASSWORD" \
                password_authentication=scram-sha-256 \
                2>&1 | tee -a /var/log/vault-init.log

              # Create read-only role
              vault write database/roles/nomad-app-readonly \
                db_name=aurora-postgres \
                creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
                  GRANT CONNECT ON DATABASE ${DB_NAME} TO \"{{name}}\"; \
                  GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
                  GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; \
                  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO \"{{name}}\";" \
                default_ttl="1h" \
                max_ttl="24h" \
                2>&1 | tee -a /var/log/vault-init.log

              # Create read-write role
              vault write database/roles/nomad-app-readwrite \
                db_name=aurora-postgres \
                creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
                  GRANT CONNECT ON DATABASE ${DB_NAME} TO \"{{name}}\"; \
                  GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
                  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; \
                  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\"; \
                  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"{{name}}\"; \
                  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO \"{{name}}\";" \
                default_ttl="1h" \
                max_ttl="24h" \
                2>&1 | tee -a /var/log/vault-init.log

              # Create Vault policies for database access
              vault policy write database-readonly - <<DB_POLICY_EOF
path "database/creds/nomad-app-readonly" {
  capabilities = ["read"]
}
DB_POLICY_EOF

              vault policy write database-readwrite - <<DB_POLICY_EOF
path "database/creds/nomad-app-readwrite" {
  capabilities = ["read"]
}
DB_POLICY_EOF

              vault policy write nomad-database-access - <<DB_POLICY_EOF
path "database/creds/nomad-app-readwrite" {
  capabilities = ["read"]
}
path "database/creds/nomad-app-readonly" {
  capabilities = ["read"]
}
DB_POLICY_EOF

              echo "Vault database secrets engine configured successfully for Aurora"
              echo "Database roles available: nomad-app-readonly, nomad-app-readwrite"
              echo "Vault policies created: database-readonly, database-readwrite, nomad-database-access"

              # Store Aurora connection info in Consul KV for Nomad jobs
              consul kv put aurora/endpoint "$DB_HOST"
              consul kv put aurora/reader-endpoint "${DB_READER_HOST:-$DB_HOST}"
              consul kv put aurora/port "$DB_PORT"
              consul kv put aurora/database "$DB_NAME"
              echo "Aurora connection info stored in Consul KV"
            else
              echo "WARNING: Could not retrieve Aurora master password from Secrets Manager"
              echo "You can configure the database secrets engine manually later using vault-database-setup.sh"
            fi
          else
            echo "Aurora endpoint not provided. Skipping database secrets engine configuration."
            echo "You can configure it manually later using vault-database-setup.sh"
          fi

          # Configure Nomad-Vault integration
          echo ""
          echo "Configuring Nomad-Vault integration..."

          # Create Nomad server policy
          vault policy write nomad-server - <<NOMAD_POLICY_EOF
path "auth/token/create/nomad-cluster" {
  capabilities = ["update"]
}
path "auth/token/roles/nomad-cluster" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/lookup" {
  capabilities = ["update"]
}
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}
path "sys/capabilities-self" {
  capabilities = ["update"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
NOMAD_POLICY_EOF

          # Create token role for Nomad cluster
          vault write /auth/token/roles/nomad-cluster \
            disallowed_policies=nomad-server \
            explicit_max_ttl=0 \
            orphan=false \
            period=259200 \
            renewable=true

          # Create Nomad server token
          NOMAD_TOKEN=$(vault token create -policy nomad-server -period 72h -orphan -format=json | jq -r .auth.client_token)

          # Store in Consul KV
          consul kv put nomad/vault-token "$NOMAD_TOKEN"

          echo "Nomad-Vault integration configured successfully"
          echo "Nomad server token stored in Consul KV: nomad/vault-token"
        else
          echo "ERROR: Failed to store keys in SSM Parameter Store"
          cat /var/log/vault-init-storage.log
        fi
      else
        echo "ERROR: Vault initialization failed"
        echo "$INIT_OUTPUT"
      fi
    else
      echo "Vault was initialized by another server while we were acquiring the lock"
    fi

    # Release lock
    kill $LOCK_PID 2>/dev/null || true
  else
    echo "Could not acquire initialization lock. Another server may be initializing Vault."
    echo "Waiting to see if initialization completes..."
    for i in {1..30}; do
      if vault status 2>&1 | grep -q "Initialized.*true"; then
        echo "Vault has been initialized by another server"
        break
      fi
      sleep 2
    done
  fi
elif vault status 2>&1 | grep -q "Initialized.*true"; then
  echo "Vault is already initialized"

  # Check if sealed (should be auto-unsealed with KMS)
  if vault status 2>&1 | grep -q "Sealed.*false"; then
    echo "Vault is unsealed (KMS auto-unseal working correctly)"
  else
    echo "WARNING: Vault is initialized but sealed. KMS auto-unseal may not be working."
    vault status
  fi
else
  echo "Could not determine Vault status"
  vault status || true
fi

echo ""
echo "Final Vault initialization check complete"
INITSCRIPT

    # Replace placeholders with actual values
    sed -i "s/CLUSTER_NAME_PLACEHOLDER/$cluster_name/g" /usr/local/bin/vault-init.sh
    sed -i "s/REGION_PLACEHOLDER/$region/g" /usr/local/bin/vault-init.sh
    sed -i "s/INSTANCE_NAME_PLACEHOLDER/$instance_name/g" /usr/local/bin/vault-init.sh

    chmod +x /usr/local/bin/vault-init.sh

    log_success "Vault initialization script created"
}

create_vault_init_systemd_service() {
    local cluster_name=$1
    local region=$2
    local instance_name=$3

    log_info "Creating Vault initialization systemd service..."

    cat > /etc/systemd/system/vault-init.service <<'EOF'
[Unit]
Description=Vault Auto-Initialization
After=vault.service consul.service
Requires=vault.service
ConditionPathExists=/usr/local/bin/vault-init.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vault-init.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

# Ensure required variables are available
Environment="VAULT_ADDR=http://127.0.0.1:8200"
Environment="CLUSTER_NAME=CLUSTER_NAME_PLACEHOLDER"
Environment="REGION=REGION_PLACEHOLDER"
Environment="INSTANCE_NAME=INSTANCE_NAME_PLACEHOLDER"
Environment="AURORA_ENDPOINT=AURORA_ENDPOINT_PLACEHOLDER"
Environment="AURORA_READER_ENDPOINT=AURORA_READER_ENDPOINT_PLACEHOLDER"
Environment="AURORA_PORT=AURORA_PORT_PLACEHOLDER"
Environment="AURORA_DATABASE=AURORA_DATABASE_PLACEHOLDER"

[Install]
WantedBy=multi-user.target
EOF

    # Replace placeholders with actual values in service file
    sed -i "s/CLUSTER_NAME_PLACEHOLDER/$cluster_name/g" /etc/systemd/system/vault-init.service
    sed -i "s/REGION_PLACEHOLDER/$region/g" /etc/systemd/system/vault-init.service
    sed -i "s/INSTANCE_NAME_PLACEHOLDER/$instance_name/g" /etc/systemd/system/vault-init.service

    log_success "Vault initialization systemd service created"
}

setup_vault_auto_init() {
    local cluster_name=$1
    local region=$2
    local instance_name=$3
    local aurora_endpoint=${4:-""}
    local aurora_port=${5:-"5432"}
    local aurora_database=${6:-"postgres"}
    local aurora_reader_endpoint=${7:-""}

    log_section "Setting up Vault auto-initialization"

    create_vault_init_script "$cluster_name" "$region" "$instance_name"
    create_vault_init_systemd_service "$cluster_name" "$region" "$instance_name"

    # Update Aurora environment variables in systemd service
    if [ -n "$aurora_endpoint" ]; then
        sed -i "s|AURORA_ENDPOINT_PLACEHOLDER|$aurora_endpoint|g" /etc/systemd/system/vault-init.service
        sed -i "s|AURORA_PORT_PLACEHOLDER|$aurora_port|g" /etc/systemd/system/vault-init.service
        sed -i "s|AURORA_DATABASE_PLACEHOLDER|$aurora_database|g" /etc/systemd/system/vault-init.service

        # Set reader endpoint (use writer endpoint if reader not provided)
        if [ -n "$aurora_reader_endpoint" ]; then
            sed -i "s|AURORA_READER_ENDPOINT_PLACEHOLDER|$aurora_reader_endpoint|g" /etc/systemd/system/vault-init.service
        else
            sed -i "s|AURORA_READER_ENDPOINT_PLACEHOLDER|$aurora_endpoint|g" /etc/systemd/system/vault-init.service
        fi

        log_info "Aurora database configuration will be set up during Vault initialization"
    else
        # Remove Aurora environment variables if not provided
        sed -i '/AURORA_ENDPOINT_PLACEHOLDER/d' /etc/systemd/system/vault-init.service
        sed -i '/AURORA_PORT_PLACEHOLDER/d' /etc/systemd/system/vault-init.service
        sed -i '/AURORA_DATABASE_PLACEHOLDER/d' /etc/systemd/system/vault-init.service
        sed -i '/AURORA_READER_ENDPOINT_PLACEHOLDER/d' /etc/systemd/system/vault-init.service
        log_info "Aurora database not configured. Will skip database secrets engine setup."
    fi

    # Enable and start vault initialization service (runs after Vault is up)
    systemctl daemon-reload
    systemctl enable vault-init.service
    # Start in background to allow user-data to complete
    systemctl start vault-init.service &

    log_success "Vault auto-initialization configured"
    log_info "Check status with: systemctl status vault-init.service"
}
