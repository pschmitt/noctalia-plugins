{
  lib,
  python3,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-ha";
  version = "0.13.69";

  src = lib.fileset.toSource {
    root = ../../plugins/ha;
    fileset = lib.fileset.unions [
      ../../plugins/ha/plugin.toml
      ../../plugins/ha/README.md
      ../../plugins/ha/bar.luau
      ../../plugins/ha/panel.luau
      ../../plugins/ha/service.luau
      ../../plugins/ha/shared.luau
      ../../plugins/ha/layout.luau
      ../../plugins/ha/search-related.py
      ../../plugins/ha/translations
      ../../plugins/ha/assets
    ];
  };

  # search-related.py's shebang is patched to this interpreter.
  buildInputs = [ python3 ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/ha
    mkdir -p "$dest"

    cp plugin.toml README.md bar.luau panel.luau service.luau shared.luau layout.luau "$dest"/
    cp -r translations assets "$dest"/
    install -Dm755 search-related.py "$dest"/search-related.py

    runHook postInstall
  '';

  meta = {
    description = "Status and toggle for a chosen handful of Home Assistant entities, for Noctalia";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
