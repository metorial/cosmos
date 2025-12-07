#!/bin/bash
# System setup and base dependencies

setup_system_packages() {
    log_section "Updating system packages"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get upgrade -y

    log_success "System packages updated"
}

install_base_dependencies() {
    log_section "Installing base dependencies"

    apt-get install -y \
        curl \
        wget \
        unzip \
        jq \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common

    log_success "Base dependencies installed"
}

install_docker() {
    log_section "Installing Docker"

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start and enable Docker
    systemctl start docker
    systemctl enable docker

    # Verify Docker installation
    docker version

    log_success "Docker installed successfully"
}

detect_architecture() {
    local arch="$(uname -m)"

    if [ "$arch" = "x86_64" ]; then
        echo "amd64"
    elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        echo "arm64"
    else
        log_error "Unsupported architecture: $arch"
        exit 1
    fi
}

get_private_ip() {
    # Try to get private IP from instance metadata (AWS)
    local private_ip=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)

    if [ -z "$private_ip" ]; then
        # Fallback to hostname -I
        private_ip=$(hostname -I | awk '{print $1}')
    fi

    echo "$private_ip"
}

get_instance_id() {
    # Get instance ID from metadata (AWS)
    curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown"
}
