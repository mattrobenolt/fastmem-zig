output "ssh_key_file" {
  description = "Path to the generated SSH private key"
  value       = abspath(local_sensitive_file.ssh_key.filename)
}

output "instances" {
  description = "AWS benchmark instance details"
  value = {
    for name, inst in aws_instance.bench : name => {
      id        = inst.id
      public_ip = inst.public_ip
      type      = inst.instance_type
      arch      = var.instances[name].arch
    }
  }
}

output "orb_instances" {
  description = "OrbStack benchmark machine details"
  value = {
    for name, machine in orbstack_machine.bench : name => {
      name = machine.name
      arch = var.orb_instances[name].arch
    }
  }
}
