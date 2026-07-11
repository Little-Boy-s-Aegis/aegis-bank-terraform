aws_region         = "ap-southeast-1"
project_name       = "ai-native-soc"
environment        = "hackathon"
deployment_profile = "hackathon"

use_fargate_spot              = false
enable_ecs_container_insights = false
enable_opensearch_serverless  = false
enable_qdrant                 = true
enable_nat_gateway            = true
enable_github_oidc            = true
github_owner                  = "Little-Boy-s-Aegis"
github_repository             = "dashboard"

ecs_cpu                    = 256
ecs_memory                 = 512
ecs_desired_count          = 1
orchestrator_desired_count = 2

force_destroy_buckets = true
audit_retention_days  = 30
log_retention_days    = 14

allowed_http_cidr_blocks = ["0.0.0.0/0"]
sns_email_subscriptions  = ["voduchieu42@gmail.com"]
telegram_bot_token       = "8667720063:AAF4M0vpuoVECb5Kv5qeesvPBVTVvErkfDQ"
telegram_chat_id         = "1628206759"

llm_provider                 = "bedrock"
bedrock_model_id             = "qwen.qwen3-coder-next"
bedrock_region               = "ap-southeast-2"
bedrock_embedding_model_id   = "amazon.titan-embed-text-v2:0"
bedrock_embedding_region     = "ap-southeast-2"
bedrock_embedding_dimensions = 1024

container_image_overrides = {}
