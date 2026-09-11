{ lib, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "noctalia-feierabend";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../plugins/feierabend;
    fileset = lib.fileset.unions [
      ../../plugins/feierabend/plugin.toml
      ../../plugins/feierabend/service.luau
      ../../plugins/feierabend/widget.luau
      ../../plugins/feierabend/README.md
      ../../plugins/feierabend/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/feierabend
    mkdir -p "$dest"

    cp plugin.toml service.luau widget.luau README.md "$dest"/
    cp -r translations "$dest"/

    runHook postInstall
  '';

  meta = {
    description = "Lockscreen countdown indicator for zhj feierabend's shutdown timer";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
