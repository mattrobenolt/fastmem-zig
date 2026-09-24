# The harness reads these with `tofu -chdir=infra/base output -json`.

output "launch_template_ids" {
  description = "Launch template ID by architecture (x86_64, arm64)"
  value       = module.bench.launch_template_ids
}

output "key_file" {
  description = "Absolute path of the SSH private key for root on the boxes"
  value       = module.bench.key_file
}

output "security_group_id" {
  description = "ID of the SSH security group"
  value       = module.bench.security_group_id
}
