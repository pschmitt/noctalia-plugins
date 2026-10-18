{
  lib,
  stdenvNoCC,
  systemd,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-lan-mouse";
  version = (lib.importTOML ../../plugins/lan-mouse/plugin.toml).version;

  src = lib.fileset.toSource {
    root = ../../plugins/lan-mouse;
    fileset = lib.fileset.unions [
      ../../plugins/lan-mouse/plugin.toml
      ../../plugins/lan-mouse/service.luau
      ../../plugins/lan-mouse/bar.luau
      ../../plugins/lan-mouse/panel.luau
      ../../plugins/lan-mouse/lockscreen.luau
      ../../plugins/lan-mouse/README.md
      ../../plugins/lan-mouse/assets
      ../../plugins/lan-mouse/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/lan-mouse
    mkdir -p "$dest"

    cp plugin.toml bar.luau panel.luau lockscreen.luau README.md "$dest"/
    substitute service.luau "$dest"/service.luau \
      --replace-fail "@systemctl@" "${lib.getExe' systemd "systemctl"}"
    cp -r assets "$dest"/
    cp -r translations "$dest"/

    runHook postInstall
  '';

  meta = {
    description = "Lan Mouse bar indicator and control panel";
    license = lib.licenses.gpl3Only;
    maintainers = [ lib.maintainers.pschmitt ];
    platforms = lib.platforms.linux;
  };
}
