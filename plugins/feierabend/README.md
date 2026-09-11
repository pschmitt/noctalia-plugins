# Feierabend Countdown

Lockscreen (and, if wired into a bar layout, bar) indicator for the shutdown
countdown armed by `zhj feierabend countdown-start`
(`~/.config/zsh/plugins/local/homeassistant.zsh`, triggered by the
go-hass-agent "Feierabend Start" button or `zhj feierabend start`).

The countdown script writes the remaining seconds as plain text to a state
file (`~/.local/state/feierabend-countdown` by default) once a second while
armed, and removes it on stop/abort or once it reaches zero and hands off to
`sudo shutdown -h now`. This plugin tails that file and shows
"🍻 {N}s before Feierabend" for as long as it exists — nothing otherwise.

Ported from the old hyprlock label
(`cmd[update:1000] cat ~/.local/state/feierabend-countdown`,
`home-manager/gui/hyprland/services/hyprlock.nix` in nixos-config) after
Noctalia replaced hyprlock as the session locker.

## Settings

- `state_file` — path to the countdown's state file.
- `poll_interval` — how often to re-read it, in seconds.
- `text_template` — shown while armed; `{seconds}` is substituted.
- `text_color` — a Noctalia color role (e.g. `error`) or a hex color.
- `font_size` — text size, in pixels.

## Entries

- `[[desktop_widget]] id = "lockscreen"` — reference as
  `pschmitt/feierabend:lockscreen` in a `lockscreen_widgets.widget` entry
  (`docs.noctalia.dev/noctalia/configuration/lockscreen/widgets`).
