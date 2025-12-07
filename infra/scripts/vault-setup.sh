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
    systemctl start vault

    log_info "Waiting for Vault to be ready..."
    sleep 5

    log_success "Vault started successfully"

    log_warn "Vault needs to be initialized and unsealed manually."
    log_info "Run the following commands on ONE Vault server:"
    log_info "  export VAULT_ADDR='http://127.0.0.1:8200'"
    log_info "  vault operator init"
    log_info "Then unseal on ALL Vault servers with:"
    log_info "  vault operator unseal <unseal-key>"
}
