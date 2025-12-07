#!/bin/bash
# Script to configure systemd-resolved to use Consul DNS for .consul domains

BASTION="ubuntu@3.149.126.26"

# List of all nodes
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

echo "Configuring systemd-resolved to use Consul DNS for .consul domains..."

for NODE in "${NODES[@]}"; do
  echo "================================"
  echo "Processing node: $NODE"
  echo "================================"

  ssh -o StrictHostKeyChecking=no -J "$BASTION" "ubuntu@$NODE" << 'ENDSSH'
    # Create systemd-resolved drop-in directory
    sudo mkdir -p /etc/systemd/resolved.conf.d

    # Configure systemd-resolved to use Consul DNS for .consul domain
    sudo tee /etc/systemd/resolved.conf.d/consul.conf > /dev/null <<EOF
[Resolve]
DNS=127.0.0.1:8600
Domains=~consul
EOF

    # Restart systemd-resolved
    sudo systemctl restart systemd-resolved

    # Test resolution
    echo "Testing DNS resolution:"
    dig +short postgres-cosmos.service.consul

    echo "Node configured successfully"
ENDSSH

  echo "Node $NODE completed"
  echo ""
done

echo "All nodes have been configured for Consul DNS!"
