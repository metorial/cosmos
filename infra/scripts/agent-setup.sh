#!/bin/bash
# Agent installation and setup functions (cosmos-agent, command-core-agent)

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

install_command_core_agent() {
    local commander_addr=$1
    local cluster_name=$2

    log_section "Installing command-core-agent"

    # Get the node ID
    local node_id=$(cat /etc/machine-id)

    # Create systemd service for command-core-agent
    cat > /etc/systemd/system/command-core-agent.service <<EOF
[Unit]
Description=Command Core Agent (Outpost)
Documentation=https://github.com/metorial/command-core
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=0

ExecStartPre=-/usr/bin/docker stop command-core-agent
ExecStartPre=-/usr/bin/docker rm command-core-agent
ExecStartPre=/usr/bin/docker pull ghcr.io/metorial/command-core-agent:latest

ExecStart=/usr/bin/docker run --rm --name command-core-agent \\
  --network host \\
  -v /opt/command-core-agent:/data \\
  -e COMMANDER_ADDR=$commander_addr \\
  -e CLUSTER_NAME=$cluster_name \\
  -e NODE_ID=$node_id \\
  ghcr.io/metorial/command-core-agent:latest

ExecStop=/usr/bin/docker stop command-core-agent

StandardOutput=journal
StandardError=journal
SyslogIdentifier=command-core-agent

[Install]
WantedBy=multi-user.target
EOF

    log_success "command-core-agent service created"
}

start_agents() {
    log_section "Starting agents"

    # Create data directories
    mkdir -p /opt/cosmos-agent
    mkdir -p /opt/command-core-agent

    # Start cosmos-agent
    log_info "Starting cosmos-agent..."
    systemctl daemon-reload
    systemctl enable cosmos-agent
    systemctl start cosmos-agent

    # Start command-core-agent (may not be available yet - will retry in background)
    log_info "Starting command-core-agent..."
    systemctl enable command-core-agent
    # Allow failure - image may not be accessible yet, systemd will keep retrying
    systemctl start command-core-agent || log_warning "command-core-agent image not available - systemd will retry"

    log_success "cosmos-agent started successfully"
}

check_agent_status() {
    log_section "Agent Status"

    log_info "cosmos-agent status:"
    systemctl status cosmos-agent --no-pager | grep "Active:"

    log_info "command-core-agent status:"
    systemctl status command-core-agent --no-pager | grep "Active:"
}
