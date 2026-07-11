output "architecture_profile" {
  description = "Deployment profile implemented by this Terraform stack."
  value       = "hackathon-cost-optimized-single-az-workload"
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "primary_az" {
  description = "Primary AZ for hackathon workloads."
  value       = local.primary_az
}

output "alb_dns_name" {
  description = "Public ALB DNS name for Backend API."
  value       = aws_lb.app.dns_name
}

output "waf_blocked_ipv4_ip_set_name" {
  description = "Regional WAF IP set name used by SOAR to block attacker IPv4 CIDRs."
  value       = aws_wafv2_ip_set.blocked_ipv4.name
}

output "waf_blocked_ipv4_ip_set_id" {
  description = "Regional WAF IP set ID used by SOAR to block attacker IPv4 CIDRs."
  value       = aws_wafv2_ip_set.blocked_ipv4.id
}

output "waf_blocked_ipv4_ip_set_arn" {
  description = "Regional WAF IP set ARN used by the ALB Web ACL."
  value       = aws_wafv2_ip_set.blocked_ipv4.arn
}

output "cloudfront_waf_blocked_ipv4_ip_set_name" {
  description = "CloudFront WAF IP set name used by SOAR to block attacker IPv4 CIDRs at the edge."
  value       = aws_wafv2_ip_set.cloudfront_blocked_ipv4.name
}

output "cloudfront_waf_blocked_ipv4_ip_set_id" {
  description = "CloudFront WAF IP set ID used by SOAR to block attacker IPv4 CIDRs at the edge."
  value       = aws_wafv2_ip_set.cloudfront_blocked_ipv4.id
}

output "cloudfront_waf_blocked_ipv4_ip_set_arn" {
  description = "CloudFront WAF IP set ARN used by the edge Web ACL."
  value       = aws_wafv2_ip_set.cloudfront_blocked_ipv4.arn
}

output "app_cloudfront_url" {
  description = "Production-only CloudFront URL in front of the application ALB."
  value       = null
}

output "app_route53_record_fqdn" {
  description = "Production-only Route53 alias record for the app edge."
  value       = null
}

output "shield_advanced_enabled" {
  description = "Whether Shield Advanced protections are enabled by Terraform."
  value       = false
}

output "dashboard_cloudfront_url" {
  description = "CloudFront URL for the SOC dashboard."
  value       = "https://${aws_cloudfront_distribution.dashboard.domain_name}"
}

output "dashboard_bucket" {
  description = "Private S3 bucket for static dashboard assets."
  value       = aws_s3_bucket.dashboard.id
}

output "raw_logs_bucket" {
  description = "S3 bucket receiving Firehose raw logs."
  value       = aws_s3_bucket.raw_logs.id
}

output "processed_logs_bucket" {
  description = "S3 bucket receiving Lambda-processed logs."
  value       = aws_s3_bucket.processed_logs.id
}

output "audit_logs_bucket" {
  description = "Object Lock enabled audit log bucket."
  value       = aws_s3_bucket.audit.id
}

output "raw_log_firehose_name" {
  description = "Kinesis Data Firehose stream for raw logs."
  value       = aws_kinesis_firehose_delivery_stream.raw_logs.name
}

output "preprocessor_lambda_name" {
  description = "Lambda preprocessing function."
  value       = aws_lambda_function.preprocessor.function_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_names" {
  description = "ECS services deployed for the SOC platform."
  value       = keys(aws_ecs_service.service)
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by service."
  value       = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint, if enabled."
  value       = var.enable_rds ? aws_db_instance.postgres[0].address : null
}

output "rds_secret_arn" {
  description = "Secrets Manager secret containing generated DB credentials."
  value       = var.enable_rds ? aws_secretsmanager_secret.db[0].arn : null
}

output "redis_endpoint" {
  description = "Redis endpoint, if enabled."
  value       = var.enable_redis ? aws_elasticache_cluster.redis[0].cache_nodes[0].address : null
}

output "dynamodb_leader_lock_table" {
  description = "DynamoDB leader lock table for HA orchestrator."
  value       = aws_dynamodb_table.leader_lock.name
}

output "opensearch_vector_endpoint" {
  description = "OpenSearch Serverless collection endpoint, if enabled."
  value       = local.vector_db_provider == "opensearch" ? aws_opensearchserverless_collection.vectors[0].collection_endpoint : null
}

output "qdrant_url" {
  description = "Qdrant endpoint used by ECS tasks, if configured."
  value       = local.effective_qdrant_url != "" ? local.effective_qdrant_url : null
}

output "layer_artifacts_bucket" {
  description = "S3 bucket containing canonical Layer 1 and Layer 2 artifacts uploaded by Terraform."
  value       = aws_s3_bucket.layer_artifacts.id
}

output "layer_artifact_inventory" {
  description = "Layer artifacts synchronized into S3 for ECS runtime and vector ingestion."
  value = {
    layer1_schema_version = local.layer1_schema_version
    layer2_schema_version = local.layer2_schema_version
    layer1_files          = sort(tolist(local.layer1_artifact_files))
    layer2_files          = sort(tolist(local.layer2_artifact_files))
    layer1_s3_prefix      = "s3://${aws_s3_bucket.layer_artifacts.id}/layer1/"
    layer2_s3_prefix      = "s3://${aws_s3_bucket.layer_artifacts.id}/layer2/"
  }
}

output "vector_db_collections" {
  description = "Vector DB provider and index names used by the SOC layers."
  value = {
    provider = local.vector_db_provider
    l1_index = local.vector_l1_index
    l2_index = local.vector_l2_index
  }
}

output "vector_db_init_task_definition_arn" {
  description = "On-demand ECS task definition that ingests Layer 1/Layer 2 artifacts into the vector DB."
  value       = aws_ecs_task_definition.vector_db_init.arn
}

output "step_functions_state_machine_arn" {
  description = "SOC playbook orchestrator state machine."
  value       = aws_sfn_state_machine.orchestrator.arn
}

output "sns_alerts_topic_arn" {
  description = "SNS topic for real-time notifications."
  value       = aws_sns_topic.alerts.arn
}

output "cloudwatch_dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.soc.dashboard_name
}

output "github_actions_role_arn" {
  description = "GitHub Actions deploy role ARN, if enabled."
  value       = var.enable_github_oidc ? aws_iam_role.github_actions[0].arn : null
}

output "cost_controls" {
  description = "Important cost-control switches."
  value = {
    single_az_workload              = true
    no_nat_gateway                  = !var.enable_nat_gateway
    nat_gateway_enabled             = var.enable_nat_gateway
    use_fargate_spot                = var.use_fargate_spot
    ecs_container_insights_enabled  = var.enable_ecs_container_insights
    opensearch_serverless_enabled   = var.enable_opensearch_serverless
    qdrant_enabled                  = local.vector_db_provider == "qdrant"
    interface_vpc_endpoints_enabled = var.enable_interface_endpoints
    audit_object_lock_days          = var.audit_retention_days
  }
}

output "route53_name_servers" {
  description = "Name servers for Route 53 zone."
  value       = var.use_custom_domain ? aws_route53_zone.littleboys_biz[0].name_servers : []
}

