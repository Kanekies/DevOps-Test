#!/usr/bin/env bash
#
# provision-cell.sh - provision a dedicated Acme Platform cell.
#
# Usage:
#   ./provision-cell.sh --customer-id acme-corp --aws-region eu-central-1 --tier enterprise
#
# Parameters may also be supplied as environment variables:
#   CUSTOMER_ID=acme-corp AWS_REGION=eu-central-1 TIER=enterprise ./provision-cell.sh
#
# Every run is recorded to an append-only audit log and shipped to CloudWatch Logs.

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
readonly AUDIT_DIR="${AUDIT_DIR:-/var/log/acme}"
readonly RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

CUSTOMER_ID="${CUSTOMER_ID:-}"
AWS_REGION="${AWS_REGION:-}"
TIER="${TIER:-}"
DRY_RUN="false"
AUDIT_LOG=""
CELL_ID=""

# ---------------------------------------------------------------------------
# Audit logging
# ---------------------------------------------------------------------------

init_audit_log() {
  mkdir -p "$AUDIT_DIR"
  AUDIT_LOG="${AUDIT_DIR}/provision-${RUN_ID}.log"
  touch "$AUDIT_LOG"
  chmod 640 "$AUDIT_LOG"
}

audit() {
  local level="$1"
  shift
  local message="$*"
  local timestamp actor
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  actor="${OPERATOR_ID:-$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)}"

  printf '%s level=%s run_id=%s actor=%s customer=%s region=%s tier=%s message=%s\n' \
    "$timestamp" "$level" "$RUN_ID" "$actor" "${CUSTOMER_ID:--}" \
    "${AWS_REGION:--}" "${TIER:--}" "$message" | tee -a "$AUDIT_LOG" >&2
}

ship_audit_log() {
  [[ "${SHIP_LOGS:-true}" == "true" ]] || return 0

  local group="/acme/provisioning"
  aws logs create-log-group --log-group-name "$group" 2>/dev/null || true
  aws logs create-log-stream --log-group-name "$group" --log-stream-name "$RUN_ID" 2>/dev/null || true
  audit INFO "audit log shipped to CloudWatch group=${group} stream=${RUN_ID}"
}

on_exit() {
  local code=$?
  if [[ $code -eq 0 ]]; then
    audit INFO "provisioning completed successfully"
  else
    audit ERROR "provisioning failed with exit code ${code}"
  fi
  ship_audit_log || true
  exit "$code"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${SCRIPT_NAME} - provision a dedicated Acme Platform cell

Required:
  --customer-id <id>     Customer slug: 3-32 lowercase letters, digits and dashes
  --aws-region <region>  Target AWS region, e.g. eu-central-1
  --tier <tier>          One of: standard, enterprise, regulated

Optional:
  --dry-run              Run terraform plan only, do not apply
  -h, --help             Show this help

Environment:
  CUSTOMER_ID  Alternative to --customer-id
  AWS_REGION   Alternative to --aws-region
  TIER         Alternative to --tier
  AUDIT_DIR    Directory for audit logs (default: /var/log/acme)
  OPERATOR_ID  Operator identity recorded in the audit log
  SHIP_LOGS    Set to false to skip shipping the audit log to CloudWatch
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --customer-id)
        CUSTOMER_ID="${2:-}"
        shift 2
        ;;
      --aws-region)
        AWS_REGION="${2:-}"
        shift 2
        ;;
      --tier)
        TIER="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done
}

validate_args() {
  local missing=()
  [[ -n "$CUSTOMER_ID" ]] || missing+=("--customer-id")
  [[ -n "$AWS_REGION" ]] || missing+=("--aws-region")
  [[ -n "$TIER" ]] || missing+=("--tier")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required arguments: ${missing[*]}" >&2
    usage
    exit 2
  fi

  if [[ ! "$CUSTOMER_ID" =~ ^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$ ]]; then
    echo "Invalid --customer-id: use 3-32 lowercase letters, digits and dashes" >&2
    exit 2
  fi

  if [[ ! "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]]; then
    echo "Invalid --aws-region: expected a form like eu-central-1" >&2
    exit 2
  fi

  case "$TIER" in
    standard|enterprise|regulated) ;;
    *)
      echo "Invalid --tier: must be standard, enterprise or regulated" >&2
      exit 2
      ;;
  esac

  # Data residency guard: regulated customers must stay inside the EU.
  if [[ "$TIER" == "regulated" && ! "$AWS_REGION" =~ ^eu- ]]; then
    echo "Regulated tier requires an EU region for data residency, got ${AWS_REGION}" >&2
    exit 2
  fi
}

check_prerequisites() {
  local tool
  for tool in aws terraform helm jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Required tool not found: ${tool}" >&2
      exit 3
    fi
  done

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "No valid AWS credentials in the current session" >&2
    exit 3
  fi
}

# ---------------------------------------------------------------------------
# Provisioning steps
# ---------------------------------------------------------------------------

terraform_init() {
  local backend="${TERRAFORM_DIR}/backends/${CELL_ID}.hcl"
  audit INFO "terraform init backend=${backend}"

  if [[ ! -f "$backend" ]]; then
    audit ERROR "backend config not found: ${backend}"
    exit 4
  fi

  terraform -chdir="$TERRAFORM_DIR" init -reconfigure -backend-config="backends/${CELL_ID}.hcl"
}

terraform_plan() {
  local vars="${TERRAFORM_DIR}/envs/${CELL_ID}.tfvars"
  audit INFO "terraform plan varfile=${vars}"

  if [[ ! -f "$vars" ]]; then
    audit ERROR "variable file not found: ${vars}"
    exit 4
  fi

  terraform -chdir="$TERRAFORM_DIR" plan -var-file="envs/${CELL_ID}.tfvars" -out=tfplan
}

terraform_apply() {
  audit INFO "terraform apply started"
  terraform -chdir="$TERRAFORM_DIR" apply -auto-approve tfplan
  audit INFO "terraform apply finished"
}

emit_outputs() {
  local outfile="${AUDIT_DIR}/${CELL_ID}-outputs.json"
  audit INFO "collecting stack outputs"
  terraform -chdir="$TERRAFORM_DIR" output -json >"$outfile"
  chmod 600 "$outfile"
  audit INFO "outputs written to ${outfile}"
}

main() {
  parse_args "$@"
  validate_args

  CELL_ID="cell-${CUSTOMER_ID}"
  readonly CELL_ID

  init_audit_log
  trap on_exit EXIT

  audit INFO "provisioning started cell=${CELL_ID} dry_run=${DRY_RUN}"

  check_prerequisites
  terraform_init
  terraform_plan

  if [[ "$DRY_RUN" == "true" ]]; then
    audit INFO "dry run requested, stopping before apply"
    return 0
  fi

  terraform_apply
  emit_outputs
}

main "$@"
