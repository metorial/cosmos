#!/bin/bash
# Script to configure Vault PKI for Cosmos certificates

set -e

export VAULT_ADDR="http://127.0.0.1:8200"

echo "=================================="
echo "Vault PKI Setup for Cosmos"
echo "=================================="

# Get root token from local file or use 'root' for dev
if [ -f /opt/vault/init-keys.json ]; then
    echo "Reading root token from init keys..."
    export VAULT_TOKEN=$(jq -r '.root_token' /opt/vault/init-keys.json)
else
    echo "Using default 'root' token..."
    export VAULT_TOKEN="root"
fi

echo "Checking Vault status..."
vault status

echo ""
echo "Step 1: Enable PKI secrets engine..."
vault secrets enable -path=cosmos-pki pki || echo "PKI already enabled or error"

echo ""
echo "Step 2: Configure max lease TTL..."
vault secrets tune -max-lease-ttl=87600h cosmos-pki

echo ""
echo "Step 3: Generate root CA..."
vault write -field=certificate cosmos-pki/root/generate/internal \
    common_name="Cosmos Internal CA" \
    issuer_name="cosmos-root" \
    ttl=87600h > /tmp/cosmos-ca.crt

echo "Root CA certificate saved to /tmp/cosmos-ca.crt"

echo ""
echo "Step 4: Configure CA and CRL URLs..."
vault write cosmos-pki/config/urls \
    issuing_certificates="http://active.vault.service.consul:8200/v1/cosmos-pki/ca" \
    crl_distribution_points="http://active.vault.service.consul:8200/v1/cosmos-pki/crl"

echo ""
echo "Step 5: Create role for controller certificates..."
vault write cosmos-pki/roles/controller \
    allowed_domains="controller,cosmos-controller,service.consul" \
    allow_subdomains=true \
    allow_bare_domains=true \
    allow_localhost=true \
    allow_ip_sans=true \
    max_ttl="8760h" \
    ttl="8760h" \
    key_bits=2048 \
    key_type=rsa

echo ""
echo "Step 6: Create role for agent certificates..."
vault write cosmos-pki/roles/agent \
    allowed_domains="agent,cosmos-agent" \
    allow_subdomains=true \
    allow_bare_domains=true \
    allow_localhost=true \
    allow_ip_sans=true \
    max_ttl="720h" \
    ttl="72h" \
    key_bits=2048 \
    key_type=rsa

echo ""
echo "Step 7: Test certificate issuance..."
vault write cosmos-pki/issue/controller \
    common_name="test-controller" \
    ttl="24h" > /tmp/test-cert.json

if [ $? -eq 0 ]; then
    echo "✓ Test certificate issued successfully!"
    echo "Certificate details:"
    jq -r '.data.certificate' /tmp/test-cert.json | openssl x509 -noout -subject -dates
else
    echo "✗ Failed to issue test certificate"
    exit 1
fi

echo ""
echo "=================================="
echo "Vault PKI Setup Complete!"
echo "=================================="
echo ""
echo "PKI Roles created:"
echo "  - controller: For cosmos-controller certificates"
echo "  - agent: For cosmos-agent certificates"
echo ""
echo "To issue a certificate:"
echo "  vault write cosmos-pki/issue/controller common_name=cosmos-controller ttl=8760h"
echo "  vault write cosmos-pki/issue/agent common_name=cosmos-agent ttl=72h"
