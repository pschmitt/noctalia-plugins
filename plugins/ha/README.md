# Home Assistant

Status and one-click toggle in the Noctalia bar for a small, explicitly chosen set of Home Assistant entities, plus a panel to browse Home Assistant and pick more.

## Why this exists

The community `pozzoo/hassio` plugin's entity browser asks Home Assistant to render every entity in one `/api/template` call and, when that is rejected, falls back to downloading and decoding the complete `/api/states` response in a single script callback. On a small Home Assistant instance that works fine. On a large one it does not: Home Assistant itself caps template output length and rejects the request, and even when it doesn't, decoding a multi-megabyte JSON response outruns Noctalia's per-callback CPU budget outright and the plugin crashes before it ever becomes usable. Verified against a 7000+ entity instance: both failure modes reproduce, in that order.

This plugin never makes either kind of unbounded request. The bar/status query names only the entities you've configured, however few. The "Add entity" browser pages through Home Assistant's entity list a bounded chunk at a time (see **Advanced: Browser page size**), optionally scoped to one domain, so every single request stays small regardless of how many entities the instance has.

The status query also carries a light's brightness, a fan's speed and a cover's position along with each entity's state, so the bar tooltip and each panel card can show e.g. "on · 62%" or "open · 40%" instead of a bare state word, with no extra request per entity.

## Usage

Add `pschmitt/ha:bar` to a Noctalia bar. By default it shows one icon per configured entity, tinted to reflect its state, with a tooltip listing names and states grouped by section. Set **Bar: Display mode** to **Single icon** for a fixed bar slot instead — the real Home Assistant logo by default, that never grows, shrinks or recolors as entities are added or change state. **Bar: Single icon glyph** swaps that logo for a plain Tabler glyph instead, if you'd rather have that; leave it at its own default (`smart-home`) to keep the logo.

What each bar interaction does is independently configurable -- **Bar: Left/Right/Middle click** and **Bar: Scroll up/down**, each a choice of Open panel, Refresh now, Open Home Assistant, Control entity or Nothing. Defaults: left click opens the panel, right click refreshes, middle click opens Home Assistant, scrolling does nothing. **Control entity** sends the gesture to the entity marked with `bar_target: true` in the layout. Its defaults are toggle on right click and brightness up/down on scroll for lights; play/pause and volume up/down for media players; and toggle and percentage up/down for fans. Add a `bar_actions` mapping to that entity to override a gesture with one of those aliases or a literal Home Assistant `domain.service` name.

**Enable animations** controls visual plugin animations. It is on by default and currently rotates active fans' default propeller icons; custom entity icons remain static.

The panel header shows the real Home Assistant mark, a small connection status line (a colored dot + Connecting…/Connected/Error, with a small external-link button that opens Home Assistant itself in the desktop's default browser -- **Panel: Home Assistant link path**, default `/`, picks what page), an **Edit** button and a settings button. The panel itself has two views:

- **My entities** — the configured list, each entity in its own card, showing its current state and domain-appropriate controls:
  - If **Panel: Show entity search** is enabled, the main view has a search bar that matches names, entity IDs, and displayed states; **Panel: Entity search position** places it at the top or bottom (the bottom position stays visible while the entity list scrolls); matching sections expand automatically while searching.
  - **cover** gets a dedicated open/stop/close row instead of a toggle, plus a position slider when Home Assistant reports `current_position`. Favorite positions can be configured per entity with `favorite_positions: [0, 50, 100]` and appear as shortcut buttons in the details view.
  - **light** gets a state-aware bulb/bulb-off entity icon and an on/off toggle that swaps its own glyph to show state, plus a brightness slider under the row whenever it's on and Home Assistant reports a brightness (i.e. it's dimmable).
  - Color-capable **lights** show a **Color** button beside their on/off toggle. It opens Noctalia's native color picker and applies the selected RGB color through Home Assistant.
  - **fan** gets a propeller/propeller-off entity icon, a plain toggle, and an oscillation toggle whenever Home Assistant reports the `oscillating` attribute; it also gets a speed slider under the row whenever it's on and Home Assistant reports a percentage (i.e. it supports speed control).
  - Every other toggleable domain (switches, scripts, automations, climate, locks, media players, and so on) gets a plain toggle button.
  - Sliders only call Home Assistant once dragging ends, not on every intermediate value, so dragging never floods it with requests.
  - The header's **Edit** button switches the whole list into edit mode at once: every card's normal controls (toggle, cover buttons, sliders) hide and a rename (pencil) and remove (trash) button take their place, so there's no risk of nudging a light while trying to rename it. **Done** switches back. Renaming only overrides what this plugin displays; it never touches the entity in Home Assistant.
  - **Add entity** and **Section** appear in the edit footer. **Panel: Hide edit button** removes the header button and disables panel layout editing; it is off by default.
- **Add entity** (via the footer's **+ Add** button) — a search box, independent Domain and Area dropdowns, and paginated results with an Add button per row. Selecting both a domain and an area combines them with AND semantics. Areas come from Home Assistant's own area registry (fetched once when the browser opens). **Load more** fetches another bounded page; it never fetches everything at once.

### Declarative layout and state

The base layout is an optional YAML file at
`~/.config/noctalia/ha.yaml`. The plugin-owned state overlay is
`~/.local/state/noctalia/plugins/data/pschmitt/ha/layout.yaml`; it has
precedence over the base, just like Noctalia's `config.toml` and
`settings.toml`. The panel writes only the state overlay, so the declarative
file can be a read-only Home Manager file. Remove the state file to reapply
changes from the base file.

The supported layout is intentionally small and readable:

```yaml
entities:
  - light.hue_office_light
  - entity_id: sensor.washing_machine_status
    state_attr: current_program_guess
  - entity_id: sensor.schmutzi_current_status
    state_template: "{{ states('sensor.schmutzi_time_remaining') }}"
  - entity_id: switch.garden_pump
    conditions:
      entity: input_boolean.garden_mode
      state: "on"
  - entity_id: cover.office_blind
    favorite_positions: [0, 50, 100]
sections:
  - name: Office
    collapsed: true
    entities:
      - entity_id: light.hue_office_light
        bar_target: true
  - name: Garden
    conditions:
      entity: input_boolean.garden_mode
      state: "on"
    entities:
      - switch.garden_pump
  homeassistant:
    customize:
      light.hue_office_light:
        friendly_name: Office lamp
        icon: mdi:desk-lamp
```

An entity listed in a section is selected automatically, so the top-level
`entities` list may be omitted when every entity belongs to a section. Set
`bar_target: true` on one configured entity to make it the target for bar
interactions set to **Control entity**. Optional `bar_actions` entries use
`left_click`, `right_click`, `middle_click`, `scroll_up`, and `scroll_down` as
keys; values can be the built-in aliases or a literal `domain.service` name.
Set a value to `none` to disable that gesture. Set
`state_attr` on an entity entry to display one of that entity's Home Assistant
attributes in place of its normal state; the real state remains available for
conditions, coloring, and controls. `state_template` accepts an HA-style Jinja
expression, with or without the surrounding `{{ }}`, and can use functions
such as `states()`, `state_attr()`, and `is_state()`; it replaces `state_attr`
when both are present. The real state remains available for conditions,
coloring, and controls. An entity or section `conditions` block compares
another entity's current state; use `not: true` to invert it. `if` is accepted
as a shorthand alias when reading a hand-written file, but the plugin writes
`conditions`. The condition entity is queried together with the selected
entities, so this remains bounded and does not fetch all of HA. Section-less
entities are shown first, followed by sections in file order. `collapsed` is
the initial state for each panel open; clicking a section header changes it
for the current panel session.

In edit mode, drag an entity by its grip to reorder it or move it between a
section and the section-less list; the up/down and move buttons remain as a
keyboard-friendly fallback. Drag section headers to reorder categories, or
use their up/down controls. Section headers also expose a rename action. The
**Section** button creates a new named section; it can start empty, after
which entities can be dragged into it.
These edits are written to the state overlay, leaving a Home Manager-managed
`ha.yaml` unchanged.

Click an entity card outside edit mode to open its details view. It fetches
that entity from Home Assistant and shows its actual state, last-changed and
last-updated timestamps, plus its attributes. While the view is open, details
are refreshed every two seconds and again immediately after a control call, so
the displayed state follows interactions without leaving the page. Attribute
values are bounded for display, and the view never requests the full HA state
list. Controllable entities also show their controls there: media players
include play/pause, mute, power, and a volume slider, while lights, fans, and
covers expose their corresponding controls. Read-only entities only show
their details.

Media-player cards additionally show play/pause, mute, power, and volume
controls. The power button uses Home Assistant's generic toggle service. The
status subtitle includes the current track and artist when Home Assistant
provides them. A media-player entity may also set `remote: remote.example` in
the layout; its details view then shows a D-pad with Up/Down/Left/Right, OK,
Home, and Back buttons, sent through Home Assistant's `remote.send_command`.

Aliases and icon overrides use Home Assistant's familiar
`homeassistant.customize` syntax and are applied only to this plugin's
display; the plugin does not modify Home Assistant. Noctalia renders Tabler
glyphs, so the plugin translates common `mdi:` names to their closest Tabler
equivalent (for example, `mdi:washing-machine` becomes `wash-machine` and
`mdi:desk-lamp` becomes `lamp`). Unknown MDI names have their prefix removed
and are passed through as a glyph name. The older temporary `labels:` mapping
is still accepted when reading an existing file.

The plugin ID is `pschmitt/ha`; existing `pschmitt/hassio` state is not
migrated as part of the rename.

`server_file` and `token_file` point to files containing the Home Assistant URL and a long-lived access token, read only at request time — the same sops-nix runtime secret pattern `pschmitt/ha-ai-usage` uses, and in practice the same secret files.

The plain toggle button calls Home Assistant's generic `homeassistant.toggle` service, which covers every domain the panel offers one for. Covers, light brightness/color, fan speed/oscillation call their own domain-specific services (`cover.open_cover`/`close_cover`/`stop_cover`, `light.turn_on` with `brightness`/`rgb_color`, `fan.set_percentage`/`oscillate`) instead.

`assets/home-assistant-icon.png` is Home Assistant's own icon mark, from the project's [home-assistant/brands](https://github.com/home-assistant/brands) repo (`core_integrations/_homeassistant/icon@2x.png`) -- the same repo every third-party Home Assistant integration and companion app sources its branding from.
