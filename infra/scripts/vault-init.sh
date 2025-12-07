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

    log_section "Setting up Vault auto-initialization"

    create_vault_init_script "$cluster_name" "$region" "$instance_name"
    create_vault_init_systemd_service "$cluster_name" "$region" "$instance_name"

    # Enable and start vault initialization service (runs after Vault is up)
    systemctl daemon-reload
    systemctl enable vault-init.service
    # Start in background to allow user-data to complete
    systemctl start vault-init.service &

    log_success "Vault auto-initialization configured"
    log_info "Check status with: systemctl status vault-init.service"
}
