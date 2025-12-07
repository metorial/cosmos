# Consul Servers
resource "aws_instance" "consul_server" {
  count = var.consul_server_count

  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.consul_instance_type
  subnet_id            = aws_subnet.private[count.index % length(aws_subnet.private)].id
  key_name             = aws_key_pair.main.key_name
  iam_instance_profile = aws_iam_instance_profile.consul_server.name

  vpc_security_group_ids = [
    aws_security_group.consul_server.id,
  ]

  user_data = templatefile("${path.module}/user-data/consul-server.sh", {
    cluster_name            = local.cluster_name
    region                  = var.aws_region
    server_count            = var.consul_server_count
    github_scripts_base_url = var.github_scripts_base_url
    controller_addr         = "cosmos-controller.service.consul:50051"
    commander_addr          = "sentinel-commander.service.consul:50052"
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-consul-server-${count.index + 1}"
    Role = "consul-server"
  })
}
