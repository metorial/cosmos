#!/bin/bash
# Agent installation and setup functions (cosmos-agent, sentinel-agent)

install_cosmos_agent() {
    local controller_addr=$1
    local cluster_name=$2

    log_section "Installing cosmos-agent"

    # Get the node ID
    local node_id=$(cat /etc/machine-id)

    # Create certificate directory
    mkdir -p /etc/cosmos/agent
    chmod 755 /etc/cosmos
    chmod 700 /etc/cosmos/agent

    # Create script to retrieve Vault token dynamically at service startup
    cat > /usr/local/bin/cosmos-agent-token.sh <<'TOKENSCRIPT'
#!/bin/bash
# Retrieve Vault token from Consul KV at service startup
TOKEN=$(consul kv get cosmos/agent-token 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to retrieve Vault token from Consul KV" >&2
  exit 1
fi
echo "$TOKEN"
TOKENSCRIPT

    chmod +x /usr/local/bin/cosmos-agent-token.sh

    # Create systemd service for cosmos-agent
    cat > /etc/systemd/system/cosmos-agent.service <<EOF
[Unit]
Description=Cosmos Agent
Documentation=https://github.com/metorial/cosmos
After=docker.service consul.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=0

ExecStartPre=-/usr/bin/docker stop cosmos-agent
ExecStartPre=-/usr/bin/docker rm cosmos-agent
ExecStartPre=/usr/bin/docker pull ghcr.io/metorial/cosmos-agent:latest

ExecStart=/bin/bash -c '/usr/bin/docker run --rm --name cosmos-agent \\
  --network host \\
  -v /var/run/docker.sock:/var/run/docker.sock \\
  -v /opt/cosmos-agent:/data \\
  -v /etc/cosmos:/etc/cosmos \\
  -e COSMOS_CONTROLLER_URL=cosmos-controller.service.consul:9091 \\
  -e CLUSTER_NAME=$cluster_name \\
  -e NODE_ID=$node_id \\
  -e VAULT_ADDR=http://active.vault.service.consul:8200 \\
  -e VAULT_TOKEN=\$(/usr/local/bin/cosmos-agent-token.sh) \\
  ghcr.io/metorial/cosmos-agent:latest'

ExecStop=/usr/bin/docker stop cosmos-agent

StandardOutput=journal
StandardError=journal
SyslogIdentifier=cosmos-agent

[Install]
WantedBy=multi-user.target
EOF

    log_success "cosmos-agent service created with dynamic token retrieval"
}

install_sentinel_agent() {
    local controller_addr=$1
    local cluster_name=$2

    log_section "Installing sentinel-agent"

    # Get the node ID
    local node_id=$(cat /etc/machine-id)

    # Create systemd service for sentinel-agent
    cat > /etc/systemd/system/sentinel-agent.service <<EOF
[Unit]
Description=Sentinel Agent
Documentation=https://github.com/metorial/sentinel
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=0

ExecStartPre=-/usr/bin/docker stop sentinel-agent
ExecStartPre=-/usr/bin/docker rm sentinel-agent
ExecStartPre=/usr/bin/docker pull ghcr.io/metorial/sentinel-agent:latest

ExecStart=/bin/bash -c '/usr/bin/docker run --rm --name sentinel-agent \\
  --network host \\
  -v /opt/sentinel-agent:/data \\
  -e CONTROLLER_URL=$controller_addr \\
  -e CLUSTER_NAME=$cluster_name \\
  -e NODE_ID=$node_id \\
  ghcr.io/metorial/sentinel-agent:latest'

ExecStop=/usr/bin/docker stop sentinel-agent

StandardOutput=journal
StandardError=journal
SyslogIdentifier=sentinel-agent

[Install]
WantedBy=multi-user.target
EOF

    log_success "sentinel-agent service created"
}

start_agents() {
    log_section "Starting agents"

    # Create data directories
    mkdir -p /opt/cosmos-agent
    mkdir -p /opt/sentinel-agent

    # Start cosmos-agent
    log_info "Starting cosmos-agent..."
    systemctl daemon-reload
    systemctl enable cosmos-agent
    systemctl start cosmos-agent

    # Start sentinel-agent (may not be available yet - will retry in background)
    log_info "Starting sentinel-agent..."
    systemctl enable sentinel-agent
    # Allow failure - image may not be accessible yet, systemd will keep retrying
    systemctl start sentinel-agent || echo "sentinel-agent image not available - systemd will retry"

    log_success "cosmos-agent started successfully"
}

check_agent_status() {
    log_section "Agent Status"

    log_info "cosmos-agent status:"
    systemctl status cosmos-agent --no-pager | grep "Active:"

    log_info "sentinel-agent status:"
    systemctl status sentinel-agent --no-pager | grep "Active:"
}
