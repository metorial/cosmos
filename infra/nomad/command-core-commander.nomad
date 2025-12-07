job "command-core-commander" {
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
        static = 8082
      }
    }

    service {
      name = "command-core-commander"
      port = "grpc"

      tags = [
        "command-core",
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
      name = "command-core-commander-http"
      port = "http"

      check {
        name     = "http-alive"
        type     = "http"
        path     = "/health"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "commander" {
      driver = "docker"

      config {
        image = "ghcr.io/metorial/command-core-commander:latest"

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
