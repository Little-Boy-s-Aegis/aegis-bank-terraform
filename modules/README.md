# Terraform Modules

This directory is split first by deployment profile, then by AWS service or platform capability.

Each module folder follows the same convention:

- `main.tf`
- `variables.tf`
- `outputs.tf`

`modules/hackathon` and `modules/production` are separate composition layers. Each one wires its environment profile together and owns its own service-module folders.

Hackathon service folders are cost-optimized and map to the lightweight architecture. Production service folders are broader and map to the full production architecture.

Common service boundary groups:

- Network and edge: `vpc`, `vpc-endpoints`, `nat-gateway`, `alb`, `cloudfront`, `route53`
- Security: `security-groups`, `waf`, `shield`, `kms`, `iam`, `secrets-manager`
- Compute and containers: `ecs`, `ecr`, `lambda`
- Data: `s3`, `rds`, `redis`, `dynamodb`, `opensearch`
- Ingestion and workflows: `kinesis`, `sqs`, `firehose`, `step-functions`, `eventbridge`
- AI and external services: `bedrock`, `sagemaker`, `api-gateway`
- Notifications: `sns`, `ses`
- Observability and governance: `cloudwatch`, `monitoring`, `xray`, `cloudtrail`, `config`, `guardduty`, `security-hub`
- Delivery: `cicd`
