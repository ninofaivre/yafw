{
  description = "A Nix flake for building the Zig program 'yafw'";

  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
    nix2zon.url = "github:ninofaivre/nix2zon";
  };

  outputs = { zig2nix, nix2zon, ... }: let
    flake-utils = zig2nix.inputs.flake-utils;
    inherit (nix2zon.lib) toZon;
  in (flake-utils.lib.eachDefaultSystem (system: let
      env = zig2nix.outputs.zig-env.${system} {
        zig = zig2nix.outputs.packages.${system}."zig-0_14_1";
      };
      name = "yafw";
      version = "0.0.1";
      zigDeps = import ./nix/deps.nix {inherit (env.pkgs) fetchFromGitHub;};
    in with builtins; with env.pkgs.lib; rec {
      # nix build .#foreign
      packages.foreign = env.package {
        meta.mainProgram = name;
        inherit name;
        inherit version;
        src = cleanSource ./.;

        nativeBuildInputs = with env.pkgs; [
        ] ++ attrValues zigDeps;

        buildInputs = with env.pkgs; [];

        preBuild = ''
          rm -rf deps
          mkdir deps
          ${concatMapStrings (value: ''
            ln -s ${value} ./deps/${removePrefix "/nix/store/" value}
          '')  (attrValues zigDeps)}
          >build.zig.zon cat <<< '${toZon { value = {
            name = ".${name}";
            fingerprint = "0x83a0b9a35c27e835";
            inherit version;
            paths = [ "src" "build.zig" ];
            dependencies = mapAttrs (name: value: {
              path = "\\./deps/${removePrefix "/nix/store/" value}/";
            }) zigDeps;
          }; }}'
        '';

        # Smaller binaries and avoids shipping glibc.
        zigPreferMusl = true;
      };

      # nix build .
      packages.default = packages.foreign.override (attrs: {
        # Prefer nix friendly settings.
        zigPreferMusl = false;

        # Executables required for runtime
        # These packages will be added to the PATH
        zigWrapperBins = with env.pkgs; [];

        # Libraries required for runtime
        # These packages will be added to the LD_LIBRARY_PATH
        zigWrapperLibs = attrs.buildInputs or [];
      });

      packages.${name} = packages.default;

      # For bundling with nix bundle for running outside of nix
      # example: https://github.com/ralismark/nix-appimage
      apps.bundle = {
        type = "app";
        program = "${packages.foreign}/bin/master";
      };

      # nix run .
      apps.default = env.app [] "zig build run -- \"$@\"";

      # nix run .#build
      apps.build = env.app [] "zig build \"$@\"";

      # nix run .#test
      apps.test = env.app [] "zig build test -- \"$@\"";

      # nix run .#docs
      apps.docs = env.app [] "zig build docs -- \"$@\"";

      # nix run .#zig2nix
      apps.zig2nix = env.app [] "zig2nix \"$@\"";

      # nix develop
      devShells.default = env.mkShell {
        shellHook = ''
          export PATH="''${PATH}:''${PWD}/zig-out/bin"
          alias build="zig build"
          alias b="build"
          ${packages.foreign.preBuild}
        '';
        nativeBuildInputs = []
          ++ packages.default.nativeBuildInputs
          ++ packages.default.buildInputs
          ++ packages.default.zigWrapperBins
          ++ packages.default.zigWrapperLibs;
      };
    }));
}
