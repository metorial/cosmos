# Cosmos AWS Infrastructure

This Terraform configuration sets up a complete HashiCorp stack (Nomad, Consul, Vault) + Traefik infrastructure on AWS with high availability.

## Architecture Overview

- **Bastion Host**: Secure SSH access point with key management
- **Consul Cluster**: 3+ servers for service discovery and configuration
- **Vault Cluster**: 3+ servers for secrets management
- **Nomad Cluster**:
  - 3+ servers for job orchestration
  - Multiple clients in general pool (for regular workloads)
  - Multiple clients in management pool (for cosmos-controller and command-core-commander)
- **Traefik**: Runs as a system job on all Nomad clients for ingress
- **Agents**: cosmos-agent and command-core-agent run via Docker on ALL nodes

## Prerequisites

1. AWS Account with appropriate credentials configured
2. Terraform >= 1.0
3. SSH key pair (or let Terraform use your default `~/.ssh/id_rsa.pub`)
4. Scripts pushed to GitHub repository (https://github.com/metorial/cosmos)

## Quick Start

1. **Create a `terraform.tfvars` file:**

```hcl
cluster_name = "my-cosmos-cluster"
aws_region   = "us-east-1"
environment  = "prod"

# Optional: customize instance counts
consul_server_count = 3
vault_server_count  = 3
nomad_server_count  = 3
nomad_client_count  = 3
nomad_management_client_count = 2

# Optional: customize SSH access
allowed_cidr_blocks = ["YOUR_IP/32"]  # Replace with your IP

# Optional: provide SSH key
# ssh_public_key = "ssh-rsa AAAAB3..."
```

2. **Initialize Terraform:**

```bash
cd cosmos/infra/terraform/aws
terraform init
```

3. **Review the plan:**

```bash
terraform plan
```

4. **Apply the configuration:**

```bash
terraform apply
```

This will create:
- VPC with public and private subnets across 3 AZs
- Bastion host with public IP
- 3 Consul servers
- 3 Vault servers
- 3 Nomad servers
- 3+ Nomad clients (general pool)
- 2+ Nomad management clients

5. **Get the bastion IP:**

```bash
terraform output bastion_public_ip
```

6. **SSH into the bastion:**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@$(terraform output -raw bastion_public_ip)
```

## Post-Deployment Steps

### 1. Verify Consul Cluster

SSH into the bastion and check Consul status:

```bash
export CONSUL_HTTP_ADDR="http://$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Role,Values=consul-server" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text):8500"

consul members
consul operator raft list-peers
```

### 2. Initialize and Unseal Vault

SSH to one of the Vault servers from the bastion:

```bash
# Get Vault server IP
VAULT_IP=$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Role,Values=vault-server" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

ssh ubuntu@$VAULT_IP

# Initialize Vault (on ONE server only)
export VAULT_ADDR='http://127.0.0.1:8200'
vault operator init

# Save the unseal keys and root token securely!
# Then unseal on ALL Vault servers (requires 3 unseal keys)
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>
```

### 3. Verify Nomad Cluster

Check Nomad status:

```bash
export NOMAD_ADDR="http://$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Role,Values=nomad-server" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text):4646"

nomad server members
nomad node status
```

### 4. Deploy Traefik

From the bastion:

```bash
# Deploy Traefik system job
nomad job run /path/to/cosmos/infra/nomad/traefik.nomad

# Verify
nomad job status traefik
```

### 5. Deploy Cosmos Controller

```bash
nomad job run /path/to/cosmos/infra/nomad/cosmos-controller.nomad
nomad job status cosmos-controller
```

### 6. Deploy Command Core Commander

```bash
nomad job run /path/to/cosmos/infra/nomad/command-core-commander.nomad
nomad job status command-core-commander
```

## SSH Access Between Nodes

The bastion automatically generates an SSH key pair on startup and distributes the public key to all other nodes via AWS Parameter Store. This allows you to SSH from the bastion to any node in the cluster:

```bash
# From bastion
ssh ubuntu@<private-ip-of-any-node>
```

## Agents

Both `cosmos-agent` and `command-core-agent` are automatically installed and running on ALL nodes (servers and clients) via Docker systemd services. Check their status:

```bash
# On any node
systemctl status cosmos-agent
systemctl status command-core-agent

# View logs
journalctl -u cosmos-agent -f
journalctl -u command-core-agent -f
```

## High Availability Details

- **Consul**: 3 servers with auto-join via AWS tags
- **Vault**: 3 servers using Consul as storage backend
- **Nomad**: 3 servers with auto-join via AWS tags
- **NAT Gateways**: One per AZ for redundancy
- **Subnets**: Resources distributed across 3 availability zones

## Networking

- **VPC**: 10.0.0.0/16
- **Public Subnets**: 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24
- **Private Subnets**: 10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24
- **Bastion**: Public subnet with EIP
- **All servers/clients**: Private subnets with NAT gateway access

## Security

- All servers are in private subnets
- Only bastion is publicly accessible (SSH only)
- Security groups restrict traffic between components
- IMDSv2 required for instance metadata
- IAM roles follow principle of least privilege

## Customization

### Changing Instance Types

Edit `terraform.tfvars`:

```hcl
consul_instance_type = "t3.medium"
vault_instance_type = "t3.medium"
nomad_server_instance_type = "t3.medium"
nomad_client_instance_type = "t3.large"
```

### Changing Script URL

If you fork the repository or use a different branch:

```hcl
github_scripts_base_url = "https://raw.githubusercontent.com/YOUR_ORG/cosmos/YOUR_BRANCH/infra/scripts"
```

### Adding More Availability Zones

```hcl
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
```

## Troubleshooting

### Viewing Setup Logs

SSH to any node and check:

```bash
# Bastion
tail -f /var/log/bastion-setup.log

# Consul servers
tail -f /var/log/consul-server-setup.log

# Vault servers
tail -f /var/log/vault-server-setup.log

# Nomad servers
tail -f /var/log/nomad-server-setup.log

# Nomad clients
tail -f /var/log/nomad-client-setup.log
```

### Checking Service Status

```bash
systemctl status consul
systemctl status vault
systemctl status nomad
systemctl status cosmos-agent
systemctl status command-core-agent
```

### Consul Not Forming Cluster

Ensure security groups allow traffic on ports 8300, 8301 (TCP/UDP), 8500

### Vault Not Starting

Check if Consul is running: `systemctl status consul`

### Agents Not Starting

Check if Docker is running: `systemctl status docker`
Check agent logs: `journalctl -u cosmos-agent -f`

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Warning**: This will delete all resources including data in Consul/Vault!

## Cost Estimation

With default settings (3 servers of each type, 3 general clients, 2 management clients):
- Approximate monthly cost: $200-300 USD (depending on region and data transfer)
- Using t3.small instances: ~$15/month each
- NAT Gateways: ~$32/month each (3 total)

## Support

For issues or questions:
- Open an issue on https://github.com/metorial/cosmos
- Check documentation at https://github.com/metorial/cosmos/wiki
