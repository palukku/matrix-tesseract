{
  description = "Tesseract, a cross-platform Matrix chat client";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      projectVersion = builtins.head (
        builtins.match ".*project\\(Tesseract VERSION ([0-9.]+).*" (builtins.readFile ./CMakeLists.txt)
      );

      # nix/package.nix builds a release tag (as it will in nixpkgs); point it at
      # this checkout instead. Cargo.lock is read directly, so no vendor hash
      # needs updating when dependencies change.
      fromCheckout =
        pkgs: ui:
        (pkgs.callPackage ./nix/package.nix { inherit ui; }).overrideAttrs (old: {
          version = "${projectVersion}-${self.shortRev or self.dirtyShortRev or "dirty"}";
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.difference ./. (
              lib.fileset.unions [
                ./flake.nix
                (lib.fileset.maybeMissing ./flake.lock)
                ./nix
              ]
            );
          };
          cargoDeps = pkgs.rustPlatform.importCargoLock {
            lockFile = ./Cargo.lock;
            allowBuiltinFetchGit = true;
          };
        });
    in
    {
      packages = forAllSystems (pkgs: rec {
        tesseract-matrix = fromCheckout pkgs "qt6";
        tesseract-matrix-gtk = fromCheckout pkgs "gtk";
        default = tesseract-matrix;
      });

      overlays.default = final: _prev: {
        tesseract-matrix = fromCheckout final "qt6";
        tesseract-matrix-gtk = fromCheckout final "gtk";
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
