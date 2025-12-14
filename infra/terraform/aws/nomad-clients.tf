# Nomad Clients - General Pool Launch Template
resource "aws_launch_template" "nomad_client" {
  name_prefix   = "${local.cluster_name}-nomad-client-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.nomad_client_instance_type
  key_name      = aws_key_pair.main.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.nomad_client.name
  }

  vpc_security_group_ids = [
    aws_security_group.nomad_client.id,
    aws_security_group.consul_server.id,
  ]

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data/nomad-client.sh", {
    cluster_name            = local.cluster_name
    region                  = var.aws_region
    node_pool               = "default"
    node_class              = "general"
    github_scripts_base_url = var.github_scripts_base_url
    controller_addr         = "cosmos-controller.service.consul:50051"
    commander_addr          = "sentinel-controller.service.consul:50052"
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${local.cluster_name}-nomad-client"
      Role = "nomad-client"
      Pool = "default"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Nomad Clients - General Pool Auto Scaling Group
resource "aws_autoscaling_group" "nomad_client" {
  name                = "${local.cluster_name}-nomad-client"
  min_size            = var.nomad_client_min_size
  max_size            = var.nomad_client_max_size
  desired_capacity    = var.nomad_client_desired_capacity
  vpc_zone_identifier = aws_subnet.private[*].id
  health_check_type   = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.nomad_client.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.cluster_name}-nomad-client"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "nomad-client"
    propagate_at_launch = true
  }

  tag {
    key                 = "Pool"
    value               = "default"
    propagate_at_launch = true
  }

  tag {
    key                 = "Cluster"
    value               = local.cluster_name
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_autoscaling_group.nomad_server,
    aws_rds_cluster_instance.aurora_writer
  ]
}

# Nomad Clients - Management Pool Launch Template
resource "aws_launch_template" "nomad_management_client" {
  name_prefix   = "${local.cluster_name}-nomad-management-client-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.nomad_management_client_instance_type
  key_name      = aws_key_pair.main.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.nomad_client.name
  }

  vpc_security_group_ids = [
    aws_security_group.nomad_client.id,
    aws_security_group.consul_server.id,
  ]

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data/nomad-client.sh", {
    cluster_name            = local.cluster_name
    region                  = var.aws_region
    node_pool               = "management"
    node_class              = "management"
    github_scripts_base_url = var.github_scripts_base_url
    controller_addr         = "cosmos-controller.service.consul:50051"
    commander_addr          = "sentinel-controller.service.consul:50052"
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${local.cluster_name}-nomad-management-client"
      Role = "nomad-client"
      Pool = "management"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Nomad Clients - Management Pool Auto Scaling Group
resource "aws_autoscaling_group" "nomad_management_client" {
  name                = "${local.cluster_name}-nomad-management-client"
  min_size            = var.nomad_management_client_min_size
  max_size            = var.nomad_management_client_max_size
  desired_capacity    = var.nomad_management_client_desired_capacity
  vpc_zone_identifier = aws_subnet.private[*].id
  health_check_type   = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.nomad_management_client.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.cluster_name}-nomad-management-client"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "nomad-client"
    propagate_at_launch = true
  }

  tag {
    key                 = "Pool"
    value               = "management"
    propagate_at_launch = true
  }

  tag {
    key                 = "Cluster"
    value               = local.cluster_name
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_autoscaling_group.nomad_server,
    aws_rds_cluster_instance.aurora_writer
  ]
}
