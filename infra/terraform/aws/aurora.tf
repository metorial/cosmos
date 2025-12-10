# DB Subnet Group for Aurora
resource "aws_db_subnet_group" "aurora" {
  name       = "${local.cluster_name}-aurora-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-aurora-subnet-group"
  })
}

# Security Group for Aurora
resource "aws_security_group" "aurora" {
  name        = "${local.cluster_name}-aurora-sg"
  description = "Security group for Aurora PostgreSQL cluster"
  vpc_id      = aws_vpc.main.id

  # PostgreSQL access from VPC
  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-aurora-sg"
  })
}

# Random password for Aurora master user
resource "random_password" "aurora_master_password" {
  length  = 32
  special = true
}

# Aurora PostgreSQL Cluster
resource "aws_rds_cluster" "aurora" {
  cluster_identifier     = "${local.cluster_name}-aurora-cluster"
  engine                 = "aurora-postgresql"
  engine_version         = var.aurora_engine_version
  database_name          = var.aurora_database_name
  master_username        = var.aurora_master_username
  master_password        = random_password.aurora_master_password.result
  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  backup_retention_period      = var.aurora_backup_retention_period
  preferred_backup_window      = var.aurora_preferred_backup_window
  preferred_maintenance_window = var.aurora_preferred_maintenance_window

  enabled_cloudwatch_logs_exports = ["postgresql"]
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.vault.arn

  deletion_protection       = var.aurora_deletion_protection
  skip_final_snapshot       = var.aurora_skip_final_snapshot
  final_snapshot_identifier = var.aurora_skip_final_snapshot ? null : "${local.cluster_name}-aurora-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-aurora-cluster"
  })

  lifecycle {
    ignore_changes = [
      final_snapshot_identifier,
    ]
  }
}

# Aurora Writer Instance
resource "aws_rds_cluster_instance" "aurora_writer" {
  identifier         = "${local.cluster_name}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_enhanced_monitoring.arn

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-aurora-writer"
    Role = "writer"
  })
}

# Aurora Read Replicas
resource "aws_rds_cluster_instance" "aurora_reader" {
  count = var.aurora_replica_count

  identifier         = "${local.cluster_name}-aurora-reader-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_enhanced_monitoring.arn

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-aurora-reader-${count.index + 1}"
    Role = "reader"
  })
}

# IAM Role for RDS Enhanced Monitoring
resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${local.cluster_name}-rds-enhanced-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-rds-enhanced-monitoring-role"
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Store master password in AWS Secrets Manager for emergency access
resource "aws_secretsmanager_secret" "aurora_master_password" {
  name                    = "${local.cluster_name}-aurora-master-password"
  description             = "Master password for Aurora PostgreSQL cluster (emergency use only - use Vault for application access)"
  recovery_window_in_days = 30

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-aurora-master-password"
  })
}

resource "aws_secretsmanager_secret_version" "aurora_master_password" {
  secret_id = aws_secretsmanager_secret.aurora_master_password.id
  secret_string = jsonencode({
    username            = var.aurora_master_username
    password            = random_password.aurora_master_password.result
    engine              = "postgres"
    host                = aws_rds_cluster.aurora.endpoint
    reader_endpoint     = aws_rds_cluster.aurora.reader_endpoint
    port                = aws_rds_cluster.aurora.port
    dbname              = var.aurora_database_name
    dbClusterIdentifier = aws_rds_cluster.aurora.cluster_identifier
  })
}
