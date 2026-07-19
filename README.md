# AI-Native SOC Terraform

[![Git Clones](https://badgen.net/https/cdn.jsdelivr.net/gh/Little-Boy-s-Aegis/aegis-bank-deployment@main/aegis-bank-terraform-clone-badge.json)](https://github.com/Little-Boy-s-Aegis/aegis-bank-deployment)
[![Unique Cloners](https://badgen.net/https/cdn.jsdelivr.net/gh/Little-Boy-s-Aegis/aegis-bank-deployment@main/aegis-bank-terraform-uniques-badge.json)](https://github.com/Little-Boy-s-Aegis/aegis-bank-deployment)
[![Release Downloads](https://badgen.net/https/cdn.jsdelivr.net/gh/Little-Boy-s-Aegis/aegis-bank-deployment@main/downloads-badge.json)](https://github.com/Little-Boy-s-Aegis/aegis-bank-deployment/releases)
[![Stars](https://badgen.net/github/stars/Little-Boy-s-Aegis/aegis-bank-terraform?color=f59e0b)](https://github.com/Little-Boy-s-Aegis/aegis-bank-terraform/stargazers)

> Part of the [Little Boy's Aegis](https://github.com/Little-Boy-s-Aegis) project -- an AI-native Security Operations Center platform.

This repository contains two separate Terraform implementations for the AI-Native SOC Platform:

- `hackathon`: cost-optimized MVP, single-AZ workload placement, serverless-first, low monthly cost.
- `production`: production deep-dive architecture, two Availability Zones, separated subnet tiers, stronger security, audit, observability, and edge controls.

Select the stack with `deployment_profile`.

## Prerequisites

- Terraform `>= 1.5.0`
- AWS CLI credentials for the target account
- Permission to create IAM, networking, ECS, RDS, CloudFront, WAF, KMS,
  observability, and data services used by the selected profile
- A reviewed remote-state backend for shared or long-lived environments

The providers are pinned through `.terraform.lock.hcl`. Run `terraform init
-upgrade` only as a deliberate dependency update and review the resulting lock
file diff.

## Quick Start

```bash
aws sts get-caller-identity
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -var-file=environments/hackathon/terraform.tfvars -out=tfplan.local
terraform apply tfplan.local
```

Use `environments/production/terraform.tfvars` for the production profile.
Always inspect the plan for replacements, public exposure, IAM broadening, and
costly services before applying it.

## Folder Layout

```text
terraform/
  environments/
    hackathon/
      terraform.tfvars
    production/
      terraform.tfvars
  modules/
    hackathon/
      main.tf
      variables.tf
      outputs.tf
      alb/
      bedrock/
      cicd/
      cloudfront/
      cloudwatch/
      dynamodb/
      ecr/
      ecs/
      eventbridge/
      firehose/
      iam/
      kinesis/
      kms/
      lambda/
      monitoring/
      opensearch/
      rds/
      redis/
      s3/
      secrets-manager/
      security-groups/
      ses/
      shield/
      sns/
      sqs/
      step-functions/
      vpc/
      vpc-endpoints/
      waf/
      xray/
    production/
      main.tf
      variables.tf
      outputs.tf
      alb/
      api-gateway/
      bedrock/
      cicd/
      cloudfront/
      cloudtrail/
      cloudwatch/
      config/
      dynamodb/
      ecr/
      ecs/
      eventbridge/
      firehose/
      guardduty/
      iam/
      kinesis/
      kms/
      lambda/
      monitoring/
      nat-gateway/
      opensearch/
      rds/
      redis/
      route53/
      s3/
      sagemaker/
      secrets-manager/
      security-groups/
      security-hub/
      ses/
      shield/
      sns/
      sqs/
      step-functions/
      vpc/
      vpc-endpoints/
      waf/
      xray/
  .terraform.lock.hcl
  locals.tf
  main.tf
  outputs.tf
  terraform.tfvars
  variables.tf
  versions.tf
```

The root folder is only the stack entrypoint. `modules/hackathon` and `modules/production` are now separated clearly. Every stack folder and every service folder inside it follows the same `main.tf`, `variables.tf`, `outputs.tf` convention.

## Hackathon Profile

Module: `modules/hackathon`

Designed for the cost-optimized hackathon diagrams:

- Single-AZ workload placement for ECS/RDS/Redis
- No NAT Gateway by default, with an optional NAT Gateway when external LLM/Qdrant egress is required
- Private ECS Fargate services with VPC endpoints
- Firehose -> S3 Raw Logs -> Lambda Preprocessing -> S3 Processed Logs
- Layer 1 AI Agents, Layer 2 Meta Analyzer, Worker, Backend API, HA Orchestrator
- Step Functions playbook orchestration
- S3 + CloudFront SOC dashboard
- SNS/SES/Telegram/Slack/Jira-ready notification layer
- CloudWatch/X-Ray/EventBridge observability
- Firehose -> S3 Object Lock audit archive

AWS reality check: ALB and RDS subnet groups require at least two AZs, so the hackathon module keeps workload services in one AZ and creates small spare subnets only for AWS control-plane requirements.

## Production Profile

Module: `modules/production`

Designed for the production architecture diagrams:

- Edge path: Users -> optional Route53 -> CloudFront app edge -> ALB -> ECS backend
- AWS Shield Standard is implicit; optional Shield Advanced resources can be enabled
- Regional AWS WAF attached to the public ALB
- VPC `10.0.0.0/16` across two Availability Zones
- Public subnets: ALB and NAT Gateway per AZ
- Private app subnets: Backend API, Layer 1 AI Agents, Layer 2 Meta Analyzer, Worker, Active/Standby Orchestrators
- Private security subnets: OPA Policy Engine, Internal Connectors, SSM utilities
- Private data subnets: RDS PostgreSQL Multi-AZ, ElastiCache Redis replication group, OpenSearch managed domain
- Ingestion: Kinesis Data Streams, SQS, Lambda preprocessing, Firehose, raw/processed S3 buckets
- AI services integration: Bedrock runtime, SageMaker runtime, Secrets Manager, KMS
- Decision and orchestration: OpenSearch vector store, Step Functions, EventBridge hourly rotation, DynamoDB leader lock
- Notifications: SNS, SES identity, Telegram/Slack/Jira/ServiceNow secrets
- Observability: CloudWatch Logs, CloudWatch Dashboard, CloudWatch Alarms, X-Ray
- Audit and governance: Firehose, S3 Object Lock, CloudTrail, AWS Config, GuardDuty, Security Hub
- CI/CD: ECR repositories and optional GitHub Actions OIDC role

Production is intentionally more expensive and more resilient than the hackathon profile.

## Deploy

Run the local preflight before applying:

```powershell
.\scripts\preflight.ps1 -Profile both
```

Bootstrap remote state before the first shared/team deployment:

```powershell
cd backend/bootstrap
terraform init
terraform apply
```

Then copy `backend/backend.tf.example` to root `backend.tf`, copy `backend/backend.hcl.example` to `backend/backend.hcl`, fill in the bootstrap outputs, and initialize the main stack:

```powershell
cd ../..
terraform init -backend-config=backend/backend.hcl
```

Initialize once:

```bash
cd terraform
terraform init
```

Plan hackathon:

```bash
terraform plan -var-file=environments/hackathon/terraform.tfvars
```

Plan production:

```bash
terraform plan -var-file=environments/production/terraform.tfvars
```

Apply the selected profile:

```bash
terraform apply -var-file=environments/production/terraform.tfvars
```

## LLM Runtime

ECS services and the one-shot vector ingestion task receive the same Qwen runtime settings:

- `LLM_PROVIDER`
- `QWEN_MODEL_NAME`
- `QWEN_BASE_URL`
- `BEDROCK_MODEL_ID`
- `BEDROCK_REGION`
- `BEDROCK_EMBEDDING_MODEL_ID`
- `BEDROCK_EMBEDDING_REGION`
- `BEDROCK_EMBEDDING_DIMENSIONS`
- `LLM_ENABLED`
- `DASHSCOPE_API_KEY` from Secrets Manager when `dashscope_api_key` is provided

For the hackathon profile, `llm_provider = "bedrock"` uses Qwen on Amazon Bedrock. The current profile keeps the main AWS stack in `ap-southeast-1`, and calls Qwen3 Coder Next plus Amazon Titan Text Embeddings V2 in `ap-southeast-2` because those selected Bedrock models are available there. Before apply, enable the selected Bedrock models in the AWS account if they are not already active.

Do not commit a real DashScope key if using the legacy DashScope path. Copy `secrets.auto.tfvars.example` to `secrets.auto.tfvars` only for local secret overrides.

## Vector Store Runtime

Local Docker/Kubernetes deployments use Qdrant for Layer 1 and Layer 2 vector context. The hackathon AWS profile also creates Qdrant by default:

- `hackathon`: private ECS Fargate Qdrant service with encrypted EFS persistence and Cloud Map DNS.
- `production`: VPC OpenSearch managed domain with IAM-signed ECS task access.

If an existing Qdrant endpoint must be used, set `qdrant_url` in an ignored tfvars file. ECS task definitions then set `VECTOR_DB_PROVIDER=qdrant` and pass `QDRANT_URL`; otherwise the hackathon profile uses the internal Cloud Map URL. OpenSearch remains available only when Qdrant is disabled and `enable_opensearch_serverless = true`. Run the vector ingestion task/script after pushing the SOAR image so `l1-threat-intel` and `l2-playbooks` are populated.

Terraform also uploads the canonical layer contracts into an encrypted S3 artifact bucket:

- Layer 1: `agent_*/layer1_standard_agent_output_schema.json`, agent prompts, attack/CAPEC references, edge-case matrices, and surface context matrices.
- Layer 2: `layer2_orchestrator_output_schema.json`, `layer2_json_output_example.json`, `layer2_orchestrator_output_example.json`, `orchestrator_l2_playbooks.md`, risk scoring tables, and `mitre_attack_full.json`.

The ECS services receive `LAYER_ARTIFACTS_S3_BUCKET`, `LAYER1_ARTIFACTS_S3_PREFIX`, `LAYER2_ARTIFACTS_S3_PREFIX`, `AGENT_L1_DIR`, and `AGENT_L2_DIR`; SOAR startup and vector ingestion sync those S3 prefixes into `/tmp/aegis-layer-artifacts`. Terraform outputs `layer_artifacts_bucket`, `layer_artifact_inventory`, `vector_db_collections`, and `vector_db_init_task_definition_arn` so the deployment can verify exactly what was synchronized.

After pushing the SOAR image, run the output `vector_db_init_task_definition_arn` as a one-shot ECS task in the private app subnet/security group. It ingests Layer 1 references into `l1-threat-intel` and Layer 2 playbooks/POC guidance into `l2-playbooks`.

## Production Edge Options

The production profile always creates a CloudFront distribution in front of the application ALB.

Optional DNS:

```hcl
app_domain_name     = "soc.example.com"
app_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/..."
route53_zone_id     = "Z1234567890"
```

Optional HTTPS from CloudFront to ALB:

```hcl
alb_origin_domain_name = "origin.soc.example.com"
alb_certificate_arn    = "arn:aws:acm:us-east-1:123456789012:certificate/..."
route53_zone_id        = "Z1234567890"
```

When `alb_origin_domain_name` and `alb_certificate_arn` are set, Terraform creates an ALB HTTPS listener, a Route53 alias for the origin name, and makes CloudFront use HTTPS to the ALB. Without those values, the stack keeps an HTTP origin path for first-time deployment.

Production ALB ingress is restricted to the AWS-managed CloudFront origin-facing prefix list by default:

```hcl
restrict_production_alb_to_cloudfront = true
```

Optional Shield Advanced:

```hcl
enable_shield_advanced = true
```

Only enable Shield Advanced if the AWS account already has an active Shield Advanced subscription.

## Container Images

Terraform creates ECR repositories. By default, ECS task definitions point to `:latest` in those repos. Push images after `terraform apply`, or set `container_image_overrides`.

For production readiness, set immutable image tags instead of relying on `:latest`:

```hcl
container_image_overrides = {
  backend-api          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/backend-api:v1.0.0"
  layer1-auth-agent    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/layer1-auth-agent:v1.0.0"
  layer1-api-agent     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/layer1-api-agent:v1.0.0"
  layer1-infra-agent   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/layer1-infra-agent:v1.0.0"
  layer2-meta-analyzer = "123456789012.dkr.ecr.us-east-1.amazonaws.com/layer2-meta-analyzer:v1.0.0"
  worker-service       = "123456789012.dkr.ecr.us-east-1.amazonaws.com/worker-service:v1.0.0"
  orchestrator-active  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/orchestrator-active:v1.0.0"
  orchestrator-standby = "123456789012.dkr.ecr.us-east-1.amazonaws.com/orchestrator-standby:v1.0.0"
  opa-policy-engine    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/opa-policy-engine:v1.0.0"
  internal-connectors  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/internal-connectors:v1.0.0"
  ssm-utilities        = "123456789012.dkr.ecr.us-east-1.amazonaws.com/ssm-utilities:v1.0.0"
}
```

Production service keys:

- `backend-api`
- `layer1-auth-agent`
- `layer1-api-agent`
- `layer1-infra-agent`
- `layer2-meta-analyzer`
- `worker-service`
- `orchestrator-active`
- `orchestrator-standby`
- `opa-policy-engine`
- `internal-connectors`
- `ssm-utilities`

Hackathon service keys:

- `backend-api`
- `layer1-agents`
- `layer2-meta-analyzer`
- `worker-service`
- `orchestrator-ha`

## Key Outputs

- `architecture_profile`
- `app_cloudfront_url`
- `alb_dns_name`
- `dashboard_cloudfront_url`
- `raw_log_firehose_name`
- `ecs_cluster_name`
- `ecs_service_names`
- `ecr_repository_urls`
- `rds_endpoint`
- `redis_endpoint`
- `qdrant_url`
- `opensearch_vector_endpoint`
- `step_functions_state_machine_arn`
- `sns_alerts_topic_arn`
- `cloudwatch_dashboard_name`
- `cost_controls`

## Secrets

Do not put real DashScope, Telegram, Slack, Jira, or ServiceNow tokens into committed tfvars files. Use a local ignored tfvars file, CI/CD secret injection, or pre-created Secrets Manager values depending on your deployment process. Bedrock uses the ECS task role and does not require a committed API key.

## Validation and Operations

```bash
terraform fmt -check -recursive
terraform validate
terraform plan -var-file=environments/hackathon/terraform.tfvars
terraform output
```

- Keep state files and local plan artifacts out of source control; plans may
  contain sensitive values even when the terminal marks them as sensitive.
- Use separate state per environment and enable locking, encryption, and state
  versioning for team deployments.
- Review `terraform plan -refresh-only` before reconciling drift.
- Destroy only with the same variable file and workspace used to create the
  stack: `terraform destroy -var-file=environments/hackathon/terraform.tfvars`.
  Destruction can permanently remove databases, buckets, and audit data.
- `force_destroy_buckets` defaults to a hackathon-friendly value; override it
  for retained environments.

## Related Repositories

| Repository | Description |
|---|---|
| [aegis-bank-deployment](https://github.com/Little-Boy-s-Aegis/aegis-bank-deployment) | Docker Compose orchestration for the full platform |
| [aegis-bank-backend](https://github.com/Little-Boy-s-Aegis/aegis-bank-backend) | Spring Boot banking API |
| [aegis-bank-web-client](https://github.com/Little-Boy-s-Aegis/aegis-bank-web-client) | Next.js banking web portal |
| [aegis-bank-mobile-app](https://github.com/Little-Boy-s-Aegis/aegis-bank-mobile-app) | Flutter mobile banking app |
| [dashboard](https://github.com/Little-Boy-s-Aegis/dashboard) | SOC Dashboard -- Go backend + React frontend |
| [agent-layer-1](https://github.com/Little-Boy-s-Aegis/agent-layer-1) | AI Sensor Agents |
| [agent-layer-2](https://github.com/Little-Boy-s-Aegis/agent-layer-2) | Meta Analyzer / SOAR Orchestrator prompts |
| [aegis-soar-engine](https://github.com/Little-Boy-s-Aegis/aegis-soar-engine) | SOAR Decision Engine |
| [aegis-staging-sandbox](https://github.com/Little-Boy-s-Aegis/aegis-staging-sandbox) | Staging Sandbox environment |
