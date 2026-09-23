output "profile" {
  description = "Credentials profile that write-credentials.sh writes (project.profile in bench.toml)"
  value       = local.profile
}

output "access_key_id" {
  description = "Access key ID of the bench IAM user"
  value       = aws_iam_access_key.bench.id
}

output "secret_access_key" {
  description = "Secret access key of the bench IAM user"
  value       = aws_iam_access_key.bench.secret
  sensitive   = true
}

output "region" {
  description = "Fleet region"
  value       = local.region
}

output "policy_arn" {
  description = "ARN of the bench EC2 policy"
  value       = aws_iam_policy.bench.arn
}
