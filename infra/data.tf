data "aws_ami" "nixos_x86_64" {
  most_recent = true
  owners      = ["427812963091"]

  filter {
    name   = "name"
    values = ["nixos/25.*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_ami" "nixos_arm64" {
  most_recent = true
  owners      = ["427812963091"]

  filter {
    name   = "name"
    values = ["nixos/25.*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}
