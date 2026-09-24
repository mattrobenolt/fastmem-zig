variable "project" {
  description = "Fleet name. It names the IAM user and is the Project tag value that the policy requires. It must equal project.name in bench.toml."
  type        = string
}

variable "region" {
  description = "The only region that the user can act in."
  type        = string
}

variable "account_id" {
  description = "Account of the fleet. The policy ARNs name it."
  type        = string
}

variable "instance_families" {
  description = "Instance families that RunInstances allows, for example [\"c8g\", \"c7i\"]. Each family allows all of its sizes, .metal included. A family name does not match its variants (c7i-flex, c7gn, c8gd)."
  type        = list(string)
}

variable "image_owners" {
  description = "AWS accounts whose AMIs RunInstances allows. The default is the official NixOS publisher."
  type        = list(string)
  default     = ["427812963091"]
}

variable "max_volume_gib" {
  description = "Largest EBS volume, in GiB, that RunInstances can create."
  type        = number
  default     = 100
}
