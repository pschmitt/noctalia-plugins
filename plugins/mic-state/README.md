# Microphone State

`pschmitt/mic-state` mirrors Noctalia's built-in input-volume bar glyph and
colors, but reads the `rnnoise_source` voice branch instead of the default
`meeting_source`. The meeting mix remains unmuted so soundboard clips can still
reach calls while the physical microphone is muted.

The widget uses Noctalia's standard `microphone` / `microphone-mute` glyphs,
`on_surface` / `error` colors, and 16 px base glyph size. It polls the source
once every 500 ms and shows an unavailable-state color if the source is absent.
