# AI-Native SOC Terraform

This repository contains two separate Terraform implementations for the AI-Native SOC Platform:

- `hackathon`: cost-optimized MVP, single-AZ workload placement, serverless-first, low monthly cost.
- `production`: production deep-dive architecture, two Availability Zones, separated subnet tiers, stronger security, audit, observability, and edge controls.

Select the stack with `deployment_profile`.

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
- No NAT Gateway by default
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

## Vector Store Runtime

Local Docker/Kubernetes deployments use Qdrant for Layer 1 and Layer 2 vector context. Terraform AWS deployments use OpenSearch instead:

- `hackathon`: OpenSearch Serverless vector collection, enabled in `environments/hackathon/terraform.tfvars` for full POC parity.
- `production`: VPC OpenSearch managed domain with IAM-signed ECS task access.

ECS task definitions set `VECTOR_DB_PROVIDER=opensearch`, clear `QDRANT_URL`, and pass `OPENSEARCH_ENDPOINT`, `OPENSEARCH_SERVICE`, `OPENSEARCH_L1_INDEX`, and `OPENSEARCH_L2_INDEX`. Run the vector ingestion task/script after pushing the SOAR image so `l1-threat-intel` and `l2-playbooks` are populated.

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
- `opensearch_vector_endpoint`
- `step_functions_state_machine_arn`
- `sns_alerts_topic_arn`
- `cloudwatch_dashboard_name`
- `cost_controls`

## Secrets

Do not put real Telegram, Slack, Jira, or ServiceNow tokens into committed tfvars files. Use a local ignored tfvars file, CI/CD secret injection, or pre-created Secrets Manager values depending on your deployment process.
