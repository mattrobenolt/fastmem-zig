# The harness interface: ec2bench reads these three outputs.

output "launch_template_ids" {
  description = "Launch template ID by architecture. The keys match the arch field of a target in bench.toml."
  value       = { for arch, template in aws_launch_template.bench : arch => template.id }
}

output "key_file" {
  description = "Absolute path of the SSH private key for root on the boxes"
  value       = abspath(local_sensitive_file.ssh_key.filename)
}

output "security_group_id" {
  description = "ID of the SSH security group"
  value       = aws_security_group.ssh.id
}

output "user_data" {
  description = "The rendered NixOS configuration of the boxes"
  value       = local.user_data
}
