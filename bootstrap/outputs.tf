output "s3_bucket_name" {
  description = "Paste this into the backend block in main.tf"
  value       = aws_s3_bucket.tfstate.bucket
}

output "dynamodb_table_name" {
  description = "Paste this into the backend block in main.tf"
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "backend_config" {
  description = "Ready-to-paste backend block for main.tf"
  value       = <<-EOT

    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tfstate.bucket}"
        key            = "wordpress/terraform.tfstate"
        region         = "us-east-1"
        dynamodb_table = "${aws_dynamodb_table.tfstate_lock.name}"
        encrypt        = true
      }
    }

  EOT
}
