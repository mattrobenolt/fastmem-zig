{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    mattware = {
      url = "github:mattrobenolt/nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      mattware,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ mattware.overlays.default ];
        };
        benchstat = pkgs.writeShellScriptBin "benchstat" ''
          exec go run golang.org/x/perf/cmd/benchstat@latest "$@"
        '';
      in
      {
        devShells.default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              just
              zig_0_15
            ]
            ++ lib.optionals stdenv.isDarwin [
              awscli2
              nushell
              opentofu
              rsync
              benchstat
              go-bin
              zigdoc
              ziglint
              zls_0_15
            ];
        };
      }
    );
}
