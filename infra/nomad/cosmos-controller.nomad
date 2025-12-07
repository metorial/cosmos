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
        static = 8090
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
VAULT_ADDR="http://{{ .Address }}:{{ .Port }}"
{{ end }}
{{- end }}
VAULT_TOKEN="{{ key "cosmos/controller-token" }}"
EOH
        destination = "local/services.env"
        env = true
      }

      env {
        GRPC_PORT = "${NOMAD_PORT_grpc}"
        HTTP_PORT = "${NOMAD_PORT_http}"
        CONSUL_HTTP_ADDR = "127.0.0.1:8500"
        COSMOS_CERT_HOSTNAME = "cosmos-controller.service.consul"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
