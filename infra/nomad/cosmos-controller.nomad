job "cosmos-controller" {
  datacenters = ["*"]
  type        = "service"

  group "controller" {
    count = 1

    constraint {
      attribute = "${node.pool}"
      value     = "management"
    }

    network {
      port "grpc" {
        static = 50051
      }

      port "http" {
        static = 8080
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

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.cosmos.rule=Host(`cosmos.example.com`)",
      ]

      check {
        name     = "http-alive"
        type     = "http"
        path     = "/health"
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
      }

      env {
        GRPC_PORT = "${NOMAD_PORT_grpc}"
        HTTP_PORT = "${NOMAD_PORT_http}"
        CONSUL_HTTP_ADDR = "127.0.0.1:8500"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
