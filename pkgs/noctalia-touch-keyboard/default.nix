{
  lib,
  stdenvNoCC,
  writeShellApplication,
  glib,
  procps,
  util-linux,
  squeekboard,
  coreutils,
}:
let
  controller = writeShellApplication {
    name = "touch-keyboard";
    runtimeInputs = [
      glib
      procps
      util-linux
      squeekboard
      coreutils
    ];
    text = builtins.readFile ../../plugins/touch-keyboard/keyboard.sh;
  };
in
stdenvNoCC.mkDerivation {
  pname = "noctalia-touch-keyboard";
  inherit (lib.importTOML ../../plugins/touch-keyboard/plugin.toml) version;
  src = ../../plugins/touch-keyboard;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/noctalia-plugins/touch-keyboard" "$out/bin"
    cp plugin.toml *.luau "$out/share/noctalia-plugins/touch-keyboard/"
    ln -s ${controller}/bin/touch-keyboard "$out/bin/touch-keyboard"
    runHook postInstall
  '';
  meta = {
    description = "Noctalia touch keyboard toggle";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
