# OBS Studio

Current scene, recording/streaming/virtual-camera status, and quick actions for OBS Studio in the Noctalia bar, plus a scene switcher and quick-actions panel.

## Why this exists

There is no OBS Studio integration among Noctalia's official/community plugins. This one is deliberately built on top of `obs-cli` rather than reimplementing obs-websocket access in Luau:

- [`obs-cli`](https://github.com/pschmitt/obs-cli) for everything obs-websocket exposes generically: scene list/switch/current, and recording/streaming/virtual-camera/input-mute status and toggling.
- Arbitrary host commands for private or host-specific actions. The plugin only runs the explicit argv supplied in each button's `command: [...]` entry; it does not know or require those commands.

Both are invoked through Noctalia's argument-array `runAsync()`, so scene names and custom button arguments never pass through a shell.

## Settings

**Host**, **Port**, and **Password file** configure the obs-websocket connection `obs-cli` uses directly. The password file is read only at request time, the same sops-nix runtime-secret pattern `pschmitt/ha`'s `server_file`/`token_file` use; left at its default (`~/.config/obs-studio/obs-websocket.password`), it is suitable for the host's OBS tooling too, so most hosts need no change here. Leave it empty for an unauthenticated obs-websocket server.

**Microphone input name** targets one obs-websocket input for mute status/toggling (`obs-cli input toggle-mute/is-muted`). Leave it empty to disable the built-in microphone toggle; host-specific mute helpers belong in a custom `command: [...]` button.

**Bar display** picks icon-only, scene-name-only, or both (the default). **Bar: Left/Right/Middle click** and **Bar: Scroll up/down** are each independently configurable (same convention as `pschmitt/ha` and `pschmitt/fan-control`): Open panel, Next/Previous scene, Toggle recording/streaming/virtual camera/mute, Refresh now, Start OBS, or Nothing. Defaults: left click opens the panel, right click toggles the mic, middle click toggles recording, scrolling switches scenes. A blinking red REC dot and a broadcast glyph reflect recording/streaming state in the bar (each independently toggleable, and animation can be disabled entirely).

**Panel: Show scene selector / recording button / streaming button / virtual camera button / microphone button / custom buttons** each toggle one element of the panel's top row (or the custom-buttons section) independently — hide whichever you don't use. **Custom button columns** (default 2) controls the custom-buttons grid width; a label too long for its column is truncated with an ellipsis (a fixed, conservative character budget per column count — Noctalia's plugin scripting bridge has no way to cap a button's own label width, so this happens to the string itself rather than at render time). Prefer a short label over relying on this if you want full control over where it breaks.

**Launch command** is what runs when OBS isn't reachable and you (or a bar/panel action bound to **Start OBS**) ask to start it — split on whitespace into an argument array, no shell. Defaults to the plain `obs` binary; point it at `gtk-launch <desktop-entry-id>` to launch a specific `.desktop` entry (e.g. one with custom flags) instead. It's run inside its own `systemd-run --user --scope`, not as a direct child of Noctalia's service: without that, OBS would sit in `noctalia.service`'s own cgroup and get killed along with everything else in it on the service's next restart (e.g. every `home-manager switch`), rather than staying up independently. Since a directly-launched `obs` process blocks for as long as OBS stays open, this plugin doesn't wait on it to refresh status. Instead, it polls once a second for up to 30 seconds after a launch (rather than waiting out a possibly much longer **Refresh interval**), until the connection comes up or that window runs out, then reverts to the configured interval either way.

## Panel

- While OBS is reachable: a single row combining the **scene dropdown** (shows the current scene, pick another to switch) with the **record/stream/virtual-camera/mute toggles**, each showing its current state; any of the five can be hidden via its own setting above.
- While it isn't: that row, and the custom-buttons grid, are replaced by an **OBS Studio isn't running** message and a **Start OBS Studio** button that runs **Launch command**.
- A **custom buttons** grid, populated from an optional declarative config file (see below).
- A refresh button and a settings-gear button (opens this plugin's settings).

## Custom buttons

An optional file at `~/.config/noctalia/obs-studio.yaml` declares extra buttons for the panel — the same "plain file, read each time, no state overlay to manage" approach `pschmitt/ha`'s `ha.yaml` uses, since these buttons aren't edited from the panel itself:

```yaml
buttons:
  - label: BRB
    icon: coffee
    command: [obs-control, brb]
    bg: "#f4a340"
    fg: "#1a1200"
  - label: Alt camera
    icon: camera-rotate
    command: [obs-control, alt]
  - label: Toggle freeze
    icon: snowflake
    command: [obs-control, toggle-freeze]
    state_filter_source: Webcam
    state_filter_name: Freeze
  - label: Replay
    icon: repeat
    command: [obs-control, replay]
  - label: 👍
    icon: thumb-up
    command: [obs-control, thumbs-up]
  - label: Show roomba
    icon: robot
    command: [obs-control, roomba-show]
  - label: Custom scene
    icon: movie
    obs_cli: [scene, switch, "My Scene"]
  - label: Custom script
    icon: terminal
    command: [/home/me/bin/my-obs-script.sh, --flag]
```

Each button needs a `label` and, optionally, an `icon` (a Tabler glyph name; defaults to `player-play`) and `bg`/`fg` (hex colors for its background/text — a plain `ui.button` only offers theme variants for its background, not an arbitrary color, so a button with either set renders as a colored backdrop with a real button on top handling the click and tinting the text/glyph). Exactly one action is used per button, checked in this order:

- `filter_source: <source>` + `filter_name: <filter>` (+ optional `filter_action: toggle|enable|disable`, default `toggle`) — flips a source filter/effect directly via `obs-cli filter <action> <source> <filter>`. Its current on/off state is polled alongside everything else.
- `state_filter_source: <source>` + `state_filter_name: <filter>` — polls a filter's state for a button whose action is supplied another way, such as `command: [obs-control, toggle-freeze]`. This lets a host-specific command retain its own OSD/side effects while the panel still shows the OBS filter state.
- `active_scene: <scene name>` — marks the button active while OBS is on this scene. Use this for scene-oriented `command` or `obs_cli` actions when you want their current state shown; active buttons get highlighted styling.
- `obs_cli: [args...]` — runs `obs-cli` with the plugin's configured host/port/password plus these arguments (e.g. `[scene, switch, "My Scene"]`, `[hotkey, trigger, "OBSBasic.StartStreaming"]`, or `[filter, toggle, Source, Filter]` if you'd rather not use the `filter_source`/`filter_name` shorthand).
- `command: [argv...]` — runs an arbitrary host command as an explicit argument array (no shell), for anything neither the plugin nor `obs-cli` covers. This is the intended place for private utilities such as `obs-control`.

## Nix usage (this flake)

```nix
programs.noctalia.settings.plugins.source = [
  {
    name = "pschmitt-obs-studio";
    kind = "path";
    location = "${noctaliaPlugins.noctalia-obs-studio}/share/noctalia-plugins";
    enabled = true;
  }
];
programs.noctalia.settings.plugins.enabled = [ "pschmitt/obs-studio" ];
```

`obs-cli` must be on the PATH the Noctalia service runs with. Commands referenced by custom `command: [...]` buttons are host configuration responsibilities.

`assets/obs-studio-icon.png` is OBS Studio's own `com.obsproject.Studio` app icon, taken from the [obsproject/obs-studio](https://github.com/obsproject/obs-studio) repo's own `data/obs-studio/`, the same icon every Linux desktop installs shows for OBS Studio itself.
