#!/bin/bash
# Enable Nomad-Vault Integration
# This script should be run ONCE after Vault is initialized

set -e

VAULT_ADDR="http://127.0.0.1:8200"

echo "=========================================="
echo "Nomad-Vault Integration Setup"
echo "=========================================="

# Get Vault root token
if [ -f /opt/vault/init-keys.json ]; then
    VAULT_TOKEN=$(sudo cat /opt/vault/init-keys.json | jq -r .root_token)
    export VAULT_TOKEN
    export VAULT_ADDR
else
    echo "ERROR: Vault init keys not found. Run this on a Vault server after initialization."
    exit 1
fi

echo "Step 1: Creating Nomad server policy in Vault..."
vault policy write nomad-server - <<'POLICY'
# Allow creating tokens under "nomad-cluster" token role
path "auth/token/create/nomad-cluster" {
  capabilities = ["update"]
}

# Allow looking up "nomad-cluster" token role
path "auth/token/roles/nomad-cluster" {
  capabilities = ["read"]
}

# Allow looking up the token passed to Nomad
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# Allow looking up incoming tokens
path "auth/token/lookup" {
  capabilities = ["update"]
}

# Allow revoking tokens
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}

# Allow checking capabilities
path "sys/capabilities-self" {
  capabilities = ["update"]
}

# Allow token renewal
path "auth/token/renew-self" {
  capabilities = ["update"]
}
POLICY

echo "Step 2: Creating nomad-cluster token role..."
vault write /auth/token/roles/nomad-cluster \
  disallowed_policies=nomad-server \
  explicit_max_ttl=0 \
  orphan=false \
  period=259200 \
  renewable=true

echo "Step 3: Creating Nomad server token..."
NOMAD_TOKEN=$(vault token create -policy nomad-server -period 72h -orphan -format=json | jq -r '.auth.client_token')

echo "Step 4: Storing token in Consul KV..."
consul kv put nomad/vault-token "$NOMAD_TOKEN"

echo ""
echo "=========================================="
echo "Vault Configuration Complete!"
echo "=========================================="
echo "Token stored in Consul KV: nomad/vault-token"
echo ""
echo "Next steps:"
echo "1. Add vault block to Nomad server configs"
echo "2. Add vault block to Nomad client configs"
echo "3. Restart Nomad servers and clients"
