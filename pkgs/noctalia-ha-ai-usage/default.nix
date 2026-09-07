{
  lib,
  stdenvNoCC,
  findutils,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-ha-ai-usage";
  version = "0.12.0";

  src = lib.fileset.toSource {
    root = ../../plugins/ha-ai-usage;
    fileset = lib.fileset.unions [
      ../../plugins/ha-ai-usage/plugin.toml
      ../../plugins/ha-ai-usage/README.md
      ../../plugins/ha-ai-usage/bar.luau
      ../../plugins/ha-ai-usage/panel.luau
      ../../plugins/ha-ai-usage/ring.luau
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
    # ring.luau writes its reset-countdown rings as SVG (Noctalia's Luau UI
    # has no circular progress control, but it does render SVG images), so the
    # only tool it still needs is find, for pruning stale cache generations.
    # ImageMagick used to draw these as PNGs; nothing here shells out to it
    # any more.
    #
    # The written SVGs live in the plugin's data dir, which outlives any single
    # build, so they are namespaced by this derivation's output hash: every
    # rebuild is a new cache generation and ring.luau deletes the older ones on
    # load. Without that, a geometry, cap or colour change keeps being served
    # from files the previous version wrote.
    cacheKey=$(basename "$out" | cut -c1-8)
    substitute ring.luau "$dest"/ring.luau \
      --subst-var-by find ${findutils}/bin/find \
      --subst-var-by cacheKey "$cacheKey"

    runHook postInstall
  '';

  meta = {
    description = "Home Assistant-backed AI plan usage widget for Noctalia";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
