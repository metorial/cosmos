# Nomad Clients - General Pool
resource "aws_instance" "nomad_client" {
  count = var.nomad_client_count

  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.nomad_client_instance_type
  subnet_id            = aws_subnet.private[count.index % length(aws_subnet.private)].id
  key_name             = aws_key_pair.main.key_name
  iam_instance_profile = aws_iam_instance_profile.nomad_client.name

  vpc_security_group_ids = [
    aws_security_group.nomad_client.id,
    aws_security_group.consul_server.id,
  ]

  user_data = templatefile("${path.module}/user-data/nomad-client.sh", {
    cluster_name            = local.cluster_name
    region                  = var.aws_region
    node_pool               = "default"
    node_class              = "general"
    github_scripts_base_url = var.github_scripts_base_url
    controller_addr         = "cosmos-controller.service.consul:50051"
    commander_addr          = "sentinel-controller.service.consul:50052"
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-nomad-client-${count.index + 1}"
    Role = "nomad-client"
    Pool = "default"
  })

  depends_on = [aws_instance.nomad_server]
}

# Nomad Clients - Management Pool
resource "aws_instance" "nomad_management_client" {
  count = var.nomad_management_client_count

  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.nomad_management_client_instance_type
  subnet_id            = aws_subnet.private[count.index % length(aws_subnet.private)].id
  key_name             = aws_key_pair.main.key_name
  iam_instance_profile = aws_iam_instance_profile.nomad_client.name

  vpc_security_group_ids = [
    aws_security_group.nomad_client.id,
    aws_security_group.consul_server.id,
  ]

  user_data = templatefile("${path.module}/user-data/nomad-client.sh", {
    cluster_name            = local.cluster_name
    region                  = var.aws_region
    node_pool               = "management"
    node_class              = "management"
    github_scripts_base_url = var.github_scripts_base_url
    controller_addr         = "cosmos-controller.service.consul:50051"
    commander_addr          = "sentinel-controller.service.consul:50052"
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-nomad-management-client-${count.index + 1}"
    Role = "nomad-client"
    Pool = "management"
  })

  depends_on = [aws_instance.nomad_server]
}
