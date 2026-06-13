terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state: S3 bucket + DynamoDB lock table created by bootstrap/
  # Run bootstrap/ once first, then paste the bucket name here.
  # After adding this block, run: terraform init -reconfigure
  backend "s3" {
    bucket         = "tfstate-wordpress-774493573578"
    key            = "wordpress/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ACM certificates for CloudFront MUST be in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# ─────────────────────────────────────────────
# DATA SOURCES
# ─────────────────────────────────────────────

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────────
# NETWORKING: Custom VPC (defined in vpc.tf)
# ─────────────────────────────────────────────
# VPC resources live in vpc.tf.
# References below use aws_vpc.wordpress and aws_subnet.public_a.

# ─────────────────────────────────────────────
# SECURITY GROUP
# ─────────────────────────────────────────────

resource "aws_security_group" "wordpress" {
  name        = "wordpress-sg"
  description = "WordPress EC2: HTTP from anywhere, SSH from anywhere"
  vpc_id      = aws_vpc.wordpress.id

  # HTTP — CloudFront connects over HTTP to origin
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH — restrict to your IP in production; open here for portability
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "wordpress-sg"
    Project = "wordpress-aws"
  }
}

# ─────────────────────────────────────────────
# IAM: EC2 role for CloudWatch Agent + SSM
# ─────────────────────────────────────────────

resource "aws_iam_role" "ec2_wordpress" {
  name = "ec2-wordpress-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = "wordpress-aws"
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_wordpress.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_wordpress.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_wordpress" {
  name = "ec2-wordpress-profile"
  role = aws_iam_role.ec2_wordpress.name
}

# ─────────────────────────────────────────────
# EC2 INSTANCE (Free Tier: t3.micro)
# NOTE: No Elastic IP — public IP changes on stop/start.
#       After each start, update CloudFront origin manually
#       OR use the update-origin.sh helper (see outputs).
# ─────────────────────────────────────────────

resource "aws_instance" "wordpress" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.wordpress.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_wordpress.name

  # Passwords are NOT passed via templatefile — EC2 fetches them from SSM at boot.
  # Only non-sensitive config is templated in.
  user_data = templatefile("${path.module}/user_data.sh", {
    domain_name    = var.domain_name
    db_name        = var.db_name
    db_user        = var.db_user
    wp_admin_user  = var.wp_admin_user
    wp_admin_email = var.wp_admin_email
    aws_region     = var.aws_region
  })

  # Prevent accidental recreation (new user_data = new instance = data loss)
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8   # GiB — stays within Free Tier (30 GiB total)
    delete_on_termination = true
  }

  tags = {
    Name    = "wordpress-server"
    Project = "wordpress-aws"
  }
}

# ─────────────────────────────────────────────
# ACM CERTIFICATE (must be us-east-1 for CloudFront)
# ─────────────────────────────────────────────

resource "aws_acm_certificate" "wordpress" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = [
    "www.${var.domain_name}"
  ]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "wordpress-cert"
    Project = "wordpress-aws"
  }
}

# NOTE: aws_acm_certificate_validation waits until ACM sees the CNAME.
# You must add the CNAME records to Namecheap first (see outputs).
# Terraform will block here until validation succeeds (~2-5 min after DNS propagates).
resource "aws_acm_certificate_validation" "wordpress" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.wordpress.arn
  validation_record_fqdns = [for dvo in aws_acm_certificate.wordpress.domain_validation_options : dvo.resource_record_name]
}

# ─────────────────────────────────────────────
# CLOUDFRONT DISTRIBUTION
# ─────────────────────────────────────────────

resource "aws_cloudfront_distribution" "wordpress" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "WordPress CDN for ${var.domain_name}"
  default_root_object = ""
  aliases             = [var.domain_name, "www.${var.domain_name}"]
  price_class         = "PriceClass_100" # US + Europe only — cheapest

  origin {
    domain_name = aws_instance.wordpress.public_dns
    origin_id   = "wordpress-ec2"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # EC2 listens on HTTP; CloudFront handles HTTPS
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Custom header so WordPress can detect it's behind CloudFront
    custom_header {
      name  = "X-CloudFront-Secret"
      value = "wordpress-origin"
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "wordpress-ec2"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # WordPress requires cookies/query strings for dynamic content
    forwarded_values {
      query_string = true
      headers      = ["Host", "CloudFront-Forwarded-Proto"]

      cookies {
        forward = "whitelist"
        whitelisted_names = [
          "wordpress_*",
          "wp-settings-*",
          "comment_author_*",
          "PHPSESSID"
        ]
      }
    }

    # Low TTL — WordPress is dynamic; static assets handled by WP itself
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 86400
  }

  # Cache static assets longer
  ordered_cache_behavior {
    path_pattern           = "/wp-content/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "wordpress-ec2"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 86400    # 1 day
    max_ttl     = 31536000 # 1 year
  }

  ordered_cache_behavior {
    path_pattern           = "/wp-includes/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "wordpress-ec2"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.wordpress.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name    = "wordpress-cdn"
    Project = "wordpress-aws"
  }

  # Depends on certificate validation completing first
  depends_on = [aws_acm_certificate_validation.wordpress]
}

# ─────────────────────────────────────────────
# CLOUDWATCH LOG GROUPS (pre-create so retention is set)
# ─────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "wordpress_access" {
  name              = "/ec2/wordpress/access"
  retention_in_days = 7

  tags = { Project = "wordpress-aws" }
}

resource "aws_cloudwatch_log_group" "wordpress_error" {
  name              = "/ec2/wordpress/error"
  retention_in_days = 7

  tags = { Project = "wordpress-aws" }
}

resource "aws_cloudwatch_log_group" "user_data" {
  name              = "/ec2/wordpress/user-data"
  retention_in_days = 3

  tags = { Project = "wordpress-aws" }
}

resource "aws_cloudwatch_log_group" "fail2ban" {
  name              = "/ec2/wordpress/fail2ban"
  retention_in_days = 7

  tags = { Project = "wordpress-aws" }
}
