{
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-ha-ai-usage";
  version = "0.6.3";

  src = lib.fileset.toSource {
    root = ../../plugins/ha-ai-usage;
    fileset = lib.fileset.unions [
      ../../plugins/ha-ai-usage/plugin.toml
      ../../plugins/ha-ai-usage/README.md
      ../../plugins/ha-ai-usage/bar.luau
      ../../plugins/ha-ai-usage/panel.luau
      ../../plugins/ha-ai-usage/service.luau
      ../../plugins/ha-ai-usage/shared.luau
      ../../plugins/ha-ai-usage/assets
      ../../plugins/ha-ai-usage/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/ha-ai-usage
    mkdir -p "$dest"

    cp plugin.toml README.md bar.luau panel.luau service.luau shared.luau "$dest"/
    cp -r assets translations "$dest"/

    runHook postInstall
  '';

  meta = {
    description = "Home Assistant-backed AI plan usage widget for Noctalia";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
