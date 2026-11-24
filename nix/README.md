# Nix / NixOS

`flake.nix` at the repository root builds Tesseract from this checkout;
[`package.nix`](package.nix) is the derivation itself, written in nixpkgs
style so it can be submitted to nixpkgs as-is.

## Using it

```bash
nix run github:surakin/tesseract            # Qt6 UI
nix run github:surakin/tesseract#tesseract-matrix-gtk   # GTK4 UI
nix build .#tesseract-matrix                # from a local checkout → ./result/bin/tesseract-matrix
```

On NixOS, add the flake as an input and install the package:

```nix
{
  inputs.tesseract.url = "github:surakin/tesseract";

  outputs = { nixpkgs, tesseract, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        { nixpkgs.overlays = [ tesseract.overlays.default ]; }
        ({ pkgs, ... }: { environment.systemPackages = [ pkgs.tesseract-matrix ]; })
      ];
    };
  };
}
```

The binary is `tesseract-matrix`, like the Arch and Debian packages, so it
does not clash with the Tesseract OCR engine.

## How the build works

- **Rust crates**: the flake vendors them straight from `Cargo.lock`
  (`importCargoLock`), so a dependency bump needs no hash update here.
  `package.nix` uses `fetchCargoVendor` with a fixed hash, as nixpkgs requires.
- **libwebrtc**: `webrtc-sys` links LiveKit's prebuilt `libwebrtc.a`, fetched
  as a fixed-output source and handed to its build script through
  `LK_CUSTOM_WEBRTC` (same as the Flatpak). The tag and hashes in
  `package.nix` must move with the `webrtc-sys` pin in `sdk/Cargo.toml`.
- **Compiler**: the package builds with `clangStdenv`. `webrtc-sys` compiles
  against libwebrtc's hermetic libc++, which needs clang ≥ 21.
- **Tests** are off: the test suite fetches Catch2 at configure time.

## Submitting to nixpkgs

After a release tag `vX.Y.Z` exists:

1. Copy `package.nix` to `pkgs/by-name/te/tesseract-matrix/package.nix` in a
   nixpkgs checkout and set `version`.
2. Build it once with `nix-build -A tesseract-matrix`; replace each
   `lib.fakeHash` (source first, then `cargoDeps`) with the hash the error
   reports.
3. Add yourself to `meta.maintainers`, run `nixfmt`, and open the PR
   (`tesseract-matrix: init at X.Y.Z`).
