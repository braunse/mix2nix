{ erlangVersion ? "erlangR23"
, elixirVersion ? "elixir_1_10"
, ... }@args:

let
  sources = import ./sources.nix;
  beamOverlay = self: super: rec {
    beamPackages = self.beam.packages.${erlangVersion};
    elixir = beamPackages.${elixirVersion};
    erlang = beamPackages.erlang;
  };
  pkgs = import sources.nixpkgs
    (args // { overlays = [ beamOverlay ] ++ (args.overlays or [ ]); });
in pkgs
