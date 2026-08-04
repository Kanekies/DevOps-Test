data "aws_caller_identity" "current" {}

resource "aws_kms_key" "cell" {
  description             = "Envelope encryption key for cell ${var.environment}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      },
    ]
  })

  tags = {
    Name = "${local.name_prefix}-cmk"
  }
}

resource "aws_kms_alias" "cell" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.cell.key_id
}

locals {
  encryption_key_arn = var.byok_key_arn != "" ? var.byok_key_arn : aws_kms_key.cell.arn
}
