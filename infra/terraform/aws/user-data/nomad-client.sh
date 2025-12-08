#!/bin/bash
set -e

# Variables from template
CLUSTER_NAME="${cluster_name}"
REGION="${region}"
NODE_POOL="${node_pool}"
NODE_CLASS="${node_class}"
SCRIPTS_URL="${github_scripts_base_url}"
CONTROLLER_ADDR="${controller_addr}"
COMMANDER_ADDR="${commander_addr}"

# Setup logging
LOG_FILE="/var/log/nomad-client-setup.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "========================================="
echo "NOMAD CLIENT SETUP STARTED"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Node Pool: $NODE_POOL"
echo "Node Class: $NODE_CLASS"
echo "========================================="

# Download and source library functions
source <(curl -fsSL "$SCRIPTS_URL/logging.sh")
curl -fsSL "$SCRIPTS_URL/system-setup.sh" -o /tmp/system-setup.sh
source /tmp/system-setup.sh
curl -fsSL "$SCRIPTS_URL/consul-setup.sh" -o /tmp/consul-setup.sh
source /tmp/consul-setup.sh
curl -fsSL "$SCRIPTS_URL/nomad-setup.sh" -o /tmp/nomad-setup.sh
source /tmp/nomad-setup.sh
curl -fsSL "$SCRIPTS_URL/bastion-ssh.sh" -o /tmp/bastion-ssh.sh
source /tmp/bastion-ssh.sh
curl -fsSL "$SCRIPTS_URL/agent-setup.sh" -o /tmp/agent-setup.sh
source /tmp/agent-setup.sh

# Main Setup
log_section "NOMAD CLIENT SETUP"

# Update system and install dependencies
setup_system_packages
install_base_dependencies
install_docker
install_ssm_agent

# Get instance info
ARCH=$(detect_architecture)
PRIVATE_IP=$(get_private_ip)
INSTANCE_ID=$(get_instance_id)

log_info "Architecture: $ARCH"
log_info "Private IP: $PRIVATE_IP"
log_info "Instance ID: $INSTANCE_ID"

# Install and configure Consul client
install_consul "$ARCH"
configure_consul_client "$REGION" "$PRIVATE_IP" "$CLUSTER_NAME"
create_consul_systemd_service
start_consul

# Configure DNS for Consul
configure_consul_dns

# Install and configure Nomad client
install_nomad "$ARCH"
install_cni_plugins "$ARCH"
configure_nomad_client "$REGION" "$INSTANCE_ID" "$NODE_POOL" "$NODE_CLASS" "$CLUSTER_NAME" "$PRIVATE_IP"
create_nomad_systemd_service "client"
start_nomad

# Install bastion SSH key
fetch_and_install_bastion_public_key "$CLUSTER_NAME" "$REGION"

# Install agents
install_cosmos_agent "$CONTROLLER_ADDR" "$CLUSTER_NAME"
install_sentinel_agent "$COMMANDER_ADDR" "$CLUSTER_NAME"
start_agents

# Deploy cosmos jobs (management nodes only)
if [ "$NODE_POOL" = "management" ]; then
  log_section "Setting up Cosmos Jobs Auto-Deployment"

  # Download cosmos jobs deployment script
  curl -fsSL "$SCRIPTS_URL/cosmos-jobs-deploy.sh" -o /usr/local/bin/cosmos-jobs-deploy.sh
  chmod +x /usr/local/bin/cosmos-jobs-deploy.sh

  # Replace placeholders
  sed -i "s/CLUSTER_NAME_PLACEHOLDER/$CLUSTER_NAME/g" /usr/local/bin/cosmos-jobs-deploy.sh
  sed -i "s/REGION_PLACEHOLDER/$REGION/g" /usr/local/bin/cosmos-jobs-deploy.sh

  # Create systemd service for cosmos jobs deployment
  cat > /etc/systemd/system/cosmos-jobs-deploy.service <<EOF
[Unit]
Description=Cosmos Nomad Jobs Auto-Deployment
After=nomad.service consul.service
Requires=nomad.service consul.service
ConditionPathExists=/usr/local/bin/cosmos-jobs-deploy.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cosmos-jobs-deploy.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

Environment="NOMAD_ADDR=http://127.0.0.1:4646"
Environment="CLUSTER_NAME=$CLUSTER_NAME"
Environment="REGION=$REGION"

[Install]
WantedBy=multi-user.target
EOF

  # Enable and start the service in background
  systemctl daemon-reload
  systemctl enable cosmos-jobs-deploy.service
  systemctl start cosmos-jobs-deploy.service &

  log_success "Cosmos jobs auto-deployment configured"
fi

log_section "NOMAD CLIENT SETUP COMPLETE"
log_info "Nomad client is running and ready"
log_info "Setup completed at: $(date)"
