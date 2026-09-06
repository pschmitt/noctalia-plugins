# Home Assistant AI Usage

Home Assistant-backed AI plan usage for the Noctalia bar and an attached detail panel. It reads the quota entities that Home Assistant already collects, so the desktop does not need separate provider CLIs, OAuth stores, or direct API calls.

## Discovery

The plugin first reads Home Assistant's integration registry and recognises loaded instances of Claude Usage, OpenAI Usage Monitor (Codex), GitHub Copilot Usage, and Gemini Usage. It then asks Home Assistant only for the correct active metrics for those integrations; it never downloads the complete state registry. Disabled integrations and unavailable entities are ignored automatically.

There is no user-maintained provider or sensor list. Each supported integration has its own appropriate metric and reset handling, while labels and icons come directly from Home Assistant.

## Usage

Add `pschmitt/ha-ai-usage:bar` to a Noctalia bar. Left click opens the attached panel; right click refreshes Home Assistant data immediately. Set **Bar display mode** to **Compact icon only** for the requested compact mode: the bar shows only discovered metric icons while retaining the tooltip, refresh action, and full detail panel.

`server_file` and `token_file` point to files containing the Home Assistant URL and a long-lived access token. They are read only at request time and are supplied by sops-nix runtime secret files here.

The default bar is deliberately compact: glyphs plus progress bars, with values and labels kept in the tooltip and panel. The tooltip is the at-a-glance view and ignores **Bar cards**, **Bar metric limit** and **Bar quota window** entirely: it lists every discovered account with one short line per headline quota (`Weekly 21%`) — an account's own session/weekly windows only, never Gemini's 3P side quotas or Copilot's per-category counters, and falling back to the primary quota for providers that expose no time window at all. Lines are kept narrow on purpose — the tooltip ellipsizes wide values — so reset times stay in the panel.

What the bar shows is configured plugin-wide (Settings -> Plugins -> Home Assistant AI Usage), not per bar instance: **Bar quota window** picks 5h/session or weekly, **Bar cards** filters which discovered accounts appear, and **Bar metric limit**, **Bar display mode**, names, percentages, reset text, and used-versus-remaining labels round it out. Only the bar's pixel geometry (icon size, progress width/height, spacing) stays a per-widget setting. That split is deliberate: on a declaratively managed Noctalia these keys must be settable from `plugin_settings."pschmitt/ha-ai-usage"`, which per-widget settings are not.

Reset times support relative countdowns and three configurable local-date formats.

## Network and privacy

One authenticated `POST /api/template` request runs at the configured refresh interval (60 seconds by default). Home Assistant filters the active metric set server-side before returning it, and no provider endpoint is contacted from the desktop. The data remains in Noctalia's in-memory plugin state and is not written to disk.

## IPC

```sh
noctalia msg plugin pschmitt/ha-ai-usage:poller all refresh
```
