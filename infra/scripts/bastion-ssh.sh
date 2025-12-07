#!/bin/bash
# Bastion SSH key generation and distribution

generate_bastion_ssh_key() {
    local cluster_name=$1

    log_section "Generating Bastion SSH Key Pair"

    # Generate SSH key pair for bastion (if not exists)
    if [ ! -f /home/ubuntu/.ssh/id_ed25519 ]; then
        log_info "Generating new ED25519 SSH key pair..."
        sudo -u ubuntu ssh-keygen -t ed25519 -f /home/ubuntu/.ssh/id_ed25519 -N "" -C "bastion@${cluster_name}"
        log_success "SSH key pair generated"
    else
        log_info "SSH key pair already exists"
    fi

    # Display public key
    log_info "Public key:"
    cat /home/ubuntu/.ssh/id_ed25519.pub
}

store_ssh_public_key_in_parameter_store() {
    local cluster_name=$1
    local region=$2

    log_section "Storing SSH Public Key in AWS Parameter Store"

    # Read the public key
    local public_key=$(cat /home/ubuntu/.ssh/id_ed25519.pub)

    # Store in Parameter Store
    aws ssm put-parameter \
        --region "$region" \
        --name "/${cluster_name}/bastion/ssh-public-key" \
        --value "$public_key" \
        --type "String" \
        --overwrite \
        2>&1

    log_success "SSH public key stored in Parameter Store"
}

fetch_and_install_bastion_public_key() {
    local cluster_name=$1
    local region=$2

    log_section "Fetching Bastion SSH Public Key from Parameter Store"

    # Wait for the key to be available (retry for up to 2 minutes)
    local max_attempts=24
    local attempt=0
    local public_key=""

    while [ $attempt -lt $max_attempts ]; do
        public_key=$(aws ssm get-parameter \
            --region "$region" \
            --name "/${cluster_name}/bastion/ssh-public-key" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null)

        if [ -n "$public_key" ] && [ "$public_key" != "None" ]; then
            break
        fi

        attempt=$((attempt + 1))
        log_info "Waiting for bastion public key to be available (attempt $attempt/$max_attempts)..."
        sleep 5
    done

    if [ -z "$public_key" ] || [ "$public_key" = "None" ]; then
        log_error "Failed to fetch bastion public key after $max_attempts attempts"
        return 1
    fi

    # Add to authorized_keys
    log_info "Installing bastion public key to ubuntu user's authorized_keys..."
    mkdir -p /home/ubuntu/.ssh
    echo "$public_key" >> /home/ubuntu/.ssh/authorized_keys
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    chmod 700 /home/ubuntu/.ssh
    chmod 600 /home/ubuntu/.ssh/authorized_keys

    log_success "Bastion public key installed successfully"
}

configure_ssh_client() {
    log_section "Configuring SSH Client"

    # Configure SSH for easier access
    cat > /home/ubuntu/.ssh/config <<'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF

    chown ubuntu:ubuntu /home/ubuntu/.ssh/config
    chmod 600 /home/ubuntu/.ssh/config

    log_success "SSH client configured"
}
