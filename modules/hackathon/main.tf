terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "random_password" "db" {
  count            = var.enable_rds ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "backend_jwt" {
  length  = 64
  special = false
}

resource "random_password" "backend_sync_token" {
  length  = 48
  special = false
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
    be-backend = {
      container_port = 8080
      desired_count  = var.ecs_desired_count
      health_path    = "/health"
      description    = "Java Spring Boot Bank API"
      cpu            = 512
      memory         = 1024
    }
    fe-web = {
      container_port = 8085
      desired_count  = var.ecs_desired_count
      health_path    = "/"
      description    = "Next.js Web Portal"
      cpu            = 512
      memory         = 1024
    }
  }

  opensearch_collection_name = substr(replace(lower(local.name_prefix), "_", "-"), 0, 23)
  layer1_schema_version      = "littleboy.soc.layer1.agent_finding.v4"
  layer2_schema_version      = "littleboy.soc.layer2.orchestrator_decision.v8"
  vector_l1_index            = "l1-threat-intel"
  vector_l2_index            = "l2-playbooks"
  qdrant_internal_url        = var.enable_qdrant ? "http://qdrant.${aws_service_discovery_private_dns_namespace.main[0].name}:6333" : ""
  effective_qdrant_url       = var.qdrant_url != "" ? var.qdrant_url : local.qdrant_internal_url
  vector_db_provider         = local.effective_qdrant_url != "" ? "qdrant" : (var.enable_opensearch_serverless ? "opensearch" : "disabled")
  bedrock_runtime_region     = coalesce(var.bedrock_region, var.aws_region)
  bedrock_embedding_region   = coalesce(var.bedrock_embedding_region, var.aws_region)
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
    { name = "QDRANT_URL", value = local.effective_qdrant_url },
    { name = "QDRANT_L1_COLLECTION", value = local.vector_l1_index },
    { name = "QDRANT_L2_COLLECTION", value = local.vector_l2_index },
    { name = "OPENSEARCH_ENDPOINT", value = local.vector_db_provider == "opensearch" ? aws_opensearchserverless_collection.vectors[0].collection_endpoint : "" },
    { name = "OPENSEARCH_SERVICE", value = "aoss" },
    { name = "OPENSEARCH_L1_INDEX", value = local.vector_l1_index },
    { name = "OPENSEARCH_L2_INDEX", value = local.vector_l2_index }
  ]
  waf_blocklist_env = [
    { name = "AWS_WAF_SCOPE", value = "REGIONAL" },
    { name = "AWS_WAF_IP_SET_NAME", value = aws_wafv2_ip_set.blocked_ipv4.name },
    { name = "AWS_WAF_IP_SET_ID", value = aws_wafv2_ip_set.blocked_ipv4.id },
    { name = "AWS_WAF_CLOUDFRONT_SCOPE", value = "CLOUDFRONT" },
    { name = "AWS_WAF_CLOUDFRONT_REGION", value = "us-east-1" },
    { name = "AWS_WAF_CLOUDFRONT_IP_SET_NAME", value = aws_wafv2_ip_set.cloudfront_blocked_ipv4.name },
    { name = "AWS_WAF_CLOUDFRONT_IP_SET_ID", value = aws_wafv2_ip_set.cloudfront_blocked_ipv4.id },
    { name = "AWS_NETWORK_ACL_ID", value = aws_network_acl.public_edge.id },
    { name = "AWS_NETWORK_ACL_RULE_START", value = "2000" },
    { name = "AWS_NETWORK_ACL_RULE_LIMIT", value = "200" },
    { name = "AWS_WAF_SIMULATION", value = "false" }
  ]
  waf_block_response_html = trimspace(<<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Access Revoked | Aegis Bank</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #070b12; color: #f8fafc; font-family: Inter, Arial, sans-serif; }
    main { width: min(560px, calc(100vw - 32px)); border: 1px solid rgba(244,63,94,.36); background: linear-gradient(180deg,#141927,#0d111c); padding: 32px; box-shadow: 0 24px 80px rgba(0,0,0,.4); border-radius: 8px; }
    .eyebrow { color: #fb7185; font: 700 12px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: .16em; text-transform: uppercase; }
    h1 { margin: 14px 0 12px; font-size: 30px; line-height: 1.1; }
    p { margin: 8px 0; color: #cbd5e1; line-height: 1.55; }
    code { display: inline-block; margin-top: 16px; padding: 8px 10px; background: rgba(244,63,94,.13); color: #fecdd3; border: 1px solid rgba(244,63,94,.28); border-radius: 6px; }
  </style>
</head>
<body>
  <main>
    <div class="eyebrow">403 IP Banned</div>
    <h1>Access revoked</h1>
    <p>This IP address has been blocked by the Aegis SOC security policy.</p>
    <p>The request was stopped at the edge before reaching the application.</p>
    <code>AEGIS_EDGE_BLOCK</code>
  </main>
</body>
</html>
HTML
  )
  llm_env = [
    { name = "LLM_PROVIDER", value = var.llm_provider },
    { name = "QWEN_MODEL_NAME", value = var.qwen_model_name },
    { name = "QWEN_BASE_URL", value = var.qwen_base_url },
    { name = "BEDROCK_MODEL_ID", value = var.bedrock_model_id },
    { name = "BEDROCK_REGION", value = local.bedrock_runtime_region },
    { name = "BEDROCK_EMBEDDING_MODEL_ID", value = var.bedrock_embedding_model_id },
    { name = "BEDROCK_EMBEDDING_REGION", value = local.bedrock_embedding_region },
    { name = "BEDROCK_EMBEDDING_DIMENSIONS", value = tostring(var.bedrock_embedding_dimensions) },
    { name = "VECTOR_EMBEDDING_DIMENSIONS", value = tostring(var.bedrock_embedding_dimensions) },
    { name = "LLM_ENABLED", value = tostring(var.llm_enabled) },
    { name = "LLM_TIMEOUT_SECONDS", value = "60" },
    { name = "EMBEDDING_TIMEOUT_SECONDS", value = "60" },
    { name = "TELEGRAM_CHAT_ID", value = var.telegram_chat_id }
  ]
  llm_secret_env = var.dashscope_api_key != "" ? [
    { name = "DASHSCOPE_API_KEY", valueFrom = aws_secretsmanager_secret.llm[0].arn }
  ] : []
  db_env = var.enable_rds ? [
    { name = "DB_HOST", value = aws_db_instance.postgres[0].address },
    { name = "DB_USER", value = var.db_username },
    { name = "DB_NAME", value = var.db_name },
    { name = "DB_PORT", value = "5432" }
  ] : []
  db_secret_env = var.enable_rds ? [
    { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db[0].arn}:password::" }
  ] : []
  kafka_env = var.kafka_bootstrap_servers != "" ? [
    { name = "KAFKA_BOOTSTRAP_SERVERS", value = var.kafka_bootstrap_servers }
  ] : []
  be_backend_kafka_disabled_env = var.kafka_bootstrap_servers == "" ? [
    { name = "SPRING_AUTOCONFIGURE_EXCLUDE", value = "org.springframework.boot.autoconfigure.kafka.KafkaAutoConfiguration" }
  ] : []
  redis_url_env = var.enable_redis ? [
    { name = "REDIS_URL", value = "redis://${aws_elasticache_cluster.redis[0].cache_nodes[0].address}:6379/0" }
  ] : []

  backend_api_env = concat(
    local.db_env,
    local.kafka_env,
    [
      { name = "FRONTEND_URL", value = "https://${aws_cloudfront_distribution.dashboard.domain_name}" },
      { name = "BANK_BACKEND_URL", value = "http://be-backend.ai-native-soc-hackathon.local:8080" },
      { name = "PORT", value = "8080" }
    ]
  )
  backend_api_secret_env = concat(
    local.db_secret_env,
    [
      { name = "JWT_SECRET", valueFrom = "${aws_secretsmanager_secret.backend_app.arn}:jwt_secret::" },
      { name = "AEGIS_INTERNAL_TOKEN", valueFrom = "${aws_secretsmanager_secret.backend_app.arn}:aegis_security_sync_token::" }
    ]
  )
  be_backend_env = concat(
    var.enable_rds ? [
      { name = "SPRING_DATASOURCE_URL", value = "jdbc:postgresql://${aws_db_instance.postgres[0].address}:5432/${var.db_name}" },
      { name = "SPRING_DATASOURCE_USERNAME", value = var.db_username }
    ] : [],
    local.kafka_env,
    local.be_backend_kafka_disabled_env
  )
  be_backend_secret_env = concat(
    var.enable_rds ? [
      { name = "SPRING_DATASOURCE_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db[0].arn}:password::" }
    ] : [],
    [
      { name = "JWT_SECRET", valueFrom = "${aws_secretsmanager_secret.backend_app.arn}:jwt_secret::" },
      { name = "AEGIS_SECURITY_SYNC_TOKEN", valueFrom = "${aws_secretsmanager_secret.backend_app.arn}:aegis_security_sync_token::" }
    ]
  )
  fe_web_env = [
    { name = "BE_BACKEND_URL", value = "http://be-backend.ai-native-soc-hackathon.local:8080" },
    { name = "DASHBOARD_BACKEND_URL", value = "http://backend-api.ai-native-soc-hackathon.local:8080" },
    { name = "DASHBOARD_FRONTEND_URL", value = "https://${aws_cloudfront_distribution.dashboard.domain_name}" },
    { name = "PORT", value = "8085" }
  ]
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

resource "aws_network_acl" "public_edge" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.public.id, aws_subnet.public_alb_spare.id]

  tags = {
    Name  = "${local.name_prefix}-public-edge-nacl"
    Layer = "network-enforcement"
  }
}

resource "aws_network_acl_rule" "public_edge_static_block_ingress" {
  for_each = { for idx, cidr in sort(distinct(var.network_blocked_ipv4_cidrs)) : idx => cidr }

  network_acl_id = aws_network_acl.public_edge.id
  rule_number    = 100 + tonumber(each.key)
  egress         = false
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = each.value
  from_port      = 0
  to_port        = 0
}

resource "aws_network_acl_rule" "public_edge_static_block_egress" {
  for_each = { for idx, cidr in sort(distinct(var.network_blocked_ipv4_cidrs)) : idx => cidr }

  network_acl_id = aws_network_acl.public_edge.id
  rule_number    = 100 + tonumber(each.key)
  egress         = true
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = each.value
  from_port      = 0
  to_port        = 0
}

resource "aws_network_acl_rule" "public_edge_allow_ingress" {
  network_acl_id = aws_network_acl.public_edge.id
  rule_number    = 30000
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

resource "aws_network_acl_rule" "public_edge_allow_egress" {
  network_acl_id = aws_network_acl.public_edge.id
  rule_number    = 30000
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
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

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoint_https_from_qdrant" {
  count = var.enable_qdrant ? 1 : 0

  security_group_id            = aws_security_group.vpc_endpoints.id
  referenced_security_group_id = aws_security_group.qdrant[0].id
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

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 8080
  ip_protocol                  = "tcp"
  to_port                      = 8087
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
  to_port                      = 8087
}

resource "aws_vpc_security_group_ingress_rule" "ecs_self" {
  security_group_id            = aws_security_group.ecs_tasks.id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 8080
  ip_protocol                  = "tcp"
  to_port                      = 8087
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

resource "aws_security_group" "qdrant" {
  count = var.enable_qdrant ? 1 : 0

  name        = "${local.name_prefix}-qdrant-sg"
  description = "Qdrant vector DB access from ECS only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-qdrant-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "qdrant_from_ecs" {
  count = var.enable_qdrant ? 1 : 0

  security_group_id            = aws_security_group.qdrant[0].id
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 6333
  ip_protocol                  = "tcp"
  to_port                      = 6333
}

resource "aws_vpc_security_group_egress_rule" "qdrant_all_egress" {
  count = var.enable_qdrant ? 1 : 0

  security_group_id = aws_security_group.qdrant[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "qdrant_efs" {
  count = var.enable_qdrant ? 1 : 0

  name        = "${local.name_prefix}-qdrant-efs-sg"
  description = "EFS access from Qdrant ECS tasks"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-qdrant-efs-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "qdrant_efs_from_qdrant" {
  count = var.enable_qdrant ? 1 : 0

  security_group_id            = aws_security_group.qdrant_efs[0].id
  referenced_security_group_id = aws_security_group.qdrant[0].id
  from_port                    = 2049
  ip_protocol                  = "tcp"
  to_port                      = 2049
}

resource "aws_vpc_security_group_egress_rule" "qdrant_efs_all_egress" {
  count = var.enable_qdrant ? 1 : 0

  security_group_id = aws_security_group.qdrant_efs[0].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  count = var.enable_qdrant ? 1 : 0

  name = "${local.name_prefix}.local"
  vpc  = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-cloudmap"
  }
}

resource "aws_service_discovery_service" "qdrant" {
  count = var.enable_qdrant ? 1 : 0

  name = "qdrant"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main[0].id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "be_backend" {
  name = "be-backend"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main[0].id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }
}

resource "aws_service_discovery_service" "backend_api" {
  name = "backend-api"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main[0].id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }
}

resource "aws_efs_file_system" "qdrant" {
  count = var.enable_qdrant ? 1 : 0

  encrypted  = true
  kms_key_id = aws_kms_key.main.arn

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name  = "${local.name_prefix}-qdrant-efs"
    Layer = "vector-db"
  }
}

resource "aws_efs_access_point" "qdrant" {
  count = var.enable_qdrant ? 1 : 0

  file_system_id = aws_efs_file_system.qdrant[0].id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/qdrant"

    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }

  tags = {
    Name  = "${local.name_prefix}-qdrant-efs-ap"
    Layer = "vector-db"
  }
}

resource "aws_efs_mount_target" "qdrant" {
  count = var.enable_qdrant ? 1 : 0

  file_system_id  = aws_efs_file_system.qdrant[0].id
  subnet_id       = aws_subnet.private_app.id
  security_groups = [aws_security_group.qdrant_efs[0].id]
}

resource "aws_wafv2_ip_set" "blocked_ipv4" {
  name               = "${local.name_prefix}-blocked-ipv4"
  description        = "Aegis SOAR runtime IPv4 blocklist for public ALB traffic"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = sort(distinct(var.waf_blocked_ipv4_cidrs))

  lifecycle {
    ignore_changes = [addresses]
  }

  tags = {
    Name  = "${local.name_prefix}-blocked-ipv4"
    Layer = "application-enforcement"
  }
}

resource "aws_wafv2_ip_set" "cloudfront_blocked_ipv4" {
  provider           = aws.us_east_1
  name               = "${local.name_prefix}-cloudfront-blocked-ipv4"
  description        = "Aegis SOAR runtime IPv4 blocklist for CloudFront edge traffic"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = sort(distinct(var.waf_blocked_ipv4_cidrs))

  lifecycle {
    ignore_changes = [addresses]
  }

  tags = {
    Name  = "${local.name_prefix}-cloudfront-blocked-ipv4"
    Layer = "edge-enforcement"
  }
}

resource "aws_wafv2_web_acl" "alb" {
  name        = "${local.name_prefix}-alb-waf"
  description = "Basic, low-maintenance WAF rules for the public ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AegisBlockedIPv4Set"
    priority = 0

    action {
      block {
        custom_response {
          response_code            = 403
          custom_response_body_key = "aegis_ip_banned"

          response_header {
            name  = "Cache-Control"
            value = "no-store, no-cache, max-age=0, must-revalidate"
          }

          response_header {
            name  = "X-Aegis-IP-Banned"
            value = "true"
          }
        }
      }
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.blocked_ipv4.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-blocked-ipv4"
      sampled_requests_enabled   = true
    }
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

  custom_response_body {
    key          = "aegis_ip_banned"
    content      = local.waf_block_response_html
    content_type = "TEXT_HTML"
  }

  tags = {
    Name = "${local.name_prefix}-alb-waf"
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.app.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

resource "aws_wafv2_web_acl" "cloudfront_edge" {
  provider    = aws.us_east_1
  name        = "${local.name_prefix}-cloudfront-edge-waf"
  description = "Edge WAF blocklist applied before CloudFront cache/origin routing"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AegisBlockedIPv4Set"
    priority = 0

    action {
      block {
        custom_response {
          response_code            = 403
          custom_response_body_key = "aegis_ip_banned"

          response_header {
            name  = "Cache-Control"
            value = "no-store, no-cache, max-age=0, must-revalidate"
          }

          response_header {
            name  = "X-Aegis-IP-Banned"
            value = "true"
          }
        }
      }
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.cloudfront_blocked_ipv4.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-cloudfront-blocked-ipv4"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-cloudfront-edge-waf"
    sampled_requests_enabled   = true
  }

  custom_response_body {
    key          = "aegis_ip_banned"
    content      = local.waf_block_response_html
    content_type = "TEXT_HTML"
  }

  tags = {
    Name  = "${local.name_prefix}-cloudfront-edge-waf"
    Layer = "edge-enforcement"
  }
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
  source_hash            = filemd5("${local.layer1_artifacts_root}/${each.value}")
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
  source_hash            = filemd5("${local.layer2_artifacts_root}/${each.value}")
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

resource "aws_secretsmanager_secret" "backend_app" {
  name        = "${local.name_prefix}/backend/app"
  description = "Generated backend API application secrets"
  kms_key_id  = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret_version" "backend_app" {
  secret_id = aws_secretsmanager_secret.backend_app.id
  secret_string = jsonencode({
    jwt_secret                = random_password.backend_jwt.result
    aegis_security_sync_token = random_password.backend_sync_token.result
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
      sqs = boto3.client("sqs")

      def _decode(body):
          try:
              while body.startswith(b'\x1f\x8b'):
                  body = gzip.decompress(body)
              return body.decode("utf-8", errors="replace")
          except Exception:
              return body.decode("utf-8", errors="replace")

      def handler(event, context):
          processed = 0
          destination = os.environ["PROCESSED_BUCKET"]
          queue_url = os.environ.get("EVENT_QUEUE_URL")

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
                          "message": raw_text[:10000000],
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

              if queue_url:
                  sqs_event = {
                      "Records": [
                          {
                              "s3": {
                                  "bucket": {
                                      "name": destination
                                  },
                                  "object": {
                                      "key": dst_key
                                  }
                              }
                          }
                      ]
                  }
                  try:
                      sqs.send_message(
                          QueueUrl=queue_url,
                          MessageBody=json.dumps(sqs_event)
                      )
                  except Exception:
                      pass

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
          "ec2:DescribeNetworkAcls",
          "ec2:CreateNetworkAclEntry",
          "ec2:DeleteNetworkAclEntry",
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
        Resource = [
          aws_kinesis_firehose_delivery_stream.audit.arn,
          aws_kinesis_firehose_delivery_stream.raw_logs.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo"
        ]
        Resource = aws_kms_key.main.arn
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

resource "aws_cloudwatch_log_group" "qdrant" {
  count = var.enable_qdrant ? 1 : 0

  name              = "/ecs/${local.name_prefix}/qdrant"
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

resource "aws_lb_target_group" "be_backend" {
  name        = "${substr(local.name_prefix, 0, 18)}-be-bk-tg"
  port        = 8080
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
    Name  = "${local.name_prefix}-be-backend-tg"
    Layer = "network"
  }
}

resource "aws_lb_target_group" "fe_web" {
  name        = "${substr(local.name_prefix, 0, 18)}-fe-web-tg"
  port        = 8085
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200-399"
    path                = "/"
    timeout             = 5
    unhealthy_threshold = 3
  }

  tags = {
    Name  = "${local.name_prefix}-fe-web-tg"
    Layer = "network"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fe_web.arn
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

resource "aws_lb_listener_rule" "api_bank" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.be_backend.arn
  }

  condition {
    path_pattern {
      values = ["/api-bank/*"]
    }
  }
}

resource "aws_ecs_task_definition" "service" {
  for_each = local.ecs_services

  family                   = "${local.name_prefix}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(lookup(each.value, "cpu", var.ecs_cpu))
  memory                   = tostring(lookup(each.value, "memory", var.ecs_memory))
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  ephemeral_storage {
    size_in_gib = 50
  }

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.ecs_cpu_architecture
  }

  container_definitions = jsonencode([
    merge({
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
      ], each.key == "backend-api" ? local.backend_api_env : (each.key == "be-backend" ? local.be_backend_env : (each.key == "fe-web" ? local.fe_web_env : [])), contains(["backend-api", "orchestrator-ha", "worker-service"], each.key) ? local.waf_blocklist_env : [], contains(["orchestrator-ha", "worker-service"], each.key) ? local.db_env : [], contains(["orchestrator-ha", "worker-service"], each.key) ? local.redis_url_env : [], local.layer_artifact_env, local.vector_db_env, local.llm_env)
      secrets = concat(local.llm_secret_env, var.telegram_bot_token != "" ? [{ name = "TELEGRAM_BOT_TOKEN", valueFrom = "${aws_secretsmanager_secret.external_connectors.arn}:telegram_bot_token::" }] : [], each.key == "backend-api" ? local.backend_api_secret_env : (each.key == "be-backend" ? local.be_backend_secret_env : []), contains(["orchestrator-ha", "worker-service"], each.key) ? local.db_secret_env : [], each.key == "orchestrator-ha" || each.key == "worker-service" ? [{ name = "AEGIS_INTERNAL_TOKEN", valueFrom = "${aws_secretsmanager_secret.backend_app.arn}:aegis_security_sync_token::" }] : [])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs[each.key].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
      }, each.key == "worker-service" ? {
      entryPoint = ["python"]
      command    = ["action_worker.py"]
    } : {})
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

resource "aws_ecs_task_definition" "qdrant" {
  count = var.enable_qdrant ? 1 : 0

  family                   = "${local.name_prefix}-qdrant"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.qdrant_cpu)
  memory                   = tostring(var.qdrant_memory)
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.ecs_cpu_architecture
  }

  volume {
    name = "qdrant-storage"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.qdrant[0].id
      transit_encryption = "ENABLED"
      root_directory     = "/"

      authorization_config {
        access_point_id = aws_efs_access_point.qdrant[0].id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "qdrant"
      image     = var.qdrant_image
      essential = true
      portMappings = [
        {
          containerPort = 6333
          hostPort      = 6333
          protocol      = "tcp"
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "qdrant-storage"
          containerPath = "/qdrant/storage"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.qdrant[0].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = {
    Name  = "${local.name_prefix}-qdrant"
    Layer = "vector-db"
  }
}

resource "aws_ecs_service" "qdrant" {
  count = var.enable_qdrant ? 1 : 0

  name                   = "qdrant"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.qdrant[0].arn
  desired_count          = 1
  enable_execute_command = true
  wait_for_steady_state  = false

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = [aws_subnet.private_app.id]
    security_groups  = [aws_security_group.qdrant[0].id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.qdrant[0].arn
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_efs_mount_target.qdrant
  ]

  tags = {
    Name  = "${local.name_prefix}-qdrant"
    Layer = "vector-db"
  }
}

resource "aws_ecs_service" "service" {
  for_each = local.ecs_services

  name                              = each.key
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.service[each.key].arn
  desired_count                     = each.value.desired_count
  enable_execute_command            = true
  wait_for_steady_state             = false
  health_check_grace_period_seconds = each.key == "be-backend" || each.key == "fe-web" || each.key == "backend-api" ? 180 : 0

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
    for_each = each.key == "backend-api" ? [1] : (each.key == "be-backend" ? [1] : (each.key == "fe-web" ? [1] : []))

    content {
      target_group_arn = each.key == "backend-api" ? aws_lb_target_group.backend.arn : (each.key == "be-backend" ? aws_lb_target_group.be_backend.arn : aws_lb_target_group.fe_web.arn)
      container_name   = each.key
      container_port   = each.value.container_port
    }
  }

  dynamic "service_registries" {
    for_each = each.key == "be-backend" ? [1] : (each.key == "backend-api" ? [1] : [])

    content {
      registry_arn = each.key == "be-backend" ? aws_service_discovery_service.be_backend.arn : aws_service_discovery_service.backend_api.arn
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
        Type    = "Pass"
        Comment = "Aggregate alerts, correlate context, and evaluate policy thresholds"
        Next    = "ActionPlan"
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

resource "aws_cloudfront_function" "rewrite_soc" {
  name    = "${substr(replace(local.name_prefix, "_", "-"), 0, 18)}-rewrite-soc"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite root and /soc requests to /soc/index.html"
  publish = true
  code    = <<EOF
function handler(event) {
    var request = event.request;
    var uri = request.uri;
    
    if (uri === '/' || uri === '/index.html' || uri === '/soc' || uri === '/soc/') {
        request.uri = '/soc/index.html';
    }
    return request;
}
EOF
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled     = true
  comment     = "${local.name_prefix} SOC dashboard"
  price_class = var.cloudfront_price_class
  aliases     = var.use_custom_domain ? ["littleboys.biz", "www.littleboys.biz"] : []
  web_acl_id  = aws_wafv2_web_acl.cloudfront_edge.arn

  origin {
    domain_name              = aws_s3_bucket.dashboard.bucket_regional_domain_name
    origin_id                = "dashboard-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard.id
  }

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "backend-alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  ordered_cache_behavior {
    path_pattern     = "/api/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "backend-alb"

    forwarded_values {
      query_string = true
      headers      = ["Accept", "Authorization", "Content-Type", "Origin", "Referer"]

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  ordered_cache_behavior {
    path_pattern     = "/soc*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "dashboard-s3"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite_soc.arn
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 300
    max_ttl                = 3600
    compress               = true
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "backend-alb"

    forwarded_values {
      query_string = true
      headers      = ["Accept", "Authorization", "Content-Type", "Origin", "Referer"]

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn            = var.use_custom_domain ? aws_acm_certificate_validation.cert[0].certificate_arn : null
    ssl_support_method             = var.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = var.use_custom_domain ? "TLSv1.2_2021" : null
    cloudfront_default_certificate = !var.use_custom_domain
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
      values = [
        aws_cloudfront_distribution.dashboard.arn,
        aws_cloudfront_distribution.soc.arn
      ]
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
  destination_arn = aws_kinesis_firehose_delivery_stream.raw_logs.arn
  role_arn        = aws_iam_role.logs_to_firehose.arn
  distribution    = "ByLogStream"

  depends_on = [aws_iam_role_policy.logs_to_firehose]
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
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.dashboard.arn,
          "${aws_s3_bucket.dashboard.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation"
        ]
        Resource = "*"
      }
    ]
  })
}

# Custom Domain Route 53 & ACM Resources
data "aws_route53_zone" "custom_domain" {
  count = var.use_custom_domain && var.route53_zone_id != "" ? 1 : 0

  zone_id      = var.route53_zone_id
  private_zone = false
}

locals {
  custom_domain_zone_id = var.use_custom_domain ? (
    var.route53_zone_id != ""
    ? data.aws_route53_zone.custom_domain[0].zone_id
    : aws_route53_zone.littleboys_biz[0].zone_id
  ) : null

  custom_domain_name_servers = var.use_custom_domain ? (
    var.route53_zone_id != ""
    ? data.aws_route53_zone.custom_domain[0].name_servers
    : aws_route53_zone.littleboys_biz[0].name_servers
  ) : []
}

resource "aws_route53_zone" "littleboys_biz" {
  count = var.use_custom_domain && var.route53_zone_id == "" ? 1 : 0
  name  = "littleboys.biz"
}

resource "aws_acm_certificate" "cert" {
  count             = var.use_custom_domain ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = "littleboys.biz"
  validation_method = "DNS"

  subject_alternative_names = [
    "*.littleboys.biz"
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.use_custom_domain ? {
    for dvo in aws_acm_certificate.cert[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = local.custom_domain_zone_id
}

resource "aws_acm_certificate_validation" "cert" {
  count                   = var.use_custom_domain ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_cloudfront_distribution" "soc" {
  enabled     = true
  comment     = "${local.name_prefix} SOC subdomain dashboard"
  price_class = var.cloudfront_price_class
  aliases     = var.use_custom_domain ? ["soc.littleboys.biz"] : []

  origin {
    domain_name              = aws_s3_bucket.dashboard.bucket_regional_domain_name
    origin_id                = "dashboard-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard.id
  }

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "backend-alb"

    custom_header {
      name  = "X-Aegis-Surface"
      value = "soc-console"
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  ordered_cache_behavior {
    path_pattern     = "/api/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "backend-alb"

    forwarded_values {
      query_string = true
      headers      = ["Accept", "Authorization", "Content-Type", "Origin", "Referer"]

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
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

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite_soc.arn
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
    acm_certificate_arn            = var.use_custom_domain ? aws_acm_certificate_validation.cert[0].certificate_arn : null
    ssl_support_method             = var.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = var.use_custom_domain ? "TLSv1.2_2021" : null
    cloudfront_default_certificate = !var.use_custom_domain
  }

  tags = {
    Name  = "${local.name_prefix}-soc-subdomain"
    Layer = "reporting"
  }
}

resource "aws_route53_record" "bank_ipv4" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = "littleboys.biz"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.dashboard.domain_name
    zone_id                = aws_cloudfront_distribution.dashboard.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "bank_ipv6" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = "littleboys.biz"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.dashboard.domain_name
    zone_id                = aws_cloudfront_distribution.dashboard.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "bank_www_ipv4" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = "www.littleboys.biz"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.dashboard.domain_name
    zone_id                = aws_cloudfront_distribution.dashboard.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "bank_www_ipv6" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = "www.littleboys.biz"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.dashboard.domain_name
    zone_id                = aws_cloudfront_distribution.dashboard.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "soc_ipv4" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = "soc.littleboys.biz"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.soc.domain_name
    zone_id                = aws_cloudfront_distribution.soc.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "soc_ipv6" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = "soc.littleboys.biz"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.soc.domain_name
    zone_id                = aws_cloudfront_distribution.soc.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "google_mx" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = ""
  type    = "MX"
  ttl     = 3600
  records = [
    "1 smtp.google.com"
  ]
}

resource "aws_route53_record" "google_spf" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = ""
  type    = "TXT"
  ttl     = 3600
  records = [
    "v=spf1 include:_spf.google.com ~all"
  ]
}

resource "aws_route53_record" "google_dkim" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = local.custom_domain_zone_id
  name    = "google._domainkey"
  type    = "TXT"
  ttl     = 3600
  records = [
    "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1M0XYfh1BYjSFKmm2VulQvJUREAsIWSHyBHkpA+6vsV4kIgnsYk+AKXzsA5RW8Fh25nJYHXiONezSFUz2tVmN1ib0saSaCjaAaAMiDjl5OOz7dGMvZO8qlSFVM8cJ4scdlpBpufZ/f5RlVziUWOfaT1e8+VGTt6LV/jiqeBABF4v8Gq0Nuh0aRXTWGWarxDq6\" \"yZorGWMikpJTLv/xXFeVWpOshR7rEA50hFrgXg8xmmRE7ISFZe8EZAoPowTY4wyaN6VQ0QPUMUJ8KlTCeZt8+txovUWTD+dCLg6WnCbzuTIIVWih2huRPi4eISO9rnBRqNc/XIF2SUPRF49VRRLAwIDAQAB"
  ]
}
