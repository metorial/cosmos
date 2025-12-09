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
  description = "SSH tunnel command to access all UIs at once"
  value       = "ssh -L 8500:${aws_instance.consul_server[0].private_ip}:8500 -L 8200:${aws_instance.vault_server[0].private_ip}:8200 -L 4646:${aws_instance.nomad_server[0].private_ip}:4646 -L 8081:${aws_instance.nomad_client[0].private_ip}:8081 -L 5020:${aws_instance.nomad_management_client[0].private_ip}:5020 -L 5010:${aws_instance.nomad_management_client[0].private_ip}:5010 ubuntu@${aws_eip.bastion.public_ip}"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer for Traefik"
  value       = aws_lb.traefik.dns_name
}

output "alb_url" {
  description = "HTTP URL for the Application Load Balancer"
  value       = "http://${aws_lb.traefik.dns_name}"
}
