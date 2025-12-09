# Security Group for ALB
resource "aws_security_group" "alb" {
  name        = "${local.cluster_name}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.main.id

  # HTTP
  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-alb-sg"
  })
}

# Application Load Balancer
resource "aws_lb" "traefik" {
  name               = "${local.cluster_name}-traefik-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
  enable_http2              = true

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-traefik-alb"
  })
}

# Target Group for Traefik (HTTP backend on port 80)
resource "aws_lb_target_group" "traefik" {
  name_prefix = "trf-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/ping"
    protocol            = "HTTP"
    port                = "80"
    matcher             = "200,404"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-traefik-tg"
  })
}

# Attach Nomad clients to target group
resource "aws_lb_target_group_attachment" "traefik" {
  count            = var.nomad_client_count
  target_group_arn = aws_lb_target_group.traefik.arn
  target_id        = aws_instance.nomad_client[count.index].id
  port             = 80
}

# HTTP Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.traefik.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik.arn
  }
}
