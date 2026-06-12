output "github_actions_role_arn" {
  description = "ARN of the IAM role GitHub Actions workflows should assume"
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.github_actions.name
}
