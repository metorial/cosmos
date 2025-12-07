# Bastion Security Group
resource "aws_security_group" "bastion" {
  name        = "${local.cluster_name}-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from allowed IPs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-bastion-sg"
  })
}

# Consul Server Security Group
resource "aws_security_group" "consul_server" {
  name        = "${local.cluster_name}-consul-server-sg"
  description = "Security group for Consul servers"
  vpc_id      = aws_vpc.main.id

  # SSH from bastion
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Consul RPC
  ingress {
    description = "Consul RPC"
    from_port   = 8300
    to_port     = 8300
    protocol    = "tcp"
    self        = true
  }

  # Consul Serf LAN (TCP)
  ingress {
    description = "Consul Serf LAN TCP"
    from_port   = 8301
    to_port     = 8301
    protocol    = "tcp"
    self        = true
  }

  # Consul Serf LAN (UDP)
  ingress {
    description = "Consul Serf LAN UDP"
    from_port   = 8301
    to_port     = 8301
    protocol    = "udp"
    self        = true
  }

  # Consul HTTP API (from all security groups)
  ingress {
    description = "Consul HTTP API"
    from_port   = 8500
    to_port     = 8500
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Consul DNS (TCP)
  ingress {
    description = "Consul DNS TCP"
    from_port   = 8600
    to_port     = 8600
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Consul DNS (UDP)
  ingress {
    description = "Consul DNS UDP"
    from_port   = 8600
    to_port     = 8600
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-consul-server-sg"
  })
}

# Vault Server Security Group
resource "aws_security_group" "vault_server" {
  name        = "${local.cluster_name}-vault-server-sg"
  description = "Security group for Vault servers"
  vpc_id      = aws_vpc.main.id

  # SSH from bastion
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Vault API
  ingress {
    description = "Vault API"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Vault cluster communication
  ingress {
    description = "Vault cluster communication"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-vault-server-sg"
  })
}

# Nomad Server Security Group
resource "aws_security_group" "nomad_server" {
  name        = "${local.cluster_name}-nomad-server-sg"
  description = "Security group for Nomad servers"
  vpc_id      = aws_vpc.main.id

  # SSH from bastion
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Nomad HTTP API
  ingress {
    description = "Nomad HTTP API"
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Nomad RPC (inter-server)
  ingress {
    description = "Nomad RPC (inter-server)"
    from_port   = 4647
    to_port     = 4647
    protocol    = "tcp"
    self        = true
  }

  # Nomad Serf TCP (inter-server)
  ingress {
    description = "Nomad Serf TCP (inter-server)"
    from_port   = 4648
    to_port     = 4648
    protocol    = "tcp"
    self        = true
  }

  # Nomad Serf UDP (inter-server)
  ingress {
    description = "Nomad Serf UDP (inter-server)"
    from_port   = 4648
    to_port     = 4648
    protocol    = "udp"
    self        = true
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-nomad-server-sg"
  })
}

# Nomad Client Security Group
resource "aws_security_group" "nomad_client" {
  name        = "${local.cluster_name}-nomad-client-sg"
  description = "Security group for Nomad clients"
  vpc_id      = aws_vpc.main.id

  # SSH from bastion
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # HTTP for Traefik
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS for Traefik
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Nomad dynamic port range (for tasks)
  ingress {
    description = "Nomad dynamic ports"
    from_port   = 20000
    to_port     = 32000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow communication from Nomad servers
  ingress {
    description     = "From Nomad servers"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.nomad_server.id]
  }

  # Allow inter-client communication
  ingress {
    description = "Inter-client communication"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-nomad-client-sg"
  })
}

# Separate security group rules to avoid circular dependencies

# Allow Nomad clients to connect to Nomad server RPC (port 4647)
resource "aws_security_group_rule" "nomad_server_rpc_from_clients" {
  type                     = "ingress"
  description              = "Nomad RPC from clients"
  from_port                = 4647
  to_port                  = 4647
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nomad_client.id
  security_group_id        = aws_security_group.nomad_server.id
}

# Allow Nomad clients to connect to Nomad server Serf TCP (port 4648)
resource "aws_security_group_rule" "nomad_server_serf_tcp_from_clients" {
  type                     = "ingress"
  description              = "Nomad Serf TCP from clients"
  from_port                = 4648
  to_port                  = 4648
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nomad_client.id
  security_group_id        = aws_security_group.nomad_server.id
}

# Allow Nomad clients to connect to Nomad server Serf UDP (port 4648)
resource "aws_security_group_rule" "nomad_server_serf_udp_from_clients" {
  type                     = "ingress"
  description              = "Nomad Serf UDP from clients"
  from_port                = 4648
  to_port                  = 4648
  protocol                 = "udp"
  source_security_group_id = aws_security_group.nomad_client.id
  security_group_id        = aws_security_group.nomad_server.id
}
