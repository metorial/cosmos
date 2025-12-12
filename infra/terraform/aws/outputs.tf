output "bastion_public_ip" {
  description = "Public IP of bastion host"
  value       = aws_eip.bastion.public_ip
}

output "bastion_private_ip" {
  description = "Private IP of bastion host"
  value       = aws_instance.bastion.private_ip
}

output "consul_server_ips" {
  description = "Private IPs of Consul servers"
  value       = aws_instance.consul_server[*].private_ip
}

output "vault_server_ips" {
  description = "Private IPs of Vault servers"
  value       = aws_instance.vault_server[*].private_ip
}

output "nomad_server_ips" {
  description = "Private IPs of Nomad servers"
  value       = aws_instance.nomad_server[*].private_ip
}

output "nomad_client_ips" {
  description = "Private IPs of Nomad clients (general pool)"
  value       = aws_instance.nomad_client[*].private_ip
}

output "nomad_management_client_ips" {
  description = "Private IPs of Nomad management clients"
  value       = aws_instance.nomad_management_client[*].private_ip
}

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
  value       = "ssh -L 8500:localhost:8500 -L 8200:localhost:8200 -L 4646:localhost:4646 -L 8081:localhost:8081 -L 5020:localhost:5020 -L 5010:localhost:5010 ubuntu@${aws_eip.bastion.public_ip}"
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
