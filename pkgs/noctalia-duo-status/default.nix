{
  lib,
  stdenvNoCC,
  findutils,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-duo-status";
  version = (lib.importTOML ../../plugins/duo-status/plugin.toml).version;

  src = lib.fileset.toSource {
    root = ../../plugins/duo-status;
    fileset = lib.fileset.unions [
      ../../plugins/duo-status/plugin.toml
      ../../plugins/duo-status/README.md
      ../../plugins/duo-status/bar.luau
      ../../plugins/duo-status/panel.luau
      ../../plugins/duo-status/service.luau
      ../../plugins/duo-status/svg.luau
      ../../plugins/duo-status/screenshots
      ../../plugins/duo-status/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/duo-status
    mkdir -p "$dest"

    cp plugin.toml README.md bar.luau panel.luau service.luau "$dest"/
    cp -r screenshots translations "$dest"/

    cacheKey=$(basename "$out" | cut -c1-8)
    substitute svg.luau "$dest"/svg.luau \
      --subst-var-by find ${findutils}/bin/find \
      --subst-var-by cacheKey "$cacheKey"

    runHook postInstall
  '';

  meta = {
    description = "iPhone Duo-inspired combined battery and network indicator for Noctalia";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
