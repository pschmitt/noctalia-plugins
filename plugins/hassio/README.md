# Home Assistant

Status and one-click toggle in the Noctalia bar for a small, explicitly chosen set of Home Assistant entities, plus a panel to browse Home Assistant and pick more.

## Why this exists

The community `pozzoo/hassio` plugin's entity browser asks Home Assistant to render every entity in one `/api/template` call and, when that is rejected, falls back to downloading and decoding the complete `/api/states` response in a single script callback. On a small Home Assistant instance that works fine. On a large one it does not: Home Assistant itself caps template output length and rejects the request, and even when it doesn't, decoding a multi-megabyte JSON response outruns Noctalia's per-callback CPU budget outright and the plugin crashes before it ever becomes usable. Verified against a 7000+ entity instance: both failure modes reproduce, in that order.

This plugin never makes either kind of unbounded request. The bar/status query names only the entities you've configured, however few. The "Add entity" browser pages through Home Assistant's entity list a bounded chunk at a time (see **Advanced: Browser page size**), optionally scoped to one domain, so every single request stays small regardless of how many entities the instance has.

## Usage

Add `pschmitt/hassio:bar` to a Noctalia bar. It shows one icon per configured entity, tinted to reflect its state, with a tooltip listing names and states. Click opens the panel; right-click refreshes immediately.

The panel has two views:

- **My entities** — the configured list, each row showing its current state with a toggle button (for domains a plain on/off toggle makes sense for: lights, switches, scripts, automations, climate, covers, locks, fans, media players, and so on) and a remove button.
- **Add entity** (via the **+ Add** button) — a search box, domain filter chips, and paginated results with an Add button per row. **Load more** fetches another bounded page; it never fetches everything at once.

Entities you add live in a small file this plugin manages itself (`entities.json` in its own plugin data directory), not in a Noctalia setting — that's what lets the panel add/remove entries live without needing a settings-write API this plugin's runtime doesn't have.

`server_file` and `token_file` point to files containing the Home Assistant URL and a long-lived access token, read only at request time — the same sops-nix runtime secret pattern `pschmitt/ha-ai-usage` uses, and in practice the same secret files.

Toggling calls Home Assistant's generic `homeassistant.toggle` service, which covers every domain the panel offers a toggle button for.
