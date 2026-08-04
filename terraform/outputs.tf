# --- сеть ---

output "vpc_id" {
  description = "ID of the cell VPC"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnets where workloads and data stores run"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnets holding the load balancer and NAT gateways"
  value       = aws_subnet.public[*].id
}

# --- база данных ---

output "rds_endpoint" {
  description = "Connection endpoint for the billing PostgreSQL instance"
  value       = aws_db_instance.billing.endpoint
}

output "rds_arn" {
  description = "ARN of the billing PostgreSQL instance"
  value       = aws_db_instance.billing.arn
}

output "rds_master_secret_arn" {
  description = "Secrets Manager ARN holding the AWS-managed master password"
  value       = aws_db_instance.billing.master_user_secret[0].secret_arn
  sensitive   = true
}

# --- объектное хранилище ---

output "billing_exports_bucket_arn" {
  description = "ARN of the billing exports bucket"
  value       = aws_s3_bucket.billing_exports.arn
}

output "billing_exports_bucket_name" {
  description = "Name of the billing exports bucket"
  value       = aws_s3_bucket.billing_exports.bucket
}

output "access_logs_bucket_arn" {
  description = "ARN of the S3 server access log bucket"
  value       = aws_s3_bucket.access_logs.arn
}

# --- шифрование ---

output "kms_key_arn" {
  description = "Encryption key used by every resource in this cell"
  value       = local.encryption_key_arn
}

# --- реестр образов ---

output "ecr_repository_url" {
  description = "Registry URL used by CI/CD to push and by the node to pull"
  value       = aws_ecr_repository.billing_service.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the billing-service container repository"
  value       = aws_ecr_repository.billing_service.arn
}

# --- роли IAM ---

output "cicd_deploy_role_arn" {
  description = "Role assumed by GitHub Actions through OIDC federation"
  value       = aws_iam_role.cicd_deploy.arn
}

output "k3s_node_role_arn" {
  description = "Role attached to the k3s node through its instance profile"
  value       = aws_iam_role.k3s_node.arn
}

output "support_readonly_role_arn" {
  description = "Read-only role for customer support, scoped to this cell only"
  value       = aws_iam_role.support_readonly.arn
}

# --- цель для SSM ---

output "k3s_node_instance_id" {
  description = "Instance ID used as the target for SSM sessions and port forwarding"
  value       = aws_instance.k3s_node.id
}
