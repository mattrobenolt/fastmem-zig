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

variable "reaper_max_lifetime_hours" {
  description = "The reaper terminates a project instance this many hours after its LaunchTime, whatever its ExpiresAt tag says. Keep it above the largest TTL of the harness (fleet.max_ttl, 12 hours by default)."
  type        = number
  default     = 24

  validation {
    condition     = var.reaper_max_lifetime_hours >= 1 && floor(var.reaper_max_lifetime_hours) == var.reaper_max_lifetime_hours
    error_message = "reaper_max_lifetime_hours must be a whole number of hours, 1 or more."
  }
}

variable "reaper_dry_run" {
  description = "If true, the reaper logs its decisions and sends each EC2 call with DryRun, which checks its permissions and changes nothing."
  type        = bool
  default     = false
}

variable "reaper_log_retention_days" {
  description = "Retention of the reaper log group, in days. It must be a value that CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, ...)."
  type        = number
  default     = 30
}
