{
  lib,
  stdenvNoCC,
  findutils,
  imagemagick,
  librsvg,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-timewarrior";
  version = "0.34.0";

  src = lib.fileset.toSource {
    root = ../../plugins/timewarrior;
    fileset = lib.fileset.unions [
      ../../plugins/timewarrior/plugin.toml
      ../../plugins/timewarrior/README.md
      ../../plugins/timewarrior/service.luau
      ../../plugins/timewarrior/bar.luau
      ../../plugins/timewarrior/panel.luau
      ../../plugins/timewarrior/lib
      ../../plugins/timewarrior/assets
      ../../plugins/timewarrior/translations
    ];
  };

  nativeBuildInputs = [ librsvg ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/timewarrior
    mkdir -p "$dest"

    cp plugin.toml README.md bar.luau panel.luau "$dest"/
    cp -r lib assets translations "$dest"/
    cp service.luau "$dest"/

    # Badge mode's constant main icon (lib/badge_icon.luau): rasterized once
    # at build time, not at runtime through ImageMagick's own SVG delegate --
    # already routed around for pschmitt/syncthing's badges the same way,
    # for the same reliability reason.
    rsvg-convert -w 128 -h 128 -o "$dest"/assets/timewarrior-logo-128.png assets/timewarrior-logo.svg

    cacheKey=$(basename "$out" | cut -c1-8)
    substitute lib/badge_icon.luau "$dest"/lib/badge_icon.luau \
      --subst-var-by magick ${lib.getExe' imagemagick "magick"} \
      --subst-var-by find ${lib.getExe' findutils "find"} \
      --subst-var-by cacheKey "$cacheKey"

    runHook postInstall
  '';

  meta = {
    description = "Timewarrior tracked-time bar widget for Noctalia, ported from the DMS/Waybar module";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
