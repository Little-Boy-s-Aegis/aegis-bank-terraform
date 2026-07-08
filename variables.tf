variable "aws_region" {
  description = "AWS region for the hackathon deployment."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in resource names."
  type        = string
  default     = "ai-native-soc"
}

variable "environment" {
  description = "Environment suffix used in resource names."
  type        = string
  default     = "hackathon"
}

variable "deployment_profile" {
  description = "Select the Terraform stack implementation: hackathon or production."
  type        = string
  default     = "hackathon"

  validation {
    condition     = contains(["hackathon", "production"], var.deployment_profile)
    error_message = "deployment_profile must be either hackathon or production."
  }
}

variable "availability_zone" {
  description = "Primary AZ. Leave null to use the first available AZ in the selected region."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Primary public subnet CIDR."
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_app_subnet_cidr" {
  description = "Private app subnet CIDR."
  type        = string
  default     = "10.0.1.0/24"
}

variable "data_subnet_cidr" {
  description = "Private data subnet CIDR."
  type        = string
  default     = "10.0.2.0/24"
}

variable "alb_spare_subnet_cidr" {
  description = "Small second-AZ public subnet required by Application Load Balancer."
  type        = string
  default     = "10.0.3.0/28"
}

variable "data_spare_subnet_cidr" {
  description = "Small second-AZ private data subnet required by RDS subnet groups."
  type        = string
  default     = "10.0.4.0/28"
}

variable "allowed_http_cidr_blocks" {
  description = "CIDR ranges allowed to access ALB HTTP/HTTPS."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_interface_endpoints" {
  description = "Create interface VPC endpoints instead of a NAT Gateway."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "Interface endpoint service suffixes. Remove bedrock-runtime if the region does not support it."
  type        = list(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
    "kms",
    "ssm",
    "xray",
    "bedrock-runtime"
  ]
}

variable "force_destroy_buckets" {
  description = "Allow Terraform destroy to delete non-empty hackathon buckets."
  type        = bool
  default     = true
}

variable "s3_transition_to_ia_days" {
  description = "Days before log objects transition to STANDARD_IA."
  type        = number
  default     = 30
}

variable "s3_transition_to_glacier_days" {
  description = "Days before log objects transition to Glacier Instant Retrieval."
  type        = number
  default     = 90
}

variable "s3_noncurrent_expiration_days" {
  description = "Days before non-current object versions expire."
  type        = number
  default     = 30
}

variable "audit_retention_days" {
  description = "Default Object Lock retention period for audit logs."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days."
  type        = number
  default     = 14
}

variable "ecs_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "ecs_memory" {
  description = "Fargate task memory MiB."
  type        = number
  default     = 512
}

variable "ecs_cpu_architecture" {
  description = "Fargate CPU architecture."
  type        = string
  default     = "ARM64"
}

variable "ecs_desired_count" {
  description = "Desired count for backend, agents, analyzer, and worker services."
  type        = number
  default     = 1
}

variable "orchestrator_desired_count" {
  description = "Desired count for HA orchestrator service. The reference diagram uses 2."
  type        = number
  default     = 2
}

variable "use_fargate_spot" {
  description = "Use Fargate Spot capacity provider for lower hackathon cost."
  type        = bool
  default     = true
}

variable "enable_ecs_container_insights" {
  description = "Enable ECS Container Insights. Disabled by default to reduce cost."
  type        = bool
  default     = false
}

variable "container_image_overrides" {
  description = "Optional ECS image overrides by service key: backend-api, layer1-agents, layer2-meta-analyzer, worker-service, orchestrator-ha."
  type        = map(string)
  default     = {}
}

variable "ecr_images_to_keep" {
  description = "Number of images to retain per ECR repository."
  type        = number
  default     = 5
}

variable "enable_rds" {
  description = "Create single-AZ RDS PostgreSQL."
  type        = bool
  default     = true
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "soc"
}

variable "db_username" {
  description = "PostgreSQL master username."
  type        = string
  default     = "soc_admin"
}

variable "postgres_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.3"
}

variable "postgres_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "postgres_allocated_storage_gb" {
  description = "Initial PostgreSQL storage."
  type        = number
  default     = 20
}

variable "postgres_max_storage_gb" {
  description = "Maximum autoscaled PostgreSQL storage."
  type        = number
  default     = 50
}

variable "db_backup_retention_days" {
  description = "RDS backup retention."
  type        = number
  default     = 1
}

variable "enable_redis" {
  description = "Create single-node ElastiCache Redis."
  type        = bool
  default     = true
}

variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "redis_node_type" {
  description = "Redis node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "redis_parameter_group_name" {
  description = "Redis parameter group."
  type        = string
  default     = "default.redis7"
}

variable "enable_opensearch_serverless" {
  description = "Create OpenSearch Serverless vector collection. Disabled by default because OCU charges can dominate hackathon cost."
  type        = bool
  default     = false
}

variable "orchestrator_rotation_schedule" {
  description = "EventBridge schedule expression for active/standby orchestrator rotation."
  type        = string
  default     = "rate(1 hour)"
}

variable "sns_email_subscriptions" {
  description = "Email addresses to subscribe to the SOC alert SNS topic."
  type        = list(string)
  default     = []
}

variable "ses_identity_email" {
  description = "Optional SES sender identity email."
  type        = string
  default     = null
}

variable "telegram_bot_token" {
  description = "Optional Telegram bot token stored in Secrets Manager."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_webhook_url" {
  description = "Optional Slack webhook URL stored in Secrets Manager."
  type        = string
  default     = ""
  sensitive   = true
}

variable "jira_base_url" {
  description = "Optional Jira base URL stored in Secrets Manager."
  type        = string
  default     = ""
}

variable "jira_api_token" {
  description = "Optional Jira API token stored in Secrets Manager."
  type        = string
  default     = ""
  sensitive   = true
}

variable "servicenow_url" {
  description = "Optional ServiceNow URL stored in Secrets Manager."
  type        = string
  default     = ""
}

variable "cloudfront_price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"
}

variable "app_domain_name" {
  description = "Optional production application DNS name for the ALB-facing CloudFront distribution."
  type        = string
  default     = ""
}

variable "app_certificate_arn" {
  description = "Optional ACM certificate ARN in us-east-1 for app_domain_name on CloudFront."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Optional Route53 hosted zone ID used to create an alias for app_domain_name."
  type        = string
  default     = ""
}

variable "enable_shield_advanced" {
  description = "Enable AWS Shield Advanced protections for production CloudFront and ALB resources. Requires an active Shield Advanced subscription."
  type        = bool
  default     = false
}

variable "alarm_alb_5xx_threshold" {
  description = "ALB 5xx count threshold."
  type        = number
  default     = 5
}

variable "alarm_ecs_cpu_threshold" {
  description = "ECS CPU high alarm threshold."
  type        = number
  default     = 80
}

variable "enable_github_oidc" {
  description = "Create a GitHub Actions OIDC provider and deploy role."
  type        = bool
  default     = false
}

variable "github_owner" {
  description = "GitHub organization or user for the CI/CD role trust policy."
  type        = string
  default     = "CHANGE_ME"
}

variable "github_repository" {
  description = "GitHub repository for the CI/CD role trust policy."
  type        = string
  default     = "CHANGE_ME"
}

variable "github_oidc_thumbprints" {
  description = "GitHub OIDC thumbprints. Override if your AWS security baseline requires updated values."
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
