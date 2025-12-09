#!/bin/bash
# Cosmos Nomad Jobs Auto-Deployment
# This script automatically deploys cosmos-controller and postgres-cosmos
# after Vault initialization completes and tokens are available

# Get environment from systemd or use defaults
CLUSTER_NAME="${CLUSTER_NAME:-CLUSTER_NAME_PLACEHOLDER}"
REGION="${REGION:-REGION_PLACEHOLDER}"

# Logging
exec >> /var/log/cosmos-jobs-deploy.log 2>&1

echo "==================================="
echo "Cosmos Jobs Deployment: $(date)"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "==================================="

# Wait for Nomad to be ready
echo "Waiting for Nomad cluster to be ready..."
# Use Consul DNS to find Nomad servers
export NOMAD_ADDR="http://nomad.service.consul:4646"
MAX_WAIT=120
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  if nomad status >/dev/null 2>&1; then
    echo "Nomad cluster is ready"
    break
  fi
  echo "Waiting for Nomad cluster... ($WAIT_COUNT/$MAX_WAIT)"
  sleep 5
  WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
  echo "ERROR: Nomad cluster did not become ready in time"
  exit 1
fi

# Wait for Vault tokens to be available in Consul KV
echo "Waiting for Vault tokens in Consul KV..."
MAX_WAIT=120
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  CONTROLLER_TOKEN=$(consul kv get cosmos/controller-token 2>/dev/null || echo "")
  AGENT_TOKEN=$(consul kv get cosmos/agent-token 2>/dev/null || echo "")

  if [ -n "$CONTROLLER_TOKEN" ] && [ -n "$AGENT_TOKEN" ]; then
    echo "Vault tokens found in Consul KV"
    break
  fi
  echo "Waiting for Vault tokens... ($WAIT_COUNT/$MAX_WAIT)"
  sleep 5
  WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
  echo "ERROR: Vault tokens did not become available in time"
  exit 1
fi

# Function to deploy a Nomad job with retries
deploy_nomad_job() {
  local job_file=$1
  local job_name=$2
  local max_retries=6
  local retry_count=0
  local wait_time=15

  while [ $retry_count -lt $max_retries ]; do
    echo "Deploying $job_name (attempt $((retry_count + 1))/$max_retries)..."

    if nomad job run "$job_file" 2>&1; then
      echo "$job_name deployed successfully"
      return 0
    else
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt $max_retries ]; then
        echo "Failed to deploy $job_name, waiting ${wait_time}s before retry..."
        sleep $wait_time
        wait_time=$((wait_time + 5))  # Increase wait time for each retry
      fi
    fi
  done

  echo "ERROR: Failed to deploy $job_name after $max_retries attempts"
  return 1
}

# Check if jobs are already running
POSTGRES_RUNNING=$(nomad job status postgres-cosmos 2>/dev/null && echo "yes" || echo "no")
CONTROLLER_RUNNING=$(nomad job status cosmos-controller 2>/dev/null && echo "yes" || echo "no")

if [ "$POSTGRES_RUNNING" = "yes" ] && [ "$CONTROLLER_RUNNING" = "yes" ]; then
  echo "Cosmos jobs are already running"
  exit 0
fi

# Create Nomad jobs directory
mkdir -p /opt/nomad/jobs

# Deploy postgres-cosmos if not running
if [ "$POSTGRES_RUNNING" = "no" ]; then
  echo "Deploying postgres-cosmos..."

  cat > /opt/nomad/jobs/postgres-cosmos.nomad <<'EOF'
job "postgres-cosmos" {
  datacenters = ["*"]
  type        = "service"
  node_pool   = "management"

  group "postgres" {
    count = 1

    constraint {
      attribute = "${node.pool}"
      value     = "management"
    }

    network {
      port "postgres" {
        static = 5432
      }
    }

    service {
      name = "postgres-cosmos"
      port = "postgres"

      tags = [
        "database",
        "postgres",
        "cosmos",
      ]

      check {
        name     = "alive"
        type     = "tcp"
        port     = "postgres"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "postgres" {
      driver = "docker"

      config {
        image = "postgres:15-alpine"

        ports = ["postgres"]

        volumes = [
          "/opt/postgres-cosmos:/var/lib/postgresql/data"
        ]
      }

      env {
        POSTGRES_DB       = "cosmos"
        POSTGRES_USER     = "cosmos"
        POSTGRES_PASSWORD = "cosmos_production"
        PGDATA            = "/var/lib/postgresql/data/pgdata"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
EOF

  if ! deploy_nomad_job /opt/nomad/jobs/postgres-cosmos.nomad postgres-cosmos; then
    exit 1
  fi

  # Wait for postgres to be healthy
  echo "Waiting for postgres-cosmos to be healthy..."
  sleep 10
fi

# Deploy cosmos-controller if not running
if [ "$CONTROLLER_RUNNING" = "no" ]; then
  echo "Deploying cosmos-controller..."

  cat > /opt/nomad/jobs/cosmos-controller.nomad <<'EOF'
job "cosmos-controller" {
  datacenters = ["*"]
  type        = "service"
  node_pool   = "management"

  group "controller" {
    count = 1

    constraint {
      attribute = "${node.pool}"
      value     = "management"
    }

    network {
      port "grpc" {
        static = 9091
      }

      port "http" {
        static = 5010
      }
    }

    service {
      name = "cosmos-controller"
      port = "grpc"

      tags = [
        "cosmos",
        "controller",
      ]

      check {
        name     = "alive"
        type     = "tcp"
        port     = "grpc"
        interval = "10s"
        timeout  = "2s"
      }
    }

    service {
      name = "cosmos-controller-http"
      port = "http"

      check {
        name     = "http-alive"
        type     = "http"
        path     = "/api/v1/health"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "controller" {
      driver = "docker"

      config {
        image = "ghcr.io/metorial/cosmos-controller:latest"

        ports = ["grpc", "http"]

        dns_servers = ["127.0.0.1"]
        dns_search_domains = ["service.consul"]

        volumes = [
          "/etc/cosmos/controller:/etc/cosmos/controller"
        ]
      }

      template {
        data = <<EOH
{{- range service "postgres-cosmos" }}
COSMOS_DB_URL="postgres://cosmos:cosmos_production@{{ .Address }}:{{ .Port }}/cosmos?sslmode=disable"
{{- end }}
{{- range service "vault" "passing,warning" }}
{{ if .Tags | contains "active" }}
VAULT_ADDR="http://{{ .Address }}:8200"
{{ end }}
{{- end }}
{{- range $i, $s := service "nomad" }}{{ if eq $i 0 }}
NOMAD_ADDR="http://{{ .Address }}:4646"
{{ end }}{{ end }}
VAULT_TOKEN="{{ key "cosmos/controller-token" }}"
EOH
        destination = "local/services.env"
        env = true
      }

      env {
        COSMOS_GRPC_PORT = "${NOMAD_PORT_grpc}"
        COSMOS_HTTP_PORT = "${NOMAD_PORT_http}"
        COSMOS_CERT_HOSTNAME = "cosmos-controller.service.consul"
        COSMOS_DATA_DIR = "/data"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
EOF

  if ! deploy_nomad_job /opt/nomad/jobs/cosmos-controller.nomad cosmos-controller; then
    exit 1
  fi
fi

# Deploy traefik if not running
TRAEFIK_RUNNING=$(nomad job status traefik 2>/dev/null && echo "yes" || echo "no")

if [ "$TRAEFIK_RUNNING" = "no" ]; then
  echo "Deploying traefik..."

  cat > /opt/nomad/jobs/traefik.nomad <<'EOF'
job "traefik" {
  datacenters = ["*"]
  type        = "system"

  group "traefik" {
    network {
      port "http" {
        static = 80
      }

      port "https" {
        static = 443
      }

      port "api" {
        static = 8081
      }
    }

    service {
      name = "traefik"
      port = "http"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.dashboard.rule=Host(`traefik.example.com`)",
        "traefik.http.routers.dashboard.service=api@internal",
      ]

      check {
        name     = "alive"
        type     = "tcp"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image        = "traefik:v3.0"
        network_mode = "host"

        volumes = [
          "local/traefik.toml:/etc/traefik/traefik.toml",
        ]
      }

      template {
        data = <<EOH
[entryPoints]
  [entryPoints.http]
  address = ":80"

  [entryPoints.https]
  address = ":443"

  [entryPoints.traefik]
  address = ":8081"

[api]
  dashboard = true
  insecure  = true

[ping]
  entryPoint = "traefik"

# Enable Consul Catalog configuration backend
[providers.consulCatalog]
  prefix           = "traefik"
  exposedByDefault = false

  [providers.consulCatalog.endpoint]
    address = "127.0.0.1:8500"
    scheme  = "http"
EOH

        destination = "local/traefik.toml"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
EOF

  if ! deploy_nomad_job /opt/nomad/jobs/traefik.nomad traefik; then
    exit 1
  fi
fi

# Deploy sentinel-controller if not running
COMMANDER_RUNNING=$(nomad job status sentinel-controller 2>/dev/null && echo "yes" || echo "no")

if [ "$COMMANDER_RUNNING" = "no" ]; then
  echo "Deploying sentinel-controller..."

  cat > /opt/nomad/jobs/sentinel-controller.nomad <<'EOF'
job "sentinel-controller" {
  datacenters = ["*"]
  type        = "service"
  node_pool   = "management"

  group "commander" {
    count = 1

    constraint {
      attribute = "${node.pool}"
      value     = "management"
    }

    network {
      port "grpc" {
        static = 50052
      }

      port "http" {
        static = 5020
      }
    }

    service {
      name = "sentinel-controller"
      port = "grpc"

      tags = [
        "sentinel",
        "commander",
      ]

      check {
        name     = "alive"
        type     = "tcp"
        port     = "grpc"
        interval = "10s"
        timeout  = "2s"
      }
    }

    service {
      name = "sentinel-controller-http"
      port = "http"

      check {
        name     = "http-alive"
        type     = "http"
        path     = "/api/v1/health"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "commander" {
      driver = "docker"

      config {
        image = "ghcr.io/metorial/sentinel-controller:latest"

        ports = ["grpc", "http"]

        dns_servers = ["127.0.0.1"]
        dns_search_domains = ["service.consul"]

        volumes = [
          "/opt/sentinel-data:/data"
        ]
      }

      env {
        PORT = "${NOMAD_PORT_grpc}"
        GRPC_PORT = "${NOMAD_PORT_grpc}"
        HTTP_PORT = "${NOMAD_PORT_http}"
        DB_PATH = "/data/metrics.db"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
EOF

  if ! deploy_nomad_job /opt/nomad/jobs/sentinel-controller.nomad sentinel-controller; then
    exit 1
  fi
fi

echo ""
echo "Cosmos jobs deployment complete!"
echo "- postgres-cosmos: $(nomad job status postgres-cosmos 2>/dev/null | grep Status | awk '{print $3}')"
echo "- cosmos-controller: $(nomad job status cosmos-controller 2>/dev/null | grep Status | awk '{print $3}')"
echo "- traefik: $(nomad job status traefik 2>/dev/null | grep Status | awk '{print $3}')"
echo "- sentinel-controller: $(nomad job status sentinel-controller 2>/dev/null | grep Status | awk '{print $3}')"
