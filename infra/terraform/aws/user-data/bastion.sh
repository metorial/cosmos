#!/bin/bash
set -e

# Variables from template
CLUSTER_NAME="${cluster_name}"
REGION="${region}"
SCRIPTS_URL="${github_scripts_base_url}"

# Setup logging
LOG_FILE="/var/log/bastion-setup.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "========================================="
echo "BASTION HOST SETUP STARTED"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "========================================="

# Download and source library functions
curl -fsSL "$SCRIPTS_URL/logging.sh" | bash -s -- source
source <(curl -fsSL "$SCRIPTS_URL/logging.sh")

curl -fsSL "$SCRIPTS_URL/system-setup.sh" -o /tmp/system-setup.sh
source /tmp/system-setup.sh

curl -fsSL "$SCRIPTS_URL/bastion-ssh.sh" -o /tmp/bastion-ssh.sh
source /tmp/bastion-ssh.sh

# Main Setup
log_section "BASTION HOST SETUP"

# Update system and install dependencies
setup_system_packages
install_base_dependencies
install_docker
install_ssm_agent

# Install HashiCorp CLI tools
ARCH=$(detect_architecture)
log_section "Installing HashiCorp CLI tools"

# Install Consul CLI
cd /tmp
wget "https://releases.hashicorp.com/consul/1.19.2/consul_1.19.2_linux_$${ARCH}.zip"
unzip -o "consul_1.19.2_linux_$${ARCH}.zip"
mv consul /usr/local/bin/
chmod +x /usr/local/bin/consul

# Install Nomad CLI
wget "https://releases.hashicorp.com/nomad/1.8.3/nomad_1.8.3_linux_$${ARCH}.zip"
unzip -o "nomad_1.8.3_linux_$${ARCH}.zip"
mv nomad /usr/local/bin/
chmod +x /usr/local/bin/nomad

# Install Vault CLI
wget "https://releases.hashicorp.com/vault/1.17.0/vault_1.17.0_linux_$${ARCH}.zip"
unzip -o "vault_1.17.0_linux_$${ARCH}.zip"
mv vault /usr/local/bin/
chmod +x /usr/local/bin/vault

log_success "HashiCorp CLI tools installed"

# Generate and distribute SSH keys
generate_bastion_ssh_key "$CLUSTER_NAME"
store_ssh_public_key_in_parameter_store "$CLUSTER_NAME" "$REGION"
configure_ssh_client

log_section "BASTION HOST SETUP COMPLETE"
log_info "Setup completed at: $(date)"
log_info "Full log available at: $LOG_FILE"
