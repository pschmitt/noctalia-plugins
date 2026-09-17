{ lib, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "noctalia-lan-mouse";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../plugins/lan-mouse;
    fileset = lib.fileset.unions [
      ../../plugins/lan-mouse/plugin.toml
      ../../plugins/lan-mouse/service.luau
      ../../plugins/lan-mouse/bar.luau
      ../../plugins/lan-mouse/panel.luau
      ../../plugins/lan-mouse/README.md
      ../../plugins/lan-mouse/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/lan-mouse
    mkdir -p "$dest"

    cp plugin.toml service.luau bar.luau panel.luau README.md "$dest"/
    cp -r translations "$dest"/

    runHook postInstall
  '';

  meta = {
    description = "Bar icon + panel for lan-mouse showing which host currently owns mouse/keyboard control";
    license = lib.licenses.gpl3Only;
    maintainers = [ lib.maintainers.pschmitt ];
    platforms = lib.platforms.linux;
  };
}
