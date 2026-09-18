{
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-obs-studio";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../plugins/obs-studio;
    fileset = lib.fileset.unions [
      ../../plugins/obs-studio/plugin.toml
      ../../plugins/obs-studio/README.md
      ../../plugins/obs-studio/LICENSE
      ../../plugins/obs-studio/service.luau
      ../../plugins/obs-studio/bar.luau
      ../../plugins/obs-studio/panel.luau
      ../../plugins/obs-studio/lib
      ../../plugins/obs-studio/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/obs-studio
    mkdir -p "$dest"

    cp plugin.toml README.md LICENSE service.luau bar.luau panel.luau "$dest"/
    cp -r lib translations "$dest"/

    runHook postInstall
  '';

  meta = {
    description = "Current scene, recording/streaming status, a scene switcher panel, and configurable quick actions for OBS Studio, driven by obs-cli/obs-control";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
