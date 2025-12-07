#!/bin/bash
# Script to redirect DNS port 53 to Consul DNS port 8600 on management nodes

BASTION="ubuntu@3.149.126.26"

# List of management nodes (where cosmos-controller runs)
NODES=(
  "10.0.10.216"  # nomad-management-client-1
  "10.0.11.85"   # nomad-management-client-2
)

echo "Setting up DNS port redirection to Consul on management nodes..."

for NODE in "${NODES[@]}"; do
  echo "================================"
  echo "Processing node: $NODE"
  echo "================================"

  ssh -o StrictHostKeyChecking=no -J "$BASTION" "ubuntu@$NODE" << 'ENDSSH'
    # Add iptables rules to redirect port 53 to 8600 for Consul DNS
    sudo iptables -t nat -A OUTPUT -d localhost -p udp -m udp --dport 53 -j REDIRECT --to-ports 8600
    sudo iptables -t nat -A OUTPUT -d localhost -p tcp -m tcp --dport 53 -j REDIRECT --to-ports 8600

    # Make iptables rules persistent
    sudo apt-get install -y iptables-persistent
    sudo netfilter-persistent save

    echo "DNS port redirection configured successfully"
ENDSSH

  echo "Node $NODE completed"
  echo ""
done

echo "All management nodes have been configured!"
