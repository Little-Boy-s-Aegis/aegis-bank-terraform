data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "random_password" "db" {
  count   = var.enable_rds ? 1 : 0
  length  = 24
  special = true
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  bucket_base = "${replace(local.name_prefix, "_", "-")}-${random_id.bucket_suffix.hex}"
  primary_az  = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])
  spare_az    = length(data.aws_availability_zones.available.names) > 1 ? data.aws_availability_zones.available.names[1] : local.primary_az

  common_tags = {
    Project      = var.project_name
    Environment  = var.environment
    Architecture = "ai-native-soc-cost-optimized"
    ManagedBy    = "terraform"
  }

  ecs_services = {
    backend-api = {
      container_port = 8080
      desired_count  = var.ecs_desired_count
      health_path    = "/health"
      description    = "Backend API REST"
    }
    layer1-agents = {
      container_port = 8081
      desired_count  = var.ecs_desired_count
      health_path    = "/health"
      description    = "Layer 1 AI sensor agents"
    }
    layer2-meta-analyzer = {
      container_port = 8082
      desired_count  = var.ecs_desired_count
      health_path    = "/health"
      description    = "Layer 2 meta analyzer"
    }
    worker-service = {
      container_port = 8083
      desired_count  = var.ecs_desired_count
      health_path    = "/health"
      description    = "Async worker service"
    }
    orchestrator-ha = {
      container_port = 8084
      desired_count  = var.orchestrator_desired_count
      health_path    = "/health"
      description    = "HA orchestrator active/standby"
    }
  }

  opensearch_collection_name = substr(replace(lower(local.name_prefix), "_", "-"), 0, 23)
  layer1_schema_version      = "littleboy.soc.layer1.agent_finding.v4"
  layer2_schema_version      = "littleboy.soc.layer2.orchestrator_decision.v8"
  vector_l1_index            = "l1-threat-intel"
  vector_l2_index            = "l2-playbooks"
  vector_db_provider         = var.qdrant_url != "" ? "qdrant" : (var.enable_opensearch_serverless ? "opensearch" : "disabled")
  layer1_artifacts_root      = abspath("${path.root}/${var.layer1_artifacts_path}")
  layer2_artifacts_root      = abspath("${path.root}/${var.layer2_artifacts_path}")
  layer1_artifact_files = toset(distinct(concat(
    tolist(fileset(local.layer1_artifacts_root, "README.md")),
    tolist(fileset(local.layer1_artifacts_root, "agent_*/README.md")),
    tolist(fileset(local.layer1_artifacts_root, "agent_*/layer1_standard_agent_output_schema.json")),
    tolist(fileset(local.layer1_artifacts_root, "agent_*/*_system_prompt.md")),
    tolist(fileset(local.layer1_artifacts_root, "agent_*/*_reference.md")),
    tolist(fileset(local.layer1_artifacts_root, "agent_*/*_matrix.md"))
  )))
  layer2_artifact_files = toset(distinct(concat(
    tolist(fileset(local.layer2_artifacts_root, "*.md")),
    tolist(fileset(local.layer2_artifacts_root, "*.json")),
    tolist(fileset(local.layer2_artifacts_root, "risk_scoring/*.md"))
  )))
  layer_artifact_env = [
    { name = "LAYER1_SCHEMA_VERSION", value = local.layer1_schema_version },
    { name = "LAYER2_SCHEMA_VERSION", value = local.layer2_schema_version },
    { name = "LAYER_ARTIFACTS_LOCAL_DIR", value = "/tmp/aegis-layer-artifacts" },
    { name = "AGENT_L1_DIR", value = "/tmp/aegis-layer-artifacts/layer1" },
    { name = "AGENT_L2_DIR", value = "/tmp/aegis-layer-artifacts/layer2" },
    { name = "LAYER_ARTIFACTS_S3_BUCKET", value = aws_s3_bucket.layer_artifacts.id },
    { name = "LAYER1_ARTIFACTS_S3_PREFIX", value = "layer1/" },
    { name = "LAYER2_ARTIFACTS_S3_PREFIX", value = "layer2/" },
    { name = "LAYER1_ARTIFACTS_URI", value = "s3://${aws_s3_bucket.layer_artifacts.id}/layer1/" },
    { name = "LAYER2_ARTIFACTS_URI", value = "s3://${aws_s3_bucket.layer_artifacts.id}/layer2/" },
    { name = "LAYER1_OUTPUT_SCHEMA_GLOB", value = "s3://${aws_s3_bucket.layer_artifacts.id}/layer1/agent_*/layer1_standard_agent_output_schema.json" },
    { name = "LAYER2_OUTPUT_SCHEMA_URI", value = "s3://${aws_s3_bucket.layer_artifacts.id}/layer2/layer2_orchestrator_output_schema.json" },
    { name = "LAYER2_OUTPUT_EXAMPLE_URI", value = "s3://${aws_s3_bucket.layer_artifacts.id}/layer2/layer2_json_output_example.json" },
    { name = "LAYER2_PLAYBOOKS_URI", value = "s3://${aws_s3_bucket.layer_artifacts.id}/layer2/orchestrator_l2_playbooks.md" },
    { name = "MITRE_ATTACK_FULL_URI", value = "s3://${aws_s3_bucket.layer_artifacts.id}/layer2/mitre_attack_full.json" }
  ]
  vector_db_env = [
    { name = "VECTOR_DB_PROVIDER", value = local.vector_db_provider },
    { name = "QDRANT_URL", value = var.qdrant_url },
    { name = "OPENSEARCH_ENDPOINT", value = local.vector_db_provider == "opensearch" ? aws_opensearchserverless_collection.vectors[0].collection_endpoint : "" },
    { name = "OPENSEARCH_SERVICE", value = "aoss" },
    { name = "OPENSEARCH_L1_INDEX", value = local.vector_l1_index },
    { name = "OPENSEARCH_L2_INDEX", value = local.vector_l2_index }
  ]
  llm_env = [
    { name = "QWEN_MODEL_NAME", value = var.qwen_model_name },
    { name = "QWEN_BASE_URL", value = var.qwen_base_url },
    { name = "LLM_ENABLED", value = tostring(var.llm_enabled) }
  ]
  llm_secret_env = var.dashscope_api_key != "" ? [
    { name = "DASHSCOPE_API_KEY", valueFrom = aws_secretsmanager_secret.llm[0].arn }
  ] : []
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.primary_az
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-1az"
    Tier = "public"
  }
}

resource "aws_subnet" "public_alb_spare" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.alb_spare_subnet_cidr
  availability_zone       = local.spare_az
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-alb-spare"
    Tier = "public-spare"
    Note = "Required by ALB even though workloads stay single-AZ"
  }
}

resource "aws_subnet" "private_app" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_app_subnet_cidr
  availability_zone       = local.primary_az
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-app-1az"
    Tier = "private-app"
  }
}

resource "aws_subnet" "private_data" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.data_subnet_cidr
  availability_zone       = local.primary_az
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-data-1az"
    Tier = "private-data"
  }
}

resource "aws_subnet" "private_data_spare" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.data_spare_subnet_cidr
  availability_zone       = local.spare_az
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-data-spare"
    Tier = "private-data-spare"
    Note = "Required by RDS subnet groups; no workload is scheduled here"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_alb_spare" {
  subnet_id      = aws_subnet.public_alb_spare.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  domain = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public.id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${local.name_prefix}-nat"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = var.enable_nat_gateway ? "${local.name_prefix}-private-rt-nat" : "${local.name_prefix}-private-rt-no-nat"
  }
}

resource "aws_route" "private_nat_egress" {
  count = var.enable_nat_gateway ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "private_app" {
  subnet_id      = aws_subnet.private_app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data" {
  subnet_id      = aws_subnet.private_data.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data_spare" {
  subnet_id      = aws_subnet.private_data_spare.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${local.name_prefix}-s3-gateway-endpoint"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${local.name_prefix}-dynamodb-gateway-endpoint"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-vpce-sg"
  description = "Interface endpoint access from private app subnet"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-vpce-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoint_https_from_ecs" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 443
  ip_protocol                  = "tcp"
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "vpc_endpoint_all" {
  security_group_id = aws_security_group.vpc_endpoints.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : toset([])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app.id]
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name = "${local.name_prefix}-${replace(each.key, ".", "-")}-endpoint"
  }
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid     = "AllowAccountAdministration"
    effect  = "Allow"
    actions = ["kms:*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    resources = ["*"]
  }

  statement {
    sid    = "AllowAwsServicesForHackathonStack"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo"
    ]

    principals {
      type = "Service"
      identifiers = [
        "cloudwatch.amazonaws.com",
        "dynamodb.amazonaws.com",
        "ec2.amazonaws.com",
        "ecs.amazonaws.com",
        "elasticache.amazonaws.com",
        "firehose.amazonaws.com",
        "lambda.amazonaws.com",
        "logs.${var.aws_region}.amazonaws.com",
        "rds.amazonaws.com",
        "s3.amazonaws.com",
        "secretsmanager.amazonaws.com",
        "sns.amazonaws.com",
        "sqs.amazonaws.com",
        "states.amazonaws.com"
      ]
    }

    resources = ["*"]
  }
}

resource "aws_kms_key" "main" {
  description             = "KMS key for AI-Native SOC hackathon data"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json

  tags = {
    Name = "${local.name_prefix}-kms"
  }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Public HTTP ingress for the hackathon ALB"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_http_cidr_blocks)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_http_cidr_blocks)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 8080
  ip_protocol                  = "tcp"
  to_port                      = 8084
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name_prefix}-ecs-tasks-sg"
  description = "Private ECS Fargate tasks"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-ecs-tasks-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs_tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  ip_protocol                  = "tcp"
  to_port                      = 8084
}

resource "aws_vpc_security_group_egress_rule" "ecs_all_egress" {
  security_group_id = aws_security_group.ecs_tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "rds" {
  count = var.enable_rds ? 1 : 0

  name        = "${local.name_prefix}-rds-sg"
  description = "PostgreSQL access from ECS only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-rds-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ecs" {
  count = var.enable_rds ? 1 : 0

  security_group_id            = aws_security_group.rds[0].id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 5432
  ip_protocol                  = "tcp"
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "rds_all_egress" {
  count = var.enable_rds ? 1 : 0

  security_group_id = aws_security_group.rds[0].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_security_group" "redis" {
  count = var.enable_redis ? 1 : 0

  name        = "${local.name_prefix}-redis-sg"
  description = "Redis access from ECS only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-redis-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_ecs" {
  count = var.enable_redis ? 1 : 0

  security_group_id            = aws_security_group.redis[0].id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 6379
  ip_protocol                  = "tcp"
  to_port                      = 6379
}

resource "aws_vpc_security_group_egress_rule" "redis_all_egress" {
  count = var.enable_redis ? 1 : 0

  security_group_id = aws_security_group.redis[0].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_wafv2_web_acl" "alb" {
  name        = "${local.name_prefix}-alb-waf"
  description = "Basic, low-maintenance WAF rules for the public ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.name_prefix}-alb-waf"
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.app.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

resource "aws_s3_bucket" "raw_logs" {
  bucket        = "${local.bucket_base}-raw-logs"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name  = "${local.name_prefix}-raw-logs"
    Layer = "ingestion"
  }
}

resource "aws_s3_bucket" "processed_logs" {
  bucket        = "${local.bucket_base}-processed-logs"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name  = "${local.name_prefix}-processed-logs"
    Layer = "ai-analysis"
  }
}

resource "aws_s3_bucket" "dashboard" {
  bucket        = "${local.bucket_base}-dashboard"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name  = "${local.name_prefix}-dashboard"
    Layer = "reporting"
  }
}

resource "aws_s3_bucket" "layer_artifacts" {
  bucket        = "${local.bucket_base}-layer-artifacts"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name  = "${local.name_prefix}-layer-artifacts"
    Layer = "layer-contracts"
  }
}

resource "aws_s3_bucket" "audit" {
  bucket              = "${local.bucket_base}-audit-logs"
  force_destroy       = var.force_destroy_buckets
  object_lock_enabled = true

  tags = {
    Name  = "${local.name_prefix}-audit-logs"
    Layer = "audit"
  }
}

resource "aws_s3_bucket_versioning" "versioned" {
  for_each = {
    raw             = aws_s3_bucket.raw_logs.id
    processed       = aws_s3_bucket.processed_logs.id
    layer_artifacts = aws_s3_bucket.layer_artifacts.id
    audit           = aws_s3_bucket.audit.id
  }

  bucket = each.value

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket     = aws_s3_bucket.audit.id
  depends_on = [aws_s3_bucket_versioning.versioned]

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.audit_retention_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kms_encrypted" {
  for_each = {
    raw             = aws_s3_bucket.raw_logs.id
    processed       = aws_s3_bucket.processed_logs.id
    layer_artifacts = aws_s3_bucket.layer_artifacts.id
    audit           = aws_s3_bucket.audit.id
  }

  bucket = each.value

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.main.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "all" {
  for_each = {
    raw             = aws_s3_bucket.raw_logs.id
    processed       = aws_s3_bucket.processed_logs.id
    dashboard       = aws_s3_bucket.dashboard.id
    layer_artifacts = aws_s3_bucket.layer_artifacts.id
    audit           = aws_s3_bucket.audit.id
  }

  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cost_optimized_logs" {
  for_each = {
    raw       = aws_s3_bucket.raw_logs.id
    processed = aws_s3_bucket.processed_logs.id
    audit     = aws_s3_bucket.audit.id
  }

  bucket = each.value

  rule {
    id     = "transition-to-low-cost-storage"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = var.s3_transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.s3_transition_to_glacier_days
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.s3_noncurrent_expiration_days
    }
  }
}

resource "aws_s3_object" "dashboard_placeholder" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "index.html"
  content_type = "text/html"
  content      = <<-HTML
    <!doctype html>
    <html>
      <head><title>AI-Native SOC Dashboard</title></head>
      <body style="font-family:Arial,sans-serif;background:#0f172a;color:white;margin:40px">
        <h1>AI-Native SOC Dashboard</h1>
        <p>Upload the Next.js/React static build to this S3 bucket for the hackathon UI.</p>
      </body>
    </html>
  HTML
}

resource "aws_s3_object" "layer1_artifacts" {
  for_each = local.layer1_artifact_files

  bucket                 = aws_s3_bucket.layer_artifacts.id
  key                    = "layer1/${each.value}"
  source                 = "${local.layer1_artifacts_root}/${each.value}"
  etag                   = filemd5("${local.layer1_artifacts_root}/${each.value}")
  content_type           = endswith(each.value, ".json") ? "application/json" : "text/markdown"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.main.arn

  tags = {
    Layer         = "layer1"
    SchemaVersion = local.layer1_schema_version
  }
}

resource "aws_s3_object" "layer2_artifacts" {
  for_each = local.layer2_artifact_files

  bucket                 = aws_s3_bucket.layer_artifacts.id
  key                    = "layer2/${each.value}"
  source                 = "${local.layer2_artifacts_root}/${each.value}"
  etag                   = filemd5("${local.layer2_artifacts_root}/${each.value}")
  content_type           = endswith(each.value, ".json") ? "application/json" : "text/markdown"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.main.arn

  tags = {
    Layer         = "layer2"
    SchemaVersion = local.layer2_schema_version
  }
}

resource "aws_secretsmanager_secret" "db" {
  count = var.enable_rds ? 1 : 0

  name        = "${local.name_prefix}/database/postgres"
  description = "Generated PostgreSQL credentials for the SOC metadata database"
  kms_key_id  = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret_version" "db" {
  count = var.enable_rds ? 1 : 0

  secret_id = aws_secretsmanager_secret.db[0].id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db[0].result
    database = var.db_name
  })
}

resource "aws_db_subnet_group" "postgres" {
  count = var.enable_rds ? 1 : 0

  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = [aws_subnet.private_data.id, aws_subnet.private_data_spare.id]

  tags = {
    Name = "${local.name_prefix}-db-subnets"
  }
}

resource "aws_db_instance" "postgres" {
  count = var.enable_rds ? 1 : 0

  identifier                 = "${local.name_prefix}-postgres"
  engine                     = "postgres"
  engine_version             = var.postgres_engine_version
  instance_class             = var.postgres_instance_class
  allocated_storage          = var.postgres_allocated_storage_gb
  max_allocated_storage      = var.postgres_max_storage_gb
  db_name                    = var.db_name
  username                   = var.db_username
  password                   = random_password.db[0].result
  db_subnet_group_name       = aws_db_subnet_group.postgres[0].name
  vpc_security_group_ids     = [aws_security_group.rds[0].id]
  multi_az                   = false
  publicly_accessible        = false
  storage_encrypted          = true
  kms_key_id                 = aws_kms_key.main.arn
  backup_retention_period    = var.db_backup_retention_days
  deletion_protection        = false
  skip_final_snapshot        = true
  auto_minor_version_upgrade = true

  tags = {
    Name  = "${local.name_prefix}-postgres"
    Layer = "data"
  }
}

resource "aws_elasticache_subnet_group" "redis" {
  count = var.enable_redis ? 1 : 0

  name       = "${local.name_prefix}-redis-subnets"
  subnet_ids = [aws_subnet.private_data.id, aws_subnet.private_data_spare.id]
}

resource "aws_elasticache_cluster" "redis" {
  count = var.enable_redis ? 1 : 0

  cluster_id           = substr("${local.name_prefix}-redis", 0, 40)
  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  num_cache_nodes      = 1
  parameter_group_name = var.redis_parameter_group_name
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis[0].name
  security_group_ids   = [aws_security_group.redis[0].id]

  tags = {
    Name  = "${local.name_prefix}-redis"
    Layer = "data"
  }
}

resource "aws_dynamodb_table" "leader_lock" {
  name         = "${local.name_prefix}-leader-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "lock_id"

  attribute {
    name = "lock_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  tags = {
    Name  = "${local.name_prefix}-leader-lock"
    Layer = "orchestration"
  }
}

resource "aws_opensearchserverless_security_policy" "encryption" {
  count = var.enable_opensearch_serverless ? 1 : 0

  name = "${local.opensearch_collection_name}-enc"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.opensearch_collection_name}-vectors"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_vpc_endpoint" "vectors" {
  count = var.enable_opensearch_serverless ? 1 : 0

  name               = "${local.opensearch_collection_name}-vpce"
  vpc_id             = aws_vpc.main.id
  subnet_ids         = [aws_subnet.private_app.id]
  security_group_ids = [aws_security_group.vpc_endpoints.id]
}

resource "aws_opensearchserverless_security_policy" "network" {
  count = var.enable_opensearch_serverless ? 1 : 0

  name = "${local.opensearch_collection_name}-net"
  type = "network"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.opensearch_collection_name}-vectors"]
    }]
    AllowFromPublic = false
    SourceVPCEs     = [aws_opensearchserverless_vpc_endpoint.vectors[0].id]
  }])
}

resource "aws_opensearchserverless_access_policy" "data" {
  count = var.enable_opensearch_serverless ? 1 : 0

  name = "${local.opensearch_collection_name}-data"
  type = "data"
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.opensearch_collection_name}-vectors"]
        Permission = [
          "aoss:CreateCollectionItems",
          "aoss:DeleteCollectionItems",
          "aoss:UpdateCollectionItems",
          "aoss:DescribeCollectionItems"
        ]
      },
      {
        ResourceType = "index"
        Resource     = ["index/${local.opensearch_collection_name}-vectors/*"]
        Permission = [
          "aoss:CreateIndex",
          "aoss:DeleteIndex",
          "aoss:UpdateIndex",
          "aoss:DescribeIndex",
          "aoss:ReadDocument",
          "aoss:WriteDocument"
        ]
      }
    ]
    Principal = [aws_iam_role.ecs_task.arn]
  }])
}

resource "aws_opensearchserverless_collection" "vectors" {
  count = var.enable_opensearch_serverless ? 1 : 0

  name = "${local.opensearch_collection_name}-vectors"
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]

  tags = {
    Name  = "${local.name_prefix}-vectors"
    Layer = "knowledge-base"
  }
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_stream" "firehose_raw" {
  name           = "raw-log-delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_cloudwatch_log_stream" "firehose_audit" {
  name           = "audit-log-delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_sqs_queue" "ingestion_dlq" {
  name                      = "${local.name_prefix}-ingestion-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.main.arn
}

resource "aws_sqs_queue" "ingestion_events" {
  name                       = "${local.name_prefix}-ingestion-events"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 345600
  kms_master_key_id          = aws_kms_key.main.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingestion_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "action_events" {
  name                       = "${local.name_prefix}-action-events"
  visibility_timeout_seconds = 120
  kms_master_key_id          = aws_kms_key.main.arn
}

resource "aws_kinesis_firehose_delivery_stream" "raw_logs" {
  name        = "${local.name_prefix}-raw-logs"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.raw_logs.arn
    prefix              = "raw/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/"
    error_output_prefix = "firehose-errors/!{firehose:error-output-type}/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/"
    buffering_interval  = 60
    buffering_size      = 5
    compression_format  = "GZIP"
    kms_key_arn         = aws_kms_key.main.arn

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_raw.name
    }
  }

  server_side_encryption {
    enabled  = true
    key_type = "CUSTOMER_MANAGED_CMK"
    key_arn  = aws_kms_key.main.arn
  }

  tags = {
    Name  = "${local.name_prefix}-raw-firehose"
    Layer = "ingestion"
  }
}

resource "aws_kinesis_firehose_delivery_stream" "audit" {
  name        = "${local.name_prefix}-audit-archive"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.audit.arn
    prefix              = "audit/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/"
    error_output_prefix = "audit-errors/!{firehose:error-output-type}/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/"
    buffering_interval  = 60
    buffering_size      = 5
    compression_format  = "GZIP"
    kms_key_arn         = aws_kms_key.main.arn

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_audit.name
    }
  }

  server_side_encryption {
    enabled  = true
    key_type = "CUSTOMER_MANAGED_CMK"
    key_arn  = aws_kms_key.main.arn
  }

  tags = {
    Name  = "${local.name_prefix}-audit-firehose"
    Layer = "audit"
  }
}

data "archive_file" "preprocessor" {
  type        = "zip"
  output_path = "${path.module}/lambda-preprocessor.zip"

  source {
    filename = "index.py"
    content  = <<-PY
      import gzip
      import json
      import os
      import urllib.parse

      import boto3

      s3 = boto3.client("s3")

      def _decode(body):
          try:
              return gzip.decompress(body).decode("utf-8", errors="replace")
          except Exception:
              return body.decode("utf-8", errors="replace")

      def handler(event, context):
          processed = 0
          destination = os.environ["PROCESSED_BUCKET"]

          for record in event.get("Records", []):
              src_bucket = record["s3"]["bucket"]["name"]
              src_key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
              obj = s3.get_object(Bucket=src_bucket, Key=src_key)
              raw_text = _decode(obj["Body"].read())

              normalized = {
                  "source_bucket": src_bucket,
                  "source_key": src_key,
                  "schema": "ai-native-soc.normalized.v1",
                  "records": [
                      {
                          "message": raw_text[:200000],
                          "pipeline": ["decode", "normalize", "deduplicate", "threat_enrichment"],
                      }
                  ],
              }

              dst_key = f"processed/{src_key}.json"
              s3.put_object(
                  Bucket=destination,
                  Key=dst_key,
                  Body=json.dumps(normalized).encode("utf-8"),
                  ContentType="application/json",
              )
              processed += 1

          return {"processed": processed}
    PY
  }
}

resource "aws_cloudwatch_log_group" "preprocessor" {
  name              = "/aws/lambda/${local.name_prefix}-preprocessor"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_function" "preprocessor" {
  function_name    = "${local.name_prefix}-preprocessor"
  description      = "Decode, normalize, deduplicate, and enrich raw SOC logs"
  role             = aws_iam_role.lambda_preprocessor.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.preprocessor.output_path
  source_code_hash = data.archive_file.preprocessor.output_base64sha256
  timeout          = 60
  memory_size      = 256
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      PROCESSED_BUCKET = aws_s3_bucket.processed_logs.id
      EVENT_QUEUE_URL  = aws_sqs_queue.ingestion_events.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.preprocessor]

  tags = {
    Name  = "${local.name_prefix}-preprocessor"
    Layer = "ingestion"
  }
}

resource "aws_lambda_permission" "allow_raw_logs_s3" {
  statement_id  = "AllowExecutionFromRawLogsS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.preprocessor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw_logs.arn
}

resource "aws_s3_bucket_notification" "raw_logs" {
  bucket = aws_s3_bucket.raw_logs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.preprocessor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
  }

  depends_on = [aws_lambda_permission.allow_raw_logs_s3]
}

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name_prefix}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_extra" {
  name = "${local.name_prefix}-ecs-execution-extra"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "secretsmanager:GetSecretValue"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWriteSocBuckets"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.raw_logs.arn,
          "${aws_s3_bucket.raw_logs.arn}/*",
          aws_s3_bucket.processed_logs.arn,
          "${aws_s3_bucket.processed_logs.arn}/*",
          aws_s3_bucket.layer_artifacts.arn,
          "${aws_s3_bucket.layer_artifacts.arn}/*",
          aws_s3_bucket.audit.arn,
          "${aws_s3_bucket.audit.arn}/*"
        ]
      },
      {
        Sid    = "LeaderElection"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable"
        ]
        Resource = aws_dynamodb_table.leader_lock.arn
      },
      {
        Sid    = "QueuesAndNotifications"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sns:Publish"
        ]
        Resource = [
          aws_sqs_queue.ingestion_events.arn,
          aws_sqs_queue.action_events.arn,
          aws_sns_topic.alerts.arn
        ]
      },
      {
        Sid    = "SecretsAndKms"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "BedrockInference"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      },
      {
        Sid    = "ResponseActions"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "wafv2:GetIPSet",
          "wafv2:UpdateIPSet",
          "states:StartExecution"
        ]
        Resource = "*"
      }
    ]
  })
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_preprocessor" {
  name               = "${local.name_prefix}-lambda-preprocessor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_preprocessor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_preprocessor" {
  name = "${local.name_prefix}-lambda-preprocessor-policy"
  role = aws_iam_role.lambda_preprocessor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.raw_logs.arn}/*",
          "${aws_s3_bucket.processed_logs.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.ingestion_events.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${local.name_prefix}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

resource "aws_iam_role_policy" "firehose" {
  name = "${local.name_prefix}-firehose-policy"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.raw_logs.arn,
          "${aws_s3_bucket.raw_logs.arn}/*",
          aws_s3_bucket.audit.arn,
          "${aws_s3_bucket.audit.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.firehose.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

data "aws_iam_policy_document" "states_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "step_functions" {
  name               = "${local.name_prefix}-step-functions-role"
  assume_role_policy = data.aws_iam_policy_document.states_assume.json
}

resource "aws_iam_role_policy" "step_functions" {
  name = "${local.name_prefix}-step-functions-policy"
  role = aws_iam_role.step_functions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:DescribeLogGroups",
          "logs:DescribeResourcePolicies",
          "logs:GetLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:UpdateLogDelivery",
          "sns:Publish",
          "sqs:SendMessage",
          "ecs:UpdateService",
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "wafv2:GetIPSet",
          "wafv2:UpdateIPSet"
        ]
        Resource = "*"
      }
    ]
  })
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_scheduler" {
  name               = "${local.name_prefix}-eventbridge-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "eventbridge_scheduler" {
  name = "${local.name_prefix}-eventbridge-scheduler-policy"
  role = aws_iam_role.eventbridge_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.orchestrator.arn
      }
    ]
  })
}

data "aws_iam_policy_document" "logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "logs_to_firehose" {
  name               = "${local.name_prefix}-logs-to-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.logs_assume.json
}

resource "aws_iam_role_policy" "logs_to_firehose" {
  name = "${local.name_prefix}-logs-to-firehose-policy"
  role = aws_iam_role.logs_to_firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "firehose:PutRecord",
          "firehose:PutRecordBatch"
        ]
        Resource = aws_kinesis_firehose_delivery_stream.audit.arn
      }
    ]
  })
}

resource "aws_ecr_repository" "service" {
  for_each = local.ecs_services

  name                 = "${local.name_prefix}-${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  tags = {
    Name  = "${local.name_prefix}-${each.key}"
    Layer = "cicd"
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the latest hackathon images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_images_to_keep
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-ecs"

  setting {
    name  = "containerInsights"
    value = var.enable_ecs_container_insights ? "enabled" : "disabled"
  }

  tags = {
    Name  = "${local.name_prefix}-ecs"
    Layer = "compute"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  for_each = local.ecs_services

  name              = "/ecs/${local.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "vector_db_init" {
  name              = "/ecs/${local.name_prefix}/vector-db-init"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lb" "app" {
  name               = substr("${local.name_prefix}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_alb_spare.id]
  idle_timeout       = 60

  tags = {
    Name  = "${local.name_prefix}-alb"
    Layer = "network"
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${substr(local.name_prefix, 0, 20)}-be-tg"
  port        = local.ecs_services["backend-api"].container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200-399"
    path                = local.ecs_services["backend-api"].health_path
    timeout             = 5
    unhealthy_threshold = 3
  }

  tags = {
    Name  = "${local.name_prefix}-backend-tg"
    Layer = "network"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_ecs_task_definition" "service" {
  for_each = local.ecs_services

  family                   = "${local.name_prefix}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.ecs_cpu)
  memory                   = tostring(var.ecs_memory)
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.ecs_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = lookup(var.container_image_overrides, each.key, "${aws_ecr_repository.service[each.key].repository_url}:latest")
      essential = true
      portMappings = [
        {
          containerPort = each.value.container_port
          hostPort      = each.value.container_port
          protocol      = "tcp"
        }
      ]
      environment = concat([
        { name = "APP_NAME", value = each.key },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "RAW_LOG_BUCKET", value = aws_s3_bucket.raw_logs.id },
        { name = "PROCESSED_LOG_BUCKET", value = aws_s3_bucket.processed_logs.id },
        { name = "AUDIT_LOG_BUCKET", value = aws_s3_bucket.audit.id },
        { name = "LEADER_LOCK_TABLE", value = aws_dynamodb_table.leader_lock.name },
        { name = "INGESTION_QUEUE_URL", value = aws_sqs_queue.ingestion_events.url },
        { name = "ACTION_QUEUE_URL", value = aws_sqs_queue.action_events.url },
        { name = "SNS_TOPIC_ARN", value = aws_sns_topic.alerts.arn },
        { name = "RDS_ENDPOINT", value = var.enable_rds ? aws_db_instance.postgres[0].address : "" },
        { name = "REDIS_ENDPOINT", value = var.enable_redis ? aws_elasticache_cluster.redis[0].cache_nodes[0].address : "" }
      ], local.layer_artifact_env, local.vector_db_env, local.llm_env)
      secrets = local.llm_secret_env
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs[each.key].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = {
    Name  = "${local.name_prefix}-${each.key}"
    Layer = "compute"
  }
}

resource "aws_ecs_task_definition" "vector_db_init" {
  family                   = "${local.name_prefix}-vector-db-init"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.ecs_cpu)
  memory                   = tostring(var.ecs_memory)
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.ecs_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name       = "vector-db-init"
      image      = lookup(var.container_image_overrides, "orchestrator-ha", "${aws_ecr_repository.service["orchestrator-ha"].repository_url}:latest")
      essential  = true
      entryPoint = ["python"]
      command    = ["ingest_to_vector_db.py"]
      environment = concat([
        { name = "APP_NAME", value = "vector-db-init" },
        { name = "AWS_REGION", value = var.aws_region }
      ], local.layer_artifact_env, local.vector_db_env, local.llm_env)
      secrets = local.llm_secret_env
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.vector_db_init.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = {
    Name  = "${local.name_prefix}-vector-db-init"
    Layer = "vector-db"
  }
}

resource "aws_ecs_service" "service" {
  for_each = local.ecs_services

  name                   = each.key
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.service[each.key].arn
  desired_count          = each.value.desired_count
  enable_execute_command = true
  wait_for_steady_state  = false

  deployment_minimum_healthy_percent = each.value.desired_count > 1 ? 50 : 0
  deployment_maximum_percent         = 200

  capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = [aws_subnet.private_app.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = each.key == "backend-api" ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.backend.arn
      container_name   = each.key
      container_port   = each.value.container_port
    }
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_execution_managed
  ]

  tags = {
    Name  = "${local.name_prefix}-${each.key}"
    Layer = "compute"
  }
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = aws_kms_key.main.arn

  tags = {
    Name  = "${local.name_prefix}-alerts"
    Layer = "notification"
  }
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.sns_email_subscriptions)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_ses_email_identity" "notification_sender" {
  count = var.ses_identity_email == null ? 0 : 1

  email = var.ses_identity_email
}

resource "aws_secretsmanager_secret" "llm" {
  count = var.dashscope_api_key != "" ? 1 : 0

  name        = "${local.name_prefix}/llm/dashscope"
  description = "DashScope API key for Qwen LLM runtime"
  kms_key_id  = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret_version" "llm" {
  count = var.dashscope_api_key != "" ? 1 : 0

  secret_id     = aws_secretsmanager_secret.llm[0].id
  secret_string = var.dashscope_api_key
}

resource "aws_secretsmanager_secret" "external_connectors" {
  name        = "${local.name_prefix}/external-connectors"
  description = "Telegram, Slack, Jira, and ServiceNow tokens for action connectors"
  kms_key_id  = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret_version" "external_connectors" {
  secret_id = aws_secretsmanager_secret.external_connectors.id
  secret_string = jsonencode({
    telegram_bot_token = var.telegram_bot_token
    slack_webhook_url  = var.slack_webhook_url
    jira_base_url      = var.jira_base_url
    jira_api_token     = var.jira_api_token
    servicenow_url     = var.servicenow_url
  })
}

resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/vendedlogs/states/${local.name_prefix}-orchestrator"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_sfn_state_machine" "orchestrator" {
  name     = "${local.name_prefix}-playbook-orchestrator"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "AI-Native SOC cost-optimized orchestration and action workflow"
    StartAt = "AggregateDecision"
    States = {
      AggregateDecision = {
        Type   = "Pass"
        Result = "Aggregate alerts, correlate context, and evaluate policy thresholds"
        Next   = "ActionPlan"
      }
      ActionPlan = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.auto_execute"
            BooleanEquals = true
            Next          = "AutoExecute"
          }
        ]
        Default = "SuggestOnly"
      }
      AutoExecute = {
        Type = "Parallel"
        Branches = [
          {
            StartAt = "IsolateHost"
            States = {
              IsolateHost = {
                Type   = "Pass"
                Result = "SSM isolate host"
                End    = true
              }
            }
          },
          {
            StartAt = "BlockIP"
            States = {
              BlockIP = {
                Type   = "Pass"
                Result = "Update WAF or security group block list"
                End    = true
              }
            }
          },
          {
            StartAt = "NotifySOC"
            States = {
              NotifySOC = {
                Type   = "Pass"
                Result = "Publish SNS / Telegram / Slack / Jira notification"
                End    = true
              }
            }
          }
        ]
        Next = "DecisionResult"
      }
      SuggestOnly = {
        Type   = "Pass"
        Result = "Generate suggestion-only action plan"
        Next   = "DecisionResult"
      }
      DecisionResult = {
        Type = "Pass"
        Result = {
          status = "completed"
          output = "decision-result-json"
        }
        End = true
      }
    }
  })

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
  }

  tags = {
    Name  = "${local.name_prefix}-playbook-orchestrator"
    Layer = "orchestration"
  }
}

resource "aws_cloudwatch_event_rule" "hourly_rotation" {
  name                = "${local.name_prefix}-hourly-orchestrator-rotation"
  description         = "Hourly active/standby orchestrator rotation trigger"
  schedule_expression = var.orchestrator_rotation_schedule
}

resource "aws_cloudwatch_event_target" "hourly_rotation" {
  rule     = aws_cloudwatch_event_rule.hourly_rotation.name
  arn      = aws_sfn_state_machine.orchestrator.arn
  role_arn = aws_iam_role.eventbridge_scheduler.arn

  input = jsonencode({
    source       = "eventbridge-scheduler"
    rotation     = "hourly"
    auto_execute = false
  })
}

resource "aws_cloudfront_origin_access_control" "dashboard" {
  name                              = "${local.name_prefix}-dashboard-oac"
  description                       = "OAC for private SOC dashboard bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${local.name_prefix} SOC dashboard"
  price_class         = var.cloudfront_price_class

  origin {
    domain_name              = aws_s3_bucket.dashboard.bucket_regional_domain_name
    origin_id                = "dashboard-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "dashboard-s3"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 300
    max_ttl                = 3600
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name  = "${local.name_prefix}-dashboard"
    Layer = "reporting"
  }
}

data "aws_iam_policy_document" "dashboard_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.dashboard.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.dashboard.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  policy = data.aws_iam_policy_document.dashboard_bucket.json
}

resource "aws_cloudwatch_dashboard" "soc" {
  dashboard_name = "${local.name_prefix}-soc"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Requests and 5XX"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.app.arn_suffix],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."]
          ]
          stat = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ECS CPU and Memory"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", "backend-api"],
            [".", "MemoryUtilization", ".", ".", ".", "."],
            [".", "CPUUtilization", ".", ".", ".", "orchestrator-ha"],
            [".", "MemoryUtilization", ".", ".", ".", "."]
          ]
          stat = "Average"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "Recent SOC Service Logs"
          region = var.aws_region
          query  = "SOURCE '/ecs/${local.name_prefix}/backend-api' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name_prefix}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.alarm_alb_5xx_threshold
  alarm_description   = "ALB is returning 5xx errors"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  for_each = local.ecs_services

  alarm_name          = "${local.name_prefix}-${each.key}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_ecs_cpu_threshold
  alarm_description   = "ECS service CPU is high"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = each.key
  }
}

resource "aws_xray_sampling_rule" "default" {
  rule_name      = "${substr(local.name_prefix, 0, 24)}-xray"
  priority       = 9999
  version        = 1
  reservoir_size = 1
  fixed_rate     = 0.05
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
}

resource "aws_cloudwatch_log_subscription_filter" "ecs_to_audit" {
  for_each = aws_cloudwatch_log_group.ecs

  name            = "to-audit-firehose"
  log_group_name  = each.value.name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.audit.arn
  role_arn        = aws_iam_role.logs_to_firehose.arn
  distribution    = "ByLogStream"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints

  tags = {
    Name  = "${local.name_prefix}-github-oidc"
    Layer = "cicd"
  }
}

data "aws_iam_policy_document" "github_actions_assume" {
  count = var.enable_github_oidc ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  count = var.enable_github_oidc ? 1 : 0

  name               = "${local.name_prefix}-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume[0].json

  tags = {
    Name  = "${local.name_prefix}-github-actions-role"
    Layer = "cicd"
  }
}

resource "aws_iam_role_policy" "github_actions" {
  count = var.enable_github_oidc ? 1 : 0

  name = "${local.name_prefix}-github-actions-policy"
  role = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = [for repo in aws_ecr_repository.service : repo.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "iam:PassRole"
        ]
        Resource = "*"
      }
    ]
  })
}
