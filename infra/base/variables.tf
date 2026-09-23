variable "account_id" {
  description = "The only AWS account that this stack can apply to."
  type        = string
  default     = "396684171460"
}

variable "image_owner" {
  description = "AWS account that publishes the pinned AMIs (the official NixOS account). infra/iam allows only AMIs from its image_owners list."
  type        = string
  default     = "427812963091"
}

variable "ssh_ingress_cidrs" {
  description = "IPv4 CIDR blocks that can connect to port 22 of the boxes."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "root_volume_gib" {
  description = "Size of the gp3 root volume, in GiB. infra/iam limits volumes to its max_volume_gib."
  type        = number
  default     = 20
}
