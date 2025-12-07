#!/bin/bash
# Script to fix cosmos and command-core agents on all nodes

BASTION="ubuntu@3.149.126.26"
CLUSTER_NAME="mtcosm-0001"

# List of all nodes (consul servers, vault servers, nomad servers, nomad clients)
NODES=(
  "10.0.10.90"   # consul-server-1
  "10.0.11.218"  # consul-server-2
  "10.0.12.12"   # consul-server-3
  "10.0.10.179"  # vault-server-1
  "10.0.11.80"   # vault-server-2
  "10.0.12.19"   # vault-server-3
  "10.0.10.238"  # nomad-server-1
  "10.0.11.88"   # nomad-server-2
  "10.0.12.49"   # nomad-server-3
  "10.0.10.188"  # nomad-client-1
  "10.0.11.224"  # nomad-client-2
  "10.0.12.214"  # nomad-client-3
  "10.0.10.216"  # nomad-management-client-1
  "10.0.11.85"   # nomad-management-client-2
)

echo "Fixing cosmos and command-core agents on all nodes..."

for NODE in "${NODES[@]}"; do
  echo "================================"
  echo "Processing node: $NODE"
  echo "================================"

  # Fix cosmos-agent service
  ssh -o StrictHostKeyChecking=no -J "$BASTION" "ubuntu@$NODE" << 'ENDSSH'
    # Get the node ID
    NODE_ID=$(cat /etc/machine-id)

    # Update cosmos-agent service
    sudo tee /etc/systemd/system/cosmos-agent.service > /dev/null <<EOF
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

ExecStart=/usr/bin/docker run --rm --name cosmos-agent \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /opt/cosmos-agent:/data \
  -e CONTROLLER_ADDR=cosmos-controller.service.consul:50051 \
  -e CLUSTER_NAME=mtcosm-0001 \
  -e NODE_ID=$NODE_ID \
  ghcr.io/metorial/cosmos-agent:latest

ExecStop=/usr/bin/docker stop cosmos-agent

StandardOutput=journal
StandardError=journal
SyslogIdentifier=cosmos-agent

[Install]
WantedBy=multi-user.target
EOF

    # Update command-core-agent service
    sudo tee /etc/systemd/system/command-core-agent.service > /dev/null <<EOF
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

ExecStart=/usr/bin/docker run --rm --name command-core-agent \
  --network host \
  -v /opt/command-core-agent:/data \
  -e COMMANDER_ADDR=command-core-commander.service.consul:50052 \
  -e CLUSTER_NAME=mtcosm-0001 \
  -e NODE_ID=$NODE_ID \
  ghcr.io/metorial/command-core-agent:latest

ExecStop=/usr/bin/docker stop command-core-agent

StandardOutput=journal
StandardError=journal
SyslogIdentifier=command-core-agent

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and restart services
    sudo systemctl daemon-reload
    sudo systemctl restart cosmos-agent
    sudo systemctl restart command-core-agent

    echo "Node fixed and services restarted"
ENDSSH

  echo "Node $NODE completed"
  echo ""
done

echo "All nodes have been updated!"
