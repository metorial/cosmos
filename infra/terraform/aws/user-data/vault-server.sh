#!/bin/bash
set -e

# Variables from template
CLUSTER_NAME="${cluster_name}"
REGION="${region}"
SCRIPTS_URL="${github_scripts_base_url}"
CONTROLLER_ADDR="${controller_addr}"
COMMANDER_ADDR="${commander_addr}"

# Setup logging
LOG_FILE="/var/log/vault-server-setup.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "========================================="
echo "VAULT SERVER SETUP STARTED"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "========================================="

# Download and source library functions
source <(curl -fsSL "$SCRIPTS_URL/logging.sh")
curl -fsSL "$SCRIPTS_URL/system-setup.sh" -o /tmp/system-setup.sh
source /tmp/system-setup.sh
curl -fsSL "$SCRIPTS_URL/consul-setup.sh" -o /tmp/consul-setup.sh
source /tmp/consul-setup.sh
curl -fsSL "$SCRIPTS_URL/vault-setup.sh" -o /tmp/vault-setup.sh
source /tmp/vault-setup.sh
curl -fsSL "$SCRIPTS_URL/bastion-ssh.sh" -o /tmp/bastion-ssh.sh
source /tmp/bastion-ssh.sh
curl -fsSL "$SCRIPTS_URL/agent-setup.sh" -o /tmp/agent-setup.sh
source /tmp/agent-setup.sh

# Main Setup
log_section "VAULT SERVER SETUP"

# Update system and install dependencies
setup_system_packages
install_base_dependencies
install_docker

# Get instance info
ARCH=$(detect_architecture)
PRIVATE_IP=$(get_private_ip)

log_info "Architecture: $ARCH"
log_info "Private IP: $PRIVATE_IP"

# Install and configure Consul client
install_consul "$ARCH"
configure_consul_client "$REGION" "$PRIVATE_IP" "$CLUSTER_NAME"
create_consul_systemd_service
start_consul

# Install and configure Vault
install_vault "$ARCH"
configure_vault_server "$REGION" "$PRIVATE_IP" "$CLUSTER_NAME"
create_vault_systemd_service
start_vault

# Install bastion SSH key
fetch_and_install_bastion_public_key "$CLUSTER_NAME" "$REGION"

# Install agents
install_cosmos_agent "$CONTROLLER_ADDR" "$CLUSTER_NAME"
install_command_core_agent "$COMMANDER_ADDR" "$CLUSTER_NAME"
start_agents

log_section "VAULT SERVER SETUP COMPLETE"
log_info "Vault server is running and ready"
log_info "Setup completed at: $(date)"
