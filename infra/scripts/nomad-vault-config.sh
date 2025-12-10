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
