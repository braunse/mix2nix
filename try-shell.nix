let
  pkgs = import ./nix/nixpkgs.nix {};
in
  pkgs.mkShell {
    buildInputs = with pkgs; [
      elixir
      (callPackage ./default.nix {})
    ];
  }
