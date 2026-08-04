resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "${local.name_prefix}-github-oidc"
  }
}

resource "aws_iam_role" "cicd_deploy" {
  name                 = "${local.name_prefix}-cicd-deploy"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGitHubActionsForThisCell"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${var.environment}"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-cicd-deploy"
  }
}

resource "aws_iam_role_policy" "cicd_deploy" {
  name = "${local.name_prefix}-cicd-deploy"
  role = aws_iam_role.cicd_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuthenticateToRegistry"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushImagesToThisRepositoryOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.billing_service.arn
      },
      {
        Sid    = "OpenTunnelToTheCellNode"
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.k3s_node.id}",
          "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "k3s_node" {
  name = "${local.name_prefix}-k3s-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2ToAssume"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-k3s-node"
  }
}

resource "aws_iam_instance_profile" "k3s_node" {
  name = "${local.name_prefix}-k3s-node"
  role = aws_iam_role.k3s_node.name
}

resource "aws_iam_role_policy_attachment" "k3s_node_ssm" {
  role       = aws_iam_role.k3s_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "k3s_node" {
  name = "${local.name_prefix}-k3s-node"
  role = aws_iam_role.k3s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuthenticateToRegistry"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PullImagesFromThisRepositoryOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.billing_service.arn
      },
      {
        Sid      = "ReadTheDatabaseSecretOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_db_instance.billing.master_user_secret[0].secret_arn
      },
      {
        Sid    = "UseTheCellKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = local.encryption_key_arn
      },
      {
        Sid    = "WriteExportsToTheCellBucketOnly"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.billing_exports.arn,
          "${aws_s3_bucket.billing_exports.arn}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "support_readonly" {
  name                 = "${local.name_prefix}-support-readonly"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowFederatedHumansWithMFA"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          Bool = {
            "aws:MultiFactorAuthPresent" = "true"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-support-readonly"
  }
}

resource "aws_iam_role_policy_attachment" "support_readonly" {
  role       = aws_iam_role.support_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
