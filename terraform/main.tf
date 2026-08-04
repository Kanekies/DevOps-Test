locals {
  is_dedicated_tier = contains(["enterprise", "regulated"], var.tier)
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

resource "aws_db_instance" "billing" {
  identifier                            = "${local.name_prefix}-billing"
  engine                                = "postgres"
  engine_version                        = "15.7"
  instance_class                        = "db.t3.medium"
  allocated_storage                     = 20
  max_allocated_storage                 = 100
  storage_type                          = "gp3"
  storage_encrypted                     = true
  kms_key_id                            = local.encryption_key_arn
  db_name                               = "billing"
  username                              = var.db_username
  manage_master_user_password           = true
  master_user_secret_kms_key_id         = local.encryption_key_arn
  iam_database_authentication_enabled   = true
  db_subnet_group_name                  = aws_db_subnet_group.main.name
  vpc_security_group_ids                = [aws_security_group.rds.id]
  parameter_group_name                  = aws_db_parameter_group.billing.name
  publicly_accessible                   = false
  multi_az                              = local.is_dedicated_tier
  backup_retention_period               = 35
  backup_window                         = "01:00-02:00"
  maintenance_window                    = "sun:03:00-sun:04:00"
  copy_tags_to_snapshot                 = true
  delete_automated_backups              = false
  deletion_protection                   = true
  skip_final_snapshot                   = false
  final_snapshot_identifier             = "${local.name_prefix}-billing-final"
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = local.encryption_key_arn
  performance_insights_retention_period = 7
  auto_minor_version_upgrade            = true
  apply_immediately                     = false

  tags = {
    Name = "${local.name_prefix}-billing"
  }
}

resource "aws_db_parameter_group" "billing" {
  name        = "${local.name_prefix}-billing"
  family      = "postgres15"
  description = "Hardened PostgreSQL settings for the billing workload"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = {
    Name = "${local.name_prefix}-billing"
  }
}

# --- S3: no encryption, no public access block ---

resource "aws_s3_bucket" "billing_exports" {
  bucket = "${local.name_prefix}-billing-exports-assessment-${random_id.bucket.hex}"
}

resource "random_id" "bucket" {
  byte_length = 4
}

# --- EC2 K3s placeholder node ---

resource "aws_instance" "k3s_node" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.private[0].id
  iam_instance_profile   = aws_iam_instance_profile.k3s_node.name
  vpc_security_group_ids = [aws_security_group.k3s_node.id]

  tags = {
    Name        = "${local.name_prefix}-k3s-node"
    Environment = var.environment
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
