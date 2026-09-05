{
  lib,
  pipewire,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-screencast";
  version = "0.3.1";

  src = lib.fileset.toSource {
    root = ../../plugins/screencast;
    fileset = lib.fileset.unions [
      ../../plugins/screencast/plugin.toml
      ../../plugins/screencast/service.luau
      ../../plugins/screencast/bar.luau
      ../../plugins/screencast/README.md
      ../../plugins/screencast/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/screencast
    mkdir -p "$dest"

    cp plugin.toml bar.luau README.md "$dest"/
    cp -r translations "$dest"/
    substitute service.luau "$dest"/service.luau \
      --replace-fail "@pw-cli@" "${lib.getExe' pipewire "pw-cli"}"

    runHook postInstall
  '';

  meta = {
    description = "Red-dot REC bar indicator for Noctalia while screensharing, ported from the Waybar custom/screencast module";
    license = lib.licenses.gpl3Only;
    maintainers = [ lib.maintainers.pschmitt ];
    platforms = lib.platforms.linux;
  };
}
