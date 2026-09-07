# Timewarrior

`pschmitt/timewarrior` shows the running [Timewarrior](https://timewarrior.net/)
interval in a Noctalia bar and provides a panel with week, month, and year
totals plus the current week's daily breakdown.

## Requirement

Install the `timew` executable for the user running Noctalia (in Nix/Home
Manager, add `pkgs.timewarrior` to that user's packages). The manifest declares
this requirement as `timew`.

The plugin invokes `timew export` directly using Noctalia's argument-array
subprocess API and decodes the JSON with `noctalia.json`. It deliberately needs
neither `jq` nor the former `timew-status` Nix helper.

## Setup

Enable `pschmitt/timewarrior` and add `pschmitt/timewarrior:bar` to a bar.
Configure the database path, polling, overtime threshold, and display formats
in **Settings → Plugins → Timewarrior**. Leave the database path empty to use
`TIMEWARRIORDB` or Timewarrior's default `~/.config/timewarrior` directory. By
default the widget hides when no interval is active; disable
`hide_when_inactive` to keep the slot visible.
