# OBS Studio

Current scene, recording/streaming/virtual-camera status, and quick actions for OBS Studio in the Noctalia bar, plus a scene switcher and quick-actions panel.

## Why this exists

There is no OBS Studio integration among Noctalia's official/community plugins. This one is deliberately built on top of two CLIs this repo already maintains rather than reimplementing obs-websocket access in Luau:

- [`obs-cli`](https://github.com/pschmitt/obs-cli) for everything obs-websocket exposes generically: scene list/switch/current, and recording/streaming/virtual-camera/input-mute status and toggling.
- `obs-control` ([`pkgs/local/obs-control`](../../../pkgs/local/obs-control) in the main `nixos-config` flake) for the higher-level actions it already owns: PulseAudio/PipeWire mic mute that also syncs OBS's "Microphone off" overlay item, named scene shortcuts, the freeze-filter toggle, replay, and emoji reactions.

Both are invoked through Noctalia's argument-array `runAsync()`, so scene names and custom button arguments never pass through a shell.

## Settings

**Host**, **Port**, and **Password file** configure the obs-websocket connection `obs-cli` uses directly. The password file is read only at request time, the same sops-nix runtime-secret pattern `pschmitt/ha`'s `server_file`/`token_file` use; left at its default (`~/.config/obs-studio/obs-websocket.password`), it already points at the canonical path `obs-control` itself falls back to, so most hosts need no change here. Leave it empty for an unauthenticated obs-websocket server.

**Microphone input name** targets one obs-websocket input for mute status/toggling (`obs-cli input toggle-mute/is-muted`). Leave it empty to mute/unmute every PulseAudio/PipeWire source through `obs-control toggle-mute` instead — the default, and what keeps OBS's own mute overlay in sync.

**Bar display** picks icon-only, scene-name-only, or both (the default). **Bar: Left/Right/Middle click** and **Bar: Scroll up/down** are each independently configurable (same convention as `pschmitt/ha` and `pschmitt/fan-control`): Open panel, Next/Previous scene, Toggle recording/streaming/virtual camera/mute, Refresh now, or Nothing. Defaults: left click opens the panel, right click toggles the mic, middle click toggles recording, scrolling switches scenes. A blinking red REC dot and a broadcast glyph reflect recording/streaming state in the bar (each independently toggleable, and animation can be disabled entirely).

**Panel: Show scene list / quick actions / custom buttons** toggle each panel section independently. **Custom button columns** controls the custom-buttons grid width.

## Panel

- A scrollable **scene list**: click any scene to switch to it; the current scene is highlighted.
- A **quick actions** row: toggle recording, streaming, the virtual camera, and the microphone, each showing its current state.
- A **custom buttons** grid, populated from an optional declarative config file (see below).
- A refresh button and a settings-gear button (opens this plugin's settings).

## Custom buttons

An optional file at `~/.config/noctalia/obs-studio.yaml` declares extra buttons for the panel — the same "plain file, read each time, no state overlay to manage" approach `pschmitt/ha`'s `ha.yaml` uses, since these buttons aren't edited from the panel itself:

```yaml
buttons:
  - label: BRB
    icon: coffee
    obs_control: brb
  - label: Alt camera
    icon: camera-rotate
    obs_control: alt
  - label: Toggle freeze
    icon: snowflake
    obs_control: toggle-freeze
  - label: Replay
    icon: repeat
    obs_control: replay
  - label: 👍
    icon: thumb-up
    obs_control: thumbs-up
  - label: Show roomba
    icon: robot
    obs_control: roomba-show
  - label: Custom scene
    icon: movie
    obs_cli: [scene, switch, "My Scene"]
  - label: Custom script
    icon: terminal
    command: [/home/me/bin/my-obs-script.sh, --flag]
```

Each button needs a `label` and, optionally, an `icon` (a Tabler glyph name; defaults to `player-play`). Exactly one action key is used per button, checked in this order:

- `obs_control: <verb>` — runs `obs-control <verb>` (any subcommand it supports: `brb`, `alt`, `webcam`, `cat`, `toggle-freeze`, `replay`, `mute`/`unmute`/`toggle-mute`, `thumbs-up`/`thumbs-down`, `roomba-show`/`roomba-hide`, `react <emoji>`, …).
- `obs_cli: [args...]` — runs `obs-cli` with the plugin's configured host/port/password plus these arguments (e.g. `[scene, switch, "My Scene"]`, `[hotkey, trigger, "OBSBasic.StartStreaming"]`).
- `command: [argv...]` — runs an arbitrary command as an explicit argument array (no shell), for anything neither CLI covers.

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

`obs-cli` and `obs-control` must be on the PATH the Noctalia service runs with.
