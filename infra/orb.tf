resource "orbstack_machine" "bench" {
  for_each = var.orb_instances

  name  = "fastmem-bench-${each.key}"
  image = "nixos:unstable"
  arch  = each.value.arch

  provisioner "local-exec" {
    command = <<-EOF
      orb -m fastmem-bench-${each.key} -u root bash -c "mkdir -p /root/.config/nix && echo 'experimental-features = nix-command flakes' > /root/.config/nix/nix.conf && nix-env -iA nixos.rsync"
      orb -m fastmem-bench-${each.key} bash -c "mkdir -p ~/.config/nix && echo 'experimental-features = nix-command flakes' > ~/.config/nix/nix.conf"
    EOF
  }
}
