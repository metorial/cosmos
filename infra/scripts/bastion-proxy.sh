#!/bin/bash
# Bastion proxy setup for forwarding internal services

setup_consul_client() {
    local cluster_name=$1
    local region=$2

    log_section "Setting up Consul client on bastion"

    # Check if Consul is already running
    if systemctl is-active --quiet consul; then
        log_info "Consul agent is already running"
        return 0
    fi

    # Get Consul server IPs from AWS
    log_info "Discovering Consul servers in cluster..."
    local consul_servers=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=tag:Role,Values=consul-server" \
                  "Name=tag:Cluster,Values=$cluster_name" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].PrivateIpAddress' \
        --output text | tr '\t' '\n')

    if [ -z "$consul_servers" ]; then
        log_error "No Consul servers found in cluster $cluster_name"
        return 1
    fi

    log_info "Found Consul servers: $(echo $consul_servers | tr '\n' ' ')"

    # Create Consul config directory
    mkdir -p /etc/consul.d
    mkdir -p /opt/consul/data

    # Build retry_join array
    local retry_join=""
    for server in $consul_servers; do
        if [ -z "$retry_join" ]; then
            retry_join="\"$server\""
        else
            retry_join="$retry_join, \"$server\""
        fi
    done

    # Create Consul client configuration
    log_info "Creating Consul client configuration..."
    cat > /etc/consul.d/client.hcl <<EOF
datacenter = "$cluster_name"
data_dir = "/opt/consul/data"
client_addr = "0.0.0.0"
bind_addr = "{{ GetPrivateIP }}"
retry_join = [$retry_join]

# Enable DNS on port 8600
ports {
  dns = 8600
  http = 8500
}

# Enable recursors for external DNS
recursors = ["169.254.169.253"]

# DNS config
dns_config {
  allow_stale = true
  max_stale = "1s"
  node_ttl = "10s"
  service_ttl = {
    "*" = "10s"
  }
}

# Enable local service registration
enable_local_script_checks = false
EOF

    # Create systemd service for Consul
    log_info "Creating Consul systemd service..."
    cat > /etc/systemd/system/consul.service <<EOF
[Unit]
Description=Consul Agent
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # Start Consul
    log_info "Starting Consul agent..."
    systemctl daemon-reload
    systemctl enable consul
    systemctl start consul

    # Wait for Consul to be ready
    log_info "Waiting for Consul to be ready..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if consul members &>/dev/null; then
            log_success "Consul agent started successfully"
            return 0
        fi
        attempt=$((attempt + 1))
        log_info "Waiting for Consul... (attempt $attempt/$max_attempts)"
        sleep 2
    done

    log_error "Consul failed to start after $max_attempts attempts"
    return 1
}

deploy_bastion_proxy() {
    log_section "Deploying Bastion Proxy"

    # Create proxy directory
    local proxy_dir="/opt/bastion-proxy"
    mkdir -p "$proxy_dir"

    # Create Caddyfile
    log_info "Creating Caddyfile..."
    cat > "$proxy_dir/Caddyfile" <<'EOF'
{
    layer4 {
        # Consul UI and API (8500)
        :8500 {
            route {
                proxy consul.service.consul:8500
            }
        }

        # Vault API (8200)
        :8200 {
            route {
                proxy vault.service.consul:8200
            }
        }

        # Nomad UI and API (4646)
        :4646 {
            route {
                proxy nomad.service.consul:4646
            }
        }

        # Traefik UI (8081)
        :8081 {
            route {
                proxy traefik.service.consul:8081
            }
        }

        # Sentinel Controller (5020)
        :5020 {
            route {
                proxy sentinel-controller.service.consul:5020
            }
        }

        # Cosmos Controller (5010)
        :5010 {
            route {
                proxy cosmos-controller.service.consul:5010
            }
        }
    }
}

# Health check endpoint
:8080 {
    respond /health 200 {
        body "healthy"
    }
}
EOF

    # Create Dockerfile
    log_info "Creating Dockerfile..."
    cat > "$proxy_dir/Dockerfile" <<'EOF'
# Build Caddy with layer4 plugin
FROM caddy:builder AS builder

RUN xcaddy build \
    --with github.com/mholt/caddy-l4

# Final image
FROM debian:bookworm-slim

# Install ca-certificates for HTTPS
RUN apt-get update && \
    apt-get install -y ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy the custom-built Caddy
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Copy Caddyfile
COPY Caddyfile /etc/caddy/Caddyfile

# Create caddy user
RUN groupadd -r caddy && \
    useradd -r -g caddy -s /sbin/nologin caddy && \
    mkdir -p /var/lib/caddy && \
    chown -R caddy:caddy /var/lib/caddy

# Expose all the ports we're proxying
EXPOSE 4646 5010 5020 8080 8081 8200 8500

# Run as caddy user
USER caddy

# Run Caddy
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
EOF

    # Create docker-compose.yml
    log_info "Creating docker-compose.yml..."
    cat > "$proxy_dir/docker-compose.yml" <<'EOF'
version: '3.8'

services:
  proxy:
    build: .
    image: bastion-proxy:latest
    container_name: bastion-proxy
    network_mode: host
    restart: unless-stopped
    dns:
      - 127.0.0.1
    dns_search:
      - service.consul
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    # Build and start the proxy
    log_info "Building proxy container..."
    cd "$proxy_dir"
    docker compose build

    log_info "Starting proxy container..."
    docker compose up -d

    # Wait for container to start
    sleep 3

    # Check if container is running
    if docker compose ps | grep -q "Up"; then
        log_success "Bastion proxy deployed successfully"
        log_info "Proxy is forwarding the following ports:"
        log_info "  - 8500: Consul UI/API"
        log_info "  - 8200: Vault API"
        log_info "  - 4646: Nomad UI/API"
        log_info "  - 8081: Traefik UI"
        log_info "  - 5020: Sentinel Controller"
        log_info "  - 5010: Cosmos Controller"
        log_info "  - 8080: Health check endpoint"
        return 0
    else
        log_error "Proxy container failed to start"
        docker compose logs
        return 1
    fi
}

setup_bastion_proxy() {
    local cluster_name=$1
    local region=$2

    log_section "BASTION PROXY SETUP"

    # Set up Consul client
    setup_consul_client "$cluster_name" "$region" || {
        log_error "Failed to set up Consul client"
        return 1
    }

    # Configure Consul DNS
    configure_consul_dns

    # Wait a bit for Consul to fully sync
    log_info "Waiting for Consul services to sync..."
    sleep 10

    # Test DNS resolution
    log_info "Testing Consul DNS resolution..."
    if host consul.service.consul 127.0.0.1 &>/dev/null; then
        log_success "Consul DNS resolution is working"
    else
        log_warn "Consul DNS resolution test failed, but continuing..."
    fi

    # Deploy the proxy
    deploy_bastion_proxy || {
        log_error "Failed to deploy bastion proxy"
        return 1
    }

    log_section "BASTION PROXY SETUP COMPLETE"
}
