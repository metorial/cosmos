# Consul Servers Launch Template
resource "aws_launch_template" "consul_server" {
  name_prefix   = "${local.cluster_name}-consul-server-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.consul_instance_type
  key_name      = aws_key_pair.main.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.consul_server.name
  }

  vpc_security_group_ids = [
    aws_security_group.consul_server.id,
  ]

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data/consul-server.sh", {
    cluster_name            = local.cluster_name
    region                  = var.aws_region
    server_count            = var.consul_server_desired_capacity
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
      Name = "${local.cluster_name}-consul-server"
      Role = "consul-server"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Consul Servers Auto Scaling Group
resource "aws_autoscaling_group" "consul_server" {
  name                = "${local.cluster_name}-consul-server"
  min_size            = var.consul_server_min_size
  max_size            = var.consul_server_max_size
  desired_capacity    = var.consul_server_desired_capacity
  vpc_zone_identifier = aws_subnet.private[*].id
  health_check_type   = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.consul_server.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.cluster_name}-consul-server"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "consul-server"
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
}
