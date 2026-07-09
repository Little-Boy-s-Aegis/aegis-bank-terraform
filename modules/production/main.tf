data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  count = var.restrict_alb_to_cloudfront ? 1 : 0

  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "random_password" "db" {
  length  = 32
  special = true
}

locals {
  name_prefix                = "${var.project_name}-${var.environment}"
  bucket_base                = "${replace(local.name_prefix, "_", "-")}-${random_id.bucket_suffix.hex}"
  app_origin_domain_name     = var.alb_origin_domain_name != "" && var.alb_certificate_arn != "" ? var.alb_origin_domain_name : aws_lb.app.dns_name
  app_origin_protocol_policy = var.alb_origin_domain_name != "" && var.alb_certificate_arn != "" ? "https-only" : "http-only"
  opensearch_domain_name     = substr(replace("${local.name_prefix}-vectors", "_", "-"), 0, 28)
  layer1_schema_version      = "littleboy.soc.layer1.agent_finding.v4"
  layer2_schema_version      = "littleboy.soc.layer2.orchestrator_decision.v8"
  vector_l1_index            = "l1-threat-intel"
  vector_l2_index            = "l2-playbooks"
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
    { name = "VECTOR_DB_PROVIDER", value = "opensearch" },
    { name = "QDRANT_URL", value = "" },
    { name = "OPENSEARCH_ENDPOINT", value = "https://${aws_opensearch_domain.vectors.endpoint}" },
    { name = "OPENSEARCH_SERVICE", value = "es" },
    { name = "OPENSEARCH_L1_INDEX", value = local.vector_l1_index },
    { name = "OPENSEARCH_L2_INDEX", value = local.vector_l2_index }
  ]

  az_names = [
    coalesce(var.availability_zone, data.aws_availability_zones.available.names[0]),
    data.aws_availability_zones.available.names[1]
  ]

  azs = {
    a = {
      name          = local.az_names[0]
      public_cidr   = "10.0.1.0/24"
      app_cidr      = "10.0.11.0/24"
      security_cidr = "10.0.21.0/24"
      data_cidr     = "10.0.31.0/24"
    }
    b = {
      name          = local.az_names[1]
      public_cidr   = "10.0.101.0/24"
      app_cidr      = "10.0.111.0/24"
      security_cidr = "10.0.121.0/24"
      data_cidr     = "10.0.131.0/24"
    }
  }

  app_services = {
    backend-api = {
      container_port = 8080
      desired_count  = max(var.ecs_desired_count, 2)
      health_path    = "/health"
      layer          = "api"
    }
    layer1-auth-agent = {
      container_port = 8081
      desired_count  = max(var.ecs_desired_count, 2)
      health_path    = "/health"
      layer          = "layer1"
    }
    layer1-api-agent = {
      container_port = 8082
      desired_count  = max(var.ecs_desired_count, 2)
      health_path    = "/health"
      layer          = "layer1"
    }
    layer1-infra-agent = {
      container_port = 8083
      desired_count  = max(var.ecs_desired_count, 2)
      health_path    = "/health"
      layer          = "layer1"
    }
    layer2-meta-analyzer = {
      container_port = 8084
      desired_count  = max(var.ecs_desired_count, 2)
      health_path    = "/health"
      layer          = "layer2"
    }
    worker-service = {
      container_port = 8085
      desired_count  = max(var.ecs_desired_count, 2)
      health_path    = "/health"
      layer          = "worker"
    }
    orchestrator-active = {
      container_port = 8086
      desired_count  = 1
      health_path    = "/health"
      layer          = "orchestration"
    }
    orchestrator-standby = {
      container_port = 8087
      desired_count  = max(var.orchestrator_desired_count - 1, 1)
      health_path    = "/health"
      layer          = "orchestration"
    }
  }

  security_services = {
    opa-policy-engine = {
      container_port = 8181
      desired_count  = 2
      health_path    = "/health"
    }
    internal-connectors = {
      container_port = 8090
      desired_count  = 2
      health_path    = "/health"
    }
    ssm-utilities = {
      container_port = 8091
      desired_count  = 2
      health_path    = "/health"
    }
  }

  ecr_repositories = merge(local.app_services, local.security_services)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-prod-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-prod-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.azs

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.public_cidr
  availability_zone       = each.value.name
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "private_app" {
  for_each = local.azs

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.app_cidr
  availability_zone       = each.value.name
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-app-${each.key}"
    Tier = "private-app"
  }
}

resource "aws_subnet" "private_security" {
  for_each = local.azs

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.security_cidr
  availability_zone       = each.value.name
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-security-${each.key}"
    Tier = "private-security"
  }
}

resource "aws_subnet" "private_data" {
  for_each = local.azs

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.data_cidr
  availability_zone       = each.value.name
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-data-${each.key}"
    Tier = "private-data"
  }
}

resource "aws_eip" "nat" {
  for_each = local.azs

  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip-${each.key}"
  }
}

resource "aws_nat_gateway" "nat" {
  for_each = local.azs

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = {
    Name = "${local.name_prefix}-nat-${each.key}"
  }

  depends_on = [aws_internet_gateway.main]
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
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = local.azs

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[each.key].id
  }

  tags = {
    Name = "${local.name_prefix}-private-rt-${each.key}"
  }
}

resource "aws_route_table_association" "private_app" {
  for_each = aws_subnet.private_app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "private_security" {
  for_each = aws_subnet.private_security

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "private_data" {
  for_each = aws_subnet.private_data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = {
    Name = "${local.name_prefix}-s3-gateway-endpoint"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = {
    Name = "${local.name_prefix}-dynamodb-gateway-endpoint"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-prod-vpce-sg"
  description = "PrivateLink endpoint access"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-prod-vpce-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoint_https_from_ecs" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 443
  ip_protocol                  = "tcp"
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "vpc_endpoint_vpc" {
  security_group_id = aws_security_group.vpc_endpoints.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset([
    "ecr.api",
    "ecr.dkr",
    "ecs",
    "ecs-agent",
    "ecs-telemetry",
    "logs",
    "secretsmanager",
    "kms",
    "ssm",
    "sts",
    "sns",
    "sqs",
    "xray",
    "bedrock-runtime"
  ])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = concat([for subnet in aws_subnet.private_app : subnet.id], [for subnet in aws_subnet.private_security : subnet.id])
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
    sid    = "AllowAwsServicesForProductionSoc"
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
        "cloudtrail.amazonaws.com",
        "cloudwatch.amazonaws.com",
        "config.amazonaws.com",
        "dynamodb.amazonaws.com",
        "ec2.amazonaws.com",
        "ecs.amazonaws.com",
        "elasticache.amazonaws.com",
        "es.amazonaws.com",
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
  description             = "KMS key for AI-Native SOC production data"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json

  tags = {
    Name = "${local.name_prefix}-prod-kms"
  }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}-prod"
  target_key_id = aws_kms_key.main.key_id
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-prod-alb-sg"
  description = "Public ALB security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-prod-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = var.restrict_alb_to_cloudfront ? toset([]) : toset(var.allowed_http_cidr_blocks)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = var.restrict_alb_to_cloudfront ? toset([]) : toset(var.allowed_http_cidr_blocks)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_from_cloudfront" {
  count = var.restrict_alb_to_cloudfront ? 1 : 0

  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[0].id
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_from_cloudfront" {
  count = var.restrict_alb_to_cloudfront ? 1 : 0

  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[0].id
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 8080
  ip_protocol                  = "tcp"
  to_port                      = 8087
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name_prefix}-prod-ecs-sg"
  description = "Private ECS app services"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-prod-ecs-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs_tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  ip_protocol                  = "tcp"
  to_port                      = 8087
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_security" {
  security_group_id            = aws_security_group.ecs_tasks.id
  referenced_security_group_id = aws_security_group.security_services.id
  from_port                    = 8080
  ip_protocol                  = "tcp"
  to_port                      = 8087
}

resource "aws_vpc_security_group_egress_rule" "ecs_all_egress" {
  security_group_id = aws_security_group.ecs_tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "security_services" {
  name        = "${local.name_prefix}-prod-security-services-sg"
  description = "OPA, connectors, and SSM utility services"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-prod-security-services-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "security_from_ecs" {
  security_group_id            = aws_security_group.security_services.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 8090
  ip_protocol                  = "tcp"
  to_port                      = 8181
}

resource "aws_vpc_security_group_egress_rule" "security_all_egress" {
  security_group_id = aws_security_group.security_services.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-prod-rds-sg"
  description = "PostgreSQL access from ECS only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-prod-rds-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ecs" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 5432
  ip_protocol                  = "tcp"
  to_port                      = 5432
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-prod-redis-sg"
  description = "Redis access from ECS only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-prod-redis-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_ecs" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 6379
  ip_protocol                  = "tcp"
  to_port                      = 6379
}

resource "aws_security_group" "opensearch" {
  name        = "${local.name_prefix}-prod-opensearch-sg"
  description = "OpenSearch access from ECS and security services"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-prod-opensearch-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_from_ecs" {
  security_group_id            = aws_security_group.opensearch.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 443
  ip_protocol                  = "tcp"
  to_port                      = 443
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_from_security" {
  security_group_id            = aws_security_group.opensearch.id
  referenced_security_group_id = aws_security_group.security_services.id
  from_port                    = 443
  ip_protocol                  = "tcp"
  to_port                      = 443
}

resource "aws_wafv2_web_acl" "alb" {
  name        = "${local.name_prefix}-prod-alb-waf"
  description = "Production WAF with AWS managed rule groups"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesCommonRuleSet          = 10
      AWSManagedRulesKnownBadInputsRuleSet  = 20
      AWSManagedRulesAmazonIpReputationList = 30
      AWSManagedRulesSQLiRuleSet            = 40
    }

    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name_prefix}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-prod-alb-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.name_prefix}-prod-alb-waf"
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.app.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

resource "aws_s3_bucket" "raw_logs" {
  bucket              = "${local.bucket_base}-raw-logs"
  force_destroy       = var.force_destroy_buckets
  object_lock_enabled = true

  tags = {
    Name  = "${local.name_prefix}-prod-raw-logs"
    Layer = "ingestion"
  }
}

resource "aws_s3_bucket" "processed_logs" {
  bucket        = "${local.bucket_base}-processed-logs"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name  = "${local.name_prefix}-prod-processed-logs"
    Layer = "analysis"
  }
}

resource "aws_s3_bucket" "dashboard" {
  bucket        = "${local.bucket_base}-dashboard"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name  = "${local.name_prefix}-prod-dashboard"
    Layer = "reporting"
  }
}

resource "aws_s3_bucket" "layer_artifacts" {
  bucket        = "${local.bucket_base}-layer-artifacts"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name  = "${local.name_prefix}-prod-layer-artifacts"
    Layer = "layer-contracts"
  }
}

resource "aws_s3_bucket" "audit" {
  bucket              = "${local.bucket_base}-audit-logs"
  force_destroy       = var.force_destroy_buckets
  object_lock_enabled = true

  tags = {
    Name  = "${local.name_prefix}-prod-audit-logs"
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

resource "aws_s3_bucket_object_lock_configuration" "raw_logs" {
  bucket     = aws_s3_bucket.raw_logs.id
  depends_on = [aws_s3_bucket_versioning.versioned]

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = max(var.audit_retention_days, 90)
    }
  }
}

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket     = aws_s3_bucket.audit.id
  depends_on = [aws_s3_bucket_versioning.versioned]

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = max(var.audit_retention_days, 365)
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

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  for_each = {
    raw       = aws_s3_bucket.raw_logs.id
    processed = aws_s3_bucket.processed_logs.id
    audit     = aws_s3_bucket.audit.id
  }

  bucket = each.value

  rule {
    id     = "production-retention-tiering"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 180
      storage_class = "GLACIER"
    }
  }
}

resource "aws_s3_object" "dashboard_placeholder" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "index.html"
  content_type = "text/html"
  content      = "<!doctype html><html><body><h1>AI-Native SOC Production Dashboard</h1></body></html>"
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
  name        = "${local.name_prefix}/production/database/postgres"
  description = "Generated PostgreSQL credentials for production SOC metadata"
  kms_key_id  = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    database = var.db_name
  })
}

resource "aws_db_subnet_group" "postgres" {
  name       = "${local.name_prefix}-prod-db-subnets"
  subnet_ids = [for subnet in aws_subnet.private_data : subnet.id]

  tags = {
    Name = "${local.name_prefix}-prod-db-subnets"
  }
}

resource "aws_db_instance" "postgres" {
  identifier                 = "${local.name_prefix}-prod-postgres"
  engine                     = "postgres"
  engine_version             = var.postgres_engine_version
  instance_class             = var.postgres_instance_class
  allocated_storage          = max(var.postgres_allocated_storage_gb, 50)
  max_allocated_storage      = max(var.postgres_max_storage_gb, 200)
  db_name                    = var.db_name
  username                   = var.db_username
  password                   = random_password.db.result
  db_subnet_group_name       = aws_db_subnet_group.postgres.name
  vpc_security_group_ids     = [aws_security_group.rds.id]
  multi_az                   = true
  publicly_accessible        = false
  storage_encrypted          = true
  kms_key_id                 = aws_kms_key.main.arn
  backup_retention_period    = max(var.db_backup_retention_days, 7)
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${local.name_prefix}-prod-final"
  auto_minor_version_upgrade = true

  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.main.arn

  tags = {
    Name  = "${local.name_prefix}-prod-postgres"
    Layer = "data"
  }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name_prefix}-prod-redis-subnets"
  subnet_ids = [for subnet in aws_subnet.private_data : subnet.id]
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = substr("${local.name_prefix}-prod-redis", 0, 40)
  description                = "Production Redis cache and session replication"
  engine                     = "redis"
  engine_version             = var.redis_engine_version
  node_type                  = var.redis_node_type
  port                       = 6379
  num_node_groups            = 1
  replicas_per_node_group    = 1
  automatic_failover_enabled = true
  multi_az_enabled           = true
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = aws_kms_key.main.arn

  tags = {
    Name  = "${local.name_prefix}-prod-redis"
    Layer = "data"
  }
}

resource "aws_dynamodb_table" "leader_lock" {
  name         = "${local.name_prefix}-prod-leader-lock"
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
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  tags = {
    Name  = "${local.name_prefix}-prod-leader-lock"
    Layer = "orchestration"
  }
}

data "aws_iam_policy_document" "opensearch_access" {
  statement {
    actions = ["es:ESHttp*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ecs_task.arn]
    }

    resources = [
      "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/${local.opensearch_domain_name}/*"
    ]
  }
}

resource "aws_opensearch_domain" "vectors" {
  domain_name     = local.opensearch_domain_name
  engine_version  = "OpenSearch_2.13"
  access_policies = data.aws_iam_policy_document.opensearch_access.json

  cluster_config {
    instance_type          = "t3.small.search"
    instance_count         = 2
    zone_awareness_enabled = true

    zone_awareness_config {
      availability_zone_count = 2
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 50
    volume_type = "gp3"
  }

  vpc_options {
    subnet_ids         = [for subnet in aws_subnet.private_data : subnet.id]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = aws_kms_key.main.arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true

    master_user_options {
      master_user_name     = "soc_master"
      master_user_password = random_password.db.result
    }
  }

  tags = {
    Name  = "${local.name_prefix}-prod-vectors"
    Layer = "knowledge-base"
  }
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
  name               = "${local.name_prefix}-prod-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_extra" {
  name = "${local.name_prefix}-prod-ecs-execution-extra"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "secretsmanager:GetSecretValue"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.name_prefix}-prod-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.name_prefix}-prod-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SocBuckets"
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
        Sid    = "QueuesStreamsNotifications"
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListShards",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sns:Publish"
        ]
        Resource = [
          aws_kinesis_stream.ingestion.arn,
          aws_sqs_queue.ingestion_events.arn,
          aws_sqs_queue.action_events.arn,
          aws_sns_topic.alerts.arn
        ]
      },
      {
        Sid    = "OpenSearchVectorStore"
        Effect = "Allow"
        Action = [
          "es:ESHttpGet",
          "es:ESHttpPost",
          "es:ESHttpPut",
          "es:ESHttpDelete"
        ]
        Resource = "${aws_opensearch_domain.vectors.arn}/*"
      },
      {
        Sid    = "BedrockInference"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = var.bedrock_model_arns
      },
      {
        Sid    = "SageMakerRuntime"
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint"
        ]
        Resource = length(var.sagemaker_endpoint_arns) > 0 ? var.sagemaker_endpoint_arns : [
          "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/*"
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
        Resource = [
          aws_secretsmanager_secret.db.arn,
          aws_secretsmanager_secret.external_connectors.arn,
          aws_kms_key.main.arn
        ]
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
  name               = "${local.name_prefix}-prod-lambda-preprocessor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_preprocessor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_preprocessor" {
  name = "${local.name_prefix}-prod-lambda-preprocessor-policy"
  role = aws_iam_role.lambda_preprocessor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "sqs:SendMessage",
          "kinesis:DescribeStream",
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:ListShards"
        ]
        Resource = [
          "${aws_s3_bucket.raw_logs.arn}/*",
          "${aws_s3_bucket.processed_logs.arn}/*",
          aws_sqs_queue.ingestion_events.arn,
          aws_kinesis_stream.ingestion.arn
        ]
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
  name               = "${local.name_prefix}-prod-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

resource "aws_iam_role_policy" "firehose" {
  name = "${local.name_prefix}-prod-firehose-policy"
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
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
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
  name               = "${local.name_prefix}-prod-step-functions-role"
  assume_role_policy = data.aws_iam_policy_document.states_assume.json
}

resource "aws_iam_role_policy" "step_functions" {
  name = "${local.name_prefix}-prod-step-functions-policy"
  role = aws_iam_role.step_functions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogDelivery",
        "logs:GetLogDelivery",
        "logs:UpdateLogDelivery",
        "logs:DeleteLogDelivery",
        "logs:ListLogDeliveries",
        "logs:PutResourcePolicy",
        "logs:DescribeResourcePolicies",
        "logs:DescribeLogGroups",
        "sns:Publish",
        "sqs:SendMessage",
        "ecs:UpdateService",
        "ssm:SendCommand",
        "ssm:GetCommandInvocation",
        "wafv2:GetIPSet",
        "wafv2:UpdateIPSet"
      ]
      Resource = "*"
    }]
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
  name               = "${local.name_prefix}-prod-eventbridge-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "eventbridge_scheduler" {
  name = "${local.name_prefix}-prod-eventbridge-policy"
  role = aws_iam_role.eventbridge_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.orchestrator.arn
    }]
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
  name               = "${local.name_prefix}-prod-logs-to-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.logs_assume.json
}

resource "aws_iam_role_policy" "logs_to_firehose" {
  name = "${local.name_prefix}-prod-logs-to-firehose-policy"
  role = aws_iam_role.logs_to_firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch"
      ]
      Resource = aws_kinesis_firehose_delivery_stream.audit.arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.name_prefix}-prod"
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

resource "aws_kinesis_stream" "ingestion" {
  name             = "${local.name_prefix}-prod-ingestion"
  shard_count      = 2
  retention_period = 48

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  encryption_type = "KMS"
  kms_key_id      = aws_kms_key.main.arn

  tags = {
    Name  = "${local.name_prefix}-prod-ingestion"
    Layer = "ingestion"
  }
}

resource "aws_sqs_queue" "ingestion_dlq" {
  name                      = "${local.name_prefix}-prod-ingestion-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.main.arn
}

resource "aws_sqs_queue" "ingestion_events" {
  name                       = "${local.name_prefix}-prod-ingestion-events"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  kms_master_key_id          = aws_kms_key.main.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingestion_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue" "action_events" {
  name                       = "${local.name_prefix}-prod-action-events"
  visibility_timeout_seconds = 180
  kms_master_key_id          = aws_kms_key.main.arn
}

resource "aws_kinesis_firehose_delivery_stream" "raw_logs" {
  name        = "${local.name_prefix}-prod-raw-logs"
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
    Name  = "${local.name_prefix}-prod-raw-firehose"
    Layer = "ingestion"
  }
}

resource "aws_kinesis_firehose_delivery_stream" "audit" {
  name        = "${local.name_prefix}-prod-audit-archive"
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
    Name  = "${local.name_prefix}-prod-audit-firehose"
    Layer = "audit"
  }
}

data "archive_file" "preprocessor" {
  type        = "zip"
  output_path = "${path.module}/lambda-preprocessor.zip"

  source {
    filename = "index.py"
    content  = <<-PY
      import base64
      import gzip
      import json
      import os
      import time

      import boto3

      s3 = boto3.client("s3")
      sqs = boto3.client("sqs")

      def _decode(payload):
          try:
              raw = gzip.decompress(payload)
          except Exception:
              raw = payload
          return raw.decode("utf-8", errors="replace")

      def handler(event, context):
          destination = os.environ["PROCESSED_BUCKET"]
          queue_url = os.environ["EVENT_QUEUE_URL"]
          written = 0

          for record in event.get("Records", []):
              if "kinesis" in record:
                  payload = base64.b64decode(record["kinesis"]["data"])
                  source = "kinesis"
                  source_key = f"kinesis/{record['eventID']}.json"
              elif "s3" in record:
                  source = "s3"
                  bucket = record["s3"]["bucket"]["name"]
                  key = record["s3"]["object"]["key"]
                  payload = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
                  source_key = key
              else:
                  continue

              message = _decode(payload)
              normalized = {
                  "schema": "ai-native-soc.production.normalized.v1",
                  "source": source,
                  "source_key": source_key,
                  "pipeline": ["decode", "deobfuscate", "deduplicate", "normalize", "parse", "threat_enrichment"],
                  "ingested_at_epoch": int(time.time()),
                  "message": message[:200000],
              }

              dst_key = f"processed/{source_key}.json"
              body = json.dumps(normalized).encode("utf-8")
              s3.put_object(Bucket=destination, Key=dst_key, Body=body, ContentType="application/json")
              sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps({"bucket": destination, "key": dst_key}))
              written += 1

          return {"processed": written}
    PY
  }
}

resource "aws_cloudwatch_log_group" "preprocessor" {
  name              = "/aws/lambda/${local.name_prefix}-prod-preprocessor"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_function" "preprocessor" {
  function_name    = "${local.name_prefix}-prod-preprocessor"
  description      = "Production decode, normalize, deduplicate, and enrich pipeline"
  role             = aws_iam_role.lambda_preprocessor.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.preprocessor.output_path
  source_code_hash = data.archive_file.preprocessor.output_base64sha256
  timeout          = 120
  memory_size      = 512
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      PROCESSED_BUCKET = aws_s3_bucket.processed_logs.id
      EVENT_QUEUE_URL  = aws_sqs_queue.ingestion_events.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.preprocessor]

  tags = {
    Name  = "${local.name_prefix}-prod-preprocessor"
    Layer = "ingestion"
  }
}

resource "aws_lambda_event_source_mapping" "kinesis_to_preprocessor" {
  event_source_arn                   = aws_kinesis_stream.ingestion.arn
  function_name                      = aws_lambda_function.preprocessor.arn
  starting_position                  = "LATEST"
  batch_size                         = 100
  maximum_batching_window_in_seconds = 30
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

resource "aws_ecr_repository" "service" {
  for_each = local.ecr_repositories

  name                 = "${local.name_prefix}-prod-${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  tags = {
    Name  = "${local.name_prefix}-prod-${each.key}"
    Layer = "cicd"
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep production rollback window"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = max(var.ecr_images_to_keep, 20)
      }
      action = {
        type = "expire"
      }
    }]
  })
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-prod-ecs"

  setting {
    name  = "containerInsights"
    value = var.enable_ecs_container_insights ? "enabled" : "disabled"
  }

  tags = {
    Name  = "${local.name_prefix}-prod-ecs"
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
  for_each = local.ecr_repositories

  name              = "/ecs/${local.name_prefix}/prod/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "vector_db_init" {
  name              = "/ecs/${local.name_prefix}/prod/vector-db-init"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lb" "app" {
  name               = substr("${local.name_prefix}-prod-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]
  idle_timeout       = 60

  tags = {
    Name  = "${local.name_prefix}-prod-alb"
    Layer = "network"
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${substr(local.name_prefix, 0, 18)}-prod-be-tg"
  port        = local.app_services["backend-api"].container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200-399"
    path                = "/health"
    timeout             = 5
    unhealthy_threshold = 3
  }

  tags = {
    Name  = "${local.name_prefix}-prod-backend-tg"
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

resource "aws_lb_listener" "https" {
  count = var.alb_certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.alb_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_ecs_task_definition" "app" {
  for_each = local.app_services

  family                   = "${local.name_prefix}-prod-${each.key}"
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
      portMappings = [{
        containerPort = each.value.container_port
        hostPort      = each.value.container_port
        protocol      = "tcp"
      }]
      environment = concat([
        { name = "APP_NAME", value = each.key },
        { name = "APP_LAYER", value = each.value.layer },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "RAW_LOG_BUCKET", value = aws_s3_bucket.raw_logs.id },
        { name = "PROCESSED_LOG_BUCKET", value = aws_s3_bucket.processed_logs.id },
        { name = "AUDIT_LOG_BUCKET", value = aws_s3_bucket.audit.id },
        { name = "INGESTION_STREAM_NAME", value = aws_kinesis_stream.ingestion.name },
        { name = "INGESTION_QUEUE_URL", value = aws_sqs_queue.ingestion_events.url },
        { name = "ACTION_QUEUE_URL", value = aws_sqs_queue.action_events.url },
        { name = "LEADER_LOCK_TABLE", value = aws_dynamodb_table.leader_lock.name },
        { name = "SNS_TOPIC_ARN", value = aws_sns_topic.alerts.arn },
        { name = "RDS_ENDPOINT", value = aws_db_instance.postgres.address },
        { name = "REDIS_ENDPOINT", value = aws_elasticache_replication_group.redis.primary_endpoint_address }
      ], local.layer_artifact_env, local.vector_db_env)
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
    Name  = "${local.name_prefix}-prod-${each.key}"
    Layer = "compute"
  }
}

resource "aws_ecs_task_definition" "security" {
  for_each = local.security_services

  family                   = "${local.name_prefix}-prod-${each.key}"
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
      portMappings = [{
        containerPort = each.value.container_port
        hostPort      = each.value.container_port
        protocol      = "tcp"
      }]
      environment = [
        { name = "APP_NAME", value = each.key },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ACTION_QUEUE_URL", value = aws_sqs_queue.action_events.url },
        { name = "EXTERNAL_CONNECTORS_SECRET_ARN", value = aws_secretsmanager_secret.external_connectors.arn }
      ]
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
    Name  = "${local.name_prefix}-prod-${each.key}"
    Layer = "security"
  }
}

resource "aws_ecs_task_definition" "vector_db_init" {
  family                   = "${local.name_prefix}-prod-vector-db-init"
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
      image      = lookup(var.container_image_overrides, "orchestrator-active", "${aws_ecr_repository.service["orchestrator-active"].repository_url}:latest")
      essential  = true
      entryPoint = ["python"]
      command    = ["ingest_to_vector_db.py"]
      environment = concat([
        { name = "APP_NAME", value = "vector-db-init" },
        { name = "AWS_REGION", value = var.aws_region }
      ], local.layer_artifact_env, local.vector_db_env)
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
    Name  = "${local.name_prefix}-prod-vector-db-init"
    Layer = "vector-db"
  }
}

resource "aws_ecs_service" "app" {
  for_each = local.app_services

  name                   = each.key
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.app[each.key].arn
  desired_count          = each.value.desired_count
  enable_execute_command = true
  wait_for_steady_state  = false

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = [for subnet in aws_subnet.private_app : subnet.id]
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
    Name  = "${local.name_prefix}-prod-${each.key}"
    Layer = "compute"
  }
}

resource "aws_ecs_service" "security" {
  for_each = local.security_services

  name                   = each.key
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.security[each.key].arn
  desired_count          = each.value.desired_count
  enable_execute_command = true
  wait_for_steady_state  = false

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = [for subnet in aws_subnet.private_security : subnet.id]
    security_groups  = [aws_security_group.security_services.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.ecs_execution_managed
  ]

  tags = {
    Name  = "${local.name_prefix}-prod-${each.key}"
    Layer = "security"
  }
}

locals {
  app_edge_aliases = var.app_domain_name != "" && var.app_certificate_arn != "" ? [var.app_domain_name] : []
}

resource "aws_cloudfront_distribution" "app_edge" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.name_prefix} production edge distribution for ALB"
  price_class     = var.cloudfront_price_class
  aliases         = local.app_edge_aliases
  http_version    = "http2"

  origin {
    domain_name = local.app_origin_domain_name
    origin_id   = "app-alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = local.app_origin_protocol_policy
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "app-alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0

    forwarded_values {
      query_string = true
      headers      = ["*"]

      cookies {
        forward = "all"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.app_certificate_arn == ""
    acm_certificate_arn            = var.app_certificate_arn != "" ? var.app_certificate_arn : null
    ssl_support_method             = var.app_certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = var.app_certificate_arn != "" ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = {
    Name  = "${local.name_prefix}-prod-app-edge"
    Layer = "edge"
  }

  depends_on = [aws_lb_listener.http, aws_lb_listener.https]
}

resource "aws_route53_record" "alb_origin_a" {
  count = var.alb_origin_domain_name != "" && var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.alb_origin_domain_name
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "app_edge_a" {
  count = length(local.app_edge_aliases) > 0 && var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.app_domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app_edge.domain_name
    zone_id                = aws_cloudfront_distribution.app_edge.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "app_edge_aaaa" {
  count = length(local.app_edge_aliases) > 0 && var.route53_zone_id != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.app_domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.app_edge.domain_name
    zone_id                = aws_cloudfront_distribution.app_edge.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_shield_protection" "app_edge" {
  count = var.enable_shield_advanced ? 1 : 0

  name         = "${local.name_prefix}-app-edge-shield"
  resource_arn = aws_cloudfront_distribution.app_edge.arn
}

resource "aws_shield_protection" "alb" {
  count = var.enable_shield_advanced ? 1 : 0

  name         = "${local.name_prefix}-alb-shield"
  resource_arn = aws_lb.app.arn
}

resource "aws_shield_protection" "dashboard" {
  count = var.enable_shield_advanced ? 1 : 0

  name         = "${local.name_prefix}-dashboard-shield"
  resource_arn = aws_cloudfront_distribution.dashboard.arn
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-prod-alerts"
  kms_master_key_id = aws_kms_key.main.arn

  tags = {
    Name  = "${local.name_prefix}-prod-alerts"
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

resource "aws_secretsmanager_secret" "external_connectors" {
  name        = "${local.name_prefix}/production/external-connectors"
  description = "Telegram, Slack, Jira, ServiceNow, EDR, and identity connector tokens"
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
  name              = "/aws/vendedlogs/states/${local.name_prefix}-prod-orchestrator"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_sfn_state_machine" "orchestrator" {
  name     = "${local.name_prefix}-prod-playbook-orchestrator"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Production AI-Native SOC orchestration workflow"
    StartAt = "NormalizeDecision"
    States = {
      NormalizeDecision = {
        Type = "Pass"
        Result = {
          stage = "decision-normalized"
        }
        Next = "PolicyGate"
      }
      PolicyGate = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.auto_execute"
            BooleanEquals = true
            Next          = "AutoExecuteActions"
          }
        ]
        Default = "SuggestOnly"
      }
      AutoExecuteActions = {
        Type = "Parallel"
        Branches = [
          {
            StartAt = "IsolateHostViaSSM"
            States = {
              IsolateHostViaSSM = {
                Type   = "Pass"
                Result = "Run SSM isolation command"
                End    = true
              }
            }
          },
          {
            StartAt = "BlockIpViaWaf"
            States = {
              BlockIpViaWaf = {
                Type   = "Pass"
                Result = "Update WAF IP set or security group"
                End    = true
              }
            }
          },
          {
            StartAt = "DisableIdentity"
            States = {
              DisableIdentity = {
                Type   = "Pass"
                Result = "Disable IAM Identity Center or directory user"
                End    = true
              }
            }
          },
          {
            StartAt = "NotifyAndTicket"
            States = {
              NotifyAndTicket = {
                Type   = "Pass"
                Result = "Publish SNS and create Jira/ServiceNow ticket"
                End    = true
              }
            }
          }
        ]
        Next = "DecisionResult"
      }
      SuggestOnly = {
        Type   = "Pass"
        Result = "Manual approval required"
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
    Name  = "${local.name_prefix}-prod-playbook-orchestrator"
    Layer = "orchestration"
  }
}

resource "aws_cloudwatch_event_rule" "hourly_rotation" {
  name                = "${local.name_prefix}-prod-hourly-orchestrator-rotation"
  description         = "Hourly active/standby orchestrator rotation and pre-kill notification"
  schedule_expression = var.orchestrator_rotation_schedule
}

resource "aws_cloudwatch_event_target" "hourly_rotation" {
  rule     = aws_cloudwatch_event_rule.hourly_rotation.name
  arn      = aws_sfn_state_machine.orchestrator.arn
  role_arn = aws_iam_role.eventbridge_scheduler.arn

  input = jsonencode({
    source       = "eventbridge-scheduler"
    rotation     = "hourly"
    notify_soc   = true
    auto_execute = false
  })
}

resource "aws_cloudfront_origin_access_control" "dashboard" {
  name                              = "${local.name_prefix}-prod-dashboard-oac"
  description                       = "OAC for private production SOC dashboard bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${local.name_prefix} production SOC dashboard"
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

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
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
    Name  = "${local.name_prefix}-prod-dashboard"
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
  dashboard_name = "${local.name_prefix}-prod-soc"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Requests and Errors"
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
          title  = "ECS Production Services"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", "backend-api"],
            [".", "MemoryUtilization", ".", ".", ".", "."],
            [".", "CPUUtilization", ".", ".", ".", "layer2-meta-analyzer"],
            [".", "MemoryUtilization", ".", ".", ".", "."],
            [".", "CPUUtilization", ".", ".", ".", "orchestrator-active"],
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
          title  = "Recent Backend Logs"
          region = var.aws_region
          query  = "SOURCE '/ecs/${local.name_prefix}/prod/backend-api' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name_prefix}-prod-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.alarm_alb_5xx_threshold
  alarm_description   = "Production ALB is returning 5xx errors"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  for_each = local.app_services

  alarm_name          = "${local.name_prefix}-prod-${each.key}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_ecs_cpu_threshold
  alarm_description   = "Production ECS service CPU is high"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = each.key
  }
}

resource "aws_xray_sampling_rule" "default" {
  rule_name      = substr("${var.project_name}-${var.environment}-xray", 0, 32)
  priority       = 9998
  version        = 1
  reservoir_size = 2
  fixed_rate     = 0.10
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
}

resource "aws_cloudwatch_log_subscription_filter" "ecs_to_audit" {
  for_each = aws_cloudwatch_log_group.ecs

  name            = "to-production-audit-firehose"
  log_group_name  = each.value.name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.audit.arn
  role_arn        = aws_iam_role.logs_to_firehose.arn
  distribution    = "ByLogStream"
}

resource "aws_cloudtrail" "org_like_trail" {
  name                          = "${local.name_prefix}-prod-trail"
  s3_bucket_name                = aws_s3_bucket.audit.id
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true
  kms_key_id                    = aws_kms_key.main.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type = "AWS::S3::Object"
      values = [
        "${aws_s3_bucket.raw_logs.arn}/",
        "${aws_s3_bucket.processed_logs.arn}/",
        "${aws_s3_bucket.audit.arn}/"
      ]
    }
  }

  depends_on = [aws_s3_bucket_policy.audit_cloudtrail]
}

data "aws_iam_policy_document" "audit_cloudtrail" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "AWSConfigBucketAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }

  statement {
    sid     = "AWSConfigBucketWrite"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.audit.arn}/config/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit_cloudtrail" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_cloudtrail.json
}

resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Name  = "${local.name_prefix}-prod-guardduty"
    Layer = "security"
  }
}

resource "aws_securityhub_account" "main" {
  enable_default_standards = true
}

data "aws_iam_policy_document" "config_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "${local.name_prefix}-prod-config-role"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "main" {
  name     = "${local.name_prefix}-prod-config"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "${local.name_prefix}-prod-config"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "config"

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_s3_bucket_policy.audit_cloudtrail
  ]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints

  tags = {
    Name  = "${local.name_prefix}-prod-github-oidc"
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

  name               = "${local.name_prefix}-prod-github-actions-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume[0].json

  tags = {
    Name  = "${local.name_prefix}-prod-github-actions-role"
    Layer = "cicd"
  }
}

resource "aws_iam_role_policy" "github_actions" {
  count = var.enable_github_oidc ? 1 : 0

  name = "${local.name_prefix}-prod-github-actions-policy"
  role = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
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
