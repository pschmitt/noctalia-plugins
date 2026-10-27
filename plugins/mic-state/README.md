# Microphone State

`pschmitt/mic-state` mirrors Noctalia's built-in input-volume bar glyph and
colors, but reads and controls the `rnnoise_source` voice branch instead of the
default `meeting_source`. The meeting mix remains unmuted so soundboard clips
can still reach calls while the physical microphone is muted.

Click the widget to open the microphone panel. It includes mute and volume
controls, a live voice level meter, the actual physical PipeWire capture
devices, and a selector for the RNNoise filter's capture device. Virtual
sources and monitor sources are filtered out. Device selection leaves the
meeting mix as the default source and persists across restarts. The plugin
settings also accept an explicit PipeWire source name or `auto` for the device,
and set the scroll volume step and refresh interval.

Changing the volume from the bar or panel shows Noctalia's native microphone
OSD with the new level.

The panel uses Noctalia's Material styling, surface containers, theme colors,
and compact status rows, following the upstream audio and Duo Status panels.
