# Timewarrior

`pschmitt/timewarrior` shows the running [Timewarrior](https://timewarrior.net/)
interval in a Noctalia bar and provides a panel with a start/stop toggle,
editable interval boundaries for any day it lists, week/month/year totals, and
a per-day breakdown of the last two weeks.

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

## Editing intervals

The panel's interval section lists every interval of the selected day as
`@id  start → end  duration`. The boundaries read as plain labels; clicking one
turns that single cell into a focused text field. Type `HH:MM` (or `HH:MM:SS`)
and press Enter, and the plugin runs
`timew modify start|end @<id> <time>` for that interval; the ✕ beside the field
leaves it unchanged. The running interval shows "running" instead of an end
field — closing it is what Stop is for.

A rejected time (bad format, or `timew` refusing the change, e.g. an end before
the start) shows as an error line under the toggle and as a toast; the fields
re-seed from the next poll, so the panel never shows a value Timewarrior didn't
accept.

Clicking a day in the breakdown points that section at that day
(clicking it again, or the "Today" button in the section header, comes back).
Opening the panel with a `YYYY-MM-DD` context lands on that day directly, so a
keybind can too:
`noctalia msg panel-open pschmitt/timewarrior:panel 2026-09-01`.
`breakdown_days` (default 14) sets how far back the breakdown reaches, and with
it the export that feeds these lists: every day it shows comes from that single
export, so browsing days costs no extra `timew` call, and the ids stay valid for
`timew modify` whichever day they belong to. The default used to be exactly the
current week, which on a Monday is one row — nothing to click, and no way to
fix up last Friday. Days are listed newest first, days with nothing tracked are
omitted, and the list scrolls inside the panel however long the window is.

Each day's total is coloured by the same `overtime_hours` threshold and
`label_color`/`label_overtime_color` pair the bar widget uses, so a long day
reads the same in the breakdown as it did in the bar while it was worked.

The section's hint text is deliberately quiet — a pencil glyph, a smaller
size, the muted colour role. Noctalia's labels cannot request an italic style
(the renderer never sets a Pango slant), so `italic_font_family` exists for the
one way that is left: name a family that resolves to an italic face. No real
family does on its own — they all ship a Roman face too — so this wants a
fontconfig alias:

```xml
<match target="pattern">
  <test name="family" compare="eq"><string>ComicCode Italic</string></test>
  <edit name="family" mode="assign" binding="same"><string>ComicCode Nerd Font</string></edit>
  <edit name="slant" mode="assign" binding="same"><const>italic</const></edit>
</match>
```

```nix
plugin_settings."pschmitt/timewarrior".italic_font_family = "ComicCode Italic";
```

`interval_precision` picks how the boundaries are rendered — `minutes`
(`HH:MM`, the default) or `seconds` (`HH:MM:SS`). Because the edit field seeds
from what is displayed, it is also the precision an edit defaults to: applying
a `HH:MM` value zeroes the seconds Timewarrior had stored for that boundary.

Interval ids are positional — `@1` is the newest — so they shift whenever an
interval is added. The panel re-renders on every poll, which keeps the window
for submitting a stale id down to one `poll_interval`.
