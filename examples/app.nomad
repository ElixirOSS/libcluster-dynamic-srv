variable "dist-port" {
  type    = number
  default = 4370
}

variable "service-name" {
  type    = string
  default = "dynamic-epmd-lab"
}

variable "consul-service-address" {
  type    = string
  default = "service.consul"
}

variable "docker-image" {
  type    = string
}

# This value is only for example purposes. Please generate a new one for production use.
variable "secret-key-base" {
  type    = string
  default = "XxCXBx3xBUuWCNIzmFMavQntSSYt1QQGyAWMpZ3hqB/Bx4YKk+gRtVqhtZWlVinX"
}

job "dynamic-epmd-lab" {
  datacenters = ["*"]

  group "app" {
    count = 3

    network {
      mode     = "bridge"
      hostname = "node-${NOMAD_HOST_PORT_dist}"
      port "dist" {
        to = var.dist-port
      }

      dns {
        servers = ["${attr.unique.network.ip-address}"]
      }
    }

    service {
      name         = var.service-name
      port         = "dist"
      provider     = "consul"
      address      = "node-${NOMAD_ALLOC_INDEX}.${var.service-name}.${var.consul-service-address}"
      address_mode = "auto"

      tags = [
        "node-${NOMAD_ALLOC_INDEX}"
      ]

      connect {
        sidecar_service {
          proxy {
            local_service_port = var.dist-port
            upstreams {
              destination_name = var.service-name
              local_bind_port  = var.dist-port + 1
            }
          }
        }
      }
    }

    task "app" {
      driver = "docker"

      config {
        image      = var.docker-image
        force_pull = true
        ports      = ["dist"]
      }

      env {
        SECRET_KEY_BASE        = var.secret-key-base
        ERL_DIST_PORT          = var.dist-port
        ELIXIR_ERL_OPTIONS     = "-start_epmd false -epmd_module Elixir.DynamicSrv.Epmd"
        DNS_CLUSTER_QUERY      = "${var.service-name}.${var.consul-service-address}"
        RELEASE_DISTRIBUTION   = "name"
        RELEASE_NODE           = "node-${NOMAD_ALLOC_INDEX}@${var.service-name}.${var.consul-service-address}"
        SERVICE_NAME           = var.service-name
        CONSUL_SERVICE_ADDRESS = var.consul-service-address
      }
    }
  }
}
