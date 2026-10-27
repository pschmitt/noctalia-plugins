{
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-mic-state";
  version = (lib.importTOML ../../plugins/mic-state/plugin.toml).version;

  src = lib.fileset.toSource {
    root = ../../plugins/mic-state;
    fileset = lib.fileset.unions [
      ../../plugins/mic-state/plugin.toml
      ../../plugins/mic-state/service.luau
      ../../plugins/mic-state/bar.luau
      ../../plugins/mic-state/README.md
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/mic-state
    mkdir -p "$dest"
    cp plugin.toml service.luau bar.luau README.md "$dest"/

    runHook postInstall
  '';

  meta = {
    description = "Noctalia microphone indicator for the RNNoise voice source";
    license = lib.licenses.gpl3Only;
    maintainers = [ lib.maintainers.pschmitt ];
    platforms = lib.platforms.linux;
  };
}
