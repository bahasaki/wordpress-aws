terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Bootstrap intentionally uses LOCAL state —
  # it creates the remote backend that everything else will use.
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────
# S3 BUCKET — stores terraform.tfstate
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "tfstate" {
  # Account ID in name guarantees global uniqueness
  bucket = "tfstate-wordpress-${data.aws_caller_identity.current.account_id}"

  # Prevent accidental deletion of state
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "terraform-state"
    Project = "wordpress-aws"
  }
}

# Block all public access — state contains secrets
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning — allows rollback to previous state
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest with AES-256
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ─────────────────────────────────────────────
# DYNAMODB TABLE — state locking
# Prevents two engineers (or two CI jobs) from
# running terraform apply simultaneously and corrupting state.
# ─────────────────────────────────────────────

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST" # Free Tier: 25 WCU/RCU free; this stays well within it
  hash_key     = "LockID"          # Required field name — Terraform expects exactly "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Protect from accidental deletion
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "terraform-state-lock"
    Project = "wordpress-aws"
  }
}
