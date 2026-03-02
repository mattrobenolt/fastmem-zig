resource "tls_private_key" "bench" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "bench" {
  key_name   = "fastmem-bench"
  public_key = tls_private_key.bench.public_key_openssh
}

resource "local_sensitive_file" "ssh_key" {
  content         = tls_private_key.bench.private_key_openssh
  filename        = "${path.module}/bench.pem"
  file_permission = "0600"
}

resource "aws_security_group" "bench_ssh" {
  name        = "fastmem-bench-ssh"
  description = "SSH access for fastmem benchmarking"
  vpc_id      = aws_vpc.bench.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "bench" {
  for_each = var.instances

  ami           = each.value.arch == "arm64" ? data.aws_ami.nixos_arm64.id : data.aws_ami.nixos_x86_64.id
  instance_type = each.value.type
  key_name      = aws_key_pair.bench.key_name
  subnet_id     = aws_subnet.bench.id

  vpc_security_group_ids      = [aws_security_group.bench_ssh.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
  }

  user_data = <<-EOF
    { imports = [
        <nixpkgs/nixos/modules/virtualisation/amazon-image.nix>
      ];
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      environment.systemPackages = [ (import <nixpkgs> {}).rsync ];
    }
  EOF

  tags = {
    Name = "fastmem-bench-${each.key}"
  }
}
