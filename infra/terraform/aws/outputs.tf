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
