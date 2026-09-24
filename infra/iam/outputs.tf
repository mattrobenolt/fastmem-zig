# write-credentials.sh reads these.

output "profile" {
  description = "Credentials profile that write-credentials.sh writes (project.profile in bench.toml)"
  value       = module.bench.user_name
}

output "access_key_id" {
  description = "Access key ID of the bench IAM user"
  value       = module.bench.access_key_id
}

output "secret_access_key" {
  description = "Secret access key of the bench IAM user"
  value       = module.bench.secret_access_key
  sensitive   = true
}

output "region" {
  description = "Fleet region"
  value       = local.region
}

output "policy_arn" {
  description = "ARN of the bench EC2 policy"
  value       = module.bench.policy_arn
}
