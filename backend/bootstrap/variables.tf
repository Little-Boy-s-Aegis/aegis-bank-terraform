variable "aws_region" {
  description = "AWS region for the Terraform remote state resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in backend resource names."
  type        = string
  default     = "ai-native-soc"
}

variable "environment" {
  description = "Environment name for backend resource names."
  type        = string
  default     = "shared"
}
