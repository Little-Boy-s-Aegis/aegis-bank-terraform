output "state_bucket" {
  description = "S3 bucket for Terraform remote state."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table for Terraform state locking."
  value       = aws_dynamodb_table.locks.name
}

output "backend_config_example" {
  description = "Backend config values to copy into backend/backend.hcl."
  value = {
    bucket         = aws_s3_bucket.state.id
    key            = "ai-native-soc/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = aws_dynamodb_table.locks.name
    encrypt        = true
  }
}
