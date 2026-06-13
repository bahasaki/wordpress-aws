# ─────────────────────────────────────────────
# STEP 1 — Add these CNAMEs to Namecheap BEFORE running terraform apply
# (ACM won't validate until DNS exists)
# ─────────────────────────────────────────────

output "acm_dns_validation_records" {
  description = <<-EOT
    Add these CNAME records to Namecheap Advanced DNS.
    Do this BEFORE running `terraform apply` (or right when Terraform pauses waiting for validation).
    Namecheap strips the root domain from the Host field — see the 'namecheap_host' value.
  EOT
  value = {
    for dvo in aws_acm_certificate.wordpress.domain_validation_options : dvo.domain_name => {
      namecheap_host  = replace(dvo.resource_record_name, ".${var.domain_name}.", "")
      type            = dvo.resource_record_type
      value           = trimsuffix(dvo.resource_record_value, ".")
      ttl             = "300"
    }
  }
}

# ─────────────────────────────────────────────
# STEP 2 — After apply, add these A/CNAME records to Namecheap
# ─────────────────────────────────────────────

output "namecheap_dns_records" {
  description = <<-EOT
    Add these records to Namecheap Advanced DNS after `terraform apply` completes.

    Record 1:
      Type:  CNAME
      Host:  www
      Value: ${try(aws_cloudfront_distribution.wordpress.domain_name, "run apply first")}
      TTL:   300

    Record 2 (root domain — Namecheap CNAME flattening / URL redirect):
      Namecheap doesn't support CNAME at root (@).
      Options:
        a) Use Namecheap's "URL Redirect" record: @ → https://${var.domain_name} (301)
        b) Use ALIAS record if available in your plan
        c) Point @ to the CloudFront IP (not stable — not recommended)

    Recommended: add a URL Redirect record for @ pointing to www.${var.domain_name}
    and set the CloudFront alias to www.${var.domain_name} only.
  EOT
  value = {
    cloudfront_domain = try(aws_cloudfront_distribution.wordpress.domain_name, "run apply first")
  }
}

# ─────────────────────────────────────────────
# INSTANCE INFO (for SSH and troubleshooting)
# ─────────────────────────────────────────────

output "ec2_public_ip" {
  description = "EC2 public IP — changes on stop/start (no Elastic IP)"
  value       = aws_instance.wordpress.public_ip
}

output "ec2_public_dns" {
  description = "EC2 public DNS (used as CloudFront origin)"
  value       = aws_instance.wordpress.public_dns
}

output "ssh_command" {
  description = "SSH into the WordPress server"
  value       = "ssh -i ~/.ssh/wp-server.pem ec2-user@${aws_instance.wordpress.public_ip}"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — needed to update origin after IP change"
  value       = aws_cloudfront_distribution.wordpress.id
}

output "cloudfront_url" {
  description = "CloudFront domain (accessible before DNS propagates)"
  value       = "https://${aws_cloudfront_distribution.wordpress.domain_name}"
}

# ─────────────────────────────────────────────
# NO ELASTIC IP REMINDER
# ─────────────────────────────────────────────

output "no_elastic_ip_warning" {
  description = "Important: how to update CloudFront origin after EC2 IP change"
  value       = <<-EOT
    ⚠️  No Elastic IP — after stop/start, the EC2 public IP changes.
    To update the CloudFront origin run:
      terraform apply   (Terraform will detect the new public_dns and update CloudFront)
    OR manually:
      aws cloudfront get-distribution-config --id ${aws_cloudfront_distribution.wordpress.id}
      (update Origin DomainName, then call update-distribution)
  EOT
}
