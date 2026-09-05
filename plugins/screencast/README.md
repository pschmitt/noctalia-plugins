# Screencast Indicator

`pschmitt/screencast` displays a red, breathing `REC` marker in a Noctalia
bar while a portal-based screen share is live. Its tooltip names the PipeWire
client(s) attached to the portal stream.

## Detection

The plugin queries PipeWire itself and inspects the graph for links to
`xdg-desktop-portal` nodes. It uses the compact `pw-cli` node and link listings
instead of decoding the complete `pw-dump` JSON graph. The package substitutes
an absolute `pw-cli` path, so it has no `jq` dependency and does not require a
separately managed `busctl` watcher or a shared state file.

This naturally relies on the PipeWire session and a portal backend—the same
stack used by browser and portal-aware application screen sharing. It reports
portal captures, not arbitrary recorder processes that bypass the portal.

## Setup

Enable `pschmitt/screencast`, then add `pschmitt/screencast:bar` to a bar.
The plugin is hidden when idle. Its settings control poll frequency, colors,
dot size, and pulse animation.
