aws_region         = "ap-southeast-1"
aws_profile        = "aegis-hackathon"
project_name       = "ai-native-soc"
environment        = "hackathon"
deployment_profile = "hackathon"

# Cost-optimized hackathon defaults.
use_fargate_spot              = true
enable_ecs_container_insights = false
enable_opensearch_serverless  = true
enable_github_oidc            = false
enable_qdrant                 = true
enable_nat_gateway            = true
llm_provider                  = "bedrock"
bedrock_region                = "ap-southeast-2"
bedrock_embedding_region      = "ap-southeast-2"

# Keep empty until you are ready to receive alerts.
sns_email_subscriptions = ["voduchieu42@gmail.com"]

# Optional image overrides. By default ECS tasks use the ECR repositories created by this stack.
container_image_overrides = {}

# Critical SQL injection source shown in the SOC alert. SOAR will keep updating
# the WAF IP set dynamically; this seeds the current emergency edge block at deploy.
waf_blocked_ipv4_cidrs     = ["42.114.204.232/32"]
network_blocked_ipv4_cidrs = []
use_custom_domain          = true
