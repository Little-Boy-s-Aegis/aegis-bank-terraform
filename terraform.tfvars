aws_region         = "us-east-1"
project_name       = "ai-native-soc"
environment        = "hackathon"
deployment_profile = "hackathon"

# Cost-optimized hackathon defaults.
use_fargate_spot              = true
enable_ecs_container_insights = false
enable_opensearch_serverless  = false
enable_github_oidc            = false

# Keep empty until you are ready to receive alerts.
sns_email_subscriptions = []

# Optional image overrides. By default ECS tasks use the ECR repositories created by this stack.
container_image_overrides = {}
