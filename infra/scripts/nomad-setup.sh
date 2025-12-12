#!/bin/bash
# Nomad installation and setup functions

NOMAD_VERSION="1.8.3"
CNI_VERSION="1.3.0"

install_nomad() {
    local arch=$1  # "arm64" or "amd64"

    log_section "Installing Nomad ($arch)"

    cd /tmp
    wget "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_${arch}.zip"
    unzip -o "nomad_${NOMAD_VERSION}_linux_${arch}.zip"
    mv nomad /usr/local/bin/
    chmod +x /usr/local/bin/nomad

    # Verify installation
    nomad version

    # Create nomad user
    useradd --system --home /etc/nomad.d --shell /bin/false nomad 2>/dev/null || true

    # Create directories
    mkdir -p /opt/nomad/data
    mkdir -p /etc/nomad.d
    chown -R nomad:nomad /opt/nomad
    chown -R nomad:nomad /etc/nomad.d

    log_success "Nomad installed successfully"
}

install_cni_plugins() {
    local arch=$1  # "arm64" or "amd64"

    log_info "Installing CNI plugins for networking..."

    mkdir -p /opt/cni/bin
    cd /tmp
    wget "https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-${arch}-v${CNI_VERSION}.tgz"
    tar -C /opt/cni/bin -xzf "cni-plugins-linux-${arch}-v${CNI_VERSION}.tgz"

    log_success "CNI plugins installed"
}

setup_nomad_vault_auto_config() {
    local cluster_name=$1
    local region=$2

    log_info "Setting up Nomad-Vault auto-configuration..."

    # Create the nomad-vault-config script
    cat > /usr/local/bin/nomad-vault-config.sh <<'VAULTCONFIG'
#!/bin/bash
# Nomad-Vault Integration Configuration
# This script automatically configures Nomad to integrate with Vault
# after Vault initialization completes and tokens are available

# Get environment from systemd or use defaults
CLUSTER_NAME="${CLUSTER_NAME:-CLUSTER_NAME_PLACEHOLDER}"
REGION="${REGION:-REGION_PLACEHOLDER}"

# Logging
exec >> /var/log/nomad-vault-config.log 2>&1

echo "==================================="
echo "Nomad-Vault Config: $(date)"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "==================================="

# Check if Vault configuration already exists in Nomad config
if grep -q "vault {" /etc/nomad.d/nomad.hcl; then
  echo "Vault configuration already exists in Nomad config"
  exit 0
fi

# Wait for Vault tokens to be available in Consul KV
echo "Waiting for Vault tokens in Consul KV..."
MAX_WAIT=300
WAIT_COUNT=0
VAULT_TOKEN=""

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  VAULT_TOKEN=$(consul kv get nomad/vault-token 2>/dev/null || echo "")
  if [ -n "$VAULT_TOKEN" ]; then
    echo "Vault token found in Consul KV"
    break
  fi
  echo "Waiting for Vault token... ($WAIT_COUNT/$MAX_WAIT)"
  sleep 5
  WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ -z "$VAULT_TOKEN" ]; then
  echo "ERROR: Vault token not found in Consul KV after ${MAX_WAIT}s"
  exit 1
fi

# Append Vault configuration to Nomad config
echo "Adding Vault integration to Nomad configuration..."
cat >> /etc/nomad.d/nomad.hcl <<EOF

vault {
  enabled = true
  address = "http://vault.service.consul:8200"
  token = "$VAULT_TOKEN"
  create_from_role = "nomad-cluster"
}
EOF

# Set correct ownership based on whether this is a server or client
if grep -q "server {" /etc/nomad.d/nomad.hcl; then
  # Server mode runs as nomad user
  chown nomad:nomad /etc/nomad.d/nomad.hcl
  echo "Configured Nomad server for Vault integration"
else
  # Client mode runs as root
  chown root:root /etc/nomad.d/nomad.hcl
  echo "Configured Nomad client for Vault integration"
fi

# Restart Nomad to apply the configuration
echo "Restarting Nomad to apply Vault configuration..."
systemctl restart nomad

# Wait for Nomad to come back up
sleep 5

# Verify Nomad is running
if systemctl is-active --quiet nomad; then
  echo "Nomad restarted successfully with Vault integration"

  # Verify Vault integration is working by checking logs
  echo "Checking for Vault token renewal in logs..."
  sleep 5
  if journalctl -u nomad -n 50 --no-pager | grep -q "successfully renewed token"; then
    echo "SUCCESS: Vault integration is working correctly"
  else
    echo "WARNING: Could not verify Vault integration from logs, but Nomad is running"
  fi
else
  echo "ERROR: Nomad failed to restart"
  exit 1
fi

echo ""
echo "Nomad-Vault configuration complete!"
VAULTCONFIG

    # Replace placeholders
    sed -i "s/CLUSTER_NAME_PLACEHOLDER/$cluster_name/g" /usr/local/bin/nomad-vault-config.sh
    sed -i "s/REGION_PLACEHOLDER/$region/g" /usr/local/bin/nomad-vault-config.sh
    chmod +x /usr/local/bin/nomad-vault-config.sh

    # Create systemd service
    cat > /etc/systemd/system/nomad-vault-config.service <<EOF
[Unit]
Description=Nomad-Vault Integration Auto-Configuration
After=nomad.service consul.service
Requires=nomad.service consul.service
ConditionPathExists=/usr/local/bin/nomad-vault-config.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nomad-vault-config.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

Environment="CLUSTER_NAME=$cluster_name"
Environment="REGION=$region"

[Install]
WantedBy=multi-user.target
EOF

    # Enable the service (don't start it yet - let systemd start it after nomad.service)
    systemctl daemon-reload
    systemctl enable nomad-vault-config.service

    log_success "Nomad-Vault auto-configuration service installed"
    log_info "Service will start automatically after Nomad is running"
    log_info "Nomad will automatically configure Vault integration when token becomes available"
}

configure_nomad_server() {
    local region=$1
    local server_count=$2
    local private_ip=$3
    local cluster_name=$4

    log_info "Configuring Nomad server..."

    cat > /etc/nomad.d/nomad.hcl <<EOF
datacenter = "$region"
data_dir = "/opt/nomad/data"
bind_addr = "$private_ip"

addresses {
  http = "0.0.0.0"
  rpc  = "$private_ip"
  serf = "$private_ip"
}

advertise {
  http = "$private_ip"
  rpc  = "$private_ip"
  serf = "$private_ip"
}

server {
  enabled = true
  bootstrap_expect = $server_count

  server_join {
    retry_join = ["provider=aws tag_key=Role tag_value=nomad-server region=$region"]
  }
}

consul {
  address = "127.0.0.1:8500"
  auto_advertise = true
  server_auto_join = true
  client_auto_join = true
}

log_level = "INFO"
EOF

    chown nomad:nomad /etc/nomad.d/nomad.hcl
    log_success "Nomad server configured"

    # Setup auto-configuration for Vault integration (will run asynchronously)
    setup_nomad_vault_auto_config "$cluster_name" "$region"
}

configure_nomad_client() {
    local region=$1
    local instance_name=$2
    local node_pool=$3
    local node_class=$4
    local cluster_name=$5
    local private_ip=$6

    log_info "Configuring Nomad client..."

    cat > /etc/nomad.d/nomad.hcl <<EOF
datacenter = "$region"
data_dir = "/opt/nomad/data"
bind_addr = "$private_ip"
name = "$instance_name"

client {
  enabled = true
  node_pool = "$node_pool"
  node_class = "$node_class"

  server_join {
    retry_join = ["provider=aws tag_key=Role tag_value=nomad-server region=$region"]
  }

  host_volume "docker-sock" {
    path = "/var/run/docker.sock"
    read_only = false
  }

  meta {
    cluster = "$cluster_name"
    node_pool = "$node_pool"
    node_class = "$node_class"
  }
}

consul {
  address = "127.0.0.1:8500"
  auto_advertise = true
  client_auto_join = true
}

plugin "docker" {
  config {
    allow_privileged = false
    volumes {
      enabled = true
    }
  }
}

log_level = "INFO"
EOF

    chown nomad:nomad /etc/nomad.d/nomad.hcl
    log_success "Nomad client configured"

    # Setup auto-configuration for Vault integration (will run asynchronously)
    setup_nomad_vault_auto_config "$cluster_name" "$region"
}

create_nomad_systemd_service() {
    local mode=$1  # "server" or "client"

    log_info "Creating Nomad systemd service..."

    local user="nomad"
    local group="nomad"
    local wants_line="Wants=consul.service"

    # Clients need root to manage containers
    if [ "$mode" = "client" ]; then
        user="root"
        group="root"
        wants_line="Wants=consul.service docker.service"
    fi

    cat > /etc/systemd/system/nomad.service <<EOF
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/
Requires=network-online.target
After=network-online.target
$wants_line
After=consul.service

[Service]
Type=notify
User=$user
Group=$group
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d/nomad.hcl
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
LimitNOFILE=65536
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF

    log_success "Nomad systemd service created"
}

start_nomad() {
    log_info "Starting Nomad..."

    systemctl daemon-reload
    systemctl enable nomad
    systemctl start nomad

    # Wait for Nomad to be ready before proceeding
    log_info "Waiting for Nomad agent to be ready..."
    MAX_WAIT=30
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if nomad node status >/dev/null 2>&1; then
            log_success "Nomad agent is ready"
            break
        fi
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        log_warn "Nomad agent did not become ready within ${MAX_WAIT}s (may still be starting)"
    fi

    log_success "Nomad started successfully"

    # Start vault-config service if it exists (will configure Vault integration)
    if systemctl is-enabled nomad-vault-config.service >/dev/null 2>&1; then
        log_info "Starting Nomad-Vault auto-configuration..."
        systemctl start nomad-vault-config.service &
    fi
}
