#!/bin/bash
# =============================================================================
# put-ssm-params.sh
# Run ONCE before terraform apply to store secrets in SSM Parameter Store.
# After this, secrets never appear in tfvars, Terraform state, or Git.
# =============================================================================
set -euo pipefail

REGION="${1:-us-east-1}"

echo "This script will store WordPress secrets in AWS SSM Parameter Store."
echo "Region: $REGION"
echo ""
echo "Parameters will be stored as SecureString (encrypted with AWS KMS)."
echo "Cost: SSM Standard parameters are FREE. KMS uses the AWS managed key (free)."
echo ""

# ─────────────────────────────────────────────
# Prompt for secrets (input hidden with -s)
# ─────────────────────────────────────────────

read -rsp "Enter DB password (for MySQL wpuser): " DB_PASSWORD
echo ""

read -rsp "Confirm DB password: " DB_PASSWORD_CONFIRM
echo ""

if [ "$DB_PASSWORD" != "$DB_PASSWORD_CONFIRM" ]; then
  echo "ERROR: Passwords do not match." >&2
  exit 1
fi

read -rsp "Enter WordPress admin password: " WP_ADMIN_PASSWORD
echo ""

read -rsp "Confirm WordPress admin password: " WP_ADMIN_PASSWORD_CONFIRM
echo ""

if [ "$WP_ADMIN_PASSWORD" != "$WP_ADMIN_PASSWORD_CONFIRM" ]; then
  echo "ERROR: Passwords do not match." >&2
  exit 1
fi

# ─────────────────────────────────────────────
# Write to SSM (--overwrite allows re-running safely)
# ─────────────────────────────────────────────

echo ""
echo "Storing parameters in SSM..."

aws ssm put-parameter \
  --name "/wordpress/db_password" \
  --value "$DB_PASSWORD" \
  --type "SecureString" \
  --description "WordPress MySQL database password" \
  --overwrite \
  --region "$REGION" \
  --no-cli-pager

echo "  [OK] /wordpress/db_password stored"

aws ssm put-parameter \
  --name "/wordpress/wp_admin_password" \
  --value "$WP_ADMIN_PASSWORD" \
  --type "SecureString" \
  --description "WordPress admin panel password" \
  --overwrite \
  --region "$REGION" \
  --no-cli-pager

echo "  [OK] /wordpress/wp_admin_password stored"

# ─────────────────────────────────────────────
# Verify (show names only, not values)
# ─────────────────────────────────────────────

echo ""
echo "Verifying parameters exist in SSM..."

aws ssm describe-parameters \
  --filters "Key=Name,Values=/wordpress/" \
  --region "$REGION" \
  --no-cli-pager \
  --query "Parameters[].{Name:Name,Type:Type,LastModified:LastModifiedDate}" \
  --output table

echo ""
echo "Done. You can now run: terraform apply"
echo ""
echo "To delete secrets after terraform destroy:"
echo "  aws ssm delete-parameter --name /wordpress/db_password --region $REGION"
echo "  aws ssm delete-parameter --name /wordpress/wp_admin_password --region $REGION"
