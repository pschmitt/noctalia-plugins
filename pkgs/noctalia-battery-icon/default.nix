{
  lib,
  stdenvNoCC,
  coreutils,
  imagemagick,
  gnused,
  power-profiles-daemon,
  roboto,
  sound-theme-freedesktop,
  systemd,
  upower,
}:

stdenvNoCC.mkDerivation {
  pname = "noctalia-battery-icon";
  version = "0.5.12";

  src = lib.fileset.toSource {
    root = ../../plugins/battery-icon;
    fileset = lib.fileset.unions [
      ../../plugins/battery-icon/plugin.toml
      ../../plugins/battery-icon/service.luau
      ../../plugins/battery-icon/bar.luau
      ../../plugins/battery-icon/panel.luau
      ../../plugins/battery-icon/README.md
      ../../plugins/battery-icon/translations
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dest=$out/share/noctalia-plugins/battery-icon
    mkdir -p "$dest"

    cp plugin.toml bar.luau panel.luau README.md "$dest"/
    cp -r translations "$dest"/
    mkdir -p "$dest"/sounds
    cp -L ${sound-theme-freedesktop}/share/sounds/freedesktop/stereo/power-plug.oga "$dest"/sounds/charging.oga
    cp -L ${sound-theme-freedesktop}/share/sounds/freedesktop/stereo/power-unplug.oga "$dest"/sounds/unplug.oga
    substitute service.luau "$dest"/service.luau \
      --subst-var-by magick ${imagemagick}/bin/magick \
      --subst-var-by font ${roboto}/share/fonts/truetype/Roboto-Bold.ttf \
      --subst-var-by powerprofilesctl ${power-profiles-daemon}/bin/powerprofilesctl \
      --subst-var-by udevadm ${systemd}/bin/udevadm \
      --subst-var-by busctl ${systemd}/bin/busctl \
      --subst-var-by systemctl ${systemd}/bin/systemctl \
      --subst-var-by systemd_inhibit ${systemd}/bin/systemd-inhibit \
      --subst-var-by systemd_run ${systemd}/bin/systemd-run \
      --subst-var-by nproc ${coreutils}/bin/nproc \
      --subst-var-by sleep ${coreutils}/bin/sleep \
      --subst-var-by stdbuf ${coreutils}/bin/stdbuf \
      --subst-var-by sed ${gnused}/bin/sed \
      --subst-var-by upower ${upower}/bin/upower

    runHook postInstall
  '';

  meta = {
    description = "Material 3 Expressive battery indicator widget for Noctalia";
    license = lib.licenses.gpl3Only;
    maintainers = [ lib.maintainers.pschmitt ];
    platforms = lib.platforms.linux;
  };
}
