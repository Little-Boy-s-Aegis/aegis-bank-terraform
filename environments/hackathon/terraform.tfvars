aws_region         = "us-east-1"
project_name       = "ai-native-soc"
environment        = "hackathon"
deployment_profile = "hackathon"

use_fargate_spot              = true
enable_ecs_container_insights = false
enable_opensearch_serverless  = true
enable_github_oidc            = false

ecs_cpu                    = 256
ecs_memory                 = 512
ecs_desired_count          = 1
orchestrator_desired_count = 2

force_destroy_buckets = true
audit_retention_days  = 30
log_retention_days    = 14

sns_email_subscriptions   = []
container_image_overrides = {}
