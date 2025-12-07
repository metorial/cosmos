variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the cluster"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b", "us-east-2c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access bastion via SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Consul Configuration
variable "consul_server_count" {
  description = "Number of Consul servers (min 3 for HA)"
  type        = number
  default     = 3
}

variable "consul_instance_type" {
  description = "Instance type for Consul servers"
  type        = string
  default     = "t3.small"
}

# Vault Configuration
variable "vault_server_count" {
  description = "Number of Vault servers (min 3 for HA)"
  type        = number
  default     = 3
}

variable "vault_instance_type" {
  description = "Instance type for Vault servers"
  type        = string
  default     = "t3.small"
}

# Nomad Configuration
variable "nomad_server_count" {
  description = "Number of Nomad servers (min 3 for HA)"
  type        = number
  default     = 3
}

variable "nomad_server_instance_type" {
  description = "Instance type for Nomad servers"
  type        = string
  default     = "t3.small"
}

variable "nomad_client_count" {
  description = "Number of Nomad clients (general pool)"
  type        = number
  default     = 3
}

variable "nomad_client_instance_type" {
  description = "Instance type for Nomad clients"
  type        = string
  default     = "t3.medium"
}

variable "nomad_management_client_count" {
  description = "Number of Nomad management clients"
  type        = number
  default     = 2
}

variable "nomad_management_client_instance_type" {
  description = "Instance type for Nomad management clients"
  type        = string
  default     = "t3.medium"
}

# Bastion Configuration
variable "bastion_instance_type" {
  description = "Instance type for bastion host"
  type        = string
  default     = "t3.small"
}

# GitHub Configuration
variable "github_scripts_base_url" {
  description = "Base URL for downloading scripts from GitHub"
  type        = string
  default     = "https://raw.githubusercontent.com/metorial/cosmos/main/infra/scripts"
}

# SSH Key
variable "ssh_key_name" {
  description = "Name of the SSH key pair"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "Public SSH key content (if ssh_key_name is not provided)"
  type        = string
  default     = ""
}
