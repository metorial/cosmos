# Bastion Host
resource "aws_instance" "bastion" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.bastion_instance_type
  subnet_id            = aws_subnet.public[0].id
  key_name             = aws_key_pair.main.key_name
  iam_instance_profile = aws_iam_instance_profile.bastion.name

  vpc_security_group_ids = [aws_security_group.bastion.id]

  user_data = templatefile("${path.module}/user-data/bastion.sh", {
    cluster_name           = local.cluster_name
    region                 = var.aws_region
    github_scripts_base_url = var.github_scripts_base_url
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-bastion"
    Role = "bastion"
  })
}

# Elastic IP for Bastion
resource "aws_eip" "bastion" {
  domain   = "vpc"
  instance = aws_instance.bastion.id

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-bastion-eip"
  })

  depends_on = [aws_internet_gateway.main]
}
