# Syncthing

`pschmitt/syncthing` is a presentation-focused fork of Marco Ziliani's
[`rylos/syncthing`](https://github.com/noctalia-dev/community-plugins/tree/main/syncthing)
plugin. It retains the upstream service, panel, launcher, shortcut, and
desktop widget while using a larger tray-like icon and composited status
badges in the bar.

## Setup

Install and run Syncthing for the same user as Noctalia, enable
`pschmitt/syncthing`, then open its settings. Enter the Syncthing GUI URL
(normally `http://127.0.0.1:8384`) and API key; select folders to show when
needed. The plugin can also read a Syncthing configuration file to discover
connection details.

The manifest declares the runtime commands it uses: `syncthing`, `gio`, and
`xdg-open`. The Nix package supplies the plugin itself; install those commands
through your normal desktop configuration.

## Attribution

The upstream code is MIT-licensed. See [NOTICE](./NOTICE) and the repository's
[MIT notice](../../LICENSES/MIT.txt) for attribution and terms.
