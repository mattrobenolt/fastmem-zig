variable "instances" {
  type = map(object({
    type = string
    arch = string
  }))
  default = {
    c7i = { type = "c7i.large", arch = "x86_64" }
    c7a = { type = "c7a.large", arch = "x86_64" }
    c8g = { type = "c8g.large", arch = "arm64" }
  }
}

variable "orb_instances" {
  type = map(object({
    arch = string
  }))
  default = {
    orb-arm64 = { arch = "arm64" }
  }
}
