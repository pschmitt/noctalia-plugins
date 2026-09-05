{
  description = "Noctalia plugins maintained by pschmitt";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          noctalia-battery-icon = pkgs.callPackage ./pkgs/noctalia-battery-icon { };
          noctalia-fan-control = pkgs.callPackage ./pkgs/noctalia-fan-control { };
          noctalia-osd = pkgs.callPackage ./pkgs/noctalia-osd { };
          noctalia-screencast = pkgs.callPackage ./pkgs/noctalia-screencast { };
          noctalia-syncthing = pkgs.callPackage ./pkgs/noctalia-syncthing { };
          noctalia-timewarrior = pkgs.callPackage ./pkgs/noctalia-timewarrior { };
          default = pkgs.symlinkJoin {
            name = "noctalia-plugins";
            paths = [
              (pkgs.callPackage ./pkgs/noctalia-battery-icon { })
              (pkgs.callPackage ./pkgs/noctalia-fan-control { })
              (pkgs.callPackage ./pkgs/noctalia-osd { })
              (pkgs.callPackage ./pkgs/noctalia-screencast { })
              (pkgs.callPackage ./pkgs/noctalia-syncthing { })
              (pkgs.callPackage ./pkgs/noctalia-timewarrior { })
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
