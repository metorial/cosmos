terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "cosmos/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "cosmos"
      Environment = var.environment
      ManagedBy   = "terraform"
      Cluster     = var.cluster_name
    }
  }
}

locals {
  cluster_name = var.cluster_name
  common_tags = {
    Name = var.cluster_name
  }
}
