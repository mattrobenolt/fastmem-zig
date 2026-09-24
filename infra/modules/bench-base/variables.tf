variable "project" {
  description = "Fleet name. It names the resources. It must equal project.name in bench.toml and the project of the bench-iam module."
  type        = string
}

variable "amis" {
  description = "AMI ID by EC2 architecture name (x86_64, arm64). Each key gets a launch template <project>-<key>, and it is the arch value of a target in bench.toml. The AMIs must be NixOS: the user_data is a NixOS configuration."
  type        = map(string)

  validation {
    condition     = length(var.amis) > 0 && alltrue([for arch in keys(var.amis) : contains(["x86_64", "arm64"], arch)])
    error_message = "The amis keys must be x86_64 and/or arm64."
  }
}

variable "image_owner" {
  description = "AWS account that publishes the AMIs. The default is the official NixOS publisher. bench-iam allows only AMIs from its image_owners."
  type        = string
  default     = "427812963091"
}

variable "image_version" {
  description = "Written to /etc/bench-image on each box. The harness waits for it to equal project.image_version in bench.toml. Change both when a box change matters to the harness."
  type        = string
}

variable "nixos_module" {
  description = "A NixOS module expression (for example the contents of a file that holds `{ pkgs, ... }: { environment.systemPackages = [ pkgs.perf ]; }`). The box configuration imports it. Use \"{ }\" for none."
  type        = string
  default     = "{ }"
}

variable "key_file" {
  description = "Path of the SSH private key file that the module writes (mode 0600). Keep it out of version control."
  type        = string
}

variable "ssh_ingress_cidrs" {
  description = "IPv4 CIDR blocks that can connect to port 22 of the boxes."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "root_volume_gib" {
  description = "Size of the gp3 root volume, in GiB. bench-iam limits volumes to its max_volume_gib."
  type        = number
  default     = 20
}
