#!/bin/bash
# Agent installation and setup functions (cosmos-agent, command-core-agent)

install_cosmos_agent() {
    local controller_addr=$1
    local cluster_name=$2

    log_section "Installing cosmos-agent"

    # Get the node ID
    local node_id=$(cat /etc/machine-id)

    # Create systemd service for cosmos-agent
    cat > /etc/systemd/system/cosmos-agent.service <<EOF
[Unit]
Description=Cosmos Agent
Documentation=https://github.com/metorial/cosmos
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=0

ExecStartPre=-/usr/bin/docker stop cosmos-agent
ExecStartPre=-/usr/bin/docker rm cosmos-agent
ExecStartPre=/usr/bin/docker pull ghcr.io/metorial/cosmos-agent:latest

ExecStart=/usr/bin/docker run --rm --name cosmos-agent \\
  --network host \\
  -v /var/run/docker.sock:/var/run/docker.sock \\
  -v /opt/cosmos-agent:/data \\
  -e CONTROLLER_ADDR=$controller_addr \\
  -e CLUSTER_NAME=$cluster_name \\
  -e NODE_ID=$node_id \\
  -e VAULT_ADDR=http://active.vault.service.consul:8200 \\
  -e VAULT_TOKEN=root \\
  ghcr.io/metorial/cosmos-agent:latest

ExecStop=/usr/bin/docker stop cosmos-agent

StandardOutput=journal
StandardError=journal
SyslogIdentifier=cosmos-agent

[Install]
WantedBy=multi-user.target
EOF

    log_success "cosmos-agent service created"
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

    # Start command-core-agent
    log_info "Starting command-core-agent..."
    systemctl enable command-core-agent
    systemctl start command-core-agent

    log_success "Agents started successfully"
}

check_agent_status() {
    log_section "Agent Status"

    log_info "cosmos-agent status:"
    systemctl status cosmos-agent --no-pager | grep "Active:"

    log_info "command-core-agent status:"
    systemctl status command-core-agent --no-pager | grep "Active:"
}
