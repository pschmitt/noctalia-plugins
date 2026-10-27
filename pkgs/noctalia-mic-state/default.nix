{
  lib,
  stdenvNoCC,
}:
let
  pname = "noctalia-mic-state";
  inherit (lib.importTOML ../../plugins/mic-state/plugin.toml) version;
in
stdenvNoCC.mkDerivation {
  inherit pname version;

  src = lib.fileset.toSource {
    root = ../../plugins/mic-state;
    fileset = lib.fileset.unions [
      ../../plugins/mic-state/plugin.toml
      ../../plugins/mic-state/service.luau
      ../../plugins/mic-state/bar.luau
      ../../plugins/mic-state/panel.luau
      ../../plugins/mic-state/README.md
      ../../plugins/mic-state/translations/en.json
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/mic-state
    mkdir -p "$dest"
    cp plugin.toml service.luau bar.luau panel.luau README.md "$dest"/
    mkdir -p "$dest/translations"
    cp translations/en.json "$dest/translations/"

    runHook postInstall
  '';

  meta = {
    description = "Noctalia microphone indicator for the RNNoise voice source";
    license = lib.licenses.gpl3Only;
    maintainers = [ lib.maintainers.pschmitt ];
    platforms = lib.platforms.linux;
  };
}
