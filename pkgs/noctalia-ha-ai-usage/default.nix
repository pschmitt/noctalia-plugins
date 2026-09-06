{
  lib,
  stdenvNoCC,
  imagemagick,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-ha-ai-usage";
  version = "0.7.0";

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

    cp plugin.toml README.md bar.luau service.luau shared.luau "$dest"/
    cp -r assets translations "$dest"/
    # panel.luau renders its reset-countdown rings with ImageMagick at
    # runtime (Noctalia's Luau UI has no native circular progress control),
    # so its @magick@ placeholder needs the store path baked in here.
    substitute panel.luau "$dest"/panel.luau --subst-var-by magick ${imagemagick}/bin/magick

    runHook postInstall
  '';

  meta = {
    description = "Home Assistant-backed AI plan usage widget for Noctalia";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
