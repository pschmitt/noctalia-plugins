{ lib, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "noctalia-osd";
  version = "1.7.0";

  src = lib.fileset.toSource {
    root = ../../plugins/osd;
    fileset = lib.fileset.unions [
      ../../plugins/osd/plugin.toml
      ../../plugins/osd/panel.luau
      ../../plugins/osd/README.md
      ../../plugins/osd/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/osd
    mkdir -p "$dest"

    cp plugin.toml panel.luau README.md "$dest"/
    cp -r translations "$dest"/

    runHook postInstall
  '';

  meta = {
    description = "Ad-hoc custom OSD toast for Noctalia, triggered via CLI/IPC with a JSON payload";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
