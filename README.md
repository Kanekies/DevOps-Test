# Acme Platform — Platform Engineering Assessment

Hardening exercise for the Enterprise customer cell `cell-01`, running the `billing-service`
workload, plus the accompanying platform architecture proposal.

| Deliverable | Location |
|---|---|
| Part A — architecture & security design | [`docs/architecture-proposal.md`](docs/architecture-proposal.md) |
| Part B1 — Terraform | [`terraform/`](terraform/) |
| Part B2 — Helm chart | [`charts/billing-service/`](charts/billing-service/) |
| Part B3 — CI/CD | [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) |
| Part B4 — provisioning script | [`scripts/provision-cell.sh`](scripts/provision-cell.sh) |
| Part B5 — security documentation | [`SECURITY.md`](SECURITY.md) |

All names, identifiers and domains are placeholders: `Acme Platform`, `cell-01`,
`platform.example.com`, AWS account `111122223333`.

---

## Repository layout

```
.
├── docs/
│   └── architecture-proposal.md    Part A
├── terraform/
│   ├── versions.tf                 Terraform and provider versions, S3 backend
│   ├── providers.tf                AWS provider, default tags, account guardrail
│   ├── variables.tf                Input variables with validation
│   ├── locals.tf                   Name prefix and common tags
│   ├── network.tf                  VPC, subnets, NAT, routing, endpoints, flow logs
│   ├── kms.tf                      Per-cell customer-managed key, BYOK indirection
│   ├── security-groups.tf          Ingress and egress rules
│   ├── iam.tf                      Roles for CI/CD, the node, support and services
│   ├── ecr.tf                      Container registry with immutable tags
│   ├── rds.tf                      PostgreSQL, parameter group, monitoring role
│   ├── s3.tf                       Export and access-log buckets
│   ├── compute.tf                  AMI lookup and the k3s node
│   ├── outputs.tf                  Stack interface consumed by CI/CD and Helm
│   ├── backends/cell-01.hcl        Remote state configuration for this cell
│   └── envs/cell-01.tfvars         Variable values for this cell
├── charts/billing-service/
│   ├── values.yaml                 Defaults
│   ├── values.production.yaml      Values for cell-01
│   └── templates/                  Deployment, Service, ServiceAccount,
│                                   ExternalSecret, NetworkPolicy
├── scripts/
│   └── provision-cell.sh           Cell provisioning with audit logging
├── .github/workflows/
│   └── deploy.yml                  Static analysis, build, deploy
└── SECURITY.md                     SOC 2 mapping, risks, rotation runbook
```

**File organisation.** Terraform loads every `.tf` file in the directory regardless of name,
so the split is for readers rather than for the tool. Files are grouped by function.
Service-linked IAM roles that exist only to serve one resource — the VPC flow-log role, the
RDS monitoring role — live beside that resource rather than in `iam.tf`, which is reserved for
roles corresponding to principals: humans, CI/CD and workloads.

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | ≥ 1.5.0 | infrastructure |
| Helm | ≥ 3.12 | chart rendering and deployment |
| AWS CLI | v2 | authentication, SSM sessions |
| Checkov | latest | Terraform policy scanning |
| Trivy | latest | configuration and image scanning |
| ShellCheck | latest | script linting |
| Node.js | 22 | dependency audit in CI |

---

## Setup

### Verifying without an AWS account

Everything in this repository can be validated statically. No AWS credentials are required
for any command in this section, and this is how the work was verified — see
[Known limitations](#known-limitations).

```bash
# Terraform — syntax, types and references
cd terraform
terraform fmt -check -recursive
terraform init -backend=false
terraform validate

# Terraform — policy scanning
checkov -d . --compact --quiet

# Helm — chart syntax and rendered manifests
cd ..
helm lint charts/billing-service -f charts/billing-service/values.production.yaml
helm template charts/billing-service -f charts/billing-service/values.production.yaml

# Configuration scanning across Terraform, Helm and the Dockerfile
trivy config .

# Shell script
bash -n scripts/provision-cell.sh
shellcheck scripts/provision-cell.sh
```

`terraform init -backend=false` skips the remote-state connection, and `terraform validate`
resolves types and references without contacting AWS. Data sources and `terraform plan`
require credentials; everything above does not.

### Running against a real account

The state backend must exist before Terraform can use it. In a real deployment a separate
bootstrap stack creates the state bucket, the DynamoDB lock table and the state KMS key,
applied once with local state. That stack is not included here.

```bash
cd terraform
terraform init -backend-config=backends/cell-01.hcl
terraform plan  -var-file=envs/cell-01.tfvars
terraform apply -var-file=envs/cell-01.tfvars
```

One code base serves every cell. Per-cell differences live in two files only —
`backends/<cell>.hcl` (state location) and `envs/<cell>.tfvars` (values). There are no
conditionals naming a specific customer anywhere in the code.

Or through the provisioning script, which adds argument validation and audit logging:

```bash
./scripts/provision-cell.sh --customer-id acme-corp --aws-region eu-central-1 --tier enterprise
./scripts/provision-cell.sh --customer-id acme-corp --aws-region eu-central-1 --tier enterprise --dry-run
```

Parameters may also be supplied as environment variables:

```bash
CUSTOMER_ID=acme-corp AWS_REGION=eu-central-1 TIER=enterprise ./scripts/provision-cell.sh
```

### Enabling the deployment pipeline

The build and deploy jobs are skipped until the cell's deploy role exists. To enable them,
set these repository variables from the Terraform outputs:

| Variable | Source |
|---|---|
| `CELL_01_DEPLOY_ROLE_ARN` | `terraform output cicd_deploy_role_arn` |
| `CELL_01_INSTANCE_ID` | `terraform output k3s_node_instance_id` |

A GitHub Environment named `cell-01` must also exist with required reviewers configured.
That name is not cosmetic: the AWS trust policy pins the OIDC `sub` claim to
`repo:<owner>/<repo>:environment:cell-01`, so obtaining AWS credentials for this cell is
only possible through a workflow that has passed the environment's approval gate. The
approval in GitHub and the permission in AWS cannot drift apart.

---

## What was changed

### Terraform

| Area | Before | After |
|---|---|---|
| Identity | Shared IAM user with `AdministratorAccess` | User removed. GitHub OIDC for CI/CD, instance profile for the node, MFA-gated read-only role for support |
| Network topology | Two subnets in one availability zone | Three availability zones, public and private subnets per zone, NAT per zone, per-zone private route tables |
| Node placement | Public subnet with an auto-assigned public IP | Private subnet, no public address |
| SSH | Port 22 open to `0.0.0.0/0` | No rule at all — access via SSM Session Manager |
| Kubernetes API | Port 6443 open to `0.0.0.0/0` | VPC-internal only, reached by SSM port forwarding |
| Database access | Any source inside the VPC | Only the node's security group, by security-group reference |
| Egress | All protocols to any destination | TCP 443, PostgreSQL and DNS only |
| AWS service traffic | Through NAT to the public internet | VPC endpoints — gateway for S3, interface for ECR, KMS, Secrets Manager, SSM, Logs and STS |
| Encryption keys | None; AWS-managed keys throughout | Per-cell customer-managed key with annual rotation, BYOK indirection for the Regulated tier |
| RDS | Unencrypted, no backups, no deletion protection, single-AZ | Encrypted with the cell key, 35-day PITR, Multi-AZ for dedicated tiers, deletion protection, mandatory final snapshot, `force_ssl`, IAM authentication, audit logging |
| S3 | No public access block, no versioning, no encryption, no logging | Four-flag public access block, ACLs disabled, versioning, SSE-KMS with bucket key, access logging to a separate bucket, lifecycle rules, explicit deny on non-TLS requests |
| EC2 | IMDSv1 permitted, unencrypted root volume, no IAM role | IMDSv2 required with hop limit 1, encrypted `gp3` root volume, instance profile attached |
| Observability | None | VPC Flow Logs at `ALL` with 60-second aggregation, encrypted log group, 365-day retention |
| State | Local file | S3 backend with encryption, versioning and DynamoDB locking |
| Guardrails | None | `allowed_account_ids`, `default_tags`, variable validation, default security group emptied |

### Helm chart

Secrets are delivered through `secretKeyRef` sourced from Secrets Manager by the External
Secrets Operator; no credential passes through `values.yaml`. Pods run with
`runAsNonRoot`, a read-only root filesystem, all Linux capabilities dropped, no privilege
escalation and the `RuntimeDefault` seccomp profile. Resource requests and limits are set,
which in a multi-tenant platform is an isolation control rather than a tuning detail. Startup,
readiness and liveness probes are all defined — the startup probe prevents the liveness
probe from killing a slow-starting container before it is ready. A `NetworkPolicy` restricts
ingress to the `api-gateway` namespace and egress to DNS, PostgreSQL and HTTPS, with the
EC2 metadata address explicitly excluded. `values.production.yaml` sets
`DB_SSL_MODE=verify-full`, which validates the server certificate and therefore defends
against redirection as well as interception.

### CI/CD

Authentication uses GitHub OIDC with no stored AWS keys. Static analysis runs a dependency
audit, Trivy configuration scanning and Helm linting. The image is scanned by Trivy and the
run fails on critical findings **before** the push, so a vulnerable artefact never reaches the
registry. Deployment reaches the private Kubernetes API through an SSM tunnel and runs
`helm upgrade --atomic`, which rolls back automatically on failure.

---

## Verification results

Run `checkov -d terraform/ --compact` and `trivy config .` to reproduce.

| | Starting point | Current |
|---|---|---|
| Checkov failed | 31 | 0 |
| Checkov passed | 30 | 172 |
| Checkov skipped with justification | 0 | 6 |
| Trivy critical | 1 | 0 (1 suppressed with justification) |

Every suppression carries an inline justification in the code and is listed in
[`SECURITY.md`](SECURITY.md). Suppressions were used only where a generic rule conflicts
with a stated requirement of this scenario, or where the scanner cannot evaluate a computed
value — for example, Checkov reports Multi-AZ as disabled because it does not evaluate the
`contains()` call that enables it for dedicated tiers.

---

## Known limitations

Nothing in this repository has been applied to a live AWS account. No account was available
for the exercise, so verification was static throughout: `terraform validate` for syntax,
types and references; Checkov and Trivy for policy; `helm template` for rendered manifests;
ShellCheck for the script. Static analysis catches misconfiguration but not runtime behaviour
— IAM policies that are too narrow, service quotas and eventual-consistency issues surface
only on `apply`.

### Deliberate divergences from the architecture proposal

| Area | Proposal | Repository | Reason |
|---|---|---|---|
| Control plane | Managed EKS, private endpoint, multi-AZ | Single-node k3s on EC2 | The starter repository supplies k3s as a control-plane placeholder. It was hardened rather than replaced, since changing the platform is outside the exercise. The cost is real: one node is a single point of failure and cannot be patched without downtime, which is incompatible with the 1-hour RTO the Enterprise tier promises |
| Workload identity | IRSA | EC2 instance profile | IRSA requires EKS. The instance profile is the equivalent mechanism for this topology — in both cases no static credential exists on the machine |
| Egress filtering | AWS Network Firewall with an FQDN allow-list | Security groups narrowed to TCP 443, 5432 and DNS | Security groups match IP ranges, not domain names, so a hostname allow-list cannot be expressed in one. The narrowing is implemented; domain-level filtering is designed but not deployed. Tracked as a residual risk in `SECURITY.md` |
| Log storage | Separate `log-archive` account with S3 Object Lock | CloudWatch and S3 inside the cell account | Cross-account archiving needs an AWS Organization that does not exist in this exercise. A principal with sufficient privileges in the cell account could currently alter evidence. Tracked as a residual risk |
| Event backbone | EventBridge and SQS between domains | Not present | The starter repository contains one service; the backbone is a platform-level concern outside its scope |
| Redis | ElastiCache for cache and pub/sub | Not present | Same reason |

### Other gaps

- **State backend bootstrap.** `backends/cell-01.hcl` assumes the state bucket, lock table
  and KMS key already exist. The bootstrap stack that creates them is described but not
  included.
- **OIDC provider placement.** `aws_iam_openid_connect_provider` is an account-level
  resource created here by the cell stack. In a real platform it belongs to an
  organisation-level stack, since only one may exist per account.
- **Load balancer.** No ALB is defined — the starter repository exposed the node directly.
  The security group for it exists because it defines the ingress model and is referenced by
  the node's ingress rule, which is what allows that rule to name a role rather than an
  address range.
- **`ReadOnlyAccess` for support.** The AWS managed policy prevents modification but permits
  reading more than a support engineer needs. A purpose-built policy is described in
  `SECURITY.md`.
- **NetworkPolicy enforcement.** k3s enforces network policies through its bundled
  kube-router. On a cluster without a policy-capable CNI, the policy is accepted and silently
  ignored.
- **Placeholder values.** `values.production.yaml` and `envs/cell-01.tfvars` contain
  placeholders where real endpoints, ARNs and account identifiers would go. In practice these
  are populated from `terraform output` during provisioning.
- **Query logging.** PostgreSQL `log_statement` is set to `ddl` rather than `all`. Logging
  every statement would place customer personal data into CloudWatch under a different
  retention policy and a different access boundary than the data itself, which conflicts with
  GDPR data minimisation. Structural changes, connections and slow queries are logged;
  full data-access auditing belongs to `pgaudit`, which records the event without the values.

---

## Notes for reviewers

**Where the reasoning lives.** `SECURITY.md` holds the SOC 2 control mapping, the residual
risk register, the suppression list with justifications and the credential rotation runbook.
`docs/architecture-proposal.md` holds the platform design, and its Appendix A maps each
divergence between the design and this repository.

**On the suppressions.** A scanner report with zero findings and zero explanations usually
means the findings were removed rather than resolved. Each suppression here names the check,
the resource and the reason, in a comment beside the code it applies to, so the decision
remains reviewable after the person who made it has moved on.

**On what is missing.** The gaps above are listed because they are the questions a reviewer
would ask. Where something was not built, the reason is either that it lies outside the
starter repository's scope or that it conflicts with another stated requirement — not that it
was overlooked.
