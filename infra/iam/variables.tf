variable "account_id" {
  description = "The only AWS account that this stack can apply to."
  type        = string
  default     = "396684171460"
}

variable "instance_families" {
  description = "Instance families that RunInstances allows. Each family allows all of its sizes, .metal included. A family name does not match its variants (c7i-flex, c7gn, c8gd)."
  type        = list(string)
  default     = ["c7i", "c8i", "c7a", "c8a", "c7g", "c8g", "c9g"]
}

variable "image_owners" {
  description = "AWS accounts whose AMIs RunInstances allows. 427812963091 publishes the official NixOS AMIs."
  type        = list(string)
  default     = ["427812963091"]
}

variable "max_volume_gib" {
  description = "Largest EBS volume, in GiB, that RunInstances can create."
  type        = number
  default     = 100
}
