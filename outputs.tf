# ─────────────────────────────────────────────
# STEP 1 — ACM DNS validation records
# ─────────────────────────────────────────────

output "acm_dns_validation_records" {
  description = "Add these CNAME records to Namecheap Advanced DNS before or during terraform apply."
  value = {
    for dvo in aws_acm_certificate.wordpress.domain_validation_options : dvo.domain_name => {
      namecheap_host = replace(dvo.resource_record_name, ".${var.domain_name}.", "")
      type           = dvo.resource_record_type
      value          = trimsuffix(dvo.resource_record_value, ".")
      ttl            = "300"
    }
  }
}

# ─────────────────────────────────────────────
# STEP 2 — Namecheap DNS records after apply
# ─────────────────────────────────────────────

output "cloudfront_domain" {
  description = "CloudFront domain — add as CNAME www in Namecheap Advanced DNS"
  value       = aws_cloudfront_distribution.wordpress.domain_name
}

output "namecheap_www_record" {
  description = "Add to Namecheap: Type=CNAME, Host=www, Value=<cloudfront_domain>, TTL=300"
  value       = "CNAME | www | ${aws_cloudfront_distribution.wordpress.domain_name} | TTL 300"
}

output "namecheap_root_record" {
  description = "Add to Namecheap: URL Redirect record, Host=@, Value=https://www.<domain>"
  value       = "URL Redirect | @ | https://www.${var.domain_name}"
}

# ─────────────────────────────────────────────
# INSTANCE INFO
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
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.wordpress.id
}

output "cloudfront_url" {
  description = "CloudFront URL — accessible before DNS propagates"
  value       = "https://${aws_cloudfront_distribution.wordpress.domain_name}"
}

output "site_url" {
  description = "WordPress site URL"
  value       = "https://www.${var.domain_name}"
}

output "no_elastic_ip_warning" {
  description = "After EC2 stop/start run terraform apply to update CloudFront origin"
  value       = "Run: terraform apply  (updates CloudFront origin with new EC2 public DNS)"
}
