aws_region         = "us-east-1"
project_name       = "ai-native-soc"
environment        = "production"
deployment_profile = "production"

use_fargate_spot              = false
enable_ecs_container_insights = true
enable_opensearch_serverless  = true
enable_github_oidc            = false
enable_shield_advanced        = false

app_domain_name     = ""
app_certificate_arn = ""
route53_zone_id     = ""

ecs_cpu                    = 512
ecs_memory                 = 1024
ecs_desired_count          = 2
orchestrator_desired_count = 2

postgres_instance_class       = "db.t4g.small"
postgres_allocated_storage_gb = 50
postgres_max_storage_gb       = 200
db_backup_retention_days      = 7

redis_node_type = "cache.t4g.small"

force_destroy_buckets = false
audit_retention_days  = 365
log_retention_days    = 30

sns_email_subscriptions   = []
container_image_overrides = {}
