{
  description = "Noctalia plugins maintained by pschmitt";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    noctalia.url = "github:noctalia-dev/noctalia";
    noctalia.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      noctalia,
      ...
    }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # Linux package builds and checks run on the self-hosted nixbot.
      hydraJobs = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
        packages = self.packages.${system} or { };
        checks = self.checks.${system} or { };
      });

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          noctalia-battery-icon = pkgs.callPackage ./pkgs/noctalia-battery-icon { };
          noctalia-duo-status = pkgs.callPackage ./pkgs/noctalia-duo-status { };
          noctalia-fan-control = pkgs.callPackage ./pkgs/noctalia-fan-control { };
          noctalia-feierabend = pkgs.callPackage ./pkgs/noctalia-feierabend { };
          noctalia-ha-ai-usage = pkgs.callPackage ./pkgs/noctalia-ha-ai-usage { };
          noctalia-ha = pkgs.callPackage ./pkgs/noctalia-ha { };
          noctalia-lan-mouse = pkgs.callPackage ./pkgs/noctalia-lan-mouse { };
          noctalia-obs-studio = pkgs.callPackage ./pkgs/noctalia-obs-studio { };
          noctalia-osd = pkgs.callPackage ./pkgs/noctalia-osd { };
          noctalia-screencast = pkgs.callPackage ./pkgs/noctalia-screencast { };
          noctalia-syncthing = pkgs.callPackage ./pkgs/noctalia-syncthing { };
          noctalia-timewarrior = pkgs.callPackage ./pkgs/noctalia-timewarrior { };
          default = pkgs.symlinkJoin {
            name = "noctalia-plugins";
            paths = [
              (pkgs.callPackage ./pkgs/noctalia-battery-icon { })
              (pkgs.callPackage ./pkgs/noctalia-duo-status { })
              (pkgs.callPackage ./pkgs/noctalia-fan-control { })
              (pkgs.callPackage ./pkgs/noctalia-feierabend { })
              (pkgs.callPackage ./pkgs/noctalia-ha-ai-usage { })
              (pkgs.callPackage ./pkgs/noctalia-ha { })
              (pkgs.callPackage ./pkgs/noctalia-lan-mouse { })
              (pkgs.callPackage ./pkgs/noctalia-obs-studio { })
              (pkgs.callPackage ./pkgs/noctalia-osd { })
              (pkgs.callPackage ./pkgs/noctalia-screencast { })
              (pkgs.callPackage ./pkgs/noctalia-syncthing { })
              (pkgs.callPackage ./pkgs/noctalia-timewarrior { })
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          plugins =
            pkgs.runCommand "noctalia-plugins-check"
              {
                nativeBuildInputs = [
                  noctalia.packages.${system}.default
                  pkgs.imagemagick
                  pkgs.jq
                  pkgs.taplo
                ];
                buildInputs = [ self.packages.${system}.default ];
                src = ./.;
              }
              ''
                cd "$src"
                for plugin in plugins/*; do
                  test -f "$plugin/plugin.toml" || continue
                  noctalia plugins lint "$plugin"
                  taplo check "$plugin/plugin.toml"
                  for translation in "$plugin"/translations/*.json; do
                    test -f "$translation" || continue
                    jq -e . "$translation" >/dev/null
                  done
                done
                for image in assets/*.png plugins/*/screenshots/*.png plugins/*/assets/*.png; do
                  test -f "$image" || continue
                  magick identify "$image" >/dev/null
                done
                touch "$out"
              '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
