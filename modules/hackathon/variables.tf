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

variable "waf_blocked_ipv4_cidrs" {
  description = "IPv4 CIDR ranges blocked by the ALB WAF IP set. SOAR updates the same IP set at runtime."
  type        = list(string)
  default     = []
}

variable "network_blocked_ipv4_cidrs" {
  description = "IPv4 CIDR ranges denied at the public subnet network ACL before ALB traffic reaches ECS."
  type        = list(string)
  default     = []
}

variable "enable_interface_endpoints" {
  description = "Create interface VPC endpoints instead of a NAT Gateway."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Create a NAT Gateway so private ECS tasks can call external services such as DashScope/Qdrant."
  type        = bool
  default     = false
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

variable "kafka_bootstrap_servers" {
  description = "Optional Kafka/MSK bootstrap servers used by the bank backend producer and dashboard backend consumers. Leave empty when Kafka is not deployed for this stack."
  type        = string
  default     = ""
}

variable "layer1_artifacts_path" {
  description = "Path, relative to the Terraform root, containing canonical Layer 1 prompts, references, and output schemas."
  type        = string
  default     = "../agent-layer-1"
}

variable "layer2_artifacts_path" {
  description = "Path, relative to the Terraform root, containing canonical Layer 2 prompt, output JSON/schema, risk tables, MITRE KB, and playbooks."
  type        = string
  default     = "../agent-layer-2"
}

variable "dashboard_build_path" {
  description = "Path, relative to the Terraform root, containing the built Vite SOC dashboard assets."
  type        = string
  default     = "../dashboard/frontend/dist"
}

variable "dashscope_api_key" {
  description = "Optional DashScope API key for Qwen, stored in Secrets Manager and injected into ECS as DASHSCOPE_API_KEY."
  type        = string
  default     = ""
  sensitive   = true
}

variable "qwen_model_name" {
  description = "Qwen model ID exposed to ECS as QWEN_MODEL_NAME."
  type        = string
  default     = "qwen3-plus"
}

variable "qwen_base_url" {
  description = "OpenAI-compatible DashScope/Qwen base URL exposed to ECS as QWEN_BASE_URL."
  type        = string
  default     = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
}

variable "llm_enabled" {
  description = "Expose whether LLM calls are enabled to ECS as LLM_ENABLED."
  type        = bool
  default     = true
}

variable "llm_provider" {
  description = "LLM provider used by ECS. Use bedrock for AWS Bedrock Qwen or dashscope for OpenAI-compatible DashScope."
  type        = string
  default     = "dashscope"

  validation {
    condition     = contains(["bedrock", "dashscope"], var.llm_provider)
    error_message = "llm_provider must be either bedrock or dashscope."
  }
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock Qwen model ID used when llm_provider is bedrock."
  type        = string
  default     = "qwen.qwen3-coder-next"
}

variable "bedrock_region" {
  description = "Amazon Bedrock runtime region for Qwen. Leave null to use aws_region."
  type        = string
  default     = null
}

variable "bedrock_embedding_model_id" {
  description = "Amazon Bedrock embedding model used for Qdrant vector ingestion and search."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "bedrock_embedding_region" {
  description = "Amazon Bedrock runtime region for embeddings. Leave null to use aws_region."
  type        = string
  default     = null
}

variable "bedrock_embedding_dimensions" {
  description = "Embedding vector dimensions used by Qdrant/OpenSearch indexes."
  type        = number
  default     = 1024
}

variable "enable_qdrant" {
  description = "Create an internal Qdrant ECS service with EFS persistence for the hackathon stack."
  type        = bool
  default     = false
}

variable "qdrant_url" {
  description = "Optional existing Qdrant endpoint. When set, ECS uses VECTOR_DB_PROVIDER=qdrant instead of the internal Qdrant service or AWS OpenSearch vector store."
  type        = string
  default     = ""
}

variable "qdrant_image" {
  description = "Container image used for the internal Qdrant ECS service."
  type        = string
  default     = "qdrant/qdrant:latest"
}

variable "qdrant_cpu" {
  description = "Fargate task CPU units for internal Qdrant."
  type        = number
  default     = 256
}

variable "qdrant_memory" {
  description = "Fargate task memory MiB for internal Qdrant."
  type        = number
  default     = 512
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
  default     = "16.14"
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

variable "telegram_chat_id" {
  description = "Optional Telegram chat ID for alert notifications."
  type        = string
  default     = ""
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

variable "use_custom_domain" {
  description = "Configure custom domains (Route53, ACM certs) for CloudFront."
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Optional existing Route53 hosted zone ID for littleboys.biz. Leave empty to let this module create a hosted zone."
  type        = string
  default     = ""
}

variable "ecs_autoscaling_max_capacity" {
  description = "Maximum number of tasks the ECS service can scale up to."
  type        = number
}

variable "ecs_autoscaling_cpu_threshold" {
  description = "Target average CPU utilization percentage for ECS auto scaling."
  type        = number
}

variable "ecs_autoscaling_memory_threshold" {
  description = "Target average Memory utilization percentage for ECS auto scaling."
  type        = number
}
