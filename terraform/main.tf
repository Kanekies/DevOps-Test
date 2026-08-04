# --- RDS: missing storage_encrypted ---

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-db"
  }
}

resource "aws_db_instance" "billing" {
  identifier                  = "${local.name_prefix}-billing-db"
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  db_name                     = "billing"
  username                    = var.db_username
  manage_master_user_password = true
  skip_final_snapshot         = false
  db_subnet_group_name        = aws_db_subnet_group.main.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  publicly_accessible         = false
  deletion_protection         = true
  # INTENTIONALLY MISSING: storage_encrypted = true
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
