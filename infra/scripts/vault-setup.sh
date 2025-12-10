#!/bin/bash
# Vault installation and setup functions

VAULT_VERSION="1.17.0"

install_vault() {
    local arch=$1  # "arm64" or "amd64"

    log_section "Installing Vault ($arch)"

    cd /tmp
    wget "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${arch}.zip"
    unzip -o "vault_${VAULT_VERSION}_linux_${arch}.zip"
    mv vault /usr/local/bin/
    chmod +x /usr/local/bin/vault

    # Give vault the ability to use mlock
    setcap cap_ipc_lock=+ep /usr/local/bin/vault

    # Verify installation
    vault version

    # Create vault user
    useradd --system --home /etc/vault.d --shell /bin/false vault 2>/dev/null || true

    # Create directories
    mkdir -p /opt/vault/data
    mkdir -p /etc/vault.d
    chown -R vault:vault /opt/vault
    chown -R vault:vault /etc/vault.d

    log_success "Vault installed successfully"
}

configure_vault_server() {
    local region=$1
    local private_ip=$2
    local cluster_name=$3
    local kms_key_id=${4:-""}

    log_info "Configuring Vault server..."

    cat > /etc/vault.d/vault.hcl <<EOF
ui = true

storage "consul" {
  address = "127.0.0.1:8500"
  path    = "vault/"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://$private_ip:8200"
cluster_addr = "http://$private_ip:8201"

log_level = "INFO"
EOF

    # Add KMS auto-unseal if KMS key ID is provided
    if [ -n "$kms_key_id" ]; then
        cat >> /etc/vault.d/vault.hcl <<EOF

# AWS KMS Auto-Unseal
seal "awskms" {
  region     = "$region"
  kms_key_id = "$kms_key_id"
}
EOF
        log_success "KMS auto-unseal configured"
    fi

    chown vault:vault /etc/vault.d/vault.hcl
    log_success "Vault server configured"

    log_warn "IMPORTANT: Vault is configured with TLS disabled for simplicity."
    log_warn "In production, you should enable TLS for secure communication."
}

create_vault_systemd_service() {
    log_info "Creating Vault systemd service..."

    cat > /etc/systemd/system/vault.service <<'EOF'
[Unit]
Description=Vault
Documentation=https://www.vaultproject.io/
Requires=network-online.target
After=network-online.target
Wants=consul.service
After=consul.service

[Service]
Type=notify
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

    log_success "Vault systemd service created"
}

start_vault() {
    log_info "Starting Vault..."

    systemctl daemon-reload
    systemctl enable vault

    # Start vault, but don't fail if it times out during systemd notification
    # Vault may take longer than systemd's timeout to initialize, especially on first boot
    systemctl start vault || true

    # Wait for Vault API to become responsive (more reliable than systemd status)
    log_info "Waiting for Vault API to be ready..."
    export VAULT_ADDR="http://127.0.0.1:8200"

    MAX_WAIT=60
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        # vault status returns exit code 2 when sealed/uninitialized, which is expected
        # Exit code 0 = unsealed, 1 = error, 2 = sealed
        if vault status >/dev/null 2>&1; then
            EXIT_CODE=$?
            if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 2 ]; then
                log_success "Vault API is responsive"
                log_info "Vault will be automatically initialized by vault-init service"
                return 0
            fi
        fi

        log_info "Waiting for Vault API... ($WAIT_COUNT/$MAX_WAIT)"
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    log_warn "Vault API did not become responsive within $MAX_WAIT seconds"
    log_warn "Vault may still be starting - check 'systemctl status vault' and /var/log/vault.log"

    # Don't fail - let the initialization continue, as Vault might come up later
    return 0
}
