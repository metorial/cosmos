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
variable "consul_server_min_size" {
  description = "Minimum number of Consul servers"
  type        = number
  default     = 3
}

variable "consul_server_max_size" {
  description = "Maximum number of Consul servers"
  type        = number
  default     = 5
}

variable "consul_server_desired_capacity" {
  description = "Desired number of Consul servers (min 3 for HA)"
  type        = number
  default     = 3
}

variable "consul_instance_type" {
  description = "Instance type for Consul servers"
  type        = string
  default     = "t3.small"
}

# Vault Configuration
variable "vault_server_min_size" {
  description = "Minimum number of Vault servers"
  type        = number
  default     = 3
}

variable "vault_server_max_size" {
  description = "Maximum number of Vault servers"
  type        = number
  default     = 5
}

variable "vault_server_desired_capacity" {
  description = "Desired number of Vault servers (min 3 for HA)"
  type        = number
  default     = 3
}

variable "vault_instance_type" {
  description = "Instance type for Vault servers"
  type        = string
  default     = "t3.small"
}

# Nomad Configuration
variable "nomad_server_min_size" {
  description = "Minimum number of Nomad servers"
  type        = number
  default     = 3
}

variable "nomad_server_max_size" {
  description = "Maximum number of Nomad servers"
  type        = number
  default     = 5
}

variable "nomad_server_desired_capacity" {
  description = "Desired number of Nomad servers (min 3 for HA)"
  type        = number
  default     = 3
}

variable "nomad_server_instance_type" {
  description = "Instance type for Nomad servers"
  type        = string
  default     = "t3.small"
}

variable "nomad_core_client_min_size" {
  description = "Minimum number of Nomad core clients"
  type        = number
  default     = 1
}

variable "nomad_core_client_max_size" {
  description = "Maximum number of Nomad core clients"
  type        = number
  default     = 10
}

variable "nomad_core_client_desired_capacity" {
  description = "Desired number of Nomad core clients"
  type        = number
  default     = 3
}

variable "nomad_core_client_instance_type" {
  description = "Instance type for Nomad core clients"
  type        = string
  default     = "t3.medium"
}

variable "nomad_management_client_min_size" {
  description = "Minimum number of Nomad management clients"
  type        = number
  default     = 1
}

variable "nomad_management_client_max_size" {
  description = "Maximum number of Nomad management clients"
  type        = number
  default     = 5
}

variable "nomad_management_client_desired_capacity" {
  description = "Desired number of Nomad management clients"
  type        = number
  default     = 2
}

variable "nomad_management_client_instance_type" {
  description = "Instance type for Nomad management clients"
  type        = string
  default     = "t3.medium"
}

variable "nomad_provider_client_min_size" {
  description = "Minimum number of Nomad provider clients"
  type        = number
  default     = 2
}

variable "nomad_provider_client_max_size" {
  description = "Maximum number of Nomad provider clients"
  type        = number
  default     = 5
}

variable "nomad_provider_client_desired_capacity" {
  description = "Desired number of Nomad provider clients"
  type        = number
  default     = 2
}

variable "nomad_provider_client_instance_type" {
  description = "Instance type for Nomad provider clients"
  type        = string
  default     = "t3.medium"
}

variable "nomad_compute_client_min_size" {
  description = "Minimum number of Nomad compute clients"
  type        = number
  default     = 2
}

variable "nomad_compute_client_max_size" {
  description = "Maximum number of Nomad compute clients"
  type        = number
  default     = 5
}

variable "nomad_compute_client_desired_capacity" {
  description = "Desired number of Nomad compute clients"
  type        = number
  default     = 2
}

variable "nomad_compute_client_instance_type" {
  description = "Instance type for Nomad compute clients"
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

# Domain Configuration
variable "domain_name" {
  description = "Domain name to use for the ALB (e.g., abc.example.com). The parent zone must already exist in Route 53."
  type        = string
}

# Aurora PostgreSQL Configuration
variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "15.14"
}

variable "aurora_database_name" {
  description = "Name of the default database to create (each service can create its own database)"
  type        = string
  default     = "postgres"
}

variable "aurora_master_username" {
  description = "Master username for Aurora database"
  type        = string
  default     = "dbadmin"
}

variable "aurora_instance_class" {
  description = "Instance class for Aurora database instances (use Graviton instances like db.r6g.large)"
  type        = string
  default     = "db.r6g.large"
}

variable "aurora_replica_count" {
  description = "Number of read replicas to create (0-15)"
  type        = number
  default     = 1
}

variable "aurora_backup_retention_period" {
  description = "Number of days to retain automated backups (1-35)"
  type        = number
  default     = 7
}

variable "aurora_preferred_backup_window" {
  description = "Daily time range during which automated backups are created (UTC)"
  type        = string
  default     = "03:00-04:00"
}

variable "aurora_preferred_maintenance_window" {
  description = "Weekly time range during which system maintenance can occur (UTC)"
  type        = string
  default     = "mon:04:00-mon:05:00"
}

variable "aurora_deletion_protection" {
  description = "Enable deletion protection for the Aurora cluster"
  type        = bool
  default     = true
}

variable "aurora_skip_final_snapshot" {
  description = "Skip final snapshot when destroying the cluster (useful for dev/test)"
  type        = bool
  default     = false
}
