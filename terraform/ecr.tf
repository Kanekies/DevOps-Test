resource "aws_ecr_repository" "billing_service" {
  name                 = "${local.name_prefix}/billing-service"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = local.encryption_key_arn
  }

  tags = {
    Name = "${local.name_prefix}-billing-service"
  }
}
