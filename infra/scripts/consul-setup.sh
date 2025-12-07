#!/bin/bash
# Consul installation and setup functions

CONSUL_VERSION="1.19.2"

install_consul() {
    local arch=$1  # "arm64" or "amd64"

    log_section "Installing Consul ($arch)"

    cd /tmp
    wget "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_${arch}.zip"
    unzip -o "consul_${CONSUL_VERSION}_linux_${arch}.zip" -d /tmp/consul-extract
    mv /tmp/consul-extract/consul /usr/local/bin/consul
    chmod +x /usr/local/bin/consul

    # Verify installation
    consul version

    # Create consul user
    useradd --system --home /etc/consul.d --shell /bin/false consul 2>/dev/null || true

    # Create directories
    mkdir -p /opt/consul
    mkdir -p /etc/consul.d
    chown -R consul:consul /opt/consul
    chown -R consul:consul /etc/consul.d

    log_success "Consul installed successfully"
}

configure_consul_server() {
    local region=$1
    local server_count=$2
    local private_ip=$3
    local cluster_name=$4

    log_info "Configuring Consul server..."

    cat > /etc/consul.d/consul.hcl <<EOF
datacenter = "$region"
data_dir = "/opt/consul"
bind_addr = "$private_ip"
client_addr = "0.0.0.0"
advertise_addr = "$private_ip"

server = true
bootstrap_expect = $server_count

retry_join = [
  "provider=aws tag_key=Role tag_value=consul-server region=$region"
]

ui_config {
  enabled = true
}

log_level = "INFO"

performance {
  raft_multiplier = 1
}
EOF

    chown consul:consul /etc/consul.d/consul.hcl
    log_success "Consul server configured"
}

configure_consul_client() {
    local region=$1
    local private_ip=$2
    local cluster_name=$3

    log_info "Configuring Consul client..."

    cat > /etc/consul.d/consul.hcl <<EOF
datacenter = "$region"
data_dir = "/opt/consul"
bind_addr = "$private_ip"
client_addr = "127.0.0.1"
advertise_addr = "$private_ip"

retry_join = [
  "provider=aws tag_key=Role tag_value=consul-server region=$region"
]

log_level = "INFO"
EOF

    chown consul:consul /etc/consul.d/consul.hcl
    log_success "Consul client configured"
}

create_consul_systemd_service() {
    log_info "Creating Consul systemd service..."

    cat > /etc/systemd/system/consul.service <<'EOF'
[Unit]
Description=Consul Agent
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target

[Service]
Type=notify
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    log_success "Consul systemd service created"
}

start_consul() {
    log_info "Starting Consul..."

    systemctl daemon-reload
    systemctl enable consul
    systemctl start consul

    log_info "Waiting for Consul to be ready..."
    sleep 10

    log_success "Consul started successfully"
}
