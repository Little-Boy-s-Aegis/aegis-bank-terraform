locals {
  active_profile = var.deployment_profile == "production" ? module.production[0] : module.hackathon[0]
}

output "architecture_profile" {
  description = "Deployment profile implemented by this Terraform stack."
  value       = local.active_profile.architecture_profile
}

output "vpc_id" {
  description = "VPC ID."
  value       = local.active_profile.vpc_id
}

output "primary_az" {
  description = "Primary AZ for workloads."
  value       = local.active_profile.primary_az
}

output "alb_dns_name" {
  description = "Public ALB DNS name for Backend API."
  value       = local.active_profile.alb_dns_name
}

output "waf_blocked_ipv4_ip_set_name" {
  description = "Regional WAF IP set name used by SOAR to block attacker IPv4 CIDRs."
  value       = var.deployment_profile == "hackathon" ? module.hackathon[0].waf_blocked_ipv4_ip_set_name : null
}

output "waf_blocked_ipv4_ip_set_id" {
  description = "Regional WAF IP set ID used by SOAR to block attacker IPv4 CIDRs."
  value       = var.deployment_profile == "hackathon" ? module.hackathon[0].waf_blocked_ipv4_ip_set_id : null
}

output "waf_blocked_ipv4_ip_set_arn" {
  description = "Regional WAF IP set ARN used by the ALB Web ACL."
  value       = var.deployment_profile == "hackathon" ? module.hackathon[0].waf_blocked_ipv4_ip_set_arn : null
}

output "cloudfront_waf_blocked_ipv4_ip_set_name" {
  description = "CloudFront WAF IP set name used by SOAR to block attacker IPv4 CIDRs at the edge."
  value       = var.deployment_profile == "hackathon" ? module.hackathon[0].cloudfront_waf_blocked_ipv4_ip_set_name : null
}

output "cloudfront_waf_blocked_ipv4_ip_set_id" {
  description = "CloudFront WAF IP set ID used by SOAR to block attacker IPv4 CIDRs at the edge."
  value       = var.deployment_profile == "hackathon" ? module.hackathon[0].cloudfront_waf_blocked_ipv4_ip_set_id : null
}

output "cloudfront_waf_blocked_ipv4_ip_set_arn" {
  description = "CloudFront WAF IP set ARN used by the edge Web ACL."
  value       = var.deployment_profile == "hackathon" ? module.hackathon[0].cloudfront_waf_blocked_ipv4_ip_set_arn : null
}

output "app_cloudfront_url" {
  description = "Production CloudFront URL in front of the application ALB, if the selected profile creates one."
  value       = local.active_profile.app_cloudfront_url
}

output "app_route53_record_fqdn" {
  description = "Optional Route53 alias record for the production app edge."
  value       = local.active_profile.app_route53_record_fqdn
}

output "shield_advanced_enabled" {
  description = "Whether Shield Advanced protections are enabled by Terraform."
  value       = local.active_profile.shield_advanced_enabled
}

output "dashboard_cloudfront_url" {
  description = "CloudFront URL for the SOC dashboard."
  value       = local.active_profile.dashboard_cloudfront_url
}

output "dashboard_bucket" {
  description = "Private S3 bucket for static dashboard assets."
  value       = local.active_profile.dashboard_bucket
}

output "raw_logs_bucket" {
  description = "S3 bucket receiving raw logs."
  value       = local.active_profile.raw_logs_bucket
}

output "processed_logs_bucket" {
  description = "S3 bucket receiving processed logs."
  value       = local.active_profile.processed_logs_bucket
}

output "audit_logs_bucket" {
  description = "Object Lock enabled audit log bucket."
  value       = local.active_profile.audit_logs_bucket
}

output "raw_log_firehose_name" {
  description = "Kinesis Data Firehose stream for raw logs, if used by the selected profile."
  value       = local.active_profile.raw_log_firehose_name
}

output "preprocessor_lambda_name" {
  description = "Lambda preprocessing function."
  value       = local.active_profile.preprocessor_lambda_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = local.active_profile.ecs_cluster_name
}

output "ecs_service_names" {
  description = "ECS services deployed for the SOC platform."
  value       = local.active_profile.ecs_service_names
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by service."
  value       = local.active_profile.ecr_repository_urls
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint."
  value       = local.active_profile.rds_endpoint
}

output "rds_secret_arn" {
  description = "Secrets Manager secret containing generated DB credentials."
  value       = local.active_profile.rds_secret_arn
}

output "redis_endpoint" {
  description = "Redis endpoint."
  value       = local.active_profile.redis_endpoint
}

output "dynamodb_leader_lock_table" {
  description = "DynamoDB leader lock table for HA orchestrator."
  value       = local.active_profile.dynamodb_leader_lock_table
}

output "opensearch_vector_endpoint" {
  description = "OpenSearch vector/search endpoint."
  value       = local.active_profile.opensearch_vector_endpoint
}

output "qdrant_url" {
  description = "Qdrant endpoint used by ECS tasks, if configured."
  value       = local.active_profile.qdrant_url
}

output "layer_artifacts_bucket" {
  description = "S3 bucket containing canonical Layer 1 and Layer 2 artifacts uploaded by Terraform."
  value       = local.active_profile.layer_artifacts_bucket
}

output "layer_artifact_inventory" {
  description = "Canonical Layer 1 and Layer 2 artifacts synchronized by Terraform."
  value       = local.active_profile.layer_artifact_inventory
}

output "vector_db_collections" {
  description = "Vector DB provider and collection/index names used by Layer 1 and Layer 2 context retrieval."
  value       = local.active_profile.vector_db_collections
}

output "vector_db_init_task_definition_arn" {
  description = "On-demand ECS task definition that ingests Layer 1/Layer 2 artifacts into the vector DB."
  value       = local.active_profile.vector_db_init_task_definition_arn
}

output "step_functions_state_machine_arn" {
  description = "SOC playbook orchestrator state machine."
  value       = local.active_profile.step_functions_state_machine_arn
}

output "sns_alerts_topic_arn" {
  description = "SNS topic for real-time notifications."
  value       = local.active_profile.sns_alerts_topic_arn
}

output "cloudwatch_dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = local.active_profile.cloudwatch_dashboard_name
}

output "github_actions_role_arn" {
  description = "GitHub Actions deploy role ARN, if enabled."
  value       = local.active_profile.github_actions_role_arn
}

output "cost_controls" {
  description = "Important cost-control switches."
  value       = local.active_profile.cost_controls
}

output "route53_name_servers" {
  description = "Name servers for Route 53 zone."
  value       = var.deployment_profile == "hackathon" ? module.hackathon[0].route53_name_servers : []
}
