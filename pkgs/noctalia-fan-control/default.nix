{
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-fan-control";
  version = "1.5.20";

  src = lib.fileset.toSource {
    root = ../../plugins/fan-control;
    fileset = lib.fileset.unions [
      ../../plugins/fan-control/plugin.toml
      ../../plugins/fan-control/README.md
      ../../plugins/fan-control/LICENSE
      ../../plugins/fan-control/service.luau
      ../../plugins/fan-control/widget.luau
      ../../plugins/fan-control/panel.luau
      ../../plugins/fan-control/lib
      ../../plugins/fan-control/scripts
      ../../plugins/fan-control/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/fan-control
    mkdir -p "$dest"

    cp plugin.toml README.md LICENSE service.luau widget.luau panel.luau "$dest"/
    cp -r lib scripts translations "$dest"/
    chmod +x "$dest"/scripts/*.sh

    runHook postInstall
  '';

  meta = {
    description = "Fan speed monitor and manual control for thinkpad_acpi and generic hwmon PWM fans (Dell dell-smm-hwmon, GPD gpd_fan), forked from piero-93/thinkpad-fan";
    license = lib.licenses.gpl3Only;
    maintainers = with lib.maintainers; [ pschmitt ];
    platforms = lib.platforms.linux;
  };
}
