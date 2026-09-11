{
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-hassio";
  version = "0.5.0";

  src = lib.fileset.toSource {
    root = ../../plugins/hassio;
    fileset = lib.fileset.unions [
      ../../plugins/hassio/plugin.toml
      ../../plugins/hassio/README.md
      ../../plugins/hassio/bar.luau
      ../../plugins/hassio/panel.luau
      ../../plugins/hassio/service.luau
      ../../plugins/hassio/shared.luau
      ../../plugins/hassio/translations
      ../../plugins/hassio/assets
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/hassio
    mkdir -p "$dest"

    cp plugin.toml README.md bar.luau panel.luau service.luau shared.luau "$dest"/
    cp -r translations assets "$dest"/

    runHook postInstall
  '';

  meta = {
    description = "Status and toggle for a chosen handful of Home Assistant entities, for Noctalia";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
