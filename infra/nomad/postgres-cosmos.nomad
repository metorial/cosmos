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
