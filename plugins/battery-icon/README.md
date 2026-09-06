# Battery Icon

`pschmitt/battery-icon` is a compact, Android-inspired Noctalia bar widget.
It draws the charge percentage inside the battery silhouette, shows a charging
bolt, adapts to Battery Saver, can play optional plug/unplug sounds, and opens
a compact power-control panel when clicked.

## Requirements

The Nix package bundles absolute paths for its command-line helpers:
ImageMagick, `powerprofilesctl`, `upower`, `udevadm`, `busctl`, and `stdbuf`.
It expects an UPower-compatible battery device (normally `BAT0`) and, for live
power state, the system D-Bus.

## Setup

Enable `pschmitt/battery-icon` in Noctalia and place
`pschmitt/battery-icon:bar` in a bar. Its popup includes the system power
profile selector, charge level/health/thresholds, other UPower battery levels,
and temperature/load from Fan Control. Fan Auto/Full blast/Manual controls are
shown by default when Fan Control supports direct control; disable them with
**Show fan controls** in **Settings → Plugins → Battery Icon**.

The small gear in the popup's lower-right corner opens these plugin settings.
Use **Other devices icons** to choose device-type glyphs (for example, mouse
or touchpad) or battery glyphs that reflect each device's current charge state.

`full_at = 0` learns a sensible full-charge limit from the hardware. Set it to
an explicit percentage only when the automatic value does not match a device's
charge-preservation limit. Plug/unplug sounds also require Noctalia's global
`audio.enable_sounds` setting.
