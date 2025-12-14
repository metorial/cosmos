output "bastion_public_ip" {
  description = "Public IP of bastion host"
  value       = aws_eip.bastion.public_ip
}

output "bastion_private_ip" {
  description = "Private IP of bastion host"
  value       = aws_instance.bastion.private_ip
}

output "consul_server_asg_name" {
  description = "Name of the Consul servers Auto Scaling Group"
  value       = aws_autoscaling_group.consul_server.name
}

output "vault_server_asg_name" {
  description = "Name of the Vault servers Auto Scaling Group"
  value       = aws_autoscaling_group.vault_server.name
}

output "nomad_server_asg_name" {
  description = "Name of the Nomad servers Auto Scaling Group"
  value       = aws_autoscaling_group.nomad_server.name
}

output "nomad_client_asg_name" {
  description = "Name of the Nomad clients (general pool) Auto Scaling Group"
  value       = aws_autoscaling_group.nomad_client.name
}

output "nomad_management_client_asg_name" {
  description = "Name of the Nomad management clients Auto Scaling Group"
  value       = aws_autoscaling_group.nomad_management_client.name
}

# To get instance IPs from ASG, use:
# aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names <asg-name> --region <region>
# or use AWS Console/CLI to query instances with the appropriate tags

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "cluster_name" {
  description = "Cluster name"
  value       = local.cluster_name
}

output "ssh_connection_command" {
  description = "Command to SSH into bastion"
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_eip.bastion.public_ip}"
}

output "all_services_tunnel" {
  description = "SSH tunnel command to access all UIs at once (via bastion proxy)"
  value       = "ssh -L 8500:localhost:8501 -L 8200:localhost:8200 -L 4646:localhost:4646 -L 8081:localhost:8081 -L 5020:localhost:5020 -L 5010:localhost:5010 ubuntu@${aws_eip.bastion.public_ip}"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer for Traefik"
  value       = aws_lb.traefik.dns_name
}

output "alb_url" {
  description = "HTTPS URL for the Application Load Balancer"
  value       = "https://${var.domain_name}"
}

output "domain_name" {
  description = "Configured domain name"
  value       = var.domain_name
}

output "wildcard_domain" {
  description = "Wildcard subdomain"
  value       = "*.${var.domain_name}"
}

output "certificate_arn" {
  description = "ARN of the ACM certificate"
  value       = aws_acm_certificate.alb.arn
}

# Aurora Outputs
output "aurora_cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.aurora.cluster_identifier
}

output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "aurora_cluster_port" {
  description = "Aurora cluster port"
  value       = aws_rds_cluster.aurora.port
}

output "aurora_database_name" {
  description = "Name of the default database"
  value       = aws_rds_cluster.aurora.database_name
}

output "aurora_master_username" {
  description = "Master username for Aurora"
  value       = aws_rds_cluster.aurora.master_username
  sensitive   = true
}

output "aurora_secret_arn" {
  description = "ARN of the Secrets Manager secret containing Aurora master credentials"
  value       = aws_secretsmanager_secret.aurora_master_password.arn
}
