#!/bin/bash
# Nomad installation and setup functions

NOMAD_VERSION="1.8.3"
CNI_VERSION="1.3.0"

install_nomad() {
    local arch=$1  # "arm64" or "amd64"

    log_section "Installing Nomad ($arch)"

    cd /tmp
    wget "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_${arch}.zip"
    unzip -o "nomad_${NOMAD_VERSION}_linux_${arch}.zip"
    mv nomad /usr/local/bin/
    chmod +x /usr/local/bin/nomad

    # Verify installation
    nomad version

    # Create nomad user
    useradd --system --home /etc/nomad.d --shell /bin/false nomad 2>/dev/null || true

    # Create directories
    mkdir -p /opt/nomad/data
    mkdir -p /etc/nomad.d
    chown -R nomad:nomad /opt/nomad
    chown -R nomad:nomad /etc/nomad.d

    log_success "Nomad installed successfully"
}

install_cni_plugins() {
    local arch=$1  # "arm64" or "amd64"

    log_info "Installing CNI plugins for networking..."

    mkdir -p /opt/cni/bin
    cd /tmp
    wget "https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-${arch}-v${CNI_VERSION}.tgz"
    tar -C /opt/cni/bin -xzf "cni-plugins-linux-${arch}-v${CNI_VERSION}.tgz"

    log_success "CNI plugins installed"
}

configure_nomad_server() {
    local region=$1
    local server_count=$2
    local private_ip=$3

    log_info "Configuring Nomad server..."

    cat > /etc/nomad.d/nomad.hcl <<EOF
datacenter = "$region"
data_dir = "/opt/nomad/data"
bind_addr = "$private_ip"

addresses {
  http = "0.0.0.0"
  rpc  = "$private_ip"
  serf = "$private_ip"
}

advertise {
  http = "$private_ip"
  rpc  = "$private_ip"
  serf = "$private_ip"
}

server {
  enabled = true
  bootstrap_expect = $server_count

  server_join {
    retry_join = ["provider=aws tag_key=Role tag_value=nomad-server region=$region"]
  }
}

consul {
  address = "127.0.0.1:8500"
  auto_advertise = true
  server_auto_join = true
  client_auto_join = true
}

log_level = "INFO"
EOF

    chown nomad:nomad /etc/nomad.d/nomad.hcl
    log_success "Nomad server configured"
}

configure_nomad_client() {
    local region=$1
    local instance_name=$2
    local node_pool=$3
    local node_class=$4
    local cluster_name=$5
    local private_ip=$6

    log_info "Configuring Nomad client..."

    cat > /etc/nomad.d/nomad.hcl <<EOF
datacenter = "$region"
data_dir = "/opt/nomad/data"
bind_addr = "$private_ip"
name = "$instance_name"

client {
  enabled = true
  node_pool = "$node_pool"
  node_class = "$node_class"

  server_join {
    retry_join = ["provider=aws tag_key=Role tag_value=nomad-server region=$region"]
  }

  host_volume "docker-sock" {
    path = "/var/run/docker.sock"
    read_only = false
  }

  meta {
    cluster = "$cluster_name"
    node_pool = "$node_pool"
    node_class = "$node_class"
  }
}

consul {
  address = "127.0.0.1:8500"
  auto_advertise = true
  client_auto_join = true
}

plugin "docker" {
  config {
    allow_privileged = false
    volumes {
      enabled = true
    }
  }
}

log_level = "INFO"
EOF

    chown nomad:nomad /etc/nomad.d/nomad.hcl
    log_success "Nomad client configured"
}

create_nomad_systemd_service() {
    local mode=$1  # "server" or "client"

    log_info "Creating Nomad systemd service..."

    local user="nomad"
    local group="nomad"
    local wants_line="Wants=consul.service"

    # Clients need root to manage containers
    if [ "$mode" = "client" ]; then
        user="root"
        group="root"
        wants_line="Wants=consul.service docker.service"
    fi

    cat > /etc/systemd/system/nomad.service <<EOF
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/
Requires=network-online.target
After=network-online.target
$wants_line
After=consul.service

[Service]
Type=notify
User=$user
Group=$group
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d/nomad.hcl
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
LimitNOFILE=65536
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF

    log_success "Nomad systemd service created"
}

start_nomad() {
    log_info "Starting Nomad..."

    systemctl daemon-reload
    systemctl enable nomad
    systemctl start nomad

    log_success "Nomad started successfully"
}
