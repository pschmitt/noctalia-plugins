# Fan Control

A fan monitor and manual speed control for **Noctalia v5**. The bar widget
shows the current fan RPM and turns a warning color when the fan is at full
speed or a manual level. Clicking it opens a panel with Auto/Full buttons, a
manual speed slider, the system load average for the 1, 5, and 15 minute
windows, and a 1-minute load trend graph — no root needed at runtime.

> Fork of [piero-93/thinkpad-fan](https://github.com/noctalia-dev/community-plugins/tree/main/thinkpad-fan),
> generalized past `thinkpad_acpi` to also drive any fan exposed through the
> standard Linux hwmon PWM ABI.

## Supported hardware

- **ThinkPads** using the `thinkpad_acpi` kernel module (`/proc/acpi/ibm/fan`).
- **Dell** laptops using `dell-smm-hwmon` (hwmon chip name `dell_smm`).
- **GPD** handhelds (Pocket, Win, etc.) using `gpdfan` (hwmon chip name
  `gpdfan`).
- Any other chip exposing the standard hwmon `pwmN`/`pwmN_enable`/`fanN_input`
  attributes, via the "Extra hwmon chip name" setting.

The service auto-detects which backend applies once per load: `thinkpad_acpi`
first (its 0–7 levels are a distinct, richer control than plain PWM), then a
scan of `/sys/class/hwmon/hwmon*/name` for a known or configured chip name.
Both backends are normalized to the same **auto / full / manual 0–100%**
shape, so the widget and panel don't need to know which is active — and a
hwmon chip with multiple `pwmN` channels (e.g. `dell_smm`'s `pwm1`+`pwm2`) is
driven and reported as one unit.

## Plugin

Manifest id `pschmitt/fan-control`. Three entries share one state snapshot (no
Lua memory is shared between them):

- `service` — headless: detects the backend, polls fan speed(s) and the
  thermal zone, and performs the writes.
- `widget` — the bar widget: fan glyph + `NNNN RPM`, tinted by status. Click it
  to open the panel.
- `panel` — the control surface: Auto / Full buttons, and a manual speed
  slider. Toggle it from a keybind with:

  ```sh
  noctalia msg panel-toggle pschmitt/fan-control:panel
  ```

## Features

- **Live RPM** in the bar, with a tooltip showing speed, mode, and
  temperature (and per-fan RPM breakdown, for multi-channel hwmon chips).
- **Status coloring** — the widget turns red at full speed and uses the
  accent color under manual control.
- **Manual control** — Auto, Full (uncapped/no software limit), or a 0–100%
  slider. Entering Manual starts at 100% rather than inheriting an unknown
  firmware-controlled duty cycle; adjust from there with the slider. On
  `thinkpad_acpi` the slider's 101 positions are mapped onto the hardware's 8
  discrete levels (0–7); dragging it always feels smooth, only the value
  committed on release is quantized.
- **Monitor-only mode** — for firmware or power-profile-controlled machines
  where PWM writes have no useful effect. It keeps the RPM and temperature
  readouts while removing every direct control from the panel and widget.
- **Temperature readout** from a configurable thermal zone.

## Requirements

- One of: a ThinkPad exposing `/proc/acpi/ibm/fan` through `thinkpad_acpi`
  (loaded with `fan_control=1`, see Setup), or a machine exposing a supported
  hwmon PWM chip (`dell_smm`, `gpdfan`, or one named via the "Extra hwmon
  chip name" setting).
- The service reads and writes those files through a shell, so `sh` and `cat`
  must be on `PATH`. Both ship with every distro (coreutils and the system
  shell); there is nothing to install.
- The bundled setup script additionally uses `sudo`, `bash`, `dirname`,
  `getent`, `groupadd`, `usermod`, `chgrp`, `chmod`, `udevadm` — all part of
  coreutils, shadow-utils, and systemd/udev.

## Setup (required for manual control)

Manual fan control needs write access to the relevant sysfs/procfs files for
your user, handled once by the included script — it sets up **both** backends
unconditionally (whichever one doesn't apply to your machine is a harmless
no-op), plus `thinkpad_acpi fan_control=1` if that module is present:

```sh
cd ~/.local/share/noctalia/plugins/fan-control/scripts
sudo ./setup-fan-permissions.sh [extra-hwmon-chip-name ...]
```

Pass any additional hwmon chip name(s) you also set in the plugin's "Extra
hwmon chip name" setting, so the udev rule covers them too.

The script is idempotent, and it makes these changes to your system:

| Change | Detail |
|--------|--------|
| Creates a group | `fan_ctl`, and adds you to it with `usermod -aG` |
| Installs a udev rule (thinkpad) | `/etc/udev/rules.d/99-noctalia-fan-control-thinkpad.rules` — `chgrp fan_ctl` + `chmod 0664` on `/proc/acpi/ibm/fan` at every module bind |
| Installs a udev rule (hwmon) | `/etc/udev/rules.d/99-noctalia-fan-control-hwmon.rules` — `chgrp fan_ctl` + `chmod 0664` on every `pwm*` file of a matching hwmon device at every bind |
| Installs a modprobe option | `/etc/modprobe.d/99-noctalia-fan-control.conf` — `options thinkpad_acpi fan_control=1` |

Write access is granted to the `fan_ctl` group only — the files are **not**
made world-writable, so other local processes cannot drive your fan.

Then **log out and back in** so the group membership applies, and reboot (or
reload `thinkpad_acpi`) if the script had to enable `fan_control=1`. Without
this setup the RPM/temperature readout still works, but changing the mode or
speed will fail (the panel shows a notification).

> ⚠️ "Full" (uncapped/no software limit) or a low manual percentage can let
> the machine overheat under load. Use manual control with care; **Auto**
> returns control to firmware/EC.

### NixOS

`/etc/udev/rules.d` is generated from system config on NixOS, so the script
exits instead of writing to it. Add the equivalent declaratively — this is
safe to apply on every host regardless of which backend (if any) is actually
present there:

```nix
users.groups.fan_ctl = { };
users.users.<you>.extraGroups = [ "fan_ctl" ];
boot.extraModprobeConfig = ''
  options thinkpad_acpi fan_control=1
'';
services.udev.extraRules = ''
  ACTION=="add|bind", SUBSYSTEM=="platform", DRIVER=="thinkpad_acpi", RUN+="${pkgs.coreutils}/bin/chgrp fan_ctl /proc/acpi/ibm/fan", RUN+="${pkgs.coreutils}/bin/chmod 0664 /proc/acpi/ibm/fan"
  SUBSYSTEM=="hwmon", ATTR{name}=="dell_smm", RUN+="${pkgs.bash}/bin/sh -c 'for f in /sys/%p/pwm*; do ${pkgs.coreutils}/bin/chgrp fan_ctl \"$$f\"; ${pkgs.coreutils}/bin/chmod 0664 \"$$f\"; done'"
  SUBSYSTEM=="hwmon", ATTR{name}=="gpdfan", RUN+="${pkgs.bash}/bin/sh -c 'for f in /sys/%p/pwm*; do ${pkgs.coreutils}/bin/chgrp fan_ctl \"$$f\"; ${pkgs.coreutils}/bin/chmod 0664 \"$$f\"; done'"
'';
```

## Usage

Install the plugin from Noctalia's plugin manager, then add the **Fan
Control** widget from the bar's Add-widget picker.

**Contributors only** — to run it from a checkout instead, register that
checkout as a development source:

```sh
noctalia msg plugins source add dev path /path/to/noctalia-plugins/plugins
noctalia msg plugins enable pschmitt/fan-control
```

`.luau` edits hot-reload; `plugin.toml` changes apply on the next config reload.

## Settings

| Setting | Type | Default | Description |
|---------|------|---------|--------------|
| Bar display | select | `rpm` | What to show next to the icon: fan speed, temperature, or nothing |
| Show units in bar | bool | `true` | Show "RPM"/"°C" next to the number in the bar |
| Alternate mode | bool | `false` | For power-profile-controlled hosts; disables all direct fan writes while retaining RPM/temperature reporting |
| Speed step (%) | int | `10` | Slider granularity, and the increase/decrease actions' step |
| Left/Right/Middle click, Scroll up/down | select | see below | Action for each input: open panel, cycle Auto→Full→Manual, increase/decrease speed, or nothing. Defaults: left=panel, right=cycle_mode, scroll up=increase, scroll down=decrease, middle=none |
| Colorize icon / Colorize text | bool | `true` | Whether the icon/text are tinted at all |
| Color by | select | `mode` | What decides the tint: Mode (Auto/Manual/Full), Temperature threshold, or Fan-speed threshold |
| Auto/Manual/Full color | color | (empty → theme default) | Used when Color by = Mode |
| Low/Mid/High temperature threshold + color | int / color | `60`/`80` °C, (empty → theme default) | Used when Color by = Temperature |
| Low/Mid/High fan-speed threshold + color | int / color | `2000`/`4000` RPM, (empty → theme default) | Used when Color by = Fan speed |
| Thermal zone | string | `thermal_zone0` | sysfs thermal zone for the temperature |
| Extra hwmon chip name | string | (empty) | Additional `/sys/class/hwmon/hwmon*/name` to treat as a controllable fan, alongside the built-in `dell_smm`/`gpdfan` |

## What it does to your system

For review transparency (this plugin is trusted, unsandboxed Luau):

- **Reads**, every 2.5 s: `/proc/acpi/ibm/fan` (thinkpad backend) or each
  detected hwmon channel's `pwmN`/`pwmN_enable`/`fanN_input` (hwmon backend),
  plus `/sys/class/thermal/<zone>/temp`. The read goes through
  `noctalia.runAsync`, which executes via `/bin/sh -c`, so each poll spawns a
  shell and a handful of `cat`s. All paths are shell-quoted, and the
  configurable thermal zone / extra hwmon name are reduced to a single path
  segment / compared verbatim before use.
- **Backend detection** runs once per load: a shell scan of
  `/sys/class/hwmon/hwmon*/name` against the built-in and configured chip
  names, entirely read-only.
- **Writes**, only when Alternate mode is disabled and you pick Auto/Full or drag
  the slider in the panel:
  `level <value>` to `/proc/acpi/ibm/fan` (thinkpad), or `2` (auto) / `1`
  (manual) to `pwmN_enable` and a `0`–`255` value to `pwmN` (hwmon) — Full is
  manual PWM `255`, avoiding `pwmN_enable = 0`, which some drivers (including
  `dell-smm-hwmon`) reject. The writes go through the same shell. All values
  are computed internally (clamped to their valid ranges) before reaching the
  command, never passed through from arbitrary input.
- **No network access**, and no commands beyond the shell, `cat`, and the
  redirects described above.
- The **setup script** is never invoked by the plugin; you run it yourself
  with `sudo`. Its system changes are listed in Setup above.

## License

GPL-3.0, inherited from the original `piero-93/thinkpad-fan`.
