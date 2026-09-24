{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    mattware = {
      url = "github:mattrobenolt/nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      mattware,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Dev machines are aarch64-linux (launchpad) and Apple Silicon macOS;
      # bench boxes are EC2 Linux. Nobody builds this on an Intel Mac.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ mattware.overlays.default ];
          };
        in
        {
          formatter = pkgs.nixfmt-tree;

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              just
              zig_0_16
              zls_0_16
              zigdoc
              ziglint
              git
              # Bench harness (bench/): a uv project on Python 3.14. uv owns
              # the Python deps; nix owns the interpreter and system tools.
              python314
              uv
              # Fleet: OpenTofu for the durable base (infra/), the AWS CLI
              # for ad-hoc inspection, ssh/rsync for box transport.
              opentofu
              awscli2
              openssh
              rsync
              jq
              # Cross-arch disassembly of local builds and pulled glibc
              # objects: llvm-objdump reads x86_64 and aarch64 alike.
              llvmPackages.bintools-unwrapped
              shellcheck
            ]
            # User-mode qemu runs cross-built x86 test binaries on the arm
            # dev host (AVX2 only: it lacks AVX-512). Linux only.
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.qemu-user ];
            # Keep uv on the nix interpreter; never download a Python.
            env = {
              UV_PYTHON = "${pkgs.python314}/bin/python3";
              UV_PYTHON_DOWNLOADS = "never";
            };
          };
        };
    };
}
