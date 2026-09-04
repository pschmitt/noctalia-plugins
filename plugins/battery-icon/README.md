# Battery Icon

`pschmitt/battery-icon` is a compact, Android-inspired Noctalia bar widget.
It draws the charge percentage inside the battery silhouette, shows a charging
bolt, adapts to Battery Saver, and can play optional plug/unplug sounds.

## Requirements

The Nix package bundles absolute paths for its command-line helpers:
ImageMagick, `powerprofilesctl`, `udevadm`, `busctl`, and `stdbuf`. It expects
an UPower-compatible battery device (normally `BAT0`) and, for live power
state, the system D-Bus.

## Setup

Enable `pschmitt/battery-icon` in Noctalia and place
`pschmitt/battery-icon:bar` in a bar. Use **Settings → Plugins → Battery
Icon** to select a different battery device or alter thresholds and colors.

`full_at = 0` learns a sensible full-charge limit from the hardware. Set it to
an explicit percentage only when the automatic value does not match a device's
charge-preservation limit. Plug/unplug sounds also require Noctalia's global
`audio.enable_sounds` setting.
