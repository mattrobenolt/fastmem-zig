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
      # The dev machine is Apple Silicon macOS (benchmark-hosts.md); AWS and
      # OrbStack targets are Linux. Nobody builds this on an Intel Mac.
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
          # bench.nu's compare step shells out to `benchstat`, which nixpkgs
          # does not package. The wrapper defers to the Go module on first
          # use; go-bin below provides the toolchain it needs.
          benchstat = pkgs.writeShellScriptBin "benchstat" ''
            exec go run golang.org/x/perf/cmd/benchstat@latest "$@"
          '';
        in
        {
          formatter = pkgs.nixfmt-tree;

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              just
              zig_0_16
              # Bench-infrastructure tooling (infra/bench.nu, Justfile): AWS,
              # OpenTofu, rsync for bench-sync, nushell for the driver, and
              # benchstat/go-bin for run comparison. Same set everywhere —
              # the Linux and macOS dev machines both drive benchmarks.
              awscli2
              benchstat
              git
              go-bin
              nushell
              opentofu
              rsync
              zigdoc
              ziglint
              zls_0_16
            ];
          };
        };
    };
}
