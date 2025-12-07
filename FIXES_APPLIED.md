# Cosmos Infrastructure Fixes Applied

This document summarizes all the fixes applied to make cosmos work correctly on the cluster.

## Issues Fixed

### 1. Service Naming Mismatch ✅
**Problem**: Terraform configuration referenced incorrect service names for cosmos services in Consul DNS.
- Used `consul-service.service.consul` instead of `cosmos-controller.service.consul`
- Used `command-service.service.consul` instead of `sentinel-commander.service.consul`

**Fixed Files**:
- `infra/terraform/aws/consul.tf`
- `infra/terraform/aws/vault.tf`
- `infra/terraform/aws/nomad-servers.tf`
- `infra/terraform/aws/nomad-clients.tf`

**Solution**: Updated all terraform files to use correct service DNS names.

### 2. Cosmos-Agent NODE_ID Environment Variable ✅
**Problem**: The systemd service for cosmos-agent tried to evaluate `$(cat /etc/machine-id)` at runtime, which caused Docker to fail with "invalid reference format".

**Fixed Files**:
- `infra/scripts/agent-setup.sh`

**Solution**: Changed to read the machine ID during script execution and pass it as a static value to the Docker container.

```bash
# Before:
-e NODE_ID=$(cat /etc/machine-id)

# After:
local node_id=$(cat /etc/machine-id)
-e NODE_ID=$node_id
```

### 3. Missing Vault Configuration for Cosmos-Agent ✅
**Problem**: Cosmos-agent required VAULT_ADDR and VAULT_TOKEN environment variables but they weren't configured.

**Fixed Files**:
- `infra/scripts/agent-setup.sh`

**Solution**: Added VAULT_ADDR and VAULT_TOKEN to the cosmos-agent systemd service:
```bash
-e VAULT_ADDR=http://active.vault.service.consul:8200 \
-e VAULT_TOKEN=root \
```

### 4. Consul DNS Resolution ✅
**Problem**: Containers and services couldn't resolve .consul domains because systemd-resolved wasn't configured to forward those queries to Consul's DNS on port 8600.

**Fixed Files**:
- `infra/scripts/system-setup.sh` - Added `configure_consul_dns()` function
- `infra/terraform/aws/user-data/consul-server.sh`
- `infra/terraform/aws/user-data/vault-server.sh`
- `infra/terraform/aws/user-data/nomad-server.sh`
- `infra/terraform/aws/user-data/nomad-client.sh`

**Solution**: Added systemd-resolved configuration to forward .consul domain queries to local Consul agent:

```bash
configure_consul_dns() {
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/consul.conf <<EOF
[Resolve]
DNS=127.0.0.1:8600
Domains=~consul
EOF
    systemctl restart systemd-resolved
}
```

### 5. Cosmos-Controller Nomad Job Configuration ✅
**Problem**: The cosmos-controller job couldn't resolve postgres and vault services via DNS.

**Fixed Files**:
- `infra/nomad/cosmos-controller.nomad`

**Solution**:
1. Added DNS configuration to Docker config:
```hcl
config {
  image = "ghcr.io/metorial/cosmos-controller:latest"
  ports = ["grpc", "http"]
  dns_servers = ["127.0.0.1"]
  dns_search_domains = ["service.consul"]
}
```

2. Added Nomad templates to dynamically resolve service addresses from Consul:
```hcl
template {
  data = <<EOH
{{- range service "postgres-cosmos" }}
COSMOS_DB_URL="postgres://cosmos:cosmos_production@{{ .Address }}:{{ .Port }}/cosmos?sslmode=disable"
{{- end }}
{{- range service "vault" "passing,warning" }}
{{ if .Tags | contains "active" }}
VAULT_ADDR="http://{{ .Address }}:{{ .Port }}"
{{ end }}
{{- end }}
EOH
  destination = "local/services.env"
  env = true
}
```

### 6. Vault PKI Initialization ✅
**Problem**: Vault PKI backend wasn't configured to issue certificates for cosmos components.

**Fixed Files**:
- `infra/scripts/vault-init.sh`

**Solution**: Added automatic PKI configuration to vault-init.sh that runs after Vault is initialized:
- Enables `cosmos-pki` secrets engine
- Generates internal root CA
- Configures CA and CRL URLs
- Creates roles for controller and agent certificates

## Files Modified Summary

### Terraform Configuration
- `infra/terraform/aws/consul.tf` - Fixed service names
- `infra/terraform/aws/vault.tf` - Fixed service names
- `infra/terraform/aws/nomad-servers.tf` - Fixed service names
- `infra/terraform/aws/nomad-clients.tf` - Fixed service names

### Setup Scripts
- `infra/scripts/agent-setup.sh` - Fixed NODE_ID, added VAULT_ADDR/VAULT_TOKEN
- `infra/scripts/system-setup.sh` - Added DNS configuration function
- `infra/scripts/vault-init.sh` - Added PKI configuration

### User Data Scripts
- `infra/terraform/aws/user-data/consul-server.sh` - Added DNS configuration call
- `infra/terraform/aws/user-data/vault-server.sh` - Added DNS configuration call
- `infra/terraform/aws/user-data/nomad-server.sh` - Added DNS configuration call
- `infra/terraform/aws/user-data/nomad-client.sh` - Added DNS configuration call

### Nomad Job Files
- `infra/nomad/cosmos-controller.nomad` - Added DNS config and Consul templates

## Testing the Fixed Deployment

After applying the fixes:

1. All agents should start successfully:
```bash
systemctl status cosmos-agent
systemctl status sentinel-agent
```

2. Cosmos controller should connect to database and vault:
```bash
nomad job status cosmos-controller
nomad alloc logs -job cosmos-controller
```

3. Services should be registered in Consul:
```bash
consul catalog services
dig @127.0.0.1 -p 8600 cosmos-controller.service.consul
dig @127.0.0.1 -p 8600 postgres-cosmos.service.consul
```

4. Vault PKI should be available:
```bash
vault secrets list  # Should show cosmos-pki
vault list cosmos-pki/roles  # Should show controller and agent roles
```

## Future Deployments

All fixes are now integrated into the setup scripts, so future deployments using `terraform apply` will automatically have these fixes applied. No manual intervention should be required.

The setup scripts now handle:
- Correct service naming
- Proper environment variable configuration
- DNS resolution for Consul services
- Vault PKI initialization for mTLS certificates
