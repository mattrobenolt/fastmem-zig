# fastmem-specific settings for the boxes. The bench-base module imports this
# NixOS module into its box configuration (modules/bench-base/image.nix.tftpl),
# which already holds the TTL guard, nix-ld, and the benchmark sysctls.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # objdump disassembles the resolved glibc memcpy/memmove on the box.
    binutils
    perf
    jq
  ];
}
