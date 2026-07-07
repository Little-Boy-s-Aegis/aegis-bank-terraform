# aegis-bank-terraform

Infrastructure-as-Code (IaC) configuration using Terraform to deploy the Aegis Banking platform on AWS.

## Provisioned AWS Resources:
* **Networking**: Custom VPC, 3 public subnets, 3 private subnets, NAT gateway, Route Tables, and VPC Flow Logs.
* **Security & Key Management**: Scoped KMS Customer Managed Keys and Key Aliases for unified data encryption at rest.
* **Compute**: Amazon EKS Kubernetes Cluster with Managed Node Groups.
* **Container Registry**: 8 AWS ECR repositories for container image management.
* **Database**: Amazon RDS PostgreSQL (encrypted with KMS key).
* **Caching**: Amazon ElastiCache Redis.
* **Streaming**: Amazon MSK Kafka cluster (encrypted with KMS key, supporting TLS and Plaintext clients).
* **Identity & Access Management**: EKS OpenID Connect (OIDC) identity provider and IAM Roles for Service Accounts (IRSA) for secure pod role association.
* **Storage**: WORM-compliant compliance logs S3 bucket with Object Lock in COMPLIANCE mode and versioning enabled.
