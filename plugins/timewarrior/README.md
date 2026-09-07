# Timewarrior

`pschmitt/timewarrior` shows the running [Timewarrior](https://timewarrior.net/)
interval in a Noctalia bar and provides a panel with a start/stop toggle,
today's intervals with editable boundaries, week/month/year totals, and the
current week's daily breakdown.

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
`TIMEWARRIORDB` or Timewarrior's default `~/.config/timewarrior` directory.

`visibility` decides whether the bar slot exists while nothing is tracked:

| value | behaviour |
| --- | --- |
| `tracking` (default) | the slot appears and disappears with the timer |
| `always` | the slot stays, showing a pause icon while idle |
| `workdays` | the slot stays Mon-Fri, and vanishes on the weekend while idle |

A running interval is always shown, whatever the setting. This is a
plugin-level setting rather than a per-widget one (it began as the
`hide_when_inactive` bool): a bar entry inside a `capsule_group` is a bare
`author/plugin:entry` id with nowhere to hang widget settings, and a
Nix-managed `config.toml` is read-only, so the per-widget settings UI cannot
persist one either.

## Starting and stopping

The panel's big toggle button starts or stops tracking; middle-clicking the bar
widget does the same without opening the panel.

By default that runs `timew start` / `timew stop`. Setting `start_command` /
`stop_command` replaces those with a command of your own, which is where the
rest of a "start working" ritual belongs — bringing a VPN up, starting the
matching Taskwarrior task, dismissing a reminder, syncing afterwards. Both are
shell command lines (run through `/bin/sh -c`) and inherit the resolved
`TIMEWARRIORDB`, so a wrapper always talks to the same database the widget
displays:

```nix
programs.noctalia.settings.plugin_settings."pschmitt/timewarrior" = {
  visibility = "workdays";
  start_command = "~/bin/zhj tw::work-start";
  stop_command = "~/bin/zhj tw::work-stop";
};
```

Wrappers that shut VMs down or sync can take a while; `command_timeout`
(default 120s) bounds the wait. The button shows "Starting…"/"Stopping…" while
the command runs, and a failure surfaces both as a toast and as an error line
in the panel. Tracking state itself always comes from `timew` polling, never
from the command's exit status, so a wrapper that fails halfway through still
leaves the widget telling the truth.

## Editing today's intervals

The panel's **Today** section lists every interval tracked today as
`@id  start → end  duration`. Both boundaries are text fields: type `HH:MM`
(seconds optional) and press Enter, and the plugin runs
`timew modify start|end @<id> <time>` for that interval. The running interval
shows "running" instead of an end field — closing it is what Stop is for.

A rejected time (bad format, or `timew` refusing the change, e.g. an end before
the start) shows as an error line under the toggle and as a toast; the fields
re-seed from the next poll, so the panel never shows a value Timewarrior didn't
accept.

Interval ids are positional — `@1` is the newest — so they shift whenever an
interval is added. The panel re-renders on every poll, which keeps the window
for submitting a stale id down to one `poll_interval`.
