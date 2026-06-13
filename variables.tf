variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Root domain (e.g. javari.cc)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type — t3.micro is Free Tier eligible in this account (us-east-1)"
  type        = string
  default     = "t3.micro"
}

variable "key_pair_name" {
  description = "Name of existing EC2 Key Pair for SSH access"
  type        = string
}

variable "db_name" {
  description = "MySQL database name for WordPress"
  type        = string
  default     = "wordpress"
}

variable "db_user" {
  description = "MySQL username for WordPress"
  type        = string
  default     = "wpuser"
}

variable "wp_admin_user" {
  description = "WordPress admin username"
  type        = string
  default     = "bahasaki"
}

variable "wp_admin_email" {
  description = "WordPress admin email"
  type        = string
}

# ─────────────────────────────────────────────
# NO MORE sensitive password variables here.
# Passwords live in SSM Parameter Store.
# See: scripts/put-ssm-params.sh
# ─────────────────────────────────────────────
