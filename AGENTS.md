# Agent instructions

Personal [Noctalia](https://github.com/noctalia-dev/noctalia) plugins (Luau),
packaged as a Nix flake. Two things matter more than anything else here:

1. **Performance.** Plugin code runs on Noctalia's main thread. A plugin that
   stalls, burns CPU or blocks on I/O makes the whole shell feel slow.
2. **Nice, responsive UX.** Every popup should feel alive: clicks answer
   immediately, work in flight is visible, and motion is smooth but cheap.

Treat both as requirements, not polish. A feature that works but janks the
shell is not done.

## Performance rules

Noctalia gives every script callback a CPU budget. A callback that crosses it
is killed and logged as `script callback '…' exceeded its CPU budget`. That log
line is the canary: check for it after every change (see Verification).

- **Never block.** Run every subprocess with `noctalia.runAsync` (argv arrays
  where possible, a timeout always) and every HTTP call with `noctalia.http`.
  Start/stop/toggle commands go through the service, never inline in a click
  handler.
- **Synchronous file I/O is main-thread I/O.** `noctalia.readFile`,
  `writeFile` and `fileExists` stall when the disk is busy (a loaded machine
  made a token `readFile` cross the budget). Do not call them per request or
  per render. Read once, cache with a TTL or until a setting changes (see
  `readSecret` in `ha/service.luau`, the palette caches, the syncthing
  `config.xml` cache).
- **No big decode or per-line loops in callbacks.** Do not `json.decode`
  tens of kilobytes or trim every line of a long output inside a callback. Ask
  the tool for just the number (`timew summary` total instead of decoding
  `timew export :year`) and find the line you need by scanning from the end.
- **Publish once.** `noctalia.state.set` runs every watcher (bar, panel)
  synchronously inside the callback that made it, and that time is charged to
  that callback. Collect partial results and publish a single time per refresh.
- **Prefer plain string searches** (`find(s, 1, true)`) over patterns on large
  inputs.
- **Poll sparingly.** Slow data gets a slow interval; do not refresh on every
  panel tick what changes once a minute.

### Panels

- `render()` must do nothing while the panel is closed. Keep a `panelIsOpen`
  flag set in `onOpen` and cleared in `onClose`, and return early from
  `render()` when it is false. State watchers keep firing while closed.
- Memoize lookups that run per row (indexes keyed by the identity of the state
  table, which watchers replace rather than mutate).
- Do not rebuild the tree on every display frame. `onFrameTick` fires every
  frame; only call `render()` when something visible changed (a glyph step, an
  opacity step), and call `panel.setNeedsFrameTick(false)` as soon as nothing
  is animating.

## UX rules

- **Answer the click immediately.** Update the UI optimistically (show the new
  selection) and keep a pending state until the service's state confirms it.
  Always add a timeout fallback (a few seconds, longer for slow operations such
  as `powerprofilesctl`) so a failed command cannot leave the UI stuck.
- **Show work in flight.** The convention here is a cycling hourglass glyph
  (`hourglass-empty`, `hourglass-low`, `hourglass-high`, `hourglass`, stepped
  every ~200 ms on the frame tick) on the button that was clicked, with the
  button disabled and a verb label ("Starting…"). Glyphs cannot be rotated; for
  a real spin use a prepared PNG frame set (see timewarrior's sync spinner).
- **Respect `animations_enabled`.** Every plugin that animates declares the
  setting (default true) with translations, and falls back to static icons
  when it is off. Reading an undeclared setting logs a warning per read.
- **Do not duplicate the header.** If the header already shows the logo or
  status icon, do not repeat it in the body.
- **Fades and pulses are opacity only** (`opacity` on a row/box); keep them
  short and stop ticking when they end.

## Noctalia UI gotchas

- `label` has no `minWidth` (use `width`); `scroll` has no `maxHeight` (bound
  the panel with `max_height` in `plugin.toml`). Unknown props are ignored with
  a warning, which means the layout silently does not do what you wrote.
- Use the palette roles the host asks for: `surface_container`,
  `outline_variant` (not the deprecated `surface_variant` / `outline`).
- The reconciler retains an omitted `fill` from the previous render; clear it
  explicitly (`"#00000000"`) when a state change should remove a background.
- Commands sent through shared state need a nonce (`n = nowMs()` plus a
  counter) or an identical second command may not reach the watcher.
- A glyph name must exist in Noctalia's tabler font
  (`share/noctalia/assets/fonts/tabler.json`).

## Verification

Static checks are the floor, not the finish:

- `nix shell nixpkgs#luau -c luau-analyze <file>` on every file you touch. The
  only acceptable errors are Noctalia's own globals (`noctalia`, `ui`, `panel`,
  `barWidget`).
- `nix flake check`.
- Deploy and look at it. Static checks cannot tell you whether a popup renders,
  animates or stalls.

On a live shell:

- Run the shell, then `journalctl --user -u noctalia.service` and grep for
  `exceeded its CPU budget`, `[ERR]`, `[WRN]` (ignored props, undeclared
  settings, deprecated roles). Restart the shell several times (load matters:
  count errors per restart, not once).
- Open every popup you touched (`noctalia msg panel-open <id>`; ids are listed
  in the error for an unknown id, battery-icon's is `pschmitt/battery-icon:power`),
  screenshot it, and click through the states you changed. For animations,
  capture frames with `grim -g "x,y WxH"` in a loop while clicking and compare
  them.
- For responsiveness, sample the shell's CPU (`/proc/<pid>/stat` utime+stime
  over a few seconds) with the popup closed, open and idle, and animating.
  Numbers are noisy; repeat them.
- **Do the interactive testing on gk4, not on the machine the user is working
  on** (ask which one that is). Clicking moves the real cursor. Do not trigger
  actions with real side effects (the timewarrior start/stop hooks run the
  user's work ritual) without asking.

## Workflow

- Keep changes minimal and targeted, match the surrounding style, and never
  add trailing whitespace.
- Commit and push to `main` as you go. After pushing, bump the
  `noctalia-plugins` input in the user's main nix config
  (`nix flake update noctalia-plugins`, commit, push).
- Expensive builds belong on a `rofl-*` host, not the local one.
