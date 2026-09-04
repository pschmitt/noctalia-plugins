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
          timew-status = pkgs.callPackage ./pkgs/timew-status { };
        in
        {
          inherit timew-status;
          noctalia-battery-icon = pkgs.callPackage ./pkgs/noctalia-battery-icon { };
          noctalia-osd = pkgs.callPackage ./pkgs/noctalia-osd { };
          noctalia-screencast = pkgs.callPackage ./pkgs/noctalia-screencast { };
          noctalia-syncthing = pkgs.callPackage ./pkgs/noctalia-syncthing { };
          noctalia-timewarrior = pkgs.callPackage ./pkgs/noctalia-timewarrior {
            inherit timew-status;
          };
          default = pkgs.symlinkJoin {
            name = "noctalia-plugins";
            paths = [
              (pkgs.callPackage ./pkgs/noctalia-battery-icon { })
              (pkgs.callPackage ./pkgs/noctalia-osd { })
              (pkgs.callPackage ./pkgs/noctalia-screencast { })
              (pkgs.callPackage ./pkgs/noctalia-syncthing { })
              (pkgs.callPackage ./pkgs/noctalia-timewarrior { inherit timew-status; })
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
