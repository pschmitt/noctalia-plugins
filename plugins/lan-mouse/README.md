# Lan Mouse

Bar icon + panel for [lan-mouse](https://github.com/feschber/lan-mouse), a
software KVM switch for sharing a mouse/keyboard on the LAN.

lan-mouse has no IPC/CLI query for "which side currently owns the cursor
right now" — `lan-mouse cli list` only reports per-client connection state
(hostname, position, whether that client connection is active), not input
focus. This plugin instead polls a sentinel file that nixos-config's
`home-manager/gui/lan-mouse.nix` `enter_hook` maintains: it holds the peer's
name while control is away from this host, and is removed once control
returns. The bar icon is hidden while control is on this host, and shows
"→ \<peer\>" while it's away.

The panel lists configured peers (from `lan-mouse cli list`) with their
connection state, and an Enable/Disable button per peer
(`lan-mouse cli activate`/`deactivate`).

## Settings

- `away_sentinel` — path to the sentinel file. Supports `$XDG_RUNTIME_DIR`
  and `~` expansion.
- `poll_interval` — how often to re-check the sentinel and re-run
  `lan-mouse cli list`, in seconds.
- `icon_color` — a Noctalia color role (e.g. `warning`) or a hex color.
- `show_label` — show the peer name next to the icon in the bar.

## Entries

- `[[widget]] id = "bar"` — the bar icon, click opens the panel.
- `[[panel]] id = "panel"` — peer list and status detail.
