{
  lib,
  stdenvNoCC,
  timew-status,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-timewarrior";
  version = "0.6.0";

  src = lib.fileset.toSource {
    root = ../../plugins/timewarrior;
    fileset = lib.fileset.unions [
      ../../plugins/timewarrior/plugin.toml
      ../../plugins/timewarrior/service.luau
      ../../plugins/timewarrior/bar.luau
      ../../plugins/timewarrior/panel.luau
      ../../plugins/timewarrior/lib
      ../../plugins/timewarrior/assets
      ../../plugins/timewarrior/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/timewarrior
    mkdir -p "$dest"

    cp plugin.toml bar.luau panel.luau "$dest"/
    cp -r lib assets translations "$dest"/
    substitute service.luau "$dest"/service.luau \
      --subst-var-by timewIsOn ${timew-status}/bin/timew-is-on \
      --subst-var-by timewTotal ${timew-status}/bin/timew-total \
      --subst-var-by timewWeekBreakdown ${timew-status}/bin/timew-week-breakdown

    runHook postInstall
  '';

  meta = {
    description = "Timewarrior tracked-time bar widget for Noctalia, ported from the DMS/Waybar module";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
