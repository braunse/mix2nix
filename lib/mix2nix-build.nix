{ pkgs, beamPackages, erlang, elixir, rebar3, stdenv, callPackage, lib }:

{ name, version, src ? "./.", buildInputs ? [ ], scope ? { }, releaseName ? name
, mixDeps, ... }@args:

let
  scope = pkgs // beamPackages // scope;

  unpackHexDeps = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: source: ''
      cp -r ${source} deps/${name}
      chmod -R a+w deps/${name}
    '') mixDeps.hex);

  unusedArgs = builtins.removeAttrs args [ "buildInputs" "mixDeps" "scope" ];

in stdenv.mkDerivation ({
  buildInputs = [ beamPackages.hex rebar3 elixir erlang ] ++ buildInputs;

  preConfigurePhases = "injectDependencies";

  injectDependencies = ''
    runHook preInjectDependencies

    if [ -d deps ]; then
      echo "Removing already-existing deps folder to preserve build reproducibility"
      rm -rf deps
    fi

    mkdir .mix_home
    mkdir .hex_home
    export HEX_OFFLINE=1
    export HEX_HOME=$PWD/.hex_home
    export HEX_NO_VERIFY_REPO_ORIGIN=true
    export MIX_ENV=prod
    export MIX_REBAR3="${rebar3}/bin/rebar3"
    export MIX_NO_DEPS=true
    export MIX_HOME=$PWD/.mix_home

    mkdir deps
    echo "Unpacking Elixir dependencies"
    ${unpackHexDeps}

    runHook postInjectDependencies
  '';

  buildPhase = ''
    runHook preBuild

    # we already have the right versions of everything
    mix deps.compile
    mix compile --no-deps-check

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mix release --no-deps-check ${releaseName}
    cp -r _build/prod/rel/${releaseName} $out

    # Do we need this? It generates a dependency on Erlang
    rm $out/erts-*/bin/start || true

    runHook postInstall
  '';
} // unusedArgs)
