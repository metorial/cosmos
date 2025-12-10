# Route 53 and ACM Configuration for custom domain

locals {
  # Extract the parent domain from the full domain
  # e.g., "abc.example.com" -> "example.com"
  domain_parts  = split(".", var.domain_name)
  # Get the last two parts as the parent domain
  parent_domain = join(".", slice(local.domain_parts, length(local.domain_parts) - 2, length(local.domain_parts)))
}

# Look up the existing Route 53 hosted zone
data "aws_route53_zone" "main" {
  name         = "${local.parent_domain}."
  private_zone = false
}

# ACM Certificate for the domain and wildcard subdomain
resource "aws_acm_certificate" "alb" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = [
    "*.${var.domain_name}"
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-alb-cert"
  })
}

# Route 53 records for ACM certificate validation
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# ACM Certificate validation
resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Route 53 A record for the domain pointing to the ALB
resource "aws_route53_record" "alb_domain" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.traefik.dns_name
    zone_id                = aws_lb.traefik.zone_id
    evaluate_target_health = true
  }
}

# Route 53 A record for the wildcard subdomain pointing to the ALB
resource "aws_route53_record" "alb_wildcard" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "*.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.traefik.dns_name
    zone_id                = aws_lb.traefik.zone_id
    evaluate_target_health = true
  }
}
