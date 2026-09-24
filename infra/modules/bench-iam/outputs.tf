output "user_name" {
  description = "Name of the bench IAM user"
  value       = aws_iam_user.bench.name
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

output "policy_arn" {
  description = "ARN of the bench EC2 policy"
  value       = aws_iam_policy.bench.arn
}
