# ─────────────────────────────────────────────
# SSM PARAMETER STORE — secrets
#
# Secrets are fetched directly by EC2 at boot via AWS CLI in user_data.sh.
# Terraform does NOT read secret values — they never appear in Terraform state.
#
# Naming convention: /wordpress/<name>
# Type: SecureString (encrypted at rest with AWS KMS default key — free)
#
# To create parameters before terraform apply:
#   bash scripts/put-ssm-params.sh
# ─────────────────────────────────────────────

# IAM POLICY: allow EC2 instance to read /wordpress/* parameters at boot
# Attached to aws_iam_role.ec2_wordpress (defined in main.tf)

resource "aws_iam_role_policy" "ssm_read_secrets" {
  name = "wordpress-ssm-read-secrets"
  role = aws_iam_role.ec2_wordpress.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWordPressSecrets"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        # Least privilege: only /wordpress/* parameters, nothing else
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/wordpress/*"
      },
      {
        Sid      = "DecryptSSMKMS"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}
