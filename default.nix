{ pkgs ? import ./nix/nixpkgs.nix {}
, stdenv ? pkgs.stdenv
, elixir ? pkgs.elixir
, erlang ? pkgs.erlang }:

stdenv.mkDerivation {
    pname = "mix2nix";
    version = "0.1.0";
    src = ./.;

    buildInputs = [ elixir erlang ];

    buildPhase = ''
        mix escript.build
    '';

    installPhase = ''
        install -m 0755 -d $out/bin
        install -m 0555 ./mix2nix $out/bin

        install -m 0755 -d $out/share
        install -m 0555 ./lib/mix2nix-build.nix $out/share
    '';
}
