# Security overview — Acme Platform cell cell-01

Scope: the hardening work applied to the dedicated Enterprise cell cell-01
running the billing-service workload. The full platform design is in
[docs/architecture-proposal.md](docs/architecture-proposal.md).

---

## 1. SOC 2 control mapping

### CC6.1 — Logical access is restricted to authorised users

| Control | Implementation | Evidence |
|---|---|---|
| No long-lived credentials | Shared IAM user with AdministratorAccess removed. Humans authenticate through IAM Identity Center with MFA; CI/CD uses GitHub OIDC federation; workloads use an EC2 instance profile. | terraform/iam.tf, CloudTrail AssumeRole* events |
| Least privilege | CI/CD may push images but not pull; the node may pull but not push. Secret access is scoped to one secret ARN, KMS access to two actions. | terraform/iam.tf role policies |
| Network segmentation | Security groups reference other security groups rather than CIDR ranges. The database accepts connections only from the node group. SSH is not open to anyone. | terraform/security-groups.tf |
| Workload segmentation | Kubernetes NetworkPolicy allows ingress only from the api-gateway namespace and egress only to DNS, PostgreSQL and HTTPS. | charts/billing-service/templates/networkpolicy.yaml |
| Access review evidence | S3 server access logging, RDS connection logging, VPC Flow Logs. | CloudWatch log groups, *-access-logs bucket |

### CC7.2 — System monitoring detects anomalies

| Control | Implementation | Evidence |
|---|---|---|
| Network telemetry | VPC Flow Logs, traffic type ALL, 60-second aggregation, 365-day retention. | /aws/vpc/acme-cell-01/flow-logs |
| Database telemetry | PostgreSQL logs exported to CloudWatch; connections and disconnections recorded; Enhanced Monitoring and Performance Insights enabled. | RDS log exports |
| Image telemetry | ECR scan-on-push; Trivy fails the pipeline on CRITICAL findings. | GitHub Actions run history |
| Infrastructure telemetry | Checkov runs against the Terraform directory; suppressions carry inline justifications. | checkov -d terraform/ |

### CC8.1 — Changes are authorised, tested and documented

| Control | Implementation | Evidence |
|---|---|---|
| Infrastructure as code | All infrastructure is declared in Terraform; state is stored in an encrypted, versioned S3 bucket with DynamoDB locking. | terraform/, backends/cell-01.hcl |
| Change authorisation | Deployment runs against the cell-01 GitHub Environment with required reviewers. The AWS trust policy pins the OIDC sub claim to that exact repository and environment, so AWS access is bound to the approval. | .github/workflows/deploy.yml, terraform/iam.tf |
| Immutable artefacts | ECR tag mutability is IMMUTABLE; an approved image cannot be replaced under the same tag. | terraform/ecr.tf |
| Safe rollout | helm upgrade --atomic --wait rolls back automatically on failure; RollingUpdate with maxUnavailable: 0. | .github/workflows/deploy.yml |
| Schema change audit | PostgreSQL log_statement = ddl records every structural change. | RDS parameter group |

---

## 2. Top 5 residual risks

### R1 — Single-node k3s control plane
Likelihood medium · Impact high

The starter repository provisions one EC2 instance running k3s. The node is a
single point of failure and cannot be patched without downtime, which conflicts
with the 2-hour RTO promised for the Enterprise tier.

*Mitigation:* migrate to managed EKS with a multi-AZ control plane and managed
node groups. Kept as-is here because replacing the platform was out of scope for
this exercise; the target design is described in the architecture document.

### R2 — Egress filtering is port-based, not domain-based
Likelihood medium · Impact high

Security groups match on IP ranges, so outbound traffic can be narrowed to
port 443 but not to an allow-list of destinations. A compromised workload could
still exfiltrate data to an arbitrary host over HTTPS.
*Mitigation:* AWS Network Firewall with FQDN filtering in front of the NAT
gateways. VPC endpoints already keep AWS-service traffic off the internet, which
reduces the volume passing through the uncontrolled path.

### R3 — Logs live in the same account as the workload
Likelihood low · Impact high

Flow logs, access logs and database logs are written inside the cell account. A
principal with sufficient privileges in that account could alter or delete
evidence, weakening the CC7 control set.

*Mitigation:* forward all logs to a dedicated log-archive account with S3
Object Lock in compliance mode, so retention cannot be shortened by anyone,
including the account root.

### R4 — ReadOnlyAccess is broader than customer support needs
Likelihood medium · Impact medium

The support role uses the AWS managed ReadOnlyAccess policy. It prevents any
modification, but it permits reading a wider set of resources than a support
engineer requires.

*Mitigation:* replace with a purpose-built policy limited to pod status, service
health and application logs, explicitly denying s3:GetObject on the exports
bucket and secretsmanager:GetSecretValue.

### R5 — No cross-region backup for the Regulated tier
Likelihood low · Impact high

Backups are retained in-region only. A prolonged regional failure would exceed
the recovery objectives stated for the Regulated tier.

*Mitigation:* AWS Backup copy jobs to a second EU region (eu-west-1) with a
region-local KMS key. Cross-region replication was deliberately left disabled —
and the corresponding Checkov finding suppressed with justification — because an
unscoped replication rule would violate the EU-only data-residency requirement.

---

## 3. Suppressed findings

All suppressions are inline in the code with a justification string.

| Check | Resource | Justification |
|---|---|---|
| CKV_AWS_157 | aws_db_instance.billing | False positive: Multi-AZ is enabled for dedicated tiers via local.is_dedicated_tier; Checkov does not evaluate contains(). |
| CKV_AWS_144 | both buckets | Cross-region replication is intentionally disabled for data residency; see R5. |
| CKV_AWS_18 | aws_s3_bucket.access_logs | The log target cannot log to itself without creating recursion. |
| CKV2_AWS_62 | both buckets | Event notifications are an integration feature, not a security control here. |
| CKV2_AWS_5 | aws_security_group.alb | The load balancer is out of scope; the group defines the ingress model and is referenced by the node group rule. |
| CKV_AWS_126 | aws_instance.k3s_node | Detailed monitoring is redundant for a placeholder single node. |

---

## 4. Credential rotation runbook

### 4.1 Rotation schedule

| Credential | Mechanism | Interval | Owner |
|---|---|---|---|
| RDS master password | Secrets Manager managed rotation | 30 days | automatic |
| KMS key material | KMS automatic key rotation | 365 days | automatic |
| CI/CD credentials | none exist — OIDC issues a token per run | every run | automatic |
| Workload credentials | instance profile, refreshed by the metadata service | ~1 hour | automatic |
| Human sessions | IAM Identity Center | 1 hour | automatic |
| TLS certificates | ACM managed renewal | 60 days before expiry | automatic |

Every credential in the cell rotates without a manual procedure. This is a design
property, not an operational discipline: nothing on the list depends on someone
remembering to act.

### 4.2 Emergency rotation — suspected compromise

1. Contain. Detach the affected IAM policy or disable the KMS key. Do not
   schedule key deletion — disabling is reversible, deletion is not.
2. Rotate. Force rotation of the database secret:
